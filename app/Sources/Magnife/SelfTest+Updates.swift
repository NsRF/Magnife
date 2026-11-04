import AppKit
import MagnifeKit

/// Software updates (M4, docs/RELEASE.md): Check for Updates… exists only in
/// builds with the Sparkle trait, and no build starts the updater in a test run.
extension SelfTest {
    static func checkUpdates() {
        let item = menuItem(UpdaterController.checkTitle)
        let sparkleKeys = [UpdateConfiguration.feedURLKey, UpdateConfiguration.publicKeyKey,
                           UpdateConfiguration.automaticChecksKey].filter { Bundle.main.object(forInfoDictionaryKey: $0) != nil }
        check("the updater never starts in a self-test run", !UpdaterController.shared.isStarted)
        guard UpdaterController.isCompiledIn else {
            check("without the Sparkle trait there is no Check for Updates…", item == nil)
            check("without the Sparkle trait Info.plist has no SU keys", sparkleKeys.isEmpty, "\(sparkleKeys)")
            check("without the Sparkle trait no Sparkle.framework is loaded",
                  Bundle(identifier: "org.sparkle-project.Sparkle") == nil)
            return
        }
        print("INFO built with the Sparkle trait; feed and key \(UpdaterController.isConfigured ? "configured" : "still placeholders")")
        let appMenu = NSApp.mainMenu?.items.first?.submenu
        check("Check for Updates… is in the Magnife menu", item != nil && item?.menu === appMenu)
        if let items = appMenu?.items, let index = item.flatMap({ items.firstIndex(of: $0) }) {
            let about = items.firstIndex { $0.title.hasPrefix("About ") }
            check("Check for Updates… comes after About Magnife", about.map { $0 < index } ?? false)
        }
        check("Check for Updates… has no keyboard shortcut (Apple's apps give it none)", item?.keyEquivalent == "")
        check("with no updater running Check for Updates… is disabled", item?.isEnabled == false)
        // SPARKLE_AUTOMATIC_CHECKS as the build had it (tools/sparkle-bundle.sh): off unless asked.
        let asked = ProcessInfo.processInfo.environment["SPARKLE_AUTOMATIC_CHECKS"] ?? "0"
        let automatic = Bundle.main.object(forInfoDictionaryKey: UpdateConfiguration.automaticChecksKey)
        check("Info.plist's automatic checks are what SPARKLE_AUTOMATIC_CHECKS=\(asked) asks (off by default)",
              asked == "ask" ? automatic == nil : automatic as? Bool == (asked == "1"), "\(automatic ?? "no key")")
        check("Info.plist has a feed URL and a public key (placeholders until there are real ones)",
              Bundle.main.object(forInfoDictionaryKey: UpdateConfiguration.feedURLKey) is String
                && Bundle.main.object(forInfoDictionaryKey: UpdateConfiguration.publicKeyKey) is String)
    }
}
