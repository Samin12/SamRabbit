import Foundation
import Testing
@testable import SamRabbitKit

/// The morning brief as the bridge sends it (CONTRACTS-WAVE8 §A3; `samrabbit_briefing.BriefingService.view`, key for
/// key): the parts in `sections[]`, the verbs, the states and what a verb did, plus a lenient reader for the other
/// shapes the contract leaves room for, and when Home shows it.
private let briefingJSON = """
{"revision": 12, "date": "2026-10-14", "building": false, "available": true, "status": "ready",
 "generatedAt": "2026-10-14T10:41:07Z", "headline": "3 things need you · 4 meetings, first at 10:00 · 1 agent waiting",
 "spoken": "First: Reply to Dana about the SOW.", "needsYou": 3, "composed": "claude",
 "sections": [
  {"id": "doFirst", "title": "Do first", "items": [
    {"id": "bi_3f2a9c4d1e0b7a21", "section": "doFirst", "kind": "email", "title": "Reply to Dana about the SOW",
     "why": "She needs it signed by Friday; asked twice",
     "actions": [{"type": "draft_reply", "label": "Draft reply"}, {"type": "remind", "label": "Remind me"}],
     "can": ["draft_reply", "remind", "done", "dismiss", "open"], "state": "open", "updatedAt": "2026-10-14T10:41:07Z",
     "account": "business", "url": "https://mail.google.com/mail/?authuser=sam%40example.com#all/18f2a9c4d1e0b7a2",
     "suggestion": "Draft a reply confirming Thu 2 pm", "draft": "Hi Dana, Thursday at 2 works."},
    {"id": "bi_77c01b9e4d3a10aa", "section": "doFirst", "kind": "email", "title": "Look into Acme's checkout errors",
     "why": "Two customers saw 500s since last night",
     "actions": [{"type": "make_task", "label": "Make task"}, {"type": "draft_reply", "label": "Draft reply"}],
     "can": ["make_task", "draft_reply", "done", "dismiss", "open"], "state": "tasked", "account": "personal",
     "url": "javascript:alert(1)",
     "result": {"threadId": "t_9", "itemId": "t3:t_9", "title": "Look into Acme", "say": "Started it as a T3 task."}},
    {"id": "bi_c0ffee00c0ffee00", "section": "doFirst", "kind": "conflict", "title": "Move the dentist or skip standup",
     "why": "Both at 10:00 AM", "actions": [{"type": "block_time", "label": "Block 30 min"}, {"type": "open", "label": "Join"}],
     "can": ["block_time", "open", "done", "dismiss"], "state": "open", "startsAt": "2026-10-14T14:00:00Z",
     "endsAt": "2026-10-14T14:15:00Z", "url": "https://meet.google.com/abc-defg-hij", "conflict": true},
    {"id": "bi_extra", "title": "A fourth: over the cap"}]},
  {"id": "today", "title": "Today", "items": [
    {"id": "bi_e100000000000001", "section": "today", "kind": "conflict", "title": "Join Standup",
     "why": "Overlaps Dentist · 10:00 AM–10:15 AM", "actions": [{"type": "open", "label": "Join"}],
     "can": ["open", "done", "dismiss"], "state": "open", "startsAt": "2026-10-14T14:00:00Z",
     "endsAt": "2026-10-14T14:15:00Z", "url": "https://meet.google.com/abc-defg-hij", "conflict": true},
    {"id": "bi_e100000000000002", "section": "today", "kind": "event", "title": "Join Design review",
     "why": "2:00 PM–3:00 PM", "actions": [{"type": "done", "label": "Got it"}], "can": ["done", "dismiss"],
     "state": "open", "startsAt": "2026-10-14T18:00:00Z", "endsAt": "2026-10-14T19:00:00Z"}]},
  {"id": "agents", "title": "Agents", "items": [
    {"id": "bi_a100000000000001", "section": "agents", "kind": "agent", "title": "Approve “Deploy staging”",
     "why": "Wants to run a command · Assistant", "actions": [{"type": "open", "label": "Review"}],
     "can": ["open", "done", "dismiss"], "state": "done", "itemId": "t3:t_deploy24", "source": "t3"}]},
  {"id": "fyi", "title": "FYI", "items": [
    {"id": "bi_f100000000000001", "section": "fyi", "kind": "fyi", "title": "Stripe payout arrived",
     "why": "$3,420 landed in checking", "actions": [{"type": "open", "label": "Open"}],
     "can": ["open", "done", "dismiss"], "state": "open", "account": "business",
     "url": "https://mail.google.com/mail/?authuser=sam%40example.com#all/18f2d7aa01c2e3f4"},
    {"title": "no id: dropped"}]}],
 "accounts": [{"label": "business", "ok": true, "fetched": 64, "kept": 9},
              {"label": "personal", "ok": false, "reason": "gmail_not_connected"}],
 "counts": {"emails": 64, "kept": 9, "events": 4, "agents": 1}}
"""

private let dana = "bi_3f2a9c4d1e0b7a21"
private let acme = "bi_77c01b9e4d3a10aa"
private let clash = "bi_c0ffee00c0ffee00"

@Suite("Morning brief")
struct BriefingTests {
    private func decode(_ json: String = briefingJSON) throws -> Briefing {
        try BridgeJSON.decode(Briefing.self, from: Data(json.utf8))
    }

    private var newYork: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    @Test func thePartsTheirItemsAndTheirVerbs() throws {
        let brief = try decode()
        #expect(brief.available)
        #expect(brief.status == .ready)
        #expect(brief.revision == 12)
        #expect(brief.updatedAt == BridgeDates.date(from: "2026-10-14T10:41:07Z"), "generatedAt")
        #expect(brief.headline == "3 things need you · 4 meetings, first at 10:00 · 1 agent waiting")
        #expect(brief.items.map(\.id) == [dana, acme, clash, "bi_e100000000000001", "bi_e100000000000002",
                                          "bi_a100000000000001", "bi_f100000000000001"],
                "in the parts' order, Do first at its cap of three")
        let first = brief.items[0]
        #expect(first.section == .doFirst)
        #expect(first.priority == 1, "Do first is the urgent part")
        #expect(first.verbs.map(\.kind) == [.draftReply, .remind], "Done is offered beside the verbs, not as one")
        #expect(first.verbs.map(\.label) == ["Draft reply", "Remind me"])
        #expect(first.verbs[0].action == "draft_reply", "sent back as the bridge wrote it")
        #expect(first.openURL?.host == "mail.google.com")
        #expect(first.accountTag == nil, "business is the default")
        #expect(first.allows(.done) && first.allows(.dismiss) && !first.allows(.makeTask))
        let task = brief.items[1]
        #expect(task.state == .tasked)
        #expect(task.state.label == "Task started")
        #expect(task.resultLine == "Started it as a T3 task.")
        #expect(task.accountTag == "Personal")
        #expect(task.url == nil, "only http(s) links are opened")
        let conflict = brief.items[2]
        #expect(conflict.kind == "conflict")
        #expect(conflict.conflict)
        #expect(conflict.verbs.map(\.label) == ["Block 30 min", "Join"])
        #expect(conflict.openURL?.host == "meet.google.com")
        let standup = brief.items[3]
        #expect(standup.section == .today)
        #expect(standup.startsAt == BridgeDates.date(from: "2026-10-14T14:00:00Z"))
        #expect(standup.verbs.map(\.label) == ["Join"])
        #expect(brief.items[4].verbs.isEmpty, "Got it is its Done")
        let agent = brief.items[5]
        #expect(agent.inboxItemId == "t3:t_deploy24", "the bridge's itemId")
        #expect(agent.verbs.map(\.label) == ["Review"])
        #expect(brief.items(in: .agents).isEmpty, "Done: gone from the brief")
        #expect(brief.toDo == 2, "Dana and the clash (Acme has its task, the deploy is done, FYI asks nothing)")
        #expect(brief.footer == "Read 64 emails · 9 worth a look · Couldn't read the personal mailbox")
    }

    @Test func otherShapesTheContractLeavesRoomFor() throws {
        // Items that name their part, a wrapper (the R1's shape), keyed lists.
        let flat = try decode("""
        {"briefing": {"date": "2026-10-14", "revision": 7, "headline": "Two things",
          "items": [{"id": "a", "section": "do_first", "title": "Reply"}, {"id": "b", "section": "fyi", "title": "Hi"}]},
         "available": true, "status": "ready"}
        """)
        #expect(flat.available)
        #expect(flat.items.map(\.section) == [.doFirst, .fyi])
        let keyed = try decode("""
        {"date": "2026-10-14", "revision": 8, "doFirst": [{"id": "a", "title": "Reply"}],
         "today": [{"id": "e", "title": "Standup"}], "agents": [{"id": "g", "title": "Approve"}]}
        """)
        #expect(keyed.items.map(\.id) == ["a", "e", "g"])
        #expect(keyed.items.map(\.section) == [.doFirst, .today, .agents])
        #expect(keyed.items[1].kind == "event")
        // Not built yet today (the real bridge: `waiting`), building, turned off.
        let none = try decode(#"{"revision": 3, "date": "2026-10-14", "building": false, "available": false, "status": "waiting"}"#)
        #expect(!none.available)
        #expect(none.status == .none)
        #expect(!none.showsOnHome())
        let building = try decode(#"{"revision": 4, "date": "2026-10-14", "building": true, "available": false, "status": "building"}"#)
        #expect(building.status == .building)
        let off = try decode(#"{"revision": 1, "date": "2026-10-14", "available": false, "status": "off", "reason": "briefing_turned_off"}"#)
        #expect(off.status == .off)
        #expect(off.reason == "briefing_turned_off")
    }

    @Test func homeShowsTodaysBriefUntilNoon() throws {
        let brief = try decode()
        let calendar = newYork
        let morning = try #require(BridgeDates.date(from: "2026-10-14T08:30:00-04:00"))
        let noon = try #require(BridgeDates.date(from: "2026-10-14T12:00:00-04:00"))
        let tomorrow = try #require(BridgeDates.date(from: "2026-10-15T08:30:00-04:00"))
        #expect(brief.showsOnHome(now: morning, calendar: calendar))
        #expect(!brief.showsOnHome(now: noon, calendar: calendar), "until noon")
        #expect(brief.showsOnHome(now: noon, calendar: calendar, allDay: true))
        #expect(!brief.showsOnHome(now: tomorrow, calendar: calendar), "yesterday's brief")
        #expect(BriefingClock.day(of: morning, calendar: calendar) == "2026-10-14")
        // Everything handled: nothing left to show.
        var handled = brief
        for item in handled.items { handled = handled.with(item.id, state: .done) }
        #expect(!handled.showsOnHome(now: morning, calendar: calendar))
    }

    @Test func aTapChangesTheItemAtOnce() throws {
        let brief = try decode()
        let link = try #require(URL(string: "https://mail.google.com/mail/?authuser=sam%40example.com#drafts?compose=r1"))
        let drafted = brief.with(dana, state: .drafted, draftUrl: link, line: "Saved as a draft in Gmail. Open it to send.")
        #expect(drafted.items[0].state == .drafted)
        #expect(drafted.items[0].draftUrl == link)
        #expect(drafted.items[0].resultLine == "Saved as a draft in Gmail. Open it to send.")
        #expect(drafted.toDo == 1)
        #expect(brief.with("nope", state: .done) == brief)
        #expect(try decode().isNewer(than: brief) == false)
        var later = brief
        later.revision += 1
        #expect(later.isNewer(than: brief))
        // The Mac's next brief carries the draft's own link in the item's `result`.
        let again = try decode(briefingJSON.replacingOccurrences(of: #""state": "open", "updatedAt": "2026-10-14T10:41:07Z","#,
            with: #""state": "drafted", "result": {"draftId": "r1", "url": "https://mail.google.com/mail/?authuser=sam%40example.com#drafts?compose=r1", "account": "business", "say": "Saved as a draft in Gmail. Open it to send."},"#))
        #expect(again.items[0].state == .drafted)
        #expect(again.items[0].draftUrl == link)
        #expect(again.items[0].resultLine == "Saved as a draft in Gmail. Open it to send.")
    }

    /// What a tap answers, as the real bridge does: `{ok, item, result, revision}`.
    @Test func whatATapAnswers() throws {
        let draft = try BridgeJSON.decode(BriefingActResult.self, from: Data("""
        {"ok": true, "item": {"id": "\(dana)", "section": "doFirst", "kind": "email", "title": "Reply to Dana",
          "why": "", "actions": [{"type": "draft_reply", "label": "Draft reply"}], "can": ["draft_reply", "done"],
          "state": "drafted", "result": {"draftId": "r1", "url": "https://mail.google.com/mail/?authuser=sam%40example.com#drafts?compose=r1"}},
         "result": {"draftId": "r1", "url": "https://mail.google.com/mail/?authuser=sam%40example.com#drafts?compose=r1",
                    "account": "business", "say": "Saved as a draft in Gmail. Open it to send."},
         "revision": 13}
        """.utf8))
        #expect(draft.state == .drafted, "the item's new state")
        #expect(draft.url?.host == "mail.google.com")
        #expect(draft.url?.absoluteString.contains("authuser=sam%40example.com") == true, "the right account")
        #expect(draft.message == "Saved as a draft in Gmail. Open it to send.")
        #expect(draft.item?.draftUrl == draft.url)
        let remind = try BridgeJSON.decode(BriefingActResult.self, from: Data("""
        {"ok": true, "item": {"id": "x", "title": "Reply", "state": "reminded"},
         "result": {"eventId": "ev_1", "until": "2026-10-14T18:00:00Z", "say": "I'll remind you at 2:00 PM."}, "revision": 14}
        """.utf8))
        #expect(remind.state == .snoozed)
        #expect(remind.until == BridgeDates.date(from: "2026-10-14T18:00:00Z"))
        #expect(remind.eventId == "ev_1")
        #expect(remind.message == "I'll remind you at 2:00 PM.")
        let task = try BridgeJSON.decode(BriefingActResult.self, from: Data("""
        {"ok": true, "item": {"id": "y", "title": "Look", "state": "tasked"},
         "result": {"threadId": "t_9", "itemId": "t3:t_9", "title": "Look", "say": "Started it as a T3 task."}, "revision": 15}
        """.utf8))
        #expect(task.threadId == "t_9")
        #expect(task.itemId == "t3:t_9")
        let open = try BridgeJSON.decode(BriefingActResult.self, from: Data("""
        {"ok": true, "item": {"id": "z", "title": "Approve", "state": "open"}, "result": {"url": null, "itemId": "t3:t_deploy24"}, "revision": 15}
        """.utf8))
        #expect(open.itemId == "t3:t_deploy24")
        #expect(open.url == nil)
        #expect(open.state == .open)
        let bad = try BridgeJSON.decode(BriefingActResult.self, from: Data(#"{"result": {"url": "file:///etc/passwd"}}"#.utf8))
        #expect(bad.url == nil)
    }

    @Test func theSummaryCarriesItForTheWidgets() throws {
        let summary = try BridgeJSON.decode(MobileSummary.self, from: Data("""
        {"briefing": {"available": true, "date": "2026-10-14", "status": "ready", "revision": 12,
                      "headline": "3 things need you", "needsYou": 3}}
        """.utf8))
        let part = try #require(summary.briefing)
        #expect(part.needsYou == 3)
        #expect(part.countLine == "3 to do")
        #expect(part.items.isEmpty, "the bridge sends no items")
        let calendar = newYork
        let morning = try #require(BridgeDates.date(from: "2026-10-14T08:30:00-04:00"))
        #expect(part.current(now: morning, calendar: calendar))
        #expect(!part.current(now: morning.addingTimeInterval(86_400), calendar: calendar))
        let waiting = try BridgeJSON.decode(MobileSummary.self, from: Data("""
        {"briefing": {"available": false, "date": "2026-10-14", "status": "waiting", "revision": 3, "headline": null, "needsYou": 0}}
        """.utf8))
        #expect(waiting.briefing?.current(now: morning, calendar: calendar) == false)
        // The iPhone adds the first open items.
        let brief = try decode()
        let merged = summary.with(briefing: .success(brief), kept: nil)
        #expect(merged.briefing?.items.map(\.id) == [dana, acme, clash, "bi_f100000000000001"],
                "open items outside Today (Acme's task is still shown, dimmed)")
        #expect(merged.briefing?.needsYou == 2)
        #expect(merged.briefing?.updatedAt == brief.updatedAt)
        // A failed call keeps the items it had while the bridge reports the same brief.
        let kept = BriefingOverview(available: true, date: "2026-10-14", revision: 12, items: [brief.items[0]])
        #expect(summary.with(briefing: .failure(.unreachable("x")), kept: kept).briefing?.items.map(\.id) == [dana])
        var moved = kept
        moved.revision = 11
        #expect(summary.with(briefing: .failure(.unreachable("x")), kept: moved).briefing?.items.isEmpty == true)
        #expect(summary.with(briefing: .success(Briefing(available: false)), kept: nil) == summary)
    }

    @Test func theSampleIsBelievable() {
        let sample = Briefing.sample()
        #expect(sample.items(in: .doFirst).count == 3)
        #expect(sample.toDo == 4)
        #expect(MobileSummary.sample().briefing?.headline.isEmpty == false)
    }

    /// Make task starts with words he saw: the title and why on the card (the Mac's own fallback), or the Mac's
    /// `taskText` when it sends it (shown first too). Never the Mac's unseen words.
    @Test func makeTaskStartsWithTheWordsShown() throws {
        let brief = try decode()
        let acme = try #require(brief.items(in: .doFirst).first { $0.id == "bi_77c01b9e4d3a10aa" })
        #expect(acme.taskText == nil, "today's bridge keeps its own words to itself")
        #expect(acme.taskPrompt == "Look into Acme's checkout errors. \(acme.why)")
        #expect(BriefingItem(id: "a", section: .doFirst, title: "Is staging down?", why: "Two alerts").taskPrompt
                == "Is staging down? Two alerts")
        #expect(BriefingItem(id: "a", section: .doFirst, title: "Renew the domain").taskPrompt == "Renew the domain")
        let proposed = try BridgeJSON.decode(BriefingItem.self, from: Data("""
        {"id":"bi_x","section":"doFirst","title":"Look into checkout errors","why":"500s since last night",
         "taskText":"Find why checkout returns 500 since last night and propose a fix.","actions":["make_task"]}
        """.utf8))
        #expect(proposed.taskPrompt == "Find why checkout returns 500 since last night and propose a fix.")
        let again = try BridgeJSON.decode(BriefingItem.self, from: BridgeJSON.encoder().encode(proposed))
        #expect(again.taskText == proposed.taskText)
        let long = try BridgeJSON.decode(BriefingItem.self, from: Data(#"{"id":"bi_y","title":"T","taskText":"\#(String(repeating: "a", count: 900))"}"#.utf8))
        #expect((long.taskText?.count ?? 0) <= BriefingItem.maxTaskText)
    }

    @Test func anItemSurvivesTheWidgetsCache() throws {
        let brief = try decode()
        let summary = MobileSummary().with(briefing: .success(brief), kept: nil)
        let again = try BridgeJSON.decode(MobileSummary.self, from: BridgeJSON.encoder().encode(summary))
        #expect(again.briefing == summary.briefing)
        let whole = try BridgeJSON.decode(Briefing.self, from: BridgeJSON.encoder().encode(brief))
        #expect(whole == brief)
    }
}
