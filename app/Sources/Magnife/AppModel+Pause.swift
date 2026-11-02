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
        AccessibilityNotification.Announcement("Paused").post()
    }

    /// Inserts what arrived while paused, reading enough rows that the
    /// selected trace stays in the list, then brings it into view.
    func resume() {
        guard isPaused else { return }
        let limit = max(TraceList.pageSize, traces.count + newTraceCount)
        pausedSeq = nil
        // Resume inserts even when scrolled away; the reveal below decides
        // whether the list then holds still where the selection is.
        isListHeld = false
        AccessibilityNotification.Announcement("Resumed").post()
        Task {
            guard let reader else { return }
            do {
                try await reloadList(reader, limit: limit)
                try await refreshOpenTrace(reader)
                try await refreshOpenTraceLogs(reader)
            } catch {
                FileHandle.standardError.write(Data("magnife: read failed: \(error)\n".utf8))
            }
            await revealSelectedTrace()
        }
    }

    /// Scrolls the selected trace into view once the table shows the new
    /// rows, or to the top when nothing is selected.
    func revealSelectedTrace() async {
        let scroller = listScroller
        for _ in 0..<50 where scroller.rowCount != traces.count {
            try? await Task.sleep(for: .milliseconds(20))
        }
        if let id = selectedTraceID, let row = traces.firstIndex(where: { $0.id == id }) {
            scroller.reveal(row: row)
        } else {
            scroller.scrollToTop()
        }
        listScrolled(awayFromTop: scroller.isAwayFromTop)
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
    }
}
