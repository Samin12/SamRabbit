import AppIntents
import Foundation
import SamRabbitKit

// The watch's App Intents, compiled into the watch app and its widget extension (the system needs
// both before a control can open the app). They run on the watch: the iPhone's "Ask SamRabbit"
// control opens the iPhone app, so watchOS doesn't offer it on the watch.

/// Where `OpenSamRabbitWatchIntent` opens the watch app.
enum WatchDestination: String, AppEnum {
    case ask, note, brief, needs, working, upnext, quick

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "SamRabbit page"
    static let caseDisplayRepresentations: [WatchDestination: DisplayRepresentation] = [
        .ask: DisplayRepresentation(title: "Talk", synonyms: ["ask", "voice", "assistant", "conversation"]),
        .note: DisplayRepresentation(title: "Voice Note", synonyms: ["note", "capture", "record"]),
        .brief: DisplayRepresentation(title: "Morning Brief", synonyms: ["brief", "briefing", "morning"]),
        .needs: DisplayRepresentation(title: "Needs You", synonyms: ["approvals"]),
        .working: "Working",
        .upnext: DisplayRepresentation(title: "Up Next", synonyms: ["calendar"]),
        .quick: DisplayRepresentation(title: "Quick Actions", synonyms: ["quick"]),
    ]

    /// The route the watch app follows: Talk opens the conversation, already listening; Voice Note the recorder,
    /// recording (it sends itself when he pauses).
    var route: String {
        switch self {
        case .ask: PendingRoute.askListening
        case .note: PendingRoute.capture
        case .brief, .needs, .working, .upnext, .quick: "samrabbit://tab/\(rawValue)"
        }
    }
}

/// Opens SamRabbit on the watch. With Talk (the default) it opens straight into a live conversation with
/// SamRabbit (pressed again while talking: like a tap on the orb). This is what the Watch Ultra's Action Button
/// runs (the "Ask SamRabbit" control) and what Siri on the watch runs ("Ask SamRabbit", "Talk to SamRabbit").
struct OpenSamRabbitWatchIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open SamRabbit"
    static let description = IntentDescription("Opens SamRabbit on your watch, ready to talk.")

    @Parameter(title: "Page", default: .ask)
    var target: WatchDestination

    init() {}
    init(_ target: WatchDestination) { self.target = target }

    @MainActor
    func perform() async throws -> some IntentResult {
        PendingRoute.set(target.route, in: BridgeAccount.shared.container.defaults)
        return .result()
    }
}
