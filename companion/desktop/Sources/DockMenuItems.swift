import SwiftUI

/// The Agent Dock's items in the menu bar extra (CONTRACTS-WAVE7 §B2): hide it or show it again (⌃⌥D), a new task on
/// its list (⌃⌥K), fold it to the orb and back (⌃⌥M), and its Settings (the four shortcuts, recorded anew there). The
/// keys shown are the ones Settings recorded, and none while another app has one (the dock's own menu and Settings say
/// why). None of these looks at the pointer: it is on the menu bar's display, which may not be the dock's, and a menu
/// item never moves the dock to another screen (only the ⌃⌥D and ⌃⌥M hot keys bring it to the pointer's).
struct DockMenuBarItems: View {
    @ObservedObject var ui = DockController.shared.ui
    @ObservedObject var shortcuts = DockShortcutCenter.shared

    var body: some View {
        if ui.shown {
            Button("Hide Agent Dock") { DockController.shared.putAwayFromMenu() }
                .keyboardShortcut(shortcuts.keyboardShortcut(.showHide))
        } else {
            // What ⌃⌥D does to a dock that is away: on again, every hide ended, back as it was (the list stays shut).
            Button("Show Agent Dock") { DockController.shared.bringBackFromMenu() }
                .keyboardShortcut(shortcuts.keyboardShortcut(.showHide))
        }
        // What ⌃⌥K does: the list, on "Ask an agent…" (Wave 6's way to open the list from here).
        Button("New Task…") { DockController.shared.summon(focusCompose: true) }
            .keyboardShortcut(shortcuts.keyboardShortcut(.compose))
        Button(ui.minimized ? "Expand Agent Dock" : "Minimize Agent Dock to Orb") {
            DockController.shared.toggleMinimized(fromMenu: true)
        }
        .keyboardShortcut(shortcuts.keyboardShortcut(.minimize))
        Button("Agent Dock Settings…") { DockController.shared.openSettings() }
    }
}

/// The main menu's dock items: "Show Agent Dock" with the compose shortcut (⌃⌥K opens it on "Ask an agent…"), and
/// Settings.
struct DockAppMenuItems: View {
    @ObservedObject var shortcuts = DockShortcutCenter.shared

    var body: some View {
        Button("Show Agent Dock") { DockController.shared.showFromMenu() }
            .keyboardShortcut(shortcuts.keyboardShortcut(.compose))
        Button("Agent Dock Settings…") { DockController.shared.openSettings() }
    }
}
