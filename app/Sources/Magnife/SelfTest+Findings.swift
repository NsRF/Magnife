import AppKit
import MagnifeKit

/// The detectors in the real app (S-023, S-024+): the seed set's findings in the
/// reader, the list's badges, the waterfall's icons, the strip and the span
/// detail; a trace that gains a finding while it is open; and the detectors'
/// cost on 12,000 and 300,000 spans and on the 100,000-span store.
extension SelfTest {
    static func checkFindings(_ model: AppModel) async {
        model.sidebar = .allTraces
        model.selectedTraceID = nil
        await model.reload()
        await checkSeedFindings(model)
        await checkFindingViews(model)
        await checkNPlusOne(model)
        await checkLiveFinding(model)
        await checkDetectorCost()
        model.selectedTraceID = nil
    }

    /// The seed trace with this route, wherever it is in the store.
    private static func findingTrace(_ model: AppModel, route: String) async -> TraceSummary? {
        try? await model.reader?.latestTraces(limit: 5_000).first { $0.route == route }
    }

    private static func checkSeedFindings(_ model: AppModel) async {
        guard let reader = model.reader, let slow = await findingTrace(model, route: "GET /admin/reports"),
              let job = await findingTrace(model, route: "inventory.reconcile"),
              let healthy = await findingTrace(model, route: "GET /checkout") else {
            return check("the seed set's traces are stored", false)
        }
        let findings = (try? await reader.traceFindings(traceID: slow.traceID)) ?? TraceFindings()
        check("S-023: the 851 ms report query is Slow SQL, and nothing else in its trace",
              findings.findings.map(\.kind) == [.slowSQL] && findings.findings.first?.durationNs == 851_000_000,
              "\(findings.findings.map(\.line))")
        check("S-023: the strip line names the duration and the statement",
              findings.findings.first?.line.hasPrefix("Slow SQL · 851 ms · SELECT date_trunc(") == true,
              findings.findings.first?.line ?? "none")
        let jobFindings = (try? await reader.traceFindings(traceID: job.traceID)) ?? TraceFindings()
        check("S-023: the job's 2 s UPDATE is Slow SQL", jobFindings.findings.map(\.kind) == [.slowSQL]
              && jobFindings.findings.first?.statement?.hasPrefix("UPDATE inventory") == true)
        let healthyFindings = (try? await reader.traceFindings(traceID: healthy.traceID)) ?? TraceFindings()
        check("S-023: the healthy trace's queries (4 to 14 ms) are not flagged", healthyFindings.isEmpty,
              "\(healthyFindings.findings.map(\.line))")

        // Earlier checks send hundreds of traces: the seed set may be past the first page.
        let seed = (try? await reader.findingSummaries(traceIDs: [slow.traceID, job.traceID, healthy.traceID])) ?? [:]
        check("S-023: the list's badges: Slow SQL on the report and the job, none on the healthy trace",
              seed[slow.traceID]?.kinds == [.slowSQL] && seed[job.traceID]?.kinds == [.slowSQL]
                && seed[healthy.traceID]?.isEmpty == true)
        check("S-023: the badge's tooltip", seed[slow.traceID]?.help(.slowSQL) == "Slow SQL: 1 query over 100 ms")
        await model.waitForTraceFindings()
        let rows = model.traces
        let read = (try? await reader.findingSummaries(traceIDs: rows.map(\.traceID))) ?? [:]
        check("S-023: every row shown has its badges, as the reader reads them",
              !rows.isEmpty && rows.allSatisfy { model.findingSummary(for: $0) == read[$0.traceID] },
              "\(rows.filter { model.findingSummary(for: $0) != read[$0.traceID] }.map(\.route))")
        check("S-023: every finding icon exists",
              FindingKind.allCases.allSatisfy { NSImage(systemSymbolName: $0.symbol, accessibilityDescription: nil) != nil })
    }

    private static func checkFindingViews(_ model: AppModel) async {
        guard let slow = await findingTrace(model, route: "GET /admin/reports") else { return }
        model.selectedTraceID = nil
        model.selectedTraceID = slow.traceID
        guard await waitUntil(3, { isShown(model) && !model.openTraceFindings.isEmpty }),
              let outline = model.waterfallOutline else {
            return check("S-023: the slow trace opens with its findings", false)
        }
        let waterfall = model.waterfall
        var marked: [String] = []
        var spoken = true
        for row in 0..<outline.numberOfRows {
            guard let item = outline.item(atRow: row) as? SpanItem,
                  let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SpanNameCell else { continue }
            let span = waterfall.nodes[item.index].span
            if cell.shownFindings == [.slowSQL] { marked.append(span.name) }
            if (cell.accessibilityLabel() ?? "").hasSuffix(", Slow SQL") != (cell.shownFindings == [.slowSQL]) { spoken = false }
        }
        check("S-023: only the slow query's row shows the Slow SQL icon", marked == ["SELECT Orders"], "\(marked)")
        check("S-023: VoiceOver reads \"Slow SQL\" on that row", spoken)

        guard let finding = model.openTraceFindings.findings.first else { return }
        model.selectedSpanID = waterfall.rootSpanID
        model.showSpanDetailTab(.traceLogs)
        model.showsSpanDetail = false
        model.selectFinding(finding)
        let opened = await waitUntil(2) { model.spanDetail?.span.spanID == finding.spanIDs.first }
        check("S-023: a strip line selects its span and opens its span detail on Span",
              opened && model.selectedSpanID == finding.spanIDs.first && model.showsSpanDetail && model.spanDetailTab == .span)
        check("S-023: the span detail lists the finding",
              model.openTraceFindings.findings(forSpan: model.selectedSpanID ?? "").map(\.detailText)
                == ["This query took 851 ms. Queries over 100 ms are flagged."])
    }

    /// S-024: the seed set's 8 identical SELECTs under the orders server span.
    private static func checkNPlusOne(_ model: AppModel) async {
        guard let reader = model.reader, let trace = await findingTrace(model, route: "GET /account/orders") else {
            return check("S-024: the N+1 seed trace is stored", false)
        }
        let findings = (try? await reader.traceFindings(traceID: trace.traceID)) ?? TraceFindings()
        let finding = findings.findings.first
        check("S-024: one N+1 finding for the 8 order_items queries, and nothing else",
              findings.findings.map(\.kind) == [.nPlusOne] && finding?.count == 8 && finding?.spanIDs.count == 8,
              "\(findings.findings.map(\.line))")
        check("S-024: it names the normalized statement and the count",
              finding?.line == "N+1 · 8 times · SELECT * FROM order_items WHERE order_id = ?", finding?.line ?? "none")
        let summary = (try? await reader.findingSummaries(traceIDs: [trace.traceID]))?[trace.traceID]
        check("S-024: the row's badge and tooltip", summary?.kinds == [.nPlusOne]
              && summary?.help(.nPlusOne) == "N+1: a statement ran 8 times")

        model.selectedTraceID = nil
        model.selectedTraceID = trace.traceID
        guard let finding, await waitUntil(3, { isShown(model) && !model.openTraceFindings.isEmpty }),
              let outline = model.waterfallOutline else {
            return check("S-024: the N+1 trace opens with its finding", false)
        }
        var marked: [String] = []
        var labels: [String] = []
        for row in 0..<outline.numberOfRows {
            guard let item = outline.item(atRow: row) as? SpanItem,
                  let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SpanNameCell,
                  cell.shownFindings == [.nPlusOne] else { continue }
            marked.append(model.waterfall.nodes[item.index].span.spanID)
            labels.append(cell.accessibilityLabel() ?? "")
        }
        check("S-024: every repeated span shows the N+1 icon", marked.sorted() == finding.spanIDs.sorted(), "\(marked.count) rows")
        check("S-024: VoiceOver reads \"N+1, 1 of 8\" on the first",
              labels.first?.hasSuffix(", N+1, 1 of 8") == true && labels.last?.hasSuffix(", N+1, 8 of 8") == true,
              labels.first ?? "none")
        model.selectFinding(finding)
        let opened = await waitUntil(2) { model.spanDetail?.span.spanID == finding.spanIDs.first }
        check("S-024: the strip line selects the first of those spans", opened && model.selectedSpanID == finding.spanIDs.first)
    }

    /// A trace still receiving spans gains its badge in place (docs/ux.md, S-023 States).
    private static func checkLiveFinding(_ model: AppModel) async {
        guard let port = ProcessInfo.processInfo.environment["APP_SEED_HTTP"]?.split(separator: ":").last.flatMap({ Int($0) }),
              let reader = model.reader else {
            return check("APP_SEED_HTTP names the seed helper (tools/selftest.sh)", false)
        }
        let trace = "f1ad1e57000000000000000000000023"
        let root = "f1ad1e5700002301"
        let start = UInt64(Date().timeIntervalSince1970 * 1e9)
        _ = await post(port: port, path: "/v1/traces", body: findingSpan(trace: trace, span: root, parent: nil,
                                                                       name: "GET /live", start: start, ms: 400))
        guard await waitForTrace(reader, trace, spans: 1) else { return check("S-023: the live trace is stored", false) }
        await model.reload()
        model.selectedTraceID = trace
        _ = await waitUntil(3) { isShown(model) }
        await model.waitForTraceFindings()
        let before = model.traces.first { $0.traceID == trace }.flatMap { model.findingSummary(for: $0) }
        _ = await post(port: port, path: "/v1/traces", body: findingSpan(trace: trace, span: "f1ad1e5700002302", parent: root,
                                                                       name: "SELECT live", start: start + 1_000_000, ms: 300,
                                                                       db: "SELECT * FROM live WHERE id = 1"))
        guard await waitForTrace(reader, trace, spans: 2) else { return check("S-023: the late span is stored", false) }
        await model.reload()
        await model.waitForTraceFindings()
        let after = model.traces.first { $0.traceID == trace }.flatMap { model.findingSummary(for: $0) }
        let strip = await waitUntil(2) { model.openTraceFindings.findings.map(\.kind) == [.slowSQL] }
        check("S-023: a late slow span adds the badge in place, and the open trace's strip",
              before?.isEmpty == true && after?.kinds == [.slowSQL] && strip,
              "before \(before?.kinds ?? []), after \(after?.kinds ?? [])")
    }

    private static func waitForTrace(_ reader: TelemetryReader, _ trace: String, spans: Int) async -> Bool {
        for _ in 0..<50 {
            if let row = try? await reader.trace(id: trace), row.spanCount == spans { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    /// One OTLP/JSON span; a database span when `db` names a statement.
    static func findingSpan(trace: String, span: String, parent: String?, name: String, start: UInt64, ms: UInt64,
                            db: String? = nil, attributes extra: [String] = [], status: Int = 0) -> String {
        var attributes = extra
        if let db {
            attributes += [#"{"key":"db.system","value":{"stringValue":"postgresql"}}"#,
                           #"{"key":"db.statement","value":{"stringValue":"\#(db)"}}"#]
        }
        let parentField = parent.map { #""parentSpanId":"\#($0)","# } ?? ""
        let statusField = status == 0 ? "" : #","status":{"code":\#(status)}"#
        return #"{"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"selftest"}}]},"#
            + #""scopeSpans":[{"spans":[{"traceId":"\#(trace)","spanId":"\#(span)",\#(parentField)"name":"\#(name)","#
            + #""kind":\#(parent == nil ? 2 : 3),"startTimeUnixNano":"\#(start)","endTimeUnixNano":"\#(start + ms * 1_000_000)","#
            + #""attributes":[\#(attributes.joined(separator: ","))]\#(statusField)}]}]}]}"#
    }

    /// The detectors' cost (release build): pure runs on 12,000 spans in
    /// 200 traces and on one 300,000-span trace, and the list's read of the
    /// newest 200 traces on the 100,000-span store.
    private static func checkDetectorCost() async {
        let small = DetectorLoad.spans(count: 12_000, traces: 200)
        let large = DetectorLoad.spans(count: 300_000, traces: 1)
        let smallTime = await DetectorLoad.time { _ = Detectors.findingsByTrace(small) }
        let largeTime = await DetectorLoad.time { _ = Detectors.findings(in: large) }
        print("INFO detectors: 12,000 spans in 200 traces \(String(format: "%.1f", smallTime)) ms, "
              + "300,000 spans in one trace \(String(format: "%.1f", largeTime)) ms")
        check("the detectors take under 50 ms on 12,000 spans and under 1.5 s on 300,000",
              smallTime < 50 && largeTime < 1_500)

        guard let path = ProcessInfo.processInfo.environment["APP_SEARCH_STORE"],
              let reader = try? await TelemetryReader.open(at: URL(fileURLWithPath: path)),
              let page = try? await reader.latestTraces(limit: TraceList.pageSize) else {
            return check("APP_SEARCH_STORE names the 100,000-span store (tools/selftest.sh)", false)
        }
        let ids = page.map(\.traceID)
        var summaries: [String: FindingSummary] = [:]
        let readTime = await DetectorLoad.time { summaries = (try? await reader.findingSummaries(traceIDs: ids)) ?? [:] }
        let flagged = summaries.values.filter { !$0.isEmpty }.count
        print("INFO detectors: the list's badges for 200 traces (\(page.reduce(0) { $0 + $1.spanCount }) spans) of the "
              + "100,000-span store read in \(String(format: "%.1f", readTime)) ms, \(flagged) traces flagged")
        check("the list's badges for a 200-row page read in under 50 ms", readTime < 50 && summaries.count == ids.count)
    }
}

/// Synthetic detector input: a database span in every 4th span (literal
/// values vary, some slow), an HTTP span in every 4th, the rest plain.
enum DetectorLoad {
    static func spans(count: Int, traces: Int) -> [DetectorSpan] {
        (0..<count).map { n in
            let trace = "t\(n % traces)"
            switch n % 4 {
            case 0:
                return DetectorSpan(traceID: trace, spanID: "s\(n)", name: "SELECT items", startNs: Int64(n),
                                    durationNs: n % 40 == 0 ? 150_000_000 : 2_000_000, dbSystem: "postgresql",
                                    dbStatement: "SELECT id, name FROM items WHERE order_id = \(n) AND status = 'open'")
            case 1:
                return DetectorSpan(traceID: trace, spanID: "s\(n)", name: "GET", startNs: Int64(n), durationNs: 1_000_000,
                                    httpMethod: "GET", httpStatusCode: n % 50 == 1 ? 503 : 200, httpURL: "http://api/items/\(n)")
            default:
                return DetectorSpan(traceID: trace, spanID: "s\(n)", name: "work", startNs: Int64(n), durationNs: 1_000)
            }
        }
    }

    /// Milliseconds `work` takes.
    static func time(_ work: () async -> Void) async -> Double {
        let started = ContinuousClock.now
        await work()
        let elapsed = ContinuousClock.now - started
        return Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1_000
    }
}
