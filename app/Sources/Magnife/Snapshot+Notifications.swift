import AppKit
import MagnifeKit

/// Snapshot states for S-028. The run's poster is the fake one, so nothing
/// asks macOS for permission.
extension Snapshot {
    /// 09-settings-notifications-denied: permission turned off in System
    /// Settings, with "Open System Settings". The plain tab before it shows
    /// the "not yet asked" line.
    static func captureNotificationsDenied(_ model: AppModel, settings: NSWindow, dir: String, mode: String) async {
        guard let fake = model.failureNotifier.fake else { return print("SNAPSHOT no fake notification poster") }
        fake.status = .denied
        await model.failureNotifier.refreshPermission()
        try? await Task.sleep(for: .seconds(0.8))
        capture(to: "\(dir)/\(SnapshotPage.settings.rawValue)-notifications-denied-\(mode).png", window: settings)
        fake.status = .notDetermined
        await model.failureNotifier.refreshPermission()
        try? await Task.sleep(for: .seconds(0.3))
    }
}
