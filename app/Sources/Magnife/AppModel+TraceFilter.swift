import AppKit
import MagnifeKit

/// The trace list's filters (S-017 to S-020): the sidebar's service plus
/// status chips, "Slower than" and condition rows, as one TraceFilter that
/// the reader turns into SQL. Search's Apply as Filter sets them all at
/// once; Clear Filters resets them and is undoable.
extension AppModel {
    /// What the trace list shows: the sidebar's scope and the filter bar's filters.
    var traceFilter: TraceFilter {
        TraceFilter(service: sidebar?.serviceName, statuses: traceStatuses, slowerThanNs: traceSlowerThanNs,
                    conditions: traceConditions)
    }

    /// A filter changed: the list starts empty and is read again (as a scope change).
    func traceFilterChanged() {
        resetTraceList()
        updateFilterMenu()
        refreshNow()
    }

    /// The filter bar's own filters are on: the Filter button is filled.
    var hasTraceBarFilters: Bool { traceFilter.narrowsScope }

    /// Clear Filters has something to clear: a filter or a service.
    var hasTraceFilters: Bool { traceFilter.isActive }

    /// Sets every filter at once (Search's Apply as Filter, a saved filter):
    /// the sidebar takes the service, the bar the rest.
    func applyTraceFilter(_ filter: TraceFilter) {
        traceStatuses = filter.statuses
        slowerThanTask?.cancel()
        traceSlowerThanNs = filter.slowerThanNs
        traceSlowerThanText = filter.slowerThanNs.map(DurationInput.normalized) ?? ""
        traceConditions = filter.conditions
        sidebar = filter.service.map { .service($0) } ?? .allTraces
    }

    /// Clear Filters in the Traces view: every status, any duration, no
    /// condition, All Services. Undo ("Undo Clear Filters") puts them back.
    func clearTraceFilters(undoManager: UndoManager?) {
        let before = traceFilter
        guard before.isActive else { return }
        applyTraceFilter(.cleared)
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.restoreTraceFilter(before, undoManager: undoManager) }
        }
        undoManager?.setActionName("Clear Filters")
    }

    private func restoreTraceFilter(_ filter: TraceFilter, undoManager: UndoManager?) {
        applyTraceFilter(filter)
        // Redo clears them again.
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.clearTraceFilters(undoManager: undoManager) }
        }
        undoManager?.setActionName("Clear Filters")
    }

    /// "Slower than": the list follows 100 ms after the last key (docs/ux.md,
    /// S-019). An empty field removes the rule; text that does not parse
    /// leaves the last valid rule on and the field says so.
    func applySlowerThanText() {
        slowerThanTask?.cancel()
        let text = traceSlowerThanText
        slowerThanTask = Task { [weak self] in
            try? await Task.sleep(for: Self.slowerThanDelay)
            guard let self, !Task.isCancelled, self.traceSlowerThanText == text else { return }
            if text.trimmingCharacters(in: .whitespaces).isEmpty {
                self.traceSlowerThanNs = nil
            } else if let ns = DurationInput.parse(text) {
                self.traceSlowerThanNs = ns
            }
        }
    }

    static let slowerThanDelay: Duration = .milliseconds(100)

    /// The typed text is a duration, or empty.
    var slowerThanIsValid: Bool {
        traceSlowerThanText.trimmingCharacters(in: .whitespaces).isEmpty || DurationInput.parse(traceSlowerThanText) != nil
    }

    /// Focus left the field: a valid value reads normalized ("1.5 s").
    func normalizeSlowerThanText() {
        guard let ns = DurationInput.parse(traceSlowerThanText) else { return }
        let normalized = DurationInput.normalized(ns)
        if traceSlowerThanText != normalized {
            // The same rule: setting the text must not wait to apply it again.
            traceSlowerThanText = normalized
            slowerThanTask?.cancel()
            traceSlowerThanNs = ns
        }
    }

    /// A status chip: a click shows only that status, ⌘-click or Space adds or removes it.
    func clickStatusChip(_ status: SpanStatus, adding: Bool) {
        let next = traceFilter.clicking(status, adding: adding).statuses
        if traceStatuses != next { traceStatuses = next }
    }

    /// The current view's filter bar shows.
    var showsFilterBar: Bool { contentMode == .traces ? showsTraceFilterBar : showsLogFilterBar }

    /// View > Show Filter Bar (⌘F) and the Filter button, for the current
    /// view. Shown from the menu, the bar's first field takes the focus.
    func toggleFilterBar(focusField: Bool = false) {
        switch contentMode {
        case .traces:
            showsTraceFilterBar.toggle()
            if showsTraceFilterBar && focusField { focusesTraceFilterField = true }
        case .logs:
            toggleLogFilterBar(focusField: focusField)
        }
    }

    /// Esc and the bar's close button: the bar hides, the filters stay on.
    func hideTraceFilterBar() {
        if showsTraceFilterBar { showsTraceFilterBar = false }
    }

    /// View > Clear Filters: the current view's.
    func clearFilters(undoManager: UndoManager?) {
        switch contentMode {
        case .traces: clearTraceFilters(undoManager: undoManager)
        case .logs: clearLogFilters(undoManager: undoManager)
        }
    }
}
