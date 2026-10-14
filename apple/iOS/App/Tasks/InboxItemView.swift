import SamRabbitKit
import SwiftUI

/// One Claude Code or Codex session (T3 threads have `ThreadDetailView`): its last messages, where it is, and what
/// can be done from here. A session no terminal owns takes a reply: the Mac resumes it in a new Terminal window
/// with it (`claude --resume` / `codex resume`), so the CLI's own permission prompts stay on the Mac. One that waits
/// in its terminal, is open there, or belongs to the Codex app says so instead. Opening a finished or failed one is
/// seeing it: it is marked seen (here and on the Mac's dock).
struct InboxItemView: View {
    @Environment(AppModel.self) private var model
    let itemId: String
    @State private var detail: InboxItemDetail?
    @State private var error: BridgeError?
    @State private var draft = ""
    @State private var sending = false
    @FocusState private var composerFocused: Bool

    /// The list's copy (the long-poll keeps it fresh; a Mark seen shows there at once).
    var listed: InboxItem? { model.tasks.first { $0.id == itemId } }

    /// The freshest copy: the list's, unless the detail read something later.
    var item: InboxItem? {
        guard let detail else { return listed }
        if let listed, (listed.updatedAt ?? .distantPast) >= (detail.item.updatedAt ?? .distantPast) { return listed }
        return detail.item
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if let item { InboxItemHeader(item: item) }
                    if let detail {
                        ForEach(detail.messages) { message in
                            MessageBubble(message: message).id(message.id)
                        }
                        if item?.status == .working {
                            HStack(spacing: 10) {
                                ProgressView().controlSize(.small).tint(SamTheme.cyan)
                                Text(item?.summary.isEmpty == false ? item?.summary ?? "" : "Working…")
                                    .font(.system(size: 13.5)).foregroundStyle(SamTheme.muted)
                                    .lineLimit(3)
                            }
                            .padding(.leading, 6)
                            .id("working")
                        }
                    } else if let error {
                        ContentUnavailableView(error.shortDescription, systemImage: "wifi.exclamationmark",
                                               description: Text(error.errorDescription ?? ""))
                    } else {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                    }
                    Color.clear.frame(height: 4).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: detail?.messages.count) { _, _ in
                withAnimation(.smooth) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    if let item { bottom(item) }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
                .background(alignment: .bottom) {
                    LinearGradient(colors: [.clear, SamTheme.night.opacity(0.9)], startPoint: .top, endPoint: .bottom)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }
            }
        }
        .samScreen()
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            if let item, item.supports(.seen) {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            await model.markSeen(item)
                            await load()
                        }
                    } label: {
                        Label("Mark seen", systemImage: "checkmark")
                    }
                    .disabled(model.busyItems.contains(item.id))
                    .accessibilityIdentifier("inbox-detail-seen")
                }
            }
        }
        .task(id: itemId) {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(item?.status == .working ? 3 : 8))
            }
        }
        // Seen once per state while it is on screen.
        .task(id: listed?.seenMark) { await model.sawItem(itemId) }
        // Read again when this item moved on (not on every change of the inbox: a working agent elsewhere moves
        // the revision every few seconds).
        .onChange(of: listed?.changeMark) { _, _ in Task { await load() } }
    }

    @ViewBuilder private func bottom(_ item: InboxItem) -> some View {
        if item.source == .note {
            // A voice note the Mac saved: what it heard is above; its suggestion here.
            VStack(alignment: .leading, spacing: 10) {
                if let suggestion = item.suggestion {
                    Label(suggestion.label, systemImage: "lightbulb")
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(SamTheme.ink)
                }
                NoteActions(item: item)
            }
            .glassCard(radius: 22, tint: SourceGlyph.tint(.note), padding: 14)
        } else if let hold = item.heldOnMac {
            VStack(alignment: .leading, spacing: 12) {
                InboxHoldNote(item: item, hold: hold)
                PendingSummary(pending: item.pending)
            }
            .glassCard(radius: 22, tint: SourceGlyph.tint(item.source), padding: 14)
        } else if item.supports(.reply) {
            VStack(alignment: .leading, spacing: 6) {
                Label("Your reply continues it in a new Terminal window on your Mac.", systemImage: "apple.terminal")
                    .font(.system(size: 12))
                    .foregroundStyle(SamTheme.muted)
                    .padding(.horizontal, 8)
                Composer(text: $draft, placeholder: "Reply to \(item.source.label)", sending: sending,
                         focused: $composerFocused) {
                    send(item)
                }
            }
        }
    }

    func load() async {
        guard let client = model.client else { return }
        do {
            let fresh = try await client.inboxItem(itemId)
            if fresh != detail { withAnimation(.smooth) { detail = fresh } }
            error = nil
        } catch let failure as BridgeError {
            if failure != .cancelled, detail == nil { error = failure }
        } catch {}
    }

    func send(_ item: InboxItem) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        sending = true
        Task {
            if await model.reply(toItem: item, text) {
                draft = ""
                composerFocused = false
            }
            sending = false
            await load()
        }
    }
}

/// The session's source, project, state and title.
struct InboxItemHeader: View {
    let item: InboxItem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                SourceGlyph(item: item, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.source.label)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(SamTheme.ink2)
                    if let project = item.project {
                        Text(project)
                            .font(.system(size: 12))
                            .foregroundStyle(SamTheme.muted)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    StatusChip(item.status)
                    Text(Formatting.ago(item.updatedAt)).font(.system(size: 12)).foregroundStyle(SamTheme.faint)
                }
            }
            Text(item.title)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(SamTheme.ink)
                .accessibilityIdentifier("inbox-detail-title")
            HStack(spacing: 6) {
                if item.live { PulseDot(color: SamTheme.green, size: 6) }
                Text(statusLine)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(item.live ? SamTheme.green : SamTheme.muted)
            }
            if let cwd = item.cwd {
                Label(Self.shortPath(cwd), systemImage: "folder")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(SamTheme.faint)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.bottom, 6)
    }

    var statusLine: String {
        var parts = [item.statusLabel.isEmpty ? item.status.label : item.statusLabel]
        if item.live, item.heldOnMac != .waitingInTerminal, !item.statusLabel.lowercased().contains("terminal") {
            parts.append("open in Terminal")
        }
        return parts.joined(separator: " · ")
    }

    /// `/Users/sam/code/app` -> `~/code/app`.
    static func shortPath(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0] == "Users" else { return path }
        return "~/" + parts.dropFirst(2).joined(separator: "/")
    }
}

/// What a session waits on in its terminal: the command or change it asks to make, or its questions and choices
/// (to read here; they are answered there).
struct PendingSummary: View {
    let pending: InboxPending

    var body: some View {
        if let approval = pending.approvals.first {
            VStack(alignment: .leading, spacing: 6) {
                Text(approval.kindLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SamTheme.muted)
                if !approval.detail.isEmpty {
                    Text(approval.detail)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(SamTheme.ink2)
                        .lineLimit(6)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.32)))
                }
            }
        } else if let input = pending.inputs.first {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(input.questions) { question in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(question.question)
                            .font(.system(size: 14.5, weight: .medium))
                            .foregroundStyle(SamTheme.ink)
                        if !question.options.isEmpty {
                            FlowLayout(spacing: 6) {
                                ForEach(question.options, id: \.self) { option in
                                    Text(option)
                                        .font(.system(size: 12.5, weight: .medium))
                                        .foregroundStyle(SamTheme.ink2)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(Capsule().fill(Color.white.opacity(0.08)))
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
