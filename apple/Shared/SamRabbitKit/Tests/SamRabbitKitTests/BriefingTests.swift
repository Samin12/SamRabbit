import Foundation
import Testing
@testable import SamRabbitKit

/// The morning brief as the bridge sends it (CONTRACTS-WAVE8 §A3): the parts in `sections[]`, the verbs, the states,
/// a lenient reader for the other shapes the contract leaves room for, and when Home shows it.
private let briefingJSON = """
{"available": true, "status": "ready", "date": "2026-10-14", "revision": 1791987275552,
 "updatedAt": "2026-10-14T11:01:00Z", "headline": "3 things need you · 4 meetings, first at 10:00",
 "spoken": "Good morning.", "footer": "Skipped 182 promos and newsletters",
 "sections": [
  {"kind": "doFirst", "title": "Do first", "items": [
    {"id": "bi_dana", "kind": "email", "account": "business", "title": "Reply to Dana about the SOW",
     "why": "She needs it signed by Friday; asked twice", "suggestion": "Draft a reply confirming Thu 2 pm",
     "actions": [{"type": "draft_reply", "label": "Draft reply"}, {"type": "remind", "label": "Remind 2 pm"},
                 {"type": "done"}],
     "url": "https://mail.google.com/mail/u/?authuser=sam%40example.com#inbox/18f2", "state": "open", "priority": 1},
    {"id": "bi_payout", "title": "Fix the failed Stripe payout", "why": "Bank details rejected",
     "actions": ["open", "remind"], "url": "javascript:alert(1)"},
    {"id": "bi_acme", "account": "personal", "title": "Look into Acme's checkout errors",
     "actions": [{"action": "make_task"}, {"type": "draft_reply"}], "state": "tasked"},
    {"id": "bi_extra", "title": "A fourth: over the cap"}]},
  {"kind": "today", "items": [
    {"id": "bi_standup", "title": "Standup", "startsAt": "2026-10-14T14:00:00Z", "endsAt": "2026-10-14T14:15:00Z",
     "conflict": true, "actions": [{"type": "block_time", "label": "Block prep"}]}]},
  {"kind": "agents", "items": [
    {"id": "bi_deploy", "title": "Approve the staging deploy", "inboxItemId": "t3:t_deploy24", "state": "done"}]},
  {"kind": "fyi", "items": [{"id": "bi_payout_in", "title": "Stripe payout arrived"}]},
  {"kind": "fyi", "items": [{"title": "no id: dropped"}]}
 ]}
"""

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
        #expect(brief.revision == 1_791_987_275_552)
        #expect(brief.headline == "3 things need you · 4 meetings, first at 10:00")
        #expect(brief.items.map(\.id) == ["bi_dana", "bi_payout", "bi_acme", "bi_standup", "bi_deploy", "bi_payout_in"],
                "in the parts' order, Do first at its cap of three")
        let dana = brief.items[0]
        #expect(dana.section == .doFirst)
        #expect(dana.verbs.map(\.kind) == [.draftReply, .remind], "Done is offered beside the verbs, not as one")
        #expect(dana.verbs.map(\.label) == ["Draft reply", "Remind 2 pm"])
        #expect(dana.verbs[0].action == "draft_reply", "sent back as the bridge wrote it")
        #expect(dana.openURL?.host == "mail.google.com")
        #expect(dana.accountTag == nil, "business is the default")
        let payout = brief.items[1]
        #expect(payout.verbs.map(\.kind) == [.open, .remind])
        #expect(payout.verbs.map(\.label) == ["Open", "Remind me"])
        #expect(payout.url == nil, "only http(s) links are opened")
        let acme = brief.items[2]
        #expect(acme.state == .tasked)
        #expect(acme.state.label == "Task started")
        #expect(acme.accountTag == "Personal")
        #expect(acme.verbs.first?.action == "make_task")
        let standup = brief.items[3]
        #expect(standup.section == .today)
        #expect(standup.conflict)
        #expect(standup.startsAt == BridgeDates.date(from: "2026-10-14T14:00:00Z"))
        #expect(brief.items[4].inboxItemId == "t3:t_deploy24")
        #expect(brief.items(in: .agents).isEmpty, "Done: gone from the brief")
        #expect(brief.toDo == 2, "Dana and the payout (Acme has its task, the deploy is done, FYI asks nothing)")
        #expect(brief.footer == "Skipped 182 promos and newsletters")
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
        let none = try decode(#"{"available": false, "status": "none", "reason": "not_built_yet", "sections": []}"#)
        #expect(!none.available)
        #expect(none.status == .none)
        #expect(none.reason == "not_built_yet")
        #expect(!none.showsOnHome())
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
        let link = try #require(URL(string: "https://mail.google.com/mail/u/?authuser=sam%40example.com#drafts?compose=r1"))
        let drafted = brief.with("bi_dana", state: .drafted, draftUrl: link)
        #expect(drafted.items[0].state == .drafted)
        #expect(drafted.items[0].draftUrl == link)
        #expect(drafted.toDo == 1)
        #expect(brief.with("nope", state: .done) == brief)
        #expect(try decode().isNewer(than: brief) == false)
        var later = brief
        later.revision += 1
        #expect(later.isNewer(than: brief))
    }

    @Test func whatATapAnswers() throws {
        let draft = try BridgeJSON.decode(BriefingActResult.self, from: Data("""
        {"ok": true, "state": "drafted", "url": "https://mail.google.com/mail/u/?authuser=sam%40example.com#drafts",
         "draftId": "r1", "message": "Saved as a draft in Gmail. Nothing was sent."}
        """.utf8))
        #expect(draft.state == .drafted)
        #expect(draft.url?.host == "mail.google.com")
        #expect(draft.message == "Saved as a draft in Gmail. Nothing was sent.")
        let nested = try BridgeJSON.decode(BriefingActResult.self, from: Data("""
        {"ok": true, "state": "snoozed", "result": {"until": "2026-10-14T18:00:00Z", "eventId": "ev_1"}}
        """.utf8))
        #expect(nested.until == BridgeDates.date(from: "2026-10-14T18:00:00Z"))
        #expect(nested.eventId == "ev_1")
        let bad = try BridgeJSON.decode(BriefingActResult.self, from: Data(#"{"url": "file:///etc/passwd"}"#.utf8))
        #expect(bad.url == nil)
    }

    @Test func theSummaryCarriesItForTheWidgets() throws {
        let summary = try BridgeJSON.decode(MobileSummary.self, from: Data("""
        {"briefing": {"available": true, "date": "2026-10-14", "status": "ready", "revision": 5,
                      "headline": "3 things need you", "needsYou": 3, "updatedAt": "2026-10-14T11:01:00Z"}}
        """.utf8))
        let part = try #require(summary.briefing)
        #expect(part.needsYou == 3)
        #expect(part.countLine == "3 to do")
        #expect(part.items.isEmpty, "the bridge sends no items")
        let calendar = newYork
        let morning = try #require(BridgeDates.date(from: "2026-10-14T08:30:00-04:00"))
        #expect(part.current(now: morning, calendar: calendar))
        #expect(!part.current(now: morning.addingTimeInterval(86_400), calendar: calendar))
        // The iPhone adds the first open items.
        let brief = try decode()
        let merged = summary.with(briefing: .success(brief), kept: nil)
        #expect(merged.briefing?.items.map(\.id) == ["bi_dana", "bi_payout", "bi_acme", "bi_payout_in"],
                "open items outside Today (Acme's task is still shown, dimmed)")
        #expect(merged.briefing?.needsYou == 2)
        // A failed call keeps the items it had while the bridge reports the same brief.
        let kept = BriefingOverview(available: true, date: "2026-10-14", revision: 5, items: [brief.items[0]])
        #expect(summary.with(briefing: .failure(.unreachable("x")), kept: kept).briefing?.items.map(\.id) == ["bi_dana"])
        var moved = kept
        moved.revision = 4
        #expect(summary.with(briefing: .failure(.unreachable("x")), kept: moved).briefing?.items.isEmpty == true)
        #expect(summary.with(briefing: .success(Briefing(available: false)), kept: nil) == summary)
    }

    @Test func theSampleIsBelievable() {
        let sample = Briefing.sample()
        #expect(sample.items(in: .doFirst).count == 3)
        #expect(sample.toDo == 4)
        #expect(MobileSummary.sample().briefing?.headline.isEmpty == false)
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
