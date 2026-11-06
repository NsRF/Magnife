import Foundation
import Testing
@testable import MagnifeKit

/// S-035: what Settings > Agents shows and copies for each coding agent.
struct AgentClientTests {
    let path = "/Applications/Magnife.app/Contents/Helpers/magnife-mcp"

    @Test func commandsForClaudeCodeAndCodex() {
        #expect(AgentClient.claudeCode.text(serverPath: path) == "claude mcp add --scope user magnife -- \(path)")
        #expect(AgentClient.codex.text(serverPath: path) == "codex mcp add magnife -- \(path)")
        #expect(AgentClient.claudeCode.isCommand && AgentClient.codex.isCommand)
        #expect(AgentClient.claudeCode.copyTitle == "Copy Command")
    }

    @Test func configurationForCursorAndOtherIsValidJSON() throws {
        for client in [AgentClient.cursor, .other] {
            let text = client.text(serverPath: path)
            #expect(client.copyTitle == "Copy Configuration")
            let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: [String: [String: String]]]
            #expect(object?["mcpServers"]?["magnife"]?["command"] == path)
        }
    }

    @Test func pathsWithSpacesOrQuotesStayOneWord() throws {
        let spaced = "/Users/me/My Apps/Magnife.app/Contents/Helpers/magnife-mcp"
        #expect(AgentClient.claudeCode.text(serverPath: spaced).hasSuffix("-- '\(spaced)'"))
        #expect(AgentClient.shellQuoted("/a/it's") == #"'/a/it'\''s'"#)
        #expect(AgentClient.shellQuoted("/Users/me/Applications/Magnife.app") == "/Users/me/Applications/Magnife.app")
        #expect(AgentClient.shellQuoted("") == "''")
        let odd = #"/a "b" \c"#
        let object = try JSONSerialization.jsonObject(with: Data(AgentClient.other.text(serverPath: odd).utf8)) as? [String: [String: [String: String]]]
        #expect(object?["mcpServers"]?["magnife"]?["command"] == odd)
    }

    @Test func titlesAndNotesComeFromTheGlossary() {
        #expect(AgentClient.allCases.map(\.title) == ["Claude Code", "Codex", "Cursor", "Other"])
        #expect(AgentClient.claudeCode.note == "Run it once in Terminal. Every Claude Code session can then use Magnife.")
        #expect(AgentClient.cursor.note.contains("~/.cursor/mcp.json"))
    }

    @Test func theChosenAgentIsRemembered() throws {
        let defaults = try #require(UserDefaults(suiteName: "magnife.tests.agents.\(UUID())"))
        #expect(AgentClient.stored(in: defaults) == .claudeCode, "Claude Code the first time")
        AgentClient.cursor.store(in: defaults)
        #expect(AgentClient.stored(in: defaults) == .cursor)
        defaults.set("gone", forKey: AgentClient.defaultsKey)
        #expect(AgentClient.stored(in: defaults) == .claudeCode)
    }

    @Test func serverLocationStates() {
        let installed = AgentServerLocation(appBundle: URL(fileURLWithPath: "/Applications/Magnife.app"), exists: { _ in true })
        #expect(installed.path == path)
        #expect(installed.state == .ready && installed.warning == nil)
        let translocated = AgentServerLocation(
            appBundle: URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/1234/d/Magnife.app"), exists: { _ in true })
        #expect(translocated.state == .temporary)
        #expect(translocated.warning == "Move Magnife to Applications first. The path below changes until you do.")
        let image = AgentServerLocation(appBundle: URL(fileURLWithPath: "/Volumes/Magnife 0.2.0/Magnife.app"), exists: { _ in true })
        #expect(image.state == .temporary)
        let missing = AgentServerLocation(appBundle: URL(fileURLWithPath: "/Applications/Magnife.app"), exists: { _ in false })
        #expect(missing.state == .missing && missing.warning == "This copy of Magnife has no MCP server.")
    }
}
