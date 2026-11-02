import MagnifeKit
import SwiftUI

/// The Exception section (S-007): one block per exception event, in time
/// order. Type in bold, the message under it, then the stack trace in
/// monospace with Copy Stack Trace. A missing stack trace shows type and
/// message only.
struct ExceptionList: View {
    let detail: SpanDetail

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            ForEach(Array(detail.exceptions.enumerated()), id: \.offset) { index, exception in
                ExceptionBlock(exception: exception, index: index, time: detail.offsetText(exception.timeNs))
            }
        }
    }
}

struct ExceptionBlock: View {
    @Environment(AppModel.self) private var model
    let exception: SpanException
    let index: Int
    /// "at 23 ms" from the span's start, so several exceptions read in order.
    let time: String

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(exception.type.isEmpty ? "Exception" : exception.type)
                    .fontWeight(.bold)
                    .textSelection(.enabled)
                    .typesettingLanguage(ExpandableText.noLanguage)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !exception.message.isEmpty {
                    ExpandableText(text: exception.message, id: SpanDetailValueID.exceptionMessage(index))
                }
            }
            if exception.hasStackTrace {
                StackTraceBlock(exception: exception, index: index, time: time)
            } else {
                timeText
            }
            if !exception.attributes.isEmpty {
                AttributeList(attributes: exception.attributes) { SpanDetailValueID.exceptionAttribute(index, $0) }
            }
        }
    }

    private var timeText: some View {
        ExceptionTime(time: time)
    }
}

/// "at 23 ms", at the end of the block's last row.
struct ExceptionTime: View {
    let time: String

    var body: some View {
        Text(time)
            .font(.callout)
            .foregroundStyle(.secondary)
            .monospacedDigit()
    }
}

/// The stack trace as selectable monospaced text that scrolls sideways
/// rather than wrapping. Over 20 lines it shows the first 20 with "Show
/// All". Copy Stack Trace always copies the whole stack trace.
struct StackTraceBlock: View {
    @Environment(AppModel.self) private var model
    let exception: SpanException
    let index: Int
    let time: String

    private var id: String { SpanDetailValueID.stackTrace(index) }
    private var isExpanded: Bool { model.expandedValues.contains(id) }
    private var preview: String? { exception.stackTracePreview() }
    private var isCopied: Bool { model.copiedStackTrace == index }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            ScrollView(.horizontal) {
                Text(isExpanded ? exception.stackTrace : preview ?? exception.stackTrace)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .fixedSize()
                    .padding(Space.md)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(exception.stackTraceAccessibilityLabel)
            .accessibilityValue(exception.stackTrace)
            HStack(spacing: Space.md) {
                Button {
                    model.copyStackTrace(at: index)
                } label: {
                    // The hidden title keeps the width while the button reads "Copied".
                    ZStack {
                        Text("Copy Stack Trace").hidden()
                        Text(isCopied ? "Copied" : "Copy Stack Trace")
                    }
                }
                .accessibilityLabel(isCopied ? "Copied" : "Copy Stack Trace")
                if preview != nil {
                    Button(isExpanded ? "Show Less" : "Show All") { model.toggleExpanded(id) }
                        .buttonStyle(.link)
                }
                Spacer(minLength: 0)
                ExceptionTime(time: time)
            }
            .controlSize(.small)
        }
    }
}
