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
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Space.sm) {
                service
                StatusChips()
                SlowerThanField()
                Spacer(minLength: 0)
                trailing
            }
            // A narrow column: the chips and "Slower than" take a second line.
            VStack(alignment: .leading, spacing: Space.sm) {
                HStack(spacing: Space.sm) {
                    service
                    Spacer(minLength: 0)
                    trailing
                }
                // Top-aligned: a wrapped error under the field never moves the chips.
                HStack(alignment: .top, spacing: Space.sm) {
                    StatusChips()
                        .gridProbe("trace-status-chips", area: "trace-filter-bar")
                    SlowerThanField()
                }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .gridArea("trace-filter-bar", inset: Space.lg)
        .onExitCommand { model.hideTraceFilterBar() }
    }

    private var service: some View {
        ServiceScopePicker(help: "Show the traces with a span from one service")
            .gridProbe("trace-filter-service", area: "trace-filter-bar")
    }

    private var trailing: some View {
        HStack(spacing: Space.sm) {
            Button("Clear Filters") { model.clearTraceFilters(undoManager: undoManager) }
                .disabled(!model.hasTraceFilters)
            FilterBarCloseButton { model.hideTraceFilterBar() }
        }
    }
}

/// "Slower than" (S-019): 200, 200ms, >200ms or 1.5s. Text that does not
/// parse gets a red outline and says how to write it; the list keeps the
/// last valid rule. Focus leaving the field writes the value normalized.
struct SlowerThanField: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
            Text("Slower than")
                .foregroundStyle(.secondary)
                .fixedSize()
            TextField("Slower than", text: $model.traceSlowerThanText, prompt: Text("200 ms"))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .frame(width: 72)
                .focused($focused)
                .overlay {
                    if !model.slowerThanIsValid {
                        RoundedRectangle(cornerRadius: Radius.small - 3).strokeBorder(.red, lineWidth: 1)
                            .allowsHitTesting(false)
                    }
                }
                .accessibilityLabel("Slower than")
                .accessibilityValue(spokenValue)
                .accessibilityHint(model.slowerThanIsValid ? "" : DurationInput.errorText)
            if !model.slowerThanIsValid {
                // Wraps in the room left, so it never widens the column.
                Text(DurationInput.errorText)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true)
            }
        }
        .onChange(of: focused) { _, isFocused in if !isFocused { model.normalizeSlowerThanText() } }
        .onAppear { focusIfAsked() }
        .onChange(of: model.focusesTraceFilterField) { focusIfAsked() }
    }

    /// "200 milliseconds" for VoiceOver.
    private var spokenValue: String {
        DurationInput.parse(model.traceSlowerThanText).map(DurationInput.spoken) ?? model.traceSlowerThanText
    }

    private func focusIfAsked() {
        guard model.focusesTraceFilterField else { return }
        model.focusesTraceFilterField = false
        focused = true
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
