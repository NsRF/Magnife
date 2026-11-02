import Foundation

/// Every query the app runs, in one place. Columns and indexes are in docs/schema.sql.
enum TelemetrySQL {
    static let userVersion = "PRAGMA user_version"

    static let traceColumns = """
        trace_id, root_span_id, root_service, route, start_ns, end_ns, duration_ns,
        span_count, error_count, status, first_seq, updated_seq, received_ns
        """

    /// Newest first. Optional cursor (start_ns, trace_id) and service, which
    /// matches traces with any span from that service.
    static func latestTraces(cursor: Bool, service: Bool) -> String {
        var conditions: [String] = []
        if cursor { conditions.append("(start_ns < ? OR (start_ns = ? AND trace_id < ?))") }
        if service { conditions.append("trace_id IN (SELECT trace_id FROM spans WHERE service_name = ?)") }
        let filter = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        return "SELECT \(traceColumns) FROM traces \(filter) ORDER BY start_ns DESC, trace_id DESC LIMIT ?"
    }

    /// Rows that existed at seq `base` and changed after seq `applied`, for
    /// a list that holds still (S-004). Optional service as in latestTraces.
    static func heldTraceUpdates(service: Bool) -> String {
        let scope = service ? " AND trace_id IN (SELECT trace_id FROM spans WHERE service_name = ?)" : ""
        return """
            SELECT \(traceColumns) FROM traces
            WHERE updated_seq > ? AND first_seq <= ?\(scope)
            ORDER BY start_ns DESC, trace_id DESC LIMIT ?
            """
    }

    /// Traces created after seq `base`: the "12 new traces" count (S-004).
    static func tracesCreatedAfter(service: Bool) -> String {
        let scope = service ? " AND trace_id IN (SELECT trace_id FROM spans WHERE service_name = ?)" : ""
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
