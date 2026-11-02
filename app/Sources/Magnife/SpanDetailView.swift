import MagnifeKit
import SwiftUI

/// The lower pane of the detail column (S-006, S-007): the selected span's name,
/// kind, duration and status, then its sections in the order of design
/// decision 5. Empty sections are left out.
struct SpanDetailPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let detail = model.spanDetail {
            ScrollViewReader { proxy in
                ScrollView {
                    SpanDetailContent(detail: detail)
                }
                .scrollBounceBehavior(.basedOnSize)
                .onChange(of: model.spanDetailScrollTarget) { _, target in
                    guard let target else { return }
                    proxy.scrollTo(target, anchor: model.spanDetailScrollAnchor)
                    model.spanDetailScrollTarget = nil
                }
            }
            .accessibilityLabel("Span Detail")
        } else if model.showsNoSpanSelected {
            ContentUnavailableView {
            } description: {
                Text("Select a span to see its attributes.")
            }
        } else {
            // The span is still being read: nothing yet, rather than a flash of text.
            Color.clear
        }
    }
}

struct SpanDetailContent: View {
    let detail: SpanDetail

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            SpanDetailHeader(detail: detail)
                .gridProbe("span-header", area: "span-detail")
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
                .gridProbe("section-\(section.rawValue)", area: "span-detail")
                .id(section)
            }
        }
        .padding(Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .gridArea("span-detail", inset: Space.lg)
    }

    @ViewBuilder
    private func sectionBody(_ section: SpanDetail.Section) -> some View {
        switch section {
        case .exception:
            ExceptionList(detail: detail)
        case .attributes:
            AttributeList(attributes: detail.attributes, id: SpanDetailValueID.attribute)
        case .events:
            EventList(detail: detail)
        case .resource:
            AttributeList(attributes: detail.resourceAttributes, id: SpanDetailValueID.resource)
        }
    }
}

/// "POST /payments", then "Server · 52 ms · Error" (the octagon with the
/// word), then the status message when the span sent one.
struct SpanDetailHeader: View {
    let detail: SpanDetail

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(detail.span.name)
                .font(.title3.weight(.semibold))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: Space.xs) {
                Text("\(detail.span.kind.title) · \(DurationFormat.string(nanoseconds: detail.span.durationNs)) ·")
                    .foregroundStyle(.secondary)
                status
            }
            .accessibilityElement(children: .combine)
            if !detail.span.statusMessage.isEmpty {
                ExpandableText(text: detail.span.statusMessage, id: SpanDetailValueID.statusMessage)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private var status: some View {
        if detail.span.status == .error {
            // Error pairs the octagon with the word, never red alone.
            Label(detail.span.status.title, systemImage: "exclamationmark.octagon.fill")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.red)
        } else {
            Text(detail.span.status.title)
                .foregroundStyle(.secondary)
        }
    }
}
