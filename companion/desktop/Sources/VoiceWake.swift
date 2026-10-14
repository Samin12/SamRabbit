import AVFoundation
import CoreMedia
import Foundation
import Speech

/// "Hey Rabbit": listens for the wake phrase while no conversation runs, entirely on this Mac.
///
/// * Speech is recognized on device by the Speech framework (`SpeechAnalyzer` with `SpeechTranscriber`, macOS 26;
///   `DictationTranscriber` where this Mac has no `SpeechTranscriber`). It needs no Speech Recognition permission and
///   no network; nothing heard ever leaves the Mac, and transcripts are never logged or kept.
/// * The microphone runs without voice processing (no ducking of other apps, little CPU), on the default input unless
///   that is a Bluetooth headset or an iPhone (`WakeMicrophoneChoice`: listening all day would put AirPods in call
///   quality); then on the built-in microphone, or not at all until the inputs change.
/// * A cheap energy gate (`WakeGate`) decides when the room is loud enough for speech; a quiet room costs nearly
///   nothing. Each stretch of sound it lets through is one recognizer run (`Run`): its own analyzer, fed from just
///   before the sound in 100 ms pieces on its own unbroken clock, then the quiet `tail` after it, then finished so
///   the final words come with their times. (One analyzer fed the stretches with gaps between them lost the first
///   words of each new stretch, and gave its final words only once more sound came.) The model stays loaded between
///   runs, so a run starts in a few milliseconds; the sound is kept meanwhile.
/// * Results are matched as they come (`WakeRunWords`): a partial match asks the run for its final words at once,
///   and the final words' times say where the phrase ended. Then `onPhrase` fires.
/// * The listener keeps listening until the conversation's own microphone runs, then hands over what was said after
///   the phrase (`handOver()`), so "Hey Rabbit, what's on my calendar?" in one breath is one question.
/// * It pauses for conversations and while the microphone is muted (`stop()`), and starts afresh after (`start()`).
///   A recognizer that keeps failing makes it pause and try again (`WakeRetry`), once a minute at worst; it never
///   gives up for good.
@MainActor
final class VoiceWake {
    /// Whether it listens and, when it can't, why (shown in the menu and the dock).
    var onStatus: (@MainActor (_ armed: Bool, _ problem: String?) -> Void)?
    /// The phrase was heard.
    var onPhrase: (@MainActor () -> Void)?
    var matcher: WakePhraseMatcher

    private enum Phase { case off, starting, listening, heard }
    private var phase = Phase.off
    /// Bumped by every `start()` and `stop()`: an arming that waited and was overtaken gives up, results of runs from
    /// before are ignored.
    private var generation = 0
    private let fixture: FixtureMicrophone?
    private var fixtureSubscription: FixtureMicrophone.Subscription?
    private var fixtureSpoke = false
    private var engine: AVAudioEngine?
    private var engineObserver: (any NSObjectProtocol)?
    /// Watches the inputs while it listens, or waits for them to change.
    private var inputWatcher: AudioInputWatcher?
    /// The device it listens with (nil: the default input, or a fixture).
    private var listeningDevice: UInt32?
    private var waitingForDevice = false
    private var recognizer: Recognizer?
    private var format: AVAudioFormat?
    /// The run being fed (the gate is open, or the tail after it is being fed). Finished runs live on in their result
    /// tasks until their final words are in.
    private var run: Run?
    private var gate = WakeGate()
    private var ring = SampleRing(capacity: 16_000 * 10)
    /// Where the phrase ended (absolute sample), once heard.
    private var phraseEnd: Int64?
    /// The room just before the stretch of sound with the phrase began (its run's pre-roll), once heard.
    private var room: Range<Int64>?
    private let localeIdentifier: String
    /// Recognizer runs that failed in a row (a run that gave words or finished resets it).
    private var failures = 0

    /// One recognizer run: one stretch of sound, from the pre-roll before it to the tail after it.
    private final class Run {
        let analyzer: SpeechAnalyzer
        let input: AsyncStream<AnalyzerInput>.Continuation
        let format: AVAudioFormat
        let converter: AVAudioConverter?
        /// The absolute sample at the run's time zero.
        let origin: Int64
        /// Fed up to here (absolute sample).
        var fed: Int64
        /// The analyzer started: it can be fed.
        var ready = false
        /// The gate closed here: the tail after it is fed, then the run finishes.
        var closedAt: Int64?
        var finishing = false
        var ended = false
        var words: WakeRunWords
        var results: Task<Void, Never>?

        init(analyzer: SpeechAnalyzer, input: AsyncStream<AnalyzerInput>.Continuation, format: AVAudioFormat,
             origin: Int64, matcher: WakePhraseMatcher) {
            self.analyzer = analyzer
            self.input = input
            self.format = format
            self.origin = origin
            fed = origin
            words = WakeRunWords(matcher: matcher)
            let samples = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
            converter = format == samples ? nil : AVAudioConverter(from: samples, to: format)
        }

        /// The absolute sample `seconds` into the run.
        func sample(at seconds: Double) -> Int64 {
            seconds.isFinite ? origin + Int64((max(0, seconds) * 16_000).rounded()) : fed
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
        waitingForDevice = false
        generation += 1
        let token = generation
        Task { await arm(token) }
    }

    private func arm(_ token: Int) async {
        let recognizer: Recognizer
        do {
            recognizer = try await Self.makeRecognizer(locale: localeIdentifier, download: fixture == nil)
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
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [recognizer.module()]) else {
            guard token == generation else { return }
            unavailable("On-device speech recognition isn't available")
            return
        }
        // Load the model now; it stays loaded a while after each run, so runs start at once.
        let warm = SpeechAnalyzer(modules: [recognizer.module()], options: Self.options)
        try? await warm.prepareToAnalyze(in: format)
        await warm.cancelAndFinishNow()
        guard token == generation else { return }
        self.recognizer = recognizer
        self.format = format
        watchInputs()
        let choice = chooseMicrophone()
        if case .waiting(let reason) = choice {
            waitForDevice(reason)
            return
        }
        do {
            try startMicrophone(choice)
        } catch {
            stop()
            unavailable("The microphone didn't start")
            return
        }
        phase = .listening
        onStatus?(true, nil)
        Log.write("voice: listening for the wake phrase" + (fixture != nil ? " (fixture)"
                                                            : choice == .systemDefault ? "" : " (built-in microphone)"))
    }

    /// Stops listening (a conversation starts, the microphone was muted, the setting was turned off).
    func stop() {
        generation += 1
        let wasOn = phase != .off || waitingForDevice
        phase = .off
        waitingForDevice = false
        inputWatcher?.invalidate()
        inputWatcher = nil
        stopMicrophone()
        if let run { cancel(run) }
        run = nil
        gate.reset()
        phraseEnd = nil
        room = nil
        if wasOn {
            onStatus?(false, nil)
            Log.write("voice: wake listener paused")
        }
    }

    /// What was said after the phrase until now (for the conversation's first utterance), after a moment of the
    /// room from before the phrase: the conversation's speech detector learns the room from it, or it would take the
    /// first word for the room ("what's" of "Hey Rabbit, what's on my calendar?"). Stops listening.
    func handOver() -> [Int16] {
        var samples: [Int16] = []
        if let phraseEnd {
            if let room, room.lowerBound >= ring.start { samples = ring.samples(from: room.lowerBound, to: room.upperBound) }
            samples += ring.samples(from: phraseEnd)
        }
        stop()
        return samples
    }

    private func unavailable(_ message: String) {
        phase = .off
        onStatus?(false, message)
        Log.write("voice: wake phrase off: \(message)")
    }

    /// Stops, and starts again after `seconds` unless it was stopped or started meanwhile (a conversation); `problem`
    /// is shown meanwhile.
    private func restart(after seconds: TimeInterval, problem: String? = nil) {
        stop()
        if let problem { onStatus?(false, problem) }
        let token = generation
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, token == self.generation else { return }
            self.start()
        }
    }

    // MARK: - The microphone

    /// Which microphone to listen with (a fixture is the default).
    private func chooseMicrophone() -> WakeMicrophoneChoice {
        guard fixture == nil else { return .systemDefault }
        return WakeMicrophoneChoice.choose(AudioInputs.devices(), defaultInput: AudioInputs.defaultInput())
    }

    /// The only microphone is a Bluetooth headset or an iPhone (or there is none): wait until the inputs change.
    private func waitForDevice(_ reason: String) {
        phase = .off
        waitingForDevice = true
        onStatus?(false, reason)
        Log.write("voice: the wake listener waits for another microphone")
    }

    private func watchInputs() {
        guard fixture == nil, inputWatcher == nil else { return }
        inputWatcher = AudioInputWatcher { [weak self] in self?.inputsChanged() }
    }

    /// The default input or the devices changed: listen with the microphone it should now (or wait).
    private func inputsChanged() {
        if waitingForDevice {
            if case .waiting = chooseMicrophone() { return }
            Log.write("voice: the inputs changed; the wake listener starts")
            waitingForDevice = false
            start()
            return
        }
        guard phase == .listening else { return }
        let defaultInput = AudioInputs.defaultInput()
        let wanted = chooseMicrophone().device(defaultInput: defaultInput)
        guard wanted != (listeningDevice ?? defaultInput) else { return }
        Log.write("voice: the inputs changed; the wake listener starts again")
        restart(after: 0.5)
    }

    private func startMicrophone(_ choice: WakeMicrophoneChoice) throws {
        ring = SampleRing(capacity: 16_000 * 10)
        listeningDevice = nil
        if let fixture {
            fixtureSubscription = fixture.subscribe { [weak self] samples in self?.heard(samples) }
            if fixture.wakeHearsFirst, !fixtureSpoke {
                fixtureSpoke = true
                fixture.opened()
            }
            return
        }
        let engine = AVAudioEngine()
        if case .device(let id) = choice {
            try AudioInputs.use(id, for: engine.inputNode)
            listeningDevice = id
        }
        try MacMicrophone.tap(engine.inputNode) { [weak self] samples in self?.heard(samples) }
        engine.prepare()
        try engine.start()
        self.engine = engine
        // The microphone's device changed or went away: the engine stopped; start afresh.
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
        listeningDevice = nil
    }

    /// 16 kHz samples from the microphone: kept, gated, and fed to the run of the stretch of sound they belong to.
    private func heard(_ samples: [Int16]) {
        guard phase == .listening || phase == .heard, !samples.isEmpty else { return }
        let start = ring.end
        ring.append(samples)
        guard phase == .listening else { return }
        let window = 320 // 20 ms
        var offset = 0
        while offset < samples.count {
            let end = min(samples.count, offset + window)
            let power = Self.dbfs(samples[offset..<end])
            let at = start + Int64(end)
            switch gate.window(power: power, end: at) {
            case .open(let from)?:
                if let run, run.closedAt != nil {
                    run.closedAt = nil // sound again during the tail: the same run goes on
                } else if run == nil {
                    open(from: max(from, ring.start))
                }
            case .close(let through)?:
                run?.closedAt = through
            case .finalize(let through)?:
                if let run, run.ready {
                    pump(run)
                    let analyzer = run.analyzer
                    let time = CMTime(value: CMTimeValue(through - run.origin), timescale: 16_000)
                    Task { try? await analyzer.finalize(through: time) }
                }
            case nil:
                break
            }
            offset = end
        }
        if let run { pump(run) }
    }

    // MARK: - Recognizer runs

    private static let options = SpeechAnalyzer.Options(priority: .utility, modelRetention: .lingering)

    /// A new run for the stretch of sound that starts at `from`.
    private func open(from: Int64) {
        guard let recognizer, let format else { return }
        let module = recognizer.module()
        let (stream, input) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [module], options: Self.options)
        let run = Run(analyzer: analyzer, input: input, format: format, origin: from, matcher: matcher)
        self.run = run
        let token = generation
        run.results = listen(to: module, run: run, token: token)
        let context = AnalysisContext()
        context.contextualStrings = [.general: matcher.phrases.map { $0.joined(separator: " ") } + ["SamRabbit", "Rabbit"]]
        Task {
            do {
                try await analyzer.setContext(context)
                try await analyzer.prepareToAnalyze(in: format)
                try await analyzer.start(inputSequence: stream)
            } catch {
                runFailed(run, error, token: token)
                return
            }
            guard token == generation, !run.ended else { return }
            run.ready = true
            pump(run)
        }
    }

    /// Feeds `run` what the ring has for it: up to now while the gate is open, the tail after a close; then finishes
    /// it once the tail is in.
    private func pump(_ run: Run) {
        guard run.ready, !run.finishing, !run.ended else { return }
        let tail = gate.settings.samples(gate.settings.tail)
        let limit = run.closedAt.map { min(ring.end, $0 + tail) } ?? ring.end
        // 100 ms pieces: one long buffer can stall the analyzer.
        var from = max(run.fed, ring.start)
        while from < limit {
            let to = min(limit, from + 1_600)
            // Its own clock, unbroken (a converter changes the pieces' lengths: then each follows the last).
            let time = run.converter == nil ? CMTime(value: CMTimeValue(from - run.origin), timescale: 16_000) : nil
            if let buffer = Self.buffer(ring.samples(from: from, to: to), run) {
                run.input.yield(AnalyzerInput(buffer: buffer, bufferStartTime: time))
            }
            from = to
        }
        run.fed = max(run.fed, limit)
        if let closed = run.closedAt, run.fed >= closed + tail { finish(run) }
    }

    /// The stretch of sound and its tail are in: the run gives its final words for everything up to the close, then
    /// ends. One that doesn't end within a few seconds is dropped.
    private func finish(_ run: Run) {
        run.finishing = true
        if self.run === run { self.run = nil }
        run.input.finish()
        let analyzer = run.analyzer
        let through = CMTime(value: CMTimeValue((run.closedAt ?? run.fed) - run.origin), timescale: 16_000)
        Task { try? await analyzer.finalizeAndFinish(through: through) }
        let token = generation
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, !run.ended else { return }
            self.runFailed(run, Problem(message: "stalled"), token: token) // (cancels it)
        }
    }

    private func cancel(_ run: Run) {
        run.input.finish()
        run.results?.cancel()
        let analyzer = run.analyzer
        Task { await analyzer.cancelAndFinishNow() }
    }

    private func listen(to module: any SpeechModule, run: Run, token: Int) -> Task<Void, Never> {
        Task { [weak self] in
            do {
                switch module {
                case let transcriber as SpeechTranscriber:
                    for try await result in transcriber.results {
                        self?.recognized(result.text, final: result.isFinal, run: run, token: token)
                    }
                case let transcriber as DictationTranscriber:
                    for try await result in transcriber.results {
                        self?.recognized(result.text, final: result.isFinal, run: run, token: token)
                    }
                default:
                    break
                }
                self?.runEnded(run, token: token)
            } catch {
                self?.runFailed(run, error, token: token)
            }
        }
    }

    /// A partial or final transcript of a run. Never logged.
    private func recognized(_ text: AttributedString, final: Bool, run: Run, token: Int) {
        guard token == generation, phase == .listening, !run.ended else { return }
        failures = 0
        let words = Self.words(text)
        if final {
            if case .heard(let end) = run.words.final(words.map { WakeRunWords.Word(text: $0.text, end: $0.end) }) {
                heard(at: end.map(run.sample(at:)) ?? run.closedAt ?? run.fed, in: run)
            }
        } else if run.words.partial(words.map(\.text)) == .finalizeNow, run.ready, !run.finishing {
            // The phrase, maybe: ask for the final words now (with their times) rather than at the next pause.
            let analyzer = run.analyzer
            Task { try? await analyzer.finalize(through: nil) }
        }
    }

    private func runEnded(_ run: Run, token: Int) {
        guard !run.ended else { return }
        run.ended = true
        guard token == generation, phase == .listening else { return }
        failures = 0
        // The final pass dropped the phrase the partial results kept: it ended where the sound did.
        if case .heard = run.words.finished() { heard(at: run.closedAt ?? run.fed, in: run) }
    }

    private func runFailed(_ run: Run, _ error: Error, token: Int) {
        guard !run.ended else { return }
        run.ended = true
        let wasFed = self.run === run
        if wasFed { self.run = nil }
        cancel(run)
        guard token == generation, phase == .listening else { return }
        failures += 1
        Log.write("voice: a wake recognizer run stopped (\(VoiceAudio.describe(error)))")
        if let pause = WakeRetry.pause(afterFailures: failures) {
            Log.write("voice: the wake listener pauses \(Int(pause)) s")
            restart(after: pause, problem: WakeRetry.problem(afterFailures: failures))
        } else if wasFed, gate.isOpen {
            // The sound goes on: a new run takes it from where this one began.
            open(from: max(run.origin, ring.start))
        }
    }

    private func heard(at end: Int64, in run: Run) {
        phraseEnd = min(max(end, ring.start), ring.end)
        // The first 0.3 s of the run's pre-roll: the room before the sound began.
        let quiet = run.origin..<max(run.origin, min(run.origin + 4_800, phraseEnd ?? run.origin))
        room = quiet.isEmpty ? nil : quiet
        phase = .heard
        Log.write("voice: wake phrase heard")
        onPhrase?()
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

    /// The on-device recognizer: a new module for each run (a module belongs to one analyzer).
    enum Recognizer {
        case transcriber(Locale)
        case dictation(Locale)

        func module() -> any SpeechModule {
            switch self {
            case .transcriber(let locale):
                SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults],
                                  attributeOptions: [.audioTimeRange])
            case .dictation(let locale):
                DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [],
                                     reportingOptions: [.volatileResults], attributeOptions: [.audioTimeRange])
            }
        }
    }

    /// SpeechTranscriber for `locale` (else DictationTranscriber), its model on this Mac. A missing model is
    /// downloaded first when `download` (the app; never in fixture mode).
    static func makeRecognizer(locale identifier: String, download: Bool) async throws -> Recognizer {
        let wanted = Locale(identifier: identifier)
        if SpeechTranscriber.isAvailable, let locale = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) {
            let recognizer = Recognizer.transcriber(locale)
            let installed = await SpeechTranscriber.installedLocales
            try await ensureModel(recognizer.module(),
                                  installed: installed.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) },
                                  download: download)
            return recognizer
        }
        if let locale = await DictationTranscriber.supportedLocale(equivalentTo: wanted) {
            let recognizer = Recognizer.dictation(locale)
            let installed = await DictationTranscriber.installedLocales
            try await ensureModel(recognizer.module(),
                                  installed: installed.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) },
                                  download: download)
            return recognizer
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
    private static func buffer(_ samples: [Int16], _ run: Run) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty, let count = AVAudioFrameCount(exactly: samples.count),
              let pcm = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
              let buffer = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: count),
              let channel = buffer.int16ChannelData?[0] else { return nil }
        buffer.frameLength = count
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        guard let converter = run.converter else { return buffer }
        let frames = Double(count) * run.format.sampleRate / 16_000 + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: run.format, frameCapacity: AVAudioFrameCount(frames)) else {
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
        return error == nil && output.frameLength > 0 ? output : nil
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
