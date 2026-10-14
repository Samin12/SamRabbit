import Foundation

enum InboxTests {
    static let all: [(String, () throws -> Void)] = [
        ("decodesTheFixture", decodesTheFixture),
        ("ordersByTheContract", ordersByTheContract),
        ("buildsSections", buildsSections),
        ("decodingIsForgiving", decodingIsForgiving),
        ("capsTheList", capsTheList),
        ("computesCountsWhenMissing", computesCountsWhenMissing),
        ("showsCountsLikeTheSections", showsCountsLikeTheSections),
        ("recommendsAnOption", recommendsAnOption),
        ("buildsAnswers", buildsAnswers),
        ("resolvesTargets", resolvesTargets),
        ("decodesDetail", decodesDetail),
        ("announcesEachNeedOnce", announcesEachNeedOnce),
        ("announcesAThreadThatFinishesAgain", announcesAThreadThatFinishesAgain),
        ("quietWhileTerminalSessionsFlap", quietWhileTerminalSessionsFlap),
        ("smokeRunsOnlyAgainstTheFake", smokeRunsOnlyAgainstTheFake),
        ("formatsTimesAndText", formatsTimesAndText),
        ("decodesDismissed", decodesDismissed),
        ("dismissHidesAtOnceUntilTheBridgeAgrees", dismissHidesAtOnceUntilTheBridgeAgrees),
        ("dismissThatFailsComesBackAndSaysWhy", dismissThatFailsComesBackAndSaysWhy),
        ("undoBringsItBackUntilTheInboxHasIt", undoBringsItBackUntilTheInboxHasIt),
        ("toastAndStaleEntriesExpire", toastAndStaleEntriesExpire),
    ]

    static func fixture() throws -> DockInbox { try DockInbox.decode(Fixture.inboxData()) }

    static func decodesTheFixture() throws {
        let inbox = try fixture()
        expectEqual(inbox.revision, 1)
        expectEqual(inbox.items.count, 15)
        expectEqual(inbox.counts, DockCounts(needsYou: 6, working: 5, total: 15), "the bridge counts the streaming chat")
        expect(inbox.t3Connected)
        let pairing = inbox.items.first { $0.id == "t3:th_pairing_redirect" }
        expectEqual(pairing?.status, .needsApproval)
        expectEqual(pairing?.agentLabel, "Claude")
        expectEqual(pairing?.pending.approvals.first?.options.count, 3)
        expectEqual(pairing?.pending.approvals.first?.kindLabel, "Wants to run a command")
        expect(pairing?.supports("approve") == true && pairing?.supports("answer") == false)
        let question = inbox.items.first { $0.id == "t3:th_waitlist_db" }?.pending.inputs.first?.questions.first
        expectEqual(question?.options, ["Postgres on Neon", "SQLite with Litestream", "Supabase"])
        expectEqual(question?.allowCustom, true)
        let chat = inbox.items.first { $0.id == "chat:c_sleep_chart" }
        expect(chat?.isChat == true && chat?.agent == nil && chat?.agentLabel == nil)
        expect(inbox.items.allSatisfy { $0.updatedAt != nil }, "every fixture item has a time")
    }

    static func ordersByTheContract() throws {
        let inbox = try fixture()
        let ranks = inbox.items.map(\.rank)
        expectEqual(ranks, ranks.sorted(), "ranks never go down")
        expectEqual(inbox.items.first?.id, "t3:th_pairing_redirect")
        // Within a rank, newest first.
        let approvals = inbox.items.filter { $0.status == .needsApproval }.map(\.id)
        expectEqual(approvals, ["t3:th_pairing_redirect", "claude:5d0c6f2e-1a47-4f7e-9a51-3c2b1e0d9f88",
                                "codex:019a2b3c-4d5e-6f70-8192-a3b4c5d6e7f8"])
        // A finished thread that was seen sorts with the rest, not with "done (unread)".
        let now = Date()
        let read = DockItem(id: "a", source: "t3", title: "A", status: .done, updatedAt: now, unread: false)
        let unread = DockItem(id: "b", source: "t3", title: "B", status: .done, updatedAt: now.addingTimeInterval(-600), unread: true)
        let working = DockItem(id: "c", source: "t3", title: "C", status: .working, updatedAt: now.addingTimeInterval(-60))
        expectEqual(DockOrder.sorted([read, working, unread]).map(\.id), ["b", "c", "a"])
        // Equal times: the id decides, so the order is stable.
        let x = DockItem(id: "x", source: "t3", title: "X", status: .idle, updatedAt: now)
        let y = DockItem(id: "y", source: "t3", title: "Y", status: .idle, updatedAt: now)
        expectEqual(DockOrder.sorted([y, x]).map(\.id), ["x", "y"])
    }

    static func buildsSections() throws {
        let sections = DockSection.build(try fixture().items)
        expectEqual(sections.map(\.kind), [.needsYou, .working, .chats, .earlier])
        expectEqual(sections[0].items.map(\.id), [
            "t3:th_pairing_redirect", "claude:5d0c6f2e-1a47-4f7e-9a51-3c2b1e0d9f88", "codex:019a2b3c-4d5e-6f70-8192-a3b4c5d6e7f8",
            "t3:th_waitlist_db", "t3:th_watch_previews", "t3:th_release_notes",
        ])
        expectEqual(sections[1].items.map(\.id), [
            "t3:th_dark_mode", "claude:8e1f0a2b-3c4d-4e5f-a6b7-c8d9e0f1a2b3", "t3:th_snapshot_cache",
            "codex:019a7788-99aa-4bbc-8cde-f00112233445",
        ])
        // A live SamRabbit chat stays with the chats, newest first.
        expectEqual(sections[2].items.map(\.id), ["chat:c_watch_calendar", "chat:c_sleep_chart", "chat:c_mac_inbox"])
        expectEqual(sections[3].items.map(\.id), ["t3:th_readme_shots", "codex:019a1111-2222-4333-8444-555566667777"])
        expectEqual(sections.map(\.title), ["Needs you", "Working", "Recent chats", "Earlier"])
        // Earlier is folded until opened.
        expectEqual(DockSection.visibleIds(sections, earlierOpen: false).count, 13)
        expectEqual(DockSection.visibleIds(sections, earlierOpen: true).count, 15)
        expectEqual(DockSection.build([]).count, 0)
    }

    static func decodingIsForgiving() throws {
        let json = """
        {"revision": 7, "items": [
          {"id": "t3:a", "source": "t3", "title": "  Two\\n lines  ", "status": "brand-new-status", "can": ["open", "teleport"],
           "updatedAt": 1760385600000},
          {"source": "t3", "title": "no id"},
          {"id": "t3:b", "status": "needs-approval", "unread": "yes",
           "pending": {"approvals": [{"requestId": "r1"}, {"kind": "no request id"}], "inputs": "nonsense"}},
          "not even an object",
          {"id": "t3:c", "status": "done", "unread": true, "updatedAt": "2026-10-13T19:00:00.250Z", "progress": "half"}
        ]}
        """
        let inbox = try DockInbox.decode(Data(json.utf8))
        expectEqual(inbox.revision, 7)
        expectEqual(inbox.items.map(\.id), ["t3:b", "t3:c", "t3:a"])
        let a = inbox.items.first { $0.id == "t3:a" }
        expectEqual(a?.status, .idle, "unknown status reads as idle")
        expectEqual(a?.title, "Two lines")
        expectEqual(a?.can, ["open", "teleport"])
        expectEqual(a?.updatedAt, Date(timeIntervalSince1970: 1_760_385_600))
        let b = inbox.items.first { $0.id == "t3:b" }
        expectEqual(b?.source, "t3", "source falls back to the id prefix")
        expectEqual(b?.unread, false, "a malformed bool is the default")
        expectEqual(b?.pending.approvals.count, 1)
        expectEqual(b?.pending.approvals.first?.options.map(\.decision), ["accept", "decline"], "no options → Approve/Deny")
        expectEqual(b?.title, "Untitled")
        let c = inbox.items.first { $0.id == "t3:c" }
        expect(c?.updatedAt != nil, "fractional ISO times parse")
        expect(c?.progress == nil)
        expectEqual(inbox.counts, DockCounts(needsYou: 2, working: 0, total: 3))
        // A body that is not an inbox at all throws (and the client keeps its last good answer).
        expect((try? DockInbox.decode(Data("[1,2]".utf8))) == nil)
        expect((try? DockInbox.decode(Data("{}".utf8)))?.items.isEmpty == true)
    }

    static func capsTheList() throws {
        let rows = (0..<90).map { "{\"id\": \"t3:\($0)\", \"status\": \"idle\"}" }.joined(separator: ",")
        let inbox = try DockInbox.decode(Data("{\"revision\": 1, \"items\": [\(rows)]}".utf8))
        expectEqual(inbox.items.count, DockInbox.itemCap)
    }

    static func computesCountsWhenMissing() throws {
        let json = """
        {"items": [{"id": "1", "status": "working"}, {"id": "2", "status": "working", "source": "samrabbit"},
                   {"id": "3", "status": "error"}, {"id": "4", "status": "done", "unread": false}]}
        """
        let inbox = try DockInbox.decode(Data(json.utf8))
        expectEqual(inbox.counts, DockCounts(needsYou: 1, working: 1, total: 4), "a streaming chat is not an agent at work")
    }

    /// The pill's "N working" and the header agree with the Working section: the real bridge counts a SamRabbit chat
    /// that is streaming an R1 reply as working; the dock doesn't (the chat sits under Recent chats).
    static func showsCountsLikeTheSections() throws {
        let inbox = try fixture()
        let sections = DockSection.build(inbox.items)
        let shown = inbox.shownCounts(items: inbox.items)
        expectEqual(shown, DockShownCounts(needsYou: 6, working: 4))
        expectEqual(shown.working, sections.first { $0.kind == .working }?.items.count ?? 0, "the pill matches the Working section")
        expectEqual(shown.needsYou, sections.first { $0.kind == .needsYou }?.items.count ?? 0)
        // An action's optimistic result counts at once (the approval is now working).
        var items = inbox.items
        let index = items.firstIndex { $0.id == "t3:th_pairing_redirect" }!
        items[index].status = .working
        items[index].pending = DockPending()
        expectEqual(inbox.shownCounts(items: items), DockShownCounts(needsYou: 5, working: 5))
        // Past the bridge's 60-item cap its counts add what isn't in the list (its working count includes chats).
        let rows = (0..<60).map { "{\"id\": \"t3:\($0)\", \"status\": \"working\"}" }.joined(separator: ",")
        let capped = try DockInbox.decode(Data("""
        {"revision": 1, "counts": {"needsYou": 3, "working": 66, "total": 70},
         "items": [\(rows)]}
        """.utf8))
        expectEqual(capped.shownCounts(items: capped.items), DockShownCounts(needsYou: 3, working: 66))
        let chat = try DockInbox.decode(Data("""
        {"revision": 1, "counts": {"needsYou": 0, "working": 1, "total": 1},
         "items": [{"id": "chat:c", "source": "samrabbit", "status": "working"}]}
        """.utf8))
        expectEqual(chat.shownCounts(items: chat.items).working, 0, "an R1 reply streaming is not an agent at work")
    }

    static func recommendsAnOption() throws {
        func approval(_ decisions: [String]) -> DockApproval {
            DockApproval(requestId: "r", kind: "command", detail: "", options: decisions.map { DockApprovalOption(decision: $0, label: $0) })
        }
        expectEqual(approval(["decline", "acceptForSession", "accept"]).recommended?.decision, "accept")
        expectEqual(approval(["decline", "allow-once", "cancel"]).recommended?.decision, "allow-once")
        expectEqual(approval(["decline", "cancel"]).recommended?.decision, "decline")
        expect(approval([]).recommended == nil)
        expectEqual(approval(["accept"]).kindLabel, "Wants to run a command")
        expectEqual(DockApproval(requestId: "r", kind: "file_change", detail: "", options: []).kindLabel, "Wants to change files")
        expectEqual(DockApproval(requestId: "r", kind: "mystery", detail: "", options: []).kindLabel, "Wants your approval")
    }

    static func buildsAnswers() throws {
        let single = DockQuestion(id: "db", header: "", question: "", options: ["A", "B"], allowCustom: true, multiSelect: false)
        let multi = DockQuestion(id: "langs", header: "", question: "", options: ["Go", "Rust", "Swift"], allowCustom: true, multiSelect: true)
        let strict = DockQuestion(id: "go", header: "", question: "", options: ["Yes", "No"], allowCustom: false, multiSelect: false)
        expectEqual(DockAnswers.value(for: single, selected: ["B"], custom: "") as? String, "B")
        expectEqual(DockAnswers.value(for: single, selected: ["B"], custom: "  Mongo ") as? String, "Mongo", "typed wins")
        expect(DockAnswers.value(for: single, selected: [], custom: " ") == nil)
        expectEqual(DockAnswers.value(for: multi, selected: ["Swift", "Go"], custom: "Zig") as? [String], ["Go", "Swift", "Zig"])
        expectEqual(DockAnswers.value(for: strict, selected: ["Nope"], custom: "anything") as? String, nil, "unknown chip, no typing")
        let request = DockInputRequest(requestId: "r", questions: [single, multi])
        expect(DockAnswers.build(request, selected: ["db": ["A"]], custom: [:]) == nil, "every question needs an answer")
        let answers = DockAnswers.build(request, selected: ["db": ["A"], "langs": ["Rust"]], custom: [:])
        expectEqual(answers?["db"] as? String, "A")
        expectEqual(answers?["langs"] as? [String], ["Rust"])
        expect(DockAnswers.answersOnTap(DockInputRequest(requestId: "r", questions: [strict])))
        expect(!DockAnswers.answersOnTap(DockInputRequest(requestId: "r", questions: [single])))
        expect(!DockAnswers.answersOnTap(request))
    }

    static func resolvesTargets() throws {
        let object = try Fixture.json()
        let data = try JSONSerialization.data(withJSONObject: object["targets"] ?? [:])
        let targets = try JSONDecoder().decode(DockTargets.self, from: data)
        expectEqual(targets.projects.count, 4)
        expectEqual(targets.agents.map(\.id), ["claude", "codex"])
        let fallback = targets.resolve(.init())
        expectEqual(fallback, DockTargets.Choice(projectId: "proj_samrabbit", agent: "claude", model: "claude-opus-5-5"))
        let picked = targets.resolve(.init(projectId: "proj_website", agent: "codex", model: "gpt-5.5-mini"))
        expectEqual(picked, DockTargets.Choice(projectId: "proj_website", agent: "codex", model: "gpt-5.5-mini"))
        // Switching agent keeps the project and takes that agent's first model (the old model isn't one of its).
        let switched = targets.resolve(.init(projectId: "proj_website", agent: "codex", model: "claude-opus-5-5"))
        expectEqual(switched, DockTargets.Choice(projectId: "proj_website", agent: "codex", model: "gpt-5.5-codex"))
        let gone = targets.resolve(.init(projectId: "proj_deleted", agent: "gemini", model: "x"))
        expectEqual(gone, DockTargets.Choice(projectId: "proj_samrabbit", agent: "claude", model: "claude-opus-5-5"))
        expectEqual(targets.model("gpt-5.5", agent: "codex")?.label, "GPT-5.5")
        let empty = try JSONDecoder().decode(DockTargets.self, from: Data("{}".utf8))
        expectEqual(empty.resolve(.init(projectId: "p")), DockTargets.Choice())
    }

    static func decodesDetail() throws {
        let messages = (0..<20).map { "{\"role\": \"\($0 % 2 == 0 ? "user" : "assistant")\", \"text\": \"m\($0)\", \"at\": \"2026-10-13T19:00:00Z\"}" }
        let json = "{\"item\": {\"id\": \"t3:x\", \"status\": \"working\"}, \"messages\": [\(messages.joined(separator: ",")), {\"role\": \"assistant\", \"text\": \"\"}]}"
        let detail = try JSONDecoder().decode(DockItemDetail.self, from: Data(json.utf8))
        expectEqual(detail.item.id, "t3:x")
        expectEqual(detail.messages.count, 12, "the last 12, empty ones dropped")
        expectEqual(detail.messages.last?.text, "m19")
        expectEqual(detail.messages.first?.text, "m8")
        expect(detail.messages.first?.isUser == true)
    }

    static func announcesEachNeedOnce() throws {
        var attention = DockAttention()
        let now = Date()
        let approval = DockItem(id: "t3:a", source: "t3", title: "A", status: .needsApproval,
                                pending: DockPending(approvals: [DockApproval(requestId: "r1", kind: "command", detail: "", options: [])]))
        let working = DockItem(id: "t3:a", source: "t3", title: "A", status: .working)
        let other = DockItem(id: "t3:b", source: "t3", title: "B", status: .done, unread: true)
        expectEqual(attention.update([approval], now: now).count, 0, "the first answer is the baseline")
        expectEqual(attention.update([approval], now: now).count, 0, "still waiting: not again")
        expectEqual(attention.update([working, other], now: now).map(\.id), ["t3:b"])
        expectEqual(attention.update([working, other], now: now.addingTimeInterval(3)).map(\.id), [], "still finished: not again")
        var request2 = approval
        request2.pending = DockPending(approvals: [DockApproval(requestId: "r2", kind: "command", detail: "", options: [])])
        expectEqual(attention.update([request2, other], now: now.addingTimeInterval(10)).map(\.id), ["t3:a"], "a new request is news")
        _ = attention.update([working, other], now: now.addingTimeInterval(20))
        expectEqual(attention.update([request2], now: now.addingTimeInterval(DockAttention.cooldown + 30)).map(\.id), ["t3:a"],
                    "after the cooldown the same need is announced again")
        var seen = other
        seen.unread = false
        expectEqual(attention.update([seen], now: now.addingTimeInterval(DockAttention.cooldown + 40)).count, 0)
    }

    /// The common loop: a T3 thread finishes (announced), Samin replies from the dock, it works for 4 minutes and
    /// finishes again: the second finish is announced too, though it is the same thread and status within 10 minutes.
    static func announcesAThreadThatFinishesAgain() throws {
        var attention = DockAttention()
        let now = Date()
        func t3(_ status: DockStatus, unread: Bool = false) -> DockItem {
            DockItem(id: "t3:a", source: "t3", title: "A", status: status, unread: unread)
        }
        _ = attention.update([], now: now)
        expectEqual(attention.update([t3(.done, unread: true)], now: now.addingTimeInterval(60)).map(\.id), ["t3:a"])
        expectEqual(attention.update([t3(.working)], now: now.addingTimeInterval(120)).count, 0)
        expectEqual(attention.update([t3(.done, unread: true)], now: now.addingTimeInterval(300)).map(\.id), ["t3:a"],
                    "the second finish")
        // Failing again after a retry, too.
        expectEqual(attention.update([t3(.error)], now: now.addingTimeInterval(310)).map(\.id), ["t3:a"])
        _ = attention.update([t3(.working)], now: now.addingTimeInterval(320))
        expectEqual(attention.update([t3(.error)], now: now.addingTimeInterval(330)).map(\.id), ["t3:a"])
    }

    /// Claude Code / Codex statuses come from their session files and can flap (a long tool reads as "waiting" for a
    /// moment): the same need back after a few seconds stays quiet; back after a real stretch of work it is news.
    static func quietWhileTerminalSessionsFlap() throws {
        var attention = DockAttention()
        let now = Date()
        func claude(_ status: DockStatus, unread: Bool = false) -> DockItem {
            DockItem(id: "claude:s", source: "claude", title: "S", status: status, unread: unread)
        }
        _ = attention.update([], now: now)
        expectEqual(attention.update([claude(.done, unread: true)], now: now.addingTimeInterval(10)).count, 1)
        _ = attention.update([claude(.working)], now: now.addingTimeInterval(20))
        expectEqual(attention.update([claude(.done, unread: true)], now: now.addingTimeInterval(25)).count, 0, "a flap")
        _ = attention.update([claude(.working)], now: now.addingTimeInterval(30))
        expectEqual(attention.update([claude(.done, unread: true)], now: now.addingTimeInterval(60)).count, 0,
                    "30 s of work is still a flap")
        _ = attention.update([claude(.working)], now: now.addingTimeInterval(70))
        expectEqual(attention.update([claude(.done, unread: true)], now: now.addingTimeInterval(200)).count, 1,
                    "two minutes of work, then finished again: news")
        // Flapping without end: at most once per cooldown.
        var flapping = DockAttention()
        _ = flapping.update([], now: now)
        var announced = 0
        for step in 0..<130 {
            let at = now.addingTimeInterval(Double(step) * 10)
            announced += flapping.update([claude(step % 2 == 0 ? .done : .working, unread: true)], now: at).count
        }
        expectEqual(announced, 3, "21 minutes of flapping: at 0, after 10 and after 20 minutes")
    }

    static func smokeRunsOnlyAgainstTheFake() throws {
        func refusal(_ url: String, isDefault: Bool = false) -> String? {
            DockSmokeGuard.refusal(base: URL(string: url)!, isDefaultBase: isDefault)
        }
        expect(refusal("http://127.0.0.1:3780/app/", isDefault: true) != nil, "the default address is the live bridge")
        expect(refusal("http://127.0.0.1:3780/app/") != nil, "port 3780 is the live bridge's")
        expect(refusal("http://localhost:3780/app/") != nil)
        expect(refusal("http://127.0.0.1/app/") != nil, "no port")
        expect(refusal("http://192.168.1.5:3811/app/") != nil, "not loopback")
        expectEqual(refusal("http://127.0.0.1:3811/app/"), nil, "a fake server's port")
        // The places smoke saves the dock's spot, orb and hide as it goes: never in the installed app's settings.
        func places(_ url: String, _ bundleId: String?, isDefault: Bool = false) -> String? {
            DockSmokeGuard.placesRefusal(base: URL(string: url)!, isDefaultBase: isDefault, bundleId: bundleId)
        }
        expect(places("http://127.0.0.1:3811/app/", "com.samrabbit.desktop") != nil, "the installed app's bundle id")
        expect(places("http://127.0.0.1:3811/app/", nil) != nil, "no bundle id")
        expect(places("http://127.0.0.1:3780/app/", "com.samrabbit.desktop.dev") != nil, "the live bridge still refused")
        expect(places("http://127.0.0.1:3811/app/", "com.samrabbit.desktop.dev", isDefault: true) != nil)
        expectEqual(places("http://127.0.0.1:3811/app/", "com.samrabbit.desktop.dev"), nil, "a development copy on the fake")
    }

    static func formatsTimesAndText() throws {
        let now = Date(timeIntervalSince1970: 1_760_385_600)
        expectEqual(DockTime.short(now.addingTimeInterval(-10), now: now), "now")
        expectEqual(DockTime.short(now.addingTimeInterval(-4 * 60), now: now), "4m")
        expectEqual(DockTime.short(now.addingTimeInterval(-2 * 3600 - 100), now: now), "2h")
        expectEqual(DockTime.short(now.addingTimeInterval(-3 * 86_400), now: now), "3d")
        expectEqual(DockTime.short(nil, now: now), "")
        expect(DockTime.short(now.addingTimeInterval(-30 * 86_400), now: now).contains(" "), "a date after a week")
        expectEqual(DockText.oneLine("a\n\n b\tc  d"), "a b c d")
        expectEqual(DockText.clip("abcdefghij", 6), "abcde…")
        expectEqual(DockText.meta("SamRabbit", nil, " ", "Finished"), "SamRabbit · Finished")
    }

    // MARK: dismissing (W8)

    static func inbox(_ revision: Int, _ items: [DockItem]) -> DockInbox {
        DockInbox(revision: revision, updatedAt: nil, counts: DockCounts(needsYou: items.filter(\.needsYou).count,
                                                                         working: 0, total: items.count),
                  sources: [:], items: items)
    }

    static func decodesDismissed() throws {
        let inbox = try fixture()
        expect(inbox.items.allSatisfy(\.canDismiss), "every fixture item can be dismissed")
        expect(inbox.items.allSatisfy { !$0.dismissed })
        expectEqual(inbox.counts.dismissed, 0, "a bridge without the count: 0")
        let json = """
        {"revision": 7, "counts": {"needsYou": 1, "working": 0, "total": 1, "dismissed": 2},
         "items": [{"id": "t3:a", "status": "error", "title": "A", "can": ["reply", "dismiss"]},
                   {"id": "t3:b", "status": "error", "title": "B", "can": ["reply", "undismiss"], "dismissed": true}]}
        """
        let decoded = try DockInbox.decode(Data(json.utf8))
        expectEqual(decoded.items.map(\.id), ["t3:a"], "a dismissed item is never a row, even when a bridge sends it")
        expectEqual(decoded.counts, DockCounts(needsYou: 1, working: 0, total: 1, dismissed: 2))
        let old = try DockInbox.decode(Data(#"{"revision": 1, "counts": {"needsYou": 3, "working": 0, "total": 3}, "items": []}"#.utf8))
        expectEqual(old.counts.needsYou, 3, "counts from a bridge before W8 still decode (no fallback to the rows)")
        let plain = DockItem(id: "t3:x", source: "t3", title: "X", status: .error, can: ["reply"])
        expect(!plain.canDismiss, "a bridge that can't dismiss offers no ✕")
    }

    static func dismissHidesAtOnceUntilTheBridgeAgrees() throws {
        let now = Date()
        let failed = DockItem(id: "t3:failed", source: "t3", title: "Hermes", status: .error, updatedAt: now, can: ["reply", "dismiss"])
        let other = DockItem(id: "t3:other", source: "t3", title: "Greeting", status: .error, updatedAt: now, can: ["reply", "dismiss"])
        var state = DockDismissals()
        state.dismiss(failed, now: now)
        expectEqual(state.shown([failed, other]).map(\.id), ["t3:other"], "gone at once")
        expectEqual(state.toast?.kind, .dismissed)
        expectEqual(state.toast?.item.title, "Hermes")
        expect(state.toast?.offersUndo == true)
        // A long poll that still carries it (the bridge hadn't hidden it yet): still hidden here.
        state.apply(inbox(10, [failed, other]))
        expectEqual(state.shown([failed, other]).map(\.id), ["t3:other"])
        // The bridge's yes: its list leaves it out from revision 11.
        state.confirmed("t3:failed", revision: 11, current: 10)
        expect(state.isHidden("t3:failed"))
        state.apply(inbox(11, [other]))
        expect(!state.isHidden("t3:failed"), "from then on the bridge's list decides")
        // It changed and came back on the bridge: it shows again by itself.
        expectEqual(state.shown([failed, other]).map(\.id), ["t3:failed", "t3:other"])
        // A yes that arrives after the answer it settles: nothing is held back.
        state.dismiss(other, now: now)
        state.apply(inbox(12, []))
        state.confirmed("t3:other", revision: 12, current: 12)
        expect(!state.isHidden("t3:other"))
        expectEqual(state.shown([]).map(\.id), [])
    }

    static func dismissThatFailsComesBackAndSaysWhy() throws {
        let now = Date()
        let item = DockItem(id: "claude:s1", source: "claude", title: "Flaky test", status: .needsApproval, can: ["open", "dismiss"])
        var state = DockDismissals()
        state.dismiss(item, now: now)
        expectEqual(state.shown([item]).count, 0)
        state.failed(item.id, reason: "Couldn’t dismiss it: the Mac bridge isn’t answering.", now: now)
        expectEqual(state.shown([item]).map(\.id), ["claude:s1"], "rolled back")
        expectEqual(state.toast?.kind, .failed("Couldn’t dismiss it: the Mac bridge isn’t answering."))
        expect(state.toast?.offersUndo == false, "nothing to undo")
        var copy = state
        expectEqual(copy.undo(now: now), nil)
        // A failure the undo already took care of says nothing.
        var undone = DockDismissals()
        undone.dismiss(item, now: now)
        _ = undone.undo(now: now)
        undone.failed(item.id, reason: "x", now: now)
        expectEqual(undone.toast, nil)
        undone.undoNotNeeded(item.id)
        expectEqual(undone.shown([item]).map(\.id), ["claude:s1"])
    }

    static func undoBringsItBackUntilTheInboxHasIt() throws {
        let now = Date()
        let item = DockItem(id: "t3:done", source: "t3", title: "Release notes", status: .done, updatedAt: now, unread: true,
                            can: ["reply", "seen", "dismiss"])
        var state = DockDismissals()
        state.dismiss(item, now: now)
        state.confirmed(item.id, revision: 21, current: 20)
        state.apply(inbox(21, []))
        expectEqual(state.shown([]).count, 0, "the bridge hides it now")
        let back = state.undo(now: now)
        expectEqual(back?.id, "t3:done")
        expectEqual(state.toast, nil, "the toast goes with the undo")
        expectEqual(state.shown([]).map(\.id), ["t3:done"], "back at once, from the copy kept here")
        expectEqual(state.shown([]).first?.unread, true, "as unread as it was")
        state.apply(inbox(21, []))
        expectEqual(state.shown([]).map(\.id), ["t3:done"], "an older answer without it doesn't take it away")
        state.undoConfirmed(item.id, revision: 22, current: 21)
        var fresh = item
        fresh.summary = "from the bridge"
        state.apply(inbox(22, [fresh]))
        expectEqual(state.shown([fresh]).map(\.summary), ["from the bridge"], "the inbox's own copy once it has it")
        // An undo that fails: hidden again (the bridge still has it dismissed), and the toast says so.
        var failing = DockDismissals()
        failing.dismiss(item, now: now)
        _ = failing.undo(now: now)
        failing.undoFailed(item.id, reason: "Couldn’t bring it back: the Mac bridge isn’t answering.", now: now)
        expectEqual(failing.shown([]).count, 0)
        expectEqual(failing.toast?.offersUndo, false)
    }

    static func toastAndStaleEntriesExpire() throws {
        let now = Date()
        let item = DockItem(id: "t3:x", source: "t3", title: "X", status: .error, can: ["dismiss"])
        var state = DockDismissals()
        state.dismiss(item, now: now)
        state.tick(now: now.addingTimeInterval(DockDismissals.toastSeconds - 0.5))
        expect(state.toast != nil)
        state.tick(now: now.addingTimeInterval(DockDismissals.toastSeconds + 0.1))
        expectEqual(state.toast, nil, "the toast is short")
        expect(state.isHidden("t3:x"), "the row stays gone")
        state.tick(now: now.addingTimeInterval(DockDismissals.staleSeconds + 1))
        expect(!state.isHidden("t3:x"), "nothing settled it in 30 s: the inbox's own list again")
        expect(!state.hasWork)
    }
}
