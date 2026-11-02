import Foundation
import MagnifeKit

/// What one test run (self-test, snapshots) owns alone, so runs that overlap
/// (two agents' self-tests, a snapshot run beside them) never share a file
/// or a defaults domain: a directory in /tmp and a defaults suite per run.
///   APP_TEST_ROOT=<dir in /tmp>   the run's directory (tools/selftest.sh and snap.sh make one with mktemp -d)
///   APP_SHOTS_DIR=<dir>          where self-test captures go (default <root>/shots)
///   APP_DEFAULTS_SUITE=<name>    the run's defaults suite (a launched copy gets its own, S-029)
enum TestRun {
    /// Every run suite starts with this, so a sweep can find the ones a crashed run left.
    static let suitePrefix = "com.nasserfarhat.magnife.tests.run."

    /// The run's directory: APP_TEST_ROOT, or a fresh one in /tmp.
    static let directory: URL = {
        if let path = ProcessInfo.processInfo.environment["APP_TEST_ROOT"], !path.isEmpty {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            if StoreLocation.isTestLocation(url.appending(path: "x")) {
                try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                return url
            }
        }
        var template = Array("/tmp/Magnife-run.\(getpid()).XXXXXX".utf8CString)
        let made = template.withUnsafeMutableBufferPointer { mkdtemp($0.baseAddress) }
        let path = made.map { String(cString: $0) } ?? "/tmp/Magnife-run.\(getpid())"
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return URL(fileURLWithPath: path, isDirectory: true)
    }()

    /// A fresh subdirectory of the run's directory (removed first if it exists).
    static func scratch(_ name: String) -> URL {
        let url = directory.appending(path: name, directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: url)
        return url
    }

    /// Where the self-test writes its captures (03-trace-detail-30000-*.png).
    static var shotsDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["APP_SHOTS_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return directory.appending(path: "shots", directoryHint: .isDirectory)
    }

    /// The run's own defaults suite: APP_DEFAULTS_SUITE, or one per process.
    static let suiteName: String = {
        if let name = ProcessInfo.processInfo.environment["APP_DEFAULTS_SUITE"], name.hasPrefix(suitePrefix) {
            return name
        }
        return suitePrefix + String(getpid())
    }()

    /// True when the suite is this process's own (not handed in), so the run removes it at exit.
    static var ownsSuite: Bool { suiteName == suitePrefix + String(getpid()) }

    /// Removes the suites that runs which ended without cleaning up (crashed, killed) left behind.
    static func sweepSuites() {
        let preferences = URL.libraryDirectory.appending(path: "Preferences")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: preferences.path)) ?? []
        for file in files where file.hasPrefix(suitePrefix) && file.hasSuffix(".plist") {
            let name = String(file.dropLast(".plist".count))
            // The pid is the first part after the prefix (a launched copy's suite adds ".launch").
            guard let pid = Int32(name.dropFirst(suitePrefix.count).prefix { $0.isNumber }),
                  pid != getpid(), kill(pid, 0) != 0 else { continue }
            UserDefaults().removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: preferences.appending(path: file))
        }
    }

    /// At the end of a test run: its suite goes, so ~/Library/Preferences keeps nothing of it.
    static func removeSuite() {
        guard ownsSuite else { return }
        UserDefaults().removePersistentDomain(forName: suiteName)
        CFPreferencesAppSynchronize(suiteName as CFString)
    }
}
