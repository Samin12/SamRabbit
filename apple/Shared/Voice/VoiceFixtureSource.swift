#if DEBUG
import AVFoundation
import Foundation
import SamRabbitKit

/// Debug builds only (never in a release build): a made-up voice instead of the microphone, so the simulator
/// walkthroughs and the UI tests (the watch's voice input, voice notes on the watch and the iPhone) drive the real
/// capture without a mic or a permission prompt. Without a fixture the simulators hear this in `quiet` mode: they
/// never record through the Mac's microphone.
///
///     -SamRabbitVoiceFixture speech    about 1.8 s of a voice-like sound, then quiet: it stops by itself
///     -SamRabbitVoiceFixture hold      the sound the whole time: tap Stop (or the cap)
///     -SamRabbitVoiceFixture quiet     nothing: tap Stop
///     -SamRabbitVoicePermission denied the microphone permission was refused
///
/// The levels it reports follow the same envelope as the sound, and the file it leaves is a real AAC
/// `.m4a` in the watch's format (`VoiceFormat.recorderSettings`, written with `AVAudioFile`), so the
/// upload, the bridge's checks and the iPhone relay are the real ones. The fake bridge answers with canned
/// words.
@MainActor
final class VoiceFixtureSource: VoiceSource {
    enum Mode: String {
        case speech, hold, quiet
    }

    let mode: Mode
    let permitted: Bool
    private var file: URL?
    private var startedAt: Date?
    var onInterrupted: (@MainActor () -> Void)?

    init(mode: Mode, permitted: Bool = true) {
        self.mode = mode
        self.permitted = permitted
    }

    static func fromLaunchArguments(_ defaults: UserDefaults = .standard) -> VoiceFixtureSource? {
        let denied = defaults.string(forKey: "SamRabbitVoicePermission") == "denied"
        guard let raw = defaults.string(forKey: "SamRabbitVoiceFixture") else {
            return denied ? VoiceFixtureSource(mode: .quiet, permitted: false) : nil
        }
        return VoiceFixtureSource(mode: Mode(rawValue: raw) ?? .speech, permitted: !denied)
    }

    func allowed() async -> Bool { permitted }

    func start(into file: URL) throws {
        self.file = file
        startedAt = .now
    }

    func power() -> Double {
        let t = startedAt.map { Date.now.timeIntervalSince($0) } ?? 0
        let amplitude = Self.envelope(mode, at: t)
        return amplitude > 0 ? 20 * log10(amplitude * 0.707) : -62 + 2 * sin(t * 7)
    }

    func stop() {
        guard let file, let startedAt else { return }
        self.file = nil
        self.startedAt = nil
        do {
            try Self.write(mode, seconds: max(0.05, Date.now.timeIntervalSince(startedAt)), to: file)
        } catch {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// The sound's loudness over time: syllables (4 Hz) between 0.3 s and 2.1 s, or the whole time.
    static func envelope(_ mode: Mode, at t: TimeInterval) -> Double {
        switch mode {
        case .quiet: return 0
        case .speech where t < 0.3 || t > 2.1: return 0
        case .hold where t < 0.3: return 0
        default: return 0.18 * (0.65 + 0.35 * sin(2 * .pi * 4 * t))
        }
    }

    /// A voice-like tone (a 160 Hz buzz with a few harmonics) shaped by `envelope`, as an AAC m4a.
    static func write(_ mode: Mode, seconds: TimeInterval, to url: URL) throws {
        let rate = VoiceFormat.sampleRate
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else { return }
        let output = try AVAudioFile(forWriting: url, settings: VoiceFormat.recorderSettings,
                                     commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(seconds * rate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let samples = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = frames
        for index in 0..<Int(frames) {
            let t = Double(index) / rate
            let buzz = sin(2 * .pi * 160 * t) + 0.5 * sin(2 * .pi * 320 * t) + 0.25 * sin(2 * .pi * 480 * t)
            samples[index] = Float(envelope(mode, at: t) * buzz / 1.75)
        }
        try output.write(from: buffer)
    }
}
#endif
