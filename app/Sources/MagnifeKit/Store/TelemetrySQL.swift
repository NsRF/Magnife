import Foundation

/// Every query the app runs, in one place. Columns and indexes are in docs/schema.sql.
enum TelemetrySQL {
    static let userVersion = "PRAGMA user_version"

    static let traceColumns = """
        trace_id, root_span_id, root_service, route, start_ns, end_ns, duration_ns,
        span_count, error_count, status, first_seq, updated_seq, received_ns
        """

    /// A service scope: traces with any span from that service (PROGRESS
    /// decision 15). The subquery reads the covering index
    /// spans_by_service_status by its first column, so its cost is the
    /// service's own spans, never a scan of spans (pinned by
    /// `ServiceScopeTests`).
    static let serviceScope = "trace_id IN (SELECT trace_id FROM spans WHERE service_name = ?)"

    /// Newest first. Optional cursor (start_ns, trace_id), pause point
    /// (traces created up to a seq, S-010) and service scope, with their
    /// arguments in that order.
    static func latestTraces(cursor: Bool, service: Bool, upTo: Bool = false) -> String {
        var conditions: [String] = []
        if cursor { conditions.append("(start_ns < ? OR (start_ns = ? AND trace_id < ?))") }
        if upTo { conditions.append("first_seq <= ?") }
        if service { conditions.append(serviceScope) }
        let filter = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        return "SELECT \(traceColumns) FROM traces \(filter) ORDER BY start_ns DESC, trace_id DESC LIMIT ?"
    }

    /// How many traces the scope has: the window's subtitle (S-009). Pause
    /// point first, then service.
    static func scopeTraceCount(service: Bool, upTo: Bool = false) -> String {
        var conditions: [String] = []
        if upTo { conditions.append("first_seq <= ?") }
        if service { conditions.append(serviceScope) }
        return "SELECT COUNT(*) FROM traces" + (conditions.isEmpty ? "" : " WHERE " + conditions.joined(separator: " AND "))
    }

    /// The trace list under a filter (S-017 to S-020), newest first. Optional
    /// cursor (start_ns, trace_id) and pause point, then the filter's
    /// conditions, then the limit, in that order. `counted` adds the number
    /// of traces the filter keeps to every row (`total`), so a filter that
    /// scans spans does it once for the page and its count.
    static func traceList(cursor: Bool, upTo: Bool, filter: TraceFilterSQL, counted: Bool = false) -> String {
        var conditions: [String] = []
        if cursor { conditions.append("(start_ns < ? OR (start_ns = ? AND trace_id < ?))") }
        if upTo { conditions.append("first_seq <= ?") }
        conditions += filter.conditions
        return "SELECT \(traceColumns)\(counted ? ", COUNT(*) OVER () AS total" : "") FROM traces "
            + whereClause(conditions) + " ORDER BY start_ns DESC, trace_id DESC LIMIT ?"
    }

    /// How many traces the filter keeps, up to a pause point (pause point first).
    static func traceCount(upTo: Bool, filter: TraceFilterSQL) -> String {
        "SELECT COUNT(*) FROM traces " + whereClause((upTo ? ["first_seq <= ?"] : []) + filter.conditions)
    }

    /// Traces created after seq `base` that the filter keeps: "12 new traces".
    /// Pass a `.perTrace` filter: only the new traces' own spans are read.
    static func tracesCreated(after filter: TraceFilterSQL) -> String {
        "SELECT COUNT(*) FROM traces WHERE first_seq > ?" + filter.andClause
    }

    /// Search (S-017): the newest traces the query keeps and their number.
    /// With `prefixFirst`, a trace whose id starts with the bound pattern comes first.
    static func traceSearch(filter: TraceFilterSQL, prefixFirst: Bool) -> String {
        "SELECT \(traceColumns), COUNT(*) OVER () AS total FROM traces " + whereClause(filter.conditions)
            + " ORDER BY " + (prefixFirst ? #"(trace_id LIKE ? ESCAPE '\') DESC, "# : "")
            + "start_ns DESC, trace_id DESC LIMIT ?"
    }

    /// Search's first look (S-017): traces that start at or after a bound
    /// (the newest few thousand), newest first, each checked on its own
    /// spans (a `.perTrace` filter), up to a limit. traces_by_start orders it.
    static func traceSearchWalk(filter: TraceFilterSQL) -> String {
        "SELECT \(traceColumns) FROM traces " + whereClause(["start_ns >= ?"] + filter.conditions)
            + " ORDER BY start_ns DESC, trace_id DESC LIMIT ?"
    }

    /// The start of the trace at an offset from the newest: the bound of Search's first look.
    static let traceStartAtOffset = "SELECT start_ns FROM traces ORDER BY start_ns DESC LIMIT 1 OFFSET ?"

    /// The shown rows (a JSON array of trace ids) that changed after seq
    /// `applied`, for a list that holds still (S-004). Primary-key lookups,
    /// so every shown row is read however many changed, and no service scan.
    static let heldTraceUpdates = """
        SELECT \(traceColumns) FROM traces
        WHERE trace_id IN (SELECT value FROM json_each(?)) AND updated_seq > ?
        """

    /// The shown rows (a JSON array of trace ids) that are no longer stored:
    /// pruning (S-015) takes them out of a held list. Primary-key lookups.
    static let heldTracesGone = """
        SELECT shown.value FROM json_each(?) AS shown
        WHERE NOT EXISTS (SELECT 1 FROM traces WHERE trace_id = shown.value)
        """

    /// The shown log rows (a JSON array of log ids) that are no longer stored (S-015).
    static let heldLogsGone = """
        SELECT shown.value FROM json_each(?) AS shown
        WHERE NOT EXISTS (SELECT 1 FROM logs WHERE id = shown.value)
        """

    /// The retention the helper last applied, in seconds (meta.retention_s).
    static let retention = "SELECT value FROM meta WHERE key = 'retention_s'"

    /// Traces created after seq `base`: the "12 new traces" count (S-004).
    static func tracesCreatedAfter(service: Bool) -> String {
        let scope = service ? " AND \(serviceScope)" : ""
        return "SELECT COUNT(*) FROM traces WHERE first_seq > ?\(scope)"
    }

    static let traceByID = "SELECT \(traceColumns) FROM traces WHERE trace_id = ?"

    static let traceCount = "SELECT COUNT(*) FROM traces"

    /// Pause counts the traces created after the seq it paused at.
    static let tracesCreatedAfter = "SELECT COUNT(*) FROM traces WHERE first_seq > ?"

    static let spanColumns = """
        id, trace_id, span_id, parent_span_id, name, kind, start_ns, end_ns, duration_ns,
        status_code, status_message, service_name, resource_id, scope_name, scope_version,
        attributes, events, links, db_system, db_statement, http_method, http_status_code,
        http_route, http_url, received_ns
        """

    static let spansOfTrace = "SELECT \(spanColumns) FROM spans WHERE trace_id = ? ORDER BY start_ns, id"

    /// The waterfall's columns only (no JSON), by start; spans_by_trace covers the order.
    static let waterfallSpansOfTrace = """
        SELECT id, span_id, parent_span_id, name, kind, start_ns, duration_ns, status_code, service_name
        FROM spans WHERE trace_id = ? ORDER BY start_ns, id
        """

    /// The columns the detectors read (S-023+): promoted columns only, no JSON;
    /// `service_name` says where a finding is (detector audit 6).
    static let detectorColumns = """
        trace_id, span_id, name, kind, start_ns, duration_ns, status_code, status_message,
        db_system, db_statement, http_method, http_status_code, http_route, http_url, service_name
        """

    /// The status messages of some spans of one trace (a JSON array of span
    /// ids): the "Under it, … has status Error: …" of an HTTP Error.
    static let statusMessagesOfSpans = """
        SELECT span_id, status_message FROM spans
        WHERE trace_id = ? AND span_id IN (SELECT value FROM json_each(?))
        """

    /// The spans a detector can flag: database spans (a system or a
    /// statement: N+1 groups statements whatever the system) and HTTP spans.
    /// spans_by_trace finds the trace's rows; the columns are checked on each row.
    static let detectorCandidate = """
        (db_system IS NOT NULL OR db_statement IS NOT NULL OR http_method IS NOT NULL OR http_status_code IS NOT NULL)
        """

    /// One trace's candidate spans, by start.
    static let detectorSpansOfTrace = """
        SELECT \(detectorColumns) FROM spans
        WHERE trace_id = ? AND \(detectorCandidate) ORDER BY start_ns, id
        """

    /// The candidate spans of several traces (a JSON array of trace ids): the trace list's badges.
    static let detectorSpansOfTraces = """
        SELECT \(detectorColumns) FROM spans
        WHERE trace_id IN (SELECT value FROM json_each(?)) AND \(detectorCandidate) ORDER BY start_ns, id
        """

    static let spanByID = "SELECT \(spanColumns) FROM spans WHERE trace_id = ? AND span_id = ?"

    static let resourceByID = "SELECT id, service_name, attributes FROM resources WHERE id = ?"

    static let logColumns = """
        id, time_ns, observed_ns, severity_number, severity_text, service_name, resource_id,
        scope_name, body, attributes, trace_id, span_id, event_name, received_ns
        """

    static let logsOfTrace = "SELECT \(logColumns) FROM logs WHERE trace_id = ? ORDER BY time_ns, id"

    /// The trace's logs that arrived after the shown ones (ids only grow).
    static let logsOfTraceAfter = "SELECT \(logColumns) FROM logs WHERE trace_id = ? AND id > ? ORDER BY time_ns, id"

    /// logs_by_trace covers it: no log row is read.
    static let logStampOfTrace = "SELECT COUNT(*), COALESCE(MAX(id), 0) FROM logs WHERE trace_id = ?"

    static let logsOfSpan = "SELECT \(logColumns) FROM logs WHERE trace_id = ? AND span_id = ? ORDER BY time_ns, id"

    /// Newest first. Optional cursor (time_ns, id), service, and severity range.
    static func latestLogs(cursor: Bool, service: Bool, level: Bool) -> String {
        var conditions: [String] = []
        if cursor { conditions.append("(time_ns < ? OR (time_ns = ? AND id < ?))") }
        if service { conditions.append("service_name = ?") }
        if level { conditions.append("severity_number BETWEEN ? AND ?") }
        let filter = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        return "SELECT \(logColumns) FROM logs \(filter) ORDER BY time_ns DESC, id DESC LIMIT ?"
    }

    /// The Logs list (S-013), newest first by time: the log's columns and
    /// whether its trace has stored spans (a primary-key lookup per row).
    /// Optional cursor (time_ns, id), pause point (logs up to an id) and
    /// filter, with their arguments in that order. logs_by_time orders it;
    /// a service reads logs_by_service.
    static func logList(cursor: Bool, upTo: Bool, filter: LogFilter) -> String {
        var conditions: [String] = []
        if cursor { conditions.append("(time_ns < ? OR (time_ns = ? AND id < ?))") }
        if upTo { conditions.append("id <= ?") }
        conditions += logFilterConditions(filter)
        return """
            SELECT \(logColumns),
                   EXISTS (SELECT 1 FROM traces WHERE traces.trace_id = logs.trace_id) AS has_trace
            FROM logs \(whereClause(conditions)) ORDER BY time_ns DESC, id DESC LIMIT ?
            """
    }

    /// The conditions of a log filter, in the order `TelemetryReader.arguments(for:)` binds them.
    /// Service, then one BETWEEN per merged severity range (S-014: ERROR is
    /// 17-20, ERROR to ERROR4), then the body text, case-insensitive for A to Z.
    static func logFilterConditions(_ filter: LogFilter) -> [String] {
        logScopeConditions(filter) + logBarConditions(filter)
    }

    /// The sidebar's part of a filter: the service.
    static func logScopeConditions(_ filter: LogFilter) -> [String] {
        filter.service == nil ? [] : ["service_name = ?"]
    }

    /// The filter bar's part: levels and body.
    static func logBarConditions(_ filter: LogFilter) -> [String] {
        var conditions: [String] = []
        let ranges = filter.severityRanges
        if !ranges.isEmpty {
            conditions.append("(" + ranges.map { _ in "severity_number BETWEEN ? AND ?" }.joined(separator: " OR ") + ")")
        }
        if !filter.bodyText.isEmpty { conditions.append("instr(lower(body), lower(?)) > 0") }
        return conditions
    }

    /// How many logs the filter keeps (the subtitle), up to a pause point.
    static func logCount(upTo: Bool, filter: LogFilter) -> String {
        "SELECT COUNT(*) FROM logs " + whereClause((upTo ? ["id <= ?"] : []) + logFilterConditions(filter))
    }

    /// How many logs the service scope has, the filter bar aside: "of 1,204 logs".
    static func logScopeCount(upTo: Bool, filter: LogFilter) -> String {
        "SELECT COUNT(*) FROM logs " + whereClause((upTo ? ["id <= ?"] : []) + logScopeConditions(filter))
    }

    /// Logs stored after an id that the filter keeps: "12 new logs".
    static func logsAfter(filter: LogFilter) -> String {
        "SELECT COUNT(*) FROM logs " + whereClause(["id > ?"] + logFilterConditions(filter))
    }

    /// The newest log id; the rowid's last entry, no scan.
    static let lastLogID = "SELECT COALESCE(MAX(id), 0) FROM logs"

    static let logItemByID = """
        SELECT \(logColumns),
               EXISTS (SELECT 1 FROM traces WHERE traces.trace_id = logs.trace_id) AS has_trace
        FROM logs WHERE id = ?
        """

    private static func whereClause(_ conditions: [String]) -> String {
        conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
    }

    /// Error count per service: distinct traces with an Error span from it
    /// (spans_by_service_status covers the subquery).
    static let servicesWithErrors = """
        SELECT name, first_seen_ns, last_seen_ns,
               (SELECT COUNT(DISTINCT trace_id) FROM spans
                 WHERE spans.service_name = services.name AND spans.status_code = 2) AS error_count
        FROM services
        WHERE EXISTS (SELECT 1 FROM spans WHERE spans.service_name = services.name)
           OR EXISTS (SELECT 1 FROM logs WHERE logs.service_name = services.name)
        ORDER BY name COLLATE NOCASE
        """

    static let lastSeq = "SELECT value FROM meta WHERE key = 'last_seq'"

    /// Recent Errors (S-026): the newest traces with an error, on the index
    /// traces_by_status (status, start_ns DESC).
    static let recentErrorTraces = """
        SELECT \(traceColumns) FROM traces WHERE status = 2 ORDER BY start_ns DESC, trace_id DESC LIMIT ?
        """

    /// Failure notifications (S-028): the traces of a batch's `error_traces`
    /// (a JSON array of ids) that are still Error, by primary key.
    static let failedTraces = """
        SELECT trace_id, route, root_service, start_ns FROM traces
        WHERE trace_id IN (SELECT value FROM json_each(?)) AND status = 2
        ORDER BY start_ns, trace_id
        """
    /// A trace's Error spans in start order, on spans_by_trace; read until one has an exception.
    static let errorSpans = """
        SELECT name, events FROM spans WHERE trace_id = ? AND status_code = 2 ORDER BY start_ns, span_id
        """

    /// Keys last seen at or after ?1 (the retention's cutoff, so pruned keys
    /// leave the suggestions; the helper keeps every key it ever saw).
    static func attributeKeys(source: Bool) -> String {
        "SELECT key, source, last_seen_ns FROM attribute_keys WHERE last_seen_ns >= ?\(source ? " AND source = ?" : "") ORDER BY key, source"
    }
}
