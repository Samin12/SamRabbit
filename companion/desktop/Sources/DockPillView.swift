import AppKit
import Combine
import SwiftUI

/// What the dock's windows show right now (not data: the store has that).
@MainActor
final class DockUIState: ObservableObject {
    enum Menu: Equatable {
        case project, agent
    }

    @Published var expanded = false
    @Published var selected: String?
    @Published var expandedRow: String?
    @Published var earlierOpen = false
    @Published var menu: Menu?
    /// A field that should take the keys (set by N, R, ⌃⌥K; cleared by the field once it has them).
    @Published var focusRequest: DockFocus?
    /// The field that has the keys.
    @Published var editing: DockFocus?
    @Published var pillScale: CGFloat = 1
    @Published var panelScale: CGFloat = 1
    @Published var maxPanelHeight: CGFloat = 640
    @Published var pillHover = false
    @Published var dragging = false
}

/// The voice state as the dock draws it. Live it comes from `MacVoice` (owned by the voice workstream); snapshots and
/// tests make one directly, so nothing here depends on how voice is implemented.
struct DockVoiceSnapshot: Equatable {
    enum Phase: Equatable {
        case idle, starting, listening, thinking, speaking
        case error(String)
    }

    var phase: Phase = .idle
    var heard = ""
    var caption = ""
    var level: CGFloat = 0
    var micMuted = false
    var wakeArmed = false
    var wakeEnabled = true
    var shortcut = "⌃⌥Space"

    var active: Bool { phase != .idle }
}

extension DockVoiceSnapshot {
    @MainActor init(_ voice: MacVoice) {
        switch voice.state {
        case .idle: phase = .idle
        case .starting: phase = .starting
        case .listening: phase = .listening
        case .thinking: phase = .thinking
        case .speaking: phase = .speaking
        case .error(let message): phase = .error(message)
        }
        heard = voice.heard
        caption = voice.caption
        level = CGFloat(voice.level)
        micMuted = voice.micMuted
        wakeArmed = voice.wakeArmed
        wakeEnabled = voice.wakeEnabled
        shortcut = voice.shortcutDescription
    }
}

/// MacVoice as one of the dock's windows draws it, published only when that changes. The list never draws the mic
/// level and the pill only during a conversation, so the level (many times a second) redraws nothing else.
@MainActor
final class DockVoiceFeed: ObservableObject {
    @Published private(set) var snapshot = DockVoiceSnapshot()
    private let keepsLevel: Bool
    private var subscription: AnyCancellable?

    init(_ voice: MacVoice, keepsLevel: Bool) {
        self.keepsLevel = keepsLevel
        update(voice)
        // objectWillChange fires before the new value is set: read it a moment later.
        subscription = voice.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self, weak voice] _ in
            MainActor.assumeIsolated {
                if let voice { self?.update(voice) }
            }
        }
    }

    private func update(_ voice: MacVoice) {
        var next = DockVoiceSnapshot(voice)
        if !keepsLevel || !next.active { next.level = 0 }
        if next != snapshot { snapshot = next }
    }
}

/// What the views ask the controller to do (no-ops in snapshots).
struct DockCommands {
    var toggleVoice: () -> Void = {}
    var setMicMuted: (Bool) -> Void = { _ in }
    var stopSpeaking: () -> Void = {}
    var endVoice: () -> Void = {}
    var showMenu: () -> Void = {}
    var collapse: () -> Void = {}
    var interact: () -> Void = {}
    var openItem: (DockItem) -> Void = { _ in }
}

/// The pill's controls report their frames, so a press anywhere else on the pill can drag it.
struct DockHitRectsKey: PreferenceKey {
    static let defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value += nextValue() }
}

struct DockSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

extension View {
    func dockControl() -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: DockHitRectsKey.self, value: [proxy.frame(in: .named("dockPill"))])
        })
    }

    func dockReportSize() -> some View {
        background(GeometryReader { proxy in Color.clear.preference(key: DockSizeKey.self, value: proxy.size) })
    }
}

// MARK: the pill

/// The collapsed dock (~44 pt tall on a laptop): the orb, "2 need you" (accent capsule, hidden at 0), "4 working"
/// (muted), and the mic, with a dot when the "Hey Rabbit" listener is armed.
struct DockPill: View {
    @ObservedObject var store: DockStore
    @ObservedObject var ui: DockUIState
    let voice: DockVoiceSnapshot
    let commands: DockCommands
    @State private var moving = false

    var body: some View {
        let s = ui.pillScale
        HStack(spacing: 9 * s) {
            DockOrbMark(size: 36 * s, moving: moving, dim: offline)
                .padding(.leading, 4 * s)
                .padding(.trailing, -2 * s)
            words(s)
            Rectangle().fill(Color.white.opacity(0.13)).frame(width: 1, height: 18 * s)
            DockRoundButton(symbol: "mic.fill", size: 32 * s, badge: voice.wakeArmed,
                            help: voice.shortcut.isEmpty ? "Talk to SamRabbit"
                                : "Talk to SamRabbit (\(voice.shortcut))") { commands.toggleVoice() }
                .dockControl()
                .padding(.trailing, 6 * s)
        }
        .frame(height: (DockMetrics.pillBaseHeight * s).rounded())
        .background(DockGlass(shape: Capsule(), firmness: ui.pillHover || ui.expanded ? 1.18 : 1))
        .contentShape(Capsule())
        .onChange(of: store.beat) { _, _ in
            moving = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { moving = false }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityText)
    }

    private var offline: Bool {
        if case .offline = store.connection { return true }
        return false
    }

    @ViewBuilder private func words(_ s: CGFloat) -> some View {
        if offline {
            Text(store.connection == .offline(0) ? "Bridge offline" : "Bridge needs setup")
                .font(.system(size: 13 * s, weight: .medium))
                .foregroundStyle(DockPalette.tertiary)
        } else {
            let needs = store.needsYouCount
            let working = store.workingCount
            if needs > 0 {
                Text(needs == 1 ? "1 needs you" : "\(needs) need you")
                    .font(.system(size: 13 * s, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 10 * s)
                    .padding(.vertical, 4.5 * s)
                    .background(Capsule().fill(DockPalette.accentFill))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
                    .fixedSize()
            }
            if working > 0 {
                HStack(spacing: 6 * s) {
                    DockWorkingDot(size: 6 * s)
                    Text("\(working) working")
                        .font(.system(size: 13 * s, weight: .medium))
                        .foregroundStyle(DockPalette.secondary)
                }
                .fixedSize()
            }
            if needs == 0 && working == 0 {
                Text(store.connection == .connecting ? "SamRabbit" : "All clear")
                    .font(.system(size: 13 * s, weight: .medium))
                    .foregroundStyle(DockPalette.secondary)
            }
        }
    }

    private var accessibilityText: String {
        if offline { return "SamRabbit dock: the Mac bridge isn’t running" }
        return "SamRabbit dock: \(store.needsYouCount) need you, \(store.workingCount) working"
    }
}

/// The small dot before "working" (still: the pill costs nothing at rest).
struct DockWorkingDot: View {
    let size: CGFloat

    var body: some View {
        Circle().fill(Palette.pale.opacity(0.85)).frame(width: size, height: size)
    }
}

// MARK: the voice bar

/// While a voice conversation is on, the pill becomes this (like ChatGPT Voice): the orb (it pulses with the mic level),
/// what was heard, the reply as it streams, and mute, stop speaking (barge in) and end.
struct DockVoiceBar: View {
    let voice: DockVoiceSnapshot
    let scale: CGFloat
    let commands: DockCommands

    var body: some View {
        let s = scale
        HStack(spacing: 12 * s) {
            DockOrbMark(size: 46 * s, lively: voice.phase == .listening || voice.phase == .speaking,
                        level: orbLevel, dim: isError)
                .padding(.leading, 6 * s)
            VStack(alignment: .leading, spacing: 2 * s) {
                HStack(spacing: 6 * s) {
                    Text(status)
                        .font(.system(size: 10.5 * s, weight: .semibold))
                        .textCase(.uppercase)
                        .kerning(0.6 * s)
                        .foregroundStyle(isError ? DockPalette.error : DockPalette.accentText)
                        .fixedSize()
                    if !voice.heard.isEmpty {
                        Text("“\(DockText.oneLine(voice.heard))”")
                            .font(.system(size: 11.5 * s))
                            .foregroundStyle(DockPalette.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Text(caption)
                    .font(.system(size: 13.5 * s, weight: .medium))
                    .foregroundStyle(captionIsPlaceholder ? DockPalette.tertiary : DockPalette.ink)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 252 * s, alignment: .leading)
            HStack(spacing: 7 * s) {
                DockRoundButton(symbol: voice.micMuted ? "mic.slash.fill" : "mic.fill", size: 32 * s,
                                tint: voice.micMuted ? DockPalette.accentText : DockPalette.ink,
                                fill: voice.micMuted ? Color.white.opacity(0.2) : DockPalette.control,
                                help: voice.micMuted ? "Unmute the mic" : "Mute the mic") { commands.setMicMuted(!voice.micMuted) }
                    .dockControl()
                DockRoundButton(symbol: "stop.fill", size: 32 * s, help: "Stop speaking") { commands.stopSpeaking() }
                    .opacity(voice.phase == .speaking ? 1 : 0.38)
                    .disabled(voice.phase != .speaking)
                    .dockControl()
                DockRoundButton(symbol: "xmark", size: 32 * s, fill: Color.white.opacity(0.16), help: "End (Esc)") { commands.endVoice() }
                    .dockControl()
            }
            .padding(.trailing, 12 * s)
        }
        .frame(height: (64 * s).rounded())
        .background(DockGlass(shape: RoundedRectangle(cornerRadius: 22 * s, style: .continuous), firmness: 1.15))
        .contentShape(RoundedRectangle(cornerRadius: 22 * s, style: .continuous))
    }

    private var isError: Bool {
        if case .error = voice.phase { return true }
        return false
    }

    private var orbLevel: CGFloat {
        switch voice.phase {
        case .listening: return voice.micMuted ? 0 : voice.level
        case .speaking: return voice.level * 0.5
        default: return 0
        }
    }

    private var status: String {
        switch voice.phase {
        case .idle: return ""
        case .starting: return "Starting"
        case .listening: return voice.micMuted ? "Muted" : "Listening"
        case .thinking: return "Thinking"
        case .speaking: return "Speaking"
        case .error: return "Voice problem"
        }
    }

    private var captionIsPlaceholder: Bool { voice.caption.isEmpty && !isError }

    /// The reply streams in: the newest words matter, so a long caption keeps its end ("…which database to use.").
    static func tail(_ text: String, max: Int) -> String {
        guard text.count > max else { return text }
        let cut = text.suffix(max)
        let start = cut.firstIndex(of: " ").map { cut.index(after: $0) } ?? cut.startIndex
        return "…" + cut[start...]
    }

    private var caption: String {
        if case .error(let message) = voice.phase { return message }
        if !voice.caption.isEmpty { return Self.tail(DockText.oneLine(voice.caption), max: 76) }
        switch voice.phase {
        case .starting: return "One moment…"
        case .listening: return voice.micMuted ? "The mic is off. Unmute to talk." : "Go ahead, I’m listening."
        case .thinking: return "Working on it…"
        default: return ""
        }
    }
}

// MARK: roots (what each window hosts)

/// The pill window's content: the pill, or the voice bar during a conversation. It sizes itself; the window follows.
struct DockPillRoot: View {
    @ObservedObject var store: DockStore
    @ObservedObject var ui: DockUIState
    @ObservedObject var voice: DockVoiceFeed
    let commands: DockCommands
    let render: DockRender
    var onSize: (CGSize) -> Void
    var onHitRects: ([CGRect]) -> Void

    var body: some View {
        let snapshot = voice.snapshot
        Group {
            if snapshot.active {
                DockVoiceBar(voice: snapshot, scale: ui.pillScale, commands: commands)
            } else {
                DockPill(store: store, ui: ui, voice: snapshot, commands: commands)
            }
        }
        .fixedSize()
        .dockReportSize()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .coordinateSpace(name: "dockPill")
        .onPreferenceChange(DockSizeKey.self) { size in onSize(size) }
        .onPreferenceChange(DockHitRectsKey.self) { rects in onHitRects(rects) }
        .environment(\.dockRender, render)
        .environment(\.colorScheme, .dark)
    }
}
