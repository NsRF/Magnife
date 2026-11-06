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
  new read.
- Live lists (S-030): the trace list and the Logs list are NSTableViews,
  never SwiftUI `Table`s (FIXLOG: "reentrant operation in its NSTableView
  delegate"). `LiveTable.swift` (`LiveTableCoordinator`) takes each new
  row array as one `RowUpdate` (MagnifeKit `LiveRows.swift`, unit-tested),
  never inside a table callback, inserting at most every 250 ms
  (`UpdatePacer`, no animation under load or with Reduce Motion), refills
  visible cells in place (never `reloadData(forRowIndexes:)`), and gives
  the flexible column (Route, Body) the width left. `TraceTable.swift` /
  `TraceTableKeys.swift` / `TraceTableCells.swift` and `LogTable.swift`
  hold the columns, cells (AppKit, frames not constraints; `HostingCell`
  for RouteCell, LogLevelLabel, LogBodyCell, given values), keys and
  context menus. `TraceRows` / `LogRows` are the only views that read the
  rows, so a batch updates the table alone. Both lists and both detail
  columns stay in the window (`shownWhen`; never `isHidden`, FIXLOG).
  Batch refreshes (`reload(fromBatches:)`, `isBatchRefresh`, read from the
  task-local `RefreshPacing.isBatch`, never a stored flag: refreshes overlap) show the
  subtitle and the sidebar's services at most once a second
  (`AppModel+Counts.swift`, `shownSubtitle`, `shownServices`), the menu bar
  extra's copy at most once a second, and rebuild a growing open waterfall
  at most every 500 ms; a change people make shows at once. `MenuState`
  publishes `hasNewRows`, not the count. Trace Logs reads only logs above
  the shown ones (`TelemetryReader.traceLogs(after:)`) and the Logs counts
  only logs above the last count (`LogCountMark`, dropped on `pruned`).
  `APP_SELFTEST_ONLY=load` floods the window at 5,000 spans/s for 60 s
  (`APP_LOAD_SECONDS`, `APP_LOAD_STEPS`); `APP_DEBUG_STALLS=1` prints each
  main run loop turn over 100 ms with the app's work in it (`StallLog`), and
  each real main-thread hang over 100 ms as `HANG <ms> ms` (a 5 ms
  heartbeat, App Nap off): a long run loop turn alone is not a hang. The
  load check fails over the acceptance's 100 ms (no WARN band); its switching
  part is `checkBlocked` (a BLOCKED line) while S-030 is blocked on it.
  The self-test turns App Nap off (FIXLOG); `selftest.sh` fails on the
  reentrant warning.
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
  `LogListView.swift`, `LogTable.swift` and `LogDetailView.swift`. A table
  cell's view never reads `@Environment` (FIXLOG): pass it values and actions.
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
- Saved filters (S-021): `SavedFilters` (MagnifeKit, unit-tested: names,
  rename, delete and undo place, `isEdited`, defaults round trip) keeps
  name + query in `AppDefaults.shared` (the user's defaults, or the
  `com.nasserfarhat.magnife.tests` suite in snapshot, self-test and
  APP_STORE runs). `SidebarSelection.savedFilter(id)`; while one is
  selected its service is `savedFilterService`, and `scopeService` is what
  every scoped read uses (never `sidebar?.serviceName`). Views in
  `SavedFilterViews.swift`, model in `AppModel+SavedFilters.swift`;
  `APP_SELFTEST_ONLY=saved-filters` runs its checks.
- Keyboard (S-022): rules in MagnifeKit `KeyboardNavigation.swift`
  (`WaterfallMove`, `ListMove`, `FocusColumn`, unit-tested); the model's
  `focus(_:)`, `enterWaterfall`, `enterSpanDetail`, `leaveWaterfall`,
  `leaveSpanDetail` in `AppModel+Keyboard.swift`. AppKit tables take the
  focus directly; SwiftUI columns (sidebar, span detail) follow
  `focusRequest` and take it once (`takeFocusRequest`). Waterfall keys in
  `WaterfallOutlineParts.swift` (`handleKey`), list keys in
  `KeyboardViews.swift` (`listKeys`), the sidebar's Tab in `SidebarTabKeys`
  (a local key monitor). Self-test keys go through `NSApp.postEvent`;
  `APP_SELFTEST_ONLY=keyboard` runs them and the menu audit.
- Findings (S-023+): detectors are pure MagnifeKit functions
  (`Models/Findings.swift`, `Detectors`) over `DetectorSpan` (promoted
  `db_*` / `http_*` columns only, never attribute JSON); they run inside the
  reader's `openTrace` (the trace row, the waterfall's spans and the
  detector spans in one read, so findings never name a span the tree
  lacks; `openTraceFindings`) and
  `findingSummaries` (the list's badges, one read for the stale rows,
  `FindingCache` keyed by `updated_seq`, `AppModel+Findings.swift`). Views in
  `FindingViews.swift`: `RouteCell` badges (icon alone unless the whole route
  fits beside the word), `FindingsStrip` under the waterfall header
  (`selectFinding`), `FindingList` first in the span detail; the waterfall
  row's orange icons are `SpanNameCell.marks`. N+1 groups statements by
  `SQLNormalizer.normalize` (MagnifeKit, table-tested in `SQLNormalizerTests`). Where each
  finding is (`FindingPlace`, `FindingPlaces.build`, pure, from the open trace's tree:
  service, "under" route, caller and callee, the first Error under an HTTP
  Error, share of the trace) is attached in `TelemetryReader.placedFindings`,
  which `readWaterfall` calls; the words per surface are `Finding.line(in:)`,
  `detailText(in:)`, `accessibilityLabel(in:)`, `rowHelp(for:)`, `spokenMark(for:)`
  (`Models/FindingWords.swift`) and `FindingSummary.help`. Never write "endpoint":
  "in <service>, under <route>". `APP_SELFTEST_ONLY=findings`
  runs the checks (the seed set's and, on `APP_EDGE_STORE`, the detector edge
  set's strings) and the cost INFO lines (`INFO places`). `MAGNIFE_EDGE_STORE=<db>
  swift test --filter EdgeStoreGoldenTests` checks an edge store (`seed_store <db> --edges`);
  `MAGNIFE_FINDINGS_DUMP=<file>` writes what each trace says as JSON
  (with `MAGNIFE_DUMP_STORE=<db>`, `EdgeStoreGoldenTests/dumpStore`, for any store).
- Menu bar extra (S-026): `MenuBarExtra` `.menu` style in `App.swift`, views
  in `MenuBarViews.swift`. `RecentErrors` (MagnifeKit, unit-tested) holds the
  five newest traces with an error (read in every refresh, paused too,
  `TelemetryReader.recentErrors`) and the count since the menu was last
  opened: the ids the batch lines named in `error_traces` since then
  (`noteFailedTraces`, a set, so a trace counts once, when it fails; never
  `updated_seq`, which late spans move), `AppModel+RecentErrors.swift`.
  While the menu is closed (`MenuBarTracking.isOpen`) its times count from
  the last list change. The label is `MenuBarGlyph.image(count:)`,
  one cached bitmap per count with its VoiceOver words as the image's
  description; never add view modifiers to the label or a fresh NSImage per
  update, and never let `isInserted` write back (FIXLOG: both looped the scene
  at 100% CPU). `MenuBarTracking` sees the menu open (`NSMenu`
  didBeginTracking, then the "Recent Errors" header once SwiftUI filled it).
  A Recent Errors item (S-027) calls `MainWindow.bringForward` and
  `openFailedTrace`: the trace through `pendingFailedTrace` (like
  `pendingSpan`), then `Waterfall.firstErrorSpanID` selected, Span tab, the
  focus in the waterfall once its outline is in a visible window.
  `MenuBarProbe` clicks the real status item for the self-test
  (`APP_SELFTEST_ONLY=menu-bar`) and snapshots (`08-menu-bar`, `-icon`,
  `-empty`, region captures with the glass).
- Notifications (S-028): each batch line's `error_traces` go to
  `AppModel.notifyFailures` (paused too; ids wait until the store is open),
  `TelemetryReader.failedTraces` reads their words off the main actor, and
  `FailureNotifier` asks macOS on the first failure (or when the setting is
  turned on), then posts what `FailureCoalescer` (MagnifeKit, pure, time
  passed in, unit-tested) says: a banner at once, one follow-up per 10 s
  window per service that replaces it (same request id). `NotificationPosting`
  is `SystemNotificationPoster` in real runs and `FakeNotificationPoster` in
  snapshot and self-test runs, which never touch `UNUserNotificationCenter`.
  `NotificationRouter` is the center's delegate (set in
  `applicationWillFinishLaunching`, real runs only): `[.banner, .list]` while
  frontmost, and a click runs `openFailedTrace` through `MainWindow.bringForward()`
  (`MainWindow.openAction`, kept by `MainWindowCommands`). Settings >
  Notifications in `NotificationSettings.swift`; `APP_SELFTEST_ONLY=notifications`
  runs the checks with a 1 s window; snapshots `09-settings-notifications`
  and `-notifications-denied`.
- Launch (S-029): `AppModel.start` restores the last quit's scope, filters
  and filter bars before the store opens (`restoreLaunchState`, `LaunchState`
  in MagnifeKit), and `finishLaunch` selects the kept trace after the first
  read and puts the focus in the list; `keepLaunchState` writes it at quit.
  Test runs restore nothing. `LaunchProbe` (APP_LAUNCH_PROBE=<file>) writes
  each step's time since the process started; `APP_SELFTEST_ONLY=launch`
  launches copies of Magnife on the 100,000-span store (and on
  `SELFTEST_LAUNCH_VOLUMES="12000 300000"` stores) and checks the restore.
- Test runs own their files and defaults: `TestRun` (a `mktemp -d`
  directory from APP_TEST_ROOT, captures in its `shots/`, and the defaults
  suite `com.nasserfarhat.magnife.tests.run.<pid>`, removed at exit, swept
  when a run crashed). Never hard-code a /tmp path in a check: use
  `TestRun.scratch("name")`. Timing checks use `checkTiming` (the value
  always printed; over the budget a WARN line, over twice it a FAIL; a check
  that encodes an acceptance line's number passes it as `regression`, so it
  fails over it: launch 1 s, search 100 ms, load 100 ms).
- Test runs and the user's defaults: AppKit saves window frames and column
  widths in the app's domain by itself; snapshot and self-test runs copy
  those keys aside at launch (`AppDefaults.protectLayout`, in
  `applicationWillFinishLaunching`) and put them back at exit
  (`restoreLayout`). Never write the real domain from a test run.
- App-owned settings (retention, Settings tab, accent) live in UserDefaults,
  never in the database.
- Sharing (S-033, `AppModel+Sharing.swift`): Export Trace… reads the trace
  with `TelemetryReader.exportTrace` (spans, logs, resources in one read) and
  `TraceExport` (MagnifeKit) writes OTLP JSON Lines; its output is the golden
  file `../ingest/internal/receiver/testdata/magnife-export.jsonl`, which the
  Go import test reads (`MAGNIFE_UPDATE_GOLDEN=1 swift test` rewrites it).
  Import Traces… (and files dropped on the window) never write: they send
  `HelperCommand.importFile` and act on `imported` / `import_failed` only for
  paths in `pendingImports`. `APP_SELFTEST_ONLY=sharing` runs it end to end.

- MCP server (S-034, `../docs/mcp.md`): `Sources/MagnifeMCP/main.swift` is
  `Contents/Helpers/magnife-mcp`, a stdio loop around `MCPServer`
  (MagnifeKit `MCP/`: JSON-RPC and MCP, no dependency) and `MagnifeTools`
  (the six read-only tools on `TelemetryReader`, `TraceQuery`, the detectors
  and `Finding.detailText(in:)`; never re-implement a rule there). Bad
  arguments throw `MCPInvalidParams`, which the server answers as an
  `isError` result. Tests: `MCPServerTests`, `MagnifeToolsTests`, and
  `MAGNIFE_MCP_STORE=<seeded db> swift test --filter MCPSeedStoreTests`.
  `build.sh`, `../scripts/install-local.sh` and `../scripts/release.sh` copy
  and sign it (identifier `com.nasserfarhat.magnife.mcp`).
- Settings > Agents (S-035, `AgentSettings.swift`, `AppModel+Agents.swift`):
  `AgentClient` (MagnifeKit, unit-tested) has each agent's command or JSON
  with the path shell-quoted or JSON-escaped; `AgentServerLocation` is this
  bundle's `magnife-mcp` and whether its path lasts (translocated, disk
  image, missing). The code block is S-003's `EnvironmentCode` with
  `wraps: true`. Help > Connect a Coding Agent… (`ConnectAgentMenuItem`)
  opens Settings on Agents. `APP_SELFTEST_ONLY=agents` runs its checks;
  snapshot `09-settings-agents`.

## Layout

- `Sources/Magnife/` the app. `App.swift` has the scene, menus, launch modes;
  `AppModel.swift` the state; `ContentView.swift` the three columns.
- `Sources/MagnifeKit/` records, the reader, the helper protocol and
  supervisor, formatting (durations, relative time, service color slots). No
  SwiftUI. Tests in `Tests/MagnifeKitTests/` (Swift Testing).
- `Package.swift` a Swift package (Swift tools 6.3, so CI's Xcode 26 can test MagnifeKit; the app builds with Xcode 27; macOS 26), GRDB 7.
  There is no Xcode project.
- `build.sh` builds, runs `../ingest/build.sh` when it exists, copies the
  helper into `Contents/Helpers/`, signs inside out (helper, then app; never
  `--deep`), and installs `~/Applications/Magnife.app`.
- Software updates (M4): Sparkle 2 is the package trait `Sparkle`, off by
  default (no Sparkle linked, no `SU*` keys, no Check for Updates…).
  `MAGNIFE_SPARKLE=1 ./build.sh` (or `scripts/install-local.sh`) builds with it:
  `tools/sparkle-bundle.sh` copies `Sparkle.framework` into
  `Contents/Frameworks`, writes `SUFeedURL` / `SUPublicEDKey` (placeholders
  unless `SPARKLE_FEED_URL` / `SPARKLE_PUBLIC_ED_KEY`) and
  `SUEnableAutomaticChecks` (false unless `SPARKLE_AUTOMATIC_CHECKS=1`, or
  no key with `=ask`; `scripts/release.sh` builds with `ask` and the feed
  `https://github.com/NsRF/Magnife/releases/latest/download/appcast.xml`,
  RELEASE.md B2 and B7), and signs Sparkle inside out.
  `UpdaterController` starts Sparkle only with a real feed and key
  (`UpdateConfiguration`, MagnifeKit) and never in snapshot or self-test runs;
  `#if MAGNIFE_SPARKLE` guards every Sparkle line. Ad hoc Sparkle builds drop
  the app's hardened runtime (library validation). `APP_SELFTEST_ONLY=updates`
  checks the menu both ways. Release steps: `../docs/RELEASE.md`.
- `Icon/AppIcon.icon` the app icon (S-032), an Icon Composer file: `lens.svg` (the lens ring and handle) over `bars.svg` (three offset bars, a tiny waterfall), both brand yellow #fcdb05, on solid brand purple #8d05fc; the dark look keeps both colors (`fill-specializations`) and translucency is off so the yellow stays true. `docs/brand/` has the 1024 and 512 px renders (ictool) and the social preview (`tools/social_preview.swift`). Filled shapes only, drawn by hand (no SF Symbol). `build.sh` compiles it with `tools/make_icon.sh`; `tools/icon_review.sh` renders every look into one PNG. The menu bar glyph (`MenuBarGlyph.drawGlyph`) is the same lens and bars as line art.
- `tools/seed.zsh` seeds test databases through the real pipeline
  (docs/STORIES.md, "Seed data"): it starts the bundled helper standalone
  (`--no-stdin`, ports 0) on a fresh /tmp database, runs
  `scripts/send-sample-traces` against it (3 services, 5 traces: healthy,
  N+1, slow SQL, HTTP 500 with an exception, an exception; 20 logs, 8 with
  no trace id), waits until the batch lines add up, and keeps the helper
  running while the app reads (the read-only reader needs the `-wal` file),
  then stops it (`--edges`: the detector edge set, 6 traces, 51 spans). `snap.sh` and `selftest.sh` source it. The app never writes,
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
  traces (INFO lines) and write `03-trace-detail-30000-*.png` in the run's `shots/` (selftest.sh prints the run directory). Exit 0 when every check passes. Add a check for every story with logic in `SelfTest.swift`.
- After every UI change, take snapshots and look at them: `tools/snap.sh`.
  It writes `<run>/shots/<page>-light.png` and `-dark.png`, linked from `/tmp/Magnife-shots`, for every
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
  `-suggestions` (key completion), `-condition` (two rows applied),
  `-save` and `-save-duplicate` (the Save Filter sheet); `02-trace-list-saved-filter`,
  `-saved-filter-edited` and `-saved-filter-rename` (S-021).
  `APP_SNAPSHOT_PAGES=02-trace-list,09-settings tools/snap.sh` limits the pages.
  A story that adds a screen fills in its page's `prepare` in `Snapshot.swift`.
- Both scripts pass an empty "NSSplitView Subview Frames …" default, so the
  window's columns start at their ideal widths, and the run puts the user's
  layout keys back when it ends (`AppDefaults.restoreLayout`).
  `03-trace-detail-waterfall-focus` and `-span-focus` show the keyboard focus (S-022).
  `03-trace-detail-slow-sql`, `-n-plus-one` and `-http-error` show a strip line clicked (S-023 to S-025) and
  `02-trace-list-findings-wide` the badges' words in a list column dragged wider.
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
- Every color besides the system's semantic ones comes from MagnifeKit
  `ColorPalette` (S-031): the ten service colors, `errorText`, `errorFill`,
  `finding`, `warning`, each in light, dark and both Increase Contrast
  variants, unit-tested for 4.5:1 text / 3:1 graphics (7:1 / 4.5:1 with
  Increase Contrast) against the window's backgrounds (`ColorPaletteTests`).
  Views use `ServicePalette` and `StatusColors` (`UI/ServicePalette.swift`),
  AppKit dots `ServiceDots.image(_:slot:)`. Never `.red`, `.orange`,
  `.systemRed` or a hex in a view: `tools/color-lint.sh` (run by
  `selftest.sh`) fails on them; `// color: ok <why>` for a real exception.
  Increase Contrast adds a 1 pt label-color border to waterfall bars and a
  ring to service dots (`StatusColors.contrastEdge`, clear otherwise);
  `NSAppearance.isHighContrast` reads the system setting, and
  `DisplayOverrides` fakes it and Reduce Transparency for snapshots
  (`03-trace-detail-contrast`, `05-logs-contrast`, `06-command-k-solid`,
  `02-trace-list-paused-solid`); `APP_SELFTEST_ONLY=appearance` checks the
  palette in each appearance and renders the border and ring. Under Reduce
  Transparency the Search panel and banners get a solid background
  (`PanelSurface`).
- Spacing comes from `Space` in `UI/Grid.swift`, on a 4 pt grid. Mark custom pages and cards with `.gridArea` and `.gridProbe`.
- Windows open calm: `.noInitialFocus()` on every window and sheet, `.fitsContent()` on sheets and Settings tabs. Both in `UI/WindowBehavior.swift`.
- Settings: one tab per topic in `SettingsView.swift`, one grouped Form per tab. Add a case to `SettingsTab` for a new tab.
- Window chrome (title bar, toolbar, sidebar, menus, sheets) stays system. Buttons use system styles, like `.borderedProminent`.
- Colors: `.primary`, `.secondary`, `.tint`, semantic system colors (labelColor, separatorColor), and the palette above. Never fixed grays or white for text.
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

- Commit only when asked
