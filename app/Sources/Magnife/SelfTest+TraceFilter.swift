import AppKit
import MagnifeKit

/// S-018 to S-020: the Traces filter bar in the real window, on the seed set
/// the helper wrote (two traces with errors, three Unset, none OK).
extension SelfTest {
    static func checkTraceFilters(_ model: AppModel) async {
        guard let reader = model.reader,
              let window = NSApp.windows.first(where: { $0.canBecomeMain && !$0.isSheet }) else {
            return check("the window is open for the filter bar", false)
        }
        model.selectedTraceID = nil
        model.applyTraceFilter(.cleared)
        model.showContentMode(.traces)
        await model.reload()
        let all = model.traces.count
        check("Show Filter Bar is offered in the Traces view", MenuState.shared.filterBar == .hidden)
        model.toggleFilterBar(focusField: true)
        check("⌘F shows the Traces filter bar", model.showsTraceFilterBar && MenuState.shared.filterBar == .shown)

        // Error: traces with an Error span anywhere, as the helper computed them.
        model.clickStatusChip(.error, adding: false)
        await model.reload()
        let errors = try? await reader.tracePage(filter: TraceFilter(statuses: [.error]))
        check("Error shows only traces with an Error span",
              model.traces.map(\.route).sorted() == ["POST /checkout/pay", "inventory.reconcile"]
                && model.traces.allSatisfy { $0.status == .error } && model.listTraceCount == errors?.traceCount,
              "\(model.traces.map(\.route))")
        check("the subtitle reads \"2 of 5 traces\" and the Filter button is filled",
              model.subtitle == TraceList.subtitle(shown: 2, of: all) && model.hasTraceBarFilters && MenuState.shared.hasFilters,
              model.subtitle)

        model.clickStatusChip(.unset, adding: true)
        await model.reload()
        check("⌘-click adds Unset", model.traceStatuses == [.error, .unset] && model.traces.count == all)
        model.sidebar = .service("orders")
        await model.reload()
        check("the Service pop-up and the sidebar are one setting, and the chips stay",
              model.title == "orders" && model.traceStatuses == [.error, .unset] && model.traces.count == 3
                && model.subtitle == TraceList.subtitle(shown: 3, of: 3), model.subtitle)
        model.sidebar = .allTraces

        // A selected trace hidden by a filter stays in the detail column.
        model.clickStatusChip(.error, adding: false)
        await model.reload()
        let failed = model.traces.first { $0.route == "POST /checkout/pay" }
        model.selectedTraceID = failed?.traceID
        _ = await waitUntil(3) { !model.waterfall.isEmpty }
        model.clickStatusChip(.ok, adding: false)
        await model.reload()
        try? await Task.sleep(for: .milliseconds(300))
        check("OK, which no seed trace is, reads \"No Matching Traces\"",
              model.traces.isEmpty && model.traceFilter.narrowsScope && !model.isLoadingScope
                && model.subtitle == TraceList.subtitle(shown: 0, of: all), model.subtitle)
        check("the selected trace stays in the detail column while the filter hides it",
              model.selectedTraceID == failed?.traceID && model.openTrace?.traceID == failed?.traceID && !model.waterfall.isEmpty)

        // Esc in the list hides the bar; the filters stay on.
        // The list's own table (the waterfall and Trace Logs have theirs).
        window.makeFirstResponder(model.listScroller.tableView)
        pressKey(window, "\u{1b}", keyCode: 53)
        let hidden = await waitUntil(1) { !model.showsTraceFilterBar }
        check("Esc hides the filter bar and the filters stay on",
              hidden && model.traceStatuses == [.ok] && model.hasTraceBarFilters && MenuState.shared.filterBar == .hidden)

        let undoManager = window.undoManager
        model.clearFilters(undoManager: undoManager)
        await model.reload()
        check("Clear Filters shows every trace again", model.traceStatuses.isEmpty && model.traces.count == all
              && model.subtitle == TraceList.subtitle(traceCount: all) && !MenuState.shared.hasFilters, model.subtitle)
        check("Edit > Undo reads \"Undo Clear Filters\"", undoManager?.undoMenuItemTitle == "Undo Clear Filters",
              undoManager?.undoMenuItemTitle ?? "no undo manager")
        undoManager?.undo()
        await model.reload()
        check("Undo puts the status back", model.traceStatuses == [.ok] && model.traces.isEmpty)
        model.clearTraceFilters(undoManager: nil)
        model.selectedTraceID = nil
        await model.reload()
    }
}
