import Foundation

// The morning briefing as the Agent Dock shows it (CONTRACTS-WAVE8 §D2): the bridge builds one brief a day from Gmail,
// the calendar and the agent inbox (`GET /v1/desktop/briefing`), and before noon the dock's list opens with a "Morning"
// section: the headline, what to do first (each with its verbs: Draft reply, Make task, Block time, Remind me, Done,
// Dismiss, Open) and today's next events. Draft reply makes a Gmail DRAFT on the bridge (nothing is ever sent) and opens
// it in the browser with the right account. Pure data and rules, no AppKit: tests/swift compiles this file on its own.
// Read forgivingly, like the inbox: a missing or odd field takes its default rather than dropping the brief.

enum DockBriefSectionKind: String, CaseIterable {
    case doFirst, today, agents, fyi

    var title: String {
        switch self {
        case .doFirst: return "Do first"
        case .today: return "Today"
        case .agents: return "Agents"
        case .fyi: return "FYI"
        }
    }

    /// "doFirst", "do_first", "Do first", "today", "events", "agents", "fyi"…
    static func parse(_ text: String?) -> DockBriefSectionKind? {
        guard let text else { return nil }
        let key = text.lowercased().filter { $0.isLetter }
        switch key {
        case "dofirst", "first", "do", "priority", "priorities": return .doFirst
        case "today", "events", "calendar", "agenda": return .today
        case "agents", "agent", "tasks": return .agents
        case "fyi", "info", "worthknowing": return .fyi
        default: return nil
        }
    }
}

/// One verb on an item. `type` is one of `DockBriefAction.known` (aliases are mapped), else kept as the bridge sent it.
struct DockBriefAction: Equatable, Hashable {
    var type: String
    var label: String
    /// A link the action opens without asking the bridge (Open).
    var url: String?

    static let known = ["draft_reply", "make_task", "block_time", "remind", "done", "dismiss", "open"]

    static func normalize(_ raw: String) -> String {
        let key = raw.lowercased().replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_")
        switch key {
        case "draft", "reply", "draftreply", "draft_reply", "create_draft": return "draft_reply"
        case "task", "make_t3_task", "t3_task", "maketask", "make_task", "new_task": return "make_task"
        case "block", "block_time", "blocktime": return "block_time"
        case "remind", "remind_me", "remindme", "snooze": return "remind"
        case "done", "complete", "mark_done": return "done"
        case "dismiss", "hide": return "dismiss"
        case "open", "open_gmail", "view": return "open"
        default: return key
        }
    }

    static func defaultLabel(_ type: String) -> String {
        switch type {
        case "draft_reply": return "Draft reply"
        case "make_task": return "Make task"
        case "block_time": return "Block time"
        case "remind": return "Remind me"
        case "done": return "Done"
        case "dismiss": return "Dismiss"
        case "open": return "Open"
        default: return type.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// The SF Symbol on its button.
    static func symbol(_ type: String) -> String {
        switch type {
        case "draft_reply": return "arrowshape.turn.up.left.fill"
        case "make_task": return "plus"
        case "block_time": return "calendar.badge.plus"
        case "remind": return "bell"
        case "done": return "checkmark"
        case "dismiss": return "xmark"
        case "open": return "arrow.up.forward.app"
        default: return "sparkle"
        }
    }

    /// The item's state once the bridge said yes (shown at once, rolled back on a failure): the bridge's own names
    /// (samrabbit_briefing `STATES`).
    static func resultingState(_ type: String) -> String? {
        switch type {
        case "draft_reply": return "drafted"
        case "make_task": return "tasked"
        case "block_time": return "blocked"
        case "remind": return "reminded"
        case "done": return "done"
        case "dismiss": return "dismissed"
        default: return nil
        }
    }
}

struct DockBriefItem: Equatable, Identifiable {
    var id: String
    var section: DockBriefSectionKind
    /// email | event | agent | conflict | fyi
    var kind: String
    /// "business" | "personal" (email only), shown as a small tag.
    var account: String?
    /// The mailbox's address, when the bridge says it (a draft link opens in that Google account).
    var accountEmail: String?
    var title: String
    var why: String
    var suggestion: String?
    var actions: [DockBriefAction]
    /// open | drafted | tasked | blocked | reminded | done | dismissed ("snoozed": the research draft's "reminded")
    var state: String
    var url: String?
    /// The Gmail draft a Draft reply made (the bridge keeps the action's `result` on the item), to open it again.
    var draftUrl: String?
    /// When a Remind me's reminder is (`result.until`; or the choice tapped, until the bridge says).
    var remindAt: Date?
    var startsAt: Date?
    var endsAt: Date?
    var conflict: Bool
    /// An agent item's inbox id (`t3:<id>`), to open it in the dock's list.
    var inboxItemId: String?

    /// Still waiting for Samin (not done, dismissed or put off).
    var isOpen: Bool { !["done", "dismissed", "reminded", "snoozed"].contains(state) }

    /// Handled one way or another (drafted, a task made, time blocked, put off with a reminder): shown quieter, with
    /// what happened.
    var isHandled: Bool { ["drafted", "tasked", "blocked", "reminded", "snoozed"].contains(state) }

    /// The verbs shown as buttons: the item's own (at most two, Done and Dismiss aside), then Done and Dismiss.
    var primaryActions: [DockBriefAction] {
        Array(actions.filter { $0.type != "done" && $0.type != "dismiss" }.prefix(2))
    }

    /// A meeting's "Join" (Open with a web link): today's rows offer it.
    var joinAction: DockBriefAction? {
        guard let url, DockBriefLinks.isWebLink(url) else { return nil }
        return actions.first { $0.type == "open" }
    }

    /// "Drafted in Gmail", "Task started", "Reminder set for 4:40 PM", …: what the state says, for a handled item.
    var stateLine: String? {
        switch state {
        case "drafted": return "Draft saved in Gmail · not sent"
        case "tasked": return "T3 task started"
        case "blocked": return "Time blocked"
        case "reminded", "snoozed": return remindAt.map { "Reminder set for \(DockBriefRemind.when($0))" } ?? "Reminder set"
        case "done": return "Done"
        case "dismissed": return "Dismissed"
        default: return nil
        }
    }

    static func from(_ raw: [String: Any], section fallback: DockBriefSectionKind) -> DockBriefItem? {
        func text(_ key: String) -> String? {
            guard let value = raw[key] as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let id = text("id") else { return nil }
        let section = DockBriefSectionKind.parse(text("section")) ?? fallback
        var kind = (text("kind") ?? text("type") ?? "").lowercased()
        if kind.isEmpty { kind = section == .today ? "event" : section == .agents ? "agent" : section == .fyi ? "fyi" : "email" }
        var actions: [DockBriefAction] = []
        for entry in (raw["actions"] as? [Any]) ?? [] {
            if let name = entry as? String, !name.isEmpty {
                let type = DockBriefAction.normalize(name)
                actions.append(DockBriefAction(type: type, label: DockBriefAction.defaultLabel(type), url: nil))
            } else if let object = entry as? [String: Any] {
                guard let name = (object["type"] as? String) ?? (object["action"] as? String) ?? (object["id"] as? String),
                      !name.isEmpty else { continue }
                let type = DockBriefAction.normalize(name)
                let label = (object["label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? DockBriefAction.defaultLabel(type)
                actions.append(DockBriefAction(type: type, label: label, url: object["url"] as? String))
            }
        }
        var unique: [DockBriefAction] = []
        for action in actions where !unique.contains(where: { $0.type == action.type }) { unique.append(action) }
        let account = text("account")
        let accountIsEmail = account?.contains("@") ?? false
        let title = DockText.oneLine(text("title") ?? "Untitled")
        let why = DockText.oneLine(text("why") ?? text("detail") ?? text("subtitle") ?? "")
        let state = (text("state") ?? "open").lowercased()
        let result = raw["result"] as? [String: Any]
        let resultUrl = (result?["url"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let reminded = state == "reminded" || state == "snoozed"
        return DockBriefItem(
            id: id, section: section, kind: kind,
            account: accountIsEmail ? nil : account?.lowercased(),
            accountEmail: text("accountEmail") ?? (accountIsEmail ? account : nil),
            title: title, why: why, suggestion: text("suggestion").map(DockText.oneLine),
            actions: unique, state: state,
            url: text("url") ?? text("openUrl") ?? text("link"),
            draftUrl: state == "drafted" ? resultUrl ?? text("draftUrl") : nil,
            remindAt: reminded ? (result?["until"] as? String).flatMap(DockDate.parse) : nil,
            startsAt: text("startsAt").flatMap(DockDate.parse) ?? text("start").flatMap(DockDate.parse),
            endsAt: text("endsAt").flatMap(DockDate.parse) ?? text("end").flatMap(DockDate.parse),
            conflict: (raw["conflict"] as? Bool) ?? (kind == "conflict"),
            inboxItemId: text("inboxItemId") ?? text("itemId"))
    }

    /// The same item after `type` went through (`at`: the Remind me choice).
    func acted(_ type: String, at: Date? = nil) -> DockBriefItem {
        var next = self
        if let state = DockBriefAction.resultingState(type) { next.state = state }
        if type == "remind", let at { next.remindAt = at }
        return next
    }
}

struct DockBriefSection: Equatable, Identifiable {
    let kind: DockBriefSectionKind
    var items: [DockBriefItem]
    var id: String { kind.rawValue }
}

/// One answer of `GET /v1/desktop/briefing`.
struct DockBrief: Equatable {
    var available: Bool
    /// ready | building | waiting (not built yet today) | failed | off
    var status: String
    /// The day it is for (YYYY-MM-DD, the bridge's own day: the Mac's).
    var date: String?
    var revision: Int
    var updatedAt: Date?
    var headline: String
    var spoken: String
    var sections: [DockBriefSection]
    var reason: String?

    static let caps: [DockBriefSectionKind: Int] = [.doFirst: 3, .today: 5, .agents: 3, .fyi: 3]

    static func decode(_ data: Data) -> DockBrief? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return from(object)
    }

    /// The brief itself, or wrapped (`{briefing: {...}}`, the R1 runtime's shape); sections as a list
    /// (`sections: [{kind, items}]`), as keys (`doFirst: [...]`, `today: [...]`) or one `items` list with a `section`
    /// on each item.
    static func from(_ raw: [String: Any]) -> DockBrief? {
        var object = raw
        if let inner = raw["briefing"] as? [String: Any] {
            object = inner
            for key in ["available", "status"] where object[key] == nil { object[key] = raw[key] }
        }
        func text(_ key: String) -> String? {
            guard let value = object[key] as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        var buckets: [DockBriefSectionKind: [DockBriefItem]] = [:]
        func add(_ list: Any?, _ kind: DockBriefSectionKind?) {
            for entry in (list as? [Any]) ?? [] {
                guard let item = entry as? [String: Any] else { continue }
                let section = kind ?? DockBriefSectionKind.parse(item["section"] as? String) ?? .fyi
                guard let parsed = DockBriefItem.from(item, section: section) else { continue }
                buckets[parsed.section, default: []].append(parsed)
            }
        }
        if let sections = object["sections"] as? [[String: Any]] {
            for section in sections {
                let kind = DockBriefSectionKind.parse((section["kind"] as? String) ?? (section["id"] as? String) ?? (section["title"] as? String))
                add(section["items"], kind)
            }
        } else if let sections = object["sections"] as? [String: Any] {
            for (key, list) in sections { add(list, DockBriefSectionKind.parse(key)) }
        }
        for (key, value) in object where key != "sections" && key != "items" {
            if let kind = DockBriefSectionKind.parse(key), value is [Any] { add(value, kind) }
        }
        add(object["items"], nil)
        let sections = DockBriefSectionKind.allCases.compactMap { kind -> DockBriefSection? in
            var seen = Set<String>()
            let items = (buckets[kind] ?? []).filter { seen.insert($0.id).inserted }
            return items.isEmpty ? nil : DockBriefSection(kind: kind, items: Array(items.prefix(caps[kind] ?? 3)))
        }
        let status = (text("status") ?? (sections.isEmpty ? "off" : "ready")).lowercased()
        let available = (object["available"] as? Bool) ?? (status != "off" && !sections.isEmpty)
        let revision = (object["revision"] as? Int) ?? (object["revision"] as? Double).map { Int($0) } ?? 0
        let updated = text("generatedAt").flatMap(DockDate.parse) ?? text("updatedAt").flatMap(DockDate.parse)
            ?? text("builtAt").flatMap(DockDate.parse)
        return DockBrief(available: available, status: status, date: text("date"), revision: revision, updatedAt: updated,
                         headline: DockText.oneLine(text("headline") ?? ""), spoken: text("spoken") ?? "",
                         sections: sections, reason: text("reason"))
    }

    func section(_ kind: DockBriefSectionKind) -> DockBriefSection? { sections.first { $0.kind == kind } }

    var items: [DockBriefItem] { sections.flatMap(\.items) }

    func item(_ id: String) -> DockBriefItem? { items.first { $0.id == id } }

    /// The items Samin still has to deal with (Do first and Agents; today's events and FYI ask nothing).
    var openCount: Int {
        sections.filter { $0.kind == .doFirst || $0.kind == .agents }.flatMap(\.items).filter { $0.isOpen && !$0.isHandled }.count
    }

    /// "YYYY-MM-DD" of `date` on `calendar` (the Mac's own day).
    static func day(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Before noon (CONTRACTS-WAVE8 §D2): today's brief, ready, with something in it.
    static let morningEndsAtHour = 12

    func isMorning(now: Date, calendar: Calendar = .current) -> Bool {
        guard available, !sections.isEmpty, calendar.component(.hour, from: now) < Self.morningEndsAtHour else { return false }
        if let date { return date == Self.day(now, calendar: calendar) }
        return updatedAt.map { calendar.isDate($0, inSameDayAs: now) } ?? true
    }

    /// The dock's Morning section: what to do first (open or just handled), then today's events still to come.
    func dockRows(now: Date) -> (first: [DockBriefItem], today: [DockBriefItem]) {
        let first = (section(.doFirst)?.items ?? []).filter { $0.state != "dismissed" && $0.state != "done" }
        let today = (section(.today)?.items ?? []).filter { ($0.endsAt ?? $0.startsAt ?? now) >= now }
        return (Array(first.prefix(3)), Array(today.prefix(3)))
    }

    /// The same brief with one item replaced (an action's optimistic result, or its rollback).
    func replacing(_ item: DockBriefItem) -> DockBrief {
        var next = self
        for index in next.sections.indices {
            if let row = next.sections[index].items.firstIndex(where: { $0.id == item.id }) { next.sections[index].items[row] = item }
        }
        return next
    }
}

/// What an item action answered: `{ok, item: {…, state}, result: {draftId?, url?, itemId?, eventId?, until?},
/// revision}` (a bare `state` is read too).
struct DockBriefActResult: Equatable {
    var state: String?
    var url: String?
    var itemId: String?
    var draftId: String?
    /// Remind me: when the reminder is.
    var until: Date?

    static func decode(_ data: Data) -> DockBriefActResult {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return DockBriefActResult() }
        let result = (object["result"] as? [String: Any]) ?? [:]
        func text(_ value: Any?) -> String? { (value as? String).flatMap { $0.isEmpty ? nil : $0 } }
        return DockBriefActResult(state: text(object["state"]) ?? text((object["item"] as? [String: Any])?["state"]),
                                  url: text(result["url"]) ?? text(object["url"]),
                                  itemId: text(result["itemId"]) ?? text(object["itemId"]),
                                  draftId: text(result["draftId"]), until: text(result["until"]).flatMap(DockDate.parse))
    }
}

enum DockBriefLinks {
    /// A Gmail link for `email`'s mailbox: Google opens `/mail/u/0/` in whichever account is first in the browser, so
    /// the personal mailbox's thread would open in the business account. `authuser` picks the account (kept when the
    /// bridge already set it; other links are left as they are).
    static func withAccount(_ link: String, email: String?) -> String {
        guard let email, email.contains("@"), var components = URLComponents(string: link),
              let host = components.host?.lowercased(), host == "mail.google.com" else { return link }
        var items = components.queryItems ?? []
        if items.contains(where: { $0.name == "authuser" }) { return link }
        items.append(URLQueryItem(name: "authuser", value: email))
        components.queryItems = items
        // `+` and `@` are fine in a query, but Google expects the address escaped.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "@", with: "%40").replacingOccurrences(of: "+", with: "%2B")
        return components.string ?? link
    }

    /// Only web links open (never `file:`, `javascript:` or an app's own scheme from a brief).
    static func isWebLink(_ link: String) -> Bool {
        guard let url = URL(string: link), let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "https" || scheme == "http") && url.host != nil
    }
}

/// "Remind me" (the brief's own verb): in an hour, at 2 PM, tonight at 6, tomorrow at 9 (each only while it is still
/// ahead). The bridge puts a 15-minute "Reminder: …" on the calendar then; the item shows "Reminder set for …".
enum DockBriefRemind {
    struct Choice: Equatable {
        let label: String
        let at: Date
    }

    /// "4:40 PM" today, "Thu 9:00 AM" another day.
    static func when(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = calendar.isDate(date, inSameDayAs: now) ? "h:mm a" : "EEE h:mm a"
        return formatter.string(from: date)
    }

    static func choices(now: Date, calendar: Calendar = .current) -> [Choice] {
        var choices = [Choice(label: "In 1 hour", at: now.addingTimeInterval(3600))]
        func today(_ hour: Int) -> Date? { calendar.date(bySettingHour: hour, minute: 0, second: 0, of: now) }
        if let two = today(14), two.timeIntervalSince(now) >= 30 * 60 { choices.append(Choice(label: "2 PM", at: two)) }
        if let six = today(18), six.timeIntervalSince(now) >= 30 * 60 { choices.append(Choice(label: "Tonight 6 PM", at: six)) }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           let nine = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) {
            choices.append(Choice(label: "Tomorrow 9 AM", at: nine))
        }
        return choices
    }
}
