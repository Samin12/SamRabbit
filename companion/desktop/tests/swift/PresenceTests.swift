import Foundation

/// Samin's own say over the dock (CONTRACTS-WAVE7 §B2): ⌃⌥D shows and hides it, ⌃⌥M / the "–" / a click on the orb
/// fold it to the orb and back, and what each of those does next to the Wave 6 rules.
enum PresenceTests {
    static let all: [(String, () throws -> Void)] = [
        ("formFollowsVoiceAndTheOrb", formFollowsVoiceAndTheOrb),
        ("showHideTogglesWhatIsOnScreen", showHideTogglesWhatIsOnScreen),
        ("showHideBringsItToThisScreen", showHideBringsItToThisScreen),
        ("showHideLiftsEveryHide", showHideLiftsEveryHide),
        ("showHideOverTheMainWindow", showHideOverTheMainWindow),
        ("voiceAndSummonStillShow", voiceAndSummonStillShow),
        ("minimizeAndExpand", minimizeAndExpand),
        ("minimizingAHiddenDockShowsIt", minimizingAHiddenDockShowsIt),
        ("showFromTheMenu", showFromTheMenu),
    ]

    /// Another app is in front: the dock shows by the Wave 6 rules.
    static let outside = DockVisibilityInput()
    /// Samin is in the main window: it steps aside by those rules.
    static let inApp = DockVisibilityInput(appActive: true, mainWindowVisible: true, mainWindowKey: true)

    static func shows(_ presence: DockPresence, _ input: DockVisibilityInput) -> Bool {
        DockVisibility.shows(presence.applied(to: input))
    }

    static func formFollowsVoiceAndTheOrb() throws {
        var presence = DockPresence()
        expectEqual(presence.form(voiceActive: false), .pill)
        presence.minimized = true
        expectEqual(presence.form(voiceActive: false), .orb)
        expectEqual(presence.form(voiceActive: true), .voiceBar, "a conversation turns the orb into the voice bar")
        expectEqual(presence.form(voiceActive: false), .orb, "and it is the orb again after it")
        presence.minimized = false
        expectEqual(presence.form(voiceActive: true), .voiceBar)
    }

    static func showHideTogglesWhatIsOnScreen() throws {
        var presence = DockPresence()
        expect(shows(presence, outside))
        expectEqual(presence.handle(.toggleShown(elsewhere: false), outside), [.closeList])
        expect(presence.hidden)
        expect(!shows(presence, outside), "put away")
        expectEqual(DockVisibility.reason(presence.applied(to: outside)), .userHidden)
        // It stays away whatever the windows do, until pressed again.
        var later = outside
        later.mainWindowMinimized = true
        expect(!shows(presence, later))
        expectEqual(presence.handle(.toggleShown(elsewhere: false), outside), [])
        expect(!presence.hidden)
        expect(shows(presence, outside), "back as it was")
        // Pressed again while it is away and elsewhere: back, on this screen.
        _ = presence.handle(.toggleShown(elsewhere: false), outside)
        expectEqual(presence.handle(.toggleShown(elsewhere: true), outside), [.bringHere])
        expect(!presence.hidden)
    }

    static func showHideBringsItToThisScreen() throws {
        // On screen, but on another display than the pointer's: it comes here, still shown.
        var presence = DockPresence()
        expectEqual(presence.handle(.toggleShown(elsewhere: true), outside), [.bringHere])
        expect(!presence.hidden)
        expect(shows(presence, outside))
        // Here now: the next press puts it away.
        expectEqual(presence.handle(.toggleShown(elsewhere: false), outside), [.closeList])
        expect(presence.hidden)
    }

    static func showHideLiftsEveryHide() throws {
        let now = Date()
        // Hidden for an hour: ⌃⌥D ends that hide.
        var presence = DockPresence()
        let forAWhile = DockVisibilityInput(hiddenUntil: now.addingTimeInterval(3600), now: now)
        expect(!shows(presence, forAWhile))
        expectEqual(presence.handle(.toggleShown(elsewhere: false), forAWhile), [.endHide])
        // A hide that already ran out is nothing to end.
        let ranOut = DockVisibilityInput(hiddenUntil: now.addingTimeInterval(-5), now: now)
        expect(shows(presence, ranOut))
        // Turned off: ⌃⌥D turns it on.
        var off = DockPresence()
        expectEqual(off.handle(.toggleShown(elsewhere: false), DockVisibilityInput(enabled: false)), [.turnOn])
        // Off, hidden for a while and on another screen at once: all of it.
        var all = DockPresence()
        let both = DockVisibilityInput(enabled: false, hiddenUntil: now.addingTimeInterval(60), now: now)
        expectEqual(all.handle(.toggleShown(elsewhere: true), both), [.turnOn, .endHide, .bringHere])
    }

    static func showHideOverTheMainWindow() throws {
        // In the main window it steps aside; ⌃⌥D brings it over the window anyway…
        var presence = DockPresence()
        expect(!shows(presence, inApp))
        expectEqual(presence.handle(.toggleShown(elsewhere: false), inApp), [])
        expect(presence.overApp)
        expect(shows(presence, inApp))
        expectEqual(DockVisibility.reason(presence.applied(to: inApp)), .shown)
        // …and a click in the dock (the main window is no longer key) is not leaving the window.
        var clicked = inApp
        clicked.mainWindowKey = false
        presence.settle(clicked)
        expect(presence.overApp)
        presence.settle(inApp)
        expect(presence.overApp, "back in the window: still shown over it")
        // ⌃⌥D again puts it away (and "over the app" is over).
        expectEqual(presence.handle(.toggleShown(elsewhere: false), inApp), [.closeList])
        expect(presence.hidden && !presence.overApp)
        // Leaving the app ends "over the app": the next time he is in the window it steps aside again.
        var shown = DockPresence()
        _ = shown.handle(.toggleShown(elsewhere: false), inApp)
        presence = shown
        presence.settle(outside)
        expect(!presence.overApp)
        expect(!shows(presence, inApp))
        var minimised = inApp
        minimised.mainWindowMinimized = true
        shown.settle(minimised)
        expect(!shown.overApp, "minimising the main window is leaving it too")
    }

    static func voiceAndSummonStillShow() throws {
        // Put away during a conversation: the voice bar stays until the conversation ends.
        var presence = DockPresence()
        var talking = outside
        talking.voiceActive = true
        expectEqual(presence.handle(.toggleShown(elsewhere: false), talking), [.closeList])
        expect(presence.hidden)
        expect(shows(presence, talking))
        expectEqual(DockVisibility.reason(presence.applied(to: talking)), .voice)
        expect(!shows(presence, outside), "and away after it")
        // ⌃⌥K (summoned) shows a dock that was put away, until its list closes.
        var summoned = outside
        summoned.summoned = true
        expectEqual(DockVisibility.reason(presence.applied(to: summoned)), .summoned)
        // Off for good beats put away in the reasons (Settings is where it comes back).
        var off = outside
        off.enabled = false
        expectEqual(DockVisibility.reason(presence.applied(to: off)), .off)
    }

    static func minimizeAndExpand() throws {
        var presence = DockPresence()
        // The "–" and a click on the orb.
        expectEqual(presence.handle(.minimize, outside), [])
        expect(presence.minimized)
        expectEqual(presence.handle(.minimize, outside), [], "twice is still the orb")
        expect(presence.minimized)
        expectEqual(presence.handle(.expand, outside), [])
        expect(!presence.minimized)
        // ⌃⌥M / "Minimize to Orb": orb ↔ pill, nothing else changes.
        expectEqual(presence.handle(.toggleMinimized(elsewhere: false), outside), [])
        expect(presence.minimized)
        expectEqual(presence.handle(.toggleMinimized(elsewhere: true), outside), [], "on screen elsewhere: folded there")
        expect(!presence.minimized)
        expect(!presence.hidden && !presence.overApp)
    }

    static func minimizingAHiddenDockShowsIt() throws {
        // Put away, then ⌃⌥M: back on screen in its new shape (on this screen).
        var presence = DockPresence()
        _ = presence.handle(.toggleShown(elsewhere: false), outside)
        expectEqual(presence.handle(.toggleMinimized(elsewhere: true), outside), [.bringHere])
        expect(presence.minimized && !presence.hidden)
        expect(shows(presence, outside))
        // Stepped aside in the main window: ⌃⌥M shows the orb over it.
        var inWindow = DockPresence()
        expectEqual(inWindow.handle(.toggleMinimized(elsewhere: false), inApp), [])
        expect(inWindow.minimized && inWindow.overApp)
        expect(shows(inWindow, inApp))
        // Off: on again.
        var off = DockPresence()
        expectEqual(off.handle(.toggleMinimized(elsewhere: false), DockVisibilityInput(enabled: false)), [.turnOn])
    }

    static func showFromTheMenu() throws {
        // "Show Agent Dock" ends ⌃⌥D's hide (the controller also turns it on, ends a hide for a while and opens it).
        var presence = DockPresence()
        _ = presence.handle(.toggleShown(elsewhere: false), outside)
        expectEqual(presence.handle(.showFromMenu, outside), [])
        expect(!presence.hidden)
        expect(shows(presence, outside))
        // The orb stays the orb.
        presence.minimized = true
        _ = presence.handle(.showFromMenu, outside)
        expect(presence.minimized)
    }
}
