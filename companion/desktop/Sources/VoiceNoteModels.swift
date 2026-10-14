import Foundation

// Voice notes on the Mac (CONTRACTS-WAVE8 §D1): ⌃⌥N held records while it is held and the release sends; tapped, it
// records until the next tap (or a pause, or the 5-minute cap). The dock's note button, the menus and the window's Home
// do the tap. The note goes to the bridge's capture route (`POST /v1/desktop/capture`, a 16 kHz WAV), which transcribes
// it, works out what it is (a journal line when Samin says so, a T3 task, a calendar entry, or a note kept for later)
// and does it. Nothing talks back: the dock shows how it went. When the bridge can't be reached the WAV waits in a local
// outbox and goes when it is back. Pure (Foundation only): tests/swift and the voice harness compile this file;
// VoiceNote.swift wires it to the microphone, the bridge and the dock.

enum VoiceNoteRules {
    /// A press held this long is "hold to talk": its release sends. A shorter one is a tap: recording goes on.
    static let holdThreshold: TimeInterval = 0.35
    /// Presses closer together than this while the key is down are the keyboard repeating, not a new press.
    static let repeatWindow: TimeInterval = 0.6
    /// Shorter recordings are a slip of the finger: discarded, never sent.
    static let minimumSeconds: TimeInterval = 0.4
    /// The bridge takes up to 300 s (CONTRACTS-WAVE8 §A2).
    static let maxSeconds: TimeInterval = 300
    /// Tapped (not held): this much quiet after speech sends it, like the iPhone's and the R1's notes.
    static let tapSilence: TimeInterval = 3
    /// Tapped and nothing said for this long: it stops and nothing is sent.
    static let tapNoSpeech: TimeInterval = 12
    /// How long the dock shows how a note went.
    static let outcomeSeconds: TimeInterval = 4.5
    /// How long it waits for the bridge to say what it did with a note before showing "Sent" alone.
    static let outcomeWait: TimeInterval = 20
    /// The outbox keeps at most this many notes, none older than a week.
    static let outboxLimit = 50
    static let outboxMaxAge: TimeInterval = 7 * 86_400
    /// Retries of an upload that didn't reach the bridge: 5 s, 30 s, 2 min, then every 10 min.
    static let retryDelays: [TimeInterval] = [5, 30, 120, 600]

    static func retryDelay(attempts: Int) -> TimeInterval {
        retryDelays[min(max(0, attempts - 1), retryDelays.count - 1)]
    }
}

/// ⌃⌥N as a press and a release (Carbon delivers both, no permission needed): hold to record while held, tap to start
/// and tap again to send. A note started some other way (the dock's button, a menu) is sent by the next press.
struct VoiceNoteGesture: Equatable {
    enum State: Equatable {
        case idle
        /// Recording, the key is down, and it isn't known yet whether this is a hold or a tap.
        case down(since: Date)
        /// Recording after a tap: the next press sends.
        case latched
        /// The key is down after the press that sent (or ended) a note: its release does nothing.
        case pressedToSend
    }

    enum Effect: Equatable {
        case none
        /// Start recording now (the key went down).
        case start
        /// Stop recording and send.
        case finish
    }

    private(set) var state = State.idle
    private var lastPress: Date?

    /// The key went down. `recording`: a note is recording right now (maybe started by a button).
    mutating func press(at now: Date, recording: Bool) -> Effect {
        defer { lastPress = now }
        let repeating = lastPress.map { now.timeIntervalSince($0) < VoiceNoteRules.repeatWindow } ?? false
        switch state {
        case .idle:
            if recording {
                state = .pressedToSend
                return .finish
            }
            state = .down(since: now)
            return .start
        case .down:
            // The key repeating; a press long after the last one means a release went missing: it sends.
            guard !repeating else { return .none }
            state = .pressedToSend
            return recording ? .finish : .none
        case .latched:
            state = .pressedToSend
            return recording ? .finish : .none
        case .pressedToSend:
            guard !repeating else { return .none }
            // A release went missing: this press is a new one.
            if recording { return .finish }
            state = .down(since: now)
            return .start
        }
    }

    /// The key came up.
    mutating func release(at now: Date) -> Effect {
        switch state {
        case .down(let since):
            if now.timeIntervalSince(since) >= VoiceNoteRules.holdThreshold {
                state = .idle
                return .finish
            }
            state = .latched
            return .none
        case .pressedToSend:
            state = .idle
            return .none
        case .idle, .latched:
            return .none
        }
    }

    /// The note ended another way (a button, a pause, the cap, cancel, a refusal): a key still down does nothing more.
    mutating func ended() {
        if case .down = state {
            state = .pressedToSend
        } else if state == .latched {
            state = .idle
        }
    }

    /// Held (not tapped) so far: the release will send.
    var holding: Bool {
        if case .down = state { return true }
        return false
    }
}

/// What the dock, the menus and the window draw of the note.
struct VoiceNoteSnapshot: Equatable {
    enum Phase: Equatable {
        case idle
        /// `held`: ⌃⌥N is held (the release sends); else it was tapped (the next tap, or a pause, sends).
        case recording(held: Bool)
        case sending
        /// The bridge has it; the lines say what it did once it said so.
        case sent
        /// Kept on this Mac: it goes when the bridge is back.
        case queued
        /// Too short or nothing said: nothing was sent.
        case discarded
        /// It couldn't record or the bridge refused it.
        case failed
    }

    var phase: Phase = .idle
    var startedAt: Date?
    /// 0...1 while recording.
    var level: Double = 0
    var line = ""
    var detail = ""
    /// "⌃⌥N", or "" when the shortcut isn't working.
    var shortcut = "⌃⌥N"
    /// Notes waiting in the outbox for the bridge.
    var waiting = 0

    var active: Bool { phase != .idle }

    var recording: Bool {
        if case .recording = phase { return true }
        return false
    }

    /// What the window's page reads (web/note.js `normalizeNote`).
    var json: [String: Any] {
        let name: String
        var held = false
        switch phase {
        case .idle: name = "idle"
        case .recording(let isHeld):
            name = "recording"
            held = isHeld
        case .sending: name = "sending"
        case .sent: name = "sent"
        case .queued: name = "queued"
        case .discarded: name = "discarded"
        case .failed: name = "failed"
        }
        return [
            "state": name, "held": held, "line": line, "detail": detail, "shortcut": shortcut, "waiting": waiting,
            "startedAt": startedAt.map { ($0.timeIntervalSince1970 * 1000).rounded() } ?? NSNull(),
        ]
    }
}

// MARK: what the bridge answers

/// What the bridge did with a note: `{kind, title, detail, threadId?, eventId?, noteId?}`.
struct CaptureOutcome: Equatable {
    var kind: String
    var title: String
    var detail: String
    var threadId: String?
    var eventId: String?
    var noteId: String?
}

/// What the bridge offers next for a note it kept (`{label, action}`), e.g. "Start it as a T3 task?".
struct CaptureSuggestion: Equatable {
    var label: String
    var action: String
}

/// `POST /v1/desktop/capture` (202 `{captureId, state: "received"}`) and `GET /v1/desktop/capture/<id>?wait=`
/// (`{state, heard, outcome, suggestion?}`). Read forgivingly: a missing or odd field takes its default.
struct CaptureStatus: Equatable {
    var captureId: String
    /// received | transcribing | transcribed | routing | acting | done | needs_you | queued | no_speech | failed
    var state: String
    var heard: String?
    var outcome: CaptureOutcome?
    var suggestion: CaptureSuggestion?
    /// The bridge's own one-line summary, when it gives one.
    var say: String?
    var error: String?

    /// The bridge is done with it (what it did is known, or it gave up).
    var settled: Bool {
        ["done", "needs_you", "no_speech", "failed"].contains(state)
    }

    static func decode(_ data: Data, fallbackId: String) -> CaptureStatus? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return from(object, fallbackId: fallbackId)
    }

    static func from(_ raw: [String: Any], fallbackId: String) -> CaptureStatus {
        // Some answers wrap it: {"capture": {...}}.
        let object = (raw["capture"] as? [String: Any]) ?? raw
        func text(_ value: Any?) -> String? {
            guard let value = value as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        var outcome: CaptureOutcome?
        if let raw = object["outcome"] as? [String: Any] {
            outcome = CaptureOutcome(kind: text(raw["kind"]) ?? "", title: text(raw["title"]) ?? "", detail: text(raw["detail"]) ?? "",
                                     threadId: text(raw["threadId"]), eventId: text(raw["eventId"]), noteId: text(raw["noteId"]))
        } else if let route = object["route"] as? [String: Any], let kind = text(route["kind"]) {
            // The research draft's shape: {route: {kind}, say}.
            outcome = CaptureOutcome(kind: kind, title: "", detail: "", threadId: nil, eventId: nil, noteId: nil)
        }
        var suggestion: CaptureSuggestion?
        if let raw = object["suggestion"] as? [String: Any], let label = text(raw["label"]) {
            let action = text(raw["action"]) ?? text(raw["kind"]) ?? (raw["action"] as? [String: Any]).flatMap { text($0["kind"]) } ?? ""
            suggestion = CaptureSuggestion(label: label, action: action)
        } else if let label = text(object["suggestion"]) {
            suggestion = CaptureSuggestion(label: label, action: "")
        }
        let error = (object["error"] as? [String: Any]).flatMap { text($0["code"]) } ?? text(object["error"])
        return CaptureStatus(captureId: text(object["captureId"]) ?? fallbackId, state: (text(object["state"]) ?? "received").lowercased(),
                             heard: text(object["heard"]) ?? text(object["transcript"]), outcome: outcome, suggestion: suggestion,
                             say: text(object["say"]), error: error)
    }
}

/// The lines the dock shows for a note the bridge has.
enum VoiceNoteText {
    static func clip(_ text: String, _ max: Int) -> String {
        let flat = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return flat.count > max ? String(flat.prefix(max - 1)) + "…" : flat
    }

    /// (line, detail): "Added to your journal" / "“finished the release notes”".
    static func outcome(_ status: CaptureStatus) -> (line: String, detail: String) {
        let outcome = status.outcome
        let heard = status.heard.map { "“\(clip($0, 90))”" } ?? ""
        let title = outcome?.title ?? ""
        let detail = outcome?.detail ?? ""
        switch status.state {
        case "no_speech":
            return ("Didn’t catch anything", "Nothing was sent.")
        case "failed":
            return ("The bridge couldn’t finish it", clip(detail.isEmpty ? (status.say ?? status.error.map(errorText) ?? "It keeps the note to try again.") : detail, 110))
        default:
            break
        }
        let kind = (outcome?.kind ?? "").lowercased()
        let named = { (fallback: String) -> String in title.isEmpty ? fallback : "“\(clip(title, 70))”" }
        switch kind {
        case "journal":
            return ("Added to your journal", detail.isEmpty ? heard : "“\(clip(detail, 90))”")
        case "t3_task", "task", "t3":
            return ("Started a T3 task", named(heard))
        case "calendar_event", "calendar_block", "calendar", "reminder", "event", "block":
            let what = title.isEmpty ? heard : clip(title, 70)
            return ("On your calendar", detail.isEmpty ? what : clip("\(what) · \(detail)", 110))
        case "note":
            if let suggestion = status.suggestion { return ("Saved as a note", clip(suggestion.label, 90)) }
            return ("Saved as a note", heard)
        default:
            if !status.settled && outcome == nil { return ("Sent", "Working on it…") }
            if !title.isEmpty { return (clip(title, 60), clip(detail.isEmpty ? heard : detail, 110)) }
            return ("Sent", status.say.map { clip($0, 110) } ?? heard)
        }
    }

    static func errorText(_ code: String) -> String {
        switch code {
        case "transcribe_unavailable", "model_downloading": return "Transcription isn’t ready on the Mac yet."
        case "t3_not_connected": return "T3 Code isn’t connected."
        case "heptabase_closed", "journal_unavailable": return "Heptabase isn’t open on the Mac."
        default: return "It said \(code)."
        }
    }
}

// MARK: sending

/// The capture upload's headers (CONTRACTS-WAVE8 §A2): the id made when recording started (the bridge keeps one note per
/// id, so a retry never makes a second), when it was said, and where.
enum VoiceNoteUpload {
    static let contentType = "audio/wav"

    static func headers(captureId: String, capturedAt: Date, timeZone: TimeZone = .current) -> [String: String] {
        ["Content-Type": contentType, "X-SamRabbit-Capture": captureId,
         "X-SamRabbit-Captured-At": iso(capturedAt, timeZone: timeZone), "X-SamRabbit-Source": "mac"]
    }

    /// "2026-10-14T09:41:07-04:00": the local time with its offset (the journal line's time, "tomorrow" in a note).
    static func iso(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }

    /// A UUID, as made for each note (also how outbox files are named, so nothing else can be a path).
    static func isCaptureId(_ text: String) -> Bool {
        text.count == 36 && UUID(uuidString: text) != nil
    }

    static func newId() -> String { UUID().uuidString.lowercased() }
}

/// What a capture upload's answer means for the note.
enum VoiceNoteDelivery: Equatable {
    /// The bridge has it (it may still be working on it).
    case delivered(CaptureStatus)
    /// Try again later; it stays in the outbox. `why` is what the dock says.
    case keep(String)
    /// Never going to be taken (too long, unreadable): it leaves the outbox.
    case drop(String)

    /// `status` 0: unreachable, -1: no desktop token.
    static func classify(status: Int, body: Data, captureId: String) -> VoiceNoteDelivery {
        if (200..<300).contains(status) {
            return .delivered(CaptureStatus.decode(body, fallbackId: captureId)
                ?? CaptureStatus(captureId: captureId, state: "received"))
        }
        let code = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])
            .flatMap { ($0["error"] as? [String: Any])?["code"] as? String } ?? ""
        switch status {
        case 0: return .keep("The bridge isn’t running")
        case -1: return .keep("SamRabbit isn’t set up (no desktop token)")
        case 401, 403: return .keep("The bridge didn’t accept SamRabbit")
        case 404, 405: return .keep("The bridge needs an update for voice notes")
        case 409: return .drop("The bridge already has a different note with this id")
        case 413: return .drop("Too long for the bridge")
        case 422 where code == "no_speech": return .drop("Didn’t catch anything")
        case 400, 415, 422:
            switch code {
            case "audio_too_long": return .drop("Too long for the bridge (5 minutes at most)")
            case "unsupported_audio", "invalid_audio": return .drop("The bridge couldn’t read the recording")
            case "invalid_capture_id": return .drop("The bridge refused the note’s id")
            default: return .drop("The bridge refused it (\(code.isEmpty ? "HTTP \(status)" : code))")
            }
        default: return .keep("The bridge is busy")
        }
    }
}

/// Notes the bridge hasn't taken yet: `<id>.wav` and `<id>.json` in a private folder (0700, files 0600), each deleted
/// once the bridge said it has it. At most 50, none older than a week. File names are capture ids (UUIDs) only.
struct VoiceNoteOutbox {
    struct Item: Equatable, Codable {
        var captureId: String
        var capturedAt: Date
        var createdAt: Date
        var seconds: Double
        var attempts = 0
        var lastError: String?
        var nextAt: Date
    }

    let directory: URL

    /// `~/Library/Application Support/SamRabbit/capture-outbox` for the installed app only; a development copy (another
    /// bundle id) or a harness without one gets its own folder, so the installed app never sends a test recording;
    /// `SAMRABBIT_CAPTURE_OUTBOX` overrides both.
    static func defaultDirectory(bundleId: String?, environment: [String: String],
                                 support: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]) -> URL {
        if let custom = environment["SAMRABBIT_CAPTURE_OUTBOX"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        let base = support.appendingPathComponent("SamRabbit", isDirectory: true)
        guard let bundleId, !bundleId.isEmpty else { return base.appendingPathComponent("capture-outbox-unbundled", isDirectory: true) }
        guard bundleId != "com.samrabbit.desktop" else { return base.appendingPathComponent("capture-outbox", isDirectory: true) }
        let safe = String(bundleId.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" })
        return base.appendingPathComponent("capture-outbox-\(safe)", isDirectory: true)
    }

    private var manager: FileManager { .default }

    private func file(_ id: String, _ ext: String) -> URL { directory.appendingPathComponent("\(id).\(ext)") }

    private func ensure() throws {
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    /// Keeps a note (the audio first, then its record, each written whole and flushed).
    func add(_ item: Item, wav: Data) throws {
        guard VoiceNoteUpload.isCaptureId(item.captureId) else { throw CocoaError(.fileWriteInvalidFileName) }
        try ensure()
        try write(wav, to: file(item.captureId, "wav"))
        try write(Self.encoder.encode(item), to: file(item.captureId, "json"))
    }

    func update(_ item: Item) {
        guard VoiceNoteUpload.isCaptureId(item.captureId), manager.fileExists(atPath: file(item.captureId, "wav").path),
              let data = try? Self.encoder.encode(item) else { return }
        try? write(data, to: file(item.captureId, "json"))
    }

    private func write(_ data: Data, to url: URL) throws {
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString.prefix(8))")
        guard manager.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            _ = try manager.replaceItemAt(url, withItemAt: temporary)
        } catch {
            try? manager.removeItem(at: temporary)
            throw error
        }
    }

    /// Every note waiting, oldest first (a record without its audio, or audio without a record, is left out).
    func items() -> [Item] {
        let names = (try? manager.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { name -> Item? in
            guard name.hasSuffix(".json") else { return nil }
            let id = String(name.dropLast(5))
            guard VoiceNoteUpload.isCaptureId(id), manager.fileExists(atPath: file(id, "wav").path),
                  let data = manager.contents(atPath: file(id, "json").path),
                  let item = try? Self.decoder.decode(Item.self, from: data), item.captureId == id else { return nil }
            return item
        }
        .sorted { ($0.createdAt, $0.captureId) < ($1.createdAt, $1.captureId) }
    }

    func wav(_ id: String) -> Data? {
        guard VoiceNoteUpload.isCaptureId(id) else { return nil }
        return manager.contents(atPath: file(id, "wav").path)
    }

    func remove(_ id: String) {
        guard VoiceNoteUpload.isCaptureId(id) else { return }
        try? manager.removeItem(at: file(id, "json"))
        try? manager.removeItem(at: file(id, "wav"))
    }

    /// Drops notes older than a week, and the oldest beyond 50, and leftovers (audio without a record, half-written
    /// files); returns the ids it dropped.
    @discardableResult
    func prune(now: Date) -> [String] {
        var dropped: [String] = []
        let kept = items()
        for item in kept where now.timeIntervalSince(item.createdAt) > VoiceNoteRules.outboxMaxAge {
            remove(item.captureId)
            dropped.append(item.captureId)
        }
        let young = kept.filter { now.timeIntervalSince($0.createdAt) <= VoiceNoteRules.outboxMaxAge }
        for item in young.dropLast(VoiceNoteRules.outboxLimit) {
            remove(item.captureId)
            dropped.append(item.captureId)
        }
        let known = Set(items().map(\.captureId))
        for name in (try? manager.contentsOfDirectory(atPath: directory.path)) ?? [] {
            let stem = name.split(separator: ".", maxSplits: 1).first.map(String.init) ?? name
            let stray = name.hasPrefix(".") || !VoiceNoteUpload.isCaptureId(stem) || !known.contains(stem)
            // A half-written file of a moment ago may still be on its way: only old ones go.
            let age = ((try? manager.attributesOfItem(atPath: directory.appendingPathComponent(name).path))?[.modificationDate] as? Date)
                .map { now.timeIntervalSince($0) } ?? .infinity
            if stray && age > 60 { try? manager.removeItem(at: directory.appendingPathComponent(name)) }
        }
        return dropped
    }

    /// The notes whose next try is due.
    func due(now: Date) -> [Item] { items().filter { $0.nextAt <= now } }

    /// When the next try is due (nil: nothing waits).
    func nextDue() -> Date? { items().map(\.nextAt).min() }

    /// A try that didn't reach the bridge: when to try next.
    static func failed(_ item: Item, why: String, now: Date) -> Item {
        var next = item
        next.attempts += 1
        next.lastError = why
        next.nextAt = now.addingTimeInterval(VoiceNoteRules.retryDelay(attempts: next.attempts))
        return next
    }
}
