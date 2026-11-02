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
}
