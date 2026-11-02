# Architecture review, 2026-11-02 (end of M2)

Check-in at the end of milestone M2 (S-009 to S-022, with M3 retention and M4
speed), after the review and end-to-end fixes (checkpoints 035 to 042). The M1
review is `architecture-review-2026-11-02.md`.

Signals found in the survey:

- **Hot spot:** `AppModel.swift` changed in 17 of M2's 22 checkpoints; `AppModel`
  is now 2,458 lines over 21 files (526 in `AppModel.swift`, 382 in
  `AppModel+Logs.swift`), about 150 stored properties. Next: `TelemetryReader`
  (10), `AppModel+Logs.swift` (9).
- **The same fix made twice:** tonight's Resume fixes (S-010: a bounded row count,
  rows held until the selection is revealed) had to be written once for the trace
  list (`AppModel+Pause.swift`) and once for the Logs list (`AppModel+Logs.swift`),
  and the wait-then-reveal step after a read exists in two copies
  (`revealSelectedTrace`, the end of `resumeLogs`), with the FIXLOG rule "wait for
  the table to show the model's rows first" in both.
- **State only refreshed while visible, read while hidden:** two review findings
  (Logs paused from the Traces view, Trace Logs re-read behind the Span tab) came
  from Logs state living on `AppModel` whatever shows.
- No Swift file over 600 lines, no type-check failures, builds warning-free. The
  M1 Strong change (`TraceListState.applying`, and its Logs twin `LogListState`)
  held up: S-010, S-015, S-018 to S-021 each added a rule there with a unit test.

## Reveal after a list read, in the scroller  [Strong]

Files: `AppModel+Pause.swift` (`revealSelectedTrace`), `AppModel+Logs.swift`
(`resumeLogs`), `TraceListScroller.swift` (both lists' scroller).
Signal: the same fix made twice; drifted copies of one AppKit protocol.
Problem: after a read changes the rows, revealing a row is three steps that must
happen in order: wait until the NSTableView shows as many rows as the model (or the
row index points at the wrong row, FIXLOG), scroll the row into view or the list to
the top, then report whether the list is away from the top so it holds still. Both
lists spell this out; a change (a longer wait, a reveal that must not run when the
row is gone) has to be made in both.
Proposal: one async method on the scroller both lists already have.

```swift
extension TraceListScroller {
    /// Waits (up to 1 s) until the table shows `rows()` rows, then brings
    /// `row()` into view, or scrolls to the top when it is nil. Returns
    /// whether the list is away from the top afterwards.
    func reveal(row: () -> Int?, once rows: () -> Int) async -> Bool
}
```

Benefits: locality (the wait-and-reveal rule in one place, next to the scroll
geometry it depends on); the two callers become one line each.
Proof of same behavior: the self-test's Resume checks for both lists ("the selected
trace is in view after Resume", "Resume inserts the logs that arrived", "after
Resume the list holds still only when scrolled away"), Search's and Open Trace's
reveal checks, unchanged counts; snapshots `02-trace-list-paused`, `05-logs-paused`.
Plan: one commit.

## One live-list controller for traces and logs  [Worth exploring]

Files: `AppModel+TraceList.swift`, `AppModel+Pause.swift`, `AppModel+Logs.swift`,
`AppModel.swift` (each list's rows, seqs, held and paused flags, resume rows,
scroller, loading flag).
Signal: the same fix made twice; hot spot.
Problem: reading a page, loading the next one, holding still when scrolled, pausing
and resuming are the same glue for both lists, around their own value types
(`TraceListState`, `LogListState`). Each new list rule is written twice.
Proposal: a generic `@MainActor` `LiveList<State: LiveListState>` owning the rows
and flags and doing the reads through a small read adapter per list; views bind to
`model.traceList.rows` / `model.logList.rows`.
Why not now: it moves every list field the views and the self-test read (about 12
files), and S-030 (100,000 rows, inserts at most every 250 ms) decides whether the
trace list becomes an NSTableView like the waterfall, which changes this glue
again. Do it with S-030.

## The Logs view as its own model  [Worth exploring]

Files: `AppModel+Logs.swift` (382), `AppModel.swift` (the Logs fields), `LogListView.swift`,
`LogDetailView.swift`, `LogFilterBar.swift`.
Signal: hot spot; state read while hidden (review finding 6).
Problem: about 35 Logs properties sit on `AppModel` next to the trace view's, so
anything can read them while the Logs view does not show, and every Logs change
re-touches `AppModel.swift`.
Proposal: an `@Observable final class LogsModel` owned by `AppModel` (reader,
scope service and pause point passed in), with `isShowing` deciding whether it reads.
Why not now: the menus and the pause bar read both views' state through `AppModel`;
splitting it adds pass-throughs until the live-list controller above exists. Do them
together.

## One OTLP/JSON span builder for the self-test  [Worth exploring]

Carried over from M1: the live checks of S-011 to S-015 added more hand-written
OTLP/JSON (`SelfTest+TraceLogs.swift`, `SelfTest+Pause.swift`,
`SelfTest+SpanLogs.swift`). Still test-only code; worth doing before M5's detector
checks add their own.

## Considered, not recommended

- **Deleting pruned services in the helper** (review finding 8): the reader filter
  keeps the contract's meaning (decision 126); no contract change needed.
- **A `trace_services` table:** still a contract change for a scan that runs off the
  main actor; S-030's load numbers decide.
- **Splitting `TelemetryReader`** (456 lines): its methods are one read each with the
  SQL in `TelemetrySQL`; a split by view would only spread the GRDB pool.

## Top recommendation

**Reveal after a list read, in the scroller** (Strong): done in this check-in.
