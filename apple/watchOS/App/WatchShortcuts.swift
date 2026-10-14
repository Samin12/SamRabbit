import AppIntents

/// Siri on the watch ("Ask SamRabbit", "Talk to SamRabbit"): opens SamRabbit on the watch straight into a live
/// conversation, like the Action Button's control; "SamRabbit note": a voice note.
struct SamRabbitWatchShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenSamRabbitWatchIntent(), phrases: [
            "Ask \(.applicationName)",
            "Talk to \(.applicationName)",
        ], shortTitle: "Ask SamRabbit", systemImageName: "mic.fill")
        // A voice note: records at once, sends itself when he pauses, says nothing back.
        AppShortcut(intent: OpenSamRabbitWatchIntent(.note), phrases: [
            "\(.applicationName) note",
            "Take a note with \(.applicationName)",
        ], shortTitle: "Voice Note", systemImageName: "waveform.badge.mic")
    }

    static let shortcutTileColor: ShortcutTileColor = .navy
}
