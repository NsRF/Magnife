import Foundation

/// Whether a build's Info.plist has what Sparkle needs to check for updates
/// (docs/RELEASE.md): an HTTPS `SUFeedURL` and a `SUPublicEDKey` that is a
/// base64 Ed25519 public key (32 bytes). build.sh writes placeholders
/// (`__SPARKLE_FEED_URL__`, `__SPARKLE_PUBLIC_ED_KEY__`) until the owner has
/// a feed and keys; with either one still a placeholder the updater never
/// starts, so the build makes no request and shows no "can't check" alert.
public enum UpdateConfiguration {
    public static let feedURLKey = "SUFeedURL"
    public static let publicKeyKey = "SUPublicEDKey"
    public static let automaticChecksKey = "SUEnableAutomaticChecks"
    public static let feedPlaceholder = "__SPARKLE_FEED_URL__"
    public static let publicKeyPlaceholder = "__SPARKLE_PUBLIC_ED_KEY__"

    public static func isConfigured(feedURL: String?, publicKey: String?) -> Bool {
        guard let feedURL, !feedURL.hasPrefix("__"),
              let url = URL(string: feedURL), url.scheme?.lowercased() == "https",
              let host = url.host(), !host.isEmpty,
              let publicKey, !publicKey.hasPrefix("__"),
              let key = Data(base64Encoded: publicKey), key.count == 32 else { return false }
        return true
    }

    /// The values an Info.plist dictionary holds.
    public static func isConfigured(infoDictionary: [String: Any]) -> Bool {
        isConfigured(feedURL: infoDictionary[feedURLKey] as? String,
                     publicKey: infoDictionary[publicKeyKey] as? String)
    }
}
