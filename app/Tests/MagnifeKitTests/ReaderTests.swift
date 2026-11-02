import Foundation
import GRDB
import Testing
@testable import MagnifeKit

/// TelemetryReader against a database written the way the helper writes it.
@Suite("TelemetryReader", .serialized)
struct ReaderTests {
    static let base: Int64 = 1_730_000_000_000_000_000

    /// 5 traces: checkout-api calls orders in trace 3 and 5; trace 3 has an
    /// Error span in orders, trace 4 an Error span in checkout-api.
    private func makeStore() async throws -> (TempDir, DatabaseQueue, TelemetryReader) {
        let dir = try TempDir("reader")
        let url = dir.file("magnife.sqlite")
        let writer = try makeWriter(at: url)
        try await writer.write { db in
            for n in 1...5 {
                let status = n == 3 || n == 4 ? 2 : 1
                try insertTrace(db, id: traceID(n), service: n == 2 ? "web" : "checkout-api", route: "GET /\(n)",
                                startNs: Self.base + Int64(n) * 1_000_000_000, status: status, seq: Int64(n))
            }
            let root3 = String(traceID(3).prefix(16))
            try insertSpan(db, trace: traceID(3), span: "00f067aa0ba90001", parent: root3, name: "SELECT orders",
                           service: "orders", startNs: Self.base + 3_000_000_100, durationNs: 500, status: 2,
                           attributes: #"{"db.system":"postgresql","rows":3}"#,
                           events: #"[{"time_ns":1,"name":"exception","attributes":{"exception.type":"PgError"}}]"#,
                           links: #"[{"trace_id":"\#(traceID(1))","span_id":"aaaaaaaaaaaaaaaa","attributes":{}}]"#,
                           dbSystem: "postgresql")
            try insertSpan(db, trace: traceID(5), span: "00f067aa0ba90002", parent: String(traceID(5).prefix(16)),
                           name: "GET /stock", service: "orders", startNs: Self.base + 5_000_000_100, durationNs: 500)
            try insertSpan(db, trace: traceID(4), span: "00f067aa0ba90003", parent: String(traceID(4).prefix(16)),
                           name: "child", service: "checkout-api", startNs: Self.base + 4_000_000_100,
                           durationNs: 10, status: 2)
            try insertLog(db, timeNs: Self.base + 3_000_000_200, severity: 17, service: "orders", body: "query failed",
                          trace: traceID(3), span: "00f067aa0ba90001")
            try insertLog(db, timeNs: Self.base + 3_000_000_300, severity: 9, service: "checkout-api",
                          body: "trace-only", trace: traceID(3))
            try insertLog(db, timeNs: Self.base + 6_000_000_000, severity: 13, service: "web", body: "no trace")
            try insertLog(db, timeNs: Self.base + 7_000_000_000, severity: 20, service: "web", body: "error4")
            try db.execute(sql: "INSERT INTO attribute_keys VALUES ('db.system', 1, 1), ('service.name', 2, 1), ('k', 3, 1)")
        }
        return (dir, writer, try await TelemetryReader.open(at: url))
    }

    @Test("latest traces come newest first, in pages")
    func pages() async throws {
        let (dir, writer, reader) = try await makeStore()
        defer { dir.remove() }
        _ = writer
        let all = try await reader.latestTraces()
        #expect(all.map(\.traceID) == (1...5).reversed().map(traceID))
        let first = try await reader.latestTraces(limit: 2)
        #expect(first.map(\.traceID) == [traceID(5), traceID(4)])
        let second = try await reader.latestTraces(limit: 2, after: first.last!.cursor)
        #expect(second.map(\.traceID) == [traceID(3), traceID(2)])
        let last = try await reader.latestTraces(limit: 2, after: second.last!.cursor)
        #expect(last.map(\.traceID) == [traceID(1)])
        #expect(try await reader.traceCount() == 5)
    }

    @Test("pages never skip traces that start at the same nanosecond")
    func sameStart() async throws {
        let (dir, writer, reader) = try await makeStore()
        defer { dir.remove() }
        try await writer.write { db in
            for n in 10...13 { try insertTrace(db, id: traceID(n), startNs: Self.base + 9_000_000_000, seq: 9) }
        }
        let first = try await reader.latestTraces(limit: 2)
        let second = try await reader.latestTraces(limit: 2, after: first.last!.cursor)
        #expect(Set(first.map(\.traceID) + second.map(\.traceID)) == Set((10...13).map(traceID)))
    }

    @Test("a service filter keeps traces with any span from it")
    func serviceFilter() async throws {
        let (dir, writer, reader) = try await makeStore()
        defer { dir.remove() }
        _ = writer
        #expect(try await reader.latestTraces(service: "orders").map(\.traceID) == [traceID(5), traceID(3)])
        #expect(try await reader.latestTraces(service: "web").map(\.traceID) == [traceID(2)])
        #expect(try await reader.latestTraces(service: "nobody").isEmpty)
    }

    @Test("a trace and its spans")
    func traceAndSpans() async throws {
        let (dir, writer, reader) = try await makeStore()
        defer { dir.remove() }
        _ = writer
        let trace = try #require(try await reader.trace(id: traceID(3)))
        #expect(trace.status == .error)
        #expect(trace.route == "GET /3")
        #expect(try await reader.trace(id: "missing") == nil)

        let spans = try await reader.spans(traceID: traceID(3))
        #expect(spans.count == 2)
        #expect(spans[0].isRoot)
        let child = spans[1]
        #expect(child.parentSpanID == spans[0].spanID)
        #expect(child.kind == .client)
        #expect(child.status == .error)
        #expect(child.attributes["rows"] == .int(3))
        #expect(child.dbSystem == "postgresql")
        #expect(child.exceptions.map(\.type) == ["PgError"])
        #expect(child.links.first?.traceID == traceID(1))
        let resource = try #require(try await reader.resource(id: child.resourceID))
        #expect(resource.serviceName == "orders")
    }

    @Test("logs of a trace, of a span, and all logs")
    func logs() async throws {
        let (dir, writer, reader) = try await makeStore()
        defer { dir.remove() }
        _ = writer
        #expect(try await reader.logs(traceID: traceID(3)).map(\.body) == ["query failed", "trace-only"])
        #expect(try await reader.logs(traceID: traceID(3), spanID: "00f067aa0ba90001").map(\.body) == ["query failed"])
        #expect(try await reader.latestLogs().map(\.body) == ["error4", "no trace", "trace-only", "query failed"])
        #expect(try await reader.latestLogs(level: .error).map(\.body) == ["error4", "query failed"])
        #expect(try await reader.latestLogs(service: "web").map(\.body) == ["error4", "no trace"])
        #expect(try await reader.latestLogs(service: "web", level: .warn).map(\.body) == ["no trace"])
        let page = try await reader.latestLogs(limit: 2)
        #expect(try await reader.latestLogs(limit: 2, after: page.last!.cursor).map(\.body) == ["trace-only", "query failed"])
        let log = try #require(page.first)
        #expect(log.level == .error)
        #expect(log.attributes["k"] == .string("v"))
        #expect(log.traceID == nil)
    }

    @Test("a span's logs in time order, whatever order they arrived in (S-011)")
    func spanLogsInTimeOrder() async throws {
        let (dir, writer, reader) = try await makeStore()
        defer { dir.remove() }
        let span = "00f067aa0ba90001"
        try await writer.write { db in
            // Arrives after "query failed" but was written before it.
            try insertLog(db, timeNs: Self.base + 3_000_000_150, severity: 5, service: "orders", body: "retrying",
                          trace: traceID(3), span: span)
            try insertLog(db, timeNs: Self.base + 3_000_000_400, severity: 13, service: "orders", body: "gave up",
                          trace: traceID(3), span: span)
        }
        let detail = try #require(try await reader.spanDetail(traceID: traceID(3), spanID: span))
        #expect(detail.logs.map(\.record.body) == ["retrying", "query failed", "gave up"])
        #expect(detail.logs.map(\.levelWord) == ["DEBUG", "ERROR", "WARN"])
    }

    @Test("the log stamp counts a trace's logs and changes when one joins")
    func logStamp() async throws {
        let (dir, writer, reader) = try await makeStore()
        defer { dir.remove() }
        let before = try await reader.logStamp(traceID: traceID(3))
        #expect(before.count == 2 && before.lastID > 0)
        #expect(try await reader.logStamp(traceID: traceID(1)) == LogStamp(count: 0, lastID: 0))
        try await writer.write { db in
            try insertLog(db, timeNs: Self.base, severity: 9, service: "orders", body: "late", trace: traceID(3))
        }
        let after = try await reader.logStamp(traceID: traceID(3))
        #expect(after.count == 3 && after.lastID > before.lastID)
        // logs_by_trace answers it alone: no log row is read.
        let plan = try await writer.read { db in
            try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + TelemetrySQL.logStampOfTrace, arguments: [traceID(3)])
                .map { $0["detail"] as String }.joined(separator: " | ")
        }
        #expect(plan.contains("USING COVERING INDEX logs_by_trace"), "\(plan)")
    }

    @Test("services with error counts derived from spans")
    func services() async throws {
        let (dir, writer, reader) = try await makeStore()
        defer { dir.remove() }
        _ = writer
        let services = try await reader.services()
        #expect(services.map(\.name) == ["checkout-api", "orders", "web"])
        // checkout-api: trace 4 (root and child are Error) counts once; trace 3's
        // Error root also belongs to checkout-api.
        #expect(services.map(\.errorCount) == [2, 1, 0])
    }

    @Test("last seq, traces since a seq, attribute keys")
    func meta() async throws {
        let (dir, writer, reader) = try await makeStore()
        defer { dir.remove() }
        #expect(try await reader.lastSeq() == 5)
        #expect(try await reader.traceCount(createdAfter: 3) == 2)
        #expect(try await reader.traceCount(createdAfter: 5) == 0)
        #expect(try await reader.attributeKeys().map(\.key) == ["db.system", "k", "service.name"])
        #expect(try await reader.attributeKeys(source: .resource).map(\.key) == ["service.name"])
        // A new batch shows up in the next read.
        try await writer.write { try insertTrace($0, id: traceID(9), startNs: Self.base + 9_000_000_000, seq: 6) }
        #expect(try await reader.lastSeq() == 6)
        #expect(try await reader.traceCount(createdAfter: 5) == 1)
    }

    @Test("a missing file is .missing")
    func missing() async throws {
        let dir = try TempDir("reader-missing")
        defer { dir.remove() }
        await #expect(throws: StoreError.missing) { try await TelemetryReader.open(at: dir.file("magnife.sqlite")) }
    }

    @Test("a WAL file with no -wal is .notReady until the helper opens it")
    func notReady() async throws {
        let dir = try TempDir("reader-notready")
        defer { dir.remove() }
        let url = dir.file("magnife.sqlite")
        try makeWriter(at: url).close()
        try? FileManager.default.removeItem(atPath: url.path + "-wal")
        try? FileManager.default.removeItem(atPath: url.path + "-shm")
        await #expect(throws: StoreError.notReady) { try await TelemetryReader.open(at: url) }
        let writer = try makeWriter(at: url)
        _ = try await TelemetryReader.open(at: url)
        _ = writer
    }

    @Test("an empty file with no schema yet is .notReady")
    func noSchema() async throws {
        let dir = try TempDir("reader-empty")
        defer { dir.remove() }
        let url = dir.file("magnife.sqlite")
        var config = Configuration()
        config.journalMode = .wal
        let writer = try DatabaseQueue(path: url.path, configuration: config)
        await #expect(throws: StoreError.notReady) { try await TelemetryReader.open(at: url) }
        _ = writer
    }

    @Test("another schema version is refused")
    func wrongVersion() async throws {
        let dir = try TempDir("reader-version")
        defer { dir.remove() }
        let url = dir.file("magnife.sqlite")
        let writer = try makeWriter(at: url)
        try await writer.writeWithoutTransaction { try $0.execute(sql: "PRAGMA user_version = 2") }
        await #expect(throws: StoreError.unsupportedVersion(found: 2, expected: 1)) {
            try await TelemetryReader.open(at: url)
        }
        #expect(StoreError.unsupportedVersion(found: 2, expected: 1).message.contains("schema version 2"))
        #expect(!StoreError.unsupportedVersion(found: 2, expected: 1).isTransient)
        #expect(StoreError.notReady.isTransient)
    }

    @Test("the store location and its /tmp guard")
    func location() {
        #expect(StoreLocation.url(environment: [:]).path.hasSuffix("Library/Application Support/Magnife/magnife.sqlite"))
        #expect(StoreLocation.url(environment: ["APP_STORE": "/tmp/x.sqlite"]).path == "/tmp/x.sqlite")
        #expect(StoreLocation.isOverridden(environment: ["APP_STORE": "/tmp/x.sqlite"]))
        #expect(!StoreLocation.isOverridden(environment: ["APP_STORE": ""]))
        #expect(StoreLocation.isTestLocation(URL(fileURLWithPath: "/tmp/x.sqlite")))
        #expect(StoreLocation.isTestLocation(URL(fileURLWithPath: "/private/tmp/a/x.sqlite")))
        #expect(!StoreLocation.isTestLocation(URL(fileURLWithPath: "/tmp/../Users/x.sqlite")))
        #expect(!StoreLocation.isTestLocation(StoreLocation.url(environment: [:])))
    }
}
