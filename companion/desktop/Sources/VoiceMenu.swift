import SwiftUI

/// The menu bar extra's voice items: "Talk to SamRabbit" (⌃⌥Space) or "End Conversation" while one is open, and the
/// "Hey Rabbit" switch (with why it can't listen, when it can't; "Unmute" when a mute left it waiting). When another
/// app has the shortcut, the menu says so instead of showing it.
struct VoiceMenuItems: View {
    @ObservedObject var voice = MacVoice.shared

    var body: some View {
        let shortcut = voice.shortcutDescription.isEmpty ? "" : "  \(voice.shortcutDescription)"
        if voice.state == .idle || voice.isShowingError {
            Button("Talk to SamRabbit" + shortcut) { voice.start(reason: "button") }
        } else {
            Button("End Conversation" + shortcut) { voice.end() }
        }
        if let problem = voice.shortcutProblem {
            Text("Shortcut unavailable: \(problem)")
        }
        Toggle("Listen for “Hey Rabbit”", isOn: $voice.wakeEnabled)
        if voice.wakeEnabled, let problem = voice.wakeProblem {
            Text(problem)
        }
        if voice.micMuted, voice.state == .idle || voice.isShowingError {
            Button("Unmute the Microphone") { voice.micMuted = false }
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
