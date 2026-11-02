import AppKit
import MagnifeKit

/// Snapshot states for saved filters (S-021).
extension Snapshot {
    /// The seed data's saved filter (docs/STORIES.md, Seed data): "Checkout
    /// errors", made through Save Filter like a person would, in the test
    /// run's own defaults suite.
    static func seedSavedFilter(_ model: AppModel) {
        AppDefaults.resetTestSuite()
        model.savedFilters = SavedFilters()
        model.applyTraceFilter(TraceFilter(service: "checkout-api", statuses: [.error]))
        model.saveFilterName = "Checkout errors"
        model.confirmSaveFilter()
        model.applyTraceFilter(.cleared)
    }

    /// 02-trace-list-saved-filter: "Checkout errors" selected, its title and
    /// its one trace; -edited: the OK chip added, "— Edited" and "Save Filter"
    /// in the bar; -rename: its name being edited in place.
    static func captureSavedFilter(_ model: AppModel, dir: String, mode: String) async {
        let page = SnapshotPage.traceList.rawValue
        guard let saved = model.savedFilters.items.first else { return print("SNAPSHOT no saved filter") }
        model.sidebar = .savedFilter(saved.id)
        await model.reload()
        try? await Task.sleep(for: .seconds(0.8))
        capture(to: "\(dir)/\(page)-saved-filter-\(mode).png")
        model.showsTraceFilterBar = true
        model.clickStatusChip(.ok, adding: true)
        await model.reload()
        try? await Task.sleep(for: .seconds(0.8))
        capture(to: "\(dir)/\(page)-saved-filter-edited-\(mode).png")
        model.showsTraceFilterBar = false
        model.sidebar = .allTraces
        model.sidebar = .savedFilter(saved.id)
        model.beginRenamingFilter(saved.id)
        try? await Task.sleep(for: .seconds(0.8))
        capture(to: "\(dir)/\(page)-saved-filter-rename-\(mode).png")
        model.cancelRenamingFilter()
        model.applyTraceFilter(.cleared)
        await model.reload()
    }

    /// 07-filter-bar-save: the Save Filter sheet over the bar, its query
    /// under the empty Name field; -save-duplicate: a name already used.
    static func captureSaveSheet(_ model: AppModel, dir: String, mode: String) async {
        let page = SnapshotPage.filterBar.rawValue
        model.applyTraceFilter(TraceFilter(service: "checkout-api", statuses: [.error], slowerThanNs: 50_000_000))
        model.showsTraceFilterBar = true
        await model.reload()
        model.saveFilter()
        try? await Task.sleep(for: .seconds(0.8))
        capture(to: "\(dir)/\(page)-save-\(mode).png")
        model.saveFilterName = "Checkout errors"
        try? await Task.sleep(for: .seconds(0.5))
        capture(to: "\(dir)/\(page)-save-duplicate-\(mode).png")
        model.cancelSaveFilter()
        try? await Task.sleep(for: .seconds(0.5))
        model.applyTraceFilter(.cleared)
    }
}
