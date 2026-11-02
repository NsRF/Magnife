import MagnifeKit
import SwiftUI

/// The Logs view's list (S-013): every log in the sidebar's scope, newest
/// first, live, paged from the database, still while you are scrolled away
/// from the top. Return, a double-click or the row's arrow opens its trace.
struct LogListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        table
            .overlay(alignment: .top) { NewLogsButton() }
            // Esc in the list hides the filter bar too; the filters stay on.
            // onExitCommand does not reach a focused Table (FIXLOG).
            .onKeyPress(.escape) {
                guard model.showsLogFilterBar else { return .ignored }
                model.hideLogFilterBar()
                return .handled
            }
            .listKeys(page: { model.pageRows(model.logScroller) }, move: { model.moveLogSelection($0) },
                      tab: { model.focusNextColumn(from: .list, backward: $0) })
    }

    // Fixed Time and Level; Service's minimum fits "checkout-api" (at the
    // 520 pt column the Table gave it its minimum plus padding, not its
    // ideal); Body takes the rest (PROGRESS decision 63).
    private var table: some View {
        @Bindable var model = model
        return Table(model.logs, selection: $model.selectedLogID) {
            TableColumn("Time") { item in
                Text(item.line.time)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    // The row's sentence lives here; the other cells are hidden, so VoiceOver reads it once.
                    .accessibilityLabel(item.accessibilityLabel)
                    // The one view inside the NSTableView: it reports scrolling.
                    .background(TraceListAnchor(scroller: model.logScroller))
                    .onAppear { if item.id == model.logs.last?.id { model.loadMoreLogs() } }
            }
            .width(96)
            TableColumn("Level") { item in
                LogLevelLabel(level: item.line.level)
                    .accessibilityHidden(true)
            }
            .width(LogLevelLabel.width)
            TableColumn("Service") { item in
                ServiceName(name: item.record.serviceName)
                    .accessibilityHidden(true)
            }
            .width(min: 124, ideal: 128, max: 200)
            TableColumn("Body") { item in
                LogBodyCell(item: item) { model.openTrace(ofLog: item.id) }
            }
            .width(min: 80, ideal: 108, max: .infinity)
        }
        .alternatingRowBackgrounds(model.logs.isEmpty ? .disabled : .enabled)
        .contextMenu(forSelectionType: LogListItem.ID.self) { ids in
            if let item = ids.first.flatMap({ id in model.logs.first { $0.id == id } }) {
                if item.hasTrace {
                    Button("Open Trace") { model.openTrace(ofLog: item.id) }
                        .disabled(!item.canOpenTrace)
                }
                Button("Copy Body") { model.copyBody(item.record.body) }
                if let traceID = item.record.traceID, item.hasTrace {
                    Button("Copy Trace ID") { model.copyTraceID(traceID) }
                }
            }
        } primaryAction: { ids in
            // Return and double-click: Open Trace (docs/ux.md, Keyboard map).
            model.openTrace(ofLog: ids.first)
        }
        .onCopyCommand {
            guard let log = model.selectedLog else { return [] }
            return [NSItemProvider(object: log.record.body as NSString)]
        }
        .accessibilityLabel("Logs")
        .overlay { emptyState }
    }

    @ViewBuilder
    private var emptyState: some View {
        if case .failed(let error) = model.storeState {
            ContentUnavailableView("Can't Read the Database", systemImage: "exclamationmark.triangle",
                                   description: Text(error.message))
        } else if model.logsLoaded && model.logs.isEmpty {
            if model.logFilter.narrowsScope {
                ContentUnavailableView {
                    Label(LogList.noMatchesTitle, systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text(LogList.noMatchesDescription)
                } actions: {
                    ClearLogFiltersButton()
                }
            } else if let service = model.scopeService {
                ContentUnavailableView(LogList.emptyTitle(service: service), systemImage: "line.3.horizontal.decrease",
                                       description: Text(LogList.emptyDescription(service: service)))
            } else {
                ContentUnavailableView {
                    Label(LogList.emptyTitle, systemImage: "text.page")
                } description: {
                    Text(LogList.emptyDescription)
                } actions: {
                    // Its own view: the actions are built outside this body,
                    // where this view's environment cannot be read.
                    CopyEnvironmentButton()
                }
            }
        }
    }
}

/// The body on one line, cut at its tail with its start as a tooltip, and
/// the arrow that opens the log's trace when it has one.
struct LogBodyCell: View {
    let item: LogListItem
    let openTrace: () -> Void

    var body: some View {
        HStack(spacing: Space.xs) {
            Text(item.record.body.prefix(TraceLogsView.bodyPrefix))
                .lineLimit(1)
                .truncationMode(.tail)
                .help(String(item.record.body.prefix(TraceLogsView.tooltipPrefix)))
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityHidden(true)
            if item.hasTrace {
                Button(action: openTrace) {
                    Image(systemName: "arrow.right.circle")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .disabled(!item.canOpenTrace)
                .help(item.canOpenTrace ? LogList.openTraceHelp : LogList.noSpansHelp)
                .accessibilityLabel("Open Trace")
            }
        }
    }
}

/// The last chosen language's variables, as ⇧⌘C copies them; reads "Copied" for 2 seconds.
struct CopyEnvironmentButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button(model.environmentCopied ? "Copied" : "Copy Environment Variables") {
            model.copyEnvironmentVariables()
        }
        .help("Copy the environment variables that point an app at Magnife (⇧⌘C)")
    }
}

/// "12 new logs" over the top of a Logs list that holds still.
struct NewLogsButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.showsNewLogsButton {
            Button {
                model.showNewestLogs()
            } label: {
                Label(LogList.newLogsTitle(model.newLogCount), systemImage: "arrow.up")
            }
            .buttonStyle(.glass)
            .accessibilityHint("Shows them at the top of the list")
            // Below the column headers.
            .padding(.top, Space.section + Space.sm)
            .transition(.opacity)
        }
    }
}
