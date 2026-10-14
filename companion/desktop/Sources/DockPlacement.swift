import CoreGraphics
import Foundation

// Where the Agent Dock sits and how big it draws. Pure maths on plain rectangles (AppKit's screen coordinates:
// origin bottom-left, y up), so tests/swift can pin it without a screen.
//
// - It rests at the bottom centre of a screen, 14 pt above the visible frame (so above the Dock), and can be dragged
//   along that edge and onto other screens.
// - Where Samin leaves it is remembered as {screen identity, x fraction}, never as a desktop point: plugging a monitor
//   in or out moves every screen's coordinates, and a remembered point would make it jump.
// - Its size follows the width of the screen it is on (a laptop's ~1728 pt is 1x; a 32" or an ultrawide draws it
//   bigger) times Samin's own zoom (⌘+/⌘− or dragging an end of the pill). The expanded panel follows only half of
//   that, because a list is read a line at a time.

/// One screen, as the dock needs it.
struct DockScreen: Equatable {
    let id: String
    let frame: CGRect
    let visibleFrame: CGRect
}

/// The remembered place: which screen, and where along its bottom edge (0 = left, 1 = right; the pill's centre).
struct DockSpot: Codable, Equatable {
    var screenId: String
    var xFraction: Double
}

enum DockMetrics {
    static let baselineWidth: CGFloat = 1728
    static let pillBaseHeight: CGFloat = 44
    static let panelBaseWidth: CGFloat = 440
    static let bottomGap: CGFloat = 14
    static let panelGap: CGFloat = 8
    static let sideMargin: CGFloat = 8
    static let zoomRange: ClosedRange<Double> = 0.75...1.6
    static let zoomStep = 0.1

    /// The automatic scale for a screen this many points wide: 1 on a laptop, growing by 40% of the extra width
    /// ratio (≈1.17 on 2560, ≈1.33 on a 3200 pt ultrawide), never below 0.9 or above 1.4.
    static func screenScale(width: CGFloat) -> CGFloat {
        guard width.isFinite, width > 0 else { return 1 }
        let raw = 1 + (width - baselineWidth) / baselineWidth * 0.4
        return (min(1.4, max(0.9, raw)) * 100).rounded() / 100
    }

    /// Samin's own multiple, kept sane (nothing stored = 1).
    static func zoom(_ value: Double?) -> Double {
        guard let value, value.isFinite else { return 1 }
        return min(zoomRange.upperBound, max(zoomRange.lowerBound, (value * 20).rounded() / 20))
    }

    static func zoomStepped(_ value: Double?, by steps: Int) -> Double {
        zoom(zoom(value) + Double(steps) * zoomStep)
    }

    /// The one number the pill multiplies everything by. Chosen so the pill's height is a whole number of points
    /// (a fractional height puts its bottom edge on half a pixel, where it goes soft).
    static func pillScale(screenWidth: CGFloat, zoom: Double?) -> CGFloat {
        let height = pillHeight(screenWidth: screenWidth, zoom: zoom)
        return height / pillBaseHeight
    }

    static func pillHeight(screenWidth: CGFloat, zoom: Double?) -> CGFloat {
        (pillBaseHeight * screenScale(width: screenWidth) * CGFloat(Self.zoom(zoom))).rounded()
    }

    /// The panel follows the pill half the way, between 0.85 and 1.25.
    static func panelScale(pillScale: CGFloat) -> CGFloat {
        let raw = 1 + (pillScale - 1) * 0.5
        return (min(1.25, max(0.85, raw)) * 1000).rounded() / 1000
    }

    /// The zoom a drag on one end of the pill means: the pill's height follows the pointer up (and outwards, at a
    /// third), the way a window corner does.
    static func zoomFromDrag(startZoom: Double, startHeight: CGFloat, up dy: CGFloat, outward dx: CGFloat) -> Double {
        guard startHeight > 0 else { return zoom(startZoom) }
        let height = max(24, startHeight + dy + dx * 0.35)
        return zoom(startZoom * Double(height / startHeight))
    }
}

enum DockPlacement {
    static func screen(containing point: CGPoint, in screens: [DockScreen]) -> DockScreen? {
        screens.first { $0.frame.contains(point) }
            ?? screens.min { distance(point, $0.frame) < distance(point, $1.frame) }
    }

    /// Where the pill goes when it appears: the remembered screen when it is connected, else the screen the pointer is
    /// on; at the remembered fraction, else centred.
    static func home(spot: DockSpot?, pointer: CGPoint, screens: [DockScreen]) -> (screen: DockScreen, xFraction: Double)? {
        if let spot, let screen = screens.first(where: { $0.id == spot.screenId }) {
            return (screen, clampFraction(spot.xFraction))
        }
        guard let screen = screen(containing: pointer, in: screens) else { return nil }
        return (screen, clampFraction(spot?.xFraction ?? 0.5))
    }

    /// The pill's frame (its window is exactly the pill) for its size on a screen at a fraction.
    static func pillFrame(size: CGSize, screen: DockScreen, xFraction: Double) -> CGRect {
        let visible = screen.visibleFrame
        let centre = visible.minX + CGFloat(clampFraction(xFraction)) * visible.width
        let x = clampX(centre - size.width / 2, width: size.width, in: visible)
        return CGRect(x: x, y: visible.minY + DockMetrics.bottomGap, width: size.width, height: size.height).integral
    }

    /// The fraction a frame stands at on its screen (the inverse of pillFrame).
    static func fraction(of frame: CGRect, on screen: DockScreen) -> Double {
        let visible = screen.visibleFrame
        guard visible.width > 0 else { return 0.5 }
        return clampFraction(Double((frame.midX - visible.minX) / visible.width))
    }

    /// The pill keeps its bottom centre when its size changes (a count grows, the voice bar opens), so it never
    /// walks away from where it was left; it is still kept on its screen.
    static func resized(_ frame: CGRect, to size: CGSize, on screen: DockScreen) -> CGRect {
        let x = clampX(frame.midX - size.width / 2, width: size.width, in: screen.visibleFrame)
        return CGRect(x: x, y: screen.visibleFrame.minY + DockMetrics.bottomGap, width: size.width, height: size.height).integral
    }

    /// While dragging: the pill follows the pointer sideways, stays on the bottom edge of whichever screen the pointer
    /// is on, and never leaves that screen.
    static func dragged(from start: CGRect, dx: CGFloat, pointer: CGPoint, screens: [DockScreen]) -> (frame: CGRect, screen: DockScreen)? {
        guard let screen = screen(containing: pointer, in: screens) else { return nil }
        let visible = screen.visibleFrame
        var x = start.minX + dx
        // Crossing onto another screen whose coordinates don't overlap: follow the pointer instead.
        if !(visible.minX...visible.maxX).contains(start.midX + dx) { x = pointer.x - start.width / 2 }
        x = clampX(x, width: start.width, in: visible)
        let frame = CGRect(x: x, y: visible.minY + DockMetrics.bottomGap, width: start.width, height: start.height).integral
        return (frame, screen)
    }

    /// The tallest the expanded panel may be above this pill: 60% of the screen, and never past the top of the
    /// visible frame.
    static func maxPanelHeight(pill: CGRect, screen: DockScreen) -> CGFloat {
        let room = screen.visibleFrame.maxY - DockMetrics.sideMargin - (pill.maxY + DockMetrics.panelGap)
        return max(120, min(screen.frame.height * 0.6, room)).rounded(.down)
    }

    /// The expanded panel: above the pill, centred on it, kept on the screen.
    static func panelFrame(size: CGSize, pill: CGRect, screen: DockScreen) -> CGRect {
        let visible = screen.visibleFrame
        let height = min(size.height, maxPanelHeight(pill: pill, screen: screen))
        let x = clampX(pill.midX - size.width / 2, width: size.width, in: visible)
        return CGRect(x: x, y: pill.maxY + DockMetrics.panelGap, width: size.width, height: height).integral
    }

    // MARK: helpers

    private static func clampFraction(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 0.5
    }

    private static func clampX(_ x: CGFloat, width: CGFloat, in visible: CGRect) -> CGFloat {
        let low = visible.minX + DockMetrics.sideMargin
        let high = visible.maxX - DockMetrics.sideMargin - width
        return high < low ? visible.midX - width / 2 : min(high, max(low, x))
    }

    private static func distance(_ point: CGPoint, _ rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return hypot(dx, dy)
    }
}
