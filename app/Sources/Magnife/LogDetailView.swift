import MagnifeKit
import SwiftUI

/// The Log Detail (S-013), the detail column of the Logs view: the selected
/// log's level, time and service, then Body (whole, selectable monospace),
/// Attributes, Resource, and Trace with Open Trace. Empty sections are left out.
struct LogDetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let detail = model.logDetail, detail.item.id == model.selectedLogID {
            ScrollView {
                LogDetailContent(detail: detail)
            }
            // Another log starts at the top.
            .id(detail.item.id)
            .scrollBounceBehavior(.basedOnSize)
            .accessibilityLabel("Log Detail")
        } else if model.selectedLogID == nil {
            ContentUnavailableView(LogList.noSelectionTitle, systemImage: "text.page",
                                   description: Text(LogList.noSelectionDescription))
        } else {
            // Still being read: nothing, rather than a flash of the empty state.
            Color.clear
        }
    }
}

/// Ids of the Log Detail's expandable values, apart from the span detail's.
enum LogDetailValueID {
    static let prefix = "log-detail:"
    static func body(_ id: Int64) -> String { "\(prefix)\(id):body" }
    static func attribute(_ id: Int64, _ key: String) -> String { "\(prefix)\(id):attribute:\(key)" }
    static func resource(_ id: Int64, _ key: String) -> String { "\(prefix)\(id):resource:\(key)" }
}

struct LogDetailContent: View {
    let detail: LogDetail

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            LogDetailHeader(line: detail.line)
                .gridProbe("log-header", area: "log-detail")
            ForEach(detail.sections) { section in
                VStack(alignment: .leading, spacing: Space.lg) {
                    Divider()
                    VStack(alignment: .leading, spacing: Space.sm) {
                        Text(section.title)
                            .font(.headline)
                            .accessibilityAddTraits(.isHeader)
                        sectionBody(section)
                    }
                }
                .gridProbe("log-section-\(section.rawValue)", area: "log-detail")
            }
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .gridArea("log-detail", inset: Space.lg)
    }

    @ViewBuilder
    private func sectionBody(_ section: LogDetail.Section) -> some View {
        let id = detail.item.id
        switch section {
        case .body:
            // Whole in the detail; past 40 lines it collapses with "Show All".
            ExpandableText(text: detail.line.body, id: LogDetailValueID.body(id), lineLimit: 40, monospaced: true)
                .font(.callout)
        case .attributes:
            AttributeList(attributes: detail.line.attributes) { LogDetailValueID.attribute(id, $0) }
        case .resource:
            AttributeList(attributes: detail.resourceAttributes) { LogDetailValueID.resource(id, $0) }
        case .trace:
            LogTraceSection(item: detail.item)
        }
    }
}

/// "ERROR  14:02:31.204", then the service and the instrumentation scope.
struct LogDetailHeader: View {
    let line: LogLine

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                LogLevelLabel(level: line.level)
                Text(line.time)
                    .monospacedDigit()
                    .textSelection(.enabled)
            }
            .font(.title3.weight(.semibold))
            HStack(spacing: Space.xs) {
                ServiceName(name: line.record.serviceName)
                if !line.record.scopeName.isEmpty {
                    Text("· \(line.record.scopeName)")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(line.record.scopeName)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Trace ID and Span ID as selectable text, and Open Trace, which needs
/// the trace's spans to be stored.
struct LogTraceSection: View {
    @Environment(AppModel.self) private var model
    let item: LogListItem

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Space.md, verticalSpacing: Space.xs) {
                row("Trace ID", item.record.traceID ?? "")
                if let spanID = item.record.spanID, !spanID.isEmpty { row("Span ID", spanID) }
            }
            .font(.callout)
            Button("Open Trace") { model.openTrace(ofLog: item.id) }
                .disabled(!item.canOpenTrace)
                .help(item.canOpenTrace ? LogList.openTraceHelp : LogList.noSpansHelp)
        }
    }

    private func row(_ key: String, _ value: String) -> some View {
        GridRow {
            Text(key)
                .foregroundStyle(.secondary)
            Text(value)
                .monospaced()
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(key), \(value)")
    }
}
