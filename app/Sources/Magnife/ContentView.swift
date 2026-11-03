import MagnifeKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        NavigationSplitView {
            // Column widths from docs/ux.md.
            Sidebar()
                .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        } content: {
            ContentColumn()
                .navigationSplitViewColumnWidth(min: 360, ideal: 520)
        } detail: {
            DetailColumn()
                .navigationSplitViewColumnWidth(min: 420, ideal: 560)
                .toolbar {
                    // Receiver status, at the leading edge of the detail column (docs/ux.md, Toolbar).
                    ToolbarItem { ReceiverStatusView() }
                    ToolbarSpacer(.flexible)
                    ToolbarItem { EnvironmentToolbarButton() }
                    ToolbarItem { SearchToolbarButton() }
                }
        }
        // Search (S-017) floats over every column.
        .overlay { SearchOverlay() }
        // Closed, the list takes the focus back, so the arrow keys work at once (S-022).
        .sheet(isPresented: Binding(get: { model.showsSaveFilterSheet }, set: { if !$0 { model.cancelSaveFilter() } }),
               onDismiss: { model.focusListAfterSheet() }) {
            SaveFilterSheet()
                .environment(model)
                .themed()
        }
        .noInitialFocus()
        .task {
            SelfTest.runIfRequested(model: model)
            Snapshot.runIfRequested(model: model, openSettings: openSettings)
        }
    }
}

/// The content column: the trace list or the Logs list (docs/ux.md,
/// Traces vs Logs), under the receiver banners and the pause bar, with the
/// window's title and the toolbar items over it.
struct ContentColumn: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // Both lists stay in the window; switching only shows the other one.
        // Taking a list out and putting it back cost 100 ms at rest and
        // several hundred under load (AppKit recomputes the key view loop, S-030).
        ZStack {
            TraceListView().shownWhen(model.contentMode == .traces)
            LogListView().shownWhen(model.contentMode == .logs)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                Banners()
                PauseBar()
                if model.contentMode == .traces && model.showsTraceFilterBar {
                    TraceFilterBar()
                    Divider()
                }
                if model.contentMode == .logs && model.showsLogFilterBar {
                    LogFilterBar()
                    Divider()
                }
            }
        }
        .navigationTitle(model.title)
        // At most once a second under load (AppModel+Counts.swift).
        .navigationSubtitle(model.shownSubtitle)
        // Over the list they act on (docs/ux.md, Toolbar items 3 and 4).
        .toolbar {
            ToolbarItem { ContentModePicker() }
            ToolbarItem { PauseButton() }
            ToolbarItem { FilterButton() }
        }
    }
}

/// Traces | Logs, also View > Traces (⌘1) and View > Logs (⌘2).
struct ContentModePicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Picker("View", selection: Binding(get: { model.contentMode }, set: { model.showContentMode($0) })) {
            ForEach(ContentMode.allCases) { mode in
                Text(mode.title)
                    .help(mode.help)
                    .tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

/// The detail column: the trace's waterfall and span detail, or the Log Detail.
struct DetailColumn: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // Both stay in the window, as the lists do (ContentColumn).
        ZStack {
            TraceDetail().shownWhen(model.contentMode == .traces)
            LogDetailView().shownWhen(model.contentMode == .logs)
        }
    }
}

extension View {
    /// Kept in the window but out of sight, out of reach of the pointer and
    /// VoiceOver while `shown` is false. Never `isHidden` on its AppKit
    /// views: hiding the focused table looped forever in SwiftUI's search
    /// for the next key view (FIXLOG).
    func shownWhen(_ shown: Bool) -> some View {
        opacity(shown ? 1 : 0)
            .allowsHitTesting(shown)
            .disabled(!shown)
            .accessibilityHidden(!shown)
    }
}

// MARK: Sidebar

struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        List(selection: $model.sidebar) {
            Label("All Services", systemImage: "square.stack.3d.up")
                .tag(SidebarSelection.allTraces)
            Section("Services") {
                ForEach(model.shownServices) { service in
                    ServiceRow(service: service)
                        .tag(SidebarSelection.service(service.name))
                }
            }
            // Saved Filters (S-021) is hidden while there are none.
            SavedFiltersSection()
        }
        .focused($focused)
        // Delete Filter (⌘⌫) only while the sidebar has the focus.
        .onChange(of: focused) { _, isFocused in model.sidebarHasFocus = isFocused }
        .onChange(of: model.focusRequest) { if model.takeFocusRequest(.sidebar) { focused = true } }
        // Tab and ⇧Tab here go through SidebarTabKeys: the List keeps ⇧Tab from onKeyPress.
        .accessibilityLabel("Sidebar")
        // Return on a saved filter edits its name in place (docs/ux.md, Keyboard map).
        .onKeyPress(.return) {
            guard model.renamingFilterID == nil, model.selectedSavedFilter != nil else { return .ignored }
            model.beginRenamingFilter()
            return .handled
        }
    }
}

struct ServiceRow: View {
    let service: ServiceSummary

    var body: some View {
        HStack(spacing: Space.xs) {
            Label {
                Text(service.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(service.name)
            } icon: {
                ServiceDot(name: service.name)
            }
            Spacer(minLength: Space.xs)
            // Traces with errors: the octagon pairs with the number, never red alone.
            if service.errorCount > 0 {
                Label(CountFormat.string(service.errorCount), systemImage: "exclamationmark.octagon.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(StatusColors.error)
                    .help(service.errorCountText)
            }
        }
        // VoiceOver: "checkout-api, 12 traces with errors" or "web, no errors"; the dot is decoration.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(service.name)
        .accessibilityValue(service.spokenErrors)
    }
}

// MARK: Detail

/// The detail column: the selected trace's waterfall (S-005) over the
/// selected span's detail (S-006), split 55 / 45 by default.
struct TraceDetail: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.showsTraceNoLongerStored {
            TraceNoLongerStored()
        } else if let trace = model.openTrace ?? model.selectedTrace {
            // The split hosts each pane in its own NSHostingView, which does not
            // inherit this view's environment: pass the model and the accent again.
            DetailSplit(showsBottom: model.showsSpanDetail,
                        top: TraceWaterfall(trace: trace).environment(model).themed(),
                        bottom: SpanDetailPane().environment(model).themed())
        } else {
            ContentUnavailableView("No Trace Selected", systemImage: "chart.bar.doc.horizontal",
                                   description: Text("Select a trace to see its waterfall."))
        }
    }
}

/// The header and the waterfall's rows.
struct TraceWaterfall: View {
    @Environment(AppModel.self) private var model
    let trace: TraceSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WaterfallHeader(trace: trace)
            FindingsStrip()
            Divider()
            WaterfallOutline(model: model, generation: model.waterfallGeneration, waterfall: model.waterfall,
                             findings: model.openTraceFindings, collapsed: model.collapsedSpans,
                             selected: model.selectedSpanID, colors: model.serviceColors)
        }
    }
}

/// "POST /orders · checkout-api · 240 ms · 18 spans": the route truncates
/// in the middle, the rest always shows.
struct WaterfallHeader: View {
    let trace: TraceSummary

    var body: some View {
        HStack(spacing: Space.xs) {
            Text(trace.route)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(trace.route)
                .gridProbe("route", area: "trace-header")
            Text("· \(trace.waterfallSubtitle)")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .gridArea("trace-header", inset: Space.lg)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}
