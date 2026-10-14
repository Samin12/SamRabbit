import Foundation

// The Agent Dock's view of the bridge inbox (`GET /v1/desktop/inbox`, CONTRACTS-WAVE6 §A): every agent thread
// that may want Samin (T3 Code threads, Claude Code and Codex sessions) and the recent SamRabbit chats.
// Pure data and rules, no AppKit: tests/swift compiles this file on its own to check decoding, order and sections.

enum DockStatus: String {
    case needsApproval = "needs-approval"
    case needsInput = "needs-input"
    case error
    case done
    case working
    case idle
}

struct DockApprovalOption: Equatable, Decodable {
    let decision: String
    let label: String
}

struct DockApproval: Equatable, Decodable {
    let requestId: String
    let kind: String
    let detail: String
    let options: [DockApprovalOption]

    private enum CodingKeys: String, CodingKey { case requestId, kind, detail, options }

    init(requestId: String, kind: String, detail: String, options: [DockApprovalOption]) {
        self.requestId = requestId
        self.kind = kind
        self.detail = detail
        self.options = options
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requestId = try c.decode(String.self, forKey: .requestId)
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? "approval"
        detail = (try? c.decodeIfPresent(String.self, forKey: .detail)) ?? ""
        let decoded = (try? c.decodeIfPresent([DockLossy<DockApprovalOption>].self, forKey: .options))
        let options = decoded?.compactMap(\.value) ?? []
        // A request without its choices still has to be answerable.
        self.options = options.isEmpty
            ? [DockApprovalOption(decision: "accept", label: "Approve"), DockApprovalOption(decision: "decline", label: "Deny")]
            : options
    }

    /// The option E (and the accent button) stands for: "accept" when offered, else the first one that is not a
    /// refusal, else the first.
    var recommended: DockApprovalOption? {
        let refusals: Set<String> = ["decline", "deny", "reject", "cancel", "abort"]
        return options.first { $0.decision == "accept" }
            ?? options.first { !refusals.contains($0.decision.lowercased()) }
            ?? options.first
    }

    /// One short line for the card header: "Wants to run a command".
    var kindLabel: String {
        switch kind.lowercased() {
        case "command", "exec", "shell", "command_execution": return "Wants to run a command"
        case "file_change", "edit", "patch", "apply_patch", "file": return "Wants to change files"
        case "network": return "Wants network access"
        case "tool", "mcp": return "Wants to use a tool"
        default: return "Wants your approval"
        }
    }
}

struct DockQuestion: Equatable, Decodable {
    let id: String
    let header: String
    let question: String
    let options: [String]
    let allowCustom: Bool
    let multiSelect: Bool

    private enum CodingKeys: String, CodingKey { case id, header, question, options, allowCustom, multiSelect }

    init(id: String, header: String, question: String, options: [String], allowCustom: Bool, multiSelect: Bool) {
        self.id = id
        self.header = header
        self.question = question
        self.options = options
        self.allowCustom = allowCustom
        self.multiSelect = multiSelect
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        header = (try? c.decodeIfPresent(String.self, forKey: .header)) ?? ""
        question = (try? c.decodeIfPresent(String.self, forKey: .question)) ?? ""
        options = (try? c.decodeIfPresent([String].self, forKey: .options)) ?? []
        allowCustom = (try? c.decodeIfPresent(Bool.self, forKey: .allowCustom)) ?? options.isEmpty
        multiSelect = (try? c.decodeIfPresent(Bool.self, forKey: .multiSelect)) ?? false
    }
}

struct DockInputRequest: Equatable, Decodable {
    let requestId: String
    let questions: [DockQuestion]

    private enum CodingKeys: String, CodingKey { case requestId, questions }

    init(requestId: String, questions: [DockQuestion]) {
        self.requestId = requestId
        self.questions = questions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requestId = try c.decode(String.self, forKey: .requestId)
        let decoded = (try? c.decodeIfPresent([DockLossy<DockQuestion>].self, forKey: .questions))
        questions = decoded?.compactMap(\.value) ?? []
    }
}

struct DockPending: Equatable, Decodable {
    var approvals: [DockApproval] = []
    var inputs: [DockInputRequest] = []

    private enum CodingKeys: String, CodingKey { case approvals, inputs }

    init(approvals: [DockApproval] = [], inputs: [DockInputRequest] = []) {
        self.approvals = approvals
        self.inputs = inputs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        approvals = (try? c.decodeIfPresent([DockLossy<DockApproval>].self, forKey: .approvals))?.compactMap(\.value) ?? []
        inputs = (try? c.decodeIfPresent([DockLossy<DockInputRequest>].self, forKey: .inputs))?.compactMap(\.value) ?? []
    }

    var isEmpty: Bool { approvals.isEmpty && inputs.isEmpty }
}

/// One `InboxItem`. Decoding is forgiving: a missing or odd field takes its default rather than dropping the item,
/// an unknown status reads as idle, unknown capabilities are kept (and ignored by the UI).
struct DockItem: Identifiable, Equatable, Decodable {
    var id: String
    var source: String
    var agent: String?
    var title: String
    var project: String?
    var cwd: String?
    var status: DockStatus
    var statusLabel: String
    var summary: String
    var updatedAt: Date?
    var unread: Bool
    var pending: DockPending
    var can: [String]
    var live: Bool
    var progress: Double?
    var phase: String?

    private enum CodingKeys: String, CodingKey {
        case id, source, agent, title, project, cwd, status, statusLabel, summary, updatedAt, unread, pending, can, live,
             progress, phase
    }

    init(id: String, source: String, agent: String? = nil, title: String, project: String? = nil, cwd: String? = nil,
         status: DockStatus, statusLabel: String = "", summary: String = "", updatedAt: Date? = nil, unread: Bool = false,
         pending: DockPending = DockPending(), can: [String] = [], live: Bool = false, progress: Double? = nil,
         phase: String? = nil) {
        self.id = id
        self.source = source
        self.agent = agent
        self.title = title
        self.project = project
        self.cwd = cwd
        self.status = status
        self.statusLabel = statusLabel
        self.summary = summary
        self.updatedAt = updatedAt
        self.unread = unread
        self.pending = pending
        self.can = can
        self.live = live
        self.progress = progress
        self.phase = phase
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) -> String? {
            guard let value = (try? c.decodeIfPresent(String.self, forKey: key)) else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let id = text(.id) else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "inbox item without an id")
        }
        self.id = id
        source = text(.source) ?? String(id.split(separator: ":").first ?? "")
        agent = text(.agent)
        title = DockText.oneLine(text(.title) ?? "Untitled")
        project = text(.project)
        cwd = text(.cwd)
        status = text(.status).flatMap(DockStatus.init(rawValue:)) ?? .idle
        statusLabel = DockText.oneLine(text(.statusLabel) ?? "")
        summary = text(.summary) ?? ""
        updatedAt = DockDate.parse(c, .updatedAt)
        unread = (try? c.decodeIfPresent(Bool.self, forKey: .unread)) ?? false
        pending = (try? c.decodeIfPresent(DockPending.self, forKey: .pending)) ?? DockPending()
        can = (try? c.decodeIfPresent([String].self, forKey: .can)) ?? []
        live = (try? c.decodeIfPresent(Bool.self, forKey: .live)) ?? false
        progress = (try? c.decodeIfPresent(Double.self, forKey: .progress))
        phase = text(.phase)
    }

    func supports(_ capability: String) -> Bool { can.contains(capability) }

    /// The item once seen, as the bridge says it next (Mark seen's instant result): not unread, no `seen`, and a
    /// failure settled (idle, its label still saying it failed; out of Needs you until it fails again), whoever runs it.
    var markedSeen: DockItem {
        var seen = self
        seen.unread = false
        seen.can.removeAll { $0 == "seen" }
        if seen.status == .error { seen.status = .idle }
        return seen
    }

    /// "Needs you": waiting on an approval or an answer, failed, or finished and not yet seen.
    var needsYou: Bool {
        switch status {
        case .needsApproval, .needsInput, .error: return true
        case .done: return unread
        case .working, .idle: return false
        }
    }

    var isChat: Bool { source == "samrabbit" }

    /// The contract's order: needs-approval, needs-input, error, done (unread), working, then everything else.
    var rank: Int {
        switch status {
        case .needsApproval: return 0
        case .needsInput: return 1
        case .error: return 2
        case .done: return unread ? 3 : 5
        case .working: return 4
        case .idle: return 5
        }
    }

    /// Who runs it, for the meta line: "Claude", "Codex", or nil for chats.
    var agentLabel: String? {
        switch (agent ?? (source == "claude" || source == "codex" ? source : "")).lowercased() {
        case "claude": return "Claude"
        case "codex": return "Codex"
        default: return nil
        }
    }

    /// The first approval, used by E and the row's accent button.
    var firstApproval: DockApproval? { pending.approvals.first }
}

struct DockCounts: Equatable, Decodable {
    var needsYou = 0
    var working = 0
    var total = 0
}

struct DockSourceState: Equatable, Decodable {
    var connected: Bool?
    var available: Bool?
    var reason: String?

    /// T3 says connected, the others say available.
    var ok: Bool { connected ?? available ?? true }
}

/// One answer of `GET /v1/desktop/inbox`.
struct DockInbox: Equatable {
    var revision: Int
    var updatedAt: Date?
    var counts: DockCounts
    var sources: [String: DockSourceState]
    var items: [DockItem]

    static let empty = DockInbox(revision: 0, updatedAt: nil, counts: DockCounts(), sources: [:], items: [])

    /// The bridge caps the list at 60; a misbehaving one must not make the dock draw thousands of rows.
    static let itemCap = 60

    static func decode(_ data: Data) throws -> DockInbox {
        let wire = try JSONDecoder().decode(Wire.self, from: data)
        let items = DockOrder.sorted(Array((wire.items ?? []).compactMap(\.value).prefix(itemCap)))
        let computed = DockCounts(needsYou: items.filter(\.needsYou).count,
                                  working: items.filter { $0.status == .working && !$0.isChat }.count,
                                  total: items.count)
        return DockInbox(revision: wire.revision ?? 0, updatedAt: wire.updatedAt.flatMap(DockDate.parse),
                         counts: wire.counts ?? computed, sources: wire.sources ?? [:], items: items)
    }

    private struct Wire: Decodable {
        let revision: Int?
        let updatedAt: String?
        let counts: DockCounts?
        let sources: [String: DockSourceState]?
        let items: [DockLossy<DockItem>]?

        private enum CodingKeys: String, CodingKey { case revision, updatedAt, counts, sources, items }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            revision = (try? c.decodeIfPresent(Int.self, forKey: .revision))
            updatedAt = (try? c.decodeIfPresent(String.self, forKey: .updatedAt))
            counts = (try? c.decodeIfPresent(DockCounts.self, forKey: .counts))
            sources = (try? c.decodeIfPresent([String: DockSourceState].self, forKey: .sources))
            items = try c.decodeIfPresent([DockLossy<DockItem>].self, forKey: .items)
        }
    }

    var t3Connected: Bool { sources["t3"]?.ok ?? true }

    /// What the pill and the list header say: counted from the dock's own rows (`items`: this answer with any action's
    /// optimistic result and new tasks still on their way), like the sections, so "1 working" never sits over an empty
    /// Working section. A SamRabbit chat streaming a reply is not an agent at work, though the bridge's
    /// `counts.working` includes it. The bridge's counts only add what lies past its 60-item cap.
    func shownCounts(items: [DockItem]) -> DockShownCounts {
        let needsYou = items.filter(\.needsYou).count
        let working = items.filter { $0.status == .working && !$0.isChat }.count
        guard counts.total > self.items.count else { return DockShownCounts(needsYou: needsYou, working: working) }
        // Everything working in the list (chats too) comes off the bridge's count, whichever way it counted chats.
        let moreNeeds = max(0, counts.needsYou - self.items.filter(\.needsYou).count)
        let moreWorking = max(0, counts.working - self.items.filter { $0.status == .working }.count)
        return DockShownCounts(needsYou: needsYou + moreNeeds, working: working + moreWorking)
    }
}

struct DockShownCounts: Equatable {
    var needsYou: Int
    var working: Int
}

struct DockMessage: Equatable, Decodable, Identifiable {
    var role: String
    var text: String
    var at: Date?
    var id: String { "\(role)-\(at?.timeIntervalSince1970 ?? 0)-\(text.prefix(24))" }

    private enum CodingKeys: String, CodingKey { case role, text, at }

    init(role: String, text: String, at: Date? = nil) {
        self.role = role
        self.text = text
        self.at = at
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = (try? c.decodeIfPresent(String.self, forKey: .role)) ?? "assistant"
        text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? ""
        at = DockDate.parse(c, .at)
    }

    var isUser: Bool { role == "user" }
}

/// `GET /v1/desktop/inbox/items/<id>`: the item and its last messages.
struct DockItemDetail: Equatable, Decodable {
    var item: DockItem
    var messages: [DockMessage]

    private enum CodingKeys: String, CodingKey { case item, messages }

    init(item: DockItem, messages: [DockMessage]) {
        self.item = item
        self.messages = messages
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        item = try c.decode(DockItem.self, forKey: .item)
        let decoded = (try? c.decodeIfPresent([DockLossy<DockMessage>].self, forKey: .messages))
        messages = Array((decoded?.compactMap(\.value) ?? []).filter { !$0.text.isEmpty }.suffix(12))
    }
}

/// `GET /v1/desktop/inbox/targets`: where a new prompt can go.
struct DockTargets: Equatable, Decodable {
    struct Project: Equatable, Decodable, Identifiable {
        let id: String
        let title: String
        let lastActiveAt: String?
    }

    struct Model: Equatable, Decodable, Identifiable {
        let id: String
        let label: String
    }

    struct Agent: Equatable, Decodable, Identifiable {
        let id: String
        let label: String
        let models: [Model]
    }

    struct Choice: Equatable, Decodable {
        var projectId: String?
        var agent: String?
        var model: String?
    }

    var projects: [Project]
    var agents: [Agent]
    var defaults: Choice

    private enum CodingKeys: String, CodingKey {
        case projects, agents
        case defaults = "default"
    }

    init(projects: [Project], agents: [Agent], defaults: Choice) {
        self.projects = projects
        self.agents = agents
        self.defaults = defaults
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projects = (try? c.decodeIfPresent([DockLossy<Project>].self, forKey: .projects))?.compactMap(\.value) ?? []
        agents = (try? c.decodeIfPresent([DockLossy<Agent>].self, forKey: .agents))?.compactMap(\.value) ?? []
        defaults = (try? c.decodeIfPresent(Choice.self, forKey: .defaults)) ?? Choice()
    }

    /// A complete, valid choice: what was picked when it still exists, else the bridge's default, else the first.
    /// A model always belongs to the chosen agent.
    func resolve(_ picked: Choice) -> Choice {
        let projectIds = Set(projects.map(\.id))
        let projectId = [picked.projectId, defaults.projectId].compactMap { $0 }.first { projectIds.contains($0) }
            ?? projects.first?.id
        let agent = [picked.agent, defaults.agent].compactMap { $0 }.compactMap { id in agents.first { $0.id == id } }.first
            ?? agents.first
        let modelIds = Set(agent?.models.map(\.id) ?? [])
        let model = [picked.model, defaults.model].compactMap { $0 }.first { modelIds.contains($0) } ?? agent?.models.first?.id
        return Choice(projectId: projectId, agent: agent?.id, model: model)
    }

    func project(_ id: String?) -> Project? { projects.first { $0.id == id } }
    func agent(_ id: String?) -> Agent? { agents.first { $0.id == id } }
    func model(_ id: String?, agent agentId: String?) -> Model? { agent(agentId)?.models.first { $0.id == id } }
}

// MARK: order and sections

enum DockOrder {
    /// needs-approval, needs-input, error, done (unread), working, then the rest, each newest first (id breaks ties so
    /// the order never flickers between two answers with equal times).
    static func sorted(_ items: [DockItem]) -> [DockItem] {
        items.sorted { a, b in
            if a.rank != b.rank { return a.rank < b.rank }
            let ta = a.updatedAt ?? .distantPast
            let tb = b.updatedAt ?? .distantPast
            if ta != tb { return ta > tb }
            return a.id < b.id
        }
    }
}

struct DockSection: Equatable, Identifiable {
    enum Kind: String {
        case needsYou, working, chats, earlier
    }

    let kind: Kind
    let items: [DockItem]
    var id: String { kind.rawValue }

    var title: String {
        switch kind {
        case .needsYou: return "Needs you"
        case .working: return "Working"
        case .chats: return "Recent chats"
        case .earlier: return "Earlier"
        }
    }

    /// The expanded panel's sections: Needs you, Working (agents), Recent chats (SamRabbit, newest first, at most 6),
    /// and Earlier (finished and idle agent threads; folded unless opened). Empty sections are left out.
    static func build(_ items: [DockItem]) -> [DockSection] {
        let sorted = DockOrder.sorted(items)
        let byTime: (DockItem, DockItem) -> Bool = { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
        let needs = sorted.filter(\.needsYou)
        let working = sorted.filter { !$0.needsYou && !$0.isChat && $0.status == .working }
        let chats = Array(sorted.filter { !$0.needsYou && $0.isChat }.sorted(by: byTime).prefix(6))
        let earlier = sorted.filter { !$0.needsYou && !$0.isChat && $0.status != .working }.sorted(by: byTime)
        return [DockSection(kind: .needsYou, items: needs), DockSection(kind: .working, items: working),
                DockSection(kind: .chats, items: chats), DockSection(kind: .earlier, items: earlier)]
            .filter { !$0.items.isEmpty }
    }

    /// The rows as drawn, top to bottom (what J/K walk through).
    static func visibleIds(_ sections: [DockSection], earlierOpen: Bool) -> [String] {
        sections.flatMap { section -> [String] in
            section.kind == .earlier && !earlierOpen ? [] : section.items.map(\.id)
        }
    }
}

// MARK: answers to questions

enum DockAnswers {
    /// The value for one question: a list for multi-select, else one string. The typed answer wins over the chips
    /// for single-select; for multi-select it is added to them. nil until something is chosen.
    static func value(for question: DockQuestion, selected: [String], custom: String) -> Any? {
        let typed = custom.trimmingCharacters(in: .whitespacesAndNewlines)
        let chosen = question.options.filter { selected.contains($0) }
        if question.multiSelect {
            let all = chosen + (typed.isEmpty || !question.allowCustom ? [] : [typed])
            return all.isEmpty ? nil : all
        }
        if question.allowCustom, !typed.isEmpty { return typed }
        return chosen.first
    }

    /// `{questionId: str|[str]}` when every question has an answer, else nil.
    static func build(_ request: DockInputRequest, selected: [String: [String]], custom: [String: String]) -> [String: Any]? {
        var answers: [String: Any] = [:]
        for question in request.questions {
            guard let value = value(for: question, selected: selected[question.id] ?? [], custom: custom[question.id] ?? "") else {
                return nil
            }
            answers[question.id] = value
        }
        return answers.isEmpty ? nil : answers
    }

    /// One tap answers it: a single question, single choice, nothing to type.
    static func answersOnTap(_ request: DockInputRequest) -> Bool {
        request.questions.count == 1 && !(request.questions[0].multiSelect) && !(request.questions[0].allowCustom)
            && !request.questions[0].options.isEmpty
    }
}

// MARK: notifications

/// Which needs-you items deserve a notification: each item once when it starts needing Samin (an approval request,
/// a question, a failure, a finish), not again while it keeps needing him. Once it has stopped needing him for a while
/// (`settle`) the same need is news again: a T3 thread that finishes, gets a reply, works and finishes again announces
/// both finishes. T3 reports its own state, so any calm counts; the Claude Code and Codex statuses are read from their
/// session files and can flap between working and waiting, so there the need must have been gone for a minute, and a
/// need that keeps flapping back is announced at most once per `cooldown`. A different need (a new request id,
/// another status) is always news.
struct DockAttention: Equatable {
    struct Announced: Equatable {
        var key: String
        var at: Date
    }

    var active: Set<String> = []
    var announced: [String: Announced] = [:]
    /// Since when an announced item has not been needing Samin with its announced need.
    var calmSince: [String: Date] = [:]
    var primed = false
    static let cooldown: TimeInterval = 10 * 60

    static func key(_ item: DockItem) -> String {
        let requests = (item.pending.approvals.map(\.requestId) + item.pending.inputs.map(\.requestId)).joined(separator: ",")
        return "\(item.id)|\(item.status.rawValue)|\(requests)"
    }

    /// How long the need must have been gone before the same one is announced again.
    static func settle(_ item: DockItem) -> TimeInterval {
        item.source == "t3" ? 0 : 60
    }

    /// The items to announce now. The first answer after launch only sets the baseline.
    mutating func update(_ items: [DockItem], now: Date) -> [DockItem] {
        let needing = items.filter(\.needsYou)
        let keys = Set(needing.map(Self.key))
        defer {
            active = keys
            for (id, last) in announced where !keys.contains(last.key) && calmSince[id] == nil { calmSince[id] = now }
            announced = announced.filter { now.timeIntervalSince($0.value.at) < Self.cooldown * 3 }
            calmSince = calmSince.filter { announced[$0.key] != nil }
        }
        guard primed else {
            primed = true
            for item in needing { announced[item.id] = Announced(key: Self.key(item), at: now) }
            return []
        }
        var announce: [DockItem] = []
        for item in needing {
            let key = Self.key(item)
            guard !active.contains(key) else { continue }
            if let last = announced[item.id], last.key == key {
                let settled = calmSince[item.id].map { now.timeIntervalSince($0) >= Self.settle(item) } ?? false
                calmSince[item.id] = nil
                if !settled && now.timeIntervalSince(last.at) < Self.cooldown { continue }
            }
            announced[item.id] = Announced(key: key, at: now)
            calmSince[item.id] = nil
            announce.append(item)
        }
        return announce
    }
}

// MARK: text and time

enum DockText {
    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: { $0.isNewline || $0 == "\t" }).joined(separator: " ")
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    static func clip(_ text: String, _ max: Int) -> String {
        let flat = oneLine(text)
        return flat.count > max ? String(flat.prefix(max - 1)) + "…" : flat
    }

    /// "SamRabbit · Wants to run a command": the parts that exist, joined.
    static func meta(_ parts: String?...) -> String {
        parts.compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

enum DockTime {
    /// "now", "4m", "2h", "3d", then "Oct 2".
    static func short(_ date: Date?, now: Date) -> String {
        guard let date else { return "" }
        let seconds = now.timeIntervalSince(date)
        if seconds < 45 { return "now" }
        if seconds < 3600 { return "\(max(1, Int((seconds / 60).rounded())))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h" }
        if seconds < 7 * 86_400 { return "\(Int(seconds / 86_400))d" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }
}

enum DockDate {
    static func parse(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let number = Double(trimmed) { return Date(timeIntervalSince1970: number > 1e11 ? number / 1000 : number) }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: trimmed) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: trimmed)
    }

    static func parse<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) -> Date? {
        if let text = (try? container.decodeIfPresent(String.self, forKey: key)) { return parse(text) }
        if let number = (try? container.decodeIfPresent(Double.self, forKey: key)) {
            return Date(timeIntervalSince1970: number > 1e11 ? number / 1000 : number)
        }
        return nil
    }
}

/// Decodes an element or nothing, so one malformed entry never empties a whole list.
struct DockLossy<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

// MARK: dev

/// DEV ONLY: whether the dock's smoke driver (`SAMRABBIT_DOCK_SMOKE`) may run against this bridge address. It approves
/// a waiting request and starts a new T3 task, so it runs only against `dev/fake_sync_server.py`: never the default
/// address (the live bridge) or port 3780, and (checked next, over HTTP) only when the server says it is the fake.
enum DockSmokeGuard {
    static let liveBridgePort = 3780

    /// nil = allowed; else why not.
    static func refusal(base: URL, isDefaultBase: Bool) -> String? {
        if isDefaultBase { return "the app points at the default bridge address" }
        guard let port = base.port else { return "the bridge address has no port" }
        if port == liveBridgePort { return "port \(liveBridgePort) is the live bridge's" }
        guard let host = base.host, ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host) else { return "not a loopback address" }
        return nil
    }

    /// The installed app's bundle id: its settings are Samin's own (where his dock is, the orb, ⌃⌥D's hide).
    static let installedBundleId = "com.samrabbit.desktop"

    /// The places smoke moves the dock, folds it and hides it, so it saves those settings as it goes (and puts them
    /// back at the end): never in the installed app's settings, only a development copy's (build.sh --bundle-id).
    static func placesRefusal(base: URL, isDefaultBase: Bool, bundleId: String?) -> String? {
        if let reason = refusal(base: base, isDefaultBase: isDefaultBase) { return reason }
        guard let bundleId, !bundleId.isEmpty else { return "no bundle id" }
        if bundleId == installedBundleId { return "\(installedBundleId) is the installed app's: build a copy with --bundle-id" }
        return nil
    }
}
