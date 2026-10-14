import Foundation
import os
import SamRabbitKit
import Synchronization
import UIKit
import WatchConnectivity

private let log = Logger(subsystem: "com.samrabbit.mobile", category: "watch")

/// The iPhone's half of the Apple Watch link (`watchOS/App/PhoneLink.swift` is the other half):
/// * provisions the watch with the bridge addresses and its own child token
///   (`POST /v1/mobile/devices/child`, revocable from the Mac; `BridgeAccount.provisionWatch`)
///   through `applicationContext`, and answers the watch's "send it now" request
///   (`WatchContext.requestKey`) with the same context;
/// * relays bridge requests the watch sends with `sendMessage` when it cannot reach the Mac itself,
///   performed with the watch's own token, never the phone's (`BridgeAccount.performRelayed`;
///   `WatchRelay` in SamRabbitKit describes both messages);
/// * passes on the watch's voice recordings the same way: they arrive in chunks (`VoiceRelay`), are put
///   back together here and uploaded for transcription with the watch's token
///   (`BridgeAccount.performRelayedTranscription`); the reply to the last chunk is the bridge's answer;
/// * passes on the watch's voice notes: in chunks like a recording (purpose `capture`, uploaded to
///   `/v1/mobile/capture` with the watch's token, `BridgeAccount.performRelayedCapture`), or handed over with
///   `transferFile` into this iPhone's outbox (`CaptureUploader` sends it on);
/// * carries the watch's assistant turns (`TurnRelay`): the utterance in chunks, then the turn goes to the Mac
///   with the watch's token and its answer is handed back piece by piece as the Mac streams it
///   (`TurnRelayHost`); a buffered answer (an older bridge, the Claude fallback) comes through the same way.
///
/// Everything it passes on runs under a background-task assertion (`RelayAwake`), so the phone finishes a
/// relayed request, and keeps streaming a turn, while the iPhone app is in the background.
final class WatchLink: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = WatchLink()

    private let account = BridgeAccount.shared
    /// The watch's recordings while their chunks arrive.
    private let recordings = VoiceRelay.Assembler()
    /// The watch's turns while their answers stream in (awake from start to the last piece pulled).
    private let turns = TurnRelayHost { turnId, active in
        Task { @MainActor in
            if active { RelayAwake.shared.begin("turn-\(turnId)") } else { RelayAwake.shared.end("turn-\(turnId)") }
        }
    }
    /// The last provisioning run: runs never overlap (two at once would issue two child tokens).
    private let lastRun = Mutex<Task<Provisioning, Never>?>(nil)

    func start() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    /// What `provision` did.
    enum Provisioning: Sendable {
        case sent(WatchContext)
        case unpaired
        case failed
    }

    /// Sends the current pairing to the watch (issuing a child token the first time, or again with
    /// `reissue`: after re-pairing the phone, or when the watch says the Mac rejected its token; the
    /// old watch token stops working).
    @discardableResult
    func provision(reissue: Bool = false) async -> Provisioning {
        let run = lastRun.withLock { last -> Task<Provisioning, Never> in
            let previous = last
            let next = Task {
                _ = await previous?.value
                return await self.provisionNow(reissue: reissue)
            }
            last = next
            return next
        }
        return await run.value
    }

    private func provisionNow(reissue: Bool) async -> Provisioning {
        guard WCSession.isSupported() else { return .failed }
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return .failed }
        guard account.isPaired else {
            try? session.updateApplicationContext([WatchContext.unpairedKey: true])
            return .unpaired
        }
        let context: WatchContext
        do {
            context = try await account.provisionWatch(reissue: reissue)
        } catch {
            log.notice("watch token not issued")
            return .failed
        }
        do {
            try session.updateApplicationContext(context.applicationContext)
        } catch {
            log.notice("watch context not sent")
        }
        return .sent(context)
    }

    /// Forgets the watch's token here and tells the watch (on unpair: the bridge revoked it with the phone).
    func reset() {
        account.forgetWatch()
        recordings.reset()
        turns.reset()
        if WCSession.isSupported(), WCSession.default.activationState == .activated {
            try? WCSession.default.updateApplicationContext([WatchContext.unpairedKey: true])
        }
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        Task { await provision() }
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        Task { await provision() }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                 replyHandler: @escaping ([String: Any]) -> Void) {
        nonisolated(unsafe) let reply = replyHandler
        if let ask = message[WatchContext.requestKey] as? String {
            Task {
                switch await provision(reissue: ask == WatchContext.reissueValue) {
                case .sent(let context): reply(context.applicationContext)
                case .unpaired: reply([WatchContext.unpairedKey: true])
                case .failed: reply([:])
                }
            }
            return
        }
        if let chunk = VoiceRelay.Chunk(message: message) {
            switch recordings.add(chunk) {
            case .waiting: reply([VoiceRelay.ackKey: chunk.seq])
            case .refused(let response): reply(response.message)
            case .complete(let upload) where upload.purpose == VoiceRelay.capturePurpose:
                // A voice note: to `/v1/mobile/capture` with the watch's own token and the note's headers.
                awake { reply(await self.account.performRelayedCapture(upload).message) }
            case .complete(let upload) where upload.purpose == TurnRelay.purpose:
                // A turn's utterance: kept until its `start` arrives.
                turns.keep(upload)
                reply([VoiceRelay.ackKey: chunk.seq])
            case .complete(let upload):
                // With the watch's own token, like every relayed request.
                awake { reply(await self.account.performRelayedTranscription(upload).message) }
            }
            return
        }
        if let turn = TurnRelay.Message(message: message) {
            // Runs (and streams) with the watch's own token; `turns` holds the phone awake meanwhile.
            Task { reply(await self.turns.handle(turn, client: self.account.isPaired ? self.account.watchClient() : nil)) }
            return
        }
        guard let request = WatchRelay.Request(message: message) else {
            reply(WatchRelay.Response(status: 400, body: Data()).message)
            return
        }
        // With the watch's own token: a watch revoked on the Mac is refused here too (401).
        awake { reply(await self.account.performRelayed(request).message) }
    }

    /// A voice note the watch handed over with `transferFile` (it couldn't reach the Mac or this iPhone just then):
    /// kept in this iPhone's outbox as the watch's (sent with the watch's own token) and sent on. The file is
    /// deleted when this returns, so it is moved first.
    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard let meta = CaptureMeta(transferMetadata: file.metadata) else { return }
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(meta.captureId).m4a")
        do {
            try? FileManager.default.removeItem(at: kept)
            try FileManager.default.moveItem(at: file.fileURL, to: kept)
            try CaptureOutbox.shared.add(recording: kept, meta: meta, relayedFor: .watch)
            log.notice("a voice note from the watch")
            CaptureUploader.shared.flush()
        } catch {
            try? FileManager.default.removeItem(at: kept)
            log.notice("a voice note from the watch could not be kept")
        }
    }

    /// Runs `work` under a background-task assertion (the phone may be in the background when the watch asks).
    private func awake(_ work: @escaping @Sendable () async -> Void) {
        let key = UUID().uuidString
        Task {
            await MainActor.run { RelayAwake.shared.begin(key) }
            await work()
            await MainActor.run { RelayAwake.shared.end(key) }
        }
    }
}

/// Background-task assertions for what the iPhone passes on for the watch: each relayed request, and each turn
/// from its start until the watch pulled the last piece. If the system ends one early it is just let go.
@MainActor
final class RelayAwake {
    static let shared = RelayAwake()
    private var tasks: [String: UIBackgroundTaskIdentifier] = [:]
    /// Ended before its begin arrived (the two hop to the main actor separately).
    private var endedEarly: Set<String> = []

    func begin(_ key: String) {
        if endedEarly.remove(key) != nil { return }
        guard tasks[key] == nil else { return }
        let id = UIApplication.shared.beginBackgroundTask(withName: "SamRabbit passes on a request from the watch") { [weak self] in
            MainActor.assumeIsolated { self?.end(key) }
        }
        guard id != .invalid else { return }
        tasks[key] = id
    }

    func end(_ key: String) {
        guard let id = tasks.removeValue(forKey: key) else {
            endedEarly.insert(key)
            if endedEarly.count > 64 { endedEarly.removeFirst() }
            return
        }
        UIApplication.shared.endBackgroundTask(id)
    }

    /// How many are held (tests and the debugger).
    var count: Int { tasks.count }
}
