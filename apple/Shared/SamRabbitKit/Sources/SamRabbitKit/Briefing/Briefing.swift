import Foundation

// The morning brief (CONTRACTS-WAVE8 §A3, §C4): built on the Mac at 06:40 from both mailboxes, today's calendar and
// the agents in the inbox, ready by 7:00. One short headline, then Do first (at most 3), Today (at most 5 events,
// conflicts flagged), Agents (at most 3) and FYI (at most 3); every item has one or two verbs that resolve it with a
// tap (Hark-style): Draft reply (a Gmail DRAFT, never sent), Make task, Block time, Remind me, Open, plus Done and
// Dismiss. `GET /v1/mobile/briefing` is the whole brief; `summary.briefing` says whether there is one and its
// headline, so widgets and complications need no extra call.

/// The brief's four parts, in their order.
public enum BriefingSection: String, Codable, Sendable, CaseIterable, Equatable {
    case doFirst, today, agents, fyi

    public init(raw: String?) {
        switch (raw ?? "").lowercased().replacingOccurrences(of: "-", with: "_") {
        case "today", "calendar", "events", "schedule": self = .today
        case "agents", "agent", "tasks", "inbox": self = .agents
        case "fyi", "info", "later", "worth_knowing": self = .fyi
        default: self = .doFirst
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(raw: try? decoder.singleValueContainer().decode(String.self))
    }

    public var title: String {
        switch self {
        case .doFirst: "Do first"
        case .today: "Today"
        case .agents: "Agents"
        case .fyi: "FYI"
        }
    }

    public var symbol: String {
        switch self {
        case .doFirst: "bolt.fill"
        case .today: "calendar"
        case .agents: "sparkles"
        case .fyi: "info.circle"
        }
    }

    /// The contract's caps.
    public var limit: Int {
        switch self {
        case .doFirst, .agents, .fyi: 3
        case .today: 5
        }
    }
}

/// One verb on an item: the button's words and what `POST …/briefing/items/<id>/act {action}` takes (the bridge's
/// own word, sent back exactly).
public struct BriefingAction: Codable, Sendable, Equatable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable, Equatable, Hashable {
        case draftReply, makeTask, blockTime, remind, done, dismiss, open, agent, other

        public init(raw: String?) {
            switch (raw ?? "").lowercased().replacingOccurrences(of: "-", with: "_") {
            case "draft_reply", "draftreply", "draft", "reply": self = .draftReply
            case "make_task", "maketask", "task", "t3_task", "new_task": self = .makeTask
            case "block_time", "blocktime", "block": self = .blockTime
            case "remind", "remind_me", "reminder", "snooze": self = .remind
            case "done", "complete", "handled": self = .done
            case "dismiss", "hide": self = .dismiss
            case "open", "open_email", "view": self = .open
            case "agent_action", "approve", "answer", "agent": self = .agent
            default: self = .other
            }
        }
    }

    public var kind: Kind
    /// The bridge's word for it.
    public var action: String
    public var label: String
    /// Where Open goes (the Gmail link, with the right account), when the brief carries it.
    public var url: URL?

    public var id: String { action }

    public init(_ kind: Kind, action: String? = nil, label: String? = nil, url: URL? = nil) {
        self.kind = kind
        self.action = action ?? kind.wire
        self.label = label ?? kind.defaultLabel
        self.url = url
    }

    /// A word (`"draft_reply"`) or `{type|action|kind, label, url|link|args.url}`.
    public init(from decoder: Decoder) throws {
        if let word = try? decoder.singleValueContainer().decode(String.self) {
            let action = word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !action.isEmpty else { throw Self.missing(decoder) }
            self.init(Kind(raw: action), action: action)
            return
        }
        let c = try decoder.container(keyedBy: AnyKey.self)
        guard let action = c.text("type", "action", "kind", "id") else { throw Self.missing(decoder) }
        let args = c.json("args")
        let link = c.text("url", "link", "href") ?? args["url"].text
        self.init(Kind(raw: action), action: action, label: c.text("label", "title").map { Formatting.clip($0, 28) },
                  url: link.flatMap(URL.init(string:)).flatMap(Self.webLink))
    }

    private static func missing(_ decoder: Decoder) -> DecodingError {
        .keyNotFound(AnyKey("type"), .init(codingPath: decoder.codingPath, debugDescription: "an action without a type"))
    }

    /// Only http(s) links are opened.
    static func webLink(_ url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", url.host != nil else {
            return nil
        }
        return url
    }

    public var symbol: String {
        switch kind {
        case .draftReply: "arrowshape.turn.up.left.fill"
        case .makeTask: "sparkles"
        case .blockTime: "calendar.badge.clock"
        case .remind: "alarm.fill"
        case .done: "checkmark"
        case .dismiss: "xmark"
        case .open: "arrow.up.right.square"
        case .agent: "hand.raised.fill"
        case .other: "arrow.right.circle"
        }
    }
}

extension BriefingAction.Kind {
    /// The contract's word for it (what is sent when the brief named the verb some other way).
    public var wire: String {
        switch self {
        case .draftReply: "draft_reply"
        case .makeTask: "make_task"
        case .blockTime: "block_time"
        case .remind: "remind"
        case .done: "done"
        case .dismiss: "dismiss"
        case .open: "open"
        case .agent: "agent_action"
        case .other: "other"
        }
    }

    public var defaultLabel: String {
        switch self {
        case .draftReply: "Draft reply"
        case .makeTask: "Make task"
        case .blockTime: "Block time"
        case .remind: "Remind me"
        case .done: "Done"
        case .dismiss: "Dismiss"
        case .open: "Open"
        case .agent: "Open"
        case .other: "Do it"
        }
    }
}

/// One item of the brief.
public struct BriefingItem: Codable, Sendable, Equatable, Identifiable {
    public enum State: String, Codable, Sendable, Equatable {
        case open, drafted, tasked, blocked, snoozed, done, dismissed

        public init(raw: String?) {
            switch (raw ?? "").lowercased() {
            case "drafted", "draft": self = .drafted
            case "tasked", "task": self = .tasked
            case "blocked": self = .blocked
            case "snoozed", "reminded", "remind": self = .snoozed
            case "done", "handled", "complete", "completed": self = .done
            case "dismissed", "hidden": self = .dismissed
            default: self = .open
            }
        }

        public init(from decoder: Decoder) throws {
            self.init(raw: try? decoder.singleValueContainer().decode(String.self))
        }

        /// Gone from the brief (Done, Dismiss).
        public var closed: Bool { self == .done || self == .dismissed }

        /// What the item shows once a verb resolved it.
        public var label: String? {
            switch self {
            case .open: nil
            case .drafted: "Draft saved in Gmail"
            case .tasked: "Task started"
            case .blocked: "Time blocked"
            case .snoozed: "Reminder set"
            case .done: "Done"
            case .dismissed: "Dismissed"
            }
        }
    }

    public var id: String
    public var section: BriefingSection
    /// `email`, `event`, `agent`, `conflict`, `fyi`.
    public var kind: String
    /// An email's mailbox: `business` or `personal` (a small tag).
    public var account: String?
    /// Verb first, at most 60 characters ("Reply to Dana about the SOW").
    public var title: String
    /// Who, what, by when (at most 100 characters).
    public var why: String
    /// A proposal ("Draft a reply confirming Thu 2 pm").
    public var suggestion: String?
    /// Its verbs, as the brief lists them (Done and Dismiss are always offered too: `verbs`).
    public var actions: [BriefingAction]
    public var priority: Int
    public var state: State
    /// Open: the Gmail thread (or the event, the task).
    public var url: URL?
    /// The Gmail draft once Draft reply made one.
    public var draftUrl: URL?
    /// An event's time (Today).
    public var startsAt: Date?
    public var endsAt: Date?
    /// Overlaps another event.
    public var conflict: Bool
    /// The inbox item an Agents row is about (`t3:<id>`, `claude:<id>`).
    public var inboxItemId: String?

    public init(id: String, section: BriefingSection, kind: String = "email", account: String? = nil, title: String,
                why: String = "", suggestion: String? = nil, actions: [BriefingAction] = [], priority: Int = 2,
                state: State = .open, url: URL? = nil, draftUrl: URL? = nil, startsAt: Date? = nil,
                endsAt: Date? = nil, conflict: Bool = false, inboxItemId: String? = nil) {
        self.id = id
        self.section = section
        self.kind = kind
        self.account = account
        self.title = title
        self.why = why
        self.suggestion = suggestion
        self.actions = actions
        self.priority = priority
        self.state = state
        self.url = url
        self.draftUrl = draftUrl
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.conflict = conflict
        self.inboxItemId = inboxItemId
    }

    /// `section` comes from the item or, inside `sections[]`, from its part (`defaultSection`).
    public init(from decoder: Decoder) throws {
        try self.init(from: decoder, defaultSection: nil)
    }

    init(from decoder: Decoder, defaultSection: BriefingSection?) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        guard let id = c.text("id", "itemId") else {
            throw DecodingError.keyNotFound(AnyKey("id"), .init(codingPath: decoder.codingPath,
                                                                debugDescription: "a brief item without an id"))
        }
        self.id = id
        let rawSection = c.text("section", "group")
        section = rawSection.map(BriefingSection.init(raw:)) ?? defaultSection ?? .doFirst
        kind = c.text("kind", "type") ?? Self.defaultKind(section)
        account = c.text("account", "mailbox")
        title = Formatting.clip(c.text("title") ?? "Untitled", 80)
        why = Formatting.clip(c.text("why", "detail", "subtitle") ?? "", 140)
        suggestion = c.text("suggestion").map { Formatting.clip($0, 120) }
        actions = Array(c.list(BriefingAction.self, "actions").prefix(6))
        priority = c.optionalInt("priority") ?? 2
        state = State(raw: c.text("state", "status"))
        url = (c.text("url", "link", "openUrl") ?? c.json("source")["url"].text)
            .flatMap(URL.init(string:)).flatMap(BriefingAction.webLink)
        draftUrl = c.text("draftUrl", "draftLink").flatMap(URL.init(string:)).flatMap(BriefingAction.webLink)
        startsAt = c.date("startsAt", "start", "at")
        endsAt = c.date("endsAt", "end")
        conflict = c.bool("conflict")
        inboxItemId = c.text("inboxItemId") ?? c.json("source")["itemId"].text
    }

    /// What an item of `section` is when it doesn't say.
    static func defaultKind(_ section: BriefingSection) -> String {
        switch section {
        case .today: "event"
        case .agents: "agent"
        case .fyi: "fyi"
        case .doFirst: "email"
        }
    }

    /// The buttons it shows: its own verbs (Done and Dismiss aside), at most two, then Done and Dismiss.
    public var verbs: [BriefingAction] {
        var seen = Set<String>()
        let primary = actions.filter { $0.kind != .done && $0.kind != .dismiss && seen.insert($0.action).inserted }
        return Array(primary.prefix(2))
    }

    /// Where Open goes: its own link, else the Open verb's.
    public var openURL: URL? { url ?? actions.first { $0.kind == .open }?.url }

    /// A mailbox tag ("Personal"), shown only for the personal one (business is the default).
    public var accountTag: String? {
        guard let account, !account.isEmpty else { return nil }
        let word = account.lowercased()
        if word.contains("personal") || word.contains("gmail.com") { return "Personal" }
        return nil
    }
}

/// What a tap on a verb did (`POST …/act`): the item's new state, and the link it made (a Gmail draft, with the
/// right account) or opened.
public struct BriefingActResult: Codable, Sendable, Equatable {
    public var ok: Bool
    public var state: BriefingItem.State?
    public var url: URL?
    public var message: String?
    public var threadId: String?
    public var eventId: String?
    public var until: Date?

    public init(ok: Bool = true, state: BriefingItem.State? = nil, url: URL? = nil, message: String? = nil,
                threadId: String? = nil, eventId: String? = nil, until: Date? = nil) {
        self.ok = ok
        self.state = state
        self.url = url
        self.message = message
        self.threadId = threadId
        self.eventId = eventId
        self.until = until
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        let result = c.json("result")
        ok = c.optionalBool("ok") ?? true
        state = (c.text("state") ?? result["state"].text).map(BriefingItem.State.init(raw:))
        url = (c.text("url", "draftUrl", "link") ?? result["url"].text ?? result["draftUrl"].text)
            .flatMap(URL.init(string:)).flatMap(BriefingAction.webLink)
        message = c.text("message", "say") ?? result["message"].text
        threadId = c.text("threadId") ?? result["threadId"].text ?? result["itemId"].text
        eventId = c.text("eventId") ?? result["eventId"].text
        until = c.date("until") ?? result["until"].date
    }
}

/// `GET /v1/mobile/briefing`: today's brief. Lenient like every payload: the parts come as `sections: [{kind,
/// items}]`, as items that name their `section`, or as `doFirst` / `today` / `agents` / `fyi` lists; the whole may be
/// wrapped in `{available, status, briefing: {...}}`.
public struct Briefing: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable, Equatable {
        case ready, building, stale, failed, off, none

        public init(raw: String?) {
            switch (raw ?? "").lowercased() {
            case "ready", "ok", "done": self = .ready
            case "building", "pending", "refreshing": self = .building
            case "stale": self = .stale
            case "failed", "error": self = .failed
            case "off", "disabled": self = .off
            case "none", "missing", "empty": self = .none
            default: self = .ready
            }
        }

        public init(from decoder: Decoder) throws {
            self.init(raw: try? decoder.singleValueContainer().decode(String.self))
        }
    }

    public var available: Bool
    /// The local day it is for (`2026-10-14`).
    public var date: String?
    public var revision: Int64
    public var status: Status
    /// At most 90 characters: "3 things need you · 4 meetings, first at 10:00".
    public var headline: String
    /// At most 400 characters, for reading it out (only when asked).
    public var spoken: String?
    public var updatedAt: Date?
    /// Every item, in the parts' order (Do first, Today, Agents, FYI).
    public var items: [BriefingItem]
    /// "Skipped 182 promos and newsletters."
    public var footer: String?
    /// Why there is none (`not_built_yet`, `composio_signed_out`, ...).
    public var reason: String?

    public init(available: Bool = true, date: String? = nil, revision: Int64 = 0, status: Status = .ready,
                headline: String = "", spoken: String? = nil, updatedAt: Date? = nil, items: [BriefingItem] = [],
                footer: String? = nil, reason: String? = nil) {
        self.available = available
        self.date = date
        self.revision = revision
        self.status = status
        self.headline = headline
        self.spoken = spoken
        self.updatedAt = updatedAt
        self.items = Self.ordered(items)
        self.footer = footer
        self.reason = reason
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        let outerAvailable = c.optionalBool("available")
        let outerStatus = c.text("status")
        if c.contains(AnyKey("briefing")), var inner = c.value(Briefing.self, "briefing") {
            if let outerAvailable { inner.available = outerAvailable && inner.available }
            if let outerStatus, c.json("briefing")["status"].isNull { inner.status = Status(raw: outerStatus) }
            self = inner
            return
        }
        date = c.text("date", "day")
        revision = c.int64("revision")
        status = Status(raw: outerStatus)
        headline = Formatting.clip(c.text("headline", "title") ?? "", 120)
        spoken = c.text("spoken", "say")
        updatedAt = c.date("updatedAt", "builtAt", "generatedAt")
        footer = c.text("footer", "skipped")
        reason = c.text("reason")
        var collected: [BriefingItem] = []
        for part in c.list(BriefingPart.self, "sections") { collected += part.items }
        collected += c.list(BriefingItem.self, "items")
        for (key, section) in [("doFirst", BriefingSection.doFirst), ("do_first", .doFirst), ("today", .today),
                               ("agents", .agents), ("fyi", .fyi)] {
            collected += c.list(SectionedItem.self, key).map { $0.item(in: section) }
        }
        var seen = Set<String>()
        items = Self.ordered(collected.filter { seen.insert($0.id).inserted })
        available = outerAvailable ?? (date != nil || !items.isEmpty)
    }

    /// By part, then as the brief listed them; each part at its cap.
    static func ordered(_ items: [BriefingItem]) -> [BriefingItem] {
        BriefingSection.allCases.flatMap { section in
            items.filter { $0.section == section }.prefix(section.limit)
        }
    }

    /// The items of one part that are still in the brief (not Done or dismissed).
    public func items(in section: BriefingSection) -> [BriefingItem] {
        items.filter { $0.section == section && !$0.state.closed }
    }

    /// The items still in the brief.
    public var shown: [BriefingItem] { items.filter { !$0.state.closed } }

    /// What still waits for him: the open items of Do first and Agents (events just happen, FYI asks nothing).
    public var toDo: Int { items.filter { ($0.section == .doFirst || $0.section == .agents) && $0.state == .open }.count }

    /// It is today's brief (`date` is the local day of `now`; a brief without a date counts as today's).
    public func isToday(now: Date = .now, calendar: Calendar = .current) -> Bool {
        guard let date else { return true }
        return date == BriefingClock.day(of: now, calendar: calendar)
    }

    /// Home shows it at the top: today's, before noon (`allDay` lifts that, for tests), with something left in it.
    public func showsOnHome(now: Date = .now, calendar: Calendar = .current, allDay: Bool = false) -> Bool {
        available && status != .off && isToday(now: now, calendar: calendar)
            && (allDay || BriefingClock.isMorning(now, calendar: calendar)) && !shown.isEmpty
    }

    /// The item with `id` in a new state (after a tap; the Mac's next answer confirms).
    public func with(_ id: String, state: BriefingItem.State, draftUrl: URL? = nil) -> Briefing {
        var copy = self
        if let index = copy.items.firstIndex(where: { $0.id == id }) {
            copy.items[index].state = state
            if let draftUrl { copy.items[index].draftUrl = draftUrl }
        }
        return copy
    }

    /// What the summary carries for the widgets (the headline, the count and the first open items).
    public func overview(top: Int = 4) -> BriefingOverview {
        BriefingOverview(available: available, date: date, status: status, revision: revision, headline: headline,
                         needsYou: toDo, updatedAt: updatedAt,
                         items: Array(shown.filter { $0.section != .today }.prefix(top)))
    }

    /// Says something the shown brief doesn't (a later revision, or another day).
    public func isNewer(than current: Briefing?) -> Bool {
        guard let current else { return true }
        return revision > current.revision || date != current.date
    }
}

/// `sections[]`: `{kind|id|section, title?, items: [...]}`.
private struct BriefingPart: Decodable {
    var items: [BriefingItem]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        let section = BriefingSection(raw: c.text("kind", "id", "section", "name", "title"))
        items = c.list(SectionedItem.self, "items").map { $0.item(in: section) }
    }
}

/// An item inside a part: its own `section` if it names one, else the part's.
private struct SectionedItem: Decodable {
    var decoded: BriefingItem
    var named: Bool
    var kindNamed: Bool

    init(from decoder: Decoder) throws {
        decoded = try BriefingItem(from: decoder, defaultSection: nil)
        let c = try decoder.container(keyedBy: AnyKey.self)
        named = c.text("section", "group") != nil
        kindNamed = c.text("kind", "type") != nil
    }

    func item(in section: BriefingSection) -> BriefingItem {
        guard !named else { return decoded }
        var item = decoded
        item.section = section
        if !kindNamed { item.kind = BriefingItem.defaultKind(section) }
        return item
    }
}

/// `summary.briefing`: whether today's brief is there, its headline and how much of it waits for him. The iPhone
/// adds the first open items from `/v1/mobile/briefing` (`Briefing.overview`), so the widgets draw them without a
/// call of their own.
public struct BriefingOverview: Codable, Sendable, Equatable {
    public var available: Bool
    public var date: String?
    public var status: Briefing.Status
    public var revision: Int64
    public var headline: String
    public var needsYou: Int
    public var updatedAt: Date?
    /// The first open items (Do first, Agents, FYI), added by the iPhone; empty from the bridge.
    public var items: [BriefingItem]

    public init(available: Bool = false, date: String? = nil, status: Briefing.Status = .none, revision: Int64 = 0,
                headline: String = "", needsYou: Int = 0, updatedAt: Date? = nil, items: [BriefingItem] = []) {
        self.available = available
        self.date = date
        self.status = status
        self.revision = revision
        self.headline = headline
        self.needsYou = needsYou
        self.updatedAt = updatedAt
        self.items = items
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        available = c.bool("available")
        date = c.text("date", "day")
        status = Briefing.Status(raw: c.text("status"))
        revision = c.int64("revision")
        headline = Formatting.clip(c.text("headline") ?? "", 120)
        needsYou = c.optionalInt("needsYou") ?? c.optionalInt("toDo") ?? 0
        updatedAt = c.date("updatedAt", "builtAt")
        items = Array(c.list(BriefingItem.self, "items").prefix(6))
    }

    /// It is today's (see `Briefing.isToday`).
    public func isToday(now: Date = .now, calendar: Calendar = .current) -> Bool {
        guard let date else { return available }
        return date == BriefingClock.day(of: now, calendar: calendar)
    }

    /// A brief for today exists and has something in it (the widgets, the complication, the watch's page).
    public func current(now: Date = .now, calendar: Calendar = .current) -> Bool {
        available && status != .off && isToday(now: now, calendar: calendar)
    }

    /// "3 to do" / "All done".
    public var countLine: String {
        needsYou == 0 ? "All done" : "\(needsYou) to do"
    }
}

extension MobileSummary {
    /// The summary with the brief's first open items in `briefing` (the iPhone's own call to
    /// `/v1/mobile/briefing`). A brief that isn't there leaves the bridge's part as it was; when the call failed, the
    /// items kept last (`kept`) stay while the bridge still reports that same brief.
    public func with(briefing result: Result<Briefing, BridgeError>?, kept: BriefingOverview?) -> MobileSummary {
        var copy = self
        switch result {
        case .success(let fetched) where fetched.available:
            copy.briefing = fetched.overview()
        case .success, nil:
            break
        case .failure:
            guard var part = briefing, let kept, kept.date == part.date, kept.revision == part.revision else { break }
            part.items = kept.items
            copy.briefing = part
        }
        return copy
    }
}

/// When the brief is shown: the local day and the morning.
public enum BriefingClock {
    /// `2026-10-14` in `calendar`'s time zone.
    public static func day(of date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Before noon.
    public static func isMorning(_ date: Date, calendar: Calendar = .current) -> Bool {
        calendar.component(.hour, from: date) < 12
    }
}
