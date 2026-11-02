import Foundation
import GRDB
import Testing
@testable import MagnifeKit

/// Retention (S-015, S-016): the default, the words, and what pruning does
/// to lists that hold still. The deleting itself is the helper's, tested in
/// Go (TestPruneInChunks, TestWriterSetRetentionPrunes,
/// TestWriterPrunesOnItsOwnWithAShortRetention) and end to end in the self-test.
@Suite("Retention (S-015)", .serialized)
struct RetentionTests {
    static let base: Int64 = 1_730_000_000_000_000_000

    private func defaults() -> UserDefaults {
        let name = "magnife.retention.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("first launch keeps 24 hours, and the helper is told so")
    func firstLaunch() throws {
        let fresh = defaults()
        #expect(Retention.stored(in: fresh, environment: [:]) == 86_400)
        #expect(HelperConfiguration.defaultRetention == 86_400)
        let configuration = HelperConfiguration(executableURL: URL(fileURLWithPath: "/x"),
                                                databaseURL: URL(fileURLWithPath: "/tmp/m.sqlite"))
        let flag = try #require(configuration.arguments.firstIndex(of: "--retention"))
        #expect(configuration.arguments[flag + 1] == "86400")
    }

    @Test("a stored choice is kept; anything else reads as 24 hours")
    func storedChoice() {
        let stored = defaults()
        stored.set(3_600, forKey: Retention.defaultsKey)
        #expect(Retention.stored(in: stored, environment: [:]) == 3_600)
        for bad: Any in [0, -5, 1_234, "1 hour"] {
            stored.set(bad, forKey: Retention.defaultsKey)
            #expect(Retention.stored(in: stored, environment: [:]) == 86_400)
        }
    }

    @Test("APP_RETENTION_SECONDS overrides the stored choice with any positive number of seconds")
    func testHook() {
        let stored = defaults()
        stored.set(604_800, forKey: Retention.defaultsKey)
        #expect(Retention.stored(in: stored, environment: ["APP_RETENTION_SECONDS": "3"]) == 3)
        #expect(Retention.stored(in: stored, environment: ["APP_RETENTION_SECONDS": "0"]) == 604_800)
        #expect(Retention.stored(in: stored, environment: ["APP_RETENTION_SECONDS": "soon"]) == 604_800)
        #expect(Retention.menuChoices(including: 3) == [3, 3_600, 21_600, 86_400, 259_200, 604_800])
        #expect(Retention.menuChoices(including: 86_400) == Retention.choices)
    }

    @Test("the choices read as docs/ux.md says",
          arguments: [(3_600, "1 hour"), (21_600, "6 hours"), (86_400, "24 hours"), (259_200, "3 days"),
                      (604_800, "7 days"), (90, "90 seconds"), (120, "2 minutes"), (1, "1 second")])
    func titles(seconds: Int, expected: String) {
        #expect(Retention.title(seconds: seconds) == expected)
    }

    @Test("the pruned trace's state names the period kept")
    func keepsText() {
        #expect(Retention.keepsText(seconds: 86_400) == "Magnife keeps traces and logs for 24 hours.")
        #expect(Retention.noLongerStoredTitle == "Trace No Longer Stored")
    }

    // MARK: Held lists

    @Test("a held read names the shown traces that were pruned, and only those")
    func heldTracesGone() async throws {
        let dir = try TempDir("retention-traces")
        defer { dir.remove() }
        let writer = try makeWriter(at: dir.file("magnife.sqlite"))
        try await writer.write { db in
            for n in 1...4 { try insertTrace(db, id: traceID(n), startNs: Self.base + Int64(n), seq: Int64(n)) }
        }
        let reader = try await TelemetryReader.open(at: dir.file("magnife.sqlite"))
        // The helper prunes traces 1 and 2 with their spans (docs/schema.sql, writer rules).
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM spans WHERE trace_id IN (?, ?)", arguments: [traceID(1), traceID(2)])
            try db.execute(sql: "DELETE FROM traces WHERE trace_id IN (?, ?)", arguments: [traceID(1), traceID(2)])
        }
        let shown = (1...4).reversed().map { traceID($0) }
        let held = try await reader.heldTraces(base: 4, applied: 4, shown: shown)
        #expect(Set(held.removed) == [traceID(1), traceID(2)])
        #expect(try await reader.heldTraces(base: 4, applied: 4, shown: [traceID(4)]).removed.isEmpty)
        #expect(try await reader.heldTraces(base: 4, applied: 4, shown: []).removed.isEmpty)
    }

    @Test("a held list loses pruned rows; a paused one keeps them")
    func heldTraceState() throws {
        func trace(_ n: Int) -> TraceSummary {
            TraceSummary(traceID: traceID(n), rootService: "checkout-api", route: "GET /\(n)",
                         startNs: Self.base + Int64(n), durationNs: 1, spanCount: 1)
        }
        let rows = (1...4).reversed().map { trace($0) }
        let held = HeldTraces(updated: [], removed: [traceID(1), traceID(2)], newCount: 0, services: [], lastSeq: 4)
        let scrolled = TraceListState(traces: rows, baseSeq: 4, appliedSeq: 4, isHeld: true, traceCount: 4)
        let next = try #require(scrolled.applying(.held(held, scope: nil, base: 4)))
        #expect(next.traces.map(\.traceID) == [traceID(4), traceID(3)])
        #expect(next.traceCount == 2)
        let paused = TraceListState(traces: rows, baseSeq: 4, appliedSeq: 4, traceCount: 4, pausedSeq: 4)
        let still = try #require(paused.applying(.held(held, scope: nil, base: 4)))
        #expect(still.traces == rows && still.traceCount == 4)
    }

    @Test("held logs: pruned rows are named and leave the list unless it is paused")
    func heldLogs() async throws {
        let dir = try TempDir("retention-logs")
        defer { dir.remove() }
        let writer = try makeWriter(at: dir.file("magnife.sqlite"))
        try await writer.write { db in
            for n in 1...5 { try insertLog(db, timeNs: Self.base + Int64(n), severity: 9, service: "web", body: "log \(n)") }
        }
        let reader = try await TelemetryReader.open(at: dir.file("magnife.sqlite"))
        let page = try await reader.logPage()
        try await writer.write { db in try db.execute(sql: "DELETE FROM logs WHERE id <= 2") }
        let held = try await reader.heldLogs(base: page.lastID, shown: page.items.map(\.id))
        #expect(held.removed.sorted() == [1, 2])

        var state = try #require(LogListState().applying(.page(page, filter: LogFilter())))
        state.isHeld = true
        let next = try #require(state.applying(.held(held, filter: LogFilter(), base: state.baseID)))
        #expect(next.items.map(\.id) == [5, 4, 3] && next.logCount == 3 && next.scopeCount == 3)
        let paused = state.paused(latestID: page.lastID)
        #expect(paused.applying(.held(held, filter: LogFilter(), base: state.baseID))?.items.count == 5)
    }

    @Test("the retention the helper applied reads from meta")
    func metaRetention() async throws {
        let dir = try TempDir("retention-meta")
        defer { dir.remove() }
        let writer = try makeWriter(at: dir.file("magnife.sqlite"))
        let reader = try await TelemetryReader.open(at: dir.file("magnife.sqlite"))
        #expect(try await reader.retentionSeconds() == nil)
        try await writer.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO meta (key, value) VALUES ('retention_s', '3600')")
        }
        #expect(try await reader.retentionSeconds() == 3_600)
    }

    // MARK: Changing it (S-016)

    @Test("a shorter period asks first; a longer one or the same applies at once")
    func asksFirst() {
        #expect(Retention.asksFirst(from: 86_400, to: 3_600))
        #expect(!Retention.asksFirst(from: 86_400, to: 604_800))
        #expect(!Retention.asksFirst(from: 86_400, to: 86_400))
    }

    @Test("the dialog's words", arguments: [(3_600, "Delete Data Older Than 1 Hour?",
                                             "Traces and logs older than 1 hour are deleted now. You can't undo this action."),
                                            (21_600, "Delete Data Older Than 6 Hours?",
                                             "Traces and logs older than 6 hours are deleted now. You can't undo this action."),
                                            (259_200, "Delete Data Older Than 3 Days?",
                                             "Traces and logs older than 3 days are deleted now. You can't undo this action.")])
    func dialog(seconds: Int, title: String, message: String) {
        #expect(Retention.confirmTitle(seconds: seconds) == title)
        #expect(Retention.confirmMessage(seconds: seconds) == message)
        #expect(Retention.label == "Keep traces and logs for")
        #expect(Retention.footnote == "Older traces and logs are deleted automatically.")
    }

    @Test("database size is the database plus its WAL, in Finder's units")
    func databaseSize() throws {
        let dir = try TempDir("retention-size")
        defer { dir.remove() }
        let db = dir.file("magnife.sqlite")
        #expect(DatabaseSize.bytes(of: db) == 0)
        try Data(count: 120_000).write(to: db)
        try Data(count: 62_000).write(to: URL(fileURLWithPath: db.path + "-wal"))
        try Data(count: 32_768).write(to: URL(fileURLWithPath: db.path + "-shm"))
        #expect(DatabaseSize.bytes(of: db) == 182_000)
        #expect(DatabaseSize.text(182_000_000) == "182 MB")
        #expect(DatabaseSize.spoken(182_000_000) == "182 megabytes")
        #expect(DatabaseSize.text(0) == "0 bytes")
        #expect(DatabaseSize.spoken(4_000) == "4 kilobytes")
        // "1.5 GB" or "1,5 GB", as the locale writes it: the number is the same in both.
        #expect(DatabaseSize.spoken(1_500_000_000)
                == DatabaseSize.text(1_500_000_000).replacingOccurrences(of: "GB", with: "gigabytes"))
    }
}
