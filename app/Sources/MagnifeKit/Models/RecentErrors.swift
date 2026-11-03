import Foundation

/// The menu bar extra's Recent Errors (S-026, docs/ux.md "Menu bar extra"):
/// the last five traces with errors, newest first, and the icon's count of
/// traces with an error since the menu was last opened.
///
/// The count is the traces the helper's batch lines named in
/// `error_traces` (status became Error in that batch) since the menu was
/// last opened, so a trace counts once, when it fails: a late span on a
/// trace that already failed never counts it again (M3 review 3), and
/// traces stored before launch are not new. The list is read in every
/// refresh (`TelemetryReader.recentErrors`).
public struct RecentErrors: Sendable, Equatable {
    public static let limit = 5
    public static let title = "Recent Errors"
    public static let emptyTitle = "No traces with errors"

    /// The newest traces with an error, newest first.
    public private(set) var traces: [TraceSummary] = []
    /// The traces that failed since the menu was last opened.
    public private(set) var newTraceIDs: Set<String> = []

    public init() {}

    /// Traces with errors since the menu was last opened: the red icon's count.
    public var newCount: Int { newTraceIDs.count }

    /// A read of the newest traces with an error.
    public mutating func apply(_ traces: [TraceSummary]) {
        self.traces = traces
    }

    /// A batch line's `error_traces`: the traces whose status became Error in it.
    public mutating func failed(_ traceIDs: [String]) {
        newTraceIDs.formUnion(traceIDs)
    }

    /// The menu opened: the count and the red icon reset.
    public mutating func opened() {
        newTraceIDs = []
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
