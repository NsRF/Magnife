import AppKit
import MagnifeKit

/// Saved filters (S-021): File > Save Filter… (⌘S) or the filter bar's
/// button names the current scope and filters; the sidebar lists them
/// under Saved Filters, and selecting one brings them back in the Traces
/// view. Rename in place (Return, Rename Filter…) and Delete Filter (⌘⌫)
/// are undoable. They live in UserDefaults (PROGRESS decision 6).
extension AppModel {
    var selectedSavedFilter: SavedFilter? {
        sidebar?.savedFilterID.flatMap { savedFilters[$0] }
    }

    /// The selected saved filter's filters changed since it was saved.
    var isSavedFilterEdited: Bool {
        selectedSavedFilter?.isEdited(by: traceFilter) ?? false
    }

    /// "Save Filter" saves an edited saved filter at once; "Save Filter…" asks for a name.
    var saveFilterTitle: String { isSavedFilterEdited ? "Save Filter" : "Save Filter…" }

    /// Save Filter is enabled in the Traces view while a filter is on, and,
    /// on a saved filter, only once it is edited (an unchanged one has nothing to save).
    var canSaveFilter: Bool {
        contentMode == .traces && traceFilter.isActive && (selectedSavedFilter == nil || isSavedFilterEdited)
    }

    /// Save Filter As… (⇧⌘S): only while a saved filter is selected.
    var canSaveFilterAs: Bool { contentMode == .traces && selectedSavedFilter != nil && traceFilter.isActive }

    /// The query the sheet shows under the Name field.
    var saveFilterQuery: String { TraceQuery.format(traceFilter) }

    /// Why the name typed in the sheet cannot be saved; nil when it can.
    var saveFilterNameProblem: SavedFilters.NameProblem? { savedFilters.problem(with: saveFilterName) }

    /// ⌘S and the filter bar's button.
    func saveFilter() {
        guard canSaveFilter else { return }
        if let saved = selectedSavedFilter, isSavedFilterEdited {
            savedFilters.update(saved.id, filter: traceFilter)
        } else {
            askForFilterName()
        }
    }

    /// ⇧⌘S: a new saved filter from the edited one.
    func saveFilterAs() {
        guard canSaveFilterAs else { return }
        askForFilterName()
    }

    private func askForFilterName() {
        saveFilterName = ""
        showsSaveFilterSheet = true
    }

    /// The sheet's Save (Return): the filter joins the sidebar, selected.
    func confirmSaveFilter() {
        let filter = traceFilter
        guard let saved = savedFilters.add(name: saveFilterName, filter: filter) else { return }
        showsSaveFilterSheet = false
        sidebar = .savedFilter(saved.id)
    }

    func cancelSaveFilter() {
        showsSaveFilterSheet = false
    }

    /// Selecting a saved filter: its service, chips, "Slower than" and
    /// condition rows as one change, in the Traces view.
    func loadSavedFilter(_ saved: SavedFilter) {
        let filter = saved.filter
        holdsFilterChanges = true
        setBarFilters(filter)
        savedFilterService = filter.service
        holdsFilterChanges = false
        showContentMode(.traces)
    }

    // MARK: Rename and delete

    /// Rename Filter… and Return on the row: the name becomes a field in place.
    func beginRenamingFilter(_ id: SavedFilter.ID? = nil) {
        guard let id = id ?? sidebar?.savedFilterID, savedFilters[id] != nil else { return }
        renamingFilterID = id
    }

    /// Return or focus leaving the field. An empty name or one another filter
    /// has keeps the old name (with a beep for the duplicate).
    func commitRenamingFilter(_ id: SavedFilter.ID, to name: String, undoManager: UndoManager?) {
        guard renamingFilterID == id else { return }
        renamingFilterID = nil
        if case .duplicate = savedFilters.problem(with: name, renaming: id) { NSSound.beep() }
        renameFilter(id, to: name, undoManager: undoManager)
    }

    func cancelRenamingFilter() {
        renamingFilterID = nil
    }

    func renameFilter(_ id: SavedFilter.ID, to name: String, undoManager: UndoManager?) {
        guard let old = savedFilters[id]?.name, savedFilters.rename(id, to: name) else { return }
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.renameFilter(id, to: old, undoManager: undoManager) }
        }
        undoManager?.setActionName("Rename Filter")
    }

    /// Delete Filter (⌘⌫), no confirmation: Edit > Undo Delete Filter brings
    /// it back in its place. A selected one leaves its filters on, scoped to its service.
    func deleteFilter(_ id: SavedFilter.ID? = nil, undoManager: UndoManager?) {
        guard let id = id ?? sidebar?.savedFilterID else { return }
        let wasSelected = sidebar?.savedFilterID == id
        let service = savedFilterService
        guard let removed = savedFilters.remove(id) else { return }
        if renamingFilterID == id { renamingFilterID = nil }
        if wasSelected { sidebar = service.map { .service($0) } ?? .allTraces }
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                model.restoreFilter(removed.filter, at: removed.index, select: wasSelected, undoManager: undoManager)
            }
        }
        undoManager?.setActionName("Delete Filter")
    }

    private func restoreFilter(_ filter: SavedFilter, at index: Int, select: Bool, undoManager: UndoManager?) {
        savedFilters.insert(filter, at: index)
        if select { sidebar = .savedFilter(filter.id) }
        // Redo deletes it again.
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.deleteFilter(filter.id, undoManager: undoManager) }
        }
        undoManager?.setActionName("Delete Filter")
    }

    /// The File menu's saved filter items (MenuState).
    func updateSavedFilterMenu() {
        MenuState.shared.update(savedFilters: MenuState.SavedFilterItems(
            canSave: canSaveFilter, saveTitle: saveFilterTitle, canSaveAs: canSaveFilterAs,
            hasSelected: selectedSavedFilter != nil, canDelete: selectedSavedFilter != nil && sidebarHasFocus))
    }
}
