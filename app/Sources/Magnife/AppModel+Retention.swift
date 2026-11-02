import AppKit
import MagnifeKit

/// Settings > General's retention and database size (S-016). The app never
/// deletes anything itself: it tells the helper the new period, the helper
/// prunes and sends `pruned`, and the lists and the size refresh.
extension AppModel {
    /// The pop-up's choice. A longer period applies at once; a shorter one
    /// deletes data now, so it waits for the dialog.
    func requestRetention(_ seconds: Int) {
        guard seconds != retentionSeconds else { return }
        if Retention.asksFirst(from: retentionSeconds, to: seconds) {
            pendingRetention = seconds
        } else {
            retentionSeconds = seconds
        }
    }

    /// Delete: applies the shorter period; the helper prunes at once.
    func confirmRetention() {
        guard let seconds = pendingRetention else { return }
        pendingRetention = nil
        retentionSeconds = seconds
    }

    /// Cancel: the pop-up shows the previous choice again.
    func cancelRetention() {
        pendingRetention = nil
    }

    /// Reads the files' size off the main actor; one read at a time.
    func refreshDatabaseSize() {
        guard databaseSizeTask == nil else { return }
        let url = storeURL
        databaseSizeTask = Task { [weak self] in
            let bytes = await Self.readSize(of: url)
            guard let self else { return }
            self.databaseSizeTask = nil
            if self.databaseSize != bytes { self.databaseSize = bytes }
        }
    }

    @concurrent
    nonisolated private static func readSize(of url: URL) async -> Int64 {
        DatabaseSize.bytes(of: url)
    }

    /// Show in Finder: the database file selected in its folder.
    func showDatabaseInFinder() {
        let exists = FileManager.default.fileExists(atPath: storeURL.path)
        if exists {
            NSWorkspace.shared.activateFileViewerSelecting([storeURL])
        } else {
            NSWorkspace.shared.open(storeURL.deletingLastPathComponent())
        }
    }
}
