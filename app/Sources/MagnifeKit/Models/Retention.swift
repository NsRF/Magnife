import Foundation

/// How long the helper keeps traces and logs (S-015, S-016): "Keep traces and
/// logs for" in Settings > General. The app owns the choice (UserDefaults,
/// never the database) and tells the helper with `--retention` at launch and
/// `retention <seconds>` on change; the helper prunes.
public enum Retention {
    /// 24 hours on first launch (docs/ux.md, Settings).
    public static let defaultSeconds = 86_400
    public static let defaultsKey = "retention.seconds"
    /// APP_RETENTION_SECONDS: any positive number of seconds, for test runs
    /// that watch pruning happen (the self-test's short retention).
    public static let environmentKey = "APP_RETENTION_SECONDS"

    /// The Settings pop-up's choices, shortest first.
    public static let choices = [3_600, 21_600, 86_400, 259_200, 604_800]

    /// The retention at launch: the test hook's seconds, else the stored
    /// choice, else 24 hours. A stored value that is not a choice (an older
    /// or hand-edited default) reads as 24 hours.
    public static func stored(in defaults: UserDefaults,
                              environment: [String: String] = ProcessInfo.processInfo.environment) -> Int {
        if let seconds = environment[environmentKey].flatMap({ Int($0) }), seconds > 0 { return seconds }
        guard let seconds = defaults.object(forKey: defaultsKey) as? Int, choices.contains(seconds) else {
            return defaultSeconds
        }
        return seconds
    }

    /// The pop-up's items: the choices, plus a test hook's value so the pop-up never shows blank.
    public static func menuChoices(including current: Int) -> [Int] {
        choices.contains(current) ? choices : (choices + [current]).sorted()
    }

    /// "1 hour", "6 hours", "24 hours", "3 days", "7 days"; other values in
    /// the largest unit that divides them ("90 seconds").
    public static func title(seconds: Int) -> String {
        let (count, unit) = parts(seconds)
        return "\(count.formatted()) \(count == 1 ? unit : unit + "s")"
    }

    /// The dialog's title case: "1 Hour", "3 Days".
    public static func titleCase(seconds: Int) -> String {
        let (count, unit) = parts(seconds)
        return "\(count.formatted()) \((count == 1 ? unit : unit + "s").capitalized)"
    }

    /// Hours up to 24, then days, as the choices read.
    private static func parts(_ seconds: Int) -> (Int, String) {
        if seconds >= 172_800, seconds.isMultiple(of: 86_400) { return (seconds / 86_400, "day") }
        if seconds >= 3_600, seconds.isMultiple(of: 3_600) { return (seconds / 3_600, "hour") }
        if seconds >= 60, seconds.isMultiple(of: 60) { return (seconds / 60, "minute") }
        return (seconds, "second")
    }

    /// The Trace No Longer Stored state (S-015): "Magnife keeps traces and logs for 24 hours."
    public static func keepsText(seconds: Int) -> String {
        "Magnife keeps traces and logs for \(title(seconds: seconds))."
    }

    /// A shorter period deletes data now, so it asks first (S-016); a longer one applies at once.
    public static func asksFirst(from current: Int, to new: Int) -> Bool { new < current }

    /// The dialog (S-016): "Delete Data Older Than 1 Hour?"
    public static func confirmTitle(seconds: Int) -> String {
        "Delete Data Older Than \(titleCase(seconds: seconds))?"
    }

    public static func confirmMessage(seconds: Int) -> String {
        "Traces and logs older than \(title(seconds: seconds)) are deleted now. You can't undo this action."
    }

    public static let label = "Keep traces and logs for"
    public static let footnote = "Older traces and logs are deleted automatically."
    public static let noLongerStoredTitle = "Trace No Longer Stored"
}
