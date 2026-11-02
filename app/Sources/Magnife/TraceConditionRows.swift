import AppKit
import MagnifeKit
import SwiftUI

/// The condition rows under the first line of the Traces filter bar
/// (S-020, the Proxyman and TablePlus shape): key / operator / value / − / +.
/// The key completes from the attributes received; all rows must match.
struct TraceConditionRows: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            ForEach(Array(model.conditionRows.enumerated()), id: \.element.id) { index, row in
                ConditionRow(row: row, number: index + 1, canAdd: model.conditionRows.count < ConditionDraft.limit)
                if model.editingConditionKey == row.id {
                    let suggestions = model.conditionSuggestions
                    if !suggestions.isEmpty {
                        ConditionKeySuggestions(suggestions: suggestions, selected: model.conditionSuggestionIndex) {
                            _ = model.pickConditionSuggestion($0)
                        }
                    }
                }
            }
        }
        .gridProbe("trace-conditions", area: "trace-filter-bar")
    }
}

/// One row. "exists" hides the value field; ">" and "<" with text that is
/// no number say "Type a number" beside it.
struct ConditionRow: View {
    @Environment(AppModel.self) private var model
    let row: ConditionDraft
    let number: Int
    let canAdd: Bool

    var body: some View {
        HStack(spacing: Space.sm) {
            ConditionKeyField(text: row.key,
                              onChange: { model.conditionKeyTyped(row.id, $0) },
                              onEditing: { model.conditionKeyEditing(row.id, $0) },
                              onMove: { model.moveConditionSuggestion(by: $0) },
                              onSubmit: { model.pickConditionSuggestion() },
                              onCancel: { model.dismissConditionSuggestions() })
                .frame(width: 160)
            Picker("Operator", selection: Binding(get: { row.effectiveOp },
                                                  set: { op in model.updateConditionRow(row.id) { $0.op = op } })) {
                ForEach(row.operators, id: \.self) { op in Text(op.title).tag(op) }
            }
            .labelsHidden()
            .fixedSize()
            if row.showsValue {
                TextField("Value", text: Binding(get: { row.value },
                                                 set: { value in model.updateConditionRow(row.id) { $0.value = value } }),
                          prompt: Text("Value"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .frame(minWidth: 80, maxWidth: .infinity)
                    .overlay {
                        if row.needsNumber {
                            RoundedRectangle(cornerRadius: Radius.small - 3).strokeBorder(.red, lineWidth: 1)
                                .allowsHitTesting(false)
                        }
                    }
                    .accessibilityLabel("Value")
                if row.needsNumber {
                    Text(ConditionDraft.numberError)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize()
                }
            } else {
                Spacer(minLength: 0)
            }
            Button {
                model.removeConditionRow(row.id)
            } label: {
                Image(systemName: "minus")
                    .frame(width: Space.md)
            }
            .help("Remove this condition")
            .accessibilityLabel("Remove Condition")
            Button {
                model.addConditionRow(after: row.id)
            } label: {
                Image(systemName: "plus")
                    .frame(width: Space.md)
            }
            .disabled(!canAdd)
            .help(canAdd ? "Add a condition" : ConditionDraft.limitHelp)
            .accessibilityLabel("Add Condition")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(row.spokenText(number: number))
    }
}

/// Up to 20 keys, the built-in ones first: "http.route — span". ↓↑ in the
/// key field move the highlight, Return or a click picks.
struct ConditionKeySuggestions: View {
    let suggestions: [ConditionKeySuggestion]
    let selected: Int
    let pick: (ConditionKeySuggestion) -> Void
    static let visibleRows: CGFloat = 6
    static let rowHeight: CGFloat = 20

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                        Button { pick(suggestion) } label: {
                            Text(suggestion.title)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(index == selected ? AnyShapeStyle(Palette.onAccent) : AnyShapeStyle(.primary))
                                .padding(.horizontal, Space.sm)
                                .frame(maxWidth: .infinity, minHeight: Self.rowHeight, alignment: .leading)
                                .background(index == selected ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(.clear),
                                            in: .rect(cornerRadius: Radius.small - 4))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(index)
                        .accessibilityAddTraits(index == selected ? .isSelected : [])
                    }
                }
                .padding(Space.xs)
            }
            .frame(width: 320, height: min(CGFloat(suggestions.count), Self.visibleRows) * Self.rowHeight + Space.sm)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: Radius.small))
            .onChange(of: selected) { _, index in proxy.scrollTo(index) }
        }
        .accessibilityLabel("Attribute suggestions")
    }
}

/// The key field. AppKit, like Search's, so ↑↓, Return and Esc reach the
/// suggestions before the field editor uses them; it says when editing
/// starts and ends, which decides where the suggestions show.
struct ConditionKeyField: NSViewRepresentable {
    let text: String
    let onChange: (String) -> Void
    let onEditing: (Bool) -> Void
    /// Each returns true when it used the key.
    let onMove: (Int) -> Bool
    let onSubmit: () -> Bool
    let onCancel: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.bezelStyle = .roundedBezel
        field.controlSize = .small
        field.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        field.placeholderString = "Attribute"
        field.setAccessibilityLabel("Attribute")
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text {
            field.stringValue = text
            field.currentEditor()?.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ConditionKeyField

        init(_ parent: ConditionKeyField) { self.parent = parent }

        func controlTextDidBeginEditing(_ notification: Notification) { parent.onEditing(true) }

        func controlTextDidEndEditing(_ notification: Notification) { parent.onEditing(false) }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.onChange(field.stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)): return parent.onMove(-1)
            case #selector(NSResponder.moveDown(_:)): return parent.onMove(1)
            case #selector(NSResponder.insertNewline(_:)): return parent.onSubmit()
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            default: return false
            }
        }
    }
}
