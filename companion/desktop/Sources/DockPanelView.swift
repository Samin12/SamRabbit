import AppKit
import SwiftUI

// The expanded panel (grows upward from the pill, ≈440 pt wide, at most 60% of the screen, scrolls): Needs you,
// Working, Recent chats (SamRabbit) and a folded Earlier; a row opens in place with its last messages and the actions
// the item supports right now (`can`); the compose bar is pinned at the bottom.

struct DockPanel: View {
    @ObservedObject var store: DockStore
    @ObservedObject var ui: DockUIState
    let voice: DockVoiceSnapshot
    let commands: DockCommands
    @Environment(\.dockRender) private var render

    var body: some View {
        let p = ui.panelScale
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    header(p)
                    if !store.inbox.t3Connected && store.isOnline {
                        DockBanner(text: "T3 Code isn’t connected to the bridge" + (store.inbox.sources["t3"]?.reason.map { ": \($0)" } ?? "."),
                                   scale: p)
                            .padding(.horizontal, 12 * p)
                            .padding(.bottom, 6 * p)
                    }
                    if !store.isOnline {
                        DockStateCard(title: store.offlineText, detail: store.offlineDetail, dim: true, scale: p,
                                      retry: store.connection == .connecting ? nil : { store.retryNow() })
                    } else if store.items.isEmpty {
                        DockStateCard(title: "Nothing is waiting for you",
                                      detail: "Agents that need you show up here. Ask one below.", dim: false, scale: p, retry: nil)
                    } else {
                        list(p)
                    }
                }
                menuRoom(p)
            }
            .overlay {
                if ui.menu != nil && !render.isSnapshot {
                    Color.black.opacity(0.001).onTapGesture { ui.menu = nil }
                }
            }
            Rectangle().fill(DockPalette.hairline).frame(height: 1)
            DockCompose(store: store, ui: ui, voice: voice, commands: commands)
        }
        .frame(width: (DockMetrics.panelBaseWidth * p).rounded())
        .background(DockGlass(shape: RoundedRectangle(cornerRadius: 22 * p, style: .continuous), firmness: 1.3))
        .clipShape(RoundedRectangle(cornerRadius: 22 * p, style: .continuous))
    }

    private func header(_ p: CGFloat) -> some View {
        HStack(spacing: 8 * p) {
            Text("Agents")
                .font(.system(size: 14 * p, weight: .semibold))
                .foregroundStyle(DockPalette.ink)
            if store.isOnline {
                Text(countsLine)
                    .font(.system(size: 12 * p))
                    .foregroundStyle(DockPalette.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6 * p)
            DockRoundButton(symbol: "ellipsis", size: 26 * p, fill: Color.clear, help: "Dock options") { commands.showMenu() }
        }
        .padding(.leading, 16 * p)
        .padding(.trailing, 10 * p)
        .padding(.top, 10 * p)
        .padding(.bottom, 6 * p)
    }

    /// An open target menu opens upward from its chip, over the list. The panel (and its window, which is exactly the
    /// glass) must be at least that tall, or a short list (nothing waiting, offline) would cut the menu off at the top
    /// edge: the same menu, invisible, holds the room in a single layout pass.
    @ViewBuilder private func menuRoom(_ p: CGFloat) -> some View {
        if let which = ui.menu, let targets = store.targets {
            DockTargetMenu(which: which, targets: targets, choice: targets.resolve(store.choice), now: store.now, scale: p,
                           maxHeight: DockTargetMenu.maxHeight(panel: ui.maxPanelHeight, scale: p)) { _, _, _ in }
                .fixedSize()
                .hidden()
                .accessibilityHidden(true)
                .padding(.bottom, 6 * p)
        }
    }

    private var countsLine: String {
        let needs = store.needsYouCount
        let working = store.workingCount
        var parts: [String] = []
        if needs > 0 { parts.append(needs == 1 ? "1 needs you" : "\(needs) need you") }
        if working > 0 { parts.append("\(working) working") }
        return parts.isEmpty ? "All clear" : parts.joined(separator: " · ")
    }

    @ViewBuilder private func list(_ p: CGFloat) -> some View {
        let limit = max(120, ui.maxPanelHeight - 150 * p)
        if render.isSnapshot {
            // ImageRenderer can't draw a ScrollView's content: the same rows, capped and clipped.
            rows(p)
                .frame(maxHeight: limit, alignment: .top)
                .fixedSize(horizontal: false, vertical: true)
                .clipped()
                .mask(DockEdgeFade(scale: p))
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    rows(p)
                }
                .frame(maxHeight: limit)
                .fixedSize(horizontal: false, vertical: true)
                .mask(DockEdgeFade(scale: p))
                .onChange(of: ui.selected) { _, selected in
                    guard let selected else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(selected) }
                }
            }
        }
    }

    private func rows(_ p: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2 * p) {
            ForEach(store.sections) { section in
                sectionHeader(section, p)
                if section.kind != .earlier || ui.earlierOpen {
                    ForEach(section.items) { item in
                        DockRow(item: item, store: store, ui: ui, commands: commands)
                            .id(item.id)
                    }
                }
            }
        }
        .padding(.horizontal, 6 * p)
        .padding(.bottom, 8 * p)
    }

    @ViewBuilder private func sectionHeader(_ section: DockSection, _ p: CGFloat) -> some View {
        let label = HStack(spacing: 6 * p) {
            Text(section.title)
                .font(.system(size: 10.5 * p, weight: .semibold))
                .textCase(.uppercase)
                .kerning(0.7 * p)
            Text("\(section.items.count)")
                .font(.system(size: 10.5 * p, weight: .medium))
                .monospacedDigit()
                .opacity(0.75)
            if section.kind == .earlier {
                Image(systemName: ui.earlierOpen ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8.5 * p, weight: .bold))
            }
            Spacer()
        }
        .foregroundStyle(section.kind == .needsYou ? DockPalette.accentText : DockPalette.tertiary)
        .padding(.horizontal, 10 * p)
        .padding(.top, 10 * p)
        .padding(.bottom, 3 * p)
        if section.kind == .earlier {
            label.contentShape(Rectangle()).onTapGesture { ui.earlierOpen.toggle() }
        } else {
            label
        }
    }
}

/// The list fades out over its last few points (and a little at the top), so a row cut by the edge reads as "more
/// below" rather than as a clipping mistake.
struct DockEdgeFade: View {
    let scale: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [Color.black.opacity(0.2), .black], startPoint: .top, endPoint: .bottom).frame(height: 6 * scale)
            Color.black
            LinearGradient(colors: [.black, Color.black.opacity(0)], startPoint: .top, endPoint: .bottom).frame(height: 18 * scale)
        }
    }
}

// MARK: a row

struct DockRow: View {
    let item: DockItem
    @ObservedObject var store: DockStore
    @ObservedObject var ui: DockUIState
    let commands: DockCommands
    @State private var hover = false

    var body: some View {
        let p = ui.panelScale
        let expanded = ui.expandedRow == item.id
        let selected = ui.selected == item.id
        VStack(alignment: .leading, spacing: 9 * p) {
            summary(p, expanded: expanded)
                .contentShape(Rectangle())
                .onTapGesture { toggle(expanded) }
            if expanded {
                DockRowDetail(item: item, store: store, ui: ui, commands: commands)
                    .padding(.leading, 38 * p)
            }
        }
        .padding(.horizontal, 10 * p)
        .padding(.vertical, 9 * p)
        .background(
            RoundedRectangle(cornerRadius: 14 * p, style: .continuous)
                .fill(Color.white.opacity(expanded ? 0.065 : (selected || hover) ? 0.06 : 0))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14 * p, style: .continuous)
                .strokeBorder(selected ? Palette.pale.opacity(0.35) : (expanded ? Color.white.opacity(0.07) : .clear), lineWidth: 1)
        )
        .onHover { hover = $0 }
    }

    private func toggle(_ expanded: Bool) {
        ui.selected = item.id
        ui.expandedRow = expanded ? nil : item.id
        store.watched = ui.expandedRow
    }

    private func summary(_ p: CGFloat, expanded: Bool) -> some View {
        HStack(alignment: .top, spacing: 10 * p) {
            DockSourceGlyph(item: item, size: 28 * p)
                .padding(.top, 1 * p)
            VStack(alignment: .leading, spacing: 2.5 * p) {
                HStack(alignment: .firstTextBaseline, spacing: 6 * p) {
                    DockStatusMark(item: item, size: 7 * p)
                    Text(item.title)
                        .font(.system(size: 13 * p, weight: .semibold))
                        .foregroundStyle(DockPalette.ink)
                        .lineLimit(expanded ? 3 : 1)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: expanded)
                    Spacer(minLength: 6 * p)
                    Text(DockTime.short(item.updatedAt, now: store.now))
                        .font(.system(size: 11 * p))
                        .monospacedDigit()
                        .foregroundStyle(DockPalette.tertiary)
                        .fixedSize()
                }
                meta(p).lineLimit(1)
                if !item.summary.isEmpty && !(expanded && store.details[item.id] != nil) {
                    Text(DockText.oneLine(item.summary))
                        .font(.system(size: 12 * p))
                        .foregroundStyle(DockPalette.ink.opacity(item.needsYou ? 0.76 : 0.62))
                        .lineLimit(item.needsYou || expanded ? 2 : 1)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 1 * p)
                }
            }
        }
    }

    private func meta(_ p: CGFloat) -> Text {
        let font = Font.system(size: 11.5 * p)
        let lead = DockText.meta(item.project, item.isChat ? nil : item.agentLabel)
        let label = item.statusLabel.isEmpty ? fallbackLabel : item.statusLabel
        let status = Text(label).font(font.weight(item.needsYou ? .medium : .regular)).foregroundStyle(statusColor)
        guard !lead.isEmpty else { return status }
        return Text(lead + "  ·  ").font(font).foregroundStyle(DockPalette.tertiary) + status
    }

    private var fallbackLabel: String {
        switch item.status {
        case .needsApproval: return "Needs your approval"
        case .needsInput: return "Has a question"
        case .error: return "Failed"
        case .done: return "Finished"
        case .working: return "Working"
        case .idle: return "Idle"
        }
    }

    private var statusColor: Color {
        switch item.status {
        case .needsApproval, .needsInput: return DockPalette.accentText
        case .error: return DockPalette.error
        case .done: return item.unread ? DockPalette.ink.opacity(0.9) : DockPalette.secondary
        case .working: return DockPalette.secondary
        case .idle: return DockPalette.tertiary
        }
    }
}

/// T3 / Claude / Codex / SamRabbit as a small drawn tile (SF Symbols and letters, not logos). T3 tiles carry the
/// model family in a corner.
struct DockSourceGlyph: View {
    let item: DockItem
    let size: CGFloat

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(LinearGradient(colors: [Color.white.opacity(0.13), Color.white.opacity(0.06)], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
            mark.frame(width: size, height: size)
            if item.source == "t3", let family = item.agentLabel {
                Image(systemName: family == "Codex" ? "chevron.left.forwardslash.chevron.right" : "asterisk")
                    .font(.system(size: size * 0.24, weight: .heavy))
                    .foregroundStyle(DockPalette.ink)
                    .frame(width: size * 0.44, height: size * 0.44)
                    .background(Circle().fill(Color(red: 0.16, green: 0.18, blue: 0.23)))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
                    .offset(x: size * 0.16, y: size * 0.16)
            }
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder private var mark: some View {
        switch item.source {
        case "t3":
            Text("T3")
                .font(.system(size: size * 0.38, weight: .heavy, design: .rounded))
                .foregroundStyle(DockPalette.ink)
        case "claude":
            Image(systemName: "asterisk")
                .font(.system(size: size * 0.44, weight: .bold))
                .foregroundStyle(DockPalette.ink)
        case "codex":
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: size * 0.36, weight: .bold))
                .foregroundStyle(DockPalette.ink)
        case "samrabbit":
            DockOrbMark(size: size * 1.05)
        default:
            Image(systemName: "sparkle").font(.system(size: size * 0.42)).foregroundStyle(DockPalette.ink)
        }
    }
}

/// The dot before a title: blue for an approval or a question, red for a failure, white for an unseen finish; a
/// progress ring while working.
struct DockStatusMark: View {
    let item: DockItem
    let size: CGFloat

    var body: some View {
        Group {
            switch item.status {
            case .needsApproval, .needsInput:
                Circle().fill(Palette.orb).overlay(Circle().strokeBorder(Palette.pale.opacity(0.6), lineWidth: 1))
            case .error:
                Circle().fill(DockPalette.error)
            case .done:
                Circle().fill(item.unread ? DockPalette.ink : Color.clear)
            case .working:
                DockProgressRing(progress: item.progress, size: size + 2)
            case .idle:
                Color.clear
            }
        }
        .frame(width: size, height: size)
        .alignmentGuide(.firstTextBaseline) { d in d[.bottom] - size * 0.05 }
    }
}

/// A small ring: filled to the progress when there is one, else a spinning arc.
struct DockProgressRing: View {
    let progress: Double?
    let size: CGFloat
    @Environment(\.dockRender) private var render

    var body: some View {
        ZStack {
            Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: max(1.2, size * 0.18))
            if let progress {
                Circle().trim(from: 0, to: min(1, max(0.04, progress)))
                    .stroke(Palette.pale, style: StrokeStyle(lineWidth: max(1.2, size * 0.18), lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(max(0.6, size * 0.09))
            } else if render.isSnapshot {
                arc(0)
            } else {
                TimelineView(.periodic(from: .now, by: 1 / 12)) { context in
                    arc(context.date.timeIntervalSinceReferenceDate * 300)
                }
            }
        }
        .frame(width: size, height: size)
    }

    private func arc(_ degrees: Double) -> some View {
        Circle().trim(from: 0, to: 0.28)
            .stroke(Palette.pale, style: StrokeStyle(lineWidth: max(1.2, size * 0.18), lineCap: .round))
            .rotationEffect(.degrees(degrees))
            .padding(max(0.6, size * 0.09))
    }
}

// MARK: an expanded row

struct DockRowDetail: View {
    let item: DockItem
    @ObservedObject var store: DockStore
    @ObservedObject var ui: DockUIState
    let commands: DockCommands

    var body: some View {
        let p = ui.panelScale
        VStack(alignment: .leading, spacing: 10 * p) {
            messages(p)
            if item.supports("approve") {
                ForEach(item.pending.approvals, id: \.requestId) { approval in
                    DockApprovalCard(item: item, approval: approval, store: store, scale: p)
                }
            } else if item.status == .needsApproval && item.pending.approvals.isEmpty && store.notes[item.id] == nil {
                DockNoteLine(note: DockStore.Note(text: item.live ? "It’s waiting in the terminal — Open to answer there."
                                                  : "Answer it in the app it runs in — Open takes you there.",
                                                  isError: false, offersOpen: false), scale: p)
            }
            if item.supports("answer") {
                ForEach(item.pending.inputs, id: \.requestId) { request in
                    DockInputCard(item: item, request: request, store: store, ui: ui, scale: p)
                }
            }
            if let note = store.notes[item.id] {
                DockNoteLine(note: note, scale: p, open: note.offersOpen && item.supports("open") ? { store.open(item) } : nil,
                             dismiss: { store.dismissNote(item.id) })
            }
            if item.supports("reply") {
                DockReplyField(item: item, store: store, ui: ui, scale: p)
            }
            actions(p)
        }
    }

    @ViewBuilder private func messages(_ p: CGFloat) -> some View {
        if let detail = store.details[item.id], !detail.messages.isEmpty {
            VStack(alignment: .leading, spacing: 8 * p) {
                ForEach(Array(detail.messages.suffix(3).enumerated()), id: \.offset) { _, message in
                    VStack(alignment: .leading, spacing: 2 * p) {
                        Text(message.isUser ? "You" : (item.isChat ? "SamRabbit" : (item.agentLabel ?? "Agent")))
                            .font(.system(size: 10.5 * p, weight: .semibold))
                            .foregroundStyle(message.isUser ? DockPalette.accentText : DockPalette.tertiary)
                        Text(message.text)
                            .font(.system(size: 12 * p))
                            .foregroundStyle(DockPalette.ink.opacity(message.isUser ? 0.8 : 0.9))
                            .lineLimit(5)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .padding(.leading, message.isUser ? 8 * p : 0)
                    .overlay(alignment: .leading) {
                        if message.isUser { Rectangle().fill(Palette.orb.opacity(0.7)).frame(width: 2 * p) }
                    }
                }
            }
        } else if store.loadingDetail.contains(item.id) {
            HStack(spacing: 6 * p) {
                DockProgressRing(progress: nil, size: 11 * p)
                Text("Loading the conversation…").font(.system(size: 11.5 * p)).foregroundStyle(DockPalette.tertiary)
            }
        }
    }

    private func actions(_ p: CGFloat) -> some View {
        HStack(spacing: 6 * p) {
            if item.supports("open") {
                DockCapsuleButton(title: openTitle, symbol: "arrow.up.forward.app", style: .plain, scale: p) { store.open(item) }
            }
            if item.supports("stop") && item.status == .working {
                DockCapsuleButton(title: "Stop", symbol: "stop.fill", style: .plain, scale: p) { store.stop(item) }
            }
            if item.supports("seen") && item.unread {
                DockCapsuleButton(title: "Mark seen", symbol: "checkmark", style: .quiet, scale: p) { store.markSeen(item) }
            }
            Spacer(minLength: 0)
            if let busy = store.busy[item.id] {
                HStack(spacing: 5 * p) {
                    DockProgressRing(progress: nil, size: 11 * p)
                    Text(busyLabel(busy)).font(.system(size: 11 * p)).foregroundStyle(DockPalette.tertiary)
                }
            }
        }
    }

    private var openTitle: String {
        switch item.source {
        case "t3": return "Open in T3"
        case "samrabbit": return "Open chat"
        case "claude": return item.live ? "Open Terminal" : "Open"
        default: return "Open"
        }
    }

    private func busyLabel(_ kind: String) -> String {
        switch kind {
        case "approve", "answer": return "Sending…"
        case "reply": return "Replying…"
        case "stop": return "Stopping…"
        case "open": return "Opening…"
        default: return "…"
        }
    }
}

struct DockApprovalCard: View {
    let item: DockItem
    let approval: DockApproval
    @ObservedObject var store: DockStore
    let scale: CGFloat

    var body: some View {
        let p = scale
        let recommended = approval.recommended
        VStack(alignment: .leading, spacing: 8 * p) {
            Label(approval.kindLabel, systemImage: symbol)
                .font(.system(size: 11 * p, weight: .semibold))
                .foregroundStyle(DockPalette.accentText)
            if !approval.detail.isEmpty {
                Text(approval.detail)
                    .font(.system(size: 11.5 * p, design: .monospaced))
                    .foregroundStyle(DockPalette.ink.opacity(0.92))
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.horizontal, 9 * p)
                    .padding(.vertical, 7 * p)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 9 * p, style: .continuous).fill(Color.black.opacity(0.3)))
                    .overlay(RoundedRectangle(cornerRadius: 9 * p, style: .continuous).strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
            }
            DockFlow(spacing: 6 * p, lineSpacing: 6 * p) {
                ForEach(approval.options, id: \.decision) { option in
                    DockCapsuleButton(title: option.label, symbol: option == recommended ? "checkmark" : nil,
                                      style: option == recommended ? .accent : .plain, scale: p,
                                      disabled: store.busy[item.id] != nil) {
                        store.approve(item, requestId: approval.requestId, decision: option.decision)
                    }
                }
            }
            if recommended != nil {
                Text("E approves with “\(recommended?.label ?? "")”")
                    .font(.system(size: 10 * p))
                    .foregroundStyle(DockPalette.tertiary)
            }
        }
        .padding(10 * p)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12 * p, style: .continuous).fill(Color.white.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 12 * p, style: .continuous).strokeBorder(Palette.pale.opacity(0.16), lineWidth: 1))
    }

    private var symbol: String {
        switch approval.kind.lowercased() {
        case "command", "exec", "shell", "command_execution": return "terminal"
        case "file_change", "edit", "patch", "apply_patch", "file": return "doc.badge.gearshape"
        case "network": return "network"
        default: return "hand.raised"
        }
    }
}

struct DockInputCard: View {
    let item: DockItem
    let request: DockInputRequest
    @ObservedObject var store: DockStore
    @ObservedObject var ui: DockUIState
    let scale: CGFloat

    var body: some View {
        let p = scale
        let oneTap = DockAnswers.answersOnTap(request)
        VStack(alignment: .leading, spacing: 9 * p) {
            ForEach(request.questions, id: \.id) { question in
                VStack(alignment: .leading, spacing: 6 * p) {
                    if !question.header.isEmpty {
                        Text(question.header)
                            .font(.system(size: 10 * p, weight: .semibold))
                            .textCase(.uppercase)
                            .kerning(0.6 * p)
                            .foregroundStyle(DockPalette.accentText)
                    }
                    Text(question.question)
                        .font(.system(size: 12.5 * p, weight: .medium))
                        .foregroundStyle(DockPalette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if !question.options.isEmpty {
                        DockFlow(spacing: 6 * p, lineSpacing: 6 * p) {
                            ForEach(question.options, id: \.self) { option in
                                chip(option, question: question, oneTap: oneTap, p)
                            }
                        }
                    }
                    if question.allowCustom {
                        DockTextInput(text: customBinding(question), placeholder: question.options.isEmpty ? "Type your answer…" : "Or type something else…",
                                      focus: .custom(item.id, question.id), ui: ui, fontSize: 12.5 * p, maxLines: 4,
                                      onSubmit: { store.answer(item, request: request) })
                            .padding(.horizontal, 10 * p)
                            .padding(.vertical, 6 * p)
                            .background(RoundedRectangle(cornerRadius: 10 * p, style: .continuous).fill(Color.black.opacity(0.25)))
                            .overlay(RoundedRectangle(cornerRadius: 10 * p, style: .continuous)
                                .strokeBorder(ui.editing == .custom(item.id, question.id) ? Palette.pale.opacity(0.5) : Color.white.opacity(0.08), lineWidth: 1))
                    }
                }
            }
            if !oneTap {
                HStack {
                    Spacer()
                    DockCapsuleButton(title: "Send answer", symbol: "arrow.up", style: .accent, scale: p,
                                      disabled: DockAnswers.build(request, selected: store.selections[item.id] ?? [:],
                                                                  custom: store.customAnswers[item.id] ?? [:]) == nil
                                        || store.busy[item.id] != nil) {
                        store.answer(item, request: request)
                    }
                }
            }
        }
        .padding(10 * p)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12 * p, style: .continuous).fill(Color.white.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 12 * p, style: .continuous).strokeBorder(Palette.pale.opacity(0.16), lineWidth: 1))
    }

    private func chip(_ option: String, question: DockQuestion, oneTap: Bool, _ p: CGFloat) -> some View {
        let chosen = (store.selections[item.id]?[question.id] ?? []).contains(option)
        return Button {
            if oneTap {
                store.answer(item, request: request, option: option)
            } else {
                store.toggle(option: option, question: question, item: item)
            }
        } label: {
            HStack(spacing: 5 * p) {
                if chosen { Image(systemName: "checkmark").font(.system(size: 9.5 * p, weight: .bold)) }
                Text(option).font(.system(size: 12 * p, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(DockPalette.ink)
            .padding(.horizontal, 10 * p)
            .padding(.vertical, 5 * p)
            .background(Capsule().fill(chosen ? AnyShapeStyle(DockPalette.accentFill) : AnyShapeStyle(DockPalette.control)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(chosen ? 0.25 : 0.09), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func customBinding(_ question: DockQuestion) -> Binding<String> {
        Binding(get: { store.customAnswers[item.id]?[question.id] ?? "" },
                set: { value in
                    store.customAnswers[item.id, default: [:]][question.id] = value
                    if !question.multiSelect && !value.isEmpty { store.selections[item.id, default: [:]][question.id] = [] }
                })
    }
}

struct DockReplyField: View {
    let item: DockItem
    @ObservedObject var store: DockStore
    @ObservedObject var ui: DockUIState
    let scale: CGFloat

    var body: some View {
        let p = scale
        let text = store.replyDrafts[item.id] ?? ""
        let editing = ui.editing == .reply(item.id)
        HStack(alignment: .bottom, spacing: 8 * p) {
            DockTextInput(text: Binding(get: { store.replyDrafts[item.id] ?? "" }, set: { store.replyDrafts[item.id] = $0 }),
                          placeholder: "Reply to \(item.isChat ? "SamRabbit" : (item.agentLabel ?? "the agent"))…",
                          focus: .reply(item.id), ui: ui, fontSize: 12.5 * p, maxLines: 5,
                          onSubmit: { store.reply(item) })
                .padding(.vertical, 5 * p)
            DockRoundButton(symbol: "arrow.up", size: 24 * p, tint: .white,
                            fill: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? DockPalette.control : Palette.orb,
                            help: "Send (↩)") { store.reply(item) }
        }
        .padding(.leading, 11 * p)
        .padding(.trailing, 4 * p)
        .padding(.vertical, 3 * p)
        .background(RoundedRectangle(cornerRadius: 14 * p, style: .continuous).fill(Color.black.opacity(0.25)))
        .overlay(RoundedRectangle(cornerRadius: 14 * p, style: .continuous)
            .strokeBorder(editing ? Palette.pale.opacity(0.5) : Color.white.opacity(0.09), lineWidth: 1))
    }
}

struct DockNoteLine: View {
    let note: DockStore.Note
    let scale: CGFloat
    var open: (() -> Void)?
    var dismiss: (() -> Void)?

    var body: some View {
        let p = scale
        HStack(alignment: .firstTextBaseline, spacing: 6 * p) {
            Image(systemName: note.isError ? "exclamationmark.circle.fill" : "info.circle")
                .font(.system(size: 11 * p, weight: .semibold))
            Text(note.text)
                .font(.system(size: 11.5 * p, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4 * p)
            if let open {
                DockCapsuleButton(title: "Open", symbol: "arrow.up.forward.app", style: .plain, scale: p * 0.92, action: open)
            }
            if let dismiss {
                Button(action: dismiss) {
                    Image(systemName: "xmark").font(.system(size: 9 * p, weight: .bold)).foregroundStyle(DockPalette.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .foregroundStyle(note.isError ? DockPalette.error : DockPalette.secondary)
    }
}

struct DockBanner: View {
    let text: String
    let scale: CGFloat

    var body: some View {
        HStack(spacing: 7 * scale) {
            Image(systemName: "bolt.horizontal.circle").font(.system(size: 11 * scale, weight: .semibold))
            Text(text).font(.system(size: 11.5 * scale)).lineLimit(2)
            Spacer(minLength: 0)
        }
        .foregroundStyle(DockPalette.secondary)
        .padding(.horizontal, 10 * scale)
        .padding(.vertical, 7 * scale)
        .background(RoundedRectangle(cornerRadius: 10 * scale, style: .continuous).fill(Color.white.opacity(0.05)))
    }
}

/// Offline ("Mac bridge isn’t running") or nothing waiting.
struct DockStateCard: View {
    let title: String
    let detail: String
    let dim: Bool
    let scale: CGFloat
    let retry: (() -> Void)?

    var body: some View {
        let p = scale
        VStack(spacing: 8 * p) {
            DockOrbMark(size: 58 * p, dim: dim)
            Text(title).font(.system(size: 14 * p, weight: .semibold)).foregroundStyle(DockPalette.ink)
            Text(detail).font(.system(size: 12 * p)).foregroundStyle(DockPalette.secondary).multilineTextAlignment(.center)
            if let retry {
                DockCapsuleButton(title: "Retry now", symbol: "arrow.clockwise", style: .plain, scale: p, action: retry)
                    .padding(.top, 4 * p)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24 * p)
        .padding(.top, 14 * p)
        .padding(.bottom, 22 * p)
    }
}

// MARK: compose

/// "Ask an agent…": a new T3 thread in the chosen project with the chosen agent and model (`/targets`), sent with
/// Enter (`POST /new`); it then shows under Working. The chips open small menus above them.
struct DockCompose: View {
    @ObservedObject var store: DockStore
    @ObservedObject var ui: DockUIState
    let voice: DockVoiceSnapshot
    let commands: DockCommands

    var body: some View {
        let p = ui.panelScale
        let choice = store.targets?.resolve(store.choice) ?? store.choice
        let empty = store.composeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let canSend = !empty && !store.composeBusy && store.isOnline && store.inbox.t3Connected
        VStack(alignment: .leading, spacing: 8 * p) {
            HStack(spacing: 6 * p) {
                chip(symbol: "folder", title: store.targets?.project(choice.projectId)?.title ?? "Project", menu: .project, p)
                    .overlay(alignment: .bottomLeading) { menu(.project, p) }
                    .zIndex(ui.menu == .project ? 1 : 0)
                chip(symbol: choice.agent == "codex" ? "chevron.left.forwardslash.chevron.right" : "asterisk",
                     title: agentTitle(choice), menu: .agent, p)
                    .overlay(alignment: .bottomLeading) { menu(.agent, p) }
                    .zIndex(ui.menu == .agent ? 1 : 0)
                Spacer(minLength: 0)
                if store.composeBusy {
                    DockProgressRing(progress: nil, size: 11 * p)
                    Text("Sending…").font(.system(size: 11 * p)).foregroundStyle(DockPalette.tertiary)
                } else {
                    Text("↩ send · ⇧↩ new line")
                        .font(.system(size: 10.5 * p))
                        .foregroundStyle(DockPalette.tertiary)
                        .lineLimit(1)
                        .layoutPriority(-1)
                }
            }
            .zIndex(2)
            HStack(alignment: .bottom, spacing: 6 * p) {
                DockTextInput(text: $store.composeText, placeholder: "Ask an agent…", focus: .compose, ui: ui,
                              fontSize: 13.5 * p, maxLines: 6, onSubmit: { store.sendCompose() })
                    .padding(.vertical, 7 * p)
                DockRoundButton(symbol: "mic.fill", size: 30 * p, badge: voice.wakeArmed,
                                help: "Talk to SamRabbit (\(voice.shortcut))") { commands.toggleVoice() }
                DockRoundButton(symbol: "arrow.up", size: 30 * p, tint: .white,
                                fill: canSend ? Palette.orb : DockPalette.control, help: "Send (↩)") { store.sendCompose() }
                    .opacity(canSend || store.composeBusy ? 1 : 0.55)
            }
            .padding(.leading, 13 * p)
            .padding(.trailing, 4 * p)
            .padding(.vertical, 3 * p)
            .background(RoundedRectangle(cornerRadius: 17 * p, style: .continuous).fill(Color.black.opacity(0.26)))
            .overlay(RoundedRectangle(cornerRadius: 17 * p, style: .continuous)
                .strokeBorder(ui.editing == .compose ? Palette.pale.opacity(0.55) : Color.white.opacity(0.1), lineWidth: 1))
            if let note = store.composeNote {
                DockNoteLine(note: note, scale: p)
            } else if store.isOnline && !store.inbox.t3Connected {
                DockNoteLine(note: DockStore.Note(text: "New prompts go to T3 Code, which isn’t connected right now.", isError: false), scale: p)
            }
        }
        .padding(.horizontal, 12 * p)
        .padding(.top, 10 * p)
        .padding(.bottom, 12 * p)
    }

    /// The chips' height, worked out from the font (the menus sit just above them, in a single layout pass).
    static func chipHeight(_ p: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 11.5 * p, weight: .medium)
        return ceil(font.ascender - font.descender + font.leading) + 9 * p
    }

    private func agentTitle(_ choice: DockTargets.Choice) -> String {
        guard let targets = store.targets, let agent = targets.agent(choice.agent) else { return "Agent" }
        let model = targets.model(choice.model, agent: choice.agent)?.label
        return model.map { "\(agent.label) · \($0)" } ?? agent.label
    }

    private func chip(symbol: String, title: String, menu: DockUIState.Menu, _ p: CGFloat) -> some View {
        let open = ui.menu == menu
        return Button {
            ui.menu = open ? nil : menu
        } label: {
            HStack(spacing: 5 * p) {
                Image(systemName: symbol).font(.system(size: 9.5 * p, weight: .bold))
                Text(title).font(.system(size: 11.5 * p, weight: .medium)).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 7.5 * p, weight: .bold)).opacity(0.7)
            }
            .foregroundStyle(DockPalette.ink.opacity(0.9))
            .padding(.horizontal, 9 * p)
            .padding(.vertical, 4.5 * p)
            .background(Capsule().fill(open ? DockPalette.controlHover : DockPalette.control))
            .overlay(Capsule().strokeBorder(open ? Palette.pale.opacity(0.45) : Color.white.opacity(0.09), lineWidth: 1))
            .contentShape(Capsule())
            .fixedSize()
        }
        .buttonStyle(.plain)
        .disabled(store.targets == nil)
    }

    @ViewBuilder private func menu(_ which: DockUIState.Menu, _ p: CGFloat) -> some View {
        if ui.menu == which, let targets = store.targets {
            DockTargetMenu(which: which, targets: targets, choice: targets.resolve(store.choice), now: store.now, scale: p,
                           maxHeight: DockTargetMenu.maxHeight(panel: ui.maxPanelHeight, scale: p)) { project, agent, model in
                if let project { store.pick(project: project) }
                if let agent, let model { store.pick(agent: agent, model: model) }
                ui.menu = nil
            }
            .fixedSize()
            .offset(y: -(Self.chipHeight(p) + 8 * p))
        }
    }
}

/// The chips' menus: projects (most recently active first), or agents with their models. At most `maxHeight` tall
/// (the room the panel can have above the compose bar); a longer list scrolls, starting at the current choice.
struct DockTargetMenu: View {
    let which: DockUIState.Menu
    let targets: DockTargets
    let choice: DockTargets.Choice
    let now: Date
    let scale: CGFloat
    let maxHeight: CGFloat
    let pick: (String?, String?, String?) -> Void
    @Environment(\.dockRender) private var render

    /// The panel is at most `panel` tall (60% of the screen, less near the top); the compose bar under the menu takes
    /// about 130 pt of it (the list's own cap leaves the same room).
    static func maxHeight(panel: CGFloat, scale p: CGFloat) -> CGFloat {
        max(120 * p, panel - 130 * p)
    }

    var body: some View {
        let p = scale
        Group {
            if render.isSnapshot {
                // ImageRenderer can't draw a ScrollView's content: the same rows, capped and clipped.
                rows(p)
                    .frame(maxHeight: maxHeight, alignment: .top)
                    .fixedSize(horizontal: false, vertical: true)
                    .clipped()
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: true) {
                        rows(p)
                    }
                    .frame(maxHeight: maxHeight)
                    .fixedSize(horizontal: false, vertical: true)
                    .onAppear { proxy.scrollTo(selectedRow, anchor: .center) }
                }
            }
        }
        .frame(width: 236 * p, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 13 * p, style: .continuous).fill(Color(red: 0.1, green: 0.11, blue: 0.14).opacity(0.98)))
        .overlay(RoundedRectangle(cornerRadius: 13 * p, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.4), radius: 14 * p, y: 6 * p)
    }

    private func rows(_ p: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 1 * p) {
            switch which {
            case .project:
                heading("Project", p)
                ForEach(projects) { project in
                    row(title: project.title, detail: DockTime.short(project.lastActiveAt.flatMap(DockDate.parse), now: now),
                        selected: project.id == choice.projectId, p) { pick(project.id, nil, nil) }
                        .id(project.id)
                }
            case .agent:
                ForEach(targets.agents) { agent in
                    heading(agent.label, p)
                    ForEach(agent.models) { model in
                        row(title: model.label, detail: nil, selected: agent.id == choice.agent && model.id == choice.model, p) {
                            pick(nil, agent.id, model.id)
                        }
                        .id("\(agent.id)/\(model.id)")
                    }
                }
            }
        }
        .padding(5 * p)
    }

    private var selectedRow: String {
        switch which {
        case .project: return choice.projectId ?? ""
        case .agent: return "\(choice.agent ?? "")/\(choice.model ?? "")"
        }
    }

    private var projects: [DockTargets.Project] {
        targets.projects.sorted { ($0.lastActiveAt.flatMap(DockDate.parse) ?? .distantPast) > ($1.lastActiveAt.flatMap(DockDate.parse) ?? .distantPast) }
    }

    private func heading(_ text: String, _ p: CGFloat) -> some View {
        Text(text)
            .font(.system(size: 10 * p, weight: .semibold))
            .textCase(.uppercase)
            .kerning(0.6 * p)
            .foregroundStyle(DockPalette.tertiary)
            .padding(.horizontal, 9 * p)
            .padding(.top, 6 * p)
            .padding(.bottom, 2 * p)
    }

    private func row(title: String, detail: String?, selected: Bool, _ p: CGFloat, action: @escaping () -> Void) -> some View {
        DockMenuRow(title: title, detail: detail, selected: selected, scale: p, action: action)
    }
}

struct DockMenuRow: View {
    let title: String
    let detail: String?
    let selected: Bool
    let scale: CGFloat
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        let p = scale
        Button(action: action) {
            HStack(spacing: 7 * p) {
                Image(systemName: "checkmark")
                    .font(.system(size: 9.5 * p, weight: .bold))
                    .opacity(selected ? 1 : 0)
                    .frame(width: 11 * p)
                Text(title).font(.system(size: 12.5 * p, weight: selected ? .semibold : .regular)).lineLimit(1)
                Spacer(minLength: 10 * p)
                if let detail, !detail.isEmpty {
                    Text(detail).font(.system(size: 11 * p)).foregroundStyle(DockPalette.tertiary)
                }
            }
            .foregroundStyle(DockPalette.ink)
            .padding(.horizontal, 8 * p)
            .padding(.vertical, 5.5 * p)
            .background(RoundedRectangle(cornerRadius: 8 * p, style: .continuous).fill(hover ? Palette.orb.opacity(0.55) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// The panel window's content. It sizes itself (width fixed, height up to the cap); the window follows.
struct DockPanelRoot: View {
    @ObservedObject var store: DockStore
    @ObservedObject var ui: DockUIState
    @ObservedObject var voice: DockVoiceFeed
    let commands: DockCommands
    let render: DockRender
    var onSize: (CGSize) -> Void

    var body: some View {
        DockPanel(store: store, ui: ui, voice: voice.snapshot, commands: commands)
            .fixedSize()
            .dockReportSize()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .onPreferenceChange(DockSizeKey.self) { size in onSize(size) }
            .environment(\.dockRender, render)
            .environment(\.colorScheme, .dark)
    }
}
