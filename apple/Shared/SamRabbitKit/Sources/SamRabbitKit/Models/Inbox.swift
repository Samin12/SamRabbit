import Foundation

// The Mac's inbox (`GET /v1/mobile/inbox`, CONTRACTS-WAVE6 §A, the mobile twin of the Agent Dock's
// `/v1/desktop/inbox`): every agent on the Mac that waits for Samin, works or finished — T3 Code threads, Claude
// Code and Codex sessions — and the recent SamRabbit chats, in one list. The iPhone's Tasks tab and Home show it;
// T3 items keep acting through the T3 routes (`TaskThread`), the others through `/v1/mobile/inbox/items/<id>/*`.

/// Where an inbox item comes from.
public enum InboxSource: String, Codable, Sendable, CaseIterable {
    case t3
    case claude
    case codex
    /// A SamRabbit conversation (R1, Watch, iPhone, Mac): shown in Chats, not in Tasks.
    case samrabbit
    case unknown

    public init(raw: String?) {
        switch (raw ?? "").lowercased() {
        case "t3", "t3code": self = .t3
        case "claude", "claude-code", "claudecode": self = .claude
        case "codex": self = .codex
        case "samrabbit", "chat": self = .samrabbit
        default: self = .unknown
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(raw: try? decoder.singleValueContainer().decode(String.self))
    }

    /// "T3 Code", "Claude Code", "Codex".
    public var label: String {
        switch self {
        case .t3: "T3 Code"
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .samrabbit: "SamRabbit"
        case .unknown: "Agent"
        }
    }

    /// "T3", "Claude", "Codex" (filters).
    public var shortLabel: String {
        switch self {
        case .t3: "T3"
        case .claude: "Claude"
        case .codex: "Codex"
        case .samrabbit: "Chats"
        case .unknown: "Other"
        }
    }
}

/// What an item supports right now (`item.can`). Unknown words are kept and ignored. `dismiss` is on every item of a
/// bridge that knows it (hidden until it changes); `undismiss` on a dismissed one (`?include=dismissed`).
public enum InboxCapability: String, Sendable {
    case approve, answer, reply, stop, seen, open, dismiss, undismiss
}

/// One approval an item waits on (`pending.approvals[]`): T3's own choices (`accept`, `acceptForSession`,
/// `decline`, ...) as `PendingOption` values. Claude Code's prompts carry none: only the terminal answers them.
public struct InboxApproval: Codable, Sendable, Equatable {
    public var requestId: String
    public var kind: String
    public var detail: String
    public var options: [PendingOption]

    public init(requestId: String, kind: String = "approval", detail: String = "", options: [PendingOption] = []) {
        self.requestId = requestId
        self.kind = kind
        self.detail = detail
        self.options = options
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        guard let id = c.text("requestId") else {
            throw DecodingError.keyNotFound(AnyKey("requestId"), .init(codingPath: decoder.codingPath,
                                                                       debugDescription: "approval without a request"))
        }
        requestId = id
        kind = c.text("kind") ?? "approval"
        detail = c.text("detail") ?? ""
        options = c.list(PendingOption.self, "options")
    }

    /// "Wants to run a command", "Wants to change files", ... (the dock's words).
    public var kindLabel: String {
        switch kind.lowercased() {
        case "command", "exec", "shell", "command_execution": "Wants to run a command"
        case "file_change", "edit", "patch", "apply_patch", "file", "file-change": "Wants to change files"
        case "network": "Wants network access"
        case "tool", "mcp": "Wants to use a tool"
        case "plan": "Wants you to approve a plan"
        default: "Wants your approval"
        }
    }
}

/// One question of an input request (`pending.inputs[].questions[]`).
public struct InboxQuestion: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var header: String
    public var question: String
    public var options: [String]
    public var allowCustom: Bool
    public var multiSelect: Bool

    public init(id: String, header: String = "", question: String, options: [String] = [], allowCustom: Bool = true,
                multiSelect: Bool = false) {
        self.id = id
        self.header = header
        self.question = question
        self.options = options
        self.allowCustom = allowCustom
        self.multiSelect = multiSelect
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        id = c.text("id", "questionId") ?? "0"
        header = c.text("header") ?? ""
        question = c.text("question", "text") ?? ""
        options = c.list(PendingOption.self, "options").map(\.label)
        allowCustom = c.optionalBool("allowCustom") ?? options.isEmpty
        multiSelect = c.bool("multiSelect")
    }
}

/// One input request (`pending.inputs[]`): its id and its questions.
public struct InboxInput: Codable, Sendable, Equatable {
    public var requestId: String
    public var questions: [InboxQuestion]

    public init(requestId: String, questions: [InboxQuestion]) {
        self.requestId = requestId
        self.questions = questions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        guard let id = c.text("requestId") else {
            throw DecodingError.keyNotFound(AnyKey("requestId"), .init(codingPath: decoder.codingPath,
                                                                       debugDescription: "input without a request"))
        }
        requestId = id
        questions = c.list(InboxQuestion.self, "questions").filter { !$0.question.isEmpty }
    }
}

/// `item.pending`: what the item waits on.
public struct InboxPending: Codable, Sendable, Equatable {
    public var approvals: [InboxApproval]
    public var inputs: [InboxInput]

    public init(approvals: [InboxApproval] = [], inputs: [InboxInput] = []) {
        self.approvals = approvals
        self.inputs = inputs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        approvals = c.list(InboxApproval.self, "approvals")
        inputs = c.list(InboxInput.self, "inputs")
    }

    public var isEmpty: Bool { approvals.isEmpty && inputs.isEmpty }

    /// The words of what it waits on: the approval's detail (else its kind), else the first question.
    public static func detail(_ pending: InboxPending) -> String? {
        if let approval = pending.approvals.first { return approval.detail.isEmpty ? approval.kindLabel : approval.detail }
        return pending.inputs.first?.questions.first?.question
    }

    /// The first open request as the T3 cards know it (`PendingAction`): an approval (Approve / Deny with its
    /// request id), else the first question of the first input request.
    public var firstAction: PendingAction? {
        if let approval = approvals.first {
            return PendingAction(kind: .approval, text: approval.detail.isEmpty ? approval.kindLabel : approval.detail,
                                 options: approval.options, requestId: approval.requestId)
        }
        if let input = inputs.first, let question = input.questions.first {
            return PendingAction(kind: .question, text: question.question,
                                 options: question.options.map { PendingOption(value: $0) }, requestId: input.requestId,
                                 questionId: question.id)
        }
        return nil
    }
}

/// One `InboxItem`. Decoding is lenient like every other bridge payload: a missing field takes its default,
/// an unknown status reads as `.unknown`, an item without an id is dropped (by the list).
public struct InboxItem: Codable, Sendable, Equatable, Identifiable {
    /// `t3:<threadId>`, `claude:<sessionId>`, `codex:<threadId>`, `chat:<conversationId>`.
    public var id: String
    public var source: InboxSource
    /// The model family that runs it (`claude` / `codex`; a T3 thread's provider), if known.
    public var agent: String?
    public var title: String
    public var project: String?
    public var cwd: String?
    public var status: ThreadStatus
    /// Short, human: "Waiting for you in the terminal", "Finished", "Working · step 3/5".
    public var statusLabel: String
    /// What it needs, else its last answer (at most 240 characters).
    public var summary: String
    public var updatedAt: Date?
    public var unread: Bool
    public var pending: InboxPending
    /// What this item supports right now (`approve`, `answer`, `reply`, `stop`, `seen`, `open`).
    public var can: [String]
    /// An interactive process owns it right now (a Claude Code or Codex CLI in a terminal on the Mac).
    public var live: Bool
    public var progress: Double?
    public var phase: String?
    /// Samin dismissed it and it hasn't changed since (only with `?include=dismissed`; the app never asks for them).
    public var dismissed: Bool

    public init(id: String, source: InboxSource, agent: String? = nil, title: String, project: String? = nil,
                cwd: String? = nil, status: ThreadStatus, statusLabel: String = "", summary: String = "",
                updatedAt: Date? = nil, unread: Bool = false, pending: InboxPending = InboxPending(), can: [String] = [],
                live: Bool = false, progress: Double? = nil, phase: String? = nil, dismissed: Bool = false) {
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
        self.dismissed = dismissed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        guard let id = c.text("id") else {
            throw DecodingError.keyNotFound(AnyKey("id"), .init(codingPath: decoder.codingPath,
                                                                debugDescription: "inbox item without an id"))
        }
        self.id = id
        let raw = c.text("source") ?? id.split(separator: ":").first.map(String.init)
        source = InboxSource(raw: raw == "chat" ? "samrabbit" : raw)
        agent = c.text("agent")
        title = Formatting.clip(c.text("title") ?? "Untitled", 200)
        project = c.text("project", "projectName")
        cwd = c.text("cwd")
        status = ThreadStatus(raw: c.text("status"))
        statusLabel = Formatting.clip(c.text("statusLabel") ?? "", 80)
        summary = c.text("summary") ?? ""
        updatedAt = c.date("updatedAt")
        unread = c.bool("unread")
        pending = c.value(InboxPending.self, "pending") ?? InboxPending()
        can = c.list(String.self, "can")
        live = c.bool("live")
        progress = c.value(Double.self, "progress")
        phase = c.text("phase")
        dismissed = c.bool("dismissed")
    }

    /// The id without its source (`<threadId>` of `t3:<threadId>`).
    public var key: String {
        guard let colon = id.firstIndex(of: ":") else { return id }
        return String(id[id.index(after: colon)...])
    }

    public func supports(_ capability: InboxCapability) -> Bool { can.contains(capability.rawValue) }

    /// It can be dismissed: hidden here and on the Mac until it changes (a bridge before it lists no `dismiss`).
    public var canDismiss: Bool { supports(.dismiss) }

    public var isChat: Bool { source == .samrabbit }

    /// An agent's session or thread (not a SamRabbit chat): what Tasks lists.
    public var isAgent: Bool { !isChat }

    /// "Needs you": waiting on an approval or an answer, failed, or finished and not yet seen.
    public var needsYou: Bool {
        switch status {
        case .needsApproval, .needsInput, .error: true
        case .done: unread
        case .working, .idle, .unknown: false
        }
    }

    /// The contract's order: needs-approval, needs-input, error, done (unread), working, then everything else.
    public var rank: Int {
        switch status {
        case .needsApproval: 0
        case .needsInput: 1
        case .error: 2
        case .done: unread ? 3 : 5
        case .working: 4
        case .idle, .unknown: 5
        }
    }

    /// The T3 thread id of a T3 item.
    public var threadId: String? { source == .t3 ? key : nil }

    /// A T3 item as the T3 screens know it (`TaskThread`): the same id, status and open request (with its id, so
    /// Approve / Deny / Answer from a card answer exactly that request through the T3 routes).
    public var taskThread: TaskThread? {
        guard let threadId else { return nil }
        return TaskThread(threadId: threadId, title: title, projectName: project, status: status, updatedAt: updatedAt,
                          summary: summary.isEmpty ? nil : summary, pending: pending.firstAction)
    }

    /// Why a Claude Code or Codex item can't be answered from the iPhone right now (nil: it can, or it is T3).
    /// The phone's items never list `open` (only the Mac opens things on its screen), so what is left says it: a
    /// prompt the CLI shows in its terminal (no `approve` / `answer`), a session a terminal owns (`live`, no
    /// `reply`), a thread of the Codex app, or a Claude Code session the Mac couldn't check (`ps` failed: the bridge
    /// then sends neither `live` nor `reply`, and a reply would be refused with 503 `session_check_failed`).
    /// A Codex CLI session in that state reads as the app's: nothing in an item tells the two apart.
    public var heldOnMac: InboxHold? {
        guard source == .claude || source == .codex else { return nil }
        if status == .needsApproval || status == .needsInput, !supports(.approve), !supports(.answer) {
            return asksInCodexApp ? .waitingInApp : .waitingInTerminal
        }
        if supports(.reply) { return nil }
        if live { return .openInTerminal }
        return source == .codex ? .ownedByApp : .unknownOnMac
    }

    /// The bridge only guesses that it waits ("May be waiting for you in the terminal": a Codex tool call that went
    /// quiet with approvals on; a long build looks the same). Listed like the others, never announced.
    public var isGuess: Bool { statusLabel.lowercased().hasPrefix("may be") }

    /// Seeing it now: `<id>@<updatedAt>` while it is unread and can be marked seen, else nil. Its screen marks it
    /// seen once per mark (a session that finishes again while it is open is marked again).
    public var seenMark: String? {
        guard unread, supports(.seen) else { return nil }
        return "\(id)@\(Self.stamp(updatedAt))"
    }

    /// The item once seen, as the bridge says it next: not unread, no `seen`, and a failure settled (idle, its label
    /// still saying it failed; out of Needs you until it fails again), whoever runs it.
    public var markedSeen: InboxItem {
        var seen = self
        seen.unread = false
        seen.can.removeAll { $0 == InboxCapability.seen.rawValue }
        if seen.status == .error { seen.status = .idle }
        return seen
    }

    /// What says its screen should read it again: its state, the request it waits on, who holds it, what it can
    /// do, and while it isn't working its time (a working one is read again every few seconds anyway, and its time
    /// moves with every line it writes).
    public var changeMark: String {
        [status.rawValue, pendingRequestId ?? "", live ? "live" : "", can.joined(separator: ","),
         status == .working ? "" : Self.stamp(updatedAt)].joined(separator: "|")
    }

    /// Milliseconds since 1970 as text ("" without a time).
    static func stamp(_ date: Date?) -> String {
        date.map { String(Int64(($0.timeIntervalSince1970 * 1000).rounded())) } ?? ""
    }

    /// A Codex Desktop thread that asks something: the bridge says where ("Waiting for you in Codex", "Has a question
    /// in Codex"; a CLI's say "in the terminal"). Nothing else tells the phone which app runs a Codex thread.
    var asksInCodexApp: Bool {
        source == .codex && statusLabel.lowercased().hasSuffix("in codex")
    }

    /// The id of the request it waits on (an approval's, else an input's), if any.
    public var pendingRequestId: String? {
        pending.approvals.first?.requestId ?? pending.inputs.first?.requestId
    }
}

/// Why a Claude Code or Codex item is answered on the Mac, not here.
public enum InboxHold: String, Sendable, Equatable {
    /// The CLI shows a prompt (a permission, a question) in its terminal: only the terminal can answer it.
    case waitingInTerminal
    /// The Codex app asks something in one of its threads: only the app can answer it.
    case waitingInApp
    /// A CLI owns the session right now (open in a terminal): answer it there.
    case openInTerminal
    /// Codex Desktop runs this thread: only the app answers it.
    case ownedByApp
    /// The Mac couldn't tell whether a terminal runs this Claude Code session (its process list didn't answer), so
    /// it takes no reply that could start a second one.
    case unknownOnMac

    /// One line for the card: the bridge's own words for a prompt ("Has a question in the terminal", "May be waiting
    /// for you in the terminal"), else ours.
    public func headline(_ item: InboxItem) -> String {
        switch self {
        case .waitingInTerminal:
            item.statusLabel.lowercased().contains("in the terminal") ? item.statusLabel : "Waiting for you in the terminal"
        case .waitingInApp: "Waiting for you in the Codex app"
        case .openInTerminal: "Open in a terminal on your Mac"
        case .ownedByApp: "Runs in the Codex app on your Mac"
        case .unknownOnMac: "Can't tell if it's open on your Mac"
        }
    }

    /// What to do about it.
    public func detail(_ item: InboxItem) -> String {
        switch self {
        case .waitingInTerminal:
            "\(item.source.label) is asking in its terminal on your Mac. Answer it there; it shows up here again when it moves on."
        case .waitingInApp:
            "The Codex app on your Mac is asking. Answer it in the app; it shows up here again when it moves on."
        case .openInTerminal:
            "\(item.source.label) is running in a terminal on your Mac. Reply there, or here once it's closed."
        case .ownedByApp:
            "The Codex app on your Mac runs this thread. Answer it in the app."
        case .unknownOnMac:
            "Your Mac couldn't check whether a terminal runs this session. Try again in a moment, or answer it there."
        }
    }

    /// The symbol beside it.
    public var symbol: String {
        switch self {
        case .waitingInTerminal, .openInTerminal: "apple.terminal.fill"
        case .waitingInApp, .ownedByApp: "macwindow"
        case .unknownOnMac: "questionmark.circle.fill"
        }
    }
}

/// `counts`: what the inbox says needs Samin and what is working (`dismissed`: how many it hides, left out of the
/// others).
public struct InboxCounts: Codable, Sendable, Equatable {
    public var needsYou: Int
    public var working: Int
    public var total: Int
    public var dismissed: Int

    public init(needsYou: Int = 0, working: Int = 0, total: Int = 0, dismissed: Int = 0) {
        self.needsYou = needsYou
        self.working = working
        self.total = total
        self.dismissed = dismissed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        needsYou = c.int("needsYou")
        working = c.int("working")
        total = c.int("total")
        dismissed = c.int("dismissed")
    }
}

/// `sources.<name>`: whether a source answered (T3 says `connected`, the others `available`).
public struct InboxSourceState: Codable, Sendable, Equatable {
    public var ok: Bool
    public var reason: String?

    public init(ok: Bool = true, reason: String? = nil) {
        self.ok = ok
        self.reason = reason
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        ok = c.optionalBool("connected") ?? c.optionalBool("available") ?? c.optionalBool("ok") ?? true
        reason = c.text("reason")
    }
}

/// `GET /v1/mobile/inbox?after=&wait=` -> `{revision, updatedAt, counts, sources, items}`.
public struct InboxSnapshot: Codable, Sendable, Equatable {
    /// Grows whenever what the list shows changes; it starts from the time in milliseconds, so 64-bit (the watch's
    /// `Int` is 32 bits).
    public var revision: Int64
    public var updatedAt: Date?
    public var counts: InboxCounts
    public var sources: [String: InboxSourceState]
    /// In the contract's order (`InboxItem.rank`, newest first within a rank), at most `itemCap`.
    public var items: [InboxItem]

    /// The bridge caps the list at 60; a misbehaving one must not make the app draw thousands of rows.
    public static let itemCap = 60

    public init(revision: Int64 = 0, updatedAt: Date? = nil, counts: InboxCounts = InboxCounts(),
                sources: [String: InboxSourceState] = [:], items: [InboxItem] = []) {
        self.revision = revision
        self.updatedAt = updatedAt
        self.counts = counts
        self.sources = sources
        self.items = items
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        revision = c.int64("revision")
        updatedAt = c.date("updatedAt")
        // A dismissed item is the bridge's to bring back: never a row, even from a bridge that sends it anyway.
        let items = Self.ordered(Array(c.list(InboxItem.self, "items").filter { !$0.dismissed }.prefix(Self.itemCap)))
        self.items = items
        let agents = items.filter(\.isAgent)
        counts = c.value(InboxCounts.self, "counts")
            ?? InboxCounts(needsYou: agents.filter(\.needsYou).count,
                           working: agents.filter { $0.status == .working }.count, total: items.count)
        sources = c.value([String: InboxSourceState].self, "sources") ?? [:]
    }

    /// The contract's order, stable for equal ranks: by rank, then newest first.
    public static func ordered(_ items: [InboxItem]) -> [InboxItem] {
        items.enumerated().sorted { a, b in
            if a.element.rank != b.element.rank { return a.element.rank < b.element.rank }
            let left = a.element.updatedAt ?? .distantPast
            let right = b.element.updatedAt ?? .distantPast
            if left != right { return left > right }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// The agents' items (T3, Claude Code, Codex): what Tasks lists.
    public var agentItems: [InboxItem] { items.filter(\.isAgent) }

    /// T3 Code answered the bridge (`sources.t3.connected`; true when the bridge doesn't say).
    public var t3Connected: Bool { sources["t3"]?.ok ?? true }

    /// Why T3 Code didn't answer, as the error the task areas show ("T3 not connected").
    public var t3Problem: BridgeError? {
        guard let state = sources["t3"], !state.ok else { return nil }
        return .server(status: 503, code: state.reason ?? "t3_unavailable",
                       message: "T3 Code on your Mac isn't answering.", retryable: true)
    }

    /// What needs Samin and what is working, counted from the agents' rows (like the dock: a SamRabbit chat
    /// streaming a reply is not an agent at work, though the bridge's `counts.working` includes it); the bridge's
    /// counts add only what lies past the item cap.
    public var shownCounts: InboxCounts {
        let agents = agentItems
        let needsYou = agents.filter(\.needsYou).count
        let working = agents.filter { $0.status == .working }.count
        guard counts.total > items.count else {
            return InboxCounts(needsYou: needsYou, working: working, total: agents.count)
        }
        let moreNeeds = max(0, counts.needsYou - items.filter(\.needsYou).count)
        let moreWorking = max(0, counts.working - items.filter { $0.status == .working }.count)
        return InboxCounts(needsYou: needsYou + moreNeeds, working: working + moreWorking,
                           total: agents.count + max(0, counts.total - items.count))
    }

    /// What the summary carries for Home, the orb and the widgets: the counts and the first few agents' items.
    public func overview(top: Int = 5) -> InboxOverview {
        let counts = shownCounts
        return InboxOverview(needsYou: counts.needsYou, working: counts.working, total: counts.total,
                             items: Array(agentItems.prefix(top)))
    }

    /// An older bridge without the inbox: the T3 thread list as inbox items (the same rows, T3 only).
    public static func fromThreads(_ threads: [TaskThread]) -> InboxSnapshot {
        let items = ordered(threads.map(InboxItem.init(thread:)))
        let agents = items.filter(\.isAgent)
        return InboxSnapshot(counts: InboxCounts(needsYou: agents.filter(\.needsYou).count,
                                                 working: agents.filter { $0.status == .working }.count,
                                                 total: items.count),
                             sources: ["t3": InboxSourceState(ok: true)], items: items)
    }

    /// Says something the shown list (`current`) doesn't: a later revision. Revisions only grow (they start from the
    /// bridge's time in milliseconds, so a restarted bridge is later too); an answer built before the shown one (the
    /// 20 s refresh landing after the long-poll) or the same one again changes nothing, and must not undo what the
    /// app changed at once (a Mark seen) while the Mac's answer is on its way.
    public func isNewer(than current: InboxSnapshot?) -> Bool {
        guard let current else { return true }
        return revision > current.revision
    }
}

/// What Tasks and Home list (`items`, in the contract's order) and whether T3's among them are the last ones kept
/// while T3 Code isn't answering (`t3Stale`). Those stay visible, read-only, and count nowhere: the bridge's counts,
/// the widgets and Siri leave them out too, and what they waited on may have been answered meanwhile.
public struct InboxRows: Sendable, Equatable {
    public var items: [InboxItem]
    public var t3Stale: Bool

    public init(items: [InboxItem] = [], t3Stale: Bool = false) {
        self.items = items
        self.t3Stale = t3Stale
    }

    /// The rows of an inbox that loaded: its agents' items; while T3 Code isn't answering (`t3Problem`), T3's
    /// last rows (`previous`) too.
    public init(_ snapshot: InboxSnapshot, previous: [InboxItem]) {
        guard snapshot.t3Problem != nil else {
            self.init(items: snapshot.agentItems)
            return
        }
        let kept = previous.filter { $0.source == .t3 }
        self.init(items: InboxSnapshot.ordered(snapshot.agentItems.filter { $0.source != .t3 } + kept),
                  t3Stale: !kept.isEmpty)
    }

    /// The Mac answered but its inbox didn't (a server error, a timeout on its first scan): T3's own thread list,
    /// fresh, with the other agents' last rows (`previous`).
    public init(threads: [TaskThread], keeping previous: [InboxItem]) {
        let others = previous.filter { $0.source != .t3 && $0.isAgent }
        self.init(items: InboxSnapshot.ordered(InboxSnapshot.fromThreads(threads).items + others))
    }

    /// What can be acted on from here and counts.
    public var live: [InboxItem] { t3Stale ? items.filter { $0.source != .t3 } : items }

    /// T3's last rows while T3 Code isn't answering.
    public var stale: [InboxItem] { t3Stale ? items.filter { $0.source == .t3 } : [] }

    public var needsYou: Int { live.filter(\.needsYou).count }

    public var working: Int { live.filter { $0.status == .working }.count }
}

extension InboxItem {
    /// A T3 thread from the T3 routes as an inbox item (an older bridge without the inbox, or a summary thread).
    public init(thread: TaskThread) {
        var pending = InboxPending()
        if let action = thread.pending, let requestId = action.requestId {
            switch action.kind {
            case .approval:
                pending.approvals = [InboxApproval(requestId: requestId, detail: action.text, options: action.options)]
            case .question:
                pending.inputs = [InboxInput(requestId: requestId, questions: [
                    InboxQuestion(id: action.questionId ?? "0", question: action.text,
                                  options: action.options.map(\.label)),
                ])]
            case .unknown:
                break
            }
        }
        var can: [String] = ["reply"]
        switch thread.status {
        case .needsApproval: can = ["approve", "reply", "stop"]
        case .needsInput: can = ["answer", "reply", "stop"]
        case .working: can = ["reply", "stop"]
        default: break
        }
        self.init(id: "t3:\(thread.threadId)", source: .t3, title: thread.title, project: thread.projectName,
                  status: thread.status, statusLabel: thread.status.label, summary: thread.summary ?? "",
                  updatedAt: thread.updatedAt, pending: pending, can: can)
        // A thread whose request isn't known (a summary thread) keeps what it waits on as words for its card.
        if pending.isEmpty, let action = thread.pending, action.requestId == nil, summary.isEmpty {
            summary = action.text
        }
    }
}

/// `summary.inbox`: the inbox's counts and first items, put into the summary by the iPhone (the app, the
/// background refresh and the widgets' own fetch) so Home, the orb and the widgets count every agent, not only
/// T3's threads. A bridge that sends it itself is read the same way. The watch keeps the T3 counts.
public struct InboxOverview: Codable, Sendable, Equatable {
    public var needsYou: Int
    public var working: Int
    public var total: Int
    public var items: [InboxItem]

    public init(needsYou: Int = 0, working: Int = 0, total: Int = 0, items: [InboxItem] = []) {
        self.needsYou = needsYou
        self.working = working
        self.total = total
        self.items = items
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        let counts = c.value(InboxCounts.self, "counts")
        needsYou = c.optionalInt("needsYou") ?? counts?.needsYou ?? 0
        working = c.optionalInt("working") ?? counts?.working ?? 0
        total = c.optionalInt("total") ?? counts?.total ?? 0
        items = c.list(InboxItem.self, "items")
    }
}

extension MobileSummary {
    /// What needs Samin across every agent (the inbox), else T3's count.
    public var needsYouCount: Int { inbox?.needsYou ?? t3.needsYou }

    /// What is working across every agent (the inbox), else T3's count.
    public var workingCount: Int { inbox?.working ?? t3.working }

    /// This summary with the inbox's counts and first items (nil: as it is).
    public func with(inbox snapshot: InboxSnapshot?) -> MobileSummary {
        guard let snapshot else { return self }
        var copy = self
        copy.inbox = snapshot.overview()
        return copy
    }

    /// This summary with what the inbox said: its counts when it answered; when it failed, the counts saved last
    /// (`kept`), so a hiccup never flips Home and the widgets back to T3's counts; none for an older bridge without
    /// the inbox (404: T3's counts are all there is). A summary that carries its own `inbox` keeps it.
    public func with(inbox result: Result<InboxSnapshot, BridgeError>, kept: InboxOverview?) -> MobileSummary {
        switch result {
        case .success(let snapshot):
            return with(inbox: snapshot)
        case .failure(let error):
            guard inbox == nil, !error.isRouteMissing, let kept else { return self }
            var copy = self
            copy.inbox = kept
            return copy
        }
    }
}

extension BridgeError {
    /// The bridge doesn't have this route (an older one: 404 `not_found`). Not an item that went away
    /// (`item_not_found`).
    public var isRouteMissing: Bool {
        guard case .server(let status, let code, _, _) = self else { return false }
        return status == 404 && (code == "not_found" || code == "http_404")
    }

    /// A Claude Code or Codex session is open in a terminal on the Mac (409 `session_live`): answer it there.
    public var isSessionLive: Bool { code == "session_live" }

    /// The Mac couldn't tell whether a terminal runs the session (503 `session_check_failed`, retryable): it
    /// started nothing.
    public var isSessionCheckFailed: Bool { code == "session_check_failed" }
}

/// `GET /v1/mobile/inbox/items/<id>` -> `{item, messages}` (the last messages, each at most 4000 characters).
public struct InboxItemDetail: Codable, Sendable, Equatable {
    public var item: InboxItem
    public var messages: [ThreadMessage]

    public init(item: InboxItem, messages: [ThreadMessage]) {
        self.item = item
        self.messages = messages
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        guard let item = c.value(InboxItem.self, "item") else {
            throw DecodingError.keyNotFound(AnyKey("item"), .init(codingPath: decoder.codingPath,
                                                                  debugDescription: "missing item"))
        }
        self.item = item
        // Ids that stay the same from one read to the next (the list animates only what is new).
        var seen: [String: Int] = [:]
        messages = c.list(ThreadMessage.self, "messages").filter { !$0.text.isEmpty }.suffix(40).map { message in
            var message = message
            let base = "\(message.role.rawValue):\(Int64((message.at?.timeIntervalSince1970 ?? 0) * 1000))"
            let index = seen[base, default: 0]
            seen[base] = index + 1
            message.id = "\(base):\(index)"
            return message
        }
    }
}

/// What `reply` did (`202 {ok, how, message?}`): `terminal` (a new Terminal window on the Mac resumed the session
/// with the reply; `message` says so in the Mac's words), `t3`, `app`. `dryRun`: a bridge copy that opens nothing.
public struct InboxReplyResult: Codable, Sendable, Equatable {
    public var how: String?
    public var message: String?
    public var dryRun: Bool

    public init(how: String? = nil, message: String? = nil, dryRun: Bool = false) {
        self.how = how
        self.message = message
        self.dryRun = dryRun
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        how = c.text("how")
        message = c.text("message").map { Formatting.clip($0, 200) }
        dryRun = c.bool("dryRun")
    }

    /// It went to a new Terminal window on the Mac (a Claude Code or Codex CLI session resumed with the reply).
    public var resumedInTerminal: Bool { how == "terminal" }
}

/// `GET /v1/mobile/inbox/targets`: where a new task can go (T3's projects, the Claude and Codex providers T3
/// offers with their models) and the default (the most recently used).
public struct InboxTargets: Codable, Sendable, Equatable {
    public struct Project: Codable, Sendable, Equatable, Identifiable, Hashable {
        public var id: String
        public var title: String

        public init(id: String, title: String) {
            self.id = id
            self.title = title
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            id = c.text("id", "projectId") ?? ""
            title = c.text("title", "name") ?? id
        }
    }

    public struct Model: Codable, Sendable, Equatable, Identifiable, Hashable {
        public var id: String
        public var label: String

        public init(id: String, label: String) {
            self.id = id
            self.label = label
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            id = c.text("id", "slug") ?? ""
            label = c.text("label", "name") ?? id
        }
    }

    public struct Agent: Codable, Sendable, Equatable, Identifiable, Hashable {
        public var id: String
        public var label: String
        public var models: [Model]

        public init(id: String, label: String, models: [Model]) {
            self.id = id
            self.label = label
            self.models = models
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            id = c.text("id") ?? ""
            label = c.text("label") ?? id.capitalized
            models = c.list(Model.self, "models").filter { !$0.id.isEmpty }
        }
    }

    public struct Choice: Codable, Sendable, Equatable, Hashable {
        public var projectId: String?
        public var agent: String?
        public var model: String?

        public init(projectId: String? = nil, agent: String? = nil, model: String? = nil) {
            self.projectId = projectId
            self.agent = agent
            self.model = model
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            projectId = c.text("projectId")
            agent = c.text("agent")
            model = c.text("model")
        }
    }

    public var projects: [Project]
    public var agents: [Agent]
    public var defaultChoice: Choice

    public init(projects: [Project] = [], agents: [Agent] = [], defaultChoice: Choice = Choice()) {
        self.projects = projects
        self.agents = agents
        self.defaultChoice = defaultChoice
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        projects = c.list(Project.self, "projects").filter { !$0.id.isEmpty }
        agents = c.list(Agent.self, "agents").filter { !$0.id.isEmpty }
        defaultChoice = c.value(Choice.self, "default") ?? c.value(Choice.self, "defaultChoice") ?? Choice()
    }

    public func agent(_ id: String?) -> Agent? { agents.first { $0.id == id } }
}

/// `dismiss` / `undismiss` -> `{ok, dismissed, revision}`: the list's revision once it shows the change.
public struct InboxDismissResult: Codable, Sendable, Equatable {
    public var dismissed: Bool
    public var revision: Int64?

    public init(dismissed: Bool, revision: Int64? = nil) {
        self.dismissed = dismissed
        self.revision = revision
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        dismissed = c.bool("dismissed")
        revision = c.optionalInt64("revision")
    }
}

/// Dismissing from the phone (W8): a dismissed row leaves Tasks and Home at once (and the counts with it); the bridge
/// then leaves it out of its list until it changes. Here it stays hidden until an inbox at least as new as the one the
/// bridge gave with its yes (from then on the bridge's own list decides: an item that changed meanwhile is back by
/// itself); a refusal puts it back. The undo shows it again at once, from the copy kept here, until the inbox carries
/// it again; an undo that fails hides it again. Entries nothing settled go after `staleSeconds`. The same rules as
/// the Mac's dock (`DockDismissals`) and window.
public struct InboxDismissals: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public var item: InboxItem
        public var at: Date
        /// The inbox revision from which the bridge's list says the same; nil while the call is on its way.
        public var settles: Int64?
    }

    public private(set) var hidden: [String: Entry] = [:]
    public private(set) var restored: [String: Entry] = [:]
    public static let staleSeconds: TimeInterval = 30

    public init() {}

    public func isHidden(_ id: String) -> Bool { hidden[id] != nil }

    public var isEmpty: Bool { hidden.isEmpty && restored.isEmpty }

    /// The rows to draw: these, less the ones dismissed here, plus the ones undone here they don't carry yet; in the
    /// contract's order.
    public func shown(_ items: [InboxItem]) -> [InboxItem] {
        guard !isEmpty else { return items }
        let ids = Set(items.map(\.id))
        let back = restored.values.map(\.item).filter { !ids.contains($0.id) }
        return InboxSnapshot.ordered(items.filter { hidden[$0.id] == nil } + back)
    }

    public mutating func dismiss(_ item: InboxItem, now: Date = .now) {
        restored[item.id] = nil
        hidden[item.id] = Entry(item: item, at: now, settles: nil)
    }

    /// The bridge said yes: its list leaves the item out from `revision` on (one past `current` when it didn't say).
    public mutating func confirmed(_ id: String, revision: Int64?, current: Int64) {
        guard hidden[id] != nil else { return }
        let settles = revision ?? current + 1
        if current >= settles { hidden[id] = nil } else { hidden[id]?.settles = settles }
    }

    /// The dismissal failed: the row is back. Whether it was still hidden here (an undo may have brought it back).
    @discardableResult
    public mutating func failed(_ id: String) -> Bool {
        hidden.removeValue(forKey: id) != nil
    }

    /// The undo: the row is back at once (the copy hidden here, else `item`). Returns the row brought back.
    @discardableResult
    public mutating func undo(_ item: InboxItem, now: Date = .now) -> InboxItem {
        let back = hidden.removeValue(forKey: item.id)?.item ?? item
        restored[item.id] = Entry(item: back, at: now, settles: nil)
        return back
    }

    /// The dismissal an undo waited for failed: nothing to undo, the inbox's own row stays.
    public mutating func undoNotNeeded(_ id: String) {
        restored[id] = nil
    }

    /// The bridge took the undo back: its list carries the item again from `revision` on.
    public mutating func undoConfirmed(_ id: String, revision: Int64?, current: Int64) {
        guard restored[id] != nil else { return }
        let settles = revision ?? current + 1
        if current >= settles { restored[id] = nil } else { restored[id]?.settles = settles }
    }

    /// The undo failed: the bridge still keeps it dismissed, so it goes again.
    public mutating func undoFailed(_ id: String, now: Date = .now) {
        guard let entry = restored.removeValue(forKey: id) else { return }
        hidden[id] = Entry(item: entry.item, at: now, settles: nil)
    }

    /// A new inbox: what it settles is the bridge's from now on.
    public mutating func apply(_ snapshot: InboxSnapshot) {
        let present = Set(snapshot.items.map(\.id))
        hidden = hidden.filter { _, entry in entry.settles.map { snapshot.revision < $0 } ?? true }
        restored = restored.filter { id, entry in
            !present.contains(id) && (entry.settles.map { snapshot.revision < $0 } ?? true)
        }
    }

    /// Lets go of entries nothing settled in `staleSeconds`; whether any went.
    @discardableResult
    public mutating func tick(now: Date = .now) -> Bool {
        let before = hidden.count + restored.count
        hidden = hidden.filter { now.timeIntervalSince($0.value.at) < Self.staleSeconds }
        restored = restored.filter { now.timeIntervalSince($0.value.at) < Self.staleSeconds }
        return hidden.count + restored.count != before
    }
}

/// `POST /v1/mobile/inbox/new` -> `202 {itemId: "t3:<id>", ...}`.
public struct CreatedInboxTask: Codable, Sendable, Equatable {
    public var itemId: String
    public var threadId: String?
    public var title: String?
    public var projectName: String?

    public init(itemId: String, threadId: String? = nil, title: String? = nil, projectName: String? = nil) {
        self.itemId = itemId
        self.threadId = threadId
        self.title = title
        self.projectName = projectName
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        let thread = c.text("threadId")
        itemId = c.text("itemId", "id") ?? thread.map { "t3:\($0)" } ?? ""
        threadId = thread ?? (itemId.hasPrefix("t3:") ? String(itemId.dropFirst(3)) : nil)
        title = c.text("title")
        projectName = c.text("projectName", "project")
    }
}
