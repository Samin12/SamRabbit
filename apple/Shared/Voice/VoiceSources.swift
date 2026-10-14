import AVFoundation
import Foundation
import SamRabbitKit

// Where a recording's sound comes from, for the watch's voice input and for voice notes on the watch and the iPhone:
// the device's microphone (`AVAudioRecorder`, AAC 16 kHz mono 32 kbps, `VoiceFormat.recorderSettings`) or, in debug
// builds, a made-up voice for the simulators (`VoiceFixtureSource`). Compiled into the iPhone app and the watch app.

/// A sound source for one recording. Main actor: the recorder is polled for its level (no callbacks of its own).
@MainActor
protocol VoiceSource: AnyObject {
    /// Whether the microphone may be used (asks the first time; only ever from a screen in front).
    func allowed() async -> Bool
    /// Starts recording into `file` (AAC, `VoiceFormat.recorderSettings`).
    func start(into file: URL) throws
    /// The average power right now, in dBFS.
    func power() -> Double
    /// Stops; the file is complete afterwards.
    func stop()
    /// Something else took the microphone (a call, Siri): what was recorded is kept, the recording ends.
    var onInterrupted: (@MainActor () -> Void)? { get set }
}

/// The device's microphone: `AVAudioRecorder` with metering on the `.record` audio session, which it claims through
/// `AudioSessionUse` like Talk and dictation do (one microphone; the last holder gives the session back). `limit` is
/// how long it may record (the caller stops it on its own before that).
@MainActor
final class MicrophoneSource: VoiceSource {
    private var recorder: AVAudioRecorder?
    private var observer: (any NSObjectProtocol)?
    private let limit: TimeInterval
    private let holder: AudioSessionClaims.Holder
    var onInterrupted: (@MainActor () -> Void)?

    struct StartFailed: Error {}

    init(limit: TimeInterval = VoiceFormat.maxSeconds, holder: AudioSessionClaims.Holder = .capture) {
        self.limit = limit
        self.holder = holder
    }

    func allowed() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: true
        case .denied: false
        default: await AVAudioApplication.requestRecordPermission()
        }
    }

    func start(into file: URL) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default)
        #if os(iOS)
        try? session.setPrefersNoInterruptionsFromSystemAlerts(true)
        #endif
        try session.setActive(true)
        AudioSessionUse.claim(holder)
        let recorder: AVAudioRecorder
        do {
            recorder = try AVAudioRecorder(url: file, settings: VoiceFormat.recorderSettings)
        } catch {
            AudioSessionUse.release(holder)
            throw error
        }
        recorder.isMeteringEnabled = true
        // A little past the cap: the caller stops at its own limit.
        guard recorder.prepareToRecord(), recorder.record(forDuration: limit + 1) else {
            AudioSessionUse.release(holder)
            throw StartFailed()
        }
        self.recorder = recorder
        observer = Self.observeInterruptions { [weak self] in self?.interrupted() }
    }

    func power() -> Double {
        guard let recorder else { return -160 }
        recorder.updateMeters()
        return Double(recorder.averagePower(forChannel: 0))
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        guard let recorder else { return }
        recorder.stop()
        self.recorder = nil
        AudioSessionUse.release(holder)
    }

    private func interrupted() {
        guard recorder != nil else { return }
        onInterrupted?()
    }

    /// The start of an interruption (a call, Siri). Nonisolated, so the observer's closure doesn't inherit the main
    /// actor: AVFoundation posts these on its own queue, and Swift 6 traps a main-actor closure run anywhere else
    /// (main 7a11958). It hops to the main queue itself.
    private nonisolated static func observeInterruptions(_ began: @escaping @MainActor @Sendable () -> Void)
        -> any NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil,
                                               queue: nil) { note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            guard type == .began else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { began() } }
        }
    }
}

extension MicrophoneSource {
    /// The microphone, or in debug builds the simulator's made-up voice (`-SamRabbitVoiceFixture`). The simulator
    /// never records through the Mac's own microphone: without a fixture it hears silence.
    static func source(limit: TimeInterval) -> VoiceSource {
        #if DEBUG
        if let fixture = VoiceFixtureSource.fromLaunchArguments() { return fixture }
        if inSimulator { return VoiceFixtureSource(mode: .quiet) }
        #endif
        return MicrophoneSource(limit: limit)
    }

    private static var inSimulator: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }
}
