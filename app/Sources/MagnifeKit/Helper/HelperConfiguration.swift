import Foundation

/// How to launch magnife-ingest (docs/schema.sql, "Helper protocol").
public struct HelperConfiguration: Sendable {
    public static let defaultGRPCPort = 4317
    public static let defaultHTTPPort = 4318
    /// 24 hours (S-015).
    public static let defaultRetention = Retention.defaultSeconds

    public var executableURL: URL
    public var databaseURL: URL
    public var grpcPort: Int
    public var httpPort: Int
    public var retentionSeconds: Int
    public var backoff: RestartBackoff
    /// How long stop() waits after closing stdin before it terminates the helper.
    public var stopTimeout: TimeInterval
    /// Added to the app's environment for the helper.
    public var environment: [String: String]

    public init(executableURL: URL, databaseURL: URL,
                grpcPort: Int = defaultGRPCPort, httpPort: Int = defaultHTTPPort,
                retentionSeconds: Int = defaultRetention, backoff: RestartBackoff = RestartBackoff(),
                stopTimeout: TimeInterval = 3, environment: [String: String] = [:]) {
        self.executableURL = executableURL
        self.databaseURL = databaseURL
        self.grpcPort = grpcPort
        self.httpPort = httpPort
        self.retentionSeconds = retentionSeconds
        self.backoff = backoff
        self.stopTimeout = stopTimeout
        self.environment = environment
    }

    /// The contract's flags. The helper binds 127.0.0.1 only.
    public var arguments: [String] {
        ["--db", databaseURL.path,
         "--grpc", "127.0.0.1:\(grpcPort)",
         "--http", "127.0.0.1:\(httpPort)",
         "--retention", String(retentionSeconds)]
    }

    /// Contents/Helpers/magnife-ingest inside the app bundle.
    public static func bundledExecutable(in bundle: Bundle = .main) -> URL {
        bundle.bundleURL.appending(path: "Contents/Helpers/magnife-ingest")
    }

    /// APP_GRPC_PORT and APP_HTTP_PORT override 4317 and 4318.
    public static func ports(environment: [String: String] = ProcessInfo.processInfo.environment) -> (grpc: Int, http: Int) {
        func port(_ key: String, _ fallback: Int) -> Int {
            guard let value = environment[key].flatMap({ Int($0) }), (1...65_535).contains(value) else { return fallback }
            return value
        }
        return (port("APP_GRPC_PORT", defaultGRPCPort), port("APP_HTTP_PORT", defaultHTTPPort))
    }
}
