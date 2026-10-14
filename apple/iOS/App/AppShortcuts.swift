import AppIntents

/// Siri phrases and Shortcuts tiles (no setup: they work as soon as the app is installed).
struct SamRabbitShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        // A live voice conversation, like the R1. The Action Button's Shortcut picker lists it too.
        AppShortcut(intent: TalkToSamRabbitIntent(), phrases: [
            "Talk to \(.applicationName)",
            "Chat with \(.applicationName)",
            "Start a conversation with \(.applicationName)",
            "\(.applicationName) voice",
        ], shortTitle: "Talk", systemImageName: "waveform")
        // A one-shot voice note: the recorder, recording at once; the Mac files it. The Action Button's Shortcut
        // picker and Back Tap (Settings > Accessibility > Touch) list it too.
        AppShortcut(intent: VoiceNoteIntent(), phrases: [
            "\(.applicationName) note",
            "Take a note with \(.applicationName)",
            "Voice note in \(.applicationName)",
            "Record a \(.applicationName) note",
        ], shortTitle: "Voice Note", systemImageName: "waveform.badge.mic")
        AppShortcut(intent: AskSamRabbitIntent(), phrases: [
            "Ask \(.applicationName)",
            "Ask \(.applicationName) to do something",
            "New \(.applicationName) task",
        ], shortTitle: "Ask SamRabbit", systemImageName: "sparkles")
        // The Action Button's Shortcut picker lists these too: this one opens Ask with dictation listening.
        AppShortcut(intent: OpenAskIntent(), phrases: [
            "Dictate to \(.applicationName)",
            "Ask \(.applicationName) by voice",
        ], shortTitle: "Ask by Voice", systemImageName: "mic.fill")
        AppShortcut(intent: BlockTimeIntent(), phrases: [
            "Block \(\.$duration) with \(.applicationName)",
            "Block time with \(.applicationName)",
            "Focus with \(.applicationName)",
        ], shortTitle: "Block Time", systemImageName: "calendar.badge.clock")
        AppShortcut(intent: WhatNeedsMeIntent(), phrases: [
            "What needs me in \(.applicationName)",
            "What does \(.applicationName) need",
            "Check \(.applicationName)",
        ], shortTitle: "What Needs Me", systemImageName: "hand.raised")
        AppShortcut(intent: AddJournalNoteIntent(), phrases: [
            "Add a journal note with \(.applicationName)",
            "Journal with \(.applicationName)",
        ], shortTitle: "Journal Note", systemImageName: "book.closed")
        AppShortcut(intent: OpenOnMacIntent(), phrases: [
            "Open an app on my Mac with \(.applicationName)",
            "\(.applicationName) open on Mac",
        ], shortTitle: "Open on Mac", systemImageName: "macbook")
        AppShortcut(intent: ScreenshotMacIntent(), phrases: [
            "Screenshot my Mac with \(.applicationName)",
            "Show my Mac screen in \(.applicationName)",
        ], shortTitle: "Screenshot Mac", systemImageName: "camera.viewfinder")
    }

    static let shortcutTileColor: ShortcutTileColor = .navy
}
