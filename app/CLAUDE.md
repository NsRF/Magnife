# Magnife

A native macOS app in SwiftUI that shows local OpenTelemetry traces and logs.
A Go helper (`../ingest`, `magnife-ingest`) receives OTLP and writes SQLite;
this app starts the helper and reads its database. No server, no accounts.

## How data flows

- The contract is `../docs/schema.sql`: tables, JSON columns, and the helper's
  stdout/stdin protocol. Never change it from here; a change updates both sides
  and bumps `PRAGMA user_version`.
- The app is a **read-only** consumer: GRDB `DatabasePool` with
  `readonly = true`, in `MagnifeKit/Store/TelemetryReader.swift`. It never
  writes, migrates, or checkpoints. All SQL lives in `TelemetrySQL.swift`.
  Every read runs off the main actor (`@concurrent` methods on GRDB's queues).
- A read-only connection cannot open a WAL database whose `-wal` file is
  missing (`SQLITE_CANTOPEN`), which is the state after a stock SQLite writer
  closes cleanly. The helper therefore keeps its `-wal` and `-shm` after it
  exits (persistent WAL, S-008), so a relaunch reads the stored traces at
  once, before the helper is up. A file without them (an older helper) reads
  as `StoreError.notReady`, and `AppModel` retries on the helper's next event
  and every 2 seconds; the list stays blank meanwhile (`knowsStoredTraces`),
  never "No Traces Yet". `storeState` turns `.ready` after the first read.
  `Tests/MagnifeKitTests/WALReadonlyTests.swift` and `LifecycleTests.swift` pin this.
- `Tests/MagnifeKitTests/ContractTests.swift` builds a database from
  `../docs/schema.sql` with the Go helper's own INSERTs and JSON encoding and
  checks every reader method; `HelperProtocolTests` decodes the protocol's
  example lines straight from that file. Change them with the contract.
- `HelperSupervisor` (MagnifeKit, Foundation only) runs
  `Contents/Helpers/magnife-ingest`, keeps its stdin open (EOF stops it),
  turns stdout lines into `SupervisorEvent`s, passes stderr through, and
  restarts it after a crash (0.5 s doubling to 30 s, reset after 60 s up);
  the S-008 banner (`ReceiverStatus.restartedBanner`) shows until the next
  trace. Quit waits for the helper in `applicationWillTerminate`.
- `AppModel` refreshes on `batch` events: at most one read in flight, 150 ms
  after the first batch. The trace list (`AppModel+TraceList.swift`) reads
  200-row pages, and `TraceListState.applying` (MagnifeKit, unit-tested) decides
  what each read may change: a read for another scope or older than the rows
  shown is dropped; scrolled away from the top it holds still (rows update in
  place, new traces are counted for the "N new traces" button) through
  `TraceListScroller`, which watches the table's NSScrollView. A sidebar scope change empties the list before the
  new read: diffing one scope's rows into another's trips AppKit's
  "reentrant operation in its NSTableView delegate" warning.
- The sidebar (S-009): services come with every list read
  (`servicesWithErrors`, counts derived from spans); a service scope is
  `TelemetrySQL.serviceScope`, an IN subquery on the covering index
  `spans_by_service_status` that every scoped query shares
  (`ServiceScopeTests` pins the plans). The subtitle is the scope's count
  (`TracePage.traceCount`).
- Pause (S-010, `AppModel+Pause.swift`): `pausedSeq` is the seq the shown
  rows were read at; while it is set, `TraceListState.applying` changes no
  row (not even in place), only the count of traces with `first_seq` after
  it; a scope change reads up to it (`tracePage(upTo:)`); the open waterfall
  is not re-read. Resume reads enough rows to keep the selection and scrolls
  it into view. Later lists (Logs, menu bar extra) read `isPaused`.
- The waterfall (S-005): `TelemetryReader.waterfallSpans` reads only the
  columns it draws; `Waterfall` (MagnifeKit) builds the tree off the main
  actor, without recursion; `AppModel+Waterfall.swift` re-reads the open trace
  only when its `updated_seq` changes and keeps `collapsedSpans` and
  `selectedSpanID` across rebuilds (spans that become parents collapse as
  `Waterfall.autoCollapsed(after:)` says). The rows are an NSOutlineView
  (`WaterfallOutline.swift`, cells in `WaterfallCells.swift`) with one
  `SpanItem` per span id across rebuilds; it scrolls only when the selected
  span changes, and the Span column keeps 55% of the width. Never pass a
  row of -1 to its view calls: `view(atColumn:row:makeIfNecessary:)` hangs.
- The span detail (S-006): `TelemetryReader.spanDetail` reads the selected
  span and its resource in one read; `SpanDetail` (MagnifeKit) orders the
  sections and attributes. The detail column is `DetailSplit` (an
  NSSplitView with one NSHostingView per pane, so each pane gets
  `.environment(model).themed()` again); it keeps its divider fraction on
  every resize. "Show All" is measured (`ExpandableText`), and expanded
  values live in `AppModel.expandedValues`.
- Span logs (S-011): `spanDetail` also reads the span's logs; `LogLine`
  (MagnifeKit) has the time "14:02:31.204", the level word and the body
  (`LogBody.pretty` re-indents JSON without re-encoding it). Logs do not
  change `traces.updated_seq`, so each refresh that is not paused reads
  `TelemetryReader.logStamp` and re-reads the span when it changed
  (`AppModel.refreshOpenTraceLogs`). Views in `SpanDetailLogs.swift`.
- Trace Logs (S-012): the span detail has a Span | Trace Logs picker
  (`SpanDetailTab`, View ⌥⌘1 / ⌥⌘2, remembered). `TelemetryReader.traceLogs`
  reads every log of the open trace (span id or not) into `TraceLogs`;
  `AppModel+TraceLogs.swift` loads it when a trace opens and when the log
  stamp changes. Selecting a row (`selectTraceLog`) opens the span's
  collapsed ancestors (`Waterfall.ancestors(of:)`) and selects it; the
  Span column is `TraceLogSpan` ("—", the name, "Span not received").
  The table is a SwiftUI `Table` in `TraceLogsView.swift`; its column
  ideals must fit the 560 pt detail column.
- The Logs view (S-013): `AppModel.contentMode` (Traces | Logs, ⌘1 / ⌘2,
  `ContentColumn` / `DetailColumn` in `ContentView.swift`) swaps the content
  and detail columns. `AppModel+Logs.swift` reads 200-row pages
  (`TelemetryReader.logPage`, newest first by time) only while Logs shows;
  `LogListState.applying` (MagnifeKit, unit-tested) holds the list still
  when scrolled away (its own `TraceListScroller`, `logScroller`) or paused,
  counting logs whose id is above the shown rows' newest id. Open Trace
  (`openTrace(ofLog:)`) switches to Traces and selects the log's span
  through `pendingSpan` once the waterfall is built. Views in
  `LogListView.swift` and `LogDetailView.swift`. A Table cell's root view
  never reads `@Environment` (FIXLOG): pass it values and actions.
- The Logs filter bar (S-014, `LogFilterBar.swift`): `LogFilter` (MagnifeKit)
  holds the service (the sidebar's), the level chips (merged OTel ranges,
  `severityRanges`) and "Body contains"; `TelemetrySQL.logFilterConditions`
  and `TelemetryReader.arguments(for:)` must stay in the same order. Any
  change empties the list and reads it again (`logFilterChanged`); Clear
  Filters is undoable. `APP_SELFTEST_ONLY=logs` runs S-013 and S-014 checks.
- Retention (S-015): `Retention` (MagnifeKit) is the choice (24 hours by
  default, `retention.seconds` in UserDefaults, `APP_RETENTION_SECONDS` in
  test runs); `AppModel.retentionSeconds` passes it as `--retention` and
  sends `retention <s>` on change. The helper prunes every 60 s (or every
  retention period when shorter) and sends `pruned`; the app refreshes.
  Held lists drop pruned rows (`HeldTraces.removed`, `HeldLogs.removed`),
  paused ones keep them; a selected trace that is gone (`reader.trace` nil)
  shows `TraceNoLongerStored` (`AppModel.traceNoLongerStored`,
  `prunedTraceID`). Settings > General's pop-up (S-016, `RetentionSettings`)
  calls `requestRetention`: longer applies at once, shorter waits for the
  "Delete Data Older Than …?" alert (`pendingRetention`); "Database size" is
  `DatabaseSize.bytes` (database plus WAL), `AppModel.databaseSize`.
  `APP_SELFTEST_ONLY=retention` runs the end-to-end checks with the real
  helper (S-015 at a 3 s retention, then S-016's change flow).
- Filters and Search (S-017+): one query language, `TraceQuery` (MagnifeKit,
  parse and format, round trip unit-tested) <-> `TraceFilter` (service,
  statuses, slower than, `TraceCondition` rows); `TraceFilterSQL` turns a
  filter into WHERE conditions with bound arguments only (`.set` scans spans
  once, `.perTrace` reads each candidate's spans for "new since" counts).
  `TraceListState.scope` is the whole `TraceFilter`; `AppModel.traceFilter`
  joins the sidebar's service with `traceStatuses`, `traceSlowerThanNs`,
  `traceConditions` (`AppModel+TraceFilter.swift`; any change resets the
  list like a scope change). Search (`AppModel+Search.swift`,
  `SearchPanel.swift`, AppKit field `SearchField.swift`) is an overlay on
  the window: `TelemetryReader.searchTraces` walks the newest 2,000 traces
  first, else reads the store in one pass; `searchCount` fills a missing
  total; each keystroke cancels the read before it. `APP_SELFTEST_ONLY=search`
  runs its checks, timed on `APP_SEARCH_STORE` (100,000 spans, selftest.sh),
  and the Traces filter bar's (`TraceFilterBar.swift`, S-018: Service pop-up,
  status chips, "Slower than" (S-019: `traceSlowerThanText` applies 100 ms
  after the last key through `DurationInput`), Clear Filters, and the
  condition rows (S-020: `conditionRows` of `ConditionDraft` become
  `traceConditions` 100 ms after the last change; keys complete from
  `attribute_keys` via `ConditionKeySuggestion`; AppKit key field in
  `TraceConditionRows.swift`);
  `showsTraceFilterBar`, `toggleFilterBar` acts on the current view). Esc on a focused Table needs `.onKeyPress(.escape)`.
- App-owned settings (retention, Settings tab, accent) live in UserDefaults,
  never in the database.

## Layout

- `Sources/Magnife/` the app. `App.swift` has the scene, menus, launch modes;
  `AppModel.swift` the state; `ContentView.swift` the three columns.
- `Sources/MagnifeKit/` records, the reader, the helper protocol and
  supervisor, formatting (durations, relative time, service color slots). No
  SwiftUI. Tests in `Tests/MagnifeKitTests/` (Swift Testing).
- `Package.swift` a Swift package (Swift 6.4 tools, macOS 26), GRDB 7.
  There is no Xcode project.
- `build.sh` builds, runs `../ingest/build.sh` when it exists, copies the
  helper into `Contents/Helpers/`, signs inside out (helper, then app; never
  `--deep`), and installs `~/Applications/Magnife.app`.
- `Icon/AppIcon.icon` the app icon, an Icon Composer file (JSON plus SVG layers). `build.sh` compiles it with `tools/make_icon.sh`; `tools/icon_review.sh` renders every look into one PNG.
- `tools/seed.zsh` seeds test databases through the real pipeline
  (docs/STORIES.md, "Seed data"): it starts the bundled helper standalone
  (`--no-stdin`, ports 0) on a fresh /tmp database, runs
  `scripts/send-sample-traces` against it (3 services, 5 traces: healthy,
  N+1, slow SQL, HTTP 500 with an exception, an exception; 20 logs, 8 with
  no trace id), waits until the batch lines add up, and keeps the helper
  running while the app reads (the read-only reader needs the `-wal` file),
  then stops it. `snap.sh` and `selftest.sh` source it. The app never writes,
  so every value on screen comes from telemetry the helper received.
- `../docs/` the brief, glossary, stories, research, and progress log.

## Launch modes

- `APP_STORE=<file>` reads another database. Snapshots and the self-test
  refuse to run unless it is in /tmp.
- `APP_HELPER=none` starts no helper (tests, snapshots, self-test);
  `APP_HELPER=<path>` starts another executable.
- `APP_GRPC_PORT`, `APP_HTTP_PORT` override 4317 and 4318.
- `APP_RETENTION_SECONDS=<s>` keeps data that many seconds (test runs only).

## Build and check

- Build and install: `./build.sh`. Add `--open` to restart the app with the new build. The build shows warnings; fix them.
  `--open` runs the real helper against the real database; use the scripts below for tests.
- Unit tests: `swift test --scratch-path ~/Library/Developer/Magnife/test-build`.
- Self-test (the app's real functions on the seeded store, the supervisor on
  `FakeHelper`, and the receiver checks with the real bundled helper on free
  ports, in `SelfTest+Receiver.swift`; the gRPC check runs the sample sender
  named by `APP_SAMPLE_SENDER`, which `selftest.sh` sets): `tools/selftest.sh`.
  The S-008 checks (`SelfTest+Lifecycle.swift`, last: relaunch, helper
  crashes, and a second Magnife process that is quit and killed with
  `kill -9`) print their timings as INFO lines; `APP_SELFTEST_ONLY=lifecycle`
  runs them alone; `APP_SELFTEST_ONLY=sidebar` the S-009 checks, `=pause` the S-010 ones, `=logs` the S-013 ones.
  `APP_SELFTEST_ONLY=waterfall tools/selftest.sh` runs only the reader, model
  and waterfall checks (`APP_SELFTEST_ONLY=span-detail`: the span detail,
  exception, span log and Trace Logs checks, incl. a 10,000-log trace timed as an INFO line); the waterfall checks time 1,000/5,000/30,000-span
  traces (INFO lines) and write `/tmp/Magnife-shots/03-trace-detail-30000-*.png`. Exit 0 when every check passes. Add a check for every story with logic in `SelfTest.swift`.
- After every UI change, take snapshots and look at them: `tools/snap.sh`.
  It writes `/tmp/Magnife-shots/<page>-light.png` and `-dark.png` for every
  `SnapshotPage` (the pages in `docs/STORIES.md`), and
  `09-settings-<tab>-light.png` / `-dark.png` (and `09-settings-general-delete`,
  the S-016 dialog), then quits. `02-trace-list-busy`
  and `02-trace-list-not-receiving` show the busy-port banners (replayed
  "ports" lines, since APP_HELPER=none), `02-trace-list-restarted` the S-008
  banner. `01-empty-state-copied` shows the
  S-003 copy feedback and `02-trace-list-environment` the toolbar popover
  (cropped from the window capture), `02-trace-list-new-traces` the S-004
  button over a held list, `02-trace-list-service` the orders scope (S-009), `02-trace-list-paused` the pause bar (S-010). `04-span-detail` shows the HTTP 500 trace's
  POST /payments span (Exception first), `04-span-detail-events` the gRPC
  server span scrolled to Events, `04-span-detail-long-value` a statement
  cut with "Show All", `04-span-detail-copied` Copy Stack Trace's "Copied",
  `04-span-detail-logs` the Logs section with a log's attributes open, `04-span-detail-log-json` a pretty-printed JSON body,
  `03-trace-detail-trace-logs` Trace Logs with a log (and so its span) selected,
  `03-trace-detail-no-longer-stored` the S-015 state (set, not pruned),
  `05-logs` the Logs view with the payment log's detail, `05-logs-no-trace`
  a log without a trace id, `05-logs-new-logs`, `05-logs-paused`, `05-logs-empty`,
  `05-logs-filtered` (ERROR and WARN on), `05-logs-filter-hidden`, `05-logs-no-matches`,
  `06-command-k` (Search for "checkout") with `-empty`, `-suggestions`, `-tokens`, `-no-match`,
  `07-filter-bar` (Error on), `07-filter-bar-no-matches`, `-duration`, `-duration-error`,
  `-suggestions` (key completion), `-condition` (two rows applied).
  `APP_SNAPSHOT_PAGES=02-trace-list,09-settings tools/snap.sh` limits the pages.
  A story that adds a screen fills in its page's `prepare` in `Snapshot.swift`.
- Both scripts pass an empty "NSSplitView Subview Frames …" default, so the
  window's columns start at their ideal widths, not where the last run left them.
- Never test against the real database in `~/Library/Application Support/Magnife/`.
- Then check the grid: `tools/grid-lint.sh` and `swift tools/check-layout.swift /tmp/Magnife-shots/*-layout.json`. Both print PASS.
- A change is done when the build has no errors, the grid checks pass, and you looked at the light and dark snapshots.

## Design rules

- Words on screen come from `../docs/GLOSSARY.md`, exactly.
- Use Apple's controls and system styles. The accent follows the system
  accent by default (`ThemeStore.defaultID = "system"`); people can pick
  another in Settings > Appearance.
- Views use `.tint`, `Palette.accent`, `Palette.accentText` (accent-colored text), and `Palette.onAccent` (text on an accent fill). Never hard-code colors, radii, or durations in views.
- Service colors: `ServiceDot(name:)`, which reads `AppModel.serviceColors`
  (`ServiceColors` in MagnifeKit: docs/ux.md's ten colors in the order
  services were first seen) and `ServicePalette`. Red means Error and orange
  a finding; neither is a service color. Error always pairs the octagon icon
  with the word.
- Spacing comes from `Space` in `UI/Grid.swift`, on a 4 pt grid. Mark custom pages and cards with `.gridArea` and `.gridProbe`.
- Windows open calm: `.noInitialFocus()` on every window and sheet, `.fitsContent()` on sheets and Settings tabs. Both in `UI/WindowBehavior.swift`.
- Settings: one tab per topic in `SettingsView.swift`, one grouped Form per tab. Add a case to `SettingsTab` for a new tab.
- Window chrome (title bar, toolbar, sidebar, menus, sheets) stays system. Buttons use system styles, like `.borderedProminent`.
- Colors: `.primary`, `.secondary`, `.tint`, and system colors. Never fixed grays or white for text.
- Every action has a menu bar item and a keyboard shortcut.
- `Label` for icon and text pairs. SF Symbols for icons.
- `ContentUnavailableView` for empty states.
- Liquid Glass belongs to floating controls only, never to content.
- The main scene is a `WindowGroup`, and closing the window keeps Magnife
  running (`applicationShouldTerminateAfterLastWindowClosed` is false).

## Skills

The bama plugin has a skill for each step: `mac-design` (design rules),
`design-system` (accent and tokens), `layout-grid`, `ux-design`,
`swift-swiftui`, `os-integrations`, `performance`, `build-and-verify`,
`test-mac-app`, `app-icon`, `user-stories`, and `improve-loop`. Use them.

## Git

- Commit after each working change, with a message that says what the user can now do.
