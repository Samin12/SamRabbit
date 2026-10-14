import AVFoundation
import Foundation
import SamRabbitKit

/// Where a conversation hears from: the Mac's microphone (voice processing on), or WAV files (`FixtureInput`).
/// Delivers 16 kHz mono 16-bit samples on the main actor.
@MainActor
protocol VoiceInput: AnyObject {
    /// Whether the microphone may be used (asks the first time; a fixture never asks).
    func allowed() async -> Bool
    /// Starts delivering samples (the engine is built; voice processing is already on for the microphone).
    func start(engine: AVAudioEngine, deliver: @escaping @MainActor ([Int16]) -> Void) throws
    func stop(engine: AVAudioEngine)
    /// The microphone opened again for the next utterance (a fixture says its next file).
    func opened()
    /// Mutes the microphone (voice processing's own mute, so the echo canceller keeps its state).
    func setMuted(_ muted: Bool, engine: AVAudioEngine)
    /// No microphone, no voice processing, nothing out loud.
    var isFixture: Bool { get }
}

/// One audio engine for the whole conversation, like the watch's `AudioGraph`: the microphone's tap converted to
/// 16 kHz, and a player node for the replies (streamed PCM, clips, the Mac's own voice), plus a quieter one for the
/// chime.
///
///     microphone (voice processing: echo cancellation) --tap--> 16 kHz Int16 --> SpeechDetector
///     replies --> AVAudioPlayerNode (16 kHz float) --> main mixer --> voice processing output --> speakers
///
/// Voice processing (`setVoiceProcessingEnabled(true)` on the input node) cancels the assistant's own voice from the
/// microphone, so it never counts as Samin speaking; other apps' sound is ducked as little as macOS allows. Should it
/// fail to start (an odd audio device), the engine runs without it: the conversation is half duplex anyway (the
/// microphone is closed while a reply plays), so it still works with speakers.
///
/// In fixture mode the engine renders into memory (manual rendering, paced in real time): every buffer still plays,
/// drains and reports like the real thing, but no sound reaches any device.
///
/// A streamed reply waits in a small jitter buffer (`PlaybackJitterBuffer`, 0.2 s) before it starts. Playback that
/// never reports its end still ends: a device change reports what was playing as drained, and `checkStalled()` gives
/// up on buffers that should have played long ago.
@MainActor
final class VoiceAudio {
    enum StartFailure: Error, Equatable {
        case microphoneDenied
        case engine(String)

        var message: String {
            switch self {
            case .microphoneDenied: "Microphone access is off for SamRabbit"
            case .engine: "The microphone didn't start"
            }
        }
    }

    enum Chime { case start, end }

    var onSamples: (@MainActor ([Int16]) -> Void)?
    var onPlaying: (@MainActor () -> Void)?
    var onDrained: (@MainActor () -> Void)?
    /// The audio device changed and the engine could not come back.
    var onInterrupted: (@MainActor () -> Void)?

    let input: VoiceInput
    private(set) var running = false
    /// Voice processing (echo cancellation) is on for this conversation.
    private(set) var voiceProcessing = false
    /// Bumped by every `start()` and `stop()`: a start that waited (the microphone prompt) and was overtaken gives up.
    private var startToken = 0
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var chimePlayer: AVAudioPlayerNode?
    private let playFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1,
                                           interleaved: false)!
    /// Bumped by `stopPlayback`: completions of what was stopped are ignored.
    private var generation = 0
    private var outstanding = 0
    private var scheduledFrames: Int64 = 0
    private var levels: [(end: Int64, level: Double)] = []
    private var expectedEnd: Date = .distantPast
    private static let stallSlack: TimeInterval = 3
    private var jitter = PlaybackJitterBuffer()
    private var jitterTimer: Task<Void, Never>?
    private var synthesizer: AVSpeechSynthesizer?
    private var speaking = false
    private var speechTimer: Task<Void, Never>?
    private var observers: [any NSObjectProtocol] = []
    /// Fixture mode: pulls the graph in real time (manual rendering; nothing reaches a device).
    private var renderTask: Task<Void, Never>?
    private var muted = false
    /// The end chime plays on its own after the engine stopped.
    private var endChime: AVAudioPlayer?

    init(input: VoiceInput) {
        self.input = input
    }

    // MARK: - Start and stop

    /// Asks for the microphone (the first time only), builds the engine with voice processing and starts it.
    /// Throws `CancellationError` when `stop()` (or another `start()`) came while it waited.
    func start() async throws {
        guard !running else { return }
        startToken += 1
        let token = startToken
        let permitted = await input.allowed()
        guard token == startToken else { throw CancellationError() }
        guard permitted else { throw StartFailure.microphoneDenied }
        do {
            try buildAndStart(voiceProcessing: !input.isFixture)
        } catch {
            teardown()
            guard !input.isFixture else { throw StartFailure.engine("fixture") }
            // Voice processing can fail on an unusual device (an aggregate, some USB interfaces): go on without it.
            Log.write("voice: voice processing did not start (\(Self.describe(error))); going on without it")
            do {
                try buildAndStart(voiceProcessing: false)
            } catch {
                teardown()
                Log.write("voice: audio did not start (\(Self.describe(error)))")
                throw StartFailure.engine("start")
            }
        }
        running = true
        observe()
        Log.write("voice: audio started" + (input.isFixture ? " (fixture, rendered silently)"
                                            : voiceProcessing ? " (echo cancellation on)" : ""))
    }

    private func buildAndStart(voiceProcessing wanted: Bool) throws {
        let engine = AVAudioEngine()
        self.engine = engine
        voiceProcessing = false
        if wanted {
            let microphone = engine.inputNode
            try microphone.setVoiceProcessingEnabled(true)
            voiceProcessing = true
            // Other apps' sound (music, a call in another app) stays as loud as macOS allows.
            microphone.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: true, duckingLevel: .min)
            microphone.isVoiceProcessingInputMuted = muted
        }
        let player = AVAudioPlayerNode()
        let chime = AVAudioPlayerNode()
        engine.attach(player)
        engine.attach(chime)
        if input.isFixture {
            // Into memory only: rendered by `startRendering`, never to a device.
            try engine.enableManualRenderingMode(.offline, format: playFormat, maximumFrameCount: 1_600)
            engine.mainMixerNode.outputVolume = 0
        }
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)
        engine.connect(chime, to: engine.mainMixerNode, format: playFormat)
        chime.volume = 0.5
        self.player = player
        chimePlayer = chime
        try input.start(engine: engine) { [weak self] samples in self?.onSamples?(samples) }
        engine.prepare()
        try engine.start()
        player.play()
        chime.play()
        if input.isFixture { startRendering(engine) }
    }

    /// Stops everything. A start still on its way gives up (see `start()`).
    func stop() {
        startToken += 1
        guard running || engine != nil else { return }
        running = false
        stopPlayback()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        teardown()
        Log.write("voice: audio stopped")
    }

    private func teardown() {
        renderTask?.cancel()
        renderTask = nil
        if let engine {
            // (A rendering engine is dropped as it is: leaving manual rendering takes seconds.)
            input.stop(engine: engine)
            engine.stop()
        }
        engine = nil
        player = nil
        chimePlayer = nil
        voiceProcessing = false
    }

    /// Mutes the microphone (the engine keeps running, the echo canceller keeps its state).
    func setMuted(_ muted: Bool) {
        self.muted = muted
        if let engine { input.setMuted(muted, engine: engine) }
    }

    private func observe() {
        guard let engine, !input.isFixture else { return }
        // Headphones came or went, the input device changed: the engine stopped; start it again.
        observers.append(NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                                object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconfigure() }
        })
    }

    private func reconfigure() {
        guard running, let engine else { return }
        Log.write("voice: audio device changed")
        // What was playing is gone with the old device and its completions never come: report it as played out,
        // or the conversation would wait on "Speaking" (a reply still streaming just plays on).
        let wasPlaying = outstanding > 0 || speaking || jitter.isHolding
        stopPlayback()
        input.stop(engine: engine)
        do {
            try input.start(engine: engine) { [weak self] samples in self?.onSamples?(samples) }
            engine.prepare()
            try engine.start()
            player?.play()
            chimePlayer?.play()
        } catch {
            onInterrupted?()
            return
        }
        if wasPlaying { onDrained?() }
    }

    /// About once a second: scheduled audio that should have played out a while ago is dropped and reported as
    /// played, so the conversation goes on.
    func checkStalled(now: Date = .now) {
        guard outstanding > 0, now.timeIntervalSince(expectedEnd) > Self.stallSlack else { return }
        Log.write("voice: playback stalled")
        stopPlayback()
        onDrained?()
    }

    /// Fixture mode: renders the graph into a scratch buffer at the pace it would play.
    private func startRendering(_ engine: AVAudioEngine) {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                            frameCapacity: engine.manualRenderingMaximumFrameCount) else { return }
        let started = Date()
        let rate = engine.manualRenderingFormat.sampleRate
        var rendered: AVAudioFramePosition = 0
        renderTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(20))
                guard let self, let engine = self.engine, engine.isInManualRenderingMode else { return }
                let due = AVAudioFramePosition(Date().timeIntervalSince(started) * rate)
                while rendered < due {
                    let frames = AVAudioFrameCount(min(AVAudioFramePosition(buffer.frameCapacity), due - rendered))
                    guard (try? engine.renderOffline(frames, to: buffer)) == .success else { break }
                    rendered += AVAudioFramePosition(frames)
                }
            }
        }
    }

    // MARK: - Playback

    /// A piece of a streamed reply: PCM16LE mono 16 kHz. Waits in the jitter buffer until 0.2 s are there (or
    /// 0.35 s went by, or the stream ends: `endOfStream`), then plays; later pieces play as they come.
    func schedule(pcm: Data) {
        for piece in jitter.add(pcm, at: .now) { play(pcm: piece) }
        armJitterTimer()
    }

    /// The reply's stream ended: what waits in the jitter buffer plays now.
    func endOfStream() {
        jitterTimer?.cancel()
        jitterTimer = nil
        for piece in jitter.finish() { play(pcm: piece) }
    }

    private func armJitterTimer() {
        jitterTimer?.cancel()
        jitterTimer = nil
        guard let deadline = jitter.deadline else { return }
        let current = generation
        jitterTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self, self.generation == current else { return }
            for piece in self.jitter.tick(at: max(.now, deadline)) { self.play(pcm: piece) }
        }
    }

    private func play(pcm: Data) {
        let samples = PCM16.samples(pcm)
        guard !samples.isEmpty, let count = AVAudioFrameCount(exactly: samples.count),
              let buffer = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: count),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = count
        for (index, sample) in samples.enumerated() { channel[index] = Float(sample) / 32768 }
        schedule(buffer)
    }

    private func dropWaiting() {
        jitterTimer?.cancel()
        jitterTimer = nil
        jitter.reset()
    }

    /// A whole clip (MP3 from the Claude fallback's voice, a WAV in another format). False when it couldn't be read
    /// (the conversation then says the words itself).
    @discardableResult
    func play(clip: AssistantAudio) -> Bool {
        dropWaiting()
        let ext = clip.mime.contains("mpeg") || clip.mime.contains("mp3") ? "mp3"
            : clip.mime.contains("wav") ? "wav" : "m4a"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("samrabbit-reply-\(UUID().uuidString).\(ext)")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try clip.data.write(to: url, options: [.atomic])
            let file = try AVAudioFile(forReading: url)
            guard file.length > 0, let frames = AVAudioFrameCount(exactly: file.length), frames <= 48_000 * 180,
                  let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
                Log.write("voice: a clip could not be read")
                return false
            }
            try file.read(into: source)
            guard let converted = convert(source) else { return false }
            schedule(converted)
            return true
        } catch {
            Log.write("voice: a clip could not be read")
            return false
        }
    }

    /// Says `text` with the Mac's own voice (the best installed en-US voice), through the same player.
    func speak(_ text: String) {
        dropWaiting()
        let synthesizer = AVSpeechSynthesizer()
        self.synthesizer = synthesizer
        speaking = true
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.voice
        let current = generation
        synthesizer.write(utterance) { [weak self] buffer in
            nonisolated(unsafe) let buffer = buffer
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == current else { return }
                    guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                        self.speechEnded(current) // the empty buffer that ends the speech
                        return
                    }
                    if let converted = self.convert(pcm) { self.schedule(converted) }
                    self.speechWatchdog(current, after: 1.5)
                }
            }
        }
        // A voice that never answers (or never says it is done) must not hang the conversation.
        speechWatchdog(current, after: 4)
    }

    private func speechWatchdog(_ generation: Int, after seconds: TimeInterval) {
        speechTimer?.cancel()
        speechTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.speechEnded(generation)
        }
    }

    private func speechEnded(_ generation: Int) {
        guard generation == self.generation, speaking else { return }
        speechTimer?.cancel()
        speechTimer = nil
        speaking = false
        synthesizer = nil
        if outstanding == 0 { onDrained?() }
    }

    /// The best installed en-US voice (premium, then enhanced, then any).
    static let voice: AVSpeechSynthesisVoice? = {
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "en-US" }
        return voices.max { $0.quality.rawValue < $1.quality.rawValue } ?? AVSpeechSynthesisVoice(language: "en-US")
    }()

    /// Stops what plays and drops what is scheduled (barge-in).
    func stopPlayback() {
        generation += 1
        outstanding = 0
        scheduledFrames = 0
        levels = []
        expectedEnd = .distantPast
        dropWaiting()
        speaking = false
        speechTimer?.cancel()
        speechTimer = nil
        synthesizer?.stopSpeaking(at: .immediate)
        synthesizer = nil
        player?.stop()
        if running { player?.play() }
    }

    private func schedule(_ buffer: AVAudioPCMBuffer) {
        guard let player, buffer.frameLength > 0 else { return }
        let current = generation
        if outstanding == 0 { onPlaying?() }
        outstanding += 1
        scheduledFrames += Int64(buffer.frameLength)
        let seconds = Double(buffer.frameLength) / max(1, buffer.format.sampleRate)
        expectedEnd = max(expectedEnd, .now).addingTimeInterval(seconds)
        levels.append((scheduledFrames, Self.level(of: buffer)))
        // Rendered into memory (fixture mode), "played back" is when it was rendered.
        let callback: AVAudioPlayerNodeCompletionCallbackType = input.isFixture ? .dataRendered : .dataPlayedBack
        player.scheduleBuffer(buffer, completionCallbackType: callback) { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.played(current) } }
        }
        if !player.isPlaying { player.play() }
    }

    private func played(_ generation: Int) {
        guard generation == self.generation else { return }
        outstanding = max(0, outstanding - 1)
        guard outstanding == 0 else { return }
        // Ran dry while the reply may go on: its next pieces fill the jitter buffer again first.
        jitter.underrun()
        if !speaking { onDrained?() }
    }

    /// 0...1: how loud the reply is right now (the orb pulses with it).
    func playbackLevel() -> Double {
        guard outstanding > 0, let player, let nodeTime = player.lastRenderTime,
              let time = player.playerTime(forNodeTime: nodeTime) else { return 0 }
        let position = time.sampleTime
        while let first = levels.first, first.end <= position, levels.count > 1 { levels.removeFirst() }
        return levels.first?.level ?? 0
    }

    private static func level(of buffer: AVAudioPCMBuffer) -> Double {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let power = PCM16.dbfs(floats: UnsafeBufferPointer(start: channel, count: Int(clamping: buffer.frameLength)))
        return VoiceActivity.level(forPower: power + 8)
    }

    /// Any PCM buffer as the player's format (16 kHz mono float).
    private func convert(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if source.format == playFormat { return source }
        guard let converter = AVAudioConverter(from: source.format, to: playFormat) else { return nil }
        converter.downmix = true
        let ratio = playFormat.sampleRate / source.format.sampleRate
        let frames = Double(source.frameLength) * ratio + 1024
        guard frames.isFinite, frames > 0, frames < Double(UInt32.max),
              let output = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: AVAudioFrameCount(frames)) else {
            return nil
        }
        nonisolated(unsafe) var consumed = false
        nonisolated(unsafe) let input = source
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return input
        }
        return error == nil && output.frameLength > 0 ? output : nil
    }

    // MARK: - The chime

    /// The soft "I'm listening" cue (two rising notes, about -24 dBFS) through the conversation's own output, so the
    /// echo canceller knows it; the end cue (two falling notes, quieter) plays on its own once the engine is gone.
    /// Fixture mode renders the start chime silently and skips the end chime.
    func chime(_ kind: Chime) {
        let notes: [(Double, Double)] = kind == .start ? [(659.3, 0.075), (987.8, 0.11)] : [(880, 0.07), (587.3, 0.1)]
        let samples = Self.chimeSamples(notes, peak: kind == .start ? 0.12 : 0.08)
        switch kind {
        case .start:
            guard let chimePlayer, let count = AVAudioFrameCount(exactly: samples.count),
                  let buffer = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: count),
                  let channel = buffer.floatChannelData?[0] else { return }
            buffer.frameLength = count
            for (index, value) in samples.enumerated() { channel[index] = value }
            chimePlayer.scheduleBuffer(buffer, completionHandler: nil)
            if !chimePlayer.isPlaying { chimePlayer.play() }
        case .end:
            guard !input.isFixture else { return }
            let wav = WAV.encode(samples: PCM16.samples(fromFloats: samples))
            endChime = try? AVAudioPlayer(data: wav)
            endChime?.volume = 0.5
            endChime?.play()
        }
    }

    /// Sine notes with soft edges, 16 kHz.
    static func chimeSamples(_ notes: [(frequency: Double, seconds: Double)], peak: Double) -> [Float] {
        var out: [Float] = []
        for note in notes {
            let count = Int(note.seconds * 16_000)
            for index in 0..<count {
                let t = Double(index) / 16_000
                let envelope = min(1, t / 0.008) * min(1, (note.seconds - t) / 0.04)
                out.append(Float(sin(2 * .pi * note.frequency * t) * envelope * peak))
            }
        }
        return out
    }

    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        return "\(ns.domain)#\(ns.code)"
    }
}

/// The Mac's microphone: a tap on the engine's input node (voice processing already on) in its own format,
/// converted to 16 kHz mono 16-bit.
@MainActor
final class MacMicrophone: VoiceInput {
    var isFixture: Bool { false }

    func allowed() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: true
        case .denied: false
        default: await AVAudioApplication.requestRecordPermission()
        }
    }

    func start(engine: AVAudioEngine, deliver: @escaping @MainActor ([Int16]) -> Void) throws {
        try MacMicrophone.tap(engine.inputNode, deliver: deliver)
    }

    func stop(engine: AVAudioEngine) {
        engine.inputNode.removeTap(onBus: 0)
    }

    func opened() {}

    func setMuted(_ muted: Bool, engine: AVAudioEngine) {
        if engine.inputNode.isVoiceProcessingEnabled { engine.inputNode.isVoiceProcessingInputMuted = muted }
    }

    /// Installs a tap that delivers 16 kHz mono 16-bit samples, in order, on the main actor (the wake listener's
    /// microphone uses it too).
    static func tap(_ input: AVAudioInputNode, deliver: @escaping @MainActor ([Int16]) -> Void) throws {
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0, let converter = TapConverter(from: format) else {
            throw VoiceAudio.StartFailure.engine("input format")
        }
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(format.sampleRate / 10), format: format) { buffer, _ in
            guard let samples = converter.convert(buffer), !samples.isEmpty else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { deliver(samples) } }
        }
    }
}

/// Converts buffers to 16 kHz mono 16-bit (any rate, any number of channels: mixed down). One converter keeps its
/// state across a tap's buffers.
final class TapConverter: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let target: AVAudioFormat

    init?(from source: AVAudioFormat) {
        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: source, to: target) else { return nil }
        converter.downmix = true
        self.converter = converter
        self.target = target
    }

    /// `final`: the last buffer of a file (the converter's tail is flushed out too).
    func convert(_ buffer: AVAudioPCMBuffer, final: Bool = false) -> [Int16]? {
        let ratio = target.sampleRate / buffer.format.sampleRate
        let frames = Double(buffer.frameLength) * ratio + 1024
        guard frames.isFinite, frames > 0, frames < Double(UInt32.max),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(frames)) else {
            return nil
        }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = final ? .endOfStream : .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = output.int16ChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(clamping: output.frameLength)))
    }
}
