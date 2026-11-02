import MagnifeKit
import SwiftUI

/// The toolbar's Pause / Resume over the list (S-010): icon only, with the
/// word for VoiceOver and the shortcut in its tooltip.
struct PauseButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.togglePause()
        } label: {
            Label(TraceList.pauseTitle(isPaused: model.isPaused),
                  systemImage: model.isPaused ? "play.fill" : "pause.fill")
        }
        .labelStyle(.iconOnly)
        .help(TraceList.pauseHelp(isPaused: model.isPaused))
    }
}

/// "Paused. 12 new traces. Magnife is still receiving." pinned to the top
/// of a paused list, with Resume: next to where it matters, never an alert.
struct PauseBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.isPaused {
            Banner(text: TraceList.pausedText(newCount: model.newTraceCount), symbol: "pause.circle") {
                Button("Resume") { model.resume() }
                    .help(TraceList.pauseHelp(isPaused: true))
            }
        }
    }
}
