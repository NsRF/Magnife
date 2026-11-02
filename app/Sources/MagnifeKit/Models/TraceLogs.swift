import Foundation

/// Trace Logs (S-012): every log that carries the open trace's id, in time
/// order, those without a span id included. Built off the main actor.
public struct TraceLogs: Sendable, Hashable {
    public let traceID: String
    public let lines: [LogLine]
    /// The logs as read, for the refresh that follows (`TelemetryReader.logStamp`).
    public let stamp: LogStamp

    public init(traceID: String, records: [LogRecord], timeZone: TimeZone = .current) {
        self.traceID = traceID
        let ordered = records.filter { $0.traceID == traceID }
            .sorted { ($0.timeNs, $0.id) < ($1.timeNs, $1.id) }
        lines = ordered.map { LogLine($0, timeZone: timeZone) }
        stamp = LogStamp(count: ordered.count, lastID: ordered.map(\.id).max() ?? 0)
    }

    public init() {
        traceID = ""
        lines = []
        stamp = LogStamp(count: 0, lastID: 0)
    }

    public var isEmpty: Bool { lines.isEmpty }

    /// The pane header: "24 logs", "1 log".
    public static func countTitle(_ count: Int) -> String {
        count == 1 ? "1 log" : "\(count.formatted()) logs"
    }

    public static let emptyTitle = "No Logs for This Trace"
    public static let emptyDescription = "Logs that carry this trace ID appear here."
}

/// What the Span column of Trace Logs shows for a log.
public enum TraceLogSpan: Sendable, Hashable {
    /// The log has no span id: "—", and selecting it leaves the waterfall alone.
    case none
    /// A span of the waterfall, by id, with its name.
    case span(id: String, name: String)
    /// A span id this trace has not received: "Span not received".
    case notReceived

    public init(spanID: String?, in waterfall: Waterfall) {
        guard let spanID else { self = .none; return }
        if let node = waterfall.node(spanID) {
            self = .span(id: spanID, name: node.span.name)
        } else {
            self = .notReceived
        }
    }

    public static let notReceivedText = "Span not received"

    public var text: String {
        switch self {
        case .none: LogLine.noLevel
        case .span(_, let name): name
        case .notReceived: Self.notReceivedText
        }
    }

    /// The span selecting the log selects in the waterfall, if any.
    public var spanID: String? {
        if case .span(let id, _) = self { return id }
        return nil
    }

    /// "span charge-card", "no span", "span not received".
    public var spoken: String {
        switch self {
        case .none: "no span"
        case .span(_, let name): "span \(name)"
        case .notReceived: "span not received"
        }
    }
}

extension LogLine {
    /// What VoiceOver reads for a Trace Logs row: "14:02:31, ERROR, orders,
    /// span charge-card, Payment declined" (docs/ux.md, S-012).
    public func accessibilityLabel(span: TraceLogSpan) -> String {
        let firstLine = record.body.prefix { !$0.isNewline }
        return [spokenTime, record.level?.title ?? "no level", record.serviceName, span.spoken, String(firstLine.prefix(200))]
            .filter { !$0.isEmpty }.joined(separator: ", ")
    }
}
