import Foundation
import Synchronization

/// The async client for the Mac bridge's mobile API (`/v1/mobile/*`).
///
/// It holds the bridge's addresses in the order to try (LAN first, then Tailscale) and the mobile
/// bearer token. A request that cannot connect moves on to the next address; the address that
/// answers becomes the first one for later requests (`onPreferredHostChange` lets the owner save it).
/// HTTP errors are never retried on another address: they come from the bridge itself.
///
/// With a `relay` (the Apple Watch relays through the iPhone), a request that reached no address at
/// all goes through the relay instead; one that may have reached the bridge (a POST that timed
/// out) is never sent a second time.
///
/// A client owns two `URLSession`s: make one per pairing and keep it (`BridgeAccount.client()` does),
/// never one per request. Each request carries its own timeout (`BridgeRequest.timeout`, else the
/// client's default).
///
/// The Mac's own app talks to the same bridge through its desktop API (`api: .desktop`): the desktop token in
/// `X-SamRabbit-Desktop` instead of a bearer token, and the assistant under `/v1/desktop/assistant/*`.
public final class BridgeClient: Sendable {
    public let hosts: [BridgeHost]
    /// Which of the bridge's APIs this client speaks.
    public let api: BridgeAPI
    private let token: String?
    private let defaultTimeout: TimeInterval
    private let session: URLSession
    let streamSession: URLSession
    private let preferred: Mutex<Int>
    private let onPreferredHostChange: (@Sendable (BridgeHost) -> Void)?
    let relay: (any BridgeRelay)?

    /// - Parameters:
    ///   - hosts: the bridge addresses, best first.
    ///   - token: the mobile token (`nil` only for `pair` and `health`).
    ///   - timeout: the timeout in seconds of requests that do not set their own.
    ///   - relay: another route to the bridge for when no address answers.
    ///   - api: the mobile API (a paired device's token) or the desktop API (the Mac's own app, loopback only).
    public init(hosts: [BridgeHost], token: String?, timeout: TimeInterval = 12, relay: (any BridgeRelay)? = nil,
                api: BridgeAPI = .mobile, onPreferredHostChange: (@Sendable (BridgeHost) -> Void)? = nil) {
        self.hosts = hosts
        self.api = api
        self.token = token
        self.relay = relay
        self.onPreferredHostChange = onPreferredHostChange
        defaultTimeout = timeout
        preferred = Mutex(0)
        let configuration = URLSessionConfiguration.ephemeral
        // Every request sets its own timeout (`makeRequest`); this is only the ceiling.
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 120
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpAdditionalHeaders = ["User-Agent": "SamRabbit-Apple/1.0"]
        session = URLSession(configuration: configuration)
        let streaming = URLSessionConfiguration.ephemeral
        // Only the ceiling: each request sets its own (the SSE feed 45 s, the bridge sends a heartbeat every 15 s;
        // an assistant turn 90 s, `AssistantTurnRequest.readTimeout`).
        streaming.timeoutIntervalForRequest = 100
        streaming.timeoutIntervalForResource = 60 * 60 * 24
        streaming.waitsForConnectivity = false
        streaming.requestCachePolicy = .reloadIgnoringLocalCacheData
        streamSession = URLSession(configuration: streaming)
    }

    deinit {
        session.finishTasksAndInvalidate()
        streamSession.invalidateAndCancel()
    }

    /// The address requests go to first.
    public var currentHost: BridgeHost? {
        let index = preferred.withLock { $0 }
        return hosts.indices.contains(index) ? hosts[index] : hosts.first
    }

    // MARK: - Pairing and health

    /// `POST /v1/mobile/pair` (no token). Codes are single use: never retried on another address
    /// once one has answered.
    public func pair(code: String, deviceName: String, platform: DevicePlatform) async throws -> PairResponse {
        try await json(.post("/v1/mobile/pair", body: ["code": .string(code), "deviceName": .string(deviceName),
                                                        "platform": .string(platform.rawValue)],
                             authorized: false, timeout: 8))
    }

    /// `GET /health`
    public func health() async throws -> BridgeHealth {
        try await json(.get("/health", authorized: false, timeout: 5))
    }

    /// `POST /v1/mobile/devices/child {name, platform}`: a separate, revocable token for the
    /// Apple Watch, issued with this device's token. The bridge replaces an earlier child of this
    /// device with the same name (its old token stops working).
    public func childDevice(name: String, platform: DevicePlatform = .watchos) async throws -> PairResponse {
        try await json(.post("/v1/mobile/devices/child", body: ["name": .string(name),
                                                                 "platform": .string(platform.rawValue)]))
    }

    /// `POST /v1/mobile/unpair`: the bridge forgets the device whose token this client holds (an
    /// iPhone takes its watch with it). Returns how many devices it revoked.
    @discardableResult
    public func unpair(timeout: TimeInterval = 6) async throws -> Int {
        let value: JSONValue = try await json(.post("/v1/mobile/unpair", body: [:], timeout: timeout))
        return value["revoked"].int ?? 0
    }

    // MARK: - Dashboard

    /// `GET /v1/mobile/summary`
    public func summary(timeout: TimeInterval? = nil) async throws -> MobileSummary {
        try await json(.get("/v1/mobile/summary", timeout: timeout))
    }

    // MARK: - R1 conversations

    /// `GET /v1/mobile/conversations?limit=&before=&q=`
    /// `before` is epoch milliseconds (`ConversationPage.nextBefore`), so 64-bit on the watch too.
    public func conversations(limit: Int = 50, before: Int64? = nil, query: String? = nil) async throws -> ConversationPage {
        var items = [URLQueryItem(name: "limit", value: String(limit))]
        if let before { items.append(URLQueryItem(name: "before", value: String(before))) }
        if let query, !query.isEmpty { items.append(URLQueryItem(name: "q", value: query)) }
        return try await json(.get("/v1/mobile/conversations", query: items))
    }

    /// `GET /v1/mobile/conversations/<id>/events?after=`
    public func events(conversationId: String, after: Int64 = 0, limit: Int? = nil) async throws -> EventPage {
        var items = [URLQueryItem(name: "after", value: String(after))]
        if let limit { items.append(URLQueryItem(name: "limit", value: String(limit))) }
        return try await json(.get("/v1/mobile/conversations/\(Self.segment(conversationId))/events", query: items))
    }

    /// Every event of a conversation (follows `more` pages).
    public func allEvents(conversationId: String, after: Int64 = 0) async throws -> EventPage {
        var page = try await events(conversationId: conversationId, after: after)
        var collected = page.events
        var guardCount = 0
        while page.more, guardCount < 20 {
            page = try await events(conversationId: conversationId, after: page.cursor)
            collected += page.events
            guardCount += 1
        }
        return EventPage(events: collected, cursor: page.cursor, more: false)
    }

    /// `GET /v1/mobile/blobs/<sha256>` (an image from the timeline). Accepts `sha256:<hex>` ids.
    public func blob(_ blobId: String) async throws -> Data {
        let digest = blobId.hasPrefix("sha256:") ? String(blobId.dropFirst(7)) : blobId
        return try await data(.get("/v1/mobile/blobs/\(Self.segment(digest))", accept: "image/*"))
    }

    /// `GET /v1/mobile/stream?after=` as parsed SSE items. One connection; see `LiveSyncFeed` for
    /// the reconnecting version.
    public func stream(after cursor: Int64?) -> AsyncThrowingStream<SyncStreamItem, Error> {
        var query: [URLQueryItem] = []
        if let cursor { query.append(URLQueryItem(name: "after", value: String(cursor))) }
        let request = BridgeRequest.get("/v1/mobile/stream", query: query, accept: "text/event-stream")
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await self.openStream(request)
                    guard response.statusCode == 200 else {
                        var body = Data()
                        for try await byte in bytes {
                            body.append(byte)
                            if body.count > 16_384 { break }
                        }
                        throw BridgeError.from(status: response.statusCode, data: body)
                    }
                    var parser = ServerSentEventParser()
                    for try await byte in bytes {
                        for message in parser.feed(byte) {
                            if let item = SyncStreamItem(message) { continuation.yield(item) }
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch let error as URLError where error.code == .cancelled {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Generated UI

    /// `GET /v1/mobile/ui/artifacts/<id>`
    public func artifact(_ artifactId: String) async throws -> GeneratedArtifact {
        try await json(.get("/v1/mobile/ui/artifacts/\(Self.segment(artifactId))"))
    }

    /// `GET /v1/mobile/ui/artifacts/<id>/image` (JPEG preview)
    public func artifactImage(_ artifactId: String) async throws -> Data {
        try await data(.get("/v1/mobile/ui/artifacts/\(Self.segment(artifactId))/image", accept: "image/*"))
    }

    /// `GET /v1/mobile/ui/artifacts/<id>/document` (the self-contained HTML document)
    public func artifactDocument(_ artifactId: String) async throws -> String {
        let body = try await data(.get("/v1/mobile/ui/artifacts/\(Self.segment(artifactId))/document",
                                       accept: "text/html"))
        guard let html = String(data: body, encoding: .utf8) else { throw BridgeError.invalidResponse("document") }
        return html
    }

    /// `POST /v1/mobile/ui/generate {prompt, data?}` -> the new artifact's id.
    public func generateUI(prompt: String, data: String? = nil) async throws -> String {
        var body: [String: JSONValue] = ["prompt": .string(prompt)]
        if let data { body["data"] = .string(data) }
        let value: JSONValue = try await json(.post("/v1/mobile/ui/generate", body: body, timeout: 20))
        guard let id = value["artifactId"].text else { throw BridgeError.invalidResponse("artifactId") }
        return id
    }

    /// Polls an artifact until it is ready or failed (or `timeout` passes).
    public func waitForArtifact(_ artifactId: String, timeout: TimeInterval = 150,
                                interval: TimeInterval = 1.5) async throws -> GeneratedArtifact {
        let deadline = Date.now.addingTimeInterval(timeout)
        while true {
            let artifact = try await artifact(artifactId)
            if artifact.status != .generating || Date.now > deadline { return artifact }
            try await Task.sleep(for: .seconds(interval))
        }
    }

    // MARK: - T3 tasks

    /// `GET /v1/mobile/t3/threads?filter=`
    public func threads(filter: ThreadFilter? = nil, timeout: TimeInterval? = nil) async throws -> [TaskThread] {
        let query = filter.map { [URLQueryItem(name: "filter", value: $0.rawValue)] } ?? []
        let list: ThreadList = try await json(.get("/v1/mobile/t3/threads", query: query, timeout: timeout))
        return list.threads
    }

    /// `GET /v1/mobile/t3/threads/<id>`
    public func thread(_ threadId: String) async throws -> ThreadDetail {
        try await json(.get("/v1/mobile/t3/threads/\(Self.segment(threadId))"))
    }

    /// `POST /v1/mobile/t3/threads {text, projectId?}`: a new task (automatic placement without a project).
    public func createThread(text: String, projectId: String? = nil) async throws -> CreatedThread {
        var body: [String: JSONValue] = ["text": .string(text)]
        if let projectId { body["projectId"] = .string(projectId) }
        return try await json(.post("/v1/mobile/t3/threads", body: body, timeout: 25))
    }

    /// `POST /v1/mobile/t3/threads/<id>/message {text}`
    public func sendMessage(threadId: String, text: String) async throws {
        try await send(.post("/v1/mobile/t3/threads/\(Self.segment(threadId))/message", body: ["text": .string(text)]))
    }

    /// Approve or deny one approval: `POST .../respond {decision, requestId}`. The bridge answers 409
    /// `t3_request_not_pending` (`BridgeError.isStaleRequest`) when `requestId` is no longer the open
    /// request, so a stale card never approves something else.
    public func respond(threadId: String, requestId: String, approve: Bool) async throws {
        try await send(.post("/v1/mobile/t3/threads/\(Self.segment(threadId))/respond",
                             body: ["decision": .string(approve ? "approve" : "deny"), "requestId": .string(requestId)]))
    }

    /// Answer one question: `POST .../respond {answer, requestId}` (409 `t3_request_not_pending` when stale).
    public func respond(threadId: String, requestId: String, answer: String) async throws {
        try await send(.post("/v1/mobile/t3/threads/\(Self.segment(threadId))/respond",
                             body: ["answer": .string(answer), "requestId": .string(requestId)]))
    }

    /// `POST .../stop`
    public func stop(threadId: String) async throws {
        try await send(.post("/v1/mobile/t3/threads/\(Self.segment(threadId))/stop", body: [:]))
    }

    /// `GET /v1/mobile/t3/projects`
    public func projects() async throws -> [TaskProject] {
        let list: ProjectList = try await json(.get("/v1/mobile/t3/projects"))
        return list.projects
    }

    // MARK: - Inbox (every agent on the Mac)

    /// `GET /v1/mobile/inbox[?after=&wait=]`: T3 threads, Claude Code and Codex sessions and the recent chats. With
    /// `after` (the revision last seen) and `wait` (at most 25 s) the Mac answers once something changed, or after
    /// `wait` with the same list. An older bridge answers 404 (`BridgeError.isRouteMissing`).
    public func inbox(after revision: Int64? = nil, wait: Int? = nil, timeout: TimeInterval? = nil) async throws
        -> InboxSnapshot {
        var query: [URLQueryItem] = []
        if let revision { query.append(URLQueryItem(name: "after", value: String(revision))) }
        let seconds = wait.map { min(max($0, 0), 25) }
        if let seconds, seconds > 0 { query.append(URLQueryItem(name: "wait", value: String(seconds))) }
        let budget = timeout ?? (seconds.map { TimeInterval($0) + 10 } ?? nil)
        return try await json(.get("/v1/mobile/inbox", query: query, timeout: budget))
    }

    /// `GET /v1/mobile/inbox/items/<id>`: the item now and its last messages.
    public func inboxItem(_ itemId: String) async throws -> InboxItemDetail {
        try await json(.get(Self.inboxPath(itemId)))
    }

    /// `POST /v1/mobile/inbox/items/<id>/reply {text}`. A T3 thread gets a new turn; a Claude Code or Codex session
    /// that no CLI owns is resumed with the reply in a new Terminal window on the Mac (`how: "terminal"`). One that
    /// is open in a terminal is refused with 409 `session_live` (`BridgeError.isSessionLive`).
    public func inboxReply(_ itemId: String, text: String) async throws -> InboxReplyResult {
        try await json(.post(Self.inboxPath(itemId, "reply"), body: ["text": .string(text)], timeout: 20))
    }

    /// `POST /v1/mobile/inbox/items/<id>/seen`: unread clears (a failed Claude Code or Codex session settles).
    public func inboxSeen(_ itemId: String) async throws {
        try await send(.post(Self.inboxPath(itemId, "seen"), body: [:]))
    }

    /// `POST /v1/mobile/inbox/items/<id>/dismiss`: hidden (and seen) here and on the Mac until it changes; the
    /// bridge's own state only, nothing reaches T3, Claude Code or Codex.
    public func inboxDismiss(_ itemId: String) async throws -> InboxDismissResult {
        try await json(.post(Self.inboxPath(itemId, "dismiss"), body: [:]))
    }

    /// `POST /v1/mobile/inbox/items/<id>/undismiss`: the undo of `inboxDismiss`.
    public func inboxUndismiss(_ itemId: String) async throws -> InboxDismissResult {
        try await json(.post(Self.inboxPath(itemId, "undismiss"), body: [:]))
    }

    /// `POST /v1/mobile/inbox/items/<id>/approve {requestId, decision}` (one of the approval's own options).
    public func inboxApprove(_ itemId: String, requestId: String, decision: String) async throws {
        try await send(.post(Self.inboxPath(itemId, "approve"),
                             body: ["requestId": .string(requestId), "decision": .string(decision)]))
    }

    /// `POST /v1/mobile/inbox/items/<id>/answer {requestId, answers: {questionId: answer}}`.
    public func inboxAnswer(_ itemId: String, requestId: String, answers: [String: String]) async throws {
        try await send(.post(Self.inboxPath(itemId, "answer"),
                             body: ["requestId": .string(requestId),
                                    "answers": .object(answers.mapValues { .string($0) })]))
    }

    /// `POST /v1/mobile/inbox/items/<id>/stop`.
    public func inboxStop(_ itemId: String) async throws {
        try await send(.post(Self.inboxPath(itemId, "stop"), body: [:]))
    }

    /// `GET /v1/mobile/inbox/targets`: where a new task can go (projects, Claude / Codex and their models).
    public func inboxTargets() async throws -> InboxTargets {
        try await json(.get("/v1/mobile/inbox/targets", timeout: 15))
    }

    /// `POST /v1/mobile/inbox/new {text, projectId?, agent?, model?}`: a new T3 thread and its first turn.
    public func inboxNew(text: String, choice: InboxTargets.Choice = InboxTargets.Choice()) async throws
        -> CreatedInboxTask {
        var body: [String: JSONValue] = ["text": .string(text)]
        if let projectId = choice.projectId { body["projectId"] = .string(projectId) }
        if let agent = choice.agent { body["agent"] = .string(agent) }
        if let model = choice.model { body["model"] = .string(model) }
        return try await json(.post("/v1/mobile/inbox/new", body: body, timeout: 25))
    }

    /// `/v1/mobile/inbox/items/<id>[/<action>]`. Ids look like `claude:<uuid>`: the colon stays, anything else
    /// outside the path's safe set is escaped (a `/` never becomes a separator).
    static func inboxPath(_ itemId: String, _ action: String? = nil) -> String {
        "/v1/mobile/inbox/items/\(segment(itemId))" + (action.map { "/\($0)" } ?? "")
    }

    // MARK: - Calendar and journal

    /// `GET /v1/mobile/calendar/agenda?hours=`
    public func agenda(hours: Int = 24) async throws -> Agenda {
        try await json(.get("/v1/mobile/calendar/agenda", query: [URLQueryItem(name: "hours", value: String(hours))],
                            timeout: 20))
    }

    /// `POST /v1/mobile/calendar/block {minutes, title?}`: now until now + minutes.
    public func block(minutes: Int, title: String? = nil) async throws -> CalendarWrite {
        var body: [String: JSONValue] = ["minutes": .number(Double(minutes))]
        if let title, !title.isEmpty { body["title"] = .string(title) }
        return try await json(.post("/v1/mobile/calendar/block", body: body, timeout: 25))
    }

    /// `POST /v1/mobile/calendar/events {title, startsAt, endsAt}`
    public func createEvent(title: String, startsAt: Date, endsAt: Date) async throws -> CalendarWrite {
        try await json(.post("/v1/mobile/calendar/events",
                             body: ["title": .string(title), "startsAt": .string(BridgeDates.iso(startsAt)),
                                    "endsAt": .string(BridgeDates.iso(endsAt))], timeout: 25))
    }

    /// `POST /v1/mobile/journal {text}`: the user's own words, appended to today's journal.
    public func addJournalNote(_ text: String) async throws -> JournalWrite {
        try await json(.post("/v1/mobile/journal", body: ["text": .string(text)], timeout: 20))
    }

    // MARK: - Mac

    /// `GET /v1/mobile/mac/state`
    public func macState() async throws -> MacState {
        try await json(.get("/v1/mobile/mac/state", timeout: 20))
    }

    /// `POST /v1/mobile/mac/open {app?|url?}`
    public func openOnMac(app: String? = nil, url: String? = nil) async throws -> MacOpenResult {
        var body: [String: JSONValue] = [:]
        if let app, !app.isEmpty { body["app"] = .string(app) }
        if let url, !url.isEmpty { body["url"] = .string(url) }
        return try await json(.post("/v1/mobile/mac/open", body: body, timeout: 20))
    }

    /// `GET /v1/mobile/mac/screenshot` (JPEG). Throws `screen_locked` / `screen_recording_required`.
    public func screenshot() async throws -> Data {
        try await data(.get("/v1/mobile/mac/screenshot", accept: "image/jpeg", timeout: 30))
    }

    // MARK: - Voice

    /// `POST /v1/mobile/transcribe[?lang=]`: a recording (the file is the raw body, `audio/mp4`) turned into
    /// words on the Mac. Transcribing changes nothing on the Mac, so unlike other POSTs the recording may be
    /// sent again another way after any connection problem (a timeout too): the next address, then the
    /// relay (the Apple Watch: the iPhone, in chunks). Throws `BridgeError` (see `VoiceProblem` for what each
    /// code means to a person).
    public func transcribe(file: URL, contentType: String = VoiceFormat.contentType, language: String? = nil,
                           timeout: TimeInterval = 60) async throws -> Transcript {
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0 else { throw BridgeError.server(status: 400, code: "invalid_audio", message: "The recording is empty.", retryable: false) }
        guard size <= VoiceFormat.maxBytes else { throw Self.tooLarge }
        return try Self.transcript(try await transcription(.file(file), contentType: contentType, language: language,
                                                           timeout: timeout))
    }

    /// `transcribe(file:)` for a recording in memory.
    public func transcribe(audio: Data, contentType: String = VoiceFormat.contentType, language: String? = nil,
                           timeout: TimeInterval = 60) async throws -> Transcript {
        guard !audio.isEmpty else { throw BridgeError.server(status: 400, code: "invalid_audio", message: "The recording is empty.", retryable: false) }
        guard audio.count <= VoiceFormat.maxBytes else { throw Self.tooLarge }
        return try Self.transcript(try await transcription(.data(audio), contentType: contentType, language: language,
                                                           timeout: timeout))
    }

    /// The iPhone's side of the watch's voice relay: the bridge's status and body for a recording, without
    /// throwing for HTTP errors (like `raw`). Direct only; throws `BridgeError.unreachable` when no address
    /// answered.
    public func rawTranscription(audio: Data, contentType: String = VoiceFormat.contentType, language: String? = nil,
                                 timeout: TimeInterval = 60) async throws -> (status: Int, body: Data) {
        do {
            let (body, response) = try await upload(Self.transcribeRequest(contentType: contentType, language: language,
                                                                           timeout: timeout), .data(audio))
            return (response.statusCode, body)
        } catch let failure as NoRoute {
            throw BridgeError.unreachable(failure.reason)
        }
    }

    /// The request line and headers of a transcription (the body is the recording).
    public static func transcribeRequest(contentType: String = VoiceFormat.contentType, language: String? = nil,
                                         timeout: TimeInterval = 60) -> BridgeRequest {
        var query: [URLQueryItem] = []
        if let language, !language.isEmpty { query.append(URLQueryItem(name: "lang", value: language)) }
        return BridgeRequest(method: "POST", path: "/v1/mobile/transcribe", query: query, body: nil, authorized: true,
                             accept: "application/json", timeout: timeout, contentType: contentType)
    }

    private static let tooLarge = BridgeError.server(status: 413, code: "audio_too_large",
                                                     message: "Recordings can be at most 2 MB.", retryable: false)

    private static func transcript(_ answer: (status: Int, body: Data)) throws -> Transcript {
        guard (200..<300).contains(answer.status) else { throw BridgeError.from(status: answer.status, data: answer.body) }
        do {
            return try BridgeJSON.decode(Transcript.self, from: answer.body)
        } catch {
            throw BridgeError.invalidResponse("Transcript")
        }
    }

    /// Where an upload's body comes from.
    enum UploadBody: Sendable {
        case file(URL)
        case data(Data)

        func bytes() throws -> Data {
            switch self {
            case .file(let url): try Data(contentsOf: url)
            case .data(let data): data
            }
        }
    }

    /// Directly (each address in turn), or through the relay: first when the relay is preferred right now,
    /// otherwise after the direct route failed to connect or timed out.
    private func transcription(_ source: UploadBody, contentType: String, language: String?,
                               timeout: TimeInterval) async throws -> (status: Int, body: Data) {
        let request = Self.transcribeRequest(contentType: contentType, language: language, timeout: timeout)
        guard let relay else {
            do {
                let (body, response) = try await upload(request, source)
                return (response.statusCode, body)
            } catch let failure as NoRoute {
                throw BridgeError.unreachable(failure.reason)
            }
        }
        // Tried the relay already (it was down, or couldn't reach the Mac either): not again.
        var relayTried = false
        if relay.prefersRelay {
            relayTried = true
            do {
                let answer = try await relay.relayTranscription(try source.bytes(), contentType: contentType,
                                                                language: language)
                if answer.status != 0 { return answer } // 0: the phone couldn't reach the Mac either; try directly
            } catch BridgeError.unreachable {
                // nothing went that way: try directly
            }
        }
        var reason = "no address"
        do {
            let (body, response) = try await upload(request, source)
            relay.noteDirectRoute(worked: true)
            return (response.statusCode, body)
        } catch let failure as NoRoute {
            reason = failure.reason
        } catch BridgeError.unreachable(let why) {
            reason = why
        }
        relay.noteDirectRoute(worked: false)
        if relayTried { throw BridgeError.unreachable(reason) }
        return try Self.relayed(try await relay.relayTranscription(try source.bytes(), contentType: contentType,
                                                                    language: language))
    }

    /// One upload over the addresses: a recording is safe to send again, so timeouts move on to the next
    /// address too.
    private func upload(_ request: BridgeRequest, _ source: UploadBody) async throws -> (Data, HTTPURLResponse) {
        try await withHosts(request, idempotent: true) { urlRequest in
            let (data, response) = switch source {
            case .file(let url): try await self.session.upload(for: urlRequest, fromFile: url)
            case .data(let bytes): try await self.session.upload(for: urlRequest, from: bytes)
            }
            guard let http = response as? HTTPURLResponse else { throw BridgeError.invalidResponse("not HTTP") }
            return (data, http)
        }
    }

    // MARK: - Transport

    /// Sends a request and decodes its JSON answer.
    public func json<T: Decodable>(_ request: BridgeRequest) async throws -> T {
        let body = try await data(request)
        do {
            return try BridgeJSON.decode(T.self, from: body)
        } catch {
            throw BridgeError.invalidResponse(String(describing: T.self))
        }
    }

    /// Sends a request whose answer body does not matter.
    public func send(_ request: BridgeRequest) async throws {
        _ = try await data(request)
    }

    /// Sends a request and returns the raw body of a 2xx answer.
    public func data(_ request: BridgeRequest) async throws -> Data {
        let (status, body) = try await exchange(request)
        guard (200..<300).contains(status) else {
            throw BridgeError.from(status: status, data: body)
        }
        return body
    }

    /// The bridge's status and body for a request: directly, or through the relay when no address
    /// could be reached (or the relay is preferred right now).
    private func exchange(_ request: BridgeRequest) async throws -> (status: Int, body: Data) {
        guard let relay, WatchRelay.Request(request).allowed else {
            do {
                let (body, response) = try await perform(request)
                return (response.statusCode, body)
            } catch let failure as NoRoute {
                throw BridgeError.unreachable(failure.reason)
            }
        }
        var relayDown = false
        if relay.prefersRelay {
            var answer: (status: Int, body: Data)?
            do {
                answer = try await relay.relay(request)
            } catch BridgeError.unreachable {
                relayDown = true // nothing was sent that way: try the bridge directly
            }
            if let answer { return try Self.relayed(answer) }
        }
        do {
            let (body, response) = try await perform(request)
            relay.noteDirectRoute(worked: true)
            return (response.statusCode, body)
        } catch let failure as NoRoute {
            relay.noteDirectRoute(worked: false)
            if relayDown { throw BridgeError.unreachable(failure.reason) }
            return try Self.relayed(try await relay.relay(request))
        } catch let error as BridgeError {
            // It may have reached the bridge (a POST that timed out): never sent twice.
            if case .unreachable = error { relay.noteDirectRoute(worked: false) }
            throw error
        }
    }

    /// A relayed answer; status 0 means the relay could not reach the bridge either (and is not
    /// tried another way: the request may have got through).
    private static func relayed(_ answer: (status: Int, body: Data)) throws -> (status: Int, body: Data) {
        guard answer.status != 0 else { throw BridgeError.unreachable("relay") }
        return answer
    }

    private func perform(_ request: BridgeRequest) async throws -> (Data, HTTPURLResponse) {
        try await withHosts(request, idempotent: request.idempotent) { urlRequest in
            let (data, response) = try await self.session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else { throw BridgeError.invalidResponse("not HTTP") }
            return (data, http)
        }
    }

    private func openStream(_ request: BridgeRequest) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        do {
            return try await withHosts(request) { urlRequest in
                let (bytes, response) = try await self.streamSession.bytes(for: urlRequest)
                guard let http = response as? HTTPURLResponse else { throw BridgeError.invalidResponse("not HTTP") }
                return (bytes, http)
            }
        } catch let failure as NoRoute {
            throw BridgeError.unreachable(failure.reason)
        }
    }

    /// No address could be connected to, so nothing reached the bridge (safe to send another way).
    struct NoRoute: Error {
        var reason: String
    }

    /// Runs `body` against each address in turn until one connects. Throws `NoRoute` when none
    /// did, and `BridgeError.unreachable` when the request may have reached the bridge.
    func withHosts<T>(_ request: BridgeRequest, idempotent: Bool? = nil,
                      _ body: (URLRequest) async throws -> T) async throws -> T {
        guard !hosts.isEmpty else { throw BridgeError.notPaired }
        if request.authorized, token == nil { throw BridgeError.notPaired }
        let start = preferred.withLock { $0 }
        var lastError = "no address"
        for offset in 0..<hosts.count {
            let index = (start + offset) % hosts.count
            guard let urlRequest = makeRequest(request, host: hosts[index]) else { continue }
            do {
                let result = try await body(urlRequest)
                if index != start {
                    preferred.withLock { $0 = index }
                    onPreferredHostChange?(hosts[index])
                }
                return result
            } catch let error as URLError {
                if error.code == .cancelled { throw BridgeError.cancelled }
                // A POST that may have reached the bridge (a timeout) is never sent again elsewhere.
                guard Self.isConnectionFailure(error, idempotent: idempotent ?? (request.method == "GET")) else {
                    throw BridgeError.unreachable(error.code.description)
                }
                lastError = error.code.description
            } catch is CancellationError {
                throw BridgeError.cancelled
            }
        }
        throw NoRoute(reason: lastError)
    }

    func makeRequest(_ request: BridgeRequest, host: BridgeHost) -> URLRequest? {
        guard let base = host.baseURL, var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.percentEncodedPath = request.path
        components.queryItems = request.query.isEmpty ? nil : request.query
        guard let url = components.url else { return nil }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        urlRequest.setValue(request.accept, forHTTPHeaderField: "Accept")
        urlRequest.timeoutInterval = request.timeout ?? (request.accept == "text/event-stream" ? 45 : defaultTimeout)
        if request.authorized, let token {
            switch api {
            case .mobile: urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            case .desktop: urlRequest.setValue(token, forHTTPHeaderField: BridgeAPI.desktopTokenHeader)
            }
        }
        if let body = request.body {
            urlRequest.httpBody = body
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let contentType = request.contentType { urlRequest.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        return urlRequest
    }

    /// Errors after which another address may be tried. Only failures that prove nothing reached the
    /// bridge count for non-idempotent requests.
    static func isConnectionFailure(_ error: URLError, idempotent: Bool) -> Bool {
        switch error.code {
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet, .dataNotAllowed,
             .internationalRoamingOff:
            true
        case .timedOut, .networkConnectionLost, .cannotLoadFromNetwork, .secureConnectionFailed, .resourceUnavailable:
            idempotent
        default:
            false
        }
    }

    /// Percent-encodes one path segment (ids never contain slashes).
    static func segment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/")))
            ?? value
    }
}

/// The bridge's two front doors.
public enum BridgeAPI: String, Sendable, Equatable {
    /// `/v1/mobile/*`: a paired iPhone or Apple Watch, over the LAN, with `Authorization: Bearer <mobile token>`.
    case mobile
    /// `/v1/desktop/*`: the SamRabbit app on the Mac itself, loopback only, with `X-SamRabbit-Desktop: <desktop
    /// token>` (the token in `~/.config/samrabbit/desktop-token`).
    case desktop

    public static let desktopTokenHeader = "X-SamRabbit-Desktop"

    /// An assistant route: `/v1/mobile/assistant/<route>` or `/v1/desktop/assistant/<route>` (the same bodies and
    /// the same streaming turn protocol on both).
    public func assistantPath(_ route: String) -> String { "/v1/\(rawValue)/assistant/\(route)" }
}

/// One call to the bridge.
public struct BridgeRequest: Sendable {
    public var method: String
    public var path: String
    public var query: [URLQueryItem]
    public var body: Data?
    public var authorized: Bool
    public var accept: String
    public var timeout: TimeInterval?
    /// The body's type when it isn't JSON (an upload: `audio/mp4`).
    public var contentType: String?
    /// More headers (the assistant's `X-SamRabbit-Conversation`, `X-SamRabbit-Turn`, ...).
    public var headers: [String: String]
    /// Safe to send again after a timeout (another address, the relay). Default: GETs only.
    public var idempotent: Bool?

    public init(method: String, path: String, query: [URLQueryItem] = [], body: Data? = nil, authorized: Bool = true,
                accept: String = "application/json", timeout: TimeInterval? = nil, contentType: String? = nil,
                headers: [String: String] = [:]) {
        self.method = method
        self.path = path
        self.query = query
        self.body = body
        self.authorized = authorized
        self.accept = accept
        self.timeout = timeout
        self.contentType = contentType
        self.headers = headers
    }

    public static func get(_ path: String, query: [URLQueryItem] = [], authorized: Bool = true,
                           accept: String = "application/json", timeout: TimeInterval? = nil) -> BridgeRequest {
        BridgeRequest(method: "GET", path: path, query: query, body: nil, authorized: authorized, accept: accept,
                      timeout: timeout)
    }

    public static func post(_ path: String, body: [String: JSONValue], authorized: Bool = true,
                            timeout: TimeInterval? = nil) -> BridgeRequest {
        let data = try? BridgeJSON.encoder().encode(JSONValue.object(body))
        return BridgeRequest(method: "POST", path: path, query: [], body: data ?? Data("{}".utf8),
                             authorized: authorized, accept: "application/json", timeout: timeout)
    }
}

extension URLError.Code: @retroactive CustomStringConvertible {
    public var description: String { "URLError(\(rawValue))" }
}
