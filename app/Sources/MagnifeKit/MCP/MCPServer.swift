import Foundation

/// One tool an MCP client can call (docs/mcp.md, "Tools").
public struct MCPTool: Sendable {
    public var name: String
    public var title: String
    public var description: String
    /// The arguments' JSON Schema.
    public var inputSchema: JSONValue

    public init(name: String, title: String, description: String, inputSchema: JSONValue) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
    }

    /// How `tools/list` shows it. Every Magnife tool only reads local data.
    public var listed: JSONValue {
        [
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": inputSchema,
            "annotations": ["title": .string(title), "readOnlyHint": true, "destructiveHint": false,
                            "idempotentHint": true, "openWorldHint": false],
        ]
    }
}

/// What a tool call answers: text for the agent, and whether it is an error
/// the agent should read (no database yet, an unknown trace).
public struct MCPToolResult: Sendable, Equatable {
    public var text: String
    public var isError: Bool

    public init(_ text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }

    public static func error(_ text: String) -> MCPToolResult { MCPToolResult(text, isError: true) }

    var json: JSONValue {
        ["content": [["type": "text", "text": .string(text)]], "isError": .bool(isError)]
    }
}

/// The arguments were wrong: answered as an `isError` result with a sentence that says how.
public struct MCPInvalidParams: Error, Sendable, Equatable {
    public var message: String
    public init(_ message: String) { self.message = message }
}

/// The tools behind the server: `MagnifeTools` in real runs, a fake in tests.
public protocol MCPToolbox: Sendable {
    var tools: [MCPTool] { get }
    func call(_ name: String, arguments: [String: JSONValue]) async throws(MCPInvalidParams) -> MCPToolResult
}

/// The MCP protocol over JSON-RPC 2.0, one message per line (S-034). It holds
/// no state between messages but the negotiated version, so each line is
/// answered on its own: `handle(line:)` returns the answer's line, or nil for
/// a notification.
public struct MCPServer: Sendable {
    /// Newest first: `initialize` answers with the client's version when it is
    /// one of these, else the first.
    public static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    public static let instructions = """
        Magnife stores the OpenTelemetry traces, spans and logs of services running on this Mac \
        (sent to localhost:4317 or 4318). Start with find_problems for "what went wrong", or \
        list_traces with a query such as "status:error service:orders >200ms". Then get_trace for one \
        trace's span tree and findings, get_span for a span's attributes, exception and logs, and \
        search_logs for logs. Everything is read-only.
        """

    public let toolbox: any MCPToolbox
    public let version: String

    public init(toolbox: any MCPToolbox, version: String) {
        self.toolbox = toolbox
        self.version = version
    }

    enum ErrorCode: Int {
        case parse = -32700
        case invalidRequest = -32600
        case methodNotFound = -32601
        case invalidParams = -32602
    }

    /// The answer to one line from the client, or nil when it needs none.
    public func handle(line: String) async -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8)) else {
            return Self.encode(Self.error(id: .null, .parse, "The message is not JSON."))
        }
        // A batch (2025-03-26 only) is answered as a batch.
        if case .array(let messages) = message {
            guard !messages.isEmpty else {
                return Self.encode(Self.error(id: .null, .invalidRequest, "The batch is empty."))
            }
            var answers: [JSONValue] = []
            for item in messages {
                if let answer = await respond(to: item) { answers.append(answer) }
            }
            return answers.isEmpty ? nil : Self.encode(.array(answers))
        }
        return await respond(to: message).map(Self.encode)
    }

    func respond(to message: JSONValue) async -> JSONValue? {
        guard case .object(let request) = message, request["jsonrpc"] == "2.0",
              let method = request["method"]?.stringValue else {
            // A response from the client (we send no requests) needs nothing back.
            if message["result"] != nil || message["error"] != nil { return nil }
            return Self.error(id: message["id"] ?? .null, .invalidRequest, "The message is not a JSON-RPC 2.0 request.")
        }
        // No id: a notification (initialized, cancelled), answered by nothing.
        guard let id = request["id"] else { return nil }
        let params = request["params"]?.objectValue ?? [:]
        switch method {
        case "initialize":
            let asked = params["protocolVersion"]?.stringValue
            let version = asked.flatMap { Self.protocolVersions.contains($0) ? $0 : nil } ?? Self.protocolVersions[0]
            return Self.result(id: id, [
                "protocolVersion": .string(version),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "magnife", "title": "Magnife", "version": .string(self.version)],
                "instructions": .string(Self.instructions),
            ])
        case "ping":
            return Self.result(id: id, [:])
        case "tools/list":
            return Self.result(id: id, ["tools": .array(toolbox.tools.map(\.listed))])
        case "tools/call":
            guard let name = params["name"]?.stringValue else {
                return Self.error(id: id, .invalidParams, "tools/call needs the tool's name.")
            }
            guard toolbox.tools.contains(where: { $0.name == name }) else {
                return Self.error(id: id, .invalidParams, "There is no tool named \(name).")
            }
            let arguments: [String: JSONValue]
            switch params["arguments"] {
            case nil, .null?: arguments = [:]
            case .object(let object)?: arguments = object
            default: return Self.error(id: id, .invalidParams, "The arguments must be an object.")
            }
            do {
                return Self.result(id: id, try await toolbox.call(name, arguments: arguments).json)
            } catch {
                // Wrong arguments are the tool's answer, so the agent reads why and
                // tries again (MCP 2025-11-25: input validation is a tool execution error).
                return Self.result(id: id, MCPToolResult.error(error.message).json)
            }
        default:
            return Self.error(id: id, .methodNotFound, "Magnife does not support \(method).")
        }
    }

    static func result(id: JSONValue, _ result: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    static func error(id: JSONValue, _ code: ErrorCode, _ message: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code.rawValue)), "message": .string(message)]]
    }

    /// One line: no newline inside, as stdio needs.
    static func encode(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else {
            return #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"The answer could not be encoded."}}"#
        }
        return text
    }
}
