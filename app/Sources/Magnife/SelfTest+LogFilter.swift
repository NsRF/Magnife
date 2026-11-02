import AppKit
import MagnifeKit

/// S-014: the Logs filter bar in the real window: level chips by OTel
/// range, the Service pop-up (the sidebar's setting), "Body contains",
/// Clear Filters with Undo, and Esc hiding the bar with the filters kept.
extension SelfTest {
    static func checkLogFilters(_ model: AppModel) async {
        let env = ProcessInfo.processInfo.environment
        guard let http = env["APP_SEED_HTTP"], let reader = model.reader,
              let port = Int(http.split(separator: ":").last ?? ""),
              let window = NSApp.windows.first(where: { $0.canBecomeMain && !$0.isSheet }) else {
            return check("APP_SEED_HTTP names the seed helper, and the window is open", false)
        }
        model.selectedTraceID = nil
        model.sidebar = .allTraces
        model.showContentMode(.logs)
        await model.reload()
        check("Show Filter Bar is offered in the Logs view only", MenuState.shared.filterBar == .hidden)

        // A log with no level, to see that no chip means every log.
        let now = UInt64(Date().timeIntervalSince1970 * 1e9)
        let posted = await post(port: port, path: "/v1/logs", body: """
            {"resourceLogs":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"web"}}]},
            "scopeLogs":[{"logRecords":[{"timeUnixNano":"\(now)","body":{"stringValue":"filter check: no level"}}]}]}]}
            """)
        for _ in 0..<30 where model.logs.first?.record.body != "filter check: no level" {
            try? await Task.sleep(for: .milliseconds(100))
            await model.reload()
        }
        check("with no chip on, a log with no level shows", posted == 200 && model.logs.first?.line.level == nil)

        window.makeKeyAndOrderFront(nil)
        model.toggleLogFilterBar(focusField: true)
        let focused = await waitUntil(2) { window.firstResponder is NSText }
        check("⌘F shows the filter bar with \"Body contains\" focused",
              model.showsLogFilterBar && MenuState.shared.filterBar == .shown && focused,
              "\(String(describing: window.firstResponder))")

        model.clickLevelChip(.error, adding: false)
        await model.reload()
        let errors = try? await reader.logPage(filter: LogFilter(levels: [.error]))
        check("ERROR keeps severity 17 to 20 only, as the store counts them",
              !model.logs.isEmpty && model.logs.allSatisfy { SeverityLevel.error.range.contains($0.record.severityNumber) }
                && model.logCount == errors?.logCount && model.logScopeCount == errors?.scopeCount,
              "\(model.logs.count) rows, \(model.subtitle)")
        check("the subtitle reads \"N of M logs\" and the Filter button is filled",
              model.subtitle == LogList.subtitle(shown: errors?.logCount ?? -1, of: errors?.scopeCount ?? -1)
                && model.hasLogBarFilters && MenuState.shared.hasFilters, model.subtitle)

        model.clickLevelChip(.warn, adding: true)
        model.sidebar = .service("checkout-api")
        await model.reload()
        check("⌘-click adds WARN, and the Service pop-up scopes like the sidebar",
              !model.logs.isEmpty && model.logs.allSatisfy {
                  $0.record.serviceName == "checkout-api" && (13...20).contains($0.record.severityNumber)
              } && model.logLevels == [.warn, .error] && model.title == "checkout-api", "\(model.logs.count) rows")

        model.logBodyText = "PAYMENT"
        let typed = await waitUntil(2) {
            model.logsLoaded && !model.logs.isEmpty && model.logs.allSatisfy { $0.record.body.lowercased().contains("payment") }
        }
        check("\"Body contains\" narrows the list as you type, ignoring case", typed, "\(model.logs.map(\.record.body))")

        // Esc in the field hides the bar; the filters stay on.
        if let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                         windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                                         charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) {
            window.sendEvent(escape)
        }
        let hidden = await waitUntil(1) { !model.showsLogFilterBar }
        check("Esc hides the filter bar and the filters stay on",
              hidden && model.logLevels == [.warn, .error] && model.logBodyFilter == "PAYMENT"
                && model.hasLogBarFilters && MenuState.shared.filterBar == .hidden)

        let undoManager = window.undoManager
        model.clearLogFilters(undoManager: undoManager)
        await model.reload()
        let all = try? await reader.logPage()
        check("Clear Filters resets the chips, the body and the scope at once",
              model.logLevels.isEmpty && model.logBodyText.isEmpty && model.sidebar == .allTraces
                && model.logCount == all?.logCount && !MenuState.shared.hasFilters && model.subtitle == LogList.subtitle(logCount: all?.logCount ?? -1),
              model.subtitle)
        check("Edit > Undo reads \"Undo Clear Filters\"", undoManager?.undoMenuItemTitle == "Undo Clear Filters",
              undoManager?.undoMenuItemTitle ?? "no undo manager")
        undoManager?.undo()
        await model.reload()
        check("Undo puts the filters back",
              model.logLevels == [.warn, .error] && model.logBodyFilter == "PAYMENT" && model.sidebar == .service("checkout-api"))
        undoManager?.redo()
        await model.reload()
        check("Redo clears them again", model.logLevels.isEmpty && model.sidebar == .allTraces && !model.hasLogFilters)

        model.clickLevelChip(.info, adding: false)
        model.logBodyText = "filter check"
        model.logBodyFilter = model.logBodyText
        await model.reload()
        check("a chip on hides the log with no level", !model.logs.contains { $0.record.body == "filter check: no level" })
        model.clickLevelChip(.fatal, adding: false)
        model.logBodyText = "no log says this"
        model.logBodyFilter = model.logBodyText
        await model.reload()
        check("a filter that matches nothing reads \"No Matching Logs\"",
              model.logsLoaded && model.logs.isEmpty && model.logFilter.narrowsScope)

        model.clearLogFilters(undoManager: nil)
        model.hideLogFilterBar()
        model.showContentMode(.traces)
        check("the Traces view has no Logs filter bar", MenuState.shared.filterBar == .unavailable && !MenuState.shared.hasFilters)
        await model.reload()
    }
}
