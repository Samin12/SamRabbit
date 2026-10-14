import SamRabbitKit
import SwiftUI

/// While a conversation runs with Talk minimized: a bar over the tab bar (the tab view's bottom accessory, like
/// Music's mini player) with the orb, what it is doing and its last line, Mute and End. Tap it for Talk.
struct TalkMiniBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    private let still = UserDefaults.standard.bool(forKey: "SamRabbitStillOrb")

    private var talk: TalkModel { model.talk }

    var body: some View {
        let inline = placement == .inline
        HStack(spacing: inline ? 8 : 11) {
            OrbView(mood: talk.phase == .thinking ? .working : talk.phase == .muted ? .idle : .live,
                    animated: !still, halo: false, frameRate: 20, level: talk.engine.level)
                .frame(width: inline ? 22 : 28, height: inline ? 22 : 28)
            VStack(alignment: .leading, spacing: 0) {
                Text(talk.phase.word)
                    .font(.system(size: inline ? 13 : 14, weight: .semibold))
                    .foregroundStyle(SamTheme.ink)
                    .accessibilityIdentifier("talk-bar-state")
                if !inline, let line = line {
                    Text(line)
                        .font(.system(size: 12))
                        .foregroundStyle(SamTheme.muted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if !inline {
                Button {
                    talk.toggleMute()
                } label: {
                    Image(systemName: talk.engine.micMuted ? "mic.slash.fill" : "mic.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(talk.engine.micMuted ? SamTheme.amber : SamTheme.ink)
                        .frame(width: 34, height: 34)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(talk.engine.micMuted ? "Unmute" : "Mute")
            }
            Button {
                talk.end()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(SamTheme.red.opacity(0.85)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("End")
            .accessibilityIdentifier("talk-bar-end")
        }
        .padding(.leading, inline ? 10 : 12)
        .padding(.trailing, 8)
        .frame(maxHeight: .infinity)
        .contentShape(.rect)
        .onTapGesture { talk.start() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("talk-bar")
        .accessibilityAction(named: "Open Talk") { talk.start() }
    }

    private var line: String? {
        let state = TalkActivityState(talk.machine, muted: talk.engine.micMuted)
        return state.line.isEmpty ? nil : state.line
    }
}

extension View {
    /// The Talk bar over the tab bar while a conversation runs minimized (iOS 26.1's `isEnabled`; on 26.0 it floats
    /// over the tab bar instead).
    @ViewBuilder
    func talkAccessory(_ shown: Bool) -> some View {
        if #available(iOS 26.1, *) {
            tabViewBottomAccessory(isEnabled: shown) { TalkMiniBar() }
        } else {
            overlay(alignment: .bottom) {
                if shown {
                    TalkMiniBar()
                        .frame(height: 52)
                        .glassEffect(.regular, in: .capsule)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 64)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
    }
}
