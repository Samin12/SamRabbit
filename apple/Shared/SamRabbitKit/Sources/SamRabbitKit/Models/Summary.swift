import Foundation

typealias Fields = KeyedDecodingContainer<AnyKey>

extension KeyedDecodingContainer where Key == AnyKey {
    func string(_ name: String) -> String? { string(AnyKey(name)) }
    func text(_ names: String...) -> String? {
        for name in names {
            if let value = string(AnyKey(name))?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return nil
    }
    func date(_ names: String...) -> Date? {
        for name in names { if let value = date(AnyKey(name)) { return value } }
        return nil
    }
    func bool(_ name: String, default value: Bool = false) -> Bool { bool(AnyKey(name), default: value) }
    func optionalBool(_ name: String) -> Bool? {
        contains(AnyKey(name)) ? lenient(Bool.self, AnyKey(name)) : nil
    }
    func int(_ name: String, default value: Int = 0) -> Int { int(AnyKey(name), default: value) }
    func optionalInt(_ name: String) -> Int? {
        guard let raw = lenient(JSONValue.self, AnyKey(name)) else { return nil }
        return raw.int
    }
    func int64(_ name: String, default value: Int64 = 0) -> Int64 { int64(AnyKey(name), default: value) }
    func optionalInt64(_ name: String) -> Int64? {
        guard let raw = lenient(JSONValue.self, AnyKey(name)) else { return nil }
        return raw.int64
    }
    func value<T: Decodable>(_ type: T.Type, _ names: String...) -> T? {
        lenient(type, any: names.map(AnyKey.init))
    }
    func list<T: Decodable>(_ type: T.Type, _ name: String) -> [T] { list(type, AnyKey(name)) }
    func json(_ name: String) -> JSONValue { lenient(JSONValue.self, AnyKey(name)) ?? .null }
}

/// `GET /v1/mobile/summary`: the one fast dashboard payload behind Home, the widgets and the
/// complications (served from the bridge's cache in well under 300 ms).
public struct MobileSummary: Codable, Sendable, Equatable {
    public var generatedAt: Date?
    public var mac: MacStatus
    public var r1: R1Status
    public var t3: TaskOverview
    public var calendar: CalendarOverview
    public var latestConversation: ConversationPreview?
    public var journal: JournalStatus
    /// Whether the Mac can turn the watch's recordings into words (`nil`: a bridge that doesn't say).
    public var transcribe: TranscribeStatus?
    /// Whether the watch can talk to the assistant, and which brain answers (`nil`: a bridge without one).
    public var assistant: AssistantStatus?
    /// Every agent on the Mac (T3, Claude Code, Codex): the inbox's counts and first items, added by the iPhone from
    /// `/v1/mobile/inbox` (`with(inbox:)`); `nil`: T3's counts only (the watch, an older bridge).
    public var inbox: InboxOverview?

    public init(generatedAt: Date? = nil, mac: MacStatus = .init(), r1: R1Status = .init(), t3: TaskOverview = .init(),
                calendar: CalendarOverview = .init(), latestConversation: ConversationPreview? = nil,
                journal: JournalStatus = .init(), transcribe: TranscribeStatus? = nil, assistant: AssistantStatus? = nil,
                inbox: InboxOverview? = nil) {
        self.generatedAt = generatedAt
        self.mac = mac
        self.r1 = r1
        self.t3 = t3
        self.calendar = calendar
        self.latestConversation = latestConversation
        self.journal = journal
        self.transcribe = transcribe
        self.assistant = assistant
        self.inbox = inbox
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        generatedAt = c.date("generatedAt")
        mac = c.value(MacStatus.self, "mac") ?? .init()
        r1 = c.value(R1Status.self, "r1") ?? .init()
        t3 = c.value(TaskOverview.self, "t3") ?? .init()
        calendar = c.value(CalendarOverview.self, "calendar") ?? .init()
        latestConversation = c.value(ConversationPreview.self, "latestConversation")
        if latestConversation?.conversationId.isEmpty == true { latestConversation = nil }
        journal = c.value(JournalStatus.self, "journal") ?? .init()
        transcribe = c.value(TranscribeStatus.self, "transcribe")
        assistant = c.value(AssistantStatus.self, "assistant")
        inbox = c.value(InboxOverview.self, "inbox")
    }

    /// The next event that has not ended yet.
    public func nextEvent(after now: Date = .now) -> CalendarEvent? {
        calendar.next.first { ($0.endsAt ?? $0.startsAt ?? .distantFuture) > now }
    }
}

/// `summary.mac`
public struct MacStatus: Codable, Sendable, Equatable {
    public var name: String?
    public var online: Bool
    public var screenLocked: Bool?

    public init(name: String? = nil, online: Bool = false, screenLocked: Bool? = nil) {
        self.name = name
        self.online = online
        self.screenLocked = screenLocked
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        name = c.text("name", "computer")
        online = c.bool("online", default: true)
        screenLocked = c.optionalBool("screenLocked")
    }
}

/// `summary.r1`: when the R1 was last heard from and whether a voice conversation is live.
public struct R1Status: Codable, Sendable, Equatable {
    public var lastSeenAt: Date?
    public var live: Bool
    public var liveConversationId: String?
    public var liveTitle: String?

    public init(lastSeenAt: Date? = nil, live: Bool = false, liveConversationId: String? = nil, liveTitle: String? = nil) {
        self.lastSeenAt = lastSeenAt
        self.live = live
        self.liveConversationId = liveConversationId
        self.liveTitle = liveTitle
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        lastSeenAt = c.date("lastSeenAt")
        live = c.bool("live")
        liveConversationId = c.text("liveConversationId")
        liveTitle = c.text("liveTitle")
    }
}

/// `summary.t3`
public struct TaskOverview: Codable, Sendable, Equatable {
    public var available: Bool
    public var needsYou: Int
    public var working: Int
    public var threads: [TaskThread]

    public init(available: Bool = false, needsYou: Int = 0, working: Int = 0, threads: [TaskThread] = []) {
        self.available = available
        self.needsYou = needsYou
        self.working = working
        self.threads = threads
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        available = c.bool("available")
        threads = c.list(TaskThread.self, "threads")
        needsYou = c.optionalInt("needsYou") ?? threads.filter(\.status.needsYou).count
        working = c.optionalInt("working") ?? threads.filter { $0.status == .working }.count
    }
}

/// `summary.calendar`
public struct CalendarOverview: Codable, Sendable, Equatable {
    public var available: Bool
    public var next: [CalendarEvent]

    public init(available: Bool = false, next: [CalendarEvent] = []) {
        self.available = available
        self.next = next
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        available = c.bool("available")
        next = c.list(CalendarEvent.self, "next")
    }
}

/// `summary.latestConversation`
public struct ConversationPreview: Codable, Sendable, Equatable {
    public var conversationId: String
    public var title: String?
    public var lastAt: Date?
    public var preview: String?

    public init(conversationId: String, title: String? = nil, lastAt: Date? = nil, preview: String? = nil) {
        self.conversationId = conversationId
        self.title = title
        self.lastAt = lastAt
        self.preview = preview
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        conversationId = c.text("conversationId", "id") ?? ""
        title = c.text("title")
        lastAt = c.date("lastAt")
        preview = c.text("preview")
    }
}

/// `summary.journal`
public struct JournalStatus: Codable, Sendable, Equatable {
    public var available: Bool

    public init(available: Bool = false) { self.available = available }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        available = c.bool("available")
    }
}
