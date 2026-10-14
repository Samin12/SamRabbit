import AppKit
import Combine
import WebKit

/// The window's half of Talk and Settings (CONTRACTS-WAVE7 §B): the page's requests go to MacVoice, the Agent Dock's
/// switch, the native windows and voice notes (WAVE8 §D1: Home's "Voice note"; the note's state, without its level,
/// goes back as `note`); MacVoice's published state (with the dock's switch, the shortcuts, the app's version
/// and whether the window is on screen) goes into the page through `window.SamRabbitApp.native(…)`, where Talk draws the
/// live transcript. The voice is MacVoice's alone (the same conversation ⌃⌥Space, "Hey Rabbit" and the dock start):
/// the page has no audio engine. The message rules are in MainWindowMessages.swift (unit-tested in tests/window).
@MainActor
final class MainWindowBridge {
    private weak var webView: WKWebView?
    private let voice: MacVoice
    /// False in `--render-window-snapshots`: nothing opens other windows or switches the dock there.
    private let live: Bool
    private var throttle = WindowPushThrottle()
    private var ready = false
    private var subscription: AnyCancellable?
    private var noteSubscription: AnyCancellable?
    private var lastNote: [String: Any]?
    private var later: Timer?
    private var lastShortcut: String?
    /// The window is on screen (not closed, minimised or hidden): the page reads the bridge only then.
    private var windowVisible = true
    /// What the page asked for, in order (the window snapshots check the Talk button's path with it).
    private(set) var received: [String] = []
    private(set) var voicePushes = 0
    var onCommand: ((WindowCommand) -> Void)?

    init(webView: WKWebView, voice: MacVoice? = nil, live: Bool = true) {
        self.webView = webView
        self.voice = voice ?? .shared
        self.live = live
        subscription = self.voice.objectWillChange.sink { [weak self] _ in
            // objectWillChange comes before the new value is in place: read it on the next turn of the run loop.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.voiceChanged() } }
        }
        // The note's state but not its level (the page has no bar of its own): only when that changed.
        noteSubscription = VoiceNotes.shared.$snapshot.receive(on: DispatchQueue.main).sink { [weak self] note in
            MainActor.assumeIsolated { self?.noteChanged(note) }
        }
    }

    // MARK: from the page

    /// Handles the page's request; false when it isn't one of these (MainWindowController handles the rest).
    func handle(_ body: [String: Any]) -> Bool {
        guard let command = WindowCommand.parse(body) else { return false }
        received.append(Self.name(command))
        switch command {
        case .ready:
            ready = true
            throttle.reset()
            pushAll()
        case .voice(let action):
            perform(action)
        case .wake(let on):
            Log.write("window: \"Hey Rabbit\" turned \(on ? "on" : "off") in Settings")
            voice.wakeEnabled = on
        case .dock(let on):
            if live { WindowDock.set(on) }
            push(["dock": dockState(asked: on)])
        case .connectChatGPT:
            if live { AppModel.shared.openChatGPT() }
        case .dockSettings:
            if live { WindowDock.openSettings() }
        case .note(let action):
            Log.write("window: voice note \(action.rawValue)")
            guard live else { break }
            switch action {
            case .toggle: VoiceNotes.shared.toggle(source: "window")
            case .send: VoiceNotes.shared.send()
            case .cancel: VoiceNotes.shared.cancel()
            }
        }
        onCommand?(command)
        return true
    }

    private func perform(_ action: WindowCommand.VoiceAction) {
        Log.write("window: voice \(action.rawValue)")
        switch action {
        case .start: voice.start(reason: "button")
        case .end: voice.end()
        case .toggle: voice.toggle(reason: "button")
        case .mute: voice.micMuted = true
        case .unmute: voice.micMuted = false
        case .stopSpeaking: voice.stopSpeaking()
        }
    }

    /// The page is going away (a reload, a bridge restart): nothing is pushed until it says it is ready again.
    func pageGone() {
        ready = false
        later?.invalidate()
        later = nil
        throttle.reset()
    }

    /// The window came to the front: the dock may have been switched, hidden or given other shortcuts from its own menu
    /// or settings meanwhile.
    func windowBecameKey() {
        guard ready else { return }
        push(["dock": dockState(), "shortcuts": shortcuts()])
    }

    /// The window was shown, minimised, brought back or closed (`closing`: it still counts as visible while it closes):
    /// the page stops or starts reading the bridge.
    func windowChanged(closing: Bool = false) {
        let visible = !closing && isWindowVisible()
        guard visible != windowVisible else { return }
        windowVisible = visible
        push(["window": ["visible": visible]])
    }

    private func isWindowVisible() -> Bool {
        guard let window = webView?.window else { return false }
        return window.isVisible && !window.isMiniaturized
    }

    // MARK: to the page

    static func state(of voice: MacVoice) -> WindowVoiceState {
        var value = WindowVoiceState()
        switch voice.state {
        case .idle: value.state = "idle"
        case .starting: value.state = "starting"
        case .listening: value.state = "listening"
        case .thinking: value.state = "thinking"
        case .speaking: value.state = "speaking"
        case .error(let message):
            value.state = "error"
            value.error = message
        }
        value.heard = voice.heard
        value.heardId = voice.heardId
        value.caption = voice.caption
        value.level = Double(voice.level)
        value.micMuted = voice.micMuted
        value.wakeArmed = voice.wakeArmed
        value.wakeEnabled = voice.wakeEnabled
        value.wakeProblem = voice.wakeProblem
        value.brain = voice.brain
        value.conversationId = voice.conversationId
        value.shortcut = voice.shortcutDescription
        value.shortcutProblem = voice.shortcutProblem
        return value
    }

    /// The dock as it is (`asked`: what the switch was set to, in the snapshots, where the dock is left alone).
    private func dockState(asked: Bool = true) -> [String: Any] {
        (live ? WindowDock.state : WindowDockState(on: asked, turnedOn: asked)).json
    }

    private func shortcuts() -> [[String: Any]] {
        WindowDock.shortcuts(voice: voice)
    }

    private func pushAll() {
        let state = Self.state(of: voice)
        let host = "\(Config.baseURL.host ?? "127.0.0.1"):\(Config.baseURL.port ?? 80)"
        lastShortcut = state.shortcut + (state.shortcutProblem ?? "")
        windowVisible = isWindowVisible()
        throttle.pushed(state, at: Date())
        voicePushes += 1
        let note = VoiceNotes.shared.snapshot.json
        lastNote = note
        push(["app": ["version": Config.version, "bridge": host], "dock": dockState(),
              "shortcuts": shortcuts(), "voice": state.json, "window": ["visible": windowVisible], "note": note])
    }

    private func voiceChanged() {
        guard ready else { return }
        let next = Self.state(of: voice)
        switch throttle.decide(next, now: Date()) {
        case .now:
            later?.invalidate()
            later = nil
            throttle.pushed(next, at: Date())
            voicePushes += 1
            var patch: [String: Any] = ["voice": next.json]
            let shortcut = next.shortcut + (next.shortcutProblem ?? "")
            if shortcut != lastShortcut {
                lastShortcut = shortcut
                patch["shortcuts"] = shortcuts()
            }
            push(patch)
        case .after(let wait):
            guard later == nil else { return }
            later = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.later = nil
                    self?.voiceChanged()
                }
            }
        case .skip:
            break
        }
    }

    private func noteChanged(_ note: VoiceNoteSnapshot) {
        guard ready else { return }
        let json = note.json
        if let lastNote, NSDictionary(dictionary: lastNote).isEqual(to: json) { return }
        let shortcutBefore = lastNote?["shortcut"] as? String
        lastNote = json
        var patch: [String: Any] = ["note": json]
        // The note's shortcut is one of the shortcuts Settings lists.
        if shortcutBefore != json["shortcut"] as? String { patch["shortcuts"] = shortcuts() }
        push(patch)
    }

    private func push(_ patch: [String: Any]) {
        guard ready, let webView, let script = WindowScript.native(patch) else { return }
        webView.evaluateJavaScript(script)
    }

    private static func name(_ command: WindowCommand) -> String {
        switch command {
        case .voice(let action): return "voice.\(action.rawValue)"
        case .wake(let on): return "wake.\(on ? "on" : "off")"
        case .dock(let on): return "dock.\(on ? "on" : "off")"
        case .ready: return "ready"
        case .connectChatGPT: return "connectChatGPT"
        case .dockSettings: return "dockSettings"
        case .note(let action): return "note.\(action.rawValue)"
        }
    }
}

/// What the window's Settings knows of the Agent Dock, in one place: its switch, its shortcuts and its settings window.
/// The switch goes through the dock's own `setEnabled(_:)` (on ends a hide for a while; off is "Turn Off the Dock")
/// and shows `isOn` (on and not hidden), so it never says "On" while the dock is away; the shortcuts are the dock's
/// shortcut center's, and their settings window is the dock's.
@MainActor
enum WindowDock {
    static let canCustomize = true

    static var state: WindowDockState {
        let dock = DockController.shared
        return WindowDockState(on: dock.isOn, turnedOn: dock.isEnabled, canCustomize: canCustomize)
    }

    static func set(_ on: Bool) {
        Log.write("window: dock turned \(on ? "on" : "off") in Settings")
        DockController.shared.setEnabled(on)
    }

    /// The four shortcuts as the dock's shortcut center has them (talk is MacVoice's own, registered through it).
    static func shortcuts(voice: MacVoice) -> [[String: Any]] {
        let center = DockShortcutCenter.shared
        return DockShortcutAction.allCases.map { action in
            WindowScript.shortcut(id: action.rawValue, label: action.label,
                                  keys: center.unavailable[action] == nil ? center.shortcut(action).display : "",
                                  problem: center.unavailable[action])
        }
    }

    static func openSettings() {
        DockController.shared.openSettings()
    }
}
