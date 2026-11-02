import MagnifeKit
import SwiftUI

/// The lower pane of the detail column: the Span | Trace Logs picker at
/// its top (docs/ux.md, Window), then the tab.
struct SpanDetailPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            SpanDetailTabBar()
            Divider()
            switch model.spanDetailTab {
            case .span: SpanTab()
            case .traceLogs: TraceLogsView()
            }
        }
    }
}

/// The picker and, on Trace Logs, the pane header "24 logs".
struct SpanDetailTabBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: Space.sm) {
            Picker("Span Detail", selection: Binding(get: { model.spanDetailTab },
                                                     set: { model.showSpanDetailTab($0) })) {
                ForEach(SpanDetailTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Span (⌥⌘1) or Trace Logs (⌥⌘2)")
            .gridProbe("span-detail-picker", area: "span-detail-tabs")
            Spacer(minLength: Space.sm)
            if model.spanDetailTab == .traceLogs, !model.traceLogs.isEmpty {
                Text(TraceLogs.countTitle(model.traceLogs.lines.count))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .gridArea("span-detail-tabs", inset: Space.lg)
    }
}

/// The Span tab (S-006, S-007, S-011): the selected span's name, kind,
/// duration and status, then its sections in the order of design decision
/// 5. Empty sections are left out.
struct SpanTab: View {
    @Environment(AppModel.self) private var model
    /// Return in the waterfall moves the focus here; Esc moves it back (S-022).
    @FocusState private var focused: Bool

    var body: some View {
        if let detail = model.spanDetail {
            ScrollViewReader { proxy in
                ScrollView {
                    SpanDetailContent(detail: detail)
                }
                // Another span starts at the top, so an Error span opens on Exception (S-007).
                .id(SpanDetailValueID.span(detail))
                .scrollBounceBehavior(.basedOnSize)
                .onChange(of: model.spanDetailScrollTarget) { _, target in
                    guard let target else { return }
                    proxy.scrollTo(target, anchor: model.spanDetailScrollAnchor)
                    model.spanDetailScrollTarget = nil
                }
            }
            .focusable()
            .focused($focused)
            // The request may come before the span's detail shows (Return right after a move).
            .onAppear { if model.takeFocusRequest(.spanDetail) { focused = true } }
            .onChange(of: model.focusRequest) { if model.takeFocusRequest(.spanDetail) { focused = true } }
            .onChange(of: focused) { _, isFocused in model.spanDetailHasFocus = isFocused }
            .onKeyPress(.escape) {
                model.leaveSpanDetail()
                return .handled
            }
            .onKeyPress(keys: [.tab, Self.backTab]) { press in
                guard press.modifiers.held.isSubset(of: .shift) else { return .ignored }
                model.focusNextColumn(from: .spanDetail, backward: press.modifiers.contains(.shift) || press.key == Self.backTab)
                return .handled
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
        case .logs:
            SpanLogList(detail: detail)
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
