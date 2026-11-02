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
        traceSlowerThanNs = filter.slowerThanNs
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

    /// View > Clear Filters: the current view's.
    func clearFilters(undoManager: UndoManager?) {
        switch contentMode {
        case .traces: clearTraceFilters(undoManager: undoManager)
        case .logs: clearLogFilters(undoManager: undoManager)
        }
    }
}
