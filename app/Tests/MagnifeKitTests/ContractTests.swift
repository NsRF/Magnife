import Foundation
import GRDB
import Testing
@testable import MagnifeKit

/// The read layer against docs/schema.sql itself, with rows written exactly
/// as the Go helper writes them: its INSERT statements
/// (ingest/internal/store/statements.go) and its JSON encoding
/// (ingest/internal/convert/json.go: sorted keys, 'g' doubles, base64 bytes,
/// "NaN" for non-finite doubles, null link span ids).
@Suite("Contract with docs/schema.sql", .serialized)
struct ContractTests {
    static let base: Int64 = 1_730_000_000_000_000_000
    static let traceA = "4bf92f3577b34da6a3ce929d0e0e4736"
    static let traceB = "0af7651916cd43dd8448eb211c80319c"
    static let root = "00f067aa0ba902b7"
    static let child = "b7ad6b7169203331"

    /// Every AnyValue type, as the helper encodes it.
    static let allTypes = #"{"arr":[1,"two",1.5,true,null,{"k":"v"},[2]],"b":false,"big":9223372036854775807,"#
        + #""bytes":"AAEC","d":1.5,"exp":1e+21,"i":-42,"nan":"NaN","nil":null,"#
        + #""obj":{"a":"first","z":{"deep":true}},"s":"a \"quoted\"\nline\u0001 é �","small":1e-06}"#

    static let events = #"[{"time_ns":1730000000100000000,"name":"exception","attributes":{"#
        + #""exception.message":"Sequence contains no elements","exception.stacktrace":"at A\n   at B","#
        + #""exception.type":"System.InvalidOperationException"}},"#
        + #"{"time_ns":1730000000200000000,"name":"retry","attributes":{}}]"#

    static let links = #"[{"trace_id":"0af7651916cd43dd8448eb211c80319c","span_id":null,"attributes":{"link.kind":"retry"}},"#
        + #"{"trace_id":"0af7651916cd43dd8448eb211c80319c","span_id":"53995c3f42cd8ad8","attributes":{}}]"#

    private func makeStore() async throws -> (TempDir, DatabaseQueue, TelemetryReader) {
        #expect(Schema.sql.contains("PRAGMA user_version = 1;"), "docs/schema.sql not found")
        let dir = try TempDir("contract")
        let url = dir.file("magnife.sqlite")
        var config = Configuration()
        config.journalMode = .wal
        config.prepareDatabase { try $0.execute(sql: "PRAGMA synchronous = NORMAL; PRAGMA foreign_keys = OFF") }
        let writer = try DatabaseQueue(path: url.path, configuration: config)
        try await writer.write { db in
            try db.execute(sql: Schema.sql)
            try Self.setMeta(db, "schema_version", "1")
            try Self.setMeta(db, "retention_s", "86400")

            // Batch 1: trace A's root (checkout-api) and child (orders, Error), and logs.
            let checkout = try Self.resource(db, hash: String(repeating: "a", count: 64), service: "checkout-api",
                                             attributes: #"{"host.name":"mac","service.name":"checkout-api"}"#)
            let orders = try Self.resource(db, hash: String(repeating: "b", count: 64), service: "orders",
                                           attributes: Self.allTypes)
            try Self.service(db, "checkout-api", Self.base)
            try Self.service(db, "orders", Self.base)
            try Self.span(db, trace: Self.traceA, span: Self.root, parent: nil, name: "POST /orders", kind: 2,
                          start: Self.base, end: Self.base + 240_000_000, status: 0, message: "",
                          service: "checkout-api", resource: checkout, attributes: #"{"http.request.method":"POST","http.route":"/orders"}"#,
                          method: "POST", statusCode: 201, route: "/orders", url: "http://localhost:5080/orders")
            try Self.span(db, trace: Self.traceA, span: Self.child, parent: Self.root, name: "SELECT shop.carts", kind: 3,
                          start: Self.base + 10_000_000, end: Self.base + 17_000_000, status: 2,
                          message: "deadlock", service: "orders", resource: orders, attributes: Self.allTypes,
                          events: Self.events, links: Self.links, dbSystem: "postgresql",
                          statement: "SELECT * FROM carts WHERE id = $1")
            try Self.recomputeTrace(db, Self.traceA, seq: 1)
            try Self.log(db, time: Self.base + 12_000_000, severity: 17, text: "Error", service: "orders",
                         resource: orders, body: "query failed", trace: Self.traceA, span: Self.child)
            try Self.log(db, time: Self.base + 1_000_000, severity: 9, text: "Information", service: "checkout-api",
                         resource: checkout, body: #"{"order":42}"#, trace: Self.traceA, span: nil, event: "order.created")
            try Self.key(db, "http.route", 1)
            try Self.key(db, "service.name", 2)
            try Self.key(db, "order.id", 3)
            try Self.setMeta(db, "last_seq", "1")

            // Batch 2: trace B, root not arrived yet: its orphan names the trace, status 0.
            try Self.service(db, "web", Self.base + 5_000_000_000)
            let web = try Self.resource(db, hash: String(repeating: "c", count: 64), service: "web", attributes: "{}")
            try Self.span(db, trace: Self.traceB, span: "53995c3f42cd8ad8", parent: "a3ce929d0e0e4736", name: "GET /products",
                          kind: 2, start: Self.base + 5_000_000_000, end: Self.base + 5_000_400_000, status: 1, message: "",
                          service: "web", resource: web, attributes: "{}", method: "GET")
            try Self.recomputeTrace(db, Self.traceB, seq: 2)
            try Self.log(db, time: Self.base + 6_000_000_000, severity: 0, text: "", service: "web", resource: web,
                         body: "no trace", trace: nil, span: nil)
            try Self.setMeta(db, "last_seq", "2")
        }
        return (dir, writer, try await TelemetryReader.open(at: url))
    }

    @Test("the contract says the writer keeps its -wal, which a read-only reader needs (S-008)")
    func persistentWAL() {
        // A writer without it leaves no -wal on exit, and a relaunched app reads
        // nothing until the helper is up (WALReadonlyTests, LifecycleTests).
        #expect(Schema.sql.contains("SQLITE_FCNTL_PERSIST_WAL"))
        #expect(Schema.sql.contains("-wal and -shm files stay after the helper exits"))
    }

    @Test("traces: columns, order, cursor, service scope, counts")
    func traces() async throws {
        let (dir, writer, reader) = try await makeStore()
        defer { dir.remove() }
        _ = writer
        let traces = try await reader.latestTraces()
        #expect(traces.map(\.traceID) == [Self.traceB, Self.traceA])
        let a = try #require(traces.last)
        #expect(a.rootSpanID == Self.root)
        #expect(a.rootService == "checkout-api")
        #expect(a.route == "POST /orders")
        #expect(a.startNs == Self.base)
        #expect(a.endNs == Self.base + 240_000_000)
        #expect(a.durationNs == 240_000_000)
        #expect(a.spanCount == 2)
        #expect(a.errorCount == 1)
        #expect(a.status == .error)
        #expect(a.firstSeq == 1 && a.updatedSeq == 1)
        #expect(a.receivedNs > 0)

        let b = try #require(traces.first)
        #expect(b.rootSpanID == nil)
        #expect(b.rootService == "web")
        #expect(b.route == "GET /products")
        #expect(b.status == .unset)

        #expect(try await reader.latestTraces(limit: 1, after: b.cursor).map(\.traceID) == [Self.traceA])
        #expect(try await reader.latestTraces(service: "orders").map(\.traceID) == [Self.traceA])
        #expect(try await reader.trace(id: Self.traceA) == a)
        #expect(try await reader.traceCount() == 2)
        #expect(try await reader.traceCount(createdAfter: 1) == 1)
        #expect(try await reader.lastSeq() == 2)
    }

    @Test("spans: ids, kind and status codes, promoted columns, events, links")
    func spans() async throws {
        let (dir, writer, reader) = try await makeStore()
        defer { dir.remove() }
        _ = writer
        let spans = try await reader.spans(traceID: Self.traceA)
        #expect(spans.map(\.spanID) == [Self.root, Self.child])
        let root = spans[0], child = spans[1]
        #expect(root.isRoot && root.kind == .server && root.status == .unset)
        #expect(root.httpMethod == "POST" && root.httpRoute == "/orders" && root.httpStatusCode == 201)
        #expect(root.httpURL == "http://localhost:5080/orders")
        #expect(root.dbSystem == nil && root.dbStatement == nil)
        #expect(root.events.isEmpty && root.links.isEmpty)

        #expect(child.parentSpanID == Self.root)
        #expect(child.kind == .client)
        #expect(child.status == .error && child.statusMessage == "deadlock")
        #expect(child.durationNs == 7_000_000)
        #expect(child.serviceName == "orders")
        #expect(child.scopeName == "Npgsql" && child.scopeVersion == "8.0.3")
        #expect(child.dbSystem == "postgresql" && child.dbStatement == "SELECT * FROM carts WHERE id = $1")
        #expect(child.httpStatusCode == nil)
        Self.expectAllTypes(child.attributes)

        #expect(child.events.map(\.name) == ["exception", "retry"])
        #expect(child.events[0].timeNs == 1_730_000_000_100_000_000)
        let exception = try #require(child.exceptions.first)
        #expect(exception.type == "System.InvalidOperationException")
        #expect(exception.message == "Sequence contains no elements")
        #expect(exception.stackTrace == "at A\n   at B")
        #expect(child.exceptions.count == 1)

        #expect(child.links.count == 2)
        #expect(child.links[0].traceID == Self.traceB && child.links[0].spanID == "")
        #expect(child.links[0].attributes["link.kind"] == .string("retry"))
        #expect(child.links[1].spanID == "53995c3f42cd8ad8")

        let resource = try #require(try await reader.resource(id: child.resourceID))
        #expect(resource.serviceName == "orders")
        Self.expectAllTypes(resource.attributes)

        // The waterfall's columns and one span by id (S-005).
        let bars = try await reader.waterfallSpans(traceID: Self.traceA)
        #expect(bars.map(\.spanID) == [Self.root, Self.child])
        #expect(bars[1].parentSpanID == Self.root && bars[1].kind == .client && bars[1].status == .error)
        #expect(bars[1].durationNs == 7_000_000 && bars[1].serviceName == "orders")
        #expect(bars[0].parentSpanID == nil && bars[0].startNs == root.startNs)
        // A comparison's columns of both traces, in one read (S-036).
        let compared = try await reader.comparison(traceA: Self.traceA, traceB: Self.traceB)
        #expect(compared.traceA?.traceID == Self.traceA && compared.traceB?.traceID == Self.traceB)
        #expect(compared.spansA.map(\.span) == bars)
        #expect(compared.spansA[0].httpURL == "http://localhost:5080/orders" && compared.spansA[0].dbStatement == nil)
        #expect(compared.spansA[1].dbStatement == "SELECT * FROM carts WHERE id = $1")
        let gone = try await reader.comparison(traceA: Self.traceA, traceB: "missing")
        #expect(gone.traceB == nil && gone.spansB.isEmpty)
        let one = try await reader.span(traceID: Self.traceA, spanID: Self.child)
        #expect(one == child)
        #expect(try await reader.span(traceID: Self.traceA, spanID: "missing") == nil)

        // The span detail reads the span and its resource together (S-006).
        let detail = try #require(try await reader.spanDetail(traceID: Self.traceA, spanID: Self.child))
        #expect(detail.span == child && detail.resource == resource)
        // ...and the logs written during it, not the trace's other logs (S-011).
        #expect(detail.logs.map(\.record.body) == ["query failed"] && detail.sections.last == .logs)
        let rootDetail = try #require(try await reader.spanDetail(traceID: Self.traceA, spanID: Self.root))
        #expect(rootDetail.logs.isEmpty && !rootDetail.sections.contains(.logs))
        #expect(try await reader.spanDetail(traceID: Self.traceA, spanID: "missing") == nil)
    }

    @Test("logs: by trace, by span, latest, levels, JSON bodies")
    func logs() async throws {
        let (dir, writer, reader) = try await makeStore()
        defer { dir.remove() }
        _ = writer
        let ofTrace = try await reader.logs(traceID: Self.traceA)
        #expect(ofTrace.map(\.body) == [#"{"order":42}"#, "query failed"])
        let created = ofTrace[0]
        #expect(created.spanID == nil && created.eventName == "order.created")
        #expect(created.level == .info && created.severityText == "Information")
        #expect(created.observedNs == Self.base + 1_000_000)
        #expect(created.attributes["order.id"] == .int(42))
        #expect(try await reader.logs(traceID: Self.traceA, spanID: Self.child).map(\.body) == ["query failed"])

        let latest = try await reader.latestLogs()
        #expect(latest.map(\.body) == ["no trace", "query failed", #"{"order":42}"#])
        #expect(latest[0].traceID == nil && latest[0].level == nil)
        #expect(try await reader.latestLogs(level: .error).map(\.body) == ["query failed"])
        #expect(try await reader.latestLogs(service: "checkout-api").map(\.body) == [#"{"order":42}"#])
        #expect(try await reader.latestLogs(limit: 1, after: latest[0].cursor).map(\.body) == ["query failed"])
    }

    @Test("services, error counts, attribute keys")
    func servicesAndKeys() async throws {
        let (dir, writer, reader) = try await makeStore()
        defer { dir.remove() }
        _ = writer
        let services = try await reader.services()
        #expect(services.map(\.name) == ["checkout-api", "orders", "web"])
        #expect(services.map(\.errorCount) == [0, 1, 0])
        #expect(services[2].firstSeenNs == Self.base + 5_000_000_000)
        let keys = try await reader.attributeKeys()
        #expect(keys.map(\.key) == ["http.route", "order.id", "service.name"])
        #expect(keys.map(\.source) == [.span, .log, .resource])
        #expect(try await reader.attributeKeys(source: .log).map(\.key) == ["order.id"])
    }

    @Test("every AnyValue type decodes from the helper's JSON")
    func anyValues() {
        Self.expectAllTypes(Attributes(json: Self.allTypes))
        #expect(Attributes(json: "{}").isEmpty)
    }

    static func expectAllTypes(_ attributes: Attributes) {
        #expect(attributes["s"] == .string("a \"quoted\"\nline\u{01} é \u{FFFD}"))
        #expect(attributes["i"] == .int(-42))
        #expect(attributes["big"] == .int(.max))
        #expect(attributes["d"] == .double(1.5))
        #expect(attributes["exp"] == .double(1e21))
        #expect(attributes["small"] == .double(0.000001))
        #expect(attributes["b"] == .bool(false))
        #expect(attributes["nil"] == .null)
        // bytes are base64 text, and non-finite doubles are strings (json.go).
        #expect(attributes["bytes"] == .string("AAEC"))
        #expect(attributes["nan"] == .string("NaN"))
        #expect(attributes["arr"] == .array([.int(1), .string("two"), .double(1.5), .bool(true), .null,
                                             .object([Attribute("k", .string("v"))]), .array([.int(2)])]))
        #expect(attributes["obj"] == .object([Attribute("a", .string("first")),
                                              Attribute("z", .object([Attribute("deep", .bool(true))]))]))
        #expect(attributes.count == 12)
    }

    // MARK: The helper's writes (ingest/internal/store/statements.go)

    private static func setMeta(_ db: Database, _ key: String, _ value: String) throws {
        try db.execute(sql: "INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value",
                       arguments: [key, value])
    }

    private static func resource(_ db: Database, hash: String, service: String, attributes: String) throws -> Int64 {
        try db.execute(sql: "INSERT INTO resources (hash, service_name, attributes) VALUES (?, ?, ?) ON CONFLICT (hash) DO NOTHING",
                       arguments: [hash, service, attributes])
        return try Int64.fetchOne(db, sql: "SELECT id FROM resources WHERE hash = ?", arguments: [hash])!
    }

    private static func service(_ db: Database, _ name: String, _ ns: Int64) throws {
        try db.execute(sql: """
            INSERT INTO services (name, first_seen_ns, last_seen_ns) VALUES (?, ?, ?)
            ON CONFLICT (name) DO UPDATE SET last_seen_ns = MAX(last_seen_ns, excluded.last_seen_ns)
            """, arguments: [name, ns, ns])
    }

    private static func span(_ db: Database, trace: String, span: String, parent: String?, name: String, kind: Int,
                             start: Int64, end: Int64, status: Int, message: String, service: String, resource: Int64,
                             attributes: String, events: String = "[]", links: String = "[]",
                             dbSystem: String? = nil, statement: String? = nil, method: String? = nil,
                             statusCode: Int? = nil, route: String? = nil, url: String? = nil) throws {
        let scope = dbSystem == nil ? ("", "") : ("Npgsql", "8.0.3")
        try db.execute(sql: """
            INSERT INTO spans (trace_id, span_id, parent_span_id, name, kind, start_ns, end_ns, duration_ns,
                status_code, status_message, service_name, resource_id, scope_name, scope_version,
                attributes, events, links, db_system, db_statement, http_method, http_status_code,
                http_route, http_url, received_ns)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [trace, span, parent, name, kind, start, end, max(0, end - start), status, message,
                             service, resource, scope.0, scope.1, attributes, events, links, dbSystem, statement,
                             method, statusCode, route, url, start])
    }

    /// The traces row from its spans, by the rules on the traces table.
    private static func recomputeTrace(_ db: Database, _ trace: String, seq: Int64) throws {
        let agg = try Row.fetchOne(db, sql: "SELECT MIN(start_ns), MAX(end_ns), COUNT(*), TOTAL(status_code = 2) FROM spans WHERE trace_id = ?",
                                   arguments: [trace])!
        let start: Int64 = agg[0], end: Int64 = agg[1], count: Int = agg[2], errors = Int(agg[3] as Double)
        let root = try Row.fetchOne(db, sql: """
            SELECT span_id, service_name, name, http_method, http_route, status_code
            FROM spans WHERE trace_id = ? AND parent_span_id IS NULL ORDER BY start_ns, id LIMIT 1
            """, arguments: [trace])
        let named = try root ?? Row.fetchOne(db, sql: """
            SELECT NULL AS span_id, s.service_name, s.name, s.http_method, s.http_route, 0 AS status_code
            FROM spans s WHERE s.trace_id = ?1 AND NOT EXISTS (
                SELECT 1 FROM spans p WHERE p.trace_id = ?1 AND p.span_id = s.parent_span_id)
            ORDER BY s.start_ns, s.id LIMIT 1
            """, arguments: [trace])!
        let method: String? = named["http_method"], httpRoute: String? = named["http_route"]
        let route = switch (method, httpRoute) {
        case let (method?, httpRoute?): "\(method) \(httpRoute)"
        case let (nil, httpRoute?): httpRoute
        default: named["name"] as String
        }
        let status = errors > 0 ? 2 : (root == nil ? 0 : named["status_code"] as Int)
        try db.execute(sql: """
            INSERT INTO traces (trace_id, root_span_id, root_service, route, start_ns, end_ns,
                duration_ns, span_count, error_count, status, first_seq, updated_seq, received_ns)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [trace, named["span_id"] as String?, named["service_name"] as String, route, start, end,
                             end - start, count, errors, status, seq, seq, end])
    }

    private static func log(_ db: Database, time: Int64, severity: Int, text: String, service: String, resource: Int64,
                            body: String, trace: String?, span: String?, event: String = "") throws {
        try db.execute(sql: """
            INSERT INTO logs (time_ns, observed_ns, severity_number, severity_text,
                service_name, resource_id, scope_name, body, attributes, trace_id, span_id, event_name, received_ns)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [time, time, severity, text, service, resource, "", body,
                             event.isEmpty ? "{}" : #"{"order.id":42}"#, trace, span, event, time])
    }

    private static func key(_ db: Database, _ key: String, _ source: Int) throws {
        try db.execute(sql: """
            INSERT INTO attribute_keys (key, source, last_seen_ns) VALUES (?, ?, ?)
            ON CONFLICT (key, source) DO UPDATE SET last_seen_ns = excluded.last_seen_ns
            """, arguments: [key, source, base])
    }
}
