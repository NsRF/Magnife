-- Magnife database contract, schema version 1.
--
-- This file is the contract between the Go helper (./ingest, the only writer)
-- and the SwiftUI app (./app, a read-only GRDB consumer). Any change here
-- updates both sides in the same commit and bumps PRAGMA user_version.
--
-- Location: ~/Library/Application Support/Magnife/magnife.sqlite
--           (the helper's --db flag overrides it; tests use /tmp).
--
-- Conventions
--   * Times are integer nanoseconds since the Unix epoch (OTLP's *_unix_nano).
--     *_received_ns columns are the helper's wall clock when it wrote the row.
--   * Trace ids are 32 and span ids 16 lowercase hex characters. All-zero ids
--     from OTLP are stored as NULL.
--   * Status codes follow OTLP: 0 Unset, 1 OK, 2 Error.
--   * Span kind follows OTLP: 0 Unspecified, 1 Internal, 2 Server, 3 Client,
--     4 Producer, 5 Consumer.
--   * Attribute columns hold one JSON object: key -> value. Values map from
--     OTLP AnyValue: string -> string, int -> number, double -> number,
--     bool -> bool, array -> array, kvlist -> object, bytes -> base64 string,
--     empty -> null. Keys are unique; order is not significant.
--   * Event columns hold a JSON array, in time order:
--     [{"time_ns": 1730000000000000000, "name": "exception",
--       "attributes": {"exception.type": "...", "exception.message": "...",
--                      "exception.stacktrace": "..."}}]
--   * Promoted columns on spans (db_*, http_*) are copies of attributes, read
--     with both old and new semantic-convention names, so the app's detectors
--     and list never parse JSON:
--       db_system        db.system | db.system.name
--       db_statement     db.statement | db.query.text
--       http_method      http.method | http.request.method
--       http_status_code http.status_code | http.response.status_code
--       http_route       http.route
--       http_url         http.url | url.full | (url.path, with url.query)
--
-- Writer rules (Go)
--   * journal_mode=WAL, synchronous=NORMAL, foreign_keys=OFF.
--   * Each batch is one transaction. After it commits, the helper writes one
--     line to stdout (see "Helper protocol" at the end of this file).
--   * After inserting spans, the helper recomputes the traces row of every
--     trace touched by the batch from its spans (rules on the traces table).
--   * Pruning deletes a trace, its spans and its logs together.
--   * Persistent WAL: every connection sets SQLITE_FCNTL_PERSIST_WAL, so the
--     -wal and -shm files stay after the helper exits. A read-only reader
--     cannot open a WAL database whose -wal file is missing (SQLITE_CANTOPEN),
--     and the app reads the stored traces at launch, before the helper is up
--     (S-008). Pinned by TestCloseKeepsWALForReadOnlyReaders (Go) and
--     WALReadonlyTests / LifecycleTests (Swift).
--
-- Reader rules (Swift)
--   * Open read-only (GRDB DatabasePool, readonly). Never write, never run
--     migrations, never checkpoint.
--   * Refuse to read a file whose user_version is not the one the app knows,
--     and say so in the window.
--   * A file without its -wal (written by a helper without persistent WAL)
--     cannot be opened until the helper runs: it is "not ready", never empty.

PRAGMA user_version = 1;

-- Key/value facts about the database.
--   schema_version  '1'
--   last_seq        the seq of the last committed batch, as text
--   retention_s     the retention the helper last applied, in seconds
CREATE TABLE IF NOT EXISTS meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
) WITHOUT ROWID;

-- One row per distinct resource (service + host + SDK ...).
CREATE TABLE IF NOT EXISTS resources (
    id           INTEGER PRIMARY KEY,
    hash         TEXT    NOT NULL UNIQUE,  -- sha256 hex of the canonical attributes JSON
    service_name TEXT    NOT NULL,         -- service.name, or 'unknown_service' when missing
    attributes   TEXT    NOT NULL          -- JSON object
);

-- One row per service.name ever seen. Error counts are not stored: the app
-- derives them from spans (see indexes) so pruning never leaves them stale.
CREATE TABLE IF NOT EXISTS services (
    name             TEXT    PRIMARY KEY,
    first_seen_ns    INTEGER NOT NULL,  -- wall clock of the first span or log
    last_seen_ns     INTEGER NOT NULL   -- wall clock of the latest span or log
) WITHOUT ROWID;

-- One row per trace, recomputed by the helper from its spans after every
-- batch that touched it.
--   root_span_id  the span with no parent; NULL until it arrives
--   root_service  service of the root span; before the root arrives, of the
--                 earliest-starting span whose parent is not in the trace
--   route         "<http_method> <http_route>" of that span when both exist,
--                 else its http_route, else its name
--   status        2 if any span is Error; else the root's status (1 or 0);
--                 before the root arrives, 0
--   first_seq     seq of the batch that created the row (Pause counts rows
--                 with first_seq > the seq at pause time)
--   updated_seq   seq of the last batch that changed the row
CREATE TABLE IF NOT EXISTS traces (
    trace_id         TEXT    PRIMARY KEY,
    root_span_id     TEXT,
    root_service     TEXT    NOT NULL,
    route            TEXT    NOT NULL,
    start_ns         INTEGER NOT NULL,  -- min(spans.start_ns)
    end_ns           INTEGER NOT NULL,  -- max(spans.end_ns)
    duration_ns      INTEGER NOT NULL,  -- end_ns - start_ns
    span_count       INTEGER NOT NULL,
    error_count      INTEGER NOT NULL,  -- spans with status_code = 2
    status           INTEGER NOT NULL,
    first_seq        INTEGER NOT NULL,
    updated_seq      INTEGER NOT NULL,
    received_ns      INTEGER NOT NULL   -- wall clock of the last update; pruning uses it
) WITHOUT ROWID;

CREATE INDEX IF NOT EXISTS traces_by_start        ON traces (start_ns DESC);
CREATE INDEX IF NOT EXISTS traces_by_status       ON traces (status, start_ns DESC);
CREATE INDEX IF NOT EXISTS traces_by_root_service ON traces (root_service, start_ns DESC);
CREATE INDEX IF NOT EXISTS traces_by_duration     ON traces (duration_ns);
CREATE INDEX IF NOT EXISTS traces_by_first_seq    ON traces (first_seq);
CREATE INDEX IF NOT EXISTS traces_by_updated_seq  ON traces (updated_seq);
CREATE INDEX IF NOT EXISTS traces_by_received     ON traces (received_ns);

CREATE TABLE IF NOT EXISTS spans (
    id               INTEGER PRIMARY KEY,
    trace_id         TEXT    NOT NULL,
    span_id          TEXT    NOT NULL,
    parent_span_id   TEXT,               -- NULL for a root span
    name             TEXT    NOT NULL,
    kind             INTEGER NOT NULL,
    start_ns         INTEGER NOT NULL,
    end_ns           INTEGER NOT NULL,
    duration_ns      INTEGER NOT NULL,   -- max(0, end_ns - start_ns)
    status_code      INTEGER NOT NULL,
    status_message   TEXT    NOT NULL DEFAULT '',
    service_name     TEXT    NOT NULL,   -- copy of resources.service_name
    resource_id      INTEGER NOT NULL REFERENCES resources (id),
    scope_name       TEXT    NOT NULL DEFAULT '',
    scope_version    TEXT    NOT NULL DEFAULT '',
    attributes       TEXT    NOT NULL DEFAULT '{}',
    events           TEXT    NOT NULL DEFAULT '[]',
    links            TEXT    NOT NULL DEFAULT '[]', -- [{"trace_id","span_id","attributes"}]
    db_system        TEXT,
    db_statement     TEXT,
    http_method      TEXT,
    http_status_code INTEGER,
    http_route       TEXT,
    http_url         TEXT,
    received_ns      INTEGER NOT NULL,
    UNIQUE (trace_id, span_id)           -- a resent span replaces the old row
);

CREATE INDEX IF NOT EXISTS spans_by_trace          ON spans (trace_id, start_ns);
CREATE INDEX IF NOT EXISTS spans_by_service_status ON spans (service_name, status_code, trace_id);
CREATE INDEX IF NOT EXISTS spans_by_db             ON spans (trace_id) WHERE db_system IS NOT NULL;

CREATE TABLE IF NOT EXISTS logs (
    id               INTEGER PRIMARY KEY, -- grows with every insert; "logs since id"
    time_ns          INTEGER NOT NULL,    -- time_unix_nano, or observed time when 0
    observed_ns      INTEGER NOT NULL DEFAULT 0,
    severity_number  INTEGER NOT NULL DEFAULT 0, -- OTLP 0..24
    severity_text    TEXT    NOT NULL DEFAULT '',
    service_name     TEXT    NOT NULL,
    resource_id      INTEGER NOT NULL REFERENCES resources (id),
    scope_name       TEXT    NOT NULL DEFAULT '',
    body             TEXT    NOT NULL DEFAULT '', -- string body as is; other bodies as JSON
    attributes       TEXT    NOT NULL DEFAULT '{}',
    trace_id         TEXT,
    span_id          TEXT,
    event_name       TEXT    NOT NULL DEFAULT '',
    received_ns      INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS logs_by_time     ON logs (time_ns DESC);
CREATE INDEX IF NOT EXISTS logs_by_trace    ON logs (trace_id, time_ns) WHERE trace_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS logs_by_service  ON logs (service_name, time_ns DESC);
CREATE INDEX IF NOT EXISTS logs_by_severity ON logs (severity_number, time_ns DESC);
CREATE INDEX IF NOT EXISTS logs_by_received ON logs (received_ns);

-- Every attribute key seen, for filter-bar autocomplete.
--   source 1 span, 2 resource, 3 log
CREATE TABLE IF NOT EXISTS attribute_keys (
    key          TEXT    NOT NULL,
    source       INTEGER NOT NULL,
    last_seen_ns INTEGER NOT NULL,
    PRIMARY KEY (key, source)
) WITHOUT ROWID;

-- Helper protocol (not SQL, but part of the same contract)
--
-- The app starts the helper as a child process:
--   Contents/Helpers/magnife-ingest --db <path> --grpc 127.0.0.1:4317
--                                   --http 127.0.0.1:4318 --retention <seconds>
-- The helper binds 127.0.0.1 only. It exits when its stdin reaches EOF, so it
-- dies with the app even after kill -9. Its own logs go to stderr.
--
-- stdout: one JSON object per line, flushed at once.
--   {"type":"ports","grpc":{"addr":"127.0.0.1:4317","state":"listening"},
--                   "http":{"addr":"127.0.0.1:4318","state":"busy",
--                           "owner":"otelcol-contrib","pid":4242}}
--       Sent once at startup, after the schema is ready, and again after a
--       "retry" command. state is "listening" or "busy". owner and pid are
--       present when the process holding the port could be found. A port held
--       by any other listener on any address (including *:port) is busy; the
--       helper does not bind alongside it.
--   {"type":"batch","seq":42,"spans":120,"logs":30,
--    "traces":["<trace id>", ...],"error_traces":["<trace id>", ...]}
--       One per committed batch. traces lists every trace touched; error_traces
--       lists the touched traces whose status became 2 in this batch.
--   {"type":"pruned","traces":12,"spans":340,"logs":56}
--       After a pruning pass that deleted anything.
--   {"type":"error","message":"..."}
--       A problem the app should show (for example the database cannot open).
--   {"type":"imported","path":"/Users/me/checkout.otlp.jsonl","spans":12,"logs":3,
--    "traces":["<trace id>", ...]}
--       After an "import" command, once its records are committed (their batch
--       lines come first). traces lists the file's distinct trace ids in file
--       order.
--   {"type":"import_failed","path":"/Users/me/notes.txt","message":"..."}
--       An "import" that stored nothing; message is a sentence to show.
--
-- stdin: one command per line.
--   retention <seconds>   set the retention and prune at once
--   prune                 prune now
--   retry                 try to bind any busy port again, then send "ports"
--   import <path>         store the spans and logs of an OTLP JSON file (one
--                         request, or one per line); <path> is absolute and is
--                         the rest of the line. Answered by "imported" or
--                         "import_failed".
