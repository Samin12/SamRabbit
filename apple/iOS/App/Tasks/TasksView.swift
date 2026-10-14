import SamRabbitKit
import SwiftUI

/// Tasks: every agent on the Mac — T3 Code threads, Claude Code and Codex sessions (the inbox) — in three
/// sections: Needs you, Working, Recent; filtered by source when there are several.
struct TasksView: View {
    @Environment(AppModel.self) private var model
    @State private var filter: InboxSource?

    var body: some View {
        let rows = model.tasks.filter { filter == nil || $0.source == filter }
        let needs = rows.filter(\.needsYou)
        let working = rows.filter { !$0.needsYou && $0.status == .working }
        let recent = rows.filter { !$0.needsYou && $0.status != .working }
            .sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
        ScrollView {
            VStack(spacing: 24) {
                if !model.isPaired {
                    PairPromptCard()
                } else {
                    if Set(model.tasks.map(\.source)).count > 1 {
                        SourceFilterBar(selection: $filter, items: model.tasks)
                    }
                    if let problem = model.tasksProblem {
                        TasksNotice(error: problem, showingLast: !model.threads.isEmpty)
                    }
                    if model.tasks.isEmpty, model.tasksProblem == nil {
                        EmptyTasks(loading: !model.threadsLoaded && (model.refreshing || model.lastError == nil))
                    } else if rows.isEmpty, let filter {
                        Text("Nothing from \(filter.label) right now.")
                            .font(.system(size: 14))
                            .foregroundStyle(SamTheme.muted)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 30)
                    }
                }
                if !needs.isEmpty {
                    VStack(spacing: 12) {
                        SectionHeader("Needs you", count: needs.count, symbol: "hand.raised.fill")
                        ForEach(needs) { InboxCard(item: $0) }
                    }
                }
                InboxSection(title: "Working", symbol: "circle.dotted.circle", items: working)
                InboxSection(title: "Recent", symbol: "clock", items: recent)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 30)
            .animation(.smooth, value: filter)
        }
        .scrollIndicators(.hidden)
        .refreshable { await model.refresh(quiet: false) }
        .samScreen()
        .navigationTitle("Tasks")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    model.sheet = .newTask
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("New task")
                .disabled(!model.isPaired)
            }
        }
    }
}

struct EmptyTasks: View {
    let loading: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 14) {
            OrbView(mood: .idle).frame(width: 70, height: 70).padding(.vertical, 18)
            Text(loading ? "Loading tasks…" : "No tasks yet").font(.system(size: 17, weight: .semibold))
            Text("Your T3 Code threads and the Claude Code and Codex sessions on your Mac show up here. Ask SamRabbit for something to start one.")
                .font(.system(size: 14)).foregroundStyle(SamTheme.muted).multilineTextAlignment(.center)
            Button("Ask SamRabbit") { model.sheet = .ask(prefill: "") }
                .buttonStyle(.glassProminent)
        }
        .padding(.vertical, 30)
        .frame(maxWidth: .infinity)
    }
}

/// "T3 not connected": the Mac answers but T3 Code on it does not, so only the task areas are out
/// of date (the last list stays visible underneath).
struct TasksNotice: View {
    let error: BridgeError
    var showingLast = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: error.isTaskServiceDown ? "bolt.horizontal.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(SamTheme.amber)
            VStack(alignment: .leading, spacing: 3) {
                Text(error.isTaskServiceDown ? "T3 not connected" : "Tasks didn't update")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(SamTheme.ink)
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(SamTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .glassCard(radius: 18, tint: SamTheme.amber, padding: 14)
        .accessibilityElement(children: .combine)
    }

    var detail: String {
        let reason = error.isTaskServiceDown
            ? (error.errorDescription.flatMap { $0.isEmpty ? nil : $0 } ?? "T3 Code on your Mac isn't answering.")
            : (error.errorDescription ?? "")
        return showingLast ? reason + " Showing the last tasks." : reason
    }
}

/// Approve / Deny, or the answers to a question (Home cards and the thread detail). Every answer
/// names the request it was shown for; a card that doesn't know it (a summary thread) only opens
/// the thread, so nothing is ever approved blind.
struct PendingActionBar: View {
    @Environment(AppModel.self) private var model
    let thread: TaskThread
    var pending: PendingAction?
    var compact = false
    @State private var custom = ""
    @State private var showCustom = false
    @FocusState private var focused: Bool

    var body: some View {
        let busy = model.busyThreads.contains(thread.threadId)
        let action = pending ?? thread.pending
        let approval = action?.kind == .approval || (action?.kind != .question && thread.status == .needsApproval)
        VStack(alignment: .leading, spacing: 10) {
            if action?.canRespond != true, thread.status.needsYou || action != nil {
                Button {
                    model.openThread(thread.threadId)
                } label: {
                    Label(approval ? "Review and approve" : "Open to answer", systemImage: "arrow.up.right")
                        .lineLimit(1).frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
            } else if approval {
                HStack(spacing: 10) {
                    Button {
                        Task { await model.approve(thread, true, pending: action) }
                    } label: {
                        Label("Approve", systemImage: "checkmark").lineLimit(1).fixedSize().frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(SamTheme.green.mix(with: .black, by: 0.15))
                    Button(role: .destructive) {
                        Task { await model.approve(thread, false, pending: action) }
                    } label: {
                        Label("Deny", systemImage: "xmark").lineLimit(1).fixedSize().frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    if compact {
                        Button {
                            model.openThread(thread.threadId)
                        } label: {
                            Image(systemName: "arrowshape.turn.up.left.fill")
                        }
                        .buttonStyle(.glass)
                        .accessibilityLabel("Reply")
                    }
                }
                .controlSize(.large)
                .disabled(busy)
            } else if thread.status == .needsInput || action?.kind == .question {
                if let options = action?.options, !options.isEmpty {
                    FlowLayout(spacing: 8) {
                        ForEach(options) { option in
                            Button(option.label) {
                                Task { _ = await model.answer(thread, option.value, pending: action) }
                            }
                            .font(.system(size: 15, weight: .medium))
                            .buttonStyle(.glass)
                            .tint(SamTheme.violet)
                        }
                        Button {
                            withAnimation(.smooth) { showCustom.toggle() }
                            focused = showCustom
                        } label: {
                            Label("Other…", systemImage: "keyboard")
                        }
                        .font(.system(size: 15, weight: .medium))
                        .buttonStyle(.glass)
                    }
                    .disabled(busy)
                }
                if showCustom || (action?.options.isEmpty ?? true) {
                    HStack(spacing: 8) {
                        TextField("Your answer", text: $custom, axis: .vertical)
                            .focused($focused)
                            .lineLimit(1...4)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 18).fill(Color.black.opacity(0.25)))
                        DictationButton(text: $custom)
                        Button {
                            let text = custom
                            Task {
                                if await model.answer(thread, text, pending: action) { custom = "" }
                            }
                        } label: {
                            Image(systemName: "arrow.up").font(.system(size: 15, weight: .bold))
                        }
                        .buttonStyle(.glassProminent)
                        .buttonBorderShape(.circle)
                        .disabled(custom.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                    }
                }
            }
        }
    }
}

/// Wraps its children onto as many lines as needed.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += line + spacing
                x = 0
                line = 0
            }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += line + spacing
                x = bounds.minX
                line = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}
