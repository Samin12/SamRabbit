import Foundation

/// The morning brief as the dock reads it (DockBriefing.swift): the fixture (dev/samples/briefing.json), the other
/// shapes a bridge may send, before noon only, the verbs and their results, and Gmail links in the right account.
enum BriefingTests {
    static let all: [(String, () throws -> Void)] = [
        ("readsTheFixture", readsTheFixture),
        ("readsOtherShapes", readsOtherShapes),
        ("forgivesOddFields", forgivesOddFields),
        ("onlyTodaysBeforeNoon", onlyTodaysBeforeNoon),
        ("dockRows", dockRows),
        ("verbs", verbs),
        ("actResults", actResults),
        ("gmailInTheRightAccount", gmailInTheRightAccount),
        ("remindChoices", remindChoices),
    ]

    static func fixture() throws -> DockBrief {
        guard let path = ProcessInfo.processInfo.environment["DOCK_FIXTURE"],
              let data = FileManager.default.contents(atPath: (path as NSString).deletingLastPathComponent + "/briefing.json"),
              let brief = DockBrief.decode(data) else { throw TestFailure("dev/samples/briefing.json is missing or unreadable") }
        return brief
    }

    static var newYork: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    static func at(_ iso: String) -> Date { DockDate.parse(iso)! }

    static func readsTheFixture() throws {
        let brief = try fixture()
        expect(brief.available)
        expectEqual(brief.status, "ready")
        expectEqual(brief.date, "2026-10-14")
        expectEqual(brief.revision, 3)
        expect(brief.headline.hasPrefix("3 things need you"))
        expectEqual(brief.sections.map(\.kind), [.doFirst, .today, .agents, .fyi])
        let first = try require(brief.section(.doFirst)?.items.first)
        expectEqual(first.kind, "email")
        expectEqual(first.account, "business")
        expectEqual(first.accountEmail, "sam@example.com")
        expectEqual(first.actions.map(\.type), ["draft_reply", "remind"])
        expectEqual(first.state, "open")
        expect(first.url?.hasPrefix("https://mail.google.com/") == true)
        let conflict = try require(brief.section(.doFirst)?.items.last)
        expect(conflict.conflict)
        let agent = try require(brief.section(.agents)?.items.first)
        expectEqual(agent.inboxItemId, "t3:th_pairing_redirect")
        expectEqual(brief.section(.today)?.items.count, 4)
        expectEqual(brief.section(.today)?.items.first?.startsAt, at("2026-10-14T13:30:00Z"))
        expectEqual(brief.openCount, 4, "3 to do first and 1 agent (events and FYI ask nothing)")
    }

    static func readsOtherShapes() throws {
        // Sections as keys, the R1 runtime's wrapper, and one flat list with a section on each item.
        let keyed = DockBrief.decode(Data("""
            {"available":true,"date":"2026-10-14","revision":7,"headline":"Two things",
             "doFirst":[{"id":"a","title":"Reply to Ana","actions":["draft","remind_me"]}],
             "today":[{"id":"e","title":"Standup","startsAt":"2026-10-14T09:30:00-04:00"}]}
            """.utf8))
        expectEqual(keyed?.sections.map(\.kind), [.doFirst, .today])
        expectEqual(keyed?.item("a")?.actions.map(\.type), ["draft_reply", "remind"], "aliases and plain strings")
        expectEqual(keyed?.item("a")?.actions.first?.label, "Draft reply")
        expectEqual(keyed?.item("e")?.kind, "event", "a Today item without a kind is an event")
        let wrapped = DockBrief.decode(Data("""
            {"configured":true,"available":true,"status":"ready",
             "briefing":{"date":"2026-10-14","revision":2,"headline":"h","sections":[{"id":"do_first","items":[{"id":"x","title":"T"}]}]}}
            """.utf8))
        expectEqual(wrapped?.available, true)
        expectEqual(wrapped?.status, "ready")
        expectEqual(wrapped?.section(.doFirst)?.items.map(\.id), ["x"])
        let flat = DockBrief.decode(Data("""
            {"status":"ready","items":[{"id":"1","section":"fyi","title":"A"},{"id":"2","section":"Do first","title":"B"},
                                       {"id":"3","section":"agents","title":"C"}]}
            """.utf8))
        expectEqual(flat?.sections.map(\.kind), [.doFirst, .agents, .fyi])
        expect(flat?.available == true, "ready with items is available")
        // Nothing built yet: not available.
        let off = DockBrief.decode(Data(#"{"available":false,"status":"off","reason":"gmail_not_connected"}"#.utf8))
        expect(off?.available == false)
        expectEqual(off?.reason, "gmail_not_connected")
        expect(DockBrief.decode(Data("[]".utf8)) == nil)
    }

    static func forgivesOddFields() throws {
        let brief = DockBrief.decode(Data("""
            {"available":true,"revision":"x","sections":[{"kind":"doFirst","items":[
              {"id":"a","title":"  Reply\\n to   Ana ","actions":[{"type":"draft_reply"},{"type":"draft_reply"},{"label":"no type"},
                {"type":"Make T3 Task","label":"Task it"},{"type":"done"},{"type":"dismiss"}],"account":"sam@example.com"},
              {"title":"no id"},
              {"id":"b","title":"B"},{"id":"c","title":"C"},{"id":"d","title":"D"},{"id":"a","title":"again"}]}]}
            """.utf8))
        let items = brief?.section(.doFirst)?.items ?? []
        expectEqual(items.map(\.id), ["a", "b", "c"], "no id dropped, a repeated id once, at most 3 to do first")
        expectEqual(items.first?.title, "Reply to Ana")
        expectEqual(items.first?.actions.map(\.type), ["draft_reply", "make_task", "done", "dismiss"])
        expectEqual(items.first?.actions[1].label, "Task it")
        expectEqual(items.first?.primaryActions.map(\.type), ["draft_reply", "make_task"], "Done and Dismiss aside")
        expectEqual(items.first?.account, nil, "an address is not a tag…")
        expectEqual(items.first?.accountEmail, "sam@example.com", "…it is the mailbox")
        expectEqual(brief?.revision, 0)
    }

    static func onlyTodaysBeforeNoon() throws {
        let brief = try fixture()
        let calendar = newYork
        expect(brief.isMorning(now: at("2026-10-14T07:05:00-04:00"), calendar: calendar))
        expect(brief.isMorning(now: at("2026-10-14T11:59:00-04:00"), calendar: calendar))
        expect(!brief.isMorning(now: at("2026-10-14T12:00:00-04:00"), calendar: calendar), "not from noon")
        expect(!brief.isMorning(now: at("2026-10-15T08:00:00-04:00"), calendar: calendar), "not yesterday's")
        var off = brief
        off.available = false
        expect(!off.isMorning(now: at("2026-10-14T08:00:00-04:00"), calendar: calendar))
        expectEqual(DockBrief.day(at("2026-10-15T03:30:00Z"), calendar: calendar), "2026-10-14", "the Mac's own day")
    }

    static func dockRows() throws {
        var brief = try fixture()
        let now = at("2026-10-14T10:05:00-04:00")
        var rows = brief.dockRows(now: now)
        expectEqual(rows.first.count, 3)
        expectEqual(rows.today.map(\.title).first, "Design review: Agent Dock and the Mac window", "standup is over")
        expectEqual(rows.today.count, 3)
        // Done and dismissed leave; drafted stays (quieter, with what happened).
        let first = brief.section(.doFirst)!.items
        brief = brief.replacing(first[0].acted("draft_reply")).replacing(first[1].acted("done"))
        rows = brief.dockRows(now: now)
        expectEqual(rows.first.map(\.id), [first[0].id, first[2].id])
        expectEqual(rows.first.first?.stateLine, "Draft saved in Gmail · not sent")
        expect(rows.first.first?.isHandled == true)
        expectEqual(brief.openCount, 2, "the conflict and the agent")
    }

    static func verbs() throws {
        expectEqual(DockBriefAction.known.map(DockBriefAction.defaultLabel),
                    ["Draft reply", "Make task", "Block time", "Remind me", "Done", "Dismiss", "Open"])
        expectEqual(DockBriefAction.normalize("Remind-Me"), "remind")
        expectEqual(DockBriefAction.normalize("snooze"), "remind")
        expectEqual(DockBriefAction.normalize("block"), "block_time")
        expectEqual(DockBriefAction.normalize("agent_action"), "agent_action", "unknown verbs are kept")
        for (verb, state) in [("draft_reply", "drafted"), ("make_task", "tasked"), ("block_time", "blocked"), ("remind", "snoozed"),
                              ("done", "done"), ("dismiss", "dismissed")] {
            expectEqual(DockBriefAction.resultingState(verb), state)
        }
        expect(DockBriefAction.resultingState("open") == nil, "opening changes nothing")
        for verb in DockBriefAction.known { expect(!DockBriefAction.symbol(verb).isEmpty) }
    }

    static func actResults() throws {
        let draft = DockBriefActResult.decode(Data("""
            {"ok":true,"state":"drafted","result":{"draftId":"r-123","url":"https://mail.google.com/mail/u/0/?authuser=sam%40example.com#drafts/r-123"}}
            """.utf8))
        expectEqual(draft.state, "drafted")
        expectEqual(draft.draftId, "r-123")
        expect(draft.url?.contains("#drafts/r-123") == true)
        expectEqual(DockBriefActResult.decode(Data(#"{"ok":true,"state":"tasked","result":{"itemId":"t3:th_new"}}"#.utf8)).itemId, "t3:th_new")
        expectEqual(DockBriefActResult.decode(Data("nonsense".utf8)), DockBriefActResult())
    }

    static func gmailInTheRightAccount() throws {
        let link = "https://mail.google.com/mail/u/0/#inbox/18f2a9c3b7e4d001"
        expectEqual(DockBriefLinks.withAccount(link, email: "sam.personal@example.com"),
                    "https://mail.google.com/mail/u/0/?authuser=sam.personal%40example.com#inbox/18f2a9c3b7e4d001")
        let set = "https://mail.google.com/mail/u/0/?authuser=a%40b.c#inbox/1"
        expectEqual(DockBriefLinks.withAccount(set, email: "x@y.z"), set, "the bridge's own choice stays")
        expectEqual(DockBriefLinks.withAccount("https://calendar.google.com/x", email: "x@y.z"), "https://calendar.google.com/x")
        expectEqual(DockBriefLinks.withAccount(link, email: nil), link)
        expect(DockBriefLinks.isWebLink(link))
        expect(!DockBriefLinks.isWebLink("file:///etc/passwd"))
        expect(!DockBriefLinks.isWebLink("javascript:alert(1)"))
        expect(!DockBriefLinks.isWebLink("t3code://thread/1"))
    }

    static func remindChoices() throws {
        let calendar = newYork
        let morning = DockBriefRemind.choices(now: at("2026-10-14T08:10:00-04:00"), calendar: calendar)
        expectEqual(morning.map(\.label), ["In 1 hour", "2 PM", "Tonight 6 PM", "Tomorrow 9 AM"])
        expectEqual(morning[1].at, at("2026-10-14T14:00:00-04:00"))
        expectEqual(morning[3].at, at("2026-10-15T09:00:00-04:00"))
        let late = DockBriefRemind.choices(now: at("2026-10-14T13:45:00-04:00"), calendar: calendar)
        expectEqual(late.map(\.label), ["In 1 hour", "Tonight 6 PM", "Tomorrow 9 AM"], "2 PM is too close")
    }

    static func require<T>(_ value: T?, file: StaticString = #file, line: UInt = #line) throws -> T {
        guard let value else { throw TestFailure("missing value (\((String(describing: file) as NSString).lastPathComponent):\(line))") }
        return value
    }
}
