import Foundation
import MagnifeKit

/// Where the app keeps what it owns that must survive a relaunch in test
/// runs too (saved filters, S-021): the user's defaults normally; in
/// snapshot and self-test runs (APP_SNAPSHOT, --selftest) the run's own
/// suite (`TestRun.suiteName`, so overlapping runs never share saved
/// filters), and in other APP_STORE runs a shared test suite, so tests never
/// change what people saved.
enum AppDefaults {
    /// The test suite of APP_STORE runs, and the window layout backups of every test run.
    static let testSuiteName = "com.nasserfarhat.magnife.tests"

    /// A snapshot or self-test run.
    static var isTestRun: Bool {
        !(ProcessInfo.processInfo.environment["APP_SNAPSHOT"] ?? "").isEmpty || CommandLine.arguments.contains("--selftest")
    }

    /// The suite `shared` reads, nil for the user's own defaults.
    static let sharedSuiteName: String? = {
        if isTestRun || ProcessInfo.processInfo.environment["APP_DEFAULTS_SUITE"] != nil { return TestRun.suiteName }
        return StoreLocation.isOverridden() ? testSuiteName : nil
    }()

    static let shared: UserDefaults = sharedSuiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard

    /// Empties the test suite (a snapshot or self-test run starts from nothing).
    /// The layout backups stay: they belong to the runs, not to their checks.
    static func resetTestSuite() {
        guard let name = sharedSuiteName else { return }
        let backups = shared.dictionaryRepresentation().filter { $0.key.hasPrefix(layoutBackupPrefix) }
        shared.removePersistentDomain(forName: name)
        for (key, value) in backups { shared.set(value, forKey: key) }
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
    /// One backup per running test run ("layout.backup.<pid>"), so runs
    /// that overlap (two agents' self-tests, a snapshot run) never take
    /// each other's window for the user's.
    static let layoutBackupPrefix = "layout.backup."
    static var layoutBackupKey: String { layoutBackupPrefix + String(ProcessInfo.processInfo.processIdentifier) }

    /// A run with its own database (APP_STORE, snapshot, self-test) is a test run for the layout too.
    static var protectsLayout: Bool { isTestRun || StoreLocation.isOverridden() }

    /// The layout keys as the app's own domain holds them now.
    static func savedLayout() -> [String: Any] {
        let domain = Bundle.main.bundleIdentifier.flatMap { UserDefaults.standard.persistentDomain(forName: $0) } ?? [:]
        return domain.filter { key, _ in layoutPrefixes.contains { key.hasPrefix($0) } }
    }

    /// At launch of a test run: keep the user's layout aside. A backup of a
    /// run that ended without putting it back (crashed, killed) is put back
    /// first; while another run is still going, its backup is the user's
    /// layout, since the window frames in the domain may be that run's.
    static func protectLayout() {
        guard protectsLayout, let suite = UserDefaults(suiteName: testSuiteName) else { return }
        var live: [String: Any]?
        for (key, value) in suite.dictionaryRepresentation() where key.hasPrefix(layoutBackupPrefix) {
            guard let backup = value as? [String: Any] else { continue }
            if let pid = Int32(key.dropFirst(layoutBackupPrefix.count)), pid != getpid(), kill(pid, 0) == 0 {
                live = backup
            } else if live == nil {
                put(backup)
                suite.removeObject(forKey: key)
            } else {
                suite.removeObject(forKey: key)
            }
        }
        // The one-key backup of earlier builds.
        if let old = suite.dictionary(forKey: "layout.backup") {
            if live == nil { put(old) }
            suite.removeObject(forKey: "layout.backup")
        }
        suite.set(live ?? savedLayout(), forKey: layoutBackupKey)
    }

    /// When a test run ends: the user's layout keys exactly as they were.
    static func restoreLayout() {
        guard protectsLayout, let suite = UserDefaults(suiteName: testSuiteName),
              let backup = suite.dictionary(forKey: layoutBackupKey) else { return }
        put(backup)
        suite.removeObject(forKey: layoutBackupKey)
        // The self-test exits right after this: write it out now.
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
        CFPreferencesAppSynchronize(testSuiteName as CFString)
    }

    /// Makes the domain's layout keys `backup`'s: keys it lacks are removed.
    private static func put(_ backup: [String: Any]) {
        for key in savedLayout().keys where backup[key] == nil { UserDefaults.standard.removeObject(forKey: key) }
        for (key, value) in backup { UserDefaults.standard.set(value, forKey: key) }
    }
}
