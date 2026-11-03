import AppKit
import MagnifeKit

/// S-013: the Logs view in the real window: every log newest first, those
/// without a trace id too; Open Trace to the trace and span; live, holding
/// still when scrolled away, paging, Pause. More logs go to the seed helper
/// that writes the store; arrival time runs on a helper the app started.
extension SelfTest {
    static func checkLogs(_ model: AppModel) async {
        let env = ProcessInfo.processInfo.environment
        guard let http = env["APP_SEED_HTTP"], let reader = model.reader,
              let port = Int(http.split(separator: ":").last ?? "") else {
            return check("APP_SEED_HTTP names the seed helper (tools/selftest.sh)", false)
        }
        model.selectedTraceID = nil
        model.sidebar = .allTraces
        model.showContentMode(.logs)
        await model.reload()
        await checkLogRows(model, reader)
        await checkOpenTrace(model, reader)
        await checkLiveLogs(model, reader, port: port)
        await checkLogArrival()
        model.selectedLogID = nil
        model.showContentMode(.traces)
        await model.reload()
    }

    private static func checkLogRows(_ model: AppModel, _ reader: TelemetryReader) async {
        // The menus follow the switch on a later turn (S-030).
        _ = await waitUntil(1) { MenuState.shared.contentMode == model.contentMode }
        let page = try? await reader.logPage()
        check("the Logs view lists the first page of every log, newest first",
              model.contentMode == .logs && MenuState.shared.contentMode == .logs && !model.logs.isEmpty
                && model.logs.map(\.id) == page?.items.map(\.id)
                && zip(model.logs, model.logs.dropFirst()).allSatisfy { $0.record.timeNs >= $1.record.timeNs },
              "\(model.logs.count) rows")
        check("the subtitle counts the logs", model.subtitle == LogList.subtitle(logCount: page?.logCount ?? -1),
              model.subtitle)
        let row = model.logs.first
        check("a row has time, level, service and body",
              row?.line.time.wholeMatch(of: /\d\d:\d\d:\d\d\.\d\d\d/) != nil && row?.line.levelWord.isEmpty == false
                && row?.record.serviceName.isEmpty == false && row?.record.body.isEmpty == false,
              row?.accessibilityLabel ?? "nil")
        model.sidebar = .service("orders")
        await model.reload()
        let orders = try? await reader.logPage(filter: LogFilter(service: "orders"))
        check("the sidebar's service scopes the Logs view",
              !model.logs.isEmpty && model.logs.allSatisfy { $0.record.serviceName == "orders" }
                && model.logCount == orders?.logCount && model.title == "orders", "\(model.logs.count) rows")
        model.sidebar = .allTraces
        await model.reload()
    }

    /// Opening a log with a trace id opens that trace with the log's span
    /// selected (its parents open), or the root span when it has none.
    private static func checkOpenTrace(_ model: AppModel, _ reader: TelemetryReader) async {
        // Earlier checks add thousands of logs: the seed's may be pages down, so they are found
        // in the store and selected by id (the detail then carries them, as for a row paged out).
        let stored = (try? await reader.logPage(limit: 100_000))?.items ?? []
        guard let log = stored.first(where: { $0.record.body == "Payment for order 1042 was not saved" }),
              let traceID = log.record.traceID, let spanID = log.record.spanID else {
            return check("the seed's payment log is listed", false)
        }
        model.selectedLogID = log.id
        let read = await waitUntil(2) { model.logDetail?.item.id == log.id }
        check("selecting a log reads its detail: Body, Attributes, Resource, Trace",
              read && model.logDetail?.sections == [.body, .attributes, .resource, .trace]
                && model.logDetail?.resourceAttributes.first?.key.hasPrefix("service.") == true,
              "\(model.logDetail?.sections.map(\.rawValue) ?? [])")
        check("Trace > Open Trace is enabled for it", MenuState.shared.canOpenTrace && MenuState.shared.hasSelectedLog)
        model.openSelectedLogTrace()
        let opened = await waitUntil(3) {
            model.contentMode == .traces && model.selectedTraceID == traceID && model.selectedSpanID == spanID
        }
        let ancestors = model.waterfall.ancestors(of: spanID)
        check("Open Trace shows that trace in the Traces view with the log's span selected",
              opened && model.collapsedSpans.isDisjoint(with: ancestors) && !MenuState.shared.canOpenTrace,
              "mode \(model.contentMode), span \(model.selectedSpanID ?? "nil")")

        // A log with the trace id and no span id opens on the root span.
        model.showContentMode(.logs)
        await model.reload()
        model.selectedTraceID = nil
        guard let noSpan = stored.first(where: { $0.canOpenTrace && $0.record.spanID == nil }) else {
            return check("the seed has a log with a trace id and no span id", false)
        }
        model.selectedLogID = noSpan.id
        _ = await waitUntil(2) { model.logDetail?.item.id == noSpan.id }
        model.openTrace(ofLog: noSpan.id)
        let root = await waitUntil(3) {
            model.contentMode == .traces && model.selectedTraceID == noSpan.record.traceID && !model.waterfall.isEmpty
                && model.selectedSpanID == model.waterfall.rootSpanID
        }
        check("a log with no span id opens its trace on the root span", root)

        // A log with no trace id has nothing to open.
        model.showContentMode(.logs)
        await model.reload()
        guard let loose = stored.first(where: { !$0.hasTrace }) else {
            return check("a log without a trace id is listed", false)
        }
        let traceBefore = model.selectedTraceID
        model.selectedLogID = loose.id
        _ = await waitUntil(2) { model.logDetail?.item.id == loose.id }
        model.openSelectedLogTrace()
        check("a log without a trace id has no Trace section and opens nothing",
              model.contentMode == .logs && model.selectedTraceID == traceBefore && !MenuState.shared.canOpenTrace
                && model.logDetail?.sections.contains(.trace) == false)
        model.selectedLogID = nil
    }

    /// Live: new logs at the top; scrolled away the list holds still and
    /// counts them; the end of the list reads the next page; Pause.
    private static func checkLiveLogs(_ model: AppModel, _ reader: TelemetryReader, port: Int) async {
        var sent = 0
        /// Posts `count` web logs with no trace id, newest now, and waits until they are stored.
        func post(_ count: Int) async -> Bool {
            let before = (try? await reader.lastLogID()) ?? 0
            let now = UInt64(Date().timeIntervalSince1970 * 1e9)
            let records = (0..<count).map { n in
                #"{"timeUnixNano":"\#(now + UInt64(n) * 1_000)","severityNumber":9,"body":{"stringValue":"live log \#(sent + n)"}}"#
            }
            sent += count
            let status = await SelfTest.post(port: port, path: "/v1/logs", body: """
                {"resourceLogs":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"web"}}]},
                "scopeLogs":[{"logRecords":[\(records.joined(separator: ","))]}]}]}
                """)
            for _ in 0..<50 where (try? await reader.lastLogID()) ?? 0 < before + Int64(count) {
                try? await Task.sleep(for: .milliseconds(100))
            }
            return status == 200
        }

        let posted = await post(400)
        await model.reload()
        check("at the top, new logs come first, the page is 200 rows",
              posted && model.logs.count == LogList.pageSize && model.hasMoreLogs
                && model.logs.first?.record.body == "live log 399", model.logs.first?.record.body ?? "nil")
        let scroller = model.logScroller
        try? await Task.sleep(for: .milliseconds(300))
        let attached = await waitUntil(3) { scroller.rowCount == model.logs.count }
        check("the Logs list finds its table's scroll view", attached, "\(scroller.rowCount) rows")
        guard attached else { return }

        scroller.scroll(toOffset: 1_200)
        check("scrolling away from the top holds the Logs list", await waitUntil(1) { model.isLogListHeld })
        try? await Task.sleep(for: .milliseconds(300))
        let ids = model.logs.map(\.id)
        let firstRow = scroller.firstVisibleRow
        _ = await post(30)
        await model.reload()
        try? await Task.sleep(for: .milliseconds(300))
        check("while scrolled away, arriving logs leave the rows where they are",
              (firstRow ?? 0) > 0 && model.logs.map(\.id) == ids && scroller.firstVisibleRow == firstRow,
              "row \(firstRow ?? -1) -> \(scroller.firstVisibleRow ?? -1)")
        // SwiftUI retitles the Trace menu's item when the menu opens (PROGRESS decision 49): check what it reads.
        check("\"12 new logs\" counts them, and Trace > Show Newest Logs is enabled",
              model.newLogCount == 30 && model.showsNewLogsButton && MenuState.shared.newTraceCount == 30
                && MenuState.shared.contentMode == .logs,
              "\(model.newLogCount), menu \(MenuState.shared.newTraceCount)")

        // To the end: every page, those without a trace id included.
        for _ in 0..<200 where model.hasMoreLogs {
            scroller.scrollToBottom()
            let count = model.logs.count
            _ = await waitUntil(2) { model.logs.count > count || !model.hasMoreLogs }
        }
        let total = (try? await reader.logPage(limit: 0, upTo: model.logBaseID))?.logCount ?? -1
        let loose = (try? await reader.logPage(limit: 100_000, upTo: model.logBaseID))?.items.filter { !$0.hasTrace }.count
        let rows = model.logs
        check("scrolling to the end reads every log, those without a trace id too",
              rows.count == total && rows.filter { !$0.hasTrace }.count == loose && Set(rows.map(\.id)).count == rows.count
                && zip(rows, rows.dropFirst()).allSatisfy { ($0.record.timeNs, $0.id) > ($1.record.timeNs, $1.id) },
              "\(rows.count) of \(total) rows, \(loose ?? -1) without a trace id")

        model.showNewestLogs()
        let shown = await waitUntil(3) {
            !model.isLogListHeld && model.newLogCount == 0 && model.logs.first?.record.body == "live log 429"
        }
        check("Show Newest Logs scrolls to the top and inserts them",
              shown && scroller.offset <= TraceListScroller.tolerance && MenuState.shared.newTraceCount == 0)

        // Pause holds the Logs list too (S-010).
        try? await Task.sleep(for: .milliseconds(300))
        model.togglePause()
        let held = model.logs
        check("Pause holds the Logs list at the id its rows were read at",
              model.logPausedID == model.logBaseID && model.subtitle.hasPrefix("Paused · "), model.subtitle)
        _ = await post(12)
        await model.reload()
        check("while paused, the Logs list does not change and the bar counts the new logs",
              model.logs == held && model.newLogCount == 12
                && LogList.pausedText(newCount: model.newLogCount) == "Paused. 12 new logs. Magnife is still receiving.")
        model.togglePause()
        let resumed = await waitUntil(3) { model.logPausedID == nil && model.logs.first?.record.body == "live log 441" }
        check("Resume inserts the logs that arrived", resumed && model.newLogCount == 0)
    }

    /// A log reaches the Logs view within 1 second of arriving, with no trace id.
    private static func checkLogArrival() async {
        guard let helper = AppModel.helperExecutable(environment: [:]),
              let sender = ProcessInfo.processInfo.environment["APP_SAMPLE_SENDER"].map(URL.init(fileURLWithPath:)) else {
            return check("the helper and APP_SAMPLE_SENDER exist", false)
        }
        let root = TestRun.scratch("logs")
        try? FileManager.default.removeItem(at: root)
        let model = AppModel(storeURL: root.appending(path: "magnife.sqlite"))
        model.contentMode = .logs
        let ports = (grpc: freePort(), http: freePort())
        model.startReceiver(executable: helper, ports: ports)
        _ = await waitUntil(3) { model.receiver.isReceiving && model.storeState == .ready }
        // Startup logs only: no trace, no span.
        let sent = await run(sender, ["--protocol", "http-protobuf", "--scenarios", "logs",
                                      "--grpc", "127.0.0.1:\(ports.grpc)", "--http", "127.0.0.1:\(ports.http)"])
        let arrived = Date()
        let shown = await waitUntil(2) { !model.logs.isEmpty }
        let elapsed = Date().timeIntervalSince(arrived)
        check("a log without a trace id appears in the Logs view within 1 second",
              sent.status == 0 && shown && elapsed < 1 && model.logs.allSatisfy { !$0.hasTrace },
              "\(String(format: "%.2f", elapsed)) s, \(model.logs.count) logs")
        await model.stopHelperAndWait()
        try? FileManager.default.removeItem(at: root)
    }
}
