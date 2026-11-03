import Foundation
import GRDB
import Testing
@testable import MagnifeKit

/// The Logs view's live list (S-013): pages newest first, the count of new
/// logs while it holds still, Pause, and the Log Detail.
@Suite("Logs list (S-013)", .serialized)
struct LogListTests {
    static let base: Int64 = 1_730_000_000_000_000_000

    /// Logs 1...count, one second apart, newest last: odd ones from web, even
    /// ones from orders; every third carries trace 1 (stored, with span
    /// 4bf92f3577b34da6), every fifth trace 9 (never stored), the rest none.
    private func makeStore(count: Int = 12) async throws -> (TempDir, DatabaseQueue, TelemetryReader) {
        let dir = try TempDir("log-list")
        let writer = try makeWriter(at: dir.file("magnife.sqlite"))
        try await writer.write { db in
            try insertTrace(db, id: traceID(1), service: "web", startNs: Self.base, seq: 1)
            for n in 1...count { try Self.insert(db, n) }
        }
        return (dir, writer, try await TelemetryReader.open(at: dir.file("magnife.sqlite")))
    }

    private static func insert(_ db: Database, _ n: Int) throws {
        let trace: String? = n % 3 == 0 ? traceID(1) : n % 5 == 0 ? traceID(9) : nil
        try insertLog(db, timeNs: base + Int64(n) * 1_000_000_000, severity: n % 2 == 0 ? 9 : 17,
                      service: n % 2 == 0 ? "orders" : "web", body: "log \(n)", trace: trace,
                      span: trace == traceID(1) ? String(traceID(1).prefix(16)) : nil)
    }

    private func bodies(_ items: [LogListItem]) -> [String] { items.map(\.record.body) }

    @Test("a refresh counts only the logs above the last count, with the same filter (S-030)")
    func incrementalCounts() async throws {
        let (dir, writer, reader) = try await makeStore()
        defer { dir.remove() }
        let errors = LogFilter(levels: [.error])
        let first = try await reader.logPage(filter: errors)
        #expect(first.logCount == 6 && first.scopeCount == 12)
        try await writer.write { db in for n in 13...16 { try Self.insert(db, n) } }
        let second = try await reader.logPage(filter: errors, counted: first.countMark)
        let full = try await reader.logPage(filter: errors)
        #expect(second.logCount == full.logCount && second.scopeCount == full.scopeCount)
        #expect(second.logCount == 8 && second.scopeCount == 16)
        #expect(second.countMark == LogCountMark(filter: errors, throughID: second.lastID, count: 8, scopeCount: 16))
        // Another filter's mark is not used.
        let web = LogFilter(service: "web")
        #expect(try await reader.logPage(filter: web, counted: second.countMark).logCount == 8)
        // Paused pages keep no mark.
        #expect(try await reader.logPage(filter: errors, upTo: 10).countMark == nil)
    }

    @Test("a page is newest first by time, with the count, the newest id and the last seq")
    func page() async throws {
        let (dir, writer, reader) = try await makeStore()
        defer { dir.remove() }
        _ = writer
        let page = try await reader.logPage(limit: 3)
        #expect(bodies(page.items) == ["log 12", "log 11", "log 10"])
        #expect(page.logCount == 12)
        #expect(page.lastID == 12)
        #expect(page.lastSeq == 1)
        let next = try await reader.logItems(limit: 3, after: page.items.last!.record.cursor)
        #expect(bodies(next) == ["log 9", "log 8", "log 7"])
        #expect(LogList.pageSize == 200)
    }

    @Test("logs without a trace id are listed; Open Trace needs a stored trace")
    func traces() async throws {
        let (dir, writer, reader) = try await makeStore()
        defer { dir.remove() }
        _ = writer
        let items = try await reader.logPage().items
        let byBody = Dictionary(uniqueKeysWithValues: items.map { ($0.record.body, $0) })
        #expect(items.count == 12)
        #expect(items.filter { !$0.hasTrace }.count == 6)
        #expect(byBody["log 3"]?.canOpenTrace == true)
        #expect(byBody["log 5"]?.hasTrace == true && byBody["log 5"]?.canOpenTrace == false)
        #expect(byBody["log 1"]?.hasTrace == false && byBody["log 1"]?.canOpenTrace == false)
    }

    @Test("a service filter keeps that service's logs, and the count follows it")
    func service() async throws {
        let (dir, writer, reader) = try await makeStore()
        defer { dir.remove() }
        _ = writer
        let page = try await reader.logPage(filter: LogFilter(service: "orders"))
        #expect(bodies(page.items) == ["log 12", "log 10", "log 8", "log 6", "log 4", "log 2"])
        #expect(page.logCount == 6)
        let next = try await reader.logItems(limit: 2, after: page.items[1].record.cursor, filter: LogFilter(service: "orders"))
        #expect(bodies(next) == ["log 8", "log 6"])
    }

    @Test("held: logs stored after the base id are counted, in scope only")
    func held() async throws {
        let (dir, writer, reader) = try await makeStore()
        defer { dir.remove() }
        try await writer.write { db in for n in 13...17 { try Self.insert(db, n) } }
        #expect(try await reader.heldLogs(base: 12).newCount == 5)
        #expect(try await reader.heldLogs(base: 12, filter: LogFilter(service: "web")).newCount == 3)
        #expect(try await reader.lastLogID() == 17)
    }

    @Test("paused: the page as of the pause id, and how many came after it")
    func pausedPage() async throws {
        let (dir, writer, reader) = try await makeStore()
        defer { dir.remove() }
        _ = writer
        let page = try await reader.logPage(limit: 2, filter: LogFilter(service: "web"), upTo: 7)
        #expect(bodies(page.items) == ["log 7", "log 5"])
        #expect(page.logCount == 4)
        #expect(page.newCount == 2)
        #expect(page.upTo == 7)
        let next = try await reader.logItems(limit: 5, after: page.items[1].record.cursor, upTo: 7)
        #expect(bodies(next) == ["log 4", "log 3", "log 2", "log 1"])
    }

    @Test("the Log Detail has its resource, and the Trace section only with a trace id")
    func detail() async throws {
        let (dir, writer, reader) = try await makeStore()
        defer { dir.remove() }
        try await writer.write { db in
            try db.execute(sql: #"UPDATE resources SET attributes = '{"telemetry.sdk.language":"go","service.name":"orders","host.name":"a"}' WHERE service_name = 'orders'"#)
        }
        let withTrace = try #require(try await reader.logDetail(id: 6))
        #expect(withTrace.resourceAttributes.map(\.key) == ["service.name", "host.name", "telemetry.sdk.language"])
        #expect(withTrace.sections == [.body, .attributes, .resource, .trace])
        #expect(withTrace.item.canOpenTrace)
        let noTrace = try #require(try await reader.logDetail(id: 2))
        #expect(noTrace.sections == [.body, .attributes, .resource])
        #expect(try await reader.logDetail(id: 99) == nil)
    }

    @Test("the list reads logs_by_time or logs_by_service, never sorting the whole table")
    func plans() async throws {
        let (dir, writer, reader) = try await makeStore()
        defer { dir.remove() }
        _ = reader
        func plan(_ sql: String, _ arguments: StatementArguments) async throws -> String {
            try await writer.read { db in
                try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql, arguments: arguments)
                    .map { $0["detail"] as String }.joined(separator: " | ")
            }
        }
        let all = try await plan(TelemetrySQL.logList(cursor: false, upTo: false, filter: LogFilter()), [200])
        #expect(all.contains("logs_by_time"), "\(all)")
        let scoped = try await plan(TelemetrySQL.logList(cursor: true, upTo: true, filter: LogFilter(service: "web")),
                                    [Self.base, Self.base, 5, 9, "web", 200])
        #expect(scoped.contains("logs_by_service"), "\(scoped)")
        for text in [all, scoped] {
            #expect(!text.contains("USE TEMP B-TREE FOR ORDER BY"), "\(text)")
            #expect(text.contains("SEARCH traces USING INDEX sqlite_autoindex_traces_1") || text.contains("traces USING"),
                    "\(text)")
        }
    }

    // MARK: What a read does to the list

    private func item(_ id: Int64, trace: String? = nil) -> LogListItem {
        let row: Row = ["id": id, "time_ns": Self.base + id, "observed_ns": 0, "severity_number": 9,
                        "severity_text": "", "service_name": "web", "resource_id": 1, "scope_name": "",
                        "body": "log \(id)", "attributes": "{}", "trace_id": trace, "span_id": nil,
                        "event_name": "", "received_ns": 0]
        return LogListItem(line: LogLine(try! LogRecord(row: row), timeZone: .gmt), hasStoredTrace: trace != nil)
    }

    private func page(_ ids: [Int64], lastID: Int64? = nil, seq: Int64, upTo: Int64? = nil, newCount: Int = 0) -> LogPage {
        LogPage(items: ids.map { item($0) }, lastID: lastID ?? ids.max() ?? 0, lastSeq: seq, upTo: upTo, newCount: newCount)
    }

    @Test("at the top, a page replaces the rows and its newest id becomes the base")
    func top() {
        let state = LogListState()
        let next = state.applying(.page(page([3, 2, 1], seq: 4), filter: LogFilter()))
        #expect(next?.items.map(\.id) == [3, 2, 1])
        #expect(next?.baseID == 3 && next?.appliedSeq == 4 && next?.logCount == 3 && next?.isLoaded == true)
        #expect(next?.hasMore == false)
    }

    @Test("held still: a page is dropped and only the count of new logs moves")
    func holding() throws {
        var state = try #require(LogListState().applying(.page(page([3, 2, 1], seq: 4), filter: LogFilter())))
        state.isHeld = true
        #expect(state.readsHeld)
        #expect(state.applying(.page(page([5, 4, 3], seq: 6), filter: LogFilter())) == nil)
        let held = try #require(state.applying(.held(HeldLogs(newCount: 2, lastSeq: 6), filter: LogFilter(), base: 3)))
        #expect(held.items.map(\.id) == [3, 2, 1] && held.newCount == 2 && held.appliedSeq == 6)
        // A held read made at another base (the list went back to the top meanwhile) is dropped.
        #expect(state.applying(.held(HeldLogs(newCount: 9, lastSeq: 7), filter: LogFilter(), base: 1)) == nil)
        // Back at the top, a held read that finishes late is dropped too.
        state.isHeld = false
        #expect(state.applying(.held(HeldLogs(newCount: 2, lastSeq: 6), filter: LogFilter(), base: 3)) == nil)
    }

    @Test("a read for another filter, or older than the rows shown, is dropped")
    func dropped() throws {
        let state = try #require(LogListState().applying(.page(page([3, 2, 1], seq: 4), filter: LogFilter())))
        #expect(state.applying(.page(page([2], seq: 5), filter: LogFilter(service: "web"))) == nil)
        #expect(state.applying(.page(page([2, 1], seq: 3), filter: LogFilter())) == nil)
        #expect(state.applying(.page(page([4, 3, 2, 1], seq: 4), filter: LogFilter()))?.items.count == 4)
    }

    @Test("paused: the pause id is the base the rows were read at, or the newest id for a list never read")
    func paused() throws {
        let read = try #require(LogListState().applying(.page(page([3, 2, 1], seq: 4), filter: LogFilter())))
        let paused = read.paused(latestID: 50)
        #expect(paused.pausedID == 3 && paused.readsHeld)
        #expect(paused.paused(latestID: 60).pausedID == 3)
        #expect(LogListState().paused(latestID: 50).pausedID == 50)
        // A page read up to the pause point fills an empty paused list; any other page is dropped.
        let empty = LogListState(pausedID: 50)
        #expect(empty.applying(.page(page([4, 3], seq: 5), filter: LogFilter())) == nil)
        let filled = try #require(empty.applying(.page(page([4, 3], lastID: 70, seq: 5, upTo: 50, newCount: 20),
                                                       filter: LogFilter())))
        #expect(filled.baseID == 50 && filled.newCount == 20)
        // Rows never change while paused, even at the top.
        #expect(filled.applying(.page(page([9, 4, 3], seq: 6, upTo: 50), filter: LogFilter())) == nil)
        #expect(filled.applying(.held(HeldLogs(newCount: 25, lastSeq: 6), filter: LogFilter(), base: 50))?.newCount == 25)
    }

    @Test("words: new logs, the subtitle, the pause bar, the empty states")
    func words() {
        #expect(LogList.newLogsTitle(1) == "1 new log")
        #expect(LogList.newLogsTitle(12) == "12 new logs")
        // Counts group the en_US way on every region (CountFormat, PROGRESS decision 192).
        #expect(LogList.subtitle(logCount: 8_310) == "8,310 logs")
        #expect(LogList.subtitle(logCount: 1, isPaused: true) == "Paused · 1 log")
        #expect(LogList.pausedText(newCount: 12) == "Paused. 12 new logs. Magnife is still receiving.")
        #expect(LogList.pausedText(newCount: 0) == "Paused. Magnife is still receiving.")
        #expect(LogList.emptyTitle(service: "orders") == "No Logs from orders")
        #expect(LogList.appending([item(3), item(2)], to: [item(4), item(3)]).map(\.id) == [4, 3, 2])
    }

    @Test("VoiceOver reads time, level, service, body and whether it has a trace")
    func spoken() {
        #expect(item(1, trace: traceID(1)).accessibilityLabel.hasSuffix(", INFO, web, log 1, has trace"))
        #expect(item(2).accessibilityLabel.hasSuffix(", INFO, web, log 2"))
    }
}
