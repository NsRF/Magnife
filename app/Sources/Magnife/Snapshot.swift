import AppKit
import IOKit.pwr_mgt
import MagnifeKit
import SwiftUI

/// The snapshot pages, from docs/STORIES.md. Each one puts the app in its
/// state before the capture. Pages whose story is not built yet capture the
/// closest state that exists; their stories fill them in.
enum SnapshotPage: String, CaseIterable {
    case emptyState = "01-empty-state"
    case traceList = "02-trace-list"
    case traceDetail = "03-trace-detail"
    case spanDetail = "04-span-detail"
    case logs = "05-logs"
    case commandK = "06-command-k"
    case filterBar = "07-filter-bar"
    case menuBar = "08-menu-bar"
    case settings = "09-settings"

    /// The schema-only database next to APP_STORE (tools/snap.sh makes both).
    static func emptyStore(next store: URL) -> URL {
        store.deletingPathExtension().appendingPathExtension("empty.sqlite")
    }

    @MainActor
    func prepare(_ model: AppModel) async {
        let store = model.storeURL
        if self == .emptyState {
            await model.useStore(at: Self.emptyStore(next: store))
        } else if model.reader?.url != store {
            await model.useStore(at: store)
        }
        model.closeSearch()
        model.applyTraceFilter(.cleared)
        model.showsTraceFilterBar = false
        model.selectedTraceID = nil
        model.selectedLogID = nil
        model.showContentMode(self == .logs ? .logs : .traces)
        // The first page of a run can come before the store opened and the list was read.
        await model.openStore()
        if model.traces.isEmpty { await model.reload() }
        switch self {
        case .emptyState, .traceList, .menuBar, .settings:
            break
        case .commandK:
            await Self.search(model, "checkout")
        case .logs:
            await model.reload()
            // The HTTP 500 trace's ERROR log: a trace and a span to open.
            model.selectedLogID = model.logs.first { $0.record.body.hasPrefix("Payment for order") }?.id
                ?? model.logs.first { $0.canOpenTrace }?.id
        case .traceDetail, .spanDetail:
            // The HTTP 500 trace: three services nested two levels, an Error span.
            model.selectedTraceID = (model.traces.first { $0.route == "POST /checkout/pay" }
                ?? model.traces.first { $0.status == .error })?.traceID
        case .filterBar:
            // The bar with Error on: the failed checkout (S-018).
            model.showsTraceFilterBar = true
            model.clickStatusChip(.error, adding: false)
        }
        await model.reload()
        if self == .logs {
            for _ in 0..<40 where model.logDetail == nil { try? await Task.sleep(for: .milliseconds(50)) }
        }
        if self == .spanDetail {
            // The failed checkout-api span: attributes, the exception event, the resource.
            await Self.select(model) { $0.name == "POST /payments" }
        }
    }

    /// Selects the first span of the open waterfall that matches, once the
    /// waterfall is built, and waits for its detail.
    @MainActor
    static func select(_ model: AppModel, span matches: (WaterfallSpan) -> Bool) async {
        for _ in 0..<60 where model.waterfall.isEmpty { try? await Task.sleep(for: .milliseconds(50)) }
        guard let id = model.waterfall.nodes.first(where: { matches($0.span) })?.span.spanID else {
            return print("SNAPSHOT no matching span")
        }
        model.selectedSpanID = id
        for _ in 0..<60 where model.spanDetail?.span.spanID != id { try? await Task.sleep(for: .milliseconds(50)) }
    }
}

/// Screenshot mode for agents.
///   APP_STORE=/tmp/Magnife-test.sqlite APP_HELPER=none APP_SNAPSHOT=/tmp/Magnife-shots ~/Applications/Magnife.app/Contents/MacOS/Magnife
/// writes <page>-light.png and <page>-dark.png for every SnapshotPage,
/// 02-trace-list-busy and 02-trace-list-not-receiving (the busy-port banners),
/// 02-trace-list-restarted (the S-008 banner), 02-trace-list-service (S-009),
/// 02-trace-list-paused (S-010), 04-span-detail-logs and -log-json (S-011),
/// 03-trace-detail-trace-logs (S-012), 03-trace-detail-no-longer-stored (S-015), 05-logs-no-trace, -new-logs, -paused and -empty (S-013),
/// 05-logs-filtered, -filter-hidden and -no-matches (S-014),
/// 06-command-k (Search for "checkout"), -empty, -suggestions, -tokens and -no-match (S-017),
/// 07-filter-bar (Error on) and -no-matches (OK on, a hidden trace still in the detail column) (S-018),
/// 02-trace-list-saved-filter, -edited and -rename, 07-filter-bar-save and -save-duplicate (S-021),
/// and 09-settings-<tab>-light.png and -dark.png for every Settings tab,
/// and 09-settings-general-delete (S-016's dialog), then quits.
/// Each PNG gets a <page>-<mode>-layout.json with the grid probes (tools/check-layout.swift).
/// APP_SNAPSHOT_PAGES=02-trace-list,09-settings limits the pages.
/// Add APP_ACCENT=<id> to see the pages in another accent.
enum Snapshot {
    private static var started = false

    static func runIfRequested(model: AppModel, openSettings: OpenSettingsAction) {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["APP_SNAPSHOT"], !dir.isEmpty, !started else { return }
        started = true
        // Snapshots never run against the real database.
        guard StoreLocation.isOverridden(), StoreLocation.isTestLocation(model.storeURL) else {
            print("SNAPSHOT refused: set APP_STORE to a file in /tmp")
            NSApp.terminate(nil)
            return
        }
        let only = env["APP_SNAPSHOT_PAGES"].map { Set($0.split(separator: ",").map(String.init)) }
        let pages = SnapshotPage.allCases.filter { only?.contains($0.rawValue) ?? true }
        Task {
            // A sleeping display gives screencapture nothing. Declaring user
            // activity wakes it; the assertion keeps it on until the run quits.
            var activity: IOPMAssertionID = 0
            IOPMAssertionDeclareUserActivity("Snapshots" as CFString, kIOPMUserActiveLocal, &activity)
            var awake: IOPMAssertionID = 0
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn), "Snapshots" as CFString, &awake)
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? await Task.sleep(for: .seconds(1.5))
            if model.receiver == .starting { model.showReceiverListening() }
            seedSavedFilter(model)
            for mode in ["light", "dark"] {
                NSApp.appearance = NSAppearance(named: mode == "light" ? .aqua : .darkAqua)
                for page in pages where page != .settings {
                    await page.prepare(model)
                    try? await Task.sleep(for: .seconds(0.8))
                    capture(to: "\(dir)/\(page.rawValue)-\(mode).png")
                    if page == .emptyState { await captureCopied(model, dir: dir, mode: mode) }
                    if page == .traceDetail {
                        await captureTraceLogs(model, dir: dir, mode: mode)
                        await captureNoLongerStored(model, dir: dir, mode: mode)
                    }
                    if page == .logs { await captureLogStates(model, dir: dir, mode: mode) }
                    if page == .commandK { await captureSearchStates(model, dir: dir, mode: mode) }
                    if page == .filterBar {
                        await captureFilterBarStates(model, dir: dir, mode: mode)
                        await captureSaveSheet(model, dir: dir, mode: mode)
                    }
                    if page == .spanDetail {
                        await captureSpanEvents(model, dir: dir, mode: mode)
                        await captureSpanLogs(model, dir: dir, mode: mode)
                    }
                    if page == .traceList {
                        await captureReceiverStates(model, dir: dir, mode: mode)
                        await captureEnvironmentPopover(model, dir: dir, mode: mode)
                        await captureNewTraces(model, dir: dir, mode: mode)
                        await captureServiceScope(model, dir: dir, mode: mode)
                        await capturePaused(model, dir: dir, mode: mode)
                        await captureSavedFilter(model, dir: dir, mode: mode)
                    }
                }
            }
            if pages.contains(.settings) {
                await SnapshotPage.settings.prepare(model)
                let main = NSApp.windows.first { $0.canBecomeMain && !$0.isSheet }
                openSettings()
                try? await Task.sleep(for: .seconds(1))
                for mode in ["light", "dark"] {
                    NSApp.appearance = NSAppearance(named: mode == "light" ? .aqua : .darkAqua)
                    for tab in SettingsTab.allCases {
                        model.settingsTab = tab
                        try? await Task.sleep(for: .seconds(0.8))
                        let settings = NSApp.windows.first { $0.isVisible && $0 !== main && !$0.isSheet }
                        capture(to: "\(dir)/\(SnapshotPage.settings.rawValue)-\(tab.rawValue)-\(mode).png", window: settings)
                        if tab == .general, let settings { await captureRetentionDialog(model, settings: settings, dir: dir, mode: mode) }
                    }
                }
            }
            print("SNAPSHOT done \(dir)")
            // An open sheet refuses terminate, and the run would wait forever.
            for window in NSApp.windows { if let sheet = window.attachedSheet { window.endSheet(sheet) } }
            NSApp.terminate(nil)
        }
    }

    /// The S-001 / S-002 banners: 02-trace-list-busy (one port held by
    /// otelcol-contrib) and 02-trace-list-not-receiving (both ports held), and
    /// the S-008 banner: 02-trace-list-restarted.
    /// APP_HELPER=none has no helper, so these replay its "ports" lines.
    private static func captureReceiverStates(_ model: AppModel, dir: String, mode: String) async {
        let page = SnapshotPage.traceList.rawValue
        // A run with a real helper (APP_HELPER set) gets its real state back afterwards.
        let real = model.receiver
        let grpc = PortStatus(addr: "127.0.0.1:4317", state: .listening)
        let http = PortStatus(addr: "127.0.0.1:4318", state: .listening)
        var busyHTTP = http
        busyHTTP.state = .busy
        busyHTTP.owner = "otelcol-contrib"
        var busyGRPC = grpc
        busyGRPC.state = .busy
        busyGRPC.owner = "jaeger-all-in-one"
        for (name, ports) in [("busy", ReceiverPorts(grpc: grpc, http: busyHTTP)),
                              ("not-receiving", ReceiverPorts(grpc: busyGRPC, http: busyHTTP))] {
            model.handle(.helper(.ports(ports)))
            try? await Task.sleep(for: .seconds(0.8))
            capture(to: "\(dir)/\(page)-\(name)-\(mode).png")
        }
        model.receiver = real
        // 02-trace-list-restarted: the S-008 banner, as after a helper crash and restart.
        model.handle(.started(pid: 0, restart: true))
        try? await Task.sleep(for: .seconds(0.8))
        capture(to: "\(dir)/\(page)-restarted-\(mode).png")
        model.receiverRestarted = false
        model.receiver = real
    }

    /// 01-empty-state-copied: the button reads "Copied" and "Waiting for the
    /// first trace…" shows (S-003). Copies to a private pasteboard.
    private static func captureCopied(_ model: AppModel, dir: String, mode: String) async {
        model.environmentLanguage = .python
        model.copyEnvironmentVariables(to: NSPasteboard(name: NSPasteboard.Name("Magnife.snapshot")))
        try? await Task.sleep(for: .seconds(0.5))
        capture(to: "\(dir)/\(SnapshotPage.emptyState.rawValue)-copied-\(mode).png")
        model.environmentLanguage = .defaultLanguage
        model.environmentCopied = false
        model.hasCopiedEnvironment = false
    }

    /// 04-span-detail-events: the orders gRPC server span of the healthy
    /// trace, with otelgrpc's two message events, scrolled to Events (S-006).
    /// 04-span-detail-long-value: a statement longer than three lines.
    /// 04-span-detail-copied: Copy Stack Trace right after a click.
    private static func captureSpanEvents(_ model: AppModel, dir: String, mode: String) async {
        // 04-span-detail-copied: Copy Stack Trace reads "Copied" (S-007). A private pasteboard.
        model.spanDetailScrollAnchor = .bottom
        model.spanDetailScrollTarget = .exception
        try? await Task.sleep(for: .seconds(0.3))
        model.spanDetailScrollAnchor = .top
        model.copyStackTrace(at: 0, to: NSPasteboard(name: NSPasteboard.Name("Magnife.snapshot")))
        try? await Task.sleep(for: .seconds(0.5))
        capture(to: "\(dir)/\(SnapshotPage.spanDetail.rawValue)-copied-\(mode).png")

        model.selectedTraceID = model.traces.first { $0.route == "GET /checkout" }?.traceID
        await SnapshotPage.select(model) { $0.serviceName == "orders" && $0.kind == .server }
        try? await Task.sleep(for: .seconds(0.5))
        model.spanDetailScrollTarget = .events
        try? await Task.sleep(for: .seconds(0.8))
        capture(to: "\(dir)/\(SnapshotPage.spanDetail.rawValue)-events-\(mode).png")

        // 04-span-detail-long-value: the slow query's statement, cut after three lines with "Show All".
        model.selectedTraceID = model.traces.first { $0.route == "GET /admin/reports" }?.traceID
        await SnapshotPage.select(model) { $0.name == "SELECT Orders" }
        try? await Task.sleep(for: .seconds(0.8))
        capture(to: "\(dir)/\(SnapshotPage.spanDetail.rawValue)-long-value-\(mode).png")
    }

    /// 02-trace-list-new-traces: the "12 new traces" button over a list that
    /// holds still (S-004). The seed set fits the window, so this sets the
    /// held state instead of scrolling; the self-test scrolls for real.
    private static func captureNewTraces(_ model: AppModel, dir: String, mode: String) async {
        model.holdListForSnapshot(newTraces: 12)
        try? await Task.sleep(for: .seconds(0.8))
        capture(to: "\(dir)/\(SnapshotPage.traceList.rawValue)-new-traces-\(mode).png")
        model.holdListForSnapshot(newTraces: 0)
    }

    /// 02-trace-list-environment: the toolbar's Copy Environment Variables
    /// popover over the list (S-003). The popover is its own window.
    private static func captureEnvironmentPopover(_ model: AppModel, dir: String, mode: String) async {
        let main = NSApp.windows.first { $0.canBecomeMain && !$0.isSheet }
        model.showsEnvironmentPopover = true
        try? await Task.sleep(for: .seconds(0.8))
        let popover = NSApp.windows.first { $0.isVisible && $0 !== main && String(describing: type(of: $0)).contains("Popover") }
        if let popover, let main {
            // `-l` on a popover window takes its parent too; crop to the popover.
            let path = "\(dir)/\(SnapshotPage.traceList.rawValue)-environment-\(mode).png"
            capture(to: path, window: popover)
            crop(path, to: popover.frame, within: main.frame.union(popover.frame))
        } else {
            print("SNAPSHOT no popover window")
        }
        model.showsEnvironmentPopover = false
        try? await Task.sleep(for: .seconds(0.4))
    }

    /// Cuts `rect` (screen points) out of a capture that covers `bounds`.
    private static func crop(_ path: String, to rect: NSRect, within bounds: NSRect) {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
        // The capture may not cover the whole union; scale from its real size.
        let factor = CGFloat(image.width) / bounds.width
        let cut = CGRect(x: (rect.minX - bounds.minX) * factor, y: (bounds.maxY - rect.maxY) * factor,
                         width: rect.width * factor, height: rect.height * factor).integral
        guard let cropped = image.cropping(to: cut),
              let out = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(out, cropped, nil)
        CGImageDestinationFinalize(out)
    }

    /// Captures the real window with screencapture, so glass, sidebars, and
    /// materials look exactly as on screen. That needs Screen Recording
    /// permission for the app that started this one (your terminal, or Claude).
    /// Without it, falls back to drawing the view hierarchy, which leaves
    /// sidebars and glass blank.
    static func capture(to path: String, window: NSWindow? = nil) {
        // Another app can hide this one while snapshots run (computer use hides
        // apps it does not control). Hidden windows cannot be captured.
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        guard let window = window ?? NSApp.windows.first(where: { $0.canBecomeMain && !$0.isSheet }) else {
            print("SNAPSHOT no window")
            return
        }
        // Active, like a window someone is using: real accent colors and focus rings.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        let size = window.contentView?.bounds.size ?? .zero
        GridProbes.shared.write(to: path.replacingOccurrences(of: ".png", with: "-layout.json"), window: size)
        try? FileManager.default.removeItem(atPath: path)
        // The first capture of a run sometimes misses the window. Try three times.
        for _ in 1...3 {
            let shot = Process()
            shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            shot.arguments = ["-x", "-o", "-l", String(window.windowNumber), path]
            try? shot.run()
            shot.waitUntilExit()
            if FileManager.default.fileExists(atPath: path) {
                print("SNAPSHOT \(path)")
                return
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
            print("SNAPSHOT \(path) (fallback: no Screen Recording permission, sidebars and glass are blank)")
        }
    }
}
