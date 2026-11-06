import Foundation

/// Opens the store once, read-only, when the first tool needs it (S-034). A
/// store that is not there yet is tried again on the next call.
public actor StoreConnection {
    public let url: URL
    private var reader: TelemetryReader?

    public init(url: URL) {
        self.url = url
    }

    public func open() async throws(StoreError) -> TelemetryReader {
        if let reader { return reader }
        let opened = try await TelemetryReader.open(at: url)
        reader = opened
        return opened
    }
}

/// Magnife's seven read-only tools (docs/mcp.md, "Tools"), on the same reader,
/// query parser, detectors and finding words as the window.
public struct MagnifeTools: MCPToolbox {
    public static let maxTraces = 100
    public static let maxSpans = 500
    public static let maxLogs = 200
    public static let maxValue = 2_000
    public static let maxStack = 8_000
    /// Spans with an error whose exceptions `get_trace` reads.
    public static let maxExceptionSpans = 20
    /// Rows of a comparison's tree, and its strip lines and queries.
    public static let maxComparisonRows = 500
    public static let maxDifferences = 50
    /// Same-route traces `compare_traces` looks at for a baseline.
    public static let baselineCandidates = 50

    public let store: StoreConnection
    public let timeZone: TimeZone
    public let now: @Sendable () -> Date

    public init(store: StoreConnection, timeZone: TimeZone = .current, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.timeZone = timeZone
        self.now = now
    }

    // MARK: Definitions

    public var tools: [MCPTool] {
        [
            MCPTool(name: "list_services", title: "List services",
                    description: "The services Magnife has received telemetry from, with when each was last seen and how many error spans it has.",
                    inputSchema: Self.schema([:])),
            MCPTool(name: "list_traces", title: "List traces",
                    description: """
                        The newest traces, newest first: trace id, root service, route, duration, span count, status and \
                        findings. Narrow them with a Magnife query: service:<name>, status:error|ok|unset, route:<part>, \
                        >200ms (slower than), key=value, key!=value, key~part, key>1, key<1, has:key, or plain words that \
                        any field contains; tokens combine with AND, quotes keep spaces (route:"GET /items/{id}").
                        """,
                    inputSchema: Self.schema([
                        "query": ["type": "string", "description": "A Magnife query, e.g. \"status:error service:orders >200ms\". Empty for every trace."],
                        "limit": ["type": "integer", "minimum": 1, "maximum": .number(Double(Self.maxTraces)), "default": 20],
                        "since_minutes": ["type": "integer", "minimum": 1, "description": "Only traces that started in the last N minutes."],
                    ])),
            MCPTool(name: "get_trace", title: "Get a trace",
                    description: """
                        One trace: its summary, its findings (Slow SQL, N+1, HTTP Error) in Magnife's words, the span tree \
                        with span ids, services, durations, statuses and error messages, its exceptions, and how many logs it has.
                        """,
                    inputSchema: Self.schema([
                        "trace_id": ["type": "string", "description": "The trace id (32 hex characters), or a unique prefix of 8 or more."],
                        "max_spans": ["type": "integer", "minimum": 1, "maximum": .number(Double(Self.maxSpans)), "default": 200],
                    ], required: ["trace_id"])),
            MCPTool(name: "get_span", title: "Get a span",
                    description: "One span's attributes, events, exceptions with stack traces, resource attributes, links and logs.",
                    inputSchema: Self.schema([
                        "trace_id": ["type": "string"],
                        "span_id": ["type": "string", "description": "The span id (16 hex characters), as get_trace lists it."],
                    ], required: ["trace_id", "span_id"])),
            MCPTool(name: "search_logs", title: "Search logs",
                    description: """
                        Logs, newest first: time, level, service, body, and the trace and span ids. Give trace_id for one \
                        trace's logs (oldest first), or filter all logs by service, levels and body text.
                        """,
                    inputSchema: Self.schema([
                        "trace_id": ["type": "string"],
                        "service": ["type": "string"],
                        "levels": ["type": "array", "items": ["type": "string", "enum": ["trace", "debug", "info", "warn", "error", "fatal"]]],
                        "body_contains": ["type": "string"],
                        "limit": ["type": "integer", "minimum": 1, "maximum": .number(Double(Self.maxLogs)), "default": 50],
                    ])),
            MCPTool(name: "find_problems", title: "Find problems",
                    description: """
                        What went wrong lately: every finding (slow SQL queries, N+1 queries, failed HTTP calls) in the newest \
                        traces, in Magnife's words with trace and span ids, then the failed traces that have no finding.
                        """,
                    inputSchema: Self.schema([
                        "limit": ["type": "integer", "minimum": 1, "maximum": .number(Double(Self.maxTraces)), "default": 50,
                                  "description": "How many of the newest traces to look at."],
                        "since_minutes": ["type": "integer", "minimum": 1],
                    ])),
            MCPTool(name: "compare_traces", title: "Compare two traces",
                    description: """
                        Two traces matched span by span, as Magnife's Compare Traces window shows them (B against A, the \
                        baseline): how much longer B took, the differences (spans that got slower or faster by their own \
                        time, new and missing spans, statements whose number of runs changed, spans that turned Error), each \
                        normalized SQL statement's runs and duration in both, and the tree of the spans that differ, with \
                        span ids from both traces. Leave baseline_trace_id out to compare with the fastest recent trace of \
                        the same route: "why is this request slower than usual?".
                        """,
                    inputSchema: Self.schema([
                        "trace_id": ["type": "string", "description": "Trace B, the one to explain (full id, or a unique prefix of 8 or more)."],
                        "baseline_trace_id": ["type": "string", "description": .string("Trace A. Left out: the fastest of the newest \(Self.baselineCandidates) other traces with B's service and route.")],
                        "max_rows": ["type": "integer", "minimum": 1, "maximum": .number(Double(Self.maxComparisonRows)), "default": 200],
                    ], required: ["trace_id"])),
        ]
    }

    static func schema(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        var schema: [String: JSONValue] = ["type": "object", "properties": .object(properties), "additionalProperties": false]
        if !required.isEmpty { schema["required"] = .array(required.map { .string($0) }) }
        return .object(schema)
    }

    // MARK: Calls

    public func call(_ name: String, arguments: [String: JSONValue]) async throws(MCPInvalidParams) -> MCPToolResult {
        let args = MCPArguments(arguments)
        do {
            switch name {
            case "list_services": return try await listServices()
            case "list_traces":
                return try await listTraces(query: try args.string("query") ?? "",
                                            limit: try args.int("limit", default: 20, in: 1...Self.maxTraces),
                                            sinceMinutes: try args.optionalInt("since_minutes", in: 1...525_600))
            case "get_trace":
                return try await getTrace(id: try args.required("trace_id"),
                                          maxSpans: try args.int("max_spans", default: 200, in: 1...Self.maxSpans))
            case "get_span":
                return try await getSpan(traceID: try args.required("trace_id"), spanID: try args.required("span_id"))
            case "search_logs":
                return try await searchLogs(traceID: try args.string("trace_id"), service: try args.string("service"),
                                            levels: try args.levels("levels"), bodyContains: try args.string("body_contains") ?? "",
                                            limit: try args.int("limit", default: 50, in: 1...Self.maxLogs))
            case "find_problems":
                return try await findProblems(limit: try args.int("limit", default: 50, in: 1...Self.maxTraces),
                                              sinceMinutes: try args.optionalInt("since_minutes", in: 1...525_600))
            case "compare_traces":
                return try await compareTraces(id: try args.required("trace_id"), baselineID: try args.string("baseline_trace_id"),
                                               maxRows: try args.int("max_rows", default: 200, in: 1...Self.maxComparisonRows))
            default:
                throw MCPInvalidParams("There is no tool named \(name).")
            }
        } catch let error as MCPInvalidParams {
            throw error
        } catch let error as StoreError {
            return .error(Self.sentence(for: error))
        } catch let error as ToolProblem {
            return .error(error.message)
        } catch {
            return .error("Magnife could not read its database: \(error).")
        }
    }

    /// A problem the agent should read as the tool's answer (an unknown trace).
    struct ToolProblem: Error {
        var message: String
    }

    static func sentence(for error: StoreError) -> String {
        switch error {
        case .missing:
            "Magnife has not stored any telemetry yet. Open Magnife and point your service at localhost:4317 (gRPC) or localhost:4318 (HTTP)."
        case .notReady:
            "Magnife's database is not ready yet. Open Magnife once so its receiver can open the database, then try again."
        case .unsupportedVersion(let found, let expected):
            "The database was written by another version of Magnife (schema \(found), this reader knows \(expected)). Update Magnife."
        case .cannotOpen(let reason):
            "Magnife could not open its database: \(reason)."
        }
    }

    // MARK: list_services

    func listServices() async throws -> MCPToolResult {
        let reader = try await store.open()
        let services = try await reader.services()
        guard !services.isEmpty else { return MCPToolResult("No services yet: Magnife has not received any spans.") }
        let traceCount = try await reader.traceCount()
        var text = "\(CountFormat.string(services.count)) \(services.count == 1 ? "service" : "services"), \(CountFormat.string(traceCount)) traces stored:\n"
        for service in services.sorted(by: { $0.lastSeenNs > $1.lastSeenNs }) {
            let errors = service.errorCount == 0 ? "no errors" : "\(CountFormat.string(service.errorCount)) error \(service.errorCount == 1 ? "span" : "spans")"
            text += "- \(service.name): last seen \(time(service.lastSeenNs)), \(errors)\n"
        }
        return MCPToolResult(text)
    }

    // MARK: list_traces

    func listTraces(query: String, limit: Int, sinceMinutes: Int?) async throws -> MCPToolResult {
        let reader = try await store.open()
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var traces: [TraceSummary]
        var total: Int?
        var header: String
        if text.isEmpty {
            let page = try await reader.tracePage(limit: limit, filter: TraceFilter())
            traces = page.traces
            total = page.traceCount
            header = "Newest traces"
        } else {
            let parsed = TraceQuery(text)
            let result = try await reader.searchTraces(parsed, limit: limit)
            traces = result.traces
            if result.isNewest {
                total = nil
            } else if let counted = result.total {
                total = counted
            } else {
                total = try? await reader.searchCount(parsed)
            }
            let words = parsed.tokens.map(\.spokenText)
            header = "Traces where " + (words.isEmpty ? "any field contains \"\(text)\"" : words.joined(separator: " and "))
        }
        if let sinceMinutes {
            let cutoff = cutoffNs(minutes: sinceMinutes)
            traces = traces.filter { $0.startNs >= cutoff }
            header += ", started in the last \(sinceMinutes) min"
        }
        guard !traces.isEmpty else { return MCPToolResult("\(header): none.") }
        let badges = try await reader.findingSummaries(traceIDs: traces.map(\.traceID))
        var out = "\(header), newest first: \(traces.count) shown"
        if let total, total > traces.count, sinceMinutes == nil { out += " of \(CountFormat.string(total))" }
        out += ".\n"
        for trace in traces { out += "- " + traceLine(trace, findings: badges[trace.traceID]) + "\n" }
        return MCPToolResult(out)
    }

    func traceLine(_ trace: TraceSummary, findings: FindingSummary?) -> String {
        var parts = [trace.traceID, trace.rootService, trace.route.isEmpty ? "(no route)" : trace.route,
                     DurationFormat.string(nanoseconds: trace.durationNs),
                     "\(CountFormat.string(trace.spanCount)) \(trace.spanCount == 1 ? "span" : "spans")", trace.status.title]
        if trace.errorCount > 0 { parts.append("\(CountFormat.string(trace.errorCount)) error \(trace.errorCount == 1 ? "span" : "spans")") }
        if let findings, !findings.isEmpty {
            parts.append("findings: " + findings.kinds.map { "\($0.title) ×\(findings.counts[$0] ?? 0)" }.joined(separator: ", "))
        }
        parts.append("started \(time(trace.startNs))")
        return parts.joined(separator: " · ")
    }

    // MARK: get_trace

    func resolveTrace(_ id: String, reader: TelemetryReader) async throws -> TraceSummary {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !id.isEmpty else { throw MCPInvalidParams("trace_id is empty.") }
        if let trace = try await reader.trace(id: id) { return trace }
        guard id.count >= 8, id.allSatisfy(\.isHexDigit) else {
            throw ToolProblem(message: "No stored trace has the id \(id). Trace ids are 32 hex characters; list_traces shows them.")
        }
        let matches = try await reader.searchTraces(TraceQuery(id), limit: 5).traces.filter { $0.traceID.hasPrefix(id) }
        switch matches.count {
        case 0: throw ToolProblem(message: "No stored trace has an id that starts with \(id). It may have been pruned (retention).")
        case 1: return matches[0]
        default:
            throw ToolProblem(message: "Several traces start with \(id): \(matches.map(\.traceID).joined(separator: ", ")). Give more of the id.")
        }
    }

    func getTrace(id: String, maxSpans: Int) async throws -> MCPToolResult {
        let reader = try await store.open()
        let summary = try await resolveTrace(id, reader: reader)
        // One snapshot, as the window reads it: the findings never name a span the tree lacks.
        let read = try await reader.openTrace(traceID: summary.traceID)
        let trace = read.trace ?? summary
        let tree = await Waterfall.build(read.spans)
        let findings = try await reader.placedFindings(read.findings, in: tree, trace: read.trace, traceID: trace.traceID)
        let errorIDs = read.spans.filter { $0.status == .error }.map(\.spanID)
        let messages = try await reader.statusMessages(traceID: trace.traceID, spanIDs: errorIDs)
        let logCount = try await reader.logStamp(traceID: trace.traceID).count

        var out = "Trace \(trace.traceID)\n"
        out += "Root service: \(trace.rootService) · Route: \(trace.route.isEmpty ? "(none)" : trace.route) · "
        out += "Duration: \(DurationFormat.string(nanoseconds: trace.durationNs)) · Spans: \(CountFormat.string(trace.spanCount)) · "
        out += "Status: \(trace.status.title)"
        if trace.errorCount > 0 { out += " (\(CountFormat.string(trace.errorCount)) error \(trace.errorCount == 1 ? "span" : "spans"))" }
        out += "\nStarted: \(time(trace.startNs))\n"
        let services = Set(read.spans.map(\.serviceName)).sorted()
        out += "Services: \(services.joined(separator: ", "))\n"
        out += "Logs: \(CountFormat.string(logCount))" + (logCount > 0 ? " (search_logs with this trace_id reads them)\n" : "\n")

        out += findingsText(findings)

        // Exceptions: the first error spans' events (most traces have a handful).
        var exceptions = ""
        for spanID in errorIDs.prefix(Self.maxExceptionSpans) {
            guard let span = try await reader.span(traceID: trace.traceID, spanID: spanID) else { continue }
            for exception in span.exceptions {
                exceptions += "- \(exception.type.isEmpty ? "Exception" : exception.type): \(Self.cut(exception.message, Self.maxValue)) "
                exceptions += "(span \(span.spanID), \(span.name)); get_span shows the stack trace\n"
            }
        }
        if !exceptions.isEmpty { out += "\nExceptions:\n" + exceptions }

        let marks = Dictionary(grouping: findings.findings.flatMap { finding in finding.spanIDs.map { ($0, finding.kind.title) } },
                               by: \.0).mapValues { Array(Set($0.map(\.1))).sorted() }
        let rows = tree.visibleRows(collapsed: [])
        out += "\nSpans (\(CountFormat.string(rows.count))), as a tree; offsets from the trace's start:\n"
        for index in rows.prefix(maxSpans) {
            let node = tree.nodes[index]
            let span = node.span
            var line = String(repeating: "  ", count: min(node.depth, 24)) + "- \(span.name)"
            line += " · \(span.serviceName) · \(span.kind.title) · \(DurationFormat.string(nanoseconds: span.durationNs))"
            let offset = max(0, span.startNs - tree.startNs)
            line += " · +" + (offset == 0 ? "0 ms" : DurationFormat.string(nanoseconds: offset))
            if span.status == .error {
                let message = messages[span.spanID] ?? ""
                line += " · Error" + (message.isEmpty ? "" : ": \(Self.cut(Self.oneLine(message), 300))")
            }
            if let kinds = marks[span.spanID] { line += " · finding: \(kinds.joined(separator: ", "))" }
            if node.isOrphan { line += " · parent \(span.parentSpanID ?? "") not received" }
            line += " · span \(span.spanID)"
            out += line + "\n"
        }
        if rows.count > maxSpans {
            out += "… \(CountFormat.string(rows.count - maxSpans)) more spans not shown (max_spans is \(maxSpans)).\n"
        }
        return MCPToolResult(out)
    }

    func findingsText(_ findings: TraceFindings) -> String {
        guard !findings.isEmpty else { return "\nFindings: none (no slow SQL, N+1 or failed HTTP call).\n" }
        var out = "\nFindings (\(findings.findings.count)):\n"
        for finding in findings.findings {
            let place = findings.place(for: finding)
            let spans = finding.spanIDs.count == 1 ? "span \(finding.spanIDs[0])"
                : "spans \(finding.spanIDs.prefix(10).joined(separator: ", "))" + (finding.spanIDs.count > 10 ? ", …" : "")
            out += "- \(finding.kind.title): \(Self.cut(finding.detailText(in: place), Self.maxValue)) (\(spans))\n"
            out += Self.statementText(finding)
        }
        return out
    }

    // MARK: compare_traces

    func compareTraces(id: String, baselineID: String?, maxRows: Int) async throws -> MCPToolResult {
        let reader = try await store.open()
        let traceB = try await resolveTrace(id, reader: reader)
        let traceA: TraceSummary
        var picked = ""
        if let baselineID, !baselineID.trimmingCharacters(in: .whitespaces).isEmpty {
            traceA = try await resolveTrace(baselineID, reader: reader)
        } else {
            let candidates = try await reader.sameRoute(as: traceB, limit: Self.baselineCandidates)
            guard let fastest = candidates.min(by: { ($0.durationNs, $1.startNs) < ($1.durationNs, $0.startNs) }) else {
                throw ToolProblem(message: "No other stored trace of \(traceB.rootService) has the route \(traceB.route.isEmpty ? "(none)" : traceB.route), so there is no baseline to pick. Give baseline_trace_id (list_traces shows ids).")
            }
            traceA = fastest
            picked = candidates.count == 1
                ? "A is the only other stored \(traceB.route) trace of \(traceB.rootService); give baseline_trace_id for another.\n"
                : "A is the fastest of the \(CountFormat.string(candidates.count)) newest other \(traceB.route) traces of \(traceB.rootService); give baseline_trace_id for another.\n"
        }
        guard traceA.traceID != traceB.traceID else {
            throw ToolProblem(message: "trace_id and baseline_trace_id are the same trace; give two different traces.")
        }
        let read = try await reader.comparison(traceA: traceA.traceID, traceB: traceB.traceID)
        let c = await TraceComparison.build(read)

        var out = "Comparing B with A (the baseline):\n"
        out += "A: " + traceLine(read.traceA ?? traceA, findings: nil) + "\n"
        out += "B: " + traceLine(read.traceB ?? traceB, findings: nil) + "\n"
        out += picked
        out += c.totalSentence + "\n"
        if c.hasLittleInCommon { out += c.littleInCommonText + "\n" }

        if c.differences.isEmpty {
            out += "\nDifferences: none. " + TraceComparison.noDifferencesText + "\n"
        } else {
            out += "\nDifferences (\(CountFormat.string(c.differences.count))), Error first, then by the time each explains:\n"
            for difference in c.differences.prefix(Self.maxDifferences) {
                out += "- \(c.line(difference)): \(c.detailText(difference))\(spanIDs(c, difference.row))\n"
            }
            if c.differences.count > Self.maxDifferences {
                out += "… \(CountFormat.string(c.differences.count - Self.maxDifferences)) more differences not shown.\n"
            }
        }

        if !c.queries.isEmpty {
            out += "\nQueries (\(CountFormat.string(c.queries.count))), runs and duration in A → B:\n"
            for query in c.queries.prefix(Self.maxDifferences) {
                out += "- \(query.service) · \(TraceComparison.runsText(query)) runs · \(TraceComparison.durationText(query)) · "
                out += Self.cut(Self.oneLine(query.statement), Self.maxValue) + "\n"
            }
            if c.queries.count > Self.maxDifferences {
                out += "… \(CountFormat.string(c.queries.count - Self.maxDifferences)) more statements not shown.\n"
            }
        }

        // The rows that differ and the rows above them; a group's runs stay one row.
        let groups = Set(c.rows.lazy.filter(\.isGroup).map(\.id))
        let rows = c.visibleRows(collapsed: groups).filter { c.rows[$0].differs || c.rows[$0].differsBelow }
        if !rows.isEmpty {
            out += "\nSpans that differ, as a tree (A → B, then the change):\n"
            for index in rows.prefix(maxRows) {
                let row = c.rows[index]
                var line = String(repeating: "  ", count: min(row.depth, 24)) + "- \(row.title) · \(row.service)"
                line += " · \(c.durationText(of: index, inA: true)) → \(c.durationText(of: index, inA: false))"
                line += " · \(c.changeText(of: index))"
                if row.statusChanged { line += " · \((row.aStatus ?? .unset).title) → \((row.bStatus ?? .unset).title)" }
                out += line + spanIDs(c, index) + "\n"
            }
            if rows.count > maxRows {
                out += "… \(CountFormat.string(rows.count - maxRows)) more rows not shown (max_rows is \(maxRows)).\n"
            }
        }
        return MCPToolResult(out)
    }

    /// " (span A 1a2b…, span B 3c4d…)": get_span reads either.
    func spanIDs(_ c: TraceComparison, _ index: Int) -> String {
        guard !c.rows[index].isGroup else { return "" }
        let ids = [c.spanID(of: index, inA: true).map { "span A \($0)" }, c.spanID(of: index, inA: false).map { "span B \($0)" }]
            .compactMap { $0 }
        return ids.isEmpty ? "" : " (" + ids.joined(separator: ", ") + ")"
    }

    // MARK: get_span

    func getSpan(traceID: String, spanID: String) async throws -> MCPToolResult {
        let reader = try await store.open()
        let trace = try await resolveTrace(traceID, reader: reader)
        let spanID = spanID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let detail = try await reader.spanDetail(traceID: trace.traceID, spanID: spanID) else {
            throw ToolProblem(message: "Trace \(trace.traceID) has no span \(spanID); get_trace lists its span ids.")
        }
        let span = detail.span
        var out = "Span \(span.spanID) of trace \(span.traceID)\n"
        out += "Name: \(span.name) · Service: \(span.serviceName) · Kind: \(span.kind.title) · "
        out += "Duration: \(DurationFormat.string(nanoseconds: span.durationNs)) · Status: \(span.status.title)\n"
        if !span.statusMessage.isEmpty { out += "Status message: \(Self.cut(span.statusMessage, Self.maxValue))\n" }
        out += "Started: \(time(span.startNs))\n"
        out += "Parent: \(span.parentSpanID.map { "span \($0)" } ?? "none (a root span)")\n"
        if !span.scopeName.isEmpty { out += "Instrumentation scope: \(span.scopeName)\(span.scopeVersion.isEmpty ? "" : " \(span.scopeVersion)")\n" }

        out += Self.attributesText("Attributes", detail.attributes)
        if !detail.exceptions.isEmpty {
            out += "\nExceptions:\n"
            for exception in detail.exceptions {
                out += "- \(exception.type.isEmpty ? "Exception" : exception.type) at \(time(exception.timeNs)): \(Self.cut(exception.message, Self.maxValue))\n"
                if !exception.stackTrace.isEmpty {
                    out += "  Stack trace:\n" + Self.indent(Self.cut(exception.stackTrace, Self.maxStack), by: "    ") + "\n"
                }
                for attribute in exception.attributes {
                    out += "  \(attribute.key): \(Self.cut(attribute.value.text, Self.maxValue))\n"
                }
            }
        }
        if !detail.events.isEmpty {
            out += "\nEvents:\n"
            for event in detail.events {
                out += "- \(event.name) at +\(DurationFormat.string(nanoseconds: max(0, event.timeNs - span.startNs)))\n"
                for attribute in event.attributes.pairs { out += "  \(attribute.key): \(Self.cut(attribute.value.text, Self.maxValue))\n" }
            }
        }
        if !span.links.isEmpty {
            out += "\nLinks:\n"
            for link in span.links { out += "- trace \(link.traceID), span \(link.spanID)\n" }
        }
        out += Self.attributesText("Resource attributes", detail.resourceAttributes)
        if !detail.logs.isEmpty {
            out += "\nLogs (\(detail.logs.count)), oldest first:\n"
            for line in detail.logs.prefix(Self.maxLogs) { out += "- " + logText(line.record, ids: false) + "\n" }
            if detail.logs.count > Self.maxLogs { out += "… \(detail.logs.count - Self.maxLogs) more logs not shown.\n" }
        }
        return MCPToolResult(out)
    }

    /// Slow SQL and N+1: the statement (N+1: normalized, `?` for values), which the sentence leaves out.
    static func statementText(_ finding: Finding) -> String {
        guard let statement = finding.statement, !statement.isEmpty else { return "" }
        let label = finding.kind == .nPlusOne ? "Repeated statement" : "Statement"
        return "  \(label)\(finding.dbSystem.map { $0.isEmpty ? "" : " (\($0))" } ?? ""): \(cut(oneLine(statement), maxValue))\n"
    }

    static func attributesText(_ title: String, _ attributes: [Attribute]) -> String {
        guard !attributes.isEmpty else { return "" }
        var out = "\n\(title):\n"
        for attribute in attributes { out += "- \(attribute.key): \(cut(attribute.value.text, maxValue))\n" }
        return out
    }

    // MARK: search_logs

    func searchLogs(traceID: String?, service: String?, levels: Set<SeverityLevel>, bodyContains: String,
                    limit: Int) async throws -> MCPToolResult {
        let reader = try await store.open()
        if let traceID, !traceID.trimmingCharacters(in: .whitespaces).isEmpty {
            let trace = try await resolveTrace(traceID, reader: reader)
            let needle = bodyContains.lowercased()
            let lines = try await reader.traceLogs(traceID: trace.traceID).lines.filter { line in
                (service.map { line.record.serviceName == $0 } ?? true)
                    && (levels.isEmpty || line.record.level.map(levels.contains) == true)
                    && (needle.isEmpty || line.record.body.lowercased().contains(needle))
            }
            guard !lines.isEmpty else { return MCPToolResult("Trace \(trace.traceID) has no logs that match.") }
            var out = "Logs of trace \(trace.traceID), oldest first: \(min(lines.count, limit)) shown of \(CountFormat.string(lines.count)).\n"
            for line in lines.prefix(limit) { out += "- " + logText(line.record, ids: true) + "\n" }
            return MCPToolResult(out)
        }
        let filter = LogFilter(service: service, levels: levels, bodyContains: bodyContains)
        let page = try await reader.logPage(limit: limit, filter: filter)
        var scope: [String] = []
        if let service { scope.append("service is \(service)") }
        if !levels.isEmpty { scope.append("level is " + levels.sorted().map(\.title).joined(separator: " or ")) }
        if !bodyContains.isEmpty { scope.append("body contains \"\(bodyContains)\"") }
        let header = scope.isEmpty ? "Newest logs" : "Logs where " + scope.joined(separator: " and ")
        guard !page.items.isEmpty else { return MCPToolResult("\(header): none.") }
        var out = "\(header), newest first: \(page.items.count) shown of \(CountFormat.string(page.logCount)).\n"
        for item in page.items { out += "- " + logText(item.record, ids: true) + "\n" }
        return MCPToolResult(out)
    }

    func logText(_ log: LogRecord, ids: Bool) -> String {
        let level = log.level?.title ?? (log.severityText.isEmpty ? "—" : log.severityText)
        var out = "\(time(log.timeNs, relative: false)) \(level) \(log.serviceName): \(Self.cut(Self.oneLine(log.body), Self.maxValue))"
        if ids {
            if let traceID = log.traceID, !traceID.isEmpty { out += " (trace \(traceID)" + (log.spanID.map { $0.isEmpty ? "" : ", span \($0)" } ?? "") + ")" }
        } else if !log.attributes.pairs.isEmpty {
            out += " {" + log.attributes.pairs.prefix(20).map { "\($0.key): \(Self.cut($0.value.text, 200))" }.joined(separator: ", ") + "}"
        }
        return out
    }

    // MARK: find_problems

    func findProblems(limit: Int, sinceMinutes: Int?) async throws -> MCPToolResult {
        let reader = try await store.open()
        var traces = try await reader.tracePage(limit: limit, filter: TraceFilter()).traces
        var scope = "the \(traces.count) newest traces"
        if let sinceMinutes {
            let cutoff = cutoffNs(minutes: sinceMinutes)
            traces = traces.filter { $0.startNs >= cutoff }
            scope = "the \(traces.count) traces of the last \(sinceMinutes) min (of the \(limit) newest)"
        }
        guard !traces.isEmpty else { return MCPToolResult("No traces to look at: \(scope).") }
        let badges = try await reader.findingSummaries(traceIDs: traces.map(\.traceID))
        var withFindings = ""
        var count = 0
        for trace in traces where !(badges[trace.traceID]?.isEmpty ?? true) {
            let read = try await reader.openTrace(traceID: trace.traceID)
            let tree = await Waterfall.build(read.spans)
            let findings = try await reader.placedFindings(read.findings, in: tree, trace: read.trace, traceID: trace.traceID)
            guard !findings.isEmpty else { continue }
            count += 1
            withFindings += "\n" + traceLine(read.trace ?? trace, findings: findings.summary) + "\n"
            for finding in findings.findings {
                let place = findings.place(for: finding)
                withFindings += "- \(finding.kind.title): \(Self.cut(finding.detailText(in: place), Self.maxValue)) (span \(finding.spanIDs.first ?? ""))\n"
                withFindings += Self.statementText(finding)
            }
        }
        let failed = traces.filter { $0.status == .error && (badges[$0.traceID]?.isEmpty ?? true) }
        var out = "Looked at \(scope): \(count) with findings, \(failed.count) failed without a finding.\n"
        if count == 0 && failed.isEmpty { out += "No slow SQL, N+1 queries, failed HTTP calls or failed traces.\n" }
        out += withFindings
        if !failed.isEmpty {
            out += "\nFailed traces with no finding (get_trace shows the error spans and exceptions):\n"
            for trace in failed { out += "- " + traceLine(trace, findings: nil) + "\n" }
        }
        return MCPToolResult(out)
    }

    // MARK: Words

    func cutoffNs(minutes: Int) -> Int64 {
        Int64((now().timeIntervalSince1970 - Double(minutes) * 60) * 1_000_000_000)
    }

    /// "2026-11-05 14:02:31.204 (2 min ago)", local time.
    func time(_ ns: Int64, relative: Bool = true) -> String {
        let date = Date(nanoseconds: ns)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        // Whole seconds through Date, milliseconds from the integer: a Double this large rounds .010 to .009.
        let (seconds, rest) = ns.quotientAndRemainder(dividingBy: 1_000_000_000)
        let wholeSeconds = rest < 0 ? seconds - 1 : seconds
        let ms = Int(((rest % 1_000_000_000) + 1_000_000_000) % 1_000_000_000 / 1_000_000)
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                        from: Date(timeIntervalSince1970: TimeInterval(wholeSeconds)))
        let stamp = String(format: "%04d-%02d-%02d %02d:%02d:%02d.%03d", c.year ?? 0, c.month ?? 0, c.day ?? 0,
                           c.hour ?? 0, c.minute ?? 0, c.second ?? 0, ms)
        return relative ? "\(stamp) (\(Self.ago(now().timeIntervalSince(date))))" : stamp
    }

    static func ago(_ seconds: TimeInterval) -> String {
        if seconds < 5 { return "just now" }
        if seconds < 60 { return "\(Int(seconds)) s ago" }
        if seconds < 3_600 { return "\(Int(seconds / 60)) min ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600)) h ago" }
        return "\(Int(seconds / 86_400)) d ago"
    }

    /// The text, cut at `limit` characters with how many were left out.
    static func cut(_ text: String, _ limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "… (\(CountFormat.string(text.count - limit)) more characters)"
    }

    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ⏎ ")
    }

    static func indent(_ text: String, by prefix: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { prefix + $0 }.joined(separator: "\n")
    }
}

/// A tool call's arguments, read with the checks docs/mcp.md lists.
struct MCPArguments {
    let values: [String: JSONValue]

    init(_ values: [String: JSONValue]) {
        self.values = values
    }

    func string(_ key: String) throws(MCPInvalidParams) -> String? {
        switch values[key] {
        case nil, .null?: return nil
        case .string(let value)?: return value
        default: throw MCPInvalidParams("\(key) must be a string.")
        }
    }

    func required(_ key: String) throws(MCPInvalidParams) -> String {
        guard let value = try string(key), !value.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw MCPInvalidParams("\(key) is required.")
        }
        return value
    }

    func optionalInt(_ key: String, in range: ClosedRange<Int>) throws(MCPInvalidParams) -> Int? {
        let number: Int
        switch values[key] {
        case nil, .null?: return nil
        case .number?:
            guard let value = values[key]?.intValue else { throw MCPInvalidParams("\(key) must be a whole number.") }
            number = value
        // Some clients send numbers as strings.
        case .string(let text)?:
            guard let value = Int(text.trimmingCharacters(in: .whitespaces)) else { throw MCPInvalidParams("\(key) must be a whole number.") }
            number = value
        default: throw MCPInvalidParams("\(key) must be a whole number.")
        }
        guard range.contains(number) else {
            throw MCPInvalidParams("\(key) must be from \(range.lowerBound) to \(range.upperBound), not \(number).")
        }
        return number
    }

    func int(_ key: String, default value: Int, in range: ClosedRange<Int>) throws(MCPInvalidParams) -> Int {
        try optionalInt(key, in: range) ?? value
    }

    /// Level words: trace, debug, info, warn (or warning), error, fatal; any case.
    func levels(_ key: String) throws(MCPInvalidParams) -> Set<SeverityLevel> {
        let words: [String]
        switch values[key] {
        case nil, .null?: return []
        case .string(let text)?: words = text.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
        case .array(let items)?:
            var collected: [String] = []
            for item in items {
                guard let word = item.stringValue else { throw MCPInvalidParams("\(key) must be a list of level words.") }
                collected.append(word)
            }
            words = collected
        default: throw MCPInvalidParams("\(key) must be a list of level words.")
        }
        var levels = Set<SeverityLevel>()
        for word in words {
            let lowered = word.lowercased() == "warning" ? "warn" : word.lowercased()
            guard let level = SeverityLevel.allCases.first(where: { $0.title.lowercased() == lowered }) else {
                throw MCPInvalidParams("\(word) is not a level; use trace, debug, info, warn, error or fatal.")
            }
            levels.insert(level)
        }
        return levels
    }
}
