import Foundation
import SwiftUI

/// Which field has (or should get) the keys in the expanded panel.
enum DockFocus: Hashable {
    case compose
    case reply(String)
    case custom(String, String)  // item id, question id
}

/// The dock's data: the inbox (long-polled from the bridge), the open items' last messages, what a new prompt can be
/// sent to, drafts, and the actions with their optimistic results. Everything here is on the main actor; the network
/// waits happen in DockAPI.
@MainActor
final class DockStore: ObservableObject {
    enum Connection: Equatable {
        case connecting
        case online
        case offline(Int)  // HTTP status; 0 = bridge unreachable, -1 = no desktop token
    }

    /// A short line under an item (or under the compose bar): an error, or what happened ("Opened in Terminal").
    struct Note: Equatable {
        var text: String
        var isError = false
        /// The note offers Open (session_live: "It's open in Terminal — Open to answer there").
        var offersOpen = false
    }

    @Published private(set) var inbox = DockInbox.empty
    @Published private(set) var items: [DockItem] = []
    @Published private(set) var sections: [DockSection] = []
    @Published private(set) var connection: Connection = .connecting
    @Published private(set) var details: [String: DockItemDetail] = [:]
    @Published private(set) var loadingDetail: Set<String> = []
    @Published private(set) var busy: [String: String] = [:]
    @Published private(set) var notes: [String: Note] = [:]
    @Published private(set) var targets: DockTargets?
    @Published private(set) var targetsUnavailable = false
    @Published var choice = DockTargets.Choice()
    @Published var composeText = ""
    @Published private(set) var composeBusy = false
    @Published private(set) var composeNote: Note?
    @Published var replyDrafts: [String: String] = [:]
    @Published var selections: [String: [String: [String]]] = [:]
    @Published var customAnswers: [String: [String: String]] = [:]
    /// Bumps when the counts change, so the orb can move once.
    @Published private(set) var beat = 0
    @Published private(set) var now = Date()

    /// New needs-you items, once each (DockAttention): the controller turns them into notifications.
    var onAnnounce: (([DockItem]) -> Void)?
    /// `open` answered `how: "desktop"`: show that conversation in the main window.
    var onOpenConversation: ((String) -> Void)?
    /// The row that is expanded: its messages are kept fresh as the inbox changes.
    var watched: String? {
        didSet { if let watched, watched != oldValue { loadDetail(watched) } }
    }

    private struct Overlay {
        var item: DockItem
        var started: Date
        var settledAt: Int?  // the revision when the bridge said yes; dropped once a newer one arrives
    }

    private var overlays: [String: Overlay] = [:]
    private var placeholders: [(item: DockItem, until: Date)] = []
    private var attention = DockAttention()
    private var pollTask: Task<Void, Never>?
    private var clock: Timer?
    private var attempt = 0
    private var targetsAt = Date.distantPast
    private var firstAnswer = true
    private let live: Bool

    init() {
        live = true
    }

    /// A store that never touches the network: the snapshot renderer's fixtures.
    init(fixture inbox: DockInbox, details: [String: DockItemDetail], targets: DockTargets?, now: Date,
         connection: Connection = .online) {
        live = false
        self.inbox = inbox
        self.details = details
        self.targets = targets
        self.now = now
        self.connection = connection
        if let targets { choice = targets.resolve(DockTargets.Choice()) }
        rebuild()
    }

    // MARK: derived

    /// "2 need you" / "4 working": counted like the sections (DockInbox.shownCounts).
    var needsYouCount: Int { inbox.shownCounts(items: items).needsYou }

    var workingCount: Int { inbox.shownCounts(items: items).working }

    var isOnline: Bool { connection == .online }

    func item(_ id: String?) -> DockItem? {
        guard let id else { return nil }
        return items.first { $0.id == id }
    }

    var offlineText: String {
        switch connection {
        case .offline(-1): return "SamRabbit isn’t set up yet"
        case .offline(401), .offline(403): return "The bridge didn’t accept SamRabbit"
        case .offline(404): return "The bridge has no agent inbox yet"
        case .offline: return "Mac bridge isn’t running"
        case .connecting: return "Connecting…"
        case .online: return ""
        }
    }

    var offlineDetail: String {
        switch connection {
        case .offline(-1), .offline(401), .offline(403): return "Run companion/desktop/install.sh"
        case .offline(404): return "Update the bridge: companion/mac-bridge/install.sh"
        default: return "SamRabbit keeps trying."
        }
    }

    // MARK: polling

    func start() {
        guard live, pollTask == nil else { return }
        pollTask = Task { [weak self] in await self?.pollLoop() }
        clock?.invalidate()
        clock = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickClock() }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        clock?.invalidate()
        clock = nil
    }

    /// Retry at once (the offline card's button, or the panel opening while offline).
    func retryNow() {
        guard live else { return }
        pollTask?.cancel()
        pollTask = nil
        attempt = 0
        start()
    }

    private func tickClock() {
        now = Date()
        let before = placeholders.count
        placeholders.removeAll { $0.until < now }
        overlays = overlays.filter { now.timeIntervalSince($0.value.started) < 20 }
        if placeholders.count != before { rebuild() }
    }

    private func pollLoop() async {
        var revision: Int?
        while !Task.isCancelled {
            let asked = Date()
            let result = await DockAPI.inbox(after: revision, wait: revision == nil ? 0 : DockAPI.longPollWait)
            if Task.isCancelled { return }
            switch result {
            case .success(let answer):
                attempt = 0
                let unchanged = answer.revision == revision
                revision = answer.revision
                apply(answer)
                // A bridge that answers a long poll at once without news must not be asked in a tight loop.
                if unchanged && Date().timeIntervalSince(asked) < 0.5 { try? await Task.sleep(nanoseconds: 1_000_000_000) }
            case .failure(let failure):
                if failure.status == -2 { return }
                revision = nil
                wentOffline(failure.status)
                let delays: [Double] = [1, 2, 4, 8, 15, 30]
                var delay = delays[min(attempt, delays.count - 1)]
                if failure.status == 404 || failure.status == -1 || failure.status == 401 || failure.status == 403 { delay = max(delay, 30) }
                attempt += 1
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    private func wentOffline(_ status: Int) {
        guard connection != .offline(status) else { return }
        switch status {
        case 0: Log.write("dock: bridge not reachable")
        case -1: Log.write("dock: no desktop token")
        case 404: Log.write("dock: the bridge has no agent inbox yet (HTTP 404)")
        default: Log.write("dock: inbox answered HTTP \(status)")
        }
        connection = .offline(status)
    }

    private func apply(_ answer: DockInbox) {
        now = Date()
        if connection != .online {
            Log.write("dock: inbox online (\(answer.items.count) items, needs you \(answer.counts.needsYou), working \(answer.counts.working))")
            connection = .online
        }
        guard answer != inbox || firstAnswer else { return }
        let countsBefore = (needsYouCount, workingCount)
        let previous = inbox.items
        inbox = answer
        overlays = overlays.filter { _, overlay in
            guard let settled = overlay.settledAt else { return true }
            return answer.revision <= settled
        }
        let present = Set(answer.items.map(\.id))
        placeholders.removeAll { present.contains($0.item.id) }
        rebuild()
        if !firstAnswer && (needsYouCount, workingCount) != countsBefore { beat += 1 }
        firstAnswer = false
        let announce = attention.update(answer.items, now: now)
        if !announce.isEmpty { onAnnounce?(announce) }
        // Keep the expanded row's messages fresh when it changed.
        if let watched, let fresh = answer.items.first(where: { $0.id == watched }),
           previous.first(where: { $0.id == watched }) != fresh {
            loadDetail(watched)
        }
    }

    private func rebuild() {
        let base = inbox.items.map { overlays[$0.id]?.item ?? $0 }
        let ids = Set(base.map(\.id))
        let extra = placeholders.map(\.item).filter { !ids.contains($0.id) }
        items = DockOrder.sorted(base + extra)
        sections = DockSection.build(items)
    }

    // MARK: details and targets

    func loadDetail(_ id: String) {
        guard live, !id.hasPrefix("pending:"), !loadingDetail.contains(id) else { return }
        loadingDetail.insert(id)
        Task {
            let result = await DockAPI.item(id)
            loadingDetail.remove(id)
            if case .success(let detail) = result { details[id] = detail }
        }
    }

    func loadTargets(force: Bool = false) {
        guard live else { return }
        guard force || targets == nil || Date().timeIntervalSince(targetsAt) > 60 else { return }
        targetsAt = Date()
        Task {
            switch await DockAPI.targets() {
            case .success(let value):
                targets = value
                targetsUnavailable = false
                choice = value.resolve(choice)
            case .failure(let failure):
                if targets == nil { targetsUnavailable = true }
                Log.write("dock: targets answered HTTP \(failure.status)")
            }
        }
    }

    func pick(project id: String) {
        choice.projectId = id
        if let targets { choice = targets.resolve(choice) }
    }

    func pick(agent: String, model: String) {
        choice.agent = agent
        choice.model = model
        if let targets { choice = targets.resolve(choice) }
    }

    // MARK: actions

    func approve(_ item: DockItem, requestId: String, decision: String) {
        var optimistic = item
        optimistic.pending.approvals.removeAll { $0.requestId == requestId }
        let refused = ["decline", "deny", "reject", "cancel"].contains(decision.lowercased())
        if optimistic.pending.isEmpty {
            optimistic.status = .working
            optimistic.statusLabel = refused ? "Declined · continuing" : "Approved · continuing"
        }
        optimistic.unread = false
        perform(item, "approve", optimistic: optimistic) {
            await DockAPI.approve(item.id, requestId: requestId, decision: decision)
        }
    }

    func answer(_ item: DockItem, request: DockInputRequest) {
        guard let answers = DockAnswers.build(request, selected: selections[item.id] ?? [:], custom: customAnswers[item.id] ?? [:]) else {
            notes[item.id] = Note(text: "Answer every question first.", isError: true)
            return
        }
        send(answers, to: item, request: request)
    }

    /// One tap on an option of a single-choice question answers it.
    func answer(_ item: DockItem, request: DockInputRequest, option: String) {
        guard let question = request.questions.first else { return }
        send([question.id: option], to: item, request: request)
    }

    private func send(_ answers: [String: Any], to item: DockItem, request: DockInputRequest) {
        var optimistic = item
        optimistic.pending.inputs.removeAll { $0.requestId == request.requestId }
        if optimistic.pending.isEmpty {
            optimistic.status = .working
            optimistic.statusLabel = "Answered · continuing"
        }
        optimistic.unread = false
        perform(item, "answer", optimistic: optimistic) {
            await DockAPI.answer(item.id, requestId: request.requestId, answers: answers)
        }
    }

    func toggle(option: String, question: DockQuestion, item: DockItem) {
        var chosen = selections[item.id]?[question.id] ?? []
        if chosen.contains(option) {
            chosen.removeAll { $0 == option }
        } else {
            chosen = question.multiSelect ? chosen + [option] : [option]
        }
        selections[item.id, default: [:]][question.id] = chosen
        if !question.multiSelect { customAnswers[item.id, default: [:]][question.id] = "" }
    }

    func reply(_ item: DockItem) {
        let text = (replyDrafts[item.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, busy[item.id] == nil else { return }
        var optimistic = item
        optimistic.status = .working
        optimistic.statusLabel = "Sending your reply…"
        optimistic.unread = false
        let detailBefore = details[item.id]
        if var detail = detailBefore {
            detail.messages.append(DockMessage(role: "user", text: text, at: Date()))
            details[item.id] = detail
        }
        replyDrafts[item.id] = ""
        perform(item, "reply", optimistic: optimistic, rollback: { [weak self] in
            self?.details[item.id] = detailBefore
            if (self?.replyDrafts[item.id] ?? "").isEmpty { self?.replyDrafts[item.id] = text }
        }) {
            await DockAPI.reply(item.id, text: text)
        }
    }

    func stop(_ item: DockItem) {
        var optimistic = item
        optimistic.statusLabel = "Stopping…"
        perform(item, "stop", optimistic: optimistic) { await DockAPI.stop(item.id) }
    }

    func markSeen(_ item: DockItem) {
        var optimistic = item
        optimistic.unread = false
        perform(item, "seen", optimistic: optimistic) { await DockAPI.seen(item.id) }
    }

    func open(_ item: DockItem) {
        perform(item, "open", optimistic: nil) { await DockAPI.open(item.id) }
    }

    func sendCompose() {
        let text = composeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !composeBusy else { return }
        let picked = targets?.resolve(choice) ?? choice
        composeBusy = true
        composeNote = nil
        let placeholderId = "pending:\(UUID().uuidString)"
        let placeholder = DockItem(id: placeholderId, source: "t3", agent: picked.agent, title: DockText.clip(text, 90),
                                   project: targets?.project(picked.projectId)?.title, status: .working,
                                   statusLabel: "Starting…", summary: "", updatedAt: Date())
        placeholders.append((placeholder, Date().addingTimeInterval(45)))
        composeText = ""
        rebuild()
        guard live else { return }
        Task {
            let result = await DockAPI.create(text: text, choice: picked)
            composeBusy = false
            switch result {
            case .success(let reply):
                Log.write("dock: new task sent")
                if let itemId = reply.itemId, let index = placeholders.firstIndex(where: { $0.item.id == placeholderId }) {
                    placeholders[index].item.id = itemId
                    placeholders.removeAll { entry in inbox.items.contains { $0.id == entry.item.id } }
                }
            case .failure(let failure):
                Log.write("dock: new task failed (HTTP \(failure.status)\(failure.code.map { " \($0)" } ?? ""))")
                placeholders.removeAll { $0.item.id == placeholderId }
                if composeText.isEmpty { composeText = text }
                composeNote = Self.note(for: failure)
            }
            rebuild()
        }
    }

    func dismissNote(_ id: String) { notes[id] = nil }

    func showNote(_ note: Note, for id: String) { notes[id] = note }

    /// Runs one action: the optimistic item shows at once; on success it stays until the inbox catches up, on failure
    /// it is rolled back and the row says why.
    private func perform(_ item: DockItem, _ kind: String, optimistic: DockItem?, rollback: (() -> Void)? = nil,
                         call: @escaping () async -> Result<DockAPI.Reply, DockAPI.Failure>) {
        guard busy[item.id] == nil else { return }
        busy[item.id] = kind
        notes[item.id] = nil
        if let optimistic {
            overlays[item.id] = Overlay(item: optimistic, started: Date(), settledAt: nil)
            rebuild()
        }
        guard live else {
            busy[item.id] = nil
            return
        }
        Task {
            let result = await call()
            busy[item.id] = nil
            switch result {
            case .success(let reply):
                Log.write("dock: \(kind) ok\(reply.how.map { " (\($0))" } ?? "")")
                if optimistic != nil { overlays[item.id]?.settledAt = inbox.revision }
                if let text = Self.info(kind, reply) { notes[item.id] = Note(text: text) }
                if kind == "open", reply.how == "desktop", let conversation = reply.conversationId {
                    onOpenConversation?(conversation)
                }
            case .failure(let failure):
                Log.write("dock: \(kind) failed (HTTP \(failure.status)\(failure.code.map { " \($0)" } ?? ""))")
                overlays[item.id] = nil
                rollback?()
                notes[item.id] = Self.note(for: failure)
            }
            rebuild()
        }
    }

    private static func info(_ kind: String, _ reply: DockAPI.Reply) -> String? {
        switch (kind, reply.how) {
        case ("reply", "terminal"): return "Sent through Terminal: it opened with your reply."
        case ("reply", "app"): return "Sent in the app."
        case ("open", "terminal"): return "Opened in Terminal."
        case ("open", "t3"): return "Opened in T3 Code."
        case ("open", "app"): return "Opened in the app."
        default: return nil
        }
    }

    static func note(for failure: DockAPI.Failure) -> Note {
        switch (failure.status, failure.code) {
        case (409, "session_live"):
            return Note(text: "It’s open in Terminal — Open to answer there", isError: true, offersOpen: true)
        case (409, "t3_not_connected"), (503, "t3_not_connected"):
            return Note(text: "T3 Code isn’t connected to the bridge.", isError: true)
        case (409, _):
            return Note(text: failure.message.map { DockText.clip($0, 120) } ?? "That was already answered.", isError: true)
        case (0, _):
            return Note(text: "The Mac bridge isn’t answering.", isError: true)
        case (-1, _), (401, _), (403, _):
            return Note(text: "The bridge didn’t accept SamRabbit.", isError: true)
        case (404, _):
            return Note(text: "This one is gone from the inbox.", isError: true)
        default:
            let detail = failure.message.map { DockText.clip($0, 120) } ?? "HTTP \(failure.status)"
            return Note(text: "That didn’t work: \(detail)", isError: true)
        }
    }
}
