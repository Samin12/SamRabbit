import Foundation
import Synchronization

/// One turn of a conversation, as sent to `POST /v1/mobile/assistant/turn`.
public struct AssistantTurnRequest: Sendable, Equatable {
    public var turnId: String
    /// Empty for a new conversation.
    public var conversationId: String?
    public var input: ConversationMachine.Input
    /// `?lang=` for an utterance (the watch's locale).
    public var language: String?
    public var deviceTime: Date
    /// Ask for the frame stream (`Accept: application/x-samrabbit-stream`); else the buffered JSON answer.
    public var stream: Bool

    public init(turnId: String, conversationId: String?, input: ConversationMachine.Input, language: String? = nil,
                deviceTime: Date = .now, stream: Bool = true) {
        self.turnId = turnId
        self.conversationId = conversationId
        self.input = input
        self.language = language
        self.deviceTime = deviceTime
        self.stream = stream
    }

    public static let path = "/v1/mobile/assistant/turn"
    public static let conversationHeader = "X-SamRabbit-Conversation"
    public static let turnHeader = "X-SamRabbit-Turn"
    public static let deviceTimeHeader = "X-SamRabbit-Device-Time"

    /// The device time the way the header carries it: ISO 8601 with the watch's own offset.
    public static func deviceTimeText(_ date: Date, timeZone: TimeZone = .current) -> String {
        Date.ISO8601FormatStyle(timeZoneSeparator: .colon, timeZone: timeZone).format(date)
    }

    /// How long the bridge may stay quiet once it answered: a tool can run for a while without a word (the bridge
    /// sends a `{"type":"ping"}` event while it does, about every 15 s; an older one sends nothing), and a buffered
    /// answer arrives whole after speech to text, the agent and the voice (up to about 80 s on the Claude path).
    public static let readTimeout: TimeInterval = 90

    public var timeout: TimeInterval { Self.readTimeout }

    /// How long until the bridge answers at all (its status line). A stream answers once the utterance is
    /// transcribed (at most 45 s on the Mac); a buffered answer only when it is whole. Shorter than `timeout` so a Mac
    /// that can't be reached is given up on (and the iPhone tried) without waiting the whole read timeout.
    public var headTimeout: TimeInterval { stream ? 50 : Self.readTimeout }

    /// The request line, headers and body.
    public var bridgeRequest: BridgeRequest {
        let headers = [Self.conversationHeader: conversationId ?? "", Self.turnHeader: turnId,
                       Self.deviceTimeHeader: Self.deviceTimeText(deviceTime)]
        let accept = stream ? AssistantStream.contentType : "application/json"
        switch input {
        case .audio(let wav):
            var query: [URLQueryItem] = []
            if let language, !language.isEmpty { query.append(URLQueryItem(name: "lang", value: language)) }
            return BridgeRequest(method: "POST", path: Self.path, query: query, body: wav, authorized: true,
                                 accept: accept, timeout: timeout, contentType: WAV.contentType, headers: headers)
        case .text, .announce:
            return BridgeRequest(method: "POST", path: Self.path, body: jsonBody, authorized: true, accept: accept,
                                 timeout: timeout, contentType: "application/json", headers: headers)
        }
    }

    /// The utterance's WAV (nil for a text or an announcement).
    public var audio: Data? {
        if case .audio(let wav) = input { return wav }
        return nil
    }

    /// `{text, conversationId?, turnId}` or `{announce, conversationId?, turnId}`.
    public var jsonBody: Data {
        var object: [String: JSONValue] = ["turnId": .string(turnId)]
        if let conversationId, !conversationId.isEmpty { object["conversationId"] = .string(conversationId) }
        switch input {
        case .text(let text): object["text"] = .string(text)
        case .announce(let id): object["announce"] = .string(id)
        case .audio: break
        }
        return (try? BridgeJSON.encoder().encode(JSONValue.object(object))) ?? Data("{}".utf8)
    }
}

extension BridgeRequest {
    /// The same request, marked safe to send again after a timeout (the warm-up, cancel and end: repeating them
    /// changes nothing).
    public var repeatable: BridgeRequest {
        var request = self
        request.idempotent = true
        return request
    }
}

/// The bridge's answer to a turn as it starts to arrive: status, content type, and the body as it streams in.
public struct AssistantTurnResponse: Sendable {
    public var status: Int
    public var contentType: String
    public var body: AsyncThrowingStream<Data, Error>

    public init(status: Int, contentType: String, body: AsyncThrowingStream<Data, Error>) {
        self.status = status
        self.contentType = contentType
        self.body = body
    }

    /// An answer that is already whole (a refusal).
    public static func whole(status: Int, contentType: String = "application/json", body: Data) -> AssistantTurnResponse {
        AssistantTurnResponse(status: status, contentType: contentType, body: AsyncThrowingStream { continuation in
            if !body.isEmpty { continuation.yield(body) }
            continuation.finish()
        })
    }

    public var isStream: Bool { contentType.lowercased().hasPrefix(AssistantStream.contentType) }

    /// Reads the answer into items: the frames of a stream, or a buffered JSON answer converted to the same items.
    /// Throws the bridge's error for a non-2xx answer, and `AssistantStreamError.truncated` when a stream ends
    /// without its `done` (or `error`) event.
    public func items() -> AsyncThrowingStream<AssistantStreamItem, Error> {
        let response = self
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard (200..<300).contains(response.status) else {
                        let body = try await Self.collect(response.body, limit: 64 * 1024)
                        throw BridgeError.from(status: response.status, data: body)
                    }
                    if response.isStream {
                        var parser = AssistantStreamParser()
                        var ended = false
                        for try await chunk in response.body {
                            for item in try parser.items(chunk) {
                                continuation.yield(item)
                                if case .event(.done) = item { ended = true }
                                if case .event(.error) = item { ended = true }
                            }
                        }
                        if !ended { throw AssistantStreamError.truncated }
                    } else {
                        let body = try await Self.collect(response.body, limit: 12 * 1024 * 1024)
                        let reply: AssistantReply
                        do {
                            reply = try BridgeJSON.decode(AssistantReply.self, from: body)
                        } catch {
                            throw BridgeError.invalidResponse("AssistantReply")
                        }
                        for item in reply.items { continuation.yield(item) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func collect(_ body: AsyncThrowingStream<Data, Error>, limit: Int) async throws -> Data {
        var data = Data()
        for try await chunk in body {
            data.append(chunk)
            if data.count > limit { throw BridgeError.invalidResponse("answer too large") }
        }
        return data
    }
}

extension BridgeClient {
    // MARK: - The assistant

    /// `POST /v1/mobile/assistant/session {conversationId?}`: warms the Mac up for a conversation (opens the
    /// realtime session) and names it. Optional: a first turn without an id starts one too.
    public func assistantSession(conversationId: String? = nil, timeout: TimeInterval = 8) async throws -> AssistantSession {
        var body: [String: JSONValue] = [:]
        if let conversationId, !conversationId.isEmpty { body["conversationId"] = .string(conversationId) }
        return try await json(.post(api.assistantPath("session"), body: body, timeout: timeout).repeatable)
    }

    /// `POST /v1/mobile/assistant/cancel {conversationId, turnId?}`: stop the reply being said (barge-in). With
    /// `turnId` only that turn stops: a cancel that arrives after it ended never stops the next one (the Mac answers
    /// `cancelled: false`).
    public func assistantCancel(conversationId: String, turnId: String? = nil, timeout: TimeInterval = 5) async throws {
        var body: [String: JSONValue] = ["conversationId": .string(conversationId)]
        if let turnId, !turnId.isEmpty { body["turnId"] = .string(turnId) }
        try await send(.post(api.assistantPath("cancel"), body: body, timeout: timeout).repeatable)
    }

    /// `POST /v1/mobile/assistant/end {conversationId}`: the watch (or the Mac) stopped listening.
    public func assistantEnd(conversationId: String, timeout: TimeInterval = 5) async throws {
        try await send(.post(api.assistantPath("end"), body: ["conversationId": .string(conversationId)],
                             timeout: timeout).repeatable)
    }

    /// `GET /v1/mobile/assistant/announcements?conversationId=&since=`: T3 tasks to tell Samin about.
    public func assistantAnnouncements(conversationId: String, since cursor: String? = nil,
                                       timeout: TimeInterval = 10) async throws -> AnnouncementPage {
        var query = [URLQueryItem(name: "conversationId", value: conversationId)]
        if let cursor, !cursor.isEmpty { query.append(URLQueryItem(name: "since", value: cursor)) }
        return try await json(.get(api.assistantPath("announcements"), query: query, timeout: timeout))
    }

    /// One turn, as items in order (`heard`, `say.delta`…, audio, `say.done`, actions, cards, `done`), whether the
    /// Mac streams them or answers in one piece. Directly (each address in turn) or through the relay (the watch:
    /// the iPhone); a turn carries its own id, so the Mac answers a repeat with the same turn and it may be sent
    /// again another way. "Still answering" (409 `assistant_busy`, a cancelled turn still stopping) is retried for
    /// `busyFor` seconds, counted from the first 409: getting the turn there can take a while of its own (the iPhone
    /// relay sends the recording over Bluetooth). Throws `BridgeError` (or `AssistantStreamError`).
    public func assistantTurn(_ turn: AssistantTurnRequest, busyFor: TimeInterval = 4) -> AsyncThrowingStream<AssistantStreamItem, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var deadline: Date?
                    while true {
                        let response = try await self.openAssistantTurn(turn)
                        if response.status == 409 {
                            let now = Date.now
                            let limit = deadline ?? now.addingTimeInterval(busyFor)
                            deadline = limit
                            let body = try await AssistantTurnResponse.collect(response.body, limit: 64 * 1024)
                            let refusal = BridgeError.from(status: 409, data: body)
                            if refusal.code == "assistant_busy", now < limit {
                                try await Task.sleep(for: .milliseconds(350))
                                continue
                            }
                            throw refusal
                        }
                        for try await item in response.items() { continuation.yield(item) }
                        break
                    }
                    continuation.finish()
                } catch let error as URLError where error.code == .cancelled {
                    continuation.finish(throwing: BridgeError.cancelled)
                } catch is CancellationError {
                    continuation.finish(throwing: BridgeError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Sends a turn and returns the answer's status, type and streaming body: directly, or through the relay
    /// (first when it is preferred right now, else when no address could be reached).
    public func openAssistantTurn(_ turn: AssistantTurnRequest) async throws -> AssistantTurnResponse {
        guard let relay else { return try await openDirect(turn) }
        var relayTried = false
        if relay.prefersRelay {
            relayTried = true
            do {
                let answer = try await relay.relayAssistantTurn(turn)
                if answer.status != 0 { return answer } // 0: the phone couldn't reach the Mac either
            } catch BridgeError.unreachable {
                // nothing went that way: try directly
            }
        }
        do {
            let answer = try await openDirect(turn)
            relay.noteDirectRoute(worked: true)
            return answer
        } catch BridgeError.unreachable(let reason) {
            relay.noteDirectRoute(worked: false)
            if relayTried { throw BridgeError.unreachable(reason) }
        }
        let answer = try await relay.relayAssistantTurn(turn)
        guard answer.status != 0 else { throw BridgeError.unreachable("relay") }
        return answer
    }

    /// The turn on the bridge's own addresses only (the iPhone's side of the relay uses this too). A desktop client
    /// sends it to `/v1/desktop/assistant/turn`.
    public func openDirect(_ turn: AssistantTurnRequest) async throws -> AssistantTurnResponse {
        do {
            var request = turn.bridgeRequest
            request.path = api.assistantPath("turn")
            return try await withHosts(request, idempotent: true) { urlRequest in
                let (http, body) = try await StreamingBody.open(urlRequest, in: self.streamSession,
                                                                headWithin: turn.headTimeout)
                return AssistantTurnResponse(status: http.statusCode,
                                             contentType: http.value(forHTTPHeaderField: "Content-Type") ?? "",
                                             body: body)
            }
        } catch let failure as NoRoute {
            throw BridgeError.unreachable(failure.reason)
        }
    }
}

/// A request whose body is read as it arrives (a task delegate hands over each piece), with the status and
/// headers first. Connection failures surface before the response, as the `URLError` they are, so the client can
/// try another address.
final class StreamingBody: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct State {
        var head: CheckedContinuation<HTTPURLResponse, Error>?
        var stream: AsyncThrowingStream<Data, Error>.Continuation?
        var answered = false
    }

    private let state = Mutex(State())

    /// `headWithin`: the status line must arrive within this long (connecting included), else the request fails with
    /// `URLError(.timedOut)` like a connection that timed out; after it, the request's own timeout is the longest
    /// the body may stay quiet.
    static func open(_ request: URLRequest, in session: URLSession,
                     headWithin: TimeInterval? = nil) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
        let delegate = StreamingBody()
        let task = session.dataTask(with: request)
        task.delegate = delegate
        let (body, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        delegate.state.withLock { $0.stream = continuation }
        continuation.onTermination = { _ in task.cancel() }
        let watchdog = headWithin.map { limit in
            Task {
                try? await Task.sleep(for: .seconds(limit))
                guard !Task.isCancelled else { return }
                let head = delegate.state.withLock { state -> CheckedContinuation<HTTPURLResponse, Error>? in
                    defer { state.head = nil }
                    return state.answered ? nil : state.head
                }
                guard let head else { return }
                head.resume(throwing: URLError(.timedOut))
                task.cancel()
            }
        }
        defer { watchdog?.cancel() }
        let http = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (head: CheckedContinuation<HTTPURLResponse, Error>) in
                delegate.state.withLock { $0.head = head }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
        return (http, body)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let head = state.withLock { state -> CheckedContinuation<HTTPURLResponse, Error>? in
            state.answered = true
            defer { state.head = nil }
            return state.head
        }
        if let http = response as? HTTPURLResponse {
            head?.resume(returning: http)
            completionHandler(.allow)
        } else {
            head?.resume(throwing: BridgeError.invalidResponse("not HTTP"))
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        _ = state.withLock { $0.stream }?.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (head, stream) = state.withLock { state -> (CheckedContinuation<HTTPURLResponse, Error>?, AsyncThrowingStream<Data, Error>.Continuation?) in
            defer {
                state.head = nil
                state.stream = nil
            }
            return (state.head, state.stream)
        }
        if let head {
            head.resume(throwing: error ?? BridgeError.invalidResponse("no answer"))
        }
        if let error {
            stream?.finish(throwing: (error as? URLError)?.code == .cancelled ? BridgeError.cancelled : error)
        } else {
            stream?.finish()
        }
    }
}
