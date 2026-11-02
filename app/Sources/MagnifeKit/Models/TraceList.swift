import Foundation

// The live trace list (S-004): pages read from the database, and the rules
// for holding the list still while you are scrolled away from the top
// (design decision 6, the same mechanism Pause uses in S-010).

/// A page of the trace list and the seq of the last batch it reflects, read
/// in one transaction so no trace falls between the two.
public struct TracePage: Sendable, Equatable {
    public var traces: [TraceSummary]
    public var services: [ServiceSummary]
    public var lastSeq: Int64

    public init(traces: [TraceSummary], services: [ServiceSummary], lastSeq: Int64) {
        self.traces = traces
        self.services = services
        self.lastSeq = lastSeq
    }
}

/// What changed while the list holds still: rows that already existed when
/// it started holding and changed since, and how many traces are new.
public struct HeldTraces: Sendable, Equatable {
    public var updated: [TraceSummary]
    public var newCount: Int
    public var services: [ServiceSummary]
    public var lastSeq: Int64

    public init(updated: [TraceSummary], newCount: Int, services: [ServiceSummary], lastSeq: Int64) {
        self.updated = updated
        self.newCount = newCount
        self.services = services
        self.lastSeq = lastSeq
    }
}

public enum TraceList {
    /// Rows read per page (docs/ux.md, S-030).
    public static let pageSize = 200
    /// At most this many changed rows are read per refresh while holding.
    public static let heldUpdateLimit = 1_000

    /// The held list with changed rows replaced where they are: a trace still
    /// receiving spans updates its row without moving it, and rows that are
    /// not shown stay out.
    public static func applying(_ updated: [TraceSummary], to rows: [TraceSummary]) -> [TraceSummary] {
        guard !updated.isEmpty else { return rows }
        let byID = Dictionary(updated.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return rows.map { byID[$0.id] ?? $0 }
    }

    /// The next page appended below the rows already shown, without the ones
    /// shown already (a trace whose start moved can match both).
    public static func appending(_ page: [TraceSummary], to rows: [TraceSummary]) -> [TraceSummary] {
        let shown = Set(rows.map(\.id))
        return rows + page.filter { !shown.contains($0.id) }
    }

    /// The floating button and its menu item: "12 new traces", "1 new trace".
    public static func newTracesTitle(_ count: Int) -> String {
        count == 1 ? "1 new trace" : "\(count.formatted()) new traces"
    }

    /// A span count: "18 spans", "1 span", "30,000 spans".
    public static func spansText(_ count: Int) -> String {
        count == 1 ? "1 span" : "\(count.formatted()) spans"
    }
}

extension TraceSummary {
    /// What VoiceOver reads for the row, one part per column:
    /// "checkout-api, POST /orders, 240 milliseconds, 18 spans, Error".
    public var spokenParts: [String] {
        [rootService, route, spokenDuration, spokenSpanCount, status.title]
    }

    /// The Duration cell for VoiceOver: "240 milliseconds".
    public var spokenDuration: String { DurationFormat.spoken(nanoseconds: durationNs) }
    /// The Spans cell for VoiceOver: "18 spans", "1 span".
    public var spokenSpanCount: String { TraceList.spansText(spanCount) }

    public var accessibilityLabel: String { spokenParts.joined(separator: ", ") }
}
