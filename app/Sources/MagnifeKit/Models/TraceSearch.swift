import Foundation

/// What Search (S-017, ⌘K) found for one query.
public struct TraceSearchResult: Sendable, Equatable {
    /// The query text it was read for: a result for older text is dropped.
    public var text: String
    /// The newest matches, newest first (a trace ID match first).
    public var traces: [TraceSummary]
    /// Every stored trace the query keeps; nil while it is being counted.
    public var total: Int?
    /// An empty query: the newest traces, not matches.
    public var isNewest: Bool

    public init(text: String, traces: [TraceSummary], total: Int?, isNewest: Bool) {
        self.text = text
        self.traces = traces
        self.total = total
        self.isNewest = isNewest
    }

    /// The header over the rows: "Newest Traces" or "Matching Traces".
    public var header: String { isNewest ? "Newest Traces" : "Matching Traces" }

    /// The count beside "Matching Traces": "50 of 312" when more matched than
    /// show, else "3 traces"; nothing over the newest traces or while counting.
    public var countText: String {
        guard !isNewest, let total else { return "" }
        if total > traces.count { return "\(traces.count.formatted()) of \(total.formatted())" }
        return total == 1 ? "1 trace" : "\(total.formatted()) traces"
    }

    /// What VoiceOver announces after typing pauses: "12 results", "1 result".
    public var spokenCount: String {
        let count = total ?? traces.count
        return count == 1 ? "1 result" : "\(count.formatted()) results"
    }
}

/// Search's words and limits (docs/ux.md, S-017).
public enum TraceSearch {
    /// Matches shown; the count says how many more there are.
    public static let resultLimit = 50
    /// Traces listed while the field is empty.
    public static let newestLimit = 10
    /// Search's first look reads this many of the newest traces (TelemetryReader.searchTraces).
    public static let quickWindow = 2_000
    /// Up to this many traces left by the trace's own columns, Search reads their spans one trace at a time.
    public static let perTraceLimit = 5_000

    public static let label = "Search traces"
    public static let placeholder = "Search traces: service:, status:, route:, >200ms or any text"

    /// "No traces match “paymnt”."
    public static func noMatchTitle(_ text: String) -> String {
        "No traces match \u{201C}\(text.trimmingCharacters(in: .whitespaces))\u{201D}."
    }

    public static let noMatchHint = "Try fewer words, or check the service name."

    /// A result row, as the list row reads: "POST /orders · checkout-api ·
    /// 240 ms · Error · 2 min ago"; Unset says nothing, as in the list.
    public static func rowText(_ trace: TraceSummary, now: Date) -> String {
        rowParts(trace, now: now).joined(separator: " · ")
    }

    public static func rowParts(_ trace: TraceSummary, now: Date) -> [String] {
        [trace.route, trace.rootService, DurationFormat.string(nanoseconds: trace.durationNs)]
            + (trace.status == .unset ? [] : [trace.status.title])
            + [RelativeTime.string(for: trace.start, now: now)]
    }
}
