import Foundation

/// Every count on screen: "1,200 times", "1,201 spans", "1,611 traces",
/// "Show All Findings (1,200)". Always grouped with ",", whatever the Mac's
/// region, so they read the same way as `DurationFormat`, whose decimal mark
/// is always "." (PROGRESS decisions 183 and 192): on a Mac set to `en_BR`
/// or `de_DE`, "1.200 times" beside "1.50 s" would read as one point two, and
/// one screen never groups two counts two ways.
public enum CountFormat {
    private static let locale = Locale(identifier: "en_US")

    public static func string(_ n: Int) -> String {
        n.formatted(.number.locale(locale))
    }
}
