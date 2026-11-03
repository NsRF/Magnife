import Foundation
import GRDB
import Testing
@testable import MagnifeKit

/// The Logs filter bar (S-014): levels by OTel severity range, the service,
/// "Body contains", the chip rules and the words.
@Suite("Logs filter (S-014)", .serialized)
struct LogFilterTests {
    static let base: Int64 = 1_730_000_000_000_000_000

    /// One log per severity number 0...24, alternating web and orders, bodies
    /// "Severity n" with odd ones in capitals and one holding "100%_done".
    private func makeStore() async throws -> (TempDir, DatabaseQueue, TelemetryReader) {
        let dir = try TempDir("log-filter")
        let writer = try makeWriter(at: dir.file("magnife.sqlite"))
        try await writer.write { db in
            for n in 0...24 {
                let body = n == 7 ? "job 100%_done" : n % 2 == 0 ? "Severity \(n)" : "SEVERITY \(n)"
                try insertLog(db, timeNs: Self.base + Int64(n) * 1_000_000, severity: n,
                              service: n % 2 == 0 ? "web" : "orders", body: body)
            }
        }
        return (dir, writer, try await TelemetryReader.open(at: dir.file("magnife.sqlite")))
    }

    private func severities(_ reader: TelemetryReader, _ filter: LogFilter) async throws -> [Int] {
        try await reader.logPage(filter: filter).items.map(\.record.severityNumber).sorted()
    }

    @Test("ERROR keeps ERROR to ERROR4 (17-20), and nothing else", arguments: SeverityLevel.allCases)
    func ranges(level: SeverityLevel) async throws {
        let (dir, writer, reader) = try await makeStore()
        defer { dir.remove() }
        _ = writer
        #expect(try await severities(reader, LogFilter(levels: [level])) == Array(level.range))
    }

    @Test("Error is 17-20 exactly")
    func error() async throws {
        let (dir, writer, reader) = try await makeStore()
        defer { dir.remove() }
        _ = writer
        #expect(try await severities(reader, LogFilter(levels: [.error])) == [17, 18, 19, 20])
        #expect(SeverityLevel.error.range == 17...20)
    }

    @Test("no chip on keeps every log, those with no level (0) too; chips add up")
    func union() async throws {
        let (dir, writer, reader) = try await makeStore()
        defer { dir.remove() }
        _ = writer
        #expect(try await severities(reader, LogFilter()) == Array(0...24))
        #expect(try await severities(reader, LogFilter(levels: [.warn, .error])) == Array(13...20))
        #expect(try await severities(reader, LogFilter(levels: [.trace, .fatal])) == Array(1...4) + Array(21...24))
        #expect(LogFilter(levels: [.error, .warn, .fatal, .trace]).severityRanges == [1...4, 13...24])
    }

    @Test("levels, service and body combine, and the SQL keeps what `keeps` keeps")
    func combined() async throws {
        let (dir, writer, reader) = try await makeStore()
        defer { dir.remove() }
        _ = writer
        let all = try await reader.logPage().items.map(\.record)
        let filters = [
            LogFilter(service: "orders", levels: [.error]),
            LogFilter(levels: [.info, .debug], bodyContains: "severity 1"),
            LogFilter(service: "web", bodyContains: " SEVERITY 2 "),
            LogFilter(bodyContains: "100%_"),
            LogFilter(bodyContains: "%"),
            LogFilter(bodyContains: "_d"),
            LogFilter(levels: [.fatal], bodyContains: "nothing like it"),
        ]
        for filter in filters {
            let read = try await reader.logPage(filter: filter).items.map(\.id).sorted()
            #expect(read == all.filter(filter.keeps).map(\.id).sorted(), "\(filter)")
        }
        #expect(try await severities(reader, LogFilter(service: "orders", levels: [.error])) == [17, 19])
        // "%" and "_" are plain characters, not patterns.
        #expect(try await severities(reader, LogFilter(bodyContains: "100%_")) == [7])
        // Case does not matter, and surrounding spaces do not count.
        #expect(try await severities(reader, LogFilter(bodyContains: "  severity 2 ")) == [2, 20, 21, 22, 23, 24])
    }

    @Test("the page counts what the filter keeps and what the scope has")
    func counts() async throws {
        let (dir, writer, reader) = try await makeStore()
        defer { dir.remove() }
        _ = writer
        let page = try await reader.logPage(filter: LogFilter(service: "web", levels: [.error]))
        #expect(page.logCount == 2 && page.scopeCount == 13)
        let paused = try await reader.logPage(filter: LogFilter(levels: [.error]), upTo: 19)
        #expect(paused.logCount == 2 && paused.scopeCount == 19 && paused.newCount == 2)
        let plain = try await reader.logPage(filter: LogFilter(service: "web"))
        #expect(plain.logCount == 13 && plain.scopeCount == 13)
        let held = try await reader.heldLogs(base: 10, filter: LogFilter(levels: [.error, .fatal]))
        #expect(held.newCount == 8)
    }

    @Test("a click shows only that level; again shows every level; ⌘-click or Space adds and removes one")
    func chips() {
        let none = LogFilter(service: "web")
        let error = none.clicking(.error, adding: false)
        #expect(error.levels == [.error] && error.service == "web")
        #expect(error.clicking(.error, adding: false).levels.isEmpty)
        let both = error.clicking(.warn, adding: true)
        #expect(both.levels == [.error, .warn])
        #expect(both.clicking(.warn, adding: false).levels == [.warn])
        #expect(both.clicking(.error, adding: true).levels == [.warn])
        #expect(both.clicking(.warn, adding: true).clicking(.error, adding: true).levels.isEmpty)
    }

    @Test("what is on, and the words")
    func words() {
        #expect(!LogFilter().isActive && !LogFilter().narrowsScope)
        #expect(LogFilter(service: "web").isActive && !LogFilter(service: "web").narrowsScope)
        #expect(LogFilter(levels: [.info]).narrowsScope && LogFilter(bodyContains: "x").narrowsScope)
        #expect(!LogFilter(bodyContains: "   ").narrowsScope)
        #expect(LogFilter.cleared == LogFilter())
        #expect(SeverityLevel.error.chipHelp == "Show only ERROR logs, ERROR to ERROR4")
        #expect(SeverityLevel.trace.chipHelp == "Show only TRACE logs, TRACE to TRACE4")
        #expect(LogList.subtitle(shown: 3, of: 3) == "3 logs")
        #expect(LogList.subtitle(shown: 1, of: 20, isPaused: true) == "Paused · 1 of 20 logs")
        // Numbers follow the user's locale.
        #expect(LogList.subtitle(shown: 312, of: 1_204) == "312 of 1,204 logs")
        #expect(LogList.noMatchesTitle == "No Matching Logs" && LogList.noMatchesDescription == "No logs match these filters.")
    }

    @Test("100,000 logs: a rare level's first page and counts stay fast")
    func speed() async throws {
        let dir = try TempDir("log-filter-speed")
        defer { dir.remove() }
        let writer = try makeWriter(at: dir.file("magnife.sqlite"))
        try await writer.write { db in
            try insertLog(db, timeNs: Self.base, severity: 9, service: "web", body: "warm")
            let statement = try db.makeStatement(sql: """
                INSERT INTO logs (time_ns, severity_number, service_name, resource_id, body, received_ns)
                VALUES (?, ?, ?, (SELECT id FROM resources LIMIT 1), ?, 0)
                """)
            for n in 1...100_000 {
                // One FATAL in 2,000; the rest INFO and DEBUG over three services.
                let severity = n % 2_000 == 0 ? 21 : n % 3 == 0 ? 5 : 9
                try statement.execute(arguments: [Self.base + Int64(n) * 1_000, severity,
                                                  ["web", "orders", "checkout-api"][n % 3], "request \(n) handled"])
            }
        }
        let reader = try await TelemetryReader.open(at: dir.file("magnife.sqlite"))
        _ = try await reader.logPage()
        for filter in [LogFilter(levels: [.fatal]), LogFilter(service: "orders", levels: [.error]),
                       LogFilter(bodyContains: "request 99999"), LogFilter()] {
            let started = ContinuousClock.now
            let page = try await reader.logPage(filter: filter)
            let elapsed = started.duration(to: .now)
            print("INFO 100,000 logs, \(filter.levels.map(\.title)) \(filter.service ?? "") \(filter.bodyText): \(page.items.count) rows, \(page.logCount) of \(page.scopeCount) in \(elapsed)")
            // Off the main actor, and well under a refresh's 150 ms.
            #expect(elapsed < .milliseconds(150), "\(filter): \(elapsed)")
        }
    }
}
