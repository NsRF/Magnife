import Foundation

/// The receiver's state for the toolbar, in the glossary's words.
public enum ReceiverStatus: Sendable, Equatable {
    /// No "ports" line yet.
    case starting
    case ports(ReceiverPorts)
    /// The helper could not run at all.
    case stopped(String)

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

    /// True when at least one port listens.
    public var isReceiving: Bool {
        if case .ports(let ports) = self { return ports.grpc.isListening || ports.http.isListening }
        return false
    }

    /// The busy ports, for the S-001 banner.
    public var busyPorts: [PortStatus] {
        guard case .ports(let ports) = self else { return [] }
        return [ports.grpc, ports.http].filter { !$0.isListening }
    }
}
