# Magnife — User stories

Source: [BRIEF.md](BRIEF.md). No reference app, so `Screens:` names the snapshot pages that will show each story:

| Page | Shows |
| --- | --- |
| 01-empty-state | Window before any trace arrives, env vars with language tabs |
| 02-trace-list | Three-column window with live traces |
| 03-trace-detail | Waterfall of the selected trace |
| 04-span-detail | Selected span: attributes, events, resource, exception |
| 05-logs | Logs tab |
| 06-command-k | Cmd+K search palette |
| 07-filter-bar | Filters applied above the trace list |
| 08-menu-bar | Menu bar extra, open |
| 09-settings | Settings window |

## M1 Core loop
Send telemetry, see the trace, read why it failed. Data survives a restart.

### S-001 Receive traces over OTLP/HTTP as soon as the app opens
As the user, I open Magnife and my app's OTLP/HTTP exporter can send to `localhost:4318` with no setup.
Screens: 02-trace-list
Acceptance:
- [self] Within 1 second of launch, the helper accepts `POST /v1/traces` and `/v1/logs` on 4318 and returns 200.
- [unit] Protobuf, JSON and gzip-compressed bodies all decode to the same stored spans.
- [unit] Spans are written to SQLite (WAL) in batches, and the helper writes one line to its stdout pipe after each batch commits; the app reads that pipe.
- [self] If 4318 is already in use, the window shows which port is busy instead of failing silently.
- [self] The helper listens only on 127.0.0.1, and no firewall prompt appears on first launch (research/platform.md, decision 4).
- [self] With another collector already on `*:4317`, Magnife shows the busy-port banner instead of binding alongside it (platform decision 5).
UX:
- Flow: open Magnife -> receiver starts with no prompt -> toolbar shows "Receiving on 4317 and 4318" -> first trace appears in the list
- Surface: inline status in the window toolbar (information that needs no action goes inline); busy port is an inline banner above the trace list, not an alert (a problem shown next to where it matters)
- States: starting shows nothing unless it takes over half a second, then "Starting receiver…"; error banner "Port 4318 is in use by otelcol-contrib. Quit that app, then click Try Again." (process name when it can be found, otherwise "by another app"); done is the status text
- Words: "Receiving on 4317 and 4318", "Try Again"; status tooltip "Magnife accepts OTLP over gRPC on 4317 and HTTP on 4318"
- Access: status and banner are read by VoiceOver with the same words; Try Again is reachable with Tab; the banner pairs an icon with text, not color alone
Status: done

### S-002 Receive traces over OTLP/gRPC
As the user, I point a gRPC exporter at `localhost:4317` and it works.
Screens: 02-trace-list
Depends: S-001
Acceptance:
- [self] An OTLP gRPC export of traces and logs to 4317 succeeds and the spans are stored.
- [self] If 4317 is busy, the window says so; 4318 keeps working.
UX:
- Flow: same as S-001; gRPC needs no extra step
- Surface: the S-001 toolbar status and banner (one place for receiver state)
- States: one port busy -> status "Receiving on 4318 only" plus the S-001 banner naming 4317; both busy -> "Not receiving" plus one banner naming both ports
- Words: "Receiving on 4318 only", "Not receiving", "Ports 4317 and 4318 are in use by other apps. Quit them, then click Try Again."
- Access: as S-001
Status: done

### S-003 Copy the environment variables for my language
As the user, I pick my language in the empty window and copy the env vars that point my app at Magnife.
Screens: 01-empty-state
Acceptance:
- [snap] Before any trace arrives, the center of the window shows tabs for .NET, Go, Node, Python and Java with that language's variables.
- [self] Copy puts exactly the shown text on the pasteboard.
- [snap] The empty state goes away once the first trace arrives.
UX:
- Flow: open Magnife with no traces -> pick a language tab (last choice remembered, .NET first time) -> click Copy Environment Variables or press ⌘⇧C -> button reads "Copied" for 2 seconds -> paste into a shell or launch config -> first trace replaces the empty state
- Surface: empty state in the trace list column (the list is the place people come back to; this is its empty state)
- States: empty is the whole story; after copying, "Waiting for the first trace…" under the button; the variables never truncate (horizontal scroll in the code block)
- Words: title "No Traces Yet", body "Set these environment variables in your app, run it, and its traces appear here.", tabs ".NET", "Go", "Node", "Python", "Java", button "Copy Environment Variables", feedback "Copied"
- Access: tabs are a segmented control reachable by keyboard; Return on the focused button copies; VoiceOver reads the variables as text and announces "Copied"
Status: done

### S-004 See a new trace appear in the live list
As the user, I run my app and its traces show up at the top of the list.
Screens: 02-trace-list
Depends: S-001
Acceptance:
- [snap] Each row shows service, route, duration, status and span count; newest first.
- [self] A trace appears within 1 second of its spans arriving.
- [snap] Failed traces read as failed at a glance (status mark, not color alone).
- [snap] Each service has one stable color, the same in the sidebar, list and waterfall (research/design.md, decision 4).
- [self] When you scroll away from the top, the list holds still while traces arrive (design decision 6).
UX:
- Flow: spans arrive -> trace row is inserted at the top -> selection and scroll position stay put if you scrolled down -> click a row to open it (S-005)
- Surface: center column list (a place people come back to); a table with columns Service, Route, Duration, Spans, Status, Time
- States: empty is S-003; too much: Route truncates in the middle with the full route in a tooltip, 100,000 rows scroll smoothly (S-030); a trace still receiving spans updates its row in place without moving it
- Words: column headers "Service", "Route", "Duration", "Spans", "Status", "Time"; statuses "Error" with an octagon icon, "OK" with no icon, "Unset" shown blank; durations "12 ms", "1.24 s"; time relative under an hour ("2 min ago"), then clock time
- Access: VoiceOver reads a row as "checkout-api, POST /orders, 240 milliseconds, 18 spans, Error"; the Error status pairs icon and word, not red alone
Status: done

### S-005 Open a trace's waterfall
As the user, I select a trace and see its spans as a waterfall in the detail column.
Screens: 03-trace-detail
Depends: S-004
Acceptance:
- [snap] Spans nest by parent, bars are placed and sized by start time and duration, failed spans are marked.
- [unit] Spans that arrive after the trace was opened join the waterfall in the right place.
- [unit] A span whose parent never arrives shows at the root rather than disappearing.
- [self] Traces over 500 spans open with deep subtrees collapsed; a 30,000-span trace opens without a hang (design decision 7).
UX:
- Flow: click a trace row -> waterfall fills the detail column, root span selected -> click a disclosure triangle to collapse a subtree -> select another row to switch; nothing to cancel
- Surface: detail column (shows details of the selection while people keep working)
- States: no selection "No Trace Selected. Select a trace to see its waterfall."; too much: span names truncate with a tooltip, collapsed subtrees show their span count, a 1,000-span trace scrolls smoothly; missing parent: span sits at the root with "Parent span not received" as its tooltip
- Words: header shows route, then service, duration and span count ("POST /orders · checkout-api · 240 ms · 18 spans"); each row shows span name and its service when it differs from the parent's
- Access: each bar is a row VoiceOver reads as "span name, service, starts at 12 ms, lasts 80 ms, Error"; Error spans carry the octagon icon as well as color
Status: done

### S-006 Inspect a span's attributes, events and resource
As the user, I click a span and read its attributes, events and the resource it came from.
Screens: 04-span-detail
Depends: S-005
Acceptance:
- [snap] Attributes and resource attributes are listed as key and value; events are listed in time order with their attributes.
- [self] Long values wrap or truncate with the full value available; nothing is cut silently.
- [snap] `http.*` and `db.*` attributes are listed first (design decision 5).
UX:
- Flow: click a span in the waterfall -> span detail fills the lower pane of the detail column -> select a value and press ⌘C to copy it -> click another span to switch
- Surface: lower pane of the detail column, split under the waterfall (inspector for the selected span while the waterfall stays visible)
- States: no span selected "Select a span to see its attributes."; a section with nothing in it is hidden, not shown empty; too much: values longer than three lines collapse with "Show All", keys truncate with a tooltip
- Words: section headers "Attributes", "Events", "Resource"; span header shows name, kind, duration and status; "Show All", "Show Less"
- Access: keys and values are selectable text; VoiceOver reads each pair as "key, value"; sections are headings so VoiceOver can jump between them
Status: done

### S-007 Read an exception with its stack trace
As the user, I click a failed span and read the exception type, message and stack trace.
Screens: 04-span-detail
Depends: S-006
Acceptance:
- [snap] `exception.type`, `exception.message` and `exception.stacktrace` from span events show as one exception block, stack trace in monospace.
- [unit] A span with several exception events shows each one.
UX:
- Flow: click an Error span -> Exception section opens first in the span detail -> read type and message -> scroll the stack trace -> click Copy Stack Trace
- Surface: a section at the top of the S-006 span detail (part of the same inspector, so nothing new opens)
- States: no exception means no section; several exceptions stack in time order; too much: stack traces over 20 lines show the first 20 with "Show All"; a missing stack trace shows type and message only
- Words: header "Exception"; type in bold, message under it; button "Copy Stack Trace"; feedback "Copied"
- Access: stack trace is selectable monospace text; Copy Stack Trace has a visible label; VoiceOver reads type, then message, then "stack trace, 42 lines"
Status: done

### S-008 Keep my traces after quitting
As the user, I quit and reopen Magnife and my traces are still there.
Screens: 02-trace-list
Depends: S-004
Acceptance:
- [self] After quit and relaunch, the list shows the same traces in the same order.
- [self] Quitting the app stops the helper; no Magnife process keeps running or holds the ports.
- [self] If the helper crashes, the app restarts it and says so, with backoff from 0.5 s to 30 s.
- [self] After `kill -9` of the app, the helper exits within 1 second because its stdin closes (platform decision 2).
- [self] On Quit, the app waits for the helper to exit, so a relaunch can bind the ports right away (platform decision 6).
UX:
- Flow: closing the window keeps Magnife running and receiving (it stays in the Dock); Quit Magnife (⌘Q) stops the receiver -> next launch shows stored traces right away, no loading screen
- Surface: no new surface; a receiver crash uses the S-001 banner
- States: loading shows cached rows from the database at once, so no spinner; error banner "The receiver stopped and was restarted. Spans sent in the last few seconds may be missing." with a close button; it closes itself after the next trace arrives
- Words: "Quit Magnife", the banner text above
- Access: banner is announced by VoiceOver once; its close button reads "Close"
Status: done

## M2 Navigate and logs

### S-009 Filter traces by service from the sidebar
As the user, I click a service in the sidebar to see only its traces.
Screens: 02-trace-list
Depends: S-004
Acceptance:
- [snap] The sidebar lists each detected service with its error count.
- [self] A new service appears in the sidebar when its first span arrives.
Status: done

### S-010 Pause the live list while I investigate
As the user, I pause the list so new traces stop pushing my selection away.
Screens: 02-trace-list
Depends: S-004
Acceptance:
- [self] While paused, the list does not change; ingestion keeps going.
- [snap] The paused state is visible, with how many traces arrived meanwhile.
- [self] Resume inserts them and keeps the selected trace selected.
Status: done

### S-011 See the logs for the selected span
As the user, I select a span and see the logs written during it.
Screens: 04-span-detail
Depends: S-006
Acceptance:
- [unit] Logs whose trace id and span id match the span are shown, in time order.
- [snap] Each log line shows time, level and body; attributes on demand.
Status: todo

### S-012 See all logs for a trace
As the user, I see every log for the selected trace in one place.
Screens: 03-trace-detail
Depends: S-011
Acceptance:
- [unit] Logs matching the trace id are shown even when the span id is missing.
- [self] Selecting a log line selects its span in the waterfall.
Status: todo

### S-013 Browse all logs in the Logs tab
As the user, I switch to the Logs tab and see every log, newest first, live.
Screens: 05-logs
Depends: S-001
Acceptance:
- [snap] Rows show time, level, service and body.
- [self] Opening a log that has a trace id opens that trace with the span selected.
- [self] Logs without a trace id still show.
Status: todo

### S-014 Filter the Logs tab by level and service
As the user, I narrow the Logs tab to one level and service.
Screens: 05-logs
Depends: S-013
Acceptance:
- [unit] Level filter matches OTel severity ranges (e.g. Error includes ERROR2–ERROR4).
- [snap] Active filters are visible and can be cleared in one action.
Status: todo

## M3 Retention

### S-015 Prune old data automatically
As the user, I never have to clean up; old traces and logs go away on their own.
Depends: S-008
Acceptance:
- [unit] Data older than the retention period is deleted, traces, spans and logs together.
- [self] Pruning runs without blocking ingestion or the interface.
- [unit] A default retention applies on first launch (24 hours, decided by the agent).
Status: todo

### S-016 Change the retention period
As the user, I set how long Magnife keeps data in Settings.
Screens: 09-settings
Depends: S-015
Acceptance:
- [snap] Settings shows the retention choice and the current database size.
- [self] Shortening retention prunes right away; the list updates.
Status: todo

## M4 Speed

### S-017 Search traces with Cmd+K
As the user, I press Cmd+K, type, and jump to a matching trace.
Screens: 06-command-k
Depends: S-004
Acceptance:
- [self] Cmd+K opens the palette from anywhere in the window; Esc closes it.
- [unit] Text matches service, route, trace id and attribute values.
- [unit] Typed tokens `service:`, `status:`, `route:` and `>200ms` parse into the same filters as the filter bar (design decision 2).
- [self] Results appear while typing, within 100 ms on 100,000 spans.
Status: todo

### S-018 Filter traces by status
As the user, I show only failed traces.
Screens: 07-filter-bar
Depends: S-004
Acceptance:
- [snap] The status filter shows in the filter bar above the list.
- [unit] Error, OK and Unset match the trace's root and child span statuses as documented.
Status: todo

### S-019 Filter traces by minimum duration
As the user, I show only traces slower than a duration I type.
Screens: 07-filter-bar
Depends: S-018
Acceptance:
- [unit] `>200ms`, `>1.5s` and plain numbers in ms parse to the same rule.
- [self] The list updates as the value changes.
Status: todo

### S-020 Filter traces by any attribute
As the user, I filter by an attribute key and value, such as `http.route = /orders`.
Screens: 07-filter-bar
Depends: S-018
Acceptance:
- [unit] Matches span attributes and resource attributes; a trace matches if any span does.
- [self] Keys autocomplete from attributes already received.
Status: todo

### S-021 Save the current filters to the sidebar
As the user, I save a set of filters with a name and reopen it from the sidebar.
Screens: 02-trace-list, 07-filter-bar
Depends: S-020
Acceptance:
- [snap] Saved filters appear in the sidebar under the services.
- [self] Saved filters survive a restart; renaming and deleting work.
Status: todo

### S-022 Move through traces and spans with the keyboard
As the user, I use arrow keys, Return and Esc to move between the list, waterfall and span detail.
Screens: 02-trace-list, 03-trace-detail
Depends: S-006
Acceptance:
- [self] Up and Down move the selection in the list and in the waterfall; Left and Right collapse and expand spans; Return opens the span detail and Space toggles it (design decision 3).
- [self] ⌘F opens the filter bar and Esc closes it (design decision 1).
- [self] Every action in the app has a menu item, and frequent ones have a shortcut shown there.
Status: todo

## M5 Detect and alert

### S-023 See slow SQL queries flagged
As the user, I see which database spans were slow without reading every span.
Screens: 02-trace-list, 03-trace-detail
Depends: S-005
Acceptance:
- [unit] A span with `db.system` and a duration over 100 ms (decided by the agent) gets a Slow SQL finding.
- [snap] The trace row shows a finding badge; the span is marked in the waterfall; the span detail says why.
Status: todo

### S-024 See N+1 queries flagged
As the user, I see when one trace runs the same SQL statement over and over.
Screens: 03-trace-detail
Depends: S-023
Acceptance:
- [unit] The same normalized `db.statement` (literals removed) 5 or more times in one trace (decided by the agent) gives one N+1 finding listing all those spans.
- [snap] The finding names the statement and the count.
Status: todo

### S-025 See failed HTTP calls flagged
As the user, I see which HTTP calls in a trace failed.
Screens: 03-trace-detail
Depends: S-023
Acceptance:
- [unit] An HTTP span with a response status of 400 or higher, or span status Error, gets an HTTP error finding.
- [snap] The finding shows method, URL or route, and status code.
Status: todo

### S-026 See recent errors in the menu bar
As the user, I glance at the menu bar and know whether something failed.
Screens: 08-menu-bar
Depends: S-004
Acceptance:
- [snap] The icon turns red and shows a count of failed traces since the menu was last opened (decided by the agent).
- [snap] The menu lists the last five failed traces with service, route and time.
Status: todo

### S-027 Open a failed trace from the menu bar
As the user, I click a failed trace in the menu and land on its detail.
Screens: 08-menu-bar, 03-trace-detail
Depends: S-026
Acceptance:
- [self] Clicking brings the window forward with the trace selected and its first failed span open.
Status: todo

### S-028 Get notified when a trace fails
As the user, I get a native notification when a trace with an error arrives, and clicking it opens the trace.
Depends: S-027
Acceptance:
- [manual] The first failure asks for notification permission; denying it changes nothing else.
- [unit] A burst of failures within 10 seconds produces one notification naming the count (decided by the agent).
- [manual] Clicking the notification opens the trace like S-027, including when the click launched the app.
- [self] Notifications show even while Magnife is frontmost, and group by service (platform decision 9).
Status: todo

## M6 Polish

### S-029 Open in under a second
As the user, I open Magnife and can use it right away.
Acceptance:
- [self] From launch to a window showing stored traces takes under 1 second with a 100,000-span database.
Status: todo

### S-030 Stay responsive under heavy load
As the user, I can scroll and select while my app floods Magnife with spans.
Screens: 02-trace-list
Depends: S-004
Acceptance:
- [self] At 5,000 spans per second for 60 seconds, no main-thread hang exceeds 100 ms.
- [self] The list pages from the database instead of loading every trace.
Status: todo

### S-031 Use Magnife in dark mode
As the user, Magnife follows my Mac's appearance.
Screens: 01-empty-state … 09-settings
Acceptance:
- [snap] Every page has a dark snapshot with readable contrast for statuses, findings and waterfall bars.
Status: todo

### S-032 Recognize Magnife by its icon
As the user, I find Magnife in the Dock and Launchpad by its icon.
Acceptance:
- [manual] The app icon follows the macOS icon grid and reads at 16 pt in Finder and the Dock.
Status: todo

## Seed data
Snapshots use a fixture of OTLP payloads replayed into the helper, so every value comes from telemetry the app receives:
- Services: `checkout-api` (.NET), `orders` (Go), `web` (Node).
- Traces: one healthy request, one with an exception and stack trace, one with a slow SQL span, one with an N+1 (8 identical statements), one with an HTTP 500 call.
- Logs at Debug, Info, Warn and Error, most linked to spans, a few with no trace id.
- One saved filter, "Checkout errors", created through S-021.

## Dropped
- Accounts and sign-in: one user, local data.
- Free and Pro plan limits, license entry and upgrade prompts: business model, not v0.1 scope; licensing comes back as its own work before public launch.
- Team plan and trace sharing: other people.
- In-app usage telemetry: vendor-only; if added later, opt-in and anonymous as the spec says.

## Later
- v0.2: metrics with charts; side-by-side comparison of two traces.
- v0.2: export and import traces as files.
- v0.3: AI agent view (calls, tools, tokens, cost).
- v0.3: MCP server for agents to query local traces.
- v0.4: forwarding to a remote backend (OTLP proxy).
- Release work, not stories: Developer ID signing and notarization, Homebrew cask, Sparkle updates.
