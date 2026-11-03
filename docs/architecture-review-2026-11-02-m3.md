# Architecture check-in, M3 (Detect and alert, Polish)

Survey after the M3 review fixes (checkpoints 058 to 061). Signals looked at: file
sizes (no Swift file over 600 lines; `AppModel.swift` 591, `TelemetryReader.swift`
563), files touched per checkpoint (`.night/patches/030` to `061`), the M3 entries
in `docs/FIXLOG.md`, `@MainActor` types doing I/O (none: every read is a
`@concurrent` reader method), and duplicated private types (none).

What the M3 review found clusters in three places: state that one async path set
and another overwrote (`isBatchRefresh`, `launchSelection`), a count derived from
the wrong column (`updated_seq`), and a check that could not fail. The first is
fixed with a task-local (`RefreshPacing`), the second by counting the batch lines'
`error_traces`, the third in the self-test. None of them needed a new module.

## Recent Errors and notifications out of AppModel  [Worth exploring]

Files: `app/Sources/Magnife/AppModel.swift` (591 lines, touched in 16 of the last
32 checkpoints), `AppModel+RecentErrors.swift`, `AppModel+Notifications.swift`,
`MenuBarViews.swift`, `FailureNotifier.swift`.
Signal: hot spot. Every story adds its stored properties to `AppModel.swift`,
because extensions cannot hold them; S-026 to S-028 added nine (`recentErrors`,
`recentErrorTraces`, `recentErrorsThrottle`, `recentErrorsTask`, `newErrorCount`,
`recentErrorsOpenedAt`, `failureNotifier`, `pendingFailedTrace`, `launchSelection`).
Problem: the menu bar extra's state sits next to the window's, so the scene's menu
and label observe the same object the window does, and a change to the count rule
touches `AppModel.swift`, its extension and the views.
Proposal:

```swift
@MainActor @Observable final class MenuBarState {
    private(set) var traces: [TraceSummary] = []   // what the menu shows
    private(set) var newCount = 0                   // the icon's count
    private(set) var openedAt = Date()
    func refresh(_ reader: TelemetryReader, paced: Bool) async
    func failed(_ ids: [String], paced: Bool)
    func opened(), closed()
}
```

Benefits: locality (S-026's rule in one file with its throttle and task); the
scene's views observe a small object.
Proof of same behavior: `APP_SELFTEST_ONLY=menu-bar` and `=notifications` (58 and
55 checks), `08-menu-bar-*` snapshots byte-compared.
Why not now: it moves nine properties and their callers across about eight files
for no behavior change, `AppModel.swift` is under the 600-line signal, and the
menu bar's cost is already paced (the menu bar check measures 49 ms for 20 changes).

## The Traces | Logs switch in an AppKit container  [Worth exploring]

Files: `ContentView.swift` (`ContentColumn`, `DetailColumn`, `shownWhen`).
Signal: S-030 is blocked on it: the switch costs about 43 ms at rest and 95 to 137
ms at 5,000 spans/s, all SwiftUI graph update and layout in one turn (PROGRESS,
Blocked).
Problem: both columns live in the window's SwiftUI graph and depend on
`contentMode`, so a switch re-renders the content column, the detail column and
the toolbar together.
Proposal: an `NSViewRepresentable` `ColumnSwitcher` holding two `NSHostingView`s
(each with `.environment(model).themed()`, as `DetailSplit` does), showing one by
`alphaValue` and hit-test filtering, never `isHidden` (FIXLOG).
Benefits: a switch becomes two AppKit property changes; the hidden column's views
stop depending on `contentMode`.
Proof of same behavior: `APP_SELFTEST_ONLY=logs`, `=keyboard` (focus moves on
⌘1 / ⌘2), `=load` (the BLOCKED line must turn PASS), `05-logs-*` and
`02-trace-list-*` snapshots.
Why not now: it is a performance change with an uncertain payoff, not a refactor
with the same behavior; it belongs to S-030's next round, not to this check-in.

## One pacer for batch-driven copies  [Speculative]

Files: `AppModel+Counts.swift` (`countsChanged`), `AppModel+RecentErrors.swift`
(`publishRecentErrors`), `AppModel+Waterfall.swift` (`scheduleWaterfallRefresh`).
Signal: the same throttle-plus-one-task shape three times.
Problem and proposal: a `PacedAction(interval:)` with `run(paced:_:)` would hold the
throttle and the task. Two of the three differ (the menu bar fires only when what
it shows changed; the waterfall counts from its last rebuild), so the shared part
is about ten lines each. Not worth a module yet.

## One pending-open intent  [Speculative]

`pendingSpan` (Open Trace from a log) and `pendingFailedTrace` (a Recent Errors
item or a notification) are two "do this once that trace's waterfall is built"
fields, both consumed in `show(_:opening:)`. One enum would make "another trace
opening drops it" one rule; today it is two lines, each next to the other.

## Carried over, still not recommended

- **LogsModel** (M2 review): same reason as M2; the menus and the pause bar read
  both views' state through `AppModel`.
- **One OTLP/JSON span builder for the self-test** (M1, M2): M5's detector checks
  used the sample sender's scenarios instead of hand-written OTLP, so the need did
  not grow.
- **Splitting `TelemetryReader`** (563 lines): still one read per method with the SQL
  in `TelemetrySQL`; `openTrace` (M3 review 7) joined three reads into one, which a
  split by view would have made harder.

## Top recommendation

**Recent Errors and notifications out of AppModel** (Worth exploring). No candidate
is Strong, so this unattended check-in changes no code; the owner can pick it, or
the ColumnSwitcher as S-030's next round.
