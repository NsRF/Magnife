import Foundation
import GRDB

/// The WHERE conditions of a TraceFilter over the `traces` table, with
/// their arguments in the same order. Values are always bound, never
/// written into the SQL: keys travel as JSON path arguments, text as LIKE
/// patterns with `\` escaping `%`, `_` and itself.
///
/// Matching rules (unit-tested in TraceFilterSQLTests):
/// - Status is `traces.status` (Error when any span is Error, else the root's).
/// - "Slower than" is `traces.duration_ns >` the value.
/// - An attribute condition matches a trace when any of its spans matches,
///   on the span's attributes or on its resource's. "is not" keeps traces in
///   which no span has the key with that value.
/// - "is" compares text: a string as stored, a number or bool as JSON
///   writes it ("500", "true"). "contains" ignores the case of A to Z
///   (SQLite's LIKE), as "Body contains" does for logs.
/// - Any Field contains: the trace's service, route or trace ID, or a span's
///   name, service or attribute value, or its resource's attribute value.
public struct TraceFilterSQL: Sendable {
    public var conditions: [String]
    public var arguments: StatementArguments

    /// How spans are matched. `.set` reads the matching trace ids once (a scan
    /// of spans, then lookups): for the list and counts. `.perTrace` looks at
    /// each candidate trace's own spans through spans_by_trace: for a few
    /// candidates, such as the traces created after a seq.
    public enum SpanMatch: Sendable { case set, perTrace }

    public init(_ filter: TraceFilter, spans: SpanMatch = .set) {
        var conditions: [String] = []
        var arguments: StatementArguments = []
        if let service = filter.service {
            conditions.append(TelemetrySQL.serviceScope)
            arguments += [service]
        }
        if !filter.statuses.isEmpty {
            let codes = filter.statuses.map(\.rawValue).sorted()
            conditions.append("status IN (" + codes.map { _ in "?" }.joined(separator: ", ") + ")")
            arguments += StatementArguments(codes)
        }
        if let ns = filter.slowerThanNs {
            conditions.append("duration_ns > ?")
            arguments += [ns]
        }
        for condition in filter.activeConditions {
            let part = Self.condition(condition, spans: spans)
            conditions.append(part.sql)
            arguments += part.arguments
        }
        self.conditions = conditions
        self.arguments = arguments
    }

    /// " AND ..." for a query that has a WHERE already, or "".
    public var andClause: String { conditions.isEmpty ? "" : " AND " + conditions.joined(separator: " AND ") }

    /// A LIKE pattern that finds `text` anywhere.
    static func containsPattern(_ text: String) -> String {
        "%" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_") + "%"
    }

    /// `$."http.route"`: one key, never a path into nested objects.
    static func jsonPath(_ key: String) -> String { "$.\"" + key + "\"" }

    private static func condition(_ condition: TraceCondition, spans: SpanMatch) -> (sql: String, arguments: StatementArguments) {
        let value = condition.trimmedValue
        switch condition.field {
        case .route:
            switch condition.op {
            case .is: return ("route = ?", [value])
            case .isNot: return ("route <> ?", [value])
            default: return (#"route LIKE ? ESCAPE '\'"#, [containsPattern(value)])
            }
        case .anyField:
            let pattern = containsPattern(value)
            let attributes = valuesContain(column: "spans.attributes")
            let resources = valuesContain(column: "resources.attributes")
            let spanMatch = #"name LIKE ? ESCAPE '\' OR service_name LIKE ? ESCAPE '\' OR "#
                + "\(attributes) OR resource_id IN (SELECT id FROM resources WHERE \(resources))"
            return (#"(root_service LIKE ? ESCAPE '\' OR route LIKE ? ESCAPE '\' OR trace_id LIKE ? ESCAPE '\' OR "#
                    + anySpan(spanMatch, spans: spans) + ")",
                    StatementArguments(Array(repeating: pattern, count: 9)))
        case .attribute(let key):
            let positive = condition.op == .isNot ? TraceCondition(field: condition.field, op: .is, value: value) : condition
            let spanPart = attributeMatch(positive, key: key, column: "spans.attributes")
            let resourcePart = attributeMatch(positive, key: key, column: "resources.attributes")
            let sql = anySpan("\(spanPart.sql) OR resource_id IN (SELECT id FROM resources WHERE \(resourcePart.sql))",
                              spans: spans)
            return (condition.op == .isNot ? "NOT \(sql)" : sql, spanPart.arguments + resourcePart.arguments)
        }
    }

    /// The trace has a span that matches `match`.
    private static func anySpan(_ match: String, spans: SpanMatch) -> String {
        switch spans {
        case .set: "trace_id IN (SELECT trace_id FROM spans WHERE \(match))"
        case .perTrace: "EXISTS (SELECT 1 FROM spans WHERE spans.trace_id = traces.trace_id AND (\(match)))"
        }
    }

    /// An attribute value (not a key) of the JSON object in `column` contains
    /// the pattern. The raw text is checked first, so most rows are never parsed.
    private static func valuesContain(column: String) -> String {
        #"(\#(column) LIKE ? ESCAPE '\' AND EXISTS (SELECT 1 FROM json_each(\#(column)) AS j "#
            + #"WHERE j.type <> 'object' AND j.value LIKE ? ESCAPE '\'))"#
    }

    /// One attribute condition on the JSON object in `column`.
    private static func attributeMatch(_ condition: TraceCondition, key: String,
                                       column: String) -> (sql: String, arguments: StatementArguments) {
        let value = condition.trimmedValue
        // SQLite's JSON paths cannot quote a key that holds a double quote:
        // such keys are found by name with json_each instead.
        guard !key.contains("\"") else { return eachMatch(condition, key: key, column: column) }
        let path = jsonPath(key)
        switch condition.op {
        case .is, .isNot:
            // ->> is a string's text; -> is a number's or bool's JSON ("500", "true").
            return ("(\(column) ->> ? = ? OR \(column) -> ? = ?)", [path, value, path, value])
        case .contains:
            return (#"\#(column) ->> ? LIKE ? ESCAPE '\'"#, [path, containsPattern(value)])
        case .exists:
            return ("\(column) -> ? IS NOT NULL", [path])
        case .greater, .less:
            let symbol = condition.op == .greater ? ">" : "<"
            return ("(json_type(\(column), ?) IN ('integer', 'real') AND \(column) ->> ? \(symbol) ?)",
                    [path, path, condition.number ?? 0])
        }
    }

    private static func eachMatch(_ condition: TraceCondition, key: String,
                                  column: String) -> (sql: String, arguments: StatementArguments) {
        let value = condition.trimmedValue
        let text = "(CASE e.type WHEN 'true' THEN 'true' WHEN 'false' THEN 'false' ELSE CAST(e.value AS TEXT) END)"
        let test: String
        var arguments: StatementArguments = [key]
        switch condition.op {
        case .is, .isNot:
            test = "\(text) = ?"
            arguments += [value]
        case .contains:
            test = #"e.value LIKE ? ESCAPE '\'"#
            arguments += [containsPattern(value)]
        case .exists:
            test = "1"
        case .greater, .less:
            test = "e.type IN ('integer', 'real') AND e.value \(condition.op == .greater ? ">" : "<") ?"
            arguments += [condition.number ?? 0]
        }
        return ("EXISTS (SELECT 1 FROM json_each(\(column)) AS e WHERE e.key = ? AND \(test))", arguments)
    }
}
