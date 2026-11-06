import Foundation
import GRDB
import Testing
@testable import MagnifeKit

/// S-036: `compare_traces`, on a store with the compare set written the way
/// the helper writes it: the fast trace, a 100 ms one, and the slow one.
struct CompareToolTests {
    static let base: Int64 = 1_800_000_000_000_000_000
    static let ms: Int64 = 1_000_000
    static let fast = traceID(11), middle = traceID(12), slow = traceID(13), other = traceID(14)

    func makeTools() throws -> (TempDir, MagnifeTools) {
        let dir = try TempDir("mcp-compare")
        let url = dir.file("store.sqlite")
        let writer = try makeWriter(at: url)
        try writer.write { db in
            try Self.insert(db, id: Self.fast, spans: CompareFixture.fast, at: 0, seq: 1)
            try Self.insert(db, id: Self.middle, spans: CompareFixture.trace(total: 100, orders: 60, selectOrders: 40, itemsAt: 54,
                                                                             items: 2, slow: false), at: 1_000, seq: 2)
            try Self.insert(db, id: Self.slow, spans: CompareFixture.slow, at: 2_000, seq: 3)
            try insertTrace(db, id: Self.other, service: "batch", route: "nightly", startNs: Self.base + 3_000 * Self.ms, seq: 4)
        }
        let tools = MagnifeTools(store: StoreConnection(url: url), timeZone: TimeZone(identifier: "UTC")!,
                                 now: { Date(nanoseconds: Self.base + 60_000 * Self.ms) })
        return (dir, tools)
    }

    /// The fixture's spans under trace `id`: the root is insertTrace's, the rest keep their parents.
    static func insert(_ db: Database, id: String, spans: [ComparisonSpan], at offsetMs: Int64, seq: Int64) throws {
        let start = base + offsetMs * ms
        let fixtureStart = spans.map(\.span.startNs).min() ?? 0
        let root = spans.first { $0.span.parentSpanID == nil }!
        try insertTrace(db, id: id, service: "web", route: "GET /account/orders", startNs: start,
                        durationNs: root.span.durationNs, seq: seq, spanCount: spans.count)
        let rootID = String(id.prefix(16))
        func mapped(_ spanID: String) -> String { spanID == root.span.spanID ? rootID : String(id.suffix(4)) + String(spanID.suffix(12)) }
        for item in spans where item.span.parentSpanID != nil {
            let span = item.span
            try insertDetectorSpan(db, trace: id, span: mapped(span.spanID), parent: span.parentSpanID.map(mapped), name: span.name,
                                   kind: span.kind.rawValue, start: start + span.startNs - fixtureStart, duration: span.durationNs,
                                   status: span.status.rawValue, system: item.dbStatement == nil ? nil : "postgresql",
                                   statement: item.dbStatement, method: span.httpMethod, route: span.httpRoute, url: item.httpURL,
                                   service: span.serviceName)
        }
    }

    func call(_ tools: MagnifeTools, _ arguments: [String: JSONValue]) async throws -> MCPToolResult {
        try await tools.call("compare_traces", arguments: arguments)
    }

    @Test func listedReadOnlyAfterTheSixOthers() throws {
        let (dir, tools) = try makeTools()
        defer { dir.remove() }
        #expect(tools.tools.map(\.name).last == "compare_traces")
        let tool = try #require(tools.tools.last)
        #expect(tool.listed["annotations"]?["readOnlyHint"] == true)
        #expect(tool.inputSchema["required"] == ["trace_id"])
    }

    @Test func comparesInTheWindowsWords() async throws {
        let (dir, tools) = try makeTools()
        defer { dir.remove() }
        let result = try await call(tools, ["trace_id": .string(Self.slow), "baseline_trace_id": .string(Self.fast)])
        #expect(!result.isError)
        let text = result.text
        let comparison = CompareFixture.comparison
        #expect(text.contains("A: \(Self.fast) · web · GET /account/orders · 64 ms · 10 spans"))
        #expect(text.contains("B: \(Self.slow) · web · GET /account/orders · 420 ms · 16 spans"))
        #expect(text.contains(comparison.totalSentence))
        #expect(text.contains("- Error · Unset → Error · GET /v1/recommendations · checkout-api: "))
        #expect(text.contains("- Slower · +300 ms · SELECT orders · orders: SELECT orders took 320 ms in B and 20 ms in A; 300 ms of it is its own time, not its children's. (span A "))
        #expect(text.contains("- Repeated · 2 → 8 runs · +30 ms · SELECT order_items · orders: "))
        #expect(text.contains("- New · GET /v1/inventory · orders: "))
        #expect(text.contains("- Missing · HGET · checkout-api: "))
        #expect(text.contains("- orders · 2 → 8 runs · 10 ms → 40 ms · SELECT * FROM order_items WHERE order_id = ?"))
        #expect(text.contains("    - SELECT orders · orders · 20 ms → 320 ms · +300 ms"), "the tree, indented")
        #expect(!text.contains("A is the fastest"))
        // Every difference line in the window's words.
        for difference in comparison.differences { #expect(text.contains(comparison.line(difference))) }
    }

    @Test func picksTheFastestSameRouteTraceAsBaseline() async throws {
        let (dir, tools) = try makeTools()
        defer { dir.remove() }
        let text = try await call(tools, ["trace_id": .string(Self.slow)]).text
        #expect(text.contains("A: \(Self.fast) · "), "64 ms beats 100 ms")
        #expect(text.contains("A is the fastest of the 2 newest other GET /account/orders traces of web; give baseline_trace_id for another."))
    }

    @Test func saysWhatToSendInstead() async throws {
        let (dir, tools) = try makeTools()
        defer { dir.remove() }
        let alone = try await call(tools, ["trace_id": .string(Self.other)])
        #expect(alone.isError && alone.text.contains("so there is no baseline to pick. Give baseline_trace_id"))
        let same = try await call(tools, ["trace_id": .string(Self.slow), "baseline_trace_id": .string(Self.slow)])
        #expect(same.isError && same.text.contains("are the same trace"))
        let unknown = try await call(tools, ["trace_id": "ffffffffffffffffffffffffffffffff"])
        #expect(unknown.isError && unknown.text.hasPrefix("No stored trace"))
        // Wrong arguments are MCPInvalidParams, which the server answers as an isError result (MCPServerTests).
        await #expect(throws: MCPInvalidParams.self) { try await call(tools, ["trace_id": .string(Self.slow), "max_rows": 0]) }
        await #expect(throws: MCPInvalidParams.self) { try await call(tools, [:]) }
    }

    @Test func treeIsBounded() async throws {
        let (dir, tools) = try makeTools()
        defer { dir.remove() }
        let text = try await call(tools, ["trace_id": .string(Self.slow), "baseline_trace_id": .string(Self.fast), "max_rows": 2]).text
        #expect(text.contains("more rows not shown (max_rows is 2)."))
    }
}
