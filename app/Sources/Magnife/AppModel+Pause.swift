import AppKit
import MagnifeKit
import SwiftUI

/// Pause and Resume (S-010): the list and the open waterfall hold still while
/// the helper keeps receiving; a bar counts the traces created since the
/// pause; Resume inserts them and keeps the selected trace selected and in view.
extension AppModel {
    var isPaused: Bool { pausedSeq != nil }

    /// The toolbar button, Trace > Pause / Resume and ⌃⌘P.
    func togglePause() {
        isPaused ? resume() : pause()
    }

    /// Holds the list at the seq its rows were read at: every trace created
    /// after it is counted, nothing is inserted or updated.
    func pause() {
        guard !isPaused else { return }
        pausedSeq = listState.paused().pausedSeq
        pauseLogs()
        AccessibilityNotification.Announcement("Paused").post()
    }

    /// Inserts what arrived while paused, reading down to the selected trace
    /// (at most `TraceList.resumeMaxRows` rows; one page with no selection),
    /// then brings it into view. A trace deeper than that stays selected and
    /// open in the detail column, and the list shows its newest page.
    func resume() {
        guard isPaused else { return }
        let selectedRow = selectedTraceID.flatMap { id in traces.firstIndex { $0.id == id } }
        let limit = TraceList.resumeLimit(selectedRow: selectedRow, newCount: newTraceCount)
        // Refreshes before the reveal read as many rows, so a one-page read cannot drop the selection.
        resumeRows = limit
        pausedSeq = nil
        // Resume inserts even when scrolled away; the reveal below decides
        // whether the list then holds still where the selection is.
        isListHeld = false
        AccessibilityNotification.Announcement("Resumed").post()
        Task {
            defer { if resumeRows == limit { resumeRows = nil } }
            guard let reader else { return }
            do {
                try await reloadList(reader)
                try await refreshOpenTrace(reader)
                try await refreshOpenTraceLogs(reader)
            } catch {
                FileHandle.standardError.write(Data("magnife: read failed: \(error)\n".utf8))
            }
            if contentMode == .logs {
                await resumeLogs()
            } else {
                logPausedID = nil
                isLogListHeld = false
                await revealSelectedTrace()
            }
        }
    }

    /// Scrolls the selected trace into view once the table shows the new
    /// rows, or to the top when nothing is selected.
    func revealSelectedTrace() async {
        let away = await listScroller.reveal(row: { selectedTraceID.flatMap { id in traces.firstIndex { $0.id == id } } },
                                             once: { traces.count })
        listScrolled(awayFromTop: away)
    }

    /// Snapshot pages show the bar without waiting for traces to arrive.
    func pauseForSnapshot(newTraces: Int?) {
        if let newTraces {
            pausedSeq = listBaseSeq
            newTraceCount = newTraces
        } else {
            pausedSeq = nil
            newTraceCount = 0
        }
        logPausedID = newTraces == nil ? nil : logBaseID
        if contentMode == .logs { newLogCount = newTraces ?? 0 }
    }
}
