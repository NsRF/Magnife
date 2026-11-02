import AppKit
import MagnifeKit

/// Snapshot states for the log stories.
extension Snapshot {
    /// 04-span-detail-logs: POST /payments scrolled to its Logs section, the
    /// ERROR log's attributes open (S-011).
    /// 04-span-detail-log-json: the web client span's pino record, its
    /// structured body pretty-printed.
    static func captureSpanLogs(_ model: AppModel, dir: String, mode: String) async {
        let checkout = model.traces.first { $0.route == "POST /checkout/pay" }?.traceID
        model.selectedTraceID = checkout
        await SnapshotPage.select(model) { $0.name == "POST /payments" }
        if let log = model.spanDetail?.logs.first { model.toggleExpanded(SpanDetailValueID.logAttributes(log.id)) }
        try? await Task.sleep(for: .seconds(0.5))
        model.spanDetailScrollAnchor = .bottom
        model.spanDetailScrollTarget = .logs
        try? await Task.sleep(for: .seconds(0.8))
        capture(to: "\(dir)/\(SnapshotPage.spanDetail.rawValue)-logs-\(mode).png")

        await SnapshotPage.select(model) { $0.serviceName == "web" && $0.kind == .client }
        try? await Task.sleep(for: .seconds(0.5))
        model.spanDetailScrollTarget = .logs
        try? await Task.sleep(for: .seconds(0.8))
        capture(to: "\(dir)/\(SnapshotPage.spanDetail.rawValue)-log-json-\(mode).png")
        model.spanDetailScrollAnchor = .top
    }
}
