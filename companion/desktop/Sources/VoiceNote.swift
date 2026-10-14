import Foundation
import SamRabbitKit

/// Quick voice notes (CONTRACTS-WAVE8 §D1): Samin says something and it is dealt with, no back and forth. ⌃⌥N held
/// records while held and the release sends; tapped (or the dock's note button, the menus, the window's Home) it records
/// until the next tap, a pause of about 3 s after speech, or the 5-minute cap. The note goes to the bridge
/// (`POST /v1/desktop/capture`), which transcribes it and does what it says: a journal line only when he asks for the
/// journal (his words as said), a T3 task, a calendar entry, or a note kept with a suggestion. The dock's bar shows
/// "Recording… ⌃⌥N to send", then "Sent ✓ — Added to your journal".
///
/// * One microphone: a note doesn't start during a conversation, and while it records "Hey Rabbit" waits and no
///   conversation starts (`MacVoice.setNoteRecording`).
/// * Nothing is lost: the WAV goes into the outbox (`VoiceNoteOutbox`) before it is sent, and leaves it only once the
///   bridge said it has it. Notes the bridge couldn't take are tried again (5 s, 30 s, 2 min, then every 10 min, and at
///   once when the bridge is back).
/// * Nothing heard or said is logged: ids, lengths, sizes and what kind of thing the bridge made of it.
@MainActor
final class VoiceNotes: ObservableObject {
    static let shared = VoiceNotes()

    @Published private(set) var snapshot = VoiceNoteSnapshot()
    /// A note that waited in the outbox has gone, with what the bridge did with it: the bar showed the note when it was
    /// recorded, so the app says this one in a notification.
    var onOutcome: ((VoiceNoteSnapshot) -> Void)?

    private let recorder: VoiceNoteRecorder
    let outbox: VoiceNoteOutbox
    private var gesture = VoiceNoteGesture()
    private var activity = VoiceActivity(silence: VoiceNoteRules.tapSilence, limit: VoiceNoteRules.maxSeconds)
    /// The note being recorded: its id (made at its start) and when it started.
    private var current: (id: String, startedAt: Date, source: String)?
    /// The note whose outcome the bar shows.
    private var shownId: String?
    private var hideTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var inFlight = Set<String>()
    private var flushing = false
    private var activated = false

    init(recorder: VoiceNoteRecorder? = nil, outbox: VoiceNoteOutbox? = nil,
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.recorder = recorder ?? VoiceNoteRecorder(environment: environment)
        self.outbox = outbox ?? VoiceNoteOutbox(directory: VoiceNoteOutbox.defaultDirectory(bundleId: Bundle.main.bundleIdentifier,
                                                                                             environment: environment))
        self.recorder.onSamples = { [weak self] piece in self?.heard(piece) }
        self.recorder.onInterrupted = { [weak self] in self?.finish(reason: "device") }
    }

    /// At launch: notes left in the outbox are tried again.
    func activate() {
        guard !activated else { return }
        activated = true
        let dropped = outbox.prune(now: Date())
        if !dropped.isEmpty { Log.write("note: \(dropped.count) old note(s) dropped from the outbox") }
        refreshWaiting()
        if snapshot.waiting > 0 { Log.write("note: \(snapshot.waiting) note(s) waiting for the bridge") }
        scheduleRetry()
    }

    var isRecording: Bool { current != nil }

    /// The shortcut the bar and the menus show ("" while it isn't working: another app has it).
    func setShortcut(_ display: String) {
        if snapshot.shortcut != display { snapshot.shortcut = display }
    }

    // MARK: - What starts and ends a note

    /// ⌃⌥N went down.
    func press() {
        switch gesture.press(at: Date(), recording: isRecording) {
        case .start: begin(source: "hotkey", held: true)
        case .finish: finish(reason: "hotkey")
        case .none: break
        }
    }

    /// ⌃⌥N came up.
    func release() {
        switch gesture.release(at: Date()) {
        case .finish:
            finish(reason: "released")
        case .start, .none:
            // A tap: it goes on recording until the next one (or a pause).
            if isRecording, case .recording(held: true) = snapshot.phase { snapshot.phase = .recording(held: false) }
        }
    }

    /// The dock's note button, the menus, the window's Home: start, or send the one recording.
    func toggle(source: String) {
        isRecording ? finish(reason: source) : begin(source: source, held: false)
    }

    /// Stops and sends what was said (the bar's Send).
    func send() {
        guard isRecording else { return }
        finish(reason: "button")
    }

    /// Stops and throws it away (the bar's ×, Esc on the bar).
    func cancel() {
        guard let note = current else { return }
        current = nil
        recorder.cancel()
        gesture.ended()
        MacVoice.shared.setNoteRecording(false)
        Log.write("note: cancelled \(note.id.prefix(8))")
        show(.discarded, "Cancelled", "Nothing was sent.", for: note.id, hideAfter: 1.6)
    }

    private func begin(source: String, held: Bool) {
        let voice = MacVoice.shared
        guard voice.state == .idle || voice.isShowingError else {
            gesture.ended()
            show(.failed, "Finish the conversation first", "One microphone at a time.", for: nil, hideAfter: 2.5)
            return
        }
        let id = VoiceNoteUpload.newId()
        let startedAt = Date()
        current = (id, startedAt, source)
        shownId = id
        hideTask?.cancel()
        activity = VoiceActivity(silence: VoiceNoteRules.tapSilence, limit: VoiceNoteRules.maxSeconds)
        voice.setNoteRecording(true)
        var next = snapshot
        next.phase = .recording(held: held)
        next.startedAt = startedAt
        next.level = 0
        next.line = "Recording…"
        next.detail = ""
        snapshot = next
        Log.write("note: recording \(id.prefix(8)) (\(source))")
        Task {
            do {
                try await recorder.start()
            } catch is CancellationError {
                return
            } catch {
                guard current?.id == id else { return }
                current = nil
                gesture.ended()
                voice.setNoteRecording(false)
                let message = (error as? VoiceNoteRecorder.Failure)?.message ?? "The microphone didn’t start"
                Log.write("note: not recorded (\(message))")
                show(.failed, "Couldn’t record", message, for: id, hideAfter: VoiceNoteRules.outcomeSeconds)
            }
        }
    }

    private func heard(_ piece: [Int16]) {
        guard let note = current else { return }
        let elapsed = Date().timeIntervalSince(note.startedAt)
        let decision = activity.feed(power: PCM16.dbfs(piece), elapsed: recorder.seconds)
        let level = (activity.level * 100).rounded() / 100
        if abs(level - snapshot.level) >= 0.03 || (level == 0 && snapshot.level != 0) { snapshot.level = level }
        let tapped = !gesture.holding && snapshot.phase == .recording(held: false)
        switch decision {
        case .limit:
            finish(reason: "limit")
        case .silence where tapped:
            finish(reason: "pause")
        case .keepGoing, .silence:
            if tapped && !activity.heardSpeech && elapsed >= VoiceNoteRules.tapNoSpeech {
                current = nil
                recorder.cancel()
                gesture.ended()
                MacVoice.shared.setNoteRecording(false)
                Log.write("note: nothing said, nothing sent")
                show(.discarded, "Didn’t hear anything", "Nothing was sent.", for: note.id, hideAfter: 2.5)
            }
        }
    }

    private func finish(reason: String) {
        guard let note = current else { return }
        current = nil
        let samples = recorder.stop()
        gesture.ended()
        MacVoice.shared.setNoteRecording(false)
        let seconds = Double(samples.count) / 16_000
        guard seconds >= VoiceNoteRules.minimumSeconds else {
            Log.write("note: too short (\(String(format: "%.1f", seconds)) s), nothing sent")
            show(.discarded, "Too short", "Hold \(snapshot.shortcut.isEmpty ? "the shortcut" : snapshot.shortcut) while you talk, or tap it, talk, and tap again.",
                 for: note.id, hideAfter: 2.5)
            return
        }
        let wav = WAV.encode(samples: samples)
        let now = Date()
        // Not due for the retry loop while this first try is on its way.
        let item = VoiceNoteOutbox.Item(captureId: note.id, capturedAt: note.startedAt, createdAt: now, seconds: seconds,
                                        nextAt: now.addingTimeInterval(VoiceNoteRules.retryDelays[0]))
        do {
            try outbox.add(item, wav: wav)
        } catch {
            Log.write("note: the outbox couldn't keep it (\(VoiceAudio.describe(error))); sending it straight away")
        }
        refreshWaiting()
        Log.write("note: \(note.id.prefix(8)) ends (\(reason), \(String(format: "%.1f", seconds)) s, \(wav.count / 1024) KB)")
        show(.sending, "On its way to your Mac’s bridge…", "", for: note.id, hideAfter: nil)
        Task { await deliver(item, wav: wav, shown: true) }
    }

    // MARK: - Sending

    /// One try. `shown`: the bar is showing this note (its first try); else it is an outbox retry.
    private func deliver(_ item: VoiceNoteOutbox.Item, wav: Data, shown: Bool) async {
        guard !inFlight.contains(item.captureId) else { return }
        inFlight.insert(item.captureId)
        defer { inFlight.remove(item.captureId) }
        let result = await VoiceNoteAPI.upload(wav, item: item)
        switch result {
        case .delivered(let status):
            outbox.remove(item.captureId)
            refreshWaiting()
            Log.write("note: \(item.captureId.prefix(8)) sent (\(status.state))" + (shown ? "" : " after \(item.attempts) tr\(item.attempts == 1 ? "y" : "ies")"))
            if shown {
                let lines = VoiceNoteText.outcome(status)
                show(.sent, lines.line, lines.detail, for: item.captureId, hideAfter: status.settled ? VoiceNoteRules.outcomeSeconds : nil)
            }
            if !status.settled { await follow(item.captureId, shown: shown) } else { report(status, shown: shown) }
        case .keep(let why):
            outbox.update(VoiceNoteOutbox.failed(item, why: why, now: Date()))
            refreshWaiting()
            Log.write("note: \(item.captureId.prefix(8)) kept for later (\(why))")
            if shown {
                show(.queued, "Saved on this Mac", "\(why) — it goes as soon as it can.", for: item.captureId,
                     hideAfter: VoiceNoteRules.outcomeSeconds + 1)
            }
            scheduleRetry()
        case .drop(let why):
            outbox.remove(item.captureId)
            refreshWaiting()
            Log.write("note: \(item.captureId.prefix(8)) not sent (\(why))")
            if shown { show(.failed, "Not sent", why, for: item.captureId, hideAfter: VoiceNoteRules.outcomeSeconds) }
        }
    }

    /// Asks the bridge what it did with the note until it says (about 20 s at most).
    private func follow(_ id: String, shown: Bool) async {
        let deadline = Date().addingTimeInterval(VoiceNoteRules.outcomeWait)
        while Date() < deadline {
            guard let status = await VoiceNoteAPI.status(id, wait: 8) else {
                try? await Task.sleep(for: .seconds(1))
                continue
            }
            if status.settled {
                report(status, shown: shown)
                return
            }
        }
        Log.write("note: \(id.prefix(8)) still being worked on")
        if shown, shownId == id, snapshot.phase == .sent {
            show(.sent, "Sent", "The bridge is still working on it.", for: id, hideAfter: VoiceNoteRules.outcomeSeconds)
        }
    }

    private func report(_ status: CaptureStatus, shown: Bool) {
        let kind = status.outcome?.kind ?? status.state
        Log.write("note: \(status.captureId.prefix(8)) \(status.state) (\(kind.isEmpty ? "-" : kind))")
        let lines = VoiceNoteText.outcome(status)
        if shown, shownId == status.captureId, snapshot.phase == .sent {
            show(.sent, lines.line, lines.detail, for: status.captureId, hideAfter: VoiceNoteRules.outcomeSeconds)
        } else if !shown {
            var note = VoiceNoteSnapshot()
            note.phase = .sent
            note.line = lines.line
            note.detail = lines.detail
            onOutcome?(note)
        }
    }

    // MARK: - The outbox

    /// The bridge is back (or answered again): every waiting note is tried now.
    func retryNow() {
        let waiting = outbox.items()
        guard !waiting.isEmpty else { return }
        let now = Date()
        for var item in waiting where item.nextAt > now && !inFlight.contains(item.captureId) {
            item.nextAt = now
            outbox.update(item)
        }
        scheduleRetry()
    }

    private func scheduleRetry() {
        retryTask?.cancel()
        guard let next = outbox.nextDue() else { return }
        retryTask = Task { [weak self] in
            let wait = max(0.2, next.timeIntervalSinceNow)
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    private func flush() async {
        guard !flushing else { return }
        flushing = true
        defer {
            flushing = false
            scheduleRetry()
        }
        for item in outbox.due(now: Date()) where !inFlight.contains(item.captureId) {
            guard let wav = outbox.wav(item.captureId) else {
                outbox.remove(item.captureId)
                continue
            }
            await deliver(item, wav: wav, shown: false)
        }
        _ = outbox.prune(now: Date())
        refreshWaiting()
    }

    private func refreshWaiting() {
        let count = outbox.items().count
        if snapshot.waiting != count { snapshot.waiting = count }
    }

    // MARK: - The bar

    private func show(_ phase: VoiceNoteSnapshot.Phase, _ line: String, _ detail: String, for id: String?, hideAfter: TimeInterval?) {
        // A note started meanwhile owns the bar: an older one's news waits for nobody.
        if let id, current != nil, current?.id != id { return }
        if let id { shownId = id }
        var next = snapshot
        next.phase = phase
        next.line = line
        next.detail = detail
        next.level = 0
        if !(phase == .sending || phase == .sent) { next.startedAt = nil }
        snapshot = next
        hideTask?.cancel()
        hideTask = nil
        guard let hideAfter else { return }
        let shown = shownId
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(hideAfter))
            guard !Task.isCancelled, let self, self.current == nil, self.shownId == shown else { return }
            var idle = self.snapshot
            idle.phase = .idle
            idle.line = ""
            idle.detail = ""
            idle.startedAt = nil
            self.snapshot = idle
        }
    }
}
