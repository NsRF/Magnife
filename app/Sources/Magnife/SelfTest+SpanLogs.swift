import AppKit
import MagnifeKit

/// S-011: the logs of the selected span. The seed set's logs on their
/// spans (a pino record with a structured body among them), then a trace
/// sent to the seed helper whose logs arrive while its span is open: they
/// join in time order, and not while paused.
extension SelfTest {
    static func checkSpanLogs(_ model: AppModel) async {
        model.sidebar = .allTraces
        await model.reload()
        await checkSeedSpanLogs(model)
        await checkLiveSpanLogs(model)
        model.selectedTraceID = nil
    }

    private static func checkSeedSpanLogs(_ model: AppModel) async {
        let checkout = try? await model.reader?.latestTraces(limit: 2_000).first { $0.route == "POST /checkout/pay" }?.traceID
        guard let payments = await openSpan(model, trace: checkout, where: { $0.name == "POST /payments" }) else {
            return check("the failed checkout-api span opens", false)
        }
        let log = payments.logs.first
        check("the span's log shows last, in Logs, with time, level and body",
              payments.sections.last == .logs && payments.logs.count == 1 && log?.levelWord == "ERROR"
                && log?.record.body == "An unhandled exception has occurred while executing the request."
                && log?.time.wholeMatch(of: /\d\d:\d\d:\d\d\.\d\d\d/) != nil,
              "\(payments.logs.map { "\($0.time) \($0.levelWord) \($0.body)" })")
        check("its attributes come on demand, by key",
              log?.attributes.map(\.key) == ["EventId.Id", "EventId.Name", "exception.message", "exception.type"],
              "\(log?.attributes.map(\.key) ?? [])")
        if let log {
            let id = SpanDetailValueID.logAttributes(log.id)
            model.toggleExpanded(id)
            let shown = model.expandedValues.contains(id)
            model.toggleExpanded(id)
            check("the disclosure triangle shows and hides them", shown && !model.expandedValues.contains(id))
            check("VoiceOver reads time, level and body",
                  log.accessibilityLabel == "\(log.spokenTime), ERROR, \(log.record.body)", log.accessibilityLabel)
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("Magnife.selftest.body"))
            model.copyBody(log.record.body, to: pasteboard)
            check("Copy Body copies the log's body", pasteboard.string(forType: .string) == log.record.body)
        }

        guard let call = await openSpan(model, trace: checkout, where: { $0.serviceName == "web" && $0.kind == .client }) else {
            return check("the web client span opens", false)
        }
        let structured = call.logs.first
        check("a structured body shows pretty-printed, keys as sent",
              structured?.isStructured == true && structured?.body.hasPrefix("{\n  \"") == true
                && structured?.body.contains("\"msg\": \"payment request failed\"") == true
                && structured?.body.contains("\n  \"err\": {\n    \"") == true,
              structured?.body ?? "none")
        guard let select = await openSpan(model, trace: checkout, where: { $0.name == "SELECT Orders" }) else {
            return check("the SELECT span opens", false)
        }
        check("a span with no logs has no Logs section", select.logs.isEmpty && !select.sections.contains(.logs),
              "\(select.sections)")
        check("every level has an SF Symbol", SeverityLevel.allCases.allSatisfy {
            NSImage(systemSymbolName: LogLevelLabel.symbol($0), accessibilityDescription: nil) != nil
        })
    }

    private static func checkLiveSpanLogs(_ model: AppModel) async {
        guard let http = ProcessInfo.processInfo.environment["APP_SEED_HTTP"]?.split(separator: ":").last.flatMap({ Int($0) }),
              let reader = model.reader else {
            return check("APP_SEED_HTTP names the seed helper (tools/selftest.sh)", false)
        }
        let trace = "5e1f7e57000000000000000000000011"
        let spanID = "5e1f7e5700001101"
        let start = UInt64(Date().timeIntervalSince1970 * 1e9)
        let resource = #"{"attributes":[{"key":"service.name","value":{"stringValue":"selftest"}}]}"#
        func log(at ms: UInt64, _ body: String, severity: Int = 9) -> String {
            #"{"resourceLogs":[{"resource":\#(resource),"scopeLogs":[{"logRecords":[{"timeUnixNano":"\#(start + ms * 1_000_000)","#
                + #""severityNumber":\#(severity),"body":{"stringValue":"\#(body)"},"traceId":"\#(trace)","spanId":"\#(spanID)"}]}]}]}"#
        }
        func stored(_ count: Int) async -> Bool {
            for _ in 0..<50 {
                if (try? await reader.logStamp(traceID: trace).count) == count { return true }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return false
        }
        let sent = await post(port: http, path: "/v1/traces", body: """
            {"resourceSpans":[{"resource":\(resource),"scopeSpans":[{"spans":[{"traceId":"\(trace)","spanId":"\(spanID)",
            "name":"GET /live-logs","kind":2,"startTimeUnixNano":"\(start)","endTimeUnixNano":"\(start + 50_000_000)"}]}]}]}
            """)
        let first = await post(port: http, path: "/v1/logs", body: log(at: 30, "third by time"))
        var exists = false
        for _ in 0..<50 where !exists {
            exists = (try? await reader.trace(id: trace)) != nil
            if !exists { try? await Task.sleep(for: .milliseconds(100)) }
        }
        guard sent == 200, first == 200, exists, await stored(1) else {
            return check("the live trace and its first log are stored", false, "\(sent) \(first)")
        }
        await model.reload()
        guard await openSpan(model, trace: trace, where: { $0.spanID == spanID }) != nil else {
            return check("the live span opens", false)
        }
        // Two logs written earlier arrive now, as from a slower exporter.
        _ = await post(port: http, path: "/v1/logs", body: log(at: 10, "first by time", severity: 5))
        _ = await post(port: http, path: "/v1/logs", body: log(at: 20, "second by time", severity: 13))
        guard await stored(3) else { return check("the later logs are stored", false) }
        await model.reload()
        let joined = await waitUntil(2) { model.spanDetail?.logs.count == 3 }
        check("logs arriving while the span is open join in time order", joined
              && model.spanDetail?.logs.map(\.record.body) == ["first by time", "second by time", "third by time"],
              "\(model.spanDetail?.logs.map(\.record.body) ?? [])")

        model.pause()
        _ = await post(port: http, path: "/v1/logs", body: log(at: 40, "while paused"))
        guard await stored(4) else { return check("the paused log is stored", false) }
        await model.reload()
        try? await Task.sleep(for: .milliseconds(300))
        check("not while paused", model.spanDetail?.logs.count == 3, "\(model.spanDetail?.logs.count ?? 0)")
        model.resume()
        try? await Task.sleep(for: .milliseconds(300))
        await model.reload()
        let resumed = await waitUntil(2) { model.spanDetail?.logs.count == 4 }
        check("Resume adds it", resumed && model.spanDetail?.logs.last?.record.body == "while paused")
    }
}
