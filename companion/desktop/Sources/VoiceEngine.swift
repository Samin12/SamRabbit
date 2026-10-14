import AppKit
import Foundation
import SamRabbitKit

/// Talking to SamRabbit on the Mac (CONTRACTS-WAVE6 "Mac voice"): the dock's mic button, ⌃⌥Space from any app,
/// "Talk to SamRabbit" in the menu bar, or "Hey Rabbit". The conversation is the watch's: the same rules
/// (`ConversationMachine`, SamRabbitKit, unit-tested), the same speech detector and the same streaming turns, to the
/// bridge's desktop routes (`/v1/desktop/assistant/*`, the desktop token, loopback only).
///
/// * Listens (`VoiceAudio`: voice processing, so the assistant's own voice through the speakers doesn't count as
///   Samin speaking), sends each utterance as a 16 kHz WAV, plays the reply as it streams in (`say.delta` is the live
///   caption), and listens again. A reply without audio is said with the Mac's own voice.
/// * `stopSpeaking()` barges in (the reply stops on the Mac and here, and it listens), `end()` ends it; it also ends
///   when the assistant says so ("bye", "that's all") or after 90 s without anything said. Talking over a reply
///   barges in too when `VoiceBargeIn` is on (off by default: `defaults write com.samrabbit.desktop VoiceBargeIn
///   -bool true`), and only while echo cancellation runs (`BargeInDetector`).
/// * T3 announcements (a task finished or needs Samin) are polled about every 20 s and said between turns.
/// * The "Hey Rabbit" listener (`VoiceWake`, on device) runs whenever no conversation does, unless it is turned off
///   or the microphone is muted.
/// * Nothing heard or said, and no audio, is ever logged.
///
/// Fixture mode (`SAMRABBIT_VOICE_FIXTURE`, see `FixtureMicrophone`) hears WAV files and plays nothing out loud;
/// `SAMRABBIT_NO_MIC=1` keeps the microphone off altogether (a development build next to someone working).
@MainActor
final class MacVoice: ObservableObject {
    static let shared = MacVoice()

    enum State: Equatable {
        case idle, starting, listening, thinking, speaking
        /// The last conversation ended because of this (shown for a few seconds, then idle).
        case error(String)
    }

    @Published private(set) var state: State = .idle
    /// The last thing Samin said (its transcript).
    @Published private(set) var heard = ""
    /// The exchange `heard` belongs to (saying "Yes." twice is two exchanges with the same words).
    @Published private(set) var heardId: String?
    /// What the assistant says in the current or last reply (streams in).
    @Published private(set) var caption = ""
    /// 0...1: the microphone while listening, the reply while speaking.
    @Published private(set) var level: Float = 0
    /// The conversation's microphone is muted: it hears nothing, and its quiet end waits four times as long. Mute is
    /// the conversation's own: the next conversation and "Hey Rabbit" hear again. (Muted while no conversation runs,
    /// "Hey Rabbit" waits until it is unmuted or a conversation starts.)
    @Published var micMuted = false {
        didSet { if micMuted != oldValue { mutedChanged() } }
    }
    /// The "Hey Rabbit" listener is running.
    @Published private(set) var wakeArmed = false
    /// Listen for "Hey Rabbit" whenever no conversation runs (saved; on by default).
    @Published var wakeEnabled: Bool {
        didSet {
            guard wakeEnabled != oldValue else { return }
            UserDefaults.standard.set(wakeEnabled, forKey: Self.wakeEnabledKey)
            Log.write("voice: wake phrase " + (wakeEnabled ? "on" : "off"))
            updateWake()
        }
    }
    /// Why the wake phrase isn't listening although it is on (no on-device speech, the microphone is off), or nil.
    @Published private(set) var wakeProblem: String?
    /// "realtime" or "claude", once the bridge said.
    @Published private(set) var brain: String?
    @Published private(set) var conversationId: String?
    /// "⌃⌥Space", or "" when another app has that shortcut (then `shortcutProblem` says so).
    @Published private(set) var shortcutDescription = VoiceHotKey.shortcutDescription
    @Published private(set) var shortcutProblem: String?

    static let wakeEnabledKey = "VoiceWakeEnabled"
    static let wakePhrasesKey = "WakePhrases"
    static let bargeInKey = "VoiceBargeIn"
    static let mutedProblem = "Paused while the microphone is muted"

    private var machine: ConversationMachine
    /// The quiet end (seconds without speech), four times as long while muted.
    private let idleTimeout: TimeInterval
    private var resettingMute = false
    private let audio: VoiceAudio
    private let wake: VoiceWake
    private var detector = SamRabbitKit.SpeechDetector()
    private let noMicrophone: Bool
    private var hotKey: VoiceHotKey?
    private var activated = false
    private var client: BridgeClient?
    private var micOpen = false
    /// Speech that followed the wake phrase, waiting for the conversation's microphone to open.
    private var carry: [Int16]?
    private var reason = "button"
    private var turnTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var levelTask: Task<Void, Never>?
    private var errorTask: Task<Void, Never>?
    private var wakeTask: Task<Void, Never>?
    private var cursor: String?
    private var storedLevel: Double = 0
    /// Talking over a reply (opt-in): the detector, and the last second of the microphone meanwhile.
    private var barge = BargeInDetector()
    private var overReply = SampleRing(capacity: 16_000)
    /// `SAMRABBIT_VOICE_BARGE_IN=1`: on in fixture mode too (no echo cancellation there), for the tests.
    private let forceBargeIn: Bool

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let idle = Double(environment["SAMRABBIT_VOICE_IDLE"] ?? "").map { max(5, $0) } ?? 90
        idleTimeout = idle
        machine = ConversationMachine(idleTimeout: idle, device: .mac)
        let fixture = FixtureMicrophone.shared
        noMicrophone = fixture == nil && environment["SAMRABBIT_NO_MIC"] == "1"
        forceBargeIn = environment["SAMRABBIT_VOICE_BARGE_IN"] == "1"
        audio = VoiceAudio(input: fixture.map { FixtureInput($0) } ?? MacMicrophone())
        let defaults = UserDefaults.standard
        wakeEnabled = defaults.object(forKey: Self.wakeEnabledKey) == nil ? true : defaults.bool(forKey: Self.wakeEnabledKey)
        let phrases = defaults.stringArray(forKey: Self.wakePhrasesKey) ?? WakePhraseMatcher.defaultPhrases
        wake = VoiceWake(fixture: fixture, phrases: phrases)
        audio.onSamples = { [weak self] in self?.heardSamples($0) }
        audio.onPlaying = { [weak self] in self?.handle(.playing) }
        audio.onDrained = { [weak self] in self?.handle(.drained) }
        audio.onInterrupted = { [weak self] in self?.handle(.audioFailed("The audio device changed")) }
        wake.onStatus = { [weak self] armed, problem in
            guard let self else { return }
            self.wakeArmed = armed
            // A pause for a conversation isn't a problem; a refusal stays until it is tried again.
            if armed || problem != nil { self.wakeProblem = problem }
        }
        wake.onPhrase = { [weak self] in self?.start(reason: "wake") }
    }

    /// At launch: the global shortcut and the wake phrase listener.
    func activate(shortcut: Bool = true) {
        guard !activated else { return }
        activated = true
        if shortcut {
            hotKey = VoiceHotKey { [weak self] in self?.toggle(reason: "shortcut") }
            if hotKey == nil {
                // Another app has it: say so rather than advertise a shortcut that does nothing.
                shortcutProblem = "\(VoiceHotKey.shortcutDescription) is used by another app"
                shortcutDescription = ""
            }
        }
        updateWake()
    }

    // MARK: - What the app asks for

    /// Opens a conversation ("button", "shortcut", "wake"); nothing while one is open.
    func start(reason: String) {
        guard machine.phase == .idle else { return }
        self.reason = reason
        errorTask?.cancel()
        errorTask = nil
        if noMicrophone {
            Log.write("voice: not started, the microphone is off (SAMRABBIT_NO_MIC)")
            show(.error("The microphone is off in this build"))
            return
        }
        // Asking to talk unmutes (a mute left from before isn't this conversation's).
        resetMute()
        // After the wake phrase the listener keeps listening until the conversation's microphone runs, then hands
        // over what followed it; otherwise it gives the microphone to the conversation now.
        carry = nil
        if reason != "wake" { wake.stop() }
        client = Self.makeClient()
        Log.write("voice: conversation starts (\(reason))")
        handle(.start)
    }

    /// Barge-in: the reply stops (here and on the Mac's bridge) and it listens.
    func stopSpeaking() {
        guard machine.phase == .speaking || machine.phase == .thinking else { return }
        handle(.tap)
    }

    func end() {
        guard machine.phase.inConversation else { return }
        handle(.stop)
    }

    /// The mic button, ⌃⌥Space: talk, or end the conversation that is open.
    func toggle(reason: String) {
        machine.phase.inConversation ? end() : start(reason: reason)
    }

    // MARK: - The machine

    private func handle(_ event: ConversationMachine.Event) {
        let before = machine.phase
        let effects = machine.handle(event)
        if machine.phase != before { Log.write("voice: \(before.rawValue) -> \(machine.phase.rawValue)") }
        for effect in effects { perform(effect) }
        publish(endedFrom: before)
    }

    private func perform(_ effect: ConversationMachine.Effect) {
        switch effect {
        case .startAudio:
            Task {
                do {
                    try await audio.start()
                } catch is CancellationError {
                    return
                } catch let failure as VoiceAudio.StartFailure {
                    handle(.audioFailed(failure.message))
                    return
                } catch {
                    handle(.audioFailed("The microphone didn't start"))
                    return
                }
                guard machine.phase.inConversation else {
                    audio.stop()
                    return
                }
                if reason == "wake" {
                    let samples = wake.handOver()
                    carry = samples.isEmpty ? nil : samples
                }
                audio.setMuted(micMuted)
                startTimers()
                handle(.audioReady)
            }
        case .stopAudio:
            micOpen = false
            carry = nil
            audio.stop()
            stopTimers()
            setLevel(0)
            resetMute()
            updateWake(after: 0.6)
        case .warmUp(let conversationId):
            warmUp(conversationId)
        case .openMic:
            micOpen = true
            if let carry {
                // What was said right after "Hey Rabbit" (or over the reply): the utterance has begun already.
                self.carry = nil
                detector.reset()
                feed(carry)
            } else {
                detector.reset(ignoring: 0.3) // the reply's echo, the chime
            }
            audio.input.opened()
        case .closeMic:
            micOpen = false
            detector.reset()
            barge.reset()
            overReply = SampleRing(capacity: 16_000)
        case .flushMic:
            for event in detector.flush() { detected(event) }
        case .send(let request):
            send(request)
        case .cancel(let turnId, let conversationId):
            // The machine ignores the old turn from now on. Tell the bridge first (it ends the reply cleanly,
            // `done{interrupted}`), then drop the stream; playback stopped already.
            let task = turnTask
            turnTask = nil
            if let conversationId, let client {
                Task {
                    _ = try? await client.assistantCancel(conversationId: conversationId, timeout: 3)
                    task?.cancel()
                }
            } else {
                task?.cancel()
            }
            Log.write("voice: turn cancelled \(turnId.prefix(8))")
        case .stopPlayback:
            audio.stopPlayback()
        case .speak(let text):
            audio.speak(text)
        case .play(let clip):
            if !audio.play(clip: clip) { handle(.clipFailed) }
        case .haptic(let haptic):
            // The Mac has no haptics: a soft chime when it starts listening, a softer one when it ends.
            switch haptic {
            case .start: audio.chime(.start)
            case .stop: audio.chime(.end)
            case .click, .failure, .retry, .notification: break
            }
        case .end(let conversationId):
            if let client {
                Task { _ = try? await client.assistantEnd(conversationId: conversationId) }
            }
        case .announcements(let on):
            on ? startPolling() : stopPolling()
        }
    }

    /// What the dock and the menu show.
    private func publish(endedFrom before: ConversationMachine.Phase) {
        switch machine.phase {
        case .idle:
            if before != .idle, let problem = machine.problem {
                show(.error(problem))
            } else if case .error = state {
                // shown until its time is up
            } else {
                state = .idle
            }
        case .starting: state = .starting
        case .listening, .hearing: state = .listening
        case .thinking: state = .thinking
        case .speaking: state = .speaking
        }
        let exchanges = machine.exchanges
        let lastHeard = exchanges.last { !$0.heard.isEmpty }
        if heard != (lastHeard?.heard ?? "") { heard = lastHeard?.heard ?? "" }
        if heardId != lastHeard?.id { heardId = lastHeard?.id }
        let say = (machine.live ?? exchanges.last)?.say ?? ""
        if caption != say { caption = say }
        if conversationId != machine.conversationId { conversationId = machine.conversationId }
        let brainName = machine.brain == .unknown ? nil : machine.brain.rawValue
        if brain != brainName { brain = brainName }
    }

    private func show(_ error: State) {
        state = error
        errorTask?.cancel()
        errorTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self, case .error = self.state else { return }
            self.state = .idle
        }
    }

    // MARK: - Listening

    private func heardSamples(_ samples: [Int16]) {
        guard !micMuted else { return }
        if micOpen {
            feed(samples)
            return
        }
        guard machine.phase == .speaking, bargeInByVoice else { return }
        overReply.append(samples)
        if barge.feed(samples, floor: detector.floor) { bargedIn() }
    }

    /// Talking over a reply stops it (opt-in, and only with echo cancellation, or forced for the tests).
    private var bargeInByVoice: Bool {
        forceBargeIn || (audio.voiceProcessing && UserDefaults.standard.bool(forKey: Self.bargeInKey))
    }

    private func bargedIn() {
        Log.write("voice: barge-in by voice")
        // What was said over the reply (the last 0.8 s) is the start of the next utterance.
        let said = overReply.samples(from: overReply.end - 12_800)
        barge.reset()
        overReply = SampleRing(capacity: 16_000)
        carry = said
        handle(.tap)
    }

    private func feed(_ samples: [Int16]) {
        for event in detector.feed(samples) { detected(event) }
        if machine.phase == .listening || machine.phase == .hearing { setLevel(detector.level) }
    }

    private func detected(_ event: SamRabbitKit.SpeechDetector.Event) {
        switch event {
        case .speechStarted: handle(.speechStarted)
        case .discarded: handle(.discarded)
        case .utterance(let samples):
            micOpen = false
            handle(.utterance(WAV.encode(samples: samples)))
        }
    }

    private func mutedChanged() {
        audio.setMuted(micMuted)
        // Muted on purpose: the quiet end waits longer, but a forgotten mute can't hold the microphone (and other
        // apps' ducked sound) for good.
        machine.idleTimeout = micMuted ? idleTimeout * 4 : idleTimeout
        Log.write("voice: microphone " + (micMuted ? "muted" : "unmuted"))
        if micMuted {
            detector.reset()
            setLevel(0)
        }
        if !resettingMute { updateWake() }
    }

    /// Unmutes without touching the wake listener (the caller decides when it listens again).
    private func resetMute() {
        if wakeProblem == Self.mutedProblem { wakeProblem = nil }
        guard micMuted else { return }
        resettingMute = true
        micMuted = false
        resettingMute = false
    }

    private func setLevel(_ value: Double) {
        // Only changes the orb can show.
        guard abs(value - storedLevel) > 0.015 || (value == 0 && storedLevel != 0) else { return }
        storedLevel = value
        level = Float(value)
    }

    // MARK: - Turns

    /// The bridge's desktop API: loopback, the desktop token (read again for each conversation).
    static func makeClient() -> BridgeClient? {
        guard let token = Config.token(), let host = Config.origin.host else { return nil }
        let port = Config.origin.port ?? 3780
        return BridgeClient(hosts: [BridgeHost(host: host, port: port)], token: token, api: .desktop)
    }

    private func warmUp(_ conversationId: String?) {
        guard let client else {
            handle(.warmUpFailed(.unauthorized))
            return
        }
        Task {
            switch await BridgeError.capture({ try await client.assistantSession(conversationId: conversationId) }) {
            case .success(let session):
                handle(.session(session))
            case .failure(let error):
                // The warm-up is optional: a bridge without it is fine.
                if case .server(404, _, _, _) = error { return }
                if let failure = Self.failure(error) { handle(.warmUpFailed(failure)) }
            }
        }
    }

    private func send(_ request: ConversationMachine.TurnRequest) {
        turnTask?.cancel()
        let id = request.turnId
        guard let client else {
            handle(.turn(id, .failed(.unauthorized)))
            return
        }
        let turn = AssistantTurnRequest(turnId: id, conversationId: request.conversationId, input: request.input,
                                        language: VoiceFormat.languageTag(), deviceTime: .now, stream: true)
        setLevel(0)
        turnTask = Task { [weak self] in
            do {
                for try await item in client.assistantTurn(turn) {
                    if Task.isCancelled { return }
                    self?.receive(item, turn: id)
                }
            } catch {
                guard !Task.isCancelled, let self else { return }
                if let failure = Self.failure(error) { self.handle(.turn(id, .failed(failure))) }
            }
        }
    }

    private func receive(_ item: AssistantStreamItem, turn id: String) {
        guard machine.currentTurnId == id else { return }
        switch item {
        case .audio(let pcm):
            audio.schedule(pcm: pcm)
        case .clip(let clip):
            audio.play(clip: clip)
        case .event(let event):
            switch event {
            case .heard(let text): handle(.turn(id, .heard(text)))
            case .sayDelta(let text): handle(.turn(id, .sayDelta(text)))
            case .sayDone(let text): handle(.turn(id, .sayDone(text)))
            case .action(let action): handle(.turn(id, .action(action)))
            case .card(let card): handle(.turn(id, .card(card)))
            case .done(let done):
                // Nothing more comes: what waits in the jitter buffer plays now.
                audio.endOfStream()
                Log.write("voice: turn done (\(done.brain.rawValue)" + (done.interrupted ? ", interrupted" : "")
                          + (done.endConversation ? ", the end" : "") + ")")
                handle(.turn(id, .done(done)))
            case .error(let code, let message):
                Log.write("voice: turn failed (\(code))")
                handle(.turn(id, .failed(ConversationMachine.Failure(code: code, message: message))))
            case .unknown: break
            }
        }
    }

    /// What a failure means to the conversation (nil: cancelled, nothing to say).
    static func failure(_ error: Error) -> ConversationMachine.Failure? {
        switch error {
        case let error as BridgeError:
            switch error {
            case .cancelled: return nil
            case .unreachable: return .unreachable
            case .unauthorized, .notPaired: return .unauthorized
            case .invalidResponse: return .failed(code: "invalid_response", message: "")
            case .server(let status, let code, let message, _):
                return ConversationMachine.Failure(code: code, message: message, status: status)
            }
        case is CancellationError:
            return nil
        case AssistantStreamError.truncated:
            return .failed(code: "stream_truncated", message: "")
        default:
            return .failed(code: "failed", message: "")
        }
    }

    // MARK: - The wake phrase

    /// Listens for "Hey Rabbit" when it is on and nothing else uses the microphone; else not.
    private func updateWake(after delay: TimeInterval = 0) {
        wakeTask?.cancel()
        wakeTask = nil
        let inConversation = machine.phase.inConversation
        let wanted = activated && wakeEnabled && !micMuted && !noMicrophone && !inConversation
        guard wanted else {
            wake.stop()
            if !wakeEnabled {
                wakeProblem = nil
            } else if noMicrophone {
                wakeProblem = "The microphone is off in this build"
            } else if micMuted, !inConversation {
                wakeProblem = Self.mutedProblem
            } else if wakeProblem == Self.mutedProblem {
                wakeProblem = nil
            }
            return
        }
        if wakeProblem == Self.mutedProblem { wakeProblem = nil }
        guard delay > 0 else {
            wake.start()
            return
        }
        // After a conversation: let its microphone go first.
        wake.stop()
        wakeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.updateWake()
        }
    }

    // MARK: - Announcements and the clock

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func poll() async {
        guard machine.phase.inConversation, let conversationId = machine.conversationId, let client else { return }
        guard let page = try? await client.assistantAnnouncements(conversationId: conversationId, since: cursor) else { return }
        if let next = page.cursor { cursor = next }
        if !page.items.isEmpty {
            Log.write("voice: \(page.items.count) announcement(s)")
            handle(.announcements(page.items))
        }
    }

    private func startTimers() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.audio.checkStalled()
                self.handle(.tick)
            }
        }
        levelTask?.cancel()
        levelTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(66))
                guard let self else { return }
                switch self.machine.phase {
                case .speaking: self.setLevel(self.storedLevel * 0.4 + self.audio.playbackLevel() * 0.6)
                case .thinking, .idle, .starting: if self.storedLevel > 0.001 { self.setLevel(self.storedLevel * 0.6) }
                case .listening, .hearing: break
                }
            }
        }
    }

    private func stopTimers() {
        tickTask?.cancel()
        tickTask = nil
        levelTask?.cancel()
        levelTask = nil
        cursor = nil
    }
}
