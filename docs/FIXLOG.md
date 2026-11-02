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
