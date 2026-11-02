import Foundation
import GRDB

/// A throwaway folder in /tmp for test databases. Never the real store.
struct TempDir {
    let url: URL

    init(_ label: String = "test") throws {
        url = URL(fileURLWithPath: "/tmp/magnife-tests/\(label)-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func file(_ name: String) -> URL { url.appending(path: name) }

    func remove() { try? FileManager.default.removeItem(at: url) }
}

enum Schema {
    /// docs/schema.sql, the contract with the Go helper.
    static let sql: String = {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return (try? String(contentsOf: repo.appending(path: "docs/schema.sql"), encoding: .utf8)) ?? ""
    }()
}

/// A writable connection that plays the Go helper: WAL, schema, inserts.
func makeWriter(at url: URL) throws -> DatabaseQueue {
    var config = Configuration()
    config.journalMode = .wal
    config.prepareDatabase { try $0.execute(sql: "PRAGMA synchronous = NORMAL") }
    let queue = try DatabaseQueue(path: url.path, configuration: config)
    try queue.write { db in
        try db.execute(sql: Schema.sql)
        try db.execute(sql: "INSERT OR REPLACE INTO meta (key, value) VALUES ('schema_version', '1'), ('last_seq', '0')")
    }
    return queue
}

/// Inserts one trace row and its root span, the way the helper would after a batch.
func insertTrace(_ db: Database, id: String, service: String = "checkout-api", route: String = "GET /",
                 startNs: Int64, durationNs: Int64 = 1_000_000, status: Int = 0, seq: Int64 = 1,
                 spanCount: Int = 1) throws {
    try db.execute(sql: "INSERT OR IGNORE INTO resources (id, hash, service_name, attributes) VALUES (?, ?, ?, ?)",
                   arguments: [abs(service.hashValue % 100_000), "hash-\(service)", service, #"{"service.name":"\#(service)"}"#])
    let resource = try Int64.fetchOne(db, sql: "SELECT id FROM resources WHERE service_name = ?", arguments: [service])!
    try db.execute(sql: """
        INSERT OR REPLACE INTO traces (trace_id, root_span_id, root_service, route, start_ns, end_ns, duration_ns,
            span_count, error_count, status, first_seq, updated_seq, received_ns)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, arguments: [id, String(id.prefix(16)), service, route, startNs, startNs + durationNs, durationNs,
                         spanCount, status == 2 ? 1 : 0, status, seq, seq, startNs])
    try db.execute(sql: """
        INSERT OR REPLACE INTO spans (trace_id, span_id, parent_span_id, name, kind, start_ns, end_ns, duration_ns,
            status_code, service_name, resource_id, received_ns)
        VALUES (?, ?, NULL, ?, 2, ?, ?, ?, ?, ?, ?, ?)
        """, arguments: [id, String(id.prefix(16)), route, startNs, startNs + durationNs, durationNs, status,
                         service, resource, startNs])
    try db.execute(sql: "INSERT OR REPLACE INTO services (name, first_seen_ns, last_seen_ns) VALUES (?, ?, ?)",
                   arguments: [service, startNs, startNs])
    try db.execute(sql: "INSERT OR REPLACE INTO meta (key, value) VALUES ('last_seq', ?)", arguments: [String(seq)])
}

func traceID(_ n: Int) -> String { String(format: "4bf92f3577b34da6a3ce929d0e0e%04x", n) }

func readonlyPool(at url: URL) throws -> DatabasePool {
    var config = Configuration()
    config.readonly = true
    return try DatabasePool(path: url.path, configuration: config)
}

func exists(_ url: URL, suffix: String) -> Bool {
    FileManager.default.fileExists(atPath: url.path + suffix)
}

func insertSpan(_ db: Database, trace: String, span: String, parent: String?, name: String, service: String,
                startNs: Int64, durationNs: Int64, status: Int = 0, attributes: String = "{}",
                events: String = "[]", links: String = "[]", dbSystem: String? = nil) throws {
    try db.execute(sql: "INSERT OR IGNORE INTO resources (id, hash, service_name, attributes) VALUES (?, ?, ?, ?)",
                   arguments: [abs(service.hashValue % 100_000), "hash-\(service)", service, #"{"service.name":"\#(service)"}"#])
    let resource = try Int64.fetchOne(db, sql: "SELECT id FROM resources WHERE service_name = ?", arguments: [service])!
    try db.execute(sql: """
        INSERT OR REPLACE INTO spans (trace_id, span_id, parent_span_id, name, kind, start_ns, end_ns, duration_ns,
            status_code, service_name, resource_id, attributes, events, links, db_system, received_ns)
        VALUES (?, ?, ?, ?, 3, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, arguments: [trace, span, parent, name, startNs, startNs + durationNs, durationNs, status, service,
                         resource, attributes, events, links, dbSystem, startNs])
    try db.execute(sql: "INSERT OR IGNORE INTO services (name, first_seen_ns, last_seen_ns) VALUES (?, ?, ?)",
                   arguments: [service, startNs, startNs])
}

func insertLog(_ db: Database, timeNs: Int64, severity: Int, service: String, body: String,
               trace: String? = nil, span: String? = nil) throws {
    try db.execute(sql: "INSERT OR IGNORE INTO resources (id, hash, service_name, attributes) VALUES (?, ?, ?, ?)",
                   arguments: [abs(service.hashValue % 100_000), "hash-\(service)", service, "{}"])
    let resource = try Int64.fetchOne(db, sql: "SELECT id FROM resources WHERE service_name = ?", arguments: [service])!
    try db.execute(sql: """
        INSERT INTO logs (time_ns, severity_number, severity_text, service_name, resource_id, body, attributes,
            trace_id, span_id, received_ns)
        VALUES (?, ?, '', ?, ?, ?, '{"k":"v"}', ?, ?, ?)
        """, arguments: [timeNs, severity, service, resource, body, trace, span, timeNs])
}

/// Waits for the first event that matches, or fails after `timeout`.
func next<T: Sendable>(_ iterator: inout AsyncStream<T>.Iterator, timeout: Duration = .seconds(5),
                       where match: @Sendable (T) -> Bool) async -> T? {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        guard let value = await iterator.next() else { return nil }
        if match(value) { return value }
    }
    return nil
}
