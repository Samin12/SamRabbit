import AppIntents
import AVFoundation
import Foundation
import SamRabbitKit

/// An experiment (CONTRACTS-WAVE8 §C2, w8-capture.md §3.1), off unless Settings > Action Button > "Record without
/// opening SamRabbit" is on: a voice note that tries to record with SamRabbit staying in the background, like Voice
/// Memos. Apple's forums say iOS 26 blocks third-party apps from starting a recording in the background (DTS,
/// thread 816408; "Target is not foreground", 561015905 from `setActive`), so whenever anything refuses (the flag
/// is off, the Live Activity, the microphone permission not granted yet, the audio session) it continues in the
/// foreground and runs the normal recorder. Pick it in Shortcuts ("Voice Note Without Opening") to try it, e.g. as
/// the Action Button's shortcut. Compiled into the app only: an `AudioRecordingIntent` must run in the app's process.
struct VoiceNoteBackgroundIntent: AudioRecordingIntent {
    static let title: LocalizedStringResource = "Voice Note Without Opening (Experimental)"
    static let description = IntentDescription("Tries to record a voice note while SamRabbit stays in the background (a Live Activity shows it, with Stop). If iOS doesn't allow that, SamRabbit opens and records as usual.",
                                               categoryName: "Voice")
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    @MainActor
    func perform() async throws -> some IntentResult {
        if BackgroundNote.enabled, systemContext.currentMode == .background, let start = BackgroundNote.start,
           await start() {
            return .result()
        }
        try await continueInForeground(nil, alwaysConfirm: false)
        PendingRoute.open(PendingRoute.capture)
        return .result()
    }
}

/// The experiment's switch and the app's hook into the recorder.
@MainActor
enum BackgroundNote {
    static let key = "voiceNoteBackground"

    static var enabled: Bool { UserDefaults.standard.bool(forKey: key) }

    /// Starts recording without the recorder on screen; false when anything refused (then it runs in front).
    static var start: (@MainActor () async -> Bool)?

    /// The microphone was allowed already (the permission can never be asked from the background).
    static var microphoneAllowed: Bool { AVAudioApplication.shared.recordPermission == .granted }
}
