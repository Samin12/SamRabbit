import Foundation

// The dock's four global shortcuts as data (CONTRACTS-WAVE7 §B2): ⌃⌥Space talk, ⌃⌥K the list on compose, ⌃⌥D show /
// hide, ⌃⌥M minimize / expand. Each can be recorded anew in Settings. Pure (no AppKit, no Carbon): key codes are the
// Mac's virtual key codes (the key's place on the keyboard, which is what Carbon's RegisterEventHotKey takes),
// modifiers Carbon's bits, and NSEvent's modifier bits are spelled out where a recorded key comes in, so tests/swift
// pins the names, the parsing and the rules. DockShortcutCenter registers them.

/// A key and its modifiers, the way RegisterEventHotKey takes them.
struct DockShortcut: Hashable {
    let keyCode: UInt32
    /// Carbon modifier bits (cmdKey, shiftKey, optionKey, controlKey).
    let modifiers: UInt32

    static let command: UInt32 = 0x0100
    static let shift: UInt32 = 0x0200
    static let option: UInt32 = 0x0800
    static let control: UInt32 = 0x1000

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers & (Self.command | Self.shift | Self.option | Self.control)
    }

    var hasControl: Bool { modifiers & Self.control != 0 }
    var hasOption: Bool { modifiers & Self.option != 0 }
    var hasShift: Bool { modifiers & Self.shift != 0 }
    var hasCommand: Bool { modifiers & Self.command != 0 }

    /// The modifiers in the Mac's order (⌃⌥⇧⌘).
    var modifierGlyphs: String {
        (hasControl ? "⌃" : "") + (hasOption ? "⌥" : "") + (hasShift ? "⇧" : "") + (hasCommand ? "⌘" : "")
    }

    /// The key's name ("Space", "D", "F5", "↩"); nil for a key the dock doesn't offer.
    var keyName: String? { DockKeys.name(keyCode) }

    /// "⌃⌥Space", as menus and Settings show it (and as UserDefaults keeps it).
    var display: String { modifierGlyphs + (keyName ?? "Key \(keyCode)") }

    var isFunctionKey: Bool { DockKeys.functionKeys.contains(keyCode) }

    /// A recorded key: NSEvent's key code and modifier flags (raw: ⇧ 1<<17, ⌃ 1<<18, ⌥ 1<<19, ⌘ 1<<20).
    static func from(keyCode: UInt16, modifierFlags: UInt) -> DockShortcut {
        var modifiers: UInt32 = 0
        if modifierFlags & (1 << 17) != 0 { modifiers |= shift }
        if modifierFlags & (1 << 18) != 0 { modifiers |= control }
        if modifierFlags & (1 << 19) != 0 { modifiers |= option }
        if modifierFlags & (1 << 20) != 0 { modifiers |= command }
        return DockShortcut(keyCode: UInt32(keyCode), modifiers: modifiers)
    }

    /// The glyphs of modifier flags alone (what the recorder shows while they are held).
    static func glyphs(modifierFlags: UInt) -> String {
        from(keyCode: 0, modifierFlags: modifierFlags).modifierGlyphs
    }

    /// "⌃⌥Space", "⌃⌥D", "control+option+space", "ctrl-alt-d", "cmd+shift+F5": nil when it isn't one.
    static func parse(_ text: String) -> DockShortcut? {
        var rest = Substring(text.trimmingCharacters(in: .whitespaces))
        var modifiers: UInt32 = 0
        let glyphs: [Character: UInt32] = ["⌃": control, "⌥": option, "⇧": shift, "⌘": command]
        while let first = rest.first, let bit = glyphs[first] {
            modifiers |= bit
            rest = rest.dropFirst()
        }
        // Words joined by + or - ("ctrl+opt+space"); a lone "-" or "+" is the key itself.
        let words: [Substring]
        if rest.count > 1, rest.contains(where: { $0 == "+" || $0 == "-" }) {
            var parts = rest.split(omittingEmptySubsequences: false) { $0 == "+" || $0 == "-" }
            // "ctrl+-" / "cmd++": the empty piece at the end was the key.
            if parts.count >= 2, parts.last == "", parts[parts.count - 2] == "" {
                parts.removeLast(2)
                parts.append(rest.last == "+" ? "=" : "-")
            }
            words = parts
        } else {
            words = [rest]
        }
        guard let keyWord = words.last, !keyWord.isEmpty else { return nil }
        let names: [String: UInt32] = ["ctrl": control, "control": control, "opt": option, "option": option, "alt": option,
                                       "shift": shift, "cmd": command, "command": command]
        for word in words.dropLast() {
            guard let bit = names[word.lowercased()] else { return nil }
            modifiers |= bit
        }
        guard let code = DockKeys.code(String(keyWord)) else { return nil }
        return DockShortcut(keyCode: code, modifiers: modifiers)
    }

    /// What an NSMenuItem shows as its key equivalent (its character; arrows and F-keys are AppKit's function-key
    /// characters), and the modifiers in NSEvent's raw bits.
    var menuKey: String? { DockKeys.menuKey(keyCode) }

    var menuModifierFlags: UInt {
        (hasShift ? 1 << 17 : 0) | (hasControl ? 1 << 18 : 0) | (hasOption ? 1 << 19 : 0) | (hasCommand ? 1 << 20 : 0)
    }
}

/// The four things a shortcut does.
enum DockShortcutAction: String, CaseIterable, Identifiable {
    case talk, compose, showHide, minimize

    var id: String { rawValue }

    var label: String {
        switch self {
        case .talk: return "Talk to SamRabbit"
        case .compose: return "New task"
        case .showHide: return "Show / hide the dock"
        case .minimize: return "Minimize / expand"
        }
    }

    var detail: String {
        switch self {
        case .talk: return "Starts a voice conversation, or ends the one that is on."
        case .compose: return "Opens the dock’s list with the cursor in “Ask an agent…”."
        case .showHide: return "Hides the dock until pressed again; brings it to the screen you are on."
        case .minimize: return "Folds the dock into the orb, and back into the pill."
        }
    }

    var defaultShortcut: DockShortcut {
        let controlOption = DockShortcut.control | DockShortcut.option
        switch self {
        case .talk: return DockShortcut(keyCode: DockKeys.space, modifiers: controlOption)
        case .compose: return DockShortcut(keyCode: 40, modifiers: controlOption)   // K
        case .showHide: return DockShortcut(keyCode: 2, modifiers: controlOption)   // D
        case .minimize: return DockShortcut(keyCode: 46, modifiers: controlOption)  // M
        }
    }
}

/// One of macOS's own keyboard shortcuts (System Settings › Keyboard › Keyboard Shortcuts) as Carbon's
/// CopySymbolicHotKeys lists it: the key code, Carbon modifier bits (with the fn bit on F keys and arrows), and
/// whether it is on. macOS takes such a combination before any app sees it.
struct DockSystemShortcut: Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let enabled: Bool
}

/// The rules over the four shortcuts: which combinations can be one, and how they are kept.
enum DockShortcuts {
    static let defaults: [DockShortcutAction: DockShortcut] =
        Dictionary(uniqueKeysWithValues: DockShortcutAction.allCases.map { ($0, $0.defaultShortcut) })

    /// What the system or other apps already use, which a global shortcut would take from them.
    static let reserved: [DockShortcut: String] = {
        let c = DockShortcut.control, o = DockShortcut.option, cmd = DockShortcut.command, s = DockShortcut.shift
        var list: [DockShortcut: String] = [
            DockShortcut(keyCode: 12, modifiers: c | cmd): "Lock Screen",
            DockShortcut(keyCode: DockKeys.space, modifiers: c | cmd): "the emoji picker",
            DockShortcut(keyCode: 3, modifiers: c | cmd): "full screen",
            DockShortcut(keyCode: DockKeys.space, modifiers: c): "switching the input source",
            DockShortcut(keyCode: DockKeys.space, modifiers: o | cmd): "Finder search",
        ]
        for arrow in [DockKeys.left, DockKeys.right, DockKeys.up, DockKeys.down] {
            list[DockShortcut(keyCode: arrow, modifiers: c)] = "Mission Control and Spaces"
        }
        for digit: UInt32 in [20, 21, 23] {  // 3, 4, 5
            list[DockShortcut(keyCode: digit, modifiers: s | cmd)] = "screenshots"
        }
        return list
    }()

    /// Why `shortcut` can't be `action`'s (nil = it can): a global shortcut must not take a key Samin types with, an
    /// app's own ⌘ shortcut or a macOS one, and the four must differ.
    static func problem(_ shortcut: DockShortcut, for action: DockShortcutAction,
                        among bindings: [DockShortcutAction: DockShortcut]) -> String? {
        guard let name = shortcut.keyName else { return "That key can’t be a shortcut." }
        if shortcut.keyCode == DockKeys.escape { return "Esc cancels recording: choose another key." }
        if let what = reserved[shortcut] { return "\(shortcut.display) is macOS’s shortcut for \(what)." }
        if !shortcut.isFunctionKey {
            if shortcut.modifiers == 0 || shortcut.modifiers == DockShortcut.shift {
                return "Add ⌃ or ⌥⌘ to \(name)."
            }
            if !shortcut.hasControl && !shortcut.hasCommand {
                return "⌥ alone types characters (⌥E is “é”): add ⌃ or ⌘."
            }
            if !shortcut.hasControl && !shortcut.hasOption {
                return "⌘ alone is an app’s own shortcut: add ⌃ or ⌥."
            }
        }
        if let other = DockShortcutAction.allCases.first(where: { $0 != action && bindings[$0] == shortcut }) {
            return "\(shortcut.display) is already “\(other.label)”."
        }
        return nil
    }

    /// macOS has `shortcut` itself and it is on (the fn bit and any bits that aren't ⌃⌥⇧⌘ don't count).
    static func takenBySystem(_ shortcut: DockShortcut, _ system: [DockSystemShortcut]) -> Bool {
        system.contains { $0.enabled && DockShortcut(keyCode: $0.keyCode, modifiers: $0.modifiers) == shortcut }
    }

    /// The saved shortcuts (UserDefaults keeps only the changed ones, as "⌃⌥D"); anything unreadable is the default.
    static func load(_ saved: [String: Any]?) -> [DockShortcutAction: DockShortcut] {
        var bindings = defaults
        for action in DockShortcutAction.allCases {
            guard let text = saved?[action.rawValue] as? String, let shortcut = DockShortcut.parse(text) else { continue }
            bindings[action] = shortcut
        }
        return bindings
    }

    static func saved(_ bindings: [DockShortcutAction: DockShortcut]) -> [String: String] {
        var saved: [String: String] = [:]
        for action in DockShortcutAction.allCases {
            if let shortcut = bindings[action], shortcut != action.defaultShortcut { saved[action.rawValue] = shortcut.display }
        }
        return saved
    }
}

/// The keys a shortcut can use, by virtual key code (the US layout's names; the code is the key's place, so on
/// another layout the same place keeps working).
enum DockKeys {
    static let space: UInt32 = 49
    static let escape: UInt32 = 53
    static let left: UInt32 = 123
    static let right: UInt32 = 124
    static let down: UInt32 = 125
    static let up: UInt32 = 126

    static let functionKeys: Set<UInt32> = Set(functionCodes)
    /// F1…F20 in order.
    static let functionCodes: [UInt32] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]

    private static let table: [(UInt32, String)] = {
        var table: [(UInt32, String)] = [
            (0, "A"), (11, "B"), (8, "C"), (2, "D"), (14, "E"), (3, "F"), (5, "G"), (4, "H"), (34, "I"), (38, "J"),
            (40, "K"), (37, "L"), (46, "M"), (45, "N"), (31, "O"), (35, "P"), (12, "Q"), (15, "R"), (1, "S"), (17, "T"),
            (32, "U"), (9, "V"), (13, "W"), (7, "X"), (16, "Y"), (6, "Z"),
            (29, "0"), (18, "1"), (19, "2"), (20, "3"), (21, "4"), (23, "5"), (22, "6"), (26, "7"), (28, "8"), (25, "9"),
            (27, "-"), (24, "="), (33, "["), (30, "]"), (42, "\\"), (41, ";"), (39, "'"), (43, ","), (47, "."), (44, "/"),
            (50, "`"),
            (space, "Space"), (36, "↩"), (48, "⇥"), (51, "⌫"), (117, "⌦"), (escape, "⎋"),
            (left, "←"), (right, "→"), (down, "↓"), (up, "↑"), (115, "↖"), (119, "↘"), (116, "⇞"), (121, "⇟"),
        ]
        for (index, code) in functionCodes.enumerated() { table.append((code, "F\(index + 1)")) }
        return table
    }()

    private static let names: [UInt32: String] = Dictionary(uniqueKeysWithValues: table)

    private static let codes: [String: UInt32] = {
        var codes: [String: UInt32] = [:]
        for (code, name) in table { codes[name.lowercased()] = code }
        let aliases: [String: UInt32] = [
            "spacebar": space, "return": 36, "enter": 36, "tab": 48, "delete": 51, "backspace": 51,
            "forwarddelete": 117, "esc": escape, "escape": escape, "left": left, "right": right, "down": down, "up": up,
            "home": 115, "end": 119, "pageup": 116, "pagedown": 121, "minus": 27, "equal": 24, "plus": 24,
        ]
        codes.merge(aliases) { first, _ in first }
        return codes
    }()

    static func name(_ code: UInt32) -> String? { names[code] }

    static func code(_ name: String) -> UInt32? {
        codes[name.lowercased().replacingOccurrences(of: " ", with: "")]
    }

    static func menuKey(_ code: UInt32) -> String? {
        if let index = functionCodes.firstIndex(of: code) { return String(UnicodeScalar(0xF704 + index)!) }
        switch code {
        case space: return " "
        case 36: return "\r"
        case 48: return "\t"
        case 51: return "\u{8}"
        case escape: return "\u{1b}"
        case 117: return String(UnicodeScalar(0xF728)!)
        case up: return String(UnicodeScalar(0xF700)!)
        case down: return String(UnicodeScalar(0xF701)!)
        case left: return String(UnicodeScalar(0xF702)!)
        case right: return String(UnicodeScalar(0xF703)!)
        case 115: return String(UnicodeScalar(0xF729)!)
        case 119: return String(UnicodeScalar(0xF72B)!)
        case 116: return String(UnicodeScalar(0xF72C)!)
        case 121: return String(UnicodeScalar(0xF72D)!)
        default:
            guard let name = names[code], name.count == 1 else { return nil }
            return name.lowercased()
        }
    }
}
