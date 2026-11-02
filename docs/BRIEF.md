# Magnife

A native macOS app that receives OpenTelemetry from what a developer runs on their own Mac and shows traces and logs instantly: no Docker, no Jaeger, no vendor account. For backend and full-stack developers on Mac who use OTel (.NET, Go, Node, Python, Java). Pitch: "the Proxyman of OpenTelemetry."

Bundle id: `com.nasserfarhat.magnife` (decided by the agent).

## Replaces
Running Jaeger, Grafana or the Aspire dashboard in Docker, or browser-based CLI viewers (otel-desktop-viewer, otelop), just to see local telemetry.

## Main jobs
1. Point an app at Magnife and see its first trace in under 60 seconds after install.
2. Find the failing or slow trace in seconds (live list, search, filters, detector flags).
3. Open a trace and see why: waterfall, span attributes, exceptions with stack traces, and the logs for that span.

## Version one scope (v0.1, as written in the MVP spec)
1. Built-in OTLP receiver on 4317 (gRPC) and 4318 (HTTP), listening as soon as the app opens, with a button that copies ready-made environment variables.
2. Live trace list: service, route, duration, status, span count.
3. Trace waterfall with span detail: attributes, events, exceptions with stack trace, source resource.
4. Logs correlated to trace and span, plus a Logs tab filtered by level and service.
5. Fast search and filters by service, status, minimum duration and any attribute, with Cmd+K.
6. Automatic detectors flagged on the trace: slow SQL queries, N+1 (same statement repeated within a trace), failed HTTP calls.
7. Menu bar icon with a recent-error count, and a native notification when a trace with an error arrives.
8. Local persistence with configurable retention, so data survives an app restart.

## Data
- Service: name, resource attributes, error count
- Trace: trace id, root service, route, start, duration, status, span count
- Span: span id, parent id, name, kind, start/end, status, attributes, events, exceptions (stack trace), resource
- LogRecord: time, level, service, body, attributes, trace id, span id
- Finding (from detectors): kind (slow SQL / N+1 / HTTP error), trace, span(s)
- SavedFilter: name, query

## Shape
Three-column window: sidebar (detected services with error counts, saved filters), center (live traces, newest first, with Pause to freeze the list), detail (waterfall; clicking a span shows its attributes, logs and exceptions). Plus a Logs tab and a menu bar extra. The empty state shows the env vars to copy, with tabs per language (.NET, Go, Node, Python, Java). macOS 26 or later (decided by the agent).
Local data: SQLite in WAL mode, written in batches by a Go helper (the OTel Collector's OTLP receiver) that the app starts and stops, and read by the SwiftUI app with GRDB. The helper signals each committed batch with a line on its stdout pipe, and exits when its stdin closes (changed from the spec's local socket after research; see research/platform.md). Works offline. No accounts.

## System hooks
Localhost OTLP listener (4317/4318), bundled Go helper process, menu bar extra (icon turns red on error, last five failed traces, one click opens the detail), native notifications, Cmd+K, keyboard shortcuts everywhere.

## Reference
Proxyman sets the bar for speed and polish. It is a benchmark for feel, not an app to clone.

## Look
Native Mac app with the system accent color (decided by the agent, since the spec names none), native dark mode, launches in under 1 second, no Electron.

## Not in version one
- v0.2: metrics with charts; side-by-side comparison of two traces
- v0.2: export and import traces as files to share with a team
- v0.3: AI agent view (calls, tools, tokens and cost for Claude Code, Codex and similar)
- v0.3: MCP server so agents can query local traces
- v0.4: forwarding to a remote backend (OTLP proxy)
