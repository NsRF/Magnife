import MagnifeKit
import SwiftUI

/// The live trace list (S-004): newest first, paged from the database, one
/// color per service, and still while you are scrolled away from the top.
struct TraceListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // Banners, the pause bar, the title and the toolbar are ContentColumn's.
        // The rows are an NSTableView (TraceTable.swift, S-030); its keys are
        // TraceTableKeys.swift's.
        // Each part reads only what it shows, so a batch's new rows update the
        // table alone, not this view and its overlays (S-030).
        TraceRows()
            .overlay(alignment: .top) { NewTracesButton() }
            .overlay { TraceListEmpty() }
    }
}

/// The table, fed with the model's rows.
struct TraceRows: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TraceTable(model: model, rows: model.traces, findings: model.findingCache, now: model.now,
                   colors: model.serviceColors, selected: model.selectedTraceID)
    }
}

/// The list's empty states, over an empty list only.
struct TraceListEmpty: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // Read on every layout: a width kept in @State could miss the
        // column's last resize and leave the variables cut (FIXLOG).
        // Only over an empty list, so it never stands between the pointer and the rows.
        if model.traces.isEmpty {
            GeometryReader { proxy in
                emptyState(width: proxy.size.width)
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
    }

    @ViewBuilder
    private func emptyState(width listWidth: CGFloat) -> some View {
        switch model.storeState {
        case .failed(let error):
            ContentUnavailableView("Can't Read the Database", systemImage: "exclamationmark.triangle",
                                   description: Text(error.message))
        case .ready, .waiting, .opening:
            if model.knowsStoredTraces && model.traces.isEmpty && !model.isLoadingScope {
                if model.traceFilter.narrowsScope {
                    ContentUnavailableView {
                        Label("No Matching Traces", systemImage: "line.3.horizontal.decrease")
                    } description: {
                        Text("No traces match these filters.")
                    } actions: {
                        ClearTraceFiltersButton()
                    }
                } else if let service = model.scopeService {
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

/// "Clear Filters" in the empty state of a filtered list; its own view, so
/// it reads the environment where it is built.
struct ClearTraceFiltersButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        Button("Clear Filters") { model.clearTraceFilters(undoManager: undoManager) }
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
/// Under Increase Contrast it gets a ring in the label color (S-031).
struct ServiceDot: View {
    @Environment(AppModel.self) private var model
    let name: String

    var body: some View {
        Image(systemName: "circle.fill")
            .imageScale(.small)
            .foregroundStyle(ServicePalette.color(slot: model.serviceColors.slot(for: name)))
            // Clear unless Increase Contrast is on.
            .overlay { Image(systemName: "circle").imageScale(.small).foregroundStyle(StatusColors.contrastEdge) }
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
                .foregroundStyle(StatusColors.error)
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
