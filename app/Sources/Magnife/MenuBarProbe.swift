import AppKit

/// Opens the real menu bar extra from code, for the self-test and snapshot
/// mode (S-026, S-027): clicks its status bar button, waits for the menu to
/// start tracking, and finds the windows to capture.
@MainActor
enum MenuBarProbe {
    /// The status item's window in the menu bar of the screen with the
    /// window (macOS puts one in every screen's menu bar; the others are
    /// not on screen).
    static var statusWindow: NSWindow? {
        let items = NSApp.windows.filter { String(describing: type(of: $0)).contains("StatusBar") && $0.isVisible }
        return items.first { $0.occlusionState.contains(.visible) } ?? items.first
    }

    /// The status item's button.
    static var statusButton: NSButton? {
        func find(_ view: NSView?) -> NSButton? {
            guard let view else { return nil }
            if let button = view as? NSButton { return button }
            return view.subviews.lazy.compactMap(find).first
        }
        return find(statusWindow?.contentView)
    }

    /// Clicks the status item and returns its menu once it is open. The click
    /// runs from a run loop timer: menu tracking blocks the caller until the
    /// menu closes, while main actor work keeps running in its loop.
    static func open() async -> NSMenu? {
        guard let button = statusButton else { return nil }
        var opened: NSMenu?
        MenuBarTracking.onOpen = { opened = $0 }
        defer { MenuBarTracking.onOpen = nil }
        button.perform(#selector(NSButton.performClick(_:)), with: nil, afterDelay: 0, inModes: [.common])
        for _ in 0..<100 where opened == nil { try? await Task.sleep(for: .milliseconds(20)) }
        // SwiftUI fills in the items as the menu opens.
        try? await Task.sleep(for: .milliseconds(300))
        return opened
    }

    /// Closes an open menu and waits until it has.
    static func close(_ menu: NSMenu) async {
        menu.cancelTracking()
        try? await Task.sleep(for: .milliseconds(300))
    }

    /// The open menu's window: this app's largest visible pop-up menu window.
    static var menuWindow: NSWindow? {
        NSApp.windows.filter {
            $0.isVisible && $0.level.rawValue >= NSWindow.Level.popUpMenu.rawValue
                && String(describing: type(of: $0)).contains("Menu")
        }.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    /// The open menu's frame on screen, with its glass: the pop-up menu
    /// window and the glass window behind it.
    static var menuFrame: NSRect? {
        guard let menu = menuWindow else { return nil }
        let glass = NSApp.windows.first {
            $0.isVisible && String(describing: type(of: $0)).contains("Glass") && $0.frame.contains(menu.frame)
        }
        return glass?.frame ?? menu.frame.insetBy(dx: -24, dy: -24)
    }

    /// The titles of the menu's items, "—" for a separator, as the self-test compares them.
    static func titles(_ menu: NSMenu) -> [String] {
        menu.items.filter { !$0.isHidden }.map { $0.isSeparatorItem ? "—" : $0.title }
    }
}
