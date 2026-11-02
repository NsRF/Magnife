import AppKit
import MagnifeKit

/// S-012: Trace Logs. The seed's HTTP 500 trace (five logs: on spans, one
/// with no span id, one from a span never received); selecting a log
/// selects its span in the waterfall, opening collapsed parents; then
/// traces sent to the seed helper: one whose logs arrive while it is open,
/// and one with 10,000 logs.
extension SelfTest {
    static func checkTraceLogs(_ model: AppModel) async {
        model.sidebar = .allTraces
        await model.reload()
        await checkSeedTraceLogs(model)
        await checkLiveTraceLogs(model)
        await checkManyTraceLogs(model)
        model.showSpanDetailTab(.span)
        model.selectedTraceID = nil
    }

    /// The Trace Logs table in the window, by its column titles.
    private static func traceLogsTable() -> NSTableView? {
        var stack = NSApp.windows.compactMap(\.contentView)
        while let view = stack.popLast() {
            if let table = view as? NSTableView, table.tableColumns.map(\.title) == ["Time", "Level", "Service", "Span", "Body"] {
                return table
            }
            stack.append(contentsOf: view.subviews)
        }
        return nil
    }

    private static func checkSeedTraceLogs(_ model: AppModel) async {
        let checkout = try? await model.reader?.latestTraces(limit: 2_000).first { $0.route == "POST /checkout/pay" }?.traceID
        guard await openSpan(model, trace: checkout, where: { $0.parentSpanID == nil }) != nil else {
            return check("the HTTP 500 trace opens", false)
        }
        let view = menuItem(SpanDetailTab.traceLogs.title)
        check("View > Trace Logs is ⌥⌘2 and View > Span is ⌥⌘1",
              view?.menu?.title == "View" && view?.keyEquivalent == "2" && view?.keyEquivalentModifierMask == [.command, .option]
                && menuItem(SpanDetailTab.span.title)?.keyEquivalent == "1")
        model.showSpanDetailTab(.traceLogs)
        let read = await waitUntil(2) { model.traceLogs.lines.count == 5 && traceLogsTable()?.numberOfRows == 5 }
        let lines = model.traceLogs.lines
        check("Trace Logs lists every log of the trace in time order, in Time, Level, Service, Span, Body",
              read && lines.map(\.record.timeNs) == lines.map(\.record.timeNs).sorted(),
              "\(lines.map(\.record.body)), rows \(traceLogsTable()?.numberOfRows ?? -1)")
        check("the pane header reads \"5 logs\"", TraceLogs.countTitle(lines.count) == "5 logs")
        guard let saved = lines.first(where: { $0.record.body == "Payment for order 1042 was not saved" }),
              let noSpan = lines.first(where: { $0.record.body == "response sent" }),
              let unknown = lines.first(where: { $0.record.body == "payment webhook queued" }),
              let insert = model.waterfall.nodes.first(where: { $0.span.name == "INSERT Payments" })?.span.spanID else {
            return check("the seed's trace logs are there", false, "\(lines.map(\.record.body))")
        }
        check("a log with no span ID shows — and one from a span not received shows \"Span not received\"",
              model.traceLogSpan(noSpan) == .none && model.traceLogSpan(unknown) == .notReceived
                && model.traceLogSpan(saved) == .span(id: insert, name: "INSERT Payments")
                && model.traceLogSpan(unknown).text == "Span not received")

        // Collapsed parents open when their span's log is selected.
        model.collapseAllSpans()
        try? await Task.sleep(for: .milliseconds(200))
        model.selectTraceLog(saved.id)
        guard let outline = model.waterfallOutline,
              await waitUntil(2, { outline.item(atRow: outline.selectedRow).flatMap { $0 as? SpanItem }
                  .map { model.waterfall.nodes[$0.index].span.spanID } == insert }) else {
            return check("selecting a log selects its span in the waterfall", false,
                         "selected \(model.selectedSpanID ?? "none"), collapsed \(model.collapsedSpans.count)")
        }
        let row = outline.selectedRow
        check("selecting a log selects its span in the waterfall, its collapsed parents open and the row in view",
              model.selectedSpanID == insert && model.waterfall.ancestors(of: insert).allSatisfy { !model.collapsedSpans.contains($0) }
                && outline.rows(in: outline.visibleRect).contains(row) && model.spanDetailTab == .traceLogs)
        model.selectTraceLog(noSpan.id)
        try? await Task.sleep(for: .milliseconds(100))
        check("a log with no span ID leaves the waterfall alone", model.selectedSpanID == insert && outline.selectedRow == row)
        model.selectTraceLog(unknown.id)
        try? await Task.sleep(for: .milliseconds(100))
        check("so does one whose span was not received", model.selectedSpanID == insert)

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("Magnife.selftest.body"))
        model.copySelectedLogBody(to: pasteboard)
        check("Edit > Copy Body copies the selected log's body", pasteboard.string(forType: .string) == "payment webhook queued"
              && MenuState.shared.hasSelectedLog && menuItem("Copy Body")?.menu?.title == "Edit")
        if let payments = lines.first(where: { $0.levelWord == "ERROR" && $0.record.serviceName == "checkout-api" }) {
            model.openTraceLogSpan(payments.id)
            let focused = await waitUntil(1) { outline.window?.firstResponder === outline }
            check("Return on a log selects its span and moves focus to the waterfall",
                  focused && model.selectedSpanID == payments.record.spanID)
        }
        check("the pane stays on Trace Logs", model.spanDetailTab == .traceLogs)
        model.showSpanDetailTab(.span)
        check("⌥⌘1 goes back to Span", model.spanDetailTab == .span)
        model.showsSpanDetail = false
        model.showSpanDetailTab(.traceLogs)
        check("picking Trace Logs shows a hidden span detail", model.showsSpanDetail && model.spanDetailTab == .traceLogs)
        check("the empty state's symbol exists", NSImage(systemSymbolName: "text.page", accessibilityDescription: nil) != nil)
    }

    private static func checkLiveTraceLogs(_ model: AppModel) async {
        guard let http = seedHTTPPort(), let reader = model.reader else {
            return check("APP_SEED_HTTP names the seed helper (tools/selftest.sh)", false)
        }
        let trace = "5e1f7e57000000000000000000000012"
        let spanID = "5e1f7e5700001201"
        let start = UInt64(Date().timeIntervalSince1970 * 1e9)
        let sent = await post(port: http, path: "/v1/traces", body: Self.span(trace: trace, spanID: spanID, start: start))
        guard sent == 200, await storedTrace(reader, trace) else { return check("the live trace is stored", false) }
        await model.reload()
        guard await openSpan(model, trace: trace, where: { $0.spanID == spanID }) != nil else {
            return check("the live trace opens", false)
        }
        model.showSpanDetailTab(.traceLogs)
        let empty = await waitUntil(2) { model.traceLogs.traceID == trace }
        check("a trace without logs reads \"No Logs for This Trace\"", empty && model.traceLogs.isEmpty
              && TraceLogs.emptyTitle == "No Logs for This Trace")
        _ = await post(port: http, path: "/v1/logs", body: Self.logs(trace: trace, spanID: nil, start: start, count: 1, body: "trace only"))
        _ = await post(port: http, path: "/v1/logs", body: Self.logs(trace: trace, spanID: spanID, start: start, count: 1, body: "on the span"))
        for _ in 0..<50 where (try? await reader.logStamp(traceID: trace).count) != 2 { try? await Task.sleep(for: .milliseconds(100)) }
        await model.reload()
        let joined = await waitUntil(2) { model.traceLogs.lines.count == 2 && model.spanDetail?.logs.count == 1 }
        check("logs matching the trace id show even when the span id is missing",
              joined && model.traceLogs.lines.contains { $0.record.body == "trace only 0" && $0.record.spanID == nil }
                && model.spanDetail?.logs.map(\.record.body) == ["on the span 0"],
              "\(model.traceLogs.lines.map(\.record.body))")
    }

    /// "10,000 logs scroll smoothly" (docs/ux.md, S-012 States): the read and the table's scroll, timed.
    private static func checkManyTraceLogs(_ model: AppModel) async {
        guard let http = seedHTTPPort(), let reader = model.reader else { return }
        let trace = "5e1f7e57000000000000000000000013"
        let spanID = "5e1f7e5700001301"
        let start = UInt64(Date().timeIntervalSince1970 * 1e9)
        _ = await post(port: http, path: "/v1/traces", body: Self.span(trace: trace, spanID: spanID, start: start))
        for part in 0..<5 {
            _ = await post(port: http, path: "/v1/logs",
                           body: Self.logs(trace: trace, spanID: part == 0 ? nil : spanID, start: start + UInt64(part) * 2_000_000,
                                           count: 2_000, body: "chatty line \(part)"))
        }
        for _ in 0..<100 where (try? await reader.logStamp(traceID: trace).count) != 10_000 {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard await storedTrace(reader, trace) else { return check("the 10,000-log trace is stored", false) }
        await model.reload()
        model.showSpanDetailTab(.traceLogs)
        let heartbeat = Heartbeat()
        heartbeat.start()
        let started = Date()
        model.selectedTraceID = trace
        let shown = await waitUntil(10) { model.traceLogs.lines.count == 10_000 && traceLogsTable()?.numberOfRows == 10_000 }
        let elapsed = Date().timeIntervalSince(started) * 1_000
        let openStall = heartbeat.stop()
        let scroll = Heartbeat()
        scroll.start()
        if let table = traceLogsTable() {
            for row in stride(from: 0, through: 9_999, by: 500) {
                table.scrollRowToVisible(row)
                try? await Task.sleep(for: .milliseconds(10))
            }
            table.scrollRowToVisible(9_999)
        }
        try? await Task.sleep(for: .milliseconds(100))
        let scrollStall = scroll.stop()
        print("INFO trace logs 10,000: shown in \(String(format: "%.0f", elapsed)) ms, open stall \(String(format: "%.0f", openStall)) ms, scroll stall \(String(format: "%.0f", scrollStall)) ms")
        check("10,000 trace logs show within 2 s and scroll without a stall over 100 ms",
              shown && elapsed < 2_000 && scrollStall < 100,
              "\(Int(elapsed)) ms, scroll stall \(Int(scrollStall)) ms")
    }

    private static func seedHTTPPort() -> Int? {
        ProcessInfo.processInfo.environment["APP_SEED_HTTP"]?.split(separator: ":").last.flatMap { Int($0) }
    }

    private static func storedTrace(_ reader: TelemetryReader, _ trace: String) async -> Bool {
        for _ in 0..<50 {
            if (try? await reader.trace(id: trace)) != nil { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    private static let resource = #"{"attributes":[{"key":"service.name","value":{"stringValue":"selftest"}}]}"#

    private static func span(trace: String, spanID: String, start: UInt64) -> String {
        #"{"resourceSpans":[{"resource":\#(resource),"scopeSpans":[{"spans":[{"traceId":"\#(trace)","spanId":"\#(spanID)","#
            + #""name":"GET /trace-logs","kind":2,"startTimeUnixNano":"\#(start)","endTimeUnixNano":"\#(start + 50_000_000)"}]}]}]}"#
    }

    /// `count` logs 1 µs apart, "<body> 0", "<body> 1", …; no span id when `spanID` is nil.
    private static func logs(trace: String, spanID: String?, start: UInt64, count: Int, body: String) -> String {
        let span = spanID.map { #","spanId":"\#($0)""# } ?? ""
        let records = (0..<count).map { n in
            #"{"timeUnixNano":"\#(start + UInt64(n) * 1_000)","severityNumber":\#(9 + n % 12),"#
                + #""body":{"stringValue":"\#(body) \#(n)"},"traceId":"\#(trace)"\#(span)}"#
        }
        return #"{"resourceLogs":[{"resource":\#(resource),"scopeLogs":[{"logRecords":[\#(records.joined(separator: ","))]}]}]}"#
    }
}
