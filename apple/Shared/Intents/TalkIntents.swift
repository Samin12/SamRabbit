import AppIntents
import Foundation
import SamRabbitKit

// The intents of the iPhone's live conversation with SamRabbit ("Talk"), compiled into the app and the widget
// extension like the others (a control and a Live Activity button can only run an intent both have).

/// "Talk to SamRabbit": opens SamRabbit straight into a live voice conversation, like talking to the R1. Siri and
/// Shortcuts run it, and so do the Action Button (as this shortcut, or the "Talk to SamRabbit" control), Control
/// Center and the Lock Screen. Pressed again while talking it acts like a tap on the orb (send now, or interrupt).
///
/// It brings the app to the front before `perform` runs (`supportedModes`), which leaves the route for it
/// (`PendingRoute.talk`); the conversation keeps going once the app is in the background or the screen locks.
struct TalkToSamRabbitIntent: AppIntent {
    static let title: LocalizedStringResource = "Talk to SamRabbit"
    static let description = IntentDescription("Opens SamRabbit in a live voice conversation, like talking to your R1. It listens, answers out loud and keeps listening until you end it.",
                                               categoryName: "Voice")
    static let supportedModes: IntentModes = .foreground(.immediate)

    @MainActor
    func perform() async throws -> some IntentResult {
        PendingRoute.open(PendingRoute.talk)
        return .result()
    }
}

/// End, on the conversation's Live Activity (the Lock Screen and the Dynamic Island). A `LiveActivityIntent` runs in
/// the app, which is running anyway while it talks.
struct EndTalkIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "End the Conversation"
    static let description = IntentDescription("Ends the conversation with SamRabbit.", categoryName: "Voice")
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        TalkRemote.end()
        return .result()
    }
}

/// How the Talk intents reach the conversation: the app sets `onEnd` at launch. Where nothing talks (the widget
/// extension, should the system run the intent there) a Darwin notification tells the app instead.
@MainActor
enum TalkRemote {
    static var onEnd: (@MainActor () -> Void)?
    static let endNotification = "com.samrabbit.mobile.talk.end"

    static func end() {
        if let onEnd {
            onEnd()
            return
        }
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(endNotification as CFString), nil, nil, true)
    }

    /// The app: ends the conversation when the notification comes from another process.
    static func listen() {
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { TalkRemote.onEnd?() } }
        }, endNotification as CFString, nil, .deliverImmediately)
    }
}
