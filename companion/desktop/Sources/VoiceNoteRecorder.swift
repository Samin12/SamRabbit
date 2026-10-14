import AVFoundation
import Foundation

/// A voice note's microphone (CONTRACTS-WAVE8 §D1): a tap on its own `AVAudioEngine`'s input (no voice processing:
/// nothing plays, other apps aren't ducked), converted to 16 kHz mono 16-bit by `MacMicrophone.tap` (`TapConverter`),
/// kept in memory until the note ends (five minutes is 9.6 MB). Nothing is written or sent from here: `VoiceNotes`
/// encodes the WAV and keeps it in the outbox first.
///
/// In fixture mode (`SAMRABBIT_VOICE_FIXTURE`) it hears the fixture microphone's next file instead and the microphone is
/// never touched (no permission prompt can come up); `SAMRABBIT_NO_MIC=1` keeps it off altogether.
@MainActor
final class VoiceNoteRecorder {
    enum Failure: Error, Equatable {
        case microphoneOff
        case denied
        case engine

        var message: String {
            switch self {
            case .microphoneOff: return "The microphone is off in this build"
            case .denied: return "Microphone access is off for SamRabbit"
            case .engine: return "The microphone didn’t start"
            }
        }
    }

    /// Each new piece (about 100 ms), on the main actor.
    var onSamples: (@MainActor ([Int16]) -> Void)?
    /// The audio device changed and the microphone could not come back: what was heard so far is still there.
    var onInterrupted: (@MainActor () -> Void)?

    private(set) var samples: [Int16] = []
    private let fixture: FixtureMicrophone?
    private let noMicrophone: Bool
    private var engine: AVAudioEngine?
    private var subscription: FixtureMicrophone.Subscription?
    private var observer: (any NSObjectProtocol)?
    /// Bumped by every start and stop: pieces from a microphone that was let go are dropped.
    private var generation = 0

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let fixture = FixtureMicrophone.shared
        self.fixture = fixture
        noMicrophone = fixture == nil && environment["SAMRABBIT_NO_MIC"] == "1"
    }

    var isFixture: Bool { fixture != nil }
    var running: Bool { engine != nil || subscription != nil }
    var seconds: Double { Double(samples.count) / 16_000 }

    /// Starts hearing (asks for the microphone the first time only). Throws `CancellationError` when `stop()` or
    /// `cancel()` came while it waited for the answer.
    func start() async throws {
        release()
        generation += 1
        let mine = generation
        samples = []
        if let fixture {
            subscription = fixture.subscribe { [weak self] piece in self?.heard(piece, mine) }
            fixture.opened()
            Log.write("note: fixture microphone (nothing recorded)")
            return
        }
        if noMicrophone { throw Failure.microphoneOff }
        let permitted: Bool
        switch AVAudioApplication.shared.recordPermission {
        case .granted: permitted = true
        case .denied: permitted = false
        default: permitted = await AVAudioApplication.requestRecordPermission()
        }
        guard mine == generation else { throw CancellationError() }
        guard permitted else { throw Failure.denied }
        let engine = AVAudioEngine()
        do {
            try MacMicrophone.tap(engine.inputNode) { [weak self] piece in self?.heard(piece, mine) }
            engine.prepare()
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            Log.write("note: the microphone didn't start (\(VoiceAudio.describe(error)))")
            throw Failure.engine
        }
        self.engine = engine
        // Headphones came or went, the input changed: the engine stopped; hear from the new device.
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconfigure(mine) }
        }
    }

    /// Stops and hands over everything heard.
    func stop() -> [Int16] {
        release()
        let heard = samples
        samples = []
        return heard
    }

    /// Stops and forgets it.
    func cancel() {
        release()
        samples = []
    }

    private func heard(_ piece: [Int16], _ from: Int) {
        guard from == generation, running else { return }
        samples.append(contentsOf: piece)
        onSamples?(piece)
    }

    private func reconfigure(_ from: Int) {
        guard from == generation, let engine else { return }
        Log.write("note: audio device changed")
        engine.inputNode.removeTap(onBus: 0)
        do {
            try MacMicrophone.tap(engine.inputNode) { [weak self] piece in self?.heard(piece, from) }
            engine.prepare()
            try engine.start()
        } catch {
            onInterrupted?()
        }
    }

    private func release() {
        generation += 1
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        if let subscription, let fixture { fixture.unsubscribe(subscription) }
        subscription = nil
    }
}
