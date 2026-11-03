import AppKit
import MagnifeKit
import SwiftUI

/// The Logs section of the span detail (S-011): the logs written during the
/// span, oldest first. Each row shows time, level and body; its disclosure
/// triangle shows the attributes. Over 50 logs, the first 50 show with
/// "Show All (312)".
struct SpanLogList: View {
    @Environment(AppModel.self) private var model
    let detail: SpanDetail

    private var showsAll: Bool { model.expandedValues.contains(SpanDetailValueID.allLogs) }

    var body: some View {
        // Lazy: a chatty span can carry thousands of logs.
        LazyVStack(alignment: .leading, spacing: Space.sm) {
            ForEach(detail.shownLogs(all: showsAll)) { log in
                SpanLogRow(log: log)
            }
            if let title = detail.showAllLogsTitle {
                Button(showsAll ? "Show Less" : title) { model.toggleExpanded(SpanDetailValueID.allLogs) }
                    .buttonStyle(.link)
                    .controlSize(.small)
            }
        }
    }
}

/// "▸ 14:02:31.204  ERROR  Payment declined for order 1182". The body wraps
/// and collapses after three lines with "Show All"; a JSON body shows
/// pretty-printed in monospace. Body and attributes are selectable.
struct SpanLogRow: View {
    @Environment(AppModel.self) private var model
    let log: LogLine

    private var attributesID: String { SpanDetailValueID.logAttributes(log.id) }
    private var showsAttributes: Bool { model.expandedValues.contains(attributesID) }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                disclosure
                HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                    Text(log.time)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    LogLevelLabel(level: log.level)
                        .frame(width: LogLevelLabel.width, alignment: .leading)
                    ExpandableText(text: log.body, id: SpanDetailValueID.logBody(log.id), monospaced: log.isStructured)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(log.accessibilityLabel)
            }
            if showsAttributes {
                AttributeList(attributes: log.attributes) { SpanDetailValueID.logAttribute(log.id, $0) }
                    .padding(.leading, Self.attributeIndent)
            }
        }
        .font(.callout)
        .contextMenu {
            Button("Copy Body") { model.copyBody(log.record.body) }
        }
    }

    /// The triangle, or the same room when the log has no attributes, so every row's time lines up.
    @ViewBuilder
    private var disclosure: some View {
        if log.attributes.isEmpty {
            Color.clear.frame(width: Self.triangleWidth, height: 1)
                .accessibilityHidden(true)
        } else {
            Button {
                model.toggleExpanded(attributesID)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(showsAttributes ? 90 : 0))
                    .frame(width: Self.triangleWidth)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help(showsAttributes ? "Hide attributes" : "Show attributes")
            .accessibilityLabel(showsAttributes ? "Hide attributes" : "Show attributes")
        }
    }

    static let triangleWidth: CGFloat = 12
    /// Attributes start under the time.
    static let attributeIndent: CGFloat = triangleWidth + Space.sm
}

/// A log's level: its icon and its word in capitals, never color alone
/// (docs/GLOSSARY.md, Level). No level reads "—" with "No level set".
struct LogLevelLabel: View {
    let level: SeverityLevel?

    /// "ERROR" and "DEBUG" with their icon, at callout size.
    static let width: CGFloat = 72

    var body: some View {
        if let level {
            Label {
                Text(level.title)
                    .foregroundStyle(Self.wordStyle(level))
            } icon: {
                Image(systemName: Self.symbol(level))
                    .foregroundStyle(Self.iconStyle(level))
            }
            .labelStyle(.titleAndIcon)
            .fontWeight(level >= .warn ? .semibold : .regular)
            .lineLimit(1)
            .fixedSize()
        } else {
            Text(LogLine.noLevel)
                .foregroundStyle(.secondary)
                .help(LogLine.noLevelHelp)
                .accessibilityLabel("no level")
        }
    }

    /// One SF Symbol per level; Error keeps the octagon it has everywhere else.
    static func symbol(_ level: SeverityLevel) -> String {
        switch level {
        case .trace: "circle.dotted"
        case .debug: "ladybug"
        case .info: "info.circle"
        case .warn: "exclamationmark.triangle.fill"
        case .error: "exclamationmark.octagon.fill"
        case .fatal: "xmark.octagon.fill"
        }
    }

    /// Error and Fatal are red, icon and word, like Error status. Warn's
    /// triangle is yellow, but its word stays primary: yellow text is
    /// unreadable on a light background (orange is the findings color).
    private static func iconStyle(_ level: SeverityLevel) -> Color {
        switch level {
        case .error, .fatal: StatusColors.error
        case .warn: StatusColors.warning
        default: .secondary
        }
    }

    private static func wordStyle(_ level: SeverityLevel) -> Color {
        switch level {
        case .error, .fatal: StatusColors.error
        case .warn: .primary
        default: .secondary
        }
    }
}

extension AppModel {
    /// Copy Body (docs/GLOSSARY.md): the log's body as stored, not re-indented.
    func copyBody(_ body: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(body, forType: .string)
    }
}
