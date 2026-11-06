import AppKit
import MagnifeKit
import SwiftUI

/// The comparison's merged tree (S-036): an NSOutlineView like the
/// waterfall's, so a 30,000-span pair draws only the rows on screen.
/// Columns: Span, A, B, Change, Timeline (an A bar over a B bar).
struct CompareOutline: NSViewRepresentable {
    let model: AppModel
    let compare: CompareModel
    let generation: Int
    let comparison: TraceComparison
    let collapsed: Set<Int>
    let selected: Int?
    let colors: ServiceColors

    func makeCoordinator() -> CompareCoordinator { CompareCoordinator(model: model, compare: compare) }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = CompareOutlineView()
        let columns: [(NSUserInterfaceItemIdentifier, String, CGFloat, CGFloat)] = [
            (.compareSpan, "Span", 280, 160), (.compareA, "A", 88, 72), (.compareB, "B", 88, 72),
            (.compareChange, "Change", 104, 88), (.compareTimeline, "", 200, 120),
        ]
        for (identifier, title, width, minimum) in columns {
            let column = NSTableColumn(identifier: identifier)
            column.title = title
            column.width = width
            column.minWidth = minimum
            if identifier == .compareTimeline { column.headerCell = TimelineHeaderCell() }
            if identifier == .compareA || identifier == .compareB || identifier == .compareChange {
                column.headerCell.alignment = .right
            }
            outline.addTableColumn(column)
        }
        outline.outlineTableColumn = outline.tableColumns[0]
        // The Span column takes the width the others leave.
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.style = .inset
        outline.rowHeight = 24
        outline.intercellSpacing = NSSize(width: 0, height: 0)
        outline.indentationPerLevel = Space.md
        outline.allowsEmptySelection = false
        outline.allowsColumnReordering = false
        outline.autosaveExpandedItems = false
        outline.autoresizesOutlineColumn = false
        outline.setAccessibilityLabel("Comparison")
        let coordinator = context.coordinator
        outline.dataSource = coordinator
        outline.delegate = coordinator
        outline.target = coordinator
        outline.doubleAction = #selector(CompareCoordinator.openClicked(_:))
        outline.menu = coordinator.contextMenu()
        outline.onReturn = { [weak coordinator] in coordinator?.openSelected() }
        outline.onCopy = { [weak coordinator] in coordinator?.copySelected() }
        coordinator.outline = outline
        compare.outline = outline

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        return scroll
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 720, height: proposal.height ?? 320)
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(generation: generation, comparison: comparison, collapsed: collapsed,
                                   selected: selected, colors: colors)
    }
}

extension NSUserInterfaceItemIdentifier {
    static let compareSpan = NSUserInterfaceItemIdentifier("compare-span")
    static let compareA = NSUserInterfaceItemIdentifier("compare-a")
    static let compareB = NSUserInterfaceItemIdentifier("compare-b")
    static let compareChange = NSUserInterfaceItemIdentifier("compare-change")
    static let compareTimeline = NSUserInterfaceItemIdentifier("compare-timeline")
}

/// Return opens the span in the main window; ⌘C copies its span id.
final class CompareOutlineView: NSOutlineView {
    var onReturn: (() -> Void)?
    var onCopy: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            onReturn?()
            return
        }
        super.keyDown(with: event)
    }

    @objc func copy(_ sender: Any?) { onCopy?() }
}

/// One row's identity across rebuilds, so the outline keeps its expanded rows.
final class CompareItem {
    var index: Int
    init(_ index: Int) { self.index = index }
}

@MainActor
final class CompareCoordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    let model: AppModel
    let compare: CompareModel
    weak var outline: NSOutlineView?
    private(set) var comparison: TraceComparison?
    private var items: [CompareItem] = []
    private var itemsByID: [Int: CompareItem] = [:]
    private var generation = -1
    private var collapsed: Set<Int> = []
    private var colors = ServiceColors()
    private var lastSelected: Int?
    private var isApplying = false

    init(model: AppModel, compare: CompareModel) {
        self.model = model
        self.compare = compare
    }

    func update(generation: Int, comparison: TraceComparison, collapsed: Set<Int>, selected: Int?, colors: ServiceColors) {
        guard let outline else { return }
        isApplying = true
        defer { isApplying = false }
        if generation != self.generation {
            self.generation = generation
            self.comparison = comparison
            self.collapsed = collapsed
            self.colors = colors
            var reused: [Int: CompareItem] = [:]
            items = comparison.rows.enumerated().map { index, row in
                let item = itemsByID[row.id] ?? CompareItem(index)
                item.index = index
                reused[row.id] = item
                return item
            }
            itemsByID = reused
            if let header = outline.tableColumns.last?.headerCell as? TimelineHeaderCell {
                header.durationNs = comparison.scaleNs
                outline.headerView?.needsDisplay = true
            }
            outline.reloadData()
            expandOpenRows(outline)
        } else if collapsed != self.collapsed {
            self.collapsed = collapsed
            outline.collapseItem(nil, collapseChildren: true)
            expandOpenRows(outline)
        } else if colors != self.colors {
            self.colors = colors
            outline.reloadData()
            expandOpenRows(outline)
        }
        select(selected, in: outline)
    }

    /// Expands every row that is not collapsed, parents first, without recursion.
    private func expandOpenRows(_ outline: NSOutlineView) {
        guard let comparison else { return }
        var stack = comparison.roots
        while let index = stack.popLast() {
            let row = comparison.rows[index]
            guard !row.children.isEmpty, !collapsed.contains(row.id) else { continue }
            outline.expandItem(items[index])
            stack.append(contentsOf: row.children)
        }
    }

    private func select(_ id: Int?, in outline: NSOutlineView) {
        guard let id, let comparison, let index = comparison.index(ofRow: id) else { return }
        var row = outline.row(forItem: items[index])
        var shown = index
        while row < 0, let parent = comparison.rows[shown].parent {
            shown = parent
            row = outline.row(forItem: items[shown])
        }
        let moved = id != lastSelected
        lastSelected = id
        guard row >= 0, row != outline.selectedRow else { return }
        outline.selectRowIndexes([row], byExtendingSelection: false)
        if moved { outline.scrollRowToVisible(row) }
    }

    private var selectedIndex: Int? {
        guard let outline, let item = outline.item(atRow: outline.selectedRow) as? CompareItem else { return nil }
        return item.index
    }

    func openSelected() {
        guard let index = selectedIndex else { return }
        model.openComparedSpan(row: index)
    }

    func copySelected() {
        guard let index = selectedIndex else { return }
        model.copyComparedSpanID(row: index)
    }

    @objc func openClicked(_ sender: Any?) {
        guard let outline, outline.clickedRow >= 0, let item = outline.item(atRow: outline.clickedRow) as? CompareItem else { return }
        model.openComparedSpan(row: item.index)
    }

    // MARK: Context menu

    func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let outline, let comparison, outline.clickedRow >= 0,
              let item = outline.item(atRow: outline.clickedRow) as? CompareItem else { return }
        let index = item.index
        let row = comparison.rows[index]
        let inA = ActionMenuItem.make("Open Span in A") { [model] in model.openComparedSpan(row: index, inA: true) }
        inA.isEnabled = !row.a.isEmpty && !row.isGroup
        let inB = ActionMenuItem.make("Open Span in B") { [model] in model.openComparedSpan(row: index, inA: false) }
        inB.isEnabled = !row.b.isEmpty && !row.isGroup
        let copy = ActionMenuItem.make("Copy Span ID") { [model] in model.copyComparedSpanID(row: index) }
        copy.isEnabled = !row.isGroup
        menu.autoenablesItems = false
        for entry in [inA, inB, .separator(), copy] { menu.addItem(entry) }
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let comparison else { return 0 }
        guard let item = item as? CompareItem else { return comparison.roots.count }
        return comparison.rows[item.index].children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let comparison else { return CompareItem(0) }
        guard let item = item as? CompareItem else { return items[comparison.roots[index]] }
        return items[comparison.rows[item.index].children[index]]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let comparison, let item = item as? CompareItem else { return false }
        return !comparison.rows[item.index].children.isEmpty
    }

    // MARK: Delegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let comparison, let item = item as? CompareItem, let column = tableColumn else { return nil }
        let index = item.index
        let row = comparison.rows[index]
        let slot = colors.slot(for: row.service)
        switch column.identifier {
        case .compareSpan:
            let cell = outlineView.makeView(withIdentifier: .compareSpan, owner: nil) as? CompareNameCell ?? CompareNameCell()
            cell.identifier = .compareSpan
            let hidden = collapsed.contains(row.id) ? row.descendantCount : 0
            cell.configure(title: row.isGroup ? "\(row.title) × \(CountFormat.string(max(row.aRuns, row.bRuns)))" : row.title,
                           service: comparison.shownService(of: index), colorSlot: slot,
                           mark: CompareMarks.kind(of: row), hidden: hidden,
                           label: comparison.accessibilityLabel(of: index))
            return cell
        case .compareA, .compareB, .compareChange:
            let cell = outlineView.makeView(withIdentifier: column.identifier, owner: nil) as? CompareTextCell ?? CompareTextCell()
            cell.identifier = column.identifier
            if column.identifier == .compareChange {
                // The change's own color; an Error is the octagon's in the Span column.
                let color: NSColor = switch row.change {
                case .slower, .repeated: StatusColors.warningNS
                case .same, .faster, .new, .missing: .secondaryLabelColor
                }
                cell.configure(text: comparison.changeText(of: index), color: color)
            } else {
                let inA = column.identifier == .compareA
                cell.configure(text: comparison.durationText(of: index, inA: inA),
                               color: (inA ? row.a : row.b).isEmpty ? .tertiaryLabelColor : .labelColor)
            }
            return cell
        default:
            let cell = outlineView.makeView(withIdentifier: .compareTimeline, owner: nil) as? CompareBarsCell ?? CompareBarsCell()
            cell.identifier = .compareTimeline
            let color = ServicePalette.nsColor(slot: slot)
            cell.configure(a: comparison.barFractions(of: index, inA: true), b: comparison.barFractions(of: index, inA: false),
                           colorA: row.aStatus == .error ? StatusColors.errorFillNS : color,
                           colorB: row.bStatus == .error ? StatusColors.errorFillNS : color)
            return cell
        }
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isApplying, let comparison, let index = selectedIndex else { return }
        let id = comparison.rows[index].id
        lastSelected = id
        if compare.selectedRow != id { compare.selectedRow = id }
    }

    func outlineViewItemDidExpand(_ notification: Notification) { changed(notification, collapsed: false) }

    func outlineViewItemDidCollapse(_ notification: Notification) { changed(notification, collapsed: true) }

    private func changed(_ notification: Notification, collapsed isCollapsed: Bool) {
        guard !isApplying, let comparison, let item = notification.userInfo?["NSObject"] as? CompareItem else { return }
        let id = comparison.rows[item.index].id
        if isCollapsed { collapsed.insert(id) } else { collapsed.remove(id) }
        let now = collapsed
        Task { @MainActor [compare] in compare.collapsed = now }
    }
}

/// The Span column: service dot, the change mark (icon in its color), the
/// title, and the service where it differs from the parent's.
final class CompareNameCell: NSTableCellView {
    private let dot = NSImageView()
    private let mark = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let service = NSTextField(labelWithString: "")
    private let spacer = NSView()

    init() {
        super.init(frame: .zero)
        for label in [title, service] {
            label.maximumNumberOfLines = 1
            label.cell?.wraps = false
            label.lineBreakMode = .byTruncatingTail
        }
        service.textColor = .secondaryLabelColor
        for view in [dot, mark, title, service] { view.setContentHuggingPriority(.required, for: .horizontal) }
        service.setContentCompressionResistancePriority(.init(249), for: .horizontal)
        title.setContentCompressionResistancePriority(.init(251), for: .horizontal)
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let stack = NSStackView(views: [dot, mark, title, service, spacer])
        stack.spacing = Space.xs
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        textField = title
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Space.xs),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Space.sm),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.cell)
        for view in [dot, mark, title, service] { view.setAccessibilityElement(false) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The mark shown, nil for Same (self-test).
    private(set) var shownMark: TraceComparison.Difference.Kind?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        dot.needsDisplay = true
    }

    func configure(title text: String, service shown: String?, colorSlot: Int, mark kind: TraceComparison.Difference.Kind?,
                   hidden: Int, label: String) {
        dot.image = ServiceDots.image(.waterfall, slot: colorSlot)
        shownMark = kind
        if let kind {
            mark.image = NSImage(systemSymbolName: CompareMarks.symbol(kind), accessibilityDescription: nil)
            mark.contentTintColor = CompareMarks.nsColor(kind)
            mark.isHidden = false
        } else {
            mark.isHidden = true
        }
        title.stringValue = text
        service.stringValue = shown ?? ""
        service.isHidden = shown == nil
        let named = shown.map { "\(text) · \($0)" } ?? text
        toolTip = hidden == 0 ? named : "\(named) (\(CountFormat.string(hidden)) rows)"
        setAccessibilityLabel(hidden == 0 ? label : "\(label), \(CountFormat.string(hidden)) rows")
    }
}

/// A, B and Change: one right-aligned line in monospaced digits.
final class CompareTextCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        label.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        label.alignment = .right
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Space.xs),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Space.sm),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var text: String { label.stringValue }

    func configure(text: String, color: NSColor) {
        label.stringValue = text
        label.textColor = color
        toolTip = text
    }
}

/// The Timeline: A's bar over B's on one scale, the longer trace's duration;
/// a side the row lacks draws no bar.
final class CompareBarsCell: NSTableCellView {
    private let bars = CompareBarsView()

    init() {
        super.init(frame: .zero)
        bars.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bars)
        NSLayoutConstraint.activate([
            bars.leadingAnchor.constraint(equalTo: leadingAnchor),
            bars.trailingAnchor.constraint(equalTo: trailingAnchor),
            bars.topAnchor.constraint(equalTo: topAnchor),
            bars.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(a: (start: Double, width: Double)?, b: (start: Double, width: Double)?, colorA: NSColor, colorB: NSColor) {
        bars.a = a
        bars.b = b
        bars.colorA = colorA
        bars.colorB = colorB
        bars.needsDisplay = true
    }
}

final class CompareBarsView: NSView {
    var a: (start: Double, width: Double)?
    var b: (start: Double, width: Double)?
    var colorA = ServicePalette.nsColor(slot: 0)
    var colorB = ServicePalette.nsColor(slot: 0)
    static let barHeight: CGFloat = 6
    static let gap: CGFloat = 2

    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let track = Timeline.track(in: bounds)
        NSColor.separatorColor.setFill()
        for quarter in Timeline.quarters {
            NSRect(x: (track.minX + quarter * track.width).rounded(), y: 0, width: 1, height: bounds.height).fill()
        }
        let top = (bounds.height - 2 * Self.barHeight - Self.gap) / 2
        for (fractions, color, y) in [(a, colorA, top), (b, colorB, top + Self.barHeight + Self.gap)] {
            guard let fractions else { continue }
            let rect = NSRect(x: track.minX + fractions.start * track.width, y: y,
                              width: max(2, fractions.width * track.width), height: Self.barHeight)
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: Radius.bar / 2, yRadius: Radius.bar / 2).fill()
            if effectiveAppearance.isHighContrast {
                let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: Radius.bar / 2, yRadius: Radius.bar / 2)
                border.lineWidth = 1
                StatusColors.contrastEdgeNS.setStroke()
                border.stroke()
            }
        }
    }
}
