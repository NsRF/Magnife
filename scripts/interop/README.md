# SDK interop checks

Small apps that use the official OpenTelemetry SDKs to send one trace (3 spans: a server span, a database call and a failed HTTP call with an exception), two logs (one inside the database span, one outside any span) and one metric to Magnife. Each app is configured only by standard `OTEL_*` environment variables and exits non-zero if its SDK reports an export error.

```sh
scripts/interop/run-all.sh          # gRPC on 34317, HTTP on 34318
scripts/interop/run-all.sh 44317    # gRPC on 44317, HTTP on 44318
```

`run-all.sh` builds and starts its own `magnife-ingest` on a fresh database in `/tmp`, runs every SDK with every protocol it supports, checks the rows with `sqlite3` (service name, ids, parent links, trace row, promoted columns, log correlation) and the helper's `-v` log for the dropped metrics, then prints PASS/FAIL per SDK and protocol. A `(protocol)` row leaves `OTEL_EXPORTER_OTLP_PROTOCOL` unset and checks the SDK's default. The first run downloads packages (Go modules, npm, NuGet, PyPI); missing toolchains are skipped.

| Folder | SDK | Protocols |
| --- | --- | --- |
| `go/` | `go.opentelemetry.io/otel` with otlptracehttp/grpc, otlploghttp/grpc, otlpmetrichttp/grpc | grpc, http/protobuf |
| `node/` | `@opentelemetry/sdk-node` | grpc, http/protobuf, http/json |
| `dotnet/` | `OpenTelemetry.Exporter.OpenTelemetryProtocol` (.NET 10 console app) | grpc, http/protobuf |
| `python/` | `opentelemetry-distro` + `opentelemetry-exporter-otlp`, run under `opentelemetry-instrument` | grpc, http/protobuf |

## Environment variables that work

Every SDK takes the same three variables. The endpoint is the base URL without `/v1/traces`; the HTTP exporters add the signal path themselves.

```sh
export OTEL_SERVICE_NAME=my-service
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318   # gRPC: http://localhost:4317
export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf           # or grpc (Node also http/json)
```

Per language:

- **Go**: the exporters read `OTEL_EXPORTER_OTLP_ENDPOINT` (an `http://` endpoint means no TLS), but the app picks the exporter package for the protocol in code; the Go SDK has no `http/json`.
- **Node** (`@opentelemetry/sdk-node`): traces, logs and metrics all go to OTLP by default (`OTEL_TRACES_EXPORTER`, `OTEL_LOGS_EXPORTER` and `OTEL_METRICS_EXPORTER` default to `otlp`). Default protocol: `http/protobuf`.
- **.NET**: `AddOtlpExporter()` with no options. The default protocol is `grpc` on 4317, so either use `http://localhost:4317`, or set `OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf` with `http://localhost:4318`. Log bodies arrive as the message template (`loading order {OrderId}`) with the values as attributes, unless the app sets `IncludeFormattedMessage = true`.
- **Python**: run under `opentelemetry-instrument`, and add `OTEL_PYTHON_LOGGING_AUTO_INSTRUMENTATION_ENABLED=true` for logs from the `logging` module. The distro's default protocol is `grpc` on 4317.

Optional: `OTEL_BSP_SCHEDULE_DELAY=500` (a standard SDK variable) sends spans every 0.5 s instead of every 5 s, so traces show up sooner in a long-running app. The apps here flush on exit, so `run-all.sh` does not exercise it.
