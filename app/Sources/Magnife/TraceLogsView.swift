import MagnifeKit
import SwiftUI

/// Trace Logs (S-012), the span detail's second tab: every log that carries
/// the open trace's id, in time order. Selecting a log selects its span in
/// the waterfall; Return also moves focus there. Bodies are one line,
/// truncated at the tail, with the whole body as a tooltip.
struct TraceLogsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.traceLogs.isEmpty {
            if model.traceLogs.traceID == model.selectedTraceID, model.selectedTraceID != nil {
                ContentUnavailableView(TraceLogs.emptyTitle, systemImage: "text.page",
                                       description: Text(TraceLogs.emptyDescription))
            } else {
                // Still being read: nothing, rather than a flash of the empty state.
                Color.clear
            }
        } else {
            table
        }
    }

    // Fixed Time and Level, and ideals that add up to what fits the
    // 560 pt detail column: SwiftUI's Table lays columns out at their
    // ideal widths and does not shrink them to fit (PROGRESS decision 63).
    private var table: some View {
        let selection = Binding<LogLine.ID?>(get: { model.selectedTraceLogID }, set: { model.selectTraceLog($0) })
        return Table(model.traceLogs.lines, selection: selection) {
            TableColumn("Time") { log in
                Text(log.time)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    // The row's sentence lives here; the other cells are hidden, so VoiceOver reads it once.
                    .accessibilityLabel(log.accessibilityLabel(span: model.traceLogSpan(log)))
            }
            .width(96)
            TableColumn("Level") { log in
                LogLevelLabel(level: log.level)
                    .accessibilityHidden(true)
            }
            .width(64)
            TableColumn("Service") { log in
                ServiceName(name: log.record.serviceName)
                    .accessibilityHidden(true)
            }
            .width(min: 56, ideal: 64, max: 160)
            TableColumn("Span") { log in
                TraceLogSpanCell(span: model.traceLogSpan(log))
                    .accessibilityHidden(true)
            }
            .width(min: 56, ideal: 80, max: 240)
            TableColumn("Body") { log in
                Text(log.record.body.prefix(Self.bodyPrefix))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(String(log.record.body.prefix(Self.tooltipPrefix)))
                    .accessibilityHidden(true)
            }
            .width(min: 80, ideal: 120, max: .infinity)
        }
        .alternatingRowBackgrounds(.enabled)
        .contextMenu(forSelectionType: LogLine.ID.self) { ids in
            if let log = ids.first.flatMap({ id in model.traceLogs.lines.first { $0.id == id } }) {
                Button("Copy Body") { model.copyBody(log.record.body) }
                Button("Copy Trace ID") { model.copyTraceID(model.traceLogs.traceID) }
            }
        } primaryAction: { ids in
            // Return and double-click: its span, and focus moves to the waterfall.
            model.openTraceLogSpan(ids.first)
        }
        .onCopyCommand {
            guard let log = model.selectedTraceLog else { return [] }
            return [NSItemProvider(object: log.record.body as NSString)]
        }
    }

    /// A body is one line here: only its start is laid out.
    static let bodyPrefix = 500
    static let tooltipPrefix = 2_000
}

/// The Span column: the span's name, "—" without a span id, or "Span not received".
struct TraceLogSpanCell: View {
    let span: TraceLogSpan

    var body: some View {
        switch span {
        case .span(_, let name):
            Text(name)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(name)
        case .none:
            Text(span.text)
                .foregroundStyle(.secondary)
                .help("This log has no span ID")
        case .notReceived:
            Text(span.text)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help("Magnife has not received the span this log names")
        }
    }
}
