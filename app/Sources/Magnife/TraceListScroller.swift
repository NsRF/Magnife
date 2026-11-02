import AppKit
import SwiftUI

/// Watches the trace list's scroll position (S-004). SwiftUI's Table has no
/// scroll offset on macOS, so a zero-size view inside a cell finds the
/// NSScrollView around the table, and this reports when the list leaves or
/// reaches the top. It also scrolls back to the top for Show Newest Traces.
final class TraceListScroller {
    /// Within this many points of the top counts as at the top.
    static let tolerance: CGFloat = 4

    private(set) weak var scrollView: NSScrollView?
    private(set) var isAwayFromTop = false
    var onChange: ((Bool) -> Void)?
    private var observer: (any NSObjectProtocol)?

    func attach(_ scrollView: NSScrollView) {
        guard scrollView !== self.scrollView else { return }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        self.scrollView = scrollView
        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        update()
    }

    /// The table inside the scroll view (SwiftUI may wrap it in a container).
    var tableView: NSTableView? {
        func find(_ view: NSView?) -> NSTableView? {
            guard let view else { return nil }
            if let table = view as? NSTableView { return table }
            for child in view.subviews { if let table = find(child) { return table } }
            return nil
        }
        return find(scrollView?.documentView)
    }

    /// Where the rows start: under the toolbar's inset and the column headers.
    private var topY: CGFloat {
        guard let scrollView else { return 0 }
        return -scrollView.contentInsets.top - (tableView?.headerView?.frame.height ?? 0)
    }

    /// How far the list is scrolled down from its top, in points.
    var offset: CGFloat {
        guard let scrollView else { return 0 }
        return scrollView.contentView.bounds.minY - topY
    }

    /// The first row under the headers, and how many rows the table has, for the self-test.
    var firstVisibleRow: Int? {
        guard let scrollView, let table = tableView else { return nil }
        // Half a row down: the table pads its first row from the top.
        let point = scrollView.contentView.convert(NSPoint(x: 1, y: scrollView.contentView.bounds.minY - topY + 12),
                                                   to: table)
        let row = table.row(at: point)
        return row >= 0 ? row : nil
    }

    var rowCount: Int { tableView?.numberOfRows ?? 0 }

    func scrollToTop() {
        scroll(toOffset: 0)
    }

    /// The row's frame in the scroll view's clip view, under the headers.
    private func frame(ofRow row: Int) -> NSRect? {
        guard let scrollView, let table = tableView, row >= 0, row < table.numberOfRows else { return nil }
        return table.convert(table.rect(ofRow: row), to: scrollView.contentView)
    }

    /// True when the whole row shows below the column headers (S-010).
    func isRowVisible(_ row: Int) -> Bool {
        guard let scrollView, let rect = frame(ofRow: row) else { return false }
        let bounds = scrollView.contentView.bounds
        return rect.minY >= bounds.minY - topY - 1 && rect.maxY <= bounds.maxY + 1
    }

    /// After a read changed the rows (Resume, Open Trace, Search): waits, up
    /// to a second, until the table shows `rows()` rows, since a row index
    /// means nothing before that (FIXLOG); then brings `row()` into view, or
    /// scrolls to the top when it is nil. Returns whether the list is away
    /// from the top afterwards, so it holds still there.
    func reveal(row: () -> Int?, once rows: () -> Int) async -> Bool {
        for _ in 0..<50 where rowCount != rows() {
            try? await Task.sleep(for: .milliseconds(20))
        }
        if let row = row() { reveal(row: row) } else { scrollToTop() }
        return isAwayFromTop
    }

    /// Scrolls the row to the middle of the list when it does not show (Resume, S-010).
    func reveal(row: Int) {
        guard !isRowVisible(row), let scrollView, let rect = frame(ofRow: row) else { return }
        // The rows' height under the headers; an offset of y puts the
        // document's y at the top of the rows.
        let rows = scrollView.contentView.bounds.height + topY
        scroll(toOffset: max(0, rect.minY - rows / 2))
    }

    /// Scrolls so the list's top is `offset` points above the visible top.
    func scroll(toOffset offset: CGFloat) {
        guard let scrollView else { return }
        let clip = scrollView.contentView
        let wanted = NSRect(origin: NSPoint(x: clip.bounds.minX, y: topY + offset),
                            size: clip.bounds.size)
        clip.scroll(to: clip.constrainBoundsRect(wanted).origin)
        scrollView.reflectScrolledClipView(clip)
        update()
    }

    private func update() {
        let away = offset > Self.tolerance
        guard away != isAwayFromTop else { return }
        isAwayFromTop = away
        // Bounds change while the table lays out its rows; changing the
        // model inside that pass is a "reentrant operation in its
        // NSTableView delegate". Report on the next turn of the run loop.
        Task { @MainActor [weak self] in self?.onChange?(away) }
    }
}

/// The zero-size view a trace list cell carries to reach the table's scroll view.
struct TraceListAnchor: NSViewRepresentable {
    let scroller: TraceListScroller

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.scroller = scroller
        return view
    }

    func updateNSView(_ view: AnchorView, context: Context) {
        view.scroller = scroller
    }

    final class AnchorView: NSView {
        var scroller: TraceListScroller?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil, let scrollView = enclosingScrollView { scroller?.attach(scrollView) }
        }
    }
}

/// Menu items whose state the SwiftUI commands cannot observe on AppModel
/// (swift-swiftui, "Menu commands").
final class MenuState: ObservableObject {
    static let shared = MenuState()
    /// Trace > Show Newest Traces is enabled while this is above zero.
    @Published private(set) var newTraceCount = 0

    /// Trace > Pause reads "Resume" while paused (S-010).
    @Published private(set) var isPaused = false

    func update(isPaused: Bool) {
        if self.isPaused != isPaused { self.isPaused = isPaused }
    }

    /// Expand All Spans and Collapse All Spans are enabled while a waterfall shows.
    @Published private(set) var hasWaterfall = false

    func update(newTraceCount: Int) {
        if self.newTraceCount != newTraceCount { self.newTraceCount = newTraceCount }
    }

    func update(hasWaterfall: Bool) {
        if self.hasWaterfall != hasWaterfall { self.hasWaterfall = hasWaterfall }
    }

    /// Edit > Copy Stack Trace is enabled while the selected span has an exception with one.
    @Published private(set) var hasStackTrace = false

    func update(hasStackTrace: Bool) {
        if self.hasStackTrace != hasStackTrace { self.hasStackTrace = hasStackTrace }
    }

    /// Edit > Copy Body is enabled while a Trace Logs row is selected (S-012).
    @Published private(set) var hasSelectedLog = false

    func update(hasSelectedLog: Bool) {
        if self.hasSelectedLog != hasSelectedLog { self.hasSelectedLog = hasSelectedLog }
    }

    /// The current view's filter bar (S-014): View > Show Filter Bar / Hide
    /// Filter Bar, and Clear Filters while any filter is on.
    enum FilterBar { case unavailable, hidden, shown }
    @Published private(set) var filterBar: FilterBar = .unavailable
    @Published private(set) var hasFilters = false

    func update(filterBar: FilterBar, hasFilters: Bool) {
        if self.filterBar != filterBar { self.filterBar = filterBar }
        if self.hasFilters != hasFilters { self.hasFilters = hasFilters }
    }

    /// Traces or Logs: the View and Trace menus follow it (S-013).
    @Published private(set) var contentMode: ContentMode = .traces

    func update(contentMode: ContentMode) {
        if self.contentMode != contentMode { self.contentMode = contentMode }
    }

    /// Trace > Open Trace is enabled while the selected log's trace has stored spans.
    @Published private(set) var canOpenTrace = false

    func update(canOpenTrace: Bool) {
        if self.canOpenTrace != canOpenTrace { self.canOpenTrace = canOpenTrace }
    }

    /// File > Save Filter…, Save Filter As…, Rename Filter… and Delete Filter (S-021).
    struct SavedFilterItems: Equatable {
        var canSave = false
        var saveTitle = "Save Filter…"
        var canSaveAs = false
        var hasSelected = false
        var canDelete = false
    }
    @Published private(set) var savedFilters = SavedFilterItems()

    func update(savedFilters: SavedFilterItems) {
        if self.savedFilters != savedFilters { self.savedFilters = savedFilters }
    }

    /// Edit > Copy Trace ID: a trace row, or a log with a trace id, is selected.
    @Published private(set) var hasTraceID = false

    func update(hasTraceID: Bool) {
        if self.hasTraceID != hasTraceID { self.hasTraceID = hasTraceID }
    }

    /// View > Show Span Detail reads "Hide Span Detail" while the pane shows.
    @Published private(set) var showsSpanDetail = true

    func update(showsSpanDetail: Bool) {
        if self.showsSpanDetail != showsSpanDetail { self.showsSpanDetail = showsSpanDetail }
    }
}
