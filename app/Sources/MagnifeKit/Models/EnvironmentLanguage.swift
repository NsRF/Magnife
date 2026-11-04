import Foundation

/// The language tabs of the empty state and the toolbar popover (S-003), with
/// the environment variables that point each OpenTelemetry SDK at Magnife.
/// Every tab uses OTLP/HTTP with protobuf, the one protocol all five SDKs
/// export, so the port is always the receiver's HTTP port. The variables were
/// checked against the real SDKs by scripts/interop (its README); Java has no
/// interop app yet.
public enum EnvironmentLanguage: String, CaseIterable, Identifiable, Sendable {
    case dotnet, go, node, python, java

    /// The tab shown the first time (docs/STORIES.md, S-003).
    public static let defaultLanguage = EnvironmentLanguage.dotnet
    /// A name people replace with their own; a placeholder in angle brackets
    /// would break the pasted line in a shell.
    public static let serviceName = "my-service"
    static let defaultsKey = "environment.language"

    public var id: String { rawValue }

    /// The tab's title, from docs/GLOSSARY.md.
    public var title: String {
        switch self {
        case .dotnet: ".NET"
        case .go: "Go"
        case .node: "Node"
        case .python: "Python"
        case .java: "Java"
        }
    }

    /// The variables in the order they are shown and copied.
    public func variables(httpPort: Int) -> [(name: String, value: String)] {
        var variables: [(name: String, value: String)] = [
            ("OTEL_SERVICE_NAME", Self.serviceName),
            ("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:\(httpPort)"),
            // .NET and Python default to gRPC on 4317, so every tab says it.
            ("OTEL_EXPORTER_OTLP_PROTOCOL", "http/protobuf"),
        ]
        if self == .python {
            // Without it the logging module's records are not exported.
            variables.append(("OTEL_PYTHON_LOGGING_AUTO_INSTRUMENTATION_ENABLED", "true"))
        }
        return variables
    }

    /// Exactly the text the tab shows and Copy Environment Variables copies:
    /// one `export NAME=value` line per variable, so a paste into a shell
    /// sets them for the app it starts.
    public func text(httpPort: Int) -> String {
        variables(httpPort: httpPort).map { "export \($0.name)=\($0.value)" }.joined(separator: "\n")
    }

    /// The one step besides the variables, shown under them (not copied).
    public var note: String {
        switch self {
        case .dotnet: "Call AddOtlpExporter() with no options; it reads these variables."
        case .go: "Use the otlptracehttp and otlploghttp exporters; they read these variables."
        case .node: "Start NodeSDK from @opentelemetry/sdk-node; it reads these variables."
        case .python: "Run your app with opentelemetry-instrument."
        case .java: "Start the JVM with -javaagent:opentelemetry-javaagent.jar."
        }
    }

    /// The last chosen tab, or .NET the first time.
    public static func stored(in defaults: UserDefaults) -> EnvironmentLanguage {
        defaults.string(forKey: defaultsKey).flatMap(EnvironmentLanguage.init(rawValue:)) ?? defaultLanguage
    }

    public func store(in defaults: UserDefaults) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}
