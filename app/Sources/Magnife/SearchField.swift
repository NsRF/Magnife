import AppKit
import MagnifeKit
import SwiftUI

/// Search's text field. AppKit, because the field editor takes ↑↓, Return
/// and Esc before SwiftUI's key handlers see them; its delegate turns them
/// into the panel's moves (docs/ux.md, S-017: everything works without the mouse).
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    /// A new value puts the focus in the field and selects its text.
    let focusRequest: Int
    let onMove: (Int) -> Void
    let onSubmit: () -> Void
    let onApply: () -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = SearchTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .preferredFont(forTextStyle: .title2)
        field.placeholderString = TraceSearch.placeholder
        field.setAccessibilityLabel(TraceSearch.label)
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // The panel's job is typing: the field takes the focus as it opens (mac-design, "Windows open calm").
        field.onWindow = { [weak coordinator = context.coordinator] field in coordinator?.focus(field) }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text {
            field.stringValue = text
            // A completed suggestion: the cursor goes to the end, ready for the next token.
            field.currentEditor()?.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        }
        if context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            DispatchQueue.main.async { context.coordinator.focus(field, selectAll: true) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// Takes the focus once it is in the window; before that there is no window to ask.
    final class SearchTextField: NSTextField {
        var onWindow: ((NSTextField) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil else { return }
                self.onWindow?(self)
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SearchField
        var focusRequest: Int

        init(_ parent: SearchField) {
            self.parent = parent
            focusRequest = parent.focusRequest
        }

        func focus(_ field: NSTextField, selectAll: Bool = false) {
            guard let window = field.window else { return }
            if window.firstResponder !== field.currentEditor() { window.makeFirstResponder(field) }
            let length = (field.stringValue as NSString).length
            field.currentEditor()?.selectedRange = selectAll ? NSRange(location: 0, length: length)
                : NSRange(location: length, length: 0)
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                parent.onMove(-1)
            case #selector(NSResponder.moveDown(_:)):
                parent.onMove(1)
            case #selector(NSResponder.insertNewline(_:)):
                if NSApp.currentEvent?.modifierFlags.contains(.command) == true { parent.onApply() } else { parent.onSubmit() }
            case Selector(("noop:")):
                // ⌘Return reaches the field editor as noop: (no key binding).
                guard let event = NSApp.currentEvent, event.type == .keyDown, event.modifierFlags.contains(.command),
                      event.keyCode == 36 || event.keyCode == 76 else { return false }
                parent.onApply()
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
            default:
                return false
            }
            return true
        }
    }
}
