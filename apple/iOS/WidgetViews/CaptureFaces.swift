import AppIntents
import SamRabbitKit
import SwiftUI
import WidgetKit

// The faces of voice notes outside the app: the Lock Screen's Voice note button and the Live Activity while a note
// records (the Lock Screen and the Dynamic Island). Shared by the widget extension and the app (the widget gallery
// and the render harness draw them too).

extension CaptureActivityState {
    /// The phase's colour (the dot, the Dynamic Island's keyline).
    var color: Color {
        switch phase {
        case .recording: SamTheme.red
        case .sending: SamTheme.orbPale
        case .sent: SamTheme.mint
        case .queued: SamTheme.amber
        case .failed: SamTheme.red
        }
    }
}

/// Lock Screen, circular: a mic and "Note". Its button runs the Voice Note intent (a link would never start the
/// microphone).
struct VoiceNoteCircularFace: View {
    var body: some View {
        Button(intent: VoiceNoteIntent()) {
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 1) {
                    Image(systemName: "waveform.badge.mic")
                        .font(.system(size: 19, weight: .semibold))
                    Text("Note")
                        .font(.system(size: 10.5, weight: .semibold))
                }
                .widgetAccentable()
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Record a voice note")
    }
}

/// Lock Screen, rectangular: "Voice note · say it, it's filed".
struct VoiceNoteRectangularFace: View {
    var body: some View {
        Button(intent: VoiceNoteIntent()) {
            HStack(spacing: 10) {
                ZStack {
                    AccessoryWidgetBackground().clipShape(Circle())
                    Image(systemName: "waveform.badge.mic").font(.system(size: 17, weight: .semibold))
                }
                .frame(width: 40, height: 40)
                .widgetAccentable()
                VStack(alignment: .leading, spacing: 1) {
                    Text("Voice note").font(.system(size: 15, weight: .semibold)).widgetAccentable()
                    Text("Say it, it's filed").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Record a voice note")
    }
}

/// The Live Activity on the Lock Screen: a red dot and the timer while it records, with Stop; then what the Mac did.
struct CaptureActivityLockFace: View {
    let state: CaptureActivityState
    let startedAt: Date
    var limit: TimeInterval = CaptureFormat.iphoneMaxSeconds

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(state.color.opacity(0.18))
                Image(systemName: state.symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(state.color)
                    .symbolEffect(.variableColor.iterative, options: .repeating, isActive: state.phase == .recording)
            }
            .frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Voice note")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(SamTheme.muted)
                    CaptureClock(state: state, startedAt: startedAt, limit: limit)
                        .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(SamTheme.faint)
                }
                Text(state.word)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(SamTheme.ink)
                Text(state.phase == .recording ? "Pause and it sends itself" : state.line.isEmpty ? "SamRabbit" : state.line)
                    .font(.system(size: 13.5))
                    .foregroundStyle(SamTheme.ink2)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            if state.phase == .recording { CaptureStopButton(size: 44) }
        }
        .padding(16)
    }
}

/// The recording's time: running while it records, stopped once it stopped.
struct CaptureClock: View {
    let state: CaptureActivityState
    let startedAt: Date
    var limit: TimeInterval = CaptureFormat.iphoneMaxSeconds

    var body: some View {
        if state.phase == .recording {
            Text(timerInterval: startedAt...startedAt.addingTimeInterval(limit), countsDown: false)
        } else if let stoppedAt = state.stoppedAt {
            Text(CaptureClock.clock(stoppedAt.timeIntervalSince(startedAt)))
        }
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}

/// Stop, on the Live Activity (`StopVoiceNoteIntent`, run by the app): stops and sends.
struct CaptureStopButton: View {
    var size: CGFloat = 40

    var body: some View {
        Button(intent: StopVoiceNoteIntent()) {
            Image(systemName: "stop.fill")
                .font(.system(size: size * 0.36, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Circle().fill(SamTheme.red.opacity(0.92)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stop and send")
    }
}

/// The Dynamic Island, expanded (also drawn by the gallery).
struct CaptureIslandExpandedFace: View {
    let state: CaptureActivityState
    let startedAt: Date

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: state.symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(state.color)
                .frame(width: 40, height: 40)
                .background(Circle().fill(state.color.opacity(0.16)))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(state.word).font(.system(size: 15.5, weight: .semibold)).foregroundStyle(state.color)
                    CaptureClock(state: state, startedAt: startedAt)
                        .font(.system(size: 13, weight: .medium).monospacedDigit())
                        .foregroundStyle(SamTheme.muted)
                }
                Text(state.phase == .recording ? "Voice note · pause and it sends" : state.line.isEmpty ? "Voice note" : state.line)
                    .font(.system(size: 13))
                    .foregroundStyle(SamTheme.ink2)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            if state.phase == .recording { CaptureStopButton(size: 38) }
        }
    }
}
