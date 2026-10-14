import Foundation

// The watch's voice assistant (CONTRACTS-WAVE5 "Streaming turn protocol"): the shapes the Mac bridge and the
// watch agree on. One conversation is a run of turns; each turn sends one utterance (a 16 kHz WAV), a text, or
// an announcement to speak, and gets back what was heard, what is said (as text and as audio) and whether the
// conversation goes on.
//
//   POST /v1/mobile/assistant/turn       (Accept: application/x-samrabbit-stream -> frames, else buffered JSON)
//   POST /v1/mobile/assistant/session    {conversationId?} -> {conversationId, brain, ready}   (warm-up)
//   POST /v1/mobile/assistant/cancel     {conversationId, turnId}  (stops that reply: the stream ends with done{interrupted})
//   POST /v1/mobile/assistant/end        {conversationId}
//   GET  /v1/mobile/assistant/announcements?conversationId=&since= -> {items:[...], cursor}
//
// The Mac's own app has the same routes under /v1/desktop/assistant/* (desktop token, loopback only; `BridgeAPI`).

/// Which model answers: gpt-realtime on the Mac (the R1's voice and tools) or the Claude fallback.
public enum AssistantBrain: String, Sendable, Codable, Equatable {
    case realtime
    case claude
    case unknown

    public init(raw: String?) {
        self = raw.flatMap { AssistantBrain(rawValue: $0.lowercased()) } ?? .unknown
    }
}

/// `summary.assistant`: `{available, brain, reason?, model, chatgpt: {connected}}`.
public struct AssistantStatus: Codable, Sendable, Equatable {
    public var available: Bool
    public var brain: AssistantBrain
    public var reason: String?
    public var model: String?
    public var chatgptConnected: Bool?

    public init(available: Bool, brain: AssistantBrain = .unknown, reason: String? = nil, model: String? = nil,
                chatgptConnected: Bool? = nil) {
        self.available = available
        self.brain = brain
        self.reason = reason
        self.model = model
        self.chatgptConnected = chatgptConnected
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        available = c.bool("available")
        brain = AssistantBrain(raw: c.text("brain"))
        reason = c.text("reason")
        model = c.text("model")
        let chatgpt = c.json("chatgpt")
        chatgptConnected = chatgpt["connected"].bool
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encode(available, forKey: AnyKey("available"))
        try c.encode(brain.rawValue, forKey: AnyKey("brain"))
        try c.encodeIfPresent(reason, forKey: AnyKey("reason"))
        try c.encodeIfPresent(model, forKey: AnyKey("model"))
        if let chatgptConnected {
            try c.encode(JSONValue.object(["connected": .bool(chatgptConnected)]), forKey: AnyKey("chatgpt"))
        }
    }
}

/// `POST /v1/mobile/assistant/session` -> `{conversationId, brain, ready}`.
public struct AssistantSession: Codable, Sendable, Equatable {
    public var conversationId: String
    public var brain: AssistantBrain
    public var ready: Bool

    public init(conversationId: String, brain: AssistantBrain = .unknown, ready: Bool = true) {
        self.conversationId = conversationId
        self.brain = brain
        self.ready = ready
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        conversationId = c.text("conversationId") ?? ""
        brain = AssistantBrain(raw: c.text("brain"))
        ready = c.bool("ready", default: true)
    }
}

/// Something the assistant did (`{"type":"action", kind, title, threadId?, artifactId?, eventId?}`): a task it
/// started, an event it created, a generated UI.
public struct AssistantAction: Codable, Sendable, Equatable, Hashable {
    public var kind: String
    public var title: String
    public var threadId: String?
    public var artifactId: String?
    public var eventId: String?

    public init(kind: String, title: String, threadId: String? = nil, artifactId: String? = nil, eventId: String? = nil) {
        self.kind = kind
        self.title = title
        self.threadId = threadId
        self.artifactId = artifactId
        self.eventId = eventId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        kind = c.text("kind") ?? "action"
        title = c.text("title") ?? ""
        threadId = c.text("threadId")
        artifactId = c.text("artifactId")
        eventId = c.text("eventId")
    }
}

/// A small card the assistant shows on the watch (`{"type":"card", title, body}`).
public struct AssistantCard: Codable, Sendable, Equatable, Hashable {
    public var title: String
    public var body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        title = c.text("title") ?? ""
        body = c.string("body") ?? c.string("text") ?? ""
    }
}

/// `timings: {stt, firstAudio, total}` (ms, 64-bit like every millisecond value). The buffered Claude path says
/// `{stt, agent, tts}`.
public struct AssistantTimings: Codable, Sendable, Equatable {
    public var stt: Int64?
    public var firstAudio: Int64?
    public var total: Int64?

    public init(stt: Int64? = nil, firstAudio: Int64? = nil, total: Int64? = nil) {
        self.stt = stt
        self.firstAudio = firstAudio
        self.total = total
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        stt = c.optionalInt64("stt")
        firstAudio = c.optionalInt64("firstAudio")
        total = c.optionalInt64("total")
        if total == nil, let agent = c.optionalInt64("agent") {
            // Wrapping adds: three durations can't overflow 64 bits, and nothing a bridge sends may trap the watch.
            total = (stt ?? 0) &+ agent &+ (c.optionalInt64("tts") ?? 0)
        }
    }
}

/// The last event of a turn: `{"type":"done", conversationId, turnId, expectReply, endConversation, interrupted?,
/// brain, timings}`.
public struct AssistantDone: Codable, Sendable, Equatable {
    public var conversationId: String
    public var turnId: String
    public var expectReply: Bool
    public var endConversation: Bool
    public var interrupted: Bool
    public var brain: AssistantBrain
    public var timings: AssistantTimings

    public init(conversationId: String, turnId: String, expectReply: Bool = false, endConversation: Bool = false,
                interrupted: Bool = false, brain: AssistantBrain = .unknown, timings: AssistantTimings = .init()) {
        self.conversationId = conversationId
        self.turnId = turnId
        self.expectReply = expectReply
        self.endConversation = endConversation
        self.interrupted = interrupted
        self.brain = brain
        self.timings = timings
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        conversationId = c.text("conversationId") ?? ""
        turnId = c.text("turnId") ?? ""
        expectReply = c.bool("expectReply")
        endConversation = c.bool("endConversation")
        interrupted = c.bool("interrupted")
        brain = AssistantBrain(raw: c.text("brain"))
        timings = c.value(AssistantTimings.self, "timings") ?? .init()
    }
}

/// One `'J'` frame of a streamed turn.
public enum AssistantEvent: Sendable, Equatable {
    /// What the Mac heard (the transcript of the utterance). May arrive after audio started.
    case heard(String)
    /// More of what is being said (live caption).
    case sayDelta(String)
    /// Everything that was said.
    case sayDone(String)
    case action(AssistantAction)
    case card(AssistantCard)
    case done(AssistantDone)
    /// The turn failed on the Mac (the stream ends after it).
    case error(code: String, message: String)
    /// A newer bridge's event this watch doesn't know: ignored.
    case unknown(String)

    /// Decodes one event's JSON. Throws only when the payload isn't a JSON object at all.
    public init(json data: Data) throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case .object = value else { throw AssistantStreamError.invalidEvent }
        let type = value["type"].string ?? ""
        switch type {
        case "heard": self = .heard(value["text"].string ?? "")
        case "say.delta": self = .sayDelta(value["text"].string ?? "")
        case "say.done": self = .sayDone(value["text"].string ?? "")
        case "action": self = .action(try BridgeJSON.decode(AssistantAction.self, from: data))
        case "card": self = .card(try BridgeJSON.decode(AssistantCard.self, from: data))
        case "done": self = .done(try BridgeJSON.decode(AssistantDone.self, from: data))
        case "error":
            self = .error(code: value["code"].string ?? "assistant_failed", message: value["message"].string ?? "")
        default: self = .unknown(type)
        }
    }

    /// The event as the bridge writes it (the fake bridge and the tests use this).
    public var json: Data {
        var object: [String: JSONValue]
        switch self {
        case .heard(let text): object = ["type": "heard", "text": .string(text)]
        case .sayDelta(let text): object = ["type": "say.delta", "text": .string(text)]
        case .sayDone(let text): object = ["type": "say.done", "text": .string(text)]
        case .action(let action):
            object = ["type": "action", "kind": .string(action.kind), "title": .string(action.title)]
            if let id = action.threadId { object["threadId"] = .string(id) }
            if let id = action.artifactId { object["artifactId"] = .string(id) }
            if let id = action.eventId { object["eventId"] = .string(id) }
        case .card(let card): object = ["type": "card", "title": .string(card.title), "body": .string(card.body)]
        case .done(let done):
            object = ["type": "done", "conversationId": .string(done.conversationId), "turnId": .string(done.turnId),
                      "expectReply": .bool(done.expectReply), "endConversation": .bool(done.endConversation),
                      "brain": .string(done.brain.rawValue)]
            if done.interrupted { object["interrupted"] = true }
            var timings: [String: JSONValue] = [:]
            if let v = done.timings.stt { timings["stt"] = .number(Double(v)) }
            if let v = done.timings.firstAudio { timings["firstAudio"] = .number(Double(v)) }
            if let v = done.timings.total { timings["total"] = .number(Double(v)) }
            object["timings"] = .object(timings)
        case .error(let code, let message): object = ["type": "error", "code": .string(code), "message": .string(message)]
        case .unknown(let type): object = ["type": .string(type)]
        }
        return (try? BridgeJSON.encoder().encode(JSONValue.object(object))) ?? Data("{}".utf8)
    }
}

/// An encoded audio clip from a buffered answer or an announcement: `{mime, b64}`.
public struct AssistantAudio: Codable, Sendable, Equatable {
    public var mime: String
    public var data: Data

    public init(mime: String, data: Data) {
        self.mime = mime
        self.data = data
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        mime = (c.text("mime", "type") ?? "audio/mpeg").lowercased()
        guard let b64 = c.string("b64") ?? c.string("data"), let data = Data(base64Encoded: b64), !data.isEmpty else {
            throw AssistantStreamError.invalidAudio
        }
        self.data = data
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encode(mime, forKey: AnyKey("mime"))
        try c.encode(data.base64EncodedString(), forKey: AnyKey("b64"))
    }

    /// 16 kHz mono 16-bit PCM inside a WAV: playable frame by frame like a stream.
    public var pcm16k: Data? {
        guard mime.contains("wav") || WAV.isWAV(data), let wav = try? WAV.decode(data),
              wav.sampleRate == AssistantAudioFormat.sampleRate, wav.channels == 1 else { return nil }
        return wav.pcm
    }
}

/// The buffered answer to a turn (no stream `Accept`, the Claude fallback, an older bridge):
/// `{conversationId, turnId, heard, say, audio|null, expectReply, endConversation, actions, timings, brain?}`.
public struct AssistantReply: Codable, Sendable, Equatable {
    public var conversationId: String
    public var turnId: String
    public var heard: String
    public var say: String
    public var audio: AssistantAudio?
    public var expectReply: Bool
    public var endConversation: Bool
    public var interrupted: Bool
    public var actions: [AssistantAction]
    public var cards: [AssistantCard]
    public var brain: AssistantBrain
    public var timings: AssistantTimings

    public init(conversationId: String, turnId: String, heard: String = "", say: String = "", audio: AssistantAudio? = nil,
                expectReply: Bool = false, endConversation: Bool = false, interrupted: Bool = false,
                actions: [AssistantAction] = [], cards: [AssistantCard] = [], brain: AssistantBrain = .unknown,
                timings: AssistantTimings = .init()) {
        self.conversationId = conversationId
        self.turnId = turnId
        self.heard = heard
        self.say = say
        self.audio = audio
        self.expectReply = expectReply
        self.endConversation = endConversation
        self.interrupted = interrupted
        self.actions = actions
        self.cards = cards
        self.brain = brain
        self.timings = timings
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        conversationId = c.text("conversationId") ?? ""
        turnId = c.text("turnId") ?? ""
        heard = c.string("heard") ?? ""
        say = c.string("say") ?? ""
        audio = c.value(AssistantAudio.self, "audio")
        expectReply = c.bool("expectReply")
        endConversation = c.bool("endConversation")
        interrupted = c.bool("interrupted")
        actions = c.list(AssistantAction.self, "actions")
        cards = c.list(AssistantCard.self, "cards")
        brain = AssistantBrain(raw: c.text("brain"))
        timings = c.value(AssistantTimings.self, "timings") ?? .init()
    }

    /// The same answer as the items a stream would have produced, so the watch plays both the same way.
    public var items: [AssistantStreamItem] {
        var items: [AssistantStreamItem] = []
        if !heard.isEmpty { items.append(.event(.heard(heard))) }
        if let audio {
            if let pcm = audio.pcm16k {
                items.append(.audio(pcm))
            } else {
                items.append(.clip(audio))
            }
        }
        if !say.isEmpty { items.append(.event(.sayDone(say))) }
        items += actions.map { .event(.action($0)) }
        items += cards.map { .event(.card($0)) }
        items.append(.event(.done(AssistantDone(conversationId: conversationId, turnId: turnId, expectReply: expectReply,
                                                endConversation: endConversation, interrupted: interrupted,
                                                brain: brain, timings: timings))))
        return items
    }
}

/// What a turn produces, in order, whether it was streamed or buffered.
public enum AssistantStreamItem: Sendable, Equatable {
    case event(AssistantEvent)
    /// PCM16LE, mono, 16 kHz (`'A'` frames).
    case audio(Data)
    /// A whole encoded clip (MP3 from the Claude fallback's voice, or a WAV in another format).
    case clip(AssistantAudio)
}

/// One T3 event to tell Samin about: `{id, say, audio|null, kind: needs_you|done|error, threadId, title}`.
public struct Announcement: Codable, Sendable, Equatable, Identifiable {
    /// The bridge's id (a number on the Claude path): kept as text, sent back as `{"announce": id}`.
    public var id: String
    public var say: String
    public var audio: AssistantAudio?
    public var kind: String
    public var threadId: String?
    public var title: String?

    public init(id: String, say: String, audio: AssistantAudio? = nil, kind: String = "done", threadId: String? = nil,
                title: String? = nil) {
        self.id = id
        self.say = say
        self.audio = audio
        self.kind = kind
        self.threadId = threadId
        self.title = title
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        let raw = c.json("id")
        if let text = raw.text {
            id = text
        } else if let number = raw.int64 {
            id = String(number)
        } else {
            throw AssistantStreamError.invalidEvent
        }
        say = c.string("say") ?? c.string("text") ?? ""
        audio = c.value(AssistantAudio.self, "audio")
        kind = c.text("kind") ?? "done"
        threadId = c.text("threadId")
        title = c.text("title")
    }
}

/// `GET /v1/mobile/assistant/announcements` -> `{items, cursor}`.
public struct AnnouncementPage: Codable, Sendable, Equatable {
    public var items: [Announcement]
    public var cursor: String?

    public init(items: [Announcement] = [], cursor: String? = nil) {
        self.items = items
        self.cursor = cursor
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        items = c.list(Announcement.self, "items")
        let raw = c.json("cursor")
        cursor = raw.text ?? raw.int64.map(String.init)
    }
}

/// The audio both ends use: utterances go up as 16 kHz mono 16-bit WAV; replies stream down as PCM16LE at 16 kHz.
public enum AssistantAudioFormat {
    public static let sampleRate = 16_000
    public static let channels = 1
    public static let bytesPerSecond = sampleRate * 2
    /// The turn route refuses bigger bodies (2 MiB) and longer utterances (60 s); the watch cuts at 30 s.
    public static let maxUploadBytes = 2 * 1024 * 1024
}

public enum AssistantStreamError: Error, Sendable, Equatable {
    case frameTooLarge(Int)
    case invalidEvent
    case invalidAudio
    /// The stream closed before its `done` event.
    case truncated
}
