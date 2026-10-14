import Foundation
import Observation
import SamRabbitKit
import SwiftUI
import UIKit

/// The tabs of the iPhone app.
enum AppTab: String, Hashable, CaseIterable {
    case home, chats, tasks, mac, settings
}

/// Sheets the app can present from anywhere (quick actions, widgets, Siri, deep links).
enum AppSheet: Identifiable, Equatable {
    /// `listen`: start dictation as the sheet opens (the Action Button, the Ask control and buttons).
    /// A new value while the sheet is already open starts it again.
    case ask(prefill: String, listen: UUID? = nil)
    case note(prefill: String, listen: UUID? = nil)
    /// `start`: generate right away (the person confirmed a link's prompt).
    case generate(prefill: String, start: Bool = false)
    case openOnMac(prefill: String)
    case newTask
    case pair(PairLink)
    case manualPair
    /// A link asked for something that writes: what will happen, and a Confirm button.
    case confirm(LinkAction)

    var id: String {
        switch self {
        case .ask: "ask"
        case .note: "note"
        case .generate: "generate"
        case .openOnMac: "open"
        case .newTask: "newTask"
        case .pair: "pair"
        case .manualPair: "manualPair"
        case .confirm: "confirm"
        }
    }
}

/// A short confirmation or error shown over the app.
struct Toast: Equatable, Identifiable {
    enum Style { case success, failure, info }
    let id = UUID()
    var style: Style
    var title: String
    var detail: String?
}

/// Everything the app shows and does. One instance, on the main actor.
@MainActor
@Observable
final class AppModel {
    let account: BridgeAccount
    let actions: SamRabbitActions

    var pairing: BridgePairing?
    var summary: MobileSummary?
    var summaryDate: Date?
    /// The Mac itself did not answer (or refused the token) on the last refresh.
    var lastError: BridgeError?
    var refreshing = false
    /// The last T3 threads that loaded (kept while T3 Code is not answering): the inbox's T3 items as the T3 screens,
    /// notifications and Live Activities know them, or the thread list of an older bridge.
    var threads: [TaskThread] = []
    /// What Tasks and Home list: every agent's item on the Mac (T3 Code, Claude Code, Codex) from the inbox, in its
    /// order; T3's from the last list that had them while T3 Code is down (`t3Stale`). An older bridge: T3's threads
    /// only.
    var tasks: [InboxItem] = []
    /// The T3 rows in `tasks` are the last ones, kept while T3 Code isn't answering: shown read-only, counted nowhere.
    var t3Stale = false
    /// The inbox failed while the Mac answered: T3's rows come from its own thread list, the others' are the last.
    var inboxFallback = false
    /// The inbox as it last loaded (`revision` for the long-poll; counts beyond the item cap).
    var inbox: InboxSnapshot?
    /// The bridge has no inbox (an older one): Tasks lists T3's threads (`/t3/threads`) as before.
    var inboxMissing = false
    /// The task list failed while the Mac answered (T3 Code not running, ...): only the task areas say so.
    var tasksError: BridgeError?
    /// A task list has loaded since launch or pairing.
    var threadsLoaded = false
    var projects: [TaskProject] = []
    /// Where a new task can go (`/inbox/targets`: projects, Claude / Codex and their models); nil until loaded or
    /// on an older bridge.
    var targets: InboxTargets?
    /// Today's morning brief (`/v1/mobile/briefing`) when the Mac has one; Home shows it at the top until noon.
    var briefing: Briefing?
    /// The bridge has no brief (an older one: 404); the summary says so too (no `briefing` part).
    var briefingMissing = false
    /// Brief items with a tap on its way.
    var busyBriefItems: Set<String> = []
    /// A refresh of the brief asked for (the header's button) and not built yet.
    var briefingRefreshing = false
    /// An item a link asked for (`samrabbit://brief/<id>`): Home scrolls to the brief.
    var briefFocus: String?

    var tab: AppTab = .home
    var homePath = NavigationPath()
    var chatsPath = NavigationPath()
    var tasksPath = NavigationPath()
    var macPath = NavigationPath()
    var sheet: AppSheet?
    var toast: Toast?
    /// Asks the Mac tab to take a screenshot when it appears (widget / Siri "Screenshot my Mac").
    var pendingScreenshot = false

    /// Approve / deny / answer in flight, by thread id.
    var busyThreads: Set<String> = []
    /// Reply / seen in flight, by inbox item id.
    var busyItems: Set<String> = []
    /// `unpair()` is waiting for the Mac.
    var unpairing = false

    /// Items whose screen marked them seen, by `seenMark` (once per state).
    private var seenMarks: Set<String> = []
    private var refreshLoop: Task<Void, Never>?
    private var inboxFeed: Task<Void, Never>?
    private var routeObserver: (any NSObjectProtocol)?
    private var lastTurnRefresh: Date?
    let notifications = NotificationController()
    let liveActivities = LiveActivityController()
    /// The live conversation with SamRabbit (Talk).
    let talk: TalkModel
    /// Voice notes: the recorder and the outbox (`CaptureModel`).
    let capture: CaptureModel

    init(account: BridgeAccount = .shared) {
        self.account = account
        actions = SamRabbitActions(account: account)
        talk = TalkModel(account: account)
        capture = CaptureModel(account: account)
        pairing = account.isPaired ? account.pairing : nil
        if let cached = SummaryCache.shared.load() {
            summary = cached.summary
            summaryDate = cached.savedAt
        }
        // An intent that ran inside the app (the Action Button or the Ask control while SamRabbit
        // is already in front) leaves its route and posts this; no scene phase change follows.
        routeObserver = NotificationCenter.default.addObserver(forName: PendingRoute.didChange, object: nil,
                                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.consumePendingRoute() }
        }
        talk.engine.onUnauthorized = { [weak self] in
            self?.lastError = .unauthorized
            self?.handleUnauthorized()
        }
        // One microphone: a voice note ends a conversation and stops dictation before it records.
        capture.willRecord = { [weak self] in
            SpeechDictation.stopListening()
            guard let self, self.talk.active else { return }
            self.talk.end()
        }
        // A note the Mac saved shows in Tasks (and a task it started): refresh.
        capture.onDelivered = { [weak self] _ in
            Task { await self?.refresh() }
        }
        BackgroundNote.start = { [weak capture] in await capture?.startInBackground() ?? false }
        talk.engine.onTurnFinished = { [weak self] in
            // A turn may have started a task or answered one: refresh, at most every 10 s.
            guard let self, self.lastTurnRefresh.map({ -$0.timeIntervalSinceNow > 10 }) ?? true else { return }
            self.lastTurnRefresh = .now
            Task { await self.refresh() }
        }
        #if DEBUG
        // `-SamRabbitTalk start` (the UI tests, screenshots): Talk opens at launch.
        if UserDefaults.standard.string(forKey: "SamRabbitTalk") == "start" {
            Task { @MainActor [weak self] in self?.startTalk() }
        }
        #endif
    }

    var isPaired: Bool { pairing != nil }

    /// The Mac answered on the last refresh.
    var reachable: Bool { lastError == nil && summary != nil }

    var orbMood: OrbMood {
        guard isPaired else { return .offline }
        return talk.active ? .live : OrbMood.from(summary, reachable: reachable)
    }

    /// Why the task areas may be out of date while the rest of the Mac works (nil when the whole Mac
    /// is unreachable: `lastError` says so already).
    var tasksProblem: BridgeError? { lastError == nil ? tasksError : nil }

    /// The rows that can be acted on and count: `tasks` without T3's last ones while T3 Code is down.
    var liveTasks: [InboxItem] { InboxRows(items: tasks, t3Stale: t3Stale).live }

    /// T3's last rows while T3 Code isn't answering (Tasks shows them apart, read-only).
    var staleTasks: [InboxItem] { InboxRows(items: tasks, t3Stale: t3Stale).stale }

    /// What needs Samin across every agent: the rows' own count once a list loaded (so the badge, the headline and
    /// the sections agree; T3's last rows while it is down don't count, as on the Mac and in the widgets), else what
    /// the summary says (the inbox's counts in it, else T3's).
    var needsYouCount: Int {
        threadsLoaded ? liveTasks.filter(\.needsYou).count + overflow.needsYou : (summary?.needsYouCount ?? 0)
    }

    /// What is working across every agent (see `needsYouCount`).
    var workingCount: Int {
        threadsLoaded ? liveTasks.filter { $0.status == .working }.count + overflow.working : (summary?.workingCount ?? 0)
    }

    /// What the inbox counts beyond the 60 items it sends.
    private var overflow: InboxCounts {
        guard let inbox, !inboxMissing else { return InboxCounts() }
        let shown = inbox.shownCounts
        let agents = inbox.agentItems
        return InboxCounts(needsYou: max(0, shown.needsYou - agents.filter(\.needsYou).count),
                           working: max(0, shown.working - agents.filter { $0.status == .working }.count))
    }

    /// The account's one client (rebuilt only when the pairing changes).
    var client: BridgeClient? { account.client() }

    // MARK: - Refresh

    /// Refreshes the summary and the inbox (and runs the notification / Live Activity checks).
    ///
    /// The two fail on their own: while T3 Code is not running the inbox still answers (without T3's items,
    /// `sources.t3.connected: false`), and so does the summary, so the orb, the calendar, the R1, the widgets and
    /// the Claude Code and Codex rows stay fresh and only the T3 rows say "T3 not connected" (with the last list,
    /// read-only). An older bridge without the inbox (404) gets the T3 thread list instead, as before; so does an
    /// inbox that fails while the Mac answers (a server error, a timeout on its first scan), beside the other
    /// agents' last rows.
    func refresh(quiet: Bool = true) async {
        guard isPaired, let client else { return }
        refreshing = true
        defer { refreshing = false }
        async let summaryCall = BridgeError.capture { try await client.summary() }
        async let inboxCall = BridgeError.capture { try await client.inbox() }
        let (summaryResult, inboxResult) = await (summaryCall, inboxCall)
        switch summaryResult {
        case .success(let fresh):
            let kept = summary
            var merged = fresh.with(inbox: inboxResult, kept: kept?.inbox)
            // The brief, when the summary says there is one: read again only when it changed (its revision or its
            // day); its first open items go into the widgets' copy either way.
            if let part = fresh.briefing {
                if let shown = briefing, shown.revision == part.revision, shown.date == part.date {
                    merged = merged.with(briefing: .success(shown), kept: nil)
                } else {
                    let result = await BridgeError.capture { try await client.briefing() }
                    apply(briefing: result)
                    merged = merged.with(briefing: result, kept: kept?.briefing)
                }
            } else {
                briefing = nil
            }
            summary = merged
            summaryDate = .now
            lastError = nil
            if let summary { SummaryCache.shared.publish(summary) } // reloads the widgets only when something changed
        case .failure(let error):
            if error == .cancelled { return }
            lastError = error
            if error == .unauthorized { handleUnauthorized() }
            if !quiet { show(error) }
        }
        switch inboxResult {
        case .success(let snapshot):
            await apply(snapshot)
        case .failure(let error) where error.isRouteMissing:
            inboxMissing = true
            inbox = nil
            await refreshThreadList(client)
        case .failure(let error):
            if error == .cancelled { return }
            guard lastError == nil, error != .unauthorized else {
                tasksError = error
                return
            }
            // The Mac answered, its inbox didn't: T3's own list (what Tasks read before the inbox), the others'
            // last rows; only the task areas say so (no toast).
            await refreshThreadList(client, inboxError: error)
        }
    }

    /// The brief as it loaded (a later revision or another day replaces the shown one), or none for an older bridge.
    private func apply(briefing result: Result<Briefing, BridgeError>) {
        switch result {
        case .success(let fresh):
            briefingMissing = false
            if fresh.isNewer(than: briefing) || fresh.available != briefing?.available {
                withAnimation(.smooth) { briefing = fresh }
            }
            if fresh.status != .building { briefingRefreshing = false }
        case .failure(let error) where error.isRouteMissing:
            briefingMissing = true
            briefing = nil
        case .failure:
            break // the last brief stays
        }
    }

    /// Home shows the brief now: today's, before noon (`-SamRabbitBriefAllDay YES` lifts that in debug builds, for
    /// the UI tests and screenshots), with something left in it.
    var showsBriefing: Bool {
        guard isPaired, let briefing else { return false }
        return briefing.showsOnHome(allDay: Self.briefAllDay)
    }

    static var briefAllDay: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "SamRabbitBriefAllDay")
        #else
        false
        #endif
    }

    /// One of a brief item's verbs, by his tap. Draft reply makes a Gmail draft (never sent) and opens it; Make task
    /// starts a T3 task; Block time and Remind me go on the calendar; Done and Dismiss take it off; Open opens its
    /// Gmail thread (with the right account). The item changes at once; the Mac's next brief confirms.
    func act(on item: BriefingItem, _ action: BriefingAction) async {
        if action.kind == .open, let url = action.url ?? item.openURL {
            UIApplicationOpener.open(url)
            return
        }
        // An agent waiting (Agents): its item in Tasks, where it is approved or answered.
        if action.kind == .open, let itemId = item.inboxItemId {
            openInbox(itemId)
            return
        }
        guard !busyBriefItems.contains(item.id) else { return }
        busyBriefItems.insert(item.id)
        defer { busyBriefItems.remove(item.id) }
        do {
            let fallback = Self.state(after: action.kind)
            let result = try await actions.briefingAct(item.id, action: action.action, state: fallback)
            let state = result.state ?? fallback ?? item.state
            withAnimation(.smooth) {
                briefing = briefing?.with(item.id, state: state, draftUrl: action.kind == .draftReply ? result.url : nil,
                                          line: result.message)
            }
            switch action.kind {
            case .draftReply:
                Haptics.success()
                show(.success, "Draft saved in Gmail", detail: "Nothing was sent: review it in Gmail, then send it.")
                if let url = result.url { UIApplicationOpener.open(url) }
            case .makeTask:
                Haptics.success()
                show(.success, "Task started", detail: result.message)
            case .blockTime:
                Haptics.success()
                show(.success, "Time blocked", detail: result.message)
            case .remind:
                Haptics.success()
                show(.success, "I'll bring it back", detail: result.message)
            case .open:
                if let url = result.url {
                    UIApplicationOpener.open(url)
                } else if let itemId = result.itemId {
                    openInbox(itemId)
                }
            case .done, .dismiss, .agent, .other:
                Haptics.tap()
            }
            if action.kind == .makeTask || action.kind == .blockTime { await refresh() } else { await reloadBriefing() }
        } catch {
            fail(error)
            await reloadBriefing()
        }
    }

    /// What an item becomes after a verb, when the Mac doesn't say.
    static func state(after kind: BriefingAction.Kind) -> BriefingItem.State? {
        switch kind {
        case .draftReply: .drafted
        case .makeTask: .tasked
        case .blockTime: .blocked
        case .remind: .snoozed
        case .done: .done
        case .dismiss: .dismissed
        case .open, .agent, .other: nil
        }
    }

    /// The brief again (after a tap), with the widgets' copy.
    func reloadBriefing() async {
        guard let client, !briefingMissing else { return }
        let result = await BridgeError.capture { try await client.briefing() }
        apply(briefing: result)
        if let summary {
            let merged = summary.with(briefing: result, kept: summary.briefing)
            self.summary = merged
            SummaryCache.shared.publish(merged)
        }
    }

    /// Builds the brief again on the Mac now (the header's button; at most every five minutes there), then follows it
    /// until the new one is in.
    func refreshBriefing() async {
        guard let client, !briefingRefreshing else { return }
        briefingRefreshing = true
        defer { briefingRefreshing = false }
        do {
            let before = briefing?.revision ?? 0
            try await client.refreshBriefing()
            for _ in 0..<6 {
                let result = await BridgeError.capture { try await client.briefing(after: before, wait: 10) }
                apply(briefing: result)
                if let fresh = try? result.get(), fresh.revision > before, fresh.status != .building { break }
            }
            await reloadBriefing()
        } catch {
            fail(error)
        }
    }

    /// T3's thread list: the only rows on an older bridge without the inbox; beside the other agents' last rows
    /// when the inbox failed (`inboxError`, which the task areas then show).
    private func refreshThreadList(_ client: BridgeClient, inboxError: BridgeError? = nil) async {
        switch await BridgeError.capture({ try await client.threads() }) {
        case .success(let list):
            threads = list
            let rows = inboxError == nil ? InboxRows(items: InboxSnapshot.fromThreads(list).items)
                : InboxRows(threads: list, keeping: tasks)
            if rows.items != tasks { withAnimation(.smooth) { tasks = rows.items } }
            t3Stale = false
            inboxFallback = inboxError != nil
            threadsLoaded = true
            tasksError = inboxError
            await notifications.check(threads: list, agents: tasks.filter { $0.source != .t3 }, needsYou: needsYouCount)
            await liveActivities.update(with: list)
        case .failure(let error):
            if error == .cancelled { return }
            tasksError = inboxError ?? error
            // Notifications wait for a real list (summary threads carry no requests: they would announce
            // again what was announced); Live Activities can move on with the summary.
            if lastError == nil, let summary { await liveActivities.update(with: summary.t3.threads) }
        }
    }

    /// Shows an inbox that loaded: its agents' rows, T3's as `threads` for the T3 screens. While T3 Code isn't
    /// answering the last T3 rows stay, read-only under "T3 not connected", and nothing is announced from them.
    /// A list no newer than the shown one (`isNewer`) changes nothing unless `force`d (a Mark seen that failed:
    /// back to what the Mac said).
    func apply(_ snapshot: InboxSnapshot, force: Bool = false) async {
        guard force || inboxMissing || inboxFallback || snapshot.isNewer(than: inbox) else { return }
        inboxMissing = false
        inboxFallback = false
        inbox = snapshot
        let rows = InboxRows(snapshot, previous: tasks)
        tasksError = snapshot.t3Problem
        t3Stale = rows.t3Stale
        if rows.items != tasks { withAnimation(.smooth) { tasks = rows.items } }
        let t3 = rows.items.compactMap(\.taskThread)
        if t3 != threads { threads = t3 }
        threadsLoaded = true
        let agents = rows.items.filter { $0.source != .t3 }
        // While T3 Code is down its rows are the last ones: nothing new is announced from them.
        await notifications.check(threads: rows.t3Stale ? [] : t3, agents: agents, needsYou: needsYouCount)
        await liveActivities.update(with: t3)
    }

    /// Refreshes every 20 seconds while the app is active, and follows the inbox as it changes in between.
    func startRefreshing() {
        refreshLoop?.cancel()
        refreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(20))
            }
        }
        startInboxFeed()
    }

    func stopRefreshing() {
        refreshLoop?.cancel()
        refreshLoop = nil
        inboxFeed?.cancel()
        inboxFeed = nil
    }

    /// The inbox's long-poll (`?after=<revision>&wait=25`) while the app is active: an approval on the Mac, a
    /// Claude Code session that finished, a reply that started in Terminal show within a moment, not at the next
    /// refresh. Backs off when the Mac doesn't answer; idle on an older bridge without the inbox.
    private func startInboxFeed() {
        inboxFeed?.cancel()
        inboxFeed = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                guard let self, self.isPaired, !self.inboxMissing, let client = self.client,
                      let revision = self.inbox?.revision else {
                    try? await Task.sleep(for: .seconds(3))
                    continue
                }
                let asked = Date.now
                let result = await BridgeError.capture { try await client.inbox(after: revision, wait: 25) }
                if Task.isCancelled { return }
                switch result {
                case .success(let snapshot):
                    failures = 0
                    // Revisions only grow: the same one (or one the 20 s refresh already passed) changes nothing.
                    guard snapshot.isNewer(than: self.inbox) else {
                        // The same list at once (a bridge that doesn't wait): ask again a little later, not in a loop.
                        if Date.now.timeIntervalSince(asked) < 2 { try? await Task.sleep(for: .seconds(5)) }
                        continue
                    }
                    await self.apply(snapshot)
                    if let summary = self.summary {
                        self.summary = summary.with(inbox: snapshot)
                        // Reloads the widgets only when what they draw changed (a working agent's every line
                        // moves the revision, not their faces).
                        if let merged = self.summary { SummaryCache.shared.publish(merged) }
                    }
                case .failure(let error):
                    if error == .cancelled { return }
                    if error.isRouteMissing { self.inboxMissing = true }
                    failures += 1
                    try? await Task.sleep(for: .seconds(min(30, 2 * failures)))
                }
            }
        }
    }

    func loadProjects() async {
        guard let client, projects.isEmpty else { return }
        projects = (try? await client.projects()) ?? []
    }

    /// Where a new task can go (projects, Claude / Codex, models), for the New task sheet. Nil on an older bridge
    /// (then the sheet offers T3's projects only).
    func loadTargets() async {
        guard let client else { return }
        if let fresh = try? await client.inboxTargets() { targets = fresh }
    }

    // MARK: - Pairing

    /// Why the last pairing attempt failed, in words for the pairing screens (nil after a success).
    var pairingProblem: String?

    func pair(with link: PairLink) async -> Bool {
        pairingProblem = nil
        do {
            let pairing = try await Pairer.pair(link: link, deviceName: UIDevice.current.name, platform: .ios,
                                                account: account)
            self.pairing = pairing
            lastError = nil
            show(.success, "Paired with \(pairing.displayName)")
            Haptics.success()
            await refresh()
            startRefreshing()
            await notifications.requestAuthorization()
            await WatchLink.shared.provision(reissue: true)
            return true
        } catch let error as BridgeError {
            Haptics.error()
            // A wrong or expired code (401 invalid_code) and too many tries (429) are about the code,
            // not about a token the Mac stopped accepting (`.unauthorized`).
            pairingProblem = error.errorDescription
            show(error)
            return false
        } catch {
            pairingProblem = "Pairing failed."
            show(.failure, "Pairing failed")
            return false
        }
    }

    /// Unpairs: tells the Mac (`POST /v1/mobile/unpair`, which revokes this iPhone and its watch; best
    /// effort, a few seconds at most), then forgets the pairing here either way.
    func unpair() async {
        guard !unpairing else { return }
        unpairing = true
        defer { unpairing = false }
        stopRefreshing()
        let confirmed = await account.unpair()
        WatchLink.shared.reset()
        if confirmed {
            show(.info, "Unpaired", detail: "Your Mac forgot this iPhone and its watch.")
        } else {
            show(.info, "Unpaired here", detail: "Your Mac didn't answer. Revoke this iPhone there too.")
        }
        SummaryCache.shared.clear()
        pairing = nil
        summary = nil
        threads = []
        tasks = []
        t3Stale = false
        inboxFallback = false
        seenMarks = []
        inbox = nil
        inboxMissing = false
        targets = nil
        threadsLoaded = false
        tasksError = nil
        lastError = nil
        briefing = nil
        briefingMissing = false
        SamRabbitActions.reloadWidgets()
        await liveActivities.endAll()
    }

    private func handleUnauthorized() {
        show(.failure, "Pair again", detail: "Your Mac no longer accepts this iPhone.")
    }

    // MARK: - Actions

    func ask(_ text: String, projectId: String? = nil) async -> Bool {
        do {
            let created = try await actions.ask(text, projectId: projectId)
            Haptics.success()
            show(.success, "Task started", detail: created.projectName.map { "In \($0)" })
            await liveActivities.start(threadId: created.threadId, title: created.title ?? Formatting.clip(text, 60),
                                       projectName: created.projectName ?? "T3")
            await refresh()
            return true
        } catch {
            fail(error)
            return false
        }
    }

    /// A new T3 task run by the agent and model picked in the New task sheet (`POST /inbox/new`); without a choice
    /// it is `ask` (automatic placement, the project's own agent).
    func newTask(_ text: String, choice: InboxTargets.Choice) async -> Bool {
        guard choice.agent != nil || choice.model != nil, let client else {
            return await ask(text, projectId: choice.projectId)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let created = try await client.inboxNew(text: trimmed, choice: choice)
            Haptics.success()
            let agent = targets?.agent(choice.agent)?.label
            show(.success, "Task started", detail: [created.projectName.map { "In \($0)" }, agent.map { "with \($0)" }]
                .compactMap { $0 }.joined(separator: " "))
            if let threadId = created.threadId {
                TaskTracker.shared.track(TrackedTask(threadId: threadId, title: created.title ?? Formatting.clip(trimmed, 60),
                                                     projectName: created.projectName, startedAt: .now))
                await liveActivities.start(threadId: threadId, title: created.title ?? Formatting.clip(trimmed, 60),
                                           projectName: created.projectName ?? "T3")
            }
            await refresh()
            return true
        } catch {
            fail(error)
            return false
        }
    }

    func note(_ text: String) async -> Bool {
        do {
            let result = try await actions.note(text)
            Haptics.success()
            show(.success, result.state == "queued" ? "Note queued for your journal" : "Added to today's journal")
            return true
        } catch {
            fail(error)
            return false
        }
    }

    @discardableResult
    func block(minutes: Int = 30, title: String? = nil) async -> Bool {
        do {
            let result = try await actions.block(minutes: minutes, title: title)
            Haptics.success()
            let range = result.event.map { Formatting.range($0.startsAt, $0.endsAt) } ?? "now"
            show(.success, "Blocked \(minutes) min", detail: result.dryRun ? "\(range) (test copy: not written)" : range)
            await refresh()
            return true
        } catch {
            fail(error)
            return false
        }
    }

    /// Approves or denies exactly the request the card shows (`pending.requestId`). A card that does
    /// not know its request (a summary thread) opens the thread instead of answering blind.
    func approve(_ thread: TaskThread, _ approve: Bool, pending: PendingAction?) async {
        guard let requestId = (pending ?? thread.pending)?.requestId else {
            openThread(thread.threadId)
            return
        }
        busyThreads.insert(thread.threadId)
        defer { busyThreads.remove(thread.threadId) }
        do {
            try await actions.approve(threadId: thread.threadId, requestId: requestId, approve)
            Haptics.success()
            show(.success, approve ? "Approved" : "Denied", detail: thread.title)
            await refresh()
        } catch {
            await failResponding(error)
        }
    }

    /// Answers exactly the question the card shows (see `approve`).
    func answer(_ thread: TaskThread, _ text: String, pending: PendingAction?) async -> Bool {
        guard let requestId = (pending ?? thread.pending)?.requestId else {
            openThread(thread.threadId)
            return false
        }
        busyThreads.insert(thread.threadId)
        defer { busyThreads.remove(thread.threadId) }
        do {
            try await actions.answer(threadId: thread.threadId, requestId: requestId, text)
            Haptics.success()
            show(.success, "Answer sent", detail: thread.title)
            await refresh()
            return true
        } catch {
            await failResponding(error)
            return false
        }
    }

    /// The request was answered elsewhere or T3 asked something new: show the new state, never act on it.
    private func failResponding(_ error: Error) async {
        guard let bridge = error as? BridgeError, bridge.isStaleRequest else {
            fail(error)
            return
        }
        Haptics.error()
        show(.failure, "That request changed", detail: "Check it again.")
        await refresh()
    }

    /// The Tasks tab with this thread open.
    func openThread(_ threadId: String) {
        tab = .tasks
        tasksPath = NavigationPath()
        tasksPath.append(ThreadRoute(threadId: threadId))
    }

    /// An inbox item by its id (`samrabbit://inbox/<id>`, a brief's agent): a T3 thread's own screen, a chat in Chats,
    /// any other item's screen in Tasks.
    func openInbox(_ id: String) {
        tab = .tasks
        tasksPath = NavigationPath()
        if id.hasPrefix("t3:") {
            tasksPath.append(ThreadRoute(threadId: String(id.dropFirst(3))))
        } else if id.hasPrefix("chat:") {
            tab = .chats
            chatsPath = NavigationPath()
            chatsPath.append(ConversationRoute(conversationId: String(id.dropFirst(5)), title: nil))
        } else {
            tasksPath.append(InboxRoute(itemId: id))
        }
    }

    /// The Tasks tab with this item open: a T3 thread's own screen, a Claude Code or Codex session's, a chat in Chats.
    func openItem(_ item: InboxItem) {
        if let threadId = item.threadId {
            openThread(threadId)
        } else if item.isChat {
            tab = .chats
            chatsPath = NavigationPath()
            chatsPath.append(ConversationRoute(conversationId: item.key, title: item.title))
        } else {
            tab = .tasks
            tasksPath = NavigationPath()
            tasksPath.append(InboxRoute(itemId: item.id))
        }
    }

    /// Replies to a Claude Code or Codex session (a T3 thread: `reply(to:)`). One no CLI owns is resumed with the
    /// reply in a new Terminal window on the Mac; one open in a terminal is refused (`session_live`): answer it there.
    func reply(toItem item: InboxItem, _ text: String) async -> Bool {
        if let threadId = item.threadId { return await reply(to: threadId, text) }
        guard let client else { return false }
        busyItems.insert(item.id)
        defer { busyItems.remove(item.id) }
        do {
            let result = try await client.inboxReply(item.id, text: text)
            Haptics.success()
            if result.resumedInTerminal {
                show(.success, "Sent to your Mac",
                     detail: result.dryRun ? "A test copy of the bridge: nothing opened."
                         : result.message ?? "\(item.source.label) picks it up in a new Terminal window there.")
            } else {
                show(.success, "Reply sent", detail: item.title)
            }
            await refresh()
            return true
        } catch let error as BridgeError where error.isSessionLive {
            Haptics.error()
            show(.info, "It's open in Terminal on your Mac", detail: "Answer it there.")
            await refresh()
            return false
        } catch let error as BridgeError where error.isSessionCheckFailed {
            Haptics.error()
            show(.info, "Your Mac can't tell if it's open", detail: "Nothing was started. Try again in a moment.")
            await refresh()
            return false
        } catch {
            fail(error)
            await refresh()
            return false
        }
    }

    /// Marks an item seen (`/inbox/items/<id>/seen`): it leaves Needs you here and on the Mac's dock. At once
    /// here; the Mac's answer follows with the next list. `quiet` (its screen opened it): no haptic, no toast and
    /// no refresh (the long-poll brings the Mac's list); a failure puts the row back as the Mac last said it.
    @discardableResult
    func markSeen(_ item: InboxItem, quiet: Bool = false) async -> Bool {
        guard let client else { return false }
        busyItems.insert(item.id)
        defer { busyItems.remove(item.id) }
        let seen = (tasks.first { $0.id == item.id } ?? item).markedSeen
        if let index = tasks.firstIndex(where: { $0.id == item.id }) {
            withAnimation(.smooth) { tasks[index] = seen }
        }
        var marked = true
        do {
            try await client.inboxSeen(item.id)
            if !quiet { Haptics.tap() }
        } catch {
            marked = false
            if !quiet { fail(error) }
            // Back to what the Mac said, unless a newer list replaced the row meanwhile.
            if tasks.first(where: { $0.id == item.id }) == seen, let inbox { await apply(inbox, force: true) }
        }
        if !quiet { await refresh() }
        return marked
    }

    /// Its screen shows this item: unread and able to be marked seen, it is marked seen, quietly, once per state
    /// (`seenMark`; a session that finishes again while its screen is open is marked again). Opening a finished
    /// or failed task is seeing it, as on the Mac; T3's last rows while T3 Code is down are left alone.
    func sawItem(_ id: String) async {
        guard let item = tasks.first(where: { $0.id == id }), let mark = item.seenMark,
              !(t3Stale && item.source == .t3), seenMarks.insert(mark).inserted else { return }
        if !(await markSeen(item, quiet: true)) { seenMarks.remove(mark) } // the next look tries again
    }

    func reply(to threadId: String, _ text: String) async -> Bool {
        guard let client else { return false }
        do {
            try await client.sendMessage(threadId: threadId, text: text)
            Haptics.success()
            await refresh()
            return true
        } catch {
            fail(error)
            return false
        }
    }

    func stop(_ threadId: String) async {
        guard let client else { return }
        do {
            try await client.stop(threadId: threadId)
            Haptics.success()
            show(.info, "Stopped")
            await refresh()
        } catch {
            fail(error)
        }
    }

    func openOnMac(app: String? = nil, url: String? = nil) async -> Bool {
        do {
            let result = try await actions.openOnMac(app: app, url: url)
            Haptics.success()
            show(.success, "Opened on your Mac", detail: result.app ?? result.url ?? app ?? url)
            return true
        } catch {
            fail(error)
            return false
        }
    }

    // MARK: - Navigation

    /// Follows a `samrabbit://` link (`AppLink`). Links that would change something (`block`, `ask`
    /// or `note` with text, `mac/open`, `generate` with a prompt) never act on their own: they open
    /// a confirmation sheet showing what will happen, performed only by its Confirm button.
    /// `fromApp`: the route came from one of the app's own intents (`PendingRoute`). Only those
    /// may open Ask with the microphone on (`ask?listen=1`).
    func handle(url: URL, fromApp: Bool = false) {
        guard let link = AppLink(url: url, fromApp: fromApp) else { return }
        // Anywhere else in the app: Talk steps aside (the conversation goes on, over the tab bar), and a sheet
        // waits for it to go. A voice note handles Talk itself (it ends it: one microphone).
        if case .capture(let record) = link {
            startVoiceNote(record: record)
            return
        }
        let overTalk = link != .talk && talk.presented
        if overTalk { talk.minimize() }
        func present(_ next: AppSheet) { self.present(next, afterTalk: overTalk) }
        switch link {
        case .talk:
            // The app's own intent again while talking (the Action Button): like a tap on the orb.
            if fromApp, talk.active, talk.presented { talk.pressedAgain() } else { startTalk() }
        case .pair(let pairLink):
            present(.pair(pairLink))
        case .manualPair:
            tab = .settings
            present(.manualPair)
        case .compose(let composer, let listen):
            let token = listen ? UUID() : nil
            switch composer {
            case .ask: present(.ask(prefill: "", listen: token))
            case .note: present(.note(prefill: "", listen: token))
            case .generate: present(.generate(prefill: ""))
            case .openOnMac: present(.openOnMac(prefill: ""))
            }
        case .confirm(let action):
            present(.confirm(action))
        case .thread(let id):
            tab = .tasks
            tasksPath = NavigationPath()
            if let id { tasksPath.append(ThreadRoute(threadId: id)) }
        case .inbox(let id):
            if let id {
                openInbox(id)
            } else {
                tab = .tasks
                tasksPath = NavigationPath()
            }
        case .conversation(let id):
            tab = .chats
            chatsPath = NavigationPath()
            if let id { chatsPath.append(ConversationRoute(conversationId: id, title: nil)) }
        case .mac(let screenshot):
            tab = .mac
            if screenshot { pendingScreenshot = true }
        case .tab(let name):
            if let value = AppTab(rawValue: name) { tab = value }
        case .capture:
            break // above
        case .briefing(let itemId):
            tab = .home
            homePath = NavigationPath()
            briefFocus = itemId ?? "brief"
        }
    }

    /// Performs what a link asked for, after the person tapped Confirm on its sheet. True when done.
    func perform(_ action: LinkAction) async -> Bool {
        switch action {
        case .block(let minutes, let title):
            return await block(minutes: minutes, title: title)
        case .ask(let text):
            return await ask(text)
        case .note(let text):
            return await note(text)
        case .openOnMac(let app, let url):
            return await openOnMac(app: app, url: url)
        case .generate(let prompt):
            sheet = .generate(prefill: prompt, start: true)
            return true
        }
    }

    /// The composer for a link's text, to change it before sending.
    func edit(_ action: LinkAction) {
        switch action {
        case .ask(let text): sheet = .ask(prefill: text)
        case .note(let text): sheet = .note(prefill: text)
        case .generate(let prompt): sheet = .generate(prefill: prompt)
        case .openOnMac(let app, let url): sheet = .openOnMac(prefill: url ?? app ?? "")
        case .block: break
        }
    }

    /// Opens Talk and starts a conversation (the Home button, `samrabbit://talk`, Siri, the Action Button, the
    /// Talk control and Lock Screen widget). A sheet that is up (a composer, a confirmation) closes first, and a voice
    /// note that records is sent first (one microphone).
    func startTalk() {
        guard isPaired else {
            tab = .settings
            show(.info, "Pair with your Mac first", detail: "Then you can talk to SamRabbit from here.")
            return
        }
        if capture.presented {
            if capture.recording { capture.stop() }
            capture.close()
            Task {
                try? await Task.sleep(for: .milliseconds(450)) // the recorder's dismissal first
                talk.start()
            }
            return
        }
        guard sheet != nil else {
            talk.start()
            return
        }
        sheet = nil
        Task {
            try? await Task.sleep(for: .milliseconds(450)) // the sheet's dismissal first
            talk.start()
        }
    }

    /// Opens the voice-note recorder (the Voice Note intent: the Action Button, the control, the widgets' buttons,
    /// Siri; Home's tile). `record`: it records at once (only the app's own intents and buttons; a link from outside
    /// opens it waiting for a tap). The intent again while it records: stop and send. Talk or a sheet that is up goes
    /// first (one microphone, one screen).
    func startVoiceNote(record: Bool) {
        guard isPaired else {
            tab = .settings
            show(.info, "Pair with your Mac first", detail: "Then a voice note goes straight to it.")
            return
        }
        let busy = talk.presented || sheet != nil
        if talk.presented { talk.minimize() }
        sheet = nil
        guard busy else {
            capture.open(record: record)
            return
        }
        Task {
            try? await Task.sleep(for: .milliseconds(450)) // Talk's or the sheet's dismissal first
            capture.open(record: record)
        }
    }

    /// Shows a sheet; `afterTalk`: Talk is stepping aside, the sheet comes once it went.
    private func present(_ next: AppSheet, afterTalk: Bool) {
        guard afterTalk else {
            sheet = next
            return
        }
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            sheet = next
        }
    }

    /// Routes left by the app's intents (the Action Button, the controls, the widgets' buttons, Siri)
    /// in the App Group, whether they ran in the widget extension or in the app.
    func consumePendingRoute() {
        guard let url = PendingRoute.take(from: account.container.defaults) else { return }
        handle(url: url, fromApp: true)
    }

    // MARK: - Toasts

    func show(_ style: Toast.Style, _ title: String, detail: String? = nil) {
        toast = Toast(style: style, title: title, detail: detail)
    }

    func show(_ error: BridgeError) {
        show(.failure, error.shortDescription, detail: error.errorDescription)
    }

    func fail(_ error: Error) {
        Haptics.error()
        if let bridge = error as? BridgeError {
            if bridge == .cancelled { return }
            if bridge == .unauthorized { handleUnauthorized() }
            show(bridge)
        } else {
            show(.failure, "Something went wrong", detail: error.localizedDescription)
        }
    }
}

struct ThreadRoute: Hashable {
    var threadId: String
}

/// A Claude Code or Codex session (`InboxItemView`).
struct InboxRoute: Hashable {
    var itemId: String
}

struct ConversationRoute: Hashable {
    var conversationId: String
    var title: String?
}

enum Haptics {
    @MainActor static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    @MainActor static func error() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
    @MainActor static func tap() { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
}
