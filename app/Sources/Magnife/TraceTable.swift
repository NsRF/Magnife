import AppKit
import MagnifeKit
import SwiftUI

/// The trace list's rows (S-004, S-030): a live NSTableView (LiveTable.swift)
/// with AppKit cells (TraceTableCells.swift) and the list's keys
/// (TraceTableKeys.swift).
struct TraceTable: NSViewRepresentable {
    let model: AppModel
    let rows: [TraceSummary]
    let findings: FindingCache
    let now: Date
    let colors: ServiceColors
    let selected: String?

    func makeCoordinator() -> TraceTableCoordinator { TraceTableCoordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        coordinator.flexibleColumn = .traceRoute
        let scroll = coordinator.makeScrollView(columns: [
            .init(id: .traceService, title: "Service", min: 64, ideal: 72, max: 200),
            .init(id: .traceRoute, title: "Route", min: 80, ideal: 98, max: 10_000),
            .init(id: .traceDuration, title: "Duration", min: 56, ideal: 56, max: 96, alignment: .right),
            .init(id: .traceSpans, title: "Spans", min: 52, ideal: 52, max: 80, alignment: .right),
            .init(id: .traceStatus, title: "Status", min: 64, ideal: 64, max: 96),
            .init(id: .traceTime, title: "Time", min: 88, ideal: 88, max: 140),
        ], label: "Traces", autosaveName: "TraceList")
        coordinator.table?.onKey = { [weak coordinator] event in coordinator?.handleKey(event) ?? false }
        coordinator.table?.onCopy = { [model] in model.copySelectedTraceID() }
        model.listScroller.attach(scroll)
        return scroll
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 520, height: proposal.height ?? 400)
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        StallLog.measure("trace table") {
            context.coordinator.update(rows: rows, findings: findings, now: now, colors: colors, selected: selected)
        }
    }
}

final class TraceTableCoordinator: LiveTableCoordinator {
    let model: AppModel
    /// The rows the table shows; the model's may be ahead by one paced update.
    private(set) var rows: [TraceSummary] = []
    private var findings = FindingCache()
    private var now = Date()
    private var colors = ServiceColors()
    /// The selection last taken from the model: the table scrolls only when it changes.
    private var lastSelected: String?

    init(model: AppModel) { self.model = model }

    func update(rows new: [TraceSummary], findings: FindingCache, now: Date, colors: ServiceColors, selected: String?) {
        take(new)
        // Badges, colors and the Time column redraw only their column of the rows on screen.
        let shown = IndexSet(integersIn: visibleRows)
        if findings != self.findings {
            let changed = shown.filteredIndexSet { findings.summary(for: rows[$0]) != self.findings.summary(for: rows[$0]) }
            self.findings = findings
            reloadVisible(changed, columns: [.traceRoute])
        }
        if colors != self.colors {
            self.colors = colors
            reloadVisible(shown, columns: [.traceService])
        }
        if now != self.now {
            self.now = now
            reloadVisible(shown, columns: [.traceTime])
        }
        select(selected)
    }

    /// New rows now, or at the pacer's next turn (the latest rows then).
    private func take(_ new: [TraceSummary]) {
        let update = RowUpdate.between(rows, new)
        guard mayApply(update, fromEmpty: rows.isEmpty, toEmpty: new.isEmpty,
                       again: { [weak self] in self?.take(self?.model.traces ?? new) }) else { return }
        rows = new
        perform(update)
        // The selection follows its trace, wherever the update moved it; the view does not.
        select(model.selectedTraceID)
    }

    private func select(_ id: String?) {
        let moved = id != lastSelected
        lastSelected = id
        select(row: id.flatMap { id in rows.firstIndex { $0.id == id } }, reveal: moved && !model.isListHeld)
    }

    // MARK: Rows

    override var rowCount: Int { rows.count }

    override func makeCell(_ column: NSUserInterfaceItemIdentifier, in table: NSTableView) -> NSView? {
        TraceTextCell.make(column, in: table)
    }

    override func fill(_ cell: NSView, column: NSUserInterfaceItemIdentifier, row: Int) {
        guard let cell = cell as? NSTableCellView else { return }
        let trace = rows[row]
        TraceTextCell.fill(cell, with: trace, findings: findings.summary(for: trace), now: now, colors: colors)
    }

    override func sentence(row: Int) -> String { model.rowAccessibilityLabel(rows[row]) }

    override func rowSelected(_ row: Int?) {
        let id = row.map { rows[$0].id }
        lastSelected = id
        if model.selectedTraceID != id { model.selectedTraceID = id }
    }

    override func lastRowAppeared() { model.loadMoreTraces() }

    /// A double-click on a row: into the waterfall (docs/ux.md, Keyboard map).
    override func doubleClicked(row: Int) { model.enterWaterfall() }

    override func menuItems(row: Int) -> [NSMenuItem] {
        let id = rows[row].traceID
        return [ActionMenuItem.make("Copy Trace ID") { [model] in model.copyTraceID(id) }]
    }
}
