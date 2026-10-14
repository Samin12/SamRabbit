import CoreGraphics
import Foundation

enum PlacementTests {
    static let all: [(String, () throws -> Void)] = [
        ("scalesWithTheScreen", scalesWithTheScreen),
        ("zoomIsKeptSane", zoomIsKeptSane),
        ("restsAtTheBottomCentre", restsAtTheBottomCentre),
        ("staysOnItsScreen", staysOnItsScreen),
        ("remembersScreenAndFraction", remembersScreenAndFraction),
        ("survivesMonitorChanges", survivesMonitorChanges),
        ("draggingFollowsThePointer", draggingFollowsThePointer),
        ("resizingKeepsTheBottomCentre", resizingKeepsTheBottomCentre),
        ("panelOpensAboveThePill", panelOpensAboveThePill),
        ("cornerDragZooms", cornerDragZooms),
    ]

    // A laptop (menu bar 37 pt, Dock 70 pt) and a 32" to its right, a little higher.
    static let laptop = DockScreen(id: "laptop", frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
                                   visibleFrame: CGRect(x: 0, y: 70, width: 1728, height: 1010))
    static let big = DockScreen(id: "big", frame: CGRect(x: 1728, y: 200, width: 3200, height: 1350),
                                visibleFrame: CGRect(x: 1728, y: 200, width: 3200, height: 1325))

    static func scalesWithTheScreen() throws {
        expectClose(DockMetrics.screenScale(width: 1728), 1)
        expectClose(DockMetrics.screenScale(width: 1440), 0.93)
        expectClose(DockMetrics.screenScale(width: 2560), 1.19)
        expectClose(DockMetrics.screenScale(width: 3200), 1.34)
        expectClose(DockMetrics.screenScale(width: 6000), 1.4)
        expectClose(DockMetrics.screenScale(width: 800), 0.9)
        expectClose(DockMetrics.screenScale(width: 0), 1)
        expectEqual(DockMetrics.pillHeight(screenWidth: 1728, zoom: nil), 44, "≈44 pt on a laptop")
        expectEqual(DockMetrics.pillHeight(screenWidth: 3200, zoom: nil), 59)
        expectEqual(DockMetrics.pillHeight(screenWidth: 1728, zoom: 1.5), 66)
        // The scale is worked back from a whole-point height.
        let scale = DockMetrics.pillScale(screenWidth: 2560, zoom: 1.1)
        expectEqual((DockMetrics.pillBaseHeight * scale).rounded(), DockMetrics.pillBaseHeight * scale)
        expectClose(DockMetrics.panelScale(pillScale: 1), 1)
        expectClose(DockMetrics.panelScale(pillScale: 1.34), 1.17)
        expectClose(DockMetrics.panelScale(pillScale: 2), 1.25)
        expectClose(DockMetrics.panelScale(pillScale: 0.5), 0.85)
    }

    static func zoomIsKeptSane() throws {
        expectEqual(DockMetrics.zoom(nil), 1)
        expectEqual(DockMetrics.zoom(.nan), 1)
        expectEqual(DockMetrics.zoom(9), 1.6)
        expectEqual(DockMetrics.zoom(0.1), 0.75)
        expectEqual(DockMetrics.zoom(1.234), 1.25)
        expectEqual(DockMetrics.zoomStepped(1, by: 1), 1.1)
        expectEqual(DockMetrics.zoomStepped(1.6, by: 1), 1.6)
        expectEqual(DockMetrics.zoomStepped(0.8, by: -1), 0.75)
    }

    static func restsAtTheBottomCentre() throws {
        let size = CGSize(width: 260, height: 44)
        let frame = DockPlacement.pillFrame(size: size, screen: laptop, xFraction: 0.5)
        expectEqual(frame, CGRect(x: 734, y: 84, width: 260, height: 44), "centred, 14 pt above the visible bottom")
        expectClose(CGFloat(DockPlacement.fraction(of: frame, on: laptop)), 0.5, 0.001)
        let home = DockPlacement.home(spot: nil, pointer: CGPoint(x: 400, y: 600), screens: [laptop, big])
        expectEqual(home?.screen.id, "laptop")
        expectEqual(home?.xFraction, 0.5)
        let onBig = DockPlacement.home(spot: nil, pointer: CGPoint(x: 3000, y: 900), screens: [laptop, big])
        expectEqual(onBig?.screen.id, "big", "the screen the pointer is on")
        // Between screens (in no screen at all): the nearest one.
        expectEqual(DockPlacement.home(spot: nil, pointer: CGPoint(x: 1800, y: 190), screens: [laptop, big])?.screen.id, "big")
        expect(DockPlacement.home(spot: nil, pointer: .zero, screens: []) == nil)
    }

    static func staysOnItsScreen() throws {
        let size = CGSize(width: 260, height: 44)
        let left = DockPlacement.pillFrame(size: size, screen: laptop, xFraction: 0)
        expectEqual(left.minX, DockMetrics.sideMargin)
        let right = DockPlacement.pillFrame(size: size, screen: laptop, xFraction: 1)
        expectEqual(right.maxX, laptop.visibleFrame.maxX - DockMetrics.sideMargin)
        let wild = DockPlacement.pillFrame(size: size, screen: laptop, xFraction: .infinity)
        expectEqual(wild.midX, laptop.visibleFrame.midX, "a nonsense fraction is the centre")
        // A pill wider than the screen is centred rather than pushed off one side.
        let tiny = DockScreen(id: "t", frame: CGRect(x: 0, y: 0, width: 200, height: 300), visibleFrame: CGRect(x: 0, y: 0, width: 200, height: 300))
        expectEqual(DockPlacement.pillFrame(size: size, screen: tiny, xFraction: 0.9).midX, 100)
    }

    static func remembersScreenAndFraction() throws {
        let spot = DockSpot(screenId: "big", xFraction: 0.25)
        let home = DockPlacement.home(spot: spot, pointer: CGPoint(x: 100, y: 100), screens: [laptop, big])
        expectEqual(home?.screen.id, "big", "the remembered screen wins over the pointer")
        expectEqual(home?.xFraction, 0.25)
        let frame = DockPlacement.pillFrame(size: CGSize(width: 300, height: 59), screen: big, xFraction: 0.25)
        expectEqual(frame.midX, 1728 + 800)
        expectEqual(frame.minY, 214)
        // Round trip through the fraction.
        expectClose(CGFloat(DockPlacement.fraction(of: frame, on: big)), 0.25, 0.001)
        let data = try JSONEncoder().encode(spot)
        expectEqual(try JSONDecoder().decode(DockSpot.self, from: data), spot)
    }

    static func survivesMonitorChanges() throws {
        let spot = DockSpot(screenId: "big", xFraction: 0.8)
        // The 32" is unplugged: the same relative place on the screen the pointer is on.
        let home = DockPlacement.home(spot: spot, pointer: CGPoint(x: 10, y: 10), screens: [laptop])
        expectEqual(home?.screen.id, "laptop")
        expectEqual(home?.xFraction, 0.8)
        // It comes back with different coordinates (now on the left): same place on it.
        let moved = DockScreen(id: "big", frame: CGRect(x: -3200, y: 0, width: 3200, height: 1350),
                               visibleFrame: CGRect(x: -3200, y: 0, width: 3200, height: 1325))
        let again = DockPlacement.home(spot: spot, pointer: CGPoint(x: 10, y: 10), screens: [laptop, moved])
        expectEqual(again?.screen.id, "big")
        let frame = DockPlacement.pillFrame(size: CGSize(width: 300, height: 59), screen: moved, xFraction: again?.xFraction ?? 0)
        expectEqual(frame.midX, -3200 + 2560)
        expectEqual(frame.minY, 14)
    }

    static func draggingFollowsThePointer() throws {
        let start = DockPlacement.pillFrame(size: CGSize(width: 260, height: 44), screen: laptop, xFraction: 0.5)
        let along = DockPlacement.dragged(from: start, dx: 200, pointer: CGPoint(x: 1064, y: 300), screens: [laptop, big])
        expectEqual(along?.frame.minX, start.minX + 200)
        expectEqual(along?.frame.minY, start.minY, "vertical travel is ignored: it stays on the bottom edge")
        let edge = DockPlacement.dragged(from: start, dx: 5000, pointer: CGPoint(x: 1700, y: 300), screens: [laptop])
        expectEqual(edge?.frame.maxX, laptop.visibleFrame.maxX - DockMetrics.sideMargin, "never off the screen")
        // Onto the 32": it drops to that screen's bottom edge under the pointer.
        let across = DockPlacement.dragged(from: start, dx: 1400, pointer: CGPoint(x: 2264, y: 700), screens: [laptop, big])
        expectEqual(across?.screen.id, "big")
        expectEqual(across?.frame.minY, 214)
        expectEqual(across?.frame.midX, 2264)
        let fraction = across.map { DockPlacement.fraction(of: $0.frame, on: $0.screen) } ?? -1
        expectClose(CGFloat(fraction), (2264 - 1728) / 3200, 0.001)
    }

    static func resizingKeepsTheBottomCentre() throws {
        let frame = DockPlacement.pillFrame(size: CGSize(width: 260, height: 44), screen: laptop, xFraction: 0.5)
        let voice = DockPlacement.resized(frame, to: CGSize(width: 420, height: 60), on: laptop)
        expectEqual(voice.midX, frame.midX)
        expectEqual(voice.minY, frame.minY)
        expectEqual(voice.size, CGSize(width: 420, height: 60))
        let atEdge = DockPlacement.pillFrame(size: CGSize(width: 200, height: 44), screen: laptop, xFraction: 1)
        let grown = DockPlacement.resized(atEdge, to: CGSize(width: 420, height: 60), on: laptop)
        expectEqual(grown.maxX, laptop.visibleFrame.maxX - DockMetrics.sideMargin, "growing at an edge stays on screen")
    }

    static func panelOpensAboveThePill() throws {
        let pill = DockPlacement.pillFrame(size: CGSize(width: 260, height: 44), screen: laptop, xFraction: 0.5)
        let panel = DockPlacement.panelFrame(size: CGSize(width: 440, height: 500), pill: pill, screen: laptop)
        expectEqual(panel.minY, pill.maxY + DockMetrics.panelGap)
        expectEqual(panel.midX, pill.midX)
        expectEqual(panel.height, 500)
        // Never taller than 60% of the screen…
        let tall = DockPlacement.panelFrame(size: CGSize(width: 440, height: 5000), pill: pill, screen: laptop)
        expectEqual(tall.height, (1117 * 0.6).rounded(.down))
        // …or than the room up to the top of the visible frame.
        let short = DockScreen(id: "s", frame: CGRect(x: 0, y: 0, width: 1280, height: 900), visibleFrame: CGRect(x: 0, y: 60, width: 1280, height: 400))
        let pillOnShort = DockPlacement.pillFrame(size: CGSize(width: 260, height: 44), screen: short, xFraction: 0.5)
        let capped = DockPlacement.panelFrame(size: CGSize(width: 440, height: 5000), pill: pillOnShort, screen: short)
        expectEqual(capped.maxY, short.visibleFrame.maxY - DockMetrics.sideMargin)
        // A pill parked at the right edge: the panel is pulled back onto the screen.
        let right = DockPlacement.pillFrame(size: CGSize(width: 200, height: 44), screen: laptop, xFraction: 1)
        let pulled = DockPlacement.panelFrame(size: CGSize(width: 440, height: 300), pill: right, screen: laptop)
        expectEqual(pulled.maxX, laptop.visibleFrame.maxX - DockMetrics.sideMargin)
    }

    static func cornerDragZooms() throws {
        expectEqual(DockMetrics.zoomFromDrag(startZoom: 1, startHeight: 44, up: 22, outward: 0), 1.5)
        expectEqual(DockMetrics.zoomFromDrag(startZoom: 1, startHeight: 44, up: -11, outward: 0), 0.75)
        expectEqual(DockMetrics.zoomFromDrag(startZoom: 1, startHeight: 44, up: 0, outward: 40), 1.3)
        expectEqual(DockMetrics.zoomFromDrag(startZoom: 1.2, startHeight: 53, up: 400, outward: 0), 1.6, "clamped")
        expectEqual(DockMetrics.zoomFromDrag(startZoom: 1, startHeight: 0, up: 10, outward: 0), 1)
    }
}
