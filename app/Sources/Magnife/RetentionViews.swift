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

/// Settings > General, Data (S-016): "Keep traces and logs for" and the
/// database size. Shortening the period asks first; Cancel leaves the
/// pop-up on the previous choice, because the choice only changes on Delete.
struct RetentionSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section("Data") {
            Picker(selection: Binding(get: { model.retentionSeconds }, set: { model.requestRetention($0) })) {
                ForEach(Retention.menuChoices(including: model.retentionSeconds), id: \.self) { seconds in
                    Text(Retention.title(seconds: seconds)).tag(seconds)
                }
            } label: {
                Text(Retention.label)
                Text(Retention.footnote)
            }
            LabeledContent("Database size") {
                HStack(spacing: Space.sm) {
                    Text(DatabaseSize.text(model.databaseSize ?? 0))
                        .monospacedDigit()
                        .accessibilityLabel("Database size")
                        .accessibilityValue(DatabaseSize.spoken(model.databaseSize ?? 0))
                    Button("Show in Finder") { model.showDatabaseInFinder() }
                        .help("Show the database file in Finder")
                }
            }
        }
        .task { model.refreshDatabaseSize() }
        .alert(Retention.confirmTitle(seconds: model.pendingRetention ?? model.retentionSeconds),
               isPresented: Binding(get: { model.pendingRetention != nil }, set: { if !$0 { model.cancelRetention() } }),
               presenting: model.pendingRetention) { _ in
            // Delete is the default button, not destructive-styled: people chose it (docs/ux.md).
            Button("Delete") { model.confirmRetention() }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { model.cancelRetention() }
        } message: { seconds in
            Text(Retention.confirmMessage(seconds: seconds))
        }
    }
}
