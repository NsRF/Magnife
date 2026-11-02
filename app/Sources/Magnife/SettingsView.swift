import MagnifeKit
import SwiftUI

/// The Settings window (Command-Comma). One tab per topic, at most about
/// six. Each tab is a grouped Form that sizes to its content, so the
/// window grows to fit and shows no scroll bar it does not need.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.settingsTab) {
            ForEach(SettingsTab.allCases) { tab in
                page(tab)
                    .tabItem { Label(tab.title, systemImage: tab.symbol) }
                    .tag(tab)
            }
        }
        .noInitialFocus()
    }

    @ViewBuilder
    private func page(_ tab: SettingsTab) -> some View {
        Form {
            switch tab {
            case .general: GeneralSettings()
            case .appearance: AppearanceSettings()
            }
        }
        .formStyle(.grouped)
        .fitsContent()
        .frame(width: 480)
    }
}

/// The Settings tabs. Snapshot mode walks through every case.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, appearance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintpalette"
        }
    }
}

/// The receiver's ports and how long data is kept. S-016 adds the database size.
struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    private static let retentions: [(String, Int)] = [
        ("1 hour", 3_600), ("6 hours", 21_600), ("24 hours", 86_400), ("3 days", 259_200), ("7 days", 604_800),
    ]

    var body: some View {
        @Bindable var model = model
        Section("Receiver") {
            LabeledContent("gRPC", value: "127.0.0.1:\(HelperConfiguration.ports().grpc)")
            LabeledContent("HTTP", value: "127.0.0.1:\(HelperConfiguration.ports().http)")
            LabeledContent("Status", value: model.receiver.text)
        }
        Section("Data") {
            Picker(selection: $model.retentionSeconds) {
                ForEach(Self.retentions, id: \.1) { Text($0.0).tag($0.1) }
            } label: {
                Text("Keep traces and logs for")
                Text("Older traces and logs are deleted automatically.")
            }
        }
    }
}
