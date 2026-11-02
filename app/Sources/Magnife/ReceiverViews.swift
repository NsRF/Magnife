import MagnifeKit
import SwiftUI

/// The receiver's state in the toolbar, in the glossary's words (S-001, S-002).
/// Nothing shows while a start is still quick.
struct ReceiverStatusView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let text = model.receiverStatusText {
            Label(text, systemImage: symbol)
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.secondary)
                .help(model.receiverTooltip)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(text)
                .accessibilityHint(model.receiverTooltip)
        }
    }

    private var symbol: String {
        let receiver = model.receiver
        if receiver == .starting { return "hourglass" }
        return receiver.isReceiving && receiver.busyPorts.isEmpty ? "dot.radiowaves.left.and.right" : "exclamationmark.triangle"
    }
}

/// Inline notices above the list: busy ports (S-001, S-002), a restarted
/// receiver (S-008), and the helper's problems.
struct Banners: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if let text = model.receiver.busyBanner {
                Banner(text: text, symbol: "exclamationmark.triangle.fill") {
                    Button("Try Again") { model.retryPorts() }
                }
            }
            if model.receiverRestarted {
                Banner(text: "The receiver stopped and was restarted. Spans sent in the last few seconds may be missing.",
                       symbol: "arrow.clockwise.circle.fill") {
                    CloseButton { model.receiverRestarted = false }
                }
            }
            if let problem = model.helperProblem {
                Banner(text: problem, symbol: "exclamationmark.triangle.fill") {
                    Button("Try Again") { model.retryPorts() }
                }
            }
            if let message = model.helperMessage {
                Banner(text: message, symbol: "exclamationmark.triangle.fill") {
                    CloseButton { model.helperMessage = nil }
                }
            }
        }
    }
}

private struct CloseButton: View {
    let action: () -> Void

    var body: some View {
        Button("Close", systemImage: "xmark", action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
    }
}

/// One notice: an icon with its text (never color alone) and an action.
struct Banner<Action: View>: View {
    let text: String
    let symbol: String
    @ViewBuilder let action: Action

    var body: some View {
        HStack(spacing: Space.sm) {
            Label(text, systemImage: symbol)
                .symbolRenderingMode(.multicolor)
                .gridProbe("banner-text", area: "banner")
            Spacer(minLength: Space.sm)
            action
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .gridArea("banner", inset: Space.md)
        .accessibilityElement(children: .contain)
    }
}
