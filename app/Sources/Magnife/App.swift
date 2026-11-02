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
                Button("Copy Span ID") { delegate.model.copySpanID() }
                    .disabled(!menu.hasWaterfall)
                Button("Copy Stack Trace") { delegate.model.copyStackTrace() }
                    .disabled(!menu.hasStackTrace)
                Button("Copy Body") {
                    menu.contentMode == .logs ? delegate.model.copySelectedListLogBody() : delegate.model.copySelectedLogBody()
                }
                    .disabled(!menu.hasSelectedLog)
                Button("Copy Environment Variables") { delegate.model.copyEnvironmentVariables() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                Divider()
                // Search (S-017): from anywhere in the window, text fields included.
                Button("Search…") { delegate.model.showSearch() }
                    .keyboardShortcut("k", modifiers: .command)
            }
            CommandGroup(before: .sidebar) {
                // Traces | Logs (docs/ux.md, View menu; PROGRESS decision 16).
                Button(ContentMode.traces.title) { delegate.model.showContentMode(.traces) }
                    .keyboardShortcut("1", modifiers: .command)
                Button(ContentMode.logs.title) { delegate.model.showContentMode(.logs) }
                    .keyboardShortcut("2", modifiers: .command)
                Divider()
                // The Logs filter bar (S-014); the Traces one comes with S-018.
                Button(menu.filterBar == .shown ? "Hide Filter Bar" : "Show Filter Bar") {
                    delegate.model.toggleLogFilterBar(focusField: true)
                }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(menu.filterBar == .unavailable)
                Button("Clear Filters") { delegate.model.clearFilters(undoManager: NSApp.mainWindow?.undoManager) }
                    .disabled(!menu.hasFilters)
                Divider()
                // The span detail belongs to the Traces view.
                Button(menu.showsSpanDetail ? "Hide Span Detail" : "Show Span Detail") { delegate.model.toggleSpanDetail() }
                    .keyboardShortcut("i", modifiers: [.command, .control])
                    .disabled(menu.contentMode != .traces)
                // The span detail's tabs (docs/ux.md, View menu).
                Button(SpanDetailTab.span.title) { delegate.model.showSpanDetailTab(.span) }
                    .keyboardShortcut("1", modifiers: [.command, .option])
                    .disabled(!menu.hasWaterfall || menu.contentMode != .traces)
                Button(SpanDetailTab.traceLogs.title) { delegate.model.showSpanDetailTab(.traceLogs) }
                    .keyboardShortcut("2", modifiers: [.command, .option])
                    .disabled(!menu.hasWaterfall || menu.contentMode != .traces)
                Divider()
            }
            CommandMenu("Trace") {
                // ⌃⌘P, not ⌘P, which is Print (docs/ux.md, Keyboard map).
                Button(TraceList.pauseTitle(isPaused: menu.isPaused)) { delegate.model.togglePause() }
                    .keyboardShortcut("p", modifiers: [.command, .control])
                Button(menu.contentMode == .logs ? "Show Newest Logs" : "Show Newest Traces") {
                    delegate.model.showNewestRows()
                }
                .disabled(menu.newTraceCount == 0)
                Divider()
                // The selected log's trace, from the Logs view (S-013).
                Button("Open Trace") { delegate.model.openSelectedLogTrace() }
                    .keyboardShortcut("o", modifiers: .command)
                    .disabled(!menu.canOpenTrace)
                Divider()
                Button("Expand All Spans") { delegate.model.expandAllSpans() }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                    .disabled(!menu.hasWaterfall || menu.contentMode != .traces)
                Button("Collapse All Spans") { delegate.model.collapseAllSpans() }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                    .disabled(!menu.hasWaterfall || menu.contentMode != .traces)
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
