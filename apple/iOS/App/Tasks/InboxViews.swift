import SamRabbitKit
import SwiftUI
import UIKit

// The inbox's rows on the iPhone: every agent on the Mac (T3 Code threads, Claude Code and Codex sessions) in Tasks
// and on Home. T3 items act as they always have (Approve / Deny / answers inline, their own thread screen); a Claude
// Code or Codex session can be replied to when no terminal owns it (the Mac resumes it in a new Terminal window),
// marked seen, and otherwise says where it waits ("Waiting for you in the terminal"). Any row can be swiped left to
// dismiss it (long press: Dismiss too): it goes here and on the Mac until it changes, with "Dismissed · Undo".

/// A card for something that needs you: the source, what it waits on, and what can be done from here.
struct InboxCard: View {
    @Environment(AppModel.self) private var model
    let item: InboxItem

    var busy: Bool { model.busyItems.contains(item.id) || item.threadId.map { model.busyThreads.contains($0) } == true }

    var body: some View {
        let style = StatusStyle(item.status)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                SourceGlyph(item: item, size: 28)
                Text(InboxText.meta(item))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(SamTheme.muted)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if item.source == .note { NoteChip(item: item) } else { StatusChip(item.status) }
            }
            Button {
                model.openItem(item)
            } label: {
                Text(item.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(SamTheme.ink)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            if let text = InboxText.body(item), !text.isEmpty {
                Text(text)
                    .font(item.heldOnMac != nil && !item.pending.approvals.isEmpty
                          ? .system(size: 13, design: .monospaced) : .system(size: 14.5))
                    .foregroundStyle(SamTheme.ink2)
                    .lineLimit(4)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black.opacity(0.22)))
            }
            actions
        }
        .glassCard(tint: item.heldOnMac != nil ? SourceGlyph.tint(item.source) : style.color)
        .opacity(busy ? 0.6 : 1)
        .animation(.smooth, value: busy)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inbox-card-\(item.id)")
        .swipeToDismiss(item, radius: 26)
    }

    @ViewBuilder private var actions: some View {
        if item.source == .note {
            // A voice note the Mac saved: its suggestion, Keep as note, Dismiss.
            NoteActions(item: item)
        } else if let thread = item.taskThread, item.status == .needsApproval || item.status == .needsInput {
            // T3: Approve / Deny and the answers inline, exactly as before.
            PendingActionBar(thread: thread, compact: true)
        } else if let hold = item.heldOnMac {
            VStack(alignment: .leading, spacing: 10) {
                InboxHoldNote(item: item, hold: hold)
                if item.supports(.seen) { SeenButton(item: item) }
            }
        } else {
            HStack(spacing: 10) {
                if item.supports(.reply) {
                    Button {
                        model.openItem(item)
                    } label: {
                        Label(item.source == .t3 ? "Open" : "Reply", systemImage: item.source == .t3
                              ? "arrow.up.right" : "arrowshape.turn.up.left.fill")
                            .lineLimit(1).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .accessibilityIdentifier("inbox-reply-\(item.id)")
                }
                if item.supports(.seen) { SeenButton(item: item) }
            }
            .controlSize(.large)
            .disabled(busy)
        }
    }
}

/// "Mark seen": the item leaves Needs you (here and on the Mac's dock).
struct SeenButton: View {
    @Environment(AppModel.self) private var model
    let item: InboxItem

    var body: some View {
        Button {
            Task { await model.markSeen(item) }
        } label: {
            Label("Mark seen", systemImage: "checkmark").lineLimit(1).frame(maxWidth: .infinity)
        }
        .buttonStyle(.glass)
        .controlSize(.large)
        .disabled(model.busyItems.contains(item.id))
        .accessibilityIdentifier("inbox-seen-\(item.id)")
    }
}

/// Where a Claude Code or Codex item waits when it can't be answered from here.
struct InboxHoldNote: View {
    let item: InboxItem
    let hold: InboxHold

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: hold.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(SourceGlyph.tint(item.source))
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(SourceGlyph.tint(item.source).opacity(0.14)))
            VStack(alignment: .leading, spacing: 2) {
                Text(hold.headline(item))
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(SamTheme.ink)
                Text(hold.detail(item))
                    .font(.system(size: 12.5))
                    .foregroundStyle(SamTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("inbox-hold")
    }
}

/// One item in a list (Working, Recent): its source, title, last words and where it is.
struct InboxRow: View {
    let item: InboxItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SourceGlyph(item: item, size: 30)
                .overlay(alignment: .topTrailing) { InboxStatusMark(item: item).offset(x: 4, y: -4) }
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.title)
                        .font(.system(size: 15.5, weight: .semibold))
                        .foregroundStyle(SamTheme.ink)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(Formatting.ago(item.updatedAt))
                        .font(.system(size: 12))
                        .foregroundStyle(SamTheme.faint)
                }
                if !item.summary.isEmpty {
                    Text(item.summary)
                        .font(.system(size: 13.5))
                        .foregroundStyle(SamTheme.muted)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    if item.live {
                        PulseDot(color: SamTheme.green, size: 5)
                    }
                    Text(InboxText.footer(item).uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.5)
                        .foregroundStyle(item.live ? SamTheme.green.opacity(0.85) : SamTheme.faint)
                        .lineLimit(1)
                }
                .padding(.top, 1)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(SamTheme.faint)
                .padding(.top, 5)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 11)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("inbox-row-\(item.id)")
    }
}

/// The small mark on a row's glyph: a pulse while working, a check for a finish, red for a failure.
struct InboxStatusMark: View {
    let item: InboxItem

    var body: some View {
        let style = StatusStyle(item.status)
        Group {
            switch item.status {
            case .working:
                PulseDot(color: SamTheme.cyan, size: 7)
            case .done, .error, .needsApproval, .needsInput:
                Image(systemName: style.symbol)
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundStyle(item.status == .done ? SamTheme.night : .white)
                    .frame(width: 15, height: 15)
                    .background(Circle().fill(style.color))
            default:
                EmptyView()
            }
        }
        .overlay(Circle().strokeBorder(SamTheme.night.opacity(0.9), lineWidth: item.status == .working ? 0 : 1.5))
    }
}

/// Opens a row where it belongs: a T3 thread's screen, a session's, a chat in Chats.
struct InboxLink<Label: View>: View {
    let item: InboxItem
    @ViewBuilder var label: Label

    var body: some View {
        if let threadId = item.threadId {
            NavigationLink(value: ThreadRoute(threadId: threadId)) { label }.buttonStyle(.plain)
        } else if item.isChat {
            NavigationLink(value: ConversationRoute(conversationId: item.key, title: item.title)) { label }
                .buttonStyle(.plain)
        } else {
            NavigationLink(value: InboxRoute(itemId: item.id)) { label }.buttonStyle(.plain)
        }
    }
}

/// A titled glass list of rows (Working, Recent). `stale`: T3's last rows while T3 Code isn't answering, dimmed (they
/// open their thread's last state, read-only).
struct InboxSection: View {
    let title: String
    let symbol: String
    let items: [InboxItem]
    var stale = false

    var body: some View {
        if !items.isEmpty {
            VStack(spacing: 12) {
                SectionHeader(title, count: items.count, symbol: symbol)
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider().overlay(SamTheme.line).padding(.leading, 52) }
                        InboxLink(item: item) { InboxRow(item: item) }
                            .swipeToDismiss(item, enabled: !stale, radius: 14)
                    }
                }
                .opacity(stale ? 0.55 : 1)
                .saturation(stale ? 0.3 : 1)
                .glassCard(padding: 6)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(stale ? "tasks-stale" : "tasks-section-\(title)")
        }
    }
}

/// All · T3 · Claude · Codex, with how many of each.
struct SourceFilterBar: View {
    @Binding var selection: InboxSource?
    let items: [InboxItem]

    var body: some View {
        let present = [InboxSource.t3, .claude, .codex, .note].filter { source in items.contains { $0.source == source } }
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    chip(nil, "All", count: items.count)
                    ForEach(present, id: \.self) { source in
                        chip(source, source.shortLabel, count: items.filter { $0.source == source }.count)
                    }
                }
                .padding(.horizontal, 2)
            }
        }
        .scrollClipDisabled()
    }

    private func chip(_ source: InboxSource?, _ title: String, count: Int) -> some View {
        let selected = selection == source
        return Button {
            Haptics.tap()
            withAnimation(.smooth) { selection = source }
        } label: {
            HStack(spacing: 6) {
                if let source {
                    SourceGlyph(source: source, size: 18)
                }
                Text(title).font(.system(size: 13.5, weight: .semibold))
                Text("\(count)")
                    .font(.system(size: 11.5, weight: .bold, design: .rounded))
                    .foregroundStyle(selected ? SamTheme.ink : SamTheme.muted)
            }
            .foregroundStyle(selected ? SamTheme.ink : SamTheme.ink2)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(selected ? .regular.tint(SamTheme.orb.opacity(0.55)).interactive() : .regular.interactive(),
                     in: .capsule)
        .accessibilityIdentifier("tasks-filter-\(source?.rawValue ?? "all")")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The words the rows and cards use.
enum InboxText {
    /// "Website · 5 min ago" (the glyph names the source, and for a T3 thread the model family in its corner); a
    /// voice note: "Voice note · 5 min ago".
    static func meta(_ item: InboxItem) -> String {
        [item.source == .note ? item.source.label : item.project, Formatting.ago(item.updatedAt)].compactMap { $0 }
            .joined(separator: " · ")
    }

    /// What a card shows in its box: the request it waits on, else its last words (a voice note: what it suggests,
    /// its words being the title).
    static func body(_ item: InboxItem) -> String? {
        if item.source == .note { return NoteText.body(item) }
        if let detail = InboxPending.detail(item.pending) { return detail }
        if let pending = item.taskThread?.pending?.text, !pending.isEmpty { return pending }
        return item.summary.isEmpty ? nil : item.summary
    }

    /// "JACKRABBIT-SRC · LIVE IN TERMINAL" (a row's last line; the glyph already names the source).
    static func footer(_ item: InboxItem) -> String {
        var parts: [String] = []
        if let project = item.project { parts.append(project) }
        if item.live {
            parts.append("Live in Terminal")
        } else if item.heldOnMac == .ownedByApp || item.heldOnMac == .waitingInApp {
            parts.append("Codex app")
        } else if !item.statusLabel.isEmpty, item.status != .working {
            parts.append(item.statusLabel)
        } else if parts.isEmpty {
            parts.append(item.source.label)
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: dismissing

extension View {
    /// Swipe left to dismiss `item` (and Dismiss in its long-press menu and for VoiceOver), when it can be dismissed.
    func swipeToDismiss(_ item: InboxItem, enabled: Bool = true, radius: CGFloat = 20) -> some View {
        modifier(SwipeToDismiss(item: item, enabled: enabled && item.canDismiss, radius: radius))
    }
}

/// The row follows a leftward swipe over a "Dismiss" mark; let go past about a third of its width (or with a quick
/// flick) and it goes, else it springs back. A UIKit pan that only begins for a mostly sideways, leftward move: the
/// list's scroll keeps every vertical drag, and a swipe that starts on a button never taps it.
struct SwipeToDismiss: ViewModifier {
    @Environment(AppModel.self) private var model
    let item: InboxItem
    let enabled: Bool
    let radius: CGFloat
    @State private var offset: CGFloat = 0
    @State private var width: CGFloat = 1

    func body(content: Content) -> some View {
        if enabled {
            content
                .offset(x: offset)
                .background(alignment: .trailing) { mark }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = max(1, $0) }
                .gesture(LeftSwipe(changed: { offset = min(0, $0) }, ended: ended))
                .contextMenu {
                    Button("Dismiss", systemImage: "eye.slash") { model.dismiss(item) }
                }
                .accessibilityAction(named: "Dismiss") { model.dismiss(item) }
        } else {
            content
        }
    }

    /// Behind the row, showing more as it moves.
    private var mark: some View {
        let shown = min(1, -offset / max(1, width * 0.38))
        return HStack(spacing: 7) {
            Image(systemName: "eye.slash.fill").font(.system(size: 15, weight: .semibold))
            Text("Dismiss").font(.system(size: 15, weight: .semibold))
        }
        .foregroundStyle(SamTheme.ink)
        .padding(.trailing, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .background(RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(SamTheme.orb.opacity(0.18 + 0.32 * shown)))
        .opacity(offset < -2 ? Double(0.35 + 0.65 * shown) : 0)
        .scaleEffect(0.96 + 0.04 * shown, anchor: .trailing)
        .accessibilityHidden(true)
    }

    /// Far enough (a third of the row) or fast enough (a flick): it goes; else back in place.
    private func ended(_ translation: CGFloat, _ velocity: CGFloat, _ cancelled: Bool) {
        let far = !cancelled && (-translation > width * 0.38 || (velocity < -650 && -translation > 24))
        guard far else {
            withAnimation(.spring(duration: 0.3, bounce: 0.2)) { offset = 0 }
            return
        }
        withAnimation(.smooth(duration: 0.2)) { offset = -width * 1.15 }
        model.dismiss(item)
        // Should it come back (a refusal, the undo), it comes back in place.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            offset = 0
        }
    }
}

/// A pan that begins only when it moves left more than up or down (`changed`: the horizontal translation;
/// `ended`: translation, velocity, whether it was cancelled).
struct LeftSwipe: UIGestureRecognizerRepresentable {
    var changed: (CGFloat) -> Void
    var ended: (CGFloat, CGFloat, Bool) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let translation = recognizer.translation(in: recognizer.view).x
        switch recognizer.state {
        case .began, .changed:
            changed(translation)
        case .ended:
            ended(translation, recognizer.velocity(in: recognizer.view).x, false)
        case .cancelled, .failed:
            ended(translation, 0, true)
        default:
            break
        }
    }

    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return velocity.x < 0 && abs(velocity.x) > abs(velocity.y) * 1.4
        }

        // The list's own scroll may run beside it (it only scrolls up and down).
        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            other is UIPanGestureRecognizer && other.view is UIScrollView
        }
    }
}

/// "Dismissed · <title>" with Undo, at the bottom for a few seconds after a task was dismissed.
struct UndoSnackbar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            if let offer = model.undoOffer {
                HStack(spacing: 12) {
                    Image(systemName: "eye.slash.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(SamTheme.orbPale)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Dismissed").font(.system(size: 14.5, weight: .semibold)).foregroundStyle(SamTheme.ink)
                        Text(offer.item.title)
                            .font(.system(size: 12.5))
                            .foregroundStyle(SamTheme.muted)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Button {
                        model.undoDismiss()
                    } label: {
                        Text("Undo").font(.system(size: 15, weight: .bold))
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(SamTheme.orb)
                    .accessibilityIdentifier("undo-dismiss")
                }
                .padding(.leading, 16)
                .padding(.trailing, 10)
                .padding(.vertical, 10)
                .glassEffect(.regular.tint(SamTheme.night.opacity(0.8)), in: .rect(cornerRadius: 22))
                .padding(.horizontal, 14)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .id(offer.id)
                .task(id: offer.id) {
                    try? await Task.sleep(for: .seconds(5))
                    withAnimation(.smooth) { if model.undoOffer?.id == offer.id { model.undoOffer = nil } }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("undo-snackbar")
            }
        }
        .animation(.spring(duration: 0.35, bounce: 0.2), value: model.undoOffer)
    }
}
