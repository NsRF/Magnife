import AppKit
import MagnifeKit

/// S-017: Search in the real window. ⌘K opens it from every column and from
/// a text field, Esc closes it, results follow every keystroke, Return
/// opens a trace and ⌘Return applies the query as the list's filters; on
/// 100,000 spans (APP_SEARCH_STORE, tools/selftest.sh) each keystroke's
/// results show within 100 ms.
extension SelfTest {
    static func checkSearch(_ model: AppModel) async {
        guard let window = NSApp.windows.first(where: { $0.canBecomeMain && !$0.isSheet }) else {
            return check("the window is open for Search", false)
        }
        window.makeKeyAndOrderFront(nil)
        model.sidebar = .allTraces
        model.showContentMode(.traces)
        await model.reload()
        model.selectedTraceID = model.traces.first { $0.route == "POST /checkout/pay" }?.traceID
        _ = await waitUntil(3) { model.waterfallOutline != nil && !model.waterfall.isEmpty }

        // ⌘K from the list, the waterfall, the Logs view and a text field; Esc closes.
        let table = model.listScroller.tableView
        let places: [(String, () -> Void)] = [
            ("the trace list", { if let table { window.makeFirstResponder(table) } }),
            ("the waterfall", { if let outline = model.waterfallOutline { window.makeFirstResponder(outline) } }),
            ("the Logs view's \"Body contains\" field", {
                model.showContentMode(.logs)
                model.toggleLogFilterBar(focusField: true)
            }),
        ]
        for (place, focus) in places {
            await ensureKey(window)
            focus()
            try? await Task.sleep(for: .milliseconds(300))
            let opened = press(window, "k", keyCode: 40, modifiers: .command) && model.showsSearch
            let focused = await waitUntil(2) { searchFieldFocused(window) }
            check("⌘K opens Search from \(place), its field focused", opened && focused,
                  "\(model.showsSearch) \(String(describing: window.firstResponder))")
            pressKey(window, "\u{1b}", keyCode: 53)
            check("Esc closes Search from \(place)", await waitUntil(1) { !model.showsSearch })
        }
        model.hideLogFilterBar()
        model.showContentMode(.traces)

        // Typing in the real field: results follow every keystroke, the newest text wins.
        await ensureKey(window)
        model.showSearch()
        _ = await waitUntil(2) { model.searchResult?.isNewest == true && searchFieldFocused(window) }
        check("an empty field lists the newest traces", model.searchResult?.header == "Newest Traces"
              && model.searchTraces.count == 5, "\(model.searchTraces.count)")
        for character in "admin" { pressKey(window, String(character), keyCode: 0) }
        let typed = await waitUntil(2) { model.searchResult?.text == "admin" }
        check("each key reads again and the last text's results stay", typed && model.searchText == "admin"
              && model.searchResult?.header == "Matching Traces" && model.searchTraces.map(\.route) == ["GET /admin/reports"],
              "\(model.searchResult?.text ?? "none"): \(model.searchTraces.map(\.route))")

        // Suggestions for an unfinished token, completed with ↓ and Return.
        model.searchText = "status:"
        _ = await waitUntil(1) { model.searchResult?.text == "status:" }
        check("\"status:\" offers error, ok and unset", model.searchSuggestions == ["error", "ok", "unset"])
        await ensureKey(window)
        for _ in 0..<2 {
            pressKey(window, String(UnicodeScalar(NSDownArrowFunctionKey)!), keyCode: 125, modifiers: [.function, .numericPad])
        }
        pressKey(window, "\r", keyCode: 36)
        let completed = await waitUntil(1) { model.searchText == "status:unset " && model.searchResult?.text == "status:unset " }
        check("↓ and Return complete the token, and its results follow", completed
              && model.searchTraces.allSatisfy { $0.status == .unset } && model.searchTraces.count == 3, model.searchText)

        model.searchText = "paymnt"
        _ = await waitUntil(1) { model.searchResult?.text == "paymnt" }
        check("no match reads \"No traces match “paymnt”.\"", model.searchTraces.isEmpty && model.searchResult?.total == 0
              && TraceSearch.noMatchTitle(model.searchText) == "No traces match \u{201C}paymnt\u{201D}.")

        // Return opens a result: Traces view, trace in the detail column and selected.
        model.selectedTraceID = nil
        model.showContentMode(.logs)
        model.searchText = "service:checkout-api status:error"
        _ = await waitUntil(1) { model.searchResult?.text == "service:checkout-api status:error" }
        let failed = model.searchTraces.first
        await ensureKey(window)
        pressKey(window, "\r", keyCode: 36)
        let opened = await waitUntil(3) { model.openTrace?.traceID == failed?.traceID && !model.waterfall.isEmpty }
        check("Return opens the trace: Search closes, Traces view, the trace selected and in the detail",
              failed?.route == "POST /checkout/pay" && opened && !model.showsSearch && model.contentMode == .traces
                && model.selectedTraceID == failed?.traceID)
        let listFocused = await waitUntil(2) { model.listScroller.tableView.map { window.firstResponder === $0 } ?? false }
        check("and the trace list has the focus, so ↑↓ work at once", listFocused,
              "\(String(describing: window.firstResponder))")

        // ⌘Return applies the query as the list's filters.
        model.showSearch()
        model.searchText = "service:checkout-api status:error"
        _ = await waitUntil(1) { model.searchResult?.text == model.searchText }
        await ensureKey(window)
        // The field takes the focus a turn after the panel appears; ⌘Return before that reaches the list.
        _ = await waitUntil(2) { (window.firstResponder as? NSTextView)?.delegate is NSTextField }
        pressKey(window, "\r", keyCode: 36, modifiers: .command)
        await model.reload()
        check("⌘Return applies the query: the filter bar shows it, the sidebar takes the service, the list the status",
              !model.showsSearch && model.showsTraceFilterBar && model.sidebar == .service("checkout-api") && model.traceStatuses == [.error]
                && model.traces.map(\.route) == ["POST /checkout/pay"] && model.subtitle == "1 of 4 traces", model.subtitle)
        model.clearTraceFilters(undoManager: nil)
        model.hideTraceFilterBar()
        await model.reload()
        check("Clear Filters puts every trace back", model.traces.count == 5 && !model.hasTraceFilters)

        await checkSearchSpeed(model, window: window)
    }

    /// Keystroke to results shown, through the model and the field, on 100,000 spans.
    private static func checkSearchSpeed(_ model: AppModel, window: NSWindow) async {
        guard let path = ProcessInfo.processInfo.environment["APP_SEARCH_STORE"],
              let reader = try? await TelemetryReader.open(at: URL(fileURLWithPath: path)) else {
            return check("APP_SEARCH_STORE names the 100,000-span store (tools/selftest.sh)", false)
        }
        let spans = (try? await reader.latestTraces(limit: 100_000).reduce(0) { $0 + $1.spanCount }) ?? 0
        model.searchReader = reader
        await ensureKey(window)
        model.showSearch()
        _ = await waitUntil(2) { model.searchResult != nil && searchFieldFocused(window) }
        var worst: Duration = .zero
        var lines: [String] = []
        let text = "orders status:error >100ms http"
        var typedSoFar = ""
        for character in text {
            typedSoFar.append(character)
            let started = ContinuousClock.now
            pressKey(window, String(character), keyCode: 0)
            let shown = await waitUntil(2, every: .milliseconds(2)) { model.searchResult?.text == typedSoFar }
            let elapsed = shown ? ContinuousClock.now - started : .seconds(2)
            worst = max(worst, elapsed)
            lines.append("\(typedSoFar.last.map(String.init) ?? "") \(Int(elapsed / .milliseconds(1)))")
        }
        let ms = worst / .milliseconds(1)
        print("INFO search on \(spans.formatted()) spans, ms per keystroke: \(lines.joined(separator: ", "))")
        checkTiming("results show within 100 ms of each keystroke on \(spans.formatted()) spans", ms: ms, budget: 100,
                    regression: 100, ok: spans >= 100_000 && model.searchResult?.text == text)
        model.closeSearch()
        model.searchReader = nil
    }

    /// Sends a key down to the window, as typing does. Menu shortcuts go
    /// through the main menu first, as AppKit does with a real key.
    @discardableResult
    static func press(_ window: NSWindow, _ characters: String, keyCode: UInt16,
                      modifiers: NSEvent.ModifierFlags = []) -> Bool {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                           windowNumber: window.windowNumber, context: nil, characters: characters,
                                           charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)
        else { return false }
        if modifiers.contains(.command) {
            if NSApp.mainMenu?.performKeyEquivalent(with: event) == true { return true }
            if window.performKeyEquivalent(with: event) { return true }
        }
        // To the window, not the app: the app may not be active while the self-test runs.
        window.sendEvent(event)
        return true
    }

    static func pressKey(_ window: NSWindow, _ characters: String, keyCode: UInt16,
                         modifiers: NSEvent.ModifierFlags = []) {
        press(window, characters, keyCode: keyCode, modifiers: modifiers)
    }

    /// Another app can take the focus while the self-test runs, and keys go
    /// to the key window: bring it back and wait for it.
    static func ensureKey(_ window: NSWindow) async {
        guard !window.isKeyWindow else { return }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        _ = await waitUntil(2) { window.isKeyWindow }
    }

    /// Search's own field has the focus (its field editor is the first responder).
    static func searchFieldFocused(_ window: NSWindow) -> Bool {
        (window.firstResponder as? NSTextView)?.delegate is SearchField.SearchTextField
    }
}
