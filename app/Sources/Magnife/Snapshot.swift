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
        model.sidebar = .allTraces
        model.selectedTraceID = nil
        switch self {
        case .emptyState, .traceList, .logs, .commandK, .menuBar, .settings:
            break
        case .traceDetail, .spanDetail:
            // The newest trace with an Error span (the seed set's exception).
            model.selectedTraceID = model.traces.first { $0.status == .error }?.traceID
        case .filterBar:
            model.sidebar = .service("checkout-api")
        }
        await model.reload()
    }
}

/// Screenshot mode for agents.
///   APP_STORE=/tmp/Magnife-test.sqlite APP_HELPER=none APP_SNAPSHOT=/tmp/Magnife-shots ~/Applications/Magnife.app/Contents/MacOS/Magnife
/// writes <page>-light.png and <page>-dark.png for every SnapshotPage,
/// 02-trace-list-busy and 02-trace-list-not-receiving (the busy-port banners),
/// and 09-settings-<tab>-light.png and -dark.png for every Settings tab, then quits.
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
            for mode in ["light", "dark"] {
                NSApp.appearance = NSAppearance(named: mode == "light" ? .aqua : .darkAqua)
                for page in pages where page != .settings {
                    await page.prepare(model)
                    try? await Task.sleep(for: .seconds(0.8))
                    capture(to: "\(dir)/\(page.rawValue)-\(mode).png")
                    if page == .traceList { await captureReceiverStates(model, dir: dir, mode: mode) }
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
    /// otelcol-contrib) and 02-trace-list-not-receiving (both ports held).
    /// APP_HELPER=none has no helper, so these replay its "ports" lines.
    private static func captureReceiverStates(_ model: AppModel, dir: String, mode: String) async {
        let page = SnapshotPage.traceList.rawValue
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
        model.showReceiverListening()
    }

    /// Captures the real window with screencapture, so glass, sidebars, and
    /// materials look exactly as on screen. That needs Screen Recording
    /// permission for the app that started this one (your terminal, or Claude).
    /// Without it, falls back to drawing the view hierarchy, which leaves
    /// sidebars and glass blank.
    private static func capture(to path: String, window: NSWindow? = nil) {
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
