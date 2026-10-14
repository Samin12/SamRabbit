import AppKit
import SwiftUI

/// The morning brief for the dock (CONTRACTS-WAVE8 §D2, DockBriefing.swift has the rules): read from the bridge
/// (`GET /v1/desktop/briefing`) when the dock starts and every 5 minutes from 05:00 to noon, and the item actions
/// (`POST /v1/desktop/briefing/items/<id>/act {action, at?}`) with their result shown at once (rolled back when the
/// bridge says no). Draft reply makes a Gmail draft on the bridge (nothing is ever sent) and opens it in the browser, in
/// the item's own Google account. Nothing here logs what an item says.
@MainActor
final class DockBriefingStore: ObservableObject {
    @Published private(set) var brief: DockBrief?
    /// Item id → the action on its way.
    @Published private(set) var busy: [String: String] = [:]
    @Published private(set) var notes: [String: DockStore.Note] = [:]
    /// The item whose "Remind me" choices are open.
    @Published var remindOpen: String?
    /// The Gmail draft each drafted item opened (to open it again).
    @Published private(set) var drafts: [String: String] = [:]
    @Published private(set) var refreshing = false
    /// An agent item's Open: the dock's list on that inbox item.
    var onOpenInboxItem: ((String) -> Void)?

    private let live: Bool
    private var task: Task<Void, Never>?
    private var fetchedAt = Date.distantPast

    init() {
        live = true
    }

    /// Snapshots: this brief, nothing live.
    init(fixture: DockBrief?) {
        live = false
        brief = fixture
    }

    func start() {
        guard live, task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let wait = await self.pollOnce()
                try? await Task.sleep(for: .seconds(wait))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// The list opened: read again unless it was read in the last minute (the morning only).
    func listOpened() {
        guard live, Date().timeIntervalSince(fetchedAt) > 60, Self.inMorningHours(Date()) else { return }
        Task { _ = await fetch() }
    }

    static func inMorningHours(_ now: Date, calendar: Calendar = .current) -> Bool {
        let hour = calendar.component(.hour, from: now)
        return hour >= 5 && hour < DockBrief.morningEndsAtHour
    }

    /// One read when it is time; how long to wait before the next look.
    private func pollOnce() async -> TimeInterval {
        let now = Date()
        // Outside the morning the dock shows no brief: nothing to read (the first look at launch aside).
        guard Self.inMorningHours(now) || brief == nil && fetchedAt == .distantPast else {
            if brief != nil, !(brief?.isMorning(now: now) ?? false) { brief = nil }
            return 600
        }
        switch await fetch() {
        case 404, 405: return 1800  // a bridge without the brief
        case 200: return 300
        default: return 120
        }
    }

    @discardableResult
    private func fetch() async -> Int {
        fetchedAt = Date()
        let answer = await DockBriefingAPI.send("GET", "/v1/desktop/briefing", query: [URLQueryItem(name: "wait", value: "0")])
        if answer.status == 200, let next = DockBrief.decode(answer.data) {
            if next != brief { brief = next }
        } else if answer.status != 0 {
            Log.write("dock: briefing answered HTTP \(answer.status)")
        }
        return answer.status
    }

    /// "↻" in the section: the bridge builds it again (at most once in 5 minutes there), read a moment later.
    func refresh() {
        guard live, !refreshing else { return }
        refreshing = true
        Task {
            let answer = await DockBriefingAPI.send("POST", "/v1/desktop/briefing/refresh", body: [:])
            Log.write("dock: briefing refresh (HTTP \(answer.status))")
            try? await Task.sleep(for: .seconds(answer.status == 202 ? 4 : 0.5))
            await fetch()
            refreshing = false
        }
    }

    // MARK: actions

    func act(_ item: DockBriefItem, _ type: String, at: Date? = nil) {
        guard busy[item.id] == nil else { return }
        remindOpen = nil
        notes[item.id] = nil
        // Open with a link needs no bridge; an agent item opens in the dock's list.
        if type == "open" {
            if let inbox = item.inboxItemId, item.url == nil {
                onOpenInboxItem?(inbox)
                return
            }
            if let url = item.url {
                open(url, account: item.accountEmail)
                return
            }
        }
        guard let brief else { return }
        let before = item
        if DockBriefAction.resultingState(type) != nil { self.brief = brief.replacing(item.acted(type)) }
        busy[item.id] = type
        guard live else {
            busy[item.id] = nil
            return
        }
        var body: [String: Any] = ["action": type]
        if let at { body["at"] = VoiceNoteUpload.iso(at) }
        Task {
            let answer = await DockBriefingAPI.send("POST", DockBriefingAPI.itemPath(item.id), body: body)
            busy[item.id] = nil
            guard (200..<300).contains(answer.status) else {
                Log.write("dock: briefing \(type) failed (HTTP \(answer.status))")
                if let current = self.brief { self.brief = current.replacing(before) }
                notes[item.id] = DockBriefingAPI.note(status: answer.status, data: answer.data)
                return
            }
            Log.write("dock: briefing \(type) ok")
            let result = DockBriefActResult.decode(answer.data)
            if let state = result.state, let current = self.brief, let now = current.item(item.id), now.state != state {
                var updated = now
                updated.state = state
                self.brief = current.replacing(updated)
            }
            switch type {
            case "draft_reply":
                // The item now says "Draft saved in Gmail · not sent"; the draft opens to be read and sent by Samin.
                if let url = result.url {
                    drafts[item.id] = url
                    open(url, account: item.accountEmail)
                }
            case "open":
                if let url = result.url { open(url, account: item.accountEmail) }
            default:
                break
            }
            // What changed on the bridge (the next revision) comes in with the next read.
            try? await Task.sleep(for: .seconds(1))
            await fetch()
        }
    }

    /// Opens a draft again (a drafted item's "Open draft").
    func openDraft(_ item: DockBriefItem) {
        guard let url = drafts[item.id] ?? item.url else { return }
        open(url, account: item.accountEmail)
    }

    func dismissNote(_ id: String) { notes[id] = nil }

    /// Snapshots: a line under an item.
    func showNote(_ note: DockStore.Note, for id: String) { notes[id] = note }

    private func open(_ link: String, account: String?) {
        let target = DockBriefLinks.withAccount(link, email: account)
        guard DockBriefLinks.isWebLink(target), let url = URL(string: target) else { return }
        guard live else { return }
        NSWorkspace.shared.open(url)
    }
}

/// `/v1/desktop/briefing*` through the desktop API (loopback, the desktop token).
enum DockBriefingAPI {
    static func itemPath(_ id: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return "/v1/desktop/briefing/items/\(id.addingPercentEncoding(withAllowedCharacters: safe) ?? id)/act"
    }

    /// (HTTP status, body): 0 = unreachable, -1 = no desktop token.
    static func send(_ method: String, _ path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil) async -> (status: Int, data: Data) {
        var components = URLComponents(url: Config.origin, resolvingAgainstBaseURL: false)!
        components.percentEncodedPath = path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url, var request = Config.request(url, timeout: method == "GET" ? 10 : 45) else { return (-1, Data()) }
        request.httpMethod = method
        if let body {
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
        } catch {
            return (0, Data())
        }
    }

    @MainActor static func note(status: Int, data: Data) -> DockStore.Note {
        let error = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any]
        return DockStore.note(for: DockAPI.Failure(status: status, code: error?["code"] as? String, message: error?["message"] as? String))
    }
}

// MARK: the section

/// The dock list's "Morning" section before noon: the brief's headline, what to do first with its verbs as buttons
/// (Hark-style: the verb is the button), and today's next events (a clash flagged). Done and dismissed items leave;
/// one that was drafted, made a task or got its time stays, quieter, saying so.
struct DockMorningSection: View {
    @ObservedObject var morning: DockBriefingStore
    let now: Date
    let scale: CGFloat

    var body: some View {
        if let brief = morning.brief, brief.isMorning(now: now) {
            let p = scale
            let rows = brief.dockRows(now: now)
            VStack(alignment: .leading, spacing: 6 * p) {
                header(brief, p)
                if !brief.headline.isEmpty {
                    Text(brief.headline)
                        .font(.system(size: 13 * p, weight: .semibold))
                        .foregroundStyle(DockPalette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 10 * p)
                }
                ForEach(rows.first) { item in
                    DockMorningRow(item: item, morning: morning, now: now, scale: p)
                }
                if !rows.today.isEmpty {
                    today(rows.today, p)
                }
            }
            .padding(.bottom, 4 * p)
        }
    }

    private func header(_ brief: DockBrief, _ p: CGFloat) -> some View {
        HStack(spacing: 6 * p) {
            Image(systemName: "sun.horizon.fill")
                .font(.system(size: 10 * p, weight: .semibold))
            Text("Morning")
                .font(.system(size: 10.5 * p, weight: .semibold))
                .textCase(.uppercase)
                .kerning(0.7 * p)
            if let updated = brief.updatedAt {
                Text(Self.time(updated))
                    .font(.system(size: 10.5 * p, weight: .medium))
                    .monospacedDigit()
                    .opacity(0.75)
            }
            Spacer()
            if morning.refreshing {
                DockProgressRing(progress: nil, size: 11 * p)
            } else {
                DockRoundButton(symbol: "arrow.clockwise", size: 22 * p, fill: Color.clear, help: "Read the mail again") {
                    morning.refresh()
                }
            }
        }
        .foregroundStyle(DockMorningRow.sun)
        .padding(.horizontal, 10 * p)
        .padding(.top, 10 * p)
    }

    private func today(_ events: [DockBriefItem], _ p: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4 * p) {
            Text("Today")
                .font(.system(size: 10 * p, weight: .semibold))
                .textCase(.uppercase)
                .kerning(0.6 * p)
                .foregroundStyle(DockPalette.tertiary)
            ForEach(events) { event in
                HStack(alignment: .firstTextBaseline, spacing: 8 * p) {
                    Text(event.startsAt.map(Self.time) ?? "All day")
                        .font(.system(size: 11.5 * p, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(event.startsAt.map { $0 <= now } ?? false ? DockPalette.accentText : DockPalette.secondary)
                        .frame(width: 58 * p, alignment: .leading)
                    Text(event.title)
                        .font(.system(size: 12 * p))
                        .foregroundStyle(DockPalette.ink.opacity(0.88))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if event.conflict {
                        Text("Clash")
                            .font(.system(size: 9.5 * p, weight: .bold))
                            .textCase(.uppercase)
                            .foregroundStyle(DockPalette.error)
                            .padding(.horizontal, 5 * p)
                            .padding(.vertical, 1.5 * p)
                            .background(Capsule().fill(DockPalette.error.opacity(0.14)))
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 10 * p)
        .padding(.top, 4 * p)
    }

    /// "9:30 AM".
    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }
}

struct DockMorningRow: View {
    let item: DockBriefItem
    @ObservedObject var morning: DockBriefingStore
    let now: Date
    let scale: CGFloat

    static let sun = Color(red: 1, green: 0.79, blue: 0.45)

    var body: some View {
        let p = scale
        let busy = morning.busy[item.id]
        HStack(alignment: .top, spacing: 10 * p) {
            glyph(p)
            VStack(alignment: .leading, spacing: 3 * p) {
                HStack(alignment: .firstTextBaseline, spacing: 6 * p) {
                    Text(item.title)
                        .font(.system(size: 13 * p, weight: .semibold))
                        .foregroundStyle(item.isHandled ? DockPalette.secondary : DockPalette.ink)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4 * p)
                    if let account = item.account {
                        Text(account == "personal" ? "Personal" : "Work")
                            .font(.system(size: 9.5 * p, weight: .semibold))
                            .foregroundStyle(DockPalette.tertiary)
                            .padding(.horizontal, 5 * p)
                            .padding(.vertical, 1.5 * p)
                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                            .fixedSize()
                    }
                }
                if item.isHandled {
                    handled(p)
                } else {
                    if !item.why.isEmpty {
                        Text(item.why)
                            .font(.system(size: 12 * p))
                            .foregroundStyle(DockPalette.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    buttons(p, busy: busy)
                        .padding(.top, 3 * p)
                }
                if morning.remindOpen == item.id {
                    DockFlow(spacing: 5 * p, lineSpacing: 5 * p) {
                        ForEach(DockBriefRemind.choices(now: now), id: \.label) { choice in
                            DockCapsuleButton(title: choice.label, symbol: "bell", style: .plain, scale: p * 0.92) {
                                morning.act(item, "remind", at: choice.at)
                            }
                        }
                    }
                }
                if let note = morning.notes[item.id] {
                    DockNoteLine(note: note, scale: p * 0.95, dismiss: { morning.dismissNote(item.id) })
                }
            }
        }
        .padding(10 * p)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 13 * p, style: .continuous).fill(Color.white.opacity(item.isHandled ? 0.025 : 0.045)))
        .overlay(RoundedRectangle(cornerRadius: 13 * p, style: .continuous)
            .strokeBorder(item.conflict ? DockPalette.error.opacity(0.22) : Self.sun.opacity(item.isHandled ? 0.06 : 0.14), lineWidth: 1))
        .padding(.horizontal, 4 * p)
    }

    /// Drafted, made a task, time blocked: what happened, the draft to open, and Done to clear it.
    private func handled(_ p: CGFloat) -> some View {
        HStack(spacing: 6 * p) {
            Label(item.stateLine ?? "", systemImage: "checkmark")
                .font(.system(size: 11.5 * p, weight: .medium))
                .foregroundStyle(DockNoteBar.green)
                .lineLimit(1)
            Spacer(minLength: 4 * p)
            if item.state == "drafted", morning.drafts[item.id] != nil || item.url != nil {
                DockCapsuleButton(title: "Open draft", symbol: "arrow.up.forward.app", style: .plain, scale: p * 0.92) {
                    morning.openDraft(item)
                }
            }
            DockRoundButton(symbol: "checkmark", size: 24 * p, fill: DockPalette.control, help: "Done") { morning.act(item, "done") }
        }
    }

    @ViewBuilder private func buttons(_ p: CGFloat, busy: String?) -> some View {
        HStack(spacing: 6 * p) {
            ForEach(Array(item.primaryActions.enumerated()), id: \.element.type) { index, action in
                DockCapsuleButton(title: action.label, symbol: DockBriefAction.symbol(action.type),
                                  style: index == 0 ? .accent : .plain, scale: p, disabled: busy != nil) {
                    if action.type == "remind" {
                        morning.remindOpen = morning.remindOpen == item.id ? nil : item.id
                    } else {
                        morning.act(item, action.type)
                    }
                }
            }
            Spacer(minLength: 0)
            if let busy {
                DockProgressRing(progress: nil, size: 11 * p)
                Text(busy == "draft_reply" ? "Drafting…" : "…").font(.system(size: 11 * p)).foregroundStyle(DockPalette.tertiary)
            } else {
                DockRoundButton(symbol: "checkmark", size: 24 * p, fill: DockPalette.control, help: "Done") { morning.act(item, "done") }
                DockRoundButton(symbol: "xmark", size: 24 * p, fill: Color.clear, help: "Dismiss: not today") { morning.act(item, "dismiss") }
            }
        }
    }

    private func glyph(_ p: CGFloat) -> some View {
        let symbol: String
        switch item.kind {
        case "email": symbol = "envelope.fill"
        case "conflict": symbol = "calendar.badge.exclamationmark"
        case "event": symbol = "calendar"
        case "agent": symbol = "sparkles"
        default: symbol = "info.circle"
        }
        return ZStack {
            RoundedRectangle(cornerRadius: 8 * p, style: .continuous)
                .fill(item.conflict ? DockPalette.error.opacity(0.16) : Self.sun.opacity(0.14))
            Image(systemName: symbol)
                .font(.system(size: 12 * p, weight: .semibold))
                .foregroundStyle(item.conflict ? DockPalette.error : Self.sun)
        }
        .frame(width: 28 * p, height: 28 * p)
    }
}
