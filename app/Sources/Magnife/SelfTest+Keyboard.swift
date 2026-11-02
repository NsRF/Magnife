import AppKit
import MagnifeKit

/// S-022: the keyboard map with real key events on the seeded store. ↑↓,
/// Home / End / Page keys in the trace list, → into the waterfall, ← → and
/// ⌥← ⌥→ on spans, Return into the span detail and Esc back out, Space,
/// ⌘F and Esc, Tab between the columns; then every menu item of docs/ux.md
/// with its shortcut, and no shortcut used twice.
extension SelfTest {
    static func checkKeyboard(_ model: AppModel) async {
        guard let window = NSApp.windows.first(where: { $0.canBecomeMain && !$0.isSheet }) else {
            return check("the main window exists", false)
        }
        model.showContentMode(.traces)
        model.applyTraceFilter(.cleared)
        model.showsTraceFilterBar = false
        model.showsSpanDetail = true
        await model.reload()
        await ensureKey(window)
        guard model.traces.count == 5, let table = model.listScroller.tableView else {
            return check("the trace list shows the seed set", false, "\(model.traces.count)")
        }
        model.selectedTraceID = model.traces[0].id
        model.focus(.list)
        check("the trace list takes the focus", await waitUntil(1) { window.firstResponder === table && table.selectedRow == 0 })

        // ↑↓ move the selection, and the waterfall follows.
        key(window, .down)
        let moved = await waitUntil(1) { model.selectedTraceID == model.traces[1].id }
        let followed = await waitUntil(2) { model.openTrace?.id == model.traces[1].id && !model.waterfall.isEmpty }
        check("↓ selects the next trace and the waterfall follows", moved && followed)
        key(window, .up)
        check("↑ selects the one above", await waitUntil(1) { model.selectedTraceID == model.traces[0].id })
        key(window, .end)
        check("End selects the oldest trace", await waitUntil(1) { model.selectedTraceID == model.traces[4].id })
        key(window, .home)
        check("Home selects the newest", await waitUntil(1) { model.selectedTraceID == model.traces[0].id })
        key(window, .down, [.command])
        let commandDown = await waitUntil(1) { model.selectedTraceID == model.traces[4].id }
        key(window, .up, [.command])
        let commandUp = await waitUntil(1) { model.selectedTraceID == model.traces[0].id }
        check("⌘↓ and ⌘↑ do the same", commandDown && commandUp)
        key(window, .pageDown)
        let pageDown = await waitUntil(1) { model.selectedTraceID != model.traces[0].id }
        key(window, .pageUp)
        let pageUp = await waitUntil(1) { model.selectedTraceID == model.traces[0].id }
        check("Page Down and Page Up move a page", pageDown && pageUp)
        key(window, .space)
        let hidden = await waitUntil(1) { !model.showsSpanDetail }
        key(window, .space)
        let shown = await waitUntil(1) { model.showsSpanDetail }
        check("Space in the list hides and shows the span detail, focus stays",
              hidden && shown && window.firstResponder === table)

        // → into the waterfall on the root span of the HTTP 500 trace (5 spans, two levels).
        guard let failed = model.traces.first(where: { $0.route == "POST /checkout/pay" }) else {
            return check("the HTTP 500 trace is listed", false)
        }
        model.selectedTraceID = failed.id
        _ = await waitUntil(2) { model.openTrace?.id == failed.id && !model.waterfall.isEmpty }
        key(window, .right)
        let entered = await waitUntil(2) { window.firstResponder === model.waterfallOutline }
        guard let outline = model.waterfallOutline, let root = model.waterfall.rootSpanID,
              let rootIndex = model.waterfall.index(of: root) else { return check("→ moves into the waterfall", false) }
        check("→ moves the focus into the waterfall, on the root span", entered && model.selectedSpanID == root)
        await checkWaterfallKeys(model, window: window, outline: outline, rootIndex: rootIndex)

        // Esc steps back: span detail -> waterfall -> trace list.
        key(window, .returnKey)
        let inDetail = await waitUntil(2) { model.spanDetailHasFocus }
        check("Return opens the span detail on Span and moves the focus into it",
              inDetail && model.showsSpanDetail && model.spanDetailTab == .span)
        key(window, .escape)
        check("Esc in the span detail moves the focus back to the waterfall",
              await waitUntil(1) { window.firstResponder === outline })
        key(window, .space)
        let spaceHid = await waitUntil(1) { !model.showsSpanDetail }
        key(window, .space)
        let spaceShowed = await waitUntil(1) { model.showsSpanDetail }
        check("Space in the waterfall hides and shows the span detail, focus stays",
              spaceHid && spaceShowed && window.firstResponder === outline)
        key(window, .escape)
        check("Esc in the waterfall moves the focus back to the trace list",
              await waitUntil(1) { window.firstResponder === table })
        key(window, .returnKey)
        check("Return in the trace list moves into the waterfall too",
              await waitUntil(2) { window.firstResponder === outline && model.selectedSpanID == root })

        // ⌘F opens the filter bar, Esc closes it first, before any focus moves.
        // The item's action, as ⌘F runs it: SwiftUI enables menu items on its own
        // schedule, so the shortcut itself is checked in the menu audit below.
        model.toggleFilterBar(focusField: true)
        let barShown = await waitUntil(1) { model.showsTraceFilterBar }
        // Under load the field can take more than a second to appear and focus; Esc before that goes elsewhere.
        let fieldFocused = await waitUntil(3) { window.firstResponder is NSTextView }
        press(window, "\u{1b}", keyCode: 53)
        let barHidden = await waitUntil(2) { !model.showsTraceFilterBar }
        check("View > Show Filter Bar (⌘F) opens the bar with its field focused, and Esc closes it",
              barShown && fieldFocused && barHidden, "shown \(barShown), focused \(fieldFocused), hidden \(barHidden)")
        model.showsTraceFilterBar = true
        window.makeFirstResponder(outline)
        key(window, .escape)
        check("with the bar shown, Esc in the waterfall closes the bar and keeps the focus",
              await waitUntil(1) { !model.showsTraceFilterBar } && window.firstResponder === outline)

        await checkTabOrder(model, window: window, table: table, outline: outline)
        checkMenus()
        window.makeFirstResponder(nil)
        model.selectedTraceID = nil
    }

    /// ↑↓ between spans, ← and → collapse, expand and move, ⌥ for the subtree.
    private static func checkWaterfallKeys(_ model: AppModel, window: NSWindow, outline: NSOutlineView, rootIndex: Int) async {
        let waterfall = model.waterfall
        let root = waterfall.nodes[rootIndex].span.spanID
        guard let firstChild = waterfall.nodes[rootIndex].children.first else { return check("the root has children", false) }
        let childID = waterfall.nodes[firstChild].span.spanID
        key(window, .down)
        check("↓ selects the next span", await waitUntil(1) { model.selectedSpanID == childID })
        key(window, .up)
        check("↑ selects the span above", await waitUntil(1) { model.selectedSpanID == root })
        key(window, .left)
        check("← collapses an open span", await waitUntil(1) { model.collapsedSpans.contains(root) && outline.numberOfRows == 1 })
        key(window, .right)
        check("→ expands it again", await waitUntil(1) { !model.collapsedSpans.contains(root) && outline.numberOfRows == waterfall.count })
        key(window, .right)
        check("→ on an open span selects its first child", await waitUntil(1) { model.selectedSpanID == childID })
        key(window, .left)
        let expected = waterfall.moveLeft(from: firstChild, collapsed: model.collapsedSpans)
        let leftDone = await waitUntil(1) {
            switch expected {
            case .collapse: model.collapsedSpans.contains(childID)
            default: model.selectedSpanID == root
            }
        }
        check("← on a child collapses it, or selects its parent", leftDone, "\(expected)")
        model.selectedSpanID = root
        _ = await waitUntil(1) { outline.selectedRow == 0 }
        key(window, .left, [.option])
        let parents = Set(waterfall.nodes.filter { !$0.children.isEmpty }.map(\.span.spanID))
        check("⌥← collapses the span and all its descendants",
              await waitUntil(1) { parents.isSubset(of: model.collapsedSpans) }, "\(model.collapsedSpans)")
        key(window, .right, [.option])
        check("⌥→ expands them all", await waitUntil(1) { model.collapsedSpans.isEmpty && outline.numberOfRows == waterfall.count })
        key(window, .end)
        let last = await waitUntil(1) { outline.selectedRow == outline.numberOfRows - 1 }
        key(window, .home)
        let first = await waitUntil(1) { model.selectedSpanID == root }
        check("End and Home select the last and first span", last && first)
    }

    /// Tab: sidebar -> list -> waterfall -> span detail -> sidebar, ⇧Tab back.
    private static func checkTabOrder(_ model: AppModel, window: NSWindow, table: NSTableView, outline: NSOutlineView) async {
        model.focus(.list)
        _ = await waitUntil(1) { window.firstResponder === table }
        key(window, .tab)
        let toWaterfall = await waitUntil(1) { window.firstResponder === outline }
        key(window, .tab)
        let toDetail = await waitUntil(1) { model.spanDetailHasFocus }
        key(window, .tab)
        let toSidebar = await waitUntil(1) { model.sidebarHasFocus }
        key(window, .tab)
        let toList = await waitUntil(1) { window.firstResponder === table }
        check("Tab moves sidebar -> list -> waterfall -> span detail and around",
              toWaterfall && toDetail && toSidebar && toList, "\(toWaterfall) \(toDetail) \(toSidebar) \(toList)")
        key(window, .backTab, [.shift])
        let back = await waitUntil(1) { model.sidebarHasFocus }
        key(window, .backTab, [.shift])
        let backAgain = await waitUntil(1) { model.spanDetailHasFocus }
        check("⇧Tab moves back", back && backAgain,
              "\(back) \(backAgain), first responder \(String(describing: window.firstResponder))")
    }

    // MARK: Menus

    /// docs/ux.md section 1: every item, in its menu, with its shortcut.
    /// Titles that change with the state list both forms.
    private static let menuMap: [(menu: String, titles: [String], key: String, modifiers: NSEvent.ModifierFlags)] = [
        ("Magnife", ["Settings…"], ",", .command),
        ("File", ["Save Filter…", "Save Filter"], "s", .command),
        ("File", ["Save Filter As…"], "s", [.command, .shift]),
        ("File", ["Rename Filter…"], "", []),
        ("File", ["Delete Filter"], "\u{8}", .command),
        ("Edit", ["Copy Trace ID"], "", []),
        ("Edit", ["Copy Span ID"], "", []),
        ("Edit", ["Copy Stack Trace"], "", []),
        ("Edit", ["Copy Body"], "", []),
        ("Edit", ["Copy Environment Variables"], "c", [.command, .shift]),
        ("Edit", ["Search…"], "k", .command),
        ("View", ["Traces"], "1", .command),
        ("View", ["Logs"], "2", .command),
        ("View", ["Show Filter Bar", "Hide Filter Bar"], "f", .command),
        ("View", ["Clear Filters"], "", []),
        ("View", ["Show Span Detail", "Hide Span Detail"], "i", [.command, .control]),
        ("View", ["Span"], "1", [.command, .option]),
        ("View", ["Trace Logs"], "2", [.command, .option]),
        ("Trace", ["Pause", "Resume"], "p", [.command, .control]),
        ("Trace", ["Show Newest Traces", "Show Newest Logs"], "", []),
        ("Trace", ["Open Trace"], "o", .command),
        ("Trace", ["Expand All Spans"], String(UnicodeScalar(NSRightArrowFunctionKey)!), [.command, .option]),
        ("Trace", ["Collapse All Spans"], String(UnicodeScalar(NSLeftArrowFunctionKey)!), [.command, .option]),
        ("Window", ["Magnife"], "0", .command),
        ("Help", ["Show Environment Variables"], "", []),
    ]

    private static func checkMenus() {
        guard let main = NSApp.mainMenu else { return check("the main menu exists", false) }
        var missing: [String] = []
        for entry in menuMap {
            let menu = main.items.first { $0.submenu?.title == entry.menu || $0.title == entry.menu }?.submenu
            let item = menu?.items.first { entry.titles.contains($0.title) }
            guard let item else {
                missing.append("\(entry.menu) > \(entry.titles[0]) missing")
                continue
            }
            let (key, modifiers) = normalized(item)
            if key != entry.key || (!entry.key.isEmpty && modifiers != entry.modifiers) {
                missing.append("\(entry.menu) > \(item.title) has \"\(key)\" \(modifiers.rawValue)")
            }
        }
        check("every action of docs/ux.md has its menu item and shortcut", missing.isEmpty, missing.joined(separator: "; "))

        var seen: [String: String] = [:]
        var twice: [String] = []
        func walk(_ menu: NSMenu, path: String) {
            for item in menu.items where !item.isAlternate && !item.isHidden {
                if let submenu = item.submenu { walk(submenu, path: "\(path) > \(item.title)") }
                let (key, modifiers) = normalized(item)
                guard !key.isEmpty else { continue }
                let shortcut = "\(key)-\(modifiers.rawValue)"
                if let other = seen[shortcut] { twice.append("\(other) and \(path) > \(item.title)") }
                seen[shortcut] = "\(path) > \(item.title)"
            }
        }
        walk(main, path: "")
        check("no shortcut belongs to two menu items", twice.isEmpty, twice.joined(separator: "; "))
    }

    /// A lowercase key and its modifiers; an uppercase letter means Shift.
    private static func normalized(_ item: NSMenuItem) -> (String, NSEvent.ModifierFlags) {
        var modifiers = item.keyEquivalentModifierMask.intersection([.command, .option, .control, .shift])
        let key = item.keyEquivalent
        if key.count == 1, let char = key.first, char.isUppercase { modifiers.insert(.shift) }
        return (key.lowercased(), modifiers)
    }

    // MARK: Keys

    enum TestKey {
        case up, down, left, right, home, end, pageUp, pageDown, space, returnKey, escape, tab, backTab

        var event: (characters: String, keyCode: UInt16, flags: NSEvent.ModifierFlags) {
            func function(_ code: Int) -> String { String(UnicodeScalar(code)!) }
            return switch self {
            case .up: (function(NSUpArrowFunctionKey), 126, [.function, .numericPad])
            case .down: (function(NSDownArrowFunctionKey), 125, [.function, .numericPad])
            case .left: (function(NSLeftArrowFunctionKey), 123, [.function, .numericPad])
            case .right: (function(NSRightArrowFunctionKey), 124, [.function, .numericPad])
            case .home: (function(NSHomeFunctionKey), 115, .function)
            case .end: (function(NSEndFunctionKey), 119, .function)
            case .pageUp: (function(NSPageUpFunctionKey), 116, .function)
            case .pageDown: (function(NSPageDownFunctionKey), 121, .function)
            case .space: (" ", 49, [])
            case .returnKey: ("\r", 36, [])
            case .escape: ("\u{1b}", 53, [])
            case .tab: ("\t", 48, [])
            case .backTab: ("\u{19}", 48, [])
            }
        }
    }

    /// A key down posted to the app's event queue, as the keyboard would: it
    /// passes the app's key monitors, then the key window's first responder.
    static func key(_ window: NSWindow, _ key: TestKey, _ modifiers: NSEvent.ModifierFlags = []) {
        let event = key.event
        guard let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: event.flags.union(modifiers),
                                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                          context: nil, characters: event.characters,
                                          charactersIgnoringModifiers: event.characters, isARepeat: false,
                                          keyCode: event.keyCode) else { return }
        NSApp.postEvent(down, atStart: false)
    }
}
