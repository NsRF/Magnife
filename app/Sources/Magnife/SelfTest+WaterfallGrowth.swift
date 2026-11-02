import AppKit
import MagnifeKit

/// S-005 with a trace that is still arriving: it grows past 500 spans while
/// open and collapses like one that opened that big (design decision 7),
/// and a rebuild leaves the waterfall's scroll position and selection alone.
/// The spans go to the seed helper over OTLP/HTTP JSON, as in checkLateSpans.
extension SelfTest {
    static func checkGrowingWaterfall(_ model: AppModel) async {
        guard let http = ProcessInfo.processInfo.environment["APP_SEED_HTTP"]?.split(separator: ":").last.flatMap({ Int($0) }),
              let reader = model.reader else {
            return check("APP_SEED_HTTP names the seed helper (tools/selftest.sh)", false)
        }
        let trace = "5e1f7e57000000000000000000000008"
        let start = UInt64(Date().timeIntervalSince1970 * 1e9)
        func id(_ n: Int) -> String { String(format: "5e1f7e57%08x", n) }
        func span(_ n: Int, parent: Int?, at ms: UInt64) -> String {
            let parentField = parent.map { #""parentSpanId":"\#(id($0))","# } ?? ""
            return """
                {"traceId":"\(trace)","spanId":"\(id(n))",\(parentField)"name":"step-\(n)","kind":1,\
                "startTimeUnixNano":"\(start + ms * 1_000_000)","endTimeUnixNano":"\(start + (ms + 1) * 1_000_000)"}
                """
        }
        func send(_ spans: [String]) async -> Int {
            await post(port: http, path: "/v1/traces", body: """
                {"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"selftest"}}]},
                "scopeSpans":[{"spans":[\(spans.joined(separator: ","))]}]}]}
                """)
        }
        func stored(_ count: Int) async -> Bool {
            for _ in 0..<50 {
                if (try? await reader.trace(id: trace))?.spanCount == count { return true }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return false
        }

        // Two spans first: the root (0) and one child (1).
        guard await send([span(0, parent: nil, at: 0), span(1, parent: 0, at: 1)]) == 200, await stored(2) else {
            return check("a growing trace's first spans are stored", false)
        }
        await model.reload()
        model.selectedTraceID = trace
        guard await waitUntil(3, { isShown(model) && model.waterfall.count == 2 }), let outline = model.waterfallOutline,
              let scroll = outline.enclosingScrollView else {
            return check("the growing trace opens", false)
        }
        // 99 more children of the root, and five spans under each of the 100: 601 spans.
        var more = (2...100).map { span($0, parent: 0, at: UInt64($0)) }
        for child in 1...100 {
            more += (0..<5).map { span(1_000 + child * 10 + $0, parent: child, at: UInt64(child + $0)) }
        }
        guard await send(more) == 200, await stored(601) else { return check("the trace grows to 601 spans", false) }
        await model.reload()
        let collapsed = await waitUntil(3) { isShown(model) && model.waterfall.count == 601 }
        check("a trace that grows past 500 spans while open collapses its deep subtrees (\(outline.numberOfRows) rows)",
              collapsed && outline.numberOfRows == 101 && model.collapsedSpans.count == 100,
              "\(outline.numberOfRows) rows, \(model.collapsedSpans.count) collapsed")

        // Scroll down, select a row there, and let one more subtree arrive
        // above it (it starts with the root), so the selected row moves down one.
        let selectedRow = 60
        outline.selectRowIndexes([selectedRow], byExtendingSelection: false)
        let selected = model.selectedSpanID
        scroll.contentView.scroll(to: NSPoint(x: 0, y: outline.rect(ofRow: 40).minY))
        scroll.reflectScrolledClipView(scroll.contentView)
        let offset = scroll.contentView.bounds.minY
        let generation = model.waterfallGeneration
        guard await send([span(101, parent: 0, at: 0), span(5_000, parent: 101, at: 0)]) == 200, await stored(603) else {
            return check("the trace grows to 603 spans", false)
        }
        await model.reload()
        let rebuilt = await waitUntil(3) { isShown(model) && model.waterfallGeneration > generation }
        check("above 500 spans, a span that becomes a parent starts collapsed",
              rebuilt && outline.numberOfRows == 102 && model.collapsedSpans.contains(id(101)),
              "\(outline.numberOfRows) rows")
        check("a rebuild keeps the waterfall's scroll position and selection",
              abs(scroll.contentView.bounds.minY - offset) < 1 && model.selectedSpanID == selected
                && (outline.item(atRow: outline.selectedRow) as? SpanItem).map { model.waterfall.nodes[$0.index].span.spanID } == selected,
              "offset \(offset) -> \(scroll.contentView.bounds.minY)")
        model.selectedTraceID = nil
    }

    /// A trace whose first read failed opens on the next batch's refresh.
    static func checkFailedOpenRetries(_ model: AppModel) async {
        guard let trace = model.traces.first else { return check("the list has a trace to open", false) }
        model.selectedTraceID = nil
        model.selectedTraceID = trace.id
        // As if the first read had failed: the open task ends with nothing shown.
        model.waterfallTask?.cancel()
        model.isOpeningTrace = false
        await model.reload()
        check("a trace whose first read failed opens on the next refresh",
              await waitUntil(3) { isShown(model) && model.openTrace?.id == trace.id })
        model.selectedTraceID = nil
    }
}
