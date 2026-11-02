import AppKit
import MagnifeKit

/// Launch (S-029, docs/ux.md App-wide states): the window opens as it was
/// left, with the scope, filters and selected trace of the last quit, and
/// the rows come from the database at once, with no spinner. The scope and
/// filters are set before the store opens, so the first read is already the
/// right one; the selection waits for that read; the focus then goes to the
/// list. Snapshot and self-test runs restore nothing.
extension AppModel {
    /// What the next launch restores.
    var launchState: LaunchState {
        let scope: LaunchState.Scope = switch sidebar {
        case .service(let name): .service(name)
        case .savedFilter(let id): .savedFilter(id)
        case .allTraces, nil: .allServices
        }
        return LaunchState(scope: scope, traceQuery: TraceQuery.format(traceFilter),
                           showsTraceFilterBar: showsTraceFilterBar, logLevels: logLevels.map(\.rawValue).sorted(),
                           logBody: logBodyFilter, showsLogFilterBar: showsLogFilterBar,
                           selectedTraceID: prunedTraceID == nil ? selectedTraceID : nil)
    }

    /// At quit (AppDelegate.applicationWillTerminate).
    func keepLaunchState() {
        guard !AppDefaults.isTestRun else { return }
        launchState.store(in: AppDefaults.shared)
    }

    /// Before the store opens (AppModel.start): the scope and filters; the
    /// selected trace waits in `launchSelection` for the first read.
    func restoreLaunchState() {
        guard !AppDefaults.isTestRun, let stored = LaunchState.stored(in: AppDefaults.shared) else { return }
        let state = stored.resolved(savedFilters: savedFilters)
        let filter = state.traceFilter
        holdsFilterChanges = true
        switch state.scope {
        case .allServices: sidebar = .allTraces
        case .service(let name): sidebar = .service(name)
        case .savedFilter(let id): sidebar = .savedFilter(id)
        }
        // A saved filter's own filters came with it; its edits come from the query.
        setBarFilters(filter)
        if sidebar?.savedFilterID != nil { savedFilterService = filter.service }
        logLevels = state.levels
        logBodyTask?.cancel()
        logBodyText = state.logBody
        logBodyTask?.cancel()
        logBodyFilter = state.logBody
        holdsFilterChanges = false
        showsTraceFilterBar = state.showsTraceFilterBar
        showsLogFilterBar = state.showsLogFilterBar
        // Restoring is not a change people made: no read for each step, one when the store opens.
        resetTraceList()
        resetLogList()
        launchSelection = state.selectedTraceID
    }

    /// After the first read: the selected trace (S-015's state when it was
    /// pruned meanwhile), shown in the list when it is on the first page,
    /// and the keyboard focus in the list once its table is in the window.
    func finishLaunch() {
        if let id = launchSelection {
            launchSelection = nil
            selectedTraceID = id
        }
        guard !AppDefaults.isTestRun else { return }
        Task {
            let rows = contentMode == .traces ? traces.count : logs.count
            let scroller = contentMode == .traces ? listScroller : logScroller
            let row = contentMode == .traces ? traces.firstIndex { $0.id == selectedTraceID } : nil
            _ = await scroller.reveal(row: { row }, once: { rows })
            focusListIfNothingFocused()
        }
    }
}
