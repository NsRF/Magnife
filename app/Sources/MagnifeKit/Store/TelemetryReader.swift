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
    /// for the next page. `service` keeps traces with any span from it;
    /// `upTo` keeps traces created by batches up to that seq (a paused list, S-010).
    @concurrent
    public func latestTraces(limit: Int = 200, after cursor: TraceCursor? = nil,
                             service: String? = nil, upTo: Int64? = nil) async throws -> [TraceSummary] {
        try await latestTraces(limit: limit, after: cursor, filter: TraceFilter(service: service), upTo: upTo)
    }

    /// A page of the traces `filter` keeps, newest first (S-017 to S-020).
    @concurrent
    public func latestTraces(limit: Int = 200, after cursor: TraceCursor? = nil, filter: TraceFilter,
                             upTo: Int64? = nil) async throws -> [TraceSummary] {
        let conditions = TraceFilterSQL(filter)
        var arguments: StatementArguments = []
        if let cursor { arguments += [cursor.startNs, cursor.startNs, cursor.traceID] }
        if let upTo { arguments += [upTo] }
        arguments += conditions.arguments + [limit]
        let sql = TelemetrySQL.traceList(cursor: cursor != nil, upTo: upTo != nil, filter: conditions)
        return try await pool.read { [arguments] in try TraceSummary.fetchAll($0, sql: sql, arguments: arguments) }
    }

    /// The first page of the list with the services, the scope's trace count
    /// and the last seq, in one read, so "new since this page" is exact (S-004).
    /// Paused (`upTo`, S-010): the page and count as of that seq, and how
    /// many traces in the scope were created after it.
    @concurrent
    public func tracePage(limit: Int = TraceList.pageSize, service: String? = nil,
                          upTo: Int64? = nil) async throws -> TracePage {
        try await tracePage(limit: limit, filter: TraceFilter(service: service), upTo: upTo)
    }

    /// The first page of the traces `filter` keeps. While the filter bar
    /// narrows the scope, the page carries both counts: the traces it keeps
    /// and the service scope's ("312 of 1,204 traces"), and the first is
    /// read with the page, so a filter that scans spans scans them once.
    @concurrent
    public func tracePage(limit: Int = TraceList.pageSize, filter: TraceFilter,
                          upTo: Int64? = nil) async throws -> TracePage {
        let conditions = TraceFilterSQL(filter)
        let scope = TraceFilterSQL(TraceFilter(service: filter.service))
        let narrows = filter.narrowsScope
        let pause: StatementArguments = upTo.map { [$0] } ?? []
        let pageSQL = TelemetrySQL.traceList(cursor: false, upTo: upTo != nil, filter: conditions, counted: narrows)
        let pageArguments = pause + conditions.arguments + [limit]
        let scopeSQL = TelemetrySQL.traceCount(upTo: upTo != nil, filter: scope)
        let scopeArguments = pause + scope.arguments
        let created = TraceFilterSQL(filter, spans: .perTrace)
        let newSQL = TelemetrySQL.tracesCreated(after: created)
        return try await pool.read { db in
            let rows = try Row.fetchAll(db, sql: pageSQL, arguments: pageArguments)
            let traces = try rows.map { try TraceSummary(row: $0) }
            let scopeCount = try Int.fetchOne(db, sql: scopeSQL, arguments: scopeArguments) ?? 0
            let count: Int = narrows ? (rows.first?["total"] ?? 0) : scopeCount
            return TracePage(traces: traces,
                             services: try ServiceSummary.fetchAll(db, sql: TelemetrySQL.servicesWithErrors),
                             lastSeq: try Self.lastSeq(db), traceCount: count, scopeCount: scopeCount, upTo: upTo,
                             newCount: try upTo.map { try Int.fetchOne(db, sql: newSQL, arguments: [$0] + created.arguments) ?? 0 } ?? 0)
        }
    }

    /// While the list holds still: the `shown` rows (trace ids) that changed
    /// after seq `applied`, and how many traces in the scope are newer than `base`.
    @concurrent
    public func heldTraces(base: Int64, applied: Int64, shown: [String], service: String? = nil) async throws -> HeldTraces {
        try await heldTraces(base: base, applied: applied, shown: shown, filter: TraceFilter(service: service))
    }

    /// The same, counting only the new traces `filter` keeps; their own spans are read, not every span.
    @concurrent
    public func heldTraces(base: Int64, applied: Int64, shown: [String], filter: TraceFilter) async throws -> HeldTraces {
        let ids = String(decoding: try JSONEncoder().encode(shown), as: UTF8.self)
        let updateArguments: StatementArguments = [ids, applied]
        let goneArguments: StatementArguments = [ids]
        let created = TraceFilterSQL(filter, spans: .perTrace)
        let countSQL = TelemetrySQL.tracesCreated(after: created)
        let countArguments: StatementArguments = [base] + created.arguments
        return try await pool.read { [updateArguments, goneArguments, countArguments] db in
            HeldTraces(updated: try TraceSummary.fetchAll(db, sql: TelemetrySQL.heldTraceUpdates,
                                                          arguments: updateArguments),
                       removed: shown.isEmpty ? [] : try String.fetchAll(db, sql: TelemetrySQL.heldTracesGone,
                                                                         arguments: goneArguments),
                       newCount: try Int.fetchOne(db, sql: countSQL, arguments: countArguments) ?? 0,
                       services: try ServiceSummary.fetchAll(db, sql: TelemetrySQL.servicesWithErrors),
                       lastSeq: try Self.lastSeq(db))
        }
    }

    /// Search (S-017): the newest traces the query keeps, up to `limit`. An
    /// empty query lists the newest traces. Search reads every stored trace:
    /// the sidebar, the filter bar and Pause do not narrow it.
    ///
    /// A query that looks into spans first walks the newest `window` traces,
    /// newest first, reading each one's own spans (spans_by_trace), and stops
    /// at `limit` matches: a common word answers in a millisecond whatever the
    /// store's size, and its `total` is nil (`searchCount` reads it). With
    /// fewer matches there, the whole store is read in one pass, page and
    /// total together. A word that looks like a trace ID puts the trace whose
    /// ID starts with it first, so it always reads the whole store.
    @concurrent
    public func searchTraces(_ query: TraceQuery, limit: Int = TraceSearch.resultLimit,
                             window: Int = TraceSearch.quickWindow) async throws -> TraceSearchResult {
        let filter = query.filter
        guard filter.isActive else {
            let newest = try await latestTraces(limit: TraceSearch.newestLimit, filter: TraceFilter())
            return TraceSearchResult(text: query.text, traces: newest, total: newest.count, isNewest: true)
        }
        let prefix = query.traceIDPrefixes.first
        let readsSpans = filter.activeConditions.contains { $0.field != .route }
        if readsSpans, prefix == nil {
            let walk = TraceFilterSQL(filter, spans: .perTrace)
            let walkSQL = TelemetrySQL.traceSearchWalk(filter: walk)
            let rows = try await pool.read { db -> (traces: [TraceSummary], complete: Bool) in
                // The start of the window's oldest trace; nil when the store holds fewer.
                let floor = try Int64.fetchOne(db, sql: TelemetrySQL.traceStartAtOffset, arguments: [window - 1])
                let traces = try TraceSummary.fetchAll(db, sql: walkSQL,
                                                       arguments: [floor ?? Int64.min] + walk.arguments + [limit])
                return (traces, floor == nil)
            }
            if rows.traces.count >= limit {
                return TraceSearchResult(text: query.text, traces: rows.traces, total: nil, isNewest: false)
            }
            // The window was the whole store: nothing more to read.
            if rows.complete {
                return TraceSearchResult(text: query.text, traces: rows.traces, total: rows.traces.count, isNewest: false)
            }
        }
        let prefixArgument: StatementArguments = prefix.map { [String(TraceFilterSQL.containsPattern($0).dropFirst())] } ?? []
        let rows = try await pool.read { db in
            let conditions = try Self.searchConditions(filter, db)
            let sql = TelemetrySQL.traceSearch(filter: conditions, prefixFirst: prefix != nil)
            return try Row.fetchAll(db, sql: sql, arguments: conditions.arguments + prefixArgument + [limit])
                .map { (try TraceSummary(row: $0), $0["total"] as Int? ?? 0) }
        }
        return TraceSearchResult(text: query.text, traces: rows.map(\.0), total: rows.first?.1 ?? 0, isNewest: false)
    }

    /// How many stored traces the query keeps, for a search whose page came
    /// back without its total ("50 of 312"). Cancel the task to stop it.
    @concurrent
    public func searchCount(_ query: TraceQuery) async throws -> Int {
        try await pool.read { db in
            let conditions = try Self.searchConditions(query.filter, db)
            return try Int.fetchOne(db, sql: TelemetrySQL.traceCount(upTo: false, filter: conditions),
                                    arguments: conditions.arguments) ?? 0
        }
    }

    /// Search's conditions over the whole store. When the trace's own columns
    /// (service, status, duration, route) leave at most a few thousand traces,
    /// their own spans are cheaper to read than every span; else every span
    /// is read once.
    private static func searchConditions(_ filter: TraceFilter, _ db: Database) throws -> TraceFilterSQL {
        let readsSpans = filter.activeConditions.contains { $0.field != .route }
        guard readsSpans, filter.service != nil || !filter.statuses.isEmpty || filter.slowerThanNs != nil else {
            return TraceFilterSQL(filter)
        }
        var columns = filter
        columns.conditions = filter.activeConditions.filter { $0.field == .route }
        let candidates = TraceFilterSQL(columns)
        let count = try Int.fetchOne(db, sql: TelemetrySQL.traceCount(upTo: false, filter: candidates),
                                     arguments: candidates.arguments) ?? 0
        return TraceFilterSQL(filter, spans: count <= TraceSearch.perTraceLimit ? .perTrace : .set)
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

    /// Trace Logs (S-012): every log of the trace in time order, those
    /// without a span id included, ready to show.
    @concurrent
    public func traceLogs(traceID: String) async throws -> TraceLogs {
        let records = try await pool.read {
            try LogRecord.fetchAll($0, sql: TelemetrySQL.logsOfTrace, arguments: [traceID])
        }
        return TraceLogs(traceID: traceID, records: records)
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

    // MARK: The Logs list (S-013)

    /// The first page of the Logs list, newest first, with the count in
    /// scope, the newest log id and the last seq, in one read. Paused
    /// (`upTo`, S-010): the page and count as of that log id, and how many
    /// logs in scope came after it.
    @concurrent
    public func logPage(limit: Int = LogList.pageSize, filter: LogFilter = LogFilter(),
                        upTo: Int64? = nil) async throws -> LogPage {
        let scope = Self.arguments(for: filter)
        let pageSQL = TelemetrySQL.logList(cursor: false, upTo: upTo != nil, filter: filter)
        let pageArguments = (upTo.map { [$0] as StatementArguments } ?? []) + scope + [limit]
        let countSQL = TelemetrySQL.logCount(upTo: upTo != nil, filter: filter)
        let countArguments = (upTo.map { [$0] as StatementArguments } ?? []) + scope
        let narrows = filter.narrowsScope
        let scopeCountSQL = TelemetrySQL.logScopeCount(upTo: upTo != nil, filter: filter)
        let scopeCountArguments = (upTo.map { [$0] as StatementArguments } ?? []) + Self.scopeArguments(for: filter)
        let rows = try await pool.read { db in
            (rows: try Self.logRows(db, sql: pageSQL, arguments: pageArguments),
             lastID: try Int64.fetchOne(db, sql: TelemetrySQL.lastLogID) ?? 0,
             lastSeq: try Self.lastSeq(db),
             count: try Int.fetchOne(db, sql: countSQL, arguments: countArguments) ?? 0,
             scopeCount: narrows ? try Int.fetchOne(db, sql: scopeCountSQL, arguments: scopeCountArguments) ?? 0 : nil,
             newCount: try upTo.map { try Int.fetchOne(db, sql: TelemetrySQL.logsAfter(filter: filter),
                                                       arguments: [$0] + scope) ?? 0 } ?? 0)
        }
        // The lines are built here, off the main actor.
        return LogPage(items: rows.rows.map(Self.logItem), lastID: rows.lastID, lastSeq: rows.lastSeq,
                       logCount: rows.count, scopeCount: rows.scopeCount ?? rows.count, upTo: upTo,
                       newCount: rows.newCount)
    }

    /// The next page of the Logs list below `cursor` (the last row shown).
    @concurrent
    public func logItems(limit: Int = LogList.pageSize, after cursor: LogCursor, filter: LogFilter = LogFilter(),
                         upTo: Int64? = nil) async throws -> [LogListItem] {
        let sql = TelemetrySQL.logList(cursor: true, upTo: upTo != nil, filter: filter)
        let arguments: StatementArguments = [cursor.timeNs, cursor.timeNs, cursor.id]
            + (upTo.map { [$0] as StatementArguments } ?? []) + Self.arguments(for: filter) + [limit]
        let rows = try await pool.read { try Self.logRows($0, sql: sql, arguments: arguments) }
        return rows.map(Self.logItem)
    }

    /// While the Logs list holds still: how many logs in scope came after
    /// `base`, and which `shown` rows (log ids) were pruned since (S-015).
    @concurrent
    public func heldLogs(base: Int64, filter: LogFilter = LogFilter(), shown: [Int64] = []) async throws -> HeldLogs {
        let sql = TelemetrySQL.logsAfter(filter: filter)
        let arguments: StatementArguments = [base] + Self.arguments(for: filter)
        let ids: StatementArguments = [String(decoding: try JSONEncoder().encode(shown), as: UTF8.self)]
        return try await pool.read { db in
            HeldLogs(newCount: try Int.fetchOne(db, sql: sql, arguments: arguments) ?? 0,
                     removed: shown.isEmpty ? [] : try Int64.fetchAll(db, sql: TelemetrySQL.heldLogsGone, arguments: ids),
                     lastSeq: try Self.lastSeq(db))
        }
    }

    /// The newest log id, where Pause holds a Logs list it has not read yet.
    @concurrent
    public func lastLogID() async throws -> Int64 {
        try await pool.read { try Int64.fetchOne($0, sql: TelemetrySQL.lastLogID) ?? 0 }
    }

    /// The Log Detail: one log, the resource it came from and whether its
    /// trace has stored spans, in one read.
    @concurrent
    public func logDetail(id: Int64) async throws -> LogDetail? {
        let read = try await pool.read { db -> (LogRow, ResourceRecord?)? in
            guard let row = try Self.logRows(db, sql: TelemetrySQL.logItemByID, arguments: [id]).first else { return nil }
            let resource = try ResourceRecord.fetchOne(db, sql: TelemetrySQL.resourceByID, arguments: [row.record.resourceID])
            return (row, resource)
        }
        guard let read else { return nil }
        return LogDetail(item: Self.logItem(read.0), resource: read.1)
    }

    /// A row of `TelemetrySQL.logList`, decoded inside the read (GRDB's Row is not Sendable).
    private typealias LogRow = (record: LogRecord, hasTrace: Bool)

    private static func logRows(_ db: Database, sql: String, arguments: StatementArguments) throws -> [LogRow] {
        try Row.fetchAll(db, sql: sql, arguments: arguments).map { (try LogRecord(row: $0), $0["has_trace"] ?? false) }
    }

    /// The row ready to show; its line is built on the caller's (nonisolated) side.
    private static func logItem(_ row: LogRow) -> LogListItem {
        LogListItem(line: LogLine(row.record), hasStoredTrace: row.hasTrace)
    }

    /// The arguments of `TelemetrySQL.logFilterConditions`, in its order.
    private static func arguments(for filter: LogFilter) -> StatementArguments {
        var arguments = scopeArguments(for: filter)
        for range in filter.severityRanges { arguments += [range.lowerBound, range.upperBound] }
        if !filter.bodyText.isEmpty { arguments += [filter.bodyText] }
        return arguments
    }

    /// The arguments of `TelemetrySQL.logScopeConditions`.
    private static func scopeArguments(for filter: LogFilter) -> StatementArguments {
        filter.service.map { [$0] } ?? []
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

    /// The retention the helper last applied, in seconds (meta.retention_s), nil before it ran.
    @concurrent
    public func retentionSeconds() async throws -> Int? {
        try await pool.read { try String.fetchOne($0, sql: TelemetrySQL.retention).flatMap { Int($0) } }
    }

    private static func lastSeq(_ db: Database) throws -> Int64 {
        Int64(try String.fetchOne(db, sql: TelemetrySQL.lastSeq) ?? "") ?? 0
    }

    /// The keys seen since `seenSinceNs` (wall clock ns; pass the retention's
    /// cutoff so keys of pruned data are left out), of one source or all.
    @concurrent
    public func attributeKeys(source: AttributeSource? = nil, seenSinceNs: Int64 = 0) async throws -> [AttributeKey] {
        let sql = TelemetrySQL.attributeKeys(source: source != nil)
        let arguments: StatementArguments = source.map { [seenSinceNs, $0.rawValue] } ?? [seenSinceNs]
        return try await pool.read { try AttributeKey.fetchAll($0, sql: sql, arguments: arguments) }
    }
}
