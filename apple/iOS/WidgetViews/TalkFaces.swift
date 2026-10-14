import AppIntents
import SamRabbitKit
import SwiftUI
import WidgetKit

// The faces of Talk (the live conversation) outside the app: the Lock Screen widget that opens it and its Live
// Activity on the Lock Screen and in the Dynamic Island. Shared by the widget extension and the app (the widget
// gallery and the render harness draw them too).

extension TalkPhase {
    /// The colour of the phase (the state dot, the Dynamic Island).
    var color: Color {
        switch self {
        case .listening, .hearing, .starting: SamTheme.green
        case .thinking: SamTheme.orbPale
        case .speaking: SamTheme.accent
        case .announcing, .muted: SamTheme.amber
        case .ended: SamTheme.muted
        }
    }

    var mood: OrbMood {
        switch self {
        case .thinking: .working
        case .muted, .ended: .idle
        default: .live
        }
    }
}

/// Lock Screen, circular: a waveform and "Talk". Tapping it opens SamRabbit in a live conversation.
struct TalkCircularFace: View {
    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 1) {
                Image(systemName: "waveform")
                    .font(.system(size: 21, weight: .semibold))
                Text("Talk")
                    .font(.system(size: 10.5, weight: .semibold))
            }
            .widgetAccentable()
        }
        .accessibilityLabel("Talk to SamRabbit")
    }
}

/// Lock Screen, rectangular: "Talk to SamRabbit".
struct TalkRectangularFace: View {
    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                AccessoryWidgetBackground().clipShape(Circle())
                Image(systemName: "waveform").font(.system(size: 18, weight: .semibold))
            }
            .frame(width: 40, height: 40)
            .widgetAccentable()
            VStack(alignment: .leading, spacing: 1) {
                Text("Talk").font(.system(size: 15, weight: .semibold)).widgetAccentable()
                Text("to SamRabbit").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

/// The Live Activity on the Lock Screen (and in the notification banner): the orb, what it is doing, the last line
/// and End.
struct TalkActivityLockFace: View {
    let state: TalkActivityState
    let startedAt: Date

    var body: some View {
        HStack(spacing: 14) {
            OrbView(mood: state.phase.mood, animated: false)
                .frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("SamRabbit")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(SamTheme.muted)
                    Text(startedAt, style: .timer)
                        .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(SamTheme.faint)
                }
                HStack(spacing: 7) {
                    Circle().fill(state.phase.color).frame(width: 7, height: 7)
                    Text(state.phase.word)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(SamTheme.ink)
                }
                if !state.line.isEmpty {
                    Text(state.line)
                        .font(.system(size: 13.5))
                        .foregroundStyle(SamTheme.ink2)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            TalkEndButton(size: 44)
        }
        .padding(16)
    }
}

/// End, on the Live Activity (`EndTalkIntent`, run by the app).
struct TalkEndButton: View {
    var size: CGFloat = 40

    var body: some View {
        Button(intent: EndTalkIntent()) {
            Image(systemName: "xmark")
                .font(.system(size: size * 0.36, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Circle().fill(SamTheme.red.opacity(0.9)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("End the conversation")
    }
}

/// The Dynamic Island, expanded (also drawn by the gallery).
struct TalkIslandExpandedFace: View {
    let state: TalkActivityState

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            OrbView(mood: state.phase.mood, animated: false, halo: false)
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.phase.word)
                    .font(.system(size: 15.5, weight: .semibold))
                    .foregroundStyle(state.phase.color)
                Text(state.line.isEmpty ? "Talking with SamRabbit" : state.line)
                    .font(.system(size: 13))
                    .foregroundStyle(SamTheme.ink2)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            TalkEndButton(size: 38)
        }
    }
}
