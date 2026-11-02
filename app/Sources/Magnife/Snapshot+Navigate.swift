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
}
