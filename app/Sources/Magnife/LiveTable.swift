import AppKit
import MagnifeKit

/// The live lists (the trace list and the Logs list, S-030) are NSTableViews
/// fed one change per update. SwiftUI's Table diffed its rows inside its own
/// graph updates, which AppKit could start while the table was in one of its
/// delegate callbacks ("reentrant operation in its NSTableView delegate",
/// FIXLOG). Here a change goes in only from `update` (SwiftUI's
/// updateNSView), never from inside a table callback; rows that come or go
/// go in at most every 250 ms (`UpdatePacer`), without an animation under
/// load or with Reduce Motion; cells are AppKit views, or hosting views given
/// values, never the model. Subclasses hold the typed rows.
class LiveTableCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    struct Column {
        var id: NSUserInterfaceItemIdentifier
        var title: String
        var min: CGFloat
        var ideal: CGFloat
        var max: CGFloat
        var alignment: NSTextAlignment = .natural
    }

    weak var table: LiveTableView?
    /// The column that takes the width the others leave.
    var flexibleColumn: NSUserInterfaceItemIdentifier?
    private var pacer = UpdatePacer()
    private var waitTask: Task<Void, Never>?
    private var retry: (() -> Void)?
    /// True while this coordinator changes the table, so its selection callback does not write back.
    private(set) var isApplying = false
    /// Above zero inside a table callback, where the table must not change.
    private var callbackDepth = 0
    private let clock = ContinuousClock()
    private lazy var start = clock.now
    private var seconds: TimeInterval { (clock.now - start).seconds }

    // MARK: For subclasses

    var rowCount: Int { 0 }
    /// A new or reused cell for the column.
    func makeCell(_ column: NSUserInterfaceItemIdentifier, in table: NSTableView) -> NSView? { nil }
    /// Fills a cell, new or on screen, with the row's value for the column.
    func fill(_ cell: NSView, column: NSUserInterfaceItemIdentifier, row: Int) {}
    /// What VoiceOver reads for the row: one sentence (the cells are hidden from it).
    func sentence(row: Int) -> String { "" }
    func rowSelected(_ row: Int?) {}
    func lastRowAppeared() {}
    func doubleClicked(row: Int) {}
    func menuItems(row: Int) -> [NSMenuItem] { [] }

    // MARK: Building the table

    func makeScrollView(columns: [Column], label: String, autosaveName: String) -> NSScrollView {
        let table = LiveTableView()
        for spec in columns {
            let column = NSTableColumn(identifier: spec.id)
            column.title = spec.title
            column.minWidth = spec.min
            column.width = spec.ideal
            column.maxWidth = spec.max
            column.headerCell.alignment = spec.alignment
            column.resizingMask = .userResizingMask
            table.addTableColumn(column)
        }
        // The flexible column takes what the others leave (`fitColumns`, on every tile).
        table.columnAutoresizingStyle = .noColumnAutoresizing
        // Full-width stripes, as the lists had as SwiftUI Tables.
        table.style = .fullWidth
        table.rowHeight = 24
        // 8 pt between columns, not AppKit's 17: the room goes to the flexible column (PROGRESS, M2 E2E 10).
        table.intercellSpacing = NSSize(width: Space.sm, height: 0)
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.allowsColumnReordering = false
        table.focusRingType = .none
        table.setAccessibilityLabel(label)
        // Column widths are remembered (docs/ux.md); test runs start at the ideal widths.
        if !StoreLocation.isOverridden() {
            table.autosaveName = autosaveName
            table.autosaveTableColumns = true
        }
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClick)
        let menu = NSMenu()
        menu.delegate = self
        // Items say themselves whether they apply (Open Trace on a log without spans).
        menu.autoenablesItems = false
        table.menu = menu
        self.table = table

        let scroll = WaterfallScrollView()
        scroll.onTile = { [weak self] in self?.fitColumns() }
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        return scroll
    }

    /// The flexible column takes the width the others leave; its minimum stays.
    func fitColumns() {
        guard let table, let scroll = table.enclosingScrollView, let id = flexibleColumn,
              let flexible = table.tableColumn(withIdentifier: id), table.numberOfColumns > 0 else { return }
        // The style's inset is the same on both sides: the first column's leading edge.
        let used = table.rect(ofColumn: table.numberOfColumns - 1).maxX + table.rect(ofColumn: 0).minX
        let wanted = max(flexible.minWidth, (flexible.width + scroll.contentView.bounds.width - used).rounded(.down))
        if abs(flexible.width - wanted) >= 1 { flexible.width = wanted }
    }

    // MARK: Updates

    /// True when `update` may go in now. Otherwise `again` runs when the pacer
    /// allows it (the latest `again` wins), and the subclass keeps its rows.
    func mayApply(_ update: RowUpdate, fromEmpty: Bool, toEmpty: Bool, again: @escaping () -> Void) -> Bool {
        let delay = pacer.delay(for: update, at: seconds, fromEmpty: fromEmpty, toEmpty: toEmpty)
        guard delay > 0 || callbackDepth > 0 else {
            retry = nil
            return true
        }
        retry = again
        if waitTask == nil {
            waitTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard let self else { return }
                self.waitTask = nil
                let again = self.retry
                self.retry = nil
                again?()
            }
        }
        return false
    }

    /// Takes `update` into the table: the subclass has set its rows already.
    func perform(_ update: RowUpdate) {
        guard let table else { return }
        let busy = pacer.isBusy(at: seconds)
        applying {
            switch update {
            case .none:
                break
            case .reload:
                table.reloadData()
            case .changes(let removed, let inserted, let changed):
                if !removed.isEmpty || !inserted.isEmpty {
                    // A fade when rows come now and then; none under load or with Reduce Motion (S-030 Access).
                    let animation: NSTableView.AnimationOptions =
                        busy || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? [] : .effectFade
                    table.beginUpdates()
                    table.removeRows(at: removed, withAnimation: [])
                    table.insertRows(at: inserted, withAnimation: animation)
                    table.endUpdates()
                }
                reloadVisible(changed)
            }
        }
        pacer.applied(update, at: seconds)
        table.usesAlternatingRowBackgroundColors = rowCount > 0
    }

    /// Fills the cells of rows on screen again (of `columns`, or all of
    /// them), in place; the others are drawn fresh when they scroll in.
    /// Not `reloadData(forRowIndexes:)`: it walks every row view the table
    /// keeps and rebuilds the key view loop for each, seconds once the list
    /// was scrolled through thousands of rows (sampled under load, S-030).
    func reloadVisible(_ indexes: IndexSet, columns: [NSUserInterfaceItemIdentifier]? = nil) {
        guard let table else { return }
        let rows = indexes.intersection(IndexSet(integersIn: visibleRows))
        guard !rows.isEmpty else { return }
        let ids = columns ?? table.tableColumns.map(\.identifier)
        let columnIndexes = ids.map { (id: $0, index: table.column(withIdentifier: $0)) }.filter { $0.index >= 0 }
        applying {
            for row in rows {
                // Rows from `visibleRows` are real rows: never -1 here (FIXLOG).
                for column in columnIndexes {
                    if let cell = table.view(atColumn: column.index, row: row, makeIfNecessary: false) {
                        fill(cell, column: column.id, row: row)
                    }
                }
                (table.rowView(atRow: row, makeIfNecessary: false) as? LiveRowView)?.sentence = sentence(row: row)
            }
        }
    }

    var visibleRows: Range<Int> {
        guard let table else { return 0..<0 }
        let range = table.rows(in: table.visibleRect)
        return range.location..<max(range.location, min(NSMaxRange(range), rowCount))
    }

    /// Selects `row` (nil: no row shows the selection), scrolling to it when asked.
    func select(row: Int?, reveal: Bool) {
        guard let table else { return }
        applying {
            if let row {
                if table.selectedRow != row { table.selectRowIndexes([row], byExtendingSelection: false) }
                if reveal { table.scrollRowToVisible(row) }
            } else if table.selectedRow >= 0 {
                table.deselectAll(nil)
            }
        }
    }

    private func applying(_ body: () -> Void) {
        let was = isApplying
        isApplying = true
        body()
        isApplying = was
    }

    // MARK: Data source and delegate

    func numberOfRows(in tableView: NSTableView) -> Int { rowCount }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn, row < rowCount else { return nil }
        callbackDepth += 1
        defer { callbackDepth -= 1 }
        // The last row came into view: the next page, out of this callback (S-004).
        if row == rowCount - 1, column === tableView.tableColumns.first {
            Task { @MainActor [weak self] in self?.lastRowAppeared() }
        }
        guard let cell = makeCell(column.identifier, in: tableView) else { return nil }
        fill(cell, column: column.identifier, row: row)
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = tableView.makeView(withIdentifier: .liveRow, owner: nil) as? LiveRowView ?? LiveRowView()
        view.identifier = .liveRow
        if row < rowCount { view.sentence = sentence(row: row) }
        return view
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isApplying, let table else { return }
        let row = table.selectedRow
        rowSelected(row >= 0 && row < rowCount ? row : nil)
    }

    @objc private func doubleClick() {
        guard let row = table?.clickedRow, row >= 0, row < rowCount else { return }
        doubleClicked(row: row)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let row = table?.clickedRow, row >= 0, row < rowCount else { return }
        for item in menuItems(row: row) { menu.addItem(item) }
    }
}

/// Keys go to the coordinator first (S-022); ⌘C copies what the list copies.
final class LiveTableView: NSTableView {
    var onKey: ((NSEvent) -> Bool)?
    var onCopy: (() -> Void)?

    @objc func copy(_ sender: Any?) { onCopy?() }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) == true { return }
        super.keyDown(with: event)
    }
}

/// A row VoiceOver reads as one sentence (S-004, S-013 Access).
final class LiveRowView: NSTableRowView {
    var sentence = "" {
        didSet { if sentence != oldValue { setAccessibilityLabel(sentence) } }
    }

    override func accessibilityChildren() -> [Any]? { [] }
}

/// A menu item that runs a closure (the lists' context menus); the item
/// keeps its action object as its represented object.
@MainActor
enum ActionMenuItem {
    private final class Action: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
        @objc func fire() { run() }
    }

    static func make(_ title: String, enabled: Bool = true, run: @escaping () -> Void) -> NSMenuItem {
        let action = Action(run)
        let item = NSMenuItem(title: title, action: #selector(Action.fire), keyEquivalent: "")
        item.target = action
        item.representedObject = action
        item.isEnabled = enabled
        return item
    }
}

extension NSUserInterfaceItemIdentifier {
    static let liveRow = NSUserInterfaceItemIdentifier("live-row")
}
