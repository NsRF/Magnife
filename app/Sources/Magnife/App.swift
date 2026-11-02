import AppKit
import MagnifeKit
import SwiftUI

// Magnife
//   Magnife                        the app: starts the helper, reads its database
//   APP_STORE=<file> Magnife       read another database (tests, snapshots; /tmp only for those)
//   APP_HELPER=none Magnife        do not start the helper (tests, snapshots, self-test)
//   APP_HELPER=<path> Magnife      start another helper executable
//   APP_GRPC_PORT / APP_HTTP_PORT  the helper's ports, 4317 and 4318 by default
//   APP_SNAPSHOT=<dir> Magnife     save a PNG of every page in SnapshotPage in light and dark mode, then quit
//   APP_SNAPSHOT_PAGES=02-trace-list,09-settings   only these pages
//   Magnife --selftest             run the self-test on a /tmp store and quit with 0 or 1 (tools/selftest.sh)
//   APP_ACCENT=<id> Magnife        run with another accent from Theme.all (UI/Theme.swift)
//   APP_GRID=1 Magnife             draw the 8 pt grid and the layout probes over the window

@main
struct MagnifeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    /// SwiftUI commands do not observe AppModel; this rebuilds them.
    @ObservedObject private var menu = MenuState.shared

    var body: some Scene {
        // A WindowGroup, not a Window: closing the last window keeps Magnife
        // running and receiving (research/platform.md, decision 7).
        WindowGroup("Magnife", id: "main") {
            ContentView()
                .environment(delegate.model)
                .themed()
                .overlay { if GridOverlay.enabled { GridOverlay() } }
                .frame(minWidth: 960, minHeight: 520)
        }
        .defaultSize(width: 1280, height: 760)
        .windowToolbarStyle(.unified)
        .commands {
            SidebarCommands()
            ToolbarCommands()
            // One window: its selection lives in AppModel. Clicking the Dock icon reopens it.
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Copy Environment Variables") { delegate.model.copyEnvironmentVariables() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
            }
            CommandMenu("Trace") {
                Button("Show Newest Traces") { delegate.model.showNewestTraces() }
                    .disabled(menu.newTraceCount == 0)
                Divider()
                Button("Expand All Spans") { delegate.model.expandAllSpans() }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                    .disabled(!menu.hasWaterfall)
                Button("Collapse All Spans") { delegate.model.collapseAllSpans() }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                    .disabled(!menu.hasWaterfall)
            }
            // No help book in v0.1 (docs/ux.md, Help menu).
            CommandGroup(replacing: .help) {
                Button("Show Environment Variables") { delegate.model.showEnvironmentVariables() }
            }
        }

        Settings {
            SettingsView()
                .environment(delegate.model)
                .themed()
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Started from a terminal, the process is not a foreground app yet.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        model.start()
    }

    /// The window can close; the receiver keeps running until Quit Magnife.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Stops the helper and waits for it, so a relaunch can bind the ports at
    /// once (platform decision 6). The self-test's result becomes the exit code.
    func applicationWillTerminate(_ notification: Notification) {
        model.stopHelper()
        if SelfTest.requested { exit(SelfTest.exitCode) }
    }
}
