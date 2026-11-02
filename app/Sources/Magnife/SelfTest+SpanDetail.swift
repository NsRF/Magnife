import AppKit
import MagnifeKit

/// S-006: the span detail in the real window. Seed spans for the sections
/// and their order; then a span sent to the seed helper with a long value,
/// a long key and events out of order; then the split and its menu item.
extension SelfTest {
    static func checkSpanDetail(_ model: AppModel) async {
        model.sidebar = .allTraces
        await model.reload()
        await checkSeedSpanDetail(model)
        await checkLongValues(model)
        await checkSpanDetailPane(model)
        model.selectedTraceID = nil
    }

    /// Opens a trace, clicks the first span that matches (as a click on its
    /// row does) and waits for its detail.
    static func openSpan(_ model: AppModel, trace: String?,
                         where matches: (WaterfallSpan) -> Bool) async -> SpanDetail? {
        guard let trace else { return nil }
        if model.selectedTraceID != trace {
            model.selectedTraceID = nil
            model.selectedTraceID = trace
        }
        guard await waitUntil(3, { isShown(model) }), let outline = model.waterfallOutline else { return nil }
        let waterfall = model.waterfall
        guard let row = (0..<outline.numberOfRows).first(where: { row in
            (outline.item(atRow: row) as? SpanItem).map { matches(waterfall.nodes[$0.index].span) } == true
        }), let item = outline.item(atRow: row) as? SpanItem else { return nil }
        outline.selectRowIndexes([row], byExtendingSelection: false)
        let id = waterfall.nodes[item.index].span.spanID
        guard await waitUntil(1, { model.spanDetail?.span.spanID == id }) else { return nil }
        return model.spanDetail
    }

    /// A seed trace by route. Earlier checks send hundreds of traces, so it may be past the list's first page.
    private static func seedTrace(_ model: AppModel, route: String) async -> String? {
        try? await model.reader?.latestTraces(limit: 2_000).first { $0.route == route }?.traceID
    }

    private static func checkSeedSpanDetail(_ model: AppModel) async {
        guard let payments = await openSpan(model, trace: await seedTrace(model, route: "POST /checkout/pay"),
                                            where: { $0.name == "POST /payments" }) else {
            return check("clicking a span fills the span detail within 1 s", false)
        }
        check("clicking a span fills the span detail within 1 s", true)
        check("the header reads name, kind, duration and status",
              payments.span.name == "POST /payments" && payments.summary == "Server · 52 ms · Error", payments.summary)
        check("sections: Attributes, Events, Resource", payments.sections == [.attributes, .events, .resource],
              "\(payments.sections)")
        let keys = payments.attributes.map(\.key)
        check("http.* attributes are listed first", keys.prefix(3).allSatisfy { $0.hasPrefix("http.") }
              && !keys.dropFirst(3).contains { $0.hasPrefix("http.") }, "\(keys)")
        check("the resource is the span's service, service.* first",
              payments.resource?.serviceName == "checkout-api"
                && payments.resourceAttributes.first?.key.hasPrefix("service.") == true
                && payments.resourceAttributes.contains { $0.key == "telemetry.sdk.language" && $0.value == .string("dotnet") })

        guard let query = await openSpan(model, trace: await seedTrace(model, route: "GET /admin/reports"),
                                         where: { $0.name == "SELECT Orders" }) else {
            return check("the slow query's span opens", false)
        }
        let queryKeys = query.attributes.map(\.key)
        let dbCount = queryKeys.filter { $0.hasPrefix("db.") }.count
        check("db.* attributes are listed first", dbCount >= 4 && queryKeys.prefix(dbCount).allSatisfy { $0.hasPrefix("db.") },
              "\(queryKeys)")

        guard let rpc = await openSpan(model, trace: await seedTrace(model, route: "GET /checkout"),
                                       where: { $0.serviceName == "orders" && $0.kind == .server }) else {
            return check("the orders gRPC server span opens", false)
        }
        check("events are listed in time order with their attributes",
              rpc.events.map { $0.attributes["message.type"]?.text ?? "" } == ["RECEIVED", "SENT"]
                && rpc.events.map(\.timeNs) == rpc.events.map(\.timeNs).sorted()
                && rpc.events.allSatisfy { $0.attributes["message.id"] == .int(1) },
              "\(rpc.events.map(\.name))")
        check("an event reads its time from the span's start", rpc.offsetText(rpc.events[0].timeNs) == "at 400 µs",
              rpc.offsetText(rpc.events.first?.timeNs ?? 0))

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("Magnife.selftest.span"))
        model.copySpanID(to: pasteboard)
        check("Copy Span ID copies the selected span's ID", pasteboard.string(forType: .string) == rpc.span.spanID)
        let contextMenu = model.waterfallOutline?.menu?.items.map { $0.isSeparatorItem ? "—" : $0.title }
        check("the waterfall row's context menu reads Copy Span ID, then Expand and Collapse All Spans",
              contextMenu == ["Copy Span ID", "—", "Expand All Spans", "Collapse All Spans"], "\(contextMenu ?? [])")
        check("Edit > Copy Span ID", menuItem("Copy Span ID")?.menu?.title == "Edit")
    }

    /// Long values wrap, then collapse after three lines with "Show All"; the
    /// whole value stays in the detail. Sent through the seed helper as OTLP/JSON.
    private static func checkLongValues(_ model: AppModel) async {
        guard let http = ProcessInfo.processInfo.environment["APP_SEED_HTTP"]?.split(separator: ":").last.flatMap({ Int($0) }),
              let reader = model.reader else {
            return check("APP_SEED_HTTP names the seed helper (tools/selftest.sh)", false)
        }
        let trace = "5e1f7e57000000000000000000000006"
        let spanID = "5e1f7e5700000b01"
        let start = UInt64(Date().timeIntervalSince1970 * 1e9)
        let long = "SELECT " + (1...160).map { "column_\($0)" }.joined(separator: ", ") + " FROM wide_table"
        let longKey = "selftest." + String(repeating: "very_long_attribute_key.", count: 4) + "end"
        func attribute(_ key: String, _ value: String) -> String {
            #"{"key":"\#(key)","value":{"stringValue":"\#(value)"}}"#
        }
        // Events out of time order: the detail lists them by time.
        let events = """
            {"timeUnixNano":"\(start + 30_000_000)","name":"second","attributes":[\(attribute("step", "2"))]},
            {"timeUnixNano":"\(start + 10_000_000)","name":"first","attributes":[\(attribute("step", "1"))]}
            """
        let status = await post(port: http, path: "/v1/traces", body: """
            {"resourceSpans":[{"resource":{"attributes":[\(attribute("service.name", "selftest"))]},
            "scopeSpans":[{"spans":[{"traceId":"\(trace)","spanId":"\(spanID)","name":"GET /wide","kind":2,
            "startTimeUnixNano":"\(start)","endTimeUnixNano":"\(start + 40_000_000)",
            "attributes":[\(attribute("selftest.long", long)),\(attribute(longKey, "short")),\(attribute("http.route", "/wide"))],
            "events":[\(events)]}]}]}]}
            """)
        var stored = false
        for _ in 0..<50 where !stored {
            stored = (try? await reader.trace(id: trace)) != nil
            if !stored { try? await Task.sleep(for: .milliseconds(100)) }
        }
        guard status == 200, stored else { return check("the wide span is stored", false, "\(status)") }
        await model.reload()
        guard let detail = await openSpan(model, trace: trace, where: { $0.spanID == spanID }) else {
            return check("the wide span opens", false)
        }
        check("the whole long value is in the detail", detail.attributes.first { $0.key == "selftest.long" }?.value.text == long)
        check("the long key is kept whole (it truncates on screen with a tooltip)",
              detail.attributes.contains { $0.key == longKey })
        check("events sent out of order are listed in time order", detail.events.map(\.name) == ["first", "second"],
              "\(detail.events.map(\.name))")

        let longID = SpanDetailValueID.attribute("selftest.long")
        let shortID = SpanDetailValueID.attribute("http.route")
        let laidOut = await waitUntil(2) { model.valueLayouts[longID] != nil && model.valueLayouts[shortID] != nil }
        let longLayout = model.valueLayouts[longID]
        check("a value over three lines is cut with \"Show All\", not silently",
              laidOut && longLayout?.isTruncated == true && model.valueLayouts[shortID]?.isTruncated == false,
              "\(String(describing: longLayout))")
        model.toggleExpanded(longID)
        let expanded = await waitUntil(2) {
            guard let layout = model.valueLayouts[longID] else { return false }
            return !layout.isTruncated && layout.shown > (longLayout?.shown ?? 0) + 1
        }
        check("\"Show All\" shows the whole value", expanded, "\(String(describing: model.valueLayouts[longID]))")
        model.toggleExpanded(longID)
        check("\"Show Less\" collapses it again", await waitUntil(2) { model.valueLayouts[longID]?.isTruncated == true })
    }

    /// The split under the waterfall: 55 / 45 at first, and View > Hide Span
    /// Detail gives the waterfall the whole column.
    private static func checkSpanDetailPane(_ model: AppModel) async {
        guard let split = splitView(in: NSApp.windows.first { $0.canBecomeMain }?.contentView) else {
            return check("the span detail is the lower pane of the detail column", false)
        }
        check("the span detail is the lower pane, 55 / 45 by default", abs(split.currentFraction - 0.55) < 0.02,
              "\(split.currentFraction)")
        model.toggleSpanDetail()
        // SwiftUI retitles the menu item when the menu opens; check what the commands receive.
        let hidden = await waitUntil(1) { split.arrangedSubviews[1].isHidden }
        check("Hide Span Detail gives the waterfall the whole column, and the item then reads Show Span Detail",
              hidden && split.arrangedSubviews[0].frame.height >= split.bounds.height - 1
                && !MenuState.shared.showsSpanDetail,
              "\(split.arrangedSubviews[0].frame.height) of \(split.bounds.height)")
        model.toggleSpanDetail()
        let shown = await waitUntil(1) {
            !split.arrangedSubviews[1].isHidden && abs(split.currentFraction - 0.55) < 0.02 && MenuState.shared.showsSpanDetail
        }
        let item = menuItem("Hide Span Detail")
        check("View > Show Span Detail ⌃⌘I brings it back where it was", shown
              && item?.keyEquivalent == "i" && item?.keyEquivalentModifierMask == [.command, .control])

        model.selectedSpanID = nil
        check("no span selected reads \"Select a span to see its attributes.\"",
              await waitUntil(1) { model.showsNoSpanSelected })
        model.selectedSpanID = model.waterfall.rootSpanID
    }

    private static func splitView(in view: NSView?) -> RememberingSplitView? {
        guard let view else { return nil }
        if let split = view as? RememberingSplitView { return split }
        for child in view.subviews {
            if let found = splitView(in: child) { return found }
        }
        return nil
    }
}
