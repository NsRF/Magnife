import AppKit
import MagnifeKit

/// Keyboard navigation between the columns (S-022, docs/ux.md "Keyboard
/// map"): → or Return in the trace list moves into the waterfall on the
/// root span, Return there opens the span detail and moves into it, Esc
/// steps back (span detail -> waterfall -> trace list), Space shows or
/// hides the span detail, and Tab moves column to column. AppKit tables
/// take the focus directly; the SwiftUI columns follow `focusRequest`.
extension AppModel {
    /// A column to focus; `serial` makes each request a change, even for the same column.
    struct FocusRequest: Equatable {
        var column: FocusColumn
        var serial: Int
    }

    /// The columns that show now, for Tab.
    var focusableColumns: Set<FocusColumn> {
        var columns: Set<FocusColumn> = [.sidebar, .list]
        if showsFilterBar { columns.insert(.filterBar) }
        if contentMode == .traces, !waterfall.isEmpty {
            columns.insert(.waterfall)
            if showsSpanDetail { columns.insert(.spanDetail) }
        }
        return columns
    }

    /// Moves the keyboard focus to a column.
    func focus(_ column: FocusColumn) {
        switch column {
        case .list:
            let table = contentMode == .traces ? listScroller.tableView : logScroller.tableView
            if let table { table.window?.makeFirstResponder(table) }
        case .waterfall:
            if selectedSpanID == nil { selectedSpanID = waterfall.rootSpanID }
            if let outline = waterfallOutline { outline.window?.makeFirstResponder(outline) }
        case .filterBar:
            if contentMode == .traces { focusesTraceFilterField = true } else { focusesLogFilterField = true }
        case .sidebar, .spanDetail:
            break
        }
        unconsumedFocus = column
        focusRequest = FocusRequest(column: column, serial: (focusRequest?.serial ?? 0) + 1)
    }

    /// A SwiftUI column takes the focus once per request, never again when it reappears.
    func takeFocusRequest(_ column: FocusColumn) -> Bool {
        guard unconsumedFocus == column else { return false }
        unconsumedFocus = nil
        return true
    }

    /// Tab and ⇧Tab in a column.
    func focusNextColumn(from column: FocusColumn, backward: Bool) {
        focus(FocusColumn.next(after: column, backward: backward, available: focusableColumns))
    }

    /// → or Return in the trace list: the waterfall, on its root span, once it is built.
    func enterWaterfall() {
        guard contentMode == .traces, let id = selectedTraceID else { return }
        Task {
            for _ in 0..<50 where waterfall.isEmpty || openTrace?.id != id {
                try? await Task.sleep(for: .milliseconds(20))
            }
            guard selectedTraceID == id, !waterfall.isEmpty else { return }
            selectedSpanID = waterfall.rootSpanID
            // After the outline has applied the selection.
            try? await Task.sleep(for: .milliseconds(10))
            focus(.waterfall)
        }
    }

    /// Return in the waterfall: the span detail on Span, with the focus in it.
    func enterSpanDetail() {
        guard selectedSpanID != nil else { return }
        showSpanDetailTab(.span)
        focus(.spanDetail)
    }

    /// Esc in the waterfall: the filter bar first, then back to the trace list.
    func leaveWaterfall() {
        if showsTraceFilterBar { return hideTraceFilterBar() }
        focus(.list)
    }

    /// Esc in the span detail: the filter bar first, then back to the waterfall.
    func leaveSpanDetail() {
        if showsTraceFilterBar { return hideTraceFilterBar() }
        focus(.waterfall)
    }

    /// Home, End, ⌘↑, ⌘↓, Page Up and Page Down in the trace list.
    func moveTraceSelection(_ move: ListMove) {
        let current = traces.firstIndex { $0.id == selectedTraceID }
        guard let index = move.index(from: current, count: traces.count) else { return }
        selectedTraceID = traces[index].id
        reveal(row: index, in: listScroller)
    }

    /// The same keys in the Logs list.
    func moveLogSelection(_ move: ListMove) {
        let current = logs.firstIndex { $0.id == selectedLogID }
        guard let index = move.index(from: current, count: logs.count) else { return }
        selectedLogID = logs[index].id
        reveal(row: index, in: logScroller)
    }

    /// The rows one page holds in a list.
    func pageRows(_ scroller: TraceListScroller) -> Int {
        guard let table = scroller.tableView, let scrollView = scroller.scrollView, table.rowHeight > 0 else { return 10 }
        return max(1, Int(scrollView.contentView.bounds.height / (table.rowHeight + table.intercellSpacing.height)) - 1)
    }

    private func reveal(row: Int, in scroller: TraceListScroller) {
        // After SwiftUI has applied the selection to the table.
        Task { @MainActor in scroller.tableView?.scrollRowToVisible(row) }
    }

    /// Edit > Copy Trace ID and ⌘C on a trace row: the selected trace's
    /// ID; in the Logs view, the selected log's trace.
    func copySelectedTraceID(to pasteboard: NSPasteboard = .general) {
        let id = contentMode == .traces ? selectedTraceID : logs.first { $0.id == selectedLogID }?.record.traceID
        guard let id, !id.isEmpty else { return }
        copyTraceID(id, to: pasteboard)
    }

    /// Edit > Copy Trace ID applies.
    var hasSelectedTraceID: Bool {
        contentMode == .traces ? selectedTraceID != nil : logs.first { $0.id == selectedLogID }?.hasTrace == true
    }

    func updateTraceIDMenu() {
        MenuState.shared.update(hasTraceID: hasSelectedTraceID)
    }
}
