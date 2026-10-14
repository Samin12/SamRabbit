import Foundation

/// What the iPhone's live conversation with SamRabbit ("Talk") is doing, in a word: the Talk screen's state line,
/// the bar over the tab bar while Talk is minimized, and the Live Activity on the Lock Screen and in the Dynamic
/// Island. Platform-neutral (the Live Activity's attributes are iOS only), so `swift test` covers it.
public enum TalkPhase: String, Codable, Sendable, Equatable, CaseIterable {
    case starting, listening, hearing, thinking, speaking, announcing, muted, ended

    /// `announcing`: what plays is an announcement (a task finished or needs you), not a reply.
    public init(_ phase: ConversationMachine.Phase, muted: Bool, announcing: Bool = false) {
        switch phase {
        case .idle: self = .ended
        case .starting: self = .starting
        case .listening, .hearing: self = muted ? .muted : phase == .hearing ? .hearing : .listening
        case .thinking: self = .thinking
        case .speaking: self = announcing ? .announcing : .speaking
        }
    }

    /// "Listening…", "Speaking…", …
    public var word: String {
        switch self {
        case .starting: "Starting…"
        case .listening: "Listening…"
        case .hearing: "Hearing you…"
        case .thinking: "Thinking…"
        case .speaking: "Speaking…"
        case .announcing: "Heads up"
        case .muted: "Muted"
        case .ended: "Ended"
        }
    }

    /// One short word (the Dynamic Island's compact side).
    public var short: String {
        switch self {
        case .starting, .listening, .hearing: "Listening"
        case .thinking: "Thinking"
        case .speaking: "Speaking"
        case .announcing: "Heads up"
        case .muted: "Muted"
        case .ended: "Ended"
        }
    }

    /// An SF Symbol for it.
    public var symbol: String {
        switch self {
        case .starting, .listening, .hearing: "waveform"
        case .thinking: "ellipsis"
        case .speaking: "speaker.wave.2.fill"
        case .announcing: "bell.fill"
        case .muted: "mic.slash.fill"
        case .ended: "checkmark"
        }
    }

    /// The microphone hears (the orb follows the voice).
    public var listens: Bool { self == .listening || self == .hearing }
}

/// The Live Activity's state while Talk runs: the phase and one line (what SamRabbit is saying or said last, else
/// what it heard, quoted).
public struct TalkActivityState: Codable, Hashable, Sendable {
    public var phase: TalkPhase
    public var line: String

    /// The longest line shown (the Lock Screen has two lines, the Dynamic Island one or two).
    public static let maxLine = 140
    /// A line that changes while the phase stays (a reply streaming in) updates the activity at most this often.
    public static let lineInterval: TimeInterval = 1.5

    public init(phase: TalkPhase, line: String = "") {
        self.phase = phase
        self.line = Formatting.clip(line, Self.maxLine)
    }

    /// From the conversation as it is now.
    public init(_ machine: ConversationMachine, muted: Bool) {
        let shown = machine.live ?? machine.exchanges.last
        let phase = TalkPhase(machine.phase, muted: muted, announcing: machine.live?.kind == .announcement)
        var line = ""
        if let shown {
            if !shown.say.isEmpty {
                line = shown.say
            } else if !shown.heard.isEmpty {
                line = "“\(Formatting.clip(shown.heard, Self.maxLine - 2))”"
            }
        }
        self.init(phase: phase, line: line)
    }

    /// Whether the Live Activity should change from `shown` (updated at `shownAt`) to this state now: a new phase
    /// at once, a new line at most every `lineInterval` (the caller tries again later), nothing new never.
    public func update(from shown: TalkActivityState?, shownAt: Date?, now: Date) -> Bool {
        guard let shown else { return true }
        if shown.phase != phase { return true }
        guard shown.line != line else { return false }
        guard let shownAt else { return true }
        return now.timeIntervalSince(shownAt) >= Self.lineInterval
    }
}

#if os(iOS) && canImport(ActivityKit)
import ActivityKit

/// The "Talking with SamRabbit" Live Activity: while a conversation runs on the iPhone, the Lock Screen and the
/// Dynamic Island show what it is doing and its last line, with End (the conversation keeps going with the screen
/// locked). The app starts it with the conversation, updates it as the phase changes and ends it with it.
public struct TalkActivityAttributes: ActivityAttributes {
    public typealias ContentState = TalkActivityState

    public var startedAt: Date

    public init(startedAt: Date = .now) {
        self.startedAt = startedAt
    }
}
#endif
