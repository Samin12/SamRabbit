import Foundation

// Quick voice notes (CONTRACTS-WAVE8 §A2, §C2–3): "tap, talk, it's sent". The iPhone or the watch records a
// short clip and sends it to the Mac bridge (`POST /v1/mobile/capture`), which stores it at once (202
// `received`), turns it into words and routes it: into the journal only on an explicit cue ("put this in my
// journal"), a new T3 task, a calendar event, or else a saved note with a suggestion. Nothing is ever said
// back: the device shows "Sent ✓ — <outcome>". What both ends agree on lives here: the request's headers, the
// answer, the summary's `captures` part and the words each outcome shows.

/// Where a voice note was recorded (`X-SamRabbit-Source`).
public enum CaptureDevice: String, Codable, Sendable, CaseIterable {
    case iphone, watch, mac, r1
}

/// What a voice note is and where it goes: made on the device when the recording starts and sent with it (the
/// idempotency key and the time it was said). The same values travel in the request's headers, the watch's relay
/// through the iPhone (`VoiceRelay`, `WCSession.transferFile`) and the outboxes (`CaptureOutbox`).
public struct CaptureMeta: Codable, Sendable, Equatable {
    /// A UUID (`X-SamRabbit-Capture`): the bridge keeps one capture per id, so sending it again (another address,
    /// through the iPhone, after a crash) never makes a second note.
    public var captureId: String
    /// When the recording started (`X-SamRabbit-Captured-At`, with the device's offset): the journal line's time
    /// and what "tomorrow" means.
    public var capturedAt: Date
    public var source: CaptureDevice
    public var contentType: String
    public var language: String?
    /// The recording's length in seconds (shown in the outbox; the bridge reads the file itself).
    public var seconds: Double

    public init(captureId: String = UUID().uuidString.lowercased(), capturedAt: Date = .now, source: CaptureDevice,
                contentType: String = VoiceFormat.contentType, language: String? = VoiceFormat.languageTag(),
                seconds: Double = 0) {
        self.captureId = captureId
        self.capturedAt = capturedAt
        self.source = source
        self.contentType = contentType
        self.language = language
        self.seconds = seconds
    }

    /// `2026-10-14T09:41:07-04:00`: the device's own offset, so the Mac knows the local time it was said.
    public var capturedAtHeader: String { Self.header(capturedAt) }

    static func header(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// The request's headers (the body is the recording).
    public var headers: [String: String] {
        ["X-SamRabbit-Capture": captureId, "X-SamRabbit-Captured-At": capturedAtHeader,
         "X-SamRabbit-Source": source.rawValue]
    }

    /// A capture id the bridge takes: a UUID (as the relay and the outbox file names use it too).
    public static func isValid(_ id: String) -> Bool {
        UUID(uuidString: id) != nil
    }

    /// The `WCSession.transferFile` metadata key a watch's note travels to the iPhone with (the encoded meta).
    public static let transferKey = "samrabbit.capture"

    /// The metadata of a `transferFile` (property-list values only).
    public var transferMetadata: [String: Any] {
        guard let data = try? JSONEncoder().encode(self) else { return [:] }
        return [Self.transferKey: data]
    }

    /// A note's meta from a `transferFile`'s metadata.
    public init?(transferMetadata: [String: Any]?) {
        guard let data = transferMetadata?[Self.transferKey] as? Data,
              let meta = try? JSONDecoder().decode(CaptureMeta.self, from: data), Self.isValid(meta.captureId) else {
            return nil
        }
        self = meta
    }
}

/// How voice notes are recorded and how long they may be: AAC in an `.m4a`, 16 kHz mono at about 32 kbps (the
/// watch's `VoiceFormat`), at most 180 s on the iPhone (about 720 KB) and 120 s on the watch, ending by
/// themselves after about 2.5 s of quiet once something was said (a note has pauses Ask doesn't).
public enum CaptureFormat {
    public static let iphoneMaxSeconds: TimeInterval = 180
    public static let watchMaxSeconds: TimeInterval = 120
    public static let silenceToStop: TimeInterval = 2.5
    /// The bridge refuses larger mobile bodies (413 `body_too_large`).
    public static let maxBytes = 8 * 1024 * 1024
    /// How long the device waits for the Mac's outcome after the upload (`GET …/capture/<id>?wait=`).
    public static let outcomeWait = 8
}

/// How far the Mac got with a voice note. The contract's words are `received`, `transcribed`, `done` and
/// `failed`; the steps in between (`transcribing`, `routing`, `acting`, `queued`) read as the one before.
public enum CaptureState: String, Codable, Sendable, Equatable {
    /// Stored on the Mac: safe there, words still to come.
    case received
    /// Words heard; routing or doing it.
    case transcribed
    case done
    case failed

    public init(raw: String?) {
        switch (raw ?? "").lowercased() {
        case "transcribed", "routing", "acting", "routed": self = .transcribed
        case "done", "needs_you", "needs-you", "saved", "finished": self = .done
        case "failed", "error", "no_speech", "rejected": self = .failed
        default: self = .received
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(raw: try? decoder.singleValueContainer().decode(String.self))
    }

    /// Nothing more will happen to it on its own.
    public var settled: Bool { self == .done || self == .failed }
}

/// What the Mac did with a voice note (`outcome`).
public struct CaptureOutcome: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, Equatable {
        /// Added to today's journal, in his own words.
        case journal
        /// A new T3 task with his words as the prompt.
        case task
        /// A calendar event or block (a reminder is a short event).
        case event
        /// Saved as a note (with a suggestion, when one fits).
        case note
        /// Nothing was heard in it (the bridge's `nothing`: done, nothing saved).
        case nothing
        /// The Mac couldn't do it (the bridge's `failed`, with `error`).
        case failed
        case unknown

        public init(raw: String?) {
            switch (raw ?? "").lowercased() {
            case "journal", "journal_note": self = .journal
            case "task", "t3", "t3_task", "thread": self = .task
            case "event", "calendar", "calendar_event", "calendar_block", "block", "reminder", "remind": self = .event
            case "note", "saved", "notes": self = .note
            case "nothing", "no_speech", "empty": self = .nothing
            case "failed", "error": self = .failed
            default: self = .unknown
            }
        }

        public init(from decoder: Decoder) throws {
            self.init(raw: try? decoder.singleValueContainer().decode(String.self))
        }
    }

    public var kind: Kind
    public var title: String?
    public var detail: String?
    public var threadId: String?
    public var eventId: String?
    public var noteId: String?

    public init(kind: Kind, title: String? = nil, detail: String? = nil, threadId: String? = nil,
                eventId: String? = nil, noteId: String? = nil) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.threadId = threadId
        self.eventId = eventId
        self.noteId = noteId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        kind = Kind(raw: c.text("kind", "type", "route"))
        title = c.text("title")
        detail = c.text("detail", "say")
        threadId = c.text("threadId")
        eventId = c.text("eventId")
        noteId = c.text("noteId")
    }

    /// "Added to your journal", "Started a T3 task", ...
    public var headline: String {
        switch kind {
        case .journal: "Added to your journal"
        case .task: "Started a T3 task"
        case .event: "On your calendar"
        case .note: "Saved as a note"
        case .nothing: "I didn't catch anything"
        case .failed: "Your Mac couldn't do it"
        case .unknown: "Done"
        }
    }

    public var symbol: String {
        switch kind {
        case .journal: "book.closed.fill"
        case .task: "sparkles"
        case .event: "calendar.badge.checkmark"
        case .note: "note.text"
        case .nothing: "ear"
        case .failed: "exclamationmark.triangle.fill"
        case .unknown: "checkmark"
        }
    }
}

/// Something the Mac offers to do with a note it only saved ("Start it as a T3 task?"); `action` is what
/// `POST …/captures/<id>/act` takes to do it, sent back exactly as the bridge wrote it.
public struct CaptureSuggestion: Codable, Sendable, Equatable {
    public var action: String
    public var label: String

    public init(action: String, label: String) {
        self.action = action
        self.label = label
    }

    /// A word ("task") or an object (`{action|kind, label|title}`).
    public init(from decoder: Decoder) throws {
        if let word = try? decoder.singleValueContainer().decode(String.self) {
            let action = word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !action.isEmpty else { throw Self.missing(decoder) }
            self.init(action: action, label: Self.label(for: action))
            return
        }
        let c = try decoder.container(keyedBy: AnyKey.self)
        guard let action = c.text("action", "kind", "type") else { throw Self.missing(decoder) }
        self.init(action: action, label: c.text("label", "title", "text") ?? Self.label(for: action))
    }

    private static func missing(_ decoder: Decoder) -> DecodingError {
        .keyNotFound(AnyKey("action"), .init(codingPath: decoder.codingPath, debugDescription: "suggestion without an action"))
    }

    /// The button's words when the bridge sends none.
    public static func label(for action: String) -> String {
        switch CaptureOutcome.Kind(raw: action) {
        case .task: "Start it as a T3 task?"
        case .journal: "Add it to your journal?"
        case .event: "Put it on your calendar?"
        default: Formatting.clip(action.capitalized, 40)
        }
    }

    /// The short button title: "Start task", "Add to journal", "Add to calendar".
    public var buttonTitle: String {
        switch CaptureOutcome.Kind(raw: action) {
        case .task: "Start task"
        case .journal: "Add to journal"
        case .event: "Add to calendar"
        case .note: "Keep as note"
        case .nothing, .failed, .unknown:
            Formatting.clip(label.trimmingCharacters(in: CharacterSet(charactersIn: "?")), 24)
        }
    }

    public var symbol: String {
        switch CaptureOutcome.Kind(raw: action) {
        case .task: "sparkles"
        case .journal: "book.closed.fill"
        case .event: "calendar.badge.plus"
        default: "arrow.right.circle.fill"
        }
    }
}

/// A voice note as the Mac knows it: the answer to the upload (`202 {captureId, state: "received"}`), to
/// `GET /v1/mobile/capture/<id>?wait=` and the items of `GET /v1/mobile/captures`.
public struct CaptureStatus: Codable, Sendable, Equatable, Identifiable {
    public var captureId: String
    public var state: CaptureState
    /// What the Mac heard (his words), once transcribed.
    public var heard: String?
    public var outcome: CaptureOutcome?
    public var suggestion: CaptureSuggestion?
    /// Why it failed, or why it waits (`transcribe_unavailable` while the Mac's speech recognition isn't ready).
    public var error: String?
    /// The bridge's one line about it (`say`: the outcome's detail, "Sent." while it works on it).
    public var say: String?
    /// It waits on the Mac and is tried again then (its speech recognition or the journal was down).
    public var retryAt: Date?
    public var capturedAt: Date?
    public var updatedAt: Date?

    public var id: String { captureId }

    public init(captureId: String, state: CaptureState, heard: String? = nil, outcome: CaptureOutcome? = nil,
                suggestion: CaptureSuggestion? = nil, error: String? = nil, say: String? = nil, retryAt: Date? = nil,
                capturedAt: Date? = nil, updatedAt: Date? = nil) {
        self.captureId = captureId
        self.state = state
        self.heard = heard
        self.outcome = outcome
        self.suggestion = suggestion
        self.error = error
        self.say = say
        self.retryAt = retryAt
        self.capturedAt = capturedAt
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        // `{capture: {...}}` too (an action's answer may wrap it).
        if let inner = c.value(CaptureStatus.self, "capture") {
            self = inner
            return
        }
        guard let id = c.text("captureId", "id") else {
            throw DecodingError.keyNotFound(AnyKey("captureId"), .init(codingPath: decoder.codingPath,
                                                                       debugDescription: "capture without an id"))
        }
        captureId = id
        state = CaptureState(raw: c.text("state", "status"))
        heard = c.text("heard", "transcript", "text")
        outcome = c.value(CaptureOutcome.self, "outcome", "result", "route")
        suggestion = c.value(CaptureSuggestion.self, "suggestion")
        let failure = c.json("error")
        error = failure["code"].text ?? failure.text ?? c.text("code")
        say = c.text("say")
        retryAt = c.date("retryAt")
        capturedAt = c.date("capturedAt")
        updatedAt = c.date("updatedAt", "receivedAt")
    }

    /// The line after "Sent ✓": what the Mac did ("Added to your journal"), or that it's on it.
    public var notice: CaptureNotice { CaptureNotice(self) }
}

/// What a device shows once a voice note went (the recorder's last screen, the Live Activity's last line, the
/// watch's result face): "Sent ✓" with what the Mac did, "Saved · will send when your Mac is reachable", or
/// why it didn't work.
public struct CaptureNotice: Sendable, Equatable {
    public enum Tone: String, Sendable, Equatable {
        /// It reached the Mac (done, or still being worked on there).
        case sent
        /// Kept on the device until the Mac can be reached.
        case queued
        case failed
    }

    public var tone: Tone
    public var title: String
    public var detail: String?
    public var symbol: String
    /// What a locked phone may show under the title (the Live Activity's last line): where it went and what to do
    /// next, never what was said or the Mac's line about it (a journal line is private). nil: the title alone.
    public var glance: String?
    /// The Mac has the note, even when it couldn't do it or heard nothing: it was sent (recording it again would
    /// make a second one).
    public var reachedMac: Bool

    public init(tone: Tone, title: String, detail: String? = nil, symbol: String, glance: String? = nil,
                reachedMac: Bool = false) {
        self.tone = tone
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.glance = glance
        self.reachedMac = reachedMac
    }

    /// From the Mac's answer. The bridge's own line (`outcome.detail`: "Started “Fix login” in Website.") is the
    /// detail unless it only repeats the headline ("Added to your journal."); then what was heard stands there.
    public init(_ status: CaptureStatus) {
        let outcome = status.outcome
        switch status.state {
        case .done where outcome?.kind == .nothing, .failed where status.error == "no_speech":
            self.init(tone: .failed, title: "I didn't catch anything", detail: "Nothing was saved.", symbol: "ear",
                      glance: "Nothing was saved.", reachedMac: true)
        case .done:
            let outcome = outcome ?? CaptureOutcome(kind: status.suggestion == nil ? .unknown : .note)
            let title = outcome.kind == .unknown ? "Sent" : outcome.headline
            var parts: [String] = []
            var glance: [String] = []
            if let said = outcome.detail ?? status.say, !Self.repeats(said, title) { parts.append(said) }
            if outcome.kind == .note {
                // A saved note: what it suggests, and where it waits.
                if let suggestion = status.suggestion { parts.append(suggestion.label) }
                parts.append("It's in Tasks.")
                glance.append("It's in Tasks.")
            } else if parts.isEmpty, let heard = status.heard, !heard.isEmpty {
                parts.append("“\(Formatting.clip(heard, 80))”")
            }
            let detail = parts.joined(separator: " ")
            self.init(tone: .sent, title: title, detail: detail.isEmpty ? nil : Formatting.clip(detail, 120),
                      symbol: outcome.symbol, glance: glance.isEmpty ? nil : glance.joined(separator: " "),
                      reachedMac: true)
        case .failed:
            let said = outcome?.detail.flatMap { Self.repeats($0, "Your Mac couldn't do it") ? nil : $0 }
            self.init(tone: .failed, title: "Your Mac couldn't do it",
                      detail: said.map { Formatting.clip($0, 120) } ?? "It kept what you said. Check Tasks on your iPhone.",
                      symbol: "exclamationmark.triangle.fill", glance: "It kept what you said. Check Tasks.",
                      reachedMac: true)
        case .received, .transcribed:
            self.init(tone: .sent, title: "Sent", detail: "Your Mac is on it.", symbol: "checkmark",
                      glance: "Your Mac is on it.", reachedMac: true)
        }
    }

    /// The bridge's line says no more than the headline ("Added to your journal." under "Added to your journal").
    public static func repeats(_ line: String, _ headline: String) -> Bool {
        func plain(_ text: String) -> String {
            text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        }
        return plain(line) == plain(headline) || plain(line).isEmpty
    }

    /// The recording is kept here until the Mac can be reached.
    public static func queued(waiting: Int = 1) -> CaptureNotice {
        let detail = waiting > 1 ? "\(waiting) notes will go when your Mac is reachable." : "It goes when your Mac is reachable."
        return CaptureNotice(tone: .queued, title: "Saved", detail: detail, symbol: "tray.and.arrow.up.fill",
                             glance: detail)
    }

    /// The watch handed the recording to the iPhone (`WCSession.transferFile`), which sends it on.
    public static let handedToPhone = CaptureNotice(tone: .queued, title: "Saved", detail: "Your iPhone sends it on.",
                                                    symbol: "iphone.and.arrow.forward", glance: "Your iPhone sends it on.")

    /// The device's own words about why a note didn't go (nothing said in them): the screen and the Lock Screen alike.
    public static func plain(_ tone: Tone, _ title: String, _ detail: String, symbol: String) -> CaptureNotice {
        CaptureNotice(tone: tone, title: title, detail: detail, symbol: symbol, glance: detail)
    }

    /// "Sent ✓ — Added to your journal" (one line: the Live Activity, accessibility).
    public var line: String {
        let head = tone == .sent && title != "Sent" ? "Sent ✓ — \(title)" : tone == .sent ? "Sent ✓" : title
        guard let detail, !detail.isEmpty else { return head }
        return "\(head) · \(detail)"
    }
}

extension InboxSnapshot {
    /// The voice notes that failed on the Mac and wait in Tasks (`note:` items with status error): what Home's "didn't
    /// go through" line counts, so it only ever points at notes Tasks shows (and can dismiss). The summary's
    /// `captures.failed` counts a week; the inbox keeps a note's item for three days.
    public var failedNotes: Int { items.filter { $0.source == .note && $0.status == .error }.count }
}

/// `summary.captures`: the last three notes (what each became, in a word and the bridge's line), how many failed
/// in the last week (not dismissed), how many are still on their way on the Mac and how many saved notes wait in
/// the inbox. `nil` in the summary: a bridge without voice notes.
public struct CapturesOverview: Codable, Sendable, Equatable {
    /// One of the last notes (`recent[]`).
    public struct Recent: Codable, Sendable, Equatable, Identifiable {
        public var captureId: String
        public var state: CaptureState
        /// What it became, once done.
        public var kind: CaptureOutcome.Kind?
        public var title: String?
        /// The bridge's line ("Added to your journal.", "Started “Fix login” in Website.").
        public var say: String?
        /// When it was said.
        public var at: Date?

        public var id: String { captureId }

        public init(captureId: String, state: CaptureState, kind: CaptureOutcome.Kind? = nil, title: String? = nil,
                    say: String? = nil, at: Date? = nil) {
            self.captureId = captureId
            self.state = state
            self.kind = kind
            self.title = title
            self.say = say
            self.at = at
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            guard let id = c.text("captureId", "id") else {
                throw DecodingError.keyNotFound(AnyKey("captureId"), .init(codingPath: decoder.codingPath,
                                                                           debugDescription: "a note without an id"))
            }
            captureId = id
            state = CaptureState(raw: c.text("state"))
            kind = c.text("kind").map(CaptureOutcome.Kind.init(raw:))
            title = c.text("title")
            say = c.text("say", "detail")
            at = c.date("at", "capturedAt")
        }
    }

    public var available: Bool
    /// Newest first.
    public var recent: [Recent]
    public var failed: Int
    /// Still being heard or filed on the Mac.
    public var pending: Int
    /// Saved notes waiting in the inbox (Tasks).
    public var notes: Int

    public init(available: Bool = true, recent: [Recent] = [], failed: Int = 0, pending: Int = 0, notes: Int = 0) {
        self.available = available
        self.recent = recent
        self.failed = failed
        self.pending = pending
        self.notes = notes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        available = c.optionalBool("available") ?? true
        recent = Array(c.list(Recent.self, "recent").prefix(3))
        failed = c.optionalInt("failed") ?? c.json("failed").array?.count ?? 0
        pending = c.optionalInt("pending") ?? 0
        notes = c.optionalInt("notes") ?? 0
    }

    /// The newest note said in the last `seconds` (Home's line under the quick actions).
    public func latest(within seconds: TimeInterval = 15 * 60, now: Date = .now) -> Recent? {
        guard let first = recent.first, let at = first.at, now.timeIntervalSince(at) <= seconds else { return nil }
        return first
    }
}

/// `GET /v1/mobile/captures?limit=` -> `{captures: [...]}` (or `{items: [...]}`).
struct CaptureList: Decodable {
    var captures: [CaptureStatus]

    init(from decoder: Decoder) throws {
        if let list = try? decoder.singleValueContainer().decode([Lossy<CaptureStatus>].self) {
            captures = list.compactMap(\.value)
            return
        }
        let c = try decoder.container(keyedBy: AnyKey.self)
        let named = c.list(CaptureStatus.self, "captures")
        captures = named.isEmpty ? c.list(CaptureStatus.self, "items") : named
    }
}

extension BridgeError {
    /// The refusals a voice note is given up for (its recording deleted): sending the same recording again can't
    /// change them. Too long, not audio, too big, a different recording under its id, an id the Mac won't take, an
    /// empty file. Only these: losing a note is worse than trying once more.
    public static let finalCaptureCodes: Set<String> = [
        "audio_too_long", "unsupported_audio", "body_too_large", "capture_conflict", "invalid_capture_id", "empty_audio",
    ]

    /// Whether a voice note that got this answer stays in the outbox to be sent again: yes for the Mac out of reach,
    /// busy or failing, an older bridge (404, until it is updated), a token it refused (pair again, then it goes), an
    /// answer the bridge marks `retryable` (a recording that didn't arrive whole: 400 `invalid_audio`), the iPhone
    /// turning the watch's relay down (409 `not_paired` while it pairs again) and any refusal not known to be final;
    /// no only for `finalCaptureCodes`.
    public var isRetryableCapture: Bool {
        switch self {
        case .unreachable, .cancelled, .invalidResponse, .unauthorized, .notPaired: return true
        case .server(_, let code, _, let retryable):
            return retryable || !Self.finalCaptureCodes.contains(code)
        }
    }
}
