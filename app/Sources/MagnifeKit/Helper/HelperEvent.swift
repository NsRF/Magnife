import Foundation

/// One line the helper writes to stdout (docs/schema.sql, "Helper protocol").
public enum HelperEvent: Sendable, Equatable {
    /// The receiver's ports, at startup and after "retry".
    case ports(ReceiverPorts)
    /// A committed batch.
    case batch(BatchEvent)
    /// A pruning pass that deleted something.
    case pruned(PrunedEvent)
    /// A problem the app should show.
    case error(message: String)
    /// An "import" command's file, stored and committed.
    case imported(ImportedEvent)
    /// An "import" command that stored nothing, with a sentence to show.
    case importFailed(path: String, message: String)
    /// A type this app does not know; ignored.
    case unknown(type: String)
}

public struct ReceiverPorts: Sendable, Equatable, Codable {
    public var grpc: PortStatus
    public var http: PortStatus

    public init(grpc: PortStatus, http: PortStatus) {
        self.grpc = grpc
        self.http = http
    }
}

public struct PortStatus: Sendable, Equatable, Codable {
    public enum State: Sendable, Equatable, Codable {
        case listening, busy
        case other(String)

        public init(from decoder: any Decoder) throws {
            let text = try decoder.singleValueContainer().decode(String.self)
            self = switch text {
            case "listening": .listening
            case "busy": .busy
            default: .other(text)
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .listening: try container.encode("listening")
            case .busy: try container.encode("busy")
            case .other(let text): try container.encode(text)
            }
        }
    }

    public var addr: String
    public var state: State
    /// The process holding a busy port, when the helper found it.
    public var owner: String?
    public var pid: Int32?

    public init(addr: String, state: State, owner: String? = nil, pid: Int32? = nil) {
        self.addr = addr
        self.state = state
        self.owner = owner
        self.pid = pid
    }

    /// The port number from "127.0.0.1:4317".
    public var port: Int? { addr.split(separator: ":").last.flatMap { Int($0) } }
    public var isListening: Bool { state == .listening }
}

public struct BatchEvent: Sendable, Equatable, Codable {
    public var seq: Int64
    public var spans: Int
    public var logs: Int
    /// Every trace the batch touched.
    public var traces: [String]
    /// Touched traces whose status became Error in this batch.
    public var errorTraces: [String]

    enum CodingKeys: String, CodingKey {
        case seq, spans, logs, traces
        case errorTraces = "error_traces"
    }

    public init(seq: Int64, spans: Int, logs: Int, traces: [String] = [], errorTraces: [String] = []) {
        self.seq = seq
        self.spans = spans
        self.logs = logs
        self.traces = traces
        self.errorTraces = errorTraces
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        seq = try container.decode(Int64.self, forKey: .seq)
        spans = try container.decodeIfPresent(Int.self, forKey: .spans) ?? 0
        logs = try container.decodeIfPresent(Int.self, forKey: .logs) ?? 0
        traces = try container.decodeIfPresent([String].self, forKey: .traces) ?? []
        errorTraces = try container.decodeIfPresent([String].self, forKey: .errorTraces) ?? []
    }
}

public struct PrunedEvent: Sendable, Equatable, Codable {
    public var traces: Int
    public var spans: Int
    public var logs: Int

    public init(traces: Int, spans: Int, logs: Int) {
        self.traces = traces
        self.spans = spans
        self.logs = logs
    }
}

public struct ImportedEvent: Sendable, Equatable, Codable {
    public var path: String
    public var spans: Int
    public var logs: Int
    /// The file's distinct trace ids, in file order.
    public var traces: [String]

    public init(path: String, spans: Int, logs: Int, traces: [String]) {
        self.path = path
        self.spans = spans
        self.logs = logs
        self.traces = traces
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        spans = try container.decodeIfPresent(Int.self, forKey: .spans) ?? 0
        logs = try container.decodeIfPresent(Int.self, forKey: .logs) ?? 0
        traces = try container.decodeIfPresent([String].self, forKey: .traces) ?? []
    }
}

extension HelperEvent: Decodable {
    private enum CodingKeys: String, CodingKey { case type, message, path }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "ports": self = .ports(try ReceiverPorts(from: decoder))
        case "batch": self = .batch(try BatchEvent(from: decoder))
        case "pruned": self = .pruned(try PrunedEvent(from: decoder))
        case "error": self = .error(message: try container.decodeIfPresent(String.self, forKey: .message) ?? "")
        case "imported": self = .imported(try ImportedEvent(from: decoder))
        case "import_failed":
            self = .importFailed(path: try container.decode(String.self, forKey: .path),
                                 message: try container.decodeIfPresent(String.self, forKey: .message) ?? "")
        default: self = .unknown(type: type)
        }
    }

    /// Decodes one stdout line. Throws for a line that is not a protocol object.
    public static func decode(line: String) throws -> HelperEvent {
        try JSONDecoder().decode(HelperEvent.self, from: Data(line.utf8))
    }
}

/// A command for the helper's stdin.
public enum HelperCommand: Sendable, Equatable {
    /// Set the retention and prune at once.
    case retention(seconds: Int)
    case prune
    /// Bind busy ports again, then send "ports".
    case retry
    /// Store an OTLP JSON file; answered by "imported" or "import_failed".
    /// The path is absolute and has no line break (`isValidImportPath`).
    case importFile(path: String)

    public var line: String {
        switch self {
        case .retention(let seconds): "retention \(seconds)"
        case .prune: "prune"
        case .retry: "retry"
        case .importFile(let path): "import \(path)"
        }
    }

    /// A path the "import" command can carry: absolute, on one line, and
    /// within the helper's 4,096-byte command limit.
    public static func isValidImportPath(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.contains(where: \.isNewline) && path.utf8.count < 4000
    }
}
