import Foundation

enum VisibilityTests {
    static let all: [(String, () throws -> Void)] = [
        ("showsOutsideTheApp", showsOutsideTheApp),
        ("stepsAsideInTheMainWindow", stepsAsideInTheMainWindow),
        ("hidesForAWhileAndComesBack", hidesForAWhileAndComesBack),
        ("offIsForGoodButVoiceAndSummonShow", offIsForGoodButVoiceAndSummonShow),
        ("hideChoices", hideChoices),
    ]

    static func showsOutsideTheApp() throws {
        expect(DockVisibility.shows(DockVisibilityInput()), "another app in front, main window closed")
        var input = DockVisibilityInput(appActive: false, mainWindowVisible: true, mainWindowKey: false)
        expect(DockVisibility.shows(input), "another app in front of a visible main window")
        input.appActive = true
        expect(DockVisibility.shows(input), "SamRabbit in front but another of its windows (Pair iPhone) is key")
        input = DockVisibilityInput(appActive: true, mainWindowVisible: true, mainWindowKey: true, mainWindowMinimized: true)
        expect(DockVisibility.shows(input), "main window minimised")
        input = DockVisibilityInput(appActive: true, mainWindowVisible: false, mainWindowKey: false)
        expect(DockVisibility.shows(input), "main window closed or hidden")
    }

    static func stepsAsideInTheMainWindow() throws {
        let input = DockVisibilityInput(appActive: true, mainWindowVisible: true, mainWindowKey: true)
        expect(!DockVisibility.shows(input))
        expectEqual(DockVisibility.reason(input), .inApp)
    }

    static func hidesForAWhileAndComesBack() throws {
        let now = Date()
        var input = DockVisibilityInput(hiddenUntil: now.addingTimeInterval(60), now: now)
        expectEqual(DockVisibility.reason(input), .hiddenForAWhile)
        input.now = now.addingTimeInterval(61)
        expect(DockVisibility.shows(input), "a hide runs out by itself")
    }

    static func offIsForGoodButVoiceAndSummonShow() throws {
        var input = DockVisibilityInput(enabled: false)
        expectEqual(DockVisibility.reason(input), .off)
        input.voiceActive = true
        expectEqual(DockVisibility.reason(input), .voice, "the voice bar is the conversation's only control")
        input = DockVisibilityInput(appActive: true, mainWindowVisible: true, mainWindowKey: true, summoned: true)
        expectEqual(DockVisibility.reason(input), .summoned, "⌃⌥K shows it even over the main window")
        input = DockVisibilityInput(hiddenUntil: Date().addingTimeInterval(600), summoned: true)
        expect(DockVisibility.shows(input))
    }

    static func hideChoices() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let formatter = ISO8601DateFormatter()
        let now = formatter.date(from: "2026-10-13T23:30:00Z")!  // 7:30 pm in New York
        expectEqual(DockVisibility.hiddenUntil(.hour, now: now, calendar: calendar), now.addingTimeInterval(3600))
        expectEqual(DockVisibility.hiddenUntil(.tomorrow, now: now, calendar: calendar), formatter.date(from: "2026-10-14T04:00:00Z")!,
                    "local midnight")
        expectEqual(DockVisibility.HideChoice.allCases.map(\.label), ["Hide for 1 Hour", "Hide Until Tomorrow"])
    }
}

enum ExpansionTests {
    static let all: [(String, () throws -> Void)] = [
        ("pointingOpensAndLeavingCloses", pointingOpensAndLeavingCloses),
        ("passingOverOpensNothing", passingOverOpensNothing),
        ("comingBackKeepsItOpen", comingBackKeepsItOpen),
        ("aClickPinsIt", aClickPinsIt),
        ("typingIsNeverClosedUnderThePointer", typingIsNeverClosedUnderThePointer),
        ("afterADragThePointerMustLeaveFirst", afterADragThePointerMustLeaveFirst),
        ("summonAndVoice", summonAndVoice),
    ]

    static func pointingOpensAndLeavingCloses() throws {
        var e = DockExpansion()
        expectEqual(e.handle(.pointer(overPill: true, overPanel: false)), [.scheduleOpen])
        expectEqual(e.phase, .pendingOpen)
        expectEqual(e.handle(.openTimer), [.show])
        expectEqual(e.phase, .open(pinned: false))
        expectEqual(e.handle(.pointer(overPill: false, overPanel: true)), [], "moving onto the list keeps it")
        expectEqual(e.handle(.pointer(overPill: false, overPanel: false)), [.scheduleClose])
        expectEqual(e.handle(.pointer(overPill: false, overPanel: false)), [], "one countdown at a time")
        expectEqual(e.handle(.closeTimer), [.hide])
        expectEqual(e.phase, .collapsed)
    }

    static func passingOverOpensNothing() throws {
        var e = DockExpansion()
        _ = e.handle(.pointer(overPill: true, overPanel: false))
        expectEqual(e.handle(.pointer(overPill: false, overPanel: false)), [.cancelOpen])
        expectEqual(e.handle(.openTimer), [], "a timer that fired late does nothing")
        expectEqual(e.phase, .collapsed)
    }

    static func comingBackKeepsItOpen() throws {
        var e = DockExpansion()
        _ = e.handle(.pointer(overPill: true, overPanel: false))
        _ = e.handle(.openTimer)
        _ = e.handle(.pointer(overPill: false, overPanel: false))
        expectEqual(e.handle(.pointer(overPill: false, overPanel: true)), [.cancelClose])
        expectEqual(e.handle(.closeTimer), [], "the countdown was dropped")
        expect(e.isOpen)
    }

    static func aClickPinsIt() throws {
        var e = DockExpansion()
        expectEqual(e.handle(.clickPill), [.show])
        expect(e.isPinned)
        expectEqual(e.handle(.pointer(overPill: false, overPanel: false)), [], "a pinned list stays when the pointer leaves")
        expectEqual(e.handle(.clickOutside), [.hide])
        _ = e.handle(.clickPill)
        expectEqual(e.handle(.escape), [.hide])
        _ = e.handle(.clickPill)
        expectEqual(e.handle(.clickPill), [.hide], "a second click closes it")
        // A hover-opened list becomes pinned once Samin clicks in it.
        var h = DockExpansion()
        _ = h.handle(.pointer(overPill: true, overPanel: false))
        _ = h.handle(.openTimer)
        _ = h.handle(.pointer(overPill: false, overPanel: true))
        expectEqual(h.handle(.interact), [])
        expect(h.isPinned)
        // A click while the open is pending opens at once.
        var p = DockExpansion()
        _ = p.handle(.pointer(overPill: true, overPanel: false))
        expectEqual(p.handle(.clickPill), [.cancelOpen, .show])
        // A click outside while the pointer is on the dock is not "outside".
        var o = DockExpansion()
        _ = o.handle(.clickPill)
        _ = o.handle(.pointer(overPill: false, overPanel: true))
        expectEqual(o.handle(.clickOutside), [])
    }

    static func typingIsNeverClosedUnderThePointer() throws {
        var e = DockExpansion()
        _ = e.handle(.pointer(overPill: true, overPanel: false))
        _ = e.handle(.openTimer)
        _ = e.handle(.pointer(overPill: false, overPanel: true))
        _ = e.handle(.editing(true))
        expectEqual(e.handle(.pointer(overPill: false, overPanel: false)), [], "no countdown while a field has the keys")
        expectEqual(e.handle(.editing(false)), [.scheduleClose])
        expectEqual(e.handle(.closeTimer), [.hide])
        // A countdown already running when typing starts is dropped.
        var f = DockExpansion()
        _ = f.handle(.pointer(overPill: true, overPanel: false))
        _ = f.handle(.openTimer)
        _ = f.handle(.pointer(overPill: false, overPanel: false))
        expectEqual(f.handle(.editing(true)), [.cancelClose])
    }

    static func afterADragThePointerMustLeaveFirst() throws {
        var e = DockExpansion()
        _ = e.handle(.pointer(overPill: true, overPanel: false))
        expectEqual(e.handle(.dragStarted), [.cancelOpen])
        _ = e.handle(.dragEnded)
        expectEqual(e.handle(.pointer(overPill: true, overPanel: false)), [], "still on the pill after the drag")
        _ = e.handle(.pointer(overPill: false, overPanel: false))
        expectEqual(e.handle(.pointer(overPill: true, overPanel: false)), [.scheduleOpen])
        // Dragging an open list's pill closes the list.
        var o = DockExpansion()
        _ = o.handle(.clickPill)
        expectEqual(o.handle(.dragStarted), [.hide])
    }

    static func summonAndVoice() throws {
        var e = DockExpansion()
        expectEqual(e.handle(.summon), [.show])
        expect(e.isPinned)
        expectEqual(e.handle(.summon), [], "already open")
        var v = DockExpansion()
        _ = v.handle(.pointer(overPill: true, overPanel: false))
        _ = v.handle(.openTimer)
        expectEqual(v.handle(.voiceStarted), [.hide], "voice takes over the pill")
        var pinned = DockExpansion()
        _ = pinned.handle(.clickPill)
        expectEqual(pinned.handle(.voiceStarted), [], "a pinned list stays")
        expectEqual(pinned.handle(.hidden), [.hide])
    }
}

enum KeyboardTests {
    static let all: [(String, () throws -> Void)] = [
        ("mapsKeys", mapsKeys),
        ("movesTheSelection", movesTheSelection),
        ("enterExpandsThenOpens", enterExpandsThenOpens),
        ("approvesWithTheRecommendedOption", approvesWithTheRecommendedOption),
        ("replyComposeEscape", replyComposeEscape),
        ("rowsFromItems", rowsFromItems),
    ]

    static func key(_ code: UInt16, _ chars: String, command: Bool = false, control: Bool = false) -> DockKey? {
        DockKey.from(keyCode: code, characters: chars, command: command, control: control, option: false)
    }

    static func mapsKeys() throws {
        expectEqual(key(38, "j"), .down)
        expectEqual(key(40, "k"), .up)
        expectEqual(key(40, "K"), .up)
        expectEqual(key(125, ""), .down)
        expectEqual(key(126, ""), .up)
        expectEqual(key(36, "\r"), .enter)
        expectEqual(key(76, "\u{3}"), .enter)
        expectEqual(key(53, "\u{1b}"), .escape)
        expectEqual(key(14, "e"), .approve)
        expectEqual(key(15, "r"), .reply)
        expectEqual(key(45, "n"), .compose)
        expectEqual(key(24, "=", command: true), .zoomIn)
        expectEqual(key(27, "-", command: true), .zoomOut)
        expectEqual(key(29, "0", command: true), .zoomReset)
        expectEqual(key(38, "j", command: true), nil)
        expectEqual(key(38, "j", control: true), nil)
        expectEqual(key(0, "a"), nil)
    }

    static let rows = [
        DockKeyRow(id: "a", canOpen: true, canReply: true, approval: (requestId: "r1", decision: "accept")),
        DockKeyRow(id: "b", canOpen: true),
        DockKeyRow(id: "c", canOpen: false, canReply: true),
    ]

    static func movesTheSelection() throws {
        expectEqual(DockKeyboard.action(for: .down, rows: rows, selected: nil, expanded: nil), .select("a"))
        expectEqual(DockKeyboard.action(for: .up, rows: rows, selected: nil, expanded: nil), .select("a"))
        expectEqual(DockKeyboard.action(for: .down, rows: rows, selected: "a", expanded: nil), .select("b"))
        expectEqual(DockKeyboard.action(for: .down, rows: rows, selected: "c", expanded: nil), .select("c"), "stays at the end")
        expectEqual(DockKeyboard.action(for: .up, rows: rows, selected: "b", expanded: nil), .select("a"))
        expectEqual(DockKeyboard.action(for: .up, rows: rows, selected: "a", expanded: nil), .select("a"))
        expectEqual(DockKeyboard.action(for: .down, rows: [], selected: nil, expanded: nil), .none)
        expectEqual(DockKeyboard.action(for: .down, rows: rows, selected: "gone", expanded: nil), .select("a"),
                    "a selection that left the list starts over")
    }

    static func enterExpandsThenOpens() throws {
        expectEqual(DockKeyboard.action(for: .enter, rows: rows, selected: "b", expanded: nil), .expand("b"))
        expectEqual(DockKeyboard.action(for: .enter, rows: rows, selected: "b", expanded: "b"), .open("b"))
        expectEqual(DockKeyboard.action(for: .enter, rows: rows, selected: "c", expanded: "c"), .none, "c can't be opened")
        expectEqual(DockKeyboard.action(for: .enter, rows: rows, selected: "c", expanded: "a"), .expand("c"))
        expectEqual(DockKeyboard.action(for: .enter, rows: rows, selected: nil, expanded: nil), .select("a"))
    }

    static func approvesWithTheRecommendedOption() throws {
        expectEqual(DockKeyboard.action(for: .approve, rows: rows, selected: "a", expanded: nil),
                    .approve(id: "a", requestId: "r1", decision: "accept"))
        expectEqual(DockKeyboard.action(for: .approve, rows: rows, selected: "b", expanded: nil), .none,
                    "E on a row without an approval does nothing")
        expectEqual(DockKeyboard.action(for: .approve, rows: rows, selected: nil, expanded: nil),
                    .approve(id: "a", requestId: "r1", decision: "accept"), "nothing selected: the first waiting approval")
    }

    static func replyComposeEscape() throws {
        expectEqual(DockKeyboard.action(for: .reply, rows: rows, selected: "a", expanded: nil), .reply("a"))
        expectEqual(DockKeyboard.action(for: .reply, rows: rows, selected: "b", expanded: nil), .none)
        expectEqual(DockKeyboard.action(for: .reply, rows: rows, selected: nil, expanded: nil), .none)
        expectEqual(DockKeyboard.action(for: .compose, rows: rows, selected: nil, expanded: nil), .compose)
        expectEqual(DockKeyboard.action(for: .escape, rows: rows, selected: "a", expanded: "a"), .collapseRow)
        expectEqual(DockKeyboard.action(for: .escape, rows: rows, selected: "a", expanded: nil), .collapsePanel)
        expectEqual(DockKeyboard.action(for: .zoomIn, rows: [], selected: nil, expanded: nil), .zoom(1))
        expectEqual(DockKeyboard.action(for: .zoomReset, rows: [], selected: nil, expanded: nil), .zoom(0))
    }

    static func rowsFromItems() throws {
        let items = try DockInbox.decode(Fixture.inboxData()).items
        let pairing = DockKeyRow(items.first { $0.id == "t3:th_pairing_redirect" }!)
        expectEqual(pairing, DockKeyRow(id: "t3:th_pairing_redirect", canOpen: true, canReply: true,
                                        approval: (requestId: "req_run_tests", decision: "accept")))
        // The CLI owns its own prompt: Open only, no inline approve.
        let cli = DockKeyRow(items.first { $0.id.hasPrefix("claude:5d0c") }!)
        expectEqual(cli, DockKeyRow(id: cli.id, canOpen: true, canReply: false, approval: nil))
    }
}
