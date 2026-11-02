import AppKit
import MagnifeKit

/// Snapshot states for the M2 navigation stories.
extension Snapshot {
    /// 02-trace-list-service: the sidebar scoped to orders (S-009): its row
    /// selected, the title "orders", and the traces with a span from it,
    /// each still showing its root service.
    static func captureServiceScope(_ model: AppModel, dir: String, mode: String) async {
        model.sidebar = .service("orders")
        await model.reload()
        try? await Task.sleep(for: .seconds(0.8))
        capture(to: "\(dir)/\(SnapshotPage.traceList.rawValue)-service-\(mode).png")
        model.sidebar = .allTraces
        await model.reload()
    }

    /// 02-trace-list-paused: the pause bar with 12 traces arrived meanwhile,
    /// Resume in the toolbar and "Paused · " in the subtitle (S-010). The
    /// state is set, not waited for; the self-test pauses for real.
    static func capturePaused(_ model: AppModel, dir: String, mode: String) async {
        model.pauseForSnapshot(newTraces: 12)
        try? await Task.sleep(for: .seconds(0.8))
        capture(to: "\(dir)/\(SnapshotPage.traceList.rawValue)-paused-\(mode).png")
        model.pauseForSnapshot(newTraces: nil)
    }
}
