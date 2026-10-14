import AppKit
import Carbon
import SwiftUI

/// The dock's four global shortcuts, registered (CONTRACTS-WAVE7 §B2): ⌃⌥Space talk, ⌃⌥K the list on compose, ⌃⌥D
/// show / hide, ⌃⌥M minimize / expand, or what Settings recorded instead (UserDefaults `AgentDockShortcuts`, only the
/// changed ones, as "⌃⌥D"). Carbon `RegisterEventHotKey`, so no Accessibility permission: the dock's three through
/// DockHotKey, the talk one through `MacVoice.setShortcut` (the voice owns its hot key). A combination another app
/// already has is refused by the system: Settings and the menus say so, and a newly recorded one that is refused
/// leaves the old one working.
@MainActor
final class DockShortcutCenter: ObservableObject {
    static let shared = DockShortcutCenter()
    static let takenMessage = "Not available — taken by another app"

    enum Outcome: Equatable {
        case saved
        case unchanged
        /// The rules said no (DockShortcuts.problem); nothing changed.
        case invalid(String)
        /// The system refused it; the old one still works.
        case refused(String)
    }

    @Published private(set) var bindings: [DockShortcutAction: DockShortcut]
    /// The actions whose shortcut the system refused (at launch, or when it was registered again): why.
    @Published private(set) var unavailable: [DockShortcutAction: String] = [:]
    /// Settings is recording a shortcut: none of the four is registered meanwhile, so its keys reach the recorder.
    @Published private(set) var paused = false

    private static let defaultsKey = "AgentDockShortcuts"
    private var handlers: [DockShortcutAction: () -> Void] = [:]
    private var keys: [DockShortcutAction: DockHotKey] = [:]
    private var started = false
    private let live: Bool

    init() {
        bindings = DockShortcuts.load(UserDefaults.standard.dictionary(forKey: Self.defaultsKey))
        live = true
    }

    /// Snapshots: these bindings and problems, nothing registered or saved.
    init(fixture bindings: [DockShortcutAction: DockShortcut], unavailable: [DockShortcutAction: String]) {
        self.bindings = bindings
        self.unavailable = unavailable
        live = false
    }

    /// At launch: what each of the dock's three does (talk is MacVoice's own toggle), and all four registered.
    func start(_ handlers: [DockShortcutAction: () -> Void]) {
        guard live, !started else { return }
        started = true
        self.handlers = handlers
        for action in DockShortcutAction.allCases { register(action) }
    }

    func shortcut(_ action: DockShortcutAction) -> DockShortcut { bindings[action] ?? action.defaultShortcut }

    /// The shortcut a menu shows for an action: nil while the system refuses it (the menu then shows no key).
    func working(_ action: DockShortcutAction) -> DockShortcut? {
        unavailable[action] == nil ? shortcut(action) : nil
    }

    /// For SwiftUI menus (the menu bar extra, the app menu).
    func keyboardShortcut(_ action: DockShortcutAction) -> KeyboardShortcut? {
        guard let shortcut = working(action), let key = shortcut.menuKey, let character = key.first else { return nil }
        var modifiers: EventModifiers = []
        if shortcut.hasControl { modifiers.insert(.control) }
        if shortcut.hasOption { modifiers.insert(.option) }
        if shortcut.hasShift { modifiers.insert(.shift) }
        if shortcut.hasCommand { modifiers.insert(.command) }
        return KeyboardShortcut(KeyEquivalent(character), modifiers: modifiers)
    }

    /// Settings recorded `shortcut` for `action`: checked against the rules, registered, kept.
    func set(_ action: DockShortcutAction, to shortcut: DockShortcut) -> Outcome {
        let old = self.shortcut(action)
        if shortcut == old && unavailable[action] == nil { return .unchanged }
        if let problem = DockShortcuts.problem(shortcut, for: action, among: bindings) { return .invalid(problem) }
        unregister(action)
        bindings[action] = shortcut
        if register(action) {
            save()
            Log.write("shortcut \(action.rawValue) is now \(shortcut.display)")
            return .saved
        }
        // Refused: the old one again (it may be the same combination, still taken).
        bindings[action] = old
        if old != shortcut { register(action) }
        return .refused("\(shortcut.display) isn’t available — another app uses it.")
    }

    func reset(_ action: DockShortcutAction) -> Outcome { set(action, to: action.defaultShortcut) }

    /// Recording: lets go of all four until `resume()`.
    func pause() {
        guard live, !paused else { return }
        paused = true
        for action in DockShortcutAction.allCases { unregister(action) }
    }

    func resume() {
        guard live, paused else { return }
        paused = false
        for action in DockShortcutAction.allCases { register(action) }
    }

    // MARK: Carbon

    @discardableResult
    private func register(_ action: DockShortcutAction) -> Bool {
        guard live else { return false }
        let shortcut = self.shortcut(action)
        let ok: Bool
        var taken = true
        switch action {
        case .talk:
            ok = MacVoice.shared.setShortcut(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers, description: shortcut.display)
        case .compose, .showHide, .minimize:
            let handler = handlers[action] ?? {}
            let key = DockHotKey(keyCode: Int(shortcut.keyCode), modifiers: Int(shortcut.modifiers), name: shortcut.display, action: handler)
            keys[action] = key
            ok = key != nil
            taken = DockHotKey.lastStatus == OSStatus(eventHotKeyExistsErr)
        }
        let problem: String? = ok ? nil : (taken ? Self.takenMessage : "Not available — macOS didn’t accept it")
        if unavailable[action] != problem { unavailable[action] = problem }
        return ok
    }

    private func unregister(_ action: DockShortcutAction) {
        switch action {
        case .talk:
            MacVoice.shared.releaseShortcut()
        case .compose, .showHide, .minimize:
            keys[action]?.unregister()
            keys[action] = nil
        }
    }

    private func save() {
        let saved = DockShortcuts.saved(bindings)
        if saved.isEmpty { UserDefaults.standard.removeObject(forKey: Self.defaultsKey) }
        else { UserDefaults.standard.set(saved, forKey: Self.defaultsKey) }
    }
}
