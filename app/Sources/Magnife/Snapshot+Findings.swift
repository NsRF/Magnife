import AppKit
import MagnifeKit

/// Snapshot states for the detector stories (S-023+).
extension Snapshot {
    /// 03-trace-detail-slow-sql: the slow report query's trace, its strip
    /// line clicked, so the span is selected and its detail opens on Findings;
    /// 03-trace-detail-n-plus-one: the 8 repeated order_items queries (S-024);
    /// 03-trace-detail-http-error: the failed checkout's first failed call (S-025).
    static func captureFindings(_ model: AppModel, dir: String, mode: String) async {
        let page = SnapshotPage.traceDetail.rawValue
        for (name, route) in [("slow-sql", "GET /admin/reports"), ("n-plus-one", "GET /account/orders"),
                              ("http-error", "POST /checkout/pay")] {
            await openFirstFinding(model, route: route)
            capture(to: "\(dir)/\(page)-\(name)-\(mode).png")
        }
        model.selectedTraceID = nil
    }

    /// 02-trace-list-findings-wide: the Route column dragged to 300 pt, where
    /// a badge has room for its word beside the whole route (at the 520 pt
    /// list's 98 pt Route column it shows its icon alone, decision 134).
    static func captureWideList(_ model: AppModel, dir: String, mode: String) async {
        guard let window = NSApp.windows.first(where: { $0.canBecomeMain && !$0.isSheet }),
              let table = tableView(in: window.contentView),
              let route = table.tableColumns.first(where: { $0.title == "Route" }) else {
            return print("SNAPSHOT no Route column")
        }
        let width = route.width
        route.width = 300
        try? await Task.sleep(for: .seconds(0.8))
        capture(to: "\(dir)/\(SnapshotPage.traceList.rawValue)-findings-wide-\(mode).png")
        route.width = width
        try? await Task.sleep(for: .seconds(0.4))
    }

    /// The trace list's table: the one with a Route column.
    private static func tableView(in view: NSView?) -> NSTableView? {
        guard let view else { return nil }
        if let table = view as? NSTableView, table.tableColumns.contains(where: { $0.title == "Route" }) { return table }
        for subview in view.subviews { if let found = tableView(in: subview) { return found } }
        return nil
    }

    /// Opens the trace with this route and clicks its first strip line.
    static func openFirstFinding(_ model: AppModel, route: String) async {
        model.selectedTraceID = model.traces.first { $0.route == route }?.traceID
        for _ in 0..<60 where model.waterfall.isEmpty || model.openTraceFindings.isEmpty {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard let finding = model.openTraceFindings.findings.first else { return print("SNAPSHOT no finding in \(route)") }
        model.selectFinding(finding)
        for _ in 0..<60 where model.spanDetail?.span.spanID != finding.spanIDs.first {
            try? await Task.sleep(for: .milliseconds(50))
        }
        try? await Task.sleep(for: .seconds(0.8))
    }
}
