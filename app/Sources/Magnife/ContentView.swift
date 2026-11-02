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
                    .help("\(service.errorCount.formatted()) traces with errors")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(service.name)
        .accessibilityValue(service.errorCount == 0 ? "no errors" : "\(service.errorCount.formatted()) traces with errors")
    }
}

// MARK: Detail

/// The waterfall comes with S-005; for now the selected trace's header and spans.
struct TraceDetail: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let trace = model.selectedTrace {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(trace.route)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .gridProbe("route", area: "trace-header")
                    Text("\(trace.rootService) · \(DurationFormat.string(nanoseconds: trace.durationNs)) · \(trace.spanCount) spans")
                        .foregroundStyle(.secondary)
                        .gridProbe("summary", area: "trace-header")
                }
                .padding(Space.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .gridArea("trace-header", inset: Space.lg)
                Divider()
                List(model.selectedSpans) { span in
                    HStack(spacing: Space.sm) {
                        ServiceDot(name: span.serviceName)
                            .help(span.serviceName)
                        Text(span.name)
                            .lineLimit(1)
                        Text(span.serviceName)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: Space.sm)
                        if span.status == .error { StatusLabel(status: .error) }
                        Text(DurationFormat.string(nanoseconds: span.durationNs))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } else {
            ContentUnavailableView("No Trace Selected", systemImage: "chart.bar.doc.horizontal",
                                   description: Text("Select a trace to see its waterfall."))
        }
    }
}
