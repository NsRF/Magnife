import AppKit
import MagnifeKit

/// S-021: saved filters on the seeded store. Save Filter… and its sheet,
/// "Edited" and ⌘S, Save Filter As…, selecting one brings it back, rename
/// in place (Return) and Delete Filter (⌘⌫ in the sidebar) with Undo, and
/// a relaunch reads them back. Test runs keep them in their own defaults
/// suite (AppDefaults), never in the user's.
extension SelfTest {
    static func checkSavedFilters(_ model: AppModel) async {
        guard let window = NSApp.windows.first(where: { $0.canBecomeMain && !$0.isSheet }) else {
            return check("the main window exists", false)
        }
        AppDefaults.resetTestSuite()
        model.savedFilters = SavedFilters()
        model.showContentMode(.traces)
        model.applyTraceFilter(.cleared)
        await model.reload()
        check("test runs keep saved filters in their own defaults suite",
              AppDefaults.shared !== UserDefaults.standard && !model.canSaveFilter && !MenuState.shared.savedFilters.canSave)

        // Save Filter…: the sheet with the query, an empty name disables Save.
        model.sidebar = .service("checkout-api")
        model.traceStatuses = [.error]
        await model.reload()
        check("Save Filter… is enabled once a filter is on", model.canSaveFilter && MenuState.shared.savedFilters.canSave
              && MenuState.shared.savedFilters.saveTitle == "Save Filter…")
        model.saveFilter()
        let sheet = await waitUntil(2) { window.attachedSheet != nil }
        check("Save Filter… opens the sheet with the query in it",
              sheet && model.saveFilterQuery == "service:checkout-api status:error" && model.saveFilterNameProblem == .empty,
              model.saveFilterQuery)
        model.saveFilterName = "Checkout errors"
        model.confirmSaveFilter()
        let closed = await waitUntil(2) { window.attachedSheet == nil }
        let listFocused = await waitUntil(2) { model.listScroller.tableView.map { window.firstResponder === $0 } ?? false }
        check("when the sheet closes, the trace list has the focus", listFocused, "\(String(describing: window.firstResponder))")
        await model.reload()
        guard let saved = model.savedFilters.items.first else { return check("the filter is saved", false) }
        check("Save adds it under Saved Filters, selected, and the title is its name",
              closed && model.savedFilters.items.count == 1 && model.sidebar == .savedFilter(saved.id)
                && model.title == "Checkout errors" && saved.query == "service:checkout-api status:error"
                && model.traces.count == 1 && model.traces.allSatisfy { $0.status == .error },
              "title \(model.title), \(model.traces.count) traces")

        // A second one with the same name is refused, ignoring case.
        model.sidebar = .allTraces
        model.traceStatuses = [.ok]
        model.saveFilter()
        model.saveFilterName = "checkout ERRORS"
        check("a duplicate name says so under the field",
              model.saveFilterNameProblem?.message == "A saved filter named “Checkout errors” already exists.")
        model.confirmSaveFilter()
        check("and Save does nothing", model.showsSaveFilterSheet && model.savedFilters.items.count == 1)
        model.cancelSaveFilter()
        _ = await waitUntil(2) { window.attachedSheet == nil }

        // Selecting it brings its scope and filters back, in the Traces view.
        model.applyTraceFilter(.cleared)
        model.showContentMode(.logs)
        model.sidebar = .savedFilter(saved.id)
        await model.reload()
        check("selecting it restores its scope and filters in the Traces view",
              model.contentMode == .traces && model.traceFilter == saved.filter && model.scopeService == "checkout-api"
                && model.traces.count == 1 && model.title == "Checkout errors" && !model.canSaveFilter,
              "\(TraceQuery.format(model.traceFilter))")

        // A change reads "Edited"; ⌘S keeps it.
        model.clickStatusChip(.ok, adding: true)
        check("a changed filter reads \"Checkout errors — Edited\" and Save Filter saves at once",
              model.title == "Checkout errors — Edited" && model.saveFilterTitle == "Save Filter"
                && MenuState.shared.savedFilters.saveTitle == "Save Filter", model.title)
        model.saveFilter()
        check("⌘S updates it", !model.showsSaveFilterSheet && model.title == "Checkout errors"
              && model.savedFilters[saved.id]?.query == "service:checkout-api status:error status:ok",
              model.savedFilters[saved.id]?.query ?? "none")
        model.clickStatusChip(.ok, adding: true)
        model.saveFilter()
        model.setScopeService("orders")
        check("the Service pop-up changes the saved filter's scope, which reads Edited",
              model.sidebar == .savedFilter(saved.id) && model.scopeService == "orders" && model.isSavedFilterEdited)

        // Save Filter As…: a new one from the edited filter.
        model.saveFilterAs()
        model.saveFilterName = "Orders errors"
        model.confirmSaveFilter()
        _ = await waitUntil(2) { window.attachedSheet == nil }
        let second = model.savedFilters.items.last
        check("Save Filter As… saves a new one and leaves the first as it was",
              model.savedFilters.items.map(\.name) == ["Checkout errors", "Orders errors"]
                && second?.query == "service:orders status:error" && model.sidebar == second.map { .savedFilter($0.id) }
                && model.savedFilters[saved.id]?.query == "service:checkout-api status:error")

        await checkRenameAndDelete(model, window: window, saved: saved)

        // A relaunch reads them back: a new model, and the defaults on disk (cfprefsd).
        let relaunched = AppModel(storeURL: model.storeURL)
        check("saved filters survive a relaunch", relaunched.savedFilters == model.savedFilters
              && relaunched.savedFilters.items.map(\.name) == ["Checkout errors", "Orders errors"])
        let defaults = URL(fileURLWithPath: "/usr/bin/defaults")
        let onDisk = await run(defaults, ["read", AppDefaults.testSuiteName, SavedFilters.defaultsKey])
        let real = await run(defaults, ["read", Bundle.main.bundleIdentifier ?? "com.nasserfarhat.magnife", SavedFilters.defaultsKey])
        check("they are on disk in the test suite, and the user's own defaults are untouched",
              onDisk.status == 0 && real.status != 0, "test \(onDisk.status), user \(real.status)")

        model.savedFilters = SavedFilters()
        model.applyTraceFilter(.cleared)
        AppDefaults.resetTestSuite()
        await model.reload()
    }

    /// Return renames in place, Esc cancels; ⌘⌫ deletes only from the
    /// sidebar; both undo with their names in the Edit menu.
    private static func checkRenameAndDelete(_ model: AppModel, window: NSWindow, saved: SavedFilter) async {
        let undo = UndoManager()
        model.sidebar = .savedFilter(saved.id)
        await ensureKey(window)
        let sidebar = sidebarTable(in: window, model: model)
        window.makeFirstResponder(sidebar)
        let focused = await waitUntil(2) { model.sidebarHasFocus }
        check("the sidebar reports its focus, and Delete Filter is enabled only then",
              focused && MenuState.shared.savedFilters.canDelete, "first responder \(String(describing: window.firstResponder))")
        pressKey(window, "\r", keyCode: 36)
        let renaming = await waitUntil(2) { model.renamingFilterID == saved.id }
        check("Return on a saved filter edits its name in place", renaming)
        let field = await waitUntil(2) { window.firstResponder is NSTextView }
        pressKey(window, "\u{1b}", keyCode: 53)
        let cancelled = await waitUntil(2) { model.renamingFilterID == nil }
        check("Esc cancels the rename", field && cancelled && model.savedFilters[saved.id]?.name == "Checkout errors",
              "field \(field), cancelled \(cancelled), first responder \(String(describing: window.firstResponder))")

        model.beginRenamingFilter(saved.id)
        model.commitRenamingFilter(saved.id, to: "  Payment errors ", undoManager: undo)
        check("Rename Filter… renames it, and Edit reads \"Undo Rename Filter\"",
              model.savedFilters[saved.id]?.name == "Payment errors" && model.title.hasPrefix("Payment errors")
                && undo.undoMenuItemTitle == "Undo Rename Filter")
        undo.undo()
        check("Undo Rename Filter brings the old name back", model.savedFilters[saved.id]?.name == "Checkout errors")
        model.beginRenamingFilter(saved.id)
        model.commitRenamingFilter(saved.id, to: "orders ERRORS", undoManager: undo)
        model.beginRenamingFilter(saved.id)
        model.commitRenamingFilter(saved.id, to: "", undoManager: undo)
        check("a duplicate or empty name keeps the old one", model.savedFilters[saved.id]?.name == "Checkout errors"
              && model.renamingFilterID == nil)

        model.deleteFilter(undoManager: undo)
        await model.reload()
        check("Delete Filter removes it with no question; its filters stay on, scoped to its service",
              model.savedFilters[saved.id] == nil && model.sidebar == .service("checkout-api")
                && model.traceStatuses == [.error] && undo.undoMenuItemTitle == "Undo Delete Filter",
              "\(String(describing: model.sidebar))")
        undo.undo()
        check("Undo Delete Filter brings it back in its place, selected",
              model.savedFilters.items.first?.id == saved.id && model.sidebar == .savedFilter(saved.id)
                && model.title == "Checkout errors")
        window.makeFirstResponder(nil)
        _ = await waitUntil(1) { !model.sidebarHasFocus }
        check("away from the sidebar, ⌘⌫ is not Delete Filter", !MenuState.shared.savedFilters.canDelete)
    }

    /// The sidebar's list: the table in the leftmost column.
    static func sidebarTable(in window: NSWindow, model: AppModel) -> NSTableView? {
        var found: [NSTableView] = []
        var stack: [NSView] = window.contentView.map { [$0] } ?? []
        while let view = stack.popLast() {
            if let table = view as? NSTableView, table !== model.waterfallOutline { found.append(table) }
            stack.append(contentsOf: view.subviews)
        }
        return found.min { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
    }
}
