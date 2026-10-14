import AVFoundation
import Foundation
import Observation
import os
import SamRabbitKit
import SwiftUI
import WatchKit

private let voiceLog = Logger(subsystem: "com.samrabbit.mobile.watchkitapp", category: "voice")

// The watch takes text only by voice: no keyboard, no Scribble, no system text input. A recording goes to
// the Mac bridge (directly, or through the iPhone in chunks) and comes back as words; the person checks
// them and sends. A voice note (`.capture`) skips all that: it goes to the Mac as it is, which files it, and the
// watch only says that it went (nothing is said back).

/// What a recording is for. Send performs it with the words.
enum VoicePurpose: Equatable {
    /// A new T3 task (automatic placement): Quick > New task.
    case ask
    /// A message into a thread.
    case reply(TaskThread)
    /// The answer to the question the card showed (`pending.requestId`).
    case answer(TaskThread, PendingAction?)
    /// A line in today's journal (the person's own words).
    case note
    /// A voice note (CONTRACTS-WAVE8 §C3): no words back, no review; the recording itself goes to the Mac
    /// (`/v1/mobile/capture`), which files it: the journal on an explicit cue, a task, the calendar, else a note.
    case capture

    var title: String {
        switch self {
        case .ask: "New task"
        case .reply(let thread): "Reply · \(Formatting.clip(thread.title, 22))"
        case .answer: "Answer"
        case .note: "Journal note"
        case .capture: "Voice note"
        }
    }

    /// Under the orb while listening.
    var prompt: String {
        switch self {
        case .ask: "What should T3 Code do?"
        case .reply: "Say your reply"
        case .answer(let thread, let pending): Formatting.clip((pending ?? thread.pending)?.text ?? "Say your answer", 60)
        case .note: "What should I add to today's journal?"
        case .capture: "Say it. Pause and it's sent."
        }
    }

    /// Above the words on the review screen.
    var reviewLabel: String {
        switch self {
        case .ask: "New task"
        case .reply(let thread): "Reply to “\(Formatting.clip(thread.title, 26))”"
        case .answer(let thread, _): "Answer for “\(Formatting.clip(thread.title, 24))”"
        case .note: "Today's journal"
        case .capture: "Voice note"
        }
    }

    var symbol: String {
        switch self {
        case .ask: "sparkles"
        case .reply: "arrowshape.turn.up.left.fill"
        case .answer: "questionmark.bubble.fill"
        case .note: "book.pages.fill"
        case .capture: "waveform.badge.mic"
        }
    }

    var tint: Color {
        switch self {
        case .ask: SamTheme.orbPale
        case .reply: SamTheme.cyan
        case .answer: SamTheme.violet
        case .note: SamTheme.mint
        case .capture: SamTheme.red
        }
    }

    /// The longest recording: a minute for words to check, two for a voice note.
    var limit: TimeInterval { self == .capture ? CaptureFormat.watchMaxSeconds : VoiceFormat.maxSeconds }

    /// Quiet this long after speech ends it (a note has pauses an answer doesn't).
    var silence: TimeInterval { self == .capture ? CaptureFormat.silenceToStop : VoiceFormat.silenceToStop }

    /// The busy key of the action (`WatchModel.busy`).
    var busyKey: String {
        switch self {
        case .ask: "ask"
        case .reply(let thread), .answer(let thread, _): thread.threadId
        case .note: "note"
        case .capture: "capture"
        }
    }
}

/// One voice capture to present (`WatchModel.voice`); `after` runs once its action was sent (the thread
/// screen reloads).
struct VoiceRequest: Identifiable {
    let id = UUID()
    var purpose: VoicePurpose
    var after: (@MainActor () async -> Void)?
}

/// One voice capture: listen (the orb follows the level), stop on quiet / Stop / 60 s, turn the recording
/// into words on the Mac, show them, send. "Say again" starts over; going back cancels. Recordings are
/// deleted as soon as they were sent (or discarded).
@MainActor
@Observable
final class VoiceCapture {
    enum Phase: Equatable {
        case starting
        case listening
        case transcribing
        case review(String)
        case sending(String)
        case failed(VoiceProblem)
        /// A voice note on its way to the Mac.
        case delivering
        /// What became of a voice note ("Sent ✓ — Added to your journal", "Saved", ...).
        case delivered(CaptureNotice)
    }

    let request: VoiceRequest
    private(set) var phase: Phase = .starting
    /// 0...1 for the orb.
    private(set) var level: Double = 0
    private(set) var elapsed: TimeInterval = 0
    private(set) var heardSpeech = false
    /// Why the last Send didn't go through (the words stay on screen).
    private(set) var sendProblem: WatchBanner?

    @ObservationIgnored private let model: WatchModel
    @ObservationIgnored private let makeSource: @MainActor () -> VoiceSource
    @ObservationIgnored private var source: VoiceSource?
    @ObservationIgnored private var file: URL?
    /// A voice note's id and time (made when it starts recording).
    @ObservationIgnored private var meta: CaptureMeta?
    @ObservationIgnored private var activity = VoiceActivity()
    @ObservationIgnored private var startedAt = Date()
    @ObservationIgnored private var meter: Task<Void, Never>?
    @ObservationIgnored private var work: Task<Void, Never>?
    /// Each attempt (start, Say again) has its own number: what an earlier one finishes is ignored.
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var summaryChecked = false
    @ObservationIgnored private var closed = false

    init(request: VoiceRequest, model: WatchModel, source: (@MainActor () -> VoiceSource)? = nil) {
        self.request = request
        self.model = model
        let limit = request.purpose.limit
        makeSource = source ?? { MicrophoneSource.source(limit: limit) }
    }

    /// The microphone, or in debug builds the simulator's made-up voice (`-SamRabbitVoiceFixture`; silence in the
    /// simulator without one).
    static func defaultSource() -> VoiceSource {
        MicrophoneSource.source(limit: VoiceFormat.maxSeconds)
    }

    var isCapture: Bool { request.purpose == .capture }

    var tint: Color { request.purpose.tint }

    // MARK: - Listening

    /// The screen is (back) in front: starts listening, or starts over after it went away mid-recording
    /// (a system alert, the microphone permission prompt). What's on screen already (the words, a
    /// problem) stays.
    func appear() {
        closed = false
        switch phase {
        case .review, .sending, .failed, .delivering, .delivered: return
        case .starting, .listening, .transcribing: begin()
        }
    }

    /// Starts listening right away (on appear, and for Say again). When the Mac said it can't transcribe
    /// now, that is shown first instead (Say again then records anyway: the Mac answers for itself).
    func begin() {
        reset()
        attempt += 1
        let current = attempt
        // A voice note never waits for words here (the Mac keeps it until it can transcribe it).
        if !summaryChecked, !isCapture {
            summaryChecked = true
            if let problem = VoiceProblem(status: model.summary?.transcribe) {
                phase = .failed(problem)
                return
            }
        }
        phase = .starting
        let source = makeSource()
        work = Task { [weak self] in
            let allowed = await source.allowed()
            guard let self, self.attempt == current, !self.closed else { return }
            guard allowed else {
                self.phase = .failed(.microphone)
                return
            }
            self.listen(with: source)
        }
    }

    private func listen(with source: VoiceSource) {
        let file = VoiceFormat.temporaryFile()
        do {
            try source.start(into: file)
        } catch {
            voiceLog.error("the recorder did not start")
            try? FileManager.default.removeItem(at: file)
            phase = .failed(.recorderFailed)
            return
        }
        self.source = source
        self.file = file
        meta = isCapture ? CaptureMeta(source: .watch) : nil // the id and the time are the recording's start
        activity = VoiceActivity(silence: request.purpose.silence, limit: request.purpose.limit)
        startedAt = .now
        elapsed = 0
        level = 0
        heardSpeech = false
        phase = .listening
        WKInterfaceDevice.current().play(.start)
        meter = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, self.phase == .listening, let source = self.source else { return }
                let elapsed = Date.now.timeIntervalSince(self.startedAt)
                let decision = self.activity.feed(power: source.power(), elapsed: elapsed)
                self.elapsed = elapsed
                self.level = self.activity.level
                self.heardSpeech = self.activity.heardSpeech
                if decision != .keepGoing {
                    self.finish()
                    return
                }
            }
        }
    }

    /// Stop (the button, quiet after speech, the 60 s cap, or the app leaving the screen): a clip shorter
    /// than 0.4 s is discarded, anything else is turned into words.
    func finish() {
        guard phase == .listening, let source, let file else { return }
        meter?.cancel()
        meter = nil
        let duration = Date.now.timeIntervalSince(startedAt)
        source.stop()
        self.source = nil
        self.file = nil
        level = 0
        WKInterfaceDevice.current().play(.stop)
        guard VoiceActivity.keeps(duration: duration) else {
            try? FileManager.default.removeItem(at: file)
            phase = .failed(.tooShort)
            return
        }
        if var meta, isCapture {
            meta.seconds = (duration * 10).rounded() / 10
            self.meta = nil
            deliver(file, meta: meta)
            return
        }
        phase = .transcribing
        let current = attempt
        work = Task { [weak self] in await self?.transcribe(file, attempt: current) }
    }

    private func transcribe(_ file: URL, attempt current: Int) async {
        defer { try? FileManager.default.removeItem(at: file) }
        guard let client = model.account.client() else {
            phase = .failed(VoiceProblem(.notPaired))
            return
        }
        let result = await BridgeError.capture {
            try await client.transcribe(file: file, language: VoiceFormat.languageTag())
        }
        guard attempt == current, !closed else { return }
        model.route = model.link.lastRoute
        switch result {
        case .success(let transcript):
            let text = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                phase = .failed(.noSpeech)
                WKInterfaceDevice.current().play(.failure)
            } else {
                phase = .review(text)
                WKInterfaceDevice.current().play(.click)
            }
        case .failure(let error):
            if error == .cancelled { return }
            if error == .unauthorized { model.lastError = .unauthorized }
            phase = .failed(VoiceProblem(error))
            WKInterfaceDevice.current().play(.failure)
        }
    }

    // MARK: - A voice note

    /// Into the watch's outbox (so nothing is lost), then to the Mac (directly, through the iPhone, or handed to the
    /// iPhone); the result face closes by itself. Not cancelled when the screen goes: the note is kept either way.
    private func deliver(_ file: URL, meta: CaptureMeta) {
        let entry: CaptureOutbox.Entry
        do {
            entry = try model.captures.outbox.add(recording: file, meta: meta)
        } catch {
            try? FileManager.default.removeItem(at: file)
            phase = .failed(.recorderFailed)
            return
        }
        phase = .delivering
        let current = attempt
        Task { [model] in
            let notice = await model.captures.send(entry)
            WKInterfaceDevice.current().play(notice.tone == .failed ? .failure : .success)
            guard self.attempt == current, !self.closed else { return }
            self.phase = .delivered(notice)
            guard notice.tone != .failed else { return }
            try? await Task.sleep(for: .seconds(notice.tone == .sent ? 1.6 : 2.2))
            if case .delivered = self.phase, self.attempt == current { model.voice = nil }
        }
    }

    // MARK: - Send

    /// Performs the purpose with the words. On success the capture closes right away (the page shows the
    /// result); on failure the words stay with what went wrong, to send again.
    func send() {
        guard case .review(let text) = phase else { return }
        phase = .sending(text)
        sendProblem = nil
        // Not cancelled when the screen goes away: a request on its way is not abandoned halfway.
        Task { [model, request] in
            let sent = await model.send(request.purpose, text) {
                model.voice = nil
            }
            if sent {
                await request.after?()
            } else if case .sending = self.phase {
                self.phase = .review(text)
                self.sendProblem = model.banner ?? WatchBanner(style: .failure, title: "Not sent", detail: "Try again.")
            }
        }
    }

    /// Back / close: stops listening, drops the recording, ignores what's still on its way.
    func cancel() {
        closed = true
        reset()
        meta = nil
    }

    private func reset() {
        attempt += 1
        meter?.cancel()
        meter = nil
        work?.cancel()
        work = nil
        source?.stop()
        source = nil
        if let file { try? FileManager.default.removeItem(at: file) }
        file = nil
        level = 0
        sendProblem = nil
    }
}
