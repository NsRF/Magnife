# Magnife architecture

Two programs share one SQLite file. The contract is `docs/schema.sql`.

```text
apps ──OTLP──> ingest/ (Go helper, magnife-ingest) ──writes──> magnife.sqlite
                    │ stdout JSON lines: ports, batch, pruned, error
                    v
               app/ (SwiftUI, Magnife.app) ──reads (GRDB, read-only)──> magnife.sqlite
                    │ stdin: retention, prune, retry; EOF = exit
```

## Targets and layers

- `ingest/` (Go): `cmd/magnife-ingest` (flags), `internal/helper` (the stdin and
  stdout protocol), `internal/receiver` (OTLP/gRPC and OTLP/HTTP on 127.0.0.1),
  `internal/ports` (busy-port check and owner), `internal/convert`
  (pdata to rows and JSON), `internal/store` (batch writer, persistent WAL, pruning,
  embeds a byte-identical copy of `docs/schema.sql`); `cmd/send-sample-traces` and
  `internal/sample` are the test sender.
- `app/Sources/MagnifeKit` (Swift library, no SwiftUI): records and the rules on
  them (`Waterfall`, `SpanDetail`, `TraceList`, `TraceListState`), the read-only
  `TelemetryReader` with all SQL in `TelemetrySQL`, the helper protocol and
  `HelperSupervisor`, formatting. Unit-tested in `app/Tests/MagnifeKitTests`.
- `app/Sources/Magnife` (the app, main actor by default): `AppModel` (observable
  state, split by story into extensions), SwiftUI views, two AppKit outlines (the
  waterfall's NSOutlineView, the span detail's NSSplitView), the self-test and
  snapshot modes.

Dependencies point one way: `Magnife` -> `MagnifeKit` -> GRDB. MagnifeKit never
imports the app.

## Threading

Every database read is a `@concurrent` method on `TelemetryReader` (GRDB's reader
queues); tree building (`Waterfall.build`) and span ordering (`SpanDetail.init`) run
there too. `AppModel` awaits them and assigns results on the main actor. Results
carry the seq they read; the rules that drop an older result live in value types
(`TraceListState.applying` for the list) or next to the read (`updated_seq` for the
open trace). Values shown together come from one `pool.read` (one WAL snapshot):
the open trace's row, waterfall spans and findings are `TelemetryReader.openTrace`.
Whether a refresh came from the helper's batches (and so is paced) is the
task-local `RefreshPacing.isBatch`, never a stored flag, since refreshes overlap.

## Seams

- The helper executable: `APP_HELPER` (none, or another binary); `FakeHelper`
  stands in for it in the self-test.
- The database file: `APP_STORE` (tests and snapshots use /tmp).
- Ports: `APP_GRPC_PORT`, `APP_HTTP_PORT`.

Both live lists (traces, logs) report and set their scroll position through
`TraceListScroller`; revealing a row after a read (Resume, Open Trace, Search) is
its `reveal(row:once:)`, which waits for the table to show the model's rows.

Reviews: `docs/architecture-review-2026-11-02.md` (M1),
`docs/architecture-review-2026-11-02-m2.md` (M2), `docs/architecture-review-2026-11-02-m3.md` (M3).
