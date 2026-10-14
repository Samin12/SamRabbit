import CoreGraphics
import Foundation

enum PlacementTests {
    static let all: [(String, () throws -> Void)] = [
        ("scalesWithTheScreen", scalesWithTheScreen),
        ("zoomIsKeptSane", zoomIsKeptSane),
        ("restsAtTheBottomCentre", restsAtTheBottomCentre),
        ("cornerAndGapRoundTrip", cornerAndGapRoundTrip),
        ("survivesMonitorChanges", survivesMonitorChanges),
        ("eachScreenKeepsItsOwnSpot", eachScreenKeepsItsOwnSpot),
        ("staysWhollyOnScreen", staysWhollyOnScreen),
        ("dragsAnywhere", dragsAnywhere),
        ("softSnapsToEdgesCornersAndTheMiddle", softSnapsToEdgesCornersAndTheMiddle),
        ("dragsOntoOtherScreens", dragsOntoOtherScreens),
        ("resizingKeepsItsCorner", resizingKeepsItsCorner),
        ("listOpensOnTheSideWithRoom", listOpensOnTheSideWithRoom),
        ("listIsCappedOnItsSide", listIsCappedOnItsSide),
        ("minimizeButtonSide", minimizeButtonSide),
        ("bringsItToAnotherScreen", bringsItToAnotherScreen),
        ("migratesTheWave6Spot", migratesTheWave6Spot),
        ("theWave6SpotIsConvertedOnce", theWave6SpotIsConvertedOnce),
        ("cornerDragZooms", cornerDragZooms),
    ]

    // A laptop (menu bar 37 pt, Dock 70 pt) and a 32" to its right, a little higher.
    static let laptop = DockScreen(id: "laptop", frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
                                   visibleFrame: CGRect(x: 0, y: 70, width: 1728, height: 1010))
    static let big = DockScreen(id: "big", frame: CGRect(x: 1728, y: 200, width: 3200, height: 1350),
                                visibleFrame: CGRect(x: 1728, y: 200, width: 3200, height: 1325))
    static let pill = CGSize(width: 260, height: 44)

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
        let frame = DockPlacement.frame(for: .home, size: pill, on: laptop)
        expectEqual(frame, CGRect(x: 734, y: 84, width: 260, height: 44), "centred, 14 pt above the visible bottom")
        expectEqual(DockPlacement.spot(for: frame, on: laptop), .home, "and that is the home spot again")
        let home = DockPlacement.home(place: nil, pointer: CGPoint(x: 400, y: 600), screens: [laptop, big])
        expectEqual(home?.screen.id, "laptop")
        expectEqual(home?.spot, .home)
        let onBig = DockPlacement.home(place: nil, pointer: CGPoint(x: 3000, y: 900), screens: [laptop, big])
        expectEqual(onBig?.screen.id, "big", "never moved: the screen the pointer is on")
        expectEqual(onBig.map { DockPlacement.frame(for: $0.spot, size: pill, on: $0.screen) },
                    CGRect(x: 3198, y: 214, width: 260, height: 44))
        // Between screens (in no screen at all): the nearest one.
        expectEqual(DockPlacement.home(place: nil, pointer: CGPoint(x: 1800, y: 190), screens: [laptop, big])?.screen.id, "big")
        expect(DockPlacement.home(place: nil, pointer: .zero, screens: []) == nil)
    }

    static func cornerAndGapRoundTrip() throws {
        // Every corner (and the middle of the top and bottom edges), near the edge and far in: frame → spot → frame.
        for screen in [laptop, big] {
            for corner in DockCorner.allCases {
                for (dx, dy) in [(CGFloat(8), CGFloat(8)), (120, 300), (0, 0)] {
                    let spot = DockSpot(corner: corner, dx: corner.side == .middle ? 0 : dx, dy: dy)
                    let frame = DockPlacement.frame(for: spot, size: pill, on: screen)
                    expect(screen.visibleFrame.contains(frame), "\(corner) +\(dx),\(dy) is on \(screen.id)")
                    expectEqual(DockPlacement.spot(for: frame, on: screen), spot, "\(corner) +\(dx),\(dy) on \(screen.id)")
                }
            }
        }
        // The gaps are measured from the dock's own nearest edges.
        let topRight = DockPlacement.frame(for: DockSpot(corner: .topRight, dx: 8, dy: 8), size: pill, on: big)
        expectEqual(topRight.maxX, big.visibleFrame.maxX - 8)
        expectEqual(topRight.maxY, big.visibleFrame.maxY - 8)
        let bottomLeft = DockPlacement.frame(for: DockSpot(corner: .bottomLeft, dx: 40, dy: 30), size: pill, on: laptop)
        expectEqual(bottomLeft, CGRect(x: 40, y: 100, width: 260, height: 44))
        // A middle spot keeps its sideways offset from the centre.
        let offCentre = DockPlacement.frame(for: DockSpot(corner: .top, dx: -100, dy: 8), size: pill, on: laptop)
        expectEqual(offCentre.midX, laptop.visibleFrame.midX - 100)
        // What is kept: the screen and each screen's spot, as JSON.
        let place = DockPlace(screenId: "big", spots: ["big": DockSpot(corner: .topRight, dx: 8, dy: 8), "laptop": .home])
        let data = try JSONEncoder().encode(place)
        expectEqual(try JSONDecoder().decode(DockPlace.self, from: data), place)
        expectEqual(place.spot, DockSpot(corner: .topRight, dx: 8, dy: 8))
        expectEqual(DockPlace(screenId: "gone", spots: [:]).spot, .home, "no spot for its screen: home")
    }

    static func survivesMonitorChanges() throws {
        let corner = DockSpot(corner: .topRight, dx: 8, dy: 8)
        let place = DockPlace(screenId: "big", spots: ["big": corner])
        // The screen it was left on wins over the pointer's.
        let home = DockPlacement.home(place: place, pointer: CGPoint(x: 100, y: 100), screens: [laptop, big])
        expectEqual(home?.screen.id, "big")
        expectEqual(home?.spot, corner)
        // The 32" is unplugged: the pointer's screen lends it a place, the same corner and gap.
        let lent = DockPlacement.home(place: place, pointer: CGPoint(x: 10, y: 10), screens: [laptop])
        expectEqual(lent?.screen.id, "laptop")
        expectEqual(lent.map { DockPlacement.frame(for: $0.spot, size: pill, on: $0.screen) },
                    CGRect(x: 1460, y: 1028, width: 260, height: 44), "8 pt from the laptop's top-right corner")
        // It comes back with other coordinates (now left of the laptop): the same corner of it, not a desktop point.
        let movedBig = DockScreen(id: "big", frame: CGRect(x: -3200, y: 0, width: 3200, height: 1350),
                                  visibleFrame: CGRect(x: -3200, y: 0, width: 3200, height: 1325))
        let again = DockPlacement.home(place: place, pointer: CGPoint(x: 10, y: 10), screens: [laptop, movedBig])
        expectEqual(again?.screen.id, "big")
        expectEqual(again.map { DockPlacement.frame(for: $0.spot, size: pill, on: $0.screen) },
                    CGRect(x: -268, y: 1273, width: 260, height: 44))
        // …or at another resolution: still 8 pt in from its top-right corner (an x fraction would have drifted).
        let lowRes = DockScreen(id: "big", frame: CGRect(x: 1728, y: 200, width: 2560, height: 1440),
                                visibleFrame: CGRect(x: 1728, y: 200, width: 2560, height: 1415))
        let scaled = DockPlacement.frame(for: corner, size: pill, on: lowRes)
        expectEqual(scaled.maxX, lowRes.visibleFrame.maxX - 8)
        expectEqual(scaled.maxY, lowRes.visibleFrame.maxY - 8)
        // A gap bigger than the screen it lands on is pulled in: wholly visible.
        let far = DockPlacement.frame(for: DockSpot(corner: .bottomLeft, dx: 3000, dy: 1200), size: pill, on: laptop)
        expectEqual(far, CGRect(x: 1468, y: 1036, width: 260, height: 44))
    }

    static func eachScreenKeepsItsOwnSpot() throws {
        // Left bottom-left on the laptop, then top-right on the 32": both are remembered, the 32" is home.
        var place = DockPlacement.remember(DockSpot(corner: .bottomLeft, dx: 20, dy: 14), on: laptop, in: nil)
        expectEqual(place.screenId, "laptop")
        place = DockPlacement.remember(DockSpot(corner: .topRight, dx: 8, dy: 8), on: big, in: place)
        expectEqual(place.screenId, "big")
        expectEqual(place.spots.count, 2)
        // The 32" unplugged: the laptop's own spot, not the 32"'s corner.
        let lent = DockPlacement.home(place: place, pointer: CGPoint(x: 10, y: 10), screens: [laptop])
        expectEqual(lent?.spot, DockSpot(corner: .bottomLeft, dx: 20, dy: 14))
        // Plugged back in: back on it, at its corner.
        expectEqual(DockPlacement.home(place: place, pointer: CGPoint(x: 10, y: 10), screens: [laptop, big])?.spot,
                    DockSpot(corner: .topRight, dx: 8, dy: 8))
    }

    static func staysWhollyOnScreen() throws {
        let visible = laptop.visibleFrame
        // Off every edge: pulled back inside the visible frame (never under the menu bar or the Dock).
        expectEqual(DockPlacement.clamped(CGRect(x: -50, y: 2000, width: 260, height: 44), in: visible),
                    CGRect(x: 0, y: 1036, width: 260, height: 44))
        expectEqual(DockPlacement.clamped(CGRect(x: 5000, y: -40, width: 260, height: 44), in: visible),
                    CGRect(x: 1468, y: 70, width: 260, height: 44))
        expectEqual(DockPlacement.clamped(CGRect(x: 100.4, y: 300.6, width: 260, height: 44), in: visible),
                    CGRect(x: 100, y: 301, width: 260, height: 44), "on whole points")
        // Nonsense is the centre; something bigger than the screen is centred on it rather than pushed off one side.
        expectEqual(DockPlacement.clamped(CGRect(x: CGFloat.nan, y: 84, width: 260, height: 44), in: visible).minX, 734)
        let tiny = DockScreen(id: "t", frame: CGRect(x: 0, y: 0, width: 200, height: 300), visibleFrame: CGRect(x: 0, y: 0, width: 200, height: 300))
        expectEqual(DockPlacement.frame(for: .home, size: pill, on: tiny).midX, 100)
        expectEqual(DockPlacement.frame(for: DockSpot(corner: .bottomLeft, dx: .infinity, dy: .nan), size: pill, on: laptop),
                    CGRect(x: 0, y: 84, width: 260, height: 44), "a broken spot is the corner itself")
        // Whatever spot it is given, on whichever screen.
        for corner in DockCorner.allCases {
            for gap in [CGFloat(-500), -1, 0, 7, 400, 9000] {
                for screen in [laptop, big] {
                    let frame = DockPlacement.frame(for: DockSpot(corner: corner, dx: gap, dy: gap), size: pill, on: screen)
                    expect(screen.visibleFrame.contains(frame), "\(corner) gap \(gap) on \(screen.id): \(frame)")
                }
            }
        }
    }

    static func dragsAnywhere() throws {
        let start = DockPlacement.frame(for: .home, size: pill, on: laptop)
        // Up and to the left, into the middle of the screen: it stays where it is dropped.
        let free = DockPlacement.dragged(from: start, dx: -300, dy: 400, pointer: CGPoint(x: 600, y: 520), screens: [laptop, big])
        expectEqual(free?.screen.id, "laptop")
        expectEqual(free?.frame, CGRect(x: 434, y: 484, width: 260, height: 44))
        expectEqual(free.map { DockPlacement.spot(for: $0.frame, on: laptop) }, DockSpot(corner: .bottomLeft, dx: 434, dy: 414))
        // High on the right half: the top-right corner is the nearest, its gap measured from there.
        let high = DockPlacement.dragged(from: start, dx: 500, dy: 700, pointer: CGPoint(x: 1400, y: 800), screens: [laptop, big])
        expectEqual(high?.frame, CGRect(x: 1234, y: 784, width: 260, height: 44))
        expectEqual(high.map { DockPlacement.spot(for: $0.frame, on: laptop) }, DockSpot(corner: .topRight, dx: 234, dy: 252))
        // Far past the top-left: kept on screen, and snapped into the corner with its gaps.
        let past = DockPlacement.dragged(from: start, dx: -5000, dy: 5000, pointer: CGPoint(x: 5, y: 1110), screens: [laptop])
        expectEqual(past?.frame, CGRect(x: 8, y: 1028, width: 260, height: 44))
        expectEqual(past.map { DockPlacement.spot(for: $0.frame, on: laptop) }, DockSpot(corner: .topLeft, dx: 8, dy: 8))
        expect(DockPlacement.dragged(from: start, dx: 10, dy: 10, pointer: .zero, screens: []) == nil)
    }

    static func softSnapsToEdgesCornersAndTheMiddle() throws {
        let visible = laptop.visibleFrame
        func snap(_ x: CGFloat, _ y: CGFloat) -> CGRect {
            DockPlacement.snapped(CGRect(x: x, y: y, width: 260, height: 44), on: laptop)
        }
        // Within 16 pt of an edge: onto it (8 pt in at the sides and the top, 14 pt above the bottom, by the Dock).
        expectEqual(snap(20, 500).minX, 8)
        expectEqual(snap(30, 500).minX, 30, "22 pt away: left alone")
        expectEqual(snap(1450, 500).maxX, visible.maxX - 8)
        expectEqual(snap(600, 1020).maxY, visible.maxY - 8)
        expectEqual(snap(600, 95).minY, visible.minY + 14)
        expectEqual(snap(600, 110).minY, 110)
        // A corner is two edges at once.
        expectEqual(snap(3, 1040), CGRect(x: 8, y: 1028, width: 260, height: 44))
        expectEqual(snap(1462, 75), CGRect(x: 1460, y: 84, width: 260, height: 44))
        // The middle, sideways: centred on the screen (and then remembered as the middle of that edge).
        let centred = snap(744, 400)
        expectEqual(centred.midX, visible.midX)
        expectEqual(DockPlacement.spot(for: centred, on: laptop), DockSpot(corner: .bottom, dx: 0, dy: 330))
        expectEqual(DockPlacement.spot(for: snap(720, 1030), on: laptop), DockSpot(corner: .top, dx: 0, dy: 8))
        // A drag snaps as it goes.
        let start = DockPlacement.frame(for: .home, size: pill, on: laptop)
        let nearLeft = DockPlacement.dragged(from: start, dx: -720, dy: 0, pointer: CGPoint(x: 140, y: 100), screens: [laptop])
        expectEqual(nearLeft?.frame, CGRect(x: 8, y: 84, width: 260, height: 44))
    }

    static func dragsOntoOtherScreens() throws {
        let start = DockPlacement.frame(for: .home, size: pill, on: laptop)
        // Onto the 32", anywhere on it.
        let across = DockPlacement.dragged(from: start, dx: 1600, dy: 600, pointer: CGPoint(x: 2464, y: 706), screens: [laptop, big])
        expectEqual(across?.screen.id, "big")
        expectEqual(across?.frame, CGRect(x: 2334, y: 684, width: 260, height: 44))
        // Partly over the edge between the two: wholly on the pointer's screen.
        let straddle = DockPlacement.dragged(from: start, dx: 900, dy: 300, pointer: CGPoint(x: 1740, y: 406), screens: [laptop, big])
        expectEqual(straddle?.screen.id, "big")
        expectEqual(straddle?.frame.minX, big.visibleFrame.minX + 8, "pulled in, then snapped to the 32\"'s left edge")
        // A screen that doesn't line up with the one it left (much higher): it stays under the pointer there.
        let upper = DockScreen(id: "upper", frame: CGRect(x: 1728, y: 1200, width: 1920, height: 1080),
                               visibleFrame: CGRect(x: 1728, y: 1200, width: 1920, height: 1055))
        let start2 = DockPlacement.frame(for: DockSpot(corner: .bottomRight, dx: 8, dy: 14), size: pill, on: laptop)
        let up = DockPlacement.dragged(from: start2, dx: 400, dy: 0, pointer: CGPoint(x: 1900, y: 1500), screens: [laptop, upper])
        expectEqual(up?.screen.id, "upper")
        expectEqual(up?.frame, CGRect(x: 1770, y: 1478, width: 260, height: 44))
    }

    static func resizingKeepsItsCorner() throws {
        let voice = CGSize(width: 420, height: 64)
        let orb = CGSize(width: 41, height: 41)
        // Bottom right: the right and bottom edges stay as the voice bar takes over, and as it folds to the orb.
        let right = DockPlacement.frame(for: DockSpot(corner: .bottomRight, dx: 8, dy: 14), size: pill, on: laptop)
        let grown = DockPlacement.resized(right, to: voice, on: laptop)
        expectEqual(grown.maxX, right.maxX)
        expectEqual(grown.minY, right.minY)
        expectEqual(grown.size, voice)
        let folded = DockPlacement.resized(right, to: orb, on: laptop)
        expectEqual(folded, CGRect(x: 1679, y: 84, width: 41, height: 41))
        // Top left: the left and top edges stay.
        let topLeft = DockPlacement.frame(for: DockSpot(corner: .topLeft, dx: 8, dy: 8), size: orb, on: big)
        let opened = DockPlacement.resized(topLeft, to: pill, on: big)
        expectEqual(opened.minX, topLeft.minX)
        expectEqual(opened.maxY, topLeft.maxY)
        // Centred: the centre stays.
        let centred = DockPlacement.frame(for: .home, size: pill, on: laptop)
        expectEqual(DockPlacement.resized(centred, to: voice, on: laptop).midX, centred.midX)
        expectEqual(DockPlacement.resized(centred, to: voice, on: laptop).minY, centred.minY)
        // Against the right edge, growing never pushes it off.
        let flush = DockPlacement.frame(for: DockSpot(corner: .bottomRight, dx: 0, dy: 14), size: pill, on: laptop)
        expectEqual(DockPlacement.resized(flush, to: CGSize(width: 900, height: 64), on: laptop).maxX, laptop.visibleFrame.maxX)
    }

    static func listOpensOnTheSideWithRoom() throws {
        let list = CGSize(width: 440, height: 500)
        // Low and centred (where it rests): above, centred on it.
        let home = DockPlacement.frame(for: .home, size: pill, on: laptop)
        expect(!DockPlacement.panelOpensBelow(pill: home, screen: laptop))
        let above = DockPlacement.panelFrame(size: list, pill: home, screen: laptop)
        expectEqual(above, CGRect(x: 644, y: home.maxY + DockMetrics.panelGap, width: 440, height: 500))
        // High on the left (under the menu bar): below, its left edge lined up with the pill's.
        let topLeft = DockPlacement.frame(for: DockSpot(corner: .topLeft, dx: 8, dy: 8), size: pill, on: laptop)
        expect(DockPlacement.panelOpensBelow(pill: topLeft, screen: laptop))
        let below = DockPlacement.panelFrame(size: list, pill: topLeft, screen: laptop)
        expectEqual(below, CGRect(x: 8, y: topLeft.minY - DockMetrics.panelGap - 500, width: 440, height: 500))
        expectEqual(below.maxY, topLeft.minY - DockMetrics.panelGap)
        // High on the right: below, right edges lined up.
        let topRight = DockPlacement.frame(for: DockSpot(corner: .topRight, dx: 8, dy: 8), size: pill, on: big)
        let belowRight = DockPlacement.panelFrame(size: list, pill: topRight, screen: big)
        expectEqual(belowRight.maxX, topRight.maxX)
        expectEqual(belowRight.maxY, topRight.minY - DockMetrics.panelGap)
        // Low on the right (the orb in the corner): above, right edges lined up.
        let orb = DockPlacement.frame(for: DockSpot(corner: .bottomRight, dx: 8, dy: 14), size: CGSize(width: 41, height: 41), on: laptop)
        let overOrb = DockPlacement.panelFrame(size: list, pill: orb, screen: laptop)
        expectEqual(overOrb.maxX, orb.maxX)
        expectEqual(overOrb.minY, orb.maxY + DockMetrics.panelGap)
        // A pill flush against the left edge: the list keeps a margin from the screen's edge.
        let flush = DockPlacement.frame(for: DockSpot(corner: .bottomLeft, dx: 0, dy: 14), size: pill, on: laptop)
        expectEqual(DockPlacement.panelFrame(size: list, pill: flush, screen: laptop).minX, DockMetrics.sideMargin)
        // A list wider than a narrow screen is centred on it.
        let narrow = DockScreen(id: "n", frame: CGRect(x: 0, y: 0, width: 400, height: 900), visibleFrame: CGRect(x: 0, y: 0, width: 400, height: 900))
        let narrowPill = DockPlacement.frame(for: .home, size: pill, on: narrow)
        expectEqual(DockPlacement.panelFrame(size: list, pill: narrowPill, screen: narrow).midX, 200)
        // Whichever side has more room wins, also off the edges (just above the middle: below).
        let middle = DockPlacement.frame(for: DockSpot(corner: .topRight, dx: 300, dy: 400), size: pill, on: laptop)
        expect(DockPlacement.panelOpensBelow(pill: middle, screen: laptop))
        let lowMiddle = DockPlacement.frame(for: DockSpot(corner: .bottomLeft, dx: 300, dy: 400), size: pill, on: laptop)
        expect(!DockPlacement.panelOpensBelow(pill: lowMiddle, screen: laptop))
    }

    static func listIsCappedOnItsSide() throws {
        let home = DockPlacement.frame(for: .home, size: pill, on: laptop)
        // Never taller than 60% of the screen…
        let tall = DockPlacement.panelFrame(size: CGSize(width: 440, height: 5000), pill: home, screen: laptop)
        expectEqual(tall.height, (1117 * 0.6).rounded(.down))
        // …or than the room on its side: above a low pill up to the top of the visible frame…
        let short = DockScreen(id: "s", frame: CGRect(x: 0, y: 0, width: 1280, height: 900), visibleFrame: CGRect(x: 0, y: 60, width: 1280, height: 400))
        let low = DockPlacement.frame(for: .home, size: pill, on: short)
        let capped = DockPlacement.panelFrame(size: CGSize(width: 440, height: 5000), pill: low, screen: short)
        expectEqual(capped.maxY, short.visibleFrame.maxY - DockMetrics.sideMargin)
        // …and below a high pill down to the bottom of it.
        let high = DockPlacement.frame(for: DockSpot(corner: .top, dx: 0, dy: 8), size: pill, on: short)
        let down = DockPlacement.panelFrame(size: CGSize(width: 440, height: 5000), pill: high, screen: short)
        expectEqual(down.minY, short.visibleFrame.minY + DockMetrics.sideMargin)
        expectEqual(down.maxY, high.minY - DockMetrics.panelGap)
        expectEqual(DockPlacement.maxPanelHeight(pill: high, screen: short), down.height)
    }

    static func minimizeButtonSide() throws {
        // The "–" goes at the end away from the edge the pill is kept against: into the screen.
        let right = DockPlacement.frame(for: DockSpot(corner: .bottomRight, dx: 8, dy: 14), size: pill, on: laptop)
        let left = DockPlacement.frame(for: DockSpot(corner: .topLeft, dx: 8, dy: 8), size: pill, on: laptop)
        let centred = DockPlacement.frame(for: .home, size: pill, on: laptop)
        expect(DockPlacement.minimizeOnLeft(right, on: laptop))
        expect(!DockPlacement.minimizeOnLeft(left, on: laptop))
        expect(!DockPlacement.minimizeOnLeft(centred, on: laptop))
        // The window grows by the button on that side; the pill itself doesn't move.
        let grownLeft = DockPlacement.withSlot(right, width: 32, onLeft: true, on: laptop)
        expectEqual(grownLeft, CGRect(x: right.minX - 32, y: right.minY, width: 292, height: 44))
        expectEqual(grownLeft.maxX, right.maxX)
        let grownRight = DockPlacement.withSlot(left, width: 32, onLeft: false, on: laptop)
        expectEqual(grownRight.minX, left.minX)
        expectEqual(grownRight.width, 292)
        expectEqual(DockPlacement.withSlot(left, width: 0, onLeft: false, on: laptop), left)
    }

    static func bringsItToAnotherScreen() throws {
        let current = DockSpot(corner: .bottomLeft, dx: 20, dy: 14)
        // Never moved: nothing to remember (it follows the pointer anyway), same spot.
        let unmoved = DockPlacement.bringing(nil, current: current, to: big)
        expect(unmoved.place == nil)
        expectEqual(unmoved.spot, current)
        // Left on the laptop: on the 32" at the same corner and gap, and the 32" is now its screen.
        let place = DockPlace(screenId: "laptop", spots: ["laptop": current])
        let brought = DockPlacement.bringing(place, current: current, to: big)
        expectEqual(brought.place?.screenId, "big")
        expectEqual(brought.spot, current)
        expectEqual(brought.place?.spots["laptop"], current, "the laptop keeps its own spot")
        // A screen it was left on before: its own spot there.
        let known = DockPlace(screenId: "laptop", spots: ["laptop": current, "big": DockSpot(corner: .topRight, dx: 8, dy: 8)])
        expectEqual(DockPlacement.bringing(known, current: current, to: big).spot, DockSpot(corner: .topRight, dx: 8, dy: 8))
    }

    static func migratesTheWave6Spot() throws {
        // Wave 6 kept {screen, x fraction along the bottom edge}: the same place, said as a corner and a gap.
        let legacy = try JSONDecoder().decode(DockLegacySpot.self, from: Data(#"{"screenId":"laptop","xFraction":0.5}"#.utf8))
        let centre = DockPlacement.migrated(legacy, size: pill, screens: [laptop, big])
        expectEqual(centre, DockPlace(screenId: "laptop", spots: ["laptop": .home]))
        let right = DockPlacement.migrated(DockLegacySpot(screenId: "laptop", xFraction: 1), size: pill, screens: [laptop])
        expectEqual(right.spot, DockSpot(corner: .bottomRight, dx: 8, dy: 14), "parked at the right edge (8 pt margin)")
        // A quarter along the 32": where Wave 6 drew it, to the point.
        let quarter = DockPlacement.migrated(DockLegacySpot(screenId: "big", xFraction: 0.25), size: pill, screens: [laptop, big])
        expectEqual(quarter.spot, DockSpot(corner: .bottomLeft, dx: 670, dy: 14))
        expectEqual(DockPlacement.frame(for: quarter.spot, size: pill, on: big).midX, 1728 + 800)
        // Its screen isn't connected right now: worked out on the first one, and still its screen.
        let away = DockPlacement.migrated(DockLegacySpot(screenId: "gone", xFraction: 0), size: pill, screens: [laptop])
        expectEqual(away.screenId, "gone")
        expectEqual(away.spot, DockSpot(corner: .bottomLeft, dx: 8, dy: 14))
        // Nonsense is the middle.
        expectEqual(DockPlacement.migrated(DockLegacySpot(screenId: "laptop", xFraction: .nan), size: pill, screens: [laptop]).spot, .home)
        expectEqual(DockPlacement.migrated(DockLegacySpot(screenId: "laptop", xFraction: 0.5), size: pill, screens: []).spot, .home)
    }

    static func theWave6SpotIsConvertedOnce() throws {
        // Samin's settings as Wave 6 left them: the dock dragged a quarter along the 32".
        let mac = FakeDefaults()
        mac.values[DockPlaceMemory.legacyKey] = try JSONEncoder().encode(DockLegacySpot(screenId: "big", xFraction: 0.25))
        // The first launch of this version: turned into a corner and a gap, and noted as done.
        let converted = DockPlaceMemory(defaults: mac).migrate(size: pill, screens: [laptop, big])
        expectEqual(converted?.spot, DockSpot(corner: .bottomLeft, dx: 670, dy: 14))
        expectEqual(DockPlaceMemory(defaults: mac).place, converted, "kept as AgentDockPlace")
        expect(mac.values[DockPlaceMemory.migratedKey] as? Bool == true)
        expect(mac.values[DockPlaceMemory.legacyKey] != nil, "Wave 6's key is left for an older copy")
        // "Move Back to the Middle" forgets the spot; the next launch (the login item's too) leaves it forgotten.
        DockPlaceMemory(defaults: mac).place = nil
        expect(mac.values[DockPlaceMemory.placeKey] == nil)
        expect(DockPlaceMemory(defaults: mac).migrate(size: pill, screens: [laptop, big]) == nil, "converted once only")
        expect(DockPlaceMemory(defaults: mac).place == nil, "still in the middle after a relaunch")
        // Moved again, relaunched: where he left it, not the old spot.
        let moved = DockPlacement.remember(DockSpot(corner: .topRight, dx: 8, dy: 8), on: big, in: nil)
        DockPlaceMemory(defaults: mac).place = moved
        _ = DockPlaceMemory(defaults: mac).migrate(size: pill, screens: [laptop, big])
        expectEqual(DockPlaceMemory(defaults: mac).place, moved)

        // A place from before the flag existed wins over the old spot (and the flag is set from then on).
        let earlier = FakeDefaults()
        earlier.values[DockPlaceMemory.legacyKey] = try JSONEncoder().encode(DockLegacySpot(screenId: "laptop", xFraction: 1))
        earlier.values[DockPlaceMemory.placeKey] = try JSONEncoder().encode(moved)
        expect(DockPlaceMemory(defaults: earlier).migrate(size: pill, screens: [laptop, big]) == nil)
        expectEqual(DockPlaceMemory(defaults: earlier).place, moved)
        expect(earlier.values[DockPlaceMemory.migratedKey] as? Bool == true)
        // Never moved in Wave 6, or nothing readable: nothing to convert, and not looked at again.
        let fresh = FakeDefaults()
        expect(DockPlaceMemory(defaults: fresh).migrate(size: pill, screens: [laptop]) == nil)
        expect(DockPlaceMemory(defaults: fresh).place == nil)
        expect(fresh.values[DockPlaceMemory.migratedKey] as? Bool == true)
        let odd = FakeDefaults()
        odd.values[DockPlaceMemory.legacyKey] = Data("not json".utf8)
        expect(DockPlaceMemory(defaults: odd).migrate(size: pill, screens: [laptop]) == nil)
        odd.values[DockPlaceMemory.placeKey] = Data("not json either".utf8)
        expect(DockPlaceMemory(defaults: odd).place == nil, "an unreadable place is no place")
    }

    static func cornerDragZooms() throws {
        expectEqual(DockMetrics.zoomFromDrag(startZoom: 1, startHeight: 44, up: 22, outward: 0), 1.5)
        expectEqual(DockMetrics.zoomFromDrag(startZoom: 1, startHeight: 44, up: -11, outward: 0), 0.75)
        expectEqual(DockMetrics.zoomFromDrag(startZoom: 1, startHeight: 44, up: 0, outward: 40), 1.3)
        expectEqual(DockMetrics.zoomFromDrag(startZoom: 1.2, startHeight: 53, up: 400, outward: 0), 1.6, "clamped")
        expectEqual(DockMetrics.zoomFromDrag(startZoom: 1, startHeight: 0, up: 10, outward: 0), 1)
    }
}

/// The app's UserDefaults as a dictionary: what DockPlaceMemory reads and writes on one simulated Mac.
final class FakeDefaults: DockDefaults {
    var values: [String: Any] = [:]

    func data(forKey key: String) -> Data? { values[key] as? Data }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values[key] = nil }
}
