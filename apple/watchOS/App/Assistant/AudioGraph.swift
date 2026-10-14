import AVFoundation
import Foundation
import os
import SamRabbitKit

private let audioLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.samrabbit.mobile", category: "audio")

/// Where the conversation's sound comes from: the watch's (or the iPhone's) microphone, or (the simulator, debug
/// builds) a made-up voice. Delivers 16 kHz mono 16-bit samples on the main actor.
@MainActor
protocol ConversationInput: AnyObject {
    /// Whether the microphone may be used (asks the first time).
    func allowed() async -> Bool
    /// Sets up the new engine before anything is connected to it (the iPhone's voice processing changes the
    /// engine's input and output formats, so it comes first).
    func prepare(engine: AVAudioEngine)
    /// Starts delivering samples (the engine is already set up).
    func start(engine: AVAudioEngine, deliver: @escaping @MainActor ([Int16]) -> Void) throws
    func stop(engine: AVAudioEngine)
    /// The microphone was opened again for the next utterance (the made-up voice speaks again).
    func opened()
    /// The fixture plays no sound and needs no recording session.
    var isFixture: Bool { get }
}

extension ConversationInput {
    func prepare(engine: AVAudioEngine) {}
}

/// The app's one audio session (`AVAudioSession` is shared by the whole app): who holds it now, so nobody
/// deactivates it under someone else (that stops their engine without telling them). The conversation and, on the
/// iPhone, a composer's dictation claim it when they activate it and give it back through here.
@MainActor
enum AudioSessionUse {
    static var claims = AudioSessionClaims()

    static func claim(_ holder: AudioSessionClaims.Holder) {
        claims.claim(holder)
    }

    /// `holder` is done with the session: deactivated only when it held it and nobody else still does.
    static func release(_ holder: AudioSessionClaims.Holder) {
        guard claims.release(holder) else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// One audio graph for the whole conversation (watchOS and iOS can't start recording from the background, so it is
/// started once, in front, and kept running between turns): the input's tap, converted to 16 kHz, and a player
/// node for the replies (streamed PCM, clips, the device's own voice). The same file runs the watch's and the
/// iPhone's conversation; on the iPhone the session is a voice chat (echo cancellation, the loudspeaker, AirPods
/// and car kits) and the microphone goes through voice processing, so the reply out of the speaker isn't heard.
///
///     microphone --tap--> 16 kHz Int16 --> SpeechDetector (the engine decides when it listens)
///     replies --> AVAudioPlayerNode (16 kHz float) --> main mixer --> speaker / AirPods
///
/// It reports when something starts playing and when everything scheduled has played (`onPlaying`, `onDrained`),
/// an interruption (a call, Siri) or a lost route it couldn't recover from (`onInterrupted`), and (the iPhone) the
/// end of an interruption after which iOS says the audio may go on (`onResumable`).
///
/// A streamed reply waits in a small jitter buffer (`PlaybackJitterBuffer`, 0.2 s) before it starts, so audio that
/// arrives at the pace it is spoken doesn't stutter. Playback that never reports its end (a route change, a stuck
/// player) still ends: a route change reports what was playing as drained, and `checkStalled()` gives up on
/// buffers that should have played long ago.
@MainActor
final class AudioGraph {
    enum StartFailure: Error, Equatable {
        case microphoneDenied
        case session(String)
        case engine(String)

        var message: String {
            switch self {
            case .microphoneDenied: "Microphone is off"
            case .session, .engine: "The microphone didn't start"
            }
        }
    }

    var onSamples: (@MainActor ([Int16]) -> Void)?
    var onPlaying: (@MainActor () -> Void)?
    var onDrained: (@MainActor () -> Void)?
    var onInterrupted: (@MainActor () -> Void)?
    /// The interruption is over and the system says the audio may go on (a call ended). Not on the watch.
    var onResumable: (@MainActor () -> Void)?
    /// The engine started or stopped (the microphone is live while true).
    var onRunning: (@MainActor (Bool) -> Void)?

    let input: ConversationInput
    private(set) var running = false {
        didSet { if running != oldValue { onRunning?(running) } }
    }
    /// Bumped by every `start()` and `stop()`. A start that waited (the microphone prompt, the session, Siri's
    /// retries) and was overtaken meanwhile, stopped or started again, gives up instead of opening the microphone.
    private var startToken = 0
    /// The start still on its way, if any (an overtaken start leaves the session to it).
    private var pendingStart: Int?
    /// The audio session was activated and not given back yet.
    private var sessionActive = false
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private let playFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1,
                                           interleaved: false)!
    /// Bumped by `stopPlayback`: completions of what was stopped are ignored.
    private var generation = 0
    private var outstanding = 0
    /// Frames scheduled in this generation, and the level of each buffer (for the orb).
    private var scheduledFrames: Int64 = 0
    private var levels: [(end: Int64, level: Double)] = []
    /// When everything scheduled should have played (the stall watchdog).
    private var expectedEnd: Date = .distantPast
    /// Scheduled audio this long overdue counts as stuck.
    private static let stallSlack: TimeInterval = 3
    private var jitter = PlaybackJitterBuffer()
    private var jitterTimer: Task<Void, Never>?
    private var synthesizer: AVSpeechSynthesizer?
    private var speaking = false
    private var speechTimer: Task<Void, Never>?
    private var observers: [any NSObjectProtocol] = []
    /// The iPhone: the end of an interruption (kept while the graph is stopped).
    private var resumeObserver: (any NSObjectProtocol)?
    /// The iPhone: an interruption (a call) stopped this graph while it ran, and no start came since. Only then does
    /// the interruption's end count (`onResumable`): not after one of dictation's, nor of a conversation that was
    /// not running.
    private var interruptedWhileRunning = false
    /// The iPhone's mute: the microphone's sound stops in voice processing (kept across route changes and starts).
    private var inputMuted = false
    private let muted: Bool

    init(input: ConversationInput, muted: Bool) {
        self.input = input
        self.muted = muted
    }

    // MARK: - Start and stop

    /// Asks for the microphone, sets up the audio session (play and record, AirPods allowed) and starts the engine.
    /// Siri may still hold the microphone right after "Talk to SamRabbit": retried for about 3 seconds.
    ///
    /// Throws `CancellationError` when `stop()` (or another `start()`) came while it waited: nothing is left
    /// running, and whoever stopped it has already decided what the conversation does.
    func start() async throws {
        guard !running else { return }
        interruptedWhileRunning = false
        startToken += 1
        let token = startToken
        pendingStart = token
        defer { if pendingStart == token { pendingStart = nil } }
        let permitted = await input.allowed()
        try abandonIfOvertaken(token)
        guard permitted else { throw StartFailure.microphoneDenied }
        let session = AVAudioSession.sharedInstance()
        do {
            if input.isFixture {
                try session.setCategory(.playback, mode: .default, options: [])
            } else {
                #if os(iOS)
                // A voice chat: echo cancellation, the loudspeaker rather than the earpiece, AirPods and car kits.
                try session.setCategory(.playAndRecord, mode: .voiceChat,
                                        options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP])
                #else
                try session.setCategory(.playAndRecord, mode: .default, policy: .default,
                                        options: [.allowBluetoothHFP, .allowBluetoothA2DP])
                #endif
                try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)
            }
            try? session.setPrefersNoInterruptionsFromSystemAlerts(true)
        } catch {
            throw StartFailure.session("category")
        }
        var lastError: Error?
        for delay in [0, 150, 300, 600, 1200] {
            if delay > 0 {
                try? await Task.sleep(for: .milliseconds(delay))
                try abandonIfOvertaken(token)
            }
            do {
                try await Self.activate(session)
                sessionActive = true
                AudioSessionUse.claim(.conversation)
            } catch {
                try abandonIfOvertaken(token)
                lastError = error
                continue
            }
            try abandonIfOvertaken(token)
            // From here to `running` nothing waits: a stop can't come in between.
            do {
                try buildAndStart()
                running = true
                observe()
                audioLog.notice("audio started")
                return
            } catch {
                lastError = error
                teardown()
            }
        }
        audioLog.error("audio did not start: \(String(describing: lastError), privacy: .public)")
        releaseSession()
        throw StartFailure.engine("start")
    }

    /// Activates the audio session: watchOS asks for it (it may connect AirPods first); iOS 26 has only the
    /// blocking call, made off the main thread.
    private static func activate(_ session: AVAudioSession) async throws {
        #if os(watchOS)
        _ = try await session.activate(options: [])
        #else
        try await Task.detached { try AVAudioSession.sharedInstance().setActive(true) }.value
        #endif
    }

    /// After each wait in `start()`: gives up when a `stop()` or a newer `start()` came meanwhile. Nothing was built
    /// yet; the session goes back unless a newer start is on its way (or running) and needs it.
    private func abandonIfOvertaken(_ token: Int) throws {
        guard token != startToken else { return }
        audioLog.notice("audio start abandoned")
        if pendingStart == nil, !running { releaseSession() }
        throw CancellationError()
    }

    private func releaseSession() {
        guard sessionActive else { return }
        sessionActive = false
        AudioSessionUse.release(.conversation)
    }

    private func buildAndStart() throws {
        let engine = AVAudioEngine()
        // First, before the player is attached or the mixer touched: the iPhone's voice processing changes the
        // engine's formats.
        input.prepare(engine: engine)
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)
        engine.mainMixerNode.outputVolume = muted ? 0 : 1
        self.engine = engine
        self.player = player
        try input.start(engine: engine) { [weak self] samples in self?.onSamples?(samples) }
        applyInputMute()
        engine.prepare()
        try engine.start()
        player.play()
    }

    /// The iPhone's mute (`ConversationEngine.setMuted`): the microphone's sound stops in voice processing, so
    /// nothing but silence reaches the tap (the engine itself keeps running: recording can't start again from the
    /// background, and unmuting must work there too). The conversation also stops listening on its own.
    func setInputMuted(_ on: Bool) {
        inputMuted = on
        applyInputMute()
    }

    private func applyInputMute() {
        #if os(iOS)
        guard !input.isFixture, let engine else { return }
        let node = engine.inputNode
        if node.isVoiceProcessingEnabled, node.isVoiceProcessingInputMuted != inputMuted {
            node.isVoiceProcessingInputMuted = inputMuted
        }
        #endif
    }

    /// Stops everything and gives the audio session back. A start still on its way gives up (see `start()`).
    func stop() {
        startToken += 1
        pendingStart = nil
        if running || engine != nil {
            running = false
            audioLog.notice("audio stopped")
            stopPlayback()
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers = []
            teardown()
        }
        releaseSession()
    }

    private func teardown() {
        if let engine {
            input.stop(engine: engine)
            engine.stop()
        }
        engine = nil
        player = nil
    }

    private func observe() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil,
                                            queue: .main) { [weak self] note in
            let began = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .began
            guard began else { return }
            MainActor.assumeIsolated { self?.interrupted() }
        })
        #if os(iOS)
        // The end of an interruption comes after the graph stopped (the conversation paused): observed for good, and
        // honoured only when it ends the interruption that stopped this graph (`interruptedWhileRunning`).
        if resumeObserver == nil {
            resumeObserver = center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil,
                                                queue: .main) { [weak self] note in
                let info = note.userInfo
                let ended = (info?[AVAudioSessionInterruptionTypeKey] as? UInt)
                    .flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .ended
                let options = AVAudioSession.InterruptionOptions(rawValue: info?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
                guard ended, options.contains(.shouldResume) else { return }
                MainActor.assumeIsolated {
                    guard let self, self.interruptedWhileRunning, !self.running else { return }
                    self.interruptedWhileRunning = false
                    self.onResumable?()
                }
            }
        }
        #endif
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.interrupted() }
        })
        if let engine {
            // AirPods came or went: the engine stopped; start it again with the new input.
            observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reconfigure() }
            })
        }
    }

    private func interrupted() {
        guard running else { return }
        audioLog.notice("audio interrupted")
        onInterrupted?()
        // Set after the conversation paused (which stopped this graph): its end may continue it.
        interruptedWhileRunning = true
    }

    /// The conversation was ended on purpose while paused: the end of the interruption no longer continues it.
    func forgetInterruption() {
        interruptedWhileRunning = false
    }

    private func reconfigure() {
        guard running, let engine else { return }
        audioLog.notice("audio route changed")
        // What was playing is gone with the old route, and its completions never come: report it as played out, or
        // the conversation would wait on "Speaking" forever (a reply still streaming just plays on).
        let wasPlaying = outstanding > 0 || speaking || jitter.isHolding
        stopPlayback()
        input.stop(engine: engine)
        do {
            try input.start(engine: engine) { [weak self] samples in self?.onSamples?(samples) }
            applyInputMute()
            engine.prepare()
            try engine.start()
            player?.play()
        } catch {
            onInterrupted?()
            return
        }
        if wasPlaying { onDrained?() }
    }

    /// About once a second: scheduled audio that should have played out a while ago (the player stopped calling
    /// back) is dropped and reported as played, so the conversation goes on.
    func checkStalled(now: Date = .now) {
        guard outstanding > 0, now.timeIntervalSince(expectedEnd) > Self.stallSlack else { return }
        audioLog.notice("playback stalled")
        stopPlayback()
        onDrained?()
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

    /// The first piece mustn't wait for the rest longer than the buffer's `maxWait`.
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

    /// Another sound takes over (the watch's voice, a clip): reply audio still waiting is dropped.
    private func dropWaiting() {
        jitterTimer?.cancel()
        jitterTimer = nil
        jitter.reset()
    }

    /// A whole clip (MP3 from the Claude fallback's voice, AAC, a WAV in another format). Returns false when it
    /// couldn't be read (the conversation then speaks the words itself).
    @discardableResult
    func play(clip: AssistantAudio) -> Bool {
        dropWaiting()
        let ext = clip.mime.contains("mpeg") || clip.mime.contains("mp3") ? "mp3"
            : clip.mime.contains("wav") ? "wav" : "m4a"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("reply-\(UUID().uuidString).\(ext)")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try clip.data.write(to: url)
            let file = try AVAudioFile(forReading: url)
            // `file.length` is 64-bit: a broken header must not trap the conversion (or ask for a huge buffer;
            // replies are a sentence or two, three minutes at 48 kHz is plenty).
            guard file.length > 0, let frames = AVAudioFrameCount(exactly: file.length), frames <= 48_000 * 180,
                  let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
                audioLog.notice("a clip could not be read")
                return false
            }
            try file.read(into: source)
            guard let converted = convert(source) else { return false }
            schedule(converted)
            return true
        } catch {
            audioLog.notice("a clip could not be read")
            return false
        }
    }

    /// Says `text` with the watch's own voice (best en-US voice), through the same player.
    func speak(_ text: String) {
        dropWaiting()
        let synthesizer = AVSpeechSynthesizer()
        self.synthesizer = synthesizer
        speaking = true
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.04
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

    /// Ends the watch's speech if nothing more came for `seconds` (the synthesizer writes faster than it plays).
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
        Self.schedule(buffer, on: player) { [weak self] in self?.played(current) }
        if !player.isPlaying { player.play() }
    }

    /// AVFoundation calls the completion back on its own queue. Nonisolated, so the closure doesn't inherit the main
    /// actor: Swift 6 traps a main-actor closure that runs anywhere else (it ended every reply on a real iPhone).
    private nonisolated static func schedule(_ buffer: AVAudioPCMBuffer, on player: AVAudioPlayerNode,
                                             played: @escaping @MainActor @Sendable () -> Void) {
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { played() } }
        }
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
        let ratio = playFormat.sampleRate / source.format.sampleRate
        // Bounded before it becomes a UInt32 frame count (a format with no sample rate would trap the conversion).
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
}

/// The watch's (or the iPhone's) microphone: a tap on the engine's input in its own format, converted to 16 kHz
/// mono 16-bit. On the iPhone the input goes through voice processing first (echo cancellation: the reply coming out
/// of the loudspeaker is taken out of what the microphone hears).
@MainActor
final class MicrophoneInput: ConversationInput {
    var isFixture: Bool { false }

    func allowed() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: true
        case .denied: false
        default: await AVAudioApplication.requestRecordPermission()
        }
    }

    /// The iPhone: voice processing (echo cancellation), switched on while the engine is new and stopped, before the
    /// player is connected (it changes the I/O formats; the tap reads the input's format afterwards). Without it the
    /// conversation still works (half duplex), only less well on the loudspeaker.
    func prepare(engine: AVAudioEngine) {
        #if os(iOS)
        let input = engine.inputNode
        guard !input.isVoiceProcessingEnabled else { return }
        do {
            try input.setVoiceProcessingEnabled(true)
        } catch {
            audioLog.notice("voice processing unavailable")
        }
        #endif
    }

    func start(engine: AVAudioEngine, deliver: @escaping @MainActor ([Int16]) -> Void) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // Numbers only (for tuning the speech detector on the voice-processed input): rate, channels, processing.
        #if os(iOS)
        let processing = input.isVoiceProcessingEnabled ? "on" : "off"
        #else
        let processing = "n/a"
        #endif
        audioLog.notice("microphone \(format.sampleRate, format: .fixed(precision: 0), privacy: .public) Hz \(format.channelCount, privacy: .public) ch, voice processing \(processing, privacy: .public)")
        guard format.sampleRate > 0, format.channelCount > 0, let tap = TapConverter(from: format) else {
            throw AudioGraph.StartFailure.engine("input format")
        }
        Self.tap(input, format: format, converter: tap, deliver: deliver)
    }

    /// The tap runs on the audio thread. Nonisolated, so its closure doesn't inherit the main actor: Swift 6 traps a
    /// main-actor closure that runs anywhere else (Talk crashed the moment the microphone opened on a real iPhone).
    private nonisolated static func tap(_ input: AVAudioInputNode, format: AVAudioFormat, converter: TapConverter,
                                        deliver: @escaping @MainActor @Sendable ([Int16]) -> Void) {
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(format.sampleRate / 10), format: format) { buffer, _ in
            guard let samples = converter.convert(buffer), !samples.isEmpty else { return }
            // In order (the detector reads a continuous stream).
            DispatchQueue.main.async { MainActor.assumeIsolated { deliver(samples) } }
        }
    }

    func stop(engine: AVAudioEngine) {
        engine.inputNode.removeTap(onBus: 0)
    }

    func opened() {}
}

/// Converts the microphone's buffers to 16 kHz mono 16-bit, on the tap's thread (one converter keeps its state
/// across buffers).
final class TapConverter: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let target: AVAudioFormat

    init?(from source: AVAudioFormat) {
        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: source, to: target) else { return nil }
        self.converter = converter
        self.target = target
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> [Int16]? {
        let ratio = target.sampleRate / buffer.format.sampleRate
        let frames = Double(buffer.frameLength) * ratio + 64
        guard frames.isFinite, frames > 0, frames < Double(UInt32.max),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(frames)) else {
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
        guard error == nil, let channel = output.int16ChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(clamping: output.frameLength)))
    }
}
