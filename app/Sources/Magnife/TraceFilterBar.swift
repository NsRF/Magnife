import AppKit
import MagnifeKit
import SwiftUI

/// The Traces filter bar (S-018 to S-020, design decision 1), over the
/// trace list: Service pop-up · status chips · "Slower than" · Clear
/// Filters · close, then the condition rows. Esc or the close button hides
/// it; the filters stay on.
struct TraceFilterBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        HStack(spacing: Space.sm) {
            ServiceScopePicker(help: "Show the traces with a span from one service")
                .gridProbe("trace-filter-service", area: "trace-filter-bar")
            StatusChips()
            Spacer(minLength: 0)
            Button("Clear Filters") { model.clearTraceFilters(undoManager: undoManager) }
                .disabled(!model.hasTraceFilters)
            FilterBarCloseButton { model.hideTraceFilterBar() }
        }
        .controlSize(.small)
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .gridArea("trace-filter-bar", inset: Space.lg)
        .onExitCommand { model.hideTraceFilterBar() }
    }
}

/// Error, OK and Unset as toggle buttons. A click shows only that status,
/// ⌘-click or Space adds or removes one; none on means every status.
struct StatusChips: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: Space.xs) {
            ForEach(SpanStatus.chipOrder, id: \.self) { status in
                StatusChip(status: status, isOn: model.traceStatuses.contains(status)) {
                    model.clickStatusChip(status, adding: LevelChips.adds)
                }
            }
        }
        .fixedSize()
    }
}

/// One status chip: accent-filled and checked while on; Error keeps its
/// octagon beside the word, on or off. VoiceOver reads "Error, on".
struct StatusChip: View {
    let status: SpanStatus
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
            HStack(spacing: Space.xs) {
                // The checkmark says "on" in an inactive window too, where the fill turns gray.
                if isOn { Image(systemName: "checkmark") }
                if status == .error {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .foregroundStyle(isOn ? AnyShapeStyle(Palette.onAccent) : AnyShapeStyle(.red))
                }
                Text(status.title)
            }
        }
        .help(status.chipHelp)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.title)
        .accessibilityValue(isOn ? "on" : "off")
        .accessibilityAddTraits([.isButton, .isToggle])
    }
}

/// All Services and each service: the same setting as the sidebar, in
/// both filter bars.
struct ServiceScopePicker: View {
    @Environment(AppModel.self) private var model
    let help: String

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
        .help(help)
    }
}

/// The bar's close button (docs/ux.md, Filter bar).
struct FilterBarCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help("Hide the filter bar (Esc)")
        .accessibilityLabel("Hide Filter Bar")
    }
}

/// The toolbar's Filter button (docs/ux.md, Toolbar item 5): the current
/// view's bar, filled with the accent while its own filters are on.
struct FilterButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let isOn = model.contentMode == .traces ? model.hasTraceBarFilters : model.hasLogBarFilters
        Button {
            model.toggleFilterBar()
        } label: {
            Label("Filter", systemImage: isOn ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .labelStyle(.iconOnly)
        .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
        .help(help(isOn: isOn))
        .accessibilityValue(isOn ? "Filters are on" : "")
    }

    private func help(isOn: Bool) -> String {
        if model.showsFilterBar { return "Hide the filter bar (⌘F)" }
        return isOn ? "Filters are on. Show the filter bar (⌘F)" : "Show the filter bar (⌘F)"
    }
}
