import Foundation
import os
import SamRabbitKit
import Synchronization
import WatchConnectivity

private let log = Logger(subsystem: "com.samrabbit.mobile.watchkitapp", category: "phone")

extension Notification.Name {
    /// The pairing changed (the iPhone sent a context, or said it unpaired).
    static let samRabbitPairingChanged = Notification.Name("samrabbit.pairingChanged")
}

/// The Apple Watch's half of the iPhone link (`iOS/App/WatchLink.swift` is the other half):
/// * receives the bridge addresses and the watch's own child token in `applicationContext`
///   (`WatchContext`) and stores them like a pairing (App Group + Keychain), so the watch and its
///   complications call the bridge directly;
/// * is the `BridgeRelay` of the watch's clients: when the Mac can't be reached directly, the
///   request goes to the iPhone with `sendMessage` (`WatchRelay`) and the phone performs it; a voice
///   recording goes in chunks of at most 40 KB (`VoiceRelay`) and the phone uploads it for transcription;
///   an assistant turn goes the same way and its answer comes back in pieces as the Mac streams it
///   (`TurnRelay`: the watch pulls each piece); a voice note goes in chunks too (`relayCapture`), or with
///   `transferFile` when the phone can't answer now (`transferCapture`).
final class PhoneLink: NSObject, WCSessionDelegate, BridgeRelay, TurnRelayLink, @unchecked Sendable {
    static let shared = PhoneLink()

    /// How the last answer from the Mac arrived.
    enum Route: String, Sendable {
        case direct
        case phone
    }

    private struct State {
        var directFailedAt: Date?
        var lastRoute: Route = .direct
    }

    private let state = Mutex(State())
    private let account = BridgeAccount.shared
    /// After the Mac couldn't be reached directly, requests go through the iPhone first for a while.
    private static let preferPhoneFor: TimeInterval = 120

    /// Debug: `-SamRabbitRoute phone` sends every request through the iPhone.
    private var forcedRoute: Route? {
        #if DEBUG
        UserDefaults.standard.string(forKey: "SamRabbitRoute").flatMap(Route.init(rawValue:))
        #else
        nil
        #endif
    }

    var lastRoute: Route { state.withLock { $0.lastRoute } }

    var phoneReachable: Bool {
        WCSession.isSupported() && WCSession.default.activationState == .activated && WCSession.default.isReachable
    }

    func start() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    // MARK: - BridgeRelay

    var prefersRelay: Bool {
        if let forcedRoute { return forcedRoute == .phone }
        guard let failed = state.withLock({ $0.directFailedAt }) else { return false }
        return Date.now.timeIntervalSince(failed) < Self.preferPhoneFor
    }

    func noteDirectRoute(worked: Bool) {
        state.withLock {
            $0.directFailedAt = worked ? nil : .now
            if worked { $0.lastRoute = .direct }
        }
    }

    func relay(_ request: BridgeRequest) async throws -> (status: Int, body: Data) {
        let reply = try await exchange(timeout: (request.timeout ?? 12) + 8) {
            WatchRelay.Request(request).message
        }
        state.withLock { $0.lastRoute = .phone }
        guard let data = reply.relay, let response = WatchRelay.Response(message: [WatchRelay.responseKey: data]) else {
            // The phone took the request but its answer is unreadable: it may have run.
            return (0, Data())
        }
        return (response.status, response.body)
    }

    /// A recording through the iPhone (`VoiceRelay`): one `sendMessage` per chunk, in order, each
    /// acknowledged; the phone answers the last one with the bridge's status and body (or refuses a
    /// chunk with an error envelope). Throws `BridgeError.unreachable` when the phone can't be reached or
    /// stops answering (transcribing changes nothing on the Mac, so that is safe to try another way).
    func relayTranscription(_ audio: Data, contentType: String, language: String?) async throws -> (status: Int, body: Data) {
        let chunks = VoiceRelay.chunks(of: audio, contentType: contentType, language: language)
        for chunk in chunks {
            // The last reply waits for the Mac's words (the bridge allows itself about 45 s).
            let reply = try await exchange(timeout: chunk.isLast ? 75 : 15) { chunk.message }
            if let data = reply.relay, let response = WatchRelay.Response(message: [WatchRelay.responseKey: data]) {
                state.withLock { $0.lastRoute = .phone }
                return (response.status, response.body)
            }
            guard !chunk.isLast, reply.ack == chunk.seq else { break }
        }
        throw BridgeError.unreachable("iPhone: the recording got no answer")
    }

    /// A voice note through the iPhone: the recording in chunks like a transcription (`VoiceRelay`, purpose
    /// `capture`, with the note's id, time and source); the phone uploads it to `POST /v1/mobile/capture` with the
    /// watch's own token and answers the last chunk with the bridge's status and body. Throws
    /// `BridgeError.unreachable` when the phone can't be reached or stops answering (a note is safe to send again).
    func relayCapture(_ audio: Data, meta: CaptureMeta) async throws -> (status: Int, body: Data) {
        let chunks = VoiceRelay.chunks(of: audio, id: meta.captureId, contentType: meta.contentType,
                                       language: meta.language, purpose: VoiceRelay.capturePurpose, capture: meta)
        for chunk in chunks {
            let reply = try await exchange(timeout: chunk.isLast ? 40 : 15) { chunk.message }
            if let data = reply.relay, let response = WatchRelay.Response(message: [WatchRelay.responseKey: data]) {
                state.withLock { $0.lastRoute = .phone }
                return (response.status, response.body)
            }
            guard !chunk.isLast, reply.ack == chunk.seq else { break }
        }
        throw BridgeError.unreachable("iPhone: the voice note got no answer")
    }

    /// Hands a voice note to the iPhone with `WCSession.transferFile` (watchOS queues it and delivers it in the
    /// background, whenever the phone is near): the phone keeps it in its own outbox and sends it on. The recording
    /// stays here until the transfer finished (`didFinish`). False when the link isn't up at all.
    func transferCapture(_ file: URL, meta: CaptureMeta) -> Bool {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              FileManager.default.fileExists(atPath: file.path) else { return false }
        guard !transferring(meta.captureId) else { return true }
        WCSession.default.transferFile(file, metadata: meta.transferMetadata)
        return true
    }

    /// A transfer of this note to the iPhone is still on its way.
    func transferring(_ captureId: String) -> Bool {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return false }
        return WCSession.default.outstandingFileTransfers.contains {
            CaptureMeta(transferMetadata: $0.file.metadata)?.captureId == captureId
        }
    }

    /// An assistant turn through the iPhone (`TurnRelay`): the utterance in chunks, then the phone sends the turn
    /// to the Mac with the watch's own token and hands the answer back piece by piece.
    func relayAssistantTurn(_ turn: AssistantTurnRequest) async throws -> AssistantTurnResponse {
        let response = try await TurnRelay.run(turn, over: self)
        if response.status != 0 { state.withLock { $0.lastRoute = .phone } }
        return response
    }

    // MARK: - TurnRelayLink

    func send(_ outgoing: TurnRelay.Outgoing, timeout: TimeInterval) async throws -> TurnRelay.Answer? {
        let reply = try await exchange(timeout: timeout) { outgoing.dictionary }
        guard reply.ack != nil || reply.turn != nil || reply.relay != nil else { return nil } // no answer in time
        var dictionary: [String: Any] = [:]
        if let ack = reply.ack { dictionary[VoiceRelay.ackKey] = ack }
        if let turn = reply.turn { dictionary[TurnRelay.replyKey] = turn }
        if let data = reply.turnData { dictionary[TurnRelay.dataKey] = data }
        if let relay = reply.relay { dictionary[WatchRelay.responseKey] = relay }
        return TurnRelay.Answer(dictionary: dictionary)
    }

    // MARK: - Pairing from the phone

    /// Asks the iPhone for the pairing now (on launch without one, or "Reconnect" after the Mac
    /// stopped accepting the watch's token: `reissue` gets a new child token).
    /// Returns true when the watch is paired afterwards.
    @discardableResult
    func requestContext(reissue: Bool = false) async -> Bool {
        do {
            let reply = try await exchange(timeout: 25) {
                [WatchContext.requestKey: reissue ? WatchContext.reissueValue : "now"]
            }
            if reply.unpaired {
                forget()
            } else if let data = reply.context {
                apply([WatchContext.key: data])
            }
        } catch {
            log.notice("no context from the phone")
        }
        return account.isPaired
    }

    private func apply(_ context: [String: Any]) {
        if context[WatchContext.unpairedKey] as? Bool == true {
            forget()
            return
        }
        guard let value = WatchContext(applicationContext: context), !value.token.isEmpty, !value.hosts.isEmpty else {
            return
        }
        let current = account.pairing
        if let current, Set(current.hosts) == Set(value.hosts), current.deviceId == value.deviceId,
           account.token == value.token {
            return
        }
        let pairing = BridgePairing(hosts: value.hosts, deviceId: value.deviceId, bridgeName: value.bridgeName,
                                    bridgeVersion: nil, deviceName: "Apple Watch", pairedAt: value.issuedAt)
        guard account.save(pairing, token: value.token) else {
            log.error("could not store the watch token")
            return
        }
        state.withLock { $0.directFailedAt = nil }
        log.notice("paired through the iPhone")
        changed()
    }

    private func forget() {
        guard account.pairing != nil || account.token != nil else { return }
        account.forget() // the phone unpaired: the bridge revoked this watch with it
        SummaryCache.shared.clear()
        log.notice("the iPhone unpaired")
        changed()
    }

    private func changed() {
        SamRabbitActions.reloadWidgets()
        NotificationCenter.default.post(name: .samRabbitPairingChanged, object: nil)
    }

    // MARK: - sendMessage

    /// What the phone answered (only the parts the watch reads, so it can cross tasks).
    private struct Reply: Sendable {
        var relay: Data?
        var context: Data?
        var unpaired: Bool
        /// The phone kept a voice chunk (its `seq`).
        var ack: Int?
        /// A turn's reply (`TurnRelay.Reply`) and its piece of the answer.
        var turn: Data?
        var turnData: Data?
    }

    /// One `sendMessage` round trip. Throws `BridgeError.unreachable` when nothing reached the
    /// phone; a reply that never came (timeout) is an empty `Reply`: the phone may have acted.
    private func exchange(timeout: TimeInterval, _ message: () -> [String: Any]) async throws -> Reply {
        guard WCSession.isSupported() else { throw BridgeError.unreachable("no iPhone link") }
        let session = WCSession.default
        guard session.activationState == .activated else { throw BridgeError.unreachable("link not active") }
        guard session.isReachable else { throw BridgeError.unreachable("iPhone not reachable") }
        let once = Once()
        let payload = message()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Reply, Error>) in
            once.set(continuation)
            session.sendMessage(payload, replyHandler: { answer in
                once.resume(.success(Reply(relay: answer[WatchRelay.responseKey] as? Data,
                                           context: answer[WatchContext.key] as? Data,
                                           unpaired: answer[WatchContext.unpairedKey] as? Bool == true,
                                           ack: answer[VoiceRelay.ackKey] as? Int,
                                           turn: answer[TurnRelay.replyKey] as? Data,
                                           turnData: answer[TurnRelay.dataKey] as? Data)))
            }, errorHandler: { error in
                let code = (error as? WCError)?.code
                switch code {
                case .messageReplyTimedOut, .messageReplyFailed:
                    once.resume(.success(Reply(relay: nil, context: nil, unpaired: false)))
                default:
                    once.resume(.failure(BridgeError.unreachable("iPhone: \(code?.rawValue ?? -1)")))
                }
            })
            Task {
                try? await Task.sleep(for: .seconds(timeout))
                once.resume(.success(Reply(relay: nil, context: nil, unpaired: false)))
            }
        }
    }

    /// Resumes a continuation exactly once (reply, error or timeout, whichever comes first).
    private final class Once: Sendable {
        private let continuation = Mutex<CheckedContinuation<Reply, Error>?>(nil)

        func set(_ value: CheckedContinuation<Reply, Error>) { continuation.withLock { $0 = value } }

        func resume(_ result: Result<Reply, Error>) {
            let pending = continuation.withLock { value -> CheckedContinuation<Reply, Error>? in
                defer { value = nil }
                return value
            }
            pending?.resume(with: result)
        }
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        guard state == .activated else { return }
        let context = session.receivedApplicationContext
        if !context.isEmpty { apply(context) }
        if !account.isPaired {
            Task { await requestContext() }
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        apply(applicationContext)
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        if session.isReachable, !account.isPaired {
            Task { await requestContext() }
        }
    }

    /// A voice note handed to the iPhone arrived there (the phone sends it on): its recording goes here. One that
    /// didn't make it waits in the outbox for another try.
    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        guard let meta = CaptureMeta(transferMetadata: fileTransfer.file.metadata) else { return }
        if error == nil {
            CaptureOutbox.shared.handedOff(meta.captureId)
            log.notice("a voice note reached the iPhone")
        } else {
            CaptureOutbox.shared.failed(meta.captureId, error: "transfer_failed", retryable: true)
        }
    }
}
