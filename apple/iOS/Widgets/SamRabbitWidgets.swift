import ActivityKit
import AppIntents
import SamRabbitKit
import SwiftUI
import WidgetKit

@main
struct SamRabbitWidgetsBundle: WidgetBundle {
    var body: some Widget {
        StatusWidget()
        TasksWidget()
        UpNextWidget()
        DashboardWidget()
        NeedsYouLockWidget()
        NextEventLockWidget()
        AskControl()
        TaskLiveActivity()
        TalkControl()
        TalkLockWidget()
        TalkLiveActivity()
    }
}

// MARK: - Data

struct SummaryEntry: TimelineEntry {
    let snapshot: WidgetSnapshot
    var date: Date { snapshot.date }
}

/// Reads the summary the app last saved in the App Group, fetches a fresh one itself (token from
/// the shared Keychain), and asks to be refreshed every 15 minutes.
struct SummaryProvider: TimelineProvider {
    func placeholder(in context: Context) -> SummaryEntry { SummaryEntry(snapshot: .sample()) }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (SummaryEntry) -> Void) {
        if context.isPreview {
            completion(SummaryEntry(snapshot: .sample()))
            return
        }
        completion(SummaryEntry(snapshot: Self.cached()))
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<SummaryEntry>) -> Void) {
        Task {
            let snapshot = await Self.fresh()
            let next = Date.now.addingTimeInterval(15 * 60)
            completion(Timeline(entries: [SummaryEntry(snapshot: snapshot)], policy: .after(next)))
        }
    }

    static func cached(now: Date = .now) -> WidgetSnapshot {
        let account = BridgeAccount.shared
        let entry = SummaryCache.shared.load()
        return WidgetSnapshot(date: now, summary: entry?.summary, fetchedAt: entry?.savedAt, paired: account.pairing != nil)
    }

    static func fresh() async -> WidgetSnapshot {
        let account = BridgeAccount.shared
        guard account.pairing != nil, let client = account.client() else { return cached() }
        do {
            // The inbox beside the summary, so the counts and rows cover every agent on the Mac.
            async let inbox = BridgeError.capture { try await client.inbox(timeout: 8) }
            let fresh = try await client.summary(timeout: 8)
            let summary = fresh.with(inbox: await inbox, kept: SummaryCache.shared.load()?.summary.inbox)
            SummaryCache.shared.save(summary)
            return WidgetSnapshot(date: .now, summary: summary, fetchedAt: .now, paired: true)
        } catch {
            return cached()
        }
    }
}

// MARK: - Home Screen

struct StatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.samrabbit.status", provider: SummaryProvider()) { entry in
            WidgetChrome(standalone: false) { StatusSmallFace(snapshot: entry.snapshot) }
                .widgetURL(URL(string: "samrabbit://tab/home"))
        }
        .configurationDisplayName("SamRabbit")
        .description("The orb, what needs you and what is working.")
        .supportedFamilies([.systemSmall])
    }
}

struct TasksWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.samrabbit.tasks", provider: SummaryProvider()) { entry in
            WidgetChrome(standalone: false) { TasksMediumFace(snapshot: entry.snapshot) }
                .widgetURL(URL(string: "samrabbit://tab/tasks"))
        }
        .configurationDisplayName("Tasks")
        .description("Your T3 Code, Claude Code and Codex work: what needs you first.")
        .supportedFamilies([.systemMedium])
    }
}

struct UpNextWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.samrabbit.upnext", provider: SummaryProvider()) { entry in
            WidgetChrome(standalone: false) { UpNextMediumFace(snapshot: entry.snapshot) }
                .widgetURL(URL(string: "samrabbit://tab/home"))
        }
        .configurationDisplayName("Up Next")
        .description("Your next events, and a button that blocks the next 30 minutes.")
        .supportedFamilies([.systemMedium])
    }
}

struct DashboardWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.samrabbit.dashboard", provider: SummaryProvider()) { entry in
            WidgetChrome(standalone: false) { DashboardLargeFace(snapshot: entry.snapshot) }
                .widgetURL(URL(string: "samrabbit://tab/home"))
        }
        .configurationDisplayName("Dashboard")
        .description("R1, your next event, tasks and the latest conversation, with Ask and Block.")
        .supportedFamilies([.systemLarge])
    }
}

// MARK: - Lock Screen

struct NeedsYouLockWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.samrabbit.lock.needs", provider: SummaryProvider()) { entry in
            LockFace(snapshot: entry.snapshot)
                .containerBackground(for: .widget) { Color.clear }
                .widgetURL(URL(string: "samrabbit://tab/tasks"))
        }
        .configurationDisplayName("Needs You")
        .description("How many tasks wait for you.")
        .supportedFamilies([.accessoryCircular, .accessoryInline])
    }
}

struct NextEventLockWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.samrabbit.lock.next", provider: SummaryProvider()) { entry in
            NextEventRectangularFace(snapshot: entry.snapshot)
                .containerBackground(for: .widget) { Color.clear }
                .widgetURL(URL(string: "samrabbit://tab/home"))
        }
        .configurationDisplayName("Next Up")
        .description("Your next event and how many tasks are working.")
        .supportedFamilies([.accessoryRectangular])
    }
}

struct LockFace: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: WidgetSnapshot

    var body: some View {
        switch family {
        case .accessoryInline: InlineFace(snapshot: snapshot)
        default: NeedsYouCircularFace(snapshot: snapshot)
        }
    }
}

// MARK: - Control Center, Lock Screen and Action Button

/// "Ask SamRabbit": opens the app at Ask with dictation listening. iOS offers every control for the
/// Action Button too (Settings > Action Button > Controls > SamRabbit). Pressing and holding the
/// button shows "Hold to Ask SamRabbit".
struct AskControl: ControlWidget {
    static let kind = "com.samrabbit.control.ask"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OpenAskIntent()) {
                Label("Ask SamRabbit", systemImage: "sparkles")
                    .controlWidgetActionHint("Ask SamRabbit")
            }
        }
        .displayName("Ask SamRabbit")
        .description("Opens SamRabbit with the microphone on, ready for a new task.")
    }
}

// MARK: - Live Activity

struct TaskLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TaskActivityAttributes.self) { context in
            TaskActivityLockView(context: context)
                .activityBackgroundTint(Color(hex: 0x0B1324).opacity(0.85))
                .activitySystemActionForegroundColor(SamTheme.orbPale)
                .widgetURL(URL(string: "samrabbit://thread/\(context.attributes.threadId)"))
        } dynamicIsland: { context in
            let style = StatusStyle(context.state.status)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    OrbView(mood: context.state.status == .working ? .working : .idle, animated: false, halo: false)
                        .frame(width: 36, height: 36)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    StatusChip(context.state.status, compact: true).padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                        Text(context.attributes.projectName).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(context.state.detail).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(2)
                        Spacer()
                        Text(context.attributes.startedAt, style: .timer)
                            .font(.system(size: 13, weight: .medium).monospacedDigit())
                            .frame(width: 56, alignment: .trailing)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                Image(systemName: style.symbol).foregroundStyle(style.color)
            } compactTrailing: {
                Text(context.attributes.startedAt, style: .timer)
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .frame(maxWidth: 44)
                    .foregroundStyle(style.color)
            } minimal: {
                Image(systemName: style.symbol).foregroundStyle(style.color)
            }
            .widgetURL(URL(string: "samrabbit://thread/\(context.attributes.threadId)"))
            .keylineTint(style.color)
        }
    }
}

struct TaskActivityLockView: View {
    let context: ActivityViewContext<TaskActivityAttributes>

    var body: some View {
        let style = StatusStyle(context.state.status)
        HStack(spacing: 14) {
            OrbView(mood: context.state.status == .working ? .working : .idle, animated: false)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(context.attributes.title).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                }
                Text(context.state.detail).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(2)
                HStack(spacing: 6) {
                    StatusChip(context.state.status)
                    Text(context.attributes.projectName).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if context.state.status == .working {
                Text(context.attributes.startedAt, style: .timer)
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(style.color)
                    .frame(width: 60, alignment: .trailing)
            }
        }
        .padding(16)
    }
}
