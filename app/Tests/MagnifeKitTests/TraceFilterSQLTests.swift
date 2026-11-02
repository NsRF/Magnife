import Foundation
import GRDB
import Testing
@testable import MagnifeKit

/// The SQL a TraceFilter becomes, run on a small store the way the helper
/// writes it: which traces each condition keeps (docs/ux.md, "Search tokens").
@Suite("Trace filter SQL (S-017 to S-020)", .serialized)
struct TraceFilterSQLTests {
    static let base: Int64 = 1_730_000_000_000_000_000

    /// 1 GET /checkout (web root, a checkout-api child "charge card" with
    ///   http.route /orders, status code 500, provider stripe), 120 ms.
    /// 2 POST /orders (orders root with a postgresql statement and a "50% off"
    ///   coupon), its resource on host build-box, 900 ms.
    /// 3 GET /health (web, an attribute key payment.id whose value is x1), 2 ms.
    /// Trace 3 is the newest.
    static func makeStore() async throws -> (TempDir, DatabaseQueue, TelemetryReader) {
        let dir = try TempDir("trace-filter")
        let writer = try makeWriter(at: dir.file("magnife.sqlite"))
        try await writer.write { db in
            let one = traceID(1), two = traceID(2), three = traceID(3)
            try insertTrace(db, id: one, service: "web", route: "GET /checkout", startNs: base + 1_000,
                            durationNs: 120_000_000, status: 2, seq: 1, spanCount: 2)
            try insertSpan(db, trace: one, span: "00000000000000c1", parent: String(one.prefix(16)), name: "charge card",
                           service: "checkout-api", startNs: base + 2_000, durationNs: 100_000_000, status: 2,
                           attributes: #"{"http.route":"/orders","http.status_code":500,"payment.provider":"stripe","retry":true}"#)
            try insertTrace(db, id: two, service: "orders", route: "POST /orders", startNs: base + 2_000_000,
                            durationNs: 900_000_000, status: 1, seq: 2)
            try db.execute(sql: "UPDATE spans SET attributes = ? WHERE trace_id = ?",
                           arguments: [#"{"db.system":"postgresql","db.statement":"SELECT * FROM orders","coupon":"50% off","items":3}"#, two])
            try insertTrace(db, id: three, service: "web", route: "GET /health", startNs: base + 3_000_000,
                            durationNs: 2_000_000, status: 0, seq: 3)
            try db.execute(sql: "UPDATE spans SET attributes = ? WHERE trace_id = ?",
                           arguments: [#"{"payment.id":"x1"}"#, three])
            try db.execute(sql: "UPDATE resources SET attributes = ? WHERE service_name = 'orders'",
                           arguments: [#"{"service.name":"orders","host.name":"build-box"}"#])
        }
        return (dir, writer, try await TelemetryReader.open(at: dir.file("magnife.sqlite")))
    }

    /// The trace numbers (1, 2, 3) a query keeps, newest first.
    private func matches(_ reader: TelemetryReader, _ text: String) async throws -> [Int] {
        try await reader.searchTraces(TraceQuery(text)).traces.map { trace in
            [traceID(1), traceID(2), traceID(3)].firstIndex(of: trace.traceID).map { $0 + 1 } ?? 0
        }
    }

    /// Any Field (S-017): service, route, trace ID, span name and attribute values.
    static let anyField: [(String, [Int])] = [
        ("checkout", [1]),            // a span's service (checkout-api) and the route
        ("web", [3, 1]),              // the root service
        ("health", [3]),              // the route
        ("charge", [1]),              // a span's name
        ("stripe", [1]),              // a span attribute's value
        ("STRIPE", [1]),              // A to Z ignore case
        ("build-box", [2]),           // a resource attribute's value
        ("payment", []),              // only in keys: keys are not values
        ("http.route", []),
        ("50%", [2]),                 // % is a plain character
        ("%", [2]),
        ("_", []),
        ("500", [1]),                 // a number's value
        ("4bf92f3577b34da6a3ce929d0e0e0002", [2]), // a trace ID
        ("0e0e000", [3, 2, 1]),       // part of every trace ID
        ("web charge", [1]),          // words combine with AND
        ("zzz", []),
    ]

    @Test("Any Field matches service, route, trace ID, span names and attribute values", arguments: anyField)
    func anyFieldMatches(_ text: String, expected: [Int]) async throws {
        let (dir, _, reader) = try await Self.makeStore()
        defer { dir.remove() }
        #expect(try await matches(reader, text) == expected, "\(text)")
    }

    /// The other tokens Search accepts (S-017), as the filter bar applies them.
    static let tokens: [(String, [Int])] = [
        ("service:checkout-api", [1]),       // any span from the service, not only the root's
        ("service:web", [3, 1]),
        ("status:error", [1]),
        ("status:ok status:unset", [3, 2]),
        ("route:/orders", [2]),
        ("route:checkout", [1]),
        (">200ms", [2]),
        (">100", [2, 1]),
        ("http.route=/orders", [1]),
        ("service:web >100", [1]),
        ("service:orders status:error", []),
    ]

    @Test("Search tokens keep the traces the filter bar would", arguments: tokens)
    func tokenMatches(_ text: String, expected: [Int]) async throws {
        let (dir, _, reader) = try await Self.makeStore()
        defer { dir.remove() }
        #expect(try await matches(reader, text) == expected, "\(text)")
    }

    @Test("an empty query lists the newest traces; a match counts every trace it keeps")
    func newestAndTotal() async throws {
        let (dir, _, reader) = try await Self.makeStore()
        defer { dir.remove() }
        let newest = try await reader.searchTraces(TraceQuery(""))
        #expect(newest.isNewest && newest.header == "Newest Traces" && newest.traces.count == 3)
        // A page that fills from the newest traces comes without its total; searchCount reads it.
        let one = try await reader.searchTraces(TraceQuery("0e0e000"), limit: 1)
        #expect(one.traces.count == 1 && one.total == nil && one.countText == "" && !one.isNewest)
        #expect(try await reader.searchCount(TraceQuery("0e0e000")) == 3)
        var counted = one
        counted.total = 3
        #expect(counted.countText == "1 of 3" && counted.spokenCount == "3 results")
        #expect(try await reader.searchTraces(TraceQuery("web")).countText == "2 traces")
        #expect(try await reader.searchTraces(TraceQuery("zzz")).total == 0)
        // A token still being typed filters nothing yet.
        #expect(try await reader.searchTraces(TraceQuery("status:")).isNewest)
    }

    @Test("the first look over the newest traces and the full read agree", arguments: [1, 2, 3, 50])
    func windows(_ window: Int) async throws {
        let (dir, _, reader) = try await Self.makeStore()
        defer { dir.remove() }
        for (text, expected) in Self.anyField + Self.tokens {
            let result = try await reader.searchTraces(TraceQuery(text), window: window)
            let ids = result.traces.map { trace in [traceID(1), traceID(2), traceID(3)].firstIndex(of: trace.traceID).map { $0 + 1 } ?? 0 }
            #expect(ids == expected, "\(text) in a window of \(window)")
            #expect(result.total == nil || result.total == expected.count, "\(text) in a window of \(window)")
        }
    }

    @Test("a trace ID prefix puts that trace first")
    func traceIDFirst() async throws {
        let (dir, writer, reader) = try await Self.makeStore()
        defer { dir.remove() }
        // A newer trace whose attribute holds the first trace's ID.
        try await writer.write { db in
            try insertTrace(db, id: traceID(4), service: "web", route: "GET /link", startNs: Self.base + 9_000_000, seq: 4)
            try db.execute(sql: "UPDATE spans SET attributes = ? WHERE trace_id = ?",
                           arguments: [#"{"link.trace_id":"\#(traceID(1))"}"#, traceID(4)])
        }
        let result = try await reader.searchTraces(TraceQuery(traceID(1)))
        #expect(result.traces.map(\.traceID) == [traceID(1), traceID(4)])
        // Every seed ID shares the first 28 digits: those that start with them all come first, newest first.
        let shared = try await reader.searchTraces(TraceQuery(String(traceID(1).prefix(12))))
        #expect(shared.traces.map(\.traceID) == [traceID(4), traceID(3), traceID(2), traceID(1)])
    }

    @Test("values are bound, never written into the SQL")
    func bound() {
        let filter = TraceQuery(#"service:x' status:error >1s k'=v'1 "it's" route:'r"#).filter
        let sql = TraceFilterSQL(filter)
        #expect(!sql.conditions.joined().contains("x'"))
        #expect(!sql.conditions.joined().contains("v'1"))
        #expect(!sql.conditions.joined().contains("it's"))
        #expect(sql.arguments.isEmpty == false)
    }

    @Test("LIKE patterns escape %, _ and the escape character")
    func patterns() {
        #expect(TraceFilterSQL.containsPattern("50%") == #"%50\%%"#)
        #expect(TraceFilterSQL.containsPattern("a_b") == #"%a\_b%"#)
        #expect(TraceFilterSQL.containsPattern(#"a\b"#) == #"%a\\b%"#)
        #expect(TraceFilterSQL.jsonPath("http.route") == #"$."http.route""#)
    }

    @Test("new traces are counted from their own spans, not a scan of every span")
    func perTracePlan() async throws {
        let (dir, writer, _) = try await Self.makeStore()
        defer { dir.remove() }
        let created = TraceFilterSQL(TraceQuery("stripe http.route=/orders").filter, spans: .perTrace)
        let steps = try await writer.read { db in
            try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + TelemetrySQL.tracesCreated(after: created),
                             arguments: [0] + created.arguments).map { $0["detail"] as String }
        }
        #expect(steps.contains { $0.contains("spans_by_trace") }, "\(steps)")
        #expect(!steps.contains { $0.hasPrefix("SCAN spans") }, "\(steps)")
    }
}
