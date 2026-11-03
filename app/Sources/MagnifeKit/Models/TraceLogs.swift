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

    private init(traceID: String, lines: [LogLine], stamp: LogStamp) {
        self.traceID = traceID
        self.lines = lines
        self.stamp = stamp
    }

    /// These logs and `records`, logs that arrived since (ids above
    /// `stamp.lastID`), merged in time order (S-030: a trace that keeps
    /// logging reads only its new logs). Records of another trace or already
    /// shown are left out.
    public func adding(_ records: [LogRecord], timeZone: TimeZone = .current) -> TraceLogs {
        let added = records.filter { $0.traceID == traceID && $0.id > stamp.lastID }
            .sorted { ($0.timeNs, $0.id) < ($1.timeNs, $1.id) }
        guard !added.isEmpty else { return self }
        let newLines = added.map { LogLine($0, timeZone: timeZone) }
        func before(_ a: LogLine, _ b: LogLine) -> Bool { (a.record.timeNs, a.id) < (b.record.timeNs, b.id) }
        var merged: [LogLine] = []
        merged.reserveCapacity(lines.count + newLines.count)
        // New logs usually come last: everything before the first of them stays as it is.
        let first = newLines[0]
        let keep = lines.partitioningIndex { before(first, $0) }
        merged.append(contentsOf: lines[..<keep])
        var old = keep, new = 0
        while old < lines.count || new < newLines.count {
            if new == newLines.count || (old < lines.count && before(lines[old], newLines[new])) {
                merged.append(lines[old]); old += 1
            } else {
                merged.append(newLines[new]); new += 1
            }
        }
        return TraceLogs(traceID: traceID, lines: merged,
                         stamp: LogStamp(count: stamp.count + added.count, lastID: added.map(\.id).max() ?? stamp.lastID))
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

extension Array {
    /// The first index whose element is in the second part (`belongs` true), binary search on a partitioned array.
    func partitioningIndex(where belongs: (Element) -> Bool) -> Int {
        var low = 0, high = count
        while low < high {
            let middle = (low + high) / 2
            if belongs(self[middle]) { high = middle } else { low = middle + 1 }
        }
        return low
    }
}
