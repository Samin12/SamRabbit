import SamRabbitKit
import SwiftUI

/// Page 5: one-tap actions: a voice note (it goes as it is; the Mac files it), block the next 30 minutes, a spoken
/// journal note, a new T3 task by voice (the words checked before they go; the conversation on the main page can
/// start tasks too).
struct QuickPage: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                VoiceButton(title: "Voice note", symbol: "waveform.badge.mic", purpose: .capture,
                            colors: [SamTheme.red, Color(hex: 0xD93A5C)], height: 46)
                    .accessibilityIdentifier("voiceNote")

                Button {
                    Task { await model.block(minutes: 30) }
                } label: {
                    CapsuleFace(title: "Block 30m", symbol: "calendar.badge.clock",
                                colors: [SamTheme.violet, Color(hex: 0x5A4BE0)], height: 46,
                                busy: model.busy.contains("block"))
                }
                .buttonStyle(.plain)
                .disabled(model.busy.contains("block"))
                .accessibilityIdentifier("block30")

                VoiceButton(title: "Journal note", symbol: "book.pages.fill", purpose: .note,
                            colors: [Color(hex: 0x3FBFA9), Color(hex: 0x2A9C8A)], height: 46,
                            busy: model.busy.contains("note"))
                    .accessibilityIdentifier("journalNote")

                VoiceButton(title: model.busy.contains("ask") ? "Starting…" : "New task", symbol: "hammer.fill",
                            purpose: .ask, colors: [SamTheme.orb2, SamTheme.orb], height: 46,
                            busy: model.busy.contains("ask"))
                    .accessibilityIdentifier("newTask")

                ConnectionFooter()
                    .padding(.top, 4)

                ActionButtonHint()
            }
            .padding(.horizontal, 2)
        }
        .navigationTitle("Quick")
        .withBanner()
        .samPage(SamTheme.mint)
    }
}

/// Where to set the Watch Ultra's Action Button (an app can't set it): a single press then opens
/// the conversation, already listening.
struct ActionButtonHint: View {
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "button.angledtop.vertical.left")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(SamTheme.orbPale)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text("Action Button").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(SamTheme.ink)
                Text("Settings > Action Button: Action > Control, then Control > Ask SamRabbit (press once to talk) or Voice Note.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(SamTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .watchCard(tint: SamTheme.orb, padding: 9)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("action-button-hint")
    }
}

/// Which Mac, which route and how fresh, with a refresh button.
struct ConnectionFooter: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        Button {
            Task { await model.refresh() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: model.route == .phone ? "iphone" : "laptopcomputer")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(model.lastError == nil ? SamTheme.orbPale : SamTheme.amber)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.account.pairing?.displayName ?? "Your Mac")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(SamTheme.ink2)
                        .lineLimit(1)
                    Text(status).font(.system(size: 11)).foregroundStyle(SamTheme.muted).lineLimit(1)
                }
                Spacer(minLength: 0)
                Group {
                    if model.refreshing {
                        ProgressView().scaleEffect(0.5)
                    } else {
                        Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .semibold)).foregroundStyle(SamTheme.muted)
                    }
                }
                .frame(width: 16, height: 16)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.06)))
        }
        .buttonStyle(.plain)
    }

    private var status: String {
        if let error = model.lastError { return error.shortDescription }
        let route = model.route == .phone ? "via iPhone" : "direct"
        return "\(route) · \(Formatting.ago(model.summaryDate))"
    }
}
