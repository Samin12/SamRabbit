import SamRabbitKit
import SwiftUI

/// The morning brief at the top of Home until noon (Hark-style: what needs you first, and the verb is the button):
/// the headline, then Do first with each item's verbs (Draft reply, Make task, Block, Remind, Open) and Done /
/// Dismiss, Today's events (conflicts flagged), the Agents waiting and, folded, FYI. A verb resolves the item with a
/// tap: Draft reply saves a Gmail draft (never sent) and opens it; the item says what happened.
struct MorningSection: View {
    @Environment(AppModel.self) private var model
    @State private var showFYI = false

    var body: some View {
        if let brief = model.briefing, model.showsBriefing {
            VStack(spacing: 12) {
                header(brief)
                let first = brief.items(in: .doFirst) + brief.items(in: .agents)
                ForEach(first) { item in
                    BriefItemCard(item: item)
                        .id(item.id)
                }
                let today = brief.items(in: .today)
                if !today.isEmpty { todayCard(today) }
                let fyi = brief.items(in: .fyi)
                if !fyi.isEmpty { fyiCard(fyi) }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("home-brief")
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    // MARK: - Header

    private func header(_ brief: Briefing) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(SamTheme.amber)
                Text("MORNING BRIEF")
                    .font(SamTheme.eyebrow)
                    .tracking(0.6)
                    .foregroundStyle(SamTheme.amber.opacity(0.9))
                if let at = brief.updatedAt {
                    Text(Formatting.time(at)).font(.system(size: 11.5)).foregroundStyle(SamTheme.faint)
                }
                Spacer(minLength: 6)
                if brief.toDo > 0 {
                    Text("\(brief.toDo) to do")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(SamTheme.amber)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(SamTheme.amber.opacity(0.15)))
                }
                Button {
                    Task { await model.refreshBriefing() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(SamTheme.muted)
                        .frame(width: 28, height: 28)
                        .rotationEffect(.degrees(model.briefingRefreshing ? 360 : 0))
                        .animation(model.briefingRefreshing ? .linear(duration: 1).repeatForever(autoreverses: false)
                                   : .default, value: model.briefingRefreshing)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Build the brief again")
                .accessibilityIdentifier("brief-refresh")
            }
            Text(brief.headline.isEmpty ? "Good morning" : brief.headline)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(SamTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("brief-headline")
            if brief.status == .stale {
                Label("From yesterday: today's isn't ready yet.", systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 12.5))
                    .foregroundStyle(SamTheme.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .id("brief")
    }

    // MARK: - Today

    private func todayCard(_ items: [BriefingItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("Today", systemImage: "calendar")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SamTheme.muted)
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 4)
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { Divider().overlay(SamTheme.line).padding(.leading, 74) }
                BriefEventRow(item: item)
            }
        }
        .glassCard(padding: 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("brief-today")
    }

    // MARK: - FYI

    private func fyiCard(_ items: [BriefingItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.smooth) { showFYI.toggle() }
            } label: {
                HStack {
                    Label("FYI · \(items.count)", systemImage: "info.circle")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SamTheme.muted)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(SamTheme.faint)
                        .rotationEffect(.degrees(showFYI ? 180 : 0))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("brief-fyi")
            if showFYI {
                ForEach(items) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Circle().fill(SamTheme.faint).frame(width: 5, height: 5).padding(.top, 7)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title).font(.system(size: 14.5, weight: .semibold)).foregroundStyle(SamTheme.ink2)
                            if !item.why.isEmpty {
                                Text(item.why).font(.system(size: 12.5)).foregroundStyle(SamTheme.muted)
                            }
                        }
                        Spacer(minLength: 0)
                        BriefCircleButton(item: item, kind: .dismiss)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.white.opacity(0.035)))
    }
}

/// A Do-first or Agents item: what to do (verb first), why, its suggestion, the verbs, and Done / Dismiss.
struct BriefItemCard: View {
    @Environment(AppModel.self) private var model
    let item: BriefingItem

    var body: some View {
        let busy = model.busyBriefItems.contains(item.id)
        let handled = item.state != .open
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: Self.symbol(item))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint.opacity(0.15)))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.title)
                            .font(.system(size: 16.5, weight: .semibold))
                            .foregroundStyle(SamTheme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        if let tag = item.accountTag {
                            Text(tag.uppercased())
                                .font(.system(size: 9.5, weight: .bold))
                                .tracking(0.4)
                                .foregroundStyle(SamTheme.violet)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(SamTheme.violet.opacity(0.15)))
                        }
                    }
                    if !item.why.isEmpty {
                        Text(item.why)
                            .font(.system(size: 14))
                            .foregroundStyle(SamTheme.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let suggestion = item.suggestion, !handled {
                        Label(suggestion, systemImage: "lightbulb")
                            .font(.system(size: 12.5))
                            .foregroundStyle(SamTheme.muted)
                            .padding(.top, 1)
                    }
                }
                Spacer(minLength: 0)
            }
            if let label = item.state.label {
                HStack(spacing: 8) {
                    Label(label, systemImage: "checkmark.circle.fill")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(SamTheme.mint)
                        .accessibilityIdentifier("brief-state-\(item.id)")
                    if let draft = item.draftUrl {
                        Link("Open draft", destination: draft)
                            .font(.system(size: 13.5, weight: .semibold))
                    }
                    Spacer()
                }
            }
            HStack(spacing: 8) {
                if !handled {
                    ForEach(Array(item.verbs.enumerated()), id: \.element.id) { index, verb in
                        BriefVerbButton(item: item, verb: verb, prominent: index == 0)
                    }
                }
                Spacer(minLength: 0)
                BriefCircleButton(item: item, kind: .done)
                BriefCircleButton(item: item, kind: .dismiss)
            }
            .disabled(busy)
        }
        .glassCard(radius: 22, tint: handled ? SamTheme.mint.opacity(0.5) : tint, padding: 14)
        .opacity(busy ? 0.6 : handled ? 0.82 : 1)
        .animation(.smooth, value: busy)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("brief-item-\(item.id)")
    }

    private var tint: Color {
        switch item.section {
        case .agents: SamTheme.violet
        case .doFirst: item.priority <= 1 ? SamTheme.amber : SamTheme.orbPale
        case .today: SamTheme.accent
        case .fyi: SamTheme.faint
        }
    }

    static func symbol(_ item: BriefingItem) -> String {
        switch item.kind.lowercased() {
        case "event": "calendar"
        case "conflict": "exclamationmark.triangle.fill"
        case "agent": "sparkles"
        case "fyi": "info.circle"
        default: "envelope.fill"
        }
    }
}

/// A verb as a button ("Draft reply", "Make task", "Block 45 min", "Remind 2 pm", "Open").
struct BriefVerbButton: View {
    @Environment(AppModel.self) private var model
    let item: BriefingItem
    let verb: BriefingAction
    var prominent = false

    var body: some View {
        if prominent {
            button.buttonStyle(.glassProminent).tint(SamTheme.orb)
        } else {
            button.buttonStyle(.glass)
        }
    }

    private var button: some View {
        Button {
            Haptics.tap()
            Task { await model.act(on: item, verb) }
        } label: {
            Label(verb.label, systemImage: verb.symbol)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
        }
        .controlSize(.regular)
        .accessibilityIdentifier("brief-\(verb.kind.wire)-\(item.id)")
    }
}

/// Done (a check) or Dismiss (an x), small and round at the end of an item.
struct BriefCircleButton: View {
    @Environment(AppModel.self) private var model
    let item: BriefingItem
    let kind: BriefingAction.Kind

    var body: some View {
        Button {
            Task { await model.act(on: item, BriefingAction(kind)) }
        } label: {
            Image(systemName: kind == .done ? "checkmark" : "xmark")
                .font(.system(size: 12.5, weight: .bold))
                .foregroundStyle(kind == .done ? SamTheme.mint : SamTheme.muted)
                .frame(width: 34, height: 34)
                .background(Circle().fill((kind == .done ? SamTheme.mint : Color.white).opacity(kind == .done ? 0.15 : 0.07)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(kind == .done ? "Done" : "Dismiss")
        .accessibilityIdentifier("brief-\(kind.wire)-\(item.id)")
    }
}

/// An event of Today: its time, title, why (a conflict in amber) and its verb (Block prep).
struct BriefEventRow: View {
    @Environment(AppModel.self) private var model
    let item: BriefingItem

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(Formatting.time(item.startsAt))
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(SamTheme.ink)
                if let start = item.startsAt {
                    Text(Formatting.until(start, end: item.endsAt, short: true))
                        .font(.system(size: 11.5))
                        .foregroundStyle(SamTheme.faint)
                }
            }
            .lineLimit(1)
            .frame(width: 62, alignment: .trailing)
            RoundedRectangle(cornerRadius: 2).fill(item.conflict ? SamTheme.amber : SamTheme.accent)
                .frame(width: 3, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(SamTheme.ink).lineLimit(1)
                if item.conflict {
                    Label(item.why.isEmpty ? "Overlaps another event" : item.why, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12.5))
                        .foregroundStyle(SamTheme.amber)
                        .lineLimit(1)
                } else if let label = item.state.label {
                    Text(label).font(.system(size: 12.5)).foregroundStyle(SamTheme.mint).lineLimit(1)
                } else if !item.why.isEmpty {
                    Text(item.why).font(.system(size: 12.5)).foregroundStyle(SamTheme.muted).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if item.state == .open, let verb = item.verbs.first {
                Button {
                    Task { await model.act(on: item, verb) }
                } label: {
                    Text(verb.label).font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .disabled(model.busyBriefItems.contains(item.id))
                .accessibilityIdentifier("brief-\(verb.kind.wire)-\(item.id)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
    }
}
