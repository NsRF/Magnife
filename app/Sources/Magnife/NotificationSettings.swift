import MagnifeKit
import SwiftUI

/// Settings > Notifications (S-028): the toggle and, while it is on, what
/// macOS allows. A grant made in System Settings calls nothing back, so the
/// status is read again every 2 seconds while the tab shows.
struct NotificationSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var notifier = model.failureNotifier
        Section {
            Toggle("Notify me when a trace has an error", isOn: $notifier.isEnabled)
            if notifier.isEnabled, let permission = notifier.permission, let line = permission.statusLine {
                if permission == .denied {
                    LabeledContent {
                        Button("Open System Settings") { notifier.openSystemSettings() }
                    } label: {
                        Text(line)
                    }
                } else {
                    Text(line)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task {
            while !Task.isCancelled {
                await notifier.refreshPermission()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}
