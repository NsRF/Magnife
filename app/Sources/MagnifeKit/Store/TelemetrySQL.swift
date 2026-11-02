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

    /// The shown rows (a JSON array of trace ids) that changed after seq
    /// `applied`, for a list that holds still (S-004). Primary-key lookups,
    /// so every shown row is read however many changed, and no service scan.
    static let heldTraceUpdates = """
        SELECT \(traceColumns) FROM traces
        WHERE trace_id IN (SELECT value FROM json_each(?)) AND updated_seq > ?
        """

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

    static let spanByID = "SELECT \(spanColumns) FROM spans WHERE trace_id = ? AND span_id = ?"

    static let resourceByID = "SELECT id, service_name, attributes FROM resources WHERE id = ?"

    static let logColumns = """
        id, time_ns, observed_ns, severity_number, severity_text, service_name, resource_id,
        scope_name, body, attributes, trace_id, span_id, event_name, received_ns
        """

    static let logsOfTrace = "SELECT \(logColumns) FROM logs WHERE trace_id = ? ORDER BY time_ns, id"

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
        ORDER BY name COLLATE NOCASE
        """

    static let lastSeq = "SELECT value FROM meta WHERE key = 'last_seq'"

    static func attributeKeys(source: Bool) -> String {
        "SELECT key, source, last_seen_ns FROM attribute_keys \(source ? "WHERE source = ?" : "") ORDER BY key, source"
    }
}
