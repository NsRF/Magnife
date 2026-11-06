import AppKit
import MagnifeKit

/// S-036: Compare Traces, on the compare set's own store (APP_COMPARE_STORE,
/// tools/selftest.sh): the context menu, Compare With… (⇧⌘K) with Same
/// Route, Swap Traces, the strip's words, Show Only Differences, Open Span
/// in B, and two 30,000-span traces.
extension SelfTest {
    static let compareFast = "a7ee16380c64f5396e5afcb974081dda"
    static let compareSlow = "99e87d935187cf52601204edd521fffc"

    static func checkCompare(_ model: AppModel) async {
        guard let path = ProcessInfo.processInfo.environment["APP_COMPARE_STORE"], !path.isEmpty,
              StoreLocation.isTestLocation(URL(fileURLWithPath: path)) else {
            return check("APP_COMPARE_STORE names the compare set's store in /tmp (tools/selftest.sh)", false)
        }
        let original = model.storeURL
        let compare = model.compare
        model.closeSearch()
        model.applyTraceFilter(.cleared)
        model.showContentMode(.traces)
        model.selectedTraceID = nil
        await model.useStore(at: URL(fileURLWithPath: path))
        guard await waitUntil(5, { Set(model.traces.map(\.id)) == [compareFast, compareSlow] }) else {
            check("the compare store lists its two traces", false, model.traces.map(\.id).joined(separator: ", "))
            return await model.useStore(at: original)
        }
        check("Trace > Compare With… is ⇧⌘K", menuItem("Compare With…").map { $0.keyEquivalent == "k" && $0.keyEquivalentModifierMask.isSuperset(of: [.command, .shift]) } == true)
        check("Trace > Swap Traces is ⌥⌘K", menuItem("Swap Traces").map { $0.keyEquivalent == "k" && $0.keyEquivalentModifierMask.isSuperset(of: [.command, .option]) } == true)
        check("Trace > Show Only Differences is ⇧⌘D", menuItem("Show Only Differences").map { $0.keyEquivalent == "d" && $0.keyEquivalentModifierMask.isSuperset(of: [.command, .shift]) } == true)

        // The context menu: the selected trace is A, the right-clicked row B.
        model.selectedTraceID = compareFast
        // The table takes the new rows one paced update after the model.
        _ = await waitUntil(3) { Set(traceTable(model)?.rows.map(\.id) ?? []) == [compareFast, compareSlow] }
        let items = traceRowMenu(model, trace: compareSlow)
        let selectedRowItems = traceRowMenu(model, trace: compareFast)
        check("a trace row's menu has Compare with Selected Trace and Compare With…",
              items.map(\.title).contains("Compare with Selected Trace") && items.map(\.title).contains("Compare With…"),
              items.map(\.title).joined(separator: ", "))
        check("Compare with Selected Trace is off on the selected row itself",
              selectedRowItems.first { $0.title == "Compare with Selected Trace" }?.isEnabled == false)
        if let item = items.first(where: { $0.title == "Compare with Selected Trace" }) {
            let menu = NSMenu()
            menu.addItem(item)
            menu.performActionForItem(at: 0)
        }
        let opened = await waitUntil(5) { compare.comparison != nil && CompareWindow.window != nil }
        check("Compare with Selected Trace opens the Compare Traces window", opened)
        check("A is the selected trace and B the clicked one",
              compare.pair == CompareModel.Pair(a: compareFast, b: compareSlow), "\(String(describing: compare.pair))")
        if let built = compare.lastBuild { INFO("compare open \(Int(built / .milliseconds(1))) ms, 10 and 16 spans") }

        guard let comparison = compare.comparison else { return await finishCompare(model, original) }
        let lines = comparison.differences.map(comparison.line)
        check("the strip names the Error first", lines.first == "Error · Unset → Error · GET /v1/recommendations · checkout-api",
              lines.first ?? "none")
        check("then the 300 ms query, before the spans above it", lines.dropFirst().first == "Slower · +300 ms · SELECT orders · orders",
              lines.dropFirst().first ?? "none")
        check("the strip says 2 → 8 runs", lines.contains("Repeated · 2 → 8 runs · +30 ms · SELECT order_items · orders"))
        check("the strip names the New call and the Missing span",
              lines.contains("New · GET /v1/inventory · orders") && lines.contains("Missing · HGET · checkout-api"))
        check("the header sentence", comparison.totalSentence == "B took 356 ms longer than A (6.6×). B has 6 more spans.",
              comparison.totalSentence)
        check("Queries lists order_items first, 2 → 8",
              comparison.queries.first.map { TraceComparison.runsText($0) == "2 → 8" && $0.service == "orders" } == true)
        if let window = CompareWindow.window { check("the window is titled Compare Traces", window.title == "Compare Traces", window.title) }

        // The tree shows the differences and its cells say them.
        _ = await waitUntil(2) { (compare.outline?.numberOfRows ?? 0) > 0 }
        let shown = compare.outline?.numberOfRows ?? 0
        check("the tree shows rows", shown > 0 && shown == compare.visibleRows.count, "\(shown) rows, \(compare.visibleRows.count) visible")
        if let select = comparison.differences.dropFirst().first {
            model.selectDifference(select)
            func selectedID() -> Int? {
                guard let outline = compare.outline, outline.selectedRow >= 0 else { return nil }
                return (outline.item(atRow: outline.selectedRow) as? CompareItem).map { comparison.rows[$0.index].id }
            }
            _ = await waitUntil(2) { selectedID() == comparison.rows[select.row].id }
            let selectedID = selectedID()
            check("a strip line selects its row in the tree", selectedID == comparison.rows[select.row].id)
            if let outline = compare.outline, outline.selectedRow >= 0,
               let cell = outline.view(atColumn: 0, row: outline.selectedRow, makeIfNecessary: true) as? CompareNameCell,
               let change = outline.view(atColumn: 3, row: outline.selectedRow, makeIfNecessary: true) as? CompareTextCell {
                check("its row shows the Slower mark and +300 ms", cell.shownMark == .slower && change.text == "+300 ms",
                      "\(String(describing: cell.shownMark)) \(change.text)")
            } else {
                check("its row shows the Slower mark and +300 ms", false, "no cell")
            }
        }

        // Show Only Differences, off and on.
        let onlyDifferences = compare.visibleRows.count
        model.toggleOnlyDifferences()
        let all = compare.visibleRows.count
        check("Show Only Differences off opens the tree like a waterfall", !compare.showsOnlyDifferences && all >= onlyDifferences,
              "\(onlyDifferences) → \(all) rows")
        model.toggleOnlyDifferences()
        check("Show Only Differences on again", compare.showsOnlyDifferences && compare.visibleRows.count == onlyDifferences)

        // Swap Traces flips A and B, and the words with them.
        model.swapComparedTraces()
        _ = await waitUntil(5) { compare.comparison?.traceA?.traceID == compareSlow }
        let swapped = compare.comparison
        check("Swap Traces flips A and B", compare.pair == CompareModel.Pair(a: compareSlow, b: compareFast))
        check("swapped, the 300 ms query reads Faster and the cache lookup New",
              swapped.map { c in c.differences.map(c.line).contains("Faster · −300 ms · SELECT orders · orders")
                  && c.differences.map(c.line).contains("New · HGET · checkout-api") } == true)
        model.swapComparedTraces()
        _ = await waitUntil(5) { compare.comparison?.traceA?.traceID == compareFast }

        // Compare With… (⇧⌘K): Search in compare mode, Same Route first, Return compares.
        CompareWindow.close()
        compare.pair = nil
        compare.comparison = nil
        model.selectedTraceID = compareFast
        if let window = MainWindow.window { await ensureKey(window) }
        if let item = menuItem("Compare With…"), let menu = item.menu, let index = menu.items.firstIndex(of: item) {
            // SwiftUI enables the item once the menu state follows the selection.
            _ = await waitUntil(3) { menu.update(); return item.isEnabled }
            if NSApp.keyWindow == nil {
                // SwiftUI disables window commands while no window is key; macOS gives
                // the self-test no key window while you work in another app.
                INFO("no key window (another app is frontmost): Compare With…'s action runs directly")
                model.showCompareSearch()
            } else {
                check("Compare With… is enabled with a trace selected", item.isEnabled,
                      "hasTraceID \(MenuState.shared.hasTraceID), mode \(MenuState.shared.contentMode)")
                menu.performActionForItem(at: index)
            }
        }
        let searching = await waitUntil(3) { model.showsSearch && model.searchCompareBase?.id == compareFast && !model.searchSameRoute.isEmpty }
        check("Compare With… opens Search in compare mode for the selected trace", searching)
        check("its chip reads Compare with GET /account/orders · 64 ms",
              model.searchCompareTitle == "Compare with GET /account/orders · 64 ms", model.searchCompareTitle ?? "nil")
        check("Same Route lists the slow trace first, and never A",
              model.searchTraces.first?.id == compareSlow && model.searchSameRouteCount == 1
                  && !model.searchTraces.contains { $0.id == compareFast })
        model.searchSelection = 0
        model.activateSearchSelection()
        let picked = await waitUntil(5) { compare.comparison != nil }
        check("Return compares A with the picked trace", picked && !model.showsSearch
              && compare.pair == CompareModel.Pair(a: compareFast, b: compareSlow))

        // Open Span in B: the main window shows the slow trace with that span.
        if let comparison = compare.comparison, let index = comparison.rows.firstIndex(where: { $0.title == "SELECT orders" }),
           let spanID = comparison.spanID(of: index, inA: false) {
            model.openComparedSpan(row: index)
            let shownInMain = await waitUntil(5) { model.selectedTraceID == compareSlow && model.selectedSpanID == spanID }
            check("Open Span in B selects the span in the main window's waterfall", shownInMain,
                  "\(model.selectedTraceID ?? "nil") \(model.selectedSpanID ?? "nil")")
        }

        await checkLargeComparison(model)
        await finishCompare(model, original)
    }

    /// Two 30,000-span traces: built off the main actor within the budget,
    /// and shown in the window within one turn of the main run loop.
    private static func checkLargeComparison(_ model: AppModel) async {
        let a = largeTrace(30_000, slow: false)
        let b = largeTrace(30_000, slow: true)
        let read = ComparisonRead(traceA: nil, traceB: nil, spansA: a, spansB: b)
        let started = ContinuousClock.now
        let cpu = CPUTime.process
        let built = await TraceComparison.build(read)
        let ms = started.duration(to: .now) / .milliseconds(1)
        checkTiming("a 30,000 vs 30,000-span comparison builds", ms: ms, budget: 1_000, regression: 1_000,
                    work: CPUTime.process - cpu, ok: built.rows.count > 0 && !built.differences.isEmpty,
                    "\(built.rows.count) rows, \(built.differences.count) differences")
        let compare = model.compare
        CompareWindow.show()
        _ = await waitUntil(2) { CompareWindow.window != nil && compare.outline != nil }
        let shownAt = ContinuousClock.now
        compare.collapsed = built.defaultCollapsed(onlyDifferences: true)
        compare.comparison = built
        compare.pair = CompareModel.Pair(a: "large-a", b: "large-b")
        compare.generation += 1
        CompareWindow.window?.contentView?.layoutSubtreeIfNeeded()
        CompareWindow.window?.displayIfNeeded()
        let shown = shownAt.duration(to: .now) / .milliseconds(1)
        let rows = compare.outline?.numberOfRows ?? 0
        checkTiming("it shows in the window without a main-thread stall over 100 ms", ms: shown, budget: 100, regression: 100,
                    ok: rows > 0 && rows <= Waterfall.autoCollapseLimit + 1, "\(rows) rows on screen")
    }

    /// Root → 100 handlers → 299 spans each: a statement per handler run 150
    /// times (an N+1), and calls; B's statements are 2 ms slower in one handler.
    private static func largeTrace(_ count: Int, slow: Bool) -> [ComparisonSpan] {
        var spans: [ComparisonSpan] = []
        spans.reserveCapacity(count)
        var next = 0
        func add(_ name: String, parent: String?, start: Int64, duration: Int64, url: String? = nil, statement: String? = nil) -> String {
            next += 1
            let id = String(format: "%016x", next)
            spans.append(ComparisonSpan(WaterfallSpan(rowID: Int64(next), spanID: id, parentSpanID: parent, name: name,
                                                      kind: parent == nil ? .server : .client, startNs: start, durationNs: duration,
                                                      serviceName: next % 3 == 0 ? "orders" : "checkout-api"),
                                        httpURL: url, dbStatement: statement))
            return id
        }
        let ms: Int64 = 1_000_000
        let root = add("POST /imports/catalog", parent: nil, start: 0, duration: 60_000 * ms)
        let perHandler = (count - 101) / 100
        for handler in 0..<100 {
            let id = add("import batch \(handler)", parent: root, start: Int64(handler) * 600 * ms, duration: 590 * ms)
            for child in 0..<perHandler {
                let start = Int64(handler) * 600 * ms + Int64(child) * ms
                if child % 2 == 0 {
                    _ = add("INSERT products", parent: id, start: start, duration: (slow && handler == 42 ? 3 : 1) * ms,
                            statement: "INSERT INTO products (sku, name) VALUES ('\(handler)-\(child)', 'item \(child)')")
                } else {
                    _ = add("GET", parent: id, start: start, duration: ms / 2, url: "http://localhost:8082/v1/stock/\(child)")
                }
            }
        }
        while spans.count < count { _ = add("flush", parent: root, start: 59_990 * ms, duration: ms) }
        return spans
    }

    private static func finishCompare(_ model: AppModel, _ original: URL) async {
        CompareWindow.close()
        model.compare.pair = nil
        model.compare.comparison = nil
        MenuState.shared.update(hasComparison: false)
        model.selectedTraceID = nil
        await model.useStore(at: original)
        if let window = MainWindow.window { await ensureKey(window) }
    }

    /// The trace table's context menu items for a trace's row.
    private static func traceRowMenu(_ model: AppModel, trace: String) -> [NSMenuItem] {
        guard let coordinator = traceTable(model), let row = coordinator.rows.firstIndex(where: { $0.id == trace }) else { return [] }
        return coordinator.menuItems(row: row)
    }

    private static func traceTable(_ model: AppModel) -> TraceTableCoordinator? {
        guard let window = MainWindow.window else { return nil }
        return tables(in: window.contentView).lazy.compactMap { $0.delegate as? TraceTableCoordinator }.first
    }

    private static func tables(in view: NSView?) -> [NSTableView] {
        guard let view else { return [] }
        var found: [NSTableView] = []
        var stack = [view]
        while let next = stack.popLast() {
            if let table = next as? NSTableView, !(table is NSOutlineView) { found.append(table) }
            stack.append(contentsOf: next.subviews)
        }
        return found
    }

    private static func INFO(_ text: String) { print("INFO \(text)") }
}
