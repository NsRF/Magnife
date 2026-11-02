import Foundation
import GRDB

// Read-only records for the tables in docs/schema.sql. The helper writes
// every row; these types only decode them.

/// One row of `traces`: the trace list's row.
public struct TraceSummary: Sendable, Hashable, Identifiable, FetchableRecord {
    public var traceID: String
    public var rootSpanID: String?
    public var rootService: String
    public var route: String
    public var startNs: Int64
    public var endNs: Int64
    public var durationNs: Int64
    public var spanCount: Int
    public var errorCount: Int
    public var status: SpanStatus
    public var firstSeq: Int64
    public var updatedSeq: Int64
    public var receivedNs: Int64

    public var id: String { traceID }
    public var start: Date { Date(nanoseconds: startNs) }
    /// The cursor that continues a page after this row.
    public var cursor: TraceCursor { TraceCursor(startNs: startNs, traceID: traceID) }

    public init(traceID: String, rootSpanID: String? = nil, rootService: String, route: String, startNs: Int64,
                durationNs: Int64, spanCount: Int, errorCount: Int = 0, status: SpanStatus = .unset,
                firstSeq: Int64 = 1, updatedSeq: Int64 = 1) {
        self.traceID = traceID
        self.rootSpanID = rootSpanID
        self.rootService = rootService
        self.route = route
        self.startNs = startNs
        self.endNs = startNs + durationNs
        self.durationNs = durationNs
        self.spanCount = spanCount
        self.errorCount = errorCount
        self.status = status
        self.firstSeq = firstSeq
        self.updatedSeq = updatedSeq
        self.receivedNs = startNs
    }

    public init(row: Row) throws {
        traceID = try row.decode(forColumn: "trace_id")
        rootSpanID = try row.decode(forColumn: "root_span_id")
        rootService = try row.decode(forColumn: "root_service")
        route = try row.decode(forColumn: "route")
        startNs = try row.decode(forColumn: "start_ns")
        endNs = try row.decode(forColumn: "end_ns")
        durationNs = try row.decode(forColumn: "duration_ns")
        spanCount = try row.decode(forColumn: "span_count")
        errorCount = try row.decode(forColumn: "error_count")
        status = SpanStatus(code: try row.decode(forColumn: "status"))
        firstSeq = try row.decode(forColumn: "first_seq")
        updatedSeq = try row.decode(forColumn: "updated_seq")
        receivedNs = try row.decode(forColumn: "received_ns")
    }
}

/// Where a page of traces ends: newest first by start, then trace id.
public struct TraceCursor: Sendable, Hashable {
    public var startNs: Int64
    public var traceID: String

    public init(startNs: Int64, traceID: String) {
        self.startNs = startNs
        self.traceID = traceID
    }
}

/// One row of `spans`, with its JSON columns decoded.
public struct SpanRecord: Sendable, Hashable, Identifiable, FetchableRecord {
    public var rowID: Int64
    public var traceID: String
    public var spanID: String
    public var parentSpanID: String?
    public var name: String
    public var kind: SpanKind
    public var startNs: Int64
    public var endNs: Int64
    public var durationNs: Int64
    public var status: SpanStatus
    public var statusMessage: String
    public var serviceName: String
    public var resourceID: Int64
    public var scopeName: String
    public var scopeVersion: String
    public var attributes: Attributes
    public var events: [SpanEvent]
    public var links: [SpanLink]
    public var dbSystem: String?
    public var dbStatement: String?
    public var httpMethod: String?
    public var httpStatusCode: Int?
    public var httpRoute: String?
    public var httpURL: String?
    public var receivedNs: Int64

    public var id: String { spanID }
    public var isRoot: Bool { parentSpanID == nil }
    /// Exceptions recorded as span events, in time order.
    public var exceptions: [SpanException] { events.compactMap(\.exception) }

    public init(row: Row) throws {
        rowID = try row.decode(forColumn: "id")
        traceID = try row.decode(forColumn: "trace_id")
        spanID = try row.decode(forColumn: "span_id")
        parentSpanID = try row.decode(forColumn: "parent_span_id")
        name = try row.decode(forColumn: "name")
        kind = SpanKind(code: try row.decode(forColumn: "kind"))
        startNs = try row.decode(forColumn: "start_ns")
        endNs = try row.decode(forColumn: "end_ns")
        durationNs = try row.decode(forColumn: "duration_ns")
        status = SpanStatus(code: try row.decode(forColumn: "status_code"))
        statusMessage = try row.decode(forColumn: "status_message")
        serviceName = try row.decode(forColumn: "service_name")
        resourceID = try row.decode(forColumn: "resource_id")
        scopeName = try row.decode(forColumn: "scope_name")
        scopeVersion = try row.decode(forColumn: "scope_version")
        attributes = Attributes(json: try row.decode(forColumn: "attributes"))
        events = JSONColumn.decode([SpanEvent].self, from: try row.decode(forColumn: "events")) ?? []
        links = JSONColumn.decode([SpanLink].self, from: try row.decode(forColumn: "links")) ?? []
        dbSystem = try row.decode(forColumn: "db_system")
        dbStatement = try row.decode(forColumn: "db_statement")
        httpMethod = try row.decode(forColumn: "http_method")
        httpStatusCode = try row.decode(forColumn: "http_status_code")
        httpRoute = try row.decode(forColumn: "http_route")
        httpURL = try row.decode(forColumn: "http_url")
        receivedNs = try row.decode(forColumn: "received_ns")
    }
}

/// A timestamped note on a span.
public struct SpanEvent: Sendable, Hashable, Decodable {
    public var timeNs: Int64
    public var name: String
    public var attributes: Attributes

    enum CodingKeys: String, CodingKey {
        case timeNs = "time_ns", name, attributes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timeNs = try container.decodeIfPresent(Int64.self, forKey: .timeNs) ?? 0
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        attributes = try container.decodeIfPresent(Attributes.self, forKey: .attributes) ?? Attributes()
    }

    /// The exception this event records, when its name is "exception".
    public var exception: SpanException? {
        guard name == "exception" else { return nil }
        return SpanException(type: attributes["exception.type"]?.text ?? "",
                             message: attributes["exception.message"]?.text ?? "",
                             stackTrace: attributes["exception.stacktrace"]?.text ?? "",
                             timeNs: timeNs)
    }
}

/// An exception from a span event, with its stack trace (empty when not sent).
public struct SpanException: Sendable, Hashable {
    public var type: String
    public var message: String
    public var stackTrace: String
    public var timeNs: Int64
}

/// A link from a span to a span in another (or the same) trace.
public struct SpanLink: Sendable, Hashable, Decodable {
    public var traceID: String
    public var spanID: String
    public var attributes: Attributes

    enum CodingKeys: String, CodingKey {
        case traceID = "trace_id", spanID = "span_id", attributes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        traceID = try container.decodeIfPresent(String.self, forKey: .traceID) ?? ""
        spanID = try container.decodeIfPresent(String.self, forKey: .spanID) ?? ""
        attributes = try container.decodeIfPresent(Attributes.self, forKey: .attributes) ?? Attributes()
    }
}

/// One row of `logs`.
public struct LogRecord: Sendable, Hashable, Identifiable, FetchableRecord {
    public var id: Int64
    public var timeNs: Int64
    public var observedNs: Int64
    public var severityNumber: Int
    public var severityText: String
    public var serviceName: String
    public var resourceID: Int64
    public var scopeName: String
    public var body: String
    public var attributes: Attributes
    public var traceID: String?
    public var spanID: String?
    public var eventName: String
    public var receivedNs: Int64

    /// nil when the log sent no severity number.
    public var level: SeverityLevel? { SeverityLevel(number: severityNumber) }
    public var time: Date { Date(nanoseconds: timeNs) }
    public var cursor: LogCursor { LogCursor(timeNs: timeNs, id: id) }

    public init(row: Row) throws {
        id = try row.decode(forColumn: "id")
        timeNs = try row.decode(forColumn: "time_ns")
        observedNs = try row.decode(forColumn: "observed_ns")
        severityNumber = try row.decode(forColumn: "severity_number")
        severityText = try row.decode(forColumn: "severity_text")
        serviceName = try row.decode(forColumn: "service_name")
        resourceID = try row.decode(forColumn: "resource_id")
        scopeName = try row.decode(forColumn: "scope_name")
        body = try row.decode(forColumn: "body")
        attributes = Attributes(json: try row.decode(forColumn: "attributes"))
        traceID = try row.decode(forColumn: "trace_id")
        spanID = try row.decode(forColumn: "span_id")
        eventName = try row.decode(forColumn: "event_name")
        receivedNs = try row.decode(forColumn: "received_ns")
    }
}

/// Where a page of logs ends: newest first by time, then id.
public struct LogCursor: Sendable, Hashable {
    public var timeNs: Int64
    public var id: Int64

    public init(timeNs: Int64, id: Int64) {
        self.timeNs = timeNs
        self.id = id
    }
}

/// A service in the sidebar. The error count is derived from spans: the
/// number of distinct traces that have an Error span from this service.
public struct ServiceSummary: Sendable, Hashable, Identifiable, FetchableRecord {
    public var name: String
    public var firstSeenNs: Int64
    public var lastSeenNs: Int64
    public var errorCount: Int

    public var id: String { name }

    public init(name: String, firstSeenNs: Int64, lastSeenNs: Int64, errorCount: Int) {
        self.name = name
        self.firstSeenNs = firstSeenNs
        self.lastSeenNs = lastSeenNs
        self.errorCount = errorCount
    }

    public init(row: Row) throws {
        name = try row.decode(forColumn: "name")
        firstSeenNs = try row.decode(forColumn: "first_seen_ns")
        lastSeenNs = try row.decode(forColumn: "last_seen_ns")
        errorCount = try row.decode(forColumn: "error_count")
    }
}

/// One row of `resources`.
public struct ResourceRecord: Sendable, Hashable, Identifiable, FetchableRecord {
    public var id: Int64
    public var serviceName: String
    public var attributes: Attributes

    public init(row: Row) throws {
        id = try row.decode(forColumn: "id")
        serviceName = try row.decode(forColumn: "service_name")
        attributes = Attributes(json: try row.decode(forColumn: "attributes"))
    }
}

/// Where an attribute key was seen: 1 span, 2 resource, 3 log.
public enum AttributeSource: Int, Sendable, CaseIterable {
    case span = 1
    case resource = 2
    case log = 3
}

/// One row of `attribute_keys`, for filter-bar autocomplete.
public struct AttributeKey: Sendable, Hashable, FetchableRecord {
    public var key: String
    public var source: AttributeSource
    public var lastSeenNs: Int64

    public init(row: Row) throws {
        key = try row.decode(forColumn: "key")
        source = AttributeSource(rawValue: try row.decode(forColumn: "source")) ?? .span
        lastSeenNs = try row.decode(forColumn: "last_seen_ns")
    }
}

enum JSONColumn {
    /// nil for a column that is not valid JSON of that shape.
    static func decode<T: Decodable>(_ type: T.Type, from text: String) -> T? {
        try? JSONDecoder().decode(type, from: Data(text.utf8))
    }
}

extension Date {
    /// A date from Unix nanoseconds, the database's time unit.
    public init(nanoseconds: Int64) {
        self.init(timeIntervalSince1970: Double(nanoseconds) / 1_000_000_000)
    }

    public var nanoseconds: Int64 { Int64((timeIntervalSince1970 * 1_000_000_000).rounded()) }
}
