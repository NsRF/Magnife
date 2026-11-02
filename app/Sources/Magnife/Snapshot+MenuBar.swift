import AppKit
import MagnifeKit

/// Snapshot states for the menu bar extra (S-026, S-027), from the real
/// status item and its real menu.
extension Snapshot {
    /// 08-menu-bar: the menu open with the seed set's traces with errors;
    /// 08-menu-bar-icon: the status item, red with the count since the menu
    /// was last opened; 08-menu-bar-empty: "No traces with errors" and the
    /// template icon (the schema-only store); 03-trace-detail-from-menu: a
    /// Recent Errors item chosen, the window brought forward (S-027).
    static func captureMenuBar(_ model: AppModel, dir: String, mode: String) async {
        let page = SnapshotPage.menuBar.rawValue
        // Every trace with an error counts as new: the count starts before the seed set.
        model.recentErrors = RecentErrors(mark: 0)
        await model.reload()
        try? await Task.sleep(for: .seconds(0.5))
        captureStatusItem(to: "\(dir)/\(page)-icon-\(mode).png")
        guard let menu = await MenuBarProbe.open() else { return print("SNAPSHOT no menu bar extra menu") }
        captureMenu(to: "\(dir)/\(page)-\(mode).png")
        await MenuBarProbe.close(menu)

        // S-027: the HTTP 500 trace's item, as a click on it runs it.
        if let menu = await MenuBarProbe.open() {
            let index = menu.items.firstIndex { $0.title.hasPrefix("POST /checkout/pay") }
            await MenuBarProbe.close(menu)
            if let index {
                menu.performActionForItem(at: index)
                for _ in 0..<60 where model.spanDetail == nil || model.selectedSpanID != model.waterfall.firstErrorSpanID {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                try? await Task.sleep(for: .seconds(0.8))
                capture(to: "\(dir)/\(SnapshotPage.traceDetail.rawValue)-from-menu-\(mode).png")
            } else {
                print("SNAPSHOT no POST /checkout/pay item")
            }
        }
        model.selectedTraceID = nil

        await model.useStore(at: SnapshotPage.emptyStore(next: model.storeURL))
        try? await Task.sleep(for: .seconds(0.5))
        if let menu = await MenuBarProbe.open() {
            captureMenu(to: "\(dir)/\(page)-empty-\(mode).png")
            await MenuBarProbe.close(menu)
        }
        await model.useStore(at: model.storeURL)
    }

    /// The status item in the menu bar, with the bar around it.
    private static func captureStatusItem(to path: String) {
        guard let window = MenuBarProbe.statusWindow else { return print("SNAPSHOT no status item") }
        captureRegion(window.frame.insetBy(dx: -24, dy: 0), to: path, fallback: window)
    }

    /// The open menu with its glass and shadow, as on screen.
    private static func captureMenu(to path: String) {
        guard let frame = MenuBarProbe.menuFrame else { return print("SNAPSHOT no menu window") }
        captureRegion(frame, to: path, fallback: MenuBarProbe.menuWindow)
    }

    /// screencapture of a screen region (Cocoa points, from the primary
    /// screen's bottom left), without making any window key: a menu closes
    /// then. While the screen is locked screencapture gets nothing; the
    /// window's own views are drawn instead, on the window background
    /// (no glass, no menu bar behind).
    private static func captureRegion(_ frame: NSRect, to path: String, fallback window: NSWindow?) {
        let top = (NSScreen.screens.first?.frame.height ?? 0) - frame.maxY
        let rect = "\(Int(frame.minX)),\(Int(top)),\(Int(frame.width)),\(Int(frame.height))"
        try? FileManager.default.removeItem(atPath: path)
        let shot = Process()
        shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        shot.arguments = ["-x", "-R", rect, path]
        try? shot.run()
        shot.waitUntilExit()
        if FileManager.default.fileExists(atPath: path) { return print("SNAPSHOT \(path)") }
        guard let view = window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return print("SNAPSHOT failed \(path)") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        (view.effectiveAppearance).performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            view.bounds.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("SNAPSHOT \(path) (fallback: screen locked, the views drawn without glass)")
    }
}
