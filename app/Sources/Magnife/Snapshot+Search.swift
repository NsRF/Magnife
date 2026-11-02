import AppKit
import MagnifeKit

/// Snapshot states for Search (S-017).
extension Snapshot {
    /// 06-command-k-empty: the newest traces. -suggestions: "status:" offers
    /// its values. -tokens: three tokens as chips over their matches.
    /// -no-match: "No traces match “paymnt”."
    static func captureSearchStates(_ model: AppModel, dir: String, mode: String) async {
        let page = SnapshotPage.commandK.rawValue
        for (name, text) in [("empty", ""), ("suggestions", "status:"), ("tokens", "service:checkout-api status:error >50ms"),
                             ("no-match", "paymnt")] {
            await SnapshotPage.search(model, text)
            try? await Task.sleep(for: .seconds(0.6))
            capture(to: "\(dir)/\(page)-\(name)-\(mode).png")
        }
        model.closeSearch()
    }
}

extension Snapshot {
    /// 07-filter-bar-no-matches: OK on, which no seed trace is; the selected
    /// failed checkout stays in the detail column. -duration and -duration-error: S-019.
    static func captureFilterBarStates(_ model: AppModel, dir: String, mode: String) async {
        let page = SnapshotPage.filterBar.rawValue
        model.selectedTraceID = model.traces.first { $0.route == "POST /checkout/pay" }?.traceID
        for _ in 0..<40 where model.waterfall.isEmpty { try? await Task.sleep(for: .milliseconds(50)) }
        model.clickStatusChip(.ok, adding: false)
        await model.reload()
        try? await Task.sleep(for: .seconds(0.8))
        capture(to: "\(dir)/\(page)-no-matches-\(mode).png")

        // 07-filter-bar-duration: "Slower than 100 ms" as typed ">100ms", normalized (S-019).
        // 07-filter-bar-duration-error: "200x", flagged; the list keeps 100 ms.
        model.selectedTraceID = nil
        model.applyTraceFilter(.cleared)
        model.traceSlowerThanText = ">100ms"
        for _ in 0..<20 where model.traceSlowerThanNs == nil { try? await Task.sleep(for: .milliseconds(50)) }
        model.normalizeSlowerThanText()
        await model.reload()
        try? await Task.sleep(for: .seconds(0.8))
        capture(to: "\(dir)/\(page)-duration-\(mode).png")
        model.traceSlowerThanText = "200x"
        try? await Task.sleep(for: .seconds(0.8))
        capture(to: "\(dir)/\(page)-duration-error-\(mode).png")
        model.applyTraceFilter(.cleared)
        model.selectedTraceID = nil
    }
}

extension SnapshotPage {
    /// Opens Search with `text` typed and waits for its results.
    @MainActor
    static func search(_ model: AppModel, _ text: String) async {
        // Opened once: showing it again would select the field's text.
        if !model.showsSearch { model.showSearch() }
        model.searchText = text
        for _ in 0..<40 where model.searchResult?.text != text { try? await Task.sleep(for: .milliseconds(50)) }
        // A counted total follows the page.
        for _ in 0..<20 where model.searchResult?.total == nil { try? await Task.sleep(for: .milliseconds(50)) }
    }
}
