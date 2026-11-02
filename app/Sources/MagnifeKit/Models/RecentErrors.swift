import Foundation

/// One read for the menu bar extra (S-026): the newest traces with an error,
/// how many traces with an error changed after `mark`, and the last seq.
public struct RecentErrorsPage: Sendable, Equatable {
    public var traces: [TraceSummary]
    public var newCount: Int
    /// The seq the count started from; nil when nothing was counted (the first read).
    public var mark: Int64?
    public var lastSeq: Int64

    public init(traces: [TraceSummary], newCount: Int, mark: Int64?, lastSeq: Int64) {
        self.traces = traces
        self.newCount = newCount
        self.mark = mark
        self.lastSeq = lastSeq
    }
}

/// The menu bar extra's Recent Errors (S-026, docs/ux.md "Menu bar extra"):
/// the last five traces with errors, newest first, and the icon's count of
/// traces with an error since the menu was last opened.
///
/// The count is the traces with status Error whose `updated_seq` is after
/// the seq the menu was last opened at (at launch: the first read's seq, so
/// traces stored before launch are not new). A trace counts once however
/// many batches change it.
public struct RecentErrors: Sendable, Equatable {
    public static let limit = 5
    public static let title = "Recent Errors"
    public static let emptyTitle = "No traces with errors"

    /// The newest traces with an error, newest first.
    public private(set) var traces: [TraceSummary] = []
    /// Traces with an error since the menu was last opened: the red icon's count.
    public private(set) var newCount = 0
    /// The seq the menu was last opened at; nil until the first read.
    public private(set) var mark: Int64?
    /// The newest seq read.
    public private(set) var lastSeq: Int64 = 0

    public init(mark: Int64? = nil) {
        self.mark = mark
    }

    /// A read's result. The first read starts the count at its seq. A count
    /// read from another mark (the menu opened during the read) is dropped,
    /// so opening the menu always resets it.
    public mutating func apply(_ page: RecentErrorsPage) {
        traces = page.traces
        lastSeq = max(lastSeq, page.lastSeq)
        guard let mark else {
            self.mark = page.lastSeq
            newCount = 0
            return
        }
        if page.mark == mark { newCount = page.newCount }
    }

    /// The menu opened: the count and the red icon reset.
    public mutating func opened() {
        mark = lastSeq
        newCount = 0
    }

    /// The count next to the red icon: nil at zero, "99+" above 99.
    public static func badge(count: Int) -> String? {
        count <= 0 ? nil : count > 99 ? "99+" : "\(count)"
    }

    /// What VoiceOver reads for the icon: "Magnife, 3 new traces with errors" or "Magnife".
    public static func iconLabel(count: Int) -> String {
        switch count {
        case ...0: "Magnife"
        case 1: "Magnife, 1 new trace with an error"
        default: "Magnife, \(count) new traces with errors"
        }
    }

    /// True when two lists read the same in the menu (trace, route, service,
    /// start), whatever else changed on the traces (spans, seqs).
    public static func showSame(_ a: [TraceSummary], _ b: [TraceSummary]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy {
            $0.traceID == $1.traceID && $0.route == $1.route && $0.rootService == $1.rootService && $0.startNs == $1.startNs
        }
    }

    /// A Recent Errors item: "POST /orders · checkout-api · 2 min ago".
    public static func itemTitle(_ trace: TraceSummary, now: Date) -> String {
        "\(trace.route) · \(trace.rootService) · \(RelativeTime.string(for: trace.start, now: now))"
    }
}
