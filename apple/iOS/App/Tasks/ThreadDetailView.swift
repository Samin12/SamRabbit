import SamRabbitKit
import SwiftUI

/// One T3 Code thread: its messages (Markdown), what it waits for, a composer and Stop. Opening a finished or failed
/// one is seeing it: it is marked seen through the inbox (here and on the Mac's dock), and Mark seen stays at hand
/// should that fail; Dismiss hides it (here and on the Mac) until it changes. While T3 Code isn't answering it shows
/// its last state, read-only.
struct ThreadDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var close
    let threadId: String
    @State private var detail: ThreadDetail?
    @State private var error: BridgeError?
    @State private var draft = ""
    @State private var sending = false
    @FocusState private var composerFocused: Bool

    var thread: TaskThread? { detail?.thread ?? model.threads.first { $0.threadId == threadId } }

    /// The thread's inbox row (unread, `seen`), when the bridge has the inbox.
    var listed: InboxItem? { model.tasks.first { $0.id == "t3:\(threadId)" } }

    /// T3 Code isn't answering: what shows is the last state, and nothing can be sent.
    var stale: Bool { model.t3Stale && listed != nil }

    /// What says the screen should read the thread again: its own state in the list moved on.
    var listedMark: String? { model.threads.first { $0.threadId == threadId }.map { InboxItem(thread: $0).changeMark } }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if let thread { ThreadHeader(thread: thread) }
                    if let detail {
                        ForEach(detail.messages) { message in
                            MessageBubble(message: message).id(message.id)
                        }
                        if detail.thread.status == .working {
                            HStack(spacing: 10) {
                                ProgressView().controlSize(.small).tint(SamTheme.cyan)
                                Text(detail.thread.summary ?? "Working…")
                                    .font(.system(size: 13.5)).foregroundStyle(SamTheme.muted)
                            }
                            .padding(.leading, 6)
                            .id("working")
                        }
                    } else if let error {
                        // While T3 Code is down the header and the note below say it all.
                        if !stale {
                            ContentUnavailableView(error.shortDescription, systemImage: "wifi.exclamationmark",
                                                   description: Text(error.errorDescription ?? ""))
                        }
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
                    if stale, let problem = model.tasksError {
                        TasksNotice(error: problem, lastNote: "This is how the task last looked.")
                    } else if let thread, let pending = detail?.pending ?? thread.pending, thread.status.needsYou {
                        VStack(alignment: .leading, spacing: 10) {
                            Label(pending.kind == .approval ? "Waiting for your approval" : "Question for you",
                                  systemImage: pending.kind == .approval ? "hand.raised.fill" : "questionmark.bubble.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(StatusStyle(thread.status).color)
                            Text(pending.text).font(.system(size: 15)).foregroundStyle(SamTheme.ink)
                            PendingActionBar(thread: thread, pending: pending)
                        }
                        .glassCard(radius: 22, tint: StatusStyle(thread.status).color, padding: 14)
                    }
                    if !stale {
                        Composer(text: $draft, placeholder: "Reply to this task", sending: sending,
                                 focused: $composerFocused) {
                            send()
                        }
                    }
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
            if thread?.status == .working, !stale {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        Task {
                            await model.stop(threadId)
                            await load()
                        }
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .tint(SamTheme.red)
                }
            }
            if let listed, listed.supports(.seen), !stale {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await model.markSeen(listed) }
                    } label: {
                        Label("Mark seen", systemImage: "checkmark")
                    }
                    .disabled(model.busyItems.contains(listed.id))
                    .accessibilityIdentifier("thread-detail-seen")
                }
            }
            if let listed, listed.canDismiss, !stale {
                ToolbarItem(placement: .topBarTrailing) {
                    // Hidden here and on the Mac until it changes (T3 itself is never told); back to the list.
                    Button {
                        model.dismiss(listed)
                        close()
                    } label: {
                        Label("Dismiss", systemImage: "eye.slash")
                    }
                    .accessibilityIdentifier("thread-detail-dismiss")
                }
            }
        }
        .task(id: threadId) {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(detail?.thread.status == .working ? 3 : 8))
            }
        }
        // Seen once per state while it is on screen.
        .task(id: listed?.seenMark) { await model.sawItem("t3:\(threadId)") }
        // Read again when this thread moved on, not on every change of any thread.
        .onChange(of: listedMark) { _, _ in Task { await load() } }
    }

    func load() async {
        guard let client = model.client else { return }
        do {
            let fresh = try await client.thread(threadId)
            if fresh != detail { withAnimation(.smooth) { detail = fresh } }
            error = nil
        } catch let failure as BridgeError {
            if failure != .cancelled, detail == nil { error = failure }
        } catch {}
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        sending = true
        Task {
            if await model.reply(to: threadId, text) {
                draft = ""
                composerFocused = false
            }
            sending = false
            await load()
        }
    }
}

struct ThreadHeader: View {
    let thread: TaskThread

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                StatusChip(thread.status)
                if let project = thread.projectName {
                    Label(project, systemImage: "folder.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(SamTheme.muted)
                }
                Spacer()
                Text(Formatting.ago(thread.updatedAt)).font(.system(size: 12)).foregroundStyle(SamTheme.faint)
            }
            Text(thread.title)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(SamTheme.ink)
            if let summary = thread.summary {
                Text(summary).font(.system(size: 14.5)).foregroundStyle(SamTheme.ink2)
            }
        }
        .padding(.bottom, 6)
    }
}

/// A thread message: the user's on the right in blue glass, the assistant's on the left.
struct MessageBubble: View {
    let message: ThreadMessage

    var body: some View {
        let mine = message.role == .user
        HStack {
            if mine { Spacer(minLength: 44) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
                if message.role == .tool {
                    Label(message.text, systemImage: "wrench.and.screwdriver")
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(SamTheme.muted)
                        .lineLimit(3)
                } else {
                    MarkdownText(message.text)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background {
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .fill(mine ? AnyShapeStyle(LinearGradient(colors: [SamTheme.orb2.opacity(0.85), SamTheme.orb.opacity(0.85)],
                                                                          startPoint: .top, endPoint: .bottom))
                                      : AnyShapeStyle(SamTheme.glass2))
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .strokeBorder(mine ? Color.white.opacity(0.18) : SamTheme.line2, lineWidth: 0.6)
                        }
                }
                if let at = message.at {
                    Text(at.formatted(.dateTime.hour().minute()))
                        .font(.system(size: 10.5))
                        .foregroundStyle(SamTheme.faint)
                        .padding(.horizontal, 6)
                }
            }
            if !mine { Spacer(minLength: 28) }
        }
    }
}

/// Markdown with fenced code blocks (inline styles, links and line breaks are kept).
struct MarkdownText: View {
    let blocks: [(code: Bool, text: String)]

    init(_ text: String) {
        var result: [(Bool, String)] = []
        let parts = text.components(separatedBy: "```")
        for (index, part) in parts.enumerated() {
            if index % 2 == 1 {
                var code = part
                if let newline = code.firstIndex(of: "\n"), !code[..<newline].contains(" ") {
                    code = String(code[code.index(after: newline)...]) // drop the language tag
                }
                result.append((true, code.trimmingCharacters(in: .newlines)))
            } else if !part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append((false, part.trimmingCharacters(in: .newlines)))
            }
        }
        blocks = result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                if block.code {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(block.text)
                            .font(.system(size: 12.5, design: .monospaced))
                            .foregroundStyle(SamTheme.ink2)
                            .padding(10)
                    }
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.35)))
                } else {
                    Text(Self.attributed(block.text))
                        .font(.system(size: 15))
                        .foregroundStyle(SamTheme.ink)
                        .tint(SamTheme.orbPale)
                        .textSelection(.enabled)
                }
            }
        }
    }

    static func attributed(_ text: String) -> AttributedString {
        let bulleted = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let trimmed = line.drop { $0 == " " }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") { return "•  " + trimmed.dropFirst(2) }
            return String(line)
        }.joined(separator: "\n")
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: bulleted, options: options)) ?? AttributedString(text)
    }
}
