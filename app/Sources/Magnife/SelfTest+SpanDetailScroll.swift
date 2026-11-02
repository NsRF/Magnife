import AppKit
import MagnifeKit

/// S-006 / S-007 in the real window: another span's detail starts at the
/// top, so an Error span opens on Exception; and a span with a 500 KB value
/// and 2,000 events opens without a hitch.
extension SelfTest {
    static func checkSpanDetailScrolling(_ model: AppModel) async {
        await checkOpensAtTop(model)
        await checkHugeSpan(model)
        model.selectedTraceID = nil
    }

    /// The span detail's scroll view, in the lower pane of the detail column.
    private static func spanDetailScroll() -> NSScrollView? {
        func find(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            for child in view.subviews { if let found = find(child) { return found } }
            return nil
        }
        func split(_ view: NSView) -> RememberingSplitView? {
            if let split = view as? RememberingSplitView { return split }
            for child in view.subviews { if let found = split(child) { return found } }
            return nil
        }
        guard let content = NSApp.windows.first(where: { $0.canBecomeMain })?.contentView,
              let pane = split(content)?.arrangedSubviews.last else { return nil }
        return find(pane)
    }

    private static func checkOpensAtTop(_ model: AppModel) async {
        let trace = try? await model.reader?.latestTraces(limit: 2_000).first { $0.route == "POST /checkout/pay" }?.traceID
        guard await openSpan(model, trace: trace, where: { $0.parentSpanID == nil }) != nil else {
            return check("the HTTP 500 trace's root span opens", false)
        }
        try? await Task.sleep(for: .milliseconds(300))
        guard let scroll = spanDetailScroll(), let document = scroll.documentView else {
            return check("the span detail scrolls", false)
        }
        // Scroll the root span's detail to its end (Resource).
        let bottom = max(0, document.frame.height - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom))
        scroll.reflectScrolledClipView(scroll.contentView)
        let scrolled = scroll.contentView.bounds.minY
        guard let payments = await openSpan(model, trace: trace, where: { $0.name == "POST /payments" }) else {
            return check("the failed checkout-api span opens", false)
        }
        try? await Task.sleep(for: .milliseconds(300))
        let top = spanDetailScroll().map { $0.contentView.bounds.minY <= 1 } ?? false
        check("another span's detail starts at the top, so an Error span opens on Exception",
              scrolled > 20 && top && payments.sections.first == .exception,
              "scrolled \(scrolled), now \(spanDetailScroll()?.contentView.bounds.minY ?? -1)")
    }

    /// 500 KB in one attribute and 2,000 events: the selection lays out only
    /// the start of the value, and the ordered lists are built once.
    private static func checkHugeSpan(_ model: AppModel) async {
        guard let http = ProcessInfo.processInfo.environment["APP_SEED_HTTP"]?.split(separator: ":").last.flatMap({ Int($0) }),
              let reader = model.reader else {
            return check("APP_SEED_HTTP names the seed helper (tools/selftest.sh)", false)
        }
        let trace = "5e1f7e57000000000000000000000009"
        let spanID = "5e1f7e5700000c01"
        let start = UInt64(Date().timeIntervalSince1970 * 1e9)
        let huge = String(repeating: "INSERT INTO audit_log VALUES (1, 'payload'); ", count: 11_500)
        let events = (0..<2_000).map { n in
            #"{"timeUnixNano":"\#(start + UInt64(2_000 - n) * 1_000)","name":"step \#(n)"}"#
        }.joined(separator: ",")
        let status = await post(port: http, path: "/v1/traces", body: """
            {"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"selftest"}}]},
            "scopeSpans":[{"spans":[{"traceId":"\(trace)","spanId":"\(spanID)","name":"POST /audit","kind":2,
            "startTimeUnixNano":"\(start)","endTimeUnixNano":"\(start + 40_000_000)",
            "attributes":[{"key":"db.statement","value":{"stringValue":"\(huge)"}}],"events":[\(events)]}]}]}]}
            """)
        var stored = false
        for _ in 0..<50 where !stored {
            stored = (try? await reader.trace(id: trace)) != nil
            if !stored { try? await Task.sleep(for: .milliseconds(100)) }
        }
        guard status == 200, stored else { return check("the 500 KB span is stored", false, "\(status)") }
        await model.reload()
        model.selectedTraceID = nil
        model.selectedTraceID = trace
        guard await waitUntil(3, { isShown(model) }) else { return check("the 500 KB span's trace opens", false) }
        try? await Task.sleep(for: .milliseconds(300))
        // Select another span id first, so the selection below reads and lays out the detail.
        model.selectedSpanID = nil
        try? await Task.sleep(for: .milliseconds(200))
        let heartbeat = Heartbeat()
        heartbeat.start()
        model.selectedSpanID = spanID
        let opened = await waitUntil(3) { model.spanDetail?.span.spanID == spanID }
        try? await Task.sleep(for: .milliseconds(500))
        let stall = heartbeat.stop()
        let layout = model.valueLayouts[SpanDetailValueID.attribute("db.statement")]
        print("INFO span detail with a 500 KB value and 2,000 events: longest main-actor stall \(String(format: "%.0f", stall)) ms")
        checkTiming("a 500 KB value and 2,000 events open without a hang, cut with Show All", ms: stall, budget: 250,
                    ok: opened && layout?.isTruncated == true && model.spanDetail?.events.count == 2_000,
                    "layout \(String(describing: layout))")
    }
}
