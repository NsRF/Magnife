import Foundation

/// A span or trace status, as OTLP numbers it: 0 Unset, 1 OK, 2 Error.
public enum SpanStatus: Int, Sendable, CaseIterable {
    case unset = 0
    case ok = 1
    case error = 2

    /// Unknown numbers read as Unset.
    public init(code: Int) {
        self = SpanStatus(rawValue: code) ?? .unset
    }

    /// The word on screen (docs/GLOSSARY.md). The trace list shows Unset blank.
    public var title: String {
        switch self {
        case .unset: "Unset"
        case .ok: "OK"
        case .error: "Error"
        }
    }
}

/// A span's OTel kind: 0 Unspecified, 1 Internal, 2 Server, 3 Client, 4 Producer, 5 Consumer.
public enum SpanKind: Int, Sendable, CaseIterable {
    case unspecified = 0
    case `internal` = 1
    case server = 2
    case client = 3
    case producer = 4
    case consumer = 5

    public init(code: Int) {
        self = SpanKind(rawValue: code) ?? .unspecified
    }

    public var title: String {
        switch self {
        case .unspecified: "Unspecified"
        case .internal: "Internal"
        case .server: "Server"
        case .client: "Client"
        case .producer: "Producer"
        case .consumer: "Consumer"
        }
    }
}

/// A log level, from OTel's severity number ranges. Error covers ERROR to ERROR4 (17-20).
public enum SeverityLevel: Int, Sendable, CaseIterable, Comparable {
    case trace = 1
    case debug = 5
    case info = 9
    case warn = 13
    case error = 17
    case fatal = 21

    /// nil for 0 (unspecified) and numbers outside 1-24.
    public init?(number: Int) {
        guard (1...24).contains(number) else { return nil }
        self = SeverityLevel.allCases.last { $0.rawValue <= number }!
    }

    /// The severity numbers this level covers.
    public var range: ClosedRange<Int> { rawValue...(rawValue + 3) }

    /// The word on screen, always in capitals (docs/GLOSSARY.md, Level).
    public var title: String {
        switch self {
        case .trace: "TRACE"
        case .debug: "DEBUG"
        case .info: "INFO"
        case .warn: "WARN"
        case .error: "ERROR"
        case .fatal: "FATAL"
        }
    }

    public static func < (lhs: SeverityLevel, rhs: SeverityLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}
