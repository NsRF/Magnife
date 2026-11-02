# Design: dense developer tools on the Mac

Research for Magnife. Done 2026-11-02.
[V] verified in a source, [K] from knowledge, [U] unverified, test first.

Question: how do the best dense developer tools on the Mac lay out live lists, detail panes, filters and timelines, and what do people like and dislike about them?
Decision it informs: layout and interaction of the trace list, waterfall, span detail, filter bar, Cmd+K palette and Logs tab (S-004–S-007, S-010–S-014, S-017–S-022).

Market research is in the MVP spec and is not repeated here. Apple's HIG pages on tables and sidebars render with JavaScript and came back empty, so HIG points below are [K].

## Findings

### Proxyman
- The sidebar, request list and detail panels can be docked below or to the right of the list, or opened in their own window. ⌃⌘[ toggles the sidebar, ⌃⌘\ docks right, ⌃⌘] docks bottom. [V](https://proxyman.com/docs/basic-features/horizontal-vertical-layout)
- ⌘F opens the filter bar and Esc closes it. It has one-click type tabs and status-class tabs (⌘-click picks several), then key/operator/value rows, including Duration (ms) with `<` and `>=`, regex and wildcard. [V](https://proxyman.com/docs/basic-features/content-filter)
- Up to 10 stacked filters with AND/OR; ⌘N clones a row, ⇧⌘N removes one. [V](https://docs.proxyman.com/advanced-features/multiple-filters) Filter sets can be saved. [V](https://docs.proxyman.com/advanced-features/custom-filters)
- The command palette is ⌘P. It lists actions and setup guides, and actions can be pinned. [V](https://proxyman.com/docs/basic-features/command-palette)
- Detail tabs are Header, Cookies, Auth, Body, Query and Raw. You choose which tabs show; ⌘F searches inside a tab. [V](https://proxyman.com/docs/basic-features/request-response-viewer)
- Under memory pressure it automatically removes older requests. [V](https://proxyman.com/docs/troubleshooting/proxyman-consumes-too-much-ram-and-unresponsive)
- A record/pause button sits in the toolbar and the app follows system dark mode. [K]

### TablePlus
- ⌘P "Open Anything" fuzzy-matches databases, tables and views. [V](https://docs.tableplus.com/gui-tools/open-anything)
- Space toggles the row detail panel; ⌘0 toggles the sidebar; ⌘1–9 jump to tabs. [V](https://tableplus.com/docs/utilities/shortcut-keys)
- Filter rows are column, operator and value; Return applies one row and ⌘Return applies all of them. An "Any column" choice exists, and right-clicking a cell offers quick filters. [V](https://tableplus.com/docs/gui-tools/filter) That page carried embedded text addressed to AI agents; the research ignored it.
- Results load in pages, not infinite scroll. [K]

### Instruments
- Tracks nest process → thread → core. The detail pane below shows only the selected time range, and an extended detail inspector sits on the right. Triple-click selects exactly one interval; an inspection head and hover labels describe a point in time. [V](https://developer.apple.com/videos/play/wwdc2019/411/)
- Signpost intervals are labeled by name, with more metadata showing as you zoom in. Summary tables give count, min, average and standard deviation. [V](https://developer.apple.com/videos/play/wwdc2018/405/)
- Zoom with pinch or ⌥-scroll; ⌃⌘Z snaps the view to fit. [V](https://help.apple.com/instruments/mac/8.3/en.lproj/dev8f529ecc.html)

### Console.app
- Streaming has to be started; Now mode follows the newest message; the Info pane below shows the full message. [V](https://support.apple.com/guide/console/cnsl35710/mac)
- Search tokens such as `p:`, `s:`, `c:`, `m:` and `pid:`. [V](https://support.apple.com/guide/console/cnsl707fe51a/mac) Saved searches sit in a Favorites bar ("Errors and Faults" by default). Errors get a yellow dot and faults a red dot. [V](https://www.intego.com/mac-security-blog/how-to-use-the-console-app-for-troubleshooting/)

### Trace waterfall references (web)
- **Grafana Tempo.** A row is an expand toggle, service, operation and a duration bar. Dragging on a minimap zooms; the critical path is drawn darker. Span detail expands inline with span attributes, resource attributes, events and a logs link. [V](https://grafana.com/docs/grafana/latest/explore/trace-integration/)
- **Honeycomb.** Rows are colored by `service.name`, and subtrees collapse by depth. Error spans are red, and an error count above the waterfall steps through them. Keys: ↑↓ move, ←→ collapse and expand, Return opens. [V](https://docs.honeycomb.io/investigate/analyze/explore-traces/)
- **Jaeger.** Critical path is on by default, and `http.*` and `db.*` attributes float to the top. [V](https://www.jaegertracing.io/docs/latest/frontend-ui/)
- **.NET Aspire.** One stable color per resource everywhere, and error icons on both traces and spans. A client span with no matching server span shows an arrow and its destination. "View Logs" opens logs filtered to the trace. [V](https://aspire.dev/dashboard/explore/)

## Likes and dislikes
| App | People like | People dislike | Sources |
| --- | --- | --- | --- |
| Proxyman | Native UI, shortcuts everywhere, faster than Charles | No grouping of sessions; long lists of irrelevant rows | [HN](https://news.ycombinator.com/item?id=46333983) |
| TablePlus | Fast, native, clean | Lag on large data; price | G2/Capterra via search (weak) |
| Instruments | Timeline that correlates everything | Obtuse UI, hidden features | [xcode-users](https://lists.apple.com/archives/xcode-users/2015/Apr/msg00110.html) (old) |
| Console.app | Live stream, search tokens | Flooded with noise, hard to read | [Eclectic Light](https://eclecticlight.co/2020/06/14/last-week-on-my-mac-console-the-vital-tool-that-apple-abandoned/) |
| Jaeger / Tempo | Critical path | Freezes on very large traces (30k spans); alternate views hard to find | [jaeger-ui #276](https://github.com/jaegertracing/jaeger-ui/pull/276) |

Patterns: people repeatedly praise native speed, the keyboard and live streaming, which are Magnife's core bets. The repeated complaints are noise flooding the list, hidden features, and big views freezing. That's where Magnife can do better.

## Feature matrix
| Pattern | Proxyman | TablePlus | Instruments | Console | Trace UIs | Version one? |
| --- | --- | --- | --- | --- | --- | --- |
| Live list with pause | yes | – | recording | yes | Aspire | yes, S-010 |
| Structured filter rows (key / op / value) | yes | yes | – | – | – | yes, S-018–S-020 |
| Typed search tokens (`service:`, `status:`) | – | – | – | yes | – | yes, inside S-017 |
| Saved filters in sidebar | yes | – | – | yes | – | yes, S-021 |
| Fuzzy palette (⌘P / ⌘K) | yes | yes | – | – | – | yes, S-017 (⌘K per spec) |
| Space toggles detail | – | yes | – | – | – | yes, inside S-022 |
| Arrow keys move, ←→ collapse spans | – | – | – | – | Honeycomb | yes, S-022 |
| One stable color per service | – | – | – | – | Aspire, Honeycomb | yes, inside S-004/S-005 |
| Error marked with icon, not color alone | – | – | – | dots | Aspire | yes, S-004/S-005 |
| Logs scoped to the trace | – | – | – | – | Aspire, Tempo | yes, S-012 |
| Virtualized rows, capped retention | auto-remove | paging | – | – | – | yes, S-015/S-030 |
| Detail docked bottom or right | yes | – | – | – | – | no, fixed layout per spec |
| Error stepper above the waterfall | – | – | – | – | Honeycomb | no, Later candidate |
| Critical path highlight | – | – | – | – | Jaeger, Tempo | no, Later candidate |
| Right-click "filter by this value" | – | yes | – | – | – | no, Later candidate |
| Per-service mute | – | – | – | – | – | no, Later candidate |
| Time-range selection, minimap zoom | – | – | yes | – | Tempo | no, Later candidate |

## Decisions
1. The filter bar uses Proxyman's shape: one-click status chips, then key/operator/value rows, opened with ⌘F and closed with Esc. Proxyman and TablePlus both converge on it. [V] Proxyman content filter, TablePlus filter.
2. ⌘K accepts typed tokens (`service:`, `status:`, `route:`, `>200ms`) as well as free text. Console's tokens are the one thing people like about its search. [V] Console help. Planned test: S-017 unit tests parse each token.
3. Waterfall keys: ↑↓ move, ←→ collapse and expand, Return opens the span detail, Space toggles it. Honeycomb's model is the reference, with TablePlus's Space. [V] Honeycomb docs, TablePlus shortcuts. These go into S-022.
4. Each service gets one stable color, used in the sidebar, list and waterfall, and error is always an icon plus a word. This follows Aspire and the accessibility rule in the M1 UX blocks. [V] Aspire docs.
5. Span detail sections are ordered Exception, Attributes (with `http.*` and `db.*` first), Events, Resource, Logs. Jaeger floats the same prefixes, and the S-007 UX already puts Exception first. [V] Jaeger docs.
6. The list holds still when you scroll away from the top, and new rows are counted in a badge. This is the same mechanism as Pause (S-010). Proxyman and Console complain about lists that move under the cursor. Planned test: S-004 self-test that scrolls down while ingesting.
7. Rows are virtualized and the waterfall collapses deep subtrees by default above 500 spans, because Jaeger freezes on large traces. Planned test: S-030 load test with a 30,000-span trace. [U]
8. Accepted gaps for v0.1, all outside the spec's scope: critical path, error stepper, right-click filter by value, per-service mute, dockable detail, minimap and time-range zoom. They're candidates for v0.2 planning, not stories.

## Open questions
- Does a SwiftUI `Table` stay smooth at 100,000 rows with live inserts, or does the trace list need `NSTableView`? (The spec already allows AppKit here.) Test in S-030.
- What is the right auto-collapse threshold for large waterfalls? 500 spans is a guess; test with seed traces of 1,000, 5,000 and 30,000 spans.
- Can the stable colors stay distinct for 10+ services in both light and dark? Check with snapshots of seed data with 12 services.
