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
        await checkSlowerThan(model, window: window, all: all)
        await checkConditions(model, window: window, all: all)
    }

    /// S-020: a condition row typed in the real fields, its key completed from
    /// the attributes the helper received.
    private static func checkConditions(_ model: AppModel, window: NSWindow, all: Int) async {
        await ensureKey(window)
        model.applyTraceFilter(.cleared)
        model.showsTraceFilterBar = true
        try? await Task.sleep(for: .milliseconds(300))
        check("the bar opens with one empty condition row", model.conditionRows.count == 1 && model.conditionRows[0].key.isEmpty)
        guard let keyField = field(placeholder: "Attribute", in: window) else {
            return check("the condition's key field is in the bar", false)
        }
        window.makeFirstResponder(keyField)
        for character in "http.ro" { pressKey(window, String(character), keyCode: 0) }
        let suggested = await waitUntil(2) { model.conditionSuggestions.contains { $0.title == "http.route — span" } }
        check("typing a key lists the received keys that match, with their source", suggested
              && model.conditionSuggestions.first?.key == "http.route", "\(model.conditionSuggestions.map(\.title))")
        pressKey(window, "\r", keyCode: 36)
        check("Return picks the suggestion", model.conditionRows[0].key == "http.route" && model.conditionSuggestions.isEmpty)
        guard let valueField = field(placeholder: "Value", in: window) else {
            return check("the condition's value field is in the bar", false)
        }
        window.makeFirstResponder(valueField)
        for character in "/checkout/pay" { pressKey(window, String(character), keyCode: 0) }
        let filtered = await waitUntil(2) { !model.isLoadingScope && model.traceConditions.contains { $0.isActive } && model.traces.count == 1 }
        check("http.route is /checkout/pay keeps the trace whose root span has it, 100 ms after the last key",
              filtered && model.traces.first?.route == "POST /checkout/pay" && model.subtitle == TraceList.subtitle(shown: 1, of: all),
              "\(model.traces.map(\.route)) \(model.subtitle)")

        // A second row matched by other spans of the same trace: all rows must match.
        model.addConditionRow(after: model.conditionRows[0].id)
        model.updateConditionRow(model.conditionRows[1].id) { $0.key = "db.system.name"; $0.op = .exists }
        let both = await waitUntil(2) { !model.isLoadingScope && model.traceConditions.filter(\.isActive).count == 2 }
        check("a second row on other spans of the trace: both must match", both && model.traces.map(\.route) == ["POST /checkout/pay"])
        model.updateConditionRow(model.conditionRows[1].id) { $0.key = "host.name"; $0.op = .is; $0.value = "nowhere" }
        let none = await waitUntil(2) { !model.isLoadingScope && model.traces.isEmpty && model.traceConditions.count == 2 }
        check("a resource attribute that no trace has leaves none", none && model.traceFilter.narrowsScope)
        model.updateConditionRow(model.conditionRows[1].id) { $0.key = "never.received"; $0.op = .exists }
        let unknown = await waitUntil(2) { !model.isLoadingScope && model.traces.isEmpty }
        check("a key never received still filters (nothing has it)", unknown)

        for _ in 0..<12 { model.addConditionRow(after: model.conditionRows[0].id) }
        check("at most 10 rows", model.conditionRows.count == ConditionDraft.limit)
        for row in model.conditionRows.dropFirst() { model.removeConditionRow(row.id) }
        model.removeConditionRow(model.conditionRows[0].id)
        let cleared = await waitUntil(2) { !model.isLoadingScope && model.traces.count == all }
        check("\"−\" on the only row clears it", cleared && model.conditionRows.count == 1 && model.conditionRows[0].key.isEmpty
              && !model.hasTraceBarFilters)
        model.hideTraceFilterBar()
        model.applyTraceFilter(.cleared)
        await model.reload()
    }

    /// An AppKit text field of the window by its placeholder.
    static func field(placeholder: String, in window: NSWindow) -> NSTextField? {
        func find(_ view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.placeholderString == placeholder || field.placeholderAttributedString?.string == placeholder {
                return field
            }
            for subview in view.subviews { if let found = find(subview) { return found } }
            return nil
        }
        return window.contentView.flatMap(find)
    }

    /// S-019: typing in "Slower than" moves the list 100 ms after the last key.
    private static func checkSlowerThan(_ model: AppModel, window: NSWindow, all: Int) async {
        await ensureKey(window)
        model.hideTraceFilterBar()
        model.toggleFilterBar(focusField: true)
        let focused = await waitUntil(2) { window.firstResponder is NSTextView }
        check("⌘F shows the bar with \"Slower than\" focused", focused && model.showsTraceFilterBar,
              String(describing: window.firstResponder.map { type(of: $0) }))
        let started = ContinuousClock.now
        for character in "800" { pressKey(window, String(character), keyCode: 0) }
        let slow = await waitUntil(2) { model.traceSlowerThanNs == 800_000_000 && !model.isLoadingScope }
        let elapsed = (ContinuousClock.now - started) / .milliseconds(1)
        check("typing 800 keeps the traces slower than 800 ms, a moment after the last key (\(Int(elapsed)) ms)",
              slow && model.traces.map(\.route).sorted() == ["GET /admin/reports", "inventory.reconcile"]
                && model.traces.allSatisfy { $0.durationNs > 800_000_000 }, "\(model.traces.map(\.route))")
        pressKey(window, "x", keyCode: 0)
        try? await Task.sleep(for: .milliseconds(300))
        check("text that is no duration is flagged and the last rule stays",
              model.traceSlowerThanText == "800x" && !model.slowerThanIsValid && model.traceSlowerThanNs == 800_000_000
                && model.traces.count == 2)
        for _ in 0..<4 { pressKey(window, "\u{7f}", keyCode: 51) }
        let cleared = await waitUntil(2) { model.traceSlowerThanNs == nil && !model.isLoadingScope && model.traces.count == all }
        check("clearing the field removes the rule", cleared && model.traceSlowerThanText.isEmpty && !model.hasTraceBarFilters)
        for character in ">1.5s" { pressKey(window, String(character), keyCode: 0) }
        _ = await waitUntil(2) { model.traceSlowerThanNs == 1_500_000_000 }
        window.makeFirstResponder(model.listScroller.tableView)
        let normalized = await waitUntil(1) { model.traceSlowerThanText == "1.5 s" }
        _ = await waitUntil(2) { !model.isLoadingScope && model.traces.count == 1 }
        check("focus leaving the field writes it normalized, \"1.5 s\"", normalized && model.traceSlowerThanNs == 1_500_000_000
              && model.traces.map(\.route) == ["inventory.reconcile"], model.traceSlowerThanText)
        check("the subtitle counts what the rule keeps", model.subtitle == TraceList.subtitle(shown: 1, of: all), model.subtitle)
        model.clearTraceFilters(undoManager: nil)
        model.hideTraceFilterBar()
        await model.reload()
        check("Clear Filters empties \"Slower than\"", model.traceSlowerThanText.isEmpty && model.traceSlowerThanNs == nil)
    }
}
