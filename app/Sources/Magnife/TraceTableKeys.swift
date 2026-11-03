import AppKit
import MagnifeKit

/// The trace list's keys (docs/ux.md, Keyboard map; S-022): Esc hides the
/// filter bar (the filters stay on), → and Return move into the waterfall
/// on the root span, Space shows or hides the span detail, Home or ⌘↑ the
/// newest row, End or ⌘↓ the oldest, Page Up and Page Down a page, Tab and
/// ⇧Tab the next column. Plain ↑↓ stay the table's own.
extension TraceTableCoordinator {
    private enum Key: UInt16 {
        case tab = 48, space = 49, escape = 53, enter = 76, returnKey = 36
        case home = 115, pageUp = 116, end = 119, pageDown = 121, right = 124, down = 125, up = 126
    }

    func handleKey(_ event: NSEvent) -> Bool {
        guard let key = Key(rawValue: event.keyCode) else { return false }
        let held = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch key {
        case .escape:
            guard held.isEmpty, model.showsTraceFilterBar else { return false }
            model.hideTraceFilterBar()
        case .right, .returnKey, .enter:
            guard held.isEmpty, model.selectedTraceID != nil else { return false }
            model.enterWaterfall()
        case .space:
            guard held.isEmpty, model.selectedTraceID != nil else { return false }
            model.toggleSpanDetail()
        case .tab:
            guard held.isSubset(of: .shift) else { return false }
            model.focusNextColumn(from: .list, backward: held == .shift)
        case .up, .down:
            guard held == .command else { return false }
            model.moveTraceSelection(key == .up ? .first : .last)
        case .home, .end, .pageUp, .pageDown:
            guard held.isEmpty else { return false }
            let page = model.pageRows(model.listScroller)
            let move: ListMove = switch key {
            case .home: .first
            case .end: .last
            case .pageUp: .pageUp(page)
            default: .pageDown(page)
            }
            model.moveTraceSelection(move)
        }
        return true
    }
}
