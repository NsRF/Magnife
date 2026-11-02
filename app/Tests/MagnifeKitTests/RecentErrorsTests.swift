import Foundation
import GRDB
import Testing
@testable import MagnifeKit

/// The menu bar extra's Recent Errors (S-026) and the span a failed trace opens on (S-027).
@Suite("Recent Errors", .serialized)
struct RecentErrorsTests {
    static let base: Int64 = 1_730_000_000_000_000_000

    private func trace(_ n: Int, route: String = "POST /orders", service: String = "checkout-api",
                       startNs: Int64 = base) -> TraceSummary {
        TraceSummary(traceID: traceID(n), rootService: service, route: route, startNs: startNs,
                     durationNs: 1_000, spanCount: 1, errorCount: 1, status: .error)
    }

    @Test("an item reads route · service · time")
    func itemTitle() {
        let start = Date(nanoseconds: Self.base)
        #expect(RecentErrors.itemTitle(trace(1), now: start.addingTimeInterval(125)) == "POST /orders · checkout-api · 2 min ago")
        #expect(RecentErrors.itemTitle(trace(1, route: "GET /", service: "web"), now: start) == "GET / · web · Just now")
    }

    @Test("the badge counts up to 99, then reads 99+")
    func badge() {
        #expect(RecentErrors.badge(count: 0) == nil)
        #expect(RecentErrors.badge(count: 1) == "1")
        #expect(RecentErrors.badge(count: 99) == "99")
        #expect(RecentErrors.badge(count: 100) == "99+")
    }

    @Test("VoiceOver reads the count with the name")
    func iconLabel() {
        #expect(RecentErrors.iconLabel(count: 0) == "Magnife")
        #expect(RecentErrors.iconLabel(count: 1) == "Magnife, 1 new trace with an error")
        #expect(RecentErrors.iconLabel(count: 3) == "Magnife, 3 new traces with errors")
    }

    @Test("the menu rebuilds only when what it shows changes")
    func showSame() {
        var grown = trace(1)
        grown.spanCount = 9
        grown.updatedSeq = 4
        #expect(RecentErrors.showSame([trace(1), trace(2)], [grown, trace(2)]))
        #expect(!RecentErrors.showSame([trace(1)], [trace(1, route: "GET /")]))
        #expect(!RecentErrors.showSame([trace(1)], [trace(1), trace(2)]))
        #expect(!RecentErrors.showSame([trace(1)], [trace(2)]))
    }

    @Test("the first read starts the count; opening the menu resets it")
    func counting() {
        var state = RecentErrors()
        state.apply(RecentErrorsPage(traces: [trace(1)], newCount: 0, mark: nil, lastSeq: 7))
        #expect(state.mark == 7 && state.newCount == 0 && state.traces.count == 1)
        state.apply(RecentErrorsPage(traces: [trace(2), trace(1)], newCount: 2, mark: 7, lastSeq: 9))
        #expect(state.newCount == 2 && state.lastSeq == 9)
        state.opened()
        #expect(state.mark == 9 && state.newCount == 0)
        // A read that counted from before the menu opened changes the rows, not the count.
        state.apply(RecentErrorsPage(traces: [trace(3)], newCount: 3, mark: 7, lastSeq: 10))
        #expect(state.newCount == 0 && state.traces.map(\.traceID) == [traceID(3)] && state.lastSeq == 10)
        state.apply(RecentErrorsPage(traces: [trace(3)], newCount: 1, mark: 9, lastSeq: 10))
        #expect(state.newCount == 1)
        // An older read never moves the last seq back.
        state.apply(RecentErrorsPage(traces: [], newCount: 1, mark: 9, lastSeq: 8))
        #expect(state.lastSeq == 10)
    }

    @Test("the reader reads the five newest traces with an error and counts changes after a seq")
    func reader() async throws {
        let dir = try TempDir("recent-errors")
        defer { dir.remove() }
        let url = dir.file("magnife.sqlite")
        let writer = try makeWriter(at: url)
        try await writer.write { db in
            for n in 1...8 {
                try insertTrace(db, id: traceID(n), route: "GET /\(n)", startNs: Self.base + Int64(n) * 1_000_000_000,
                                status: n == 4 ? 1 : 2, seq: Int64(n))
            }
        }
        let reader = try await TelemetryReader.open(at: url)
        let first = try await reader.recentErrors(changedAfter: nil)
        #expect(first.traces.map(\.route) == ["GET /8", "GET /7", "GET /6", "GET /5", "GET /3"])
        #expect(first.newCount == 0 && first.mark == nil && first.lastSeq == 8)
        let counted = try await reader.recentErrors(changedAfter: 5)
        #expect(counted.newCount == 3 && counted.mark == 5)
        // A trace changed again counts once; one that turned OK stops counting.
        try await writer.write { db in
            try db.execute(sql: "UPDATE traces SET updated_seq = 9 WHERE trace_id = ?", arguments: [traceID(8)])
            try db.execute(sql: "UPDATE traces SET status = 1, updated_seq = 9 WHERE trace_id = ?", arguments: [traceID(7)])
            try db.execute(sql: "UPDATE meta SET value = '9' WHERE key = 'last_seq'")
        }
        let again = try await reader.recentErrors(changedAfter: 5)
        #expect(again.newCount == 2 && again.lastSeq == 9)
        #expect(try await reader.recentErrors(limit: 2, changedAfter: 9).traces.map(\.route) == ["GET /8", "GET /6"])
        _ = writer
    }

    @Test("a failed trace opens on its earliest-starting Error span")
    func firstErrorSpan() async {
        let spans = [
            WaterfallSpan(spanID: "root", name: "POST /checkout", startNs: 0, durationNs: 100, status: .error, serviceName: "web"),
            WaterfallSpan(spanID: "a", parentSpanID: "root", name: "a", startNs: 10, durationNs: 10, serviceName: "web"),
            WaterfallSpan(spanID: "late", parentSpanID: "root", name: "late", startNs: 60, durationNs: 10, status: .error,
                          serviceName: "orders"),
            WaterfallSpan(spanID: "early", parentSpanID: "a", name: "early", startNs: 12, durationNs: 2, status: .error,
                          serviceName: "orders"),
        ]
        // The root's status is the trace's; its own Error starts first here.
        #expect(await Waterfall.build(spans).firstErrorSpanID == "root")
        var children = spans
        children[0].status = .ok
        #expect(await Waterfall.build(children).firstErrorSpanID == "early")
        children[3].startNs = 60
        // A tie goes to the first in tree order: "late" is the root's second child, "early" is under "a".
        let tied = await Waterfall.build(children)
        #expect(tied.firstErrorSpanID == tied.nodes.first { $0.span.startNs == 60 && $0.span.status == .error }?.span.spanID)
        #expect(await Waterfall.build(Array(children.prefix(2))).firstErrorSpanID == nil)
    }
}
