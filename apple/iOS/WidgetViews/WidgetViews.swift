import AppIntents
import SamRabbitKit
import SwiftUI
import WidgetKit

// The widget faces, shared by the widget extension and the app (Settings > Widget gallery and the
// screenshot harness render them too). Every view takes a `WidgetSnapshot`.

/// What a widget shows.
struct WidgetSnapshot: Sendable {
    var date: Date
    var summary: MobileSummary?
    /// When the shown summary was fetched.
    var fetchedAt: Date?
    var paired: Bool

    static func sample(_ date: Date = .now) -> WidgetSnapshot {
        WidgetSnapshot(date: date, summary: .sample(now: date), fetchedAt: date, paired: true)
    }

    var stale: Bool { (fetchedAt.map { date.timeIntervalSince($0) } ?? .infinity) > 45 * 60 }
    /// Every agent on the Mac when the summary carries the inbox's counts (the app and the provider add them), else T3's.
    var needsYou: Int { summary?.needsYouCount ?? 0 }
    var working: Int { summary?.workingCount ?? 0 }
    var mood: OrbMood { paired ? OrbMood.from(summary, reachable: !stale) : .offline }
    var nextEvents: [CalendarEvent] { (summary?.calendar.next ?? []).filter { ($0.endsAt ?? .distantFuture) > date } }
    /// The first tasks to list: every agent's (the inbox's, in its order), else T3's threads.
    var taskItems: [InboxItem] {
        if let items = summary?.inbox?.items, !items.isEmpty { return items }
        return (summary?.t3.threads ?? []).map(InboxItem.init(thread:))
    }
}

/// The widget background: the night backdrop with a blue bloom.
struct WidgetBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x111A2E), Color(hex: 0x0A0E17)], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [SamTheme.orb.opacity(0.32), .clear], center: .init(x: 0.85, y: -0.1),
                           startRadius: 0, endRadius: 220)
            RadialGradient(colors: [SamTheme.violet.opacity(0.10), .clear], center: .init(x: 0, y: 1.1),
                           startRadius: 0, endRadius: 200)
        }
    }
}

/// Puts a face in a widget (container background) or in a stand-alone rounded tile (gallery).
struct WidgetChrome<Content: View>: View {
    var standalone: Bool
    var size: CGSize?
    @ViewBuilder var content: Content

    var body: some View {
        if standalone {
            content
                .padding(16)
                .frame(width: size?.width, height: size?.height)
                .background(WidgetBackdrop())
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .environment(\.colorScheme, .dark)
        } else {
            content.containerBackground(for: .widget) { WidgetBackdrop() }
        }
    }
}

struct UnpairedFace: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            OrbView(mood: .offline, animated: false, halo: false).frame(width: 34, height: 34)
            Spacer(minLength: 0)
            Text("SamRabbit").font(.system(size: 14, weight: .semibold)).foregroundStyle(SamTheme.ink)
            Text("Open the app to pair with your Mac.").font(.system(size: 12)).foregroundStyle(SamTheme.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Small: orb + counts

struct StatusSmallFace: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        if !snapshot.paired {
            UnpairedFace()
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    OrbView(mood: snapshot.mood, animated: false)
                        .frame(width: 46, height: 46)
                        .padding(.top, 2)
                    Spacer()
                    if snapshot.summary?.r1.live == true {
                        Image(systemName: "waveform").font(.system(size: 13, weight: .bold)).foregroundStyle(SamTheme.green)
                    }
                }
                Spacer(minLength: 6)
                CountLine(count: snapshot.needsYou, label: "need you", color: SamTheme.amber, symbol: "hand.raised.fill")
                CountLine(count: snapshot.working, label: "working", color: SamTheme.cyan, symbol: "circle.dotted.circle")
                    .padding(.top, 3)
                Text(footer)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(SamTheme.faint)
                    .lineLimit(1)
                    .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    var footer: String {
        if snapshot.stale { return "As of \(Formatting.ago(snapshot.fetchedAt, now: snapshot.date))" }
        if let next = snapshot.nextEvents.first { return "\(next.title) \(Formatting.time(next.startsAt))" }
        return "SamRabbit"
    }
}

struct CountLine: View {
    let count: Int
    let label: String
    let color: Color
    let symbol: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(count)")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(count > 0 ? SamTheme.ink : SamTheme.faint)
                .contentTransition(.numericText())
                .widgetAccentable()
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(count > 0 ? color : SamTheme.faint)
        }
    }
}

// MARK: - Medium: Tasks

struct TasksMediumFace: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        if !snapshot.paired {
            UnpairedFace()
        } else {
            let threads = Array(snapshot.taskItems.prefix(3))
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    OrbView(mood: snapshot.mood, animated: false, halo: false).frame(width: 20, height: 20)
                    Text("Tasks").font(.system(size: 15, weight: .semibold)).foregroundStyle(SamTheme.ink)
                    Spacer()
                    MiniCount(count: snapshot.needsYou, color: SamTheme.amber, symbol: "hand.raised.fill")
                    MiniCount(count: snapshot.working, color: SamTheme.cyan, symbol: "circle.dotted.circle")
                }
                if threads.isEmpty {
                    Spacer()
                    Text("No tasks. Ask SamRabbit for something.").font(.system(size: 13)).foregroundStyle(SamTheme.muted)
                    Spacer()
                } else {
                    VStack(spacing: 7) {
                        ForEach(threads) { item in
                            Link(destination: WidgetItemRow.link(item)) {
                                WidgetItemRow(item: item, now: snapshot.date)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

struct MiniCount: View {
    let count: Int
    let color: Color
    let symbol: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold))
            Text("\(count)").font(.system(size: 12, weight: .bold, design: .rounded))
        }
        .foregroundStyle(count > 0 ? color : SamTheme.faint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill((count > 0 ? color : SamTheme.faint).opacity(0.15)))
    }
}

/// One task in a widget: its source (T3 Code, Claude Code, Codex), title, state and project.
struct WidgetItemRow: View {
    let item: InboxItem
    let now: Date

    /// "In the terminal" / "In the Codex app" for a prompt only the Mac answers, else the status.
    static func state(_ item: InboxItem, _ style: StatusStyle) -> String {
        switch item.heldOnMac {
        case .waitingInTerminal: "In the terminal"
        case .waitingInApp: "In the Codex app"
        default: style.label
        }
    }

    /// T3 threads open their own screen; Claude Code and Codex sessions theirs (`samrabbit://inbox/<id>`).
    static func link(_ item: InboxItem) -> URL {
        if let threadId = item.threadId, let url = URL(string: "samrabbit://thread/\(threadId)") { return url }
        return URL(string: "samrabbit://inbox/\(item.id)") ?? URL(string: "samrabbit://tab/tasks")!
    }

    var body: some View {
        let style = StatusStyle(item.status)
        HStack(spacing: 9) {
            SourceGlyph(item: item, size: 22)
                .widgetAccentable()
            VStack(alignment: .leading, spacing: 0) {
                Text(item.title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(SamTheme.ink)
                    .lineLimit(1)
                Text([WidgetItemRow.state(item, style), item.project]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11))
                    .foregroundStyle(item.needsYou ? style.color : SamTheme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(Formatting.ago(item.updatedAt, now: now))
                .font(.system(size: 10.5))
                .foregroundStyle(SamTheme.faint)
        }
    }
}

// MARK: - Medium: Up next + Block 30m

struct UpNextMediumFace: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        if !snapshot.paired {
            UnpairedFace()
        } else {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "calendar").font(.system(size: 12, weight: .bold)).foregroundStyle(SamTheme.orbPale)
                        Text("Up next").font(.system(size: 15, weight: .semibold)).foregroundStyle(SamTheme.ink)
                    }
                    let events = Array(snapshot.nextEvents.prefix(2))
                    if events.isEmpty {
                        Spacer()
                        Text("Nothing else today.").font(.system(size: 13)).foregroundStyle(SamTheme.muted)
                        Spacer()
                    } else {
                        ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                            WidgetEventRow(event: event, now: snapshot.date, highlight: index == 0)
                        }
                        Spacer(minLength: 0)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(intent: BlockTimeIntent(minutes: 30)) {
                    VStack(spacing: 6) {
                        Image(systemName: "calendar.badge.clock")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(SamTheme.violet)
                        Text("Block").font(.system(size: 13, weight: .semibold)).foregroundStyle(SamTheme.ink)
                        Text("30 min").font(.system(size: 11)).foregroundStyle(SamTheme.muted)
                    }
                    .frame(width: 84)
                    .frame(maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(SamTheme.violet.opacity(0.16)))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(SamTheme.violet.opacity(0.35), lineWidth: 0.8))
                }
                .buttonStyle(.plain)
                .widgetAccentable()
            }
        }
    }
}

struct WidgetEventRow: View {
    let event: CalendarEvent
    let now: Date
    var highlight = false

    var body: some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 2)
                .fill(highlight ? SamTheme.accent : SamTheme.violet.opacity(0.7))
                .frame(width: 3, height: 32)
                .widgetAccentable()
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(SamTheme.ink).lineLimit(1)
                Text("\(Formatting.time(event.startsAt, allDay: event.allDay)) · \(event.isNow(now) ? "now" : Formatting.until(event.startsAt, end: event.endsAt, now: now))")
                    .font(.system(size: 11.5))
                    .foregroundStyle(highlight ? SamTheme.orbPale : SamTheme.muted)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Large: Dashboard

struct DashboardLargeFace: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        if !snapshot.paired {
            UnpairedFace()
        } else {
            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 12) {
                    OrbView(mood: snapshot.mood, animated: false).frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(r1Line).font(.system(size: 15, weight: .semibold)).foregroundStyle(SamTheme.ink).lineLimit(1)
                        Text(snapshot.summary?.mac.name ?? "Your Mac")
                            .font(.system(size: 11.5)).foregroundStyle(SamTheme.muted).lineLimit(1)
                    }
                    Spacer()
                    MiniCount(count: snapshot.needsYou, color: SamTheme.amber, symbol: "hand.raised.fill")
                    MiniCount(count: snapshot.working, color: SamTheme.cyan, symbol: "circle.dotted.circle")
                }
                if let next = snapshot.nextEvents.first {
                    WidgetEventRow(event: next, now: snapshot.date, highlight: true)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.05)))
                }
                VStack(spacing: 7) {
                    ForEach(Array(snapshot.taskItems.prefix(3))) { item in
                        Link(destination: WidgetItemRow.link(item)) {
                            WidgetItemRow(item: item, now: snapshot.date)
                        }
                    }
                }
                if let latest = snapshot.summary?.latestConversation {
                    Link(destination: URL(string: "samrabbit://conversation/\(latest.conversationId)")!) {
                        HStack(spacing: 8) {
                            Image(systemName: "waveform").font(.system(size: 11, weight: .bold)).foregroundStyle(SamTheme.orbPale)
                            Text(latest.title ?? "Conversation").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(SamTheme.ink2)
                            Text(Formatting.clip(latest.preview, 60)).font(.system(size: 12)).foregroundStyle(SamTheme.muted)
                        }
                        .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: 10) {
                    // Talk: straight into the live call (the app comes up already in the conversation).
                    Button(intent: TalkToSamRabbitIntent()) {
                        Label("Talk", systemImage: "waveform")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 38)
                            .background(Capsule().fill(LinearGradient(colors: [SamTheme.orb2, SamTheme.orb],
                                                                      startPoint: .top, endPoint: .bottom)))
                    }
                    .buttonStyle(.plain)
                    // A one-shot voice note: the recorder, recording; the Mac files it.
                    Button(intent: VoiceNoteIntent()) {
                        Label("Voice note", systemImage: "waveform.badge.mic")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(SamTheme.ink)
                            .frame(maxWidth: .infinity, minHeight: 38)
                            .background(Capsule().fill(SamTheme.red.opacity(0.2)))
                            .overlay(Capsule().strokeBorder(SamTheme.red.opacity(0.42), lineWidth: 0.8))
                    }
                    .buttonStyle(.plain)
                }
                .widgetAccentable()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    var r1Line: String {
        guard let summary = snapshot.summary else { return "SamRabbit" }
        if summary.r1.live { return "R1 live · \(Formatting.clip(summary.r1.liveTitle, 22))" }
        return "R1 seen \(Formatting.ago(summary.r1.lastSeenAt, now: snapshot.date))"
    }
}

// MARK: - Lock Screen

struct NeedsYouCircularFace: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        let needs = snapshot.needsYou
        let total = max(needs + snapshot.working, 1)
        Gauge(value: Double(needs), in: 0...Double(total)) {
            Image(systemName: "hand.raised.fill")
        } currentValueLabel: {
            VStack(spacing: -1) {
                Text("\(needs)").font(.system(size: 20, weight: .bold, design: .rounded))
                Image(systemName: needs > 0 ? "hand.raised.fill" : "checkmark").font(.system(size: 8, weight: .bold))
            }
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .widgetAccentable()
    }
}

struct NextEventRectangularFace: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let next = snapshot.nextEvents.first {
                Text(next.title).font(.system(size: 15, weight: .semibold)).lineLimit(1).widgetAccentable()
                Text("\(Formatting.time(next.startsAt, allDay: next.allDay)) · \(Formatting.until(next.startsAt, end: next.endsAt, now: snapshot.date))")
                    .font(.system(size: 13)).lineLimit(1)
            } else {
                Text("SamRabbit").font(.system(size: 15, weight: .semibold)).widgetAccentable()
                Text("Nothing else today").font(.system(size: 13))
            }
            Text("\(snapshot.working) working · \(snapshot.needsYou) need you")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct InlineFace: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        if snapshot.needsYou > 0 {
            Label("\(snapshot.needsYou) need you · \(snapshot.working) working", systemImage: "hand.raised.fill")
        } else if let next = snapshot.nextEvents.first {
            Label("\(next.title) \(Formatting.time(next.startsAt))", systemImage: "calendar")
        } else {
            Label("\(snapshot.working) working", systemImage: "circle.dotted.circle")
        }
    }
}
