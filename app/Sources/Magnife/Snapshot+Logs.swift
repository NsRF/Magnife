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

    /// 03-trace-detail-trace-logs: the HTTP 500 trace on Trace Logs, the
    /// INSERT Payments log selected and so its span in the waterfall (S-012);
    /// one log has no span ID ("—"), one names a span not received.
    static func captureTraceLogs(_ model: AppModel, dir: String, mode: String) async {
        model.showSpanDetailTab(.traceLogs)
        for _ in 0..<40 where model.traceLogs.lines.count < 5 { try? await Task.sleep(for: .milliseconds(50)) }
        let saved = model.traceLogs.lines.first { $0.record.body == "Payment for order 1042 was not saved" }
        model.selectTraceLog(saved?.id)
        try? await Task.sleep(for: .seconds(0.8))
        capture(to: "\(dir)/\(SnapshotPage.traceDetail.rawValue)-trace-logs-\(mode).png")
        model.selectTraceLog(nil)
        model.showSpanDetailTab(.span)
    }

    /// 05-logs-no-trace: a startup log with no trace ID selected: no arrow, no Trace section.
    /// 05-logs-new-logs: "12 new logs" over a list that holds still (set, not scrolled: the seed fits).
    /// 05-logs-paused: the pause bar counting logs. 05-logs-empty: "No Logs Yet" (S-013).
    static func captureLogStates(_ model: AppModel, dir: String, mode: String) async {
        let page = SnapshotPage.logs.rawValue
        model.selectedLogID = model.logs.first { !$0.hasTrace }?.id
        for _ in 0..<40 where model.logDetail?.item.id != model.selectedLogID { try? await Task.sleep(for: .milliseconds(50)) }
        try? await Task.sleep(for: .seconds(0.8))
        capture(to: "\(dir)/\(page)-no-trace-\(mode).png")

        model.isLogListHeld = true
        model.newLogCount = 12
        try? await Task.sleep(for: .seconds(0.8))
        capture(to: "\(dir)/\(page)-new-logs-\(mode).png")
        model.isLogListHeld = false
        model.newLogCount = 0

        model.pauseForSnapshot(newTraces: 12)
        try? await Task.sleep(for: .seconds(0.8))
        capture(to: "\(dir)/\(page)-paused-\(mode).png")
        model.pauseForSnapshot(newTraces: nil)

        let store = model.storeURL
        model.selectedLogID = nil
        await model.useStore(at: SnapshotPage.emptyStore(next: store))
        try? await Task.sleep(for: .seconds(0.8))
        capture(to: "\(dir)/\(page)-empty-\(mode).png")
        await model.useStore(at: store)
    }
}
