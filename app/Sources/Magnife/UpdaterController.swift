import Foundation
import MagnifeKit
#if MAGNIFE_SPARKLE
import Sparkle
#endif

/// Software updates through Sparkle 2, compiled in only with the Sparkle
/// trait (`MAGNIFE_SPARKLE=1 ./build.sh`, docs/RELEASE.md). Without it this
/// type is an empty shell: Sparkle is not linked and Magnife makes no
/// network requests. With it, nothing is checked automatically
/// (SUEnableAutomaticChecks is false); the only request is the one
/// Magnife > Check for Updates… makes, and only once Info.plist has a real
/// feed and key (`UpdateConfiguration`).
final class UpdaterController: ObservableObject {
    static let shared = UpdaterController()

    /// True in builds with the Sparkle trait.
    static var isCompiledIn: Bool {
        #if MAGNIFE_SPARKLE
        true
        #else
        false
        #endif
    }

    /// The menu item's words (docs/GLOSSARY.md).
    static let checkTitle = "Check for Updates…"

    /// Check for Updates… is enabled while this is true (Sparkle's own state:
    /// false while a check or an install is under way, or with no updater).
    @Published private(set) var canCheckForUpdates = false

    /// True once Sparkle's updater was started.
    var isStarted: Bool {
        #if MAGNIFE_SPARKLE
        controller != nil
        #else
        false
        #endif
    }

    /// Info.plist has an HTTPS SUFeedURL and a real SUPublicEDKey.
    static var isConfigured: Bool {
        UpdateConfiguration.isConfigured(infoDictionary: Bundle.main.infoDictionary ?? [:])
    }

    private init() {}

    #if MAGNIFE_SPARKLE
    private var controller: SPUStandardUpdaterController?
    private var observation: NSKeyValueObservation?

    /// Starts Sparkle once, from applicationDidFinishLaunching. Not in the
    /// self-test or snapshot runs (Sparkle keeps its state in the app's own
    /// defaults), and not while Info.plist has the placeholders: an invalid
    /// SUPublicEDKey makes Sparkle show an alert at launch.
    func start() {
        guard controller == nil, !AppDefaults.isTestRun, Self.isConfigured else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        // Sparkle changes canCheckForUpdates on the main thread.
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
            let value = change.newValue ?? false
            MainActor.assumeIsolated { self?.canCheckForUpdates = value }
        }
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
    #else
    func start() {}
    func checkForUpdates() {}
    #endif
}
