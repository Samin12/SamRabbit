import SwiftUI

/// T3 Code / Claude Code / Codex / SamRabbit as a small drawn tile (SF Symbols and letters, not logos), the Agent
/// Dock's glyphs: "T3" in rounded type, an asterisk for Claude, the code chevrons for Codex, the orb for a chat. A
/// T3 tile carries the model family that runs the thread in its corner. Each mark has its own quiet tint so a
/// glance tells them apart.
public struct SourceGlyph: View {
    public var source: InboxSource
    public var agent: String?
    public var size: CGFloat

    public init(source: InboxSource, agent: String? = nil, size: CGFloat = 28) {
        self.source = source
        self.agent = agent
        self.size = size
    }

    public init(item: InboxItem, size: CGFloat = 28) {
        self.init(source: item.source, agent: item.agent, size: size)
    }

    /// The mark's colour.
    public static func tint(_ source: InboxSource) -> Color {
        switch source {
        case .t3: SamTheme.orbPale
        case .claude: Color(hex: 0xF0A27E)
        case .codex: SamTheme.mint
        case .samrabbit: SamTheme.accent
        case .unknown: SamTheme.ink2
        }
    }

    public var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(LinearGradient(colors: [Self.tint(source).opacity(0.20), Color.white.opacity(0.05)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.75))
            mark.frame(width: size, height: size)
            if source == .t3, let family = Self.family(agent) {
                Image(systemName: family == .codex ? "chevron.left.forwardslash.chevron.right" : "asterisk")
                    .font(.system(size: size * 0.22, weight: .heavy))
                    .foregroundStyle(Self.tint(family))
                    .frame(width: size * 0.46, height: size * 0.46)
                    .background(Circle().fill(Color(hex: 0x1A1F2B)))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.75))
                    .offset(x: size * 0.17, y: size * 0.17)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel(accessibilityText)
    }

    /// "Claude Code", or "T3 Code, run by Codex" for a T3 thread whose model family is known.
    var accessibilityText: String {
        guard source == .t3, let family = Self.family(agent) else { return source.label }
        return "\(source.label), run by \(family == .codex ? "Codex" : "Claude")"
    }

    @ViewBuilder private var mark: some View {
        switch source {
        case .t3:
            Text("T3")
                .font(.system(size: size * 0.38, weight: .heavy, design: .rounded))
                .foregroundStyle(Self.tint(.t3))
        case .claude:
            Image(systemName: "asterisk")
                .font(.system(size: size * 0.44, weight: .bold))
                .foregroundStyle(Self.tint(.claude))
        case .codex:
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: size * 0.34, weight: .bold))
                .foregroundStyle(Self.tint(.codex))
        case .samrabbit:
            OrbView(mood: .idle, animated: false, halo: false).frame(width: size * 0.7, height: size * 0.7)
        case .unknown:
            Image(systemName: "sparkle").font(.system(size: size * 0.42)).foregroundStyle(Self.tint(.unknown))
        }
    }

    /// The model family behind a T3 thread (`agent`).
    static func family(_ agent: String?) -> InboxSource? {
        switch (agent ?? "").lowercased() {
        case "claude": .claude
        case "codex": .codex
        default: nil
        }
    }
}
