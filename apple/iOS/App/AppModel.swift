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
    /// The last thread list that loaded (kept while T3 Code is not answering).
    var threads: [TaskThread] = []
    /// The thread list failed while the Mac answered (T3 Code not running, ...): only the task areas say so.
    var tasksError: BridgeError?
    /// A thread list has loaded since launch or pairing.
    var threadsLoaded = false
    var projects: [TaskProject] = []

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
    /// `unpair()` is waiting for the Mac.
    var unpairing = false

    private var refreshLoop: Task<Void, Never>?
    private var routeObserver: (any NSObjectProtocol)?
    private var lastTurnRefresh: Date?
    let notifications = NotificationController()
    let liveActivities = LiveActivityController()
    /// The live conversation with SamRabbit (Talk).
    let talk: TalkModel

    init(account: BridgeAccount = .shared) {
        self.account = account
        actions = SamRabbitActions(account: account)
        talk = TalkModel(account: account)
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

    /// The account's one client (rebuilt only when the pairing changes).
    var client: BridgeClient? { account.client() }

    // MARK: - Refresh

    /// Refreshes the summary and the thread list (and runs the notification / Live Activity checks).
    ///
    /// The two fail on their own: while T3 Code is not running the bridge answers the thread list
    /// with 503 `t3_unavailable` but the summary still works, so the orb, the calendar, the R1 and
    /// the widgets stay fresh and only the task areas say "T3 not connected" (with the last list).
    func refresh(quiet: Bool = true) async {
        guard isPaired, let client else { return }
        refreshing = true
        defer { refreshing = false }
        async let summaryCall = BridgeError.capture { try await client.summary() }
        async let threadsCall = BridgeError.capture { try await client.threads() }
        let (summaryResult, threadsResult) = await (summaryCall, threadsCall)
        switch summaryResult {
        case .success(let fresh):
            summary = fresh
            summaryDate = .now
            lastError = nil
            SummaryCache.shared.publish(fresh) // reloads the widgets only when something changed
        case .failure(let error):
            if error == .cancelled { return }
            lastError = error
            if error == .unauthorized { handleUnauthorized() }
            if !quiet { show(error) }
        }
        switch threadsResult {
        case .success(let list):
            threads = list
            threadsLoaded = true
            tasksError = nil
            await notifications.check(threads: list)
            await liveActivities.update(with: list)
        case .failure(let error):
            if error == .cancelled { return }
            tasksError = error
            // Only the task areas say so (no toast). Notifications wait for a real list (summary
            // threads carry no requests: they would announce again what was announced); Live
            // Activities can move on with the summary.
            if lastError == nil, let summary { await liveActivities.update(with: summary.t3.threads) }
        }
    }

    /// Refreshes every 20 seconds while the app is active.
    func startRefreshing() {
        refreshLoop?.cancel()
        refreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }

    func stopRefreshing() {
        refreshLoop?.cancel()
        refreshLoop = nil
    }

    func loadProjects() async {
        guard let client, projects.isEmpty else { return }
        projects = (try? await client.projects()) ?? []
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
        threadsLoaded = false
        tasksError = nil
        lastError = nil
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
        // waits for it to go.
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
        case .conversation(let id):
            tab = .chats
            chatsPath = NavigationPath()
            if let id { chatsPath.append(ConversationRoute(conversationId: id, title: nil)) }
        case .mac(let screenshot):
            tab = .mac
            if screenshot { pendingScreenshot = true }
        case .tab(let name):
            if let value = AppTab(rawValue: name) { tab = value }
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
    /// Talk control and Lock Screen widget). A sheet that is up (a composer, a confirmation) closes first.
    func startTalk() {
        guard isPaired else {
            tab = .settings
            show(.info, "Pair with your Mac first", detail: "Then you can talk to SamRabbit from here.")
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

struct ConversationRoute: Hashable {
    var conversationId: String
    var title: String?
}

enum Haptics {
    @MainActor static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    @MainActor static func error() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
    @MainActor static func tap() { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
}
