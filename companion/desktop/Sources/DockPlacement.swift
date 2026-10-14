import CoreGraphics
import Foundation

// Where the Agent Dock sits and how big it draws. Pure maths on plain rectangles (AppKit's screen coordinates:
// origin bottom-left, y up), so tests/swift can pin it without a screen.
//
// - It rests at the bottom centre of a screen, 14 pt above the visible frame (so above the Dock), until Samin drags it
//   somewhere else: anywhere on any screen, always wholly inside the visible frame (never under the menu bar or the
//   Dock), soft-snapping to an edge, a corner or the middle of the top or bottom edge when it comes within 16 pt.
// - Where he leaves it is remembered per screen as {nearest corner, gap from it}, never as a desktop point (Agentbox's
//   lesson): plugging a monitor in or out moves every screen's coordinates, and a remembered point would make it
//   jump, while "bottom right, 8 pt in" means the same on any screen. While the screen it was left on is not
//   connected, the screen the pointer is on lends it a place (that screen's own spot, else the same corner and gap).
// - When it changes size (the counts, the orb, the voice bar) the edges nearest its corner stay put.
// - The list opens on the side with room (above a low dock, below a high one), lined up with the dock's outer edge.
// - Its size follows the width of the screen it is on (a laptop's ~1728 pt is 1x; a 32" or an ultrawide draws it
//   bigger) times Samin's own zoom (⌘+/⌘− or dragging an end of the pill). The expanded panel follows only half of
//   that, because a list is read a line at a time.

/// One screen, as the dock needs it.
struct DockScreen: Equatable {
    let id: String
    let frame: CGRect
    let visibleFrame: CGRect
}

/// A corner of a screen's visible frame, or the middle of its bottom or top edge (where the dock rests until it is
/// moved, and where a drag snaps to when it passes the middle).
enum DockCorner: String, Codable, CaseIterable {
    case bottomLeft, bottom, bottomRight, topLeft, top, topRight

    enum Side: Equatable {
        case left, middle, right
    }

    var isTop: Bool { self == .topLeft || self == .top || self == .topRight }

    var side: Side {
        switch self {
        case .bottomLeft, .topLeft: return .left
        case .bottom, .top: return .middle
        case .bottomRight, .topRight: return .right
        }
    }

    static func make(top: Bool, side: Side) -> DockCorner {
        switch side {
        case .left: return top ? .topLeft : .bottomLeft
        case .middle: return top ? .top : .bottom
        case .right: return top ? .topRight : .bottomRight
        }
    }
}

/// Where the dock rests on one screen: its corner, and the gaps from that corner to the dock's own nearest edges
/// (`dx` in from the side, or for the middle of an edge how far the dock's centre is right of the middle; `dy` up from
/// the bottom or down from the top of the visible frame).
struct DockSpot: Codable, Equatable {
    var corner: DockCorner
    var dx: CGFloat
    var dy: CGFloat

    /// Until Samin moves it: the middle of the bottom edge, 14 pt up (above the Dock).
    static let home = DockSpot(corner: .bottom, dx: 0, dy: DockMetrics.bottomGap)
}

/// Everything remembered about where the dock is: the screen it was left on, and its spot on each screen it has been
/// left on. Nothing remembered (nil) = never moved: bottom centre of the screen the pointer was last on.
struct DockPlace: Codable, Equatable {
    var screenId: String
    var spots: [String: DockSpot]

    var spot: DockSpot { spots[screenId] ?? .home }
}

/// Wave 6's memory, {screen, x fraction along the bottom edge}: read once and turned into a DockPlace.
struct DockLegacySpot: Codable, Equatable {
    var screenId: String
    var xFraction: Double
}

/// The few UserDefaults calls the dock's memory makes (UserDefaults has them all), so tests/swift can run them on a
/// dictionary instead of the app's settings.
protocol DockDefaults: AnyObject {
    func data(forKey key: String) -> Data?
    func bool(forKey key: String) -> Bool
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
}

extension UserDefaults: DockDefaults {}

/// Where the dock was left, as the app keeps it: `AgentDockPlace` (a DockPlace, JSON), and Wave 6's `AgentDockSpot`
/// turned into one at the first launch that finds it. That happens once (`AgentDockPlaceMigrated`): the old key stays
/// for an older copy to read, and "Move Back to the Middle" (no place) must not bring the old spot back next launch.
struct DockPlaceMemory {
    static let placeKey = "AgentDockPlace"
    static let legacyKey = "AgentDockSpot"
    static let migratedKey = "AgentDockPlaceMigrated"

    let defaults: DockDefaults

    /// nil: never moved, or "Move Back to the Middle".
    var place: DockPlace? {
        get { defaults.data(forKey: Self.placeKey).flatMap { try? JSONDecoder().decode(DockPlace.self, from: $0) } }
        nonmutating set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: Self.placeKey) }
            else { defaults.removeObject(forKey: Self.placeKey) }
        }
    }

    /// At launch: Wave 6's spot as a corner and a gap, the first time only, and only when there is no place yet (a
    /// pill of about `size`, on `screens` as they are now). The place it made, or nil when there was nothing to do.
    @discardableResult
    func migrate(size: CGSize, screens: [DockScreen]) -> DockPlace? {
        guard !defaults.bool(forKey: Self.migratedKey) else { return nil }
        defaults.set(true, forKey: Self.migratedKey)
        guard place == nil, let data = defaults.data(forKey: Self.legacyKey),
              let legacy = try? JSONDecoder().decode(DockLegacySpot.self, from: data) else { return nil }
        let converted = DockPlacement.migrated(legacy, size: size, screens: screens)
        place = converted
        return converted
    }
}

enum DockMetrics {
    static let baselineWidth: CGFloat = 1728
    static let pillBaseHeight: CGFloat = 44
    static let panelBaseWidth: CGFloat = 440
    /// The minimized dock: a glass circle this big at 1x, with room above and to the right for the count badge.
    static let orbBaseSize: CGFloat = 36
    static let orbBadgeRoom: CGFloat = 5
    static let bottomGap: CGFloat = 14
    /// The gap a drag snaps to at the sides and the top.
    static let edgeGap: CGFloat = 8
    /// How close to an edge, a corner or the middle a drag has to come to snap there.
    static let snapReach: CGFloat = 16
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

    /// Where the dock goes when it appears: on the screen it was left on when that is connected; else on the screen
    /// the pointer is on, at that screen's own spot when it has one, else at the same corner and gap; never moved:
    /// the middle of the bottom edge of the pointer's screen.
    static func home(place: DockPlace?, pointer: CGPoint, screens: [DockScreen]) -> (screen: DockScreen, spot: DockSpot)? {
        if let place, let screen = screens.first(where: { $0.id == place.screenId }) {
            return (screen, place.spot)
        }
        guard let screen = screen(containing: pointer, in: screens) else { return nil }
        return (screen, place?.spots[screen.id] ?? place?.spot ?? .home)
    }

    /// The dock's frame (its window is exactly the dock) for a spot on a screen: wholly inside the visible frame,
    /// however small the screen and wherever the spot came from.
    static func frame(for spot: DockSpot, size: CGSize, on screen: DockScreen) -> CGRect {
        let visible = screen.visibleFrame
        let dx = spot.dx.isFinite ? spot.dx : 0
        let dy = spot.dy.isFinite ? spot.dy : DockMetrics.bottomGap
        let x: CGFloat
        switch spot.corner.side {
        case .left: x = visible.minX + dx
        case .middle: x = visible.midX + dx - size.width / 2
        case .right: x = visible.maxX - dx - size.width
        }
        let y = spot.corner.isTop ? visible.maxY - dy - size.height : visible.minY + dy
        return clamped(CGRect(x: x, y: y, width: size.width, height: size.height), in: visible)
    }

    /// The spot a frame stands at (the inverse of frame(for:)): the nearest corner by halves of the visible frame, or
    /// the middle of the edge when the dock is centred on it.
    static func spot(for frame: CGRect, on screen: DockScreen) -> DockSpot {
        let visible = screen.visibleFrame
        let top = frame.midY > visible.midY
        let side: DockCorner.Side
        if abs(frame.midX - visible.midX) <= 1 {
            side = .middle
        } else {
            side = frame.midX > visible.midX ? .right : .left
        }
        let dx: CGFloat
        switch side {
        case .left: dx = frame.minX - visible.minX
        case .middle: dx = 0
        case .right: dx = visible.maxX - frame.maxX
        }
        let dy = top ? visible.maxY - frame.maxY : frame.minY - visible.minY
        return DockSpot(corner: .make(top: top, side: side), dx: dx, dy: dy)
    }

    /// Samin left the dock at `spot` on `screen`: that is now the screen it lives on, and its spot there.
    static func remember(_ spot: DockSpot, on screen: DockScreen, in place: DockPlace?) -> DockPlace {
        var spots = place?.spots ?? [:]
        spots[screen.id] = spot
        return DockPlace(screenId: screen.id, spots: spots)
    }

    /// ⌃⌥D on another screen brings the dock to it: at its own spot there if it was ever left there, else at the same
    /// corner and gap as now. A dock that was never moved stays unremembered (it follows the pointer anyway).
    static func bringing(_ place: DockPlace?, current: DockSpot, to screen: DockScreen) -> (place: DockPlace?, spot: DockSpot) {
        guard let place else { return (nil, current) }
        let spot = place.spots[screen.id] ?? current
        return (remember(spot, on: screen, in: place), spot)
    }

    /// The dock keeps its corner and gap when its size changes (a count grows, the orb opens into the pill, the voice
    /// bar takes over), so it never walks away from the edge it was left against; it is still kept on its screen.
    static func resized(_ frame: CGRect, to size: CGSize, on screen: DockScreen) -> CGRect {
        self.frame(for: spot(for: frame, on: screen), size: size, on: screen)
    }

    /// While dragging: the dock follows the pointer anywhere, onto whichever screen the pointer is on, stays wholly
    /// inside that screen's visible frame, and snaps to an edge, a corner or the middle when it comes close.
    static func dragged(from start: CGRect, dx: CGFloat, dy: CGFloat, pointer: CGPoint, screens: [DockScreen]) -> (frame: CGRect, screen: DockScreen)? {
        guard let screen = screen(containing: pointer, in: screens) else { return nil }
        var moved = start.offsetBy(dx: dx, dy: dy)
        // Onto a screen that doesn't line up with the one it left (one higher than the other): wherever the moved
        // frame would be, it stays under the pointer on the screen the pointer is on.
        if !screen.visibleFrame.intersects(moved) {
            moved.origin = CGPoint(x: pointer.x - start.width / 2, y: pointer.y - start.height / 2)
        }
        let kept = clamped(moved, in: screen.visibleFrame)
        return (snapped(kept, on: screen), screen)
    }

    /// Within `snapReach` of an edge (or of the middle of the screen, sideways) the dock jumps to it: 8 pt in from the
    /// sides and the top, 14 pt above the bottom (the Dock's side), or centred.
    static func snapped(_ frame: CGRect, on screen: DockScreen) -> CGRect {
        let visible = screen.visibleFrame
        let xs = [visible.minX + DockMetrics.edgeGap, visible.maxX - DockMetrics.edgeGap - frame.width,
                  (visible.midX - frame.width / 2).rounded()]
        let ys = [visible.minY + DockMetrics.bottomGap, visible.maxY - DockMetrics.edgeGap - frame.height]
        func nearest(_ value: CGFloat, _ targets: [CGFloat]) -> CGFloat {
            guard let best = targets.min(by: { abs($0 - value) < abs($1 - value) }),
                  abs(best - value) <= DockMetrics.snapReach else { return value }
            return best
        }
        let snapped = CGRect(x: nearest(frame.minX, xs), y: nearest(frame.minY, ys), width: frame.width, height: frame.height)
        return clamped(snapped, in: visible)
    }

    /// Wholly inside `visible` (centred on it when it is bigger), on whole points.
    static func clamped(_ frame: CGRect, in visible: CGRect) -> CGRect {
        func keep(_ value: CGFloat, _ length: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
            guard value.isFinite else { return ((low + high - length) / 2).rounded() }
            if high - low < length { return ((low + high - length) / 2).rounded() }
            return min(high - length, max(low, value)).rounded()
        }
        return CGRect(x: keep(frame.minX, frame.width, visible.minX, visible.maxX),
                      y: keep(frame.minY, frame.height, visible.minY, visible.maxY),
                      width: frame.width, height: frame.height)
    }

    // MARK: the "–" on the pill

    /// The "–" appears at the end of the pill away from the side of the screen it is kept against (left of a pill on
    /// the right half), so the pill grows into the screen and nothing under the pointer moves.
    static func minimizeOnLeft(_ frame: CGRect, on screen: DockScreen) -> Bool {
        spot(for: frame, on: screen).corner.side == .right
    }

    /// The pill's window while the "–" shows: its resting frame plus the button's width on that side.
    static func withSlot(_ rest: CGRect, width: CGFloat, onLeft: Bool, on screen: DockScreen) -> CGRect {
        guard width > 0 else { return rest }
        let grown = CGRect(x: onLeft ? rest.minX - width : rest.minX, y: rest.minY, width: rest.width + width, height: rest.height)
        return clamped(grown, in: screen.visibleFrame)
    }

    // MARK: the list

    /// The list opens on the side with more room: above a dock in the lower part of the screen, below one near the top.
    static func panelOpensBelow(pill: CGRect, screen: DockScreen) -> Bool {
        let room = rooms(pill: pill, screen: screen)
        return room.below > room.above
    }

    /// The tallest the list may be on that side: 60% of the screen, and never past the visible frame.
    static func maxPanelHeight(pill: CGRect, screen: DockScreen) -> CGFloat {
        let room = rooms(pill: pill, screen: screen)
        let side = room.below > room.above ? room.below : room.above
        return max(120, min(screen.frame.height * 0.6, side)).rounded(.down)
    }

    /// The list's frame: on the side with room, lined up with the dock's outer edge (left edges on the left half of the
    /// screen, right edges on the right, centred on a centred dock), then kept on the screen sideways. A list taller
    /// than its side runs past the screen's edge rather than over the dock.
    static func panelFrame(size: CGSize, pill: CGRect, screen: DockScreen) -> CGRect {
        let visible = screen.visibleFrame
        let height = min(size.height, maxPanelHeight(pill: pill, screen: screen))
        let x: CGFloat
        switch spot(for: pill, on: screen).corner.side {
        case .left: x = pill.minX
        case .middle: x = pill.midX - size.width / 2
        case .right: x = pill.maxX - size.width
        }
        let low = visible.minX + DockMetrics.sideMargin
        let high = visible.maxX - DockMetrics.sideMargin - size.width
        let keptX = high < low ? visible.midX - size.width / 2 : min(high, max(low, x))
        let y = panelOpensBelow(pill: pill, screen: screen)
            ? pill.minY - DockMetrics.panelGap - height
            : pill.maxY + DockMetrics.panelGap
        return CGRect(x: keptX.rounded(), y: y.rounded(), width: size.width, height: height)
    }

    private static func rooms(pill: CGRect, screen: DockScreen) -> (above: CGFloat, below: CGFloat) {
        let visible = screen.visibleFrame
        let above = visible.maxY - DockMetrics.sideMargin - (pill.maxY + DockMetrics.panelGap)
        let below = (pill.minY - DockMetrics.panelGap) - (visible.minY + DockMetrics.sideMargin)
        return (above, below)
    }

    // MARK: Wave 6's memory

    /// The bottom-edge fraction Wave 6 remembered, as a corner and a gap: where the pill stood then (for a pill of
    /// about this size, on that screen, else on the first one), said the new way. Its screen stays its screen.
    static func migrated(_ legacy: DockLegacySpot, size: CGSize, screens: [DockScreen]) -> DockPlace {
        let fraction = legacy.xFraction.isFinite ? min(1, max(0, legacy.xFraction)) : 0.5
        let screen = screens.first { $0.id == legacy.screenId } ?? screens.first
            ?? DockScreen(id: legacy.screenId, frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
                          visibleFrame: CGRect(x: 0, y: 70, width: 1728, height: 1010))
        let visible = screen.visibleFrame
        let centre = visible.minX + CGFloat(fraction) * visible.width
        let low = visible.minX + DockMetrics.sideMargin
        let high = visible.maxX - DockMetrics.sideMargin - size.width
        let x = high < low ? visible.midX - size.width / 2 : min(high, max(low, centre - size.width / 2))
        let then = CGRect(x: x.rounded(), y: visible.minY + DockMetrics.bottomGap, width: size.width, height: size.height)
        return DockPlace(screenId: legacy.screenId, spots: [legacy.screenId: spot(for: then, on: screen)])
    }

    private static func distance(_ point: CGPoint, _ rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return hypot(dx, dy)
    }
}
