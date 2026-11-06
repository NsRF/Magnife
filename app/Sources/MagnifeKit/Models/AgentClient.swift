import Foundation

/// The agent tabs of Settings > Agents (S-035, docs/ux.md): what connects
/// each coding agent to Magnife's MCP server (S-034, docs/mcp.md), with the
/// running copy's own path, so people never look it up.
public enum AgentClient: String, CaseIterable, Identifiable, Sendable {
    case claudeCode, codex, cursor, other

    public static let defaultClient = AgentClient.claudeCode
    static let defaultsKey = "agents.client"
    /// The server's name in every client's configuration.
    public static let serverName = "magnife"
    /// `Contents/Helpers/magnife-mcp` inside Magnife.app.
    public static let helperPath = "Contents/Helpers/magnife-mcp"

    public var id: String { rawValue }

    /// The tab's title, from docs/GLOSSARY.md.
    public var title: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .cursor: "Cursor"
        case .other: "Other"
        }
    }

    /// A shell command to run once, or a configuration to paste.
    public var isCommand: Bool { self == .claudeCode || self == .codex }

    /// The button's title: Copy Command or Copy Configuration.
    public var copyTitle: String { isCommand ? "Copy Command" : "Copy Configuration" }

    /// Exactly what the tab shows and the button copies.
    public func text(serverPath path: String) -> String {
        switch self {
        case .claudeCode: "claude mcp add --scope user \(Self.serverName) -- \(Self.shellQuoted(path))"
        case .codex: "codex mcp add \(Self.serverName) -- \(Self.shellQuoted(path))"
        case .cursor, .other:
            """
            {
              "mcpServers": {
                "\(Self.serverName)": {
                  "command": \(Self.jsonString(path))
                }
              }
            }
            """
        }
    }

    /// The one step besides the text, shown under it (not copied).
    public var note: String {
        switch self {
        case .claudeCode: "Run it once in Terminal. Every Claude Code session can then use Magnife."
        case .codex: "Run it once in Terminal. Every Codex session can then use Magnife."
        case .cursor: "Add it to ~/.cursor/mcp.json, or to .cursor/mcp.json in one project."
        case .other: "Add it to your MCP client's settings, such as Claude Desktop's."
        }
    }

    /// The path as one shell word: as it is when it only has safe characters,
    /// else in single quotes (a quote inside becomes '\'').
    public static func shellQuoted(_ path: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-+@%:,=~"))
        if !path.isEmpty, path.unicodeScalars.allSatisfy(safe.contains) { return path }
        return "'" + path.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// A JSON string literal, with the escapes JSON needs.
    public static func jsonString(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case let s where s.value < 0x20: out += String(format: "\\u%04x", s.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    /// The last chosen tab, or Claude Code the first time.
    public static func stored(in defaults: UserDefaults) -> AgentClient {
        defaults.string(forKey: defaultsKey).flatMap(AgentClient.init(rawValue:)) ?? defaultClient
    }

    public func store(in defaults: UserDefaults) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}

/// Where this copy's MCP server is, and whether that path will last (S-035).
public struct AgentServerLocation: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        /// Installed: the path stays the same.
        case ready
        /// Run from a translocated or disk-image copy: macOS moves the app, so
        /// the path changes until Magnife is in Applications.
        case temporary
        /// This bundle has no magnife-mcp (an old or a partial build).
        case missing
    }

    public var path: String
    public var state: State

    public init(path: String, state: State) {
        self.path = path
        self.state = state
    }

    /// The server inside `appBundle`; `exists` checks the file (the file system in real runs).
    public init(appBundle: URL, exists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) {
        let path = appBundle.standardizedFileURL.appending(path: AgentClient.helperPath).path
        self.path = path
        if !exists(path) {
            state = .missing
        } else if path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/") {
            state = .temporary
        } else {
            state = .ready
        }
    }

    /// The warning line under the intro, or nil when the path is fine.
    public var warning: String? {
        switch state {
        case .ready: nil
        case .temporary: "Move Magnife to Applications first. The path below changes until you do."
        case .missing: "This copy of Magnife has no MCP server."
        }
    }
}
