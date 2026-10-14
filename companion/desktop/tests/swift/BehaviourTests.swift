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
        ("strayKeysApproveNothing", strayKeysApproveNothing),
        ("replyComposeEscape", replyComposeEscape),
        ("commandKeysStayInTheDock", commandKeysStayInTheDock),
        ("rowsFromItems", rowsFromItems),
        ("xDismissesTheSelectedRow", xDismissesTheSelectedRow),
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
        expectEqual(key(7, "x"), .dismiss)
        expectEqual(key(7, "X"), .dismiss)
        expectEqual(key(7, "x", command: true), nil, "⌘X is the fields' cut")
        expectEqual(key(24, "=", command: true), nil, "⌘ keys go through DockCommandKey")
        expectEqual(key(29, "0", command: true), nil)
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
        expectEqual(DockKeyboard.action(for: .approve, rows: rows, selected: "a", expanded: "a"),
                    .approve(id: "a", requestId: "r1", decision: "accept"), "the open row, its command on screen")
        expectEqual(DockKeyboard.action(for: .approve, rows: rows, selected: "b", expanded: "b"), .none,
                    "E on a row without an approval does nothing")
    }

    /// Samin clicks the pill and starts typing "explain the failing test": no letter may approve a command he never saw.
    static func strayKeysApproveNothing() throws {
        expectEqual(DockKeyboard.action(for: .approve, rows: rows, selected: nil, expanded: nil), .none,
                    "nothing selected: no fallback to the first waiting approval")
        expectEqual(DockKeyboard.action(for: .approve, rows: rows, selected: "a", expanded: nil), .none,
                    "selected but closed: the command isn't on screen")
        expectEqual(DockKeyboard.action(for: .approve, rows: rows, selected: "a", expanded: "c"), .none,
                    "another row is open")
        // Typed into a list that just opened: e, x, p, l, a, i, n… — only N acts (it moves the keys to compose).
        var selected: String?
        var expanded: String?
        for character in "explain the failing test" {
            guard let key = DockKey.from(keyCode: 0, characters: String(character), command: false, control: false, option: false) else { continue }
            let action = DockKeyboard.action(for: key, rows: rows, selected: selected, expanded: expanded)
            if case .approve = action { expect(false, "‘\(character)’ approved something") }
            switch action {
            case .select(let id): selected = id
            case .expand(let id): expanded = id
            case .compose: return  // the rest goes into the compose field
            default: break
            }
        }
    }

    static func replyComposeEscape() throws {
        expectEqual(DockKeyboard.action(for: .reply, rows: rows, selected: "a", expanded: nil), .reply("a"))
        expectEqual(DockKeyboard.action(for: .reply, rows: rows, selected: "b", expanded: nil), .none)
        expectEqual(DockKeyboard.action(for: .reply, rows: rows, selected: nil, expanded: nil), .none)
        expectEqual(DockKeyboard.action(for: .compose, rows: rows, selected: nil, expanded: nil), .compose)
        expectEqual(DockKeyboard.action(for: .escape, rows: rows, selected: "a", expanded: "a"), .collapseRow)
        expectEqual(DockKeyboard.action(for: .escape, rows: rows, selected: "a", expanded: nil), .collapsePanel)
    }

    /// ⌘ keys while the dock has the keys: its size keys, editing, and never one of the app's menu items (⌘0 "Open
    /// SamRabbit Window" would bring the main window forward, ⌘K would search it, ⌘Q would quit SamRabbit).
    static func commandKeysStayInTheDock() throws {
        func route(_ code: UInt16, _ chars: String, shift: Bool = false, control: Bool = false) -> DockCommandKey {
            DockCommandKey.route(keyCode: code, characters: chars, shift: shift, control: control, option: false)
        }
        expectEqual(route(24, "="), .zoom(1))
        expectEqual(route(24, "+", shift: true), .zoom(1))
        expectEqual(route(27, "-"), .zoom(-1))
        expectEqual(route(29, "0"), .zoom(0), "⌘0 resets the dock's size, it doesn't open the main window")
        for (code, chars) in [(UInt16(40), "k"), (12, "q"), (15, "r"), (31, "o"), (13, "w"), (4, "h"), (43, ","), (35, "p")] {
            expectEqual(route(code, chars), .swallow, "⌘\(chars) runs no menu item from the dock")
        }
        expectEqual(route(35, "p", shift: true), .swallow, "⇧⌘P (Pair iPhone…)")
        for chars in ["c", "v", "x", "a", "z"] { expectEqual(route(0, chars), .pass, "⌘\(chars) edits the field") }
        expectEqual(route(6, "z", shift: true), .pass, "⇧⌘Z redoes")
        expectEqual(route(49, " ", control: true), .pass, "⌃⌘Space: the emoji picker")
        expectEqual(route(40, "k", control: true), .swallow)
    }

    static func rowsFromItems() throws {
        let items = try DockInbox.decode(Fixture.inboxData()).items
        let pairing = DockKeyRow(items.first { $0.id == "t3:th_pairing_redirect" }!)
        expectEqual(pairing, DockKeyRow(id: "t3:th_pairing_redirect", canOpen: true, canReply: true, canDismiss: true,
                                        approval: (requestId: "req_run_tests", decision: "accept")))
        // The CLI owns its own prompt: Open only, no inline approve (it can still be dismissed).
        let cli = DockKeyRow(items.first { $0.id.hasPrefix("claude:5d0c") }!)
        expectEqual(cli, DockKeyRow(id: cli.id, canOpen: true, canReply: false, canDismiss: true, approval: nil))
    }

    static func xDismissesTheSelectedRow() throws {
        let rows = [DockKeyRow(id: "a", canDismiss: true), DockKeyRow(id: "b", canDismiss: true),
                    DockKeyRow(id: "c", canDismiss: false)]
        expectEqual(DockKeyboard.action(for: .dismiss, rows: rows, selected: "a", expanded: nil), .dismiss("a"))
        expectEqual(DockKeyboard.action(for: .dismiss, rows: rows, selected: "b", expanded: "b"), .dismiss("b"),
                    "an open row too")
        expectEqual(DockKeyboard.action(for: .dismiss, rows: rows, selected: "c", expanded: nil), .none,
                    "a bridge that can't dismiss it")
        expectEqual(DockKeyboard.action(for: .dismiss, rows: rows, selected: nil, expanded: nil), .none,
                    "nothing selected: nothing goes")
        expectEqual(DockKeyboard.action(for: .dismiss, rows: rows, selected: "gone", expanded: nil), .none)
        // The selection moves on, so X X X clears a run of rows.
        let ids = ["a", "b", "c"]
        expectEqual(DockKeyboard.selection(afterDismissing: "a", rows: ids), "b")
        expectEqual(DockKeyboard.selection(afterDismissing: "c", rows: ids), "b", "the last one: the row before it")
        expectEqual(DockKeyboard.selection(afterDismissing: "a", rows: ["a"]), nil)
        expectEqual(DockKeyboard.selection(afterDismissing: "z", rows: ids), nil)
    }
}
