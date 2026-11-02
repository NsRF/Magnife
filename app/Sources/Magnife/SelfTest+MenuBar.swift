import AppKit
import MagnifeKit

/// S-026 and S-027: the real menu bar extra, opened from code, its items
/// and icon, the count of traces with errors (with traces sent to the seed
/// helper while paused), and a Recent Errors item opening its trace in a
/// main window that was closed.
extension SelfTest {
    static func checkMenuBar(_ model: AppModel) async {
        guard let reader = model.reader else { return check("the menu bar checks have a store", false) }
        model.showContentMode(.traces)
        model.applyTraceFilter(.cleared)
        await model.reload()
        let all = (try? await reader.latestTraces(limit: 100_000)) ?? []
        let failed = all.filter { $0.status == .error }
        check("Recent Errors lists the five newest traces with errors, newest first",
              model.recentErrors.traces.map(\.traceID) == failed.prefix(RecentErrors.limit).map(\.traceID)
                && !failed.isEmpty, "\(model.recentErrors.traces.map(\.route)) of \(failed.count)")

        // Every stored trace with an error counts as new from seq 0.
        model.recentErrors = RecentErrors(mark: 0)
        await model.reload()
        check("the count is the traces with errors since the mark", model.newErrorCount == failed.count,
              "\(model.newErrorCount) of \(failed.count)")
        let red = await waitUntil(2) { MenuBarProbe.statusButton?.image?.isTemplate == false }
        let image = MenuBarProbe.statusButton?.image
        check("the icon turns red with the count drawn beside it",
              red && (image?.size.width ?? 0) > MenuBarGlyph.glyphSize, "\(image?.size ?? .zero)")
        check("VoiceOver reads the icon with the count",
              image?.accessibilityDescription == RecentErrors.iconLabel(count: failed.count), image?.accessibilityDescription ?? "nil")

        guard let menu = await MenuBarProbe.open() else {
            return check("the menu bar extra opens", false, MenuBarProbe.statusButton == nil ? "no status item" : "no menu")
        }
        let opened = model.recentErrorsOpenedAt
        let items = model.recentErrors.traces.map { RecentErrors.itemTitle($0, now: opened) }
        let expected = [model.receiver.text, "—", RecentErrors.title] + items
            + ["—", "Open Magnife", TraceList.pauseTitle(isPaused: model.isPaused), "Copy Environment Variables",
               "—", "Settings…", "Quit Magnife"]
        check("the menu reads status, Recent Errors and the actions (docs/ux.md)", MenuBarProbe.titles(menu) == expected,
              "\(MenuBarProbe.titles(menu))")
        check("the receiver line is not an action", menu.items.first?.isEnabled == false)
        let newest = model.recentErrors.traces.first
        check("items read \"POST /orders · checkout-api · 2 min ago\"",
              newest.map { items.first == "\($0.route) · \($0.rootService) · \(RelativeTime.string(for: $0.start, now: opened))" } == true
                && items.allSatisfy { $0.hasSuffix(" ago") || $0.hasSuffix("Just now") }, "\(items)")
        let template = await waitUntil(2) { MenuBarProbe.statusButton?.image?.isTemplate == true }
        check("opening the menu resets the count and the icon",
              model.newErrorCount == 0 && model.recentErrors.mark == model.recentErrors.lastSeq && template)
        await MenuBarProbe.close(menu)
        check("the menu closes", !(MenuBarProbe.statusButton?.isHighlighted ?? false))
        await checkMenuBarCounting(model, reader: reader)
        await checkMenuBarCost(model)
        await checkMenuBarPause(model)
        await checkMenuBarWindows(model)
        await checkOpenFailedTrace(model)
    }

    /// Traces with errors that arrive while paused still count (docs/ux.md, S-010 States).
    private static func checkMenuBarCounting(_ model: AppModel, reader: TelemetryReader) async {
        let env = ProcessInfo.processInfo.environment
        guard let sender = env["APP_SAMPLE_SENDER"].map(URL.init(fileURLWithPath:)),
              let grpc = env["APP_SEED_GRPC"], let http = env["APP_SEED_HTTP"] else {
            return check("APP_SEED_GRPC and APP_SEED_HTTP name the seed helper (tools/selftest.sh)", false)
        }
        model.recentErrorsMenuOpened()
        let mark = model.recentErrors.mark ?? 0
        model.pause()
        let result = await run(sender, ["--protocol", "http-protobuf", "--scenarios", "exception", "--volume", "6",
                                        "--grpc", grpc, "--http", http])
        let sent = result.output.firstMatch(of: /(\d+) spans in (\d+) traces/).flatMap { Int($0.2) } ?? 0
        var arrived = 0
        for _ in 0..<50 {
            arrived = (try? await reader.recentErrors(changedAfter: mark).newCount) ?? 0
            if arrived >= sent { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        await model.reload()
        check("traces with errors that arrive while paused count up",
              sent > 0 && arrived >= sent && model.newErrorCount == arrived, "sent \(sent), counted \(model.newErrorCount)")
        let red = await waitUntil(2) { MenuBarProbe.statusButton?.image?.isTemplate == false }
        check("the icon is red again with them", red)
        model.resume()
        _ = await waitUntil(3) { !model.isPaused }
    }

    /// What a new count and list cost the main thread: the icon and the
    /// menu are rebuilt each time they change (once per refresh in a burst).
    private static func checkMenuBarCost(_ model: AppModel) async {
        let traces = model.recentErrors.traces
        let mark = model.recentErrors.mark
        let heartbeat = Heartbeat()
        heartbeat.start()
        for count in 1...20 {
            model.recentErrors.apply(RecentErrorsPage(traces: count.isMultiple(of: 2) ? traces : traces.reversed(),
                                                      newCount: count, mark: mark, lastSeq: model.recentErrors.lastSeq))
            try? await Task.sleep(for: .milliseconds(50))
        }
        let stall = heartbeat.stop()
        print("INFO menu bar: 20 changes of the count and the list, longest main-actor stall \(String(format: "%.0f", stall)) ms")
        // The hang budget of S-030; about 15 ms each for the icon and the menu here.
        checkTiming("a new count and list do not stall the main thread over 100 ms", ms: stall, budget: 100)
        model.recentErrorsMenuOpened()
    }

    /// Pause and Resume from the menu: the same toggle as the toolbar's.
    private static func checkMenuBarPause(_ model: AppModel) async {
        guard let menu = await MenuBarProbe.open() else { return check("the menu reopens", false) }
        let pause = menu.items.firstIndex { $0.title == "Pause" }
        await MenuBarProbe.close(menu)
        if let pause { menu.performActionForItem(at: pause) }
        check("Pause in the menu pauses the list", await waitUntil(2) { model.isPaused })
        guard let again = await MenuBarProbe.open() else { return check("the menu reopens", false) }
        let resume = again.items.firstIndex { $0.title == "Resume" }
        await MenuBarProbe.close(again)
        check("the menu then reads Resume", resume != nil, "\(MenuBarProbe.titles(again))")
        if let resume { again.performActionForItem(at: resume) }
        check("Resume in the menu resumes it", await waitUntil(3) { !model.isPaused })
    }

    /// S-027: a Recent Errors item with the main window closed.
    private static func checkOpenFailedTrace(_ model: AppModel) async {
        model.selectedTraceID = nil
        for window in NSApp.windows where window.canBecomeMain { window.close() }
        _ = await waitUntil(2) { MainWindow.window == nil }
        guard let menu = await MenuBarProbe.open() else { return check("the menu opens for S-027", false) }
        // The newest: earlier checks sent traces with errors after the seed set.
        let trace = model.recentErrors.traces.first
        let index = menu.items.firstIndex { item in trace.map { item.title.hasPrefix("\($0.route) · \($0.rootService) · ") } == true }
        await MenuBarProbe.close(menu)
        guard let index, let trace else { return check("Recent Errors has an item for its newest trace", false) }
        let started = ContinuousClock.now
        menu.performActionForItem(at: index)
        let shown = await waitUntil(5) {
            model.selectedTraceID == trace.traceID && !model.waterfall.isEmpty && model.selectedSpanID != nil
                && model.spanDetail?.span.spanID == model.selectedSpanID
                && model.waterfallOutline.map { $0.window?.firstResponder === $0 } == true
        }
        print("INFO Recent Errors item to the focused Error span: \(started.duration(to: .now)); app active "
              + "\(NSApp.isActive), window key \(MainWindow.window?.isKeyWindow ?? false), frontmost "
              + "\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none")")
        check("choosing a trace brings a closed main window back", MainWindow.window?.isVisible == true)
        check("the trace is selected and open in the detail column", shown && model.openTrace?.traceID == trace.traceID,
              "\(model.selectedTraceID ?? "nil")")
        check("its earliest-starting Error span is selected",
              model.selectedSpanID != nil && model.selectedSpanID == model.waterfall.firstErrorSpanID
                && model.waterfall.node(model.selectedSpanID ?? "")?.span.status == .error)
        check("the span detail shows on Span", model.showsSpanDetail && model.spanDetailTab == .span)
        check("the focus is in the waterfall on that span",
              model.waterfallOutline.map { $0.window?.firstResponder === $0 } == true)
        check("the list selects the trace", model.traces.contains { $0.id == trace.traceID })

        // The exception scenario's trace: its Error span carries the exception, shown in the span detail.
        if let other = model.recentErrors.traces.first(where: { $0.route == "inventory.reconcile" }) {
            model.openFailedTrace(other.traceID)
            let ok = await waitUntil(3) {
                model.selectedSpanID == model.waterfall.firstErrorSpanID && model.selectedSpanID != nil
                    && model.spanDetail?.span.spanID == model.selectedSpanID
            }
            check("a failed span with an exception opens on Exception",
                  ok && model.spanDetail?.sections.first == .exception,
                  "\(model.spanDetail?.sections.map(\.rawValue) ?? [])")
        }

        // Hidden by the filters: no selection in the list, the trace still in the detail column.
        model.traceStatuses = [.ok]
        _ = await waitUntil(3) { !model.isLoadingScope }
        model.openFailedTrace(trace.traceID)
        let hidden = await waitUntil(3) { model.openTrace?.traceID == trace.traceID && !model.waterfall.isEmpty }
        check("a trace the filters hide still opens, with no row selected",
              hidden && !model.traces.contains { $0.id == trace.traceID })
        model.applyTraceFilter(.cleared)

        // Pruned since the menu opened.
        model.openFailedTrace(String(repeating: "f", count: 32))
        check("a trace no longer stored says so", await waitUntil(3) { model.showsTraceNoLongerStored })
        model.selectedTraceID = nil
    }

    /// Open Magnife and Settings… from the menu, with the main window closed.
    private static func checkMenuBarWindows(_ model: AppModel) async {
        for window in NSApp.windows where window.canBecomeMain { window.close() }
        _ = await waitUntil(2) { MainWindow.window == nil }
        if let menu = await MenuBarProbe.open(), let open = menu.items.firstIndex(where: { $0.title == "Open Magnife" }),
           let settings = menu.items.firstIndex(where: { $0.title == "Settings…" }) {
            await MenuBarProbe.close(menu)
            menu.performActionForItem(at: open)
            check("Open Magnife brings the main window back", await waitUntil(3) { MainWindow.window?.isVisible == true })
            let main = MainWindow.window
            menu.performActionForItem(at: settings)
            func isSettings(_ window: NSWindow) -> Bool {
                window.isVisible && window !== main && window.canBecomeKey && !window.isSheet
                    && !String(describing: type(of: window)).contains("StatusBar")
            }
            check("Settings… opens the Settings window", await waitUntil(3) { NSApp.windows.contains(where: isSettings) })
            for window in NSApp.windows where isSettings(window) { window.close() }
        } else {
            check("the menu has Open Magnife and Settings…", false)
        }
        // The Settings toggle's setting (on by default) inserts and removes the status item.
        AppDefaults.shared.set(false, forKey: MenuBarSettings.showsKey)
        check("turning off \"Show Magnife in the menu bar\" removes the icon",
              await waitUntil(3) { MenuBarTracking.statusItemVisible == false })
        AppDefaults.shared.set(true, forKey: MenuBarSettings.showsKey)
        check("turning it on brings the icon back", await waitUntil(3) { MenuBarTracking.statusItemVisible == true })
    }
}
