import Foundation

/// What the iPhone sends the Apple Watch in WatchConnectivity's `applicationContext`: the bridge
/// addresses and a child token issued for the watch (`POST /v1/mobile/devices/child`), revocable on
/// its own from the Mac.
public struct WatchContext: Codable, Sendable, Equatable {
    public var hosts: [BridgeHost]
    public var token: String
    public var deviceId: String
    public var bridgeName: String?
    public var issuedAt: Date

    public init(hosts: [BridgeHost], token: String, deviceId: String, bridgeName: String?, issuedAt: Date = .now) {
        self.hosts = hosts
        self.token = token
        self.deviceId = deviceId
        self.bridgeName = bridgeName
        self.issuedAt = issuedAt
    }

    /// The `applicationContext` key that carries the encoded context.
    public static let key = "samrabbit.watchContext"
    /// Sent instead when the phone unpaired (the watch should forget its token).
    public static let unpairedKey = "samrabbit.unpaired"
    /// A `sendMessage` from the watch asking for its context now (on launch without a pairing).
    /// The phone replies with `applicationContext` (or `unpairedKey`). With the value
    /// `reissueValue` the phone first issues a new child token (the old one was rejected and the
    /// person asked to reconnect).
    public static let requestKey = "samrabbit.contextRequest"
    public static let reissueValue = "reissue"
    /// The name the watch's child token is issued under. Always the same, so the bridge replaces
    /// the previous watch token of this iPhone when it issues a new one.
    public static let watchName = "Apple Watch"

    public var applicationContext: [String: Any] {
        guard let data = try? BridgeJSON.encoder().encode(self) else { return [:] }
        return [Self.key: data]
    }

    public init?(applicationContext: [String: Any]) {
        guard let data = applicationContext[Self.key] as? Data,
              let value = try? BridgeJSON.decode(WatchContext.self, from: data) else { return nil }
        self = value
    }
}

/// A bridge request relayed through the iPhone (`WCSession.sendMessage`) when the watch cannot
/// reach the Mac directly. The phone performs it with the watch's own child token (the one it
/// issued and keeps in its Keychain, `BridgeAccount.performRelayed`), never with its own, and
/// answers with the status and body, so the watch decodes exactly what the bridge said: a watch
/// revoked on the Mac gets 401 through the phone just as it does directly.
public enum WatchRelay {
    public static let requestKey = "samrabbit.relay"
    public static let responseKey = "samrabbit.relayResponse"

    static let prefix = "/v1/mobile/"
    /// The first path segments under `/v1/mobile/` the phone relays (an allowlist).
    static let relayable: Set<String> = ["summary", "t3", "calendar", "journal", "conversations", "blobs", "ui", "mac",
                                         "assistant", "briefing", "capture", "captures"]
    /// Relayed another way (`TurnRelay`: the answer streams back in pieces), never as one request.
    static let notRelayed: Set<String> = ["assistant/turn"]

    public struct Request: Codable, Sendable, Equatable {
        public var method: String
        public var path: String
        public var query: [[String]]
        public var body: Data?
        public var accept: String
        public var timeout: TimeInterval?

        public init(_ request: BridgeRequest) {
            method = request.method
            path = request.path
            query = request.query.map { [$0.name, $0.value ?? ""] }
            body = request.body
            accept = request.accept
            timeout = request.timeout
        }

        public var bridgeRequest: BridgeRequest {
            BridgeRequest(method: method, path: path,
                          query: query.compactMap { $0.count == 2 ? URLQueryItem(name: $0[0], value: $0[1]) : nil },
                          body: body, authorized: true, accept: accept, timeout: timeout)
        }

        /// Only what the watch itself does may be relayed: the dashboard, tasks, the calendar, the
        /// journal, conversations, generated UIs, the Mac, the assistant's warm-up, cancel, end and
        /// announcements, the morning brief and what became of a voice note (the note itself goes in chunks,
        /// `relayCapture`). Never pairing, unpairing or device management (`pair`, `pairing/start`, `unpair`,
        /// `devices`, `devices/child`), never the SSE stream, and never an assistant turn this way (it streams:
        /// `TurnRelay`).
        public var allowed: Bool {
            guard ["GET", "POST"].contains(method), path.hasPrefix(WatchRelay.prefix) else { return false }
            let lowered = path.lowercased()
            guard !lowered.contains(".."), !lowered.contains("//"), !lowered.contains("%2e"), !lowered.contains("%2f"),
                  !path.contains("?"), !path.contains("#") else { return false }
            let rest = String(path.dropFirst(WatchRelay.prefix.count))
            guard !WatchRelay.notRelayed.contains(rest.lowercased()) else { return false }
            let first = rest.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            return WatchRelay.relayable.contains(first)
        }

        public var message: [String: Any] {
            guard let data = try? JSONEncoder().encode(self) else { return [:] }
            return [WatchRelay.requestKey: data]
        }

        public init?(message: [String: Any]) {
            guard let data = message[WatchRelay.requestKey] as? Data,
                  let value = try? JSONDecoder().decode(Request.self, from: data) else { return nil }
            self = value
        }
    }

    public struct Response: Codable, Sendable, Equatable {
        /// The bridge's HTTP status, or 0 when the phone could not reach the Mac either.
        public var status: Int
        public var body: Data

        public init(status: Int, body: Data) {
            self.status = status
            self.body = body
        }

        /// The phone's own refusal, in the bridge's error envelope.
        static func refusal(_ status: Int, _ code: String, _ message: String) -> Response {
            let envelope: JSONValue = ["error": ["code": .string(code), "message": .string(message), "retryable": false]]
            return Response(status: status, body: (try? JSONEncoder().encode(envelope)) ?? Data())
        }

        public var message: [String: Any] {
            guard let data = try? JSONEncoder().encode(self) else { return [:] }
            return [WatchRelay.responseKey: data]
        }

        public init?(message: [String: Any]) {
            guard let data = message[WatchRelay.responseKey] as? Data,
                  let value = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
            self = value
        }
    }
}

extension BridgeClient {
    /// Performs any request and returns the bridge's status and body, without throwing for HTTP
    /// errors (the phone's side of `WatchRelay`). Throws only when no address answered.
    public func raw(_ request: BridgeRequest) async throws -> (status: Int, body: Data) {
        do {
            let body = try await data(request)
            return (200, body)
        } catch let error as BridgeError {
            switch error {
            case .server(let status, let code, let message, let retryable):
                let envelope: JSONValue = ["error": ["code": .string(code), "message": .string(message),
                                                     "retryable": .bool(retryable)]]
                return (status, (try? JSONEncoder().encode(envelope)) ?? Data())
            case .unauthorized:
                return (401, Data(#"{"error":{"code":"unauthorized","message":"Pair again.","retryable":false}}"#.utf8))
            default:
                throw error
            }
        }
    }
}

/// Another route to the bridge, used by `BridgeClient` when no address can be connected to. The
/// Apple Watch implements it with `WCSession.sendMessage` (the iPhone performs the request with
/// the watch's own child token and answers with `WatchRelay.Response`).
public protocol BridgeRelay: Sendable {
    /// True when requests should go through the relay first (the direct route failed a moment ago).
    var prefersRelay: Bool { get }
    /// Called after each direct attempt: `true` when the bridge answered, `false` when it could not be reached.
    func noteDirectRoute(worked: Bool)
    /// Performs the request through the relay and returns the bridge's status and body (status 0:
    /// the relay could not reach the bridge either). Throws `BridgeError.unreachable` only when the
    /// relay itself is down and nothing was sent.
    func relay(_ request: BridgeRequest) async throws -> (status: Int, body: Data)
    /// Sends a recording for `POST /v1/mobile/transcribe` through the relay (the watch: in chunks to the
    /// iPhone, `VoiceRelay`) and returns the bridge's status and body (status 0: the relay could not reach
    /// the bridge either). Throws `BridgeError.unreachable` when the relay itself is down.
    func relayTranscription(_ audio: Data, contentType: String, language: String?) async throws -> (status: Int, body: Data)
    /// An assistant turn through the relay (the watch: the iPhone sends it to the Mac and passes the answer back in
    /// pieces as it streams in, `TurnRelay`). Returns the bridge's status, content type and body (status 0: the
    /// relay could not reach the bridge). Throws `BridgeError.unreachable` when the relay itself is down.
    func relayAssistantTurn(_ turn: AssistantTurnRequest) async throws -> AssistantTurnResponse
    /// A voice note for `POST /v1/mobile/capture` through the relay (the watch: in chunks to the iPhone, which
    /// uploads it with the watch's own token and the note's headers). Returns the bridge's status and body (status
    /// 0: the relay could not reach the bridge either). Throws `BridgeError.unreachable` when the relay itself is
    /// down.
    func relayCapture(_ audio: Data, meta: CaptureMeta) async throws -> (status: Int, body: Data)
}

extension BridgeRelay {
    /// A relay that can't carry assistant turns.
    public func relayAssistantTurn(_ turn: AssistantTurnRequest) async throws -> AssistantTurnResponse {
        throw BridgeError.unreachable("no turn relay")
    }

    /// A relay without a voice route.
    public func relayTranscription(_ audio: Data, contentType: String,
                                   language: String?) async throws -> (status: Int, body: Data) {
        throw BridgeError.unreachable("no voice relay")
    }

    /// A relay that can't carry voice notes.
    public func relayCapture(_ audio: Data, meta: CaptureMeta) async throws -> (status: Int, body: Data) {
        throw BridgeError.unreachable("no capture relay")
    }
}
