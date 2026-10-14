import SwiftUI

/// The Agent Dock's items in the menu bar extra (CONTRACTS-WAVE7 §B2): hide it or show it again (⌃⌥D), fold it to the
/// orb and back (⌃⌥M), and its Settings (the four shortcuts, recorded anew there). The keys shown are the ones Settings
/// recorded, and none while another app has one (the dock's own menu and Settings say why).
struct DockMenuBarItems: View {
    @ObservedObject var ui = DockController.shared.ui
    @ObservedObject var shortcuts = DockShortcutCenter.shared

    var body: some View {
        if ui.shown {
            Button("Hide Agent Dock") { DockController.shared.toggleShown() }
                .keyboardShortcut(shortcuts.keyboardShortcut(.showHide))
        } else {
            // As in Wave 6: on again, every hide ended, and open (⌃⌥D brings it back without opening the list).
            Button("Show Agent Dock") { DockController.shared.showFromMenu() }
                .keyboardShortcut(shortcuts.keyboardShortcut(.showHide))
        }
        Button(ui.minimized ? "Expand Agent Dock" : "Minimize Agent Dock to Orb") { DockController.shared.toggleMinimized() }
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
