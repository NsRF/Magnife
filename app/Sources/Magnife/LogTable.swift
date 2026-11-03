import AppKit
import MagnifeKit
import SwiftUI

/// The Logs list's rows (S-013, S-030): a live NSTableView (LiveTable.swift).
/// Time and Service are AppKit cells; Level and Body host their SwiftUI
/// views (`LogLevelLabel`, `LogBodyCell` with its Open Trace arrow), given values.
struct LogTable: NSViewRepresentable {
    let model: AppModel
    let rows: [LogListItem]
    let colors: ServiceColors
    let selected: LogListItem.ID?

    func makeCoordinator() -> LogTableCoordinator { LogTableCoordinator(model: model) }

    // Fixed Time and Level; Service's minimum fits "checkout-api"; Body takes the rest (PROGRESS decision 63).
    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        coordinator.flexibleColumn = .logBody
        let scroll = coordinator.makeScrollView(columns: [
            .init(id: .logTime, title: "Time", min: 96, ideal: 96, max: 96),
            .init(id: .logLevel, title: "Level", min: LogLevelLabel.width, ideal: LogLevelLabel.width, max: LogLevelLabel.width),
            .init(id: .logService, title: "Service", min: 124, ideal: 128, max: 200),
            .init(id: .logBody, title: "Body", min: 80, ideal: 108, max: 10_000),
        ], label: "Logs", autosaveName: "LogList")
        coordinator.table?.onKey = { [weak coordinator] event in coordinator?.handleKey(event) ?? false }
        coordinator.table?.onCopy = { [model] in model.copySelectedListLogBody() }
        model.logScroller.attach(scroll)
        return scroll
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 520, height: proposal.height ?? 400)
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        StallLog.measure("log table") { context.coordinator.update(rows: rows, colors: colors, selected: selected) }
    }
}

extension NSUserInterfaceItemIdentifier {
    static let logTime = NSUserInterfaceItemIdentifier("log-time")
    static let logLevel = NSUserInterfaceItemIdentifier("log-level")
    static let logService = NSUserInterfaceItemIdentifier("log-service")
    static let logBody = NSUserInterfaceItemIdentifier("log-body")
}

final class LogTableCoordinator: LiveTableCoordinator {
    let model: AppModel
    private(set) var rows: [LogListItem] = []
    private var colors = ServiceColors()
    private var lastSelected: LogListItem.ID?

    init(model: AppModel) { self.model = model }

    func update(rows new: [LogListItem], colors: ServiceColors, selected: LogListItem.ID?) {
        take(new)
        if colors != self.colors {
            self.colors = colors
            reloadVisible(IndexSet(integersIn: visibleRows), columns: [.logService])
        }
        select(selected)
    }

    private func take(_ new: [LogListItem]) {
        let update = RowUpdate.between(rows, new)
        guard mayApply(update, fromEmpty: rows.isEmpty, toEmpty: new.isEmpty,
                       again: { [weak self] in self?.take(self?.model.logs ?? new) }) else { return }
        rows = new
        perform(update)
        select(model.selectedLogID)
    }

    private func select(_ id: LogListItem.ID?) {
        let moved = id != lastSelected
        lastSelected = id
        select(row: id.flatMap { id in rows.firstIndex { $0.id == id } }, reveal: moved && !model.isLogListHeld)
    }

    override var rowCount: Int { rows.count }

    override func makeCell(_ column: NSUserInterfaceItemIdentifier, in table: NSTableView) -> NSView? {
        if let cell = table.makeView(withIdentifier: column, owner: nil) { return cell }
        switch column {
        case .logLevel: return HostingCell(identifier: column, view: LogLevelLabel(level: nil))
        case .logBody: return HostingCell(identifier: column, view: LogBodyCell(item: rows[0], openTrace: {}))
        default: return TraceTextCell(identifier: column, digits: column == .logTime)
        }
    }

    override func fill(_ cell: NSView, column: NSUserInterfaceItemIdentifier, row: Int) {
        let item = rows[row]
        if let cell = cell as? HostingCell<LogLevelLabel> {
            if cell.view.level != item.line.level { cell.view = LogLevelLabel(level: item.line.level) }
        } else if let cell = cell as? HostingCell<LogBodyCell> {
            if cell.view.item != item {
                let id = item.id
                cell.view = LogBodyCell(item: item) { [model] in model.openTrace(ofLog: id) }
            }
        } else if let cell = cell as? TraceTextCell {
            if column == .logTime {
                cell.configure(item.line.time, color: .secondaryLabelColor)
            } else {
                cell.configure(item.record.serviceName, image: TraceTextCell.dot,
                               imageTint: ServicePalette.nsColor(slot: colors.slot(for: item.record.serviceName)))
            }
        }
    }

    override func sentence(row: Int) -> String { rows[row].accessibilityLabel }

    override func rowSelected(_ row: Int?) {
        let id = row.map { rows[$0].id }
        lastSelected = id
        if model.selectedLogID != id { model.selectedLogID = id }
    }

    override func lastRowAppeared() { model.loadMoreLogs() }

    /// Return and double-click: Open Trace (docs/ux.md, Keyboard map).
    override func doubleClicked(row: Int) { model.openTrace(ofLog: rows[row].id) }

    override func menuItems(row: Int) -> [NSMenuItem] {
        let item = rows[row]
        var items: [NSMenuItem] = []
        if item.hasTrace {
            items.append(ActionMenuItem.make("Open Trace", enabled: item.canOpenTrace) { [model] in
                model.openTrace(ofLog: item.id)
            })
        }
        items.append(ActionMenuItem.make("Copy Body") { [model] in model.copyBody(item.record.body) })
        if let traceID = item.record.traceID, item.hasTrace {
            items.append(ActionMenuItem.make("Copy Trace ID") { [model] in model.copyTraceID(traceID) })
        }
        return items
    }

    // MARK: Keys

    /// The Logs list's keys (docs/ux.md, Keyboard map): Esc hides the filter
    /// bar, Return opens the log's trace, Home / End / Page Up / Page Down
    /// and ⌘↑ / ⌘↓ move the selection, Tab moves to the next column.
    func handleKey(_ event: NSEvent) -> Bool {
        let held = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch event.keyCode {
        case 53:
            guard held.isEmpty, model.showsLogFilterBar else { return false }
            model.hideLogFilterBar()
        case 36, 76:
            guard held.isEmpty, let id = model.selectedLogID else { return false }
            model.openTrace(ofLog: id)
        case 48:
            guard held.isSubset(of: .shift) else { return false }
            model.focusNextColumn(from: .list, backward: held == .shift)
        case 125, 126:
            guard held == .command else { return false }
            model.moveLogSelection(event.keyCode == 126 ? .first : .last)
        case 115, 119, 116, 121:
            guard held.isEmpty else { return false }
            let page = model.pageRows(model.logScroller)
            let move: ListMove = switch event.keyCode {
            case 115: .first
            case 119: .last
            case 116: .pageUp(page)
            default: .pageDown(page)
            }
            model.moveLogSelection(move)
        default:
            return false
        }
        return true
    }
}

/// A cell that hosts a SwiftUI view given values, in its own hosting view,
/// sized by the cell (it never asks the table for a height).
final class HostingCell<Content: View>: NSTableCellView {
    private let host: NSHostingView<LeadingView<Content>>
    var view: Content {
        get { host.rootView.content }
        set { host.rootView = LeadingView(content: newValue) }
    }

    init(identifier: NSUserInterfaceItemIdentifier, view: Content) {
        host = NSHostingView(rootView: LeadingView(content: view))
        super.init(frame: .zero)
        self.identifier = identifier
        host.sizingOptions = []
        // Frames, not constraints (TraceTextCell, S-030).
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        addSubview(host)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The row reads its sentence once (its arrow stays a button for Full Keyboard Access only).
    override func accessibilityChildren() -> [Any]? { [] }
}

/// A hosting view centers its content: cells start at their leading edge.
struct LeadingView<Content: View>: View {
    let content: Content

    var body: some View {
        content.frame(maxWidth: .infinity, alignment: .leading)
    }
}
