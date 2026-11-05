import Foundation

/// File > Export Trace… (v0.2, "share a trace with a team"): one trace, its
/// spans and its logs as OTLP JSON Lines. The first line is an
/// ExportTraceServiceRequest, the second (when the trace has logs) an
/// ExportLogsServiceRequest, in the OTLP/JSON encoding (hex ids, 64-bit
/// integers as strings, enums as numbers). File > Import Traces… reads it
/// back through the helper, and so does any OTLP tool that reads JSON Lines
/// (the Collector's otlpjsonfile receiver).
///
/// What the store does not keep cannot be exported: trace state, flags,
/// dropped counts, and whether a log body was a string or structured
/// (bodies are exported as strings). A double that is a whole number was
/// stored as one and comes back as an int.
public struct TraceExport: Sendable, Equatable {
    /// The file's bytes: one JSON object per line, each line ending in "\n".
    public var data: Data
    public var spanCount: Int
    public var logCount: Int

    /// The extension Magnife writes and suggests.
    public static let fileExtension = "jsonl"

    public init(spans: [SpanRecord], logs: [LogRecord], resources: [Int64: ResourceRecord]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var lines: [Data] = []
        if !spans.isEmpty {
            let request = TracesRequest(resourceSpans: Self.group(spans, resources: resources, resourceID: \.resourceID,
                                                                  scope: { Scope(name: $0.scopeName, version: $0.scopeVersion) })
                .map { ResourceSpans(resource: $0.resource, scopeSpans: $0.scopes.map { ScopeSpans(scope: $0.scope, spans: $0.items.map(Span.init)) }) })
            // Encoding plain structs of strings and numbers cannot fail.
            lines.append(try! encoder.encode(request))
        }
        if !logs.isEmpty {
            let request = LogsRequest(resourceLogs: Self.group(logs, resources: resources, resourceID: \.resourceID,
                                                               scope: { Scope(name: $0.scopeName, version: "") })
                .map { ResourceLogs(resource: $0.resource, scopeLogs: $0.scopes.map { ScopeLogs(scope: $0.scope, logRecords: $0.items.map(LogRecordJSON.init)) }) })
            lines.append(try! encoder.encode(request))
        }
        data = lines.reduce(into: Data()) { $0.append($1); $0.append(0x0A) }
        spanCount = spans.count
        logCount = logs.count
    }

    /// A file name for the trace: "checkout-api GET reports-sales 4bf92f35.jsonl".
    public static func suggestedFileName(for trace: TraceSummary) -> String {
        let words = "\(trace.rootService) \(trace.route)"
            .map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." ? $0 : " " }
        let name = String(words).split(separator: " ").joined(separator: " ").prefix(80)
        let base = name.isEmpty ? "trace" : String(name)
        return "\(base) \(trace.traceID.prefix(8)).\(fileExtension)"
    }

    // MARK: Grouping

    private struct Group<Item> {
        var resource: Resource
        var scopes: [(scope: Scope, items: [Item])]
    }

    /// Items grouped by resource, then by scope, each in order of first appearance.
    private static func group<Item>(_ items: [Item], resources: [Int64: ResourceRecord], resourceID: KeyPath<Item, Int64>,
                                    scope: (Item) -> Scope) -> [Group<Item>] {
        var groups: [Group<Item>] = []
        var index: [Int64: Int] = [:]
        for item in items {
            let id = item[keyPath: resourceID]
            let g = index[id] ?? {
                let attributes = resources[id]?.attributes.pairs ?? []
                groups.append(Group(resource: Resource(attributes: attributes.map(KeyValue.init)), scopes: []))
                index[id] = groups.count - 1
                return groups.count - 1
            }()
            let s = scope(item)
            if let i = groups[g].scopes.firstIndex(where: { $0.scope == s }) {
                groups[g].scopes[i].items.append(item)
            } else {
                groups[g].scopes.append((s, [item]))
            }
        }
        return groups
    }

    // MARK: OTLP/JSON shapes

    private struct TracesRequest: Encodable { var resourceSpans: [ResourceSpans] }
    private struct LogsRequest: Encodable { var resourceLogs: [ResourceLogs] }
    private struct ResourceSpans: Encodable { var resource: Resource; var scopeSpans: [ScopeSpans] }
    private struct ResourceLogs: Encodable { var resource: Resource; var scopeLogs: [ScopeLogs] }
    private struct ScopeSpans: Encodable { var scope: Scope; var spans: [Span] }
    private struct ScopeLogs: Encodable { var scope: Scope; var logRecords: [LogRecordJSON] }
    private struct Resource: Encodable { var attributes: [KeyValue] }

    private struct Scope: Encodable, Equatable {
        var name: String
        var version: String

        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            if !name.isEmpty { try c.encode(name, forKey: .name) }
            if !version.isEmpty { try c.encode(version, forKey: .version) }
        }

        enum CodingKeys: String, CodingKey { case name, version }
    }

    private struct Span: Encodable {
        var record: SpanRecord
        init(_ record: SpanRecord) { self.record = record }

        enum CodingKeys: String, CodingKey {
            case traceId, spanId, parentSpanId, name, kind, startTimeUnixNano, endTimeUnixNano, attributes, events, links, status
        }

        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(record.traceID, forKey: .traceId)
            try c.encode(record.spanID, forKey: .spanId)
            try c.encodeIfPresent(record.parentSpanID, forKey: .parentSpanId)
            try c.encode(record.name, forKey: .name)
            try c.encode(record.kind.rawValue, forKey: .kind)
            try c.encode(String(record.startNs), forKey: .startTimeUnixNano)
            try c.encode(String(record.endNs), forKey: .endTimeUnixNano)
            if !record.attributes.pairs.isEmpty { try c.encode(record.attributes.pairs.map(KeyValue.init), forKey: .attributes) }
            if !record.events.isEmpty { try c.encode(record.events.map(Event.init), forKey: .events) }
            if !record.links.isEmpty { try c.encode(record.links.map(Link.init), forKey: .links) }
            try c.encode(Status(code: record.status.rawValue, message: record.statusMessage), forKey: .status)
        }
    }

    private struct Status: Encodable {
        var code: Int
        var message: String

        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            if code != 0 { try c.encode(code, forKey: .code) }
            if !message.isEmpty { try c.encode(message, forKey: .message) }
        }

        enum CodingKeys: String, CodingKey { case code, message }
    }

    private struct Event: Encodable {
        var timeUnixNano: String
        var name: String
        var attributes: [KeyValue]
        init(_ event: SpanEvent) {
            timeUnixNano = String(event.timeNs)
            name = event.name
            attributes = event.attributes.pairs.map(KeyValue.init)
        }
    }

    private struct Link: Encodable {
        var traceId: String
        var spanId: String
        var attributes: [KeyValue]
        init(_ link: SpanLink) {
            traceId = link.traceID
            spanId = link.spanID
            attributes = link.attributes.pairs.map(KeyValue.init)
        }
    }

    private struct LogRecordJSON: Encodable {
        var record: LogRecord
        init(_ record: LogRecord) { self.record = record }

        enum CodingKeys: String, CodingKey {
            case timeUnixNano, observedTimeUnixNano, severityNumber, severityText, body, attributes, traceId, spanId, eventName
        }

        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(String(record.timeNs), forKey: .timeUnixNano)
            if record.observedNs != 0 { try c.encode(String(record.observedNs), forKey: .observedTimeUnixNano) }
            if record.severityNumber != 0 { try c.encode(record.severityNumber, forKey: .severityNumber) }
            if !record.severityText.isEmpty { try c.encode(record.severityText, forKey: .severityText) }
            try c.encode(AnyValue(.string(record.body)), forKey: .body)
            if !record.attributes.pairs.isEmpty { try c.encode(record.attributes.pairs.map(KeyValue.init), forKey: .attributes) }
            try c.encodeIfPresent(record.traceID, forKey: .traceId)
            try c.encodeIfPresent(record.spanID, forKey: .spanId)
            if !record.eventName.isEmpty { try c.encode(record.eventName, forKey: .eventName) }
        }
    }

    private struct KeyValue: Encodable {
        var key: String
        var value: AnyValue
        init(_ attribute: Attribute) {
            key = attribute.key
            value = AnyValue(attribute.value)
        }
    }

    private struct ArrayValue: Encodable { var values: [AnyValue] }
    private struct KeyValueList: Encodable { var values: [KeyValue] }

    /// OTLP's AnyValue: one of its fields, or none for an empty value.
    private struct AnyValue: Encodable {
        var value: AttributeValue
        init(_ value: AttributeValue) { self.value = value }

        enum CodingKeys: String, CodingKey { case stringValue, intValue, doubleValue, boolValue, arrayValue, kvlistValue }

        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch value {
            case .string(let v): try c.encode(v, forKey: .stringValue)
            case .int(let v): try c.encode(String(v), forKey: .intValue)
            case .double(let v): try c.encode(v, forKey: .doubleValue)
            case .bool(let v): try c.encode(v, forKey: .boolValue)
            case .array(let v): try c.encode(ArrayValue(values: v.map(AnyValue.init)), forKey: .arrayValue)
            case .object(let v): try c.encode(KeyValueList(values: v.map(KeyValue.init)), forKey: .kvlistValue)
            case .null: break
            }
        }
    }
}
