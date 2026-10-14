import ActivityKit
import Foundation
import Observation
import os
import SamRabbitKit
import SwiftUI
import UIKit

private let captureLog = Logger(subsystem: "com.samrabbit.mobile", category: "capture")

/// A voice note on the iPhone: "tap, talk, it's sent" (CONTRACTS-WAVE8 §C2). The Voice Note intent (the Action
/// Button, the control, the widgets' buttons, Siri) opens the full-screen recorder (`CaptureView`), which records at
/// once: AAC 16 kHz mono 32 kbps (`AVAudioRecorder`, the watch's format). It stops on about 2.5 s of quiet after
/// speech, on Stop (the screen's, the Live Activity's), on a second press of the Action Button, on a call, or at
/// 180 s; then the recording goes into the outbox and up to the Mac (`CaptureUploader`, a background upload), and the
/// recorder says what the Mac did ("Sent ✓ — Added to your journal") and closes. Nothing is said back. It keeps
/// recording with the phone locked or the app in the background (`UIBackgroundModes: audio`; the Live Activity shows
/// the timer and Stop). The Mac out of reach: "Saved · it goes when your Mac is reachable".
///
/// One microphone: a running conversation (Talk) ends first, and dictation stops (`willRecord`).
@MainActor
@Observable
final class CaptureModel {
    enum Phase: Equatable {
        case idle
        /// Opened by a link from outside the app: waits for a tap (a link never turns the microphone on).
        case ready
        case starting
        case recording
        case sending
        case finished(CaptureNotice)
        /// It couldn't record (the microphone refused, too short, the recorder didn't start).
        case problem(title: String, detail: String)
    }

    /// The recorder is up.
    var presented = false
    private(set) var phase: Phase = .idle
    /// 0...1 for the orb.
    private(set) var level: Double = 0
    private(set) var elapsed: TimeInterval = 0
    private(set) var heardSpeech = false
    private(set) var startedAt: Date?
    /// Notes still waiting for the Mac (shown under the outcome).
    private(set) var waiting = 0

    @ObservationIgnored private let account: BridgeAccount
    @ObservationIgnored let uploader: CaptureUploader
    @ObservationIgnored let activity = CaptureActivityController()
    @ObservationIgnored private let makeSource: @MainActor () -> VoiceSource
    @ObservationIgnored private var source: VoiceSource?
    @ObservationIgnored private var file: URL?
    @ObservationIgnored private var meta: CaptureMeta?
    @ObservationIgnored private var voice = VoiceActivity(silence: CaptureFormat.silenceToStop,
                                                          limit: CaptureFormat.iphoneMaxSeconds)
    @ObservationIgnored private var meter: Task<Void, Never>?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var closing: Task<Void, Never>?
    /// Each recording has its own number: what an earlier one finishes is ignored.
    @ObservationIgnored private var attempt = 0
    /// Runs just before the microphone opens: Talk ends, dictation stops.
    @ObservationIgnored var willRecord: (@MainActor () -> Void)?
    /// A note reached the Mac (the app refreshes Tasks: a saved note shows there).
    @ObservationIgnored var onDelivered: (@MainActor (CaptureStatus) -> Void)?

    init(account: BridgeAccount, uploader: CaptureUploader = .shared,
         source: (@MainActor () -> VoiceSource)? = nil) {
        self.account = account
        self.uploader = uploader
        makeSource = source ?? { MicrophoneSource.source(limit: CaptureFormat.iphoneMaxSeconds) }
        waiting = uploader.waiting
        CaptureRemote.onStop = { [weak self] in self?.stop() }
        CaptureRemote.listen()
        // Nothing records at launch: a Live Activity left by an earlier run (the app was closed) goes.
        CaptureActivityController.endLeftovers()
    }

    var recording: Bool { phase == .recording || phase == .starting }

    // MARK: - Opening

    /// The recorder, from the Voice Note intent (`record`: it records at once) or a link from outside (it waits for a
    /// tap). The intent again while recording: stop and send (a second press of the Action Button).
    func open(record: Bool) {
        closing?.cancel()
        withAnimation(.smooth(duration: 0.3)) { presented = true }
        switch phase {
        case .recording:
            if record { stop() }
        case .starting, .sending:
            break
        case .idle, .ready, .finished, .problem:
            if record { start() } else { phase = .ready }
        }
    }

    /// Records (the intent, the screen's mic button, Try again).
    func start() {
        closing?.cancel()
        guard account.isPaired else {
            phase = .problem(title: "Pair with your Mac first", detail: "Then a voice note goes straight to it.")
            return
        }
        reset()
        attempt += 1
        let current = attempt
        phase = .starting
        willRecord?()
        let source = makeSource()
        work = Task { [weak self] in
            let allowed = await source.allowed()
            guard let self, self.attempt == current, self.phase == .starting else { return }
            guard allowed else {
                self.phase = .problem(title: "Microphone is off",
                                      detail: "Allow it in Settings > Privacy & Security > Microphone > SamRabbit.")
                Haptics.error()
                return
            }
            self.record(with: source)
        }
    }

    /// The experiment (`VoiceNoteBackgroundIntent`): records with the recorder off screen, the Live Activity showing
    /// it. False when anything refuses (the microphone not allowed yet, the audio session, the Live Activity): the
    /// intent then opens the app and records as usual.
    func startInBackground() async -> Bool {
        guard account.isPaired, !recording, BackgroundNote.microphoneAllowed else { return false }
        reset()
        attempt += 1
        phase = .starting
        willRecord?()
        record(with: makeSource())
        guard phase == .recording, activity.running else {
            reset()
            phase = .idle
            activity.end()
            return false
        }
        return true
    }

    private func record(with source: VoiceSource) {
        let meta = CaptureMeta(source: .iphone) // the id and the time are the recording's start
        let file = VoiceFormat.temporaryFile()
        do {
            try source.start(into: file)
        } catch {
            captureLog.error("the recorder did not start")
            try? FileManager.default.removeItem(at: file)
            phase = .problem(title: "The microphone didn't start", detail: "Try again in a moment.")
            Haptics.error()
            return
        }
        source.onInterrupted = { [weak self] in self?.stop() } // a call: keep what was said, send it
        self.source = source
        self.file = file
        self.meta = meta
        voice = VoiceActivity(silence: CaptureFormat.silenceToStop, limit: CaptureFormat.iphoneMaxSeconds)
        startedAt = meta.capturedAt
        elapsed = 0
        level = 0
        heardSpeech = false
        phase = .recording
        Haptics.tap()
        activity.start(meta: meta)
        meter = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, self.phase == .recording, let source = self.source, let startedAt = self.startedAt else {
                    return
                }
                let elapsed = Date.now.timeIntervalSince(startedAt)
                let decision = self.voice.feed(power: source.power(), elapsed: elapsed)
                // What the screen draws changes only when it shows: the whole seconds, a level step the orb shows.
                if elapsed.rounded(.down) != self.elapsed.rounded(.down) { self.elapsed = elapsed }
                if abs(self.voice.level - self.level) > 0.02 { self.level = self.voice.level }
                if self.voice.heardSpeech != self.heardSpeech { self.heardSpeech = self.voice.heardSpeech }
                if decision != .keepGoing {
                    self.stop()
                    return
                }
            }
        }
    }

    // MARK: - Stop and send

    /// Stop & send (the button, quiet after speech, the cap, the intent again, the Live Activity's Stop, a call):
    /// under 0.4 s is a slip and is discarded; anything else goes to the outbox and up to the Mac.
    func stop() {
        guard phase == .recording, let source, let file, var meta else { return }
        meter?.cancel()
        meter = nil
        let duration = Date.now.timeIntervalSince(startedAt ?? .now)
        source.stop()
        self.source = nil
        self.file = nil
        self.meta = nil
        level = 0
        guard VoiceActivity.keeps(duration: duration) else {
            try? FileManager.default.removeItem(at: file)
            phase = .problem(title: "Didn't catch that", detail: "Hold on a moment longer, then speak.")
            activity.end()
            return
        }
        meta.seconds = (duration * 10).rounded() / 10
        let entry: CaptureOutbox.Entry
        do {
            entry = try uploader.outbox.add(recording: file, meta: meta)
        } catch {
            try? FileManager.default.removeItem(at: file)
            phase = .problem(title: "Couldn't keep the recording", detail: "Try again.")
            activity.end()
            return
        }
        phase = .sending
        Haptics.tap()
        activity.update(CaptureActivityState(phase: .sending, stoppedAt: .now))
        let current = attempt
        work = Task { [weak self] in await self?.deliver(entry, attempt: current) }
    }

    /// Up to the Mac, then what it did (it waits up to 8 s for the outcome). Held awake in the background (the
    /// phone may be locked: the note went quiet and stopped by itself).
    private func deliver(_ entry: CaptureOutbox.Entry, attempt current: Int) async {
        let awake = Awake()
        defer { awake.end() }
        let stoppedAt = Date.now
        // In front: a quick try first. Either way the recorder says "Saved" after 15 s without an answer (the upload
        // goes on; the outbox keeps the note).
        let quick = UIApplication.shared.applicationState == .active
        let uploader = uploader
        guard let result = await Self.first(within: 15, { await uploader.send(entry, quick: quick) }) else {
            guard attempt == current else { return }
            finish(.queued(waiting: max(1, uploader.waiting)), stoppedAt: stoppedAt)
            return
        }
        guard attempt == current else { return }
        switch result {
        case .success(let received):
            var status = received
            if !status.state.settled, let client = account.client() {
                status = await Self.outcome(of: status, client: client)
                uploader.outbox.record(status)
            }
            guard attempt == current else { return }
            onDelivered?(status)
            finish(status.notice, stoppedAt: stoppedAt)
        case .failure(let error):
            if error == .unauthorized {
                finish(CaptureNotice(tone: .queued, title: "Saved", detail: "Pair again with your Mac to send it.",
                                     symbol: "iphone.slash"), stoppedAt: stoppedAt)
            } else if error.isRetryableCapture {
                finish(.queued(waiting: max(1, uploader.waiting)), stoppedAt: stoppedAt)
            } else {
                finish(CaptureNotice(tone: .failed, title: "Your Mac didn't take it",
                                     detail: error.errorDescription ?? "Try recording it again.",
                                     symbol: "exclamationmark.triangle.fill"), stoppedAt: stoppedAt)
            }
        }
    }

    /// `work`'s answer, or nil when it takes longer than `seconds` (it goes on either way).
    private static func first<T: Sendable>(within seconds: TimeInterval,
                                           _ work: @escaping @Sendable () async -> T) async -> T? {
        let race = Race<T>()
        return await withCheckedContinuation { continuation in
            race.set(continuation)
            Task { race.resume(await work()) }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                race.resume(nil)
            }
        }
    }

    /// What the Mac did, waiting at most 8 s in all (`GET …/capture/<id>?wait=`): the note as it is by then.
    private static func outcome(of status: CaptureStatus, client: BridgeClient) async -> CaptureStatus {
        var latest = status
        let deadline = Date.now.addingTimeInterval(TimeInterval(CaptureFormat.outcomeWait))
        while !latest.state.settled, Date.now < deadline {
            let left = Int(deadline.timeIntervalSinceNow.rounded(.up))
            guard left > 0, let next = try? await client.captureStatus(latest.captureId, wait: min(left, 8)) else { break }
            latest = next
        }
        return latest
    }

    private func finish(_ notice: CaptureNotice, stoppedAt: Date) {
        phase = .finished(notice)
        waiting = uploader.waiting
        switch notice.tone {
        case .sent: Haptics.success()
        case .queued: Haptics.tap()
        case .failed: Haptics.error()
        }
        activity.finish(CaptureActivityState(notice, stoppedAt: stoppedAt))
        // The recorder closes by itself a moment after saying it (a problem stays until closed).
        guard notice.tone != .failed else { return }
        closing = Task { [weak self] in
            try? await Task.sleep(for: .seconds(notice.tone == .sent ? 2.2 : 3.0))
            guard !Task.isCancelled, let self, case .finished = self.phase else { return }
            self.close()
        }
    }

    // MARK: - Cancel and close

    /// Cancel (the X while recording): the recording is dropped, nothing is sent.
    func cancel() {
        reset()
        phase = .idle
        activity.end()
        withAnimation(.smooth(duration: 0.3)) { presented = false }
    }

    /// Closes the recorder; a note on its way keeps going (the outbox has it).
    func close() {
        closing?.cancel()
        if phase == .recording || phase == .starting {
            cancel()
            return
        }
        withAnimation(.smooth(duration: 0.3)) { presented = false }
        if case .sending = phase { return }
        phase = .idle
    }

    private func reset() {
        meter?.cancel()
        meter = nil
        work?.cancel()
        work = nil
        source?.stop()
        source = nil
        if let file { try? FileManager.default.removeItem(at: file) }
        file = nil
        meta = nil
        level = 0
        elapsed = 0
        heardSpeech = false
    }

    /// The app came to the front: the outbox tries again, the count follows.
    func sceneActive() {
        uploader.flush(quick: true)
        waiting = uploader.waiting
        activity.retry()
    }
}

/// Resumes a continuation once, with whichever comes first.
private final class Race<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Never>?

    func set(_ value: CheckedContinuation<T?, Never>) {
        lock.withLock { continuation = value }
    }

    func resume(_ value: T?) {
        let pending = lock.withLock { () -> CheckedContinuation<T?, Never>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
    }
}

/// A background-task assertion while a note goes up and its outcome comes back (the phone may be locked). If iOS
/// ends it early it is just let go.
@MainActor
private final class Awake {
    private var id: UIBackgroundTaskIdentifier = .invalid

    init() {
        id = UIApplication.shared.beginBackgroundTask(withName: "SamRabbit sends a voice note") { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}

/// The voice note's Live Activity: started when recording starts (the app is in front then), updated when it
/// sends, ended a few seconds after showing what the Mac did. Its Stop runs `StopVoiceNoteIntent`. Kept by id:
/// ActivityKit's calls run off the main actor.
@MainActor
final class CaptureActivityController {
    private var activityId: String?
    private var pending: (CaptureMeta, CaptureActivityState)?

    /// An activity shows the note now.
    var running: Bool { activityId != nil }

    func start(meta: CaptureMeta) {
        end()
        let state = CaptureActivityState(phase: .recording)
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            let attributes = CaptureActivityAttributes(captureId: meta.captureId, startedAt: meta.capturedAt)
            let activity = try Activity.request(attributes: attributes, content: Self.content(state))
            activityId = activity.id
            pending = nil
        } catch {
            pending = (meta, state)
            captureLog.notice("voice note live activity not started: \(String(describing: error), privacy: .public)")
        }
    }

    /// The app is in front again: a recording without its activity gets it now.
    func retry() {
        guard activityId == nil, let pending, pending.1.phase == .recording else { return }
        start(meta: pending.0)
    }

    func update(_ state: CaptureActivityState) {
        guard let id = activityId else { return }
        Task { await Self.update(id, to: state) }
    }

    /// Shows what the Mac did, then goes after a few seconds.
    func finish(_ state: CaptureActivityState) {
        pending = nil
        guard let id = activityId else { return }
        activityId = nil
        Task { await Self.end([id], final: state, after: 4) }
    }

    func end() {
        pending = nil
        guard let id = activityId else { return }
        activityId = nil
        Task { await Self.end([id], final: nil, after: 0) }
    }

    /// Ends the voice-note activities a closed app left behind.
    static func endLeftovers() {
        let leftovers = Activity<CaptureActivityAttributes>.activities.map(\.id)
        guard !leftovers.isEmpty else { return }
        Task { await end(leftovers, final: nil, after: 0) }
    }

    /// A voice note being recorded is what the Dynamic Island and the top of the Lock Screen show, over a task's
    /// activity (`relevanceScore`): its Stop must be at hand.
    nonisolated private static func content(_ state: CaptureActivityState) -> ActivityContent<CaptureActivityState> {
        ActivityContent(state: state, staleDate: nil, relevanceScore: 100)
    }

    nonisolated private static func update(_ id: String, to state: CaptureActivityState) async {
        guard let activity = Activity<CaptureActivityAttributes>.activities.first(where: { $0.id == id }) else { return }
        await activity.update(content(state))
    }

    nonisolated private static func end(_ ids: [String], final: CaptureActivityState?, after seconds: TimeInterval) async {
        for activity in Activity<CaptureActivityAttributes>.activities where ids.contains(activity.id) {
            let content = final.map { Self.content($0) }
            await activity.end(content, dismissalPolicy: seconds > 0 ? .after(.now.addingTimeInterval(seconds)) : .immediate)
        }
    }
}
