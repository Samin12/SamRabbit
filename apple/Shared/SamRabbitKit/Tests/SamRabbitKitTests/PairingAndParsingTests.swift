import Foundation
import Testing
@testable import SamRabbitKit

@Suite("Pair links and hosts")
struct PairLinkTests {
    @Test func parsesTheDesktopLink() throws {
        let link = try #require(PairLink(string: "samrabbit://pair?h=192.168.1.183:3780,100.101.2.3:3780&c=K7MQ2ZXA&n=Samin%27s%20MacBook%20Pro"))
        #expect(link.hosts == [BridgeHost(host: "192.168.1.183", port: 3780), BridgeHost(host: "100.101.2.3", port: 3780)])
        #expect(link.hosts[1].isTailscale)
        #expect(!link.hosts[0].isTailscale)
        #expect(link.code == "K7MQ2ZXA")
        #expect(link.name == "Samin's MacBook Pro")
    }

    @Test func roundTripsThroughItsURL() throws {
        let link = PairLink(hosts: [BridgeHost(host: "10.0.0.5", port: 3780), BridgeHost(host: "fd7a::1", port: 3780)],
                            code: "SAMRABBT", name: "Mac & Co")
        let parsed = try #require(PairLink(url: link.url))
        #expect(parsed == link)
    }

    @Test func acceptsLenientCodesAndPlusSpaces() throws {
        let link = try #require(PairLink(string: "samrabbit://pair?c=samr-abbt&h=127.0.0.1:3799&n=Fake+Mac"))
        #expect(link.code == "SAMRABBT")
        #expect(link.name == "Fake Mac")
        let bare = try #require(PairLink(string: "SAMRABBIT://PAIR?h=mac.local&c=SAMRABBT"))
        #expect(bare.hosts == [BridgeHost(host: "mac.local", port: 3780)])
        #expect(bare.name == nil)
    }

    @Test(arguments: [
        "samrabbit://pair?h=1.2.3.4:3780&c=SAMRABB", // 7 characters
        "samrabbit://pair?h=1.2.3.4:3780&c=SAMRABBO", // O is ambiguous
        "samrabbit://pair?h=1.2.3.4:3780&c=SAMRABB1", // 1 is ambiguous
        "samrabbit://pair?h=1.2.3.4:3780&c=SAMRABBI", // I is ambiguous
        "samrabbit://pair?c=SAMRABBT", // no host
        "samrabbit://pair?h=1.2.3.4:99999&c=SAMRABBT", // bad port
        "samrabbit://ask?h=1.2.3.4&c=SAMRABBT", // not a pair link
        "https://pair?h=1.2.3.4&c=SAMRABBT", // wrong scheme
        "samrabbit://pair?h=bad host!&c=SAMRABBT",
    ])
    func rejectsBadLinks(_ text: String) {
        #expect(PairLink(string: text) == nil)
    }

    @Test func dropsDuplicateHosts() throws {
        let link = try #require(PairLink(string: "samrabbit://pair?h=1.2.3.4:3780,1.2.3.4:3780,1.2.3.4&c=SAMRABBT"))
        #expect(link.hosts.count == 1)
    }

    @Test(arguments: [
        ("192.168.1.183", "192.168.1.183:3780"),
        ("192.168.1.183:3781", "192.168.1.183:3781"),
        ("http://192.168.1.183:3780/health", "192.168.1.183:3780"),
        (" Mac.Local ", "mac.local:3780"),
        ("[fd7a:115c::5]:3780", "[fd7a:115c::5]:3780"),
    ])
    func hostParsing(input: String, expected: String) throws {
        let host = try #require(BridgeHost(parsing: input))
        #expect(host.description == expected)
        #expect(host.baseURL != nil)
    }

    @Test(arguments: ["", "ftp://x", "a:b:c", "host:0", "-host", "white space"])
    func badHosts(_ input: String) {
        #expect(BridgeHost(parsing: input) == nil)
    }

    @Test func codeHelpers() {
        #expect(PairingCode.normalize("k7mq 2zxa") == "K7MQ2ZXA")
        #expect(PairingCode.normalize("K7MQ-2ZX0") == nil)
        #expect(PairingCode.display("K7MQ2ZXA") == "K7MQ-2ZXA")
    }
}

@Suite("Server-sent events")
struct ServerSentEventTests {
    @Test func parsesTheBridgeStream() {
        var parser = ServerSentEventParser()
        let wire = "retry: 2000\n: ready 31\n\nid: 32\nevent: sync\ndata: {\"type\":\"message.user\",\"text\":\"hi\",\"cursor\":32}\n\n: heartbeat\n\n"
        let messages = parser.feed(wire)
        let items = messages.compactMap(SyncStreamItem.init)
        #expect(items.count == 3)
        #expect(items[0] == .ready(cursor: 31))
        guard case .event(let event) = items[1] else {
            Issue.record("expected an event")
            return
        }
        #expect(event.type == "message.user")
        #expect(event.cursor == 32)
        #expect(items[2] == .heartbeat)
    }

    @Test func handlesCRLFMultilineDataAndSplitChunks() {
        var parser = ServerSentEventParser()
        var messages: [ServerSentEvent] = []
        for chunk in ["id: 7\r\nevent: sync\r\ndata: {\"type\":", "\"x\",\r\ndata: \"cursor\":7}\r", "\n\r\n"] {
            messages += parser.feed(chunk)
        }
        #expect(messages.count == 1)
        #expect(messages[0].id == "7")
        #expect(messages[0].data == "{\"type\":\"x\",\n\"cursor\":7}")
    }

    @Test func idOnlyBecomesTheCursorWhenMissing() {
        var parser = ServerSentEventParser()
        let items = parser.feed("id: 99\nevent: sync\ndata: {\"type\":\"image\",\"blobId\":\"sha256:1\"}\n\n").compactMap(SyncStreamItem.init)
        guard case .event(let event)? = items.first else {
            Issue.record("expected an event")
            return
        }
        #expect(event.cursor == 99)
    }
}

@Suite("Notifications")
struct AlertPlannerTests {
    func thread(_ id: String, _ status: ThreadStatus, pending: String? = nil, request: String? = nil) -> TaskThread {
        TaskThread(threadId: id, title: "Task \(id)", status: status, summary: "summary",
                   pending: pending.map { PendingAction(kind: status == .needsApproval ? .approval : .question, text: $0,
                                                        requestId: request) })
    }

    @Test func announcesNewNeedsYouOnce() {
        let threads = [thread("a", .needsApproval, pending: "Deploy?", request: "r1"), thread("b", .working)]
        let first = AlertPlanner.plan(threads: threads, announced: [:], tracked: [])
        #expect(first.alerts.map(\.kind) == [.needsYou])
        #expect(first.alerts.first?.body == "Deploy?")
        #expect(first.alerts.first?.id == "needs:a|r1")
        let second = AlertPlanner.plan(threads: threads, announced: first.announced, tracked: [])
        #expect(second.alerts.isEmpty)
        // A new request on the same thread is new.
        let third = AlertPlanner.plan(threads: [thread("a", .needsApproval, pending: "Deploy prod?", request: "r2")],
                                      announced: second.announced, tracked: [])
        #expect(third.alerts.count == 1)
    }

    /// The foreground (every thread) and the background refresh (needs-you filter plus summary
    /// threads, which carry no request) see the same request differently: text edits, a missing
    /// pending, the thread missing from one list. They key it the same way, so it is announced once.
    @Test func foregroundAndBackgroundAgreeOnOneRequest() {
        let foreground = [thread("a", .needsApproval, pending: "Run ./deploy.sh staging", request: "req_1"),
                          thread("b", .needsInput, pending: "Which page?", request: "req_q"), thread("c", .working)]
        let first = AlertPlanner.plan(threads: foreground, announced: [:], tracked: [])
        #expect(first.alerts.count == 2)
        // The background list: other text for the same request, and a summary copy without a request.
        let background = [thread("a", .needsApproval, pending: "Run ./deploy.sh staging (pushes 2.4.0)", request: "req_1"),
                          thread("b", .needsInput)]
        let second = AlertPlanner.plan(threads: background, announced: first.announced, tracked: [])
        #expect(second.alerts.isEmpty)
        // "b" was not in that list with its request: its key is kept, the foreground stays quiet.
        let third = AlertPlanner.plan(threads: foreground, announced: second.announced, tracked: [])
        #expect(third.alerts.isEmpty)
        // Not in the list at all for a while (other filter), then back: still once.
        let fourth = AlertPlanner.plan(threads: [thread("c", .working)], announced: third.announced, tracked: [])
        let fifth = AlertPlanner.plan(threads: foreground, announced: fourth.announced, tracked: [])
        #expect(fourth.alerts.isEmpty && fifth.alerts.isEmpty)
    }

    /// Without a request id (summary threads, or a request the bridge has not read yet) nothing is
    /// announced; the first list that shows the request announces it, once.
    @Test func waitsForTheRequestId() {
        let unknown = AlertPlanner.plan(threads: [thread("a", .needsApproval), thread("b", .needsInput, pending: "Why?")],
                                        announced: [:], tracked: [])
        #expect(unknown.alerts.isEmpty)
        #expect(unknown.announced.isEmpty)
        let known = AlertPlanner.plan(threads: [thread("a", .needsApproval, pending: "Deploy?", request: "r1")],
                                      announced: unknown.announced, tracked: [])
        #expect(known.alerts.map(\.id) == ["needs:a|r1"])
        let again = AlertPlanner.plan(threads: [thread("a", .needsApproval)], announced: known.announced, tracked: [])
        let back = AlertPlanner.plan(threads: [thread("a", .needsApproval, pending: "Deploy?", request: "r1")],
                                     announced: again.announced, tracked: [])
        #expect(again.alerts.isEmpty && back.alerts.isEmpty)
    }

    @Test func forgetsAnnouncedRequestsAfterAWeek() {
        let old = Date.now.addingTimeInterval(-8 * 86_400)
        let plan = AlertPlanner.plan(threads: [], announced: ["a|r1": old, "b|r2": .now], tracked: [])
        #expect(Set(plan.announced.keys) == ["b|r2"])
    }

    @Test func reportsTrackedTasksThatFinish() {
        let tracked = [TrackedTask(threadId: "x", title: "X", projectName: nil, startedAt: .now),
                       TrackedTask(threadId: "y", title: "Y", projectName: nil, startedAt: .now),
                       TrackedTask(threadId: "z", title: "Z", projectName: nil, startedAt: .now)]
        let plan = AlertPlanner.plan(threads: [thread("x", .done), thread("y", .working), thread("z", .error)],
                                     announced: [:], tracked: tracked)
        #expect(plan.alerts.map(\.kind) == [.finished, .failed])
        #expect(plan.tracked.map(\.threadId) == ["y"])
    }

    @Test func trackerKeepsTasksInTheAppGroup() {
        let tracker = TaskTracker(container: .temporary())
        tracker.track(TrackedTask(threadId: "a", title: "A", projectName: "P", startedAt: .now))
        tracker.track(TrackedTask(threadId: "a", title: "A2", projectName: "P", startedAt: .now))
        #expect(tracker.tasks.map(\.title) == ["A2"])
        tracker.untrack("a")
        #expect(tracker.tasks.isEmpty)
    }

    @Test func trackerKeepsAnnouncedRequestsAndReadsTheOldList() throws {
        let container = SharedContainer.temporary()
        container.save(["a|r1", "b|r2"], as: "announced.json")
        let tracker = TaskTracker(container: container)
        #expect(Set(tracker.announced.keys) == ["a|r1", "b|r2"])
        let plan = AlertPlanner.plan(threads: [thread("a", .needsApproval, pending: "Deploy?", request: "r1")],
                                     announced: tracker.announced, tracked: [])
        #expect(plan.alerts.isEmpty) // announced before the update: not again
        tracker.setAnnounced(plan.announced)
        #expect(container.read("announced.json") == nil)
        #expect(Set(TaskTracker(container: container).announced.keys) == ["a|r1", "b|r2"])
    }
}

@Suite("Widget reloads")
struct WidgetReloadTests {
    func summary(needsYou: Int, at date: Date) -> MobileSummary {
        MobileSummary(generatedAt: date, mac: MacStatus(name: "Mac", online: true),
                      t3: TaskOverview(available: true, needsYou: needsYou, working: 1))
    }

    /// The apps refresh every 20-30 s; the timelines reload only when the summary says something new
    /// (`generatedAt` aside), or every half hour so the faces never turn "As of …".
    @Test func reloadsOnlyWhenTheSummaryChanged() {
        let cache = SummaryCache(container: .temporary())
        var reloads = 0
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(cache.publish(summary(needsYou: 1, at: start), at: start) { reloads += 1 })
        for step in 1...20 {
            let date = start.addingTimeInterval(TimeInterval(step * 30))
            #expect(!cache.publish(summary(needsYou: 1, at: date), at: date) { reloads += 1 })
            #expect(cache.load()?.savedAt == date) // the cache itself is always fresh
        }
        #expect(reloads == 1)
        let changed = start.addingTimeInterval(700)
        #expect(cache.publish(summary(needsYou: 2, at: changed), at: changed) { reloads += 1 })
        #expect(!cache.publish(summary(needsYou: 2, at: changed), at: changed.addingTimeInterval(60)) { reloads += 1 })
        let later = changed.addingTimeInterval(31 * 60)
        #expect(cache.publish(summary(needsYou: 2, at: later), at: later) { reloads += 1 })
        #expect(reloads == 3)
        // A widget timeline's own fetch (`save`) does not count as a reload for the others.
        cache.save(summary(needsYou: 3, at: later), at: later)
        #expect(cache.publish(summary(needsYou: 3, at: later), at: later.addingTimeInterval(30)) { reloads += 1 })
        cache.clear()
        #expect(cache.publish(summary(needsYou: 3, at: later), at: later.addingTimeInterval(60)) { reloads += 1 })
        #expect(reloads == 5)
    }

    /// The inbox's long-poll moves on with every line a working agent writes (its row's time and last words): the
    /// widgets reload for what they draw (a state, a title, the counts) at once, for times and words at most every
    /// five minutes, and each reload makes every widget fetch from the Mac again.
    @Test func aWorkingAgentDoesNotReloadTheWidgetsEveryFewSeconds() throws {
        let cache = SummaryCache(container: .temporary())
        var reloads = 0
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let item = InboxItem(id: "claude:a", source: .claude, agent: "claude", title: "Refactor the relay",
                             project: "jackrabbit-src", cwd: "/Users/sam/jackrabbit-src", status: .working,
                             statusLabel: "Working", summary: "Reading Relay.swift", updatedAt: start, live: true)
        func summary(_ item: InboxItem) -> MobileSummary {
            var value = self.summary(needsYou: 0, at: start)
            value.inbox = InboxOverview(needsYou: item.needsYou ? 1 : 0, working: item.status == .working ? 1 : 0,
                                        total: 1, items: [item])
            return value
        }
        #expect(cache.publish(summary(item), at: start) { reloads += 1 })
        // Two minutes of writing: every revision a new time and new last words, no reload.
        for step in 1...60 {
            var wrote = item
            wrote.updatedAt = start.addingTimeInterval(TimeInterval(step * 2))
            wrote.summary = "Editing file \(step)"
            #expect(!cache.publish(summary(wrote), at: start.addingTimeInterval(TimeInterval(step * 2))) { reloads += 1 })
            #expect(cache.load()?.summary.inbox?.items.first?.summary == "Editing file \(step)") // saved all the same
        }
        #expect(reloads == 1)
        // Five minutes on: the faces' times catch up once.
        var later = item
        later.updatedAt = start.addingTimeInterval(301)
        #expect(cache.publish(summary(later), at: start.addingTimeInterval(301)) { reloads += 1 })
        #expect(!cache.publish(summary(later), at: start.addingTimeInterval(320)) { reloads += 1 })
        // It finished: what the faces draw changed, at once.
        var finished = later
        finished.status = .done
        finished.unread = true
        finished.statusLabel = "Finished"
        #expect(cache.publish(summary(finished), at: start.addingTimeInterval(330)) { reloads += 1 })
        #expect(reloads == 3)
    }

    /// Dates finer than a millisecond (the bridge sends microseconds) don't survive a save; the cache
    /// compares what it saved as bytes, so the same summary is still "the same" after a round trip.
    @Test func subMillisecondDatesDoNotReloadEveryTime() throws {
        let cache = SummaryCache(container: .temporary())
        var reloads = 0
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let seen = Date(timeIntervalSince1970: 1_800_000_000.123456)
        var fresh = summary(needsYou: 1, at: start)
        fresh.r1 = R1Status(lastSeenAt: seen, live: false)
        fresh.transcribe = TranscribeStatus(available: true)
        let decoded = try BridgeJSON.decode(MobileSummary.self, from: BridgeJSON.encoder().encode(fresh))
        #expect(decoded != fresh) // the round trip keeps milliseconds only
        #expect(cache.publish(fresh, at: start) { reloads += 1 })
        for step in 1...5 {
            let date = start.addingTimeInterval(TimeInterval(step * 20))
            #expect(!cache.publish(fresh, at: date) { reloads += 1 })
        }
        #expect(reloads == 1)
        fresh.transcribe = TranscribeStatus(available: false, reason: "model_downloading")
        #expect(cache.publish(fresh, at: start.addingTimeInterval(200)) { reloads += 1 })
    }
}

@Suite("Links")
struct AppLinkTests {
    func link(_ text: String) -> AppLink? { AppLink(url: URL(string: text)!) }

    /// Links that would write anything never act: they become `.confirm`, shown on a sheet.
    @Test func linksThatWriteAlwaysNeedConfirmation() {
        #expect(link("samrabbit://block?minutes=45") == .confirm(.block(minutes: 45, title: nil)))
        #expect(link("samrabbit://block") == .confirm(.block(minutes: 30, title: nil)))
        #expect(link("samrabbit://block?minutes=99999&title=Deep%20work") == .confirm(.block(minutes: 720, title: "Deep work")))
        #expect(link("samrabbit://block?minutes=1") == .confirm(.block(minutes: 5, title: nil)))
        #expect(link("samrabbit://ask?text=Fix%20the%20login") == .confirm(.ask(text: "Fix the login")))
        #expect(link("samrabbit://task?text=Fix") == .confirm(.ask(text: "Fix")))
        #expect(link("samrabbit://note?text=Felt%20good") == .confirm(.note(text: "Felt good")))
        #expect(link("samrabbit://journal?text=x") == .confirm(.note(text: "x")))
        #expect(link("samrabbit://generate?text=chart") == .confirm(.generate(prompt: "chart")))
        #expect(link("samrabbit://mac/open?app=Notes") == .confirm(.openOnMac(app: "Notes", url: nil)))
        #expect(link("samrabbit://mac/open?url=https://example.com/a") ==
                .confirm(.openOnMac(app: nil, url: "https://example.com/a")))
    }

    @Test func linksWithoutContentOnlyOpenTheApp() {
        #expect(link("samrabbit://ask") == .compose(.ask))
        #expect(link("samrabbit://ask?text=%20%20") == .compose(.ask))
        #expect(link("samrabbit://note") == .compose(.note))
        #expect(link("samrabbit://generate") == .compose(.generate))
        #expect(link("samrabbit://mac/open") == .compose(.openOnMac))
        // Only web links may be opened on the Mac from a link.
        #expect(link("samrabbit://mac/open?url=file:///etc/hosts") == .compose(.openOnMac))
        #expect(link("samrabbit://mac/screenshot") == .mac(screenshot: true))
        #expect(link("samrabbit://mac") == .mac(screenshot: false))
        #expect(link("samrabbit://thread/t_1") == .thread("t_1"))
        #expect(link("samrabbit://task/t_1") == .thread("t_1"))
        #expect(link("samrabbit://conversation/c_1") == .conversation("c_1"))
        #expect(link("samrabbit://tab/tasks") == .tab("tasks"))
        #expect(link("samrabbit://pair") == .manualPair)
        if case .pair(let pair)? = link("samrabbit://pair?h=192.168.1.183:3780&c=ABCD-EFGH") {
            #expect(pair.code == "ABCDEFGH")
        } else {
            Issue.record("a pair link")
        }
        #expect(link("https://example.com/block?minutes=30") == nil)
        #expect(link("samrabbit://unknown") == nil)
    }

    @Test func confirmationWords() {
        #expect(LinkAction.block(minutes: 45, title: nil).headline == "Block 45 minutes on your calendar")
        #expect(LinkAction.block(minutes: 90, title: nil).headline == "Block 1 h 30 min on your calendar")
        #expect(LinkAction.block(minutes: 60, title: nil).headline == "Block 1 hour on your calendar")
        #expect(LinkAction.openOnMac(app: nil, url: "https://example.com/x").headline == "Open example.com on your Mac")
        #expect(LinkAction.note(text: "x").payload == "x")
        #expect(LinkAction.block(minutes: 30, title: nil).payload == nil)
    }
}

@Suite("Bridge errors")
struct BridgeErrorTests {
    func error(_ status: Int, _ body: String) -> BridgeError { BridgeError.from(status: status, data: Data(body.utf8)) }

    @Test func aRefusedCodeIsNotARefusedToken() {
        let code = error(401, #"{"error":{"code":"invalid_code","message":"That code is wrong or expired.","retryable":false}}"#)
        #expect(code.isPairingCodeRejected && code != .unauthorized)
        #expect(code.errorDescription == "That code is wrong or expired — get a new one on your Mac.")
        let expired = error(401, #"{"error":{"code":"expired_code","message":"x"}}"#)
        #expect(expired.isPairingCodeRejected)
        #expect(expired.errorDescription == code.errorDescription)
        let limited = error(429, #"{"error":{"code":"pairing_rate_limited","message":"Too many","retryable":true}}"#)
        #expect(limited.isPairingRateLimited && !limited.isPairingCodeRejected)
        #expect(limited.errorDescription == "Too many wrong codes. Wait a few minutes, then get a new code on your Mac.")
        #expect(error(401, #"{"error":{"code":"unauthorized","message":"Pair again."}}"#) == .unauthorized)
        #expect(error(401, "") == .unauthorized)
        #expect(BridgeError.unauthorized.errorDescription == "Your Mac no longer accepts this iPhone. Pair again in Settings.")
    }
}

@Suite("Watch link formats")
struct WatchLinkFormatTests {
    @Test func contextRoundTripsThroughApplicationContext() throws {
        let context = WatchContext(hosts: [BridgeHost(host: "192.168.1.183", port: 3780)], token: "srm_child",
                                   deviceId: "dev_1", bridgeName: "Mac", issuedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let decoded = try #require(WatchContext(applicationContext: context.applicationContext))
        #expect(decoded == context)
        #expect(WatchContext(applicationContext: [WatchContext.unpairedKey: true]) == nil)
    }

    @Test func relayRequestsKeepTheirShapeAndStayInsideTheMobileAPI() throws {
        let original = BridgeRequest.post("/v1/mobile/t3/threads/t_1/respond", body: ["decision": "approve"])
        let request = try #require(WatchRelay.Request(message: WatchRelay.Request(original).message))
        #expect(request.allowed)
        #expect(request.bridgeRequest.method == "POST")
        #expect(request.bridgeRequest.body == original.body)
        let query = WatchRelay.Request(.get("/v1/mobile/t3/threads", query: [URLQueryItem(name: "filter", value: "needs_you")]))
        #expect(query.bridgeRequest.query == [URLQueryItem(name: "filter", value: "needs_you")])
        #expect(!WatchRelay.Request(.post("/v1/mobile/pair", body: [:])).allowed)
        #expect(!WatchRelay.Request(.post("/v1/mobile/unpair", body: [:])).allowed)
        #expect(!WatchRelay.Request(.post("/v1/mobile/devices/child", body: [:])).allowed)
        #expect(!WatchRelay.Request(BridgeRequest(method: "DELETE", path: "/v1/mobile/devices/dev_1", query: [], body: nil,
                                                  authorized: true, accept: "application/json", timeout: nil)).allowed)
        #expect(!WatchRelay.Request(.get("/health")).allowed)
        for path in ["/v1/mobile/summary", "/v1/mobile/t3/threads", "/v1/mobile/calendar/agenda", "/v1/mobile/journal",
                     "/v1/mobile/mac/state", "/v1/mobile/conversations/c_1/events", "/v1/mobile/ui/artifacts/ui_1"] {
            #expect(WatchRelay.Request(.get(path)).allowed, "\(path)")
        }
        #expect(!WatchRelay.Request(.get("/v1/mobile/summaryx")).allowed)
        #expect(!WatchRelay.Request(.get("/v1/mobile/stream")).allowed)
        let response = try #require(WatchRelay.Response(message: WatchRelay.Response(status: 409, body: Data("x".utf8)).message))
        #expect(response.status == 409)
    }
}
