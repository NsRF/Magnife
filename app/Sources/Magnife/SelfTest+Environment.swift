import AppKit
import MagnifeKit

/// S-003: the environment variables in the empty state and the toolbar popover.
extension SelfTest {
    static func checkEnvironment(_ model: AppModel) async {
        // A pasteboard of its own, so the self-test never replaces what you copied.
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("Magnife.selftest"))
        defer { pasteboard.releaseGlobally() }
        check("the first tab is .NET", model.environmentLanguage == .dotnet)
        for language in EnvironmentLanguage.allCases {
            model.environmentLanguage = language
            model.copyEnvironmentVariables(to: pasteboard)
            let copied = pasteboard.string(forType: .string)
            check("Copy puts exactly the shown \(language.title) text on the pasteboard",
                  copied == model.environmentText && copied == language.text(httpPort: model.environmentHTTPPort),
                  copied ?? "nil")
        }
        check("the variables name the receiver's HTTP port",
              model.environmentText.contains("OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:\(model.environmentHTTPPort)\n"))
        check("after a copy the button reads \"Copied\"", model.environmentCopied)
        try? await Task.sleep(for: AppModel.copiedFeedback + .milliseconds(300))
        check("2 seconds later it reads \"Copy Environment Variables\" again", !model.environmentCopied)
        check("with traces stored there is no empty state", !model.showsEmptyState && !model.waitingForFirstTrace)
        model.environmentLanguage = .defaultLanguage
        model.environmentCopied = false
        model.hasCopiedEnvironment = false

        model.showEnvironmentVariables()
        check("Show Environment Variables opens the popover", model.showsEnvironmentPopover)
        model.showsEnvironmentPopover = false

        let edit = menuItem("Copy Environment Variables")
        check("Edit > Copy Environment Variables is ⇧⌘C",
              edit?.keyEquivalent == "c" && edit?.keyEquivalentModifierMask == [.command, .shift],
              "\(edit?.keyEquivalent ?? "missing") \(edit?.keyEquivalentModifierMask.rawValue ?? 0)")
        check("Help > Show Environment Variables", menuItem("Show Environment Variables")?.menu?.title == "Help")
        check("the default Magnife Help item is gone", menuItem("Magnife Help") == nil)
    }

    /// The first menu bar item with this title, searched depth first.
    static func menuItem(_ title: String, in menu: NSMenu? = NSApp.mainMenu) -> NSMenuItem? {
        for item in menu?.items ?? [] {
            if item.title == title { return item }
            if let found = menuItem(title, in: item.submenu) { return found }
        }
        return nil
    }
}
