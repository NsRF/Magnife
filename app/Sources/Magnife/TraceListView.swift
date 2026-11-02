import MagnifeKit
import SwiftUI

/// The live trace list (S-004): newest first, paged from the database, one
/// color per service, and still while you are scrolled away from the top.
struct TraceListView: View {
    @Environment(AppModel.self) private var model
    @State private var listWidth: CGFloat = 0

    var body: some View {
        table
            .overlay(alignment: .top) { NewTracesButton() }
            .safeAreaInset(edge: .top, spacing: 0) { Banners() }
            .navigationTitle(model.title)
    }

    private var table: some View {
        @Bindable var model = model
        return Table(model.traces, selection: $model.selectedTraceID) {
            TableColumn("Service") { trace in
                ServiceName(name: trace.rootService)
                    // The one view inside the NSTableView: it reports scrolling (S-004).
                    .background(TraceListAnchor(scroller: model.listScroller))
                    .onAppear { if trace.id == model.traces.last?.id { model.loadMoreTraces() } }
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
                    .accessibilityLabel(trace.spokenDuration)
            }
            .width(min: 64, ideal: 72)
            .alignment(.trailing)
            TableColumn("Spans") { trace in
                Text(trace.spanCount, format: .number)
                    .monospacedDigit()
                    .accessibilityLabel(trace.spokenSpanCount)
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
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { listWidth = $0 }
    }

    @ViewBuilder
    private var emptyState: some View {
        switch model.storeState {
        case .failed(let error):
            ContentUnavailableView("Can't Read the Database", systemImage: "exclamationmark.triangle",
                                   description: Text(error.message))
        case .ready, .waiting, .opening:
            if model.knowsStoredTraces && model.traces.isEmpty && !model.isLoadingScope {
                if let service = model.sidebar?.serviceName {
                    ContentUnavailableView("No Traces from \(service)", systemImage: "line.3.horizontal.decrease",
                                           description: Text("Traces with a span from \(service) appear here."))
                } else {
                    // S-003: the language tabs and Copy Environment Variables.
                    ContentUnavailableView {
                        Label("No Traces Yet", systemImage: "point.3.connected.trianglepath.dotted")
                    } description: {
                        Text("Set these environment variables in your app, run it, and its traces appear here.")
                    } actions: {
                        // The actions area offers only the description's width; the
                        // variables take the column's, up to the popover's width.
                        EnvironmentSetup(showsWaiting: true)
                            .frame(width: listWidth > 0
                                   ? max(0, min(listWidth - 2 * Space.margin, EnvironmentToolbarButton.popoverWidth))
                                   : nil)
                    }
                }
            }
        }
    }
}

/// "12 new traces" over the top of a list that holds still; clicking it
/// scrolls to the top and inserts them (S-004, design decision 6).
struct NewTracesButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.showsNewTracesButton {
            Button {
                model.showNewestTraces()
            } label: {
                Label(TraceList.newTracesTitle(model.newTraceCount), systemImage: "arrow.up")
            }
            .buttonStyle(.glass)
            .accessibilityHint("Shows them at the top of the list")
            // Below the column headers.
            .padding(.top, Space.section + Space.sm)
            .transition(.opacity)
        }
    }
}

/// A service's color dot. Decoration: VoiceOver reads the name next to it.
struct ServiceDot: View {
    @Environment(AppModel.self) private var model
    let name: String

    var body: some View {
        Image(systemName: "circle.fill")
            .imageScale(.small)
            .foregroundStyle(ServicePalette.color(slot: model.serviceColors.slot(for: name)))
            .accessibilityHidden(true)
    }
}

struct ServiceName: View {
    let name: String

    var body: some View {
        HStack(spacing: Space.xs) {
            ServiceDot(name: name)
            Text(name)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
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
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(status.title)
        case .ok:
            Text(status.title)
        case .unset:
            Text("")
                .accessibilityLabel(status.title)
        }
    }
}
