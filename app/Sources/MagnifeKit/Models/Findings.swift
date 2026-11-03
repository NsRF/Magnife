import Foundation
import GRDB

/// The columns of a span the detectors read: the promoted `db_*` and
/// `http_*` columns (PROGRESS decision 3), never the attribute JSON.
public struct DetectorSpan: Sendable, Hashable, FetchableRecord {
    public var traceID: String
    public var spanID: String
    public var name: String
    public var kind: SpanKind
    public var startNs: Int64
    public var durationNs: Int64
    public var status: SpanStatus
    public var statusMessage: String
    public var dbSystem: String?
    public var dbStatement: String?
    public var httpMethod: String?
    public var httpStatusCode: Int?
    public var httpRoute: String?
    public var httpURL: String?

    public init(traceID: String = "", spanID: String, name: String = "", kind: SpanKind = .client, startNs: Int64 = 0,
                durationNs: Int64, status: SpanStatus = .unset, statusMessage: String = "",
                dbSystem: String? = nil, dbStatement: String? = nil, httpMethod: String? = nil,
                httpStatusCode: Int? = nil, httpRoute: String? = nil, httpURL: String? = nil) {
        self.traceID = traceID
        self.spanID = spanID
        self.name = name
        self.kind = kind
        self.startNs = startNs
        self.durationNs = durationNs
        self.status = status
        self.statusMessage = statusMessage
        self.dbSystem = dbSystem
        self.dbStatement = dbStatement
        self.httpMethod = httpMethod
        self.httpStatusCode = httpStatusCode
        self.httpRoute = httpRoute
        self.httpURL = httpURL
    }

    public init(row: Row) throws {
        traceID = try row.decode(forColumn: "trace_id")
        spanID = try row.decode(forColumn: "span_id")
        name = try row.decode(forColumn: "name")
        kind = SpanKind(code: try row.decode(forColumn: "kind"))
        startNs = try row.decode(forColumn: "start_ns")
        durationNs = try row.decode(forColumn: "duration_ns")
        status = SpanStatus(code: try row.decode(forColumn: "status_code"))
        statusMessage = try row.decode(forColumn: "status_message")
        dbSystem = try row.decode(forColumn: "db_system")
        dbStatement = try row.decode(forColumn: "db_statement")
        httpMethod = try row.decode(forColumn: "http_method")
        httpStatusCode = try row.decode(forColumn: "http_status_code")
        httpRoute = try row.decode(forColumn: "http_route")
        httpURL = try row.decode(forColumn: "http_url")
    }
}

/// What a detector flagged (docs/GLOSSARY.md, Finding). Orange with its
/// icon and name on screen, never a service color.
public enum FindingKind: Int, Sendable, CaseIterable, Comparable, Identifiable {
    case slowSQL
    case nPlusOne
    case httpError

    public var id: Int { rawValue }
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// The badge, strip and section title.
    public var title: String {
        switch self {
        case .slowSQL: "Slow SQL"
        case .nPlusOne: "N+1"
        case .httpError: "HTTP Error"
        }
    }

    /// The SF Symbol (docs/ux.md, S-023 to S-025).
    public var symbol: String {
        switch self {
        case .slowSQL: "cylinder"
        case .nPlusOne: "repeat"
        case .httpError: "network"
        }
    }
}

/// One finding: its kind and the spans it is about, in start order. A click
/// on its strip line selects the first of them.
public struct Finding: Sendable, Hashable, Identifiable {
    public var kind: FindingKind
    public var spanIDs: [String]
    public var startNs: Int64
    /// Slow SQL: the query's duration; N+1: the repeated spans' total.
    public var durationNs: Int64
    /// Slow SQL: the statement as stored; N+1: the normalized statement.
    public var statement: String?
    /// N+1: how many times the statement ran (the spans' count).
    public var count: Int = 1
    public var dbSystem: String?
    public var spanName: String
    /// HTTP Error: the method, what was called (URL, route or span name),
    /// the response code and the span's status message.
    public var httpMethod: String?
    public var httpTarget: String?
    public var httpStatusCode: Int?
    public var statusMessage: String = ""

    public var id: String { "\(kind.rawValue)/\(spanIDs.first ?? "")" }

    /// The strip line under the waterfall header:
    /// "Slow SQL · 340 ms · SELECT * FROM orders WHERE …" (the view cuts it).
    public var line: String {
        switch kind {
        case .slowSQL:
            [kind.title, durationText, Self.oneLine(statement ?? spanName)]
                .joined(separator: " · ")
        case .nPlusOne:
            [kind.title, "\(CountFormat.string(count)) times", Self.oneLine(statement ?? spanName)].joined(separator: " · ")
        case .httpError:
            ([kind.title] + (httpStatusCode.map { [String($0)] } ?? []) + [Self.oneLine(call)]).joined(separator: " · ")
        }
    }

    /// The duration in the finding's words: "340 ms". A Slow SQL query over
    /// 100 ms that rounds to "100 ms" reads "just over 100 ms", so the words
    /// never say it took the threshold (PROGRESS decision 182).
    public var durationText: String {
        let text = DurationFormat.string(nanoseconds: durationNs)
        return isJustOverThreshold ? "just over \(text)" : text
    }

    /// `durationText` for VoiceOver: "340 milliseconds", "just over 100 milliseconds".
    public var spokenDuration: String {
        let text = DurationFormat.spoken(nanoseconds: durationNs)
        return isJustOverThreshold ? "just over \(text)" : text
    }

    private var isJustOverThreshold: Bool {
        kind == .slowSQL && durationNs > Detectors.slowSQLThresholdNs
            && DurationFormat.string(nanoseconds: durationNs) == DurationFormat.string(nanoseconds: Detectors.slowSQLThresholdNs)
    }

    /// "POST /payments": the method and what was called, the method left out
    /// when the target already starts with it (a span named "POST /payments").
    public var call: String {
        let target = httpTarget ?? spanName
        guard let method = httpMethod, !method.isEmpty, !target.hasPrefix(method + " "), target != method else { return target }
        return "\(method) \(target)"
    }

    /// "POST /payments returned 500.", or "… has status Error and no response code."
    private var httpOutcome: String {
        guard let code = httpStatusCode else { return "\(call) has status Error and no response code." }
        return code >= Detectors.httpErrorMinimumCode ? "\(call) returned \(code)."
            : "\(call) returned \(code) and has status Error."
    }

    /// The span detail's text under the title (docs/ux.md, S-023 Words).
    public var detailText: String {
        switch kind {
        case .slowSQL:
            let took = durationText
            let threshold = DurationFormat.string(nanoseconds: Detectors.slowSQLThresholdNs)
            let query = statement == nil ? "This \(dbSystem ?? "database") query" : "This query"
            return "\(query) took \(took). Queries over \(threshold) are flagged."
        case .nPlusOne:
            return "This statement ran \(CountFormat.string(count)) times in this trace."
        case .httpError:
            // The span's status message, when set, follows the text (docs/ux.md, S-025 States).
            let message = statusMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            return message.isEmpty ? httpOutcome : "\(httpOutcome) \(message)"
        }
    }

    /// The statement shown under the text, monospaced; nil when there is none.
    public var shownStatement: String? { statement }

    /// The strip line for VoiceOver: "Select span: Slow SQL, 340 milliseconds".
    public var accessibilityLabel: String {
        switch kind {
        case .slowSQL: "Select span: \(kind.title), \(spokenDuration)"
        case .nPlusOne: "Select span: \(kind.title), \(CountFormat.string(count)) times"
        case .httpError: "Select span: \(kind.title), \(httpOutcome.dropLast())"
        }
    }

    /// What the waterfall row adds for VoiceOver for this span: "Slow SQL", "N+1, 1 of 8".
    public func spokenMark(for spanID: String) -> String {
        switch kind {
        case .slowSQL, .httpError: kind.title
        case .nPlusOne:
            "\(kind.title), \(CountFormat.string((spanIDs.firstIndex(of: spanID) ?? 0) + 1)) of \(CountFormat.string(count))"
        }
    }

    /// A statement on one line, its runs of white space as one space, and
    /// at most 300 characters: the strip line shows one line.
    static func oneLine(_ text: String) -> String {
        let words = text.prefix(600).split(whereSeparator: \.isWhitespace)
        let joined = words.joined(separator: " ")
        return joined.count > 300 ? String(joined.prefix(300)) + "…" : joined
    }
}

/// One read of an open trace (`TelemetryReader.openTrace`): the row, the
/// waterfall's spans and the findings, all from the same snapshot.
public struct OpenTraceRead: Sendable {
    public var trace: TraceSummary?
    public var spans: [WaterfallSpan]
    public var findings: TraceFindings

    public init(trace: TraceSummary?, spans: [WaterfallSpan], findings: TraceFindings) {
        self.trace = trace
        self.spans = spans
        self.findings = findings
    }
}

/// Every finding of one trace, and which spans carry which.
public struct TraceFindings: Sendable, Hashable {
    /// In kind order, then by the first span's start.
    public private(set) var findings: [Finding] = []
    /// The findings of each span, by span id, as indexes into `findings`.
    private var bySpan: [String: [Int]] = [:]

    public init() {}

    public init(_ findings: [Finding]) {
        self.findings = findings.sorted { ($0.kind, $0.startNs, $0.id) < ($1.kind, $1.startNs, $1.id) }
        for (index, finding) in self.findings.enumerated() {
            for spanID in finding.spanIDs { bySpan[spanID, default: []].append(index) }
        }
    }

    public var isEmpty: Bool { findings.isEmpty }
    public var count: Int { findings.count }

    /// The findings that name this span, in kind order.
    public func findings(forSpan spanID: String) -> [Finding] {
        bySpan[spanID]?.map { findings[$0] } ?? []
    }

    /// The kinds this span carries, in order: the waterfall row's icons.
    public func kinds(forSpan spanID: String) -> [FindingKind] {
        var kinds: [FindingKind] = []
        for finding in findings(forSpan: spanID) where !kinds.contains(finding.kind) { kinds.append(finding.kind) }
        return kinds
    }

    /// The trace list's badges: one per kind, with its count.
    public var summary: FindingSummary {
        var counts: [FindingKind: Int] = [:]
        for finding in findings { counts[finding.kind, default: 0] += 1 }
        let repeats = findings.filter { $0.kind == .nPlusOne }.map(\.count).max() ?? 0
        return FindingSummary(counts: counts, mostRepeats: repeats)
    }

    /// The strip shows this many lines, then "Show All Findings (7)" (docs/ux.md, S-023 States).
    public static let stripPreviewCount = 3

    public func shownInStrip(all: Bool) -> ArraySlice<Finding> {
        all ? findings[...] : findings.prefix(Self.stripPreviewCount)
    }

    /// "Show All Findings (7)" while lines are cut, else nil.
    public var showAllTitle: String? {
        findings.count > Self.stripPreviewCount ? "Show All Findings (\(CountFormat.string(findings.count)))" : nil
    }
}

/// A trace row's badges: the kinds found and how many of each.
public struct FindingSummary: Sendable, Hashable {
    public var counts: [FindingKind: Int]
    /// N+1: the most times one statement ran, for the tooltip.
    public var mostRepeats: Int

    public init(counts: [FindingKind: Int] = [:], mostRepeats: Int = 0) {
        self.counts = counts.filter { $0.value > 0 }
        self.mostRepeats = mostRepeats
    }

    public var kinds: [FindingKind] { counts.keys.sorted() }
    public var isEmpty: Bool { counts.isEmpty }

    /// The badge's tooltip: "Slow SQL: 3 queries over 100 ms".
    public func help(_ kind: FindingKind) -> String {
        let count = counts[kind] ?? 0
        let threshold = DurationFormat.string(nanoseconds: Detectors.slowSQLThresholdNs)
        switch kind {
        case .slowSQL:
            return "\(kind.title): \(count == 1 ? "1 query" : "\(CountFormat.string(count)) queries") over \(threshold)"
        case .nPlusOne:
            return count == 1 ? "\(kind.title): a statement ran \(CountFormat.string(mostRepeats)) times"
                : "\(kind.title): \(CountFormat.string(count)) statements ran \(Detectors.nPlusOneMinimum) or more times"
        case .httpError:
            return "\(kind.title): \(count == 1 ? "1 call" : "\(CountFormat.string(count)) calls") returned "
                + "\(Detectors.httpErrorMinimumCode) or higher, or had status Error"
        }
    }

    /// What the row adds for VoiceOver: "findings: Slow SQL".
    public var spoken: String? {
        isEmpty ? nil : "findings: " + kinds.map(\.title).joined(separator: ", ")
    }
}

/// The detectors (S-023 to S-025): pure functions over a trace's spans,
/// run off the main actor where the spans are read.
public enum Detectors {
    /// A database span that took longer than this is Slow SQL (docs/GLOSSARY.md: over 100 ms).
    public static let slowSQLThresholdNs: Int64 = 100_000_000
    /// The same normalized statement this many times in one trace is N+1 (docs/GLOSSARY.md: 5 or more).
    public static let nPlusOneMinimum = 5
    /// An HTTP span with a response code from this one up is an HTTP Error (docs/GLOSSARY.md: 400 or higher).
    public static let httpErrorMinimumCode = 400

    /// Every finding in one trace's spans.
    public static func findings(in spans: [DetectorSpan]) -> TraceFindings {
        TraceFindings(slowSQL(spans) + nPlusOne(spans) + httpErrors(spans))
    }

    /// Findings of several traces at once, by trace id: the trace list's badges.
    public static func findingsByTrace(_ spans: [DetectorSpan]) -> [String: TraceFindings] {
        Dictionary(grouping: spans, by: \.traceID).mapValues(findings(in:))
    }

    /// Slow SQL: a span with `db_system` and a duration over 100 ms, one finding each.
    public static func slowSQL(_ spans: [DetectorSpan]) -> [Finding] {
        spans.compactMap { span in
            guard span.dbSystem != nil, span.durationNs > slowSQLThresholdNs else { return nil }
            let statement = span.dbStatement.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            return Finding(kind: .slowSQL, spanIDs: [span.spanID], startNs: span.startNs, durationNs: span.durationNs,
                           statement: statement, dbSystem: span.dbSystem, spanName: span.name)
        }
    }
}

extension Detectors {
    /// N+1: the same normalized `db_statement` (literals removed) 5 or more
    /// times in one trace gives one finding for all those spans, first by
    /// start. Each distinct statement is normalized once. A span with a
    /// statement and no `db_system` counts too, as in the reader's
    /// candidates (PROGRESS decision 172; it replaces the detector audit's 4a).
    public static func nPlusOne(_ spans: [DetectorSpan]) -> [Finding] {
        var shapes: [String: String] = [:]
        var groups: [String: [DetectorSpan]] = [:]
        for span in spans {
            guard let statement = span.dbStatement, !statement.isEmpty else { continue }
            let shape: String
            if let known = shapes[statement] {
                shape = known
            } else {
                shape = SQLNormalizer.normalize(statement)
                shapes[statement] = shape
            }
            guard !shape.isEmpty else { continue }
            groups[shape, default: []].append(span)
        }
        return groups.compactMap { shape, group in
            guard group.count >= nPlusOneMinimum else { return nil }
            let ordered = group.sorted { ($0.startNs, $0.spanID) < ($1.startNs, $1.spanID) }
            return Finding(kind: .nPlusOne, spanIDs: ordered.map(\.spanID), startNs: ordered[0].startNs,
                           durationNs: ordered.reduce(0) { $0 + $1.durationNs }, statement: shape, count: ordered.count,
                           dbSystem: ordered[0].dbSystem, spanName: ordered[0].name)
        }
    }
}

extension Detectors {
    /// HTTP Error: a span with `http_method` or `http_status_code`, and a
    /// code of 400 or higher or status Error, one finding each. A client
    /// span names its URL, a server span its route, else the span's name;
    /// an empty URL or route counts as none (PROGRESS decision 184).
    public static func httpErrors(_ spans: [DetectorSpan]) -> [Finding] {
        spans.compactMap { span in
            guard span.httpMethod != nil || span.httpStatusCode != nil,
                  (span.httpStatusCode ?? 0) >= httpErrorMinimumCode || span.status == .error else { return nil }
            let outgoing = span.kind == .client || span.kind == .producer
            let url = span.httpURL.flatMap { $0.isEmpty ? nil : $0 }
            let route = span.httpRoute.flatMap { $0.isEmpty ? nil : $0 }
            return Finding(kind: .httpError, spanIDs: [span.spanID], startNs: span.startNs, durationNs: span.durationNs,
                           statement: nil, spanName: span.name, httpMethod: span.httpMethod,
                           httpTarget: outgoing ? url ?? route : route ?? url, httpStatusCode: span.httpStatusCode,
                           statusMessage: span.status == .error ? span.statusMessage : "")
        }
    }
}

/// The trace list's badges, kept per trace and read again only when the
/// trace's `updated_seq` changes (a trace still receiving spans gains badges in place).
public struct FindingCache: Sendable, Equatable {
    private var entries: [String: Entry] = [:]

    private struct Entry: Sendable, Equatable {
        var updatedSeq: Int64
        var summary: FindingSummary
    }

    public init() {}

    public var count: Int { entries.count }

    /// The badges of a trace as of its shown row, or nil while not read yet.
    public func summary(for trace: TraceSummary) -> FindingSummary? {
        entries[trace.traceID]?.summary
    }

    /// The rows whose badges are missing or older than the row.
    public func stale(_ traces: [TraceSummary]) -> [TraceSummary] {
        traces.filter { entries[$0.traceID]?.updatedSeq != $0.updatedSeq }
    }

    /// Takes summaries read for the rows at `seqs`; never replaces a newer one.
    public mutating func store(_ summaries: [String: FindingSummary], seqs: [String: Int64]) {
        for (id, summary) in summaries {
            guard let seq = seqs[id] else { continue }
            if let old = entries[id], old.updatedSeq > seq { continue }
            entries[id] = Entry(updatedSeq: seq, summary: summary)
        }
    }

    /// Forgets traces no longer shown.
    public mutating func keep(only ids: Set<String>) {
        entries = entries.filter { ids.contains($0.key) }
    }
}
