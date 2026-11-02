import AppKit
import MagnifeKit
import SwiftUI

/// The waterfall's rows: an NSOutlineView, because it draws only the rows
/// on screen at any span count, and gives disclosure triangles, ← → keys
/// and VoiceOver's outline levels for free (MVP allows AppKit for
/// performance; SwiftUI's List rebuilds every row identity on each change).
/// The tree comes built from AppModel; this view only shows it.
struct WaterfallOutline: NSViewRepresentable {
    let model: AppModel
    let generation: Int
    let waterfall: Waterfall
    let collapsed: Set<String>
    let selected: String?
    let colors: ServiceColors

    func makeCoordinator() -> WaterfallCoordinator { WaterfallCoordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = WaterfallOutlineView()
        outline.onCopy = { [model] in model.copySpanID() }
        let name = NSTableColumn(identifier: .spanName)
        name.title = "Span"
        // Narrow at first: the scroll view gives it its share once it has a width.
        name.width = 200
        name.minWidth = 120
        let bars = NSTableColumn(identifier: .spanBar)
        bars.headerCell = TimelineHeaderCell()
        bars.width = 80
        bars.minWidth = 80
        outline.addTableColumn(name)
        outline.addTableColumn(bars)
        outline.outlineTableColumn = name
        outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outline.style = .inset
        outline.rowHeight = 24
        outline.intercellSpacing = NSSize(width: 0, height: 0)
        outline.indentationPerLevel = Space.md
        outline.allowsEmptySelection = false
        outline.allowsColumnReordering = false
        outline.autosaveExpandedItems = false
        // Deep subtrees truncate their names instead of squeezing the bars.
        outline.autoresizesOutlineColumn = false
        outline.setAccessibilityLabel("Waterfall")
        let coordinator = context.coordinator
        outline.dataSource = coordinator
        outline.delegate = coordinator
        outline.menu = coordinator.contextMenu()
        coordinator.outline = outline
        outline.onKey = { [weak coordinator] event in coordinator?.handleKey(event) ?? false }
        model.waterfallOutline = outline

        let scroll = WaterfallScrollView()
        scroll.onTile = { [weak coordinator] in coordinator?.fitColumns() }
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        return scroll
    }

    /// The column's size, never the table's: the bar column fills what is left.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 420, height: proposal.height ?? 320)
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(generation: generation, waterfall: waterfall, collapsed: collapsed,
                                   selected: selected, colors: colors)
    }
}

extension NSUserInterfaceItemIdentifier {
    static let spanName = NSUserInterfaceItemIdentifier("span-name")
    static let spanBar = NSUserInterfaceItemIdentifier("span-bar")
}

final class WaterfallCoordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let model: AppModel
    weak var outline: NSOutlineView?
    private(set) var waterfall = Waterfall()
    private(set) var items: [SpanItem] = []
    private var itemsByID: [String: SpanItem] = [:]
    private var generation = -1
    /// The span last selected from the model: the outline scrolls only when
    /// it changes, never because a rebuild moved its row.
    private var lastSelected: String?
    /// The Span column's share of the width (S-005: name and service need
    /// room more than the bars do); a drag of its divider changes it.
    private var nameShare: CGFloat = 0.55
    private var isFitting = false
    /// The collapsed spans the outline shows.
    private(set) var collapsed: Set<String> = []
    private var colors = ServiceColors()
    /// True while this coordinator changes the outline, so its own
    /// expand, collapse and selection callbacks do not write back.
    private var isApplying = false

    init(model: AppModel) { self.model = model }

    func update(generation: Int, waterfall: Waterfall, collapsed: Set<String>, selected: String?, colors: ServiceColors) {
        guard let outline else { return }
        isApplying = true
        defer { isApplying = false }
        if generation != self.generation {
            self.generation = generation
            self.waterfall = waterfall
            self.collapsed = collapsed
            self.colors = colors
            var reused: [String: SpanItem] = [:]
            items = waterfall.nodes.enumerated().map { index, node in
                let item = itemsByID[node.span.spanID] ?? SpanItem(index)
                item.index = index
                reused[node.span.spanID] = item
                return item
            }
            itemsByID = reused
            if let header = outline.tableColumns.last?.headerCell as? TimelineHeaderCell {
                header.durationNs = waterfall.durationNs
                outline.headerView?.needsDisplay = true
            }
            outline.reloadData()
            expandOpenSpans(outline)
            fitColumns()
            model.waterfallShown(generation: generation)
        } else if collapsed != self.collapsed {
            self.collapsed = collapsed
            if collapsed.isEmpty {
                outline.expandItem(nil, expandChildren: true)
            } else {
                outline.collapseItem(nil, collapseChildren: true)
                expandOpenSpans(outline)
            }
            reloadNames(outline)
        } else if colors != self.colors {
            self.colors = colors
            outline.reloadData(forRowIndexes: IndexSet(integersIn: 0..<outline.numberOfRows),
                               columnIndexes: IndexSet(integersIn: 0..<outline.numberOfColumns))
        }
        select(selected, in: outline)
    }

    /// Expands every span that is not collapsed, parents first, without recursion.
    private func expandOpenSpans(_ outline: NSOutlineView) {
        var stack = waterfall.roots
        while let index = stack.popLast() {
            let node = waterfall.nodes[index]
            guard !node.children.isEmpty, !collapsed.contains(node.span.spanID) else { continue }
            outline.expandItem(items[index])
            stack.append(contentsOf: node.children)
        }
    }

    private func select(_ spanID: String?, in outline: NSOutlineView) {
        guard let spanID, let index = waterfall.index(of: spanID) else { return }
        var row = outline.row(forItem: items[index])
        if row < 0 {
            // Hidden under a collapsed span: select the nearest shown parent.
            var shown = index
            while row < 0, let parent = waterfall.nodes[shown].parent {
                shown = parent
                row = outline.row(forItem: items[shown])
            }
            let id = waterfall.nodes[shown].span.spanID
            Task { @MainActor [model] in model.selectedSpanID = id }
        }
        let moved = spanID != lastSelected
        lastSelected = spanID
        guard row >= 0, row != outline.selectedRow else { return }
        outline.selectRowIndexes([row], byExtendingSelection: false)
        // A rebuild moved the row under a list people may be scrolling: leave the view alone.
        if moved { outline.scrollRowToVisible(row) }
    }

    /// The Span column takes its share of the width, the bars the rest.
    func fitColumns() {
        guard !isFitting, let outline, outline.tableColumns.count == 2 else { return }
        isFitting = true
        defer { isFitting = false }
        let name = outline.tableColumns[0], bars = outline.tableColumns[1]
        // The bars fill the width first, so the two columns add up to all of it.
        outline.sizeLastColumnToFit()
        let total = name.width + bars.width
        let wanted = min(max(name.minWidth, (total * nameShare).rounded()), max(name.minWidth, total - bars.minWidth))
        if abs(name.width - wanted) >= 1 { name.width = wanted }
        outline.sizeLastColumnToFit()
    }

    /// A drag of the column divider sets the share the Span column keeps.
    func outlineViewColumnDidResize(_ notification: Notification) {
        guard !isFitting, !isApplying, let outline, outline.inLiveResize == false,
              let column = notification.userInfo?["NSTableColumn"] as? NSTableColumn, column.identifier == .spanName,
              let bars = outline.tableColumns.last else { return }
        let total = column.width + bars.width
        if total > 0 { nameShare = min(max(column.width / total, 0.2), 0.8) }
    }

    /// Rows show "N spans" while collapsed; refresh the ones on screen.
    private func reloadNames(_ outline: NSOutlineView) {
        let rows = outline.rows(in: outline.visibleRect)
        guard rows.length > 0 else { return }
        outline.reloadData(forRowIndexes: IndexSet(integersIn: rows.location..<NSMaxRange(rows)), columnIndexes: [0, 1])
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item = item as? SpanItem else { return waterfall.roots.count }
        return waterfall.nodes[item.index].children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item = item as? SpanItem else { return items[waterfall.roots[index]] }
        return items[waterfall.nodes[item.index].children[index]]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let item = item as? SpanItem else { return false }
        return !waterfall.nodes[item.index].children.isEmpty
    }

    // MARK: Delegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? SpanItem, let column = tableColumn else { return nil }
        let index = item.index
        let span = waterfall.nodes[index].span
        let color = ServicePalette.nsColor(slot: colors.slot(for: span.serviceName))
        if column.identifier == .spanName {
            let cell = outlineView.makeView(withIdentifier: .spanName, owner: nil) as? SpanNameCell ?? SpanNameCell()
            cell.identifier = .spanName
            let node = waterfall.nodes[index]
            let hiddenCount = collapsed.contains(span.spanID) ? node.descendantCount : 0
            cell.configure(name: span.name, service: waterfall.shownService(of: index),
                           duration: DurationFormat.string(nanoseconds: span.durationNs), color: color,
                           isError: span.status == .error, hiddenCount: hiddenCount, isOrphan: node.isOrphan,
                           label: waterfall.accessibilityLabel(of: index))
            return cell
        }
        let cell = outlineView.makeView(withIdentifier: .spanBar, owner: nil) as? SpanBarCell ?? SpanBarCell()
        cell.identifier = .spanBar
        let bar = waterfall.barFractions(of: index)
        let hidden = collapsed.contains(span.spanID) ? waterfall.nodes[index].descendantCount : 0
        cell.configure(start: bar.start, width: bar.width, color: span.status == .error ? .systemRed : color,
                       note: hidden == 0 ? nil : TraceList.spansText(hidden))
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isApplying, let outline, let item = outline.item(atRow: outline.selectedRow) as? SpanItem else { return }
        let id = waterfall.nodes[item.index].span.spanID
        if model.selectedSpanID != id { model.selectedSpanID = id }
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        changed(notification, collapsed: false)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        changed(notification, collapsed: true)
    }

    /// A disclosure triangle, ← or → (⌥ for the whole subtree) changed a span.
    private func changed(_ notification: Notification, collapsed isCollapsed: Bool) {
        guard !isApplying, let item = notification.userInfo?["NSObject"] as? SpanItem else { return }
        let id = waterfall.nodes[item.index].span.spanID
        if isCollapsed { collapsed.insert(id) } else { collapsed.remove(id) }
        model.collapsedSpans = collapsed
        // Out of the outline's own callback: refresh the "N spans" text, and
        // a selection the collapse hid moves to the collapsed span.
        Task { @MainActor [weak self] in
            guard let self, let outline = self.outline else { return }
            let row = outline.row(forItem: item)
            if row >= 0 { outline.reloadData(forRowIndexes: [row], columnIndexes: [0, 1]) }
            if isCollapsed, let selected = self.model.selectedSpanID, let index = self.waterfall.index(of: selected),
               outline.row(forItem: self.items[index]) < 0 {
                self.model.selectedSpanID = id
            }
        }
    }
}
