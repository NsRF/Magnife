import MagnifeKit
import SwiftUI

/// The detail column when retention deleted the selected trace (S-015):
/// a normal content view, read in order, with no announcement.
struct TraceNoLongerStored: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        ContentUnavailableView {
            Label(Retention.noLongerStoredTitle, systemImage: "clock.badge.xmark")
        } description: {
            Text(Retention.keepsText(seconds: model.retentionSeconds))
        } actions: {
            Button("Open Settings") {
                model.settingsTab = .general
                openSettings()
            }
        }
    }
}
