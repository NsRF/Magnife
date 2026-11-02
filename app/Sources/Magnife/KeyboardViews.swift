import AppKit
import MagnifeKit
import SwiftUI

extension View {
    /// The list keys of docs/ux.md's keyboard map on a Table (S-022): Home
    /// or ⌘↑ selects the newest row, End or ⌘↓ the oldest, Page Up and
    /// Page Down move a page, Tab and ⇧Tab move to the next column. Plain ↑↓
    /// stay the table's own.
    func listKeys(page: @escaping () -> Int, move: @escaping (ListMove) -> Void,
                  tab: @escaping (_ backward: Bool) -> Void) -> some View {
        onKeyPress(keys: [.home, .end, .pageUp, .pageDown, .upArrow, .downArrow, .tab, Self.backTab]) { press in
            switch press.key {
            case .home: move(.first)
            case .end: move(.last)
            case .pageUp: move(.pageUp(page()))
            case .pageDown: move(.pageDown(page()))
            case .upArrow, .downArrow:
                guard press.modifiers.held == .command else { return .ignored }
                move(press.key == .upArrow ? .first : .last)
            default:
                guard press.modifiers.held.isSubset(of: .shift) else { return .ignored }
                tab(press.modifiers.contains(.shift) || press.key == Self.backTab)
            }
            return .handled
        }
    }

    /// ⇧Tab arrives as the back-tab character.
    static var backTab: KeyEquivalent { KeyEquivalent("\u{19}") }
}

/// Tab and ⇧Tab while the sidebar has the focus move to the next column
/// (S-022). A local key monitor, because the sidebar's List handles ⇧Tab
/// itself before `onKeyPress` sees it.
@MainActor
enum SidebarTabKeys {
    private static var monitor: Any?

    static func install(model: AppModel) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 48 else { return event }
            let held = event.modifierFlags.intersection([.command, .option, .control, .shift])
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard model.sidebarHasFocus, model.renamingFilterID == nil, held.isSubset(of: .shift),
                      event.window?.attachedSheet == nil else { return false }
                model.focusNextColumn(from: .sidebar, backward: held == .shift)
                return true
            }
            return handled ? nil : event
        }
    }
}

/// The modifier keys a press counts with: arrows also carry the
/// function and keypad flags, which say nothing about what was held.
extension EventModifiers {
    var held: EventModifiers { intersection([.command, .option, .control, .shift]) }
}
