# Magnife — Fix log

One entry per bug a story fixed: symptom, cause, fix, and the rule that keeps it fixed. Newest at the bottom.

## Receiver status flashed "Starting receiver…" on every launch (S-001)

- Symptom: the toolbar read "Starting receiver…" from the first frame, although the helper is listening in about 0.4 s; helper `error` lines showed as raw text with a close button.
- Cause: the view showed `ReceiverStatus.text` for `.starting` directly; there was no clock for the S-001 rule "starting shows nothing unless it takes over half a second", and the error banner skipped docs/ux.md's "App-wide states" wording.
- Fix: `ReceiverStatus.statusText(startingFor:)` returns nil under `quietStart` (0.5 s); `AppModel` starts that clock with the helper and after each crash. Error lines read "The receiver reported a problem: <message>" with Try Again. Unit tests in `ReceiverStatusTests`, self-test "a quick start shows no status" with a helper that never reports.
- Rule: every state in a story's UX block gets its own test, including the "shows nothing" ones.

## A banner pushed the whole window up under the toolbar (S-001, before checkpoint)

- Symptom: with the busy-port banner shown, the sidebar and the trace list moved about 130 pt up under the toolbar and the banner itself was off screen (its probe at y = -80).
- Cause: `.fixedSize(horizontal: false, vertical: true)` on the banner's text. AppKit asks the window's SwiftUI content for its minimum size with a near-zero width; the text then wraps a word per line, the minimum height outgrows the window, and the content is laid out taller than the window, anchored at the bottom.
- Fix: removed the modifier; the text wraps within the width it gets.
- Rule: never put `fixedSize(vertical: true)` on wrapping text in the main window's layout; check the `-layout.json` probe positions after adding a banner or bar.

## Two services could share a color (S-004)

- Symptom: service colors came from a hash of the name into 12 slots, so two services could get the same dot (about one time in four with three services), and the palette held orange, which docs/ux.md keeps for findings.
- Cause: the scaffold's `ServiceColor.slot(for:)` hashed names instead of following docs/ux.md (ten colors, assigned in order of `services.first_seen_ns`).
- Fix: `ServiceColors` (MagnifeKit) ranks services by first seen, then name, into docs/ux.md's ten system colors; `ServiceDot` reads it from AppModel in the sidebar, list and detail. Unit test `TraceListTests.colors`, self-test "each seed service has its own color".
- Rule: assign identity colors from a stable order of the data, never from a hash, when they must stay distinct.

## The self-test hung after collapsing a waterfall row (S-005, before checkpoint)

- Symptom: the self-test stopped printing after "clicking a row selects its span" and never quit; the main thread sat idle in the event loop.
- Cause: after `collapseItem`, `outline.parent(forItem:)` of the now hidden row returned nil, `row(forItem:)` gave -1, and `view(atColumn: 0, row: -1, makeIfNecessary: true)` never returns.
- Fix: the check finds the parent's row by walking the outline's items and asks for a view only when the row is 0 or more.
- Rule: never pass a row from `row(forItem:)` to an NSTableView view or rect call without checking it is not -1.

## The waterfall's bar column ran past the window edge (S-005, before checkpoint)

- Symptom: in the first snapshot the bars and the header's time labels were cut off at the right edge of the detail column.
- Cause: the columns' initial and minimum widths plus the inset style's padding were wider than the 420 pt detail column, and NSOutlineView's `autoresizesOutlineColumn` widened the Span column on every expand.
- Fix: narrow initial widths with `lastColumnOnlyAutoresizingStyle`, so the bar column fills what is left; `autoresizesOutlineColumn = false`; `sizeThatFits` returns the proposed size so SwiftUI never sizes the column from the table.
- Rule: give an AppKit table inside a SwiftUI column a minimum width below the column's minimum, and check the right edge in the snapshot.


## The first snapshot page of a run showed "No Trace Selected" (S-007)

- Symptom: `APP_SNAPSHOT_PAGES=04-span-detail tools/snap.sh` wrote `04-span-detail-light.png` with an empty detail column; the dark capture and every later page were right.
- Cause: `SnapshotPage.prepare` picked the trace from `model.traces` before the store had opened and the list had been read; earlier runs always began with 01-empty-state or 02-trace-list, which need no selection, so the race never showed.
- Fix: `prepare` awaits `model.openStore()` and reads the list when it is still empty before choosing a trace.
- Rule: a snapshot or self-test step that selects data waits for the read that provides it; never assume an earlier page warmed it up.

## The span detail split opened 50 / 50 instead of 55 / 45 (S-006, before checkpoint)

- Symptom: the self-test measured the waterfall at 0.50 of the column; the snapshot showed the divider in the middle.
- Cause: the divider was placed once on the first layout, then AppKit's default resize of an NSSplitView with equal holding priorities shared every later height change evenly between the panes.
- Fix: `DetailSplitCoordinator` implements `splitView(_:resizeSubviewsWithOldSize:)` and lays both panes out from the stored fraction on every resize.
- Rule: an NSSplitView that must keep proportions lays its subviews out itself in `resizeSubviewsWithOldSize`; holding priorities alone do not keep a ratio.
