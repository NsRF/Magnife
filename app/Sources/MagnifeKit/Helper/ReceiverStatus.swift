import Foundation

/// The receiver's state for the toolbar, in the glossary's words.
public enum ReceiverStatus: Sendable, Equatable {
    /// No "ports" line yet.
    case starting
    case ports(ReceiverPorts)
    /// The helper could not run at all.
    case stopped(String)

    /// Starting shows nothing until it has taken this long (S-001).
    public static let quietStart: TimeInterval = 0.5

    /// "Receiving on 4317 and 4318", "Receiving on 4318 only", "Not receiving".
    public var text: String {
        switch self {
        case .starting:
            return "Starting receiver…"
        case .stopped:
            return "Not receiving"
        case .ports(let ports):
            let grpc = ports.grpc.port.map(String.init) ?? "gRPC"
            let http = ports.http.port.map(String.init) ?? "HTTP"
            switch (ports.grpc.isListening, ports.http.isListening) {
            case (true, true): return "Receiving on \(grpc) and \(http)"
            case (true, false): return "Receiving on \(grpc) only"
            case (false, true): return "Receiving on \(http) only"
            case (false, false): return "Not receiving"
            }
        }
    }

    /// The toolbar's text after the receiver has been starting for `elapsed`
    /// seconds: nothing while a start is still quick, then `text`.
    public func statusText(startingFor elapsed: TimeInterval) -> String? {
        if self == .starting && elapsed < Self.quietStart { return nil }
        return text
    }

    /// True when at least one port listens.
    public var isReceiving: Bool {
        if case .ports(let ports) = self { return ports.grpc.isListening || ports.http.isListening }
        return false
    }

    /// The HTTP port the helper reported, for the environment variables (S-003).
    public var httpPort: Int? {
        if case .ports(let ports) = self { return ports.http.port }
        return nil
    }

    /// The busy ports, for the S-001 banner.
    public var busyPorts: [PortStatus] {
        guard case .ports(let ports) = self else { return [] }
        return [ports.grpc, ports.http].filter { !$0.isListening }
    }

    /// The S-001 / S-002 banner, or nil while no port is busy.
    public var busyBanner: String? {
        let busy = busyPorts
        switch busy.count {
        case 0:
            return nil
        case 1:
            let owner = busy[0].owner.flatMap { $0.isEmpty ? nil : $0 } ?? "another app"
            return "Port \(Self.number(busy[0])) is in use by \(owner). Quit that app, then click Try Again."
        default:
            return "Ports \(Self.number(busy[0])) and \(Self.number(busy[1])) are in use by other apps. Quit them, then click Try Again."
        }
    }

    /// The status tooltip, with the ports the helper reported, else the configured ones.
    public func tooltip(grpcPort: Int, httpPort: Int) -> String {
        var grpc = grpcPort, http = httpPort
        if case .ports(let ports) = self {
            grpc = ports.grpc.port ?? grpcPort
            http = ports.http.port ?? httpPort
        }
        return "Magnife accepts OTLP over gRPC on \(grpc) and HTTP on \(http)"
    }

    /// The S-008 banner after the helper crashed and was restarted.
    public static let restartedBanner = "The receiver stopped and was restarted. Spans sent in the last few seconds may be missing."

    /// The banner for the helper's "error" line (docs/ux.md, App-wide states).
    public static func problem(_ message: String) -> String {
        "The receiver reported a problem: \(message)"
    }

    private static func number(_ port: PortStatus) -> String {
        port.port.map(String.init) ?? port.addr
    }
}
