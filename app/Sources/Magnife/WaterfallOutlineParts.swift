import AppKit
import MagnifeKit

/// ⌘C on a waterfall row copies its span ID (docs/ux.md, Edit menu); the
/// keyboard map's keys go to the coordinator first (S-022).
final class WaterfallOutlineView: NSOutlineView {
    var onCopy: (() -> Void)?
    var onKey: ((NSEvent) -> Bool)?

    @objc func copy(_ sender: Any?) {
        onCopy?()
    }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) == true { return }
        super.keyDown(with: event)
    }
}

/// Lays out the columns again whenever its width changes (`tile`).
final class WaterfallScrollView: NSScrollView {
    var onTile: (() -> Void)?

    override func tile() {
        super.tile()
        onTile?()
    }
}

/// NSOutlineView needs objects for items. One per span, kept across the
/// rebuilds of one trace, so the outline keeps its rows' identity; `index`
/// points into the current tree.
final class SpanItem: NSObject {
    var index: Int
    init(_ index: Int) { self.index = index }
}

/// The waterfall's keys (docs/ux.md, Keyboard map): ← collapses or selects
/// the parent, → expands or selects the first child, ⌥← / ⌥→ the whole
/// subtree, Return opens the span detail, Space shows or hides it, Esc
/// goes back to the trace list, Home / End / Page Up / Page Down move the
/// selection, Tab moves to the next column. ↑↓ stay the outline's own.
extension WaterfallCoordinator {
    enum Key: UInt16 {
        case tab = 48, space = 49, escape = 53, enter = 76, returnKey = 36
        case home = 115, pageUp = 116, end = 119, pageDown = 121, left = 123, right = 124
    }

    func handleKey(_ event: NSEvent) -> Bool {
        guard let key = Key(rawValue: event.keyCode), let outline else { return false }
        let held = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch key {
        case .left, .right:
            guard held.isEmpty || held == .option else { return false }
            arrow(key == .left, subtree: held == .option, in: outline)
        case .returnKey, .enter:
            guard held.isEmpty else { return false }
            model.enterSpanDetail()
        case .space:
            guard held.isEmpty else { return false }
            model.toggleSpanDetail()
        case .escape:
            guard held.isEmpty else { return false }
            model.leaveWaterfall()
        case .tab:
            guard held.isSubset(of: .shift) else { return false }
            model.focusNextColumn(from: .waterfall, backward: held == .shift)
        case .home, .end, .pageUp, .pageDown:
            guard held.isEmpty else { return false }
            let page = max(1, outline.rows(in: outline.visibleRect).length - 1)
            let move: ListMove = switch key {
            case .home: .first
            case .end: .last
            case .pageUp: .pageUp(page)
            default: .pageDown(page)
            }
            let current = outline.selectedRow >= 0 ? outline.selectedRow : nil
            guard let row = move.index(from: current, count: outline.numberOfRows),
                  let item = outline.item(atRow: row) as? SpanItem else { return true }
            model.selectedSpanID = waterfall.nodes[item.index].span.spanID
        }
        return true
    }

    /// ← and → on the selected row; with ⌥, its whole subtree.
    private func arrow(_ left: Bool, subtree: Bool, in outline: NSOutlineView) {
        guard let item = outline.item(atRow: outline.selectedRow) as? SpanItem else { return }
        if subtree {
            if left { outline.collapseItem(item, collapseChildren: true) } else { outline.expandItem(item, expandChildren: true) }
            return
        }
        let move = left ? waterfall.moveLeft(from: item.index, collapsed: collapsed)
            : waterfall.moveRight(from: item.index, collapsed: collapsed)
        switch move {
        case .collapse(let index): outline.collapseItem(items[index])
        case .expand(let index): outline.expandItem(items[index])
        case .select(let index): model.selectedSpanID = waterfall.nodes[index].span.spanID
        case .none: break
        }
    }
}

/// The row context menu (docs/ux.md: Copy Span ID, —, Expand All Spans, Collapse All Spans).
extension WaterfallCoordinator {
    func contextMenu() -> NSMenu {
        let menu = NSMenu()
        for (title, action) in [("Copy Span ID", #selector(copySpanID)), ("", nil),
                                ("Expand All Spans", #selector(expandAll)), ("Collapse All Spans", #selector(collapseAll))] {
            guard let action else {
                menu.addItem(.separator())
                continue
            }
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    /// The row that was right-clicked, else the selected one.
    @objc private func copySpanID() {
        guard let outline else { return }
        let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        guard row >= 0, let item = outline.item(atRow: row) as? SpanItem else { return }
        model.copySpanID(waterfall.nodes[item.index].span.spanID)
    }

    @objc private func expandAll() { model.expandAllSpans() }
    @objc private func collapseAll() { model.collapseAllSpans() }
}
