import ActivityKit
import AppIntents
import SamRabbitKit
import SwiftUI
import WidgetKit

// Talk (the live conversation with SamRabbit) from outside the app: the Control Center / Lock Screen / Action
// Button control, the Lock Screen widget and the Live Activity while it runs.

/// "Talk to SamRabbit": opens SamRabbit straight into a live conversation. iOS offers every control for the Action
/// Button too (Settings > Action Button > Controls > SamRabbit > Talk to SamRabbit).
struct TalkControl: ControlWidget {
    static let kind = "com.samrabbit.control.talk"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: TalkToSamRabbitIntent()) {
                Label("Talk to SamRabbit", systemImage: "waveform")
                    .controlWidgetActionHint("Talk to SamRabbit")
            }
        }
        .displayName("Talk to SamRabbit")
        .description("Opens SamRabbit in a live voice conversation.")
    }
}

/// The Lock Screen's Talk button: opens SamRabbit in a live conversation (`samrabbit://talk`).
struct TalkLockWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.samrabbit.lock.talk", provider: TalkProvider()) { _ in
            TalkLockFace()
                .containerBackground(for: .widget) { Color.clear }
                .widgetURL(URL(string: PendingRoute.talk))
        }
        .configurationDisplayName("Talk")
        .description("Opens SamRabbit in a live voice conversation.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular])
    }
}

struct TalkLockFace: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryRectangular: TalkRectangularFace()
        default: TalkCircularFace()
        }
    }
}

/// The Talk button never changes: one entry, never refreshed.
struct TalkProvider: TimelineProvider {
    struct Entry: TimelineEntry {
        var date: Date
    }

    func placeholder(in context: Context) -> Entry { Entry(date: .now) }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (Entry) -> Void) {
        completion(Entry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<Entry>) -> Void) {
        completion(Timeline(entries: [Entry(date: .now)], policy: .never))
    }
}

/// While a conversation runs: the Lock Screen and the Dynamic Island show what it is doing and its last line, with
/// End. Tapping it opens Talk.
struct TalkLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TalkActivityAttributes.self) { context in
            TalkActivityLockFace(state: context.state, startedAt: context.attributes.startedAt)
                .activityBackgroundTint(Color(hex: 0x0B1324).opacity(0.88))
                .activitySystemActionForegroundColor(SamTheme.orbPale)
                .widgetURL(URL(string: PendingRoute.talk))
        } dynamicIsland: { context in
            let phase = context.state.phase
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    OrbView(mood: phase.mood, animated: false, halo: false)
                        .frame(width: 40, height: 40)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    TalkEndButton(size: 38).padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(phase.word)
                            .font(.system(size: 15.5, weight: .semibold))
                            .foregroundStyle(phase.color)
                        Text("SamRabbit")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if !context.state.line.isEmpty {
                        Text(context.state.line)
                            .font(.system(size: 13.5))
                            .foregroundStyle(SamTheme.ink2)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                    }
                }
            } compactLeading: {
                OrbView(mood: phase.mood, animated: false, halo: false)
                    .frame(width: 22, height: 22)
            } compactTrailing: {
                HStack(spacing: 4) {
                    Image(systemName: phase.symbol)
                        .font(.system(size: 11, weight: .bold))
                    Text(phase.short)
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(phase.color)
            } minimal: {
                Image(systemName: phase.symbol)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(phase.color)
            }
            .widgetURL(URL(string: PendingRoute.talk))
            .keylineTint(phase.color)
        }
    }
}
