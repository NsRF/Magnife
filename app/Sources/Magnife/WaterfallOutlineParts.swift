import AppKit
import MagnifeKit

/// ⌘C on a waterfall row copies its span ID (docs/ux.md, Edit menu).
final class WaterfallOutlineView: NSOutlineView {
    var onCopy: (() -> Void)?

    @objc func copy(_ sender: Any?) {
        onCopy?()
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
