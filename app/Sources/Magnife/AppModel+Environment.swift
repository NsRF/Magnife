import AppKit
import MagnifeKit

/// The environment variables that point an app at Magnife (S-003): the
/// empty state, the toolbar popover, and Edit > Copy Environment Variables.
extension AppModel {
    /// How long the copy button reads "Copied".
    static let copiedFeedback: Duration = .seconds(2)

    /// The HTTP port the helper reported, else the one it was started on
    /// (APP_HTTP_PORT), else 4318.
    var environmentHTTPPort: Int {
        receiver.httpPort ?? supervisor?.configuration.httpPort ?? HelperConfiguration.ports().http
    }

    /// Exactly what the code block shows and Copy puts on the pasteboard.
    var environmentText: String {
        environmentLanguage.text(httpPort: environmentHTTPPort)
    }

    /// The trace list's S-003 empty state: no traces in All Services.
    var showsEmptyState: Bool {
        guard case .failed = storeState else {
            return traces.isEmpty && !isLoadingScope && sidebar?.serviceName == nil
        }
        return false
    }

    /// "Waiting for the first trace…" shows under the button after a copy.
    var waitingForFirstTrace: Bool {
        hasCopiedEnvironment && showsEmptyState
    }

    /// Copies the shown variables, reads "Copied" for 2 seconds and tells
    /// VoiceOver. The self-test passes its own pasteboard.
    func copyEnvironmentVariables(to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(environmentText, forType: .string)
        environmentCopied = true
        hasCopiedEnvironment = true
        NSAccessibility.post(element: NSApp.mainWindow ?? NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: "Copied",
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
        copiedResetTask?.cancel()
        copiedResetTask = Task { [weak self] in
            try? await Task.sleep(for: Self.copiedFeedback)
            guard !Task.isCancelled else { return }
            self?.environmentCopied = false
        }
    }

    /// Help > Show Environment Variables: the toolbar popover.
    func showEnvironmentVariables() {
        showsEnvironmentPopover = true
    }
}
