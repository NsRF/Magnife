import Foundation
import GRDB
import Testing
@testable import MagnifeKit

/// How long Search and the filtered list take to read (S-017: results
/// within 100 ms on 100,000 spans). A generated 12,000-span store always
/// runs; MAGNIFE_PERF_STORES=<db>,<db> times stores the sample sender
/// filled through the real helper (`--volume 100000`, `--volume 300000`)
/// and prints the times, for docs/PROGRESS.md.
@Suite("Search speed (S-017)", .serialized)
struct TraceSearchSpeedTests {
    static let queries = ["o", "or", "orders", "paymnt", "payment", "http", "status:error", "service:orders",
                          ">200ms", "http.route=/orders", "has:db.system", "status:error service:orders >100ms",
                          "4bf92f3577b34da6", "orders status:error >100ms ht", "service:orders paymnt"]

    /// 2,400 traces of 5 spans, each span with three attributes, a few with a statement.
    private func makeStore() async throws -> (TempDir, TelemetryReader) {
        let dir = try TempDir("search-speed")
        let writer = try makeWriter(at: dir.file("magnife.sqlite"))
        let base: Int64 = 1_730_000_000_000_000_000
        try await writer.write { db in
            for n in 1...2_400 {
                let id = traceID(n)
                let start = base + Int64(n) * 1_000_000_000
                try insertTrace(db, id: id, service: "web", route: "GET /items/\(n % 40)", startNs: start,
                                durationNs: Int64(n % 900) * 1_000_000, status: n % 30 == 0 ? 2 : 1, seq: Int64(n),
                                spanCount: 5)
                for child in 1...4 {
                    let attributes = #"{"http.route":"/items/{id}","http.method":"GET","item.id":\#(n * 10 + child)"#
                        + (child == 3 ? #","db.system":"postgresql","db.statement":"SELECT * FROM orders WHERE id = \#(n)""# : "")
                        + "}"
                    try insertSpan(db, trace: id, span: String(format: "%012x%04x", n, child),
                                   parent: String(id.prefix(16)), name: "child \(child)",
                                   service: child > 2 ? "orders" : "checkout-api", startNs: start + Int64(child),
                                   durationNs: 10, attributes: attributes)
                }
            }
        }
        return (dir, try await TelemetryReader.open(at: dir.file("magnife.sqlite")))
    }

    /// The slowest of three runs of each query's page, in milliseconds, and of its count when the page had none.
    private func time(_ reader: TelemetryReader, _ text: String) async throws -> (page: Double, count: Double) {
        var worst = (page: 0.0, count: 0.0)
        for _ in 0..<3 {
            let started = ContinuousClock.now
            let result = try await reader.searchTraces(TraceQuery(text))
            let paged = ContinuousClock.now
            if result.total == nil { _ = try await reader.searchCount(TraceQuery(text)) }
            worst.page = max(worst.page, (paged - started) / .milliseconds(1))
            worst.count = max(worst.count, (ContinuousClock.now - paged) / .milliseconds(1))
        }
        return worst
    }

    @Test("every query answers within 100 ms at 12,000 spans")
    func generated() async throws {
        let (dir, reader) = try await makeStore()
        defer { dir.remove() }
        _ = try await reader.searchTraces(TraceQuery("warm"))
        for text in Self.queries {
            let ms = try await time(reader, text)
            #expect(ms.page < 100, "\(text): \(ms.page) ms")
        }
        let orders = try await reader.searchTraces(TraceQuery("orders"))
        #expect(orders.traces.count == TraceSearch.resultLimit)
        #expect(try await reader.searchCount(TraceQuery("orders")) == 2_400)
    }

    @Test("the sample sender's stores (MAGNIFE_PERF_STORES)")
    func stores() async throws {
        let paths = ProcessInfo.processInfo.environment["MAGNIFE_PERF_STORES"]?.split(separator: ",") ?? []
        for path in paths {
            let reader = try await TelemetryReader.open(at: URL(fileURLWithPath: String(path)))
            _ = try await reader.searchTraces(TraceQuery("warm"))
            var lines: [String] = []
            for text in Self.queries {
                let ms = try await time(reader, text)
                lines.append("\(text) \(String(format: "%.1f", ms.page)) ms" + (ms.count > 0.05 ? " (+count \(String(format: "%.0f", ms.count)))" : ""))
            }
            for text in ["status:error", ">200ms", "http.route=/orders", "orders"] {
                let filter = TraceQuery(text).filter
                let started = ContinuousClock.now
                let page = try await reader.tracePage(filter: filter)
                let ms = (ContinuousClock.now - started) / .milliseconds(1)
                lines.append("list \(text) \(String(format: "%.1f", ms)) ms (\(page.traceCount) of \(page.scopeCount))")
            }
            print("INFO \(path): " + lines.joined(separator: "; "))
        }
    }
}
