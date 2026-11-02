import AppKit
import MagnifeKit

/// The menu bar extra (S-026, S-027): Recent Errors and the icon's count,
/// read with every refresh (paused too), and the path a Recent Errors item
/// takes into the main window.
extension AppModel {
    /// Reads the newest traces with an error and the count since the mark,
    /// off the main actor. A failed read keeps what the menu shows.
    func refreshRecentErrors(_ reader: TelemetryReader) async {
        guard let page = try? await reader.recentErrors(changedAfter: recentErrors.mark),
              self.reader === reader else { return }
        recentErrors.apply(page)
    }

    /// Copies what the menu and the icon show, only when it changed: each
    /// change rebuilds the scene's menus.
    func publishRecentErrors() {
        if !RecentErrors.showSame(recentErrors.traces, recentErrorTraces) { recentErrorTraces = recentErrors.traces }
        if newErrorCount != recentErrors.newCount { newErrorCount = recentErrors.newCount }
    }

    /// The menu opened: the count and the red icon reset, and the items'
    /// times are fixed at this moment.
    func recentErrorsMenuOpened() {
        recentErrorsOpenedAt = Date()
        recentErrors.opened()
    }

    /// A Recent Errors item (S-027): the Traces view with the trace in the
    /// detail column, its earliest-starting Error span selected, the span
    /// detail on Span, and the focus in the waterfall. The list selects the
    /// trace when its scope, filters and pause show it; a trace pruned since
    /// shows "Trace No Longer Stored". The caller brings the window forward.
    func openFailedTrace(_ traceID: String) {
        closeSearch()
        showContentMode(.traces)
        if selectedTraceID == traceID, !waterfall.isEmpty {
            showFirstErrorSpan()
        } else {
            pendingFailedTrace = traceID
            selectedTraceID = traceID
        }
        Task { await revealSelectedTrace() }
    }

    /// Selects the open trace's earliest Error span (its root when it has
    /// none), with its parents open, shows the span detail on Span, and
    /// moves the focus into the waterfall once the outline shows the row.
    func showFirstErrorSpan() {
        guard let spanID = waterfall.firstErrorSpanID ?? waterfall.rootSpanID else { return }
        selectSpanOpeningParents(spanID)
        showSpanDetailTab(.span)
        let id = selectedTraceID
        Task {
            // A window that was closed is still being built: wait for its outline.
            for _ in 0..<50 where waterfallOutline?.window?.isVisible != true || shownWaterfallGeneration != waterfallGeneration {
                try? await Task.sleep(for: .milliseconds(20))
            }
            guard selectedTraceID == id, selectedSpanID == spanID else { return }
            try? await Task.sleep(for: .milliseconds(10))
            focus(.waterfall)
        }
    }
}
