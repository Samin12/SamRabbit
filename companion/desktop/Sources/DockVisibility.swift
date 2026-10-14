import Foundation

// When the Agent Dock is on screen, and when its list is open. Pure rules (no AppKit, no timers), so tests/swift can
// pin the behaviour; DockController feeds them what AppKit says and carries out what they answer.

/// What decides whether the dock shows.
struct DockVisibilityInput: Equatable {
    var enabled = true
    var hiddenUntil: Date?
    var now = Date()
    /// SamRabbit is the frontmost app.
    var appActive = false
    var mainWindowVisible = false
    var mainWindowKey = false
    var mainWindowMinimized = false
    /// A voice conversation is on: the voice bar is its only control (stop, mute, end), so it always shows.
    var voiceActive = false
    /// A voice note is recording, being sent, or saying how it went (CONTRACTS-WAVE8 §D1): its bar is the live
    /// microphone and its only control, so it shows like the voice bar.
    var noteActive = false
    /// Samin asked for it (⌃⌥K, "Show Agent Dock", a notification): it shows until he lets the list close.
    var summoned = false
    /// ⌃⌥D put it away: hidden until he presses it again (DockPresence).
    var userHidden = false
    /// ⌃⌥D (or ⌃⌥M) brought it back while he is in the main window, where it otherwise steps aside (DockPresence).
    var overApp = false
}

enum DockVisibility {
    enum Reason: String, Equatable {
        case voice, note, summoned, off, userHidden, hiddenForAWhile, inApp, shown
    }

    static func reason(_ input: DockVisibilityInput) -> Reason {
        // A live microphone is never out of sight: the voice bar shows through every hide.
        if input.voiceActive { return .voice }
        if input.noteActive { return .note }
        if input.summoned { return .summoned }
        if !input.enabled { return .off }
        if input.userHidden { return .userHidden }
        if let until = input.hiddenUntil, until > input.now { return .hiddenForAWhile }
        // It steps aside while Samin is in the main window: there the app already shows all of this, bigger. It is
        // back as soon as the window is minimised, closed or hidden, or another app is in front.
        if inMainWindow(input) && !input.overApp { return .inApp }
        return .shown
    }

    static func shows(_ input: DockVisibilityInput) -> Bool {
        switch reason(input) {
        case .voice, .note, .summoned, .shown: return true
        case .off, .userHidden, .hiddenForAWhile, .inApp: return false
        }
    }

    /// Samin is working in the main window (SamRabbit in front, the window visible, key and not minimised).
    static func inMainWindow(_ input: DockVisibilityInput) -> Bool {
        input.appActive && input.mainWindowVisible && input.mainWindowKey && !input.mainWindowMinimized
    }

    /// The ways to hide it for a while. Both come back by themselves; only "Turn off" (persisted) is for good, and
    /// turning it back on lives in the menu bar extra and the main menu.
    enum HideChoice: String, CaseIterable {
        case hour, tomorrow

        var label: String {
            switch self {
            case .hour: return "Hide for 1 Hour"
            case .tomorrow: return "Hide Until Tomorrow"
            }
        }
    }

    static func hiddenUntil(_ choice: HideChoice, now: Date, calendar: Calendar = .current) -> Date {
        switch choice {
        case .hour:
            return now.addingTimeInterval(3600)
        case .tomorrow:
            let startOfToday = calendar.startOfDay(for: now)
            return calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? now.addingTimeInterval(86_400)
        }
    }
}

/// Samin's own say over the dock, beside the rules above (CONTRACTS-WAVE7 §B2): ⌃⌥D shows and hides it (hidden
/// lasts until he presses it again; pressed while the dock is on another screen it brings the dock to his), and ⌃⌥M,
/// the "–" on the pill, "Minimize to Orb" or a click on the orb fold it to the orb and back. The menus' Hide / Show /
/// Minimize do what the keys do without looking at the pointer: a menu item never moves the dock to another screen.
/// Pure, like the rest of this file: the controller keeps `hidden` and `minimized` in UserDefaults and carries out the
/// effects.
struct DockPresence: Equatable {
    /// ⌃⌥D or "Hide Agent Dock" put it away: until ⌃⌥D again or "Show Agent Dock" (⌃⌥K shows it with its list until
    /// that closes).
    var hidden = false
    /// Folded to the orb.
    var minimized = false
    /// ⌃⌥D (or ⌃⌥M) brought it back while Samin is in the main window, where it would step aside: it stays until he
    /// leaves the app or the window (a click in the dock giving it the keys is not leaving), then the rules are back.
    var overApp = false

    enum Form: Equatable {
        case pill, orb, voiceBar
    }

    enum Event: Equatable {
        /// ⌃⌥D. `elsewhere`: the dock is (or would come back) on another screen than the pointer's.
        case toggleShown(elsewhere: Bool)
        /// "Hide Agent Dock" / "Hide the Dock" in a menu: put away where it is. A menu never asks where the pointer
        /// is (in the menu bar extra it is on the menu bar's display, maybe not the dock's).
        case putAway
        /// "Show Agent Dock" in the menu bar extra: back as it was and where it was (⌃⌥D's reveal, never moved).
        case bringBack
        /// ⌃⌥M (`elsewhere` as for ⌃⌥D), "Minimize to Orb" / "Expand the Dock" in the menus (never elsewhere).
        case toggleMinimized(elsewhere: Bool)
        /// The "–" on the pill.
        case minimize
        /// A click on the orb.
        case expand
        /// "Show Agent Dock" (the menu bar extra, the app menu, Settings).
        case showFromMenu
    }

    enum Effect: Equatable {
        /// It was turned off: turn it on again.
        case turnOn
        /// It was hidden for a while: that hide is over.
        case endHide
        /// Move it to the screen the pointer is on.
        case bringHere
        /// It goes away: the list closes with it.
        case closeList
    }

    /// What the pill window draws: during a conversation always the voice bar, and the orb again after it.
    func form(voiceActive: Bool) -> Form {
        voiceActive ? .voiceBar : (minimized ? .orb : .pill)
    }

    /// The visibility input with Samin's say in it.
    func applied(to input: DockVisibilityInput) -> DockVisibilityInput {
        var input = input
        input.userHidden = hidden
        input.overApp = overApp
        return input
    }

    mutating func handle(_ event: Event, _ input: DockVisibilityInput) -> [Effect] {
        switch event {
        case .toggleShown(let elsewhere):
            let now = applied(to: input)
            if DockVisibility.shows(now) && !hidden {
                // On screen somewhere else: here it comes, still shown. On screen here: put away until pressed again
                // (the voice bar of a conversation stays until it ends).
                if elsewhere { return [.bringHere] }
                hidden = true
                overApp = false
                return [.closeList]
            }
            return reveal(input, elsewhere: elsewhere)

        case .putAway:
            hidden = true
            overApp = false
            return [.closeList]

        case .bringBack:
            return reveal(input, elsewhere: false)

        case .toggleMinimized(let elsewhere):
            minimized.toggle()
            // Folding a dock that isn't on screen shows it, in its new shape.
            return DockVisibility.shows(applied(to: input)) ? [] : reveal(input, elsewhere: elsewhere)

        case .minimize:
            minimized = true
            return []

        case .expand:
            minimized = false
            return []

        case .showFromMenu:
            hidden = false
            return []
        }
    }

    /// After every look at the windows: "over the app" ends once Samin has left the app or its main window.
    mutating func settle(_ input: DockVisibilityInput) {
        guard overApp else { return }
        if !input.appActive || !input.mainWindowVisible || input.mainWindowMinimized { overApp = false }
    }

    /// Back on screen, as it was (pill or orb, its spot): whatever kept it away is lifted.
    private mutating func reveal(_ input: DockVisibilityInput, elsewhere: Bool) -> [Effect] {
        var effects: [Effect] = []
        hidden = false
        if !input.enabled { effects.append(.turnOn) }
        if let until = input.hiddenUntil, until > input.now { effects.append(.endHide) }
        if DockVisibility.inMainWindow(input) { overApp = true }
        if elsewhere { effects.append(.bringHere) }
        return effects
    }
}

/// The list's open/closed state. Pointing at the pill for a moment opens it; it closes shortly after the pointer has
/// left both the pill and the list. A click (on the pill, or anywhere in the list), ⌃⌥K or a notification pins it open:
/// then it stays until Esc, a click on the pill, or a click somewhere else. Typing never gets closed under the pointer.
struct DockExpansion: Equatable {
    enum Phase: Equatable {
        case collapsed
        case pendingOpen
        case open(pinned: Bool)
    }

    enum Event: Equatable {
        case pointer(overPill: Bool, overPanel: Bool)
        case openTimer
        case closeTimer
        case clickPill
        case summon
        case interact
        case escape
        case clickOutside
        case editing(Bool)
        case dragStarted
        case dragEnded
        case voiceStarted
        case hidden
    }

    enum Effect: Equatable {
        case scheduleOpen, cancelOpen, scheduleClose, cancelClose, show, hide
    }

    static let openDelay: TimeInterval = 0.35
    static let closeDelay: TimeInterval = 0.45

    private(set) var phase: Phase = .collapsed
    private(set) var closing = false
    private(set) var editing = false
    private(set) var overPill = false
    private(set) var overPanel = false
    /// After a drag the pointer is still on the pill: the list waits for it to leave and come back.
    private(set) var settling = false

    var isOpen: Bool {
        if case .open = phase { return true }
        return false
    }

    var isPinned: Bool { phase == .open(pinned: true) }

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .pointer(let pill, let panel):
            overPill = pill
            overPanel = panel
            if !pill { settling = false }
            switch phase {
            case .collapsed:
                guard pill, !settling else { return [] }
                phase = .pendingOpen
                return [.scheduleOpen]
            case .pendingOpen:
                guard !pill else { return [] }
                phase = .collapsed
                return [.cancelOpen]
            case .open(pinned: false):
                return reconsiderClose()
            case .open(pinned: true):
                return []
            }

        case .openTimer:
            guard phase == .pendingOpen else { return [] }
            if overPill && !settling {
                phase = .open(pinned: false)
                return [.show] + reconsiderClose()
            }
            phase = .collapsed
            return []

        case .closeTimer:
            guard closing else { return [] }
            closing = false
            guard phase == .open(pinned: false), !overPill, !overPanel, !editing else { return [] }
            phase = .collapsed
            return [.hide]

        case .clickPill:
            if isOpen { return collapse() }
            let wasPending = phase == .pendingOpen
            phase = .open(pinned: true)
            return (wasPending ? [.cancelOpen] : []) + [.show]

        case .summon:
            let effects: [Effect] = isOpen ? [] : [.show]
            let cancel: [Effect] = phase == .pendingOpen ? [.cancelOpen] : []
            let stopClosing: [Effect] = closing ? [.cancelClose] : []
            closing = false
            phase = .open(pinned: true)
            return cancel + stopClosing + effects

        case .interact:
            guard isOpen else { return [] }
            let effects: [Effect] = closing ? [.cancelClose] : []
            closing = false
            phase = .open(pinned: true)
            return effects

        case .escape:
            return isOpen ? collapse() : []

        case .clickOutside:
            guard isOpen, !overPill, !overPanel else { return [] }
            return collapse()

        case .editing(let on):
            editing = on
            guard phase == .open(pinned: false) else { return [] }
            return reconsiderClose()

        case .dragStarted:
            settling = true
            if phase == .pendingOpen {
                phase = .collapsed
                return [.cancelOpen]
            }
            return isOpen ? collapse() : []

        case .dragEnded:
            settling = true
            return []

        case .voiceStarted:
            switch phase {
            case .pendingOpen:
                phase = .collapsed
                return [.cancelOpen]
            case .open(pinned: false):
                return collapse()
            default:
                return []
            }

        case .hidden:
            switch phase {
            case .collapsed: return []
            case .pendingOpen:
                phase = .collapsed
                return [.cancelOpen]
            case .open:
                return collapse()
            }
        }
    }

    private mutating func collapse() -> [Effect] {
        let effects: [Effect] = closing ? [.cancelClose, .hide] : [.hide]
        closing = false
        phase = .collapsed
        return effects
    }

    /// Start, keep or drop the countdown to closing an unpinned list.
    private mutating func reconsiderClose() -> [Effect] {
        let away = !overPill && !overPanel && !editing
        if away && !closing {
            closing = true
            return [.scheduleClose]
        }
        if !away && closing {
            closing = false
            return [.cancelClose]
        }
        return []
    }
}
