import AppKit
import MagnifeKit
import SwiftUI

/// The menu bar extra's menu (S-026, docs/ux.md "Menu bar extra"): a native
/// NSMenu (`.menu` style, platform decision 8), so arrows and Return work.
struct MenuBarMenu: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        // The receiver's status words, as in the toolbar (S-001, S-002).
        Button(model.receiver.text) {}
            .disabled(true)
        // The section brings its own separators above and below.
        Section(RecentErrors.title) {
            if model.recentErrorTraces.isEmpty {
                Button(RecentErrors.emptyTitle) {}
                    .disabled(true)
            } else {
                ForEach(model.recentErrorTraces) { trace in
                    Button(RecentErrors.itemTitle(trace, now: model.recentErrorsOpenedAt)) {
                        MainWindow.bringForward(openWindow)
                        model.openFailedTrace(trace.traceID)
                    }
                }
            }
        }
        Button("Open Magnife") { MainWindow.bringForward(openWindow) }
        Button(TraceList.pauseTitle(isPaused: model.isPaused)) { model.togglePause() }
        Button("Copy Environment Variables") { model.copyEnvironmentVariables() }
        Divider()
        Button("Settings…") {
            NSApp.activate()
            openSettings()
        }
        Button("Quit Magnife") { NSApp.terminate(nil) }
    }
}

/// The menu bar icon: the template glyph, or the red glyph with the count
/// of traces with errors since the menu was last opened. The red state
/// always carries the count, never color alone.
struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        // VoiceOver reads the image's description: `.accessibilityLabel` on
        // the label made SwiftUI update the scene without end (decision).
        Image(nsImage: MenuBarGlyph.image(count: model.newErrorCount))
    }
}

/// The Magnife glyph for the menu bar (docs/ux.md, S-032): a lens holding
/// three stacked, offset bars, a tiny waterfall, as one-color line art. A
/// template image normally; a non-template red image with the count drawn
/// beside it, because the label ignores tint (platform decision 8).
enum MenuBarGlyph {
    static let glyphSize: CGFloat = 16
    static let gap: CGFloat = 2
    static var countFont: NSFont { .monospacedDigitSystemFont(ofSize: 12, weight: .semibold) }

    /// The image for the last count: a new NSImage on every update would
    /// update the status item, which updates the scene again, without end.
    private static var last: (count: Int, image: NSImage)?

    static func image(count: Int) -> NSImage {
        if let last, last.count == count { return last.image }
        let image = makeImage(badge: RecentErrors.badge(count: count))
        image.accessibilityDescription = RecentErrors.iconLabel(count: count)
        last = (count, image)
        return image
    }

    private static func makeImage(badge: String?) -> NSImage {
        let text = badge.map { NSAttributedString(string: $0, attributes: [.font: countFont]) }
        let textWidth = text.map { ceil($0.size().width) } ?? 0
        let size = NSSize(width: glyphSize + (text == nil ? 0 : gap + textWidth), height: glyphSize)
        // A bitmap drawn once (at 2x), not a drawing handler: SwiftUI redrew
        // a handler image on every appearance change and updated the scene
        // again, without end.
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                         pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return NSImage(size: size) }
        rep.size = size
        // Made after the size is set, so it draws in points, not pixels.
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return NSImage(size: size) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        // y down, like the menu bar's coordinates in the drawing below.
        let flip = NSAffineTransform()
        flip.translateX(by: 0, yBy: size.height)
        flip.scaleX(by: 1, yBy: -1)
        flip.concat()
        let color: NSColor = badge == nil ? .black : .systemRed
        drawGlyph(color: color)
        if let badge {
            let attributed = NSAttributedString(string: badge, attributes: [.font: countFont, .foregroundColor: color])
            let height = attributed.size().height
            // Text draws upright in a flipped context only when the context says it is flipped.
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
            attributed.draw(at: NSPoint(x: glyphSize + gap, y: (glyphSize - height) / 2))
        }
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        image.isTemplate = badge == nil
        return image
    }

    /// The lens, its handle and the three bars, in a 16 pt square (y down).
    private static func drawGlyph(color: NSColor) {
        color.set()
        let lens = NSBezierPath(ovalIn: NSRect(x: 1.25, y: 1.25, width: 10.5, height: 10.5)) // grid: ok glyph drawing, not layout
        lens.lineWidth = 1.5
        lens.stroke()
        let handle = NSBezierPath()
        handle.move(to: NSPoint(x: 10.4, y: 10.4))
        handle.line(to: NSPoint(x: 14.6, y: 14.6))
        handle.lineWidth = 2.2
        handle.lineCapStyle = .round
        handle.stroke()
        for (x, y, width) in [(3.6, 3.9, 3.6), (4.9, 5.75, 3.6), (6.2, 7.6, 3.0)] as [(CGFloat, CGFloat, CGFloat)] {
            NSBezierPath(roundedRect: NSRect(x: x, y: y, width: width, height: 1.5), // grid: ok glyph drawing, not layout
                         xRadius: 0.75, yRadius: 0.75).fill()
        }
    }
}

/// The main window: brought forward, or opened again when it was closed
/// (Window > Magnife, Open Magnife, a Recent Errors item).
enum MainWindow {
    /// The WindowGroup's window ids read "main-AppWindow-1"; opening another would make a second one.
    static var window: NSWindow? {
        NSApp.windows.first { ($0.identifier?.rawValue.hasPrefix("main") ?? false) && ($0.isVisible || $0.isMiniaturized) }
    }

    static func bringForward(_ openWindow: OpenWindowAction) {
        NSApp.activate()
        if let window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
    }
}

/// Tells the model when the menu bar extra's menu opens: the count resets
/// then. SwiftUI gives no callback for a `.menu` style extra, so this
/// watches every menu that starts tracking (AppKit posts it on the main
/// thread) and knows ours by its "Recent Errors" section, once SwiftUI has
/// filled the items in.
@MainActor
final class MenuBarTracking: NSObject {
    private static var shared: MenuBarTracking?
    /// The menu bar extra's menu, once it has opened (self-test, snapshots).
    static weak var menu: NSMenu?
    /// Called on every open of the menu, after the model (self-test, snapshots).
    static var onOpen: ((NSMenu) -> Void)?
    /// Whether the status item said it is in the menu bar, last time it changed (self-test).
    static var statusItemVisible: Bool?

    private let model: AppModel

    private init(model: AppModel) {
        self.model = model
    }

    static func install(model: AppModel) {
        guard shared == nil else { return }
        let tracking = MenuBarTracking(model: model)
        shared = tracking
        NotificationCenter.default.addObserver(tracking, selector: #selector(menuBeganTracking(_:)),
                                               name: NSMenu.didBeginTrackingNotification, object: nil)
    }

    @objc private func menuBeganTracking(_ note: Notification) {
        // SwiftUI fills the items in after tracking begins: look once they are in.
        guard let menu = note.object as? NSMenu, menu.supermenu == nil, menu !== NSApp.mainMenu else { return }
        Task { @MainActor in
            guard Self.isMenuBarExtra(menu) else { return }
            Self.menu = menu
            model.recentErrorsMenuOpened()
            Self.onOpen?(menu)
        }
    }

    static func isMenuBarExtra(_ menu: NSMenu) -> Bool {
        menu.supermenu == nil && menu !== NSApp.mainMenu && menu.items.contains { $0.title == RecentErrors.title }
    }
}
