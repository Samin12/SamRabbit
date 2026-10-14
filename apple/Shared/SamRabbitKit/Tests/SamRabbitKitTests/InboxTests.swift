import Foundation
import Testing
@testable import SamRabbitKit

/// `GET /v1/mobile/inbox` as the real bridge sends it to a phone (CONTRACTS-WAVE6 §A, WAVE7 C): every source, every
/// state, `can` without `open` (the phone never opens anything on the Mac's screen), plus a few things a lenient
/// reader must survive.
private let inboxJSON = """
{"revision": 1791955209038, "updatedAt": "2026-10-14T05:20:09Z",
 "counts": {"needsYou": 5, "working": 3, "total": 10},
 "sources": {"t3": {"connected": true}, "claude": {"available": true},
             "codex": {"available": false, "reason": "no_sessions"}, "samrabbit": {"available": true}},
 "items": [
  {"id": "chat:c_focus", "source": "samrabbit", "agent": null, "title": "Weekly focus review", "project": "R1",
   "status": "working", "statusLabel": "Answering", "summary": "You logged 18.5 hours", "updatedAt": "2026-10-14T05:20:00Z",
   "unread": false, "pending": {"approvals": [], "inputs": []}, "can": [], "live": true},
  {"id": "codex:desk-q", "source": "codex", "agent": "codex", "title": "Sketch onboarding copy", "project": "website",
   "cwd": "/Users/sam/website", "status": "needs-input", "statusLabel": "Has a question in Codex",
   "summary": "Which tone?", "updatedAt": "2026-10-14T05:10:00Z", "unread": true,
   "pending": {"approvals": [], "inputs": [{"requestId": "call_9", "questions": [
      {"id": "0", "header": "Question", "question": "Which tone?", "options": ["Warm", "Crisp"],
       "allowCustom": true, "multiSelect": false}]}]},
   "can": ["seen"], "live": false},
  {"id": "claude:flaky", "source": "claude", "agent": "claude", "title": "Investigate the flaky long-poll test",
   "project": "jackrabbit-src", "cwd": "/Users/sam/jackrabbit-src", "status": "needs-approval",
   "statusLabel": "Waiting for you in the terminal", "summary": "Bash: python3 -I -m unittest -k long_poll",
   "updatedAt": "2026-10-14T05:18:00Z", "unread": true,
   "pending": {"approvals": [{"requestId": "toolu_01", "kind": "command",
                              "detail": "Bash: python3 -I -m unittest -k long_poll", "options": []}], "inputs": []},
   "can": [], "live": true, "progress": null, "phase": null},
  {"id": "t3:t_deploy", "source": "t3", "agent": "codex", "title": "Deploy release 2.4 to staging",
   "project": "Assistant", "status": "needs-approval", "statusLabel": "Wants to run a command",
   "summary": "Run ./deploy.sh staging", "updatedAt": "2026-10-14T05:19:00Z", "unread": true,
   "pending": {"approvals": [{"requestId": "r1", "kind": "command", "detail": "Run ./deploy.sh staging",
     "options": [{"decision": "accept", "label": "Approve"}, {"decision": "decline", "label": "Deny"}]}], "inputs": []},
   "can": ["approve", "reply", "stop", "seen"], "live": false},
  {"id": "claude:changelog", "source": "claude", "agent": "claude", "title": "Summarize this week's merged PRs",
   "project": "website", "status": "done", "statusLabel": "Finished", "summary": "14 PRs in the draft.",
   "updatedAt": "2026-10-14T05:00:00Z", "unread": true, "can": ["reply", "seen"], "live": false},
  {"id": "claude:retry", "source": "claude", "agent": "claude", "title": "Add retry with backoff",
   "project": "jackrabbit-src", "status": "working", "statusLabel": "Working", "summary": "Editing…",
   "updatedAt": "2026-10-14T05:19:30Z", "unread": false, "can": [], "live": true},
  {"id": "codex:cli-idle", "source": "codex", "agent": "codex", "title": "Explain the relay",
   "project": "jackrabbit-src", "status": "idle", "statusLabel": "Idle", "summary": "",
   "updatedAt": "2026-10-13T20:00:00Z", "unread": false, "can": ["reply"], "live": false},
  {"id": "codex:desk-run", "source": "codex", "agent": "codex", "title": "Draft the pricing FAQ",
   "project": "website", "status": "working", "statusLabel": "Working", "summary": "Drafting…",
   "updatedAt": "2026-10-14T05:15:00Z", "unread": false, "can": [], "live": false},
  {"id": "claude:open-done", "source": "claude", "agent": "claude", "title": "Rename the tokens file",
   "project": "jackrabbit-src", "status": "done", "statusLabel": "Finished", "summary": "Renamed.",
   "updatedAt": "2026-10-14T05:05:00Z", "unread": true, "can": ["seen"], "live": true},
  {"title": "no id: dropped"},
  {"id": "t3:t_odd", "source": "t3", "title": "Mystery", "status": "teleporting", "updatedAt": "2026-10-14T04:00:00Z"}
 ]}
"""

private func snapshot(_ json: String = inboxJSON) throws -> InboxSnapshot {
    try BridgeJSON.decode(InboxSnapshot.self, from: Data(json.utf8))
}

private func item(_ id: String, in snapshot: InboxSnapshot) throws -> InboxItem {
    try #require(snapshot.items.first { $0.id == id })
}

@Suite("The inbox: every agent on the Mac")
struct InboxTests {
    @Test func decodesEverySourceInTheContractsOrder() throws {
        let inbox = try snapshot()
        #expect(inbox.revision == 1_791_955_209_038)
        #expect(inbox.updatedAt == BridgeDates.date(from: "2026-10-14T05:20:09Z"))
        // The id-less item is dropped; the rest in order: approvals (newest first), questions, errors, finished and
        // unread, working, then the rest.
        #expect(inbox.items.map(\.id) == [
            "t3:t_deploy", "claude:flaky", "codex:desk-q", "claude:open-done", "claude:changelog",
            "chat:c_focus", "claude:retry", "codex:desk-run", "t3:t_odd", "codex:cli-idle",
        ])
        let flaky = try item("claude:flaky", in: inbox)
        #expect(flaky.source == .claude && flaky.agent == "claude")
        #expect(flaky.key == "flaky")
        #expect(flaky.live)
        #expect(flaky.cwd == "/Users/sam/jackrabbit-src")
        #expect(flaky.pending.approvals.first?.requestId == "toolu_01")
        #expect(flaky.pending.approvals.first?.kindLabel == "Wants to run a command")
        #expect(flaky.pendingRequestId == "toolu_01")
        #expect(try item("t3:t_odd", in: inbox).status == .unknown)
        #expect(try item("chat:c_focus", in: inbox).isChat)
        #expect(inbox.agentItems.count == 9)
        #expect(!inbox.agentItems.contains { $0.isChat })
        // Sources: T3 connected, Codex not available (with why).
        #expect(inbox.t3Connected)
        #expect(inbox.t3Problem == nil)
        #expect(inbox.sources["codex"] == InboxSourceState(ok: false, reason: "no_sessions"))
        #expect(inbox.sources["claude"]?.ok == true)
    }

    /// What the phone may do with a Claude Code or Codex item, read from `can` (never `open`) and `live`.
    @Test func whereEachAgentWaits() throws {
        let inbox = try snapshot()
        // A permission prompt in the CLI's terminal: only the terminal answers it.
        let flaky = try item("claude:flaky", in: inbox)
        #expect(flaky.heldOnMac == .waitingInTerminal)
        #expect(InboxHold.waitingInTerminal.headline(flaky) == "Waiting for you in the terminal")
        #expect(flaky.needsYou && flaky.supports(.reply) == false)
        // A Codex Desktop thread asking: the app answers it; it can be marked seen.
        let question = try item("codex:desk-q", in: inbox)
        #expect(question.heldOnMac == .waitingInApp)
        #expect(InboxHold.waitingInApp.headline(question) == "Waiting for you in the Codex app")
        #expect(question.supports(.seen))
        // Live in a terminal (working, or finished and still open there).
        #expect(try item("claude:retry", in: inbox).heldOnMac == .openInTerminal)
        #expect(try item("claude:open-done", in: inbox).heldOnMac == .openInTerminal)
        // A Codex Desktop thread at work: the app's.
        #expect(try item("codex:desk-run", in: inbox).heldOnMac == .ownedByApp)
        // Nobody holds these: a reply continues them on the Mac.
        #expect(try item("claude:changelog", in: inbox).heldOnMac == nil)
        #expect(try item("codex:cli-idle", in: inbox).heldOnMac == nil)
        // T3 acts through its own routes.
        #expect(try item("t3:t_deploy", in: inbox).heldOnMac == nil)
        // A prompt whose label doesn't say where gets ours.
        var unlabeled = flaky
        unlabeled.statusLabel = "Needs approval"
        #expect(InboxHold.waitingInTerminal.headline(unlabeled) == "Waiting for you in the terminal")
        var question2 = flaky
        question2.status = .needsInput
        question2.statusLabel = "Has a question in the terminal"
        #expect(question2.heldOnMac == .waitingInTerminal)
        #expect(InboxHold.waitingInTerminal.headline(question2) == "Has a question in the terminal")
    }

    /// A T3 item is the thread the T3 screens know, with the request the inbox showed (so Approve answers exactly it).
    @Test func t3ItemsBecomeTheirThreads() throws {
        let inbox = try snapshot()
        let deploy = try #require(try item("t3:t_deploy", in: inbox).taskThread)
        #expect(deploy.threadId == "t_deploy")
        #expect(deploy.status == .needsApproval)
        #expect(deploy.projectName == "Assistant")
        #expect(deploy.pending?.kind == .approval)
        #expect(deploy.pending?.requestId == "r1")
        #expect(deploy.pending?.canRespond == true)
        #expect(try item("claude:flaky", in: inbox).taskThread == nil)
        #expect(try item("claude:flaky", in: inbox).threadId == nil)

        // And back: an older bridge's thread list as inbox rows, T3 only.
        let question = TaskThread(threadId: "t_q", title: "Fix login", projectName: "Website", status: .needsInput,
                                  updatedAt: .now, summary: nil,
                                  pending: PendingAction(kind: .question, text: "Where should people land?",
                                                         options: [PendingOption(value: "/home")], requestId: "q1",
                                                         questionId: "qa"))
        let row = InboxItem(thread: question)
        #expect(row.id == "t3:t_q" && row.source == .t3)
        #expect(row.supports(.answer) && row.supports(.stop))
        #expect(row.pending.inputs.first?.requestId == "q1")
        #expect(row.pending.inputs.first?.questions.first?.id == "qa")
        #expect(row.taskThread?.pending?.questionId == "qa")
        let older = InboxSnapshot.fromThreads([question, TaskThread(threadId: "t_w", title: "W", status: .working)])
        #expect(older.items.map(\.id) == ["t3:t_q", "t3:t_w"])
        #expect(older.counts == InboxCounts(needsYou: 1, working: 1, total: 2))
        // A summary thread (no request id) keeps what it waits on as words, and can't be answered from a card.
        let summaryThread = TaskThread(threadId: "t_s", title: "S", status: .needsApproval,
                                       pending: PendingAction(kind: .approval, text: "Deploy prod?"))
        let summaryRow = InboxItem(thread: summaryThread)
        #expect(summaryRow.pending.isEmpty)
        #expect(summaryRow.summary == "Deploy prod?")
    }

    /// The counts Home, the badge and the widgets show: the agents' rows (a chat answering is not an agent at work),
    /// plus what the bridge counts beyond the 60 items it sends.
    @Test func countsComeFromTheAgentsRows() throws {
        let inbox = try snapshot()
        #expect(inbox.shownCounts == InboxCounts(needsYou: 5, working: 2, total: 9))
        let overview = inbox.overview(top: 3)
        #expect(overview.needsYou == 5 && overview.working == 2 && overview.total == 9)
        #expect(overview.items.map(\.id) == ["t3:t_deploy", "claude:flaky", "codex:desk-q"])

        // 75 items on the Mac, 60 sent: what lies past the cap still counts.
        var items: [String] = []
        for index in 0..<75 {
            items.append("""
            {"id":"claude:s\(index)","source":"claude","title":"S\(index)","status":"\(index < 20 ? "needs-approval" : "working")",
             "updatedAt":"2026-10-14T05:\(String(format: "%02d", index % 60)):00Z","can":[],"live":true}
            """)
        }
        let big = try snapshot("""
        {"revision": 7, "counts": {"needsYou": 20, "working": 55, "total": 75}, "items": [\(items.joined(separator: ","))]}
        """)
        #expect(big.items.count == InboxSnapshot.itemCap)
        #expect(big.shownCounts == InboxCounts(needsYou: 20, working: 55, total: 75))

        // No counts at all: counted from the items.
        let bare = try snapshot("""
        {"revision": 3, "items": [{"id":"codex:x","title":"X","status":"error","unread":true},
                                  {"id":"chat:y","title":"Y","status":"working"}]}
        """)
        #expect(bare.counts == InboxCounts(needsYou: 1, working: 0, total: 2))
        #expect(bare.items.first?.source == .codex)
        #expect(bare.items.last?.source == .samrabbit) // `chat:` ids are SamRabbit's
    }

    /// T3 Code not answering: the others stay, the T3 part says why.
    @Test func t3DownIsAProblemOnlyForT3() throws {
        let inbox = try snapshot("""
        {"revision": 9, "sources": {"t3": {"connected": false, "reason": "t3_unavailable"}, "claude": {"available": true}},
         "items": [{"id":"claude:a","source":"claude","title":"A","status":"done","unread":true,"can":["reply","seen"]}]}
        """)
        #expect(!inbox.t3Connected)
        let problem = try #require(inbox.t3Problem)
        #expect(problem.code == "t3_unavailable")
        #expect(problem.isRetryable)
        #expect(inbox.agentItems.count == 1)
    }

    /// The iPhone puts the inbox's counts into the summary for Home, the orb, Siri and the widgets; a hiccup keeps
    /// the last ones, an older bridge (404) leaves T3's.
    @Test func theSummaryCarriesTheInbox() throws {
        let inbox = try snapshot()
        var plain = MobileSummary.sample()
        plain.inbox = nil
        plain.t3.needsYou = 0
        plain.t3.working = 0
        #expect(plain.needsYouCount == 0)
        #expect(OrbMood.from(plain) == .idle || plain.r1.live)
        plain.r1.live = false

        let merged = plain.with(inbox: inbox)
        #expect(merged.needsYouCount == 5)
        #expect(merged.workingCount == 2)
        #expect(merged.inbox?.items.count == 5)
        #expect(OrbMood.from(merged) == .attention)

        let kept = try #require(merged.inbox)
        let hiccup = plain.with(inbox: .failure(.unreachable("timed out")), kept: kept)
        #expect(hiccup.inbox == kept)
        let older = plain.with(inbox: .failure(.server(status: 404, code: "not_found", message: "", retryable: false)),
                               kept: kept)
        #expect(older.inbox == nil)
        #expect(older.needsYouCount == plain.t3.needsYou)
        #expect(plain.with(inbox: .failure(.unreachable("x")), kept: nil).inbox == nil)
        // A bridge that sends its own `inbox` in the summary keeps it.
        #expect(merged.with(inbox: .failure(.unreachable("x")), kept: nil).inbox == kept)
        #expect(plain.with(inbox: Result<InboxSnapshot, BridgeError>.success(inbox), kept: nil).inbox == kept)

        let decoded = try BridgeJSON.decode(MobileSummary.self, from: Data("""
        {"t3": {"needsYou": 1, "working": 0}, "inbox": {"counts": {"needsYou": 4, "working": 2, "total": 7}, "items": []}}
        """.utf8))
        #expect(decoded.needsYouCount == 4 && decoded.workingCount == 2)
        #expect(decoded.inbox?.total == 7)
    }

    /// The App Group cache (the widgets read it) keeps every inbox field.
    @Test func theInboxSurvivesTheWidgetsCache() throws {
        let base = try BridgeJSON.decode(MobileSummary.self, from: Data(DecodingTests.summaryJSON.utf8))
        let summary = base.with(inbox: try snapshot())
        let cache = SummaryCache(container: .temporary())
        cache.save(summary, at: Date(timeIntervalSince1970: 1_800_000_000))
        let entry = try #require(cache.load())
        #expect(entry.summary == summary)
        #expect(entry.summary.inbox?.items.first { $0.id == "claude:flaky" }?.heldOnMac == .waitingInTerminal)
        #expect(entry.summary.inbox?.items.first { $0.id == "codex:desk-q" }?.pending.inputs.first?.questions.first?
            .options == ["Warm", "Crisp"])
        // The sample the widget gallery and previews use covers every source.
        let sources = Set(MobileSummary.sample().inbox?.items.map(\.source) ?? [])
        #expect(sources == [.t3, .claude, .codex])
    }

    /// "What needs me" (Siri, the intents) counts every agent and says where a terminal waits.
    @Test func whatNeedsMeNamesEveryAgent() throws {
        let now = BridgeDates.date(from: "2026-10-14T05:20:30Z")!
        var summary = MobileSummary(generatedAt: now).with(inbox: try snapshot())
        summary.calendar.next = []
        #expect(SpokenSummary.whatNeedsMe(summary, now: now) ==
            "Five tasks need you: approve “Deploy release 2.4 to staging”, approve “Investigate the flaky long-poll test” "
            + "in the terminal and answer “Sketch onboarding copy” in the Codex app. Two are working.")
        summary.inbox = InboxOverview()
        #expect(SpokenSummary.whatNeedsMe(summary, now: now) == "Nothing needs you right now.")
    }

    @Test func itemDetailsHaveStableIds() throws {
        let detail = try BridgeJSON.decode(InboxItemDetail.self, from: Data("""
        {"item": {"id": "claude:changelog", "source": "claude", "title": "Changelog", "status": "done", "can": ["reply"]},
         "messages": [{"role": "user", "text": "Summarize the PRs", "at": "2026-10-14T05:00:00Z"},
                      {"role": "assistant", "text": "", "at": "2026-10-14T05:00:10Z"},
                      {"role": "assistant", "text": "Done. **14 PRs**", "at": "2026-10-14T05:01:00Z"},
                      {"role": "assistant", "text": "Want a PR?", "at": "2026-10-14T05:01:00Z"}]}
        """.utf8))
        #expect(detail.item.id == "claude:changelog")
        #expect(detail.messages.count == 3) // the empty one is dropped
        #expect(Set(detail.messages.map(\.id)).count == 3)
        let again = try BridgeJSON.decode(InboxItemDetail.self, from: try BridgeJSON.encoder().encode(detail))
        #expect(again.messages.map(\.id) == detail.messages.map(\.id))
        #expect(throws: (any Error).self) {
            _ = try BridgeJSON.decode(InboxItemDetail.self, from: Data(#"{"messages": []}"#.utf8))
        }
    }

    @Test func targetsRepliesAndNewTasks() throws {
        let targets = try BridgeJSON.decode(InboxTargets.self, from: Data("""
        {"projects": [{"id": "p_site", "title": "Website", "lastActiveAt": "2026-10-14T05:00:00Z"}, {"id": "", "title": "x"}],
         "agents": [{"id": "claude", "label": "Claude", "models": [{"id": "claude-opus-5-5", "label": "Claude Opus 5.5"}]},
                    {"id": "codex", "models": [{"id": "gpt-5.5-codex", "label": "GPT-5.5 Codex"}, {"label": "no id"}]}],
         "default": {"projectId": "p_site", "agent": "codex", "model": "gpt-5.5-codex"}}
        """.utf8))
        #expect(targets.projects.map(\.title) == ["Website"])
        #expect(targets.agents.map(\.id) == ["claude", "codex"])
        #expect(targets.agent("codex")?.label == "Codex")
        #expect(targets.agent("codex")?.models.map(\.id) == ["gpt-5.5-codex"])
        #expect(targets.defaultChoice == InboxTargets.Choice(projectId: "p_site", agent: "codex", model: "gpt-5.5-codex"))
        #expect(try BridgeJSON.decode(InboxTargets.self, from: try BridgeJSON.encoder().encode(targets)) == targets)

        let terminal = try BridgeJSON.decode(InboxReplyResult.self, from: Data(
            #"{"ok": true, "how": "terminal", "message": "It continues in a new Terminal window on the Mac."}"#.utf8))
        #expect(terminal.resumedInTerminal && !terminal.dryRun)
        #expect(terminal.message == "It continues in a new Terminal window on the Mac.")
        let dry = try BridgeJSON.decode(InboxReplyResult.self, from: Data(#"{"ok":true,"how":"terminal","dryRun":true}"#.utf8))
        #expect(dry.dryRun && dry.message == nil)
        #expect(!(try BridgeJSON.decode(InboxReplyResult.self, from: Data(#"{"ok":true,"how":"t3"}"#.utf8))).resumedInTerminal)

        let created = try BridgeJSON.decode(CreatedInboxTask.self, from: Data(
            #"{"itemId": "t3:t_new", "title": "Dark mode", "projectName": "Website"}"#.utf8))
        #expect(created.threadId == "t_new" && created.projectName == "Website")
        let fromThread = try BridgeJSON.decode(CreatedInboxTask.self, from: Data(#"{"threadId": "t_x"}"#.utf8))
        #expect(fromThread.itemId == "t3:t_x")
    }

    @Test func errorsLinksAndPaths() {
        #expect(BridgeError.server(status: 404, code: "not_found", message: "", retryable: false).isRouteMissing)
        #expect(!BridgeError.server(status: 404, code: "item_not_found", message: "", retryable: false).isRouteMissing)
        #expect(!BridgeError.unreachable("x").isRouteMissing)
        #expect(BridgeError.server(status: 409, code: "session_live", message: "", retryable: false).isSessionLive)
        #expect(!BridgeError.server(status: 409, code: "unsupported_action", message: "", retryable: false).isSessionLive)

        #expect(AppLink(url: URL(string: "samrabbit://inbox/claude:5d0c6f2e-1a47")!) == .inbox("claude:5d0c6f2e-1a47"))
        #expect(AppLink(url: URL(string: "samrabbit://inbox")!) == .inbox(nil))

        #expect(BridgeClient.inboxPath("claude:5d0c") == "/v1/mobile/inbox/items/claude:5d0c")
        #expect(BridgeClient.inboxPath("codex:a/b c", "reply") == "/v1/mobile/inbox/items/codex:a%2Fb%20c/reply")
    }

    /// Claude Code and Codex prompts are announced once per request, open the item, and say where to answer; finished
    /// sessions, T3 items given as agents and items without a request are not.
    @Test func agentPromptsAreAnnouncedOnce() throws {
        let inbox = try snapshot()
        let agents = inbox.agentItems
        let first = AlertPlanner.plan(threads: [], agents: agents, announced: [:], tracked: [])
        #expect(first.alerts.map(\.id) == ["needs:claude:flaky|toolu_01", "needs:codex:desk-q|call_9"])
        let flaky = try #require(first.alerts.first)
        #expect(flaky.title == "Investigate the flaky long-poll test")
        #expect(flaky.body == "Waiting for you in the terminal: Bash: python3 -I -m unittest -k long_poll")
        #expect(flaky.link == "samrabbit://inbox/claude:flaky")
        #expect(first.alerts.last?.body == "Waiting for you in the Codex app: Which tone?")
        // Once.
        #expect(AlertPlanner.plan(threads: [], agents: agents, announced: first.announced, tracked: []).alerts.isEmpty)
        // A new prompt on the same session: again.
        var next = try item("claude:flaky", in: inbox)
        next.pending = InboxPending(approvals: [InboxApproval(requestId: "toolu_02", kind: "file_change")])
        let second = AlertPlanner.plan(threads: [], agents: [next], announced: first.announced, tracked: [])
        #expect(second.alerts.map(\.body) == ["Waiting for you in the terminal: Wants to change files"])
        // No request id: nothing to key it on.
        next.pending = InboxPending()
        #expect(AlertPlanner.plan(threads: [], agents: [next], announced: [:], tracked: []).alerts.isEmpty)
        // T3 threads keep their own links.
        let t3 = AlertPlanner.plan(threads: [try #require(try item("t3:t_deploy", in: inbox).taskThread)],
                                   agents: agents, announced: first.announced, tracked: [])
        #expect(t3.alerts.map(\.link) == ["samrabbit://thread/t_deploy"])
    }

    /// Opening a finished or failed item marks it seen once per state; what it looks like then is what the bridge
    /// says next (a Claude Code or Codex failure settles, a T3 one stays an error until T3 settles it).
    @Test func seeingAnItem() throws {
        let inbox = try snapshot()
        let changelog = try item("claude:changelog", in: inbox)
        let mark = try #require(changelog.seenMark)
        #expect(mark == "claude:changelog@1791954000000")
        // Finished again later (a new turn): a new mark, so it is marked again.
        var again = changelog
        again.updatedAt = changelog.updatedAt?.addingTimeInterval(90)
        #expect(again.seenMark != mark)
        // Nothing to mark: a Claude Code prompt (only the terminal answers it), something already seen, working.
        #expect(try item("claude:flaky", in: inbox).seenMark == nil)
        #expect(try item("codex:cli-idle", in: inbox).seenMark == nil)
        #expect(try item("claude:retry", in: inbox).seenMark == nil)

        let seen = changelog.markedSeen
        #expect(!seen.unread && !seen.supports(.seen) && seen.supports(.reply))
        #expect(seen.status == .done && !seen.needsYou && seen.seenMark == nil)
        var failed = changelog
        failed.status = .error
        #expect(failed.needsYou)
        #expect(failed.markedSeen.status == .idle && !failed.markedSeen.needsYou)
        var t3Failed = try item("t3:t_deploy", in: inbox)
        t3Failed.status = .error
        #expect(t3Failed.markedSeen.status == .error && t3Failed.markedSeen.needsYou)
        #expect(!t3Failed.markedSeen.supports(.seen))
    }

    /// A screen reads its item again when that item moved on: not for every line a working agent writes (its time),
    /// but for a new state, request, owner, what it can do, or a finished one's new time.
    @Test func whenAScreenReadsAgain() throws {
        let inbox = try snapshot()
        let retry = try item("claude:retry", in: inbox)
        var wrote = retry
        wrote.updatedAt = retry.updatedAt?.addingTimeInterval(2)
        wrote.summary = "Editing the next file…"
        #expect(wrote.changeMark == retry.changeMark)
        var finished = retry
        finished.status = .done
        #expect(finished.changeMark != retry.changeMark)
        var closed = retry
        closed.live = false
        closed.can = ["reply"]
        #expect(closed.changeMark != retry.changeMark)
        let changelog = try item("claude:changelog", in: inbox)
        var later = changelog
        later.updatedAt = changelog.updatedAt?.addingTimeInterval(60)
        #expect(later.changeMark != changelog.changeMark)
        #expect(changelog.markedSeen.changeMark != changelog.changeMark)
        var asked = try item("claude:flaky", in: inbox)
        let first = asked.changeMark
        asked.pending = InboxPending(approvals: [InboxApproval(requestId: "toolu_02")])
        #expect(asked.changeMark != first)
    }

    /// When the Mac couldn't check its process list, a Claude Code session arrives with neither `live` nor `reply`:
    /// the phone says it can't tell, not that a terminal owns it.
    @Test func whenTheMacCantTellWhoRunsIt() throws {
        let inbox = try snapshot("""
        {"revision": 4, "items": [
          {"id": "claude:unsure", "source": "claude", "title": "U", "status": "done", "statusLabel": "Finished",
           "unread": true, "can": ["seen"], "live": false},
          {"id": "claude:unsure-idle", "source": "claude", "title": "V", "status": "idle", "can": [], "live": false},
          {"id": "codex:unsure", "source": "codex", "title": "W", "status": "done", "can": [], "live": false}]}
        """)
        let unsure = try item("claude:unsure", in: inbox)
        #expect(unsure.heldOnMac == .unknownOnMac)
        #expect(InboxHold.unknownOnMac.headline(unsure) == "Can't tell if it's open on your Mac")
        #expect(InboxHold.unknownOnMac.detail(unsure).contains("Try again in a moment"))
        #expect(try item("claude:unsure-idle", in: inbox).heldOnMac == .unknownOnMac)
        // A Codex item looks the same as a Codex Desktop thread: the app's (nothing in it tells them apart).
        #expect(try item("codex:unsure", in: inbox).heldOnMac == .ownedByApp)
        #expect(BridgeError.server(status: 503, code: "session_check_failed", message: "", retryable: true)
            .isSessionCheckFailed)
        #expect(!BridgeError.server(status: 409, code: "session_live", message: "", retryable: false)
            .isSessionCheckFailed)
    }

    /// T3 Code down: its last rows stay, read-only and counted nowhere (like the bridge's counts and the widgets);
    /// an inbox that fails gets T3's own list beside the others' last rows.
    @Test func t3sLastRowsWhileItIsDown() throws {
        let up = try snapshot()
        let shown = InboxRows(up, previous: [])
        #expect(!shown.t3Stale && shown.items == up.agentItems && shown.stale.isEmpty)
        #expect(shown.needsYou == 5 && shown.working == 2)

        let down = try snapshot("""
        {"revision": 1791955209100, "sources": {"t3": {"connected": false, "reason": "t3_unavailable"}},
         "counts": {"needsYou": 1, "working": 0, "total": 1},
         "items": [{"id":"claude:a","source":"claude","title":"A","status":"done","unread":true,"can":["reply","seen"],
                    "updatedAt":"2026-10-14T05:21:00Z"}]}
        """)
        let kept = InboxRows(down, previous: shown.items)
        #expect(kept.t3Stale)
        #expect(kept.stale.map(\.id) == ["t3:t_deploy", "t3:t_odd"])
        #expect(kept.live.map(\.id) == ["claude:a"])
        #expect(kept.items.first?.id == "t3:t_deploy") // still in the contract's order
        #expect(kept.needsYou == 1 && kept.needsYou == down.overview().needsYou) // as the widgets count
        // The previous Claude Code and Codex rows are not kept: the inbox has them fresh.
        #expect(!kept.items.contains { $0.id == "claude:flaky" })
        // Down from the start: nothing to keep, nothing stale.
        #expect(!InboxRows(down, previous: []).t3Stale)
        // Back up: fresh rows.
        #expect(InboxRows(up, previous: kept.items) == shown)

        let threads = [TaskThread(threadId: "t_new", title: "New", status: .needsApproval,
                                  updatedAt: BridgeDates.date(from: "2026-10-14T05:30:00Z"),
                                  pending: PendingAction(kind: .approval, text: "Run it?", requestId: "r9"))]
        let fallback = InboxRows(threads: threads, keeping: shown.items)
        #expect(!fallback.t3Stale)
        #expect(fallback.items.filter { $0.source == .t3 }.map(\.id) == ["t3:t_new"])
        #expect(fallback.items.filter { $0.source != .t3 }.map(\.id) == shown.items.filter { $0.source != .t3 }.map(\.id))
        #expect(fallback.items.first?.id == "t3:t_new")
    }

    /// A list built before the shown one (the 20 s refresh landing after the long-poll), or the same one, changes
    /// nothing; a restarted bridge starts from its time in milliseconds, so it is later.
    @Test func olderListsChangeNothing() throws {
        let shown = try snapshot()
        var older = shown
        older.revision -= 1
        var newer = shown
        newer.revision += 1
        #expect(shown.isNewer(than: nil))
        #expect(newer.isNewer(than: shown))
        #expect(!shown.isNewer(than: shown))
        #expect(!older.isNewer(than: shown))
    }

    /// Prompts only the Mac answers come as normal alerts (not time-sensitive); the bridge's guesses aren't
    /// announced; a prompt without a known tool call is keyed by when it started waiting.
    @Test func agentAlertsAreQuietAboutWhatOnlyTheMacAnswers() throws {
        let inbox = try snapshot()
        let plan = AlertPlanner.plan(threads: [try #require(try item("t3:t_deploy", in: inbox).taskThread)],
                                     agents: inbox.agentItems, announced: [:], tracked: [])
        #expect(plan.alerts.map(\.onlyOnMac) == [false, true, true]) // T3's, then the terminal's and the app's

        // "May be waiting": a quiet Codex tool call, as a long build is. Listed, not announced.
        var guess = try item("codex:desk-q", in: inbox)
        guess.status = .needsApproval
        guess.statusLabel = "May be waiting for you in the terminal"
        guess.pending = InboxPending(approvals: [InboxApproval(requestId: "call_build", kind: "command",
                                                               detail: "Wants to run: make test")])
        #expect(guess.isGuess && guess.needsYou)
        #expect(AlertPlanner.plan(threads: [], agents: [guess], announced: [:], tracked: []).alerts.isEmpty)

        // A prompt only Claude Code's registry reports (the stand-in id "terminal"): one alert per wait.
        var registry = try item("claude:flaky", in: inbox)
        registry.pending = InboxPending(approvals: [InboxApproval(requestId: "terminal")])
        let first = AlertPlanner.plan(threads: [], agents: [registry], announced: [:], tracked: [])
        #expect(first.alerts.map(\.id) == ["needs:claude:flaky|terminal@1791955080000"])
        #expect(AlertPlanner.plan(threads: [], agents: [registry], announced: first.announced, tracked: []).alerts.isEmpty)
        var next = registry
        next.updatedAt = registry.updatedAt?.addingTimeInterval(600)
        #expect(AlertPlanner.plan(threads: [], agents: [next], announced: first.announced, tracked: []).alerts.count == 1)
    }

    /// The revision starts from the time in milliseconds: 64-bit on the watch's 32-bit hardware too.
    @Test func noIntOverflowsOn32BitWatches() throws {
        let inbox = try snapshot()
        #expect(Int32Range.violations(in: inbox).isEmpty)
        #expect(Int32Range.violations(in: MobileSummary.sample().with(inbox: inbox)).isEmpty)
    }

    // MARK: dismissing (W8)

    /// A dismissed item is never a row; `counts.dismissed` is read (0 from an older bridge); `dismiss` in `can` is
    /// what offers it, so a bridge before it offers nothing.
    @Test func dismissedItemsAndCounts() throws {
        let json = """
        {"revision": 9, "counts": {"needsYou": 1, "working": 0, "total": 1, "dismissed": 2},
         "items": [{"id": "t3:a", "source": "t3", "title": "A", "status": "error", "can": ["reply", "dismiss"]},
                   {"id": "t3:b", "source": "t3", "title": "B", "status": "error", "can": ["undismiss"], "dismissed": true}]}
        """
        let decoded = try snapshot(json)
        #expect(decoded.items.map(\.id) == ["t3:a"])
        #expect(decoded.counts.dismissed == 2)
        #expect(try item("t3:a", in: decoded).canDismiss)
        #expect(try snapshot().counts.dismissed == 0)
        let older = try item("t3:t_deploy", in: try snapshot())
        #expect(!older.canDismiss, "an older bridge: no dismiss in can")
        let result = try BridgeJSON.decode(InboxDismissResult.self,
                                           from: Data(#"{"ok": true, "dismissed": true, "revision": 1791955209040}"#.utf8))
        #expect(result == InboxDismissResult(dismissed: true, revision: 1_791_955_209_040))
        #expect(try BridgeJSON.decode(InboxDismissResult.self, from: Data(#"{"ok": true}"#.utf8)).revision == nil)
    }

    /// Gone at once; kept gone until the bridge's list at the revision its yes gave; from then on that list decides,
    /// so an item that changed is back by itself. A refusal puts it back; nothing settled in 30 s lets go.
    @Test func dismissingHidesUntilTheBridgeDecides() throws {
        let inbox = try snapshot()
        let deploy = try item("t3:t_deploy", in: inbox)
        let now = Date.now
        var dismissals = InboxDismissals()
        dismissals.dismiss(deploy, now: now)
        #expect(!dismissals.shown(inbox.items).contains { $0.id == deploy.id })
        #expect(dismissals.shown(inbox.items).count == inbox.items.count - 1)
        dismissals.apply(inbox)
        #expect(dismissals.isHidden(deploy.id), "an answer from before the bridge hid it")
        dismissals.confirmed(deploy.id, revision: inbox.revision + 1, current: inbox.revision)
        var without = inbox
        without.revision += 1
        without.items.removeAll { $0.id == deploy.id }
        dismissals.apply(without)
        #expect(!dismissals.isHidden(deploy.id), "the bridge decides from here")
        var back = inbox
        back.revision += 2
        #expect(dismissals.shown(back.items).contains { $0.id == deploy.id }, "it changed: back by itself")
        // A yes after the answer it settles holds nothing back.
        dismissals.dismiss(deploy, now: now)
        dismissals.confirmed(deploy.id, revision: back.revision, current: back.revision)
        #expect(!dismissals.isHidden(deploy.id))
        // A refusal puts it back.
        dismissals.dismiss(deploy, now: now)
        let putBack = dismissals.failed(deploy.id)
        #expect(putBack)
        #expect(dismissals.shown(inbox.items).contains { $0.id == deploy.id })
        let again = dismissals.failed(deploy.id)
        #expect(!again, "nothing left to put back")
        // Nothing settles it in 30 s.
        dismissals.dismiss(deploy, now: now)
        let early = dismissals.tick(now: now.addingTimeInterval(29))
        #expect(!early)
        let late = dismissals.tick(now: now.addingTimeInterval(InboxDismissals.staleSeconds))
        #expect(late)
        #expect(dismissals.isEmpty)
    }

    /// The undo: back at once, as it was, until the inbox carries it again; a failed undo hides it again; an undo
    /// of a dismissal that never happened leaves the inbox's own row.
    @Test func undoBringsItBack() throws {
        let inbox = try snapshot()
        let changelog = try item("claude:changelog", in: inbox)
        var without = inbox
        without.revision += 1
        without.items.removeAll { $0.id == changelog.id }
        var dismissals = InboxDismissals()
        dismissals.dismiss(changelog)
        dismissals.confirmed(changelog.id, revision: without.revision, current: inbox.revision)
        dismissals.apply(without)
        #expect(!dismissals.shown(without.items).contains { $0.id == changelog.id })
        let back = dismissals.undo(changelog)
        #expect(back.unread, "as unread as it was")
        #expect(dismissals.shown(without.items).contains { $0.id == changelog.id }, "at once, from the copy")
        #expect(dismissals.shown(without.items).map(\.id) == InboxSnapshot.ordered(without.items + [changelog]).map(\.id),
                "in the contract's order")
        dismissals.apply(without)
        #expect(dismissals.shown(without.items).contains { $0.id == changelog.id })
        dismissals.undoConfirmed(changelog.id, revision: without.revision + 1, current: without.revision)
        var again = inbox
        again.revision = without.revision + 1
        dismissals.apply(again)
        #expect(dismissals.isEmpty, "the inbox carries it again")
        dismissals.dismiss(changelog)
        dismissals.undo(changelog)
        dismissals.undoFailed(changelog.id)
        #expect(!dismissals.shown(inbox.items).contains { $0.id == changelog.id }, "the Mac still keeps it dismissed")
        dismissals.undo(changelog)
        dismissals.undoNotNeeded(changelog.id)
        #expect(dismissals.shown(inbox.items).filter { $0.id == changelog.id }.count == 1)
    }
}

#if os(macOS)
/// The client's inbox routes against `apple/dev/fake_bridge.py` (the same rules as the real bridge's phone routes).
@Suite("The inbox against the fake bridge", .serialized)
struct InboxBridgeTests {
    static let flaky = "claude:5d0c6f2e-1a47-4f7e-9a51-3c2b1e0d9f88"
    static let changelog = "claude:8b1e2c3d-4f5a-4b6c-8d7e-9f0a1b2c3d4e"
    static let pytest = "codex:019a1f2e-3d4c-7b5a-9687-a5b4c3d2e1f0"
    static let onboarding = "codex:019a6c7d-8e9f-7a01-b2c3-d4e5f6a7b8c9"

    @Test func listsEverySourceWithoutOpen() async throws {
        let bridge = try FakeBridgeProcess()
        let (client, _) = try await bridge.pairedClient()
        let inbox = try await client.inbox()
        #expect(Set(inbox.items.map(\.source)) == [.t3, .claude, .codex, .samrabbit])
        #expect(!inbox.items.contains { $0.supports(.open) })
        #expect(inbox.t3Connected)
        #expect(inbox.items.first?.status == .needsApproval)
        let flaky = try #require(inbox.items.first { $0.id == Self.flaky })
        #expect(flaky.heldOnMac == .waitingInTerminal)
        #expect(flaky.live)
        #expect(try #require(inbox.items.first { $0.id == Self.onboarding }).heldOnMac == .ownedByApp)
        #expect(try #require(inbox.items.first { $0.id == Self.changelog }).supports(.reply))
        #expect(inbox.shownCounts.needsYou == 7)
        #expect(inbox.shownCounts.needsYou == inbox.counts.needsYou)
        // Opening is the Mac's own.
        let opened = try await client.raw(.post(BridgeClient.inboxPath(Self.flaky, "open"), body: [:]))
        #expect(opened.status == 409)
        #expect(try JSONDecoder().decode(JSONValue.self, from: opened.body)["error"]["code"].string == "unsupported_action")
    }

    /// `?after=<revision>&wait=` answers at once when the list moved, after `wait` with the same list otherwise, and
    /// wakes up when something changes meanwhile.
    @Test func theLongPollWakesUpOnAChange() async throws {
        let bridge = try FakeBridgeProcess()
        let (client, _) = try await bridge.pairedClient()
        let first = try await client.inbox()
        let started = Date.now
        let same = try await client.inbox(after: first.revision, wait: 1)
        #expect(same.revision == first.revision)
        #expect(Date.now.timeIntervalSince(started) >= 0.9)
        #expect(try await client.inbox(after: first.revision - 1, wait: 5).revision == first.revision)

        async let woken = client.inbox(after: first.revision, wait: 20)
        try await Task.sleep(for: .milliseconds(400))
        try await client.inboxSeen(Self.pytest)
        let changed = try await woken
        #expect(changed.revision > first.revision)
        let pytest = try #require(changed.items.first { $0.id == Self.pytest })
        #expect(!pytest.unread && !pytest.needsYou)
        #expect(pytest.status == .idle) // a failure he has seen settles
        #expect(changed.shownCounts.needsYou == first.shownCounts.needsYou - 1)
    }

    /// A Claude Code session nobody runs: the reply continues it in a Terminal window on the Mac (said so), then it
    /// is live there and a second reply is refused (`session_live`); the CLI's own prompt can't be answered here.
    @Test func replyingToClaudeCode() async throws {
        let bridge = try FakeBridgeProcess()
        let (client, _) = try await bridge.pairedClient()
        let detail = try await client.inboxItem(Self.changelog)
        #expect(detail.item.title == "Summarize this week's merged PRs for the changelog")
        #expect(detail.messages.map(\.role) == [.user, .assistant])
        #expect(detail.messages.last?.text.contains("14 PRs") == true)

        let sent = try await client.inboxReply(Self.changelog, text: "Yes, open the PR")
        #expect(sent.resumedInTerminal)
        #expect(sent.message == "It continues in a new Terminal window on the Mac.")
        let now = try await client.inboxItem(Self.changelog)
        #expect(now.item.live && now.item.status == .working)
        #expect(now.item.heldOnMac == .openInTerminal)
        #expect(now.messages.last?.text == "Yes, open the PR")
        await #expect { _ = try await client.inboxReply(Self.changelog, text: "again") }
            throws: { ($0 as? BridgeError)?.isSessionLive == true }
        await #expect { _ = try await client.inboxReply(Self.flaky, text: "go") }
            throws: { ($0 as? BridgeError)?.isSessionLive == true }
        await #expect { _ = try await client.inboxReply(Self.onboarding, text: "go") }
            throws: { ($0 as? BridgeError)?.code == "unsupported_action" }
        let log = try await bridge.control("inbox", [:])
        #expect(log["replies"].array?.compactMap { $0["id"].string } == [Self.changelog])
        // It finishes in its terminal a few seconds later.
        try await bridge.control("settle")
        let finished = try await client.inboxItem(Self.changelog)
        #expect(finished.item.status == .done && finished.item.unread)
        #expect(finished.messages.last?.text.contains("I followed your note") == true)

        // The Mac's process list doesn't answer: neither live nor reply, "can't tell"; a reply starts nothing (503).
        _ = try await bridge.control("inbox", ["id": .string(Self.changelog), "live": false, "unsure": true])
        let unsure = try #require(try await client.inbox().items.first { $0.id == Self.changelog })
        #expect(!unsure.live && !unsure.supports(.reply))
        #expect(unsure.heldOnMac == .unknownOnMac)
        await #expect { _ = try await client.inboxReply(Self.changelog, text: "go") }
            throws: { ($0 as? BridgeError)?.isSessionCheckFailed == true && ($0 as? BridgeError)?.isRetryable == true }
    }

    /// T3 items act through the inbox routes too (approve with T3's own decisions, answer, reply), and a new task
    /// goes with the agent and model picked.
    @Test func t3ThroughTheInboxAndNewTasks() async throws {
        let bridge = try FakeBridgeProcess()
        let (client, _) = try await bridge.pairedClient()
        let inbox = try await client.inbox()
        let deploy = try #require(inbox.items.first { $0.id == "t3:t_deploy24" })
        let approval = try #require(deploy.pending.approvals.first)
        #expect(approval.options.map(\.value) == ["accept", "acceptForSession", "decline"])
        try await client.inboxApprove(deploy.id, requestId: approval.requestId, decision: "accept")
        #expect(try await client.thread("t_deploy24").thread.status == .working)
        let login = try #require(inbox.items.first { $0.id == "t3:t_loginfix" })
        let input = try #require(login.pending.inputs.first)
        try await client.inboxAnswer(login.id, requestId: input.requestId,
                                     answers: [try #require(input.questions.first?.id): "/pricing"])
        #expect(try await client.thread("t_loginfix").thread.status == .working)

        let targets = try await client.inboxTargets()
        #expect(targets.agents.map(\.id) == ["claude", "codex"])
        #expect(targets.defaultChoice.agent == "claude")
        let created = try await client.inboxNew(text: "Add a dark mode to the pricing page",
                                                choice: .init(projectId: "p_website", agent: "codex",
                                                              model: "gpt-5.5-codex"))
        #expect(created.itemId.hasPrefix("t3:"))
        #expect(created.projectName == "Website")
        let new = try #require(try await client.inbox().items.first { $0.id == created.itemId })
        #expect(new.status == .working && new.agent == "codex")
        await #expect { _ = try await client.inboxNew(text: "x", choice: .init(agent: "codex", model: "claude-opus-5-5")) }
            throws: { ($0 as? BridgeError)?.code == "invalid_model" }
    }

    /// Dismiss on the phone: gone from the list and the counts (here and in the dock: one list), seen; back with the
    /// undo as unread as it was; back by itself when it changes; nothing reaches T3.
    @Test func dismissingAndTheUndo() async throws {
        let bridge = try FakeBridgeProcess()
        let (client, _) = try await bridge.pairedClient()
        let first = try await client.inbox()
        #expect(first.items.allSatisfy { $0.canDismiss }, "every item")
        let dismissed = try await client.inboxDismiss(Self.changelog)
        #expect(dismissed.dismissed)
        #expect((dismissed.revision ?? 0) > first.revision)
        let after = try await client.inbox()
        #expect(after.revision == dismissed.revision)
        #expect(!after.items.contains { $0.id == Self.changelog })
        #expect(after.counts.dismissed == 1)
        #expect(after.shownCounts.needsYou == first.shownCounts.needsYou - 1)
        let all = try await client.raw(.get("/v1/mobile/inbox", query: [URLQueryItem(name: "include", value: "dismissed")]))
        let listed = try JSONDecoder().decode(JSONValue.self, from: all.body)["items"].array ?? []
        let hidden = listed.filter { $0["dismissed"].bool == true }
        #expect(hidden.compactMap { $0["id"].string } == [Self.changelog])
        #expect(hidden.first?["can"].array?.compactMap(\.string).contains("undismiss") == true)
        // The undo: back, unread.
        let undone = try await client.inboxUndismiss(Self.changelog)
        #expect(!undone.dismissed)
        let changelog = try #require(try await client.inbox().items.first { $0.id == Self.changelog })
        #expect(changelog.unread && changelog.needsYou)
        // It comes back by itself when it changes: a reply makes it work.
        _ = try await client.inboxDismiss(Self.changelog)
        _ = try await client.inboxReply(Self.changelog, text: "Open the PR too")
        let working = try #require(try await client.inbox().items.first { $0.id == Self.changelog })
        #expect(working.status == .working)
        let log = try await bridge.control("inbox", [:])
        #expect(log["dismissed"].array?.count == 2 && log["undismissed"].array?.count == 1)
        // A refusal (the fake's switch): 503, nothing hidden.
        try await bridge.control("inbox", ["refuse": .array([.string("dismiss")])])
        await #expect { _ = try await client.inboxDismiss(Self.pytest) } throws: { ($0 as? BridgeError)?.code == "fake_refused" }
        #expect(try await client.inbox().items.contains { $0.id == Self.pytest })
        try await bridge.control("inbox", ["refuse": .array([])])
        await #expect { _ = try await client.inboxDismiss("claude:nope") } throws: {
            ($0 as? BridgeError)?.code == "item_not_found"
        }
    }

    /// A T3 thread dismissed in the inbox is out of the summary's `t3` and the thread lists too (what the watch, the
    /// phone's background alerts and its fallback list read), as on the real bridge, until the undo.
    @Test func aDismissedThreadLeavesTheThreadListsAndTheSummary() async throws {
        let bridge = try FakeBridgeProcess()
        let (client, _) = try await bridge.pairedClient()
        let before = try await client.summary()
        #expect(Set(try await client.threads(filter: .needsYou).map(\.threadId)) == ["t_deploy24", "t_loginfix"])
        _ = try await client.inboxDismiss("t3:t_deploy24")
        #expect(try await client.threads(filter: .needsYou).map(\.threadId) == ["t_loginfix"])
        #expect(!(try await client.threads()).contains { $0.threadId == "t_deploy24" })
        let summary = try await client.summary()
        #expect(summary.t3.needsYou == before.t3.needsYou - 1)
        #expect(!summary.t3.threads.contains { $0.threadId == "t_deploy24" })
        _ = try await client.inboxUndismiss("t3:t_deploy24")
        #expect(Set(try await client.threads(filter: .needsYou).map(\.threadId)) == ["t_deploy24", "t_loginfix"])
        #expect(try await client.summary().t3.needsYou == before.t3.needsYou)
    }

    /// T3 Code down: the inbox still answers with the others; an older bridge has no inbox at all (404).
    @Test func t3DownAndAnOlderBridge() async throws {
        let bridge = try FakeBridgeProcess()
        let (client, account) = try await bridge.pairedClient()
        try await bridge.control("t3", ["available": false])
        let down = try await client.inbox()
        #expect(!down.t3Connected)
        #expect(down.t3Problem?.code == "t3_unavailable")
        #expect(!down.items.contains { $0.source == .t3 })
        #expect(down.items.contains { $0.id == Self.flaky })
        try await bridge.control("t3", ["available": true])

        try await bridge.control("inbox", ["missing": true])
        await #expect { _ = try await client.inbox() } throws: { ($0 as? BridgeError)?.isRouteMissing == true }
        // The shared refresh (widgets, intents) then keeps T3's counts.
        let cache = SummaryCache(container: .temporary())
        let actions = SamRabbitActions(account: account, cache: cache, tracker: TaskTracker(container: .temporary()),
                                       includesInbox: true)
        #expect(try await actions.refresh().inbox == nil)
        try await bridge.control("inbox", ["missing": false])
        let summary = try await actions.refresh()
        #expect(summary.inbox?.needsYou == 7)
        #expect(cache.load()?.summary.inbox?.needsYou == 7)
        #expect(summary.needsYouCount == 7 && summary.t3.needsYou == 2)
        // The watch never reads it.
        let watch = SamRabbitActions(account: account, cache: SummaryCache(container: .temporary()),
                                     tracker: TaskTracker(container: .temporary()), includesInbox: false)
        #expect(try await watch.refresh().inbox == nil)
    }
}
#endif
