import Foundation
import GRDB
import Testing
@testable import MagnifeKit

/// The live trace list (S-004): pages, holding still, service colors, and
/// what VoiceOver reads.
@Suite("Trace list (S-004)", .serialized)
struct TraceListTests {
    static let base: Int64 = 1_730_000_000_000_000_000

    /// Traces 1...count, one per batch (seq n), newest last; trace 2 is from web.
    private func makeStore(count: Int = 5) async throws -> (TempDir, DatabaseQueue, TelemetryReader) {
        let dir = try TempDir("trace-list")
        let writer = try makeWriter(at: dir.file("magnife.sqlite"))
        try await writer.write { db in
            for n in 1...count {
                try insertTrace(db, id: traceID(n), service: n == 2 ? "web" : "checkout-api", route: "GET /\(n)",
                                startNs: Self.base + Int64(n) * 1_000_000_000, seq: Int64(n))
            }
        }
        return (dir, writer, try await TelemetryReader.open(at: dir.file("magnife.sqlite")))
    }

    @Test("a page, its services and the last seq come from one read")
    func page() async throws {
        let (dir, writer, reader) = try await makeStore()
        defer { dir.remove() }
        _ = writer
        let page = try await reader.tracePage(limit: 3)
        #expect(page.traces.map(\.traceID) == [traceID(5), traceID(4), traceID(3)])
        #expect(page.services.map(\.name) == ["checkout-api", "web"])
        #expect(page.lastSeq == 5)
        let web = try await reader.tracePage(service: "web")
        #expect(web.traces.map(\.traceID) == [traceID(2)])
        #expect(TraceList.pageSize == 200)
    }

    @Test("while holding: new traces are counted, changed shown rows are read, nothing else")
    func held() async throws {
        let (dir, writer, reader) = try await makeStore()
        defer { dir.remove() }
        // The list was read at seq 5. Then batch 6 adds trace 6 and adds a
        // span to trace 3; batch 7 adds trace 7 from web.
        try await writer.write { db in
            try insertTrace(db, id: traceID(6), route: "GET /6", startNs: Self.base + 6_000_000_000, seq: 6)
            try db.execute(sql: "UPDATE traces SET span_count = 2, updated_seq = 6 WHERE trace_id = ?",
                           arguments: [traceID(3)])
            try insertTrace(db, id: traceID(7), service: "web", route: "GET /7",
                            startNs: Self.base + 7_000_000_000, seq: 7)
        }
        let shown = (1...5).reversed().map { traceID($0) }
        let held = try await reader.heldTraces(base: 5, applied: 5, shown: shown)
        #expect(held.newCount == 2)
        #expect(held.updated.map(\.traceID) == [traceID(3)])
        #expect(held.updated.first?.spanCount == 2)
        #expect(held.lastSeq == 7)
        // Applied up to 6: trace 3's change was already applied.
        #expect(try await reader.heldTraces(base: 5, applied: 6, shown: shown).updated.isEmpty)
        // A row that is not shown is not read.
        #expect(try await reader.heldTraces(base: 5, applied: 5, shown: [traceID(1)]).updated.isEmpty)
        // A service scope counts only its traces.
        let web = try await reader.heldTraces(base: 5, applied: 5, shown: [traceID(2)], service: "web")
        #expect(web.newCount == 1)
        #expect(web.updated.isEmpty)
    }

    @Test("while holding, every shown row that changed is read, however many changed")
    func heldManyUpdates() async throws {
        let (dir, writer, reader) = try await makeStore(count: 1_500)
        defer { dir.remove() }
        try await writer.write { db in
            try db.execute(sql: "UPDATE traces SET span_count = 3, updated_seq = 1501")
        }
        let shown = (1...1_500).reversed().map { traceID($0) }
        let held = try await reader.heldTraces(base: 1_500, applied: 1_500, shown: shown)
        #expect(held.updated.count == 1_500)
        #expect(held.updated.allSatisfy { $0.spanCount == 3 })
        // The oldest rows, far below the newest thousand, update too.
        #expect(held.updated.contains { $0.traceID == traceID(1) })
    }

    @Test("a held row updates in place; new and unshown rows stay out")
    func applying() {
        let shown = (1...3).reversed().map { trace($0) }
        var changed = trace(2)
        changed.spanCount = 9
        changed.startNs = Self.base // an earlier root arrived: the sort would move it, the held list does not
        let result = TraceList.applying([changed, trace(8)], to: shown)
        #expect(result.map(\.traceID) == shown.map(\.traceID))
        #expect(result[1].spanCount == 9)
        #expect(TraceList.applying([], to: shown) == shown)
    }

    @Test("the next page is appended without rows shown already")
    func appending() {
        let shown = [trace(5), trace(4)]
        #expect(TraceList.appending([trace(4), trace(3), trace(2)], to: shown).map(\.traceID)
                == [traceID(5), traceID(4), traceID(3), traceID(2)])
    }

    @Test("the new-traces button inflects", arguments: [(1, "1 new trace"), (2, "2 new traces"), (12, "12 new traces")])
    func title(count: Int, expected: String) {
        #expect(TraceList.newTracesTitle(count) == expected)
    }

    @Test("VoiceOver reads a row as service, route, duration, spans, status")
    func spoken() {
        var row = TraceSummary(traceID: traceID(1), rootService: "checkout-api", route: "POST /orders",
                               startNs: Self.base, durationNs: 240_000_000, spanCount: 18, status: .error)
        #expect(row.accessibilityLabel == "checkout-api, POST /orders, 240 milliseconds, 18 spans, Error")
        row.spanCount = 1
        row.durationNs = 1_240_000_000
        row.status = .ok
        #expect(row.accessibilityLabel == "checkout-api, POST /orders, 1.24 seconds, 1 span, OK")
        row.status = .unset
        #expect(row.accessibilityLabel == "checkout-api, POST /orders, 1.24 seconds, 1 span")
    }

    @Test("spoken durations", arguments: [
        (850_000, "850 microseconds"), (1_000_000, "1.0 milliseconds"), (240_000_000, "240 milliseconds"),
        (1_240_000_000, "1.24 seconds"), (125_000_000_000, "2 minutes 5 seconds"), (61_000_000_000, "1 minute 1 second"),
        (3_600_000_000_000, "1 hour"), (3_720_000_000_000, "1 hour 2 minutes"),
    ] as [(Int64, String)])
    func spokenDuration(ns: Int64, expected: String) {
        #expect(DurationFormat.spoken(nanoseconds: ns) == expected)
    }

    @Test("services take colors in the order first seen, distinct for the first ten, stable across reads")
    func colors() {
        let names = (0..<12).map { "service-\($0)" }
        let services = names.enumerated().map { index, name in
            ServiceSummary(name: name, firstSeenNs: Self.base + Int64(index), lastSeenNs: Self.base, errorCount: 0)
        }
        let colors = ServiceColors(services: services)
        #expect(names.prefix(10).map(colors.slot(for:)) == Array(0..<10))
        #expect(colors.slot(for: "service-10") == 0)
        // The same services read in another order (alphabetical, as the sidebar reads them) keep their slots.
        let again = ServiceColors(services: services.sorted { $0.name < $1.name }.reversed())
        #expect(names.map(again.slot(for:)) == names.map(colors.slot(for:)))
        // A new service takes the next slot without moving the others.
        let more = ServiceColors(services: services.prefix(3) + [ServiceSummary(
            name: "aaa-new", firstSeenNs: Self.base + 100, lastSeenNs: Self.base, errorCount: 0)])
        #expect(["service-0", "service-1", "service-2", "aaa-new"].map(more.slot(for:)) == [0, 1, 2, 3])
        // Ties on first seen go by name.
        let tied = ServiceColors(services: ["b", "a"].map {
            ServiceSummary(name: $0, firstSeenNs: Self.base, lastSeenNs: Self.base, errorCount: 0)
        })
        #expect(tied.slot(for: "a") == 0 && tied.slot(for: "b") == 1)
    }

    @Test("a service not read yet gets a stable hashed slot")
    func unknownService() {
        let colors = ServiceColors()
        #expect(colors.slot(for: "checkout-api") == ServiceColor.slot(for: "checkout-api"))
        #expect((0..<ServiceColors.paletteCount).contains(colors.slot(for: "checkout-api")))
        // FNV-1a reference values, so the fallback never changes between releases.
        #expect(ServiceColor.slot(for: "", slots: Int(UInt32.max)) == Int(0x811C_9DC5 % UInt32.max))
        #expect(ServiceColor.slot(for: "a", slots: Int(UInt32.max)) == Int(UInt32(0xE40C_292C) % UInt32.max))
    }

    private func trace(_ n: Int) -> TraceSummary {
        TraceSummary(traceID: traceID(n), rootService: "checkout-api", route: "GET /\(n)",
                     startNs: Self.base + Int64(n) * 1_000_000_000, durationNs: 1_000_000, spanCount: 1)
    }
}
