import AppKit
import MagnifeKit

/// Snapshot states for S-031: Increase Contrast and Reduce Transparency, in
/// light and dark, after the plain pages.
extension Snapshot {
    /// 03-trace-detail-contrast: the HTTP 500 trace under Increase Contrast
    /// (bars with a border, dots with a ring, the high-contrast palette).
    /// 06-command-k-solid and 02-trace-list-paused-solid: the Search panel
    /// and a banner on a solid background (Reduce Transparency).
    static func captureDisplayOptions(_ model: AppModel, dir: String) async {
        for mode in ["light", "dark"] {
            await setAppearance(mode, increaseContrast: true)
            await SnapshotPage.traceDetail.prepare(model)
            try? await Task.sleep(for: .seconds(0.8))
            capture(to: "\(dir)/\(SnapshotPage.traceDetail.rawValue)-contrast-\(mode).png")
            await SnapshotPage.logs.prepare(model)
            try? await Task.sleep(for: .seconds(0.8))
            capture(to: "\(dir)/\(SnapshotPage.logs.rawValue)-contrast-\(mode).png")

            await setAppearance(mode, increaseContrast: false)
            DisplayOverrides.reduceTransparency = true
            await SnapshotPage.commandK.prepare(model)
            try? await Task.sleep(for: .seconds(0.8))
            capture(to: "\(dir)/\(SnapshotPage.commandK.rawValue)-solid-\(mode).png")
            model.closeSearch()
            await SnapshotPage.traceList.prepare(model)
            model.pauseForSnapshot(newTraces: 12)
            try? await Task.sleep(for: .seconds(0.8))
            capture(to: "\(dir)/\(SnapshotPage.traceList.rawValue)-paused-solid-\(mode).png")
            model.pauseForSnapshot(newTraces: nil)
            DisplayOverrides.reduceTransparency = false
        }
    }

    /// `NSAppearance(named:)` has no high-contrast appearance, so the
    /// override stands in for the setting; passing through the other mode
    /// makes every view resolve its colors again, as a change in System
    /// Settings does.
    private static func setAppearance(_ mode: String, increaseContrast: Bool) async {
        DisplayOverrides.increaseContrast = increaseContrast
        NSApp.appearance = NSAppearance(named: mode == "light" ? .darkAqua : .aqua)
        try? await Task.sleep(for: .seconds(0.3))
        NSApp.appearance = NSAppearance(named: mode == "light" ? .aqua : .darkAqua)
    }
}
