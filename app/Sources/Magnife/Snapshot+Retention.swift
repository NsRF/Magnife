import AppKit
import MagnifeKit

/// Snapshot states for the M3 retention stories.
extension Snapshot {
    /// 03-trace-detail-no-longer-stored: the open trace deleted by retention
    /// (S-015). The seed store is never pruned (APP_HELPER=none), so the state
    /// is set, not waited for; the self-test prunes for real.
    static func captureNoLongerStored(_ model: AppModel, dir: String, mode: String) async {
        guard let id = model.selectedTraceID else { return print("SNAPSHOT no trace selected") }
        model.traceNoLongerStored(id)
        try? await Task.sleep(for: .seconds(0.8))
        capture(to: "\(dir)/\(SnapshotPage.traceDetail.rawValue)-no-longer-stored-\(mode).png")
        model.selectedTraceID = nil
    }

    /// 09-settings-general-delete: the dialog that shortening the period
    /// opens (S-016), as a sheet on the Settings window. Cancelled after the
    /// capture, so nothing is sent (and APP_HELPER=none has no helper anyway).
    static func captureRetentionDialog(_ model: AppModel, settings: NSWindow, dir: String, mode: String) async {
        model.requestRetention(3_600)
        try? await Task.sleep(for: .seconds(0.8))
        guard settings.attachedSheet != nil else {
            model.cancelRetention()
            return print("SNAPSHOT no retention dialog")
        }
        let path = "\(dir)/\(SnapshotPage.settings.rawValue)-general-delete-\(mode).png"
        // `-l` on the Settings window takes its attached sheet with it.
        capture(to: path, window: settings)
        model.cancelRetention()
        try? await Task.sleep(for: .seconds(0.5))
    }
}
