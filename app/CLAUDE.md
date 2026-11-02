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
  closes cleanly. The reader reports that as `StoreError.notReady`, and
  `AppModel` retries on the helper's next event and every 2 seconds.
  `Tests/MagnifeKitTests/WALReadonlyTests.swift` pins this behavior.
- `Tests/MagnifeKitTests/ContractTests.swift` builds a database from
  `../docs/schema.sql` with the Go helper's own INSERTs and JSON encoding and
  checks every reader method; `HelperProtocolTests` decodes the protocol's
  example lines straight from that file. Change them with the contract.
- `HelperSupervisor` (MagnifeKit, Foundation only) runs
  `Contents/Helpers/magnife-ingest`, keeps its stdin open (EOF stops it),
  turns stdout lines into `SupervisorEvent`s, passes stderr through, and
  restarts it after a crash (0.5 s doubling to 30 s, reset after 60 s up).
- `AppModel` refreshes on `batch` events: at most one read in flight, 150 ms
  after the first batch. The trace list (`AppModel+TraceList.swift`) reads
  200-row pages; scrolled away from the top it holds still (rows update in
  place, new traces are counted for the "N new traces" button) through
  `TraceListScroller`, which watches the table's NSScrollView. A sidebar scope change empties the list before the
  new read: diffing one scope's rows into another's trips AppKit's
  "reentrant operation in its NSTableView delegate" warning.
- The waterfall (S-005): `TelemetryReader.waterfallSpans` reads only the
  columns it draws; `Waterfall` (MagnifeKit) builds the tree off the main
  actor, without recursion; `AppModel+Waterfall.swift` re-reads the open trace
  only when its `updated_seq` changes and keeps `collapsedSpans` and
  `selectedSpanID` across rebuilds. The rows are an NSOutlineView
  (`WaterfallOutline.swift`, cells in `WaterfallCells.swift`). Never pass a
  row of -1 to its view calls: `view(atColumn:row:makeIfNecessary:)` hangs.
- The span detail (S-006): `TelemetryReader.spanDetail` reads the selected
  span and its resource in one read; `SpanDetail` (MagnifeKit) orders the
  sections and attributes. The detail column is `DetailSplit` (an
  NSSplitView with one NSHostingView per pane, so each pane gets
  `.environment(model).themed()` again); it keeps its divider fraction on
  every resize. "Show All" is measured (`ExpandableText`), and expanded
  values live in `AppModel.expandedValues`.
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
  N+1, slow SQL, HTTP 500 with an exception, an exception; 18 logs, 8 with
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

## Build and check

- Build and install: `./build.sh`. Add `--open` to restart the app with the new build. The build shows warnings; fix them.
  `--open` runs the real helper against the real database; use the scripts below for tests.
- Unit tests: `swift test --scratch-path ~/Library/Developer/Magnife/test-build`.
- Self-test (the app's real functions on the seeded store, the supervisor on
  `FakeHelper`, and the receiver checks with the real bundled helper on free
  ports, in `SelfTest+Receiver.swift`; the gRPC check runs the sample sender
  named by `APP_SAMPLE_SENDER`, which `selftest.sh` sets): `tools/selftest.sh`.
  `APP_SELFTEST_ONLY=waterfall tools/selftest.sh` runs only the reader, model
  and waterfall checks (`APP_SELFTEST_ONLY=span-detail`: the span detail and
  exception checks); the waterfall checks time 1,000/5,000/30,000-span
  traces (INFO lines) and write `/tmp/Magnife-shots/03-trace-detail-30000-*.png`. Exit 0 when every check passes. Add a check for every story with logic in `SelfTest.swift`.
- After every UI change, take snapshots and look at them: `tools/snap.sh`.
  It writes `/tmp/Magnife-shots/<page>-light.png` and `-dark.png` for every
  `SnapshotPage` (the pages in `docs/STORIES.md`), and
  `09-settings-<tab>-light.png` / `-dark.png`, then quits. `02-trace-list-busy`
  and `02-trace-list-not-receiving` show the busy-port banners (replayed
  "ports" lines, since APP_HELPER=none). `01-empty-state-copied` shows the
  S-003 copy feedback and `02-trace-list-environment` the toolbar popover
  (cropped from the window capture), `02-trace-list-new-traces` the S-004
  button over a held list. `04-span-detail` shows the HTTP 500 trace's
  POST /payments span (Exception first), `04-span-detail-events` the gRPC
  server span scrolled to Events, `04-span-detail-long-value` a statement
  cut with "Show All", `04-span-detail-copied` Copy Stack Trace's "Copied".
  `APP_SNAPSHOT_PAGES=02-trace-list,09-settings tools/snap.sh` limits the pages.
  A story that adds a screen fills in its page's `prepare` in `Snapshot.swift`.
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
