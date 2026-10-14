import SamRabbitKit
import SwiftUI

/// Page 2 in the morning: today's brief. The headline, then what to do first (and the agents waiting), each with
/// its first verb and Done; today's events; FYI. A draft reply is saved in Gmail, never sent (open it on the iPhone).
/// Shown only while there is a brief with something in it.
struct BriefPage: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                if let brief = model.briefing {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 4) {
                            Image(systemName: "sun.max.fill").font(.system(size: 11, weight: .bold))
                            Text(brief.toDo > 0 ? "\(brief.toDo) to do" : "Morning brief")
                                .font(.system(size: 12.5, weight: .semibold))
                            Spacer(minLength: 2)
                            if let at = brief.updatedAt {
                                Text(Formatting.time(at)).font(.system(size: 11)).foregroundStyle(SamTheme.muted)
                            }
                        }
                        .foregroundStyle(SamTheme.amber)
                        Text(brief.headline.isEmpty ? "Good morning" : brief.headline)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(SamTheme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("brief-headline")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    ForEach(brief.items(in: .doFirst) + brief.items(in: .agents)) { item in
                        BriefCard(item: item)
                    }
                    let today = brief.items(in: .today)
                    if !today.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(today) { item in
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text(Formatting.time(item.startsAt))
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(item.conflict ? SamTheme.amber : SamTheme.orbPale)
                                    Text(item.title).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                                    if item.conflict {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .font(.system(size: 10)).foregroundStyle(SamTheme.amber)
                                    }
                                }
                            }
                        }
                        .watchCard(tint: SamTheme.accent, padding: 9)
                    }
                    let fyi = brief.items(in: .fyi)
                    if !fyi.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("FYI").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(SamTheme.muted)
                            ForEach(fyi) { item in
                                Text(item.title).font(.system(size: 12.5)).foregroundStyle(SamTheme.ink2).lineLimit(2)
                            }
                        }
                        .watchCard(padding: 9)
                    }
                } else {
                    EmptyNote(symbol: "sun.max", title: "No brief yet", detail: "It's ready by 7:00.")
                }
            }
            .padding(.horizontal, 2)
        }
        .navigationTitle("Brief")
        .withBanner()
        .samPage(SamTheme.amber)
    }
}

/// One item: the title, why, its first verb (when the watch can do it) and Done.
struct BriefCard: View {
    @Environment(WatchModel.self) private var model
    let item: BriefingItem

    var body: some View {
        let busy = model.busy.contains(item.id)
        VStack(alignment: .leading, spacing: 5) {
            Text(item.title)
                .font(.system(size: 14.5, weight: .semibold))
                .foregroundStyle(SamTheme.ink)
                .lineLimit(3)
            if !item.why.isEmpty {
                Text(item.why).font(.system(size: 12)).foregroundStyle(SamTheme.ink2).lineLimit(3)
            }
            if let label = item.state.label {
                Label(label, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SamTheme.mint)
            }
            HStack(spacing: 6) {
                if item.state == .open, let verb = item.verbs.first(where: { $0.kind != .open }) {
                    Button {
                        Task { await model.briefAct(item, verb.kind) }
                    } label: {
                        Text(verb.label).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                            .minimumScaleFactor(0.8).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(SamTheme.orb)
                    .accessibilityIdentifier("brief-verb-\(item.id)")
                }
                Button {
                    Task { await model.briefAct(item, .done) }
                } label: {
                    Image(systemName: "checkmark").font(.system(size: 13, weight: .bold))
                }
                .buttonStyle(.bordered)
                .tint(SamTheme.mint)
                .frame(width: item.state == .open && item.verbs.contains { $0.kind != .open } ? 44 : nil)
                .frame(maxWidth: item.state == .open && item.verbs.contains { $0.kind != .open } ? nil : .infinity)
                .accessibilityLabel("Done")
                .accessibilityIdentifier("brief-done-\(item.id)")
            }
            .disabled(busy)
        }
        .watchCard(tint: item.section == .agents ? SamTheme.violet : SamTheme.amber, padding: 9)
        .opacity(busy ? 0.6 : 1)
    }
}
