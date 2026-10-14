import AVFoundation
import Foundation
import SamRabbitKit

/// No sound at all: what a conversation hears in the simulator unless a fixture is asked for, so the simulator
/// never listens through the Mac's own microphone (the watch and the iPhone alike).
@MainActor
final class SilentInput: ConversationInput {
    var isFixture: Bool { true }
    func allowed() async -> Bool { true }
    func start(engine: AVAudioEngine, deliver: @escaping @MainActor ([Int16]) -> Void) throws {}
    func stop(engine: AVAudioEngine) {}
    func opened() {}
}

#if DEBUG
/// Debug builds only (never in a release build): a made-up voice for the conversation, for the simulators and the
/// watch and iPhone UI tests. Each time the microphone opens it waits a moment, then "says" something for about 1.6 s (a
/// voice-like buzz in syllables at speaking level over a quiet room), then stays quiet; after `turns` utterances
/// it stays quiet for good, so the conversation's end after a quiet while can be seen too.
///
///     -SamRabbitVoiceFixture speech      speaks after each reply (the default, with the turns below)
///     -SamRabbitVoiceFixture hold        talks without a pause (the 30 s cut)
///     -SamRabbitVoiceFixture quiet       never speaks
///     -SamRabbitFixtureTurns 2           how many times it speaks (default 2)
///     -SamRabbitFixtureLead 0.8          seconds of quiet before it speaks
///     -SamRabbitFixtureLength 1.6        seconds it speaks each time (0.22: a short "yes")
///     -SamRabbitVoicePermission denied   the microphone was refused
///     -SamRabbitFixtureMicDelay 3        seconds before the microphone is allowed (the first launch's prompt,
///                                        Siri still holding it): the window where Stop or a failed warm-up comes
///                                        while the audio is still starting
///
/// Everything after it is the real thing: the 16 kHz samples go through the same speech detector, become the same
/// WAV and the same turns to the (fake) bridge.
@MainActor
final class ConversationFixture: ConversationInput {
    /// The same words as the watch's voice capture fixture (`-SamRabbitVoiceFixture`).
    enum Mode: String {
        case speech, hold, quiet
    }

    let mode: Mode
    let permitted: Bool
    let turns: Int
    let lead: TimeInterval
    let micDelay: TimeInterval
    let length: TimeInterval
    private var timer: Task<Void, Never>?
    /// Samples since the microphone last opened.
    private var position = 0
    private var speaking = false
    private var spoken = 0
    private var phase = 0.0
    private var noise: UInt32 = 7

    var isFixture: Bool { true }

    init(mode: Mode, permitted: Bool = true, turns: Int = 2, lead: TimeInterval = 0.8,
         micDelay: TimeInterval = 0, length: TimeInterval = 1.6) {
        self.mode = mode
        self.permitted = permitted
        self.turns = turns
        self.lead = lead
        self.micDelay = micDelay
        self.length = length
    }

    static func fromLaunchArguments(_ defaults: UserDefaults = .standard) -> ConversationFixture? {
        let denied = defaults.string(forKey: "SamRabbitVoicePermission") == "denied"
        guard let raw = defaults.string(forKey: "SamRabbitVoiceFixture") else {
            return denied ? ConversationFixture(mode: .quiet, permitted: false) : nil
        }
        let turns = defaults.object(forKey: "SamRabbitFixtureTurns") == nil ? 2 : defaults.integer(forKey: "SamRabbitFixtureTurns")
        let lead = defaults.object(forKey: "SamRabbitFixtureLead") == nil ? 0.8 : defaults.double(forKey: "SamRabbitFixtureLead")
        let micDelay = defaults.double(forKey: "SamRabbitFixtureMicDelay")
        let length = defaults.object(forKey: "SamRabbitFixtureLength") == nil ? 1.6 : defaults.double(forKey: "SamRabbitFixtureLength")
        return ConversationFixture(mode: Mode(rawValue: raw) ?? .speech, permitted: !denied,
                                   turns: max(0, turns), lead: max(0, lead), micDelay: min(30, max(0, micDelay)),
                                   length: min(20, max(0.05, length)))
    }

    func allowed() async -> Bool {
        if micDelay > 0 { try? await Task.sleep(for: .seconds(micDelay)) }
        return permitted
    }

    func start(engine: AVAudioEngine, deliver: @escaping @MainActor ([Int16]) -> Void) throws {
        timer?.cancel()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self else { return }
                deliver(self.next(1600))
            }
        }
    }

    func stop(engine: AVAudioEngine) {
        timer?.cancel()
        timer = nil
    }

    func opened() {
        position = 0
        speaking = mode == .hold || (mode == .speech && spoken < turns)
        if speaking, mode == .speech { spoken += 1 }
    }

    /// The next `count` samples: a quiet room, with the voice in its window.
    private func next(_ count: Int) -> [Int16] {
        var samples = [Int16](repeating: 0, count: count)
        for index in 0..<count {
            let t = Double(position + index) / 16_000
            noise = noise &* 1_664_525 &+ 1_013_904_223
            var value = (Double(noise >> 8) / Double(1 << 24) * 2 - 1) * 0.0014 // about -60 dBFS
            let start = lead
            let end = mode == .hold ? .infinity : lead + length
            if speaking, t >= start, t < end {
                let local = t - start
                let syllables = 0.62 + 0.38 * sin(2 * .pi * 4 * local)
                let edge = min(1, local / 0.04, (end - t) / 0.06)
                phase += 2 * .pi * (160 + 18 * sin(2 * .pi * 0.8 * local)) / 16_000
                let buzz = (sin(phase) + 0.5 * sin(2 * phase) + 0.25 * sin(3 * phase)) / 1.75
                value += 0.22 * syllables * edge * buzz
            }
            samples[index] = Int16(max(-32768, min(32767, value * 32767)))
        }
        position += count
        return samples
    }
}
#endif
