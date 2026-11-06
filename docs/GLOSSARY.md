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
| Coding Agent | An AI tool that changes code and can read Magnife through MCP (Claude Code, Codex, Cursor) | AI, assistant, bot, LLM; never "agent" for the receiver |
| MCP Server | `magnife-mcp`, the program a coding agent starts to read Magnife's traces | plugin, integration, API, connector |
| Kind | A span's OTel kind: Server, Client, Internal, Producer, Consumer | type, role |
| Finding | A problem a detector flagged on a span or trace: Slow SQL, N+1 or HTTP Error | issue, insight, warning, alert, problem |
| Slow SQL | Finding: a database span that took over 100 ms | slow query, DB warning |
| N+1 | Finding: the same normalized statement 5 or more times in one trace | repeated query, N plus 1, chatty |
| HTTP Error | Finding: an HTTP span with a response code of 400 or higher, or status Error | failed call, bad response |
| Filters | The conditions that narrow the trace list or Logs | query, rules, criteria |
| Filter Bar | The bar above a list that holds its filters (⌘F) | query bar, search bar, filter panel |
| Condition | One key / operator / value row in the filter bar | rule, clause, predicate |
| Any Field | Condition key that matches service, route, trace ID and attribute values | anything, all columns |
| Saved Filter | A named set of scope and filters kept in the sidebar | favorite, preset, view, smart filter |
| Search | The ⌘K box that finds traces as you type | command palette, quick open, find, omnibox |
| Span Detail | Lower pane of the detail column, with the Span and Trace Logs tabs | inspector, panel, details |
| Trace Logs | Every log that carries the open trace's ID | related logs, correlated logs |
| Log Detail | The detail column in the Logs view, for the selected log | log inspector |
| Level | A log's OTel severity, always shown in capitals: TRACE, DEBUG, INFO, WARN, ERROR, FATAL | severity, priority, log type |
| Body | A log's text | message, content, text |
| All Services | The sidebar scope that shows every service | everything, all, unfiltered |
| Traces with errors | How a service's count is worded: stored traces where it has an Error span | errors, failures, error rate |
| Recent Errors | The menu bar extra's list of the last five traces with errors | recent failures, latest issues |
| Database size | Size on disk of the stored traces and logs | storage, disk usage, cache |
| Edited | Marks a saved filter whose filters changed since it was saved | modified, unsaved, dirty |
| Comparison | Two traces' spans matched up side by side, with what differs (S-036) | diff, delta, delta view |
| Compare Traces | The window that shows a comparison | Diff, Trace Diff, Compare View |
| A / B | The two traces of a comparison; changes read B against A | left / right, old / new, before / after |
| Baseline | Trace A, the one B is compared with | reference, original, control |
| Difference | One thing that differs between A and B, as a strip line | change set, delta, regression |
| Same Route | Search's first section in compare mode: traces with A's route | similar traces, siblings |
| Slower / Faster | A span that took over 1 ms and over 20% longer or less in B | regressed, improved, degraded |
| Same | A span within 1 ms or 20% in both traces | unchanged, equal, identical |
| New | A span only in B | added, extra, inserted |
| Missing | A span only in A | removed, deleted, gone |
| Repeated | A statement or span whose number of runs differs, "2 → 8 runs" | calls, executions, iterations |
| Queries | The comparison's table of normalized statements with runs and duration in A and B | statements, SQL, DB calls |
| Runs | How many times a statement or span ran in one trace | calls, executions, hits |

## Actions

| Term | Means | Not |
| --- | --- | --- |
| Copy Environment Variables | Put the shown `OTEL_*` lines on the pasteboard | Copy Config, Copy Setup, Copy Snippet |
| Copy Stack Trace | Put an exception's full stack trace on the pasteboard | Copy Error, Copy Exception |
| Try Again | Retry listening on a port that was busy | Retry, Reconnect, Restart Receiver |
| Quit Magnife | Close the app and stop the receiver | Exit, Stop, Shut Down |
| Show All / Show Less | Expand or collapse a long value or stack trace | More, Expand, See Full |
| Copied | Brief feedback on a copy button after it copies | Done, Success, Copied to Clipboard |
| Pause | Hold the trace list, Logs and open waterfall still; receiving continues | Freeze, Stop, Hold |
| Resume | Add what arrived while paused | Play, Continue, Unpause |
| Search… | Open Search (⌘K) | Find, Quick Open, Go to Trace |
| Show Filter Bar / Hide Filter Bar | Show or hide the filter bar (⌘F) | Filter…, Toggle Filters |
| Clear Filters | Turn every filter off and return to All Services | Reset, Remove Filters, Clear All |
| Apply as Filter | Turn the Search query into filters (⌘Return) | Use as Filter, Convert |
| Save Filter… / Save Filter As… | Keep the current filters as a saved filter | Save Search, Bookmark, Add Favorite |
| Rename Filter… | Change a saved filter's name | Edit, Change Name |
| Delete Filter | Remove a saved filter; Undo brings it back | Remove, Move to Trash |
| Open Trace | Show a trace in the detail column from a log, Search, the menu bar or a notification | Go to Trace, View Trace, Jump to Trace |
| Show Newest Traces | Scroll to the top and insert the waiting traces | Jump to Top, Scroll to Top, Refresh |
| Expand All Spans / Collapse All Spans | Open or close every subtree in the waterfall | Expand Tree, Fold |
| Show Span Detail / Hide Span Detail | Show or hide the lower pane of the detail column | Show Inspector, Toggle Details |
| Copy Trace ID / Copy Span ID | Put the ID on the pasteboard | Copy Identifier, Copy Link |
| Copy Body | Put a log's body on the pasteboard | Copy Message, Copy Log |
| Show Environment Variables | Open the toolbar popover with the language tabs | Setup, Onboarding, Connect App |
| Connect a Coding Agent… | Open Settings > Agents (Help menu) | Set Up AI, Add Integration, Install MCP |
| Copy Command / Copy Configuration | Put the agent's setup command, or its MCP configuration, on the pasteboard | Copy Snippet, Copy Setup, Copy JSON |
| Open Magnife | Bring the main window forward from the menu bar extra | Show Window, Launch |
| Compare With… | Open Search in compare mode to pick trace B for the selected trace (⇧⌘K) | Diff With…, Compare To… |
| Compare with Selected Trace | Compare the selected trace (A) with the right-clicked one (B) | Diff, Compare Selected |
| Swap Traces | Make A the B and B the A (⌥⌘K) | Reverse, Flip, Switch |
| Show Only Differences | Collapse every subtree of the comparison with no difference in it (⇧⌘D) | Hide Unchanged, Diff Only |
| Open Span in A / Open Span in B | Show a compared span in the main window's waterfall | Go to Span, Reveal |
| Show All Differences (N) / Show Fewer Differences | Expand or collapse the comparison's strip | More, See All |
| Show in Finder | Reveal the database file | Reveal, Open Folder |
| Check for Updates… | Ask the update feed for a newer Magnife (Magnife menu; only in builds with Sparkle) | Update Now, Software Update, Check for New Version |
| Open Settings / Open System Settings | Go to Magnife's Settings, or to macOS's for notifications | Preferences, Configure |
| Delete | Confirm deleting data older than a shortened period | OK, Yes, Prune |

## Status lines

| Text | When |
| --- | --- |
| Receiving on 4317 and 4318 | Both ports listening |
| Receiving on 4318 only / Receiving on 4317 only | One port busy |
| Not receiving | Both ports busy |
| Waiting for the first trace… | Empty state after copying the environment variables |
| Starting receiver… | Receiver takes over 0.5 s to start |
| Paused. 12 new traces. Magnife is still receiving. | Bar at the top of a paused list |
| 12 new traces / 12 new logs | Button at the top of a list scrolled away from the newest rows |
| Trace No Longer Stored | Detail column when the open trace was deleted by retention |
| No traces with errors | Recent Errors when there are none |
| No Comparison | Compare Traces with nothing to compare |
| These traces have little in common: 3 of 120 spans match. They may not be the same request. | Banner over a comparison where under 20% of the spans matched |
| No differences over 1 ms and 20%. | The comparison's strip when nothing differs |

## Settings

| Label | Means |
| --- | --- |
| Keep traces and logs for | Retention: 1 hour, 6 hours, 24 hours (default), 3 days, 7 days |
| Database size | The size of the database files, with Show in Finder |
| Show Magnife in the menu bar | Shows the menu bar extra (on) |
| Notify me when a trace has an error | Posts a notification per trace with an error, coalesced per service (on) |
