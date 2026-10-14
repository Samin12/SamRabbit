import Foundation

/// Voice notes (VoiceNoteModels.swift): ⌃⌥N's hold and tap, what the bridge answers and what the dock says about it,
/// the upload's headers, and the outbox on disk (a temp folder).
enum VoiceNoteTests {
    static let all: [(String, () throws -> Void)] = [
        ("holdRecordsWhileHeld", holdRecordsWhileHeld),
        ("tapStartsAndTapSends", tapStartsAndTapSends),
        ("aNoteStartedElsewhereIsSentByThePress", aNoteStartedElsewhereIsSentByThePress),
        ("repeatsAndLostReleases", repeatsAndLostReleases),
        ("endedAnotherWay", endedAnotherWay),
        ("captureAnswers", captureAnswers),
        ("outcomeLines", outcomeLines),
        ("deliveryByStatus", deliveryByStatus),
        ("retryableAndCalledOffTriesKeepTheNote", retryableAndCalledOffTriesKeepTheNote),
        ("phaseAndConfirm", phaseAndConfirm),
        ("uploadHeaders", uploadHeaders),
        ("outboxKeepsAndRetries", outboxKeepsAndRetries),
        ("outboxPrunes", outboxPrunes),
        ("outboxFolderPerCopy", outboxFolderPerCopy),
        ("snapshotForThePage", snapshotForThePage),
    ]

    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    static func holdRecordsWhileHeld() throws {
        var gesture = VoiceNoteGesture()
        expectEqual(gesture.press(at: t0, recording: false), .start, "recording starts on the press, at once")
        expect(gesture.holding)
        expectEqual(gesture.release(at: t0.addingTimeInterval(4.2)), .finish, "the release sends")
        expectEqual(gesture.state, .idle)
        // Exactly at the threshold counts as held.
        expectEqual(gesture.press(at: t0.addingTimeInterval(10), recording: false), .start)
        expectEqual(gesture.release(at: t0.addingTimeInterval(10 + VoiceNoteRules.holdThreshold)), .finish)
    }

    static func tapStartsAndTapSends() throws {
        var gesture = VoiceNoteGesture()
        expectEqual(gesture.press(at: t0, recording: false), .start)
        expectEqual(gesture.release(at: t0.addingTimeInterval(0.12)), .none, "a quick tap keeps recording")
        expectEqual(gesture.state, .latched)
        expect(!gesture.holding)
        expectEqual(gesture.press(at: t0.addingTimeInterval(6), recording: true), .finish, "the next press sends")
        expectEqual(gesture.release(at: t0.addingTimeInterval(6.4)), .none, "its release does nothing")
        expectEqual(gesture.state, .idle)
        expectEqual(gesture.press(at: t0.addingTimeInterval(9), recording: false), .start, "and the next one starts again")
    }

    static func aNoteStartedElsewhereIsSentByThePress() throws {
        // The dock's button or the menu started it (a tap): ⌃⌥N sends it.
        var gesture = VoiceNoteGesture()
        expectEqual(gesture.press(at: t0, recording: true), .finish)
        expectEqual(gesture.release(at: t0.addingTimeInterval(2)), .none, "even a long press only sends")
        expectEqual(gesture.state, .idle)
    }

    static func repeatsAndLostReleases() throws {
        var gesture = VoiceNoteGesture()
        _ = gesture.press(at: t0, recording: false)
        expectEqual(gesture.press(at: t0.addingTimeInterval(0.1), recording: true), .none, "the key repeating while held")
        expectEqual(gesture.press(at: t0.addingTimeInterval(0.2), recording: true), .none)
        expectEqual(gesture.release(at: t0.addingTimeInterval(1.5)), .finish, "still a hold")
        // A release that never came: the next real press, a while later, still sends rather than sticking.
        _ = gesture.press(at: t0.addingTimeInterval(5), recording: false)
        expectEqual(gesture.press(at: t0.addingTimeInterval(9), recording: true), .finish)
        expectEqual(gesture.press(at: t0.addingTimeInterval(12), recording: false), .start, "and the one after starts")
    }

    static func endedAnotherWay() throws {
        // The cap or the dock's Send ended a held note: the key's release must not do anything more.
        var gesture = VoiceNoteGesture()
        _ = gesture.press(at: t0, recording: false)
        gesture.ended()
        expectEqual(gesture.release(at: t0.addingTimeInterval(3)), .none)
        expectEqual(gesture.state, .idle)
        // A tapped note sent by a pause: the next press starts a new one.
        _ = gesture.press(at: t0.addingTimeInterval(10), recording: false)
        _ = gesture.release(at: t0.addingTimeInterval(10.1))
        gesture.ended()
        expectEqual(gesture.state, .idle)
        expectEqual(gesture.press(at: t0.addingTimeInterval(20), recording: false), .start)
    }

    static func captureAnswers() throws {
        let received = CaptureStatus.decode(Data(#"{"captureId":"abc","state":"received"}"#.utf8), fallbackId: "x")
        expectEqual(received?.captureId, "abc")
        expectEqual(received?.state, "received")
        expect(received?.settled == false)
        let done = CaptureStatus.decode(Data("""
            {"captureId":"abc","state":"done","heard":"Put this in my journal: shipped the dock",
             "outcome":{"kind":"journal","title":"Journal","detail":"shipped the dock"}}
            """.utf8), fallbackId: "x")
        expectEqual(done?.outcome?.kind, "journal")
        expect(done?.settled == true)
        let note = CaptureStatus.decode(Data("""
            {"state":"needs_you","heard":"call the bank about the card",
             "outcome":{"kind":"note","title":"Saved","noteId":"n1"},
             "suggestion":{"label":"Start it as a T3 task?","action":"task"}}
            """.utf8), fallbackId: "fallback")
        expectEqual(note?.captureId, "fallback", "an answer without its id is ours")
        expectEqual(note?.suggestion, CaptureSuggestion(label: "Start it as a T3 task?", action: "task"))
        expectEqual(note?.outcome?.noteId, "n1")
        // Wrapped, the research draft's route/say shape, an error object, and nonsense.
        let wrapped = CaptureStatus.decode(Data(#"{"capture":{"captureId":"w","state":"DONE","route":{"kind":"t3_task"},"say":"Started it."}}"#.utf8), fallbackId: "x")
        expectEqual(wrapped?.state, "done")
        expectEqual(wrapped?.outcome?.kind, "t3_task")
        expectEqual(wrapped?.say, "Started it.")
        let failed = CaptureStatus.decode(Data(#"{"captureId":"f","state":"failed","error":{"code":"t3_not_connected"}}"#.utf8), fallbackId: "x")
        expectEqual(failed?.error, "t3_not_connected")
        expect(CaptureStatus.decode(Data("[1,2]".utf8), fallbackId: "x") == nil)
    }

    static func outcomeLines() throws {
        func status(_ state: String, _ kind: String? = nil, title: String = "", detail: String = "", heard: String? = nil,
                    suggestion: CaptureSuggestion? = nil) -> CaptureStatus {
            CaptureStatus(captureId: "c", state: state, heard: heard,
                          outcome: kind.map { CaptureOutcome(kind: $0, title: title, detail: detail) }, suggestion: suggestion)
        }
        expectEqual(VoiceNoteText.outcome(status("received")).line, "Sent")
        expectEqual(VoiceNoteText.outcome(status("received")).detail, "Working on it…")
        expectEqual(VoiceNoteText.outcome(status("transcribed")).line, "Sent", "heard, not done yet")
        // The bridge's own outcomes (samrabbit_capture: _journal_outcome, _task_outcome, _event_outcome, _as_note).
        let journal = VoiceNoteText.outcome(status("done", "journal", title: "Journal", detail: "Added to your journal.",
                                                   heard: "Put this in my journal: shipped the dock"))
        expectEqual(journal.line, "Added to your journal")
        expectEqual(journal.detail, "“Put this in my journal: shipped the dock”", "what he said, not the bridge's line again")
        let task = VoiceNoteText.outcome(status("done", "task", title: "Fix the login redirect",
                                                detail: "Started “Fix the login redirect” in SamRabbit."))
        expectEqual(task.line, "Started a T3 task")
        expectEqual(task.detail, "Started “Fix the login redirect” in SamRabbit.")
        expectEqual(VoiceNoteText.outcome(status("done", "t3_task", title: "Fix the login redirect")).detail, "“Fix the login redirect”")
        expectEqual(VoiceNoteText.outcome(status("done", "t3_task")).line, "Started a T3 task")
        let calendar = VoiceNoteText.outcome(status("done", "event", title: "Call the dentist",
                                                    detail: "Added “Call the dentist” for Thu 2:00 PM."))
        expectEqual(calendar.line, "On your calendar")
        expectEqual(calendar.detail, "Added “Call the dentist” for Thu 2:00 PM.")
        expectEqual(VoiceNoteText.outcome(status("done", "calendar_event", title: "Call the dentist")).detail, "Call the dentist")
        let kept = VoiceNoteText.outcome(status("done", "note", title: "the bank", detail: "Saved as a note.", heard: "the bank",
                                                suggestion: CaptureSuggestion(label: "Start it as a T3 task?", action: "task")))
        expectEqual(kept.line, "Saved as a note")
        expectEqual(kept.detail, "Start it as a T3 task?")
        expectEqual(VoiceNoteText.outcome(status("done", "nothing", title: "Nothing heard", detail: "I didn't catch anything.")).line,
                    "Didn’t catch anything")
        expectEqual(VoiceNoteText.outcome(status("no_speech")).line, "Didn’t catch anything")
        expectEqual(VoiceNoteText.outcome(status("failed", nil)).line, "The bridge couldn’t finish it")
        let failed = VoiceNoteText.outcome(status("failed", "failed", title: "Voice note", detail: "Couldn't save it: T3 Code isn't connected."))
        expectEqual(failed.detail, "Couldn't save it: T3 Code isn't connected.")
        // Buttons only for what POST …/captures/<id>/act takes: task, journal, event.
        expectEqual(VoiceNoteText.offer(CaptureSuggestion(label: "Start it as a T3 task?", action: "task")), "Start as task")
        expectEqual(VoiceNoteText.offer(CaptureSuggestion(label: "Add it to your journal?", action: "journal")), "Add to journal")
        expectEqual(VoiceNoteText.offer(CaptureSuggestion(label: "Put it on your calendar for Thu 9:00 AM?", action: "event")),
                    "Put on calendar")
        expectEqual(VoiceNoteText.offer(CaptureSuggestion(label: "Block the time?", action: "block")), nil,
                    "the bridge has no act for a block")
        expectEqual(VoiceNoteText.offer(CaptureSuggestion(label: "Only words", action: "")), nil, "no action, no button")
        expectEqual(VoiceNoteText.actAction("t3_task"), "task")
        expectEqual(VoiceNoteText.actAction("calendar_event"), "event")
        expectEqual(VoiceNoteText.actAction("block"), nil)
        let long = VoiceNoteText.outcome(status("done", "journal", heard: String(repeating: "word ", count: 60)))
        expect(long.detail.count <= 92, "a long transcript is clipped (\(long.detail.count))")
    }

    static func deliveryByStatus() throws {
        let id = "8b9f5f8e-4c1e-4a0b-9a51-3c2b1e0d9f88"
        func error(_ code: String) -> Data { Data(#"{"error":{"code":"\#(code)","message":"x"}}"#.utf8) }
        if case .delivered(let status) = VoiceNoteDelivery.classify(status: 202, body: Data(#"{"captureId":"\#(id)","state":"received"}"#.utf8), captureId: id) {
            expectEqual(status.state, "received")
        } else {
            expect(false, "202 is delivered")
        }
        if case .delivered(let status) = VoiceNoteDelivery.classify(status: 200, body: Data(), captureId: id) {
            expectEqual(status.captureId, id, "an empty 200 still means the bridge has it")
        } else {
            expect(false, "200 is delivered")
        }
        for status in [0, -1, 401, 403, 404, 405, 429, 500, 503] {
            if case .keep = VoiceNoteDelivery.classify(status: status, body: Data(), captureId: id) {} else {
                expect(false, "HTTP \(status) keeps the note for later")
            }
        }
        for (status, code) in [(413, "body_too_large"), (400, "audio_too_long"), (415, "unsupported_audio"), (409, "capture_conflict"),
                               (422, "no_speech"), (400, "invalid_capture_id")] {
            if case .drop = VoiceNoteDelivery.classify(status: status, body: error(code), captureId: id) {} else {
                expect(false, "HTTP \(status) \(code) is never retried")
            }
        }
        expectEqual(VoiceNoteDelivery.classify(status: 404, body: Data(), captureId: id), .keep("The bridge needs an update for voice notes"))
    }

    /// A 400 the bridge marks retryable (samrabbit_capture: "The recording did not arrive completely", a stalled
    /// upload) keeps the WAV; so does a 4xx it doesn't name. A try this Mac called off is no try at all.
    static func retryableAndCalledOffTriesKeepTheNote() throws {
        let id = "8b9f5f8e-4c1e-4a0b-9a51-3c2b1e0d9f88"
        func error(_ code: String, retryable: Bool) -> Data {
            Data(#"{"error":{"code":"\#(code)","message":"x","retryable":\#(retryable)}}"#.utf8)
        }
        expectEqual(VoiceNoteDelivery.classify(status: 400, body: error("invalid_audio", retryable: true), captureId: id),
                    .keep("The recording didn’t reach the bridge whole"), "a body that didn't arrive whole: sent again")
        if case .drop = VoiceNoteDelivery.classify(status: 400, body: error("invalid_audio", retryable: false), captureId: id) {} else {
            expect(false, "an empty or unreadable body (not retryable) is dropped")
        }
        if case .keep = VoiceNoteDelivery.classify(status: 409, body: error("capture_busy", retryable: true), captureId: id) {} else {
            expect(false, "a retryable 409 keeps it")
        }
        if case .keep = VoiceNoteDelivery.classify(status: 400, body: error("invalid_captured_at", retryable: false), captureId: id) {} else {
            expect(false, "a 400 the Mac doesn't know is not a reason to lose the note")
        }
        if case .drop = VoiceNoteDelivery.classify(status: 400, body: error("audio_too_long", retryable: false), captureId: id) {} else {
            expect(false, "too long stays dropped")
        }
        expectEqual(VoiceNoteDelivery.failure(URLError(.cancelled)), .cancelled, "URLSession's cancelled")
        expectEqual(VoiceNoteDelivery.failure(CancellationError()), .cancelled, "a cancelled task")
        expectEqual(VoiceNoteDelivery.failure(URLError(.cannotConnectToHost)), .keep("The bridge isn’t running"))
        expectEqual(VoiceNoteDelivery.failure(URLError(.timedOut)), .keep("The bridge isn’t running"))
    }

    /// How the bar marks an outcome, and the suggestion button's second-click label.
    static func phaseAndConfirm() throws {
        func status(_ state: String, _ kind: String?) -> CaptureStatus {
            CaptureStatus(captureId: "c", state: state, heard: nil, outcome: kind.map { CaptureOutcome(kind: $0, title: "", detail: "") })
        }
        expectEqual(VoiceNoteText.phase(status("done", "journal")), .sent)
        expectEqual(VoiceNoteText.phase(status("done", "note")), .sent)
        expectEqual(VoiceNoteText.phase(status("done", "nothing")), .discarded, "nothing heard is no green check")
        expectEqual(VoiceNoteText.phase(status("no_speech", nil)), .discarded)
        expectEqual(VoiceNoteText.phase(status("failed", "failed")), .failed)
        expectEqual(VoiceNoteText.phase(status("failed", nil)), .failed)
        expectEqual(VoiceNoteText.confirm("task"), "Yes, start the task")
        expectEqual(VoiceNoteText.confirm("t3_task"), "Yes, start the task")
        expectEqual(VoiceNoteText.confirm("journal"), "Yes, add to journal")
        expectEqual(VoiceNoteText.confirm("event"), "Yes, put on calendar")
        var snapshot = VoiceNoteSnapshot()
        snapshot.offer = "Yes, add to journal"
        snapshot.offerArmed = true
        expectEqual(snapshot.json["offerArmed"] as? Bool, true)
    }

    static func uploadHeaders() throws {
        let newYork = TimeZone(identifier: "America/New_York")!
        let at = ISO8601DateFormatter().date(from: "2026-10-14T13:41:07Z")!
        let headers = VoiceNoteUpload.headers(captureId: "8b9f5f8e-4c1e-4a0b-9a51-3c2b1e0d9f88", capturedAt: at, timeZone: newYork)
        expectEqual(headers["X-SamRabbit-Captured-At"], "2026-10-14T09:41:07-04:00", "local time with its offset")
        expectEqual(headers["X-SamRabbit-Source"], "mac")
        expectEqual(headers["X-SamRabbit-Capture"], "8b9f5f8e-4c1e-4a0b-9a51-3c2b1e0d9f88")
        expectEqual(headers["Content-Type"], "audio/wav")
        let id = VoiceNoteUpload.newId()
        expect(VoiceNoteUpload.isCaptureId(id), "a new id is a UUID")
        expectEqual(id, id.lowercased())
        for bad in ["", "../etc/passwd", "8b9f5f8e-4c1e-4a0b-9a51-3c2b1e0d9f8", "not-a-uuid-at-all-but-36-characters!!"] {
            expect(!VoiceNoteUpload.isCaptureId(bad), "\(bad) is not an id")
        }
    }

    static func temporaryOutbox() throws -> VoiceNoteOutbox {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("voice-note-tests-\(UUID().uuidString)/outbox")
        return VoiceNoteOutbox(directory: folder)
    }

    static func item(_ id: String, created: Date, next: Date? = nil) -> VoiceNoteOutbox.Item {
        VoiceNoteOutbox.Item(captureId: id, capturedAt: created, createdAt: created, seconds: 3.5, nextAt: next ?? created)
    }

    static func outboxKeepsAndRetries() throws {
        let outbox = try temporaryOutbox()
        defer { try? FileManager.default.removeItem(at: outbox.directory.deletingLastPathComponent()) }
        expectEqual(outbox.items(), [], "nothing yet (and no folder)")
        let a = VoiceNoteUpload.newId(), b = VoiceNoteUpload.newId()
        try outbox.add(item(a, created: t0), wav: Data("RIFFa".utf8))
        try outbox.add(item(b, created: t0.addingTimeInterval(1)), wav: Data("RIFFb".utf8))
        expectEqual(outbox.items().map(\.captureId), [a, b], "oldest first")
        expectEqual(outbox.wav(a), Data("RIFFa".utf8))
        let attributes = try FileManager.default.attributesOfItem(atPath: outbox.directory.appendingPathComponent("\(a).wav").path)
        expectEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600, "the audio is private")
        let folder = try FileManager.default.attributesOfItem(atPath: outbox.directory.path)
        expectEqual((folder[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        // A try that didn't reach the bridge waits 5 s, then 30 s, 2 min and 10 min.
        var first = outbox.items()[0]
        first = VoiceNoteOutbox.failed(first, why: "The bridge isn’t running", now: t0)
        outbox.update(first)
        expectEqual(outbox.items()[0].attempts, 1)
        expectEqual(outbox.items()[0].nextAt, t0.addingTimeInterval(5))
        expectEqual(outbox.due(now: t0.addingTimeInterval(4)).map(\.captureId), [b], "a is not due yet")
        expectEqual(outbox.nextDue(), t0.addingTimeInterval(1), "b is due since it was made")
        var later = first
        for _ in 0..<5 { later = VoiceNoteOutbox.failed(later, why: "x", now: t0) }
        expectEqual(later.nextAt, t0.addingTimeInterval(600), "every 10 minutes at worst")
        expectEqual(VoiceNoteRules.retryDelay(attempts: 2), 30)
        // Delivered: gone, audio and record.
        outbox.remove(a)
        expectEqual(outbox.items().map(\.captureId), [b])
        expect(outbox.wav(a) == nil)
        // Never a path outside the folder.
        outbox.remove("../outbox")
        expect(outbox.wav("../\(b)") == nil)
        do {
            try outbox.add(item("../escape", created: t0), wav: Data())
            expect(false, "a bad id is refused")
        } catch {}
        // A record whose audio is gone is not a note.
        try FileManager.default.removeItem(at: outbox.directory.appendingPathComponent("\(b).wav"))
        expectEqual(outbox.items(), [])
    }

    static func outboxPrunes() throws {
        let outbox = try temporaryOutbox()
        defer { try? FileManager.default.removeItem(at: outbox.directory.deletingLastPathComponent()) }
        let old = VoiceNoteUpload.newId()
        try outbox.add(item(old, created: t0.addingTimeInterval(-8 * 86_400)), wav: Data([1]))
        var ids: [String] = []
        for index in 0..<(VoiceNoteRules.outboxLimit + 2) {
            let id = VoiceNoteUpload.newId()
            ids.append(id)
            try outbox.add(item(id, created: t0.addingTimeInterval(Double(index))), wav: Data([2]))
        }
        let dropped = outbox.prune(now: t0.addingTimeInterval(100))
        expect(dropped.contains(old), "older than a week")
        expect(dropped.contains(ids[0]) && dropped.contains(ids[1]), "the oldest beyond 50")
        expectEqual(outbox.items().count, VoiceNoteRules.outboxLimit)
        expectEqual(outbox.items().first?.captureId, ids[2])
    }

    static func outboxFolderPerCopy() throws {
        let support = URL(fileURLWithPath: "/Users/x/Library/Application Support")
        expectEqual(VoiceNoteOutbox.defaultDirectory(bundleId: "com.samrabbit.desktop", environment: [:], support: support).path,
                    "/Users/x/Library/Application Support/SamRabbit/capture-outbox")
        expectEqual(VoiceNoteOutbox.defaultDirectory(bundleId: "com.samrabbit.desktop.notedev", environment: [:], support: support).path,
                    "/Users/x/Library/Application Support/SamRabbit/capture-outbox-com.samrabbit.desktop.notedev",
                    "a development copy never shares the installed app's outbox")
        expectEqual(VoiceNoteOutbox.defaultDirectory(bundleId: "../x y", environment: [:], support: support).lastPathComponent,
                    "capture-outbox-.._x_y")
        expectEqual(VoiceNoteOutbox.defaultDirectory(bundleId: nil, environment: [:], support: support).lastPathComponent,
                    "capture-outbox-unbundled", "a harness without a bundle id neither")
        expectEqual(VoiceNoteOutbox.defaultDirectory(bundleId: nil, environment: ["SAMRABBIT_CAPTURE_OUTBOX": "/tmp/o"], support: support).path,
                    "/tmp/o")
    }

    static func snapshotForThePage() throws {
        var snapshot = VoiceNoteSnapshot()
        expectEqual(snapshot.json["state"] as? String, "idle")
        snapshot.phase = .recording(held: true)
        snapshot.startedAt = t0
        snapshot.waiting = 2
        let json = snapshot.json
        expectEqual(json["state"] as? String, "recording")
        expectEqual(json["held"] as? Bool, true)
        expectEqual(json["startedAt"] as? Double, 1_800_000_000_000)
        expectEqual(json["waiting"] as? Int, 2)
        expect(JSONSerialization.isValidJSONObject(json))
        expect(snapshot.recording && snapshot.active)
    }
}
