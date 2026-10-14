import Combine
import SwiftUI

/// VoiceNotes as the dock's pill window draws it, published only when that changes (the level moves the bars a few
/// times a second; nothing else redraws for it).
@MainActor
final class DockNoteFeed: ObservableObject {
    @Published private(set) var snapshot = VoiceNoteSnapshot()
    private var subscription: AnyCancellable?

    init(_ notes: VoiceNotes) {
        snapshot = notes.snapshot
        subscription = notes.$snapshot.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] next in
            MainActor.assumeIsolated { self?.snapshot = next }
        }
    }

    /// Snapshots: this state, nothing live.
    init(fixture: VoiceNoteSnapshot) {
        snapshot = fixture
    }
}

/// While a voice note records, is sent, or says how it went (CONTRACTS-WAVE8 §D1), the pill becomes this small bar:
/// a red dot and the level, "Recording… ⌃⌥N to send" with the time, × (throw it away) and ↑ (send now); then "Sending…",
/// then "Sent ✓ — Added to your journal" (or "Saved on this Mac" when the bridge can't take it yet) for a few seconds.
/// It never speaks.
struct DockNoteBar: View {
    let note: VoiceNoteSnapshot
    let scale: CGFloat
    let commands: DockCommands
    @Environment(\.dockRender) private var render

    var body: some View {
        let s = scale
        HStack(spacing: 11 * s) {
            mark(s)
                .padding(.leading, 9 * s)
            VStack(alignment: .leading, spacing: 2 * s) {
                HStack(spacing: 6 * s) {
                    Text(label)
                        .font(.system(size: 10.5 * s, weight: .semibold))
                        .textCase(.uppercase)
                        .kerning(0.6 * s)
                        .foregroundStyle(labelColor)
                        .fixedSize()
                    if note.recording, let startedAt = note.startedAt {
                        elapsed(since: startedAt, s)
                    }
                }
                Text(line)
                    .font(.system(size: 13.5 * s, weight: .medium))
                    .foregroundStyle(DockPalette.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11.5 * s))
                        .foregroundStyle(DockPalette.secondary)
                        .lineLimit(note.recording ? 1 : 2)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // Recording, the level and the two buttons sit beside the words; after, the words have the room.
            .frame(width: (note.recording ? 236 : 292) * s, alignment: .leading)
            .padding(.vertical, 8 * s)
            if note.recording {
                DockLevelBars(level: note.level, scale: s)
                HStack(spacing: 7 * s) {
                    DockRoundButton(symbol: "xmark", size: 30 * s, fill: Color.white.opacity(0.12), help: "Throw it away (Esc)") {
                        commands.cancelNote()
                    }
                    .dockControl()
                    DockRoundButton(symbol: "arrow.up", size: 30 * s, tint: .white, fill: Palette.orb,
                                    help: note.shortcut.isEmpty ? "Send it now" : "Send it now (\(note.shortcut))") { commands.sendNote() }
                        .dockControl()
                }
                .padding(.trailing, 11 * s)
            } else {
                Spacer(minLength: 0).frame(width: 4 * s)
            }
        }
        .frame(minHeight: (58 * s).rounded())
        .background(DockGlass(shape: RoundedRectangle(cornerRadius: 21 * s, style: .continuous), firmness: 1.15))
        .contentShape(RoundedRectangle(cornerRadius: 21 * s, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Voice note: \(label). \(line) \(detail)")
    }

    /// The red dot (with a halo that follows the voice) while recording, a ring while sending, then how it went.
    @ViewBuilder private func mark(_ s: CGFloat) -> some View {
        let size = 34 * s
        ZStack {
            Circle().fill(Color.white.opacity(0.07))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.09), lineWidth: 1))
            switch note.phase {
            case .recording:
                Circle().fill(Self.red.opacity(0.28))
                    .frame(width: size * (0.5 + 0.42 * CGFloat(note.level)), height: size * (0.5 + 0.42 * CGFloat(note.level)))
                Circle().fill(Self.red).frame(width: size * 0.34, height: size * 0.34)
                    .shadow(color: Self.red.opacity(0.6), radius: 4 * s)
            case .sending:
                DockProgressRing(progress: nil, size: size * 0.46)
            case .sent:
                Image(systemName: "checkmark").font(.system(size: size * 0.4, weight: .bold)).foregroundStyle(Self.green)
            case .queued:
                Image(systemName: "tray.and.arrow.up.fill").font(.system(size: size * 0.36, weight: .semibold)).foregroundStyle(Self.amber)
            case .discarded:
                Image(systemName: "minus").font(.system(size: size * 0.38, weight: .bold)).foregroundStyle(DockPalette.secondary)
            case .failed:
                Image(systemName: "exclamationmark").font(.system(size: size * 0.4, weight: .bold)).foregroundStyle(DockPalette.error)
            case .idle:
                EmptyView()
            }
        }
        .frame(width: size, height: size)
        .animation(render.isSnapshot ? nil : .easeOut(duration: 0.12), value: note.level)
    }

    @ViewBuilder private func elapsed(since start: Date, _ s: CGFloat) -> some View {
        let text = { (now: Date) in Self.clock(now.timeIntervalSince(start)) }
        Group {
            if render.isSnapshot {
                Text(text(Date()))
            } else {
                TimelineView(.periodic(from: start, by: 1)) { context in Text(text(context.date)) }
            }
        }
        .font(.system(size: 10.5 * s, weight: .semibold))
        .monospacedDigit()
        .foregroundStyle(DockPalette.secondary)
        .fixedSize()
    }

    /// "0:07", "1:42".
    static func clock(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds))
        return "\(whole / 60):" + String(format: "%02d", whole % 60)
    }

    static let red = Color(red: 1, green: 0.33, blue: 0.32)
    static let green = Color(red: 0.42, green: 0.86, blue: 0.62)
    static let amber = Color(red: 1, green: 0.78, blue: 0.36)

    private var label: String {
        switch note.phase {
        case .idle: return ""
        case .recording: return "Voice note"
        case .sending: return "Sending"
        case .sent: return "Sent ✓"
        case .queued: return "Kept"
        case .discarded: return "Not sent"
        case .failed: return "Voice note"
        }
    }

    private var labelColor: Color {
        switch note.phase {
        case .recording: return Self.red
        case .sent: return Self.green
        case .queued: return Self.amber
        case .failed: return DockPalette.error
        default: return DockPalette.accentText
        }
    }

    private var line: String {
        guard case .recording(let held) = note.phase else { return note.line }
        let key = note.shortcut
        if key.isEmpty { return "Recording… ↑ to send" }
        return held ? "Recording… let go of \(key) to send" : "Recording… \(key) to send"
    }

    private var detail: String {
        guard case .recording(let held) = note.phase else { return note.detail }
        return held ? "Talk while you hold it." : "Or stop talking: it sends after a pause."
    }
}

/// Five bars that follow the voice (still while it is quiet).
struct DockLevelBars: View {
    let level: Double
    let scale: CGFloat

    var body: some View {
        let s = scale
        let shape: [CGFloat] = [0.45, 0.8, 1, 0.7, 0.4]
        HStack(alignment: .center, spacing: 3 * s) {
            ForEach(0..<shape.count, id: \.self) { index in
                Capsule()
                    .fill(Color.white.opacity(level > 0.04 ? 0.9 : 0.35))
                    .frame(width: 3 * s, height: max(4, 22 * s * shape[index] * CGFloat(0.2 + 0.8 * min(1, level))))
            }
        }
        .frame(width: 27 * s, height: 24 * s)
    }
}
