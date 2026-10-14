import SamRabbitKit
import SwiftUI

/// The watch's only way to enter text: a full-screen voice capture. It listens as soon as it opens (the
/// orb follows your voice, a big Stop), stops by itself after a short quiet, turns what you said into
/// words on the Mac, then shows them large with Send and Say again. Close it to cancel. A voice note sends the
/// recording itself and says only that it went ("Sent ✓", what the Mac did), then closes; double tap is its Stop
/// on watches that have it.
struct VoiceCaptureView: View {
    @State private var capture: VoiceCapture
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isLuminanceReduced) private var dimmed

    init(request: VoiceRequest, model: WatchModel) {
        _capture = State(initialValue: VoiceCapture(request: request, model: model))
    }

    var body: some View {
        Group {
            switch capture.phase {
            case .starting, .listening: listening
            case .transcribing: transcribing
            case .review(let text): review(text, sending: false)
            case .sending(let text): review(text, sending: true)
            case .failed(let problem): failed(problem)
            case .delivering: delivering
            case .delivered(let notice): delivered(notice)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: capture.phase)
        .background {
            ZStack {
                SamTheme.night
                LinearGradient(colors: [capture.tint.opacity(0.30), .clear], startPoint: .top, endPoint: .center)
            }
            .ignoresSafeArea()
        }
        .onAppear { capture.appear() }
        .onDisappear { capture.cancel() }
        .onChange(of: scenePhase) { _, phase in
            // The wrist went down while listening: keep what was said.
            if phase == .background { capture.finish() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .samRabbitStopVoiceNote)) { _ in
            capture.finish() // the Voice Note control pressed again: stop and send
        }
    }

    // MARK: - Listening

    private var listening: some View {
        VStack(spacing: 4) {
            Label(capture.request.purpose.title, systemImage: capture.request.purpose.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(capture.tint)
                .lineLimit(1)
            Spacer(minLength: 2)
            OrbView(mood: .live, animated: !dimmed, frameRate: 30, level: capture.level)
                .frame(width: 84, height: 84)
                .accessibilityHidden(true)
            Spacer(minLength: 6)
            Text(capture.phase == .starting ? "Starting…" : capture.heardSpeech ? "Listening…" : capture.request.purpose.prompt)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(SamTheme.ink2)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .accessibilityIdentifier("voice-prompt")
            Button {
                capture.finish()
            } label: {
                CapsuleFace(title: capture.isCapture ? "Stop & send" : "Stop", symbol: "stop.fill",
                            colors: [SamTheme.red, SamTheme.red.opacity(0.72)], height: 50)
            }
            .buttonStyle(.plain)
            .disabled(capture.phase != .listening)
            // Double tap (Series 9+ / Ultra 2+) is Stop: the hand that holds nothing can end a note.
            .handGestureShortcut(.primaryAction, isEnabled: capture.phase == .listening)
            .accessibilityIdentifier("voice-stop")
            .accessibilityLabel(capture.isCapture ? "Stop and send" : "Stop")
            .accessibilityValue(Formatting.duration(capture.elapsed))
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("voice-listening")
    }

    // MARK: - A voice note

    private var delivering: some View {
        VStack(spacing: 10) {
            OrbView(mood: .working, animated: !dimmed, frameRate: 24)
                .frame(width: 64, height: 64)
            Text("Sending…")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(SamTheme.ink)
                .accessibilityIdentifier("voice-delivering")
            ProgressView().controlSize(.small)
        }
    }

    private func delivered(_ notice: CaptureNotice) -> some View {
        let tint = notice.tone == .sent ? SamTheme.mint : notice.tone == .queued ? SamTheme.amber : SamTheme.red
        return ScrollView {
            VStack(spacing: 6) {
                Image(systemName: notice.symbol)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 58, height: 58)
                    .background(Circle().fill(tint.opacity(0.16)))
                    .padding(.top, 2)
                Text(notice.tone == .sent ? "Sent ✓" : notice.title)
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .foregroundStyle(SamTheme.ink)
                    .accessibilityIdentifier("voice-result")
                if notice.tone == .sent, notice.title != "Sent" {
                    Text(notice.title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(tint)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("voice-outcome")
                }
                if let detail = notice.detail {
                    Text(detail)
                        .font(.system(size: 12.5))
                        .foregroundStyle(SamTheme.muted)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .accessibilityIdentifier("voice-detail")
                }
                if notice.tone == .failed {
                    Button {
                        capture.begin()
                    } label: {
                        CapsuleFace(title: "Say again", symbol: "mic.fill", colors: [SamTheme.orb2, SamTheme.orb],
                                    height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("voice-again")
                    .padding(.top, 4)
                }
            }
            .padding(.horizontal, 4)
        }
    }

    // MARK: - Transcribing

    private var transcribing: some View {
        VStack(spacing: 10) {
            OrbView(mood: .working, animated: !dimmed, frameRate: 24)
                .frame(width: 64, height: 64)
            Text("Writing it down…")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(SamTheme.ink)
                .accessibilityIdentifier("voice-transcribing")
            ProgressView().controlSize(.small)
        }
    }

    // MARK: - Review

    private func review(_ text: String, sending: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Label(capture.request.purpose.reviewLabel, systemImage: capture.request.purpose.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(capture.tint)
                    .lineLimit(1)
                Text(text)
                    .font(.system(size: text.count <= 40 ? 22 : text.count <= 90 ? 19 : 17, weight: .semibold,
                                  design: .rounded))
                    .foregroundStyle(SamTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("voice-transcript")
                if let problem = capture.sendProblem {
                    HStack(alignment: .top, spacing: 5) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(SamTheme.red)
                        Text([problem.title, problem.detail].compactMap { $0 }.joined(separator: ". "))
                            .foregroundStyle(SamTheme.ink2)
                    }
                    .font(.system(size: 12))
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("voice-send-problem")
                }
                Button {
                    capture.send()
                } label: {
                    CapsuleFace(title: sending ? "Sending…" : "Send", symbol: "arrow.up",
                                colors: [SamTheme.orb2, SamTheme.orb], height: 50, busy: sending)
                }
                .buttonStyle(.plain)
                .disabled(sending)
                .accessibilityIdentifier("voice-send")
                .padding(.top, 2)
                Button {
                    capture.begin()
                } label: {
                    CapsuleFace(title: "Say again", symbol: "mic.fill",
                                colors: [Color.white.opacity(0.17), Color.white.opacity(0.10)], height: 44)
                }
                .buttonStyle(.plain)
                .disabled(sending)
                .accessibilityIdentifier("voice-again")
            }
            .padding(.horizontal, 4)
        }
    }

    // MARK: - Problems

    private func failed(_ problem: VoiceProblem) -> some View {
        ScrollView {
            VStack(spacing: 6) {
                Image(systemName: problem.symbol)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(SamTheme.amber)
                    .padding(.top, 4)
                Text(problem.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(SamTheme.ink)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("voice-problem")
                Text(problem.detail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(SamTheme.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    capture.begin()
                } label: {
                    CapsuleFace(title: "Say again", symbol: "mic.fill", colors: [SamTheme.orb2, SamTheme.orb], height: 48)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("voice-again")
                .padding(.top, 6)
            }
            .padding(.horizontal, 4)
        }
    }
}

extension Formatting {
    /// "0:07"
    static func duration(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}
