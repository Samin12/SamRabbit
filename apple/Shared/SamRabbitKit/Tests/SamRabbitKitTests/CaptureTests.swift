import Foundation
import Testing
@testable import SamRabbitKit

/// Voice notes (CONTRACTS-WAVE8 §A2, §C2–3): the request's headers, the Mac's answers (the contract's words and the
/// steps in between, read leniently), what each outcome shows, the outbox (durable, idempotent, backoff, pruning), the
/// links (only the app's own intents start the microphone) and the watch's relay chunks.
@Suite("Voice notes")
struct CaptureTests {
    // MARK: - The request

    @Test func theHeadersCarryTheIdTheTimeWithItsOffsetAndTheSource() throws {
        let at = Date(timeIntervalSince1970: 1_791_984_067) // 2026-10-14 13:21:07 UTC
        let meta = CaptureMeta(captureId: "0d196ba8-190f-4ee5-b248-0f2c76bf13a8", capturedAt: at, source: .watch,
                               language: "en-US", seconds: 4.2)
        #expect(meta.headers["X-SamRabbit-Capture"] == "0d196ba8-190f-4ee5-b248-0f2c76bf13a8")
        #expect(meta.headers["X-SamRabbit-Source"] == "watch")
        let newYork = try #require(TimeZone(identifier: "America/New_York"))
        #expect(CaptureMeta.header(at, timeZone: newYork) == "2026-10-14T09:21:07-04:00")
        #expect(CaptureMeta.header(at, timeZone: .gmt) == "2026-10-14T13:21:07Z")
        #expect(BridgeDates.date(from: meta.capturedAtHeader) == at)
        let client = BridgeClient(hosts: [BridgeHost(host: "10.0.0.2", port: 3780)], token: "t")
        let request = client.captureRequest(meta, wait: 30)
        #expect(request.path == "/v1/mobile/capture")
        #expect(request.method == "POST")
        #expect(request.contentType == "audio/mp4")
        #expect(request.idempotent == true)
        #expect(request.query.contains(URLQueryItem(name: "wait", value: "10"))) // at most 10 s
        #expect(request.query.contains(URLQueryItem(name: "lang", value: "en-US")))
        let urlRequest = try #require(client.captureUploadRequest(meta))
        #expect(urlRequest.url?.absoluteString.hasPrefix("http://10.0.0.2:3780/v1/mobile/capture") == true)
        #expect(urlRequest.value(forHTTPHeaderField: "Authorization") == "Bearer t")
        #expect(urlRequest.value(forHTTPHeaderField: "X-SamRabbit-Captured-At") == meta.capturedAtHeader)
        #expect(urlRequest.value(forHTTPHeaderField: "Content-Type") == "audio/mp4")
        let desktop = BridgeClient(hosts: [BridgeHost(host: "127.0.0.1", port: 3780)], token: "d", api: .desktop)
        #expect(desktop.captureRequest(meta).path == "/v1/desktop/capture")
    }

    @Test func onlyUUIDsAreCaptureIds() {
        #expect(CaptureMeta.isValid(UUID().uuidString))
        #expect(CaptureMeta.isValid(CaptureMeta(source: .iphone).captureId))
        #expect(!CaptureMeta.isValid("note-1"))
        #expect(!CaptureMeta.isValid("../../etc"))
    }

    // MARK: - The Mac's answers

    @Test func theAnswersReadTheContractsWordsAndTheStepsBetween() throws {
        func status(_ json: String) throws -> CaptureStatus { try BridgeJSON.decode(CaptureStatus.self, from: Data(json.utf8)) }
        #expect(try status(#"{"captureId":"a","state":"received"}"#).state == .received)
        #expect(try status(#"{"captureId":"a","state":"transcribing"}"#).state == .received)
        #expect(try status(#"{"captureId":"a","state":"routing"}"#).state == .transcribed)
        #expect(try status(#"{"captureId":"a","state":"needs_you"}"#).state == .done)
        #expect(try status(#"{"captureId":"a","state":"no_speech"}"#).state == .failed)
        #expect(try status(#"{"id":"a","state":"teleporting"}"#).state == .received)
        let done = try status("""
        {"captureId":"c1","state":"done","heard":"Put this in my journal: the walk was great",
         "outcome":{"kind":"journal","title":"Today's journal","detail":"“the walk was great”"},
         "updatedAt":"2026-10-14T13:21:09Z"}
        """)
        #expect(done.outcome?.kind == .journal)
        #expect(done.notice.line == "Sent ✓ — Added to your journal · Today's journal · “the walk was great”")
        let task = try status(#"{"captureId":"c2","state":"done","outcome":{"kind":"t3_task","title":"Fix login","detail":"Website","threadId":"t_9"}}"#)
        #expect(task.outcome?.kind == .task)
        #expect(task.outcome?.threadId == "t_9")
        #expect(task.notice.title == "Started a T3 task")
        #expect(task.notice.detail == "Fix login · Website")
        let note = try status("""
        {"captureId":"c3","state":"done","heard":"look at pricing tonight","outcome":{"kind":"note"},
         "suggestion":{"action":"task","label":"Start it as a T3 task?"}}
        """)
        #expect(note.notice.title == "Saved as a note")
        #expect(note.notice.detail == "Start it as a T3 task? It's in Tasks.")
        #expect(note.suggestion?.buttonTitle == "Start task")
        let word = try status(#"{"captureId":"c4","state":"done","outcome":{"kind":"note"},"suggestion":"journal"}"#)
        #expect(word.suggestion == CaptureSuggestion(action: "journal", label: "Add it to your journal?"))
        let failed = try status(#"{"captureId":"c5","state":"failed","error":{"code":"no_speech","message":"…"}}"#)
        #expect(failed.error == "no_speech")
        #expect(failed.notice.tone == .failed)
        #expect(failed.notice.title == "I didn't catch anything")
        let waiting = try status(#"{"captureId":"c6","state":"transcribed","heard":"hi"}"#)
        #expect(waiting.notice == CaptureNotice(tone: .sent, title: "Sent", detail: "Your Mac is on it.", symbol: "checkmark"))
        #expect(waiting.notice.line == "Sent ✓ · Your Mac is on it.")
        // An action's answer may wrap the note.
        #expect(try status(#"{"ok":true,"capture":{"captureId":"c7","state":"done"}}"#).captureId == "c7")
        #expect(CaptureNotice.queued(waiting: 3).detail == "3 notes will go when your Mac is reachable.")
    }

    @Test func aListAndTheSummaryPart() throws {
        let list = try BridgeJSON.decode(CaptureList.self, from: Data("""
        {"captures":[{"captureId":"a","state":"done"},{"nope":true},{"captureId":"b","state":"received"}]}
        """.utf8))
        #expect(list.captures.map(\.captureId) == ["a", "b"])
        let summary = try BridgeJSON.decode(MobileSummary.self, from: Data(#"{"captures":{"recent":[1,2,3],"failed":1}}"#.utf8))
        #expect(summary.captures == CapturesOverview(recent: 3, failed: 1))
        #expect(try BridgeJSON.decode(MobileSummary.self, from: Data("{}".utf8)).captures == nil)
    }

    // MARK: - The outbox

    @Test func theOutboxKeepsANoteUntilTheMacHasIt() throws {
        let outbox = CaptureOutbox.temporary()
        defer { try? FileManager.default.removeItem(at: outbox.folder) }
        let meta = CaptureMeta(capturedAt: Date(timeIntervalSince1970: 1_000), source: .iphone, seconds: 3)
        let recording = try Self.recording()
        let entry = try outbox.add(recording: recording, meta: meta)
        #expect(entry.state == .waiting)
        #expect(!FileManager.default.fileExists(atPath: recording.path), "moved in")
        #expect(FileManager.default.fileExists(atPath: outbox.audioURL(meta.captureId).path))
        #expect(outbox.waiting == 1)
        #expect(outbox.due(now: Date(timeIntervalSince1970: 1_001)).map(\.id) == [meta.captureId])

        // The same note again (a retry that recorded nothing new) changes nothing.
        _ = try outbox.add(recording: try Self.recording(), meta: meta)
        #expect(outbox.entries().count == 1)

        // Out of reach: tried again after 5 s, then 30 s, 2 min, 10 min...
        let now = Date(timeIntervalSince1970: 2_000)
        outbox.failed(meta.captureId, error: "unreachable", retryable: true, now: now)
        #expect(outbox.due(now: now).isEmpty)
        #expect(outbox.nextDue(now: now) == now.addingTimeInterval(5))
        #expect(outbox.due(now: now.addingTimeInterval(5)).count == 1)
        outbox.failed(meta.captureId, error: "unreachable", retryable: true, now: now)
        #expect(outbox.entry(meta.captureId)?.nextAttemptAt == now.addingTimeInterval(30))
        #expect(CaptureOutbox.backoff(after: 3) == 120)
        #expect(CaptureOutbox.backoff(after: 9) == 600)
        // The Mac is back: everything goes now.
        outbox.retryNow()
        #expect(outbox.due(now: now).count == 1)

        // Received: the recording goes, the answer stays.
        let received = CaptureStatus(captureId: meta.captureId, state: .received)
        outbox.delivered(meta.captureId, status: received, now: now)
        #expect(outbox.waiting == 0)
        #expect(!FileManager.default.fileExists(atPath: outbox.audioURL(meta.captureId).path))
        let done = CaptureStatus(captureId: meta.captureId, state: .done, outcome: CaptureOutcome(kind: .journal))
        outbox.record(done)
        #expect(outbox.entry(meta.captureId)?.status?.state == .done)
        #expect(outbox.entry(meta.captureId)?.state == .sent)
    }

    @Test func aRefusalThatCantChangeEndsIt() throws {
        let outbox = CaptureOutbox.temporary()
        defer { try? FileManager.default.removeItem(at: outbox.folder) }
        let meta = CaptureMeta(source: .iphone)
        try outbox.add(recording: try Self.recording(), meta: meta)
        outbox.failed(meta.captureId, error: "audio_too_long", retryable: false)
        #expect(outbox.entry(meta.captureId)?.state == .failed)
        #expect(outbox.waiting == 0)
        #expect(!FileManager.default.fileExists(atPath: outbox.audioURL(meta.captureId).path))
    }

    @Test func pruningDropsOldNotesStrayFilesAndTheExcess() throws {
        let outbox = CaptureOutbox.temporary()
        defer { try? FileManager.default.removeItem(at: outbox.folder) }
        let now = Date(timeIntervalSince1970: 10_000_000)
        let old = CaptureMeta(capturedAt: now.addingTimeInterval(-8 * 86_400), source: .iphone)
        let fresh = CaptureMeta(capturedAt: now.addingTimeInterval(-60), source: .iphone)
        let sent = CaptureMeta(capturedAt: now.addingTimeInterval(-3 * 86_400), source: .watch)
        try outbox.add(recording: try Self.recording(), meta: old)
        try outbox.add(recording: try Self.recording(), meta: fresh)
        try outbox.add(recording: try Self.recording(), meta: sent)
        outbox.delivered(sent.captureId, status: nil, now: now.addingTimeInterval(-2 * 86_400))
        // A recording whose entry never got written (a crash between the two).
        try Data("stray".utf8).write(to: outbox.audioURL(UUID().uuidString.lowercased()))
        #expect(outbox.prune(now: now) == 3)
        #expect(outbox.entries().map(\.id) == [fresh.captureId])
        let names = try FileManager.default.contentsOfDirectory(atPath: outbox.folder.path).sorted()
        #expect(names == ["\(fresh.captureId).json", "\(fresh.captureId).m4a"].sorted())

        // At most 50: the oldest go, settled ones first.
        for index in 0..<CaptureOutbox.maxEntries {
            let meta = CaptureMeta(capturedAt: now.addingTimeInterval(TimeInterval(index)), source: .iphone)
            try outbox.add(recording: try Self.recording(), meta: meta)
            if index < 3 { outbox.delivered(meta.captureId, status: nil, now: now) }
        }
        #expect(outbox.entries().count == CaptureOutbox.maxEntries + 1)
        #expect(outbox.prune(now: now) == 1)
        #expect(outbox.entries().count == CaptureOutbox.maxEntries)
        #expect(outbox.entries().filter { $0.state == .sent }.count == 2, "a settled one went first")
        #expect(outbox.entry(fresh.captureId) != nil, "the oldest waiting note stays")
    }

    @Test func theWatchHandsANoteToThePhone() throws {
        let outbox = CaptureOutbox.temporary()
        defer { try? FileManager.default.removeItem(at: outbox.folder) }
        let meta = CaptureMeta(source: .watch)
        try outbox.add(recording: try Self.recording(), meta: meta)
        outbox.handedOff(meta.captureId)
        #expect(outbox.entry(meta.captureId)?.state == .handedOff)
        #expect(outbox.waiting == 0)
        // The phone keeps what it got from the watch as the watch's (sent with the watch's token).
        let phone = CaptureOutbox.temporary()
        defer { try? FileManager.default.removeItem(at: phone.folder) }
        let entry = try phone.add(recording: try Self.recording(), meta: meta, relayedFor: .watch)
        #expect(entry.relayedFor == .watch)
        #expect(entry.meta.source == .watch)
    }

    @Test func anEntrySurvivesTheRoundTrip() throws {
        let meta = CaptureMeta(capturedAt: Date(timeIntervalSince1970: 1_791_984_067.25), source: .iphone, seconds: 12.5)
        let entry = CaptureOutbox.Entry(meta: meta, attempts: 2, lastError: "unreachable",
                                        status: CaptureStatus(captureId: meta.captureId, state: .done,
                                                              outcome: CaptureOutcome(kind: .task, title: "Fix it"),
                                                              suggestion: CaptureSuggestion(action: "task", label: "Go?")))
        let again = try BridgeJSON.decode(CaptureOutbox.Entry.self, from: BridgeJSON.encoder().encode(entry))
        #expect(again == entry)
    }

    // MARK: - Links and routes

    @Test func onlyTheAppsOwnIntentsStartTheMicrophone() throws {
        let url = try #require(URL(string: PendingRoute.capture))
        #expect(AppLink(url: url, fromApp: true) == .capture(record: true))
        #expect(AppLink(url: url) == .capture(record: false), "a link from a page opens the recorder, waiting")
        #expect(AppLink(url: try #require(URL(string: "samrabbit://note/voice"))) == .capture(record: false))
        #expect(AppLink(url: try #require(URL(string: "samrabbit://voicenote")), fromApp: true) == .capture(record: true))
        #expect(AppLink(url: try #require(URL(string: "samrabbit://brief/bi_dana"))) == .briefing("bi_dana"))
        #expect(AppLink(url: try #require(URL(string: "samrabbit://morning"))) == .briefing(nil))
        // The journal composer is untouched.
        #expect(AppLink(url: try #require(URL(string: "samrabbit://note"))) == .compose(.note, listen: false))
    }

    @Test func aRouteLeftByTheIntentIsTakenOnce() throws {
        let defaults = try #require(UserDefaults(suiteName: "capture-route-\(UUID().uuidString)"))
        PendingRoute.set(PendingRoute.capture, in: defaults)
        #expect(PendingRoute.take(from: defaults)?.absoluteString == "samrabbit://capture")
        #expect(PendingRoute.take(from: defaults) == nil)
    }

    @Test func theRecorderHoldsTheSessionLikeTheOthers() {
        var claims = AudioSessionClaims()
        claims.claim(.conversation)
        claims.claim(.capture)
        let first = claims.release(.capture)
        #expect(!first, "Talk still holds it")
        let last = claims.release(.conversation)
        #expect(last)
    }

    // MARK: - The watch's relay

    @Test func aNoteThroughTheIPhoneKeepsItsIdTimeAndSource() throws {
        let meta = CaptureMeta(capturedAt: Date(timeIntervalSince1970: 1_791_984_067), source: .watch, seconds: 7)
        let audio = Data(repeating: 7, count: 90_000)
        let chunks = VoiceRelay.chunks(of: audio, id: meta.captureId, purpose: VoiceRelay.capturePurpose, capture: meta)
        #expect(chunks.count == 3)
        let assembler = VoiceRelay.Assembler()
        var upload: VoiceRelay.Upload?
        for chunk in chunks.reversed() {
            let decoded = try #require(VoiceRelay.Chunk(message: chunk.message))
            #expect(decoded.capture == meta)
            if case .complete(let whole) = assembler.add(decoded) { upload = whole }
        }
        #expect(upload?.data == audio)
        #expect(upload?.purpose == VoiceRelay.capturePurpose)
        #expect(upload?.capture == meta)
        // Handed over with `transferFile` instead: the same meta in its metadata.
        #expect(CaptureMeta(transferMetadata: meta.transferMetadata) == meta)
        #expect(CaptureMeta(transferMetadata: ["other": 1]) == nil)
        // A chunk from an older watch (no capture part) still reads.
        let plain = VoiceRelay.chunks(of: Data([1, 2, 3]), purpose: nil)[0]
        #expect(VoiceRelay.Chunk(message: plain.message)?.capture == nil)
    }

    @Test func theWatchRelaysWhatBecameOfANoteAndTheBrief() {
        func allowed(_ method: String, _ path: String) -> Bool {
            WatchRelay.Request(BridgeRequest(method: method, path: path)).allowed
        }
        #expect(allowed("GET", "/v1/mobile/capture/0d196ba8-190f-4ee5-b248-0f2c76bf13a8"))
        #expect(allowed("GET", "/v1/mobile/briefing"))
        #expect(allowed("POST", "/v1/mobile/briefing/items/bi_dana/act"))
        #expect(allowed("POST", "/v1/mobile/captures/abc/act"))
        #expect(!allowed("POST", "/v1/mobile/unpair"))
    }

    // MARK: - Helpers

    static func recording() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("voice-\(UUID().uuidString).m4a")
        try Data(repeating: 1, count: 2_048).write(to: url)
        return url
    }
}
