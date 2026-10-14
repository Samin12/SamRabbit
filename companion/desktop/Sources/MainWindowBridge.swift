import AppKit
import Combine
import WebKit

/// The window's half of Talk and Settings (CONTRACTS-WAVE7 §B): the page's requests go to MacVoice, the Agent Dock's
/// switch and the native windows; MacVoice's published state (with the dock's switch, the shortcuts and the app's
/// version) goes into the page through `window.SamRabbitApp.native(…)`, where Talk draws the live transcript. The voice
/// is MacVoice's alone (the same conversation ⌃⌥Space, "Hey Rabbit" and the dock start): the page has no audio engine.
/// The message rules are in MainWindowMessages.swift (unit-tested in tests/window).
@MainActor
final class MainWindowBridge {
    private weak var webView: WKWebView?
    private let voice: MacVoice
    /// False in `--render-window-snapshots`: nothing opens other windows or switches the dock there.
    private let live: Bool
    private var throttle = WindowPushThrottle()
    private var ready = false
    private var subscription: AnyCancellable?
    private var later: Timer?
    private var lastShortcut: String?
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
            if live { WindowDockSwitch.set(on) }
            push(["dock": dockState(enabled: live ? WindowDockSwitch.enabled : on)])
        case .connectChatGPT:
            if live { AppModel.shared.openChatGPT() }
        case .dockSettings:
            // The dock's own settings window comes with the dock's next version; nothing to open yet.
            Log.write("window: dock settings asked for (not available in this build)")
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

    /// The window came to the front: the dock may have been switched from its own menu meanwhile.
    func windowBecameKey() {
        guard ready else { return }
        push(["dock": dockState(enabled: live ? WindowDockSwitch.enabled : true)])
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

    private func dockState(enabled: Bool) -> [String: Any] {
        ["enabled": enabled, "canCustomize": false]
    }

    private func shortcuts() -> [[String: Any]] {
        WindowScript.shortcuts(talk: voice.shortcutDescription, talkProblem: voice.shortcutProblem)
    }

    private func pushAll() {
        let state = Self.state(of: voice)
        let host = "\(Config.baseURL.host ?? "127.0.0.1"):\(Config.baseURL.port ?? 80)"
        lastShortcut = state.shortcut + (state.shortcutProblem ?? "")
        throttle.pushed(state, at: Date())
        voicePushes += 1
        push(["app": ["version": Config.version, "bridge": host],
              "dock": dockState(enabled: live ? WindowDockSwitch.enabled : true),
              "shortcuts": shortcuts(), "voice": state.json])
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
        }
    }
}

/// Settings' "Show the Agent Dock". The dock keeps its switch in its own setting and its menu turns it off and on;
/// DockController has no setter for it yet, so this does what those menu items do, without opening the list.
/// (When the dock gets a `setEnabled(_:)`, this becomes a call to it.)
@MainActor
enum WindowDockSwitch {
    static let key = "AgentDockEnabled"

    static var enabled: Bool { DockController.shared.isEnabled }

    static func set(_ on: Bool) {
        guard on != enabled else { return }
        UserDefaults.standard.set(on, forKey: key)
        let dock = DockController.shared
        if on { dock.store.start() } else { dock.store.stop() }
        dock.refresh()
        Log.write("window: dock turned \(on ? "on" : "off") in Settings")
    }
}
