import MagnifeKit
import SwiftUI

/// Keys and values, one pair per row (S-006). Keys sit in a column that
/// takes at most about a third of the pane and truncate in the middle
/// with the full key as a tooltip; values wrap and collapse after three
/// lines with "Show All". Both are selectable text.
struct AttributeList: View {
    let attributes: [Attribute]
    /// The expandable id of a value, by key.
    let id: (String) -> String
    @State private var width: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            ForEach(attributes) { attribute in
                HStack(alignment: .firstTextBaseline, spacing: Space.md) {
                    Text(attribute.key)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .frame(width: keyWidth, alignment: .leading)
                        .help(attribute.key)
                    ExpandableText(text: attribute.value.text, id: id(attribute.key))
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(SpanDetail.accessibilityLabel(attribute))
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    /// 38% of the row, between 120 and 240 pt, on the 4 pt grid.
    private var keyWidth: CGFloat {
        let share = (width * 0.38 / Space.xs).rounded(.down) * Space.xs
        return min(max(share, 120), 240)
    }
}

/// A span's events in time order, each with its time from the span's
/// start and its attributes under it.
struct EventList: View {
    let detail: SpanDetail

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            ForEach(Array(detail.events.enumerated()), id: \.offset) { index, event in
                VStack(alignment: .leading, spacing: Space.xs) {
                    HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                        Text(event.name.isEmpty ? "Event" : event.name)
                            .fontWeight(.semibold)
                            .textSelection(.enabled)
                        Text(detail.offsetText(event.timeNs))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .font(.callout)
                    .accessibilityElement(children: .combine)
                    if !event.attributes.isEmpty {
                        AttributeList(attributes: event.attributes.pairs) { SpanDetailValueID.event(index, $0) }
                            .padding(.leading, Space.lg)
                    }
                }
            }
        }
    }
}

/// Text that wraps, and past `lineLimit` lines collapses with "Show All"
/// (then "Show Less"). Nothing is cut silently: the button shows whenever
/// the full text is taller than what shows. Expanded state lives in
/// AppModel, so the self-test and snapshots can open a value too.
struct ExpandableText: View {
    @Environment(AppModel.self) private var model
    let text: String
    let id: String
    var lineLimit = 3
    @State private var fullHeight: CGFloat = 0
    @State private var shownHeight: CGFloat = 0

    private var isExpanded: Bool { model.expandedValues.contains(id) }
    private var isTruncated: Bool { ValueLayout(full: fullHeight, shown: shownHeight).isTruncated }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(text)
                .lineLimit(isExpanded ? nil : lineLimit)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    shownHeight = $0
                    report()
                }
                .background(alignment: .topLeading) {
                    // The whole text at the same width, never drawn: its height says whether the shown text is cut.
                    Text(text)
                        .fixedSize(horizontal: false, vertical: true)
                        .hidden()
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                            fullHeight = $0
                            report()
                        }
                }
            if isExpanded || isTruncated {
                Button(isExpanded ? "Show Less" : "Show All") { model.toggleExpanded(id) }
                    .buttonStyle(.link)
                    .controlSize(.small)
            }
        }
        // Values are code, not prose: break long identifiers without
        // hyphens, which would show a "-" that is not in the value.
        .typesettingLanguage(Self.noLanguage)
    }

    /// "zxx", no linguistic content: SwiftUI then never hyphenates.
    static let noLanguage = Locale.Language(identifier: "zxx")

    private func report() {
        model.valueLayouts[id] = ValueLayout(full: fullHeight, shown: shownHeight)
    }
}
