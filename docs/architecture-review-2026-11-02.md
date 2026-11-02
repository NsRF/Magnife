# Architecture review, 2026-11-02 (end of M1)

Check-in at the end of milestone M1 (S-001 to S-008), after the M1 review fixes
(checkpoints 014 to 017). No Swift file is over 300 lines (largest: `Telemetry.swift`
360, `Snapshot.swift` 295, `SelfTest+Waterfall.swift` 291, `AppModel.swift` 287), no
type over 400, and builds are warning-free, so the signals are the fix log and the
milestone end.

Signals found in the survey:

- **The same kind of bug happened twice:** an older async read replacing a newer
  result, once in the trace list (review finding 5) and once in the open trace's
  rebuild (found while fixing it). Both were fixed with guards written inline in
  `AppModel` extensions.
- **Pure logic inside a `@MainActor` store:** the rules of the live list (design
  decision 6: hold still while scrolled, count new traces, update shown rows in place,
  drop stale reads) live in `AppModel+TraceList.swift`, in the app target. They can be
  tested only through the self-test with a running helper, never by a unit test.
- **Fix log hot spot:** 6 of 17 entries are S-005 (waterfall), 3 are S-004 (list).
- **Drifted copies in the self-test:** five files build OTLP/JSON spans by hand
  (`checkLateSpans`, `checkGrowingWaterfall`, `checkLongValues`,
  `checkSeveralExceptions`, `checkHugeSpan`), each with its own `span(...)` and `send`.

## The live list's rules as a value type  [Strong]

Files: `app/Sources/Magnife/AppModel+TraceList.swift` (81 lines), `AppModel.swift`
(the list's stored fields), `MagnifeKit/Models/TraceList.swift`.
Signal: the same kind of bug twice; pure logic inside a `@MainActor` store.
Problem: whether a read result may replace the rows on screen depends on the scope it
read, whether the list holds still, the base and applied seqs, and the seq the read
saw. Today that is a chain of `guard`s mixed with `await`s and assignments in
`reloadList`, so the overlap bug (an older page put back over a newer one) could only
be shown by forcing `listAppliedSeq` from the self-test, and the next rule (S-010
Pause holds through the same reads) would be added to the same chain.
Proposal: a value type in MagnifeKit that holds what the list shows and decides what a
read does to it; `AppModel` keeps the async reads and its observable fields.

```swift
public struct TraceListState: Sendable, Equatable {
    public var scope: String?          // the sidebar's service, nil for all
    public var traces: [TraceSummary] = []
    public var baseSeq: Int64 = 0, appliedSeq: Int64 = 0
    public var isHeld = false, newCount = 0, hasMore = false
}
public enum TraceListRead: Sendable {
    case page(TracePage, scope: String?)
    case held(HeldTraces, scope: String?, base: Int64)
}
extension TraceListState {
    /// The state after `read`, or nil when the read must be dropped.
    public func applying(_ read: TraceListRead) -> TraceListState?
}
```

Benefits: locality (every rule of design decision 6 and every staleness rule in one
function, next to `TraceList.applying`); leverage (S-010 Pause adds one case);
unit tests replace the self-test's forced-seq check for the ordering rules.
Proof of same behavior: new unit tests at the interface (a page at the top replaces
the rows; a page while held with rows is dropped; a page or held read older than the
applied seq is dropped; a held read for another base or scope is dropped; a held read
updates rows in place and sets the new count; a scope change starts from an empty
list); the self-test's list checks unchanged (holding still, counting, paging, Show
Newest Traces, the older read dropped); `02-trace-list` snapshots unchanged.
Plan: one commit: add the type and its tests, then move `reloadList` onto it.

## One OTLP/JSON span builder for the self-test  [Worth exploring]

Files: `SelfTest+Waterfall.swift`, `SelfTest+WaterfallGrowth.swift`,
`SelfTest+SpanDetail.swift`, `SelfTest+Exception.swift`, `SelfTest+SpanDetailScroll.swift`.
Signal: drifted copies (five hand-written `span(...)` / `send` pairs; one collision
between two self-test trace ids happened tonight).
Problem: each check spells the OTLP/JSON shape, the trace id and the wait-until-stored
loop again; trace ids are picked by hand per file.
Proposal: `SelfTestSender` (app target, test code) with `span(id:parent:name:at:lasting:...)`,
`send(_ spans:, service:) async -> Int` and `waitStored(trace:count:)`, and one table of
self-test trace ids.
Benefits: shorter checks; a new check cannot reuse another's trace id.
Proof: the self-test passes with the same check count.
Why not now: test-only code, and the copies are each used once; worth doing when
S-009 to S-012 add more live checks.

## The waterfall outline's sync with the model  [Worth exploring]

Files: `WaterfallOutline.swift` (281), `WaterfallCells.swift` (248), `AppModel+Waterfall.swift`.
Signal: 6 fix-log entries in S-005.
Problem: `WaterfallCoordinator.update` diffs generation, collapsed set, colors and
selection by hand, and expansion state lives both in the model and in the outline.
Proposal: keep the model's `collapsedSpans` as the only source and have the
coordinator apply a computed `WaterfallOutlineChange` (reload, expand/collapse sets,
select with or without scrolling) from a pure function in MagnifeKit.
Why not now: the entries are fixed and each has a self-test check; the pure part
(`Waterfall`) is already in MagnifeKit. Revisit with S-028 (scroll to a finding), which
adds another selection source.

## Considered, not recommended

- **Splitting `AppModel`** (287 lines plus five extensions, 765 in all): extensions
  already split it by story; a split now would add pass-throughs for the menus.
- **A `trace_services` table** (review finding 13): a contract change for a scan that
  runs off the main actor; decide with S-030's load numbers.
- **Moving the trace list to an NSTableView** (the reentrancy warning): only if S-030's
  100,000-row test needs it.

## Top recommendation

**The live list's rules as a value type** (Strong): done in this check-in.
