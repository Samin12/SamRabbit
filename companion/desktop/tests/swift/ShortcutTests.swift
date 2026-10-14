import Foundation

/// The four global shortcuts as data (DockShortcut.swift): names, parsing, recorded keys, the rules Settings applies
/// and how they are kept.
enum ShortcutTests {
    static let all: [(String, () throws -> Void)] = [
        ("defaults", defaults),
        ("parsesWhatPeopleWrite", parsesWhatPeopleWrite),
        ("refusesWhatIsNotAShortcut", refusesWhatIsNotAShortcut),
        ("displayRoundTrips", displayRoundTrips),
        ("recordedKeys", recordedKeys),
        ("rules", rules),
        ("keptOnlyWhenChanged", keptOnlyWhenChanged),
        ("menuKeys", menuKeys),
    ]

    static let controlOption = DockShortcut.control | DockShortcut.option

    static func defaults() throws {
        expectEqual(DockShortcutAction.allCases.map { $0.defaultShortcut.display }, ["⌃⌥Space", "⌃⌥K", "⌃⌥D", "⌃⌥M"])
        expectEqual(DockShortcuts.defaults[.talk], DockShortcut(keyCode: 49, modifiers: controlOption))
        expectEqual(DockShortcuts.defaults.count, 4)
        // The defaults pass the rules, and differ from each other.
        for action in DockShortcutAction.allCases {
            expect(DockShortcuts.problem(action.defaultShortcut, for: action, among: DockShortcuts.defaults) == nil, "\(action)")
        }
        expectEqual(Set(DockShortcuts.defaults.values).count, 4)
    }

    static func parsesWhatPeopleWrite() throws {
        let d = DockShortcut(keyCode: 2, modifiers: controlOption)
        expectEqual(DockShortcut.parse("⌃⌥D"), d)
        expectEqual(DockShortcut.parse("  ⌥⌃d "), d, "glyphs in any order, any case")
        expectEqual(DockShortcut.parse("ctrl-alt-d"), d)
        expectEqual(DockShortcut.parse("Control+Option+D"), d)
        expectEqual(DockShortcut.parse("control+option+space"), DockShortcuts.defaults[.talk])
        expectEqual(DockShortcut.parse("⌃⌥Space"), DockShortcuts.defaults[.talk])
        expectEqual(DockShortcut.parse("cmd+shift+F5"), DockShortcut(keyCode: 96, modifiers: DockShortcut.command | DockShortcut.shift))
        expectEqual(DockShortcut.parse("⌃⌥F12"), DockShortcut(keyCode: 111, modifiers: controlOption))
        expectEqual(DockShortcut.parse("F5"), DockShortcut(keyCode: 96, modifiers: 0))
        expectEqual(DockShortcut.parse("⌃⌥Page Up"), DockShortcut(keyCode: 116, modifiers: controlOption))
        expectEqual(DockShortcut.parse("ctrl+alt+return"), DockShortcut(keyCode: 36, modifiers: controlOption))
        // The minus and plus keys, also where - and + join the words.
        expectEqual(DockShortcut.parse("⌃⌥-"), DockShortcut(keyCode: 27, modifiers: controlOption))
        expectEqual(DockShortcut.parse("ctrl+-"), DockShortcut(keyCode: 27, modifiers: DockShortcut.control))
        expectEqual(DockShortcut.parse("ctrl-alt--"), DockShortcut(keyCode: 27, modifiers: controlOption))
        expectEqual(DockShortcut.parse("cmd++"), DockShortcut(keyCode: 24, modifiers: DockShortcut.command))
        expectEqual(DockShortcut.parse("⌃⌥="), DockShortcut(keyCode: 24, modifiers: controlOption))
    }

    static func refusesWhatIsNotAShortcut() throws {
        for text in ["", "   ", "⌃⌥", "ctrl+", "hyper+d", "⌃⌥Banana", "ctrl+alt", "control option d", "⌃⌥dd", "fn+d"] {
            expect(DockShortcut.parse(text) == nil, "“\(text)” is not a shortcut")
        }
    }

    static func displayRoundTrips() throws {
        // Every key the dock offers, with each mix of modifiers: what is shown parses back to the same shortcut.
        let mixes: [UInt32] = [0, DockShortcut.control, controlOption, DockShortcut.command | DockShortcut.option,
                               DockShortcut.control | DockShortcut.shift | DockShortcut.command,
                               DockShortcut.control | DockShortcut.option | DockShortcut.shift | DockShortcut.command]
        var keys = 0
        for code in UInt32(0)..<UInt32(200) where DockKeys.name(code) != nil {
            keys += 1
            for modifiers in mixes {
                let shortcut = DockShortcut(keyCode: code, modifiers: modifiers)
                expectEqual(DockShortcut.parse(shortcut.display), shortcut, "\(shortcut.display)")
            }
        }
        expectEqual(keys, 26 + 10 + 11 + 6 + 8 + 20, "letters, digits, punctuation, ↩⇥⌫⌦␣⎋, arrows and paging, F1–F20")
        // The modifiers in the Mac's order, whatever order they were given in.
        expectEqual(DockShortcut(keyCode: 0, modifiers: DockShortcut.command | DockShortcut.shift | DockShortcut.option | DockShortcut.control).display, "⌃⌥⇧⌘A")
        expectEqual(DockShortcut(keyCode: 999, modifiers: controlOption).display, "⌃⌥Key 999")
        // Bits that aren't modifiers (caps lock, Carbon's others) are dropped.
        expectEqual(DockShortcut(keyCode: 2, modifiers: controlOption | 0x0400 | 0x4000), DockShortcut(keyCode: 2, modifiers: controlOption))
    }

    static func recordedKeys() throws {
        // NSEvent's raw flags: ⇧ 1<<17, ⌃ 1<<18, ⌥ 1<<19, ⌘ 1<<20; caps lock (1<<16) and fn (1<<23) are not modifiers here.
        let flags: UInt = (1 << 18) | (1 << 19) | (1 << 16) | (1 << 23)
        expectEqual(DockShortcut.from(keyCode: 46, modifierFlags: flags), DockShortcut(keyCode: 46, modifiers: controlOption))
        expectEqual(DockShortcut.from(keyCode: 49, modifierFlags: (1 << 17) | (1 << 20)).display, "⇧⌘Space")
        expectEqual(DockShortcut.glyphs(modifierFlags: (1 << 20) | (1 << 17) | (1 << 19) | (1 << 18)), "⌃⌥⇧⌘")
        expectEqual(DockShortcut.glyphs(modifierFlags: 1 << 16), "", "caps lock alone is nothing held")
    }

    static func rules() throws {
        let bindings = DockShortcuts.defaults
        func problem(_ code: UInt32, _ modifiers: UInt32, _ action: DockShortcutAction = .showHide) -> String? {
            DockShortcuts.problem(DockShortcut(keyCode: code, modifiers: modifiers), for: action, among: bindings)
        }
        let s = DockShortcut.shift, c = DockShortcut.control, o = DockShortcut.option, cmd = DockShortcut.command
        // Fine: ⌃ with anything, ⌥⌘, and the F keys alone.
        expect(problem(7, c | o) == nil, "⌃⌥X")
        expect(problem(7, c) == nil, "⌃X")
        expect(problem(7, o | cmd) == nil, "⌥⌘X")
        expect(problem(7, c | s | cmd) == nil, "⌃⇧⌘X")
        expect(problem(96, 0) == nil, "F5 alone")
        // Keys he types with.
        expectEqual(problem(7, 0), "Add ⌃ or ⌥⌘ to X.")
        expectEqual(problem(7, s), "Add ⌃ or ⌥⌘ to X.")
        expectEqual(problem(14, o), "⌥ alone types characters (⌥E is “é”): add ⌃ or ⌘.")
        expectEqual(problem(14, o | s), "⌥ alone types characters (⌥E is “é”): add ⌃ or ⌘.")
        expectEqual(problem(7, cmd), "⌘ alone is an app’s own shortcut: add ⌃ or ⌥.")
        expectEqual(problem(7, cmd | s), "⌘ alone is an app’s own shortcut: add ⌃ or ⌥.")
        // Esc cancels the recorder; a key the dock doesn't know can't be one.
        expectEqual(problem(53, c | o), "Esc cancels recording: choose another key.")
        expectEqual(problem(999, c | o), "That key can’t be a shortcut.")
        // macOS's own.
        expectEqual(problem(12, c | cmd), "⌃⌘Q is macOS’s shortcut for Lock Screen.")
        expectEqual(problem(49, c), "⌃Space is macOS’s shortcut for switching the input source.")
        expectEqual(problem(123, c), "⌃← is macOS’s shortcut for Mission Control and Spaces.")
        expectEqual(problem(21, s | cmd), "⇧⌘4 is macOS’s shortcut for screenshots.")
        // The four differ; an action may keep its own.
        expectEqual(problem(40, c | o, .showHide), "⌃⌥K is already “New task”.")
        expectEqual(problem(49, c | o, .minimize), "⌃⌥Space is already “Talk to SamRabbit”.")
        expect(problem(2, c | o, .showHide) == nil, "⌃⌥D for show / hide is its own")
    }

    static func keptOnlyWhenChanged() throws {
        // Nothing saved: the defaults; nothing to save for the defaults.
        expectEqual(DockShortcuts.load(nil), DockShortcuts.defaults)
        expectEqual(DockShortcuts.saved(DockShortcuts.defaults), [:])
        // One recorded anew: only it is kept, as it is shown.
        var bindings = DockShortcuts.defaults
        bindings[.minimize] = DockShortcut(keyCode: 31, modifiers: controlOption)
        bindings[.talk] = DockShortcut(keyCode: 96, modifiers: 0)
        let saved = DockShortcuts.saved(bindings)
        expectEqual(saved, ["minimize": "⌃⌥O", "talk": "F5"])
        expectEqual(DockShortcuts.load(saved), bindings, "and read back")
        // Anything unreadable is the default.
        let odd: [String: Any] = ["minimize": "⌃⌥Banana", "talk": 42, "showHide": "", "compose": "⌃⌥J", "other": "⌃⌥Q"]
        var expected = DockShortcuts.defaults
        expected[.compose] = DockShortcut(keyCode: 38, modifiers: controlOption)
        expectEqual(DockShortcuts.load(odd), expected)
    }

    static func menuKeys() throws {
        // What NSMenuItem shows: the key's character (AppKit's function-key characters for F keys and arrows).
        expectEqual(DockShortcutAction.talk.defaultShortcut.menuKey, " ")
        expectEqual(DockShortcutAction.showHide.defaultShortcut.menuKey, "d")
        expectEqual(DockShortcut(keyCode: 96, modifiers: 0).menuKey, "\u{F708}", "F5")
        expectEqual(DockShortcut(keyCode: 122, modifiers: 0).menuKey, "\u{F704}", "F1")
        expectEqual(DockShortcut(keyCode: 126, modifiers: 0).menuKey, "\u{F700}", "↑")
        expectEqual(DockShortcut(keyCode: 36, modifiers: 0).menuKey, "\r")
        expectEqual(DockShortcut(keyCode: 27, modifiers: 0).menuKey, "-")
        expect(DockShortcut(keyCode: 999, modifiers: 0).menuKey == nil)
        // NSEvent's raw modifier bits.
        expectEqual(DockShortcutAction.minimize.defaultShortcut.menuModifierFlags, (1 << 18) | (1 << 19))
        expectEqual(DockShortcut(keyCode: 0, modifiers: DockShortcut.shift | DockShortcut.command).menuModifierFlags, (1 << 17) | (1 << 20))
    }
}
