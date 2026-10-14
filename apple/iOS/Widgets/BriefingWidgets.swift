import SamRabbitKit
import SwiftUI
import WidgetKit

// The morning brief's widgets: the Home Screen (medium, large; Done and Dismiss run in the background) and the Lock
// Screen's rectangle. Fed by the same summary as the other widgets (`SummaryProvider`), which carries the brief's
// headline, count and first open items.

struct BriefingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.samrabbit.briefing", provider: SummaryProvider()) { entry in
            WidgetChrome(standalone: false) { BriefingFace(snapshot: entry.snapshot) }
                .widgetURL(URL(string: "samrabbit://brief"))
        }
        .configurationDisplayName("Morning Brief")
        .description("Today's brief from your email, calendar and agents, with Done and Dismiss.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct BriefingFace: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: WidgetSnapshot

    var body: some View {
        switch family {
        case .systemLarge: BriefingLargeFace(snapshot: snapshot)
        default: BriefingMediumFace(snapshot: snapshot)
        }
    }
}

struct BriefingLockWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.samrabbit.lock.briefing", provider: SummaryProvider()) { entry in
            BriefingRectangularFace(snapshot: entry.snapshot)
                .containerBackground(for: .widget) { Color.clear }
                .widgetURL(URL(string: "samrabbit://brief"))
        }
        .configurationDisplayName("Morning Brief")
        .description("How much of today's brief waits for you, and its headline.")
        .supportedFamilies([.accessoryRectangular])
    }
}
