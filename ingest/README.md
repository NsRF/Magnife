# magnife-ingest

The Go helper behind Magnife. It receives OTLP on `127.0.0.1` (gRPC on 4317, HTTP on 4318), writes traces and logs to `magnife.sqlite` in batches, and tells the app about each committed batch with one JSON line on stdout. The app starts it as a child process and reads the database with GRDB.

The database schema and the stdout/stdin protocol are defined in [`docs/schema.sql`](../docs/schema.sql); that file is the contract and this README only summarizes it.

## Build

```sh
ingest/build.sh            # universal binary at ingest/bin/magnife-ingest (git-ignored)
```

`build.sh` builds `darwin/arm64` and `darwin/amd64` with `CGO_ENABLED=0 -trimpath -ldflags "-s -w -B gobuildid"`, joins them with `lipo -create`, and checks that both slices have an `LC_UUID`. CGO is off everywhere (SQLite is `modernc.org/sqlite`), so the amd64 slice needs no C toolchain.

For development, `go build ./cmd/magnife-ingest` or `go run ./cmd/magnife-ingest` work too. Tests: `go test -race ./...`.

## Run without the app

```sh
# In a terminal: stdin stays open (the tty), so the helper runs until Ctrl-D or Ctrl-C.
go run ./cmd/magnife-ingest --db /tmp/magnife/magnife.sqlite

# In the background: stdin is /dev/null, an immediate EOF, so pass --no-stdin
# and stop it with kill (SIGTERM) or Ctrl-C.
go run ./cmd/magnife-ingest --db /tmp/magnife/magnife.sqlite --no-stdin &

# Send the seed data (see scripts/send-sample-traces --help for load modes).
scripts/send-sample-traces
```

Then point any OpenTelemetry SDK at it:

```sh
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318
export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
```

## Flags

| Flag | Default | Meaning |
| --- | --- | --- |
| `--db <path>` | `~/Library/Application Support/Magnife/magnife.sqlite` | Database file; its directory is created (mode 0700). |
| `--grpc <addr>` | `127.0.0.1:4317` | OTLP/gRPC address. Must be a loopback IP; port 0 picks a free port. |
| `--http <addr>` | `127.0.0.1:4318` | OTLP/HTTP address. Same rules. |
| `--retention <seconds>` | `86400` | Keep traces and logs this long. |
| `--no-stdin` | off | Do not read stdin or exit on its EOF; stop with SIGINT/SIGTERM. |
| `-v` | off | Debug logging on stderr. |

Exit codes: 0 after stdin EOF or a signal, 1 when the database cannot be opened, 2 for bad flags. An `error` line on stdout explains 1 and 2 (unknown flags are reported on stderr only).

## Protocol summary

stdout carries only protocol lines, one JSON object per line, each written in one call; all logging goes to stderr.

- `{"type":"ports","grpc":{...},"http":{...}}` once the schema is ready, and again after `retry`. Each port is `listening` or `busy`; a busy port names its `owner` (the executable name from `ps`, which `lsof` truncates to 15 characters) and `pid` when `lsof` can see the process.
- `{"type":"batch","seq":..,"spans":..,"logs":..,"traces":[..],"error_traces":[..]}` after every committed batch.
- `{"type":"pruned","traces":..,"spans":..,"logs":..}` after a pruning pass that deleted something.
- `{"type":"error","message":"..."}` for a problem the app should show.

stdin takes `retention <seconds>`, `prune` and `retry`; anything else (including lines over 4 KiB) is logged on stderr and ignored. EOF means exit: the helper stops the servers, commits the queued batches, closes the database and exits 0, normally in a few milliseconds. It always exits within a second: batches still queued 700 ms after EOF (only possible during a flood that filled the queue) are dropped, and the count is logged on stderr.

## How it works

- **Decoding** uses the OpenTelemetry Collector's `pdata` packages (`ptraceotlp`, `plogotlp`, `pmetricotlp`): the same protobuf and OTLP/JSON decoders and gRPC service registration the Collector's OTLP receiver is built on, without its component framework.
- **HTTP**: `POST /v1/traces`, `/v1/logs`, `/v1/metrics`; `application/x-protobuf` or `application/json`; optional `Content-Encoding: gzip`. The reply is the `Export*ServiceResponse` in the request's encoding. Errors: 415 for another content type or encoding, 400 for an undecodable body, 405 for a method other than POST, 503 while shutting down; error bodies are a `google.rpc.Status`.
- **gRPC**: the trace, logs and metrics services, with gzip registered. Messages up to 64 MiB.
- **Metrics** are accepted and dropped (v0.2). With `-v` the helper logs every export on stderr, and `dropped metrics service=<name>` for metrics.
- **Batching**: handlers decode and convert on their own goroutine, then hand the rows to one writer goroutine through a bounded queue (the backpressure). The writer commits every 50 ms or 2,000 records, whichever comes first, in one transaction, then recomputes the `traces` row of every touched trace from its spans.
- **Ports**: before binding, the helper asks `lsof` for any other listener on the port (any address) and also tries to connect on `127.0.0.1` and `::1`, which catches listeners of other users. This matters because Go listeners set `SO_REUSEADDR`, and with it `127.0.0.1:P` binds fine while another process holds `*:P`, which would split traffic silently (see `internal/ports`).
- **Pruning** runs at startup, every 60 s and on command, 500 traces per transaction, between batches.
- **SQLite**: WAL, `synchronous=NORMAL`, a 16 MiB page cache (as fast as 64 MiB in `BenchmarkCommit`, and the helper stays near 55 MB physical footprint at 5,000 spans/s instead of 160 MB), one connection, and persistent WAL (`SQLITE_FCNTL_PERSIST_WAL`): the checkpointed `-wal` and `-shm` files stay after a clean exit, so the app's read-only connection can open the database at launch, before the helper is up (S-008).

## Checks with real SDKs

`scripts/interop/run-all.sh` runs the official Go, Node, .NET and Python SDKs against a fresh helper over every protocol they support and checks the rows; see `scripts/interop/README.md` for the environment variables each language needs.

## Layout

| Path | What |
| --- | --- |
| `cmd/magnife-ingest` | The helper's `main`, plus end-to-end tests that run it as a child process. |
| `cmd/send-sample-traces` | Sample sender (wrapped by `scripts/send-sample-traces`). |
| `internal/helper` | Startup, ports, stdin commands and stdout lines. |
| `internal/receiver` | OTLP/HTTP and OTLP/gRPC servers. |
| `internal/convert` | pdata to rows: attribute, event and link JSON, promoted columns. |
| `internal/store` | Schema (`schema.sql`, a byte-for-byte copy of `docs/schema.sql`, checked by a test), batch commit, trace recompute, pruning, the writer goroutine. |
| `internal/ports` | Busy-port detection. |
| `internal/sample` | The sample services and scenarios. |

When `docs/schema.sql` changes, copy it to `internal/store/schema.sql`; `TestSchemaCopyMatchesDocs` fails until you do.
