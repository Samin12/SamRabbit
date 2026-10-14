import SamRabbitKit
import SwiftUI

/// Home: the orb and its state, Talk (the live conversation), what needs you, what is running, what is
/// next, the latest R1 conversation and the quick actions.
struct HomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(spacing: 26) {
                OrbHeader()
                if !model.isPaired {
                    PairPromptCard()
                } else {
                    // The morning brief first, until noon (what needs you, the verb is the button).
                    MorningSection()
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
        .onChange(of: model.briefFocus, initial: true) { _, focus in
            // `samrabbit://brief[/<id>]` (the brief's widgets): the brief, or that item.
            guard let focus else { return }
            Task {
                try? await Task.sleep(for: .milliseconds(300))
                withAnimation(.smooth) { proxy.scrollTo(focus, anchor: .top) }
                model.briefFocus = nil
            }
        }
        }
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
            // Tap the orb to talk, like the big button under it. Smaller in the morning, so the brief under it
            // starts on the first screen.
            let morning = model.showsBriefing
            Button {
                model.startTalk()
            } label: {
                OrbView(mood: model.orbMood)
                    .frame(width: morning ? 92 : 136, height: morning ? 92 : 136)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!model.isPaired)
            .padding(.top, morning ? 14 : 26)
            .padding(.bottom, morning ? 22 : 36)
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
        // Every agent on the Mac (the inbox), not only T3's threads.
        let needs = model.needsYouCount
        let working = model.workingCount
        if needs > 0 { return needs == 1 ? "1 task needs you" : "\(needs) tasks need you" }
        if working > 0 { return working == 1 ? "Working on 1 task" : "Working on \(working) tasks" }
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
        // While the R1 is live the headline says so: what needs you (every agent's) still shows here.
        if summary.r1.live, model.needsYouCount > 0 {
            parts.append(model.needsYouCount == 1 ? "1 needs you" : "\(model.needsYouCount) need you")
        }
        if summary.r1.live || model.needsYouCount > 0, model.workingCount > 0 {
            parts.append("\(model.workingCount) working")
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

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)
        GlassEffectContainer(spacing: 12) {
            LazyVGrid(columns: columns, spacing: 12) {
                QuickActionTile(title: "Ask", symbol: "sparkles", tint: SamTheme.orb2) { model.sheet = .ask(prefill: "") }
                QuickActionTile(title: "Note", symbol: "square.and.pencil", tint: SamTheme.mint) { model.sheet = .note(prefill: "") }
                // A one-shot voice note: records at once, the Mac files it (Block lives on in Siri and the Up Next
                // widget).
                QuickActionTile(title: "Voice note", symbol: "waveform.badge.mic", tint: SamTheme.red) {
                    model.startVoiceNote(record: true)
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

/// What needs you across every agent on the Mac (T3 Code, Claude Code, Codex): the first few cards, the rest in
/// Tasks.
struct NeedsYouSection: View {
    @Environment(AppModel.self) private var model
    static let shown = 4

    /// The inbox's rows once a list loaded (not T3's last ones while it is down: those wait in Tasks, read-only),
    /// else what the summary knew (its inbox items, else T3's threads).
    var items: [InboxItem] {
        if model.threadsLoaded { return model.liveTasks.filter(\.needsYou) }
        if let inbox = model.summary?.inbox { return inbox.items.filter(\.needsYou) }
        return (model.summary?.t3.threads ?? []).filter(\.status.needsYou).map(InboxItem.init(thread:))
    }

    var body: some View {
        let problem = model.tasksProblem
        let items = items
        if !items.isEmpty || problem != nil {
            VStack(spacing: 12) {
                if !items.isEmpty {
                    SectionHeader("Needs you", count: max(items.count, model.needsYouCount), symbol: "hand.raised.fill")
                }
                if let problem {
                    TasksNotice(error: problem, showingLast: !items.isEmpty && !model.t3Stale && !model.inboxFallback,
                                fallback: model.inboxFallback)
                }
                ForEach(items.prefix(Self.shown)) { item in
                    InboxCard(item: item)
                }
                if items.count > Self.shown {
                    Button {
                        model.tab = .tasks
                    } label: {
                        Label("\(items.count - Self.shown) more in Tasks", systemImage: "checklist")
                            .font(.system(size: 14.5, weight: .semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .accessibilityIdentifier("home-more-needs")
                }
            }
        }
    }
}

/// What is working across every agent on the Mac.
struct WorkingSection: View {
    @Environment(AppModel.self) private var model

    var items: [InboxItem] {
        if model.threadsLoaded { return model.liveTasks.filter { $0.status == .working } }
        if let inbox = model.summary?.inbox { return inbox.items.filter { $0.status == .working } }
        return (model.summary?.t3.threads ?? []).filter { $0.status == .working }.map(InboxItem.init(thread:))
    }

    var body: some View {
        InboxSection(title: "Working", symbol: "circle.dotted.circle", items: items)
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
