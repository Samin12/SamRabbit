import SamRabbitKit
import SwiftUI

/// The voice-note recorder, full screen and minimal: it records the moment it opens (the orb follows your voice, a
/// red dot and the timer), "Stop & send" or just pause, then "Sent ✓" with what your Mac did, and it closes by
/// itself. Cancel (top left) drops it. Opened from a link outside the app it waits for a tap on the mic.
struct CaptureView: View {
    @Environment(AppModel.self) private var model
    /// `-SamRabbitStillOrb YES` (UI tests): a still orb, so the app goes idle between frames.
    private let still = UserDefaults.standard.bool(forKey: "SamRabbitStillOrb")

    private var capture: CaptureModel { model.capture }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, 18)
                    .padding(.top, 4)
                Spacer(minLength: 12)
                center(width: geometry.size.width)
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 12)
                bottom
                    .padding(.horizontal, 24)
                    .padding(.bottom, 14)
            }
        }
        .background { CaptureBackdrop(phase: capture.phase, level: capture.level) }
        .preferredColorScheme(.dark)
        .animation(.smooth(duration: 0.3), value: capture.phase)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("capture-screen")
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            CircleIconButton(symbol: "xmark", label: capture.recording ? "Cancel" : "Close") {
                if capture.recording { capture.cancel() } else { capture.close() }
            }
            .accessibilityIdentifier("capture-close")
            Spacer()
            Label("Voice note", systemImage: "waveform.badge.mic")
                .font(.system(size: 14.5, weight: .semibold))
                .foregroundStyle(SamTheme.ink2)
                .padding(.horizontal, 14)
                .frame(height: 36)
                .glassEffect(.regular.tint(SamTheme.navy.opacity(0.3)), in: .capsule)
            Spacer()
            Color.clear.frame(width: 40, height: 40)
        }
        .frame(height: 48)
    }

    // MARK: - The middle

    @ViewBuilder private func center(width: CGFloat) -> some View {
        let size = min(width * 0.62, 260)
        switch capture.phase {
        case .idle, .ready:
            VStack(spacing: 22) {
                Button {
                    capture.start()
                } label: {
                    Image(systemName: "mic.fill")
                        .font(.system(size: size * 0.2, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: size * 0.56, height: size * 0.56)
                        .background(Circle().fill(LinearGradient(colors: [SamTheme.red, Color(hex: 0xE2365A)],
                                                                 startPoint: .top, endPoint: .bottom)))
                        .shadow(color: SamTheme.red.opacity(0.45), radius: 24, y: 8)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("capture-record")
                .accessibilityLabel("Record a voice note")
                VStack(spacing: 6) {
                    Text("Record a voice note")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(SamTheme.ink)
                    Text("Say it once. Your Mac files it: your journal when you say so, a task, your calendar, or a note.")
                        .font(.system(size: 14.5))
                        .foregroundStyle(SamTheme.muted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                }
            }
        case .starting, .recording:
            VStack(spacing: 26) {
                OrbView(mood: .live, animated: !still, frameRate: 30, level: capture.level)
                    .frame(width: size, height: size)
                    .accessibilityHidden(true)
                VStack(spacing: 10) {
                    HStack(spacing: 9) {
                        PulseDot(color: SamTheme.red, size: 9)
                        Text(capture.phase == .starting ? "Starting…" : "Recording")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(SamTheme.red.mix(with: .white, by: 0.25))
                            .accessibilityIdentifier("capture-state")
                    }
                    Text(Self.clock(capture.elapsed))
                        .font(.system(size: 54, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(SamTheme.ink)
                        .contentTransition(.numericText())
                        .accessibilityIdentifier("capture-timer")
                    Text(capture.heardSpeech ? "Pause and it sends itself" : "Say it: a thought, a task, a journal line")
                        .font(.system(size: 14.5))
                        .foregroundStyle(SamTheme.muted)
                        .contentTransition(.opacity)
                }
            }
        case .sending:
            VStack(spacing: 22) {
                OrbView(mood: .working, animated: !still, frameRate: 24)
                    .frame(width: size * 0.7, height: size * 0.7)
                Text("Sending…")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(SamTheme.ink)
                    .accessibilityIdentifier("capture-state")
            }
        case .finished(let notice):
            result(symbol: notice.symbol, tint: Self.tint(notice.tone), title: notice.tone == .sent ? "Sent ✓" : notice.title,
                   headline: notice.tone == .sent && notice.title != "Sent" ? notice.title : nil, detail: notice.detail,
                   footer: notice.tone == .sent && capture.waiting > 0
                       ? Formatting.count(capture.waiting, "note", "notes") + " still waiting for your Mac" : nil)
        case .problem(let title, let detail):
            result(symbol: "exclamationmark.triangle.fill", tint: SamTheme.amber, title: title, headline: nil,
                   detail: detail, footer: nil)
        }
    }

    private func result(symbol: String, tint: Color, title: String, headline: String?, detail: String?,
                        footer: String?) -> some View {
        VStack(spacing: 18) {
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 112, height: 112)
                .background(Circle().fill(tint.opacity(0.14)))
                .overlay(Circle().strokeBorder(tint.opacity(0.35), lineWidth: 1))
                .symbolEffect(.bounce, value: title)
            VStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(SamTheme.ink)
                    .accessibilityIdentifier("capture-result")
                if let headline {
                    Text(headline)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(tint)
                        .accessibilityIdentifier("capture-outcome")
                }
                if let detail {
                    Text(detail)
                        .font(.system(size: 15))
                        .foregroundStyle(SamTheme.ink2)
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                        .padding(.horizontal, 28)
                        .accessibilityIdentifier("capture-detail")
                }
                if let footer {
                    Text(footer)
                        .font(.system(size: 13))
                        .foregroundStyle(SamTheme.muted)
                        .padding(.top, 4)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - The bottom

    @ViewBuilder private var bottom: some View {
        switch capture.phase {
        case .starting, .recording:
            VStack(spacing: 14) {
                Button {
                    capture.stop()
                } label: {
                    Label("Stop & send", systemImage: "stop.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 60)
                        .background(Capsule().fill(LinearGradient(colors: [SamTheme.red, Color(hex: 0xD93A5C)],
                                                                  startPoint: .top, endPoint: .bottom)))
                        .shadow(color: SamTheme.red.opacity(0.35), radius: 18, y: 6)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .disabled(capture.phase != .recording)
                .accessibilityIdentifier("capture-stop")
                Text("Up to 3 minutes · keeps recording with the screen locked")
                    .font(.system(size: 12.5))
                    .foregroundStyle(SamTheme.faint)
            }
        case .finished(let notice) where notice.tone == .failed:
            retryButtons
        case .problem:
            retryButtons
        case .finished:
            Button {
                capture.close()
            } label: {
                Text("Done")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
            }
            .buttonStyle(.glass)
            .accessibilityIdentifier("capture-done")
        case .idle, .ready, .sending:
            Color.clear.frame(height: 60)
        }
    }

    private var retryButtons: some View {
        HStack(spacing: 12) {
            Button {
                capture.close()
            } label: {
                Text("Close").font(.system(size: 17, weight: .semibold)).frame(maxWidth: .infinity).frame(height: 54)
            }
            .buttonStyle(.glass)
            Button {
                capture.start()
            } label: {
                Label("Try again", systemImage: "mic.fill")
                    .font(.system(size: 17, weight: .semibold)).frame(maxWidth: .infinity).frame(height: 54)
            }
            .buttonStyle(.glassProminent)
            .tint(SamTheme.red.mix(with: .black, by: 0.1))
            .accessibilityIdentifier("capture-again")
        }
    }

    // MARK: - Words

    /// "0:07"
    static func clock(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    static func tint(_ tone: CaptureNotice.Tone) -> Color {
        switch tone {
        case .sent: SamTheme.mint
        case .queued: SamTheme.amber
        case .failed: SamTheme.red
        }
    }
}

/// The recorder's background: the night, with a red bloom that breathes with your voice while it records, and mint
/// once it's sent.
struct CaptureBackdrop: View {
    var phase: CaptureModel.Phase
    var level: Double

    var body: some View {
        GeometryReader { geometry in
            let w = geometry.size.width
            let h = geometry.size.height
            ZStack {
                LinearGradient(colors: [Color(hex: 0x120A12), Color(hex: 0x08070C), Color(hex: 0x040508)],
                               startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [glow.opacity(0.34 + level * 0.2), glow.opacity(0.07), .clear],
                               center: .init(x: 0.5, y: 0.36), startRadius: 0, endRadius: max(w, h) * (0.55 + level * 0.1))
                RadialGradient(colors: [SamTheme.orb.opacity(0.10), .clear], center: .init(x: 0.0, y: 1.0),
                               startRadius: 0, endRadius: max(w, h) * 0.5)
            }
            .animation(.smooth(duration: 0.5), value: phase)
        }
        .ignoresSafeArea()
    }

    private var glow: Color {
        switch phase {
        case .recording, .starting, .idle, .ready: SamTheme.red
        case .sending: SamTheme.violet
        case .finished(let notice): CaptureView.tint(notice.tone)
        case .problem: SamTheme.amber
        }
    }
}
