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
            TraceList()
                .navigationSplitViewColumnWidth(min: 360, ideal: 520)
        } detail: {
            TraceDetail()
                .navigationSplitViewColumnWidth(min: 420, ideal: 560)
                .toolbar {
                    // Receiver status, at the leading edge of the detail column (docs/ux.md, Toolbar).
                    ToolbarItem { ReceiverStatusView() }
                    ToolbarSpacer(.flexible)
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
                Image(systemName: "circle.fill")
                    .foregroundStyle(ServicePalette.color(for: service.name))
                    .imageScale(.small)
                    .accessibilityHidden(true)
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

// MARK: Trace list

struct TraceList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        table
            .safeAreaInset(edge: .top, spacing: 0) { Banners() }
            .navigationTitle(model.title)
    }

    private var table: some View {
        @Bindable var model = model
        return Table(model.traces, selection: $model.selectedTraceID) {
            TableColumn("Service") { trace in
                ServiceName(name: trace.rootService)
            }
            .width(min: 100, ideal: 120)
            TableColumn("Route") { trace in
                Text(trace.route)
                    .truncationMode(.middle)
                    .help(trace.route)
            }
            .width(min: 120, ideal: 220)
            TableColumn("Duration") { trace in
                Text(DurationFormat.string(nanoseconds: trace.durationNs))
                    .monospacedDigit()
            }
            .width(min: 64, ideal: 72)
            .alignment(.trailing)
            TableColumn("Spans") { trace in
                Text(trace.spanCount, format: .number)
                    .monospacedDigit()
            }
            .width(min: 44, ideal: 48)
            .alignment(.trailing)
            TableColumn("Status") { trace in
                StatusLabel(status: trace.status)
            }
            .width(min: 56, ideal: 64)
            TableColumn("Time") { trace in
                Text(RelativeTime.string(for: trace.start, now: model.now))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(min: 136, ideal: 150)
        }
        .alternatingRowBackgrounds(model.traces.isEmpty ? .disabled : .enabled)
        .overlay { emptyState }
    }

    @ViewBuilder
    private var emptyState: some View {
        switch model.storeState {
        case .failed(let error):
            ContentUnavailableView("Can't Read the Database", systemImage: "exclamationmark.triangle",
                                   description: Text(error.message))
        case .ready, .waiting, .opening:
            if model.traces.isEmpty && !model.isLoadingScope {
                if let service = model.sidebar?.serviceName {
                    ContentUnavailableView("No Traces from \(service)", systemImage: "line.3.horizontal.decrease",
                                           description: Text("Traces with a span from \(service) appear here."))
                } else {
                    // S-003 adds the language tabs and Copy Environment Variables here.
                    ContentUnavailableView {
                        Label("No Traces Yet", systemImage: "point.3.connected.trianglepath.dotted")
                    } description: {
                        Text("Set these environment variables in your app, run it, and its traces appear here.")
                    } actions: {
                        EnvironmentVariables()
                    }
                }
            }
        }
    }
}

/// The OTLP/HTTP variables that point an app at Magnife, as selectable text.
struct EnvironmentVariables: View {
    var body: some View {
        Text(lines)
            .font(.body.monospaced())
            .textSelection(.enabled)
            .fixedSize()
            .padding(Space.md)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
    }

    private var lines: String {
        """
        OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:\(HelperConfiguration.ports().http)
        OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
        """
    }
}

struct ServiceName: View {
    let name: String

    var body: some View {
        HStack(spacing: Space.xs) {
            Image(systemName: "circle.fill")
                .imageScale(.small)
                .foregroundStyle(ServicePalette.color(for: name))
                .accessibilityHidden(true)
            Text(name)
        }
    }
}

/// Error pairs the octagon with the word; OK is the word; Unset is blank.
struct StatusLabel: View {
    let status: SpanStatus

    var body: some View {
        switch status {
        case .error:
            Label(status.title, systemImage: "exclamationmark.octagon.fill")
                .foregroundStyle(.red)
        case .ok:
            Text(status.title)
        case .unset:
            Text("")
                .accessibilityLabel(status.title)
        }
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
                        Image(systemName: "circle.fill")
                            .imageScale(.small)
                            .foregroundStyle(ServicePalette.color(for: span.serviceName))
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
