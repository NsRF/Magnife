# Magnife — Glossary

Every word Magnife puts on screen. One name per idea; the "Not" column lists names that must not appear. Users are developers who know OpenTelemetry, so OTel's own words win over invented ones.

## Voice
Direct, precise, quiet. Talk to "you", say "click", and name OTel concepts the way the spec does.

## Things

| Term | Means | Not |
| --- | --- | --- |
| Trace | One request's full path: all spans that share a trace id | request, transaction, call tree |
| Span | One timed operation inside a trace | step, segment, operation, node |
| Root span | The span with no parent; it names the trace's route | top span, entry |
| Service | The app that sent a span, from `service.name` | app, source, component |
| Resource | The attributes describing where a span came from (service, host, SDK) | origin, process info |
| Attribute | One key and value on a span, log or resource | tag, label, field, property |
| Event | A timestamped note recorded on a span | annotation, span log |
| Exception | An error recorded on a span, with type, message and stack trace | crash, fault, error event |
| Stack Trace | The call stack of an exception | backtrace, traceback, stack |
| Log | One log record, linked to a trace and span when they are known | log entry, log line, message |
| Waterfall | The detail view that draws a trace's spans as nested bars over time | timeline, Gantt, flame graph |
| Route | What the trace was for: the root span's `http.route`, otherwise its name | endpoint, path, URL |
| Duration | How long a span or trace took, shown as "12 ms" or "1.24 s" | latency, time, elapsed |
| Spans (count) | How many spans a trace has | size, depth |
| Status | OK, Error or Unset, as OTel defines it | result, state, outcome |
| Error | Status of a span that failed, and of any trace that contains one | failure, failed, fault, issue |
| Receiver | The part of Magnife that listens for OTLP on ports 4317 and 4318 | server, collector, listener, agent |
| Port | A local network port: 4317 for gRPC, 4318 for HTTP | socket, endpoint |
| Environment Variables | The `OTEL_*` settings that point an app at Magnife | env, config, setup snippet |
| Kind | A span's OTel kind: Server, Client, Internal, Producer, Consumer | type, role |

## Actions

| Term | Means | Not |
| --- | --- | --- |
| Copy Environment Variables | Put the shown `OTEL_*` lines on the pasteboard | Copy Config, Copy Setup, Copy Snippet |
| Copy Stack Trace | Put an exception's full stack trace on the pasteboard | Copy Error, Copy Exception |
| Try Again | Retry listening on a port that was busy | Retry, Reconnect, Restart Receiver |
| Quit Magnife | Close the app and stop the receiver | Exit, Stop, Shut Down |
| Show All / Show Less | Expand or collapse a long value or stack trace | More, Expand, See Full |
| Copied | Brief feedback on a copy button after it copies | Done, Success, Copied to Clipboard |

## Status lines

| Text | When |
| --- | --- |
| Receiving on 4317 and 4318 | Both ports listening |
| Receiving on 4318 only / Receiving on 4317 only | One port busy |
| Not receiving | Both ports busy |
| Waiting for the first trace… | Empty state after copying the environment variables |
