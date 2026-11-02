import AppKit
import MagnifeKit

/// S-005: the waterfall in the real window. The seed set's HTTP 500 trace
/// for nesting, bars, Error marks and collapsing; then traces of 1,000,
/// 5,000 and 30,000 spans (`send-sample-traces --huge-trace`) sent to the
/// seed helper, timed from selection to rows on screen while a heartbeat
/// on the main actor measures the longest stall.
extension SelfTest {
    static func checkWaterfall(_ model: AppModel) async {
        model.sidebar = .allTraces
        await model.reload()
        await checkSeedWaterfall(model)
        await checkLateSpans(model)
        await checkGrowingWaterfall(model)
        await checkFailedOpenRetries(model)
        await checkHugeWaterfalls(model)
        model.selectedTraceID = nil
    }

    private static func checkSeedWaterfall(_ model: AppModel) async {
        guard let reader = model.reader,
              let trace = try? await reader.latestTraces(limit: 1_000).first(where: { $0.route == "POST /checkout/pay" }) else {
            return check("the seed set's HTTP 500 trace is stored", false)
        }
        model.selectedTraceID = nil
        model.selectedTraceID = trace.id
        let shown = await waitUntil(3) { isShown(model) }
        guard shown, let outline = model.waterfallOutline else { return check("the waterfall opens", false) }
        let waterfall = model.waterfall
        check("the header reads route, service, duration and span count",
              model.openTrace.map { "\($0.route) · \($0.waterfallSubtitle)" }
                == "POST /checkout/pay · \(trace.rootService) · \(DurationFormat.string(nanoseconds: trace.durationNs)) · 5 spans",
              model.openTrace?.waterfallSubtitle ?? "nil")
        check("all 5 spans show, nested by parent", outline.numberOfRows == 5
              && (0..<5).allSatisfy { row in
                  (outline.item(atRow: row) as? SpanItem).map { outline.level(forRow: row) == waterfall.nodes[$0.index].depth } == true
              } && waterfall.maxDepth == 3, "\(outline.numberOfRows) rows, depth \(waterfall.maxDepth)")
        check("the root span is selected", outline.selectedRow == 0 && model.selectedSpanID == waterfall.rootSpanID)

        var barsPlaced = true
        var errorsMarked = true
        for row in 0..<outline.numberOfRows {
            guard let item = outline.item(atRow: row) as? SpanItem,
                  let name = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SpanNameCell,
                  let bar = outline.view(atColumn: 1, row: row, makeIfNecessary: true) as? SpanBarCell else {
                barsPlaced = false
                continue
            }
            let expected = waterfall.barFractions(of: item.index)
            if bar.fractions != expected { barsPlaced = false }
            let isError = waterfall.nodes[item.index].span.status == .error
            // Findings follow the status in the label (", Error, HTTP Error", S-025).
            if name.showsError != isError || (name.accessibilityLabel() ?? "").contains(", Error") != isError {
                errorsMarked = false
            }
        }
        check("bars are placed and sized by start time and duration", barsPlaced)
        check("Error spans carry the octagon, and VoiceOver reads \"Error\"", errorsMarked
              && waterfall.nodes.contains { $0.span.status == .error })
        // checkout-api's POST /payments under web's client span: its service shows next to the name.
        let paymentsRow = (0..<outline.numberOfRows).first { row in
            (outline.item(atRow: row) as? SpanItem).map { waterfall.nodes[$0.index].span.name == "POST /payments" } == true
        }
        let payments = paymentsRow.flatMap { outline.view(atColumn: 0, row: $0, makeIfNecessary: true) as? SpanNameCell }
        let nameColumn = outline.tableColumns.first?.width ?? 0
        check("a span from another service than its parent's shows its service (Span column \(Int(nameColumn)) pt)",
              payments?.showsService == true && nameColumn >= outline.bounds.width * 0.5)

        // Collapse the subtree that holds the selection, as a click on the triangle does.
        let leafRow = (0..<outline.numberOfRows).last { row in
            (outline.item(atRow: row) as? SpanItem).map { waterfall.nodes[$0.index].depth == waterfall.maxDepth } == true
        } ?? 0
        outline.selectRowIndexes([leafRow], byExtendingSelection: false)
        guard let leaf = outline.item(atRow: leafRow) as? SpanItem, let parent = waterfall.nodes[leaf.index].parent else {
            return check("the trace has nested spans", false)
        }
        check("clicking a row selects its span", model.selectedSpanID == waterfall.nodes[leaf.index].span.spanID)
        let generation = model.waterfallGeneration
        outline.collapseItem(outline.parent(forItem: leaf))
        let parentID = waterfall.nodes[parent].span.spanID
        // The "N spans" text is refreshed a run-loop turn after the collapse.
        func countText() -> String? {
            // A row of -1 would hang view(atColumn:row:makeIfNecessary:).
            guard let row = (0..<outline.numberOfRows).first(where: { (outline.item(atRow: $0) as? SpanItem)?.index == parent })
            else { return nil }
            return (outline.view(atColumn: 1, row: row, makeIfNecessary: true) as? SpanBarCell)?.hiddenCountText
        }
        let collapsed = await waitUntil(1) {
            model.collapsedSpans == [parentID] && model.selectedSpanID == parentID && countText() == "2 spans"
        }
        check("collapsing a subtree hides it, shows its span count and selects the collapsed span",
              collapsed && outline.numberOfRows == 3 && model.waterfallGeneration == generation,
              "\(model.collapsedSpans), \(outline.numberOfRows) rows, \(countText() ?? "nil")")
        model.expandAllSpans()
        check("Expand All Spans opens every subtree", await waitUntil(1) { outline.numberOfRows == 5 })
        model.collapseAllSpans()
        check("Collapse All Spans leaves the root", await waitUntil(1) { outline.numberOfRows == 1 }
              && model.selectedSpanID == waterfall.rootSpanID)
        model.expandAllSpans()
        let expand = menuItem("Expand All Spans"), collapse = menuItem("Collapse All Spans")
        check("Trace > Expand All Spans ⌥⌘→ and Collapse All Spans ⌥⌘←",
              expand?.menu?.title == "Trace" && expand?.keyEquivalentModifierMask == [.command, .option]
                && collapse?.menu?.title == "Trace" && MenuState.shared.hasWaterfall)
    }

    /// Spans that reach the helper after the trace was opened join under their
    /// parent on the next read; one whose parent never arrives sits at the root.
    private static func checkLateSpans(_ model: AppModel) async {
        guard let http = ProcessInfo.processInfo.environment["APP_SEED_HTTP"]?.split(separator: ":").last.flatMap({ Int($0) }),
              let reader = model.reader else {
            return check("APP_SEED_HTTP names the seed helper (tools/selftest.sh)", false)
        }
        let trace = "5e1f7e57000000000000000000000005"
        let start = UInt64(Date().timeIntervalSince1970 * 1e9)
        func span(_ id: String, parent: String?, name: String, at ms: UInt64, lasting length: UInt64, error: Bool = false) -> String {
            let parentField = parent.map { #""parentSpanId":"\#($0)","# } ?? ""
            let status = error ? #","status":{"code":2}"# : ""
            return """
                {"traceId":"\(trace)","spanId":"\(id)",\(parentField)"name":"\(name)","kind":2,\
                "startTimeUnixNano":"\(start + ms * 1_000_000)","endTimeUnixNano":"\(start + (ms + length) * 1_000_000)"\(status)}
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
        let first = await send([span("5e1f7e5700000a01", parent: nil, name: "GET /late", at: 0, lasting: 240),
                                span("5e1f7e5700000a02", parent: "5e1f7e5700000a01", name: "load-cart", at: 10, lasting: 100)])
        guard first == 200, await stored(2) else { return check("the first spans of a live trace are stored", false, "\(first)") }
        await model.reload()
        model.selectedTraceID = trace
        guard await waitUntil(3, { isShown(model) && model.waterfall.count == 2 }), let outline = model.waterfallOutline else {
            return check("the live trace opens", false)
        }
        outline.selectRowIndexes([1], byExtendingSelection: false)
        let late = await send([span("5e1f7e5700000a03", parent: "5e1f7e5700000a02", name: "SELECT carts", at: 20, lasting: 30, error: true),
                               span("5e1f7e5700000a04", parent: "5e1f7e57000000ff", name: "orphan-call", at: 60, lasting: 5)])
        guard late == 200, await stored(4) else { return check("the late spans are stored", false, "\(late)") }
        await model.reload()
        let joined = await waitUntil(3) { isShown(model) && model.waterfall.count == 4 }
        let waterfall = model.waterfall
        let rows = (0..<outline.numberOfRows).compactMap { (outline.item(atRow: $0) as? SpanItem).map { waterfall.nodes[$0.index].span.name } }
        check("spans that arrive after the trace was opened join under their parent",
              joined && rows == ["GET /late", "load-cart", "SELECT carts", "orphan-call"]
                && waterfall.node("5e1f7e5700000a03")?.depth == 2,
              "\(rows)")
        check("the selected span stays selected when late spans arrive",
              model.selectedSpanID == "5e1f7e5700000a02" && outline.selectedRow == 1)
        let orphanRow = rows.firstIndex(of: "orphan-call") ?? -1
        let orphan = orphanRow < 0 ? nil : outline.view(atColumn: 0, row: orphanRow, makeIfNecessary: true) as? SpanNameCell
        check("a span whose parent never arrives sits at the root with \"Parent span not received\"",
              outline.level(forRow: max(orphanRow, 0)) == 0 && orphan?.toolTip?.hasPrefix("orphan-call") == true
                && orphan?.toolTip?.hasSuffix(" · \(Waterfall.orphanHelp)") == true
                && model.openTrace?.spanCount == 4,
              orphan?.toolTip ?? "nil")
    }

    /// Design decision 7: over 500 spans open with deep subtrees collapsed,
    /// and 30,000 spans open without a hang.
    private static func checkHugeWaterfalls(_ model: AppModel) async {
        let env = ProcessInfo.processInfo.environment
        guard let sender = env["APP_SAMPLE_SENDER"].map(URL.init(fileURLWithPath:)),
              let grpc = env["APP_SEED_GRPC"], let http = env["APP_SEED_HTTP"], let reader = model.reader else {
            return check("APP_SEED_GRPC and APP_SEED_HTTP name the seed helper (tools/selftest.sh)", false)
        }
        for count in [1_000, 5_000, 30_000] {
            let sent = await run(sender, ["--protocol", "http-protobuf", "--huge-trace", String(count),
                                          "--grpc", grpc, "--http", http])
            var trace: TraceSummary?
            for _ in 0..<100 where trace == nil {
                trace = try? await reader.latestTraces(limit: 2_000).first { $0.route == "POST /imports/catalog" && $0.spanCount == count }
                if trace == nil { try? await Task.sleep(for: .milliseconds(100)) }
            }
            guard let trace else {
                check("a \(count.formatted())-span trace is stored", false, sent.output)
                continue
            }
            model.selectedTraceID = nil
            try? await Task.sleep(for: .milliseconds(200))
            let heartbeat = Heartbeat()
            heartbeat.start()
            model.selectedTraceID = trace.id
            let shown = await waitUntil(10) { isShown(model) && model.waterfall.count == count }
            try? await Task.sleep(for: .milliseconds(100))
            let stall = heartbeat.stop()
            let open = model.lastWaterfallOpen.map { $0 / .milliseconds(1) } ?? -1
            let rows = model.waterfallOutline?.numberOfRows ?? 0
            print("INFO waterfall \(count) spans: open \(String(format: "%.0f", open)) ms, longest main-actor stall \(String(format: "%.0f", stall)) ms, \(rows) rows shown")
            check("a \(count.formatted())-span trace opens with deep subtrees collapsed (\(rows) rows)",
                  shown && rows <= Waterfall.autoCollapseLimit && !model.collapsedSpans.isEmpty
                    && model.selectedSpanID == model.waterfall.rootSpanID)
            check("a \(count.formatted())-span trace opens without a hang (\(String(format: "%.0f", open)) ms, stall \(String(format: "%.0f", stall)) ms)",
                  shown && open < 2_000 && stall < 250)

            if count == 30_000 { await captureLarge(model) }
            if count == 1_000 { await checkScrolling(model, count: count) }
            if count == 30_000 {
                let expand = Heartbeat()
                expand.start()
                let started = Date()
                model.expandAllSpans()
                let opened = await waitUntil(10) { model.waterfallOutline?.numberOfRows == count }
                let elapsed = Date().timeIntervalSince(started) * 1_000
                print("INFO waterfall \(count) spans: Expand All Spans \(String(format: "%.0f", elapsed)) ms, stall \(String(format: "%.0f", expand.stop())) ms")
                check("Expand All Spans shows all 30,000 rows", opened)
            }
        }
    }

    /// A 1,000-span trace, fully expanded, scrolls with no step over 50 ms.
    private static func checkScrolling(_ model: AppModel, count: Int) async {
        model.expandAllSpans()
        guard await waitUntil(2, { model.waterfallOutline?.numberOfRows == count }),
              let outline = model.waterfallOutline, let scroll = outline.enclosingScrollView else {
            return check("a 1,000-span trace expands", false)
        }
        var longest = 0.0
        let height = outline.frame.height - scroll.contentView.bounds.height
        for step in 0...60 {
            let started = Date()
            scroll.contentView.scroll(to: NSPoint(x: 0, y: height * Double(step) / 60))
            scroll.reflectScrolledClipView(scroll.contentView)
            scroll.window?.displayIfNeeded()
            longest = max(longest, Date().timeIntervalSince(started) * 1_000)
            await Task.yield()
        }
        print("INFO waterfall \(count) spans expanded: longest scroll step \(String(format: "%.1f", longest)) ms")
        check("a 1,000-span trace scrolls smoothly (longest step \(String(format: "%.1f", longest)) ms)", longest < 50)
        scroll.contentView.scroll(to: .zero)
    }

    /// 03-trace-detail-30000-light.png and -dark.png in /tmp/Magnife-shots: the
    /// auto-collapsed 30,000-span trace (the snapshot store has no huge trace).
    private static func captureLarge(_ model: AppModel) async {
        // APP_HELPER=none sends no batch events: read the list, so the open trace shows in it.
        await model.reload()
        try? FileManager.default.createDirectory(atPath: "/tmp/Magnife-shots", withIntermediateDirectories: true)
        let appearance = NSApp.appearance
        for mode in ["light", "dark"] {
            NSApp.appearance = NSAppearance(named: mode == "light" ? .aqua : .darkAqua)
            try? await Task.sleep(for: .seconds(0.6))
            Snapshot.capture(to: "/tmp/Magnife-shots/03-trace-detail-30000-\(mode).png")
        }
        NSApp.appearance = appearance
    }

    static func isShown(_ model: AppModel) -> Bool {
        !model.waterfall.isEmpty && model.shownWaterfallGeneration == model.waterfallGeneration
    }
}

/// Measures the longest gap between main-actor turns, 5 ms apart.
@MainActor
final class Heartbeat {
    private var task: Task<Void, Never>?
    private var longest: Double = 0
    private var last = Date()

    /// Starts counting now, so work done before the first tick counts too.
    func start() {
        last = Date()
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(5))
                self?.tick()
            }
        }
    }

    private func tick() {
        let now = Date()
        longest = max(longest, now.timeIntervalSince(last) * 1_000)
        last = now
    }

    /// Stops and returns the longest gap in milliseconds.
    func stop() -> Double {
        tick()
        task?.cancel()
        return longest
    }
}
