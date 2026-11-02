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
    /// The layout backup stays: it belongs to the run, not to its checks.
    static func resetTestSuite() {
        guard shared !== UserDefaults.standard else { return }
        let backup = shared.dictionary(forKey: layoutBackupKey)
        shared.removePersistentDomain(forName: testSuiteName)
        if let backup { shared.set(backup, forKey: layoutBackupKey) }
    }

    // MARK: Window layout

    /// AppKit itself saves window frames and column widths in the app's own
    /// defaults ("NSWindow Frame main-AppWindow-1", "NSSplitView Subview
    /// Frames main-AppWindow-1, SidebarNavigationSplitView"), so a test run's
    /// window would become the next real launch's. Test runs copy those keys
    /// into the test suite at launch and put them back when they end; a run
    /// that crashed is put right by the next test run.
    static let layoutPrefixes = ["NSWindow Frame ", "NSSplitView Subview Frames ", "NSTableView Columns ",
                                 "NSTableView Hidden Columns ", "NSTableView Sort Ordering ", "NSOutlineView Items ",
                                 "NSToolbar Configuration "]
    static let layoutBackupKey = "layout.backup"

    /// The layout keys as the app's own domain holds them now.
    static func savedLayout() -> [String: Any] {
        let domain = Bundle.main.bundleIdentifier.flatMap { UserDefaults.standard.persistentDomain(forName: $0) } ?? [:]
        return domain.filter { key, _ in layoutPrefixes.contains { key.hasPrefix($0) } }
    }

    /// At launch of a test run: keep the user's layout aside.
    static func protectLayout() {
        guard isTestRun, let suite = UserDefaults(suiteName: testSuiteName) else { return }
        // A backup left over means the last test run did not end: it holds the user's layout.
        if suite.dictionary(forKey: layoutBackupKey) != nil { restoreLayout() }
        suite.set(savedLayout(), forKey: layoutBackupKey)
    }

    /// When a test run ends: the user's layout keys exactly as they were.
    static func restoreLayout() {
        guard isTestRun, let suite = UserDefaults(suiteName: testSuiteName),
              let backup = suite.dictionary(forKey: layoutBackupKey) else { return }
        for key in savedLayout().keys where backup[key] == nil { UserDefaults.standard.removeObject(forKey: key) }
        for (key, value) in backup { UserDefaults.standard.set(value, forKey: key) }
        suite.removeObject(forKey: layoutBackupKey)
        // The self-test exits right after this: write it out now.
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
        CFPreferencesAppSynchronize(testSuiteName as CFString)
    }
}
