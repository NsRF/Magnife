import MagnifeKit
import SwiftUI

/// The S-003 language tabs, the variables, and Copy Environment Variables.
/// The empty trace list shows them, and so does the toolbar popover, so the
/// setup stays reachable after the first trace.
struct EnvironmentSetup: View {
    @Environment(AppModel.self) private var model
    /// The empty state says "Waiting for the first trace…" after a copy.
    var showsWaiting = false

    var body: some View {
        @Bindable var model = model
        VStack(spacing: Space.md) {
            Picker("Language", selection: $model.environmentLanguage) {
                ForEach(EnvironmentLanguage.allCases) { language in
                    Text(language.title).tag(language)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            VStack(alignment: .leading, spacing: Space.sm) {
                EnvironmentCode(text: model.environmentText)
                Text(model.environmentLanguage.note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
            }
            Button {
                model.copyEnvironmentVariables()
            } label: {
                // The hidden title keeps the width while the button reads "Copied".
                ZStack {
                    Text("Copy Environment Variables").hidden()
                    Text(model.environmentCopied ? "Copied" : "Copy Environment Variables")
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel(model.environmentCopied ? "Copied" : "Copy Environment Variables")
            if showsWaiting && model.waitingForFirstTrace {
                Text("Waiting for the first trace…")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The variables as selectable monospaced text. Long lines scroll sideways
/// instead of truncating (S-003).
struct EnvironmentCode: View {
    let text: String

    var body: some View {
        // The whole text when it fits; a sideways scroll only when it does not.
        ViewThatFits(in: .horizontal) {
            code
            ScrollView(.horizontal) { code }
                .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var code: some View {
        Text(text)
            .font(.body.monospaced())
            .textSelection(.enabled)
            .fixedSize()
            .padding(Space.md)
    }
}

/// The toolbar's Copy Environment Variables button and its popover.
struct EnvironmentToolbarButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Button("Copy Environment Variables", systemImage: "terminal") {
            model.showsEnvironmentPopover.toggle()
        }
        .help("Show the environment variables that point an app at Magnife")
        .popover(isPresented: $model.showsEnvironmentPopover, arrowEdge: .bottom) {
            EnvironmentSetup()
                .padding(Space.xl)
                .frame(width: EnvironmentToolbarButton.popoverWidth)
                .noInitialFocus()
        }
    }

    /// Wide enough for the longest line (Python's) without scrolling.
    static let popoverWidth: CGFloat = 520
}
