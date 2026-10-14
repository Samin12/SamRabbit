import Foundation

// What the window's page (web/native.js) and the Swift shell say to each other beyond loading the page
// (CONTRACTS-WAVE7 §B): the page's requests (voice, "Hey Rabbit", the Agent Dock switch, the native windows, a voice
// note: WAVE8 §D1) and the state the shell pushes into `window.SamRabbitApp.native(…)`. Pure (Foundation only), so tests/window can pin it;
// MainWindowBridge.swift wires it to MacVoice, the dock and the web view.

/// One request from the page (`postNative({type, …})`), or nil for what the bridge doesn't handle (the window's own
/// messages: open, copy, noDrag, status, diag, pairPhone).
enum WindowCommand: Equatable {
    enum VoiceAction: String, CaseIterable {
        case start, end, toggle, mute, unmute, stopSpeaking
    }

    enum NoteAction: String, CaseIterable {
        case toggle, send, cancel
    }

    /// The page asks MacVoice: talk, end, mute, unmute, stop speaking.
    case voice(VoiceAction)
    /// Home's "Voice note": start one (it records until the next tap of ⌃⌥N, the dock's ↑, or a pause), send it, or
    /// throw it away. The recording is the shell's (VoiceNotes); the page only asks.
    case note(NoteAction)
    /// "Listen for “Hey Rabbit”" in Settings.
    case wake(Bool)
    /// "Show the Agent Dock" in Settings.
    case dock(Bool)
    /// The page loaded (or reloaded after a bridge restart): it wants the whole state.
    case ready
    case connectChatGPT
    case dockSettings

    static func parse(_ body: [String: Any]) -> WindowCommand? {
        switch body["type"] as? String {
        case "voice":
            guard let raw = body["action"] as? String else { return nil }
            if raw == "wake" {
                guard let on = body["on"] as? Bool else { return nil }
                return .wake(on)
            }
            return VoiceAction(rawValue: raw).map { .voice($0) }
        case "dock":
            guard let on = body["enabled"] as? Bool else { return nil }
            return .dock(on)
        case "note":
            return (body["action"] as? String).flatMap(NoteAction.init(rawValue:)).map { .note($0) }
        case "ready":
            return .ready
        case "connectChatGPT":
            return .connectChatGPT
        case "dockSettings":
            return .dockSettings
        default:
            return nil
        }
    }
}

/// MacVoice's published state as the page reads it (web/voice.js `normalizeVoice`).
struct WindowVoiceState: Equatable {
    /// "idle" | "starting" | "listening" | "thinking" | "speaking" | "error"
    var state = "idle"
    var error: String?
    var heard = ""
    /// The exchange `heard` belongs to: the same words said again are a new line (web/voice.js).
    var heardId: String?
    var caption = ""
    /// 0...1, rounded to a hundredth (the page only moves the orb with it).
    var level = 0.0
    var micMuted = false
    var wakeArmed = false
    var wakeEnabled = true
    var wakeProblem: String?
    var brain: String?
    var conversationId: String?
    var shortcut = ""
    var shortcutProblem: String?

    var json: [String: Any] {
        [
            "state": state, "error": error ?? NSNull(), "heard": heard, "heardId": heardId ?? NSNull(), "caption": caption,
            "level": (min(1, max(0, level)) * 100).rounded() / 100,
            "micMuted": micMuted, "wakeArmed": wakeArmed, "wakeEnabled": wakeEnabled,
            "wakeProblem": wakeProblem ?? NSNull(), "brain": brain ?? NSNull(),
            "conversationId": conversationId ?? NSNull(), "shortcut": shortcut,
            "shortcutProblem": shortcutProblem ?? NSNull(),
        ]
    }

    /// Everything but the level (the level alone moves ~12 times a second while listening or speaking).
    func sameApartFromLevel(_ other: WindowVoiceState) -> Bool {
        var a = self
        var b = other
        a.level = 0
        b.level = 0
        return a == b
    }
}

/// How often the voice state goes to the page: anything but the level at once; a level-only change at most every
/// `levelInterval` (later, with the newest value), and not at all while it moves less than `levelStep`.
struct WindowPushThrottle {
    enum Decision: Equatable {
        case now
        case after(TimeInterval)
        case skip
    }

    var levelInterval: TimeInterval = 1.0 / 12
    var levelStep = 0.02
    private(set) var sent: WindowVoiceState?
    private(set) var sentAt: Date?

    func decide(_ next: WindowVoiceState, now: Date) -> Decision {
        guard let sent, let sentAt else { return .now }
        if !next.sameApartFromLevel(sent) { return .now }
        if abs(next.level - sent.level) < levelStep { return .skip }
        let wait = levelInterval - now.timeIntervalSince(sentAt)
        return wait <= 0 ? .now : .after(wait)
    }

    mutating func pushed(_ state: WindowVoiceState, at now: Date) {
        sent = state
        sentAt = now
    }

    /// The page reloaded: the next state goes at once, whole.
    mutating func reset() {
        sent = nil
        sentAt = nil
    }
}

/// The Agent Dock as the window's Settings shows it. `on` is its switch: the dock is on and not hidden for a while (what
/// it actually does, not only its setting); `turnedOn` is its setting (on but hidden for now: "Hidden for now");
/// `canCustomize`: the dock has a shortcut settings window to open.
struct WindowDockState: Equatable {
    var on: Bool
    var turnedOn: Bool
    var canCustomize = false

    var json: [String: Any] { ["enabled": on, "turnedOn": turnedOn, "canCustomize": canCustomize] }
}

enum WindowScript {
    /// `window.SamRabbitApp.native(<patch>)`, safe to evaluate in the page (JSON, which is valid JavaScript; the
    /// page may still be loading, hence the guard).
    static func native(_ patch: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(patch),
              let data = try? JSONSerialization.data(withJSONObject: patch, options: [.sortedKeys]),
              var text = String(data: data, encoding: .utf8) else { return nil }
        // U+2028 / U+2029 are valid in JSON strings but ended a JavaScript string literal before ES2019.
        text = text.replacingOccurrences(of: "\u{2028}", with: "\\u2028").replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return "window.SamRabbitApp && window.SamRabbitApp.native(\(text))"
    }

    /// One shortcut as Settings lists it: `{id, label, keys, problem}` ("" keys: none works).
    static func shortcut(id: String, label: String, keys: String, problem: String?) -> [String: Any] {
        ["id": id, "label": label, "keys": keys, "problem": problem ?? NSNull()]
    }

    /// The shortcuts Settings lists: talk from MacVoice, the dock's compose key.
    static func shortcuts(talk: String, talkProblem: String?, compose: String = "⌃⌥K") -> [[String: Any]] {
        [
            shortcut(id: "talk", label: "Talk to SamRabbit", keys: talk, problem: talkProblem),
            shortcut(id: "compose", label: "Open the Agent Dock on a new task", keys: compose, problem: nil),
        ]
    }
}
