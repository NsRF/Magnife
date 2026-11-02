import Foundation
import MagnifeKit

/// Where the app keeps what it owns that must survive a relaunch in test
/// runs too (saved filters, S-021): the user's defaults normally, a
/// separate suite in snapshot and self-test runs (APP_SNAPSHOT, --selftest)
/// and other APP_STORE runs, so tests never change what people saved.
enum AppDefaults {
    static let testSuiteName = "com.nasserfarhat.magnife.tests"

    /// A snapshot or self-test run.
    static var isTestRun: Bool {
        !(ProcessInfo.processInfo.environment["APP_SNAPSHOT"] ?? "").isEmpty || CommandLine.arguments.contains("--selftest")
    }

    static let shared: UserDefaults = isTestRun || StoreLocation.isOverridden()
        ? UserDefaults(suiteName: testSuiteName) ?? .standard
        : .standard

    /// Empties the test suite (a snapshot or self-test run starts from nothing).
    static func resetTestSuite() {
        guard shared !== UserDefaults.standard else { return }
        shared.removePersistentDomain(forName: testSuiteName)
    }
}
