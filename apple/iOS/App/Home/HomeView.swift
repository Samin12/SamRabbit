import SamRabbitKit
import SwiftUI

/// Home: the orb and its state, Talk (the live conversation), what needs you, what is running, what is
/// next, the latest R1 conversation and the quick actions.
struct HomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(spacing: 26) {
                OrbHeader()
                if !model.isPaired {
                    PairPromptCard()
                } else {
                    TalkButton()
                    QuickActionsGrid()
                    if let error = model.lastError, model.summary != nil { OfflineBanner(error: error) }
                    NeedsYouSection()
                    WorkingSection()
                    UpNextSection()
                    LatestConversationSection()
                    UpdatedFooter()
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 30)
        }
        .scrollIndicators(.hidden)
        .refreshable { await model.refresh(quiet: false) }
        .samScreen()
        .toolbar(.hidden, for: .navigationBar)
    }
}

// MARK: - Orb header

struct OrbHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("SamRabbit")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(SamTheme.ink)
                Spacer()
                ConnectionPill()
            }
            .padding(.top, 6)
            // Tap the orb to talk, like the big button under it.
            Button {
                model.startTalk()
            } label: {
                OrbView(mood: model.orbMood)
                    .frame(width: 136, height: 136)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!model.isPaired)
            .padding(.top, 26)
            .padding(.bottom, 36)
            .accessibilityLabel(headline)
            .accessibilityHint(model.isPaired ? "Talk to SamRabbit" : "")
            Text(headline)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(SamTheme.ink)
                .multilineTextAlignment(.center)
                .contentTransition(.numericText())
            Text(subline)
                .font(.system(size: 14))
                .foregroundStyle(SamTheme.muted)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .animation(.smooth, value: headline)
    }

    var headline: String {
        guard model.isPaired else { return "Not paired yet" }
        guard let summary = model.summary else { return model.lastError == nil ? "Connecting…" : "Can't reach your Mac" }
        if summary.r1.live { return "R1 is live" }
        if summary.t3.needsYou > 0 {
            return summary.t3.needsYou == 1 ? "1 task needs you" : "\(summary.t3.needsYou) tasks need you"
        }
        if summary.t3.working > 0 {
            return summary.t3.working == 1 ? "Working on 1 task" : "Working on \(summary.t3.working) tasks"
        }
        return "All quiet"
    }

    var subline: String {
        guard model.isPaired else { return "Pair with the SamRabbit app on your Mac to control your R1, tasks and calendar." }
        guard let summary = model.summary else { return model.pairing?.displayName ?? "" }
        var parts: [String] = []
        if summary.r1.live, let title = summary.r1.liveTitle {
            parts.append("“\(Formatting.clip(title, 34))”")
        } else {
            parts.append("R1 seen \(Formatting.ago(summary.r1.lastSeenAt))")
        }
        if summary.r1.live || summary.t3.needsYou > 0, summary.t3.working > 0 {
            parts.append("\(summary.t3.working) working")
        }
        if let next = summary.nextEvent(), let start = next.startsAt, !summary.r1.live {
            parts.append("\(next.title) \(next.isNow() ? "now" : Formatting.until(start, end: next.endsAt))")
        }
        return parts.joined(separator: "  ·  ")
    }
}

/// "Samin's MacBook Pro" with a status dot.
struct ConnectionPill: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.isPaired {
            HStack(spacing: 6) {
                if model.reachable {
                    PulseDot(color: SamTheme.green, size: 6)
                } else {
                    Circle().fill(SamTheme.amber).frame(width: 6, height: 6)
                }
                Text(model.summary?.mac.name ?? model.pairing?.displayName ?? "Mac")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(SamTheme.ink2)
                    .lineLimit(1)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .glassEffect(.regular, in: .capsule)
        }
    }
}

struct OfflineBanner: View {
    let error: BridgeError

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.exclamationmark").foregroundStyle(SamTheme.amber)
            VStack(alignment: .leading, spacing: 1) {
                Text(error.shortDescription).font(.system(size: 14, weight: .semibold))
                Text("Showing what SamRabbit knew last.").font(.system(size: 12.5)).foregroundStyle(SamTheme.muted)
            }
            Spacer()
        }
        .glassCard(radius: 18, tint: SamTheme.amber, padding: 14)
    }
}

struct PairPromptCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Connect to your Mac", systemImage: "qrcode.viewfinder")
                .font(.system(size: 17, weight: .semibold))
            Text("On your Mac, open SamRabbit and choose **Pair iPhone…**, then scan its code or type it here.")
                .font(.system(size: 14.5))
                .foregroundStyle(SamTheme.ink2)
            HStack {
                Button {
                    model.tab = .settings
                } label: {
                    Label("Scan or enter code", systemImage: "qrcode")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            }
        }
        .glassCard(tint: SamTheme.orb)
    }
}

// MARK: - Talk

/// The big Talk button: a live voice conversation with SamRabbit (or back to the one that is running).
struct TalkButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let talking = model.talk.active
        Button {
            Haptics.tap()
            model.startTalk()
        } label: {
            HStack(spacing: 11) {
                Image(systemName: talking ? "waveform.circle.fill" : "waveform")
                    .font(.system(size: 19, weight: .semibold))
                    .symbolEffect(.variableColor.iterative, options: .repeating, isActive: talking)
                Text(talking ? "Back to the conversation" : "Talk to SamRabbit")
                    .font(.system(size: 17, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(SamTheme.orb.opacity(0.85)).interactive(), in: .capsule)
        .shadow(color: SamTheme.orb.opacity(0.35), radius: 18, y: 6)
        .accessibilityIdentifier("home-talk")
    }
}

// MARK: - Quick actions

struct QuickActionsGrid: View {
    @Environment(AppModel.self) private var model
    @State private var blocking = false

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)
        GlassEffectContainer(spacing: 12) {
            LazyVGrid(columns: columns, spacing: 12) {
                QuickActionTile(title: "Ask", symbol: "sparkles", tint: SamTheme.orb2) { model.sheet = .ask(prefill: "") }
                QuickActionTile(title: "Note", symbol: "square.and.pencil", tint: SamTheme.mint) { model.sheet = .note(prefill: "") }
                QuickActionTile(title: blocking ? "Blocking…" : "Block 30m", symbol: "calendar.badge.clock", tint: SamTheme.violet) {
                    guard !blocking else { return }
                    blocking = true
                    Task {
                        await model.block(minutes: 30)
                        blocking = false
                    }
                }
                QuickActionTile(title: "Screenshot", symbol: "camera.viewfinder", tint: SamTheme.cyan) {
                    model.pendingScreenshot = true
                    model.tab = .mac
                }
                QuickActionTile(title: "Generate UI", symbol: "wand.and.sparkles", tint: SamTheme.pink) {
                    model.sheet = .generate(prefill: "")
                }
                QuickActionTile(title: "Open on Mac", symbol: "macbook.and.iphone", tint: SamTheme.amber) {
                    model.sheet = .openOnMac(prefill: "")
                }
            }
        }
    }
}

struct QuickActionTile: View {
    let title: String
    let symbol: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            VStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(tint.opacity(0.16)))
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(SamTheme.ink2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .contentShape(.rect(cornerRadius: 22))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(SamTheme.navy.opacity(0.35)).interactive(), in: .rect(cornerRadius: 22))
        .accessibilityLabel(title)
    }
}

// MARK: - Sections

struct NeedsYouSection: View {
    @Environment(AppModel.self) private var model

    var threads: [TaskThread] {
        let full = model.threads.filter(\.status.needsYou)
        return full.isEmpty ? (model.summary?.t3.threads.filter(\.status.needsYou) ?? []) : full
    }

    var body: some View {
        let problem = model.tasksProblem
        if !threads.isEmpty || problem != nil {
            VStack(spacing: 12) {
                if !threads.isEmpty {
                    SectionHeader("Needs you", count: threads.count, symbol: "hand.raised.fill")
                }
                if let problem { TasksNotice(error: problem, showingLast: !threads.isEmpty) }
                ForEach(threads) { thread in
                    NeedsYouCard(thread: thread)
                }
            }
        }
    }
}

/// A waiting thread with Approve / Deny or the question's answers inline.
struct NeedsYouCard: View {
    @Environment(AppModel.self) private var model
    let thread: TaskThread
    @State private var answering = false
    @State private var answer = ""

    var busy: Bool { model.busyThreads.contains(thread.threadId) }

    var body: some View {
        let style = StatusStyle(thread.status)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: style.symbol)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(style.color)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(style.color.opacity(0.16)))
                Text([thread.projectName, Formatting.ago(thread.updatedAt)].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(SamTheme.muted)
                Spacer()
                StatusChip(thread.status)
            }
            Button {
                model.openThread(thread.threadId)
            } label: {
                Text(thread.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(SamTheme.ink)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            if let text = thread.pending?.text ?? thread.summary, !text.isEmpty {
                Text(text)
                    .font(.system(size: 14.5))
                    .foregroundStyle(SamTheme.ink2)
                    .lineLimit(4)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black.opacity(0.22)))
            }
            PendingActionBar(thread: thread, compact: true)
        }
        .glassCard(tint: style.color)
        .opacity(busy ? 0.6 : 1)
        .animation(.smooth, value: busy)
    }
}

struct WorkingSection: View {
    @Environment(AppModel.self) private var model

    var threads: [TaskThread] {
        let full = model.threads.filter { $0.status == .working }
        return full.isEmpty ? (model.summary?.t3.threads.filter { $0.status == .working } ?? []) : full
    }

    var body: some View {
        if !threads.isEmpty {
            VStack(spacing: 12) {
                SectionHeader("Working", count: threads.count, symbol: "circle.dotted.circle")
                VStack(spacing: 0) {
                    ForEach(Array(threads.enumerated()), id: \.element.id) { index, thread in
                        if index > 0 { Divider().overlay(SamTheme.line).padding(.leading, 40) }
                        NavigationLink(value: ThreadRoute(threadId: thread.threadId)) {
                            ThreadRow(thread: thread)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .glassCard(padding: 6)
            }
        }
    }
}

/// One thread in a list.
struct ThreadRow: View {
    let thread: TaskThread

    var body: some View {
        let style = StatusStyle(thread.status)
        HStack(alignment: .top, spacing: 12) {
            Group {
                if thread.status == .working {
                    ProgressView().controlSize(.small).tint(style.color)
                } else {
                    Image(systemName: style.symbol).font(.system(size: 13, weight: .bold)).foregroundStyle(style.color)
                }
            }
            .frame(width: 22, height: 22)
            .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(thread.title)
                        .font(.system(size: 15.5, weight: .semibold))
                        .foregroundStyle(SamTheme.ink)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(Formatting.ago(thread.updatedAt))
                        .font(.system(size: 12))
                        .foregroundStyle(SamTheme.faint)
                }
                if let summary = thread.summary {
                    Text(summary)
                        .font(.system(size: 13.5))
                        .foregroundStyle(SamTheme.muted)
                        .lineLimit(2)
                }
                if let project = thread.projectName {
                    Text(project.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.5)
                        .foregroundStyle(SamTheme.faint)
                        .padding(.top, 1)
                }
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(SamTheme.faint)
                .padding(.top, 5)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 11)
        .contentShape(.rect)
    }
}

struct UpNextSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let events = (model.summary?.calendar.next ?? []).filter { ($0.endsAt ?? .distantFuture) > .now }
        if model.summary?.calendar.available == true {
            VStack(spacing: 12) {
                SectionHeader("Up next", symbol: "calendar")
                if events.isEmpty {
                    Text("Nothing else on your calendar today.")
                        .font(.system(size: 14))
                        .foregroundStyle(SamTheme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassCard(radius: 18, padding: 14)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(events.prefix(3).enumerated()), id: \.element.id) { index, event in
                            if index > 0 { Divider().overlay(SamTheme.line).padding(.leading, 74) }
                            EventRow(event: event, highlight: index == 0)
                        }
                    }
                    .glassCard(padding: 6)
                }
            }
        }
    }
}

struct EventRow: View {
    let event: CalendarEvent
    var highlight = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(Formatting.time(event.startsAt, allDay: event.allDay))
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(highlight ? SamTheme.ink : SamTheme.ink2)
                Text(event.isNow() ? "now" : Formatting.until(event.startsAt, end: event.endsAt, short: true))
                    .font(.system(size: 11.5))
                    .foregroundStyle(highlight ? SamTheme.orbPale : SamTheme.faint)
            }
            .lineLimit(1)
            .frame(width: 66, alignment: .trailing)
            RoundedRectangle(cornerRadius: 2).fill(highlight ? SamTheme.accent : SamTheme.violet.opacity(0.7))
                .frame(width: 3, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).font(.system(size: 15.5, weight: .semibold)).foregroundStyle(SamTheme.ink).lineLimit(1)
                if let detail = event.location ?? event.meetingUrl?.host {
                    Text(detail).font(.system(size: 12.5)).foregroundStyle(SamTheme.muted).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let url = event.meetingUrl {
                Button("Join") { openURL(url) }
                    .font(.system(size: 13, weight: .semibold))
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
    }
}

struct LatestConversationSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let latest = model.summary?.latestConversation {
            let live = model.summary?.r1.liveConversationId == latest.conversationId && model.summary?.r1.live == true
            VStack(spacing: 12) {
                SectionHeader("Latest R1 conversation", symbol: "waveform")
                Button {
                    model.tab = .chats
                    model.chatsPath.append(ConversationRoute(conversationId: latest.conversationId, title: latest.title))
                } label: {
                    HStack(alignment: .top, spacing: 14) {
                        OrbView(mood: live ? .live : .idle, animated: live, halo: false)
                            .frame(width: 38, height: 38)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(latest.title ?? "Conversation")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(SamTheme.ink)
                                    .lineLimit(1)
                                if live { LiveBadge() }
                                Spacer(minLength: 6)
                                Text(Formatting.ago(latest.lastAt)).font(.system(size: 12)).foregroundStyle(SamTheme.faint)
                            }
                            if let preview = latest.preview {
                                Text(preview)
                                    .font(.system(size: 14))
                                    .foregroundStyle(SamTheme.ink2)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .glassCard(tint: live ? SamTheme.orb : nil)
            }
        }
    }
}

struct LiveBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            PulseDot(color: SamTheme.green, size: 5)
            Text("LIVE").font(.system(size: 10, weight: .bold)).tracking(0.6)
        }
        .foregroundStyle(SamTheme.green)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(SamTheme.green.opacity(0.14)))
    }
}

struct UpdatedFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { _ in
            Text(model.summaryDate.map { "Updated \(Formatting.ago($0))" } ?? "")
                .font(.system(size: 11.5))
                .foregroundStyle(SamTheme.faint)
        }
    }
}
