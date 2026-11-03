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

## Switching spans kept the span detail's scroll position (S-006 / S-007, M1 review)

- Symptom: with span A's detail scrolled down to Resource, clicking an Error span left the pane scrolled down, so its Exception section, which S-007 says opens first, was out of view.
- Cause: the pane's ScrollView was the same view for every span; only `spanDetailScrollTarget` (snapshots) ever scrolled it.
- Fix: the ScrollView takes the span's trace and span id as its identity (`SpanDetailValueID.span`), so another span starts at the top; a re-read of the same span (a rebuild) keeps the position. Self-test "another span's detail starts at the top, so an Error span opens on Exception".
- Rule: a pane that shows "the selected thing" resets its scroll position when the thing changes, and only then.

## A span with a huge value or thousands of events hitched on selection (S-006, M1 review)

- Symptom: a span with a 500 KB `db.statement` and 2,000 events stalled the main actor for about 700 ms when selected.
- Cause: every event row was laid out at once (a plain VStack), each long value was laid out twice (shown, and a hidden full copy to decide "Show All"), and `SpanDetail.sections`, `attributes`, `events` and `exceptions` were computed properties that sorted again on every access during a view update.
- Fix: the events list is a LazyVStack; a value over 4,000 UTF-8 bytes counts as cut without measuring and shows only its start while collapsed (the whole value when expanded); `SpanDetail` orders its lists once in `init`, where the reader builds it off the main actor. Measured: 700 ms to about 20 ms (self-test INFO line, check "a 500 KB value and 2,000 events open without a hang"); the 500 KB value alone went to 26 ms with the prefix measure.
- Rule: a detail view lays out only what is on screen and never measures more text than it can show.

## The dark receiver-banner snapshots showed a made-up state with a real helper (S-001 / S-008 snapshot tool, M1 end-to-end check)

- Symptom: in a snapshot run against a real helper with a port held by another app, `02-trace-list-dark.png` read "Receiving on 45317 and 45318" with no banner, while the light one showed the real busy banner.
- Cause: after replaying the busy and not-receiving "ports" lines, `captureReceiverStates` set the receiver to "listening on both ports" instead of putting back the state it found.
- Fix: it keeps the receiver state it found and restores it after the replayed banners and the restart banner.
- Rule: a snapshot step that fakes a state restores the state it found, never a default.

## The Logs view crashed when its rows went away (S-013, during the story)

- Symptom: switching the Logs view to an empty store (all rows removed at once) stopped the app with "No Observable object of type AppModel found".
- Cause: the Body column's cell (`LogBodyCell`) read `@Environment(AppModel.self)` in its own root view. When the table dropped its rows, SwiftUI updated the cell's view once more outside the window's hierarchy, where that environment is gone.
- Fix: the cell takes its Open Trace action as a closure from the table, which already holds the model; no table cell root reads the environment. A button in `ContentUnavailableView`'s actions also gets its own view (`CopyEnvironmentButton`), not the outer view's `model`.
- Rule: a Table cell's root view never reads `@Environment`; pass it the values and actions it needs.

## The empty trace list cut the environment variables at 270 pt (S-003, found in S-013's snapshots)

- Symptom: `01-empty-state` showed the variables in a 270 pt code block that scrolled sideways ("export OTEL_SERVICE_NAME=my-serv…") in a 520 pt column.
- Cause: the list kept its width in `@State` from `onGeometryChange`. While the window first lays out, the content column briefly reports 310 pt (the sidebar's 210 pt as a leading safe-area inset), and the change back to 520 pt was not always reported, so the setup stayed sized for 310 pt. Moving the toolbar items to the content column (S-013) changed the layout passes enough to show it on every run.
- Fix: the empty state reads the width from a `GeometryReader` in the overlay, on every layout, and the overlay is there only while the list is empty.
- Rule: a size that lays out other views is read where it is used, on every layout, not cached in `@State` from a geometry callback.

## The VoiceOver row check read no rows (S-004 check, found in S-017's runs)

- Symptom: "VoiceOver reads the HTTP 500 row once, as that sentence" failed with no rows in every self-test run, on the last checkpoint's build as well as the new one.
- Cause: with the screen locked during an unattended run, the Accessibility API answers the app's `AXWindows` with the application element itself, so the walk from the application only ever reached the menu bar (thousands of menu items) and never a table row.
- Fix: the check first asks whether the API lists a real window (`accessibilityShowsWindows`) and skips with an INFO line when it does not, as it already did without the permission.
- Rule: a self-test check that reads through a system service checks that the service can answer before it judges the app.

## Search's keys reached the wrong place in the self-test (S-017)

- Symptom: Return and ⌘Return in Search did nothing in the self-test, and a field focused right after it opened lost its first keystroke's text.
- Cause: three things. The field asked for focus before it was in a window (`field.window` was nil); the test sent keys through `NSApp.sendEvent`, which drops them when another app is frontmost (no key window); and ⌘Return never reaches the field editor's `doCommandBy`.
- Fix: the field takes focus in `viewDidMoveToWindow`; test keys go to the window (`window.sendEvent`, `window.performKeyEquivalent`); Apply as Filter is the footer button's `.keyboardShortcut(.return, modifiers: .command)`.
- Rule: an AppKit field focuses itself once it has a window, and window-level shortcuts live on a control, not in the field editor's command handler.

## Esc in a list did not hide its filter bar (S-014, found in S-018)

- Symptom: with the focus in the Logs list (or the new Traces list), Esc left the filter bar open; only Esc in "Body contains" hid it.
- Cause: the list used `.onExitCommand`, which SwiftUI never calls while its Table (an NSTableView) is the first responder.
- Fix: `.onKeyPress(.escape)` on the table hides the current bar and returns `.handled` only when a bar shows; the self-test now presses Esc with the list focused in both views.
- Rule: keys on a focused SwiftUI Table go through `.onKeyPress`, not `.onExitCommand`; test them with the table as first responder.

## The VoiceOver row check never saw the list's rows (S-004, found in S-018)

- Symptom: once the Accessibility permission was there, "VoiceOver reads the HTTP 500 row once" failed, listing only the sidebar's rows; the last checkpoint's build failed the same way.
- Cause: the check ran right after the sidebar reloaded the list, before SwiftUI's next update gave the NSTableView its rows, so the table had 0 rows to expose.
- Fix: the check waits until the table has as many rows as the model (`listScroller.rowCount`) before it reads the Accessibility tree.
- Rule: a self-test that reads a table through AppKit waits for the table to show the model's rows first.

## Test runs changed the real app's window and column layout (found in S-022)

- Symptom: a normal launch opened with the window 1,697 pt wide at (37, 153) and the columns where the last snapshot or self-test run left them, not at docs/ux.md's ideal widths.
- Cause: AppKit saves "NSWindow Frame main-AppWindow-1" and "NSSplitView Subview Frames …" in the app's own defaults domain by itself. The scripts' empty split-frames argument only changed what a run read at launch; every resize in a test run (and in the self-test's second Magnife) wrote the real domain.
- Fix: snapshot and self-test runs (`AppDefaults.isTestRun`) copy the layout keys into the `com.nasserfarhat.magnife.tests` suite in `applicationWillFinishLaunching`, before the window exists, and put them back exactly in `applicationWillTerminate`; a copy left by a crashed run is restored by the next test run. App-owned keys of test runs (saved filters) live in that suite too. The real app's layout keys were reset once (backup in the session scratchpad), so a normal launch opens at 1280 × 760 with the columns at 210 / 520 / the rest.
- Rule: a test run never writes the user's defaults domain; anything AppKit saves there by itself is copied aside at launch and restored at exit.

## A restarted helper went back to the launch retention (S-016, M2 review)

- Symptom: launched with 24 hours, set to 7 days in Settings; after a helper crash and restart, the helper pruned everything older than 24 hours within a minute. A change made while the helper was down was dropped without a word.
- Cause: `HelperSupervisor` kept the `HelperConfiguration` built at launch, with `--retention`, and reused it for every restart; the app sent `retention <s>` once with `try?`, which failed while the helper was down, and sent nothing on `.started(restart: true)`.
- Fix: `HelperSupervisor.setRetention(seconds:)` keeps the value for every later launch and writes `retention <s>` to a running helper; `AppModel.retentionSeconds` calls it. Unit test (FakeHelper echoes its argv after a SIGKILL restart) and a self-test check with the real helper (`meta.retention_s` after a kill -9 restart).
- Rule: state the app changes after launch never lives only in launch arguments; anything a restart must keep is owned by the supervisor.

## Services whose data was pruned stayed in the sidebar (S-015, M2 review)

- Symptom: a service that stopped sending more than the retention ago stayed in the sidebar with no count, selecting it showed "No Traces from X", and its old keys still came up as condition suggestions.
- Cause: the helper keeps a row per service and per key ever seen (the contract's meaning), and the reader listed every row.
- Fix: `servicesWithErrors` lists a service only while a span or log of it is stored; `attributeKeys(seenSinceNs:)` leaves out keys last seen before the retention's cutoff. Unit test `prunedServicesAndKeys`.
- Rule: a list read from a "ever seen" table filters by what is still stored.

## No view had the keyboard focus after Search or the Save Filter sheet (S-022, M2 end-to-end)

- Symptom: after Return opened a trace from Search, or after the Save Filter sheet closed, the arrow keys did nothing until Tab was pressed; the focused element was the window itself.
- Cause: Search's panel and the sheet held the focus; when they went away AppKit gave it back to the window, not to a column, and nothing asked for it.
- Fix: `openSearchResult` focuses the trace list after revealing the trace, and the sheet's `onDismiss` does the same once AppKit has ended the sheet, both only when nothing else has the focus. Self-test checks for both.
- Rule: anything that takes the focus and goes away (panel, sheet, popover) hands it to a column, or the keyboard user is stranded.

## Resume read every row of a long pause and could lose the selection (S-010, M2 review)

- Symptom: after a long pause under traffic, Resume read every trace that arrived (60,000 after 10 minutes at 100/s) into the list in one query and diff; and with traffic flowing, a refresh during Resume could put back a 200-row page, so a selected trace further down left the list and the list scrolled to the top.
- Cause: the Resume limit was `traces.count + newTraceCount` with no ceiling, even with nothing selected; the larger limit applied to the Resume read only, while `pausedSeq` was already nil and other refreshes read one page.
- Fix: `TraceList.resumeLimit(selectedRow:newCount:)` (unit-tested) reads down to the selected row plus a page, at most 5,000 rows, one page without a selection; `resumeRows` makes every page read until the reveal ends use it. The same for the Logs list.
- Rule: a read sized by "how much arrived" has a ceiling, and a one-off larger read holds until the step that needs it is finished.

## Pausing in the Traces view froze the Logs list at an old visit (S-010, M2 review)

- Symptom: Logs viewed at 09:00, Traces at 11:00, Pause, then Logs: the 09:00 rows with "Paused. 40,000 new logs."
- Cause: the Logs list is read only while it shows, but `logsLoaded` stayed true after leaving it, so `pauseLogs` paused at the old rows' newest id.
- Fix: pausing while Logs is not showing empties the Logs list and pauses at `reader.lastLogID()`.
- Rule: state that is only refreshed while visible is stale when hidden; never act on it from elsewhere.

## The trace list stayed blank after adding a condition row during a read (S-020, M2 review)

- Symptom: finish a value in row 1 (the list empties and reads), then press "+" or type a key in row 2 before the read ends: the list stayed blank, without even "No Matching Traces", until the next batch; with no traffic, for good.
- Cause: `TraceListState.applying` drops a read whose scope differs from the list's, comparing the whole `TraceFilter`, inactive condition rows included, while a new read starts only when the active conditions change.
- Fix: the list's scope is `traceFilter.normalized` (active conditions only), in `listState` and the next-page read.
- Rule: what decides whether a read is still wanted is the same value that decides whether to start one.

## Saving a filter changed what some conditions meant (S-021, M2 review)

- Symptom: a condition row `_dd.p.tid is abc` (or a key with `/`, a space, `"`, `=` or `~`) was saved as `_dd.p.tid=abc` and read back as "Any Field contains _dd.p.tid=abc"; since Save selects the new filter, the list changed meaning the moment it was saved, and after every relaunch.
- Cause: `TraceQuery.format` wrote keys unquoted, while the parser accepts a key only when it starts with a letter and holds letters, digits, `.`, `_` and `-`.
- Fix: odd keys are quoted when formatting, and a quoted key before an operator parses as an attribute; round-trip unit tests for 11 odd keys.
- Rule: a format/parse pair is tested on every value the editor accepts, not just the ones the parser was written for.

## Open Trace never worked from Trace Logs (S-012, M2 review)

- Symptom: Trace > Open Trace stayed disabled in the Traces view, and the Trace Logs row's context menu had only Copy Body and Copy Trace ID, while docs/ux.md lists Open Trace for both log lists.
- Cause: `updateLogMenu` set `canOpenTrace: false` for the Traces view, and the context menu was built without it.
- Fix: `canOpenSelectedTraceLogSpan` enables it while Trace Logs shows a log whose span is in the waterfall; `openSelectedLogTrace` then runs `openTraceLogSpan` (select and focus); the context menu shows the item for such logs.
- Rule: a story marked done checks every row of docs/ux.md's menu and context-menu tables for its surfaces.

## The filter chips could not be pressed with VoiceOver or System Events (S-018, S-014, M2 end-to-end)

- Symptom: AXPress (or a System Events click) on the Error, OK and Unset chips, and on the level chips, left them off; the status chips had no name and no actions.
- Cause: the status chip wrapped its Button in `.accessibilityElement(children: .ignore)`, a new element that has no press action, and both chips added `.isToggle`, which exposes a checkbox SwiftUI does not press.
- Fix: the label and value sit on the Button itself; no new element, no toggle trait.
- Rule: never wrap a Button in `.accessibilityElement(children: .ignore)` or retype it with traits; label the Button and give its state as the value.

## Overlapping test runs wrote their window layout into the user's settings (M2 end-to-end)

- Symptom: "a test run keeps the user's window layout aside" failed with "kept aside: []" while another agent's snapshot run was going, and the real domain was left with a test run's split widths; APP_STORE runs wrote window frames there too.
- Cause: one shared `layout.backup` key: the second run took the first run's backup for a crashed run's, restored and replaced it, and whichever run ended first removed the backup the other needed; APP_STORE runs did not protect the layout at all.
- Fix: a backup per process id, a live run's backup copied by a run that starts during it, dead runs' backups restored at launch, and APP_STORE runs included.
- Rule: anything a test run sets aside in a shared place is keyed by the run, and never assumes it is the only run.

## The menu bar extra kept SwiftUI updating the scene at 100% CPU (S-026)

- Symptom: with the first menu bar extra the app sat at 100% CPU with no window drawn and snapshot mode never started; `sample` showed `AppGraph.graphDidChange` and `makeMainMenu` in a loop.
- Cause: two feedback loops between the status item and the scene. (1) `.accessibilityLabel` on the label's `Image(nsImage:)` made every scene update touch the status button again. (2) In snapshot runs, `MenuBarExtra(isInserted:)` bound to `@AppStorage` was written back by SwiftUI from the status item's KVO state on each update, and that write updated the scene again.
- Fix: the label is a cached, prerendered bitmap per count (`MenuBarGlyph.image(count:)`) whose `accessibilityDescription` carries the VoiceOver words; `isInserted` reads the setting in the scene's body (so the scene follows it) and never writes SwiftUI's reports back into it (only the Settings toggle changes it).
- Rule: a `MenuBarExtra` label is a plain value that only changes with the model (same NSImage object for the same state, no view modifiers on it), and a binding passed to the scene is never written back by the system into state the scene reads.

## "reentrant operation in its NSTableView delegate" from the live lists (S-030)

- Symptom: AppKit's warning "Application performed a reentrant operation in its NSTableView delegate" in most self-test runs (11 in one run), when the trace list or the Logs list jumped by hundreds of rows, emptied for a new scope, or read its next page; nothing visible went wrong.
- Cause: both lists were SwiftUI `Table`s. SwiftUI diffs a Table's rows inside its own graph update, and AppKit can start that update while the table is inside one of its delegate callbacks (a row view being made during layout runs the window's SwiftUI graph, which then inserts rows into the same table). No code of ours ran in between, so emptying the list first, animations off and two-step updates only made it rarer.
- Fix: the trace list and the Logs list are NSTableViews (`LiveTable.swift`, `TraceTable.swift`, `LogTable.swift`): rows go in only from `updateNSView`, as one `RowUpdate` (MagnifeKit, unit-tested), never inside a table callback (`callbackDepth` defers it), paced to one insert per 250 ms; cells are AppKit views or hosting views given values. `tools/selftest.sh` now fails a run that prints the warning.
- Rule: a list that changes while people use it is an AppKit table fed from outside its callbacks; its cells never read the model or run the window's SwiftUI graph.

## Main-thread "stalls" that were App Nap (S-030)

- Symptom: timing checks failed in full runs and passed alone; the load check saw 300-800 ms stalls while `sample` showed the main thread idle 90% of the time.
- Cause: behind other windows macOS puts the self-test's app in App Nap and defers its timers by hundreds of milliseconds; every heartbeat (`Task.sleep(5 ms)`) measured that delay as a stall.
- Fix: the self-test holds a `.userInitiated, .latencyCritical` activity (`ProcessInfo.beginActivity`) for its whole run; the load check's worst stall dropped from 300-800 ms to 86-101 ms.
- Rule: a run that measures timing turns App Nap off; a heartbeat gap with an idle main thread in `sample` is the scheduler, not the app.

## Hiding the focused table looped forever (S-030)

- Symptom: with both lists kept in the window, switching to Logs pinned the main thread at 100% for minutes.
- Cause: `scrollView.isHidden = true` on the table that was first responder made AppKit ask for the next valid key view, and SwiftUI's focus bridge kept answering with views it could not focus.
- Fix: the column out of sight is only transparent, not hit-testable, disabled and hidden from VoiceOver (`shownWhen`); its AppKit views are never `isHidden`.
- Rule: never hide an AppKit view inside SwiftUI while it may hold the focus; move the focus first, or keep it shown.

## reloadData(forRowIndexes:) took seconds after scrolling through thousands of rows (S-030)

- Symptom: under load, after the list had been scrolled to its end, each refresh stalled the main thread for up to seconds.
- Cause: `reloadData(forRowIndexes:columnIndexes:)` walks every row view the table keeps and rebuilds the key view loop for each (`_updateKeyViewLoopForRowView`), and adding row views with Auto Layout constraints went through the window's layout engine.
- Fix: rows on screen are filled in place (`view(atColumn:row:makeIfNecessary: false)` then `fill`), and cells lay out with frames, not constraints.
- Rule: refresh a visible cell by refilling it; keep table cells off Auto Layout when rows come and go many times a second.

## The main window did not open at launch (S-030)

- Symptom: launches of the signed build, test runs included, showed no main window (only the status item); the same build re-signed ad hoc opened it. Snapshots and self-tests waited forever.
- Cause: not found: SwiftUI decided not to open the WindowGroup's window (no saved state; `~/Library/Saved Application State` itself had gone missing at the time).
- Fix: `MainWindow.openAtLaunch()` opens the window when none showed up within a second of launch (S-029: a launch always shows the window).
- Rule: a launch that must show a window checks that it did.

## Finding words and several service colors were unreadable on a light background (S-031)

- Symptom: in light mode the orange finding words ("Slow SQL", "N+1", "HTTP Error") measured 2.3:1 against the white list, the red "Error" word 3.6:1, and the green, teal, mint, cyan and yellow service dots and bars about 2:1 (1.4:1 for yellow), under docs/ux.md's 4.5:1 for text and 3:1 for bars. Dark mode passed except red text on the sidebar (3.5:1).
- Cause: views used the system's `.red`, `.orange`, `.systemRed` and the ten system colors as they are. Those are tuned as fills for dark mode and for large shapes, not as text or thin bars on white.
- Fix: one palette in MagnifeKit (`ColorPalette`: each color in light, dark and both Increase Contrast variants, the system color where it passes, else the same hue darkened or lightened until it does), unit-tested against the window's measured backgrounds (`ColorPaletteTests`) and resolved in each appearance by the self-test (`checkAppearance`). Views take `ServicePalette` / `StatusColors`; `tools/color-lint.sh` (run by `selftest.sh`) fails on a named or numeric color in a view.
- Rule: never put a system color name or a hex value in a view; every color comes from the contrast-tested palette, and a new color gets its light, dark and Increase Contrast values with a test.


## The findings-wide snapshot showed no badge words, and findings could name spans the waterfall lacked (M3 review, S-023 to S-025)

- Symptom: `02-trace-list-findings-wide` looked exactly like `02-trace-list` (icons only); under load an open trace's strip line could point at a span missing from its tree, so clicking it did nothing.
- Cause: since S-030 the Route column takes the width the other columns leave (`LiveTable.fitColumns`), so the snapshot's `route.width = 300` was undone on the next tile; and the waterfall read the trace, its spans and its findings in three separate reads, each its own WAL snapshot, while the helper kept writing.
- Fix: the snapshot drags the column split instead; `TelemetryReader.openTrace` reads all three in one `pool.read` and runs the detectors after it.
- Rule: values shown together are read in one `pool.read`; a snapshot that sets a size checks the size it got.

## The menu bar icon turned red again for a trace that had already failed (M3 review, S-026)

- Symptom: a trace whose child span failed made the icon read "1"; after opening the menu, its healthy root span arrived in the next batch and the icon read "1" again for the same failure. Notifications, which use the batch lines' `error_traces`, fired once.
- Cause: the count was `COUNT(*) FROM traces WHERE status = 2 AND updated_seq > mark`, and `updated_seq` is the last batch that touched the row, not the one that made it fail.
- Fix: the count is the set of `error_traces` ids since the menu opened (`RecentErrors.failed`, `AppModel.noteFailedTraces`).
- Rule: count "new" things from the event that made them so (the batch line's `error_traces`), never from a column every later write moves.

## One stored flag paced overlapping refreshes wrongly (M3 review, S-026, S-030)

- Symptom: a menu opening or sidebar change during a batch refresh could be paced like a batch (the icon stayed red up to a second), or a batch refresh lost its pacing half-way.
- Cause: `isBatchRefresh` was one stored Bool set and cleared (`defer`) by each async `reload`; two reloads interleave at their awaits.
- Fix: `RefreshPacing.isBatch`, a `@TaskLocal` set with `withValue` for one reload and inherited by its tasks.
- Rule: per-operation context in async code is a task-local or a parameter, never a stored flag.
