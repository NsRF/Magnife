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

## A relaunch showed "No Traces Yet" before the stored traces (S-008)

- Symptom: on a relaunch with stored traces, the list read "No Traces Yet" until the helper had started (about half a second), then the traces appeared.
- Cause: the helper's SQLite deleted the `-wal` on a clean exit, so the read-only app could not open the file until the helper had; meanwhile `.opening` / `.waiting` counted as "no traces", and `storeState` turned `.ready` before the first read.
- Fix: the helper keeps its `-wal` and `-shm` (persistent WAL); the app shows the empty state only once it knows (`knowsStoredTraces`: after the first read, or when no file exists) and sets `.ready` after the first read.
- Rule: an empty state means "there is nothing", never "not read yet"; until the first read the list stays blank.

## An open trace that grew past 500 spans never collapsed, and every batch scrolled the waterfall back (S-005, M1 review)

- Symptom: a trace selected while `--huge-trace 30000` was still arriving ended with all 30,000 rows expanded; on every refresh the waterfall jumped back to the selected span, so it could not be scrolled while spans arrived.
- Cause: `defaultCollapsed()` ran only when a trace opened; a rebuild only intersected the old collapsed set, so every new parent started expanded. Each rebuild made new `SpanItem`s and reloaded the outline, whose selected row index then pointed at another row, and `select()` scrolled whenever the row differed.
- Fix: `Waterfall.autoCollapsed(after:)` (worked out off the main actor with the tree) collapses as if the trace had opened that big when it crosses 500 spans, and above 500 collapses only spans that became parents since. Items are kept per span id across rebuilds, and the outline scrolls only when the selected span id changes, never because a rebuild moved its row. Unit tests `growsPastLimit`, `growsAboveLimit`; self-test `checkGrowingWaterfall` (601 then 603 spans over OTLP/HTTP, scroll offset and selection kept).
- Rule: a rule that applies "when it opens" also applies when the data grows into it while open; rebuilds never move the user's view.

## Span names and services were cut at the default window size (S-005, M1 review)

- Symptom: the waterfall's Span column was a fixed 200 pt, so names read "POST /pa…", "SELECT Or…", and a span's service (checkout-api under web) never showed, while the bars took three quarters of the column.
- Cause: the column kept its initial width and only the bar column followed the window; the service gave way to the name entirely below 40 pt. The review's snapshot also came from a saved split layout (the detail column at its 420 pt minimum, from an earlier run), because test runs read and wrote the app's real split autosave.
- Fix: the Span column takes 55% of the waterfall's width on every tile (a drag of its divider sets a new share); when name and service do not both fit, the service keeps 35% of the text's room (at least 40 pt) and both truncate with "…". `snap.sh` and `selftest.sh` pass an empty split-frames default, so test runs start at docs/ux.md's ideal widths. Self-test "a span from another service than its parent's shows its service".
- Rule: size columns that hold names by share of the width, and give tests a known window layout instead of whatever the last run saved.

## A trace whose first read failed stayed empty (S-005, M1 review)

- Symptom: after a failed read at open time (a busy or failing disk), the header showed over an empty outline until another trace was selected.
- Cause: the open read swallowed the error, and `refreshOpenTrace` returned early whenever the waterfall was empty.
- Fix: `isOpeningTrace` marks the read in flight; a refresh that finds a selected trace with an empty waterfall and no read in flight reads it again. Self-test "a trace whose first read failed opens on the next refresh".
- Rule: an early return for "still loading" must tell "loading" from "failed".

## An older list read could put older rows back, and held rows past the newest thousand never updated (S-004, M1 review)

- Symptom: with a batch refresh in flight, scrolling back to the top started a second read; if the first finished last it put its older page back and moved `listBaseSeq` backwards, so the newest trace stayed missing until the next batch. While the list held still, a burst that changed more than 1,000 traces left the older shown rows with their old span count and status, although `listAppliedSeq` moved past the change.
- Cause: the guards compared only the scope, not how new a read was; the held read took at most 1,000 changed rows, newest first, from all of the scope, then marked everything applied.
- Fix: a page or held read whose `lastSeq` is below `listAppliedSeq` is dropped (the open trace's rebuild likewise by `updated_seq`); the held read asks only for the shown rows by id (`trace_id IN json_each(?)`, primary-key lookups, no cap and no scan of the service's spans). Unit test `heldManyUpdates` (1,500 changed rows, the oldest included); self-test "a list read older than the rows shown is dropped, and the next one applies".
- Rule: when async reads can overlap, every result carries the version it read and older results never replace newer ones; a capped read never advances the "applied up to" mark past what it read.

## VoiceOver read each trace row cell by cell, Time and "Unset" included (S-004, M1 review)

- Symptom: `TraceSummary.accessibilityLabel` ("web, POST /checkout/pay, 64 milliseconds, 5 spans, Error") was used by no view; VoiceOver read each cell, including the Time cell and "Unset" for a blank status, and the self-test checked the string, not the table.
- Cause: SwiftUI's TableRow has no accessibility label, so decision 33 put a spoken part in each cell and only unit-tested the sentence.
- Fix: the Service cell carries the whole sentence and the other cells are hidden from VoiceOver, so the row reads once, as docs/STORIES.md S-004 Access says; Unset says nothing (it shows blank). The self-test reads the row through the Accessibility API (AXUIElement) when Magnife has that permission; walking SwiftUI's accessibility elements in process crashed the app in its next render, so it is not done.
- Rule: a test of what VoiceOver hears reads the accessibility tree the way VoiceOver does, never the string the code meant to give it.

## Trace list columns cut "30.000" and long routes while space was free (S-004, M1 review)

- Symptom: the Spans column showed "30.0…" for a 30,000-span trace (en_BR digits), and at a wide list Route was cut while space was left after Time.
- Cause: Spans was 44–48 pt and Route had no maximum, so the table gave extra width to no column in particular; the Time column was 136–150 pt for at most 86 pt of text.
- Fix: widths from measured 13 pt text ("28 Nov, 22:32" 86 pt, "30.000" 44 pt, "2 min 5 s" 56 pt, the Error label 64 pt): Service 72, Route 98 and up (max: .infinity), Duration 56, Spans 52, Status 64, Time 88; at docs/ux.md's 520 pt list only Route truncates (in the middle, tooltip), and a wider list gives the room to Route.
- Rule: size table columns from the longest text they show, measured, and give the free width to the column that truncates.
