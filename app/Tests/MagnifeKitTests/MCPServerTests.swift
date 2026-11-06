import Foundation
import Testing
@testable import MagnifeKit

/// S-034: the MCP protocol layer, against a fake toolbox (docs/mcp.md).
struct MCPServerTests {
    struct FakeToolbox: MCPToolbox {
        var tools: [MCPTool] {
            [MCPTool(name: "echo", title: "Echo", description: "Says the text back.",
                     inputSchema: ["type": "object", "properties": ["text": ["type": "string"]]])]
        }

        func call(_ name: String, arguments: [String: JSONValue]) async throws(MCPInvalidParams) -> MCPToolResult {
            guard let text = arguments["text"]?.stringValue else { throw MCPInvalidParams("text is required.") }
            return MCPToolResult("echo: \(text)")
        }
    }

    let server = MCPServer(toolbox: FakeToolbox(), version: "1.2.3")

    func answer(_ line: String) async throws -> JSONValue {
        let text = try #require(await server.handle(line: line))
        #expect(!text.contains("\n"), "one message per line")
        return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    @Test func initializeAnswersWithTheClientsVersionWhenSupported() async throws {
        let reply = try await answer(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{}}}"#)
        #expect(reply["id"] == 1, "a number id stays a number, not a Bool")
        let result = try #require(reply["result"])
        #expect(result["protocolVersion"] == "2025-06-18")
        #expect(result["capabilities"]?["tools"] != nil)
        #expect(result["capabilities"]?["resources"] == nil, "tools only")
        #expect(result["serverInfo"]?["name"] == "magnife")
        #expect(result["serverInfo"]?["version"] == "1.2.3")
        #expect(result["instructions"]?.stringValue?.contains("find_problems") == true)
    }

    @Test func initializeAnswersWithTheNewestVersionOtherwise() async throws {
        let reply = try await answer(#"{"jsonrpc":"2.0","id":"a","method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#)
        #expect(reply["id"] == "a")
        #expect(reply["result"]?["protocolVersion"] == .string(MCPServer.protocolVersions[0]))
        let none = try await answer(#"{"jsonrpc":"2.0","id":2,"method":"initialize"}"#)
        #expect(none["result"]?["protocolVersion"] == .string(MCPServer.protocolVersions[0]))
    }

    @Test func notificationsAndClientResponsesGetNoAnswer() async {
        #expect(await server.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        #expect(await server.handle(line: #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":3}}"#) == nil)
        #expect(await server.handle(line: #"{"jsonrpc":"2.0","id":9,"result":{}}"#) == nil)
        #expect(await server.handle(line: "   ") == nil)
    }

    @Test func pingAndToolsList() async throws {
        #expect(try await answer(#"{"jsonrpc":"2.0","id":3,"method":"ping"}"#)["result"] == [:])
        let tools = try await answer(#"{"jsonrpc":"2.0","id":4,"method":"tools/list"}"#)["result"]?["tools"]
        guard case .array(let list)? = tools, let tool = list.first else { Issue.record("no tools"); return }
        #expect(tool["name"] == "echo")
        #expect(tool["inputSchema"]?["type"] == "object")
        #expect(tool["annotations"]?["readOnlyHint"] == true)
        #expect(tool["annotations"]?["openWorldHint"] == false)
    }

    @Test func toolsCallAnswersTextContent() async throws {
        let result = try await answer(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"echo","arguments":{"text":"hi"}}}"#)["result"]
        #expect(result?["isError"] == false)
        #expect(result?["content"] == [["type": "text", "text": "echo: hi"]])
    }

    @Test func wrongArgumentsAreAToolErrorTheAgentReads() async throws {
        let result = try await answer(#"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"echo","arguments":{}}}"#)["result"]
        #expect(result?["isError"] == true)
        #expect(result?["content"] == [["type": "text", "text": "text is required."]])
    }

    @Test func protocolErrors() async throws {
        #expect(try await answer("not json")["error"]?["code"] == -32700)
        #expect(try await answer(#"{"jsonrpc":"2.0","id":7,"method":"resources/list"}"#)["error"]?["code"] == -32601)
        #expect(try await answer(#"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"nope"}}"#)["error"]?["code"] == -32602)
        #expect(try await answer(#"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{}}"#)["error"]?["code"] == -32602)
        #expect(try await answer(#"{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"echo","arguments":[1]}}"#)["error"]?["code"] == -32602)
        #expect(try await answer(#"{"id":11,"method":"ping"}"#)["error"]?["code"] == -32600, "no jsonrpc 2.0")
        #expect(try await answer("[]")["error"]?["code"] == -32600)
    }

    @Test func aBatchIsAnsweredAsABatch() async throws {
        let reply = try await answer(#"[{"jsonrpc":"2.0","id":1,"method":"ping"},{"jsonrpc":"2.0","method":"notifications/initialized"},{"jsonrpc":"2.0","id":2,"method":"ping"}]"#)
        guard case .array(let answers) = reply else { Issue.record("not an array"); return }
        #expect(answers.map { $0["id"] } == [1, 2])
    }

    @Test func jsonValueRoundTrip() throws {
        let value: JSONValue = ["a": 1, "b": [true, nil, "x"], "c": .number(1.5)]
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(JSONValue.self, from: data) == value)
        #expect(String(decoding: try JSONEncoder().encode(JSONValue.number(42)), as: UTF8.self) == "42")
        #expect(JSONValue.number(3)["x"] == nil)
        #expect(JSONValue.number(2.5).intValue == nil)
    }
}
