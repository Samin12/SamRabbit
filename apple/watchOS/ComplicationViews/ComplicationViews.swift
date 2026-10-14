import SamRabbitKit
import SwiftUI
import WidgetKit

// The complication faces, shared by the watch widget extension and the watch app (which renders
// them for previews with `-SamRabbitRenderComplications`). Every view takes a `ComplicationSnapshot`.

/// What a complication shows.
struct ComplicationSnapshot: Sendable {
    var date: Date
    var summary: MobileSummary?
    /// When the shown summary was fetched.
    var fetchedAt: Date?
    var paired: Bool

    static func sample(_ date: Date = .now) -> ComplicationSnapshot {
        ComplicationSnapshot(date: date, summary: .sample(now: date), fetchedAt: date, paired: true)
    }

    /// Older than 45 minutes: shown dimmed, the counts may be out of date.
    var stale: Bool { (fetchedAt.map { date.timeIntervalSince($0) } ?? .infinity) > 45 * 60 }
    var needsYou: Int { summary?.t3.needsYou ?? 0 }
    var working: Int { summary?.t3.working ?? 0 }
    var next: CalendarEvent? { summary?.nextEvent(after: date) }
    /// Today's morning brief, if the Mac has one.
    var brief: BriefingOverview? {
        guard let brief = summary?.briefing, brief.current(now: date) else { return nil }
        return brief
    }

    /// "Standup in 25m", "Standup now".
    func eventLine(_ event: CalendarEvent) -> String {
        if event.isNow(date) { return "\(event.title) now" }
        return "\(event.title) \(Formatting.until(event.startsAt, end: event.endsAt, now: date, short: true))"
    }
}

/// accessoryCircular: the needs-you count in a ring (the ring fills with what needs you out of
/// everything open).
struct NeedsYouCircularComplication: View {
    let snapshot: ComplicationSnapshot

    var body: some View {
        let needs = snapshot.needsYou
        let total = max(needs + snapshot.working, 1)
        Gauge(value: Double(snapshot.paired ? needs : 0), in: 0...Double(total)) {
            Image(systemName: "hand.raised.fill")
        } currentValueLabel: {
            VStack(spacing: -2) {
                Text(snapshot.paired ? "\(needs)" : "–")
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.6)
                Image(systemName: needs > 0 ? "hand.raised.fill" : "checkmark")
                    .font(.system(size: 8, weight: .bold))
            }
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .tint(needs > 0 ? SamTheme.amber : SamTheme.green)
        .widgetAccentable()
        .opacity(snapshot.stale ? 0.6 : 1)
        .accessibilityLabel(snapshot.paired ? "\(needs) need you" : "SamRabbit not paired")
    }
}

/// accessoryCorner: the count in the corner and the next event (or what is working) along the bezel.
struct NeedsYouCornerComplication: View {
    let snapshot: ComplicationSnapshot

    var body: some View {
        let needs = snapshot.needsYou
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: -3) {
                Text(snapshot.paired ? "\(needs)" : "–")
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .foregroundStyle(needs > 0 ? SamTheme.amber : SamTheme.green)
                    .widgetAccentable()
                Image(systemName: needs > 0 ? "hand.raised.fill" : "checkmark")
                    .font(.system(size: 7, weight: .bold))
            }
        }
        .widgetLabel {
            Text(cornerLine)
                .foregroundStyle(SamTheme.orbPale)
        }
        .accessibilityLabel("\(needs) need you. \(cornerLine)")
    }

    var cornerLine: String {
        guard snapshot.paired else { return "Pair on iPhone" }
        if let next = snapshot.next { return Formatting.clip(snapshot.eventLine(next), 22) }
        return snapshot.working > 0 ? "\(snapshot.working) working" : "All clear"
    }
}

/// accessoryRectangular: the next event, and how many tasks are working / need you.
struct NextUpRectangularComplication: View {
    let snapshot: ComplicationSnapshot

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                if !snapshot.paired {
                    Text("SamRabbit").font(.system(size: 15, weight: .semibold)).widgetAccentable()
                    Text("Pair on your iPhone").font(.system(size: 13)).foregroundStyle(.secondary)
                } else if let next = snapshot.next {
                    HStack(spacing: 4) {
                        Image(systemName: "calendar").font(.system(size: 11, weight: .bold))
                        Text(next.isNow(snapshot.date) ? "Now" : Formatting.time(next.startsAt, allDay: next.allDay))
                            .font(.system(size: 13, weight: .semibold))
                        Text(next.isNow(snapshot.date) ? "" : Formatting.until(next.startsAt, end: next.endsAt,
                                                                               now: snapshot.date, short: true))
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(SamTheme.orbPale)
                    .widgetAccentable()
                    Text(next.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                } else {
                    Text("SamRabbit").font(.system(size: 15, weight: .semibold)).foregroundStyle(SamTheme.orbPale)
                        .widgetAccentable()
                    Text("Nothing else today").font(.system(size: 14)).lineLimit(1)
                }
                if snapshot.paired {
                    HStack(spacing: 8) {
                        Label("\(snapshot.working) working", systemImage: "circle.dotted.circle")
                            .foregroundStyle(SamTheme.cyan)
                        if snapshot.needsYou > 0 {
                            Label("\(snapshot.needsYou)", systemImage: "hand.raised.fill")
                                .foregroundStyle(SamTheme.amber)
                        }
                    }
                    .font(.system(size: 12.5, weight: .medium))
                    .labelStyle(CompactLabelStyle())
                    .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(snapshot.stale ? 0.6 : 1)
    }
}

/// accessoryInline: one line of text on the face.
struct StatusInlineComplication: View {
    let snapshot: ComplicationSnapshot

    var body: some View {
        if !snapshot.paired {
            Label("SamRabbit", systemImage: "circle.hexagongrid.fill")
        } else if snapshot.needsYou > 0 {
            // The longest line that fits the face's slot.
            ViewThatFits {
                Label("\(snapshot.needsYou) need you · \(snapshot.working) working", systemImage: "hand.raised.fill")
                Label("\(snapshot.needsYou) need you", systemImage: "hand.raised.fill")
            }
        } else if let next = snapshot.next {
            Label(Formatting.clip(snapshot.eventLine(next), 24), systemImage: "calendar")
        } else {
            Label("\(snapshot.working) working", systemImage: "circle.dotted.circle")
        }
    }
}

/// accessoryCircular: a mic: tap to record a voice note.
struct VoiceNoteCircularComplication: View {
    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Image(systemName: "waveform.badge.mic")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(SamTheme.red)
                Text("Note").font(.system(size: 10, weight: .semibold))
            }
            .widgetAccentable()
        }
        .accessibilityLabel("Record a voice note")
    }
}

/// accessoryCorner: the mic in the corner, "Voice note" along the bezel.
struct VoiceNoteCornerComplication: View {
    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(SamTheme.red)
                .widgetAccentable()
        }
        .widgetLabel { Text("Voice note").foregroundStyle(SamTheme.orbPale) }
        .accessibilityLabel("Record a voice note")
    }
}

/// accessoryRectangular: "☀ 3 to do" and the headline of today's brief.
struct BriefRectangularComplication: View {
    let snapshot: ComplicationSnapshot

    var body: some View {
        let brief = snapshot.brief
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Image(systemName: "sun.max.fill").font(.system(size: 11, weight: .bold))
                Text(brief.map { $0.needsYou > 0 ? $0.countLine : "Brief done" } ?? "Morning brief")
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(SamTheme.amber)
            .widgetAccentable()
            Text(line(brief))
                .font(.system(size: 13.5))
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(snapshot.stale ? 0.6 : 1)
    }

    private func line(_ brief: BriefingOverview?) -> String {
        guard snapshot.paired else { return "Pair on your iPhone" }
        guard let brief else { return "Ready by 7:00" }
        return brief.headline.isEmpty ? (brief.needsYou > 0 ? "Open to see it" : "Nothing waits for you") : brief.headline
    }
}

/// accessoryInline: "☀ 3 to do · 4 meetings".
struct BriefInlineComplication: View {
    let snapshot: ComplicationSnapshot

    var body: some View {
        if let brief = snapshot.brief {
            Label(brief.needsYou > 0 ? brief.countLine : "Brief done", systemImage: "sun.max.fill")
        } else {
            Label("Morning brief", systemImage: "sun.max.fill")
        }
    }
}

/// Icon and title close together (for small complications).
struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.system(size: 10, weight: .bold))
            configuration.title
        }
    }
}
