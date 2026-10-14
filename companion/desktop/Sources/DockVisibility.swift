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
    /// Samin asked for it (⌃⌥K, "Show Agent Dock", a notification): it shows until he lets the list close.
    var summoned = false
}

enum DockVisibility {
    enum Reason: String, Equatable {
        case voice, summoned, off, hiddenForAWhile, inApp, shown
    }

    static func reason(_ input: DockVisibilityInput) -> Reason {
        if input.voiceActive { return .voice }
        if input.summoned { return .summoned }
        if !input.enabled { return .off }
        if let until = input.hiddenUntil, until > input.now { return .hiddenForAWhile }
        // It steps aside while Samin is in the main window: there the app already shows all of this, bigger. It is
        // back as soon as the window is minimised, closed or hidden, or another app is in front.
        if input.appActive && input.mainWindowVisible && input.mainWindowKey && !input.mainWindowMinimized { return .inApp }
        return .shown
    }

    static func shows(_ input: DockVisibilityInput) -> Bool {
        switch reason(input) {
        case .voice, .summoned, .shown: return true
        case .off, .hiddenForAWhile, .inApp: return false
        }
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
