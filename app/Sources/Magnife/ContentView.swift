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
            TraceListView()
                .navigationSplitViewColumnWidth(min: 360, ideal: 520)
        } detail: {
            TraceDetail()
                .navigationSplitViewColumnWidth(min: 420, ideal: 560)
                .toolbar {
                    // Receiver status, at the leading edge of the detail column (docs/ux.md, Toolbar).
                    ToolbarItem { ReceiverStatusView() }
                    ToolbarSpacer(.flexible)
                    ToolbarItem { EnvironmentToolbarButton() }
                }
        }
        .noInitialFocus()
        .task {
            SelfTest.runIfRequested(model: model)
            Snapshot.runIfRequested(model: model, openSettings: openSettings)
        }
    }
}

// MARK: Sidebar

struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.sidebar) {
            Label("All Services", systemImage: "square.stack.3d.up")
                .tag(SidebarSelection.allTraces)
            Section("Services") {
                ForEach(model.services) { service in
                    ServiceRow(service: service)
                        .tag(SidebarSelection.service(service.name))
                }
            }
            // Saved Filters (S-020) is hidden while there are none.
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
                Label(service.errorCount.formatted(), systemImage: "exclamationmark.octagon.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.red)
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
        if let trace = model.openTrace ?? model.selectedTrace {
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
            Divider()
            WaterfallOutline(model: model, generation: model.waterfallGeneration, waterfall: model.waterfall,
                             collapsed: model.collapsedSpans, selected: model.selectedSpanID,
                             colors: model.serviceColors)
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
