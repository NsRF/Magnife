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
    /// Every trace in the scope, for the window's subtitle (S-009).
    public var traceCount: Int
    /// Read while paused (S-010): only traces created up to this seq, and
    /// `newCount` the ones created after it.
    public var upTo: Int64?
    public var newCount: Int

    public init(traces: [TraceSummary], services: [ServiceSummary], lastSeq: Int64, traceCount: Int? = nil,
                upTo: Int64? = nil, newCount: Int = 0) {
        self.traces = traces
        self.services = services
        self.lastSeq = lastSeq
        self.traceCount = traceCount ?? traces.count
        self.upTo = upTo
        self.newCount = newCount
    }
}

/// What changed while the list holds still: rows that already existed when
/// it started holding and changed since, shown rows pruned since (S-015),
/// and how many traces are new.
public struct HeldTraces: Sendable, Equatable {
    public var updated: [TraceSummary]
    public var removed: [String]
    public var newCount: Int
    public var services: [ServiceSummary]
    public var lastSeq: Int64

    public init(updated: [TraceSummary], removed: [String] = [], newCount: Int, services: [ServiceSummary],
                lastSeq: Int64) {
        self.updated = updated
        self.removed = removed
        self.newCount = newCount
        self.services = services
        self.lastSeq = lastSeq
    }
}

public enum TraceList {
    /// Rows read per page (docs/ux.md, S-030).
    public static let pageSize = 200

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

    /// The window's subtitle: the count in the list, "1,204 traces", "1 trace",
    /// prefixed "Paused · " while paused (S-010).
    public static func subtitle(traceCount: Int, isPaused: Bool = false) -> String {
        (isPaused ? "Paused · " : "") + (traceCount == 1 ? "1 trace" : "\(traceCount.formatted()) traces")
    }

    /// The bar at the top of a paused list (S-010): "Paused. 12 new traces.
    /// Magnife is still receiving.", without the count while none arrived.
    public static func pausedText(newCount: Int) -> String {
        let count = newCount == 0 ? "" : " \(newCount == 1 ? "1 new trace" : "\(newCount.formatted()) new traces")."
        return "Paused.\(count) Magnife is still receiving."
    }

    /// The toolbar button and Trace menu item: "Pause" or "Resume".
    public static func pauseTitle(isPaused: Bool) -> String { isPaused ? "Resume" : "Pause" }

    /// The toolbar button's tooltip (docs/ux.md, Toolbar).
    public static func pauseHelp(isPaused: Bool) -> String {
        isPaused ? "Add the traces that arrived while paused (⌃⌘P)"
            : "Hold the list still while new traces keep arriving (⌃⌘P)"
    }
}

extension ServiceSummary {
    /// The sidebar count's tooltip (S-009): "12 traces with errors", "1 trace with errors".
    public var errorCountText: String {
        errorCount == 1 ? "1 trace with errors" : "\(errorCount.formatted()) traces with errors"
    }

    /// What VoiceOver reads after the name: "12 traces with errors" or "no errors".
    public var spokenErrors: String { errorCount == 0 ? "no errors" : errorCountText }
}

extension TraceSummary {
    /// What VoiceOver reads for the row (S-004 Access):
    /// "checkout-api, POST /orders, 240 milliseconds, 18 spans, Error".
    /// Unset shows blank, so it says nothing; the Time column is left out.
    public var spokenParts: [String] {
        [rootService, route, spokenDuration, spokenSpanCount] + (status == .unset ? [] : [status.title])
    }

    /// The Duration cell for VoiceOver: "240 milliseconds".
    public var spokenDuration: String { DurationFormat.spoken(nanoseconds: durationNs) }
    /// The Spans cell for VoiceOver: "18 spans", "1 span".
    public var spokenSpanCount: String { TraceList.spansText(spanCount) }

    public var accessibilityLabel: String { spokenParts.joined(separator: ", ") }
}

/// What the live list shows, and the rules for what a read does to it
/// (design decision 6 and S-004): a page at the top replaces the rows; while
/// the list holds still only the shown rows change, in place, and new
/// traces are counted; a read for another scope, or older than what is shown,
/// is dropped, so overlapping reads never put older rows back.
public struct TraceListState: Sendable, Equatable {
    /// The sidebar's service, nil for all services.
    public var scope: String?
    public var traces: [TraceSummary]
    /// The seq the shown rows were read at, and the last seq applied to them.
    public var baseSeq: Int64
    public var appliedSeq: Int64
    /// Scrolled away from the top: the rows hold still.
    public var isHeld: Bool
    /// Traces newer than the shown rows while the list holds still.
    public var newCount: Int
    /// A full page came back, so there may be older rows to read.
    public var hasMore: Bool
    /// Every trace in the scope when the rows were read (the subtitle).
    public var traceCount: Int
    /// While paused (S-010), the seq the list paused at: rows never change,
    /// traces created after it are counted, and a scope change reads up to it.
    public var pausedSeq: Int64?

    public init(scope: String? = nil, traces: [TraceSummary] = [], baseSeq: Int64 = 0, appliedSeq: Int64 = 0,
                isHeld: Bool = false, newCount: Int = 0, hasMore: Bool = false, traceCount: Int = 0,
                pausedSeq: Int64? = nil) {
        self.scope = scope
        self.traces = traces
        self.baseSeq = baseSeq
        self.appliedSeq = appliedSeq
        self.isHeld = isHeld
        self.newCount = newCount
        self.hasMore = hasMore
        self.traceCount = traceCount
        self.pausedSeq = pausedSeq
    }

    public var isPaused: Bool { pausedSeq != nil }

    /// True when the next read is a held one: the list holds still (scrolled
    /// away, or paused) and shows rows.
    public var readsHeld: Bool { (isHeld || isPaused) && !traces.isEmpty }

    /// Paused at the seq the shown rows were read at, so every trace
    /// created after it counts as new (S-010).
    public func paused() -> TraceListState {
        var next = self
        if next.pausedSeq == nil { next.pausedSeq = baseSeq }
        return next
    }

    /// The state after `read`, or nil when the read must be dropped.
    public func applying(_ read: TraceListRead) -> TraceListState? {
        guard read.scope == scope, read.lastSeq >= appliedSeq else { return nil }
        var next = self
        switch read {
        case .page(let page, _):
            // Scrolled away or paused while reading: inserting now would move the rows under the pointer.
            // While paused, only a page read up to the pause point may fill the list.
            guard !readsHeld, page.upTo == pausedSeq else { return nil }
            next.traces = page.traces
            // A Resume read can ask for more than a page.
            next.hasMore = page.traces.count >= TraceList.pageSize
            next.baseSeq = pausedSeq ?? page.lastSeq
            next.appliedSeq = page.lastSeq
            next.newCount = page.newCount
            next.traceCount = page.traceCount
        case .held(let held, _, let base):
            // Back at the top, or a newer page arrived while reading: that read decides.
            guard isHeld || isPaused, base == baseSeq else { return nil }
            // Paused, the rows do not change at all; only the count moves. A paused list
            // may show pruned rows, which open to "Trace No Longer Stored" (S-015).
            if !isPaused {
                next.traces = TraceList.applying(held.updated, to: traces)
                // Pruned rows leave; they are the oldest, so the rows under the pointer stay put.
                if !held.removed.isEmpty {
                    let gone = Set(held.removed)
                    next.traces.removeAll { gone.contains($0.id) }
                    next.traceCount = max(0, traceCount - (traces.count - next.traces.count))
                }
            }
            next.appliedSeq = held.lastSeq
            next.newCount = held.newCount
        }
        return next
    }
}

/// A read of the live list, with the scope it was made for.
public enum TraceListRead: Sendable {
    /// The first page, read at the top.
    case page(TracePage, scope: String?)
    /// Changes to the shown rows read while the list held still at `base`.
    case held(HeldTraces, scope: String?, base: Int64)

    public var scope: String? {
        switch self {
        case .page(_, let scope), .held(_, let scope, _): scope
        }
    }

    public var lastSeq: Int64 {
        switch self {
        case .page(let page, _): page.lastSeq
        case .held(let held, _, _): held.lastSeq
        }
    }

    public var services: [ServiceSummary] {
        switch self {
        case .page(let page, _): page.services
        case .held(let held, _, _): held.services
        }
    }
}
