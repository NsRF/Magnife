import MagnifeKit
import SwiftUI

/// The Logs view's list (S-013): every log in the sidebar's scope, newest
/// first, live, paged from the database, still while you are scrolled away
/// from the top. Return, a double-click or the row's arrow opens its trace.
struct LogListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // The rows are an NSTableView (LogTable.swift, S-030), with its keys.
        LogRows()
            .overlay(alignment: .top) { NewLogsButton() }
            .overlay { LogListEmpty() }
    }
}

/// The table, fed with the model's rows; on its own so new rows update it alone (S-030).
struct LogRows: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        LogTable(model: model, rows: model.logs, colors: model.serviceColors, selected: model.selectedLogID)
    }
}

/// The Logs list's empty states.
struct LogListEmpty: View {
    @Environment(AppModel.self) private var model

    var body: some View { emptyState }

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
