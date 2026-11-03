import Foundation

/// Counts in finding words: "1,200 times", "Show All Findings (1,200)".
/// Always grouped with ",", whatever the Mac's region, so they read the same
/// way as `DurationFormat`, whose decimal mark is always "." (PROGRESS
/// decision 183): on a Mac set to `en_BR`, "1.200 times" beside "1.50 s"
/// would read as one point two.
public enum CountFormat {
    private static let locale = Locale(identifier: "en_US")

    public static func string(_ n: Int) -> String {
        n.formatted(.number.locale(locale))
    }
}
