import AppIntents
import SamRabbitKit
import SwiftUI
import WidgetKit

// The morning brief outside the app: its Home Screen widget (medium and large, with Done and Dismiss right on the
// items) and the Lock Screen's rectangle ("3 to do" and the headline). Shared by the widget extension and the app
// (the gallery and the render harness). They draw `summary.briefing`: the bridge's headline and count, with the
// first open items the iPhone put in.

extension WidgetSnapshot {
    /// Today's brief, if the Mac has one.
    var brief: BriefingOverview? {
        guard let brief = summary?.briefing, brief.current(now: date) else { return nil }
        return brief
    }
}

/// The sun and "Morning brief · 7:01".
struct BriefingHeader: View {
    let brief: BriefingOverview?
    var size: CGFloat = 15

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "sun.max.fill")
                .font(.system(size: size - 2, weight: .bold))
                .foregroundStyle(SamTheme.amber)
                .widgetAccentable()
            Text("Morning brief").font(.system(size: size, weight: .semibold)).foregroundStyle(SamTheme.ink)
            if let at = brief?.updatedAt {
                Text(Formatting.time(at)).font(.system(size: size - 3.5)).foregroundStyle(SamTheme.faint)
            }
            Spacer(minLength: 4)
            if let brief, brief.needsYou > 0 {
                Text(brief.countLine)
                    .font(.system(size: size - 3, weight: .bold, design: .rounded))
                    .foregroundStyle(SamTheme.amber)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(SamTheme.amber.opacity(0.16)))
            }
        }
    }
}

/// One item: its verb-first title, why, Dismiss and Done, which run in the background.
struct BriefingWidgetRow: View {
    let item: BriefingItem

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Self.tint(item))
                .frame(width: 3, height: 30)
                .widgetAccentable()
            Link(destination: URL(string: "samrabbit://brief/\(item.id)") ?? URL(string: "samrabbit://brief")!) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(SamTheme.ink)
                        .lineLimit(1)
                    Text(item.state.label ?? item.why)
                        .font(.system(size: 11.5))
                        .foregroundStyle(item.state == .open ? SamTheme.muted : SamTheme.mint)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button(intent: BriefingItemIntent(itemId: item.id, action: .dismiss)) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(SamTheme.muted)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.white.opacity(0.07)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
            Button(intent: BriefingItemIntent(itemId: item.id, action: .done)) {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(SamTheme.mint)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(SamTheme.mint.opacity(0.16)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Done")
        }
    }

    static func tint(_ item: BriefingItem) -> Color {
        switch item.section {
        case .doFirst: item.priority <= 1 ? SamTheme.amber : SamTheme.orbPale
        case .today: SamTheme.accent
        case .agents: SamTheme.violet
        case .fyi: SamTheme.faint
        }
    }
}

/// No brief today (yet), or nothing left in it.
struct BriefingEmptyLine: View {
    let brief: BriefingOverview?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: brief == nil ? "moon.zzz.fill" : "checkmark.circle.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(brief == nil ? SamTheme.faint : SamTheme.mint)
            VStack(alignment: .leading, spacing: 1) {
                Text(brief == nil ? "No brief yet" : "All done for this morning")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(SamTheme.ink)
                Text(brief == nil ? "It's ready by 7:00 each morning." : "Nothing in the brief waits for you.")
                    .font(.system(size: 12))
                    .foregroundStyle(SamTheme.muted)
            }
        }
    }
}

/// Medium: the headline and the first two items, each with Dismiss and Done.
struct BriefingMediumFace: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        if !snapshot.paired {
            UnpairedFace()
        } else {
            let brief = snapshot.brief
            let items = Array((brief?.items ?? []).prefix(2))
            VStack(alignment: .leading, spacing: 8) {
                BriefingHeader(brief: brief)
                if let brief, !items.isEmpty {
                    Text(brief.headline)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(SamTheme.ink2)
                        .lineLimit(1)
                    VStack(spacing: 7) {
                        ForEach(items) { BriefingWidgetRow(item: $0) }
                    }
                    Spacer(minLength: 0)
                } else {
                    Spacer(minLength: 0)
                    BriefingEmptyLine(brief: brief)
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// Large: the headline and up to four items with Done and Dismiss, and what's next on the calendar.
struct BriefingLargeFace: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        if !snapshot.paired {
            UnpairedFace()
        } else {
            let brief = snapshot.brief
            let items = Array((brief?.items ?? []).prefix(4))
            VStack(alignment: .leading, spacing: 11) {
                BriefingHeader(brief: brief, size: 16)
                if let brief, !items.isEmpty {
                    Text(brief.headline)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(SamTheme.ink)
                        .lineLimit(2)
                    VStack(spacing: 9) {
                        ForEach(items) { BriefingWidgetRow(item: $0) }
                    }
                } else {
                    Spacer(minLength: 0)
                    BriefingEmptyLine(brief: brief)
                }
                Spacer(minLength: 0)
                if let next = snapshot.nextEvents.first {
                    WidgetEventRow(event: next, now: snapshot.date, highlight: true)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.05)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// Lock Screen, rectangular: "☀ 3 to do" and the headline.
struct BriefingRectangularFace: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        let brief = snapshot.brief
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                Image(systemName: "sun.max.fill").font(.system(size: 12, weight: .bold))
                Text(brief.map { $0.needsYou > 0 ? $0.countLine : "Brief done" } ?? "Morning brief")
                    .font(.system(size: 15, weight: .semibold))
            }
            .widgetAccentable()
            Text(brief?.headline.isEmpty == false ? brief!.headline : brief == nil ? "Ready by 7:00" : "Nothing waits for you")
                .font(.system(size: 13))
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
