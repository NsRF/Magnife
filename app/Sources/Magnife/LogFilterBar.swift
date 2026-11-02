import AppKit
import MagnifeKit
import SwiftUI

/// The Logs filter bar (S-014), over the log list: Service pop-up · level
/// chips · "Body contains" · Clear Filters · close. One line when the
/// column is wide enough, else the chips take a second line. Esc or the
/// close button hides it; the filters stay on.
struct LogFilterBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    @FocusState private var bodyFocused: Bool

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Space.sm) {
                LogServicePicker()
                LevelChips()
                bodyField
                Spacer(minLength: 0)
                trailing
            }
            VStack(alignment: .leading, spacing: Space.sm) {
                HStack(spacing: Space.sm) {
                    LogServicePicker()
                        .gridProbe("log-filter-service", area: "log-filter-bar")
                    bodyField
                    trailing
                }
                // Under the pop-up, on the bar's leading edge.
                LevelChips()
                    .gridProbe("log-level-chips", area: "log-filter-bar")
            }
        }
        .controlSize(.small)
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .gridArea("log-filter-bar", inset: Space.lg)
        .onExitCommand { model.hideLogFilterBar() }
        .onAppear { focusIfAsked() }
        .onChange(of: model.focusesLogFilterField) { focusIfAsked() }
    }

    private var bodyField: some View {
        @Bindable var model = model
        return TextField("Body contains", text: $model.logBodyText, prompt: Text("Body contains"))
            .textFieldStyle(.roundedBorder)
            .labelsHidden()
            .frame(minWidth: 96, idealWidth: 160, maxWidth: 240)
            .focused($bodyFocused)
    }

    private var trailing: some View {
        HStack(spacing: Space.sm) {
            Button("Clear Filters") { model.clearLogFilters(undoManager: undoManager) }
                .disabled(!model.hasLogFilters)
            Button {
                model.hideLogFilterBar()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Hide the filter bar (Esc)")
            .accessibilityLabel("Hide Filter Bar")
        }
    }

    private func focusIfAsked() {
        guard model.focusesLogFilterField else { return }
        model.focusesLogFilterField = false
        bodyFocused = true
    }
}

/// All Services and each service: the same setting as the sidebar.
struct LogServicePicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Picker("Service", selection: Binding(get: { model.sidebar?.serviceName ?? "" },
                                             set: { model.sidebar = $0.isEmpty ? .allTraces : .service($0) })) {
            Text("All Services").tag("")
            ForEach(model.services) { service in
                Text(service.name).tag(service.name)
            }
        }
        .labelsHidden()
        .fixedSize()
        .help("Show the logs of one service")
    }
}

/// TRACE to FATAL as toggle buttons. A click shows only that level, ⌘-click
/// or Space adds or removes one; none on means every level.
struct LevelChips: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: Space.xs) {
            ForEach(SeverityLevel.allCases, id: \.self) { level in
                LevelChip(level: level, isOn: model.logLevels.contains(level)) {
                    model.clickLevelChip(level, adding: Self.adds)
                }
            }
        }
        .fixedSize()
    }

    /// ⌘-click, or Space on the focused chip, adds or removes one level.
    private static var adds: Bool {
        guard let event = NSApp.currentEvent else { return false }
        return event.modifierFlags.contains(.command) || event.type == .keyDown
    }
}

/// One chip: filled with the accent and checked while on, so "on" never
/// rests on a faint bezel change or on color alone; VoiceOver reads "ERROR, on".
struct LevelChip: View {
    let level: SeverityLevel
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        if isOn {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    private var button: some View {
        Button(action: action) {
            // The checkmark says "on" in an inactive window too, where the fill turns gray.
            if isOn {
                Label(level.title, systemImage: "checkmark")
            } else {
                Text(level.title)
            }
        }
        .help(level.chipHelp)
        .accessibilityLabel(level.title)
        .accessibilityValue(isOn ? "on" : "off")
        .accessibilityAddTraits(.isToggle)
    }
}

/// The toolbar's Filter button in the Logs view, filled with the accent
/// while a level or body filter is on (docs/ux.md, Toolbar item 5).
struct LogFilterButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.toggleLogFilterBar()
        } label: {
            Label("Filter", systemImage: model.hasLogBarFilters ? "line.3.horizontal.decrease.circle.fill"
                                                                : "line.3.horizontal.decrease.circle")
        }
        .labelStyle(.iconOnly)
        .foregroundStyle(model.hasLogBarFilters ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
        .help(help)
        .accessibilityValue(model.hasLogBarFilters ? "Filters are on" : "")
    }

    private var help: String {
        if model.showsLogFilterBar { return "Hide the filter bar (⌘F)" }
        return model.hasLogBarFilters ? "Filters are on. Show the filter bar (⌘F)" : "Show the filter bar (⌘F)"
    }
}

/// "Clear Filters" in the empty state of a filtered list; its own view, so
/// it reads the environment where it is built.
struct ClearLogFiltersButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        Button("Clear Filters") { model.clearLogFilters(undoManager: undoManager) }
    }
}
