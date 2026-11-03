import Foundation
import Testing
@testable import MagnifeKit

/// Sparkle builds start the updater only with a real feed and key (docs/RELEASE.md).
@Suite("Update configuration (Sparkle)")
struct UpdateConfigurationTests {
    /// 32 zero bytes: the right length for an Ed25519 public key, not anyone's key.
    static let wellFormedKey = Data(count: 32).base64EncodedString()

    static let cases: [(String, String?, String?, Bool)] = [
        ("an HTTPS feed and a 32-byte key", "https://example.com/appcast.xml", wellFormedKey, true),
        ("HTTPS in capitals", "HTTPS://example.com/appcast.xml", wellFormedKey, true),
        ("the placeholders build.sh writes", UpdateConfiguration.feedPlaceholder, UpdateConfiguration.publicKeyPlaceholder, false),
        ("a real feed with the placeholder key", "https://example.com/appcast.xml", UpdateConfiguration.publicKeyPlaceholder, false),
        ("the placeholder feed with a key", UpdateConfiguration.feedPlaceholder, wellFormedKey, false),
        ("plain HTTP", "http://example.com/appcast.xml", wellFormedKey, false),
        ("a file URL", "file:///tmp/appcast.xml", wellFormedKey, false),
        ("no host", "https:///appcast.xml", wellFormedKey, false),
        ("no feed", nil, wellFormedKey, false),
        ("no key", "https://example.com/appcast.xml", nil, false),
        ("an empty key", "https://example.com/appcast.xml", "", false),
        ("a key that is not base64", "https://example.com/appcast.xml", "not a key!", false),
        ("a 16-byte key", "https://example.com/appcast.xml", Data(count: 16).base64EncodedString(), false),
    ]

    @Test(arguments: cases)
    func configured(_ testCase: (String, String?, String?, Bool)) {
        let (_, feed, key, expected) = testCase
        #expect(UpdateConfiguration.isConfigured(feedURL: feed, publicKey: key) == expected, "\(testCase.0)")
    }

    @Test func readsTheInfoDictionaryKeys() {
        #expect(UpdateConfiguration.isConfigured(infoDictionary: [
            "SUFeedURL": "https://example.com/appcast.xml", "SUPublicEDKey": Self.wellFormedKey,
        ]))
        // The default build's Info.plist has neither key.
        #expect(!UpdateConfiguration.isConfigured(infoDictionary: ["CFBundleIdentifier": "com.nasserfarhat.magnife"]))
    }
}
