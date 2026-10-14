#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import SamRabbitKit

/// The watch's voice-note relay, like `PhoneLink` + `WatchLink`: the note in chunks through the `sendMessage`
/// dictionaries, put together by the phone's `VoiceRelay.Assembler`, uploaded with the watch's own token.
final class PhoneCaptureRelay: BridgeRelay, @unchecked Sendable {
    let phone: BridgeAccount
    let down: Bool
    let chunks = Mutex(0)

    init(phone: BridgeAccount, down: Bool = false) {
        self.phone = phone
        self.down = down
    }

    var prefersRelay: Bool { false }
    func noteDirectRoute(worked: Bool) {}

    func relay(_ request: BridgeRequest) async throws -> (status: Int, body: Data) {
        let answer = await phone.performRelayed(WatchRelay.Request(request))
        return (answer.status, answer.body)
    }

    func relayCapture(_ audio: Data, meta: CaptureMeta) async throws -> (status: Int, body: Data) {
        if down { throw BridgeError.unreachable("phone not reachable") }
        let assembler = VoiceRelay.Assembler()
        for chunk in VoiceRelay.chunks(of: audio, id: meta.captureId, contentType: meta.contentType,
                                       purpose: VoiceRelay.capturePurpose, capture: meta) {
            guard let received = VoiceRelay.Chunk(message: chunk.message) else { return (400, Data()) }
            chunks.withLock { $0 += 1 }
            switch assembler.add(received) {
            case .waiting: continue
            case .refused(let response): return (response.status, response.body)
            case .complete(let upload):
                let answer = await phone.performRelayedCapture(upload)
                return (answer.status, answer.body)
            }
        }
        return (0, Data())
    }
}

/// Voice notes and the morning brief against `apple/dev/fake_bridge.py` (CONTRACTS-WAVE8): the upload as the bridge
/// sees it (headers, the file's bytes), the same note sent twice, what became of it, its suggestion done by a tap,
/// the note in the inbox, the Mac out of reach, the watch's note through the iPhone, the brief and its verbs, and
/// the assistant's cancel naming its turn.
@Suite("Voice notes and the brief against the fake bridge", .serialized)
struct CaptureBridgeTests {
    @Test func aNoteReachesTheMacAndIsAddedToTheJournal() async throws {
        let bridge = try FakeBridgeProcess()
        let (client, _) = try await bridge.pairedClient()
        try await bridge.control("capture", ["heard": "Put this in my journal: the walk by the river was great",
                                             "delay": 0.4])
        let file = try VoiceClip.make(seconds: 1.5)
        defer { try? FileManager.default.removeItem(at: file) }
        let meta = CaptureMeta(source: .iphone, language: "en-US", seconds: 1.5)
        let first = try await client.capture(file: file, meta: meta)
        #expect(first.captureId == meta.captureId)
        #expect(first.state == .received)
        let done = try await waitSettled(client, meta.captureId)
        #expect(done.state == .done)
        #expect(done.outcome?.kind == .journal)
        #expect(done.notice.title == "Added to your journal")
        let lines = try await fakeGet(bridge, "journal")["lines"].array?.compactMap(\.string) ?? []
        #expect(lines.last?.hasSuffix(" the walk by the river was great") == true, "his words after the cue, verbatim")

        let log = try await fakeGet(bridge, "capture")
        let upload = try #require(log["uploads"].array?.last)
        #expect(upload["captureId"].string == meta.captureId)
        #expect(upload["source"].string == "iphone")
        #expect(upload["kind"].string == "mp4")
        #expect(upload["contentType"].string == "audio/mp4")
        #expect(upload["bytes"].int == (try Data(contentsOf: file)).count)
        #expect(upload["capturedAt"].string == meta.capturedAtHeader)
        #expect(upload["lang"].string == "en-US")
        #expect(upload["platform"].string == "ios")

        // The same note again (a retry after a timeout) is the same note; other bytes under its id are refused.
        let again = try await client.capture(file: file, meta: meta)
        #expect(again.state == .done)
        #expect(try await fakeGet(bridge, "capture")["captures"].array?.count == 1)
        let other = try VoiceClip.make(seconds: 0.8)
        defer { try? FileManager.default.removeItem(at: other) }
        await #expect(throws: BridgeError.self) { _ = try await client.capture(file: other, meta: meta) }
        do {
            _ = try await client.capture(file: other, meta: meta)
        } catch let error as BridgeError {
            #expect(error.code == "capture_conflict")
        }
        #expect(try await client.captures().map(\.captureId) == [meta.captureId])
        let summary = try await client.summary()
        let part = try #require(summary.captures)
        #expect(part.recent.map(\.captureId) == [meta.captureId])
        #expect(part.recent.first?.kind == .journal)
        #expect(part.recent.first?.say == "Added to your journal.")
        #expect(part.latest()?.captureId == meta.captureId)
        #expect(part.failed == 0 && part.pending == 0 && part.notes == 0)
    }

    @Test func aNoteItCouldOnlySaveWaitsInTheInboxWithItsSuggestion() async throws {
        let bridge = try FakeBridgeProcess()
        let (client, _) = try await bridge.pairedClient()
        try await bridge.control("capture", ["heard": "Look at the pricing page tonight", "delay": 0.3])
        let file = try VoiceClip.make(seconds: 1)
        defer { try? FileManager.default.removeItem(at: file) }
        let meta = CaptureMeta(source: .iphone)
        _ = try await client.capture(file: file, meta: meta, wait: 5)
        let done = try await waitSettled(client, meta.captureId)
        #expect(done.outcome?.kind == .note)
        #expect(done.suggestion?.action == "task")

        let inbox = try await client.inbox()
        let note = try #require(inbox.items.first { $0.id == "note:\(meta.captureId)" })
        #expect(note.source == .note)
        #expect(note.status == .needsInput)
        #expect(note.needsYou)
        #expect(note.suggestion?.label == "Start it as a T3 task?")
        #expect(note.supports(.act) && note.supports(.dismiss) && note.supports(.seen))
        #expect(note.summary == "Look at the pricing page tonight")
        #expect(inbox.agentItems.contains { $0.id == note.id }, "Tasks lists it")

        // His tap: it becomes a T3 task with his words.
        let acted = try #require(try await client.captureAct(meta.captureId, action: "task"))
        #expect(acted.outcome?.kind == .task)
        #expect(acted.outcome?.threadId != nil)
        #expect(acted.notice.title == "Started a T3 task")
        #expect(acted.notice.detail?.hasPrefix("Started “Look at the pricing page tonight”") == true)
        #expect(try await client.inbox().items.contains { $0.id == note.id } == false)
        #expect(try await fakeGet(bridge, "capture")["acts"].array?.last?["action"].string == "task")
        #expect(try await client.summary().captures?.notes == 0)
    }

    /// The inbox's own route for a note (`POST /inbox/items/note:<id>/act`, with the suggestion or `{action}`),
    /// answered `{ok, capture}` like the real bridge.
    @Test func theInboxDoesANotesSuggestion() async throws {
        let bridge = try FakeBridgeProcess()
        let (client, _) = try await bridge.pairedClient()
        try await bridge.control("capture", ["heard": "Ask Dana about the deck", "delay": 0.2])
        let file = try VoiceClip.make(seconds: 1)
        defer { try? FileManager.default.removeItem(at: file) }
        let meta = CaptureMeta(source: .iphone)
        _ = try await client.capture(file: file, meta: meta, wait: 5)
        #expect(try await client.summary().captures?.notes == 1)
        let body = try await client.data(.post(BridgeClient.inboxPath("note:\(meta.captureId)", "act"), body: [:]))
        let status = try BridgeJSON.decode(CaptureStatus.self, from: body)
        #expect(status.outcome?.kind == .task, "its suggestion")
        // A journal line can't be taken back from here; a note made into an event can.
        do {
            _ = try await client.captureAct(meta.captureId, action: "undo")
            Issue.record("a task is stopped in Tasks")
        } catch let error as BridgeError {
            #expect(error.code == "cannot_undo")
        }
        let event = try #require(try await client.captureAct(meta.captureId, action: "note"))
        #expect(event.outcome?.kind == .note)
        do {
            _ = try await client.captureAct(meta.captureId, action: "event")
            Issue.record("an event needs a time")
        } catch let error as BridgeError {
            #expect(error.code == "invalid_time")
        }
    }

    @Test func aDismissedNoteLeavesTheList() async throws {
        let bridge = try FakeBridgeProcess()
        let (client, _) = try await bridge.pairedClient()
        try await bridge.control("capture", ["heard": "Maybe a podcast about the R1", "delay": 0.2])
        let file = try VoiceClip.make(seconds: 1)
        defer { try? FileManager.default.removeItem(at: file) }
        let meta = CaptureMeta(source: .iphone)
        _ = try await client.capture(file: file, meta: meta)
        _ = try await waitSettled(client, meta.captureId)
        try await client.send(.post(BridgeClient.inboxPath("note:\(meta.captureId)", "dismiss"), body: [:]))
        #expect(try await client.inbox().items.contains { $0.id == "note:\(meta.captureId)" } == false)
    }

    @Test func theMacOutOfReachOrNotTakingNotes() async throws {
        let bridge = try FakeBridgeProcess()
        let (client, _) = try await bridge.pairedClient()
        let file = try VoiceClip.make(seconds: 1)
        defer { try? FileManager.default.removeItem(at: file) }
        try await bridge.control("capture", ["mode": "drop"])
        do {
            _ = try await client.capture(file: file, meta: CaptureMeta(source: .iphone), timeout: 5)
            Issue.record("a dropped connection is no answer")
        } catch let error as BridgeError {
            #expect(error.isRetryableCapture, "kept in the outbox: \(error)")
        }
        try await bridge.control("capture", ["mode": "unavailable"])
        do {
            _ = try await client.capture(file: file, meta: CaptureMeta(source: .iphone))
            Issue.record("503")
        } catch let error as BridgeError {
            #expect(error.code == "capture_unavailable")
            #expect(error.isRetryableCapture)
        }
        try await bridge.control("capture", ["mode": "missing"])
        do {
            _ = try await client.capture(file: file, meta: CaptureMeta(source: .iphone))
            Issue.record("404")
        } catch let error as BridgeError {
            #expect(error.isRouteMissing)
            #expect(error.isRetryableCapture, "an older bridge: kept until it is updated")
        }
        #expect(try await client.summary().captures == nil)
        // Refusals that sending again can't change end the note.
        #expect(!BridgeError.server(status: 413, code: "audio_too_long", message: "", retryable: false).isRetryableCapture)
        #expect(!BridgeError.server(status: 415, code: "unsupported_audio", message: "", retryable: false).isRetryableCapture)
        #expect(BridgeError.server(status: 409, code: "capture_conflict", message: "", retryable: false).isRetryableCapture == false)
        #expect(BridgeError.unauthorized.isRetryableCapture)
    }

    @Test func theWatchsNoteGoesThroughTheIPhoneWithTheWatchsToken() async throws {
        let bridge = try FakeBridgeProcess()
        let (_, phone) = try await bridge.pairedClient()
        let context = try await phone.provisionWatch()
        let closed = try SilentPort(listening: false)
        let relay = PhoneCaptureRelay(phone: phone)
        let watch = BridgeClient(hosts: [closed.host], token: context.token, relay: relay)
        try await bridge.control("capture", ["heard": "Make a task to rename the tokens file", "delay": 0.3])
        let file = try VoiceClip.make(seconds: 2)
        defer { try? FileManager.default.removeItem(at: file) }
        let meta = CaptureMeta(source: .watch, seconds: 2)
        let answer = try await watch.capture(file: file, meta: meta)
        #expect(answer.captureId == meta.captureId)
        #expect(relay.chunks.withLock { $0 } >= 1)
        let upload = try #require(try await fakeGet(bridge, "capture")["uploads"].array?.last)
        #expect(upload["source"].string == "watch")
        #expect(upload["platform"].string == "watchos", "with the watch's own token")
        #expect(upload["parentId"].string != nil)
        #expect(upload["capturedAt"].string == meta.capturedAtHeader)
        // What became of it, through the phone too.
        let done = try await waitSettled(watch, meta.captureId)
        #expect(done.outcome?.kind == .task)
        // The phone out of reach too: the watch keeps it (and hands it over with transferFile).
        let lonely = BridgeClient(hosts: [closed.host], token: context.token, relay: PhoneCaptureRelay(phone: phone, down: true))
        do {
            _ = try await lonely.capture(file: file, meta: CaptureMeta(source: .watch))
            Issue.record("nobody could take it")
        } catch let error as BridgeError {
            guard case .unreachable = error else {
                Issue.record("expected unreachable, got \(error)")
                return
            }
        }
    }

    // MARK: - The brief

    @Test func theBriefItsVerbsAndARefresh() async throws {
        let bridge = try FakeBridgeProcess()
        let (client, _) = try await bridge.pairedClient()
        let summary = try await client.summary()
        let part = try #require(summary.briefing)
        #expect(part.available)
        #expect(part.needsYou == 4)
        #expect(part.isToday())
        let brief = try await client.briefing()
        #expect(brief.revision == part.revision)
        #expect(brief.items(in: .doFirst).map(\.id) == ["bi_dana", "bi_acme", "bi_conflict"])
        #expect(brief.items(in: .doFirst).allSatisfy { $0.allows(.done) && $0.allows(.dismiss) })
        #expect(brief.items(in: .today).count >= 3)
        #expect(brief.items(in: .today).contains { $0.conflict })
        #expect(brief.items(in: .agents).first?.inboxItemId == "t3:t_deploy24")
        #expect(brief.items(in: .fyi).count == 2)
        #expect(brief.toDo == 4)
        #expect(brief.headline.hasPrefix("3 things need you"))
        #expect(brief.footer == "Read 105 emails · 14 worth a look")

        // Remind me, then Draft reply: a Gmail draft (never sent), with its link in the right account.
        let reminded = try await client.briefingAct("bi_dana", action: "remind")
        #expect(reminded.state == .snoozed)
        #expect(reminded.message?.hasPrefix("I'll remind you at") == true)
        let drafted = try await client.briefingAct("bi_dana", action: "draft_reply")
        #expect(drafted.state == .drafted)
        #expect(drafted.url?.host == "mail.google.com")
        #expect(drafted.url?.absoluteString.contains("authuser=sam%40example.com") == true)
        #expect(drafted.message == "Saved as a draft in Gmail. Open it to send.")
        #expect(try await client.briefingAct("bi_dana", action: "draft_reply").url == drafted.url, "a second tap: the same draft")
        // Make task, Block, Dismiss, Open on an agent (its inbox item).
        let tasked = try await client.briefingAct("bi_acme", action: "make_task")
        #expect(tasked.threadId != nil)
        #expect(tasked.itemId == "t3:" + (tasked.threadId ?? ""))
        #expect(try await client.briefingAct("bi_fyi_payout", action: "dismiss").state == .dismissed)
        let blocked = try await client.briefingAct("bi_conflict", action: "block_time")
        #expect(blocked.state == .blocked)
        #expect(blocked.message?.hasPrefix("Blocked 30 min at") == true)
        #expect(try await client.briefingAct("bi_agent_deploy", action: "open").itemId == "t3:t_deploy24")
        // A verb the item doesn't offer is refused.
        do {
            _ = try await client.briefingAct("bi_fyi_renewal", action: "make_task")
            Issue.record("refused")
        } catch let error as BridgeError {
            #expect(error.code == "unsupported_action")
        }
        let after = try await client.briefing()
        #expect(after.revision > brief.revision)
        let danaAfter = try #require(after.items.first { $0.id == "bi_dana" })
        #expect(danaAfter.state == .drafted)
        #expect(danaAfter.draftUrl == drafted.url)
        #expect(danaAfter.resultLine == "Saved as a draft in Gmail. Open it to send.")
        #expect(after.toDo == 1, "only the deploy is left")
        let taps = try await fakeGet(bridge, "briefing")["acts"].array ?? []
        #expect(taps.compactMap { $0["action"].string } == ["remind", "draft_reply", "draft_reply", "make_task", "dismiss",
                                                            "block_time", "open"])

        // Refresh: a new revision, picked up by the long-poll; another right away is too soon (one every 5 min).
        try await client.refreshBriefing()
        let refreshed = try await client.briefing(after: after.revision, wait: 8)
        #expect(refreshed.revision > after.revision)
        let built = try await client.briefing(wait: 8) // without `after`: until the build is over
        #expect(built.status == .ready)
        do {
            try await client.refreshBriefing()
            Issue.record("too soon")
        } catch let error as BridgeError {
            #expect(error.code == "refresh_too_soon")
        }
    }

    @Test func noBriefYetOrAnOlderBridge() async throws {
        let bridge = try FakeBridgeProcess()
        let (client, _) = try await bridge.pairedClient()
        try await bridge.control("briefing", ["mode": "none"])
        let none = try await client.briefing()
        #expect(!none.available)
        #expect(none.status == .none, "the real bridge's waiting")
        #expect(try await client.summary().briefing?.available == false)
        try await bridge.control("briefing", ["mode": "failed"])
        let failed = try await client.briefing()
        #expect(failed.status == .failed)
        #expect(failed.reason == "gmail_not_connected")
        try await bridge.control("briefing", ["mode": "off"])
        #expect(try await client.briefing().status == .off)
        try await bridge.control("briefing", ["mode": "missing"])
        do {
            _ = try await client.briefing()
            Issue.record("404")
        } catch let error as BridgeError {
            #expect(error.isRouteMissing)
        }
        #expect(try await client.summary().briefing == nil)
    }

    // MARK: - The assistant

    @Test func aCancelNamesTheTurnItMeans() async throws {
        let bridge = try FakeBridgeProcess()
        let (client, _) = try await bridge.pairedClient()
        let session = try await client.assistantSession()
        try await client.assistantCancel(conversationId: session.conversationId, turnId: "turn-gone")
        try await client.assistantCancel(conversationId: session.conversationId)
        let cancels = try await fakeGet(bridge, "assistant")["cancels"].array ?? []
        #expect(cancels.count == 2)
        #expect(cancels.first?["turnId"].string == "turn-gone")
        #expect(cancels.first?["cancelled"].bool == false, "no such turn: nothing stops")
        #expect(cancels.last?["turnId"].isNull == true)
    }

    // MARK: - Helpers

    private func waitSettled(_ client: BridgeClient, _ id: String) async throws -> CaptureStatus {
        var status = try await client.captureStatus(id, wait: 4)
        for _ in 0..<6 where !status.state.settled {
            status = try await client.captureStatus(id, wait: 4)
        }
        return status
    }

    private func fakeGet(_ bridge: FakeBridgeProcess, _ name: String) async throws -> JSONValue {
        let (data, _) = try await URLSession.shared.data(from: bridge.base.appendingPathComponent("__fake/\(name)"))
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
}
#endif
