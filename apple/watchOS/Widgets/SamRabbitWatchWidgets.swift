import SamRabbitKit
import SwiftUI
import WidgetKit

@main
struct SamRabbitWatchWidgetsBundle: WidgetBundle {
    var body: some Widget {
        NeedsYouComplication()
        NextUpComplication()
        WatchAskControl()
        WatchVoiceNoteControl()
        VoiceNoteComplication()
        BriefComplication()
    }
}

// MARK: - Control (Action Button, Control Center, Smart Stack)

/// "Ask SamRabbit" on the watch: opens the watch app straight into a live conversation. On Apple
/// Watch Ultra: Settings > Action Button > Action > Control, then Control (says "Configure" until
/// set) > SamRabbit > Ask SamRabbit. A single press then runs it. It runs on the watch (the iPhone's control opens the iPhone app, so watchOS
/// doesn't offer that one here).
struct WatchAskControl: ControlWidget {
    static let kind = "com.samrabbit.watch.control.ask"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OpenSamRabbitWatchIntent(.ask)) {
                Label("Ask SamRabbit", systemImage: "sparkles")
                    .controlWidgetActionHint("Ask SamRabbit")
            }
        }
        .displayName("Ask SamRabbit")
        .description("Opens SamRabbit on your watch, ready to talk.")
    }
}

/// "Voice Note" on the watch: opens the watch app straight into the recorder, recording; it sends itself when he
/// pauses (or Stop, or a double tap), and says nothing back. On Apple Watch Ultra: Settings > Action Button >
/// Action > Control, then Control > SamRabbit > Voice Note. Pressed again while it records: stop and send.
struct WatchVoiceNoteControl: ControlWidget {
    static let kind = "com.samrabbit.watch.control.note"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OpenSamRabbitWatchIntent(.note)) {
                Label("Voice Note", systemImage: "waveform.badge.mic")
                    .controlWidgetActionHint("Record a voice note")
            }
        }
        .displayName("Voice Note")
        .description("Records a quick voice note on your watch; your Mac files it.")
    }
}

// MARK: - Data

struct ComplicationEntry: TimelineEntry {
    let snapshot: ComplicationSnapshot
    var date: Date { snapshot.date }
}

/// Reads the summary the watch app last saved in the App Group and fetches a fresh one itself
/// (directly: WatchConnectivity isn't available to complications). One timeline holds an entry
/// every 5 minutes for the next hour, so "in 25m" stays right; it is refreshed every 15 minutes
/// and whenever the watch app changes something.
struct ComplicationProvider: TimelineProvider {
    func placeholder(in context: Context) -> ComplicationEntry { ComplicationEntry(snapshot: .sample()) }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (ComplicationEntry) -> Void) {
        if context.isPreview {
            completion(ComplicationEntry(snapshot: .sample()))
            return
        }
        completion(ComplicationEntry(snapshot: Self.cached()))
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<ComplicationEntry>) -> Void) {
        Task {
            let base = await Self.fresh()
            let entries = (0..<12).map { step -> ComplicationEntry in
                var snapshot = base
                snapshot.date = base.date.addingTimeInterval(TimeInterval(step) * 300)
                return ComplicationEntry(snapshot: snapshot)
            }
            completion(Timeline(entries: entries, policy: .after(.now.addingTimeInterval(15 * 60))))
        }
    }

    static func cached(now: Date = .now) -> ComplicationSnapshot {
        let entry = SummaryCache.shared.load()
        return ComplicationSnapshot(date: now, summary: entry?.summary, fetchedAt: entry?.savedAt,
                                    paired: BridgeAccount.shared.pairing != nil)
    }

    static func fresh() async -> ComplicationSnapshot {
        let account = BridgeAccount.shared
        guard account.pairing != nil, let client = account.client() else { return cached() }
        do {
            let summary = try await client.summary(timeout: 8)
            SummaryCache.shared.save(summary)
            return ComplicationSnapshot(date: .now, summary: summary, fetchedAt: .now, paired: true)
        } catch {
            return cached()
        }
    }
}

// MARK: - Widgets

/// The needs-you count: a ring (circular), the count with the next event along the bezel
/// (corner), or one line (inline). Tapping it opens the conversation (like every way into the app).
struct NeedsYouComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.samrabbit.watch.needs", provider: ComplicationProvider()) { entry in
            NeedsYouFace(snapshot: entry.snapshot)
                .containerBackground(for: .widget) { Color.clear }
                .widgetURL(URL(string: "samrabbit://talk"))
        }
        .configurationDisplayName("Needs You")
        .description("How many tasks wait for you.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryInline])
    }
}

/// The next event and what is working.
struct NextUpComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.samrabbit.watch.next", provider: ComplicationProvider()) { entry in
            NextUpRectangularComplication(snapshot: entry.snapshot)
                .containerBackground(for: .widget) { Color.clear }
                .widgetURL(URL(string: "samrabbit://talk"))
        }
        .configurationDisplayName("Next Up")
        .description("Your next event and how many tasks are working.")
        .supportedFamilies([.accessoryRectangular])
    }
}

/// A tap that records a voice note (the recorder opens recording).
struct VoiceNoteComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.samrabbit.watch.note", provider: ComplicationProvider()) { _ in
            VoiceNoteFace()
                .containerBackground(for: .widget) { Color.clear }
                .widgetURL(URL(string: PendingRoute.capture))
        }
        .configurationDisplayName("Voice Note")
        .description("Tap to record a voice note; your Mac files it.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner])
    }
}

/// Today's morning brief: how much of it waits for you, and its headline. Opens the Brief page.
struct BriefComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.samrabbit.watch.brief", provider: ComplicationProvider()) { entry in
            BriefFace(snapshot: entry.snapshot)
                .containerBackground(for: .widget) { Color.clear }
                .widgetURL(URL(string: "samrabbit://tab/brief"))
        }
        .configurationDisplayName("Morning Brief")
        .description("How much of today's brief waits for you, and its headline.")
        .supportedFamilies([.accessoryRectangular, .accessoryInline])
    }
}

struct VoiceNoteFace: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCorner: VoiceNoteCornerComplication()
        default: VoiceNoteCircularComplication()
        }
    }
}

struct BriefFace: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: ComplicationSnapshot

    var body: some View {
        switch family {
        case .accessoryInline: BriefInlineComplication(snapshot: snapshot)
        default: BriefRectangularComplication(snapshot: snapshot)
        }
    }
}

struct NeedsYouFace: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: ComplicationSnapshot

    var body: some View {
        switch family {
        case .accessoryCorner: NeedsYouCornerComplication(snapshot: snapshot)
        case .accessoryInline: StatusInlineComplication(snapshot: snapshot)
        default: NeedsYouCircularComplication(snapshot: snapshot)
        }
    }
}

#Preview("Circular", as: .accessoryCircular) {
    NeedsYouComplication()
} timeline: {
    ComplicationEntry(snapshot: .sample())
}

#Preview("Rectangular", as: .accessoryRectangular) {
    NextUpComplication()
} timeline: {
    ComplicationEntry(snapshot: .sample())
}
