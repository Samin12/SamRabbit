import AppKit
import Carbon
import SwiftUI

/// The dock's four global shortcuts, registered (CONTRACTS-WAVE7 §B2): ⌃⌥Space talk, ⌃⌥K the list on compose, ⌃⌥D
/// show / hide, ⌃⌥M minimize / expand, or what Settings recorded instead (UserDefaults `AgentDockShortcuts`, only the
/// changed ones, as "⌃⌥D"). Carbon `RegisterEventHotKey`, so no Accessibility permission: the dock's three through
/// DockHotKey, the talk one through `MacVoice.setShortcut` (the voice owns its hot key). Each is registered
/// exclusively, so Carbon refuses one another app holds that way; one of macOS's own shortcuts (Keyboard Shortcuts,
/// CopySymbolicHotKeys) isn't registered at all, since macOS takes it first. (An app that registered a combination
/// without exclusivity can't be seen: Carbon then shares it.) Settings and the menus say why one isn't working, and a
/// newly recorded one that is refused leaves the old one working.
@MainActor
final class DockShortcutCenter: ObservableObject {
    static let shared = DockShortcutCenter()
    static let takenMessage = "Not available — taken by another app"
    static let systemMessage = "Not available — macOS uses it (Keyboard Shortcuts)"

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
        var modifiers: SwiftUI.EventModifiers = []
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
        let why = unavailable[action] ?? Self.takenMessage
        bindings[action] = old
        if old != shortcut { register(action) }
        Log.write("shortcut \(action.rawValue): \(shortcut.display) refused, kept \(old.display)")
        return .refused("\(shortcut.display): \(why.prefix(1).lowercased() + why.dropFirst())")
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
        var problem: String?
        if DockShortcuts.takenBySystem(shortcut, Self.systemShortcuts()) {
            problem = Self.systemMessage
            Log.write("shortcut \(shortcut.display) is one of macOS’s own: not registered")
        }
        switch action {
        case .talk:
            let voiceProblem = problem.map { _ in "\(shortcut.display) is one of macOS’s own shortcuts" }
            if !MacVoice.shared.setShortcut(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers, description: shortcut.display,
                                            unavailable: voiceProblem) {
                problem = problem ?? Self.takenMessage
            }
        case .compose, .showHide, .minimize:
            guard problem == nil else { break }
            let handler = handlers[action] ?? {}
            let key = DockHotKey(keyCode: Int(shortcut.keyCode), modifiers: Int(shortcut.modifiers), name: shortcut.display,
                                 exclusive: true, action: handler)
            keys[action] = key
            if key == nil {
                problem = DockHotKey.lastStatus == OSStatus(eventHotKeyExistsErr) ? Self.takenMessage : "Not available — macOS didn’t accept it"
            }
        }
        if unavailable[action] != problem { unavailable[action] = problem }
        return problem == nil
    }

    /// macOS's own keyboard shortcuts as they are set right now (read each time: Samin may change them meanwhile).
    private static func systemShortcuts() -> [DockSystemShortcut] {
        var list: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&list) == noErr, let array = list?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return array.compactMap { item in
            guard let code = (item[kHISymbolicHotKeyCode] as? NSNumber)?.uint32Value,
                  let modifiers = (item[kHISymbolicHotKeyModifiers] as? NSNumber)?.uint32Value else { return nil }
            return DockSystemShortcut(keyCode: code, modifiers: modifiers, enabled: (item[kHISymbolicHotKeyEnabled] as? NSNumber)?.boolValue ?? false)
        }
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
