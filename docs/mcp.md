# Magnife MCP server (S-034)

`magnife-mcp` lets a coding agent (Claude Code, Codex, Cursor, any MCP client)
read the traces, spans, logs and findings Magnife has stored, so the agent can
check what its change did at run time without anyone copying from the window.

## Shape

- A command-line program in the app bundle:
  `Magnife.app/Contents/Helpers/magnife-mcp`, next to `magnife-ingest`. The
  agent starts it; Magnife does not need to be running to read what is stored.
- Swift, on MagnifeKit: the same read-only `TelemetryReader`, query parser
  (`TraceQuery`), detectors and finding words (`Finding.detailText(in:)`) as
  the window. Nothing about traces is implemented twice.
- Read-only. It opens `~/Library/Application Support/Magnife/magnife.sqlite`
  with `readonly = true` (`APP_STORE` or `--store <file>` for another file),
  like the app. The helper stays the only writer (docs/schema.sql).
- MCP over stdio: JSON-RPC 2.0, one message per line on stdin and stdout,
  diagnostics on stderr. No network, no ports. Protocol versions
  2025-11-25, 2025-06-18, 2025-03-26 and 2024-11-05; capabilities: tools only.
- No dependency: the protocol layer is a few hundred lines in MagnifeKit
  (`MCP/`), unit-tested, so CI's Xcode 26 tests it with the rest.

## Connecting

```sh
# Claude Code, for every project
claude mcp add --scope user magnife -- /Applications/Magnife.app/Contents/Helpers/magnife-mcp
# Codex
codex mcp add magnife -- /Applications/Magnife.app/Contents/Helpers/magnife-mcp
```

Any other client (Cursor, Claude Desktop, VS Code):

```json
{ "mcpServers": { "magnife": { "command": "/Applications/Magnife.app/Contents/Helpers/magnife-mcp" } } }
```

## Tools

All tools are read-only (`readOnlyHint: true`, `openWorldHint: false`) and
answer in plain text: ids first, the app's words for durations ("182 ms"),
statuses and findings. Times are local ISO 8601 plus how long ago.

| Tool | Arguments | Answers |
| --- | --- | --- |
| `list_services` | — | Each service: last seen, error spans. |
| `list_traces` | `query` (⌘K language, optional), `limit` (1-100, default 20), `since_minutes` | Newest traces first: trace id, service, route, duration, spans, status, finding counts, start. The total the query keeps. |
| `get_trace` | `trace_id` (full, or a unique prefix of 8+ characters), `max_spans` (1-500, default 200) | The trace's summary, its findings in the app's words, the span tree (indented, with span ids, services, durations, statuses, error messages), exceptions, and how many logs it has. |
| `get_span` | `trace_id`, `span_id` | Attributes, events, exceptions with stack traces, resource attributes, links and the span's logs. |
| `search_logs` | `trace_id`, or `service`, `levels` (`debug`, `info`, `warn`, `error`, `fatal`), `body_contains`; `limit` (1-200, default 50) | Logs newest first (oldest first for a trace): time, level, service, body, trace and span ids. |
| `find_problems` | `limit` (traces to scan, 1-100, default 50), `since_minutes` | Every finding (Slow SQL, N+1, HTTP Error) in the newest traces, in the app's words with trace and span ids, then failed traces with no finding. |
| `compare_traces` (S-036) | `trace_id` (B), `baseline_trace_id` (A; left out: the fastest of the newest 50 other traces with B's root service and route), `max_rows` (1-500, default 200) | The Compare Traces window in text: both traces, "B took 356 ms longer than A (6.6×). B has 6 more spans.", the differences in the window's words (Error first, then Slower and Faster by self time, Repeated, New, Missing) with span ids from both traces, the Queries (each service's normalized statements, runs and duration in A → B), and the tree of the spans that differ. |

The query language (`list_traces`, docs/ux.md "Search tokens"):
`service:orders`, `status:error`, `route:/checkout`, `>200ms`, `key=value`,
`key~part`, `has:key`, and plain words (any field contains it), combined with AND.

## Limits

- At most 100 traces, 500 spans of a trace (the rest counted: "312 more spans
  not shown"), 200 logs per answer; `compare_traces` at most 500 rows of the
  tree, 50 differences and 50 statements (the rest counted).
- Attribute values, log bodies and statements over 2,000 characters are cut
  with "… (N more characters)"; stack traces over 8,000.
- A trace id that matches nothing, or a prefix that matches several, answers
  `isError` with one sentence that says which.

## Errors

- Tool problems are tool results with `isError: true` and one sentence, so the
  agent can read them: no database yet ("Magnife has not stored any telemetry
  yet. Open Magnife and point your service at localhost:4317 or 4318."), a
  database from a newer Magnife, an unknown trace.
- Wrong arguments (a missing `trace_id`, `limit` out of range, an unknown
  level) are `isError` results too, saying what to send instead, as MCP
  2025-11-25 asks, so the agent can correct itself.
- Protocol problems are JSON-RPC errors: -32700 (not JSON), -32600 (not a
  request), -32601 (unknown method), -32602 (unknown tool, or arguments that
  are not an object).

## Not in S-034

- Settings > Agents with the commands above and a Copy button: S-035.
- Resources, prompts, subscriptions to new traces, writes of any kind.
