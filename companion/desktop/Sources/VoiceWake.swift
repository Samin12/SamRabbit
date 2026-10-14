import AVFoundation
import CoreMedia
import Foundation
import Speech

/// "Hey Rabbit": listens for the wake phrase while no conversation runs, entirely on this Mac.
///
/// * Speech is recognized on device by the Speech framework (`SpeechAnalyzer` with `SpeechTranscriber`, macOS 26;
///   `DictationTranscriber` where this Mac has no `SpeechTranscriber`). It needs no Speech Recognition permission and
///   no network; nothing heard ever leaves the Mac, and transcripts are never logged or kept.
/// * The microphone runs without voice processing (no ducking of other apps, little CPU). A cheap energy gate
///   (`WakeGate`) feeds the recognizer only while the room is loud enough for speech, so a quiet room costs nearly
///   nothing; when the sound stops, what was sent is finalized (final words come with their times).
/// * Partial (volatile) results are matched as they come (`WakePhraseMatcher`); a partial match asks the recognizer
///   for its final words at once, and the final words' times say where the phrase ended. Then `onPhrase` fires.
/// * The listener keeps listening until the conversation's own microphone runs, then hands over what was said after
///   the phrase (`handOver()`), so "Hey Rabbit, what's on my calendar?" in one breath is one question.
/// * It pauses for conversations and while the microphone is muted (`stop()`), and starts afresh after (`start()`).
@MainActor
final class VoiceWake {
    /// Whether it listens and, when it can't, why (shown in the menu and the dock).
    var onStatus: (@MainActor (_ armed: Bool, _ problem: String?) -> Void)?
    /// The phrase was heard.
    var onPhrase: (@MainActor () -> Void)?
    var matcher: WakePhraseMatcher

    private enum Phase { case off, starting, listening, heard }
    private var phase = Phase.off
    /// Bumped by every `start()` and `stop()`: an arming that waited and was overtaken gives up.
    private var generation = 0
    private let fixture: FixtureMicrophone?
    private var fixtureSubscription: FixtureMicrophone.Subscription?
    private var fixtureSpoke = false
    private var engine: AVAudioEngine?
    private var engineObserver: (any NSObjectProtocol)?
    private var session: Session?
    private var gate = WakeGate()
    private var ring = SampleRing(capacity: 16_000 * 10)
    /// Fed to the recognizer up to here (while the gate is open).
    private var fedThrough: Int64 = 0
    private var feeding = false
    private var finalizeAsked = false
    /// Where the phrase ended (absolute sample), once heard.
    private var phraseEnd: Int64?
    private let localeIdentifier: String
    /// The recognizer stopped by itself this many times in a row (a run that heard words resets it).
    private var failures = 0

    /// One recognizer run: from `start()` to `stop()`.
    private final class Session {
        let analyzer: SpeechAnalyzer
        let input: AsyncStream<AnalyzerInput>.Continuation
        let format: AVAudioFormat
        let converter: AVAudioConverter?
        var results: Task<Void, Never>?

        init(analyzer: SpeechAnalyzer, input: AsyncStream<AnalyzerInput>.Continuation, format: AVAudioFormat) {
            self.analyzer = analyzer
            self.input = input
            self.format = format
            let samples = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
            converter = format == samples ? nil : AVAudioConverter(from: samples, to: format)
        }
    }

    init(fixture: FixtureMicrophone?, phrases: [String], locale: String = "en-US") {
        self.fixture = fixture
        matcher = WakePhraseMatcher(phrases: phrases)
        localeIdentifier = locale
    }

    var listening: Bool { phase == .listening }

    // MARK: - Start and stop

    /// Starts listening (nothing happens while it already does; after the phrase was heard, afresh).
    func start() {
        if phase == .heard { stop() }
        guard phase == .off else { return }
        phase = .starting
        generation += 1
        let token = generation
        Task { await arm(token) }
    }

    private func arm(_ token: Int) async {
        let module: any SpeechModule
        do {
            module = try await Self.makeModule(locale: localeIdentifier, download: fixture == nil)
        } catch let problem as Problem {
            guard token == generation else { return }
            unavailable(problem.message)
            return
        } catch {
            guard token == generation else { return }
            unavailable("On-device speech recognition isn't available")
            return
        }
        guard token == generation else { return }
        if fixture == nil {
            let permitted: Bool = switch AVAudioApplication.shared.recordPermission {
            case .granted: true
            case .denied: false
            default: await AVAudioApplication.requestRecordPermission()
            }
            guard token == generation else { return }
            guard permitted else {
                unavailable("Microphone access is off for SamRabbit")
                return
            }
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            guard token == generation else { return }
            unavailable("On-device speech recognition isn't available")
            return
        }
        let context = AnalysisContext()
        context.contextualStrings = [.general: matcher.phrases.map { $0.joined(separator: " ") } + ["SamRabbit", "Rabbit"]]
        let (stream, input) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [module], options: .init(priority: .utility, modelRetention: .lingering))
        do {
            try await analyzer.setContext(context)
            try await analyzer.prepareToAnalyze(in: format)
            try await analyzer.start(inputSequence: stream)
        } catch {
            input.finish()
            await analyzer.cancelAndFinishNow()
            guard token == generation else { return }
            unavailable("On-device speech recognition didn't start")
            Log.write("voice: wake recognizer did not start (\(VoiceAudio.describe(error)))")
            return
        }
        guard token == generation else {
            input.finish()
            await analyzer.cancelAndFinishNow()
            return
        }
        let session = Session(analyzer: analyzer, input: input, format: format)
        session.results = listen(to: module, token: token)
        self.session = session
        do {
            try startMicrophone()
        } catch {
            stop()
            unavailable("The microphone didn't start")
            return
        }
        phase = .listening
        onStatus?(true, nil)
        Log.write("voice: listening for the wake phrase" + (fixture == nil ? "" : " (fixture)"))
    }

    /// Stops listening (a conversation starts, the microphone was muted, the setting was turned off).
    func stop() {
        generation += 1
        let wasOn = phase != .off
        phase = .off
        stopMicrophone()
        if let session {
            session.input.finish()
            session.results?.cancel()
            let analyzer = session.analyzer
            Task { await analyzer.cancelAndFinishNow() }
        }
        session = nil
        gate.reset()
        feeding = false
        finalizeAsked = false
        phraseEnd = nil
        if wasOn {
            onStatus?(false, nil)
            Log.write("voice: wake listener paused")
        }
    }

    /// What was said after the phrase until now (for the conversation's first utterance); stops listening.
    func handOver() -> [Int16] {
        let samples = phraseEnd.map { ring.samples(from: $0) } ?? []
        stop()
        return samples
    }

    private func unavailable(_ message: String) {
        phase = .off
        onStatus?(false, message)
        Log.write("voice: wake phrase off: \(message)")
    }

    // MARK: - The microphone

    private func startMicrophone() throws {
        ring = SampleRing(capacity: 16_000 * 10)
        fedThrough = 0
        if let fixture {
            fixtureSubscription = fixture.subscribe { [weak self] samples in self?.heard(samples) }
            if fixture.wakeHearsFirst, !fixtureSpoke {
                fixtureSpoke = true
                fixture.opened()
            }
            return
        }
        let engine = AVAudioEngine()
        try MacMicrophone.tap(engine.inputNode) { [weak self] samples in self?.heard(samples) }
        engine.prepare()
        try engine.start()
        self.engine = engine
        // Another microphone (AirPods, a USB mic) or the default device changed: the engine stopped; start afresh.
        engineObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                                object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.deviceChanged() }
        }
    }

    private func deviceChanged() {
        guard phase == .listening else { return }
        Log.write("voice: the microphone changed; the wake listener starts again")
        restart(after: 1)
    }

    /// Stops, and starts again after `seconds` unless it was stopped or started meanwhile (a conversation).
    private func restart(after seconds: TimeInterval) {
        stop()
        let token = generation
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, token == self.generation else { return }
            self.start()
        }
    }

    private func stopMicrophone() {
        if let fixtureSubscription { fixture?.unsubscribe(fixtureSubscription) }
        fixtureSubscription = nil
        if let engineObserver { NotificationCenter.default.removeObserver(engineObserver) }
        engineObserver = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
    }

    /// 16 kHz samples from the microphone: kept, gated, and while the gate is open fed to the recognizer.
    private func heard(_ samples: [Int16]) {
        guard phase == .listening || phase == .heard, !samples.isEmpty else { return }
        let start = ring.end
        ring.append(samples)
        guard phase == .listening, let session else { return }
        let window = 320 // 20 ms
        var offset = 0
        while offset < samples.count {
            let end = min(samples.count, offset + window)
            let power = Self.dbfs(samples[offset..<end])
            let at = start + Int64(end)
            switch gate.window(power: power, end: at) {
            case .open(let from)?:
                feeding = true
                fedThrough = max(from, ring.start)
            case .close(let through)?:
                feed(through: through, session)
                feeding = false
                finalize(through: through, session)
            case .finalize(let through)?:
                feed(through: through, session)
                finalize(through: through, session)
            case nil:
                break
            }
            offset = end
        }
        if feeding { feed(through: ring.end, session) }
    }

    private func feed(through end: Int64, _ session: Session) {
        guard end > fedThrough else { return }
        let samples = ring.samples(from: fedThrough, to: end)
        let startTime = CMTime(value: CMTimeValue(fedThrough), timescale: 16_000)
        fedThrough = end
        guard let buffer = Self.buffer(samples, session) else { return }
        session.input.yield(AnalyzerInput(buffer: buffer, bufferStartTime: startTime))
    }

    private func finalize(through end: Int64, _ session: Session) {
        finalizeAsked = false
        let analyzer = session.analyzer
        let time = CMTime(value: CMTimeValue(end), timescale: 16_000)
        Task { try? await analyzer.finalize(through: time) }
    }

    // MARK: - The words

    private func listen(to module: any SpeechModule, token: Int) -> Task<Void, Never> {
        switch module {
        case let transcriber as SpeechTranscriber:
            return Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        self?.recognized(result.text, final: result.isFinal, token: token)
                    }
                } catch {
                    self?.recognizerFailed(error, token: token)
                }
            }
        case let transcriber as DictationTranscriber:
            return Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        self?.recognized(result.text, final: result.isFinal, token: token)
                    }
                } catch {
                    self?.recognizerFailed(error, token: token)
                }
            }
        default:
            return Task {}
        }
    }

    /// A partial or final transcript of what the gate let through. Never logged.
    private func recognized(_ text: AttributedString, final: Bool, token: Int) {
        guard token == generation, phase == .listening, let session else { return }
        failures = 0
        let words = Self.words(text)
        guard let match = matcher.match(words: words.map(\.text)) else {
            if final { finalizeAsked = false }
            return
        }
        guard final else {
            // A partial match: ask for the final words now (with their times) rather than at the next pause.
            if !finalizeAsked {
                finalizeAsked = true
                let analyzer = session.analyzer
                Task { try? await analyzer.finalize(through: nil) }
            }
            return
        }
        let end = words[match.upperBound - 1].end.map { Int64(($0 * 16_000).rounded()) } ?? ring.end
        phraseEnd = min(max(end, ring.start), ring.end)
        phase = .heard
        Log.write("voice: wake phrase heard")
        onPhrase?()
    }

    private func recognizerFailed(_ error: Error, token: Int) {
        guard token == generation, phase != .off else { return }
        failures += 1
        guard failures <= 3 else {
            // Something is wrong with on-device speech: say so instead of trying forever.
            stop()
            unavailable("On-device speech recognition keeps stopping")
            return
        }
        Log.write("voice: wake recognizer stopped (\(VoiceAudio.describe(error))); starting again")
        restart(after: 2 * Double(failures))
    }

    /// The words of a transcript with where each ended (seconds), from the runs' audio time ranges.
    static func words(_ text: AttributedString) -> [(text: String, end: Double?)] {
        var words: [(text: String, end: Double?)] = []
        var current = ""
        var end: Double?
        for run in text.runs {
            let range = run.audioTimeRange
            for character in text[run.range].characters {
                if character.isWhitespace {
                    if !current.isEmpty { words.append((current, end)) }
                    current = ""
                    end = nil
                } else {
                    current.append(character)
                    if let range, range.end.isNumeric { end = range.end.seconds }
                }
            }
        }
        if !current.isEmpty { words.append((current, end)) }
        return words
    }

    // MARK: - The recognizer

    struct Problem: Error {
        let message: String
    }

    /// SpeechTranscriber for `locale` (else DictationTranscriber), its model on this Mac. A missing model is
    /// downloaded first when `download` (the app; never in fixture mode).
    static func makeModule(locale identifier: String, download: Bool) async throws -> any SpeechModule {
        let wanted = Locale(identifier: identifier)
        if SpeechTranscriber.isAvailable, let locale = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) {
            let module = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                           reportingOptions: [.volatileResults, .fastResults],
                                           attributeOptions: [.audioTimeRange])
            let installed = await SpeechTranscriber.installedLocales
            try await ensureModel(module, installed: installed.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) },
                                  download: download)
            return module
        }
        if let locale = await DictationTranscriber.supportedLocale(equivalentTo: wanted) {
            let module = DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [],
                                              reportingOptions: [.volatileResults], attributeOptions: [.audioTimeRange])
            let installed = await DictationTranscriber.installedLocales
            try await ensureModel(module, installed: installed.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) },
                                  download: download)
            return module
        }
        throw Problem(message: "This Mac can't recognize \(identifier) speech on device")
    }

    private static func ensureModel(_ module: any SpeechModule, installed: Bool, download: Bool) async throws {
        guard !installed else { return }
        guard download else { throw Problem(message: "The on-device speech model isn't installed") }
        Log.write("voice: downloading the on-device speech model for the wake phrase")
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                try await request.downloadAndInstall()
            }
        } catch {
            throw Problem(message: "The on-device speech model couldn't be downloaded")
        }
    }

    /// 16 kHz mono 16-bit samples as the recognizer's format.
    private static func buffer(_ samples: [Int16], _ session: Session) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty, let count = AVAudioFrameCount(exactly: samples.count),
              let pcm = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
              let buffer = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: count),
              let channel = buffer.int16ChannelData?[0] else { return nil }
        buffer.frameLength = count
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        guard let converter = session.converter else { return buffer }
        let frames = Double(count) * session.format.sampleRate / 16_000 + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: session.format, frameCapacity: AVAudioFrameCount(frames)) else {
            return nil
        }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil ? output : nil
    }

    static func dbfs(_ samples: ArraySlice<Int16>) -> Double {
        guard !samples.isEmpty else { return -160 }
        var sum = 0.0
        for sample in samples {
            let value = Double(sample) / 32768
            sum += value * value
        }
        let rms = (sum / Double(samples.count)).squareRoot()
        return rms > 0 ? max(-160, 20 * log10(rms)) : -160
    }
}
