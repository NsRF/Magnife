import Foundation
import GRDB

/// Reads the helper's database. Read-only: it never writes, migrates, or
/// checkpoints. Every method runs its query on GRDB's reader queues, off the
/// main actor.
public final class TelemetryReader: Sendable {
    /// The schema version in docs/schema.sql this app reads.
    public static let schemaVersion = 1

    public let url: URL
    private let pool: DatabasePool

    private init(url: URL, pool: DatabasePool) {
        self.url = url
        self.pool = pool
    }

    /// Opens the database read-only and checks its schema version.
    /// Throws a StoreError; `.missing` and `.notReady` clear once the helper
    /// has opened the file (it sends "ports" after that).
    @concurrent
    public static func open(at url: URL) async throws(StoreError) -> TelemetryReader {
        guard FileManager.default.fileExists(atPath: url.path) else { throw .missing }
        var config = Configuration()
        config.readonly = true
        config.label = "Magnife.reader"
        let pool: DatabasePool
        do {
            pool = try DatabasePool(path: url.path, configuration: config)
        } catch let error as DatabaseError where error.resultCode == .SQLITE_CANTOPEN {
            // A WAL database whose writer is not running has no -wal file,
            // and a read-only connection cannot create it (WALReadonlyTests).
            throw FileManager.default.fileExists(atPath: url.path) ? .notReady : .missing
        } catch {
            throw .cannotOpen(String(describing: error))
        }
        let version: Int
        do {
            version = try await pool.read { try Int.fetchOne($0, sql: TelemetrySQL.userVersion) ?? 0 }
        } catch {
            throw .cannotOpen(String(describing: error))
        }
        // 0 means the helper created the file but not the schema yet.
        if version == 0 { throw .notReady }
        guard version == schemaVersion else { throw .unsupportedVersion(found: version, expected: schemaVersion) }
        return TelemetryReader(url: url, pool: pool)
    }

    // MARK: Traces

    /// A page of traces, newest first by start. Pass the last row's cursor
    /// for the next page. `service` keeps traces with any span from it.
    @concurrent
    /// `upTo` keeps traces created by batches up to that seq (a paused list, S-010).
    public func latestTraces(limit: Int = 200, after cursor: TraceCursor? = nil,
                             service: String? = nil, upTo: Int64? = nil) async throws -> [TraceSummary] {
        var arguments: StatementArguments = []
        if let cursor { arguments += [cursor.startNs, cursor.startNs, cursor.traceID] }
        if let upTo { arguments += [upTo] }
        if let service { arguments += [service] }
        arguments += [limit]
        let sql = TelemetrySQL.latestTraces(cursor: cursor != nil, service: service != nil, upTo: upTo != nil)
        return try await pool.read { [arguments] in try TraceSummary.fetchAll($0, sql: sql, arguments: arguments) }
    }

    /// The first page of the list with the services, the scope's trace count
    /// and the last seq, in one read, so "new since this page" is exact (S-004).
    /// Paused (`upTo`, S-010): the page and count as of that seq, and how
    /// many traces in the scope were created after it.
    @concurrent
    public func tracePage(limit: Int = TraceList.pageSize, service: String? = nil,
                          upTo: Int64? = nil) async throws -> TracePage {
        var scope: StatementArguments = []
        if let upTo { scope += [upTo] }
        if let service { scope += [service] }
        let arguments = scope + [limit]
        let scoped = service != nil
        let sql = TelemetrySQL.latestTraces(cursor: false, service: scoped, upTo: upTo != nil)
        let countSQL = TelemetrySQL.scopeTraceCount(service: scoped, upTo: upTo != nil)
        let newArguments: StatementArguments = upTo.map { [$0] + (service.map { [$0] } ?? []) } ?? []
        return try await pool.read { [scope] db in
            TracePage(traces: try TraceSummary.fetchAll(db, sql: sql, arguments: arguments),
                      services: try ServiceSummary.fetchAll(db, sql: TelemetrySQL.servicesWithErrors),
                      lastSeq: try Self.lastSeq(db),
                      traceCount: try Int.fetchOne(db, sql: countSQL, arguments: scope) ?? 0,
                      upTo: upTo,
                      newCount: upTo == nil ? 0 : try Int.fetchOne(db, sql: TelemetrySQL.tracesCreatedAfter(service: scoped),
                                                                   arguments: newArguments) ?? 0)
        }
    }

    /// While the list holds still: the `shown` rows (trace ids) that changed
    /// after seq `applied`, and how many traces in the scope are newer than `base`.
    @concurrent
    public func heldTraces(base: Int64, applied: Int64, shown: [String], service: String? = nil) async throws -> HeldTraces {
        let ids = String(decoding: try JSONEncoder().encode(shown), as: UTF8.self)
        let updateArguments: StatementArguments = [ids, applied]
        var countArguments: StatementArguments = [base]
        if let service { countArguments += [service] }
        let scoped = service != nil
        return try await pool.read { [updateArguments, countArguments] db in
            HeldTraces(updated: try TraceSummary.fetchAll(db, sql: TelemetrySQL.heldTraceUpdates,
                                                          arguments: updateArguments),
                       newCount: try Int.fetchOne(db, sql: TelemetrySQL.tracesCreatedAfter(service: scoped),
                                                  arguments: countArguments) ?? 0,
                       services: try ServiceSummary.fetchAll(db, sql: TelemetrySQL.servicesWithErrors),
                       lastSeq: try Self.lastSeq(db))
        }
    }

    @concurrent
    public func trace(id: String) async throws -> TraceSummary? {
        try await pool.read { try TraceSummary.fetchOne($0, sql: TelemetrySQL.traceByID, arguments: [id]) }
    }

    @concurrent
    public func traceCount() async throws -> Int {
        try await pool.read { try Int.fetchOne($0, sql: TelemetrySQL.traceCount) ?? 0 }
    }

    /// Traces created by batches after `seq`, for the paused list's count.
    @concurrent
    public func traceCount(createdAfter seq: Int64) async throws -> Int {
        try await pool.read { try Int.fetchOne($0, sql: TelemetrySQL.tracesCreatedAfter, arguments: [seq]) ?? 0 }
    }

    // MARK: Spans

    /// Every span of a trace, by start time.
    @concurrent
    public func spans(traceID: String) async throws -> [SpanRecord] {
        try await pool.read { try SpanRecord.fetchAll($0, sql: TelemetrySQL.spansOfTrace, arguments: [traceID]) }
    }

    /// The waterfall's columns of every span of a trace, by start time (S-005).
    @concurrent
    public func waterfallSpans(traceID: String) async throws -> [WaterfallSpan] {
        try await pool.read { try WaterfallSpan.fetchAll($0, sql: TelemetrySQL.waterfallSpansOfTrace, arguments: [traceID]) }
    }

    /// One span with its attributes, events and links: the span detail.
    @concurrent
    public func span(traceID: String, spanID: String) async throws -> SpanRecord? {
        try await pool.read { try SpanRecord.fetchOne($0, sql: TelemetrySQL.spanByID, arguments: [traceID, spanID]) }
    }

    /// The span detail (S-006, S-011): one span, the resource it came from
    /// and its logs, in one read.
    @concurrent
    public func spanDetail(traceID: String, spanID: String) async throws -> SpanDetail? {
        let read = try await pool.read { db -> (SpanRecord, ResourceRecord?, [LogRecord])? in
            guard let span = try SpanRecord.fetchOne(db, sql: TelemetrySQL.spanByID, arguments: [traceID, spanID]) else {
                return nil
            }
            let resource = try ResourceRecord.fetchOne(db, sql: TelemetrySQL.resourceByID, arguments: [span.resourceID])
            let logs = try LogRecord.fetchAll(db, sql: TelemetrySQL.logsOfSpan, arguments: [traceID, spanID])
            return (span, resource, logs)
        }
        // Ordering and pretty-printing happen here, on this nonisolated method, not on the main actor.
        return read.map { SpanDetail(span: $0.0, resource: $0.1, logs: $0.2) }
    }

    @concurrent
    public func resource(id: Int64) async throws -> ResourceRecord? {
        try await pool.read { try ResourceRecord.fetchOne($0, sql: TelemetrySQL.resourceByID, arguments: [id]) }
    }

    // MARK: Logs

    /// Logs of a trace in time order, including those with no span id.
    @concurrent
    public func logs(traceID: String) async throws -> [LogRecord] {
        try await pool.read { try LogRecord.fetchAll($0, sql: TelemetrySQL.logsOfTrace, arguments: [traceID]) }
    }

    /// How many logs carry the trace id, and the newest row id among them:
    /// it changes whenever a log joins the trace (S-011 refresh).
    @concurrent
    public func logStamp(traceID: String) async throws -> LogStamp {
        try await pool.read { db in
            let row = try Row.fetchOne(db, sql: TelemetrySQL.logStampOfTrace, arguments: [traceID])
            return LogStamp(count: row?[0] ?? 0, lastID: row?[1] ?? 0)
        }
    }

    /// Logs written during one span, in time order.
    @concurrent
    public func logs(traceID: String, spanID: String) async throws -> [LogRecord] {
        try await pool.read {
            try LogRecord.fetchAll($0, sql: TelemetrySQL.logsOfSpan, arguments: [traceID, spanID])
        }
    }

    /// A page of all logs, newest first, optionally one service and one level.
    @concurrent
    public func latestLogs(limit: Int = 200, after cursor: LogCursor? = nil, service: String? = nil,
                           level: SeverityLevel? = nil) async throws -> [LogRecord] {
        var arguments: StatementArguments = []
        if let cursor { arguments += [cursor.timeNs, cursor.timeNs, cursor.id] }
        if let service { arguments += [service] }
        if let level { arguments += [level.range.lowerBound, level.range.upperBound] }
        arguments += [limit]
        let sql = TelemetrySQL.latestLogs(cursor: cursor != nil, service: service != nil, level: level != nil)
        return try await pool.read { [arguments] in try LogRecord.fetchAll($0, sql: sql, arguments: arguments) }
    }

    // MARK: Services, meta, keys

    /// Every service by name, with its error count derived from spans.
    @concurrent
    public func services() async throws -> [ServiceSummary] {
        try await pool.read { try ServiceSummary.fetchAll($0, sql: TelemetrySQL.servicesWithErrors) }
    }

    /// The seq of the last committed batch (meta.last_seq), 0 before the first.
    @concurrent
    public func lastSeq() async throws -> Int64 {
        try await pool.read { try Self.lastSeq($0) }
    }

    private static func lastSeq(_ db: Database) throws -> Int64 {
        Int64(try String.fetchOne(db, sql: TelemetrySQL.lastSeq) ?? "") ?? 0
    }

    @concurrent
    public func attributeKeys(source: AttributeSource? = nil) async throws -> [AttributeKey] {
        let sql = TelemetrySQL.attributeKeys(source: source != nil)
        let arguments: StatementArguments = source.map { [$0.rawValue] } ?? []
        return try await pool.read { try AttributeKey.fetchAll($0, sql: sql, arguments: arguments) }
    }
}
