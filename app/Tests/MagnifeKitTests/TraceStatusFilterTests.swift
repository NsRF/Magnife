import Foundation
import GRDB
import Testing
@testable import MagnifeKit

/// The status chips (S-018): Error, OK and Unset against the trace's root
/// and child span statuses, as docs/schema.sql documents `traces.status`
/// and docs/ux.md's chip tooltips say. The helper's side of the rule is
/// pinned by `TestRouteAndStatusRules` (Go); here the rows are written by it.
@Suite("Status filter (S-018)", .serialized)
struct TraceStatusFilterTests {
    /// (root status or nil before the root arrives, child statuses).
    static let traces: [(root: Int?, children: [Int])] = [
        (1, [2]),     // 1: OK root, an Error child
        (1, [1, 0]),  // 2: OK root, no Error span
        (0, [1]),     // 3: Unset root with an OK child
        (nil, [1]),   // 4: the root not received yet
        (2, []),      // 5: Error root
        (0, [0, 2]),  // 6: Unset root, an Error grandchild
    ]

    /// docs/schema.sql: 2 if any span is Error; else the root's status; before the root arrives, 0.
    static func documentedStatus(root: Int?, children: [Int]) -> Int {
        if root == 2 || children.contains(2) { return 2 }
        return root ?? 0
    }

    private func makeStore() async throws -> (TempDir, TelemetryReader) {
        let dir = try TempDir("status-filter")
        let writer = try makeWriter(at: dir.file("magnife.sqlite"))
        try await writer.write { db in
            for (n, trace) in Self.traces.enumerated() {
                let id = traceID(n + 1)
                let start: Int64 = 1_730_000_000_000_000_000 + Int64(n) * 1_000_000
                try insertTrace(db, id: id, startNs: start,
                                status: Self.documentedStatus(root: trace.root, children: trace.children), seq: Int64(n + 1),
                                spanCount: trace.children.count + 1)
                for (index, status) in trace.children.enumerated() {
                    try insertSpan(db, trace: id, span: String(format: "%012x%04x", n, index), parent: String(id.prefix(16)),
                                   name: "child", service: "checkout-api", startNs: start + 1, durationNs: 1, status: status)
                }
                if let root = trace.root {
                    try db.execute(sql: "UPDATE spans SET status_code = ? WHERE trace_id = ? AND parent_span_id IS NULL",
                                   arguments: [root, id])
                } else {
                    try db.execute(sql: "DELETE FROM spans WHERE trace_id = ? AND parent_span_id IS NULL", arguments: [id])
                    try db.execute(sql: "UPDATE traces SET root_span_id = NULL WHERE trace_id = ?", arguments: [id])
                }
            }
        }
        return (dir, try await TelemetryReader.open(at: dir.file("magnife.sqlite")))
    }

    static let chips: [(Set<SpanStatus>, [Int])] = [
        ([.error], [6, 5, 1]),
        ([.ok], [2]),
        ([.unset], [4, 3]),
        ([.error, .ok], [6, 5, 2, 1]),
        ([.ok, .unset], [4, 3, 2]),
        ([.error, .ok, .unset], [6, 5, 4, 3, 2, 1]),
        ([], [6, 5, 4, 3, 2, 1]),
    ]

    @Test("Error, OK and Unset keep the traces their tooltips describe", arguments: chips)
    func chipMatches(_ statuses: Set<SpanStatus>, expected: [Int]) async throws {
        let (dir, reader) = try await makeStore()
        defer { dir.remove() }
        let page = try await reader.tracePage(filter: TraceFilter(statuses: statuses))
        let numbers = page.traces.map { trace in (1...Self.traces.count).first { traceID($0) == trace.traceID } ?? 0 }
        #expect(numbers == expected)
        #expect(page.traceCount == expected.count)
        #expect(page.scopeCount == Self.traces.count)
    }

    @Test("a status chip and the status: token are the same filter")
    func tokens() {
        #expect(TraceQuery("status:error").filter == TraceFilter().clicking(.error, adding: false))
        #expect(TraceQuery("status:ok status:unset").filter
                == TraceFilter().clicking(.ok, adding: false).clicking(.unset, adding: true))
    }

    @Test("a click shows only that status; ⌘-click adds or removes one; the only chip on turns off")
    func clicking() {
        let error = TraceFilter().clicking(.error, adding: false)
        #expect(error.statuses == [.error] && error.narrowsScope)
        #expect(error.clicking(.ok, adding: false).statuses == [.ok])
        #expect(error.clicking(.ok, adding: true).statuses == [.error, .ok])
        #expect(error.clicking(.ok, adding: true).clicking(.error, adding: true).statuses == [.ok])
        #expect(error.clicking(.error, adding: false).statuses.isEmpty)
        #expect(error.clicking(.error, adding: true).statuses.isEmpty)
        #expect(!TraceFilter(service: "web").narrowsScope && TraceFilter(service: "web").isActive)
    }

    @Test("chip words and tooltips")
    func words() {
        #expect(SpanStatus.chipOrder.map(\.title) == ["Error", "OK", "Unset"])
        #expect(SpanStatus.error.chipHelp == "Show traces with at least one Error span")
        #expect(SpanStatus.ok.chipHelp == "Show traces with no Error span and an OK root span")
        #expect(SpanStatus.unset.chipHelp == "Show traces with no Error span and an Unset or missing root span")
        #expect(TraceList.subtitle(shown: 312, of: 1_204) == "312 of 1,204 traces")
        #expect(TraceList.subtitle(shown: 1, of: 1, isPaused: true) == "Paused · 1 of 1 trace")
    }
}
