import SwiftUI

/// How the orb behaves: calm when idle, livelier while tasks run, liveliest while the R1 is in a
/// voice conversation, dim when the Mac is out of reach.
public enum OrbMood: String, Sendable, CaseIterable {
    case idle
    case working
    case live
    case attention
    case offline

    public var energy: Double {
        switch self {
        case .idle: 0.12
        case .working: 0.26
        case .live: 0.36
        case .attention: 0.2
        case .offline: 0.05
        }
    }

    /// Time multiplier.
    public var speed: Double {
        switch self {
        case .idle: 1.0
        case .working: 1.45
        case .live: 2.0
        case .attention: 1.2
        case .offline: 0.45
        }
    }

    public var glow: Double {
        switch self {
        case .idle: 0.9
        case .working: 1.0
        case .live: 1.15
        case .attention: 1.0
        case .offline: 0.45
        }
    }

    public var base: OrbRenderer.RGB {
        switch self {
        case .offline: OrbRenderer.RGB(hex: 0x4F5F7D)
        default: OrbRenderer.blue
        }
    }

    /// The mood a summary calls for (every agent's counts when the summary carries the inbox's).
    public static func from(_ summary: MobileSummary?, reachable: Bool = true) -> OrbMood {
        guard reachable, let summary else { return .offline }
        if summary.r1.live { return .live }
        if summary.needsYouCount > 0 { return .attention }
        if summary.workingCount > 0 { return .working }
        return .idle
    }
}

/// The animated SamRabbit orb. The view's frame is the orb's diameter; the halo spills outside
/// it (like the R1 and desktop orbs), so give it room. `animated: false` draws one still frame
/// (widgets, complications, snapshots).
public struct OrbView: View {
    public var mood: OrbMood
    public var animated: Bool
    public var halo: Bool
    /// A fixed moment for still frames (the app icon uses 2.0).
    public var phase: Double
    /// Frames per second while animated (the watch uses fewer).
    public var frameRate: Double
    /// 0...1: a live input level (the watch's voice capture). The orb swells and its waves stir with it.
    public var level: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    @State private var start = Date()

    public init(mood: OrbMood = .idle, animated: Bool = true, halo: Bool = true, phase: Double = 7.3,
                frameRate: Double = 30, level: Double = 0) {
        self.mood = mood
        self.animated = animated
        self.halo = halo
        self.phase = phase
        self.frameRate = frameRate
        self.level = min(1, max(0, level.isFinite ? level : 0))
    }

    private var energy: Double { mood.energy + level * 0.75 }

    public var body: some View {
        GeometryReader { geometry in
            let diameter = min(geometry.size.width, geometry.size.height)
            ZStack {
                if halo { OrbHalo(mood: mood, radius: diameter / 2, boost: level) }
                if animated, !reduceMotion {
                    TimelineView(.animation(minimumInterval: 1.0 / max(1, frameRate))) { context in
                        let t = phase + context.date.timeIntervalSince(start) * mood.speed
                        OrbDisc(mood: mood, energy: energy, time: t, diameter: diameter, scale: displayScale)
                    }
                } else {
                    OrbDisc(mood: mood, energy: energy, time: phase, diameter: diameter, scale: displayScale)
                }
            }
            .scaleEffect(1 + level * 0.14)
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

/// The orb's surface for one moment.
struct OrbDisc: View {
    var mood: OrbMood
    var energy: Double
    var time: Double
    var diameter: CGFloat
    var scale: CGFloat

    var body: some View {
        // About one sample per point (the surface is soft); bilinear filtering does the rest.
        let size = diameter * min(scale, 3) * 0.42
        let samples = size.isFinite ? Int(min(176, max(40, size))) : 40
        Group {
            if let image = OrbRenderer.field(pixels: samples, time: time, energy: energy, base: mood.base) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
            } else {
                Circle().fill(Color(red: 0.1, green: 0.45, blue: 0.95))
            }
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
    }
}

/// The soft glow under the orb (same falloff as the shader: flat to 35%, then two ramps).
struct OrbHalo: View {
    var mood: OrbMood
    var radius: CGFloat
    /// 0...1: a live level brightens and widens the glow.
    var boost: Double = 0

    var body: some View {
        let glowRadius = radius * (1.55 + mood.energy * 0.25 + boost * 0.3)
        let base = Color(red: Double(mood.base.r), green: Double(mood.base.g), blue: Double(mood.base.b))
        let g = mood.glow * (1 + boost * 0.6)
        Circle()
            .fill(RadialGradient(stops: [
                .init(color: base.opacity(0.431 * g), location: 0),
                .init(color: base.opacity(0.431 * g), location: 0.35),
                .init(color: base.opacity(0.133 * g), location: 0.7),
                .init(color: base.opacity(0), location: 1),
            ], center: .center, startRadius: 0, endRadius: glowRadius))
            .frame(width: glowRadius * 2, height: glowRadius * 2)
            .offset(y: radius * 0.25)
            .allowsHitTesting(false)
    }
}

#Preview("Orb moods") {
    VStack(spacing: 40) {
        HStack(spacing: 50) {
            OrbView(mood: .idle).frame(width: 90)
            OrbView(mood: .working).frame(width: 90)
        }
        HStack(spacing: 50) {
            OrbView(mood: .live).frame(width: 90)
            OrbView(mood: .offline).frame(width: 90)
        }
    }
    .padding(60)
    .background(SamTheme.background)
}
