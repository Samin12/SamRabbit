import Foundation
import Observation
import os
import SamRabbitKit
import SwiftUI
#if os(watchOS)
import WatchKit
#else
import UIKit
#endif

private let conversationLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.samrabbit.mobile",
                                     category: "conversation")

/// The watch's always-on conversation with SamRabbit, and the iPhone's Talk (the same file is compiled into both
/// apps): listens, sends what was said to the Mac, plays the answer as it streams in, and listens again. The rules
/// are `ConversationMachine` (SamRabbitKit, unit-tested); this carries out its effects with the audio graph
/// (`AudioGraph`), the speech detector and the bridge client, and feeds it back what happened.
///
/// * Turns stream (`application/x-samrabbit-stream`): PCM frames are played as they arrive, `say.delta` is the live
///   caption. An older bridge or the Claude fallback answers in one piece; a reply without audio is spoken by the
///   watch itself.
/// * Directly to the Mac, or (the watch) through the iPhone (`TurnRelay`) when the Mac can't be reached directly.
///   The iPhone always goes straight to the Mac with its own token.
/// * Announcements are polled about every 20 s while the conversation is open and played between turns.
/// * The iPhone also mutes the microphone (`setMuted`) and takes typed turns (`send(text:)`).
/// * Nothing heard, said, or any audio is ever logged.
@MainActor
@Observable
final class ConversationEngine {
    /// What the conversation is doing (the page shows `machine.phase`, `machine.live`, `machine.exchanges`).
    private(set) var machine: ConversationMachine
    /// 0...1 for the orb: the microphone's level while listening, the reply's while speaking.
    private(set) var level: Double {
        get { access(keyPath: \.level); return storedLevel }
        set {
            // Only changes the orb can show (and none in UI tests: `-SamRabbitStillOrb`, so the app goes idle).
            guard !Self.stillOrb, abs(newValue - storedLevel) > 0.015 || (newValue == 0 && storedLevel != 0) else { return }
            withMutation(keyPath: \.level) { storedLevel = newValue }
        }
    }
    @ObservationIgnored private var storedLevel: Double = 0
    @ObservationIgnored private static let stillOrb = UserDefaults.standard.bool(forKey: "SamRabbitStillOrb")
    /// The audio engine runs (the microphone is live). Debug builds show it to the UI tests.
    private(set) var audioRunning = false
    /// The microphone is muted (the iPhone's mute button): nothing is heard until it is unmuted; replies and
    /// announcements still play, and the quiet end waits longer (`ConversationMachine.mutedTimeout`). Kept across a
    /// pause (a call); a new conversation starts unmuted.
    var micMuted: Bool { machine.micMuted }

    @ObservationIgnored private let account: BridgeAccount
    @ObservationIgnored private let graph: AudioGraph
    @ObservationIgnored private var detector = SpeechDetector()
    @ObservationIgnored private var micOpen = false
    @ObservationIgnored private var turnTask: Task<Void, Never>?
    /// The last cancel sent to the Mac. The next turn waits for it: the Mac cancels whatever turn holds the
    /// conversation, so a turn that got there before its cancel would be the one stopped.
    @ObservationIgnored private var cancelling: Task<Void, Never>?
    /// The iPhone: a call ended while SamRabbit wasn't in front; the paused conversation goes on once it is.
    @ObservationIgnored private var resumeWhenActive = false
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var levelTask: Task<Void, Never>?
    @ObservationIgnored private var cursor: String?
    /// Called when the Mac refused the watch's token (the status shows Reconnect).
    @ObservationIgnored var onUnauthorized: (@MainActor () -> Void)?
    /// Called after each turn (the route may have changed, a task may have started).
    @ObservationIgnored var onTurnFinished: (@MainActor () -> Void)?
    /// Called after every event the conversation handled (the iPhone's Live Activity follows it).
    @ObservationIgnored var onUpdate: (@MainActor () -> Void)?

    init(account: BridgeAccount) {
        self.account = account
        let idle = UserDefaults.standard.object(forKey: "SamRabbitIdleSeconds") == nil
            ? 120 : max(5, UserDefaults.standard.double(forKey: "SamRabbitIdleSeconds"))
        machine = ConversationMachine(idleTimeout: idle)
        let input = Self.makeInput()
        graph = AudioGraph(input: input, muted: Self.muted(input))
        graph.onSamples = { [weak self] in self?.heard($0) }
        graph.onPlaying = { [weak self] in self?.handle(.playing) }
        graph.onDrained = { [weak self] in self?.handle(.drained) }
        graph.onInterrupted = { [weak self] in self?.handle(.interrupted) }
        // The iPhone: a call ended and iOS says the audio may go on: the paused conversation continues.
        graph.onResumable = { [weak self] in self?.interruptionEnded() }
        graph.onRunning = { [weak self] in self?.audioRunning = $0 }
    }

    /// The microphone; in the simulator never the Mac's own: a debug build's made-up voice
    /// (`-SamRabbitVoiceFixture`), or silence.
    static func makeInput() -> ConversationInput {
        #if DEBUG
        if let fixture = ConversationFixture.fromLaunchArguments() { return fixture }
        #endif
        #if targetEnvironment(simulator)
        return SilentInput()
        #else
        return MicrophoneInput()
        #endif
    }

    /// The simulator plays nothing out loud unless `-SamRabbitAudioOut on`.
    static func muted(_ input: ConversationInput) -> Bool {
        let setting = UserDefaults.standard.string(forKey: "SamRabbitAudioOut")
        #if targetEnvironment(simulator)
        return setting != "on"
        #else
        return setting == "mute"
        #endif
    }

    var phase: ConversationMachine.Phase { machine.phase }
    var active: Bool { machine.phase.inConversation }

    // MARK: - What the app asks for

    /// Opens a conversation (the app opened, the Action Button, Siri, a complication), or continues the one that
    /// was paused a moment ago. While one is open it goes on (back from the Crown while a reply played: it no longer
    /// pauses after the reply).
    func open() { handle(.start) }

    /// The orb (or the Action Button while talking): talk, send now, or barge in.
    func tap() { handle(.tap) }

    /// Ends the conversation; one that is paused (a call) no longer goes on by itself.
    func stop() {
        resumeWhenActive = false
        graph.forgetInterruption()
        handle(.stop)
    }

    /// The wrist came up or the app came back to the front.
    func resume() { handle(.resume) }

    /// The iPhone: the interruption that paused the conversation (a call) is over and iOS says the audio may go on.
    /// With SamRabbit in front the conversation continues (within `ConversationMachine.resumeWindow`); behind the
    /// Lock Screen or another app it waits until SamRabbit is in front again (`sceneActive`): the microphone never
    /// comes back on by itself with nothing on screen to stop it (a Live Activity can't start in the background).
    private func interruptionEnded() {
        #if os(iOS)
        guard UIApplication.shared.applicationState == .active else {
            resumeWhenActive = true
            return
        }
        #endif
        resume()
    }

    /// The iPhone: SamRabbit is in front again. A conversation paused by a call that has ended goes on.
    func sceneActive() {
        guard resumeWhenActive else { return }
        resumeWhenActive = false
        resume()
    }

    /// The app left the screen (the Digital Crown, another app): finish the reply, then pause. (The iPhone's
    /// conversation goes on in the background instead.)
    func leave() { handle(.background) }

    /// Mutes or unmutes the microphone (in voice processing too, on the iPhone). Speech being heard when it mutes is
    /// dropped.
    func setMuted(_ on: Bool) {
        guard on != micMuted, active || !on else { return }
        detector.reset()
        if on { level = 0 }
        graph.setInputMuted(on)
        handle(.muted(on))
        if on, machine.phase == .hearing { handle(.discarded) }
    }

    /// A typed turn (the iPhone's keyboard): sent as `{text}`; a reply on its way or playing is interrupted. Returns
    /// whether it went (not while the conversation starts, nor while it says a failure before it ends).
    @discardableResult
    func send(text: String) -> Bool {
        handle(.typed(text)).contains { effect in
            if case .send = effect { true } else { false }
        }
    }

    // MARK: - The machine

    @discardableResult
    private func handle(_ event: ConversationMachine.Event) -> [ConversationMachine.Effect] {
        let before = machine.phase
        let effects = machine.handle(event)
        if machine.phase != before {
            conversationLog.info("\(before.rawValue, privacy: .public) -> \(self.machine.phase.rawValue, privacy: .public)")
        }
        for effect in effects { perform(effect) }
        onUpdate?()
        return effects
    }

    private func perform(_ effect: ConversationMachine.Effect) {
        switch effect {
        case .startAudio:
            // A paused conversation goes on with its mute; a new one starts unmuted (the machine decided which).
            graph.setInputMuted(micMuted)
            Task {
                do {
                    try await graph.start()
                } catch is CancellationError {
                    // Stopped (Stop, the Crown, the conversation ended) or started again while it came up: the
                    // graph left nothing running, and a newer start reports for itself.
                    return
                } catch let failure as AudioGraph.StartFailure {
                    handle(.audioFailed(failure.message))
                    return
                } catch {
                    handle(.audioFailed("The microphone didn't start"))
                    return
                }
                // The graph gives up when stopped while it starts; should the conversation still be over, the
                // microphone must not stay on behind "Tap to talk".
                guard active else {
                    graph.stop()
                    return
                }
                startTimers()
                handle(.audioReady)
            }
        case .stopAudio:
            micOpen = false
            graph.stop()
            stopTimers()
            level = 0
        case .warmUp(let conversationId):
            warmUp(conversationId)
        case .openMic:
            detector.reset(ignoring: 0.3) // the reply's echo
            micOpen = true
            graph.input.opened()
        case .closeMic:
            micOpen = false
            detector.reset()
        case .flushMic:
            for event in detector.flush() { detected(event) }
        case .send(let request):
            send(request)
        case .cancel(let turnId, let conversationId):
            // The machine ignores the old turn from now on. Tell the Mac first (it ends the reply cleanly,
            // `done{interrupted}`), then drop the stream; playback stopped already. A turn sent meanwhile (a typed
            // one goes at once) waits for this: the Mac cancels whatever turn holds the conversation.
            let task = turnTask
            turnTask = nil
            if let conversationId, let client = account.client() {
                let earlier = cancelling
                cancelling = Task {
                    await earlier?.value
                    _ = try? await client.assistantCancel(conversationId: conversationId, turnId: turnId, timeout: 3)
                    task?.cancel()
                }
            } else {
                task?.cancel()
            }
            conversationLog.info("turn cancelled \(turnId.prefix(8), privacy: .public)")
        case .stopPlayback:
            graph.stopPlayback()
        case .speak(let text):
            graph.speak(Self.deviceWords(text))
        case .play(let clip):
            // An announcement's clip the watch can't read (an MP3 from the Claude path): its words are said instead.
            if !graph.play(clip: clip) { handle(.clipFailed) }
        case .haptic(let haptic):
            Self.play(haptic)
        case .end(let conversationId):
            if let client = account.client() {
                Task { _ = try? await client.assistantEnd(conversationId: conversationId) }
            }
        case .announcements(let on):
            on ? startPolling() : stopPolling()
        }
    }

    /// The conversation's words are the watch's; the iPhone says the few that name the watch about itself.
    static func deviceWords(_ text: String) -> String {
        #if os(iOS)
        switch text {
        case ConversationMachine.Failure.unauthorized.spoken:
            "Your Mac no longer accepts this iPhone. Pair it again in SamRabbit's Settings."
        case ConversationMachine.Failure.unauthorized.shown:
            "Pair this iPhone again"
        default:
            text
        }
        #else
        text
        #endif
    }

    private static func play(_ haptic: ConversationMachine.Haptic) {
        #if os(watchOS)
        let type: WKHapticType = switch haptic {
        case .start: .start
        case .click: .click
        case .stop: .stop
        case .failure: .failure
        case .retry: .retry
        case .notification: .notification
        }
        WKInterfaceDevice.current().play(type)
        #else
        switch haptic {
        case .start: UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        case .click: UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .stop: UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .failure: UINotificationFeedbackGenerator().notificationOccurred(.error)
        case .retry: UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .notification: UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        #endif
    }

    // MARK: - Listening

    private func heard(_ samples: [Int16]) {
        guard micOpen, !micMuted else { return }
        for event in detector.feed(samples) { detected(event) }
        if machine.phase == .listening || machine.phase == .hearing { level = detector.level }
    }

    private func detected(_ event: SpeechDetector.Event) {
        switch event {
        case .speechStarted: handle(.speechStarted)
        case .discarded: handle(.discarded)
        case .utterance(let samples):
            micOpen = false
            // Numbers only, for tuning the detector on each device's input (the iPhone's is voice-processed).
            conversationLog.info("utterance \(Double(samples.count) / Double(AssistantAudioFormat.sampleRate), format: .fixed(precision: 1), privacy: .public) s, noise floor \(self.detector.floor ?? -160, format: .fixed(precision: 0), privacy: .public) dBFS")
            handle(.utterance(WAV.encode(samples: samples)))
        }
    }

    // MARK: - Turns

    private func warmUp(_ conversationId: String?) {
        guard let client = account.client() else {
            handle(.warmUpFailed(.unauthorized))
            return
        }
        Task {
            switch await BridgeError.capture({ try await client.assistantSession(conversationId: conversationId) }) {
            case .success(let session):
                handle(.session(session))
            case .failure(let error):
                // The warm-up is optional: a bridge without it (404, the Claude fallback's first build) is fine.
                if case .server(404, _, _, _) = error { return }
                if let failure = Self.failure(error) {
                    noteRefused(failure)
                    handle(.warmUpFailed(failure))
                }
            }
        }
    }

    /// The Mac refused the watch's token: the status shows Reconnect at once (not at the next summary refresh).
    private func noteRefused(_ failure: ConversationMachine.Failure) {
        if failure == .unauthorized { onUnauthorized?() }
    }

    private func send(_ request: ConversationMachine.TurnRequest) {
        turnTask?.cancel()
        let id = request.turnId
        guard let client = account.client() else {
            handle(.turn(id, .failed(.unauthorized)))
            return
        }
        let turn = AssistantTurnRequest(turnId: id, conversationId: request.conversationId, input: request.input,
                                        language: VoiceFormat.languageTag(), deviceTime: .now, stream: true)
        level = 0
        let cancelling = cancelling
        turnTask = Task { [weak self] in
            if let cancelling {
                // A cancel still on its way goes first (3 s per address at most), or it could stop this turn on
                // the Mac.
                await cancelling.value
                if Task.isCancelled { return }
            }
            do {
                for try await item in client.assistantTurn(turn) {
                    if Task.isCancelled { return }
                    self?.receive(item, turn: id)
                }
            } catch {
                guard !Task.isCancelled, let self else { return }
                if let failure = Self.failure(error) {
                    self.noteRefused(failure)
                    self.handle(.turn(id, .failed(failure)))
                }
            }
            self?.onTurnFinished?()
        }
    }

    private func receive(_ item: AssistantStreamItem, turn id: String) {
        guard machine.currentTurnId == id else { return }
        switch item {
        case .audio(let pcm):
            graph.schedule(pcm: pcm)
        case .clip(let clip):
            graph.play(clip: clip)
        case .event(let event):
            switch event {
            case .heard(let text): handle(.turn(id, .heard(text)))
            case .sayDelta(let text): handle(.turn(id, .sayDelta(text)))
            case .sayDone(let text): handle(.turn(id, .sayDone(text)))
            case .action(let action): handle(.turn(id, .action(action)))
            case .card(let card): handle(.turn(id, .card(card)))
            case .done(let done):
                // Nothing more comes: what waits in the jitter buffer plays now (before the machine decides
                // whether the reply had audio).
                graph.endOfStream()
                handle(.turn(id, .done(done)))
            case .error(let code, let message):
                // The same rules as a refusal: one that can't get better (the assistant unavailable, a revoked
                // watch) ends the conversation once it was said; the bridge's `done` after it is ignored.
                let failure = ConversationMachine.Failure(code: code, message: message)
                noteRefused(failure)
                handle(.turn(id, .failed(failure)))
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
        guard active, let conversationId = machine.conversationId, let client = account.client() else { return }
        guard let page = try? await client.assistantAnnouncements(conversationId: conversationId, since: cursor) else { return }
        if let next = page.cursor { cursor = next }
        if !page.items.isEmpty { handle(.announcements(page.items)) }
    }

    private func startTimers() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.graph.checkStalled()
                self?.handle(.tick)
            }
        }
        levelTask?.cancel()
        levelTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(66))
                guard let self else { return }
                switch self.machine.phase {
                case .speaking: self.level = self.level * 0.4 + self.graph.playbackLevel() * 0.6
                case .thinking, .idle, .starting: if self.level > 0.001 { self.level *= 0.6 }
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
