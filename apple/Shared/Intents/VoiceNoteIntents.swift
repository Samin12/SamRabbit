import AppIntents
import Foundation
import SamRabbitKit

// The intents of voice notes and the morning brief, compiled into the app and the widget extension like the others
// (a control, a widget button and a Live Activity button can only run an intent both have).

/// "Voice note": opens SamRabbit straight into the voice-note recorder, already recording. Say it and stop (or just
/// pause): it goes to your Mac, which puts it where it belongs (the journal only when you say so, a T3 task, the
/// calendar, else a saved note). Nothing is said back. Siri and Shortcuts run it, and so do the Action Button (the
/// "Voice Note" control or shortcut), Control Center, the Lock Screen widget and the widgets' Voice note buttons.
/// Pressed again while recording it stops and sends.
///
/// It brings the app to the front before `perform` runs (`supportedModes`): a third-party app can't start recording
/// in the background on iOS 26, and the microphone starts only for the app's own route (`PendingRoute.capture`).
struct VoiceNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Voice Note"
    static let description = IntentDescription("Records a quick voice note and sends it to your Mac, which files it: your journal when you ask for it, a T3 task, your calendar, or a saved note.",
                                               categoryName: "Voice")
    static let supportedModes: IntentModes = .foreground(.immediate)

    @MainActor
    func perform() async throws -> some IntentResult {
        PendingRoute.open(PendingRoute.capture)
        return .result()
    }
}

/// Stop, on the voice note's Live Activity (the Lock Screen and the Dynamic Island): stops recording and sends it.
/// A `LiveActivityIntent` runs in the app, which is running anyway while it records.
struct StopVoiceNoteIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop the Voice Note"
    static let description = IntentDescription("Stops recording the voice note and sends it.", categoryName: "Voice")
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        CaptureRemote.stop()
        return .result()
    }
}

/// How the voice-note intents reach the recorder: the app sets `onStop` at launch. Where nothing records (the
/// widget extension, should the system run the intent there) a Darwin notification tells the app instead.
@MainActor
enum CaptureRemote {
    static var onStop: (@MainActor () -> Void)?
    static let stopNotification = "com.samrabbit.mobile.capture.stop"

    static func stop() {
        if let onStop {
            onStop()
            return
        }
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(stopNotification as CFString), nil, nil, true)
    }

    /// The app: stops the recording when the notification comes from another process.
    static func listen() {
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { CaptureRemote.onStop?() } }
        }, stopNotification as CFString, nil, .deliverImmediately)
    }
}

/// What the morning brief's widget buttons do.
enum BriefingWidgetAction: String, AppEnum {
    case done, dismiss

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Brief action"
    static let caseDisplayRepresentations: [BriefingWidgetAction: DisplayRepresentation] = [
        .done: "Done",
        .dismiss: "Dismiss",
    ]
}

/// Done / Dismiss on a morning-brief item, from the widget (runs in the background, never opens the app): tells the
/// Mac, takes the item off the widgets' copy at once and reloads them.
struct BriefingItemIntent: AppIntent {
    static let title: LocalizedStringResource = "Morning Brief Item"
    static let description = IntentDescription("Marks an item of your morning brief done, or dismisses it.",
                                               categoryName: "Brief")
    static let isDiscoverable = false

    @Parameter(title: "Item")
    var itemId: String

    @Parameter(title: "Action", default: .done)
    var action: BriefingWidgetAction

    init() {}
    init(itemId: String, action: BriefingWidgetAction) {
        self.itemId = itemId
        self.action = action
    }

    func perform() async throws -> some IntentResult {
        do {
            _ = try await SamRabbitActions.shared.briefingAct(itemId, action: action.rawValue,
                                                               state: action == .done ? .done : .dismissed)
        } catch {
            throw SamRabbitIntentError(error)
        }
        return .result()
    }
}
