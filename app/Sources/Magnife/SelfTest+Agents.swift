import AppKit
import MagnifeKit

/// S-035: Settings > Agents and Help > Connect a Coding Agent…
extension SelfTest {
    static func checkAgents(_ model: AppModel) async {
        // A pasteboard of its own, so the self-test never replaces what you copied.
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("Magnife.selftest.agents"))
        defer { pasteboard.releaseGlobally() }
        let server = model.agentServer
        check("the agent tab names this copy's magnife-mcp",
              server.path == Bundle.main.bundleURL.standardizedFileURL.appending(path: AgentClient.helperPath).path, server.path)
        check("this copy has its MCP server", server.state != .missing, "\(server.state)")

        // The path shown is one that runs: the server answers --version.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: server.path)
        process.arguments = ["--version"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            check("the shown path runs magnife-mcp", process.terminationStatus == 0 && text.hasPrefix("magnife-mcp "), text)
        } catch {
            check("the shown path runs magnife-mcp", false, "\(error)")
        }

        let before = model.agentClient
        for client in AgentClient.allCases {
            model.agentClient = client
            model.copyAgentSetup(to: pasteboard)
            let copied = pasteboard.string(forType: .string)
            check("\(client.copyTitle) puts exactly the shown \(client.title) text on the pasteboard",
                  copied == model.agentSetupText && copied == client.text(serverPath: server.path), copied ?? "nil")
        }
        check("after a copy the button reads \"Copied\"", model.agentSetupCopied)
        try? await Task.sleep(for: AppModel.copiedFeedback + .milliseconds(300))
        check("2 seconds later it reads its title again", !model.agentSetupCopied)

        model.agentClient = .codex
        check("the picked agent is remembered", AgentClient.stored(in: AppDefaults.shared) == .codex)
        model.agentClient = before

        let item = menuItem("Connect a Coding Agent…")
        check("Help > Connect a Coding Agent…", item?.menu?.title == "Help")
        let tab = model.settingsTab
        model.settingsTab = .general
        // The checks after these expect the main window to have the focus again.
        let keyWindow = NSApp.keyWindow
        defer {
            keyWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
        if let item, let menu = item.menu, let index = menu.items.firstIndex(of: item) {
            menu.performActionForItem(at: index)
            try? await Task.sleep(for: .milliseconds(600))
            check("Connect a Coding Agent… opens Settings on Agents",
                  model.settingsTab == .agents && NSApp.windows.contains { $0.isVisible && $0.title == SettingsTab.agents.title },
                  NSApp.windows.filter(\.isVisible).map(\.title).joined(separator: ", "))
            NSApp.windows.first { $0.isVisible && $0.title == SettingsTab.agents.title }?.close()
        }
        model.settingsTab = tab
    }
}
