import SwiftUI

/// The menu bar extra's voice items: "Talk to SamRabbit" (⌃⌥Space) or "End Conversation" while one is open, and the
/// "Hey Rabbit" switch (with why it can't listen, when it can't).
struct VoiceMenuItems: View {
    @ObservedObject var voice = MacVoice.shared

    var body: some View {
        if voice.state == .idle || voice.isShowingError {
            Button("Talk to SamRabbit  \(voice.shortcutDescription)") { voice.start(reason: "button") }
        } else {
            Button("End Conversation  \(voice.shortcutDescription)") { voice.end() }
        }
        Toggle("Listen for “Hey Rabbit”", isOn: $voice.wakeEnabled)
        if voice.wakeEnabled, let problem = voice.wakeProblem {
            Text(problem)
        }
    }
}

extension MacVoice {
    /// The last conversation's problem is on screen (no conversation is open).
    var isShowingError: Bool {
        if case .error = state { return true }
        return false
    }
}
