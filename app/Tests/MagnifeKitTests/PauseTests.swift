import Foundation
import GRDB
import Testing
@testable import MagnifeKit

/// Pause and Resume (S-010): a paused list never changes, counts the traces
/// created after the seq it paused at, and a scope change reads up to it.
@Suite("Pause (S-010)", .serialized)
struct PauseTests {
    static let base: Int64 = 1_730_000_000_000_000_000

    private func trace(_ n: Int) -> TraceSummary {
        TraceSummary(traceID: traceID(n), rootService: "checkout-api", route: "GET /\(n)",
                     startNs: Self.base + Int64(n) * 1_000_000_000, durationNs: 1_000_000, spanCount: 1)
    }

    /// Traces 1...6, one per batch (seq n); traces 2 and 5 are from web.
    private func makeStore() async throws -> (TempDir, DatabaseQueue, TelemetryReader) {
        let dir = try TempDir("pause")
        let writer = try makeWriter(at: dir.file("magnife.sqlite"))
        try await writer.write { db in
            for n in 1...6 {
                try insertTrace(db, id: traceID(n), service: n == 2 || n == 5 ? "web" : "checkout-api",
                                route: "GET /\(n)", startNs: Self.base + Int64(n) * 1_000_000_000, seq: Int64(n))
            }
        }
        return (dir, writer, try await TelemetryReader.open(at: dir.file("magnife.sqlite")))
    }

    @Test("pausing holds at the seq the rows were read at, even at the top of the list")
    func pause() {
        let state = TraceListState(traces: [trace(2), trace(1)], baseSeq: 5, appliedSeq: 7)
        #expect(!state.readsHeld)
        let paused = state.paused()
        #expect(paused.pausedSeq == 5 && paused.isPaused && paused.readsHeld)
        // Pausing again keeps the first pause point.
        var later = paused
        later.baseSeq = 9
        #expect(later.paused().pausedSeq == 5)
    }

    @Test("paused, the rows never change, not even in place; only the count moves")
    func heldWhilePaused() throws {
        let state = TraceListState(traces: [trace(2), trace(1)], baseSeq: 5, appliedSeq: 5).paused()
        var changed = trace(1)
        changed.spanCount = 9
        let held = HeldTraces(updated: [changed], newCount: 4, services: [], lastSeq: 8)
        let next = try #require(state.applying(.held(held, scope: nil, base: 5)))
        #expect(next.traces == state.traces)
        #expect(next.newCount == 4 && next.appliedSeq == 8 && next.baseSeq == 5 && next.pausedSeq == 5)
        // A first page read before the pause would insert rows: dropped.
        #expect(state.applying(.page(TracePage(traces: [trace(3)], services: [], lastSeq: 8), scope: nil)) == nil)
    }

    @Test("paused with no rows (a scope change), a page read up to the pause point fills the list")
    func scopeWhilePaused() throws {
        let state = TraceListState(scope: "web", baseSeq: 5, appliedSeq: 7, pausedSeq: 5)
        #expect(!state.readsHeld)
        // A page read without the pause point is dropped.
        #expect(state.applying(.page(TracePage(traces: [trace(7)], services: [], lastSeq: 8), scope: "web")) == nil)
        let page = TracePage(traces: [trace(5), trace(2)], services: [], lastSeq: 8, traceCount: 2, upTo: 5, newCount: 1)
        let next = try #require(state.applying(.page(page, scope: "web")))
        #expect(next.traces.map(\.traceID) == [traceID(5), traceID(2)])
        #expect(next.baseSeq == 5 && next.appliedSeq == 8 && next.newCount == 1 && next.traceCount == 2)
        #expect(next.pausedSeq == 5 && next.readsHeld)
    }

    @Test("after Resume a page applies again, and a Resume read of more than a page may have more")
    func resume() throws {
        var state = TraceListState(traces: [trace(2), trace(1)], baseSeq: 5, appliedSeq: 8, newCount: 3).paused()
        state.pausedSeq = nil
        let rows = (1...(TraceList.pageSize + 3)).reversed().map { trace($0) }
        let next = try #require(state.applying(.page(TracePage(traces: rows, services: [], lastSeq: 9), scope: nil)))
        #expect(next.traces.count == TraceList.pageSize + 3 && next.hasMore)
        #expect(next.baseSeq == 9 && next.newCount == 0 && !next.isPaused)
    }

    @Test("the reader reads a scope as of the pause point, and counts what was created after it")
    func reader() async throws {
        let (dir, writer, reader) = try await makeStore()
        defer { dir.remove() }
        _ = writer
        let all = try await reader.tracePage(upTo: 4)
        #expect(all.traces.map(\.traceID) == [traceID(4), traceID(3), traceID(2), traceID(1)])
        #expect(all.traceCount == 4 && all.newCount == 2 && all.upTo == 4 && all.lastSeq == 6)
        let web = try await reader.tracePage(service: "web", upTo: 4)
        #expect(web.traces.map(\.traceID) == [traceID(2)] && web.traceCount == 1 && web.newCount == 1)
        let next = try await reader.latestTraces(after: all.traces[1].cursor, upTo: 4)
        #expect(next.map(\.traceID) == [traceID(2), traceID(1)])
        // Not paused: no count of new traces.
        #expect(try await reader.tracePage().newCount == 0)
    }

    @Test("the bar's words", arguments: [
        (0, "Paused. Magnife is still receiving."),
        (1, "Paused. 1 new trace. Magnife is still receiving."),
        (12, "Paused. 12 new traces. Magnife is still receiving."),
    ])
    func bar(count: Int, expected: String) {
        #expect(TraceList.pausedText(newCount: count) == expected)
    }

    @Test("the button, its tooltip and the subtitle")
    func words() {
        #expect(TraceList.pauseTitle(isPaused: false) == "Pause")
        #expect(TraceList.pauseTitle(isPaused: true) == "Resume")
        #expect(TraceList.pauseHelp(isPaused: false) == "Hold the list still while new traces keep arriving (⌃⌘P)")
        #expect(TraceList.pauseHelp(isPaused: true) == "Add the traces that arrived while paused (⌃⌘P)")
        #expect(TraceList.subtitle(traceCount: 5, isPaused: true) == "Paused · 5 traces")
        #expect(TraceList.subtitle(traceCount: 1) == "1 trace")
    }
}
