import AppKit
import MagnifeKit

/// The menu bar extra (S-026, S-027): Recent Errors and the icon's count,
/// read with every refresh (paused too), and the path a Recent Errors item
/// takes into the main window.
extension AppModel {
    /// Reads the newest traces with an error, off the main actor. A failed
    /// read keeps what the menu shows.
    func refreshRecentErrors(_ reader: TelemetryReader) async {
        guard let traces = try? await reader.recentErrors(), self.reader === reader else { return }
        recentErrors.apply(traces)
    }

    /// A batch line's traces whose status became Error (paused too): the
    /// icon's count. Paced like a batch refresh: at most once a second.
    func noteFailedTraces(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        RefreshPacing.$isBatch.withValue(true) { recentErrors.failed(ids) }
    }

    /// Copies what the menu and the icon show, only when it changed: each
    /// change rebuilds the scene's menus.
    /// Under a flood, at most once a second: each change also redraws the
    /// status item (S-030, PROGRESS S-026 note).
    func publishRecentErrors() {
        let now = ProcessInfo.processInfo.systemUptime
        let delay = isBatchRefresh ? recentErrorsThrottle.delay(at: now) : 0
        guard delay == 0 else {
            guard recentErrorsTask == nil else { return }
            recentErrorsTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard let self else { return }
                self.recentErrorsTask = nil
                self.publishRecentErrors()
            }
            return
        }
        let listChanged = !RecentErrors.showSame(recentErrors.traces, recentErrorTraces)
        let changed = listChanged || newErrorCount != recentErrors.newCount
        if listChanged {
            // While the menu is closed its times count from now, so the first
            // frame of the next opening never reads a newer trace as "Just now"
            // (M3 review 12); opening fixes them at that moment.
            if !MenuBarTracking.isOpen { recentErrorsOpenedAt = Date() }
            recentErrorTraces = recentErrors.traces
        }
        if newErrorCount != recentErrors.newCount { newErrorCount = recentErrors.newCount }
        if changed { recentErrorsThrottle.fired(at: now) }
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
        // A click that launched Magnife comes before the first read: the
        // last quit's selection must not replace this trace (M3 review 2).
        launchSelection = nil
        closeSearch()
        showContentMode(.traces)
        if selectedTraceID == traceID, !waterfall.isEmpty {
            showFirstErrorSpan()
        } else if selectedTraceID == traceID {
            // Selected, but its read failed (and a paused list reads no
            // more): open it again rather than wait (M3 review 9).
            pendingFailedTrace = traceID
            openSelectedTrace()
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
