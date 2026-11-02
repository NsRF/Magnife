import AppKit
import MagnifeKit

/// The menu bar extra (S-026): Recent Errors and the icon's count, read
/// with every refresh (paused too).
extension AppModel {
    /// Reads the newest traces with an error and the count since the mark,
    /// off the main actor. A failed read keeps what the menu shows.
    func refreshRecentErrors(_ reader: TelemetryReader) async {
        guard let page = try? await reader.recentErrors(changedAfter: recentErrors.mark),
              self.reader === reader else { return }
        recentErrors.apply(page)
    }

    /// Copies what the menu and the icon show, only when it changed: each
    /// change rebuilds the scene's menus.
    func publishRecentErrors() {
        if !RecentErrors.showSame(recentErrors.traces, recentErrorTraces) { recentErrorTraces = recentErrors.traces }
        if newErrorCount != recentErrors.newCount { newErrorCount = recentErrors.newCount }
    }

    /// The menu opened: the count and the red icon reset, and the items'
    /// times are fixed at this moment.
    func recentErrorsMenuOpened() {
        recentErrorsOpenedAt = Date()
        recentErrors.opened()
    }
}
