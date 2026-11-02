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

    func update(newTraceCount: Int) {
        if self.newTraceCount != newTraceCount { self.newTraceCount = newTraceCount }
    }
}
