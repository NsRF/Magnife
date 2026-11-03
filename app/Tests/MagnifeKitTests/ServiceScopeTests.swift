import Foundation
import GRDB
import Testing
@testable import MagnifeKit

/// The sidebar's service scope (S-009): traces with any span from the
/// service, its count of traces with errors, and the index that keeps both
/// cheap at 12,000+ spans.
@Suite("Service scope (S-009)", .serialized)
struct ServiceScopeTests {
    static let base: Int64 = 1_730_000_000_000_000_000
    static let traceCount = 2_400

    /// 2,400 traces of 5 spans (12,000 spans), one per batch: the root from
    /// web, two checkout-api children, and two more from orders in every
    /// third trace (one of them Error in every 30th trace), else from
    /// checkout-api. inventory has one span, in trace 7, which it does not root.
    private func makeStore() async throws -> (TempDir, DatabaseQueue, TelemetryReader) {
        let dir = try TempDir("service-scope")
        let writer = try makeWriter(at: dir.file("magnife.sqlite"))
        try await writer.write { db in
            for n in 1...Self.traceCount {
                let id = traceID(n)
                let start = Self.base + Int64(n) * 1_000_000_000
                let orders = n % 3 == 0
                try insertTrace(db, id: id, service: "web", route: "GET /\(n)", startNs: start,
                                status: orders && n % 30 == 0 ? 2 : 0, seq: Int64(n), spanCount: 5)
                for child in 1...4 {
                    let service = child > 2 && orders ? "orders" : "checkout-api"
                    try insertSpan(db, trace: id, span: String(format: "%012x%04x", n, child),
                                   parent: String(id.prefix(16)), name: "child \(child)", service: service,
                                   startNs: start + Int64(child), durationNs: 10,
                                   status: service == "orders" && child == 3 && n % 30 == 0 ? 2 : 0)
                }
            }
            try insertSpan(db, trace: traceID(7), span: "00000000000007ff", parent: String(traceID(7).prefix(16)),
                           name: "reserve", service: "inventory", startNs: Self.base + 7_000_000_005, durationNs: 10,
                           status: 2)
        }
        return (dir, writer, try await TelemetryReader.open(at: dir.file("magnife.sqlite")))
    }

    /// SQLite's plan for `sql`, one line per step.
    private func plan(_ writer: DatabaseQueue, _ sql: String, _ arguments: StatementArguments) async throws -> String {
        try await writer.read { db in
            try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql, arguments: arguments)
                .map { $0["detail"] as String }.joined(separator: " | ")
        }
    }

    @Test("every scoped query reads spans through spans_by_service_status, never a scan of spans")
    func indexed() async throws {
        let (dir, writer, reader) = try await makeStore()
        defer { dir.remove() }
        _ = reader
        let queries: [(String, StatementArguments)] = [
            (TelemetrySQL.latestTraces(cursor: false, service: true), ["orders", 200]),
            (TelemetrySQL.latestTraces(cursor: true, service: true), [Self.base, Self.base, traceID(1), "orders", 200]),
            (TelemetrySQL.scopeTraceCount(service: true), ["orders"]),
            (TelemetrySQL.tracesCreatedAfter(service: true), [5, "orders"]),
            (TelemetrySQL.servicesWithErrors, []),
        ]
        for (sql, arguments) in queries {
            let steps = try await plan(writer, sql, arguments)
            #expect(steps.contains("COVERING INDEX spans_by_service_status"), "\(steps)")
            #expect(!steps.contains("SCAN spans"), "\(steps)")
        }
    }

    @Test("a service scope lists traces with any span from it, newest first, at 12,000 spans")
    func scope() async throws {
        let (dir, writer, reader) = try await makeStore()
        defer { dir.remove() }
        _ = writer
        let clock = ContinuousClock()
        var page = TracePage(traces: [], services: [], lastSeq: 0)
        let elapsed = try await clock.measure { page = try await reader.tracePage(service: "orders") }
        // Every third trace has orders spans; none of them is rooted in orders.
        let expected = stride(from: Self.traceCount - Self.traceCount % 3, through: 3, by: -3).map { traceID($0) }
        #expect(page.traces.map(\.traceID) == Array(expected.prefix(TraceList.pageSize)))
        #expect(page.traces.allSatisfy { $0.rootService == "web" })
        #expect(page.traceCount == Self.traceCount / 3)
        #expect(page.lastSeq == Int64(Self.traceCount))
        let next = try await reader.latestTraces(after: page.traces.last?.cursor, service: "orders")
        #expect(next.first?.traceID == expected[TraceList.pageSize])
        // A service with one span in one trace it does not root.
        let inventory = try await reader.tracePage(service: "inventory")
        #expect(inventory.traces.map(\.traceID) == [traceID(7)] && inventory.traceCount == 1)
        #expect(try await reader.tracePage(service: "nobody").traces.isEmpty)
        #expect(try await reader.tracePage().traceCount == Self.traceCount)
        print("INFO scoped first page at 12,005 spans: \(elapsed)")
    }

    @Test("a service's count is the traces in which it has an Error span, alphabetical")
    func errorCounts() async throws {
        let (dir, writer, reader) = try await makeStore()
        defer { dir.remove() }
        _ = writer
        let services = try await reader.services()
        #expect(services.map(\.name) == ["checkout-api", "inventory", "orders", "web"])
        // orders: one Error span in each of 80 traces; web: the root of the same 80.
        #expect(services.map(\.errorCount) == [0, 1, Self.traceCount / 30, Self.traceCount / 30])
        // New traces in a scope: created after a seq, with a span from it.
        #expect(try await reader.heldTraces(base: Int64(Self.traceCount - 9), applied: Int64(Self.traceCount),
                                            shown: [], service: "orders").newCount == 3)
    }

    @Test("the sidebar's count and what VoiceOver reads", arguments: [
        (0, "0 traces with errors", "no errors"),
        (1, "1 trace with errors", "1 trace with errors"),
        (12, "12 traces with errors", "12 traces with errors"),
        // Counts group the en_US way on every region (CountFormat, PROGRESS decision 192).
        (1_204, "1,204 traces with errors", "1,204 traces with errors"),
    ])
    func words(count: Int, text: String, spoken: String) {
        let service = ServiceSummary(name: "checkout-api", firstSeenNs: 0, lastSeenNs: 0, errorCount: count)
        #expect(service.errorCountText == text)
        #expect(service.spokenErrors == spoken)
    }

    @Test("the window's subtitle counts the list", arguments: [(1, "1 trace"), (5, "5 traces"),
                                                                    (1_204, "1,204 traces")])
    func subtitle(count: Int, expected: String) {
        #expect(TraceList.subtitle(traceCount: count) == expected)
    }
}
