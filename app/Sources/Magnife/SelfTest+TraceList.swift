import AppKit
import MagnifeKit

/// S-004: the live trace list. Arrival time with the real helper the way the
/// app starts it; holding still, paging and Show Newest Traces in the real
/// window, with more traces sent to the seed helper that writes the store.
extension SelfTest {
    static func checkTraceList(_ model: AppModel) async {
        checkColorsAndLabels(model)
        await checkArrival()
        await checkHoldStill(model)
    }

    private static func checkColorsAndLabels(_ model: AppModel) {
        let slots = model.services.map { model.serviceColors.slot(for: $0.name) }
        check("each seed service has its own color", Set(slots).count == model.services.count, "\(slots)")
        let byFirstSeen = model.services.sorted { ($0.firstSeenNs, $0.name) < ($1.firstSeenNs, $1.name) }
        check("colors follow the order services were first seen",
              byFirstSeen.map { model.serviceColors.slot(for: $0.name) } == Array(0..<byFirstSeen.count))
        let failed = model.traces.first { $0.route == "POST /checkout/pay" }
        check("VoiceOver reads the HTTP 500 row as service, route, duration, spans, status",
              failed?.accessibilityLabel.hasPrefix("web, POST /checkout/pay, ") == true
                && failed?.accessibilityLabel.hasSuffix(" milliseconds, 5 spans, Error") == true,
              failed?.accessibilityLabel ?? "nil")
    }

    /// A trace reaches the list within 1 second of its spans arriving.
    private static func checkArrival() async {
        guard let helper = AppModel.helperExecutable(environment: [:]),
              let sender = ProcessInfo.processInfo.environment["APP_SAMPLE_SENDER"].map(URL.init(fileURLWithPath:)) else {
            return check("the helper and APP_SAMPLE_SENDER exist", false)
        }
        let root = URL(fileURLWithPath: "/tmp/Magnife-selftest-list")
        try? FileManager.default.removeItem(at: root)
        let model = AppModel(storeURL: root.appending(path: "magnife.sqlite"))
        let ports = (grpc: freePort(), http: freePort())
        model.startReceiver(executable: helper, ports: ports)
        _ = await waitUntil(3) { model.receiver.isReceiving && model.storeState == .ready }
        let sent = await run(sender, ["--protocol", "http-protobuf", "--scenarios", "healthy",
                                      "--grpc", "127.0.0.1:\(ports.grpc)", "--http", "127.0.0.1:\(ports.http)"])
        let arrived = Date()
        let shown = await waitUntil(2) { !model.traces.isEmpty }
        let elapsed = Date().timeIntervalSince(arrived)
        check("a trace appears in the list within 1 second of its spans arriving",
              sent.status == 0 && shown && elapsed < 1, "\(String(format: "%.2f", elapsed)) s, \(sent.output)")
        await model.stopHelperAndWait()
        try? FileManager.default.removeItem(at: root)
    }

    /// Design decision 6: scrolled away from the top, the list holds still
    /// while traces arrive, and "N new traces" counts them.
    private static func checkHoldStill(_ model: AppModel) async {
        let env = ProcessInfo.processInfo.environment
        guard let sender = env["APP_SAMPLE_SENDER"].map(URL.init(fileURLWithPath:)),
              let grpc = env["APP_SEED_GRPC"], let http = env["APP_SEED_HTTP"], let reader = model.reader else {
            return check("APP_SEED_GRPC and APP_SEED_HTTP name the seed helper (tools/selftest.sh)", false)
        }
        /// Sends `spans` spans of 2-span traces to the seed helper and waits until they are stored.
        func send(spans: Int) async -> Int {
            let before = (try? await reader.traceCount()) ?? 0
            let result = await run(sender, ["--protocol", "http-protobuf", "--scenarios", "exception",
                                            "--volume", String(spans), "--grpc", grpc, "--http", http])
            let traces = result.output.firstMatch(of: /(\d+) spans in (\d+) traces/).flatMap { Int($0.2) } ?? 0
            for _ in 0..<50 where (try? await reader.traceCount()) ?? 0 < before + traces {
                try? await Task.sleep(for: .milliseconds(100))
            }
            return ((try? await reader.traceCount()) ?? 0) - before
        }

        let added = await send(spans: 700)
        await model.reload()
        check("the list reads one page of 200 rows", added > 200 && model.traces.count == TraceList.pageSize
              && model.hasMoreTraces, "\(added) added, \(model.traces.count) rows")
        let scroller = model.listScroller
        let attached = await waitUntil(3) { scroller.rowCount == model.traces.count }
        check("the list finds its table's scroll view", attached)
        guard attached else { return }

        scroller.scroll(toOffset: 1_200)
        check("scrolling away from the top holds the list", await waitUntil(1) { model.isListHeld })
        try? await Task.sleep(for: .milliseconds(300))
        let ids = model.traces.map(\.id)
        let firstRow = scroller.firstVisibleRow
        let offset = scroller.offset
        let arrived = await send(spans: 80)
        await model.reload()
        try? await Task.sleep(for: .milliseconds(300))
        check("while scrolled away, arriving traces leave the rows where they are",
              (firstRow ?? 0) > 0 && model.traces.map(\.id) == ids && scroller.firstVisibleRow == firstRow
                && scroller.offset == offset,
              "row \(firstRow ?? -1) -> \(scroller.firstVisibleRow ?? -1), offset \(offset) -> \(scroller.offset)")
        check("\"N new traces\" counts them", arrived > 0 && model.newTraceCount == arrived && model.showsNewTracesButton,
              "\(arrived) sent, \(model.newTraceCount) counted")
        check("the button reads \"\(TraceList.newTracesTitle(arrived))\"",
              TraceList.newTracesTitle(model.newTraceCount) == "\(arrived) new traces")
        check("Trace > Show Newest Traces is enabled", MenuState.shared.newTraceCount == arrived
              && menuItem("Show Newest Traces")?.menu?.title == "Trace")

        scroller.scrollToBottom()
        let paged = await waitUntil(3) { model.traces.count > TraceList.pageSize }
        let rows = model.traces
        check("scrolling to the end reads the next page from the database",
              paged && Set(rows.map(\.id)).count == rows.count
                && zip(rows, rows.dropFirst()).allSatisfy { $0.startNs >= $1.startNs },
              "\(rows.count) rows")

        model.showNewestTraces()
        let newest = try? await reader.latestTraces(limit: 1).first
        // Back at the top the list reads its first page again: the newest 200.
        let shown = await waitUntil(3) {
            !model.isListHeld && model.newTraceCount == 0 && model.traces.count == TraceList.pageSize
                && model.traces.first?.id == newest?.id
        }
        check("Show Newest Traces scrolls to the top and inserts them",
              shown && scroller.offset <= TraceListScroller.tolerance && model.newTraceCount == 0
                && MenuState.shared.newTraceCount == 0,
              "shown \(shown), offset \(scroller.offset), held \(model.isListHeld), count \(model.newTraceCount) menu \(MenuState.shared.newTraceCount), \(model.traces.count) rows (table \(scroller.rowCount)), first \(model.traces.first?.id ?? "nil") newest \(newest?.id ?? "nil")")

        _ = await send(spans: 4)
        await model.reload()
        try? await Task.sleep(for: .milliseconds(300))
        let latest = try? await reader.latestTraces(limit: 1).first
        check("at the top, a new trace is inserted first and stays in view",
              model.traces.first?.id == latest?.id && !model.isListHeld && scroller.firstVisibleRow == 0
                && scroller.offset <= TraceListScroller.tolerance,
              "row \(scroller.firstVisibleRow ?? -1), offset \(scroller.offset), table \(scroller.rowCount) rows \(scroller.tableView?.frame ?? .zero), clip \(scroller.scrollView?.contentView.bounds ?? .zero), first \(model.traces.first?.id == latest?.id)")
    }
}

extension TraceListScroller {
    /// The self-test's way to the last row.
    func scrollToBottom() {
        guard let height = scrollView?.documentView?.frame.height else { return }
        scroll(toOffset: height)
    }
}
