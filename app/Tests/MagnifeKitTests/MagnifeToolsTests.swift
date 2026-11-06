import Foundation
import GRDB
import Testing
@testable import MagnifeKit

/// S-034 and S-036: the seven tools on a store written the way the helper writes it (docs/mcp.md).
struct MagnifeToolsTests {
    static let base: Int64 = 1_800_000_000_000_000_000
    static let ms: Int64 = 1_000_000

    /// Trace 1: a slow query. Trace 2: POST /pay returned 500, with logs. Trace 3: an N+1 (6 runs).
    /// Trace 4: 30 spans, no finding.
    func makeTools() throws -> (TempDir, MagnifeTools) {
        let dir = try TempDir("mcp")
        let url = dir.file("store.sqlite")
        let writer = try makeWriter(at: url)
        try writer.write { db in
            let t1 = traceID(1), t2 = traceID(2), t3 = traceID(3), t4 = traceID(4)
            try insertTrace(db, id: t1, service: "web", route: "GET /reports", startNs: Self.base, durationNs: 300 * Self.ms, seq: 1, spanCount: 2)
            try insertDetectorSpan(db, trace: t1, span: "1000000000000001", parent: String(t1.prefix(16)), name: "SELECT sales",
                                   start: Self.base + 10 * Self.ms, duration: 250 * Self.ms, system: "postgresql",
                                   statement: "SELECT * FROM sales WHERE day > now() - interval '1 year'", service: "web")

            try insertTrace(db, id: t2, service: "web", route: "POST /pay", startNs: Self.base + 1_000 * Self.ms,
                            durationNs: 60 * Self.ms, status: 2, seq: 2, spanCount: 1)
            try insertDetectorSpan(db, trace: t2, span: String(t2.prefix(16)), name: "POST /pay", kind: 2,
                                   start: Self.base + 1_000 * Self.ms, duration: 60 * Self.ms, status: 2,
                                   statusMessage: "duplicate key", method: "POST", code: 500, route: "/pay", service: "web")
            try insertLog(db, timeNs: Self.base + 1_010 * Self.ms, severity: 17, service: "web", body: "payment failed",
                          trace: t2, span: String(t2.prefix(16)))
            try insertLog(db, timeNs: Self.base + 1_005 * Self.ms, severity: 9, service: "web", body: "paying\nline two",
                          trace: t2, span: String(t2.prefix(16)))

            try insertTrace(db, id: t3, service: "orders", route: "GET /orders", startNs: Self.base + 2_000 * Self.ms,
                            durationNs: 50 * Self.ms, seq: 3, spanCount: 7)
            for n in 1...6 {
                try insertDetectorSpan(db, trace: t3, span: String(format: "30000000000000%02d", n), parent: String(t3.prefix(16)),
                                       name: "SELECT items", start: Self.base + 2_000 * Self.ms + Int64(n) * Self.ms,
                                       duration: 2 * Self.ms, system: "postgresql",
                                       statement: "SELECT * FROM items WHERE id = \(n)", service: "orders")
            }

            try insertTrace(db, id: t4, service: "batch", route: "nightly", startNs: Self.base + 3_000 * Self.ms,
                            durationNs: 40 * Self.ms, seq: 4, spanCount: 31)
            for n in 1...30 {
                try insertSpan(db, trace: t4, span: String(format: "40000000000000%02d", n), parent: String(t4.prefix(16)),
                               name: "step \(n)", service: "batch", startNs: Self.base + 3_000 * Self.ms + Int64(n), durationNs: Self.ms)
            }
            try insertLog(db, timeNs: Self.base + 3_001 * Self.ms, severity: 13, service: "batch", body: "slow disk")
        }
        let tools = MagnifeTools(store: StoreConnection(url: url), timeZone: TimeZone(identifier: "UTC")!,
                                 now: { Date(nanoseconds: Self.base + 60_000 * Self.ms) })
        return (dir, tools)
    }

    func text(_ tools: MagnifeTools, _ name: String, _ arguments: [String: JSONValue] = [:]) async throws -> MCPToolResult {
        try await tools.call(name, arguments: arguments)
    }

    @Test func everyToolIsListedReadOnly() throws {
        let (dir, tools) = try makeTools()
        defer { dir.remove() }
        #expect(tools.tools.map(\.name) == ["list_services", "list_traces", "get_trace", "get_span", "search_logs", "find_problems",
                                            "compare_traces"])
        #expect(tools.tools.allSatisfy { $0.listed["annotations"]?["readOnlyHint"] == true })
        #expect(tools.tools.allSatisfy { $0.inputSchema["type"] == "object" })
    }

    @Test func noStoreYetIsOneSentenceTheAgentReads() async throws {
        let tools = MagnifeTools(store: StoreConnection(url: URL(fileURLWithPath: "/tmp/magnife-tests/none-\(UUID()).sqlite")))
        let result = try await tools.call("list_traces", arguments: [:])
        #expect(result.isError)
        #expect(result.text.hasPrefix("Magnife has not stored any telemetry yet."))
    }

    @Test func listServicesAndTraces() async throws {
        let (dir, tools) = try makeTools()
        defer { dir.remove() }
        let services = try await text(tools, "list_services")
        #expect(services.text.contains("3 services, 4 traces stored"))
        #expect(services.text.contains("- web: last seen 2027-01-15"))

        let all = try await text(tools, "list_traces")
        #expect(all.text.hasPrefix("Newest traces, newest first: 4 shown."))
        let lines = all.text.split(separator: "\n").dropFirst()
        #expect(lines.first?.hasPrefix("- \(traceID(4)) · batch · nightly") == true, "newest first")
        #expect(all.text.contains("\(traceID(1)) · web · GET /reports · 300 ms · 2 spans · Unset · findings: Slow SQL ×1"))
        #expect(all.text.contains("(59 s ago)"))

        let failed = try await text(tools, "list_traces", ["query": "status:error"])
        #expect(failed.text.hasPrefix("Traces where status is Error, newest first: 1 shown."))
        #expect(failed.text.contains(traceID(2)) && !failed.text.contains(traceID(1)))
        #expect(failed.text.contains("findings: HTTP Error ×1"))

        let limited = try await text(tools, "list_traces", ["limit": 2])
        #expect(limited.text.hasPrefix("Newest traces, newest first: 2 shown of 4."))
        let recent = try await text(tools, "list_traces", ["since_minutes": 1])
        #expect(recent.text.contains("4 shown"))
    }

    @Test func getTraceShowsTreeFindingsAndLogs() async throws {
        let (dir, tools) = try makeTools()
        defer { dir.remove() }
        let result = try await text(tools, "get_trace", ["trace_id": .string(traceID(2))])
        #expect(!result.isError)
        #expect(result.text.hasPrefix("Trace \(traceID(2))\nRoot service: web · Route: POST /pay · Duration: 60 ms"))
        #expect(result.text.contains("Logs: 2"))
        #expect(result.text.contains("- HTTP Error: POST /pay in web returned 500 after 60 ms."))
        #expect(result.text.contains("- POST /pay · web · Server · 60 ms · +0 ms · Error: duplicate key · finding: HTTP Error · span \(traceID(2).prefix(16))"))

        let slow = try await text(tools, "get_trace", ["trace_id": .string(traceID(1).uppercased())])
        #expect(slow.text.contains("  Statement (postgresql): SELECT * FROM sales"))
        #expect(slow.text.contains("  - SELECT sales · web · Client · 250 ms · +10 ms · finding: Slow SQL · span 1000000000000001"))
    }

    @Test func getTraceCountsSpansItLeavesOut() async throws {
        let (dir, tools) = try makeTools()
        defer { dir.remove() }
        let result = try await text(tools, "get_trace", ["trace_id": .string(traceID(4)), "max_spans": 10])
        #expect(result.text.contains("Spans (31)"))
        #expect(result.text.contains("… 21 more spans not shown (max_spans is 10)."))
        #expect(result.text.contains("Findings: none"))
    }

    @Test func traceIDsByPrefixAndUnknownOnes() async throws {
        let (dir, tools) = try makeTools()
        defer { dir.remove() }
        let unique = try await text(tools, "get_trace", ["trace_id": .string(String(traceID(3).suffix(32)))])
        #expect(unique.text.hasPrefix("Trace \(traceID(3))"))
        let ambiguous = try await text(tools, "get_trace", ["trace_id": .string(String(traceID(3).prefix(12)))])
        #expect(ambiguous.isError && ambiguous.text.hasPrefix("Several traces start with"))
        let unknown = try await text(tools, "get_trace", ["trace_id": "0123456789abcdef"])
        #expect(unknown.isError && unknown.text.contains("No stored trace"))
        let notHex = try await text(tools, "get_trace", ["trace_id": "checkout"])
        #expect(notHex.isError && notHex.text.contains("32 hex characters"))
        let span = try await text(tools, "get_span", ["trace_id": .string(traceID(2)), "span_id": "ffffffffffffffff"])
        #expect(span.isError && span.text.contains("has no span ffffffffffffffff"))
    }

    @Test func getSpanShowsStatusAndLogs() async throws {
        let (dir, tools) = try makeTools()
        defer { dir.remove() }
        let result = try await text(tools, "get_span", ["trace_id": .string(traceID(2)), "span_id": .string(String(traceID(2).prefix(16)))])
        #expect(result.text.contains("Name: POST /pay · Service: web · Kind: Server · Duration: 60 ms · Status: Error"))
        #expect(result.text.contains("Status message: duplicate key"))
        #expect(result.text.contains("Parent: none (a root span)"))
        #expect(result.text.contains("Logs (2), oldest first:\n- 2027-01-15 08:00:01.005 INFO web: paying ⏎ line two {k: v}"))
    }

    @Test func findProblemsUsesTheAppsWords() async throws {
        let (dir, tools) = try makeTools()
        defer { dir.remove() }
        let result = try await text(tools, "find_problems")
        #expect(result.text.hasPrefix("Looked at the 4 newest traces: 3 with findings, 0 failed without a finding."))
        // The same words the window shows for each finding (Finding.detailText, placed in its trace).
        let reader = try await tools.store.open()
        for id in [traceID(1), traceID(2), traceID(3)] {
            let read = try await reader.openTrace(traceID: id)
            let tree = await Waterfall.build(read.spans)
            let placed = try await reader.placedFindings(read.findings, in: tree, trace: read.trace, traceID: id)
            for finding in placed.findings {
                #expect(result.text.contains("- \(finding.kind.title): \(finding.detailText(in: placed.place(for: finding)))"))
            }
        }
        #expect(result.text.contains("  Repeated statement (postgresql): SELECT * FROM items WHERE id = ?"))
        let recent = try await text(tools, "find_problems", ["since_minutes": 1, "limit": 2])
        #expect(recent.text.hasPrefix("Looked at the 2 traces of the last 1 min (of the 2 newest)"))
    }

    @Test func searchLogs() async throws {
        let (dir, tools) = try makeTools()
        defer { dir.remove() }
        let errors = try await text(tools, "search_logs", ["levels": ["error"]])
        #expect(errors.text.hasPrefix("Logs where level is ERROR, newest first: 1 shown of 1."))
        #expect(errors.text.contains("ERROR web: payment failed (trace \(traceID(2)), span \(traceID(2).prefix(16)))"))
        let warnings = try await text(tools, "search_logs", ["levels": "Warning", "service": "batch"])
        #expect(warnings.text.contains("WARN batch: slow disk") && !warnings.text.contains("(trace"))
        let ofTrace = try await text(tools, "search_logs", ["trace_id": .string(traceID(2)), "limit": "1"])
        #expect(ofTrace.text.hasPrefix("Logs of trace \(traceID(2)), oldest first: 1 shown of 2."))
        #expect(ofTrace.text.contains("INFO web: paying ⏎ line two"))
        let body = try await text(tools, "search_logs", ["body_contains": "DISK"])
        #expect(body.text.contains("slow disk") && body.text.contains("body contains \"DISK\""))
    }

    @Test func wrongArgumentsSayWhy() async throws {
        let (dir, tools) = try makeTools()
        defer { dir.remove() }
        await #expect(throws: MCPInvalidParams("limit must be from 1 to 100, not 0.")) {
            try await tools.call("list_traces", arguments: ["limit": 0])
        }
        await #expect(throws: MCPInvalidParams("limit must be a whole number.")) {
            try await tools.call("list_traces", arguments: ["limit": .number(2.5)])
        }
        await #expect(throws: MCPInvalidParams("trace_id is required.")) {
            try await tools.call("get_trace", arguments: [:])
        }
        await #expect(throws: MCPInvalidParams("query must be a string.")) {
            try await tools.call("list_traces", arguments: ["query": 3])
        }
        await #expect(throws: MCPInvalidParams("loud is not a level; use trace, debug, info, warn, error or fatal.")) {
            try await tools.call("search_logs", arguments: ["levels": ["loud"]])
        }
    }

    @Test func longTextIsCutWithWhatWasLeftOut() {
        #expect(MagnifeTools.cut(String(repeating: "a", count: 2_500), 2_000) == String(repeating: "a", count: 2_000) + "… (500 more characters)")
        #expect(MagnifeTools.cut("short", 2_000) == "short")
        #expect(MagnifeTools.oneLine("a\n  b\r\nc") == "a ⏎ b ⏎ c")
        #expect(MagnifeTools.ago(30) == "30 s ago" && MagnifeTools.ago(7_200) == "2 h ago" && MagnifeTools.ago(200_000) == "2 d ago")
    }
}

/// S-034's seed-store check: `MAGNIFE_MCP_STORE=<db> swift test --filter MCPSeedStoreTests` on a store seeded
/// with `seed_store` (app/tools/seed.zsh): find_problems names the seed set's slow SQL, N+1 (8 runs) and HTTP 500.
struct MCPSeedStoreTests {
    @Test func findProblemsNamesTheSeedSet() async throws {
        guard let path = ProcessInfo.processInfo.environment["MAGNIFE_MCP_STORE"], !path.isEmpty else { return }
        let tools = MagnifeTools(store: StoreConnection(url: URL(fileURLWithPath: path)))
        let problems = try await tools.call("find_problems", arguments: [:])
        #expect(!problems.isError)
        #expect(problems.text.contains("- Slow SQL: This query took"))
        #expect(problems.text.contains("- N+1: This statement ran 8 times"))
        #expect(problems.text.contains("returned 500"))
        let failed = try await tools.call("list_traces", arguments: ["query": "status:error route:/checkout/pay"])
        let id = try #require(failed.text.split(separator: "\n").dropFirst().first?.dropFirst(2).prefix(32))
        let trace = try await tools.call("get_trace", arguments: ["trace_id": .string(String(id))])
        #expect(trace.text.contains("DbUpdateException"))
        #expect(trace.text.contains("- POST /checkout/pay · web · Server"))
    }
}

/// S-036's compare-store check: `MAGNIFE_COMPARE_STORE=<db> swift test --filter MCPCompareStoreTests` on a store
/// seeded with `seed_store <db> --compare`: compare_traces on the slow trace picks the fast one and names the query.
struct MCPCompareStoreTests {
    static let fast = "a7ee16380c64f5396e5afcb974081dda"
    static let slow = "99e87d935187cf52601204edd521fffc"

    @Test func compareTracesExplainsTheSlowOne() async throws {
        guard let path = ProcessInfo.processInfo.environment["MAGNIFE_COMPARE_STORE"], !path.isEmpty else { return }
        let tools = MagnifeTools(store: StoreConnection(url: URL(fileURLWithPath: path)))
        let result = try await tools.call("compare_traces", arguments: ["trace_id": .string(String(Self.slow.prefix(8)))])
        #expect(!result.isError)
        #expect(result.text.contains("A: \(Self.fast) · web · GET /account/orders · 64 ms · 10 spans"))
        #expect(result.text.contains("A is the only other stored GET /account/orders trace of web; give baseline_trace_id for another."))
        #expect(result.text.contains("B took 356 ms longer than A (6.6×). B has 6 more spans."))
        #expect(result.text.contains("- Slower · +300 ms · SELECT orders · orders: "))
        #expect(result.text.contains("- Repeated · 2 → 8 runs · +30 ms · SELECT order_items · orders: "))
        #expect(result.text.contains("- New · GET /v1/inventory · orders: "))
        #expect(result.text.contains("- Missing · HGET · checkout-api: "))
    }
}
