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
