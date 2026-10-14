import Foundation

// =====================================================================================================================
// PLACEHOLDER — DELETE THIS FILE WHEN THE REAL MacVoice LANDS (Sources/Voice*.swift, the Mac voice workstream).
//
// It implements the `MacVoice` interface of CONTRACTS-WAVE6 with a scripted fixture so the Agent Dock compiles and its
// voice bar can be exercised before the voice work is merged. It never touches the microphone, plays no audio, makes
// no network request and registers no shortcut: "start" only walks through listening → thinking → speaking with canned
// text. The dock talks to voice only through this interface, so deleting this file is the whole integration step.
// =====================================================================================================================

@MainActor
final class MacVoice: ObservableObject {
    static let shared = MacVoice()

    enum State: Equatable {
        case idle, starting, listening, thinking, speaking
        case error(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var heard = ""
    @Published private(set) var caption = ""
    @Published private(set) var level: Float = 0
    @Published var micMuted = false
    @Published private(set) var wakeArmed = false
    @Published var wakeEnabled: Bool {
        didSet {
            UserDefaults.standard.set(wakeEnabled, forKey: Self.wakeKey)
            refreshWake()
        }
    }
    @Published private(set) var brain: String?
    @Published private(set) var conversationId: String?
    let shortcutDescription = "⌃⌥Space"

    private static let wakeKey = "DockPlaceholderWakeEnabled"
    private static let reply = "Two things need you. The pairing fix wants to run its tests, and the waitlist task is "
        + "asking which database to use. Want me to approve the tests?"
    private var steps: [Timer] = []
    private var meter: Timer?
    private var phase = 0.0

    private init() {
        wakeEnabled = UserDefaults.standard.object(forKey: Self.wakeKey) as? Bool ?? true
        refreshWake()
    }

    func start(reason: String) {
        guard state == .idle else { return }
        Log.write("voice placeholder: start (\(reason))")
        cancelSteps()
        brain = "realtime"
        conversationId = "fixture-\(Int(Date().timeIntervalSince1970))"
        heard = ""
        caption = ""
        state = .starting
        refreshWake()
        startMeter()
        after(0.5) { $0.listen() }
    }

    func stopSpeaking() {
        guard state == .speaking else { return }
        cancelSteps()
        listen()
    }

    func end() {
        guard state != .idle else { return }
        Log.write("voice placeholder: end")
        cancelSteps()
        meter?.invalidate()
        meter = nil
        state = .idle
        heard = ""
        caption = ""
        level = 0
        brain = nil
        conversationId = nil
        refreshWake()
    }

    func toggle(reason: String) {
        if state == .idle { start(reason: reason) } else { end() }
    }

    // MARK: the script

    private func listen() {
        state = .listening
        after(2.6) { voice in
            voice.heard = "What needs me right now?"
            voice.caption = ""
            voice.state = .thinking
            voice.after(1.1) { $0.speak(words: Self.reply.split(separator: " ").map(String.init), index: 0) }
        }
        after(30) { $0.end() }
    }

    private func speak(words: [String], index: Int) {
        state = .speaking
        guard index < words.count else {
            after(1.4) { $0.listenAgain() }
            return
        }
        caption = words[...index].joined(separator: " ")
        after(0.11) { $0.speak(words: words, index: index + 1) }
    }

    private func listenAgain() {
        state = .listening
        after(25) { $0.end() }
    }

    private func startMeter() {
        meter?.invalidate()
        meter = Timer.scheduledTimer(withTimeInterval: 1 / 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.phase += 0.45
                let wave = Float(0.5 + 0.5 * sin(self.phase)) * Float(0.6 + 0.4 * sin(self.phase * 0.37))
                switch self.state {
                case .listening: self.level = self.micMuted ? 0 : wave * 0.7
                case .speaking: self.level = wave
                default: self.level = 0
                }
            }
        }
    }

    private func refreshWake() {
        // No listener runs here; "armed" is only pretended when a dev run asks for it, to see the mic's dot.
        let pretend = ProcessInfo.processInfo.environment["SAMRABBIT_DOCK_FIXTURE_WAKE"] == "1"
        wakeArmed = pretend && wakeEnabled && state == .idle && !micMuted
    }

    private func after(_ seconds: TimeInterval, _ body: @escaping (MacVoice) -> Void) {
        let timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                body(self)
            }
        }
        steps.append(timer)
    }

    private func cancelSteps() {
        steps.forEach { $0.invalidate() }
        steps.removeAll()
    }
}
