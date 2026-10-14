import SamRabbitKit
import SwiftUI

/// Talk: the live conversation with SamRabbit, full screen, like ChatGPT Voice or talking to the R1. The fluid orb
/// listens (it follows your voice), thinks and speaks (it pulses with the reply); under it the line it heard and the
/// reply as it streams in, with the tasks it started and the cards it showed (tap a task for it in Tasks). Mute,
/// Stop (the reply), End, and a keyboard for a typed turn. Minimize (top left) and it goes on over the app; it
/// goes on with the screen locked too (the Live Activity has End).
struct TalkView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var fieldFocused: Bool
    @State private var draft = ""
    /// `-SamRabbitStillOrb YES` (UI tests): a still orb, so the app goes idle between frames and queries are quick.
    private let still = UserDefaults.standard.bool(forKey: "SamRabbitStillOrb")

    private var talk: TalkModel { model.talk }
    private var engine: ConversationEngine { talk.engine }
    private var machine: ConversationMachine { engine.machine }
    private var phase: TalkPhase { talk.phase }

    var body: some View {
        GeometryReader { geometry in
            let compact = talk.typing || talk.transcript
            let orbRoom = geometry.size.height * (compact ? 0.2 : 0.42)
            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, 18)
                    .padding(.top, 4)
                orb(size: min(geometry.size.width * 0.6, orbRoom * 0.74))
                    .frame(height: orbRoom)
                    .frame(maxWidth: .infinity)
                middle
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                bottom
                    .padding(.horizontal, 22)
                    .padding(.bottom, 10)
            }
            .animation(.smooth(duration: 0.35), value: compact)
        }
        .background { TalkBackdrop(phase: phase, level: engine.level) }
        .preferredColorScheme(.dark)
        .tint(SamTheme.accent)
        .statusBarHidden(false)
        .onChange(of: talk.typing) { _, typing in
            fieldFocused = typing
            if !typing { draft = "" }
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            CircleIconButton(symbol: "chevron.down", label: "Minimize") { talk.minimize() }
                .accessibilityIdentifier("talk-minimize")
            Spacer()
            statePill
            Spacer()
            CircleIconButton(symbol: talk.transcript ? "circle.hexagongrid.fill" : "text.bubble",
                             label: talk.transcript ? "Hide the transcript" : "Show the transcript") {
                withAnimation(.smooth(duration: 0.35)) { talk.transcript.toggle() }
            }
            .accessibilityIdentifier("talk-transcript")
            .opacity(machine.exchanges.isEmpty ? 0.45 : 1)
            .disabled(machine.exchanges.isEmpty)
        }
        .frame(height: 48)
    }

    private var statePill: some View {
        HStack(spacing: 8) {
            Group {
                switch phase {
                case .listening, .hearing, .starting:
                    PulseDot(color: phase == .starting ? SamTheme.orbPale : SamTheme.green, size: 7)
                case .thinking:
                    ProgressView().controlSize(.mini).tint(SamTheme.orbPale)
                case .ended where machine.problem != nil:
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(pillColor)
                default:
                    Image(systemName: phase.symbol)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(pillColor)
                }
            }
            .frame(width: 14, height: 14)
            Text(stateWord)
                .font(.system(size: 14.5, weight: .semibold))
                .foregroundStyle(SamTheme.ink)
                .contentTransition(.opacity)
                .accessibilityIdentifier("talk-state")
                .accessibilityValue(audioValue)
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
        .glassEffect(.regular.tint(pillColor.opacity(0.14)), in: .capsule)
        .animation(.smooth(duration: 0.25), value: phase)
    }

    private var stateWord: String {
        if !model.isPaired { return "Not paired" }
        if phase == .ended { return machine.exchanges.isEmpty && machine.problem == nil ? "Ready" : "Ended" }
        return phase.word
    }

    private var pillColor: Color {
        switch phase {
        case .listening, .hearing: SamTheme.green
        case .thinking, .starting: SamTheme.orbPale
        case .speaking: SamTheme.accent
        case .announcing, .muted: SamTheme.amber
        case .ended: machine.problem == nil ? SamTheme.muted : SamTheme.amber
        }
    }

    /// Debug builds: whether the microphone is live ("audio on"/"audio off"), for the UI tests (nothing in release).
    private var audioValue: String {
        #if DEBUG
        engine.audioRunning ? "audio on" : "audio off"
        #else
        ""
        #endif
    }

    // MARK: - Orb

    private func orb(size: CGFloat) -> some View {
        Button {
            talk.tapOrb()
        } label: {
            OrbView(mood: mood, animated: !still, frameRate: 30, level: engine.level)
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(OrbPressStyle())
        .accessibilityIdentifier("talk-orb")
        .accessibilityLabel(orbLabel)
        .disabled(!model.isPaired)
    }

    private var mood: OrbMood {
        if !model.isPaired { return .offline }
        switch phase {
        case .starting, .listening, .hearing, .speaking, .announcing: return .live
        case .thinking: return .working
        case .muted: return .idle
        case .ended:
            if machine.problem == "Can't reach your Mac" { return .offline }
            return machine.problem == nil ? .idle : .attention
        }
    }

    private var orbLabel: String {
        switch machine.phase {
        case .idle: "Talk to SamRabbit"
        case .hearing: "Send now"
        case .thinking, .speaking: "Interrupt"
        default: "Listening"
        }
    }

    // MARK: - Captions, cards, transcript

    /// The exchange being heard or answered, else the last one (while the next is awaited).
    private var shown: ConversationMachine.Exchange? { machine.live ?? machine.exchanges.last }

    @ViewBuilder
    private var middle: some View {
        if talk.transcript {
            TalkTranscript(exchanges: machine.exchanges, liveId: machine.live?.id) { open($0) }
        } else {
            ScrollView {
                VStack(spacing: 16) {
                    caption
                }
                .animation(.spring(duration: 0.45, bounce: 0.2), value: (shown?.actions.count ?? 0) + (shown?.cards.count ?? 0))
                .padding(.horizontal, 26)
                .padding(.top, 6)
                .padding(.bottom, 18)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            .defaultScrollAnchor(.top)
            .scrollBounceBehavior(.basedOnSize)
            .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.9),
                                         .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
        }
    }

    @ViewBuilder
    private var caption: some View {
        if !model.isPaired {
            hint("Pair with your Mac first", "On your Mac, open SamRabbit and choose Pair iPhone…, then scan its code in Settings.")
        } else if phase == .ended, let problem = machine.problem {
            hint(Self.phoneWords(problem), Self.problemDetail(problem), warning: true)
        } else if let exchange = shown, !(exchange.heard.isEmpty && exchange.say.isEmpty && exchange.cards.isEmpty && exchange.actions.isEmpty) {
            if !exchange.heard.isEmpty {
                Text("“\(exchange.heard)”")
                    .font(.system(size: 16.5, weight: .regular))
                    .italic()
                    .foregroundStyle(SamTheme.muted)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .accessibilityIdentifier("talk-heard")
            }
            if !exchange.say.isEmpty {
                Text(ConversationEngine.deviceWords(exchange.say))
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(exchange.kind == .notice ? SamTheme.amber : SamTheme.ink)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                    // No animation: the reply grows a word at a time and must wrap as it does.
                    .transaction { $0.animation = nil }
                    .accessibilityIdentifier("talk-say")
            }
            if !exchange.actions.isEmpty || !exchange.cards.isEmpty {
                VStack(spacing: 10) {
                    ForEach(exchange.actions, id: \.self) { action in
                        TalkActionCard(action: action) { open(action) }
                    }
                    ForEach(exchange.cards, id: \.self) { card in
                        TalkInfoCard(card: card)
                    }
                }
                .padding(.top, 6)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        } else if phase == .ended {
            hint("Tap the orb to talk", "Ask about your tasks, your calendar, your journal or your Mac.")
        } else if phase == .muted {
            hint("Your microphone is muted", "Unmute to talk, or type instead.")
        } else {
            hint("Go ahead, I'm listening", "Ask about your tasks, your calendar, your journal or your Mac.")
        }
    }

    private func hint(_ title: String, _ detail: String?, warning: Bool = false) -> some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(warning ? SamTheme.amber : SamTheme.ink)
                .accessibilityIdentifier(warning ? "talk-problem" : "talk-hint")
            if let detail {
                Text(detail)
                    .font(.system(size: 15))
                    .foregroundStyle(SamTheme.muted)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.top, 8)
    }

    /// A task it started: the thread in Tasks (Talk steps aside; the conversation goes on).
    private func open(_ action: AssistantAction) {
        guard let threadId = action.threadId else { return }
        talk.minimize()
        model.openThread(threadId)
    }

    // MARK: - Controls

    @ViewBuilder
    private var bottom: some View {
        if talk.typing {
            typeBar
        } else if talk.active {
            HStack(spacing: 0) {
                TalkRoundButton(symbol: "keyboard", title: "Type") {
                    talk.typing = true
                }
                .accessibilityIdentifier("talk-keyboard")
                TalkRoundButton(symbol: engine.micMuted ? "mic.slash.fill" : "mic.fill",
                            title: engine.micMuted ? "Unmute" : "Mute", selected: engine.micMuted) {
                    talk.toggleMute()
                }
                .accessibilityIdentifier("talk-mute")
                TalkRoundButton(symbol: "stop.fill", title: "Stop", enabled: talk.canStopSpeaking) {
                    talk.stopSpeaking()
                }
                .accessibilityIdentifier("talk-stop")
                TalkRoundButton(symbol: "xmark", title: "End", tint: SamTheme.red) {
                    talk.end()
                }
                .accessibilityIdentifier("talk-end")
            }
            .transition(.opacity)
        } else {
            HStack(spacing: 14) {
                Button {
                    talk.start()
                } label: {
                    Label("Talk", systemImage: "waveform")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 58)
                }
                .buttonStyle(.glassProminent)
                .tint(SamTheme.orb)
                .disabled(!model.isPaired)
                .accessibilityIdentifier("talk-start")
                CircleIconButton(symbol: "xmark", label: "Close", size: 58) { talk.end() }
                    .accessibilityIdentifier("talk-close")
            }
            .padding(.bottom, 14)
            .transition(.opacity)
        }
    }

    private var typeBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Type to SamRabbit", text: $draft, axis: .vertical)
                .font(.system(size: 17))
                .lineLimit(1...5)
                .focused($fieldFocused)
                .submitLabel(.send)
                .onSubmit(sendDraft)
                .padding(.horizontal, 18)
                .padding(.vertical, 13)
                .glassEffect(.regular.tint(SamTheme.navy.opacity(0.4)), in: .rect(cornerRadius: 24))
                .accessibilityIdentifier("talk-field")
            Button(action: sendDraft) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 18, weight: .bold))
                    .frame(width: 48, height: 48)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .tint(SamTheme.orb)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Send")
            .accessibilityIdentifier("talk-send")
            CircleIconButton(symbol: "xmark", label: "Close the keyboard", size: 48) { talk.typing = false }
                .accessibilityIdentifier("talk-type-close")
        }
        .padding(.bottom, 6)
    }

    private func sendDraft() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft = ""
        talk.send(text)
    }

    // MARK: - Words

    /// The conversation's words are the watch's; a few say "watch" where the iPhone means itself.
    static func phoneWords(_ problem: String) -> String { ConversationEngine.deviceWords(problem) }

    static func problemDetail(_ problem: String) -> String? {
        switch problem {
        case "Microphone is off": "Allow it in Settings > Privacy & Security > Microphone > SamRabbit."
        case "Can't reach your Mac": "Is your Mac awake and on the same network? Tap Talk to try again."
        case "Update SamRabbit on your Mac": "Run the SamRabbit installer on your Mac again."
        case "Assistant unavailable on the Mac": "Connect ChatGPT in SamRabbit on your Mac."
        case "Reconnect through your iPhone": "Your Mac no longer accepts this iPhone. Pair again in Settings."
        case "Paused. Tap to talk.": "A call or another app took the audio."
        default: nil
        }
    }
}

// MARK: - Pieces

/// The deep night behind Talk, with a glow under the orb that follows the conversation.
struct TalkBackdrop: View {
    var phase: TalkPhase
    var level: Double

    var body: some View {
        GeometryReader { geometry in
            let w = geometry.size.width
            let h = geometry.size.height
            let glow: Color = phase == .thinking ? SamTheme.violet : phase == .muted || phase == .ended ? SamTheme.navy : SamTheme.orb
            ZStack {
                LinearGradient(colors: [Color(hex: 0x0A0F1C), Color(hex: 0x070A12), Color(hex: 0x040508)],
                               startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [glow.opacity(0.34 + level * 0.18), glow.opacity(0.08), .clear],
                               center: .init(x: 0.5, y: 0.27), startRadius: 0, endRadius: max(w, h) * (0.55 + level * 0.08))
                RadialGradient(colors: [SamTheme.violet.opacity(0.10), .clear], center: .init(x: 0.95, y: 1.0),
                               startRadius: 0, endRadius: max(w, h) * 0.55)
                RadialGradient(colors: [SamTheme.orb.opacity(0.08), .clear], center: .init(x: 0.0, y: 0.85),
                               startRadius: 0, endRadius: max(w, h) * 0.45)
            }
            .animation(.smooth(duration: 0.6), value: phase)
        }
        .ignoresSafeArea()
    }
}

/// The orb shrinks a little under the finger.
private struct OrbPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(duration: 0.25, bounce: 0.3), value: configuration.isPressed)
    }
}

/// One of the four round buttons at the bottom of Talk, with its word under it.
struct TalkRoundButton: View {
    let symbol: String
    let title: String
    var selected = false
    var enabled = true
    var tint: Color?
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(selected ? SamTheme.night : tint == nil ? SamTheme.ink : .white)
                    .frame(width: 66, height: 66)
                    .background {
                        if selected { Circle().fill(SamTheme.ink) }
                    }
                    .glassEffect(glass, in: .circle)
                    .contentTransition(.symbolEffect(.replace))
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(SamTheme.ink2)
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.38)
        .accessibilityLabel(title)
    }

    private var glass: Glass {
        if let tint { return .regular.tint(tint.opacity(0.75)).interactive() }
        return selected ? .clear.interactive() : .regular.tint(SamTheme.navy.opacity(0.35)).interactive()
    }
}

/// A round glass icon button (minimize, transcript, close).
struct CircleIconButton: View {
    let symbol: String
    let label: String
    var size: CGFloat = 40
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(SamTheme.ink)
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(SamTheme.navy.opacity(0.3)).interactive(), in: .circle)
        .accessibilityLabel(label)
    }
}

/// Something the assistant did (`{"type":"action"}`): a T3 task it started or answered opens in Tasks.
struct TalkActionCard: View {
    let action: AssistantAction
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 13) {
                Image(systemName: Self.symbol(action.kind))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(SamTheme.mint)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(SamTheme.mint.opacity(0.15)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(action.title)
                        .font(.system(size: 15.5, weight: .semibold))
                        .foregroundStyle(SamTheme.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(Self.caption(action))
                        .font(.system(size: 12.5))
                        .foregroundStyle(SamTheme.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if action.threadId != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(SamTheme.faint)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(action.threadId == nil)
        .glassCard(radius: 20, tint: SamTheme.mint, padding: 13)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("talk-action")
    }

    static func symbol(_ kind: String) -> String {
        if kind.hasPrefix("t3") { return "hammer.fill" }
        if kind.hasPrefix("calendar") { return "calendar" }
        if kind.hasPrefix("journal") { return "book.pages.fill" }
        if kind.hasPrefix("ui") || kind.hasPrefix("genui") { return "rectangle.on.rectangle" }
        if kind.hasPrefix("mac") { return "laptopcomputer" }
        return "checkmark.circle.fill"
    }

    static func caption(_ action: AssistantAction) -> String {
        let kind = action.kind
        if kind.hasPrefix("t3") {
            let what = kind.hasSuffix("started") ? "Task started" : kind.hasSuffix("stopped") ? "Task stopped"
                : kind.contains("repl") ? "Reply sent" : kind.contains("respond") || kind.contains("approv") ? "Answered" : "T3 Code"
            return action.threadId == nil ? what : "\(what) · open in Tasks"
        }
        if kind.hasPrefix("calendar") { return "On your calendar" }
        if kind.hasPrefix("journal") { return "In today's journal" }
        if kind.hasPrefix("ui") || kind.hasPrefix("genui") { return "On your Mac and in Chats" }
        if kind.hasPrefix("mac") { return "On your Mac" }
        return "Done"
    }
}

/// A small card the assistant showed (`{"type":"card", title, body}`).
struct TalkInfoCard: View {
    let card: AssistantCard

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(card.title.uppercased())
                .font(SamTheme.eyebrow)
                .tracking(0.5)
                .foregroundStyle(SamTheme.orbPale)
                .lineLimit(1)
            Text(card.body)
                .font(.system(size: 16.5, weight: .semibold))
                .foregroundStyle(SamTheme.ink)
                .lineLimit(4)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(radius: 20, tint: SamTheme.orb, padding: 15)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("talk-card")
    }
}

/// The conversation so far (up to the last twelve exchanges), newest at the bottom.
struct TalkTranscript: View {
    let exchanges: [ConversationMachine.Exchange]
    let liveId: String?
    let open: (AssistantAction) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                ForEach(exchanges.filter { !$0.heard.isEmpty || !$0.say.isEmpty }) { exchange in
                    VStack(spacing: 8) {
                        if !exchange.heard.isEmpty {
                            HStack {
                                Spacer(minLength: 50)
                                Text(exchange.heard)
                                    .font(.system(size: 15.5))
                                    .foregroundStyle(SamTheme.ink)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .fill(SamTheme.orb.opacity(0.32)))
                            }
                        }
                        if !exchange.say.isEmpty {
                            HStack {
                                VStack(alignment: .leading, spacing: 6) {
                                    if exchange.kind == .announcement {
                                        Label("Heads up", systemImage: "bell.fill")
                                            .font(.system(size: 11.5, weight: .semibold))
                                            .foregroundStyle(SamTheme.amber)
                                    }
                                    Text(ConversationEngine.deviceWords(exchange.say))
                                        .font(.system(size: 15.5))
                                        .foregroundStyle(exchange.failed ? SamTheme.amber : SamTheme.ink2)
                                    if exchange.interrupted, exchange.id != liveId {
                                        Label("Stopped", systemImage: "stop.fill")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(SamTheme.faint)
                                    }
                                    ForEach(exchange.actions, id: \.self) { action in
                                        Button { open(action) } label: {
                                            Label(action.title, systemImage: TalkActionCard.symbol(action.kind))
                                                .font(.system(size: 13, weight: .semibold))
                                                .foregroundStyle(SamTheme.mint)
                                                .lineLimit(1)
                                        }
                                        .buttonStyle(.plain)
                                        .disabled(action.threadId == nil)
                                    }
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(SamTheme.glass2))
                                Spacer(minLength: 50)
                            }
                        }
                    }
                    .id(exchange.id)
                    .opacity(exchange.interrupted && exchange.id != liveId ? 0.7 : 1)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        }
        .scrollIndicators(.hidden)
        .defaultScrollAnchor(.bottom)
        .accessibilityIdentifier("talk-transcript-list")
    }
}
