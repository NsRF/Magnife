import AppKit
import MagnifeKit

/// The condition rows of the Traces filter bar (S-020): key, operator and
/// value per row, all rows AND. The list follows 100 ms after the last
/// change; keys complete from the attributes received (attribute_keys).
extension AppModel {
    /// A row changed: its conditions apply a moment after the last change.
    func applyConditionRows() {
        conditionTask?.cancel()
        let rows = conditionRows
        conditionTask = Task { [weak self] in
            try? await Task.sleep(for: Self.slowerThanDelay)
            guard let self, !Task.isCancelled, self.conditionRows == rows else { return }
            self.traceConditions = rows.map(\.condition)
        }
    }

    /// Edits one row in place.
    func updateConditionRow(_ id: ConditionDraft.ID, _ change: (inout ConditionDraft) -> Void) {
        guard let index = conditionRows.firstIndex(where: { $0.id == id }) else { return }
        var row = conditionRows[index]
        change(&row)
        // A key that offers other operators keeps the one in effect.
        row.op = row.effectiveOp
        conditionRows[index] = row
    }

    /// "+": a new row below this one, up to 10.
    func addConditionRow(after id: ConditionDraft.ID) {
        guard conditionRows.count < ConditionDraft.limit else { return }
        let index = (conditionRows.firstIndex { $0.id == id } ?? conditionRows.count - 1) + 1
        conditionRows.insert(ConditionDraft(), at: index)
    }

    /// "−": removes the row; on the only row, clears it.
    func removeConditionRow(_ id: ConditionDraft.ID) {
        if conditionRows.count == 1 {
            conditionRows = [ConditionDraft()]
        } else {
            conditionRows.removeAll { $0.id == id }
        }
        if editingConditionKey == id { editingConditionKey = nil }
    }

    /// The suggestions under the key field being edited.
    var conditionSuggestions: [ConditionKeySuggestion] {
        guard let id = editingConditionKey, !conditionSuggestionsDismissed,
              let row = conditionRows.first(where: { $0.id == id }) else { return [] }
        return ConditionKeySuggestion.suggestions(for: row.key, keys: conditionKeys)
    }

    /// The key field took or left the focus. Taking it reads the keys received so far.
    func conditionKeyEditing(_ id: ConditionDraft.ID, _ editing: Bool) {
        if editing {
            editingConditionKey = id
            conditionSuggestionIndex = 0
            conditionSuggestionsDismissed = false
            loadConditionKeys()
        } else if editingConditionKey == id {
            editingConditionKey = nil
        }
    }

    /// Typing in the key field shows the suggestions again from the top.
    func conditionKeyTyped(_ id: ConditionDraft.ID, _ text: String) {
        updateConditionRow(id) { $0.key = text }
        editingConditionKey = id
        conditionSuggestionIndex = 0
        conditionSuggestionsDismissed = false
    }

    /// ↑↓ in the key field: true when suggestions show and took the key.
    func moveConditionSuggestion(by offset: Int) -> Bool {
        let count = conditionSuggestions.count
        guard count > 0 else { return false }
        conditionSuggestionIndex = min(max(0, conditionSuggestionIndex + offset), count - 1)
        return true
    }

    /// Return in the key field, or a click: the highlighted key goes in the field.
    func pickConditionSuggestion(_ suggestion: ConditionKeySuggestion? = nil) -> Bool {
        guard let id = editingConditionKey,
              let picked = suggestion ?? conditionSuggestions[safe: conditionSuggestionIndex] else { return false }
        updateConditionRow(id) { $0.key = picked.key }
        conditionSuggestionsDismissed = true
        return true
    }

    /// Esc in the key field: the suggestions go first, then the bar.
    func dismissConditionSuggestions() {
        if conditionSuggestions.isEmpty {
            hideTraceFilterBar()
        } else {
            conditionSuggestionsDismissed = true
        }
    }

    /// Span and resource keys received so far (log keys are not trace filters).
    func loadConditionKeys() {
        guard let reader else { return }
        Task { [weak self] in
            let keys = (try? await reader.attributeKeys()) ?? []
            guard let self, keys != self.conditionKeys else { return }
            self.conditionKeys = keys
        }
    }
}
