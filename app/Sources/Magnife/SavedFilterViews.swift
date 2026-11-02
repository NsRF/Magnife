import MagnifeKit
import SwiftUI

/// Section Saved Filters in the sidebar (S-021), hidden while there are
/// none: one row per saved filter, in the order created.
struct SavedFiltersSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.savedFilters.isEmpty {
            Section("Saved Filters") {
                ForEach(model.savedFilters.items) { saved in
                    SavedFilterRow(saved: saved, isRenaming: model.renamingFilterID == saved.id)
                        .tag(SidebarSelection.savedFilter(saved.id))
                }
            }
        }
    }
}

/// "Checkout errors" with the filter icon; a field in place while renamed.
/// Long names truncate, with the whole name as the tooltip.
struct SavedFilterRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    let saved: SavedFilter
    let isRenaming: Bool

    var body: some View {
        Label {
            if isRenaming {
                SavedFilterNameField(saved: saved)
            } else {
                Text(saved.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(saved.name)
            }
        } icon: {
            Image(systemName: "line.3.horizontal.decrease.circle")
        }
        .accessibilityElement(children: isRenaming ? .contain : .ignore)
        .accessibilityLabel(saved.spokenLabel)
        // Rename and delete in the context menu and the File menu, not only on hover.
        .contextMenu {
            Button("Rename Filter…") { model.beginRenamingFilter(saved.id) }
            Button("Delete Filter") { model.deleteFilter(saved.id, undoManager: undoManager) }
        }
    }
}

/// The inline rename: Return keeps the name, Esc cancels, and focus
/// leaving the field keeps it too (as in Finder).
private struct SavedFilterNameField: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    let saved: SavedFilter
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Name", text: $name)
            .labelsHidden()
            .focused($focused)
            .onSubmit { model.commitRenamingFilter(saved.id, to: name, undoManager: undoManager) }
            .onExitCommand { model.cancelRenamingFilter() }
            .onAppear { name = saved.name }
            // The list keeps the focus while the row updates: take it a moment later.
            .task {
                try? await Task.sleep(for: .milliseconds(50))
                focused = true
            }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { model.commitRenamingFilter(saved.id, to: name, undoManager: undoManager) }
            }
            .accessibilityLabel("Name")
    }
}

/// The "Save Filter" sheet: Name, the query in monospace under it, Cancel
/// and Save. Its one job is typing a name, so the field takes the focus.
struct SaveFilterSheet: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: Space.md) {
            Text("Save Filter")
                .font(.headline)
            VStack(alignment: .leading, spacing: Space.xs) {
                LabeledContent("Name") {
                    TextField("Name", text: $model.saveFilterName, prompt: Text("Checkout errors"))
                        .labelsHidden()
                        .focused($focused)
                        .onSubmit { model.confirmSaveFilter() }
                }
                Text(model.saveFilterQuery)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .accessibilityLabel("Query")
                    .accessibilityValue(model.saveFilterQuery)
                if let message = model.saveFilterNameProblem?.message {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
            HStack(spacing: Space.sm) {
                Spacer()
                Button("Cancel") { model.cancelSaveFilter() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { model.confirmSaveFilter() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.saveFilterNameProblem != nil)
            }
        }
        .padding(Space.margin)
        .frame(width: 420)
        .gridArea("save-filter-sheet", inset: Space.margin)
        .onAppear { focused = true }
    }
}
