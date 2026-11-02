import Foundation

/// Where the helper's database lives:
///   ~/Library/Application Support/Magnife/magnife.sqlite
/// APP_STORE=<file in /tmp> overrides it for tests, snapshots, and the self-test.
public enum StoreLocation {
    public static let fileName = "magnife.sqlite"

    public static func url(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let path = environment["APP_STORE"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return URL.applicationSupportDirectory
            .appending(path: "Magnife", directoryHint: .isDirectory)
            .appending(path: fileName)
    }

    /// True when APP_STORE points somewhere else.
    public static func isOverridden(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        !(environment["APP_STORE"] ?? "").isEmpty
    }

    /// True for a file inside /tmp, the only place snapshots and the self-test may use.
    public static func isTestLocation(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return path.hasPrefix("/tmp/") || path.hasPrefix("/private/tmp/")
    }
}
