import AVFoundation
import Foundation

/// Voice fixture mode (development and tests only): the conversation and the "Hey Rabbit" listener hear WAV files
/// instead of the microphone, and nothing plays out loud (the conversation's audio is rendered into memory, never to
/// a device). The microphone is never touched, so no permission prompt can come up.
///
///     SAMRABBIT_VOICE_FIXTURE=/tmp/ask.wav,/tmp/bye.wav   each time the microphone opens it "says" the next file
///     SAMRABBIT_VOICE_FIXTURE_WAKE=1                      the wake listener hears the first file (say "Hey Rabbit,
///                                                         …" in it); otherwise it hears a quiet room only
///     SAMRABBIT_VOICE_FIXTURE_LEAD=0.6                    seconds of quiet before each file
///
/// Like a real microphone it is one stream, in real time (100 ms pieces of 16 kHz mono 16-bit), shared by whoever
/// listens: a quiet room (about -60 dBFS) with the files in it. Any audio format `AVAudioFile` reads works; it is
/// converted to 16 kHz mono once at start.
@MainActor
final class FixtureMicrophone {
    /// The fixture of this run, if `SAMRABBIT_VOICE_FIXTURE` is set.
    static let shared: FixtureMicrophone? = FixtureMicrophone(environment: ProcessInfo.processInfo.environment)

    struct Subscription: Hashable {
        fileprivate let id: Int
    }

    let wakeHearsFirst: Bool
    private var segments: [[Int16]]
    private let lead: TimeInterval
    /// What is being "said" now, and how far it got.
    private var current: [Int16] = []
    private var position = 0
    private var startsAt = 0
    private var listeners: [Int: @MainActor ([Int16]) -> Void] = [:]
    private var nextId = 0
    private var clock: Task<Void, Never>?
    private var noise: UInt32 = 7
    private var spoken = 0

    init?(environment: [String: String]) {
        guard let raw = environment["SAMRABBIT_VOICE_FIXTURE"]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty
        else { return nil }
        let paths = raw.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        segments = paths.compactMap { Self.load($0) }
        lead = max(0, Double(environment["SAMRABBIT_VOICE_FIXTURE_LEAD"] ?? "") ?? 0.6)
        wakeHearsFirst = environment["SAMRABBIT_VOICE_FIXTURE_WAKE"] == "1"
        Log.write("voice: fixture microphone with \(segments.count) of \(paths.count) files (nothing plays out loud)")
    }

    /// Files not yet said.
    var remaining: Int { segments.count }

    func subscribe(_ deliver: @escaping @MainActor ([Int16]) -> Void) -> Subscription {
        nextId += 1
        listeners[nextId] = deliver
        startClock()
        return Subscription(id: nextId)
    }

    func unsubscribe(_ subscription: Subscription) {
        listeners[subscription.id] = nil
        if listeners.isEmpty {
            clock?.cancel()
            clock = nil
        }
    }

    /// The microphone opened for the next utterance: the next file is said after the lead (nothing when none is left).
    func opened() {
        guard !segments.isEmpty else { return }
        current = segments.removeFirst()
        position = 0
        startsAt = Int(lead * 16_000)
        spoken += 1
        Log.write("voice: fixture says file \(spoken) (\(current.count * 1000 / 16_000) ms)")
    }

    private func startClock() {
        guard clock == nil else { return }
        let started = Date()
        var delivered = 0
        clock = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self else { return }
                // Real time: as many 100 ms pieces as are due (a busy main thread catches up).
                let due = Int(Date().timeIntervalSince(started) * 10)
                while delivered < due {
                    delivered += 1
                    let piece = self.next(1_600)
                    for deliver in self.listeners.values { deliver(piece) }
                }
            }
        }
    }

    /// The next `count` samples: a quiet room, with the file being said in it.
    private func next(_ count: Int) -> [Int16] {
        var samples = [Int16](repeating: 0, count: count)
        for index in 0..<count {
            noise = noise &* 1_664_525 &+ 1_013_904_223
            var value = Int((Double(noise >> 8) / Double(1 << 24) * 2 - 1) * 0.001 * 32_767) // about -63 dBFS
            if !current.isEmpty {
                if startsAt > 0 {
                    startsAt -= 1
                } else if position < current.count {
                    value += Int(current[position])
                    position += 1
                    if position == current.count { current = [] }
                }
            }
            samples[index] = Int16(clamping: value)
        }
        return samples
    }

    /// A sound file as 16 kHz mono 16-bit samples (nil when it can't be read).
    static func load(_ path: String) -> [Int16]? {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let file = try? AVAudioFile(forReading: url), file.length > 0, file.length < 16_000 * 600,
              let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: source)) != nil,
              let converter = TapConverter(from: file.processingFormat),
              let samples = converter.convert(source, final: true) else {
            Log.write("voice: a fixture file could not be read")
            return nil
        }
        return samples
    }
}

/// The conversation's input in fixture mode: the shared fixture microphone.
@MainActor
final class FixtureInput: VoiceInput {
    private let microphone: FixtureMicrophone
    private var subscription: FixtureMicrophone.Subscription?

    init(_ microphone: FixtureMicrophone) {
        self.microphone = microphone
    }

    var isFixture: Bool { true }
    func allowed() async -> Bool { true }

    func start(engine: AVAudioEngine, deliver: @escaping @MainActor ([Int16]) -> Void) throws {
        if let subscription { microphone.unsubscribe(subscription) }
        subscription = microphone.subscribe(deliver)
    }

    func stop(engine: AVAudioEngine) {
        if let subscription { microphone.unsubscribe(subscription) }
        subscription = nil
    }

    func opened() { microphone.opened() }
    func setMuted(_ muted: Bool, engine: AVAudioEngine) {}
}
