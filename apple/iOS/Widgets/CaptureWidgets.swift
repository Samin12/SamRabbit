import ActivityKit
import AppIntents
import SamRabbitKit
import SwiftUI
import WidgetKit

// Voice notes from outside the app: the Control Center / Lock Screen / Action Button control, the Lock Screen
// widget and the Live Activity while one records.

/// "Voice Note": opens SamRabbit straight into the recorder, recording. iOS offers every control for the Action
/// Button too (Settings > Action Button > Controls > SamRabbit > Voice Note), which then says "Hold to Record a
/// voice note"; pressed again while recording it stops and sends.
struct VoiceNoteControl: ControlWidget {
    static let kind = "com.samrabbit.control.note"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: VoiceNoteIntent()) {
                Label("Voice Note", systemImage: "waveform.badge.mic")
                    .controlWidgetActionHint("Record a voice note")
            }
        }
        .displayName("Voice Note")
        .description("Records a quick voice note; your Mac files it.")
    }
}

/// The Lock Screen's Voice note button (an interactive `Button(intent:)`: the microphone only ever starts from the
/// app's own intent, never from a link).
struct VoiceNoteLockWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.samrabbit.lock.note", provider: TalkProvider()) { _ in
            VoiceNoteLockFace()
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("Voice Note")
        .description("Records a quick voice note; your Mac files it.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular])
    }
}

struct VoiceNoteLockFace: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryRectangular: VoiceNoteRectangularFace()
        default: VoiceNoteCircularFace()
        }
    }
}

/// While a voice note records (the screen may be locked): the timer and Stop on the Lock Screen and in the Dynamic
/// Island; then what the Mac did, for a few seconds. Tapping it opens the recorder (a link: it never starts one).
struct CaptureLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CaptureActivityAttributes.self) { context in
            CaptureActivityLockFace(state: context.state, startedAt: context.attributes.startedAt,
                                    limit: context.attributes.limit)
                .activityBackgroundTint(Color(hex: 0x120A12).opacity(0.88))
                .activitySystemActionForegroundColor(SamTheme.orbPale)
                .widgetURL(URL(string: PendingRoute.capture))
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: state.symbol)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(state.color)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(state.color.opacity(0.16)))
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if state.phase == .recording { CaptureStopButton(size: 38).padding(.trailing, 4) }
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(state.word).font(.system(size: 15.5, weight: .semibold)).foregroundStyle(state.color)
                            CaptureClock(state: state, startedAt: context.attributes.startedAt,
                                         limit: context.attributes.limit)
                                .font(.system(size: 13, weight: .medium).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Text("Voice note").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if state.phase != .recording, !state.line.isEmpty {
                        Text(state.line)
                            .font(.system(size: 13.5))
                            .foregroundStyle(SamTheme.ink2)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                    }
                }
            } compactLeading: {
                Image(systemName: state.phase == .recording ? "record.circle" : state.symbol)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(state.color)
            } compactTrailing: {
                CaptureClock(state: state, startedAt: context.attributes.startedAt, limit: context.attributes.limit)
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .frame(maxWidth: 44)
                    .foregroundStyle(state.color)
            } minimal: {
                Image(systemName: state.phase == .recording ? "record.circle" : state.symbol)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(state.color)
            }
            .widgetURL(URL(string: PendingRoute.capture))
            .keylineTint(state.color)
        }
    }
}
