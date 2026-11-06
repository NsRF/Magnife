import AppKit
import MagnifeKit

/// Settings > Agents (S-035): the command or configuration that connects a
/// coding agent to this copy's MCP server (S-034).
extension AppModel {
    /// This copy's `Contents/Helpers/magnife-mcp`, and whether its path lasts.
    var agentServer: AgentServerLocation {
        AgentServerLocation(appBundle: Bundle.main.bundleURL)
    }

    /// Exactly what the code block shows and the button copies.
    var agentSetupText: String {
        agentClient.text(serverPath: agentServer.path)
    }

    /// Copies the shown text, reads "Copied" for 2 seconds and tells
    /// VoiceOver, like Copy Environment Variables. The self-test passes its own pasteboard.
    func copyAgentSetup(to pasteboard: NSPasteboard = .general) {
        guard agentServer.state != .missing else { return }
        pasteboard.clearContents()
        pasteboard.setString(agentSetupText, forType: .string)
        agentSetupCopied = true
        NSAccessibility.post(element: NSApp.keyWindow ?? NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: "Copied",
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
        agentCopiedResetTask?.cancel()
        agentCopiedResetTask = Task { [weak self] in
            try? await Task.sleep(for: Self.copiedFeedback)
            guard !Task.isCancelled else { return }
            self?.agentSetupCopied = false
        }
    }

    /// Help > Connect a Coding Agent…: Settings opens on Agents.
    func showAgentSettings() {
        settingsTab = .agents
    }
}
