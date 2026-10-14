import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

/// The actions every surface offers (app, widgets, App Intents, Siri, the watch), in one place so
/// they behave the same everywhere: each one calls the bridge, refreshes the shared summary and
/// reloads the widgets.
public struct SamRabbitActions: Sendable {
    public let account: BridgeAccount
    public let cache: SummaryCache
    public let tracker: TaskTracker
    /// `refresh` also reads the inbox (`/v1/mobile/inbox`) and puts its counts into the summary, so the widgets
    /// count every agent on the Mac. The iPhone does; the watch keeps T3's counts (it never reads the inbox).
    public let includesInbox: Bool

    public init(account: BridgeAccount = .shared, cache: SummaryCache = .shared, tracker: TaskTracker = .shared,
                includesInbox: Bool = SamRabbitActions.inboxByDefault) {
        self.account = account
        self.cache = cache
        self.tracker = tracker
        self.includesInbox = includesInbox
    }

    /// The iPhone (and its widgets and intents) read the inbox; the watch doesn't.
    public static var inboxByDefault: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }

    public static let shared = SamRabbitActions()

    /// A new T3 task with automatic placement (or in `projectId`). Tracked so the phone can say
    /// when it finishes.
    @discardableResult
    public func ask(_ text: String, projectId: String? = nil) async throws -> CreatedThread {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw BridgeError.server(status: 400, code: "empty", message: "Say what to do.", retryable: false) }
        let created = try await account.requireClient().createThread(text: trimmed, projectId: projectId)
        tracker.track(TrackedTask(threadId: created.threadId, title: created.title ?? Formatting.clip(trimmed, 60),
                                  projectName: created.projectName, startedAt: .now))
        await refreshQuietly()
        return created
    }

    /// Blocks the calendar from now for `minutes` ("Focus" unless titled).
    @discardableResult
    public func block(minutes: Int, title: String? = nil) async throws -> CalendarWrite {
        let result = try await account.requireClient().block(minutes: minutes, title: title)
        await refreshQuietly()
        return result
    }

    /// Appends the user's own words to today's Heptabase journal.
    @discardableResult
    public func note(_ text: String) async throws -> JournalWrite {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw BridgeError.server(status: 400, code: "empty", message: "The note is empty.", retryable: false) }
        return try await account.requireClient().addJournalNote(trimmed)
    }

    @discardableResult
    public func openOnMac(app: String? = nil, url: String? = nil) async throws -> MacOpenResult {
        try await account.requireClient().openOnMac(app: app, url: url)
    }

    /// Approves or denies exactly the request `requestId` (the one the person saw). Throws
    /// `BridgeError.isStaleRequest` when it is no longer open.
    public func approve(threadId: String, requestId: String, _ approve: Bool) async throws {
        try await account.requireClient().respond(threadId: threadId, requestId: requestId, approve: approve)
        await refreshQuietly()
    }

    /// Answers exactly the question request `requestId`. Throws `BridgeError.isStaleRequest` when stale.
    public func answer(threadId: String, requestId: String, _ answer: String) async throws {
        try await account.requireClient().respond(threadId: threadId, requestId: requestId, answer: answer)
        await refreshQuietly()
    }

    /// Fetches the summary (and on the iPhone the inbox beside it, for every agent's counts) and hands it to the
    /// widgets (reloaded only when it changed).
    @discardableResult
    public func refresh(timeout: TimeInterval = 10) async throws -> MobileSummary {
        let client = try account.requireClient()
        guard includesInbox else {
            let summary = try await client.summary(timeout: timeout)
            cache.publish(summary)
            return summary
        }
        async let summaryCall = client.summary(timeout: timeout)
        async let inboxCall = BridgeError.capture { try await client.inbox(timeout: timeout) }
        let fresh = try await summaryCall
        let summary = fresh.with(inbox: await inboxCall, kept: cache.load()?.summary.inbox)
        cache.publish(summary)
        return summary
    }

    /// `refresh()` that never throws (after an action the action's own result matters).
    public func refreshQuietly() async {
        _ = try? await refresh()
    }

    /// The spoken "what needs me" sentence (fresh when the Mac answers, cached otherwise).
    public func whatNeedsMe() async -> String {
        if let summary = try? await refresh(timeout: 8) { return SpokenSummary.whatNeedsMe(summary) }
        if let cached = cache.load() {
            return SpokenSummary.whatNeedsMe(cached.summary) + " (As of \(Formatting.ago(cached.savedAt)).)"
        }
        return account.isPaired ? "I can't reach your Mac right now." : "SamRabbit isn't paired with your Mac yet."
    }

    public static func reloadWidgets() {
        #if canImport(WidgetKit) && !os(macOS)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}

/// A task started from this phone (so it can say when it finishes).
public struct TrackedTask: Codable, Sendable, Equatable, Identifiable {
    public var threadId: String
    public var title: String
    public var projectName: String?
    public var startedAt: Date
    public var lastStatus: ThreadStatus = .working
    public var id: String { threadId }

    public init(threadId: String, title: String, projectName: String?, startedAt: Date, lastStatus: ThreadStatus = .working) {
        self.threadId = threadId
        self.title = title
        self.projectName = projectName
        self.startedAt = startedAt
        self.lastStatus = lastStatus
    }
}

/// Tasks started from the phone and the needs-you requests already announced (App Group).
public final class TaskTracker: Sendable {
    public static let shared = TaskTracker()
    private let container: SharedContainer
    private static let tasksFile = "tracked-tasks.json"
    private static let announcedFile = "announced-requests.json"
    /// The earlier format (a list of keys), read once.
    private static let legacyAnnouncedFile = "announced.json"
    /// Tracked tasks are dropped after a day either way.
    static let maxAge: TimeInterval = 86_400

    public init(container: SharedContainer = .shared) { self.container = container }

    public var tasks: [TrackedTask] {
        (container.load([TrackedTask].self, from: Self.tasksFile) ?? []).filter { -$0.startedAt.timeIntervalSinceNow < Self.maxAge }
    }

    public func track(_ task: TrackedTask) {
        var list = tasks.filter { $0.threadId != task.threadId }
        list.append(task)
        container.save(Array(list.suffix(20)), as: Self.tasksFile)
    }

    public func update(_ list: [TrackedTask]) { container.save(list, as: Self.tasksFile) }

    public func untrack(_ threadId: String) { update(tasks.filter { $0.threadId != threadId }) }

    /// The needs-you requests that already raised a notification (`threadId|requestId` -> when),
    /// shared by the foreground app and the background refresh.
    public var announced: [String: Date] {
        if let value = container.load([String: Date].self, from: Self.announcedFile) { return value }
        let legacy = container.load([String].self, from: Self.legacyAnnouncedFile) ?? []
        return Dictionary(legacy.map { ($0, Date.now) }, uniquingKeysWith: { first, _ in first })
    }

    public func setAnnounced(_ keys: [String: Date]) {
        container.save(keys, as: Self.announcedFile)
        container.remove(Self.legacyAnnouncedFile)
    }
}

/// A local notification the app should post.
public struct PlannedAlert: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable { case needsYou, finished, failed }
    public var id: String
    public var kind: Kind
    public var title: String
    public var body: String
    public var threadId: String
    /// A Claude Code or Codex item's inbox id (`claude:<id>`): the alert opens that item, not a T3 thread.
    public var itemId: String? = nil
    /// Only the Mac can answer it (a prompt in a terminal or the Codex app): it comes as a normal alert, never
    /// time-sensitive through a Focus (Samin is usually at that Mac).
    public var onlyOnMac = false

    /// What tapping it opens: the T3 thread, or the inbox item.
    public var link: String {
        itemId.map { "samrabbit://inbox/\($0)" } ?? "samrabbit://thread/\(threadId)"
    }
}

/// Decides which local notifications fresh thread states deserve (no push: the background refresh
/// and the foreground app both run this, on different lists, and must agree).
///
/// A needs-you notification is keyed by the T3 request it is about (`threadId|requestId`), never by
/// its text or by which list the thread came from: the same request is announced once, wherever it
/// was seen first; a new request on the same thread is announced again. A thread that needs you but
/// carries no request id (summary threads, or a list item whose request the bridge has not read yet)
/// is not announced until a list shows its request. Keys are kept for a week whether or not the
/// thread is in the list this time, so a thread that drops out of one list and shows up in another
/// is not announced twice.
///
/// Claude Code and Codex sessions (the inbox's `agents`) are announced the same way when they wait for a prompt in
/// their terminal or app (`<itemId>|<requestId>`, the tool call it waits on); only the Mac can answer those, so the
/// alert says where and isn't time-sensitive. A prompt the bridge only guesses at ("May be waiting for you …": a
/// quiet Codex tool call, which a long build is too) is not announced; one whose tool call the bridge doesn't know
/// (its stand-in ids `terminal` / `codex`) is keyed with the time it started waiting, so the session's next prompt
/// is announced too.
public enum AlertPlanner {
    public struct Plan: Sendable, Equatable {
        public var alerts: [PlannedAlert]
        public var announced: [String: Date]
        public var tracked: [TrackedTask]
    }

    static let keepAnnounced: TimeInterval = 7 * 86_400
    static let maxAnnounced = 400

    /// - Parameters:
    ///   - threads: the freshest thread states known (a thread list, plus any looked up).
    ///   - announced: needs-you requests already notified, with when.
    ///   - tracked: tasks started from the phone.
    ///   - agents: Claude Code and Codex items from the inbox (T3's come as `threads`; others are skipped).
    public static func plan(threads: [TaskThread], agents: [InboxItem] = [], announced: [String: Date],
                            tracked: [TrackedTask], now: Date = .now) -> Plan {
        var alerts: [PlannedAlert] = []
        var keys = announced.filter { now.timeIntervalSince($0.value) < keepAnnounced }
        var seen = Set<String>()
        for thread in threads where thread.status.needsYou {
            guard let key = needsYouKey(thread), seen.insert(key).inserted else { continue }
            guard keys[key] == nil else { continue }
            keys[key] = now
            let what = thread.status == .needsApproval ? "Needs your approval" : "Has a question for you"
            let detail = thread.pending?.text.isEmpty == false ? thread.pending!.text : (thread.summary ?? what)
            alerts.append(PlannedAlert(id: "needs:\(key)", kind: .needsYou, title: thread.title,
                                       body: Formatting.clip(detail, 160), threadId: thread.threadId))
        }
        for item in agents where item.source == .claude || item.source == .codex {
            guard item.status == .needsApproval || item.status == .needsInput, !item.isGuess,
                  let key = needsYouKey(item), seen.insert(key).inserted, keys[key] == nil else { continue }
            keys[key] = now
            let place = item.heldOnMac?.headline(item) ?? item.statusLabel
            let detail = InboxPending.detail(item.pending) ?? item.summary
            let body = [place, detail].filter { !$0.isEmpty }.joined(separator: ": ")
            alerts.append(PlannedAlert(id: "needs:\(key)", kind: .needsYou, title: item.title,
                                       body: Formatting.clip(body, 160), threadId: item.id, itemId: item.id,
                                       onlyOnMac: item.heldOnMac != nil))
        }
        if keys.count > maxAnnounced {
            keys = Dictionary(uniqueKeysWithValues: keys.sorted { $0.value > $1.value }.prefix(maxAnnounced).map { ($0.key, $0.value) })
        }
        let byId = Dictionary(threads.map { ($0.threadId, $0) }, uniquingKeysWith: { first, _ in first })
        var remaining: [TrackedTask] = []
        for var task in tracked {
            guard let thread = byId[task.threadId] else {
                remaining.append(task)
                continue
            }
            if thread.status == .done || thread.status == .error {
                let failed = thread.status == .error
                alerts.append(PlannedAlert(id: "done:\(task.threadId)", kind: failed ? .failed : .finished,
                                           title: failed ? "Task failed" : "Task finished",
                                           body: "“\(Formatting.clip(thread.title, 70))”" +
                                               (thread.summary.map { " " + Formatting.clip($0, 110) } ?? ""),
                                           threadId: thread.threadId))
                continue
            }
            task.lastStatus = thread.status
            remaining.append(task)
        }
        return Plan(alerts: alerts, announced: keys, tracked: remaining)
    }

    /// `threadId|requestId`, or nil when the thread's request is not known.
    static func needsYouKey(_ thread: TaskThread) -> String? {
        guard let requestId = thread.pending?.requestId, !requestId.isEmpty else { return nil }
        return "\(thread.threadId)|\(requestId)"
    }

    /// `claude:<sessionId>|<requestId>`, or nil without a request. The bridge's stand-ins for a tool call it doesn't
    /// know (`terminal`: a prompt only Claude Code's own registry reports; `codex`) would be the same for every prompt
    /// of the session: those add the time it started waiting (`…|terminal@<ms>`).
    static func needsYouKey(_ item: InboxItem) -> String? {
        guard let requestId = item.pendingRequestId, !requestId.isEmpty else { return nil }
        if standInRequests.contains(requestId) { return "\(item.id)|\(requestId)@\(InboxItem.stamp(item.updatedAt))" }
        return "\(item.id)|\(requestId)"
    }

    static let standInRequests: Set<String> = ["terminal", "codex"]
}
