import Foundation

/// The bridge's agent inbox for the Agent Dock (CONTRACTS-WAVE6 §A, `/v1/desktop/inbox*`): loopback + the desktop
/// token, like the rest of the app (`Config.request`). The list is a long poll (`?after=<revision>&wait=25`); the
/// actions are small JSON POSTs. Errors come back as the HTTP status (0 = unreachable, -1 = no desktop token) and the
/// bridge's error code (`{"error":{"code","message","retryable"}}`). Nothing here logs titles, text or tokens.
enum DockAPI {
    struct Failure: Error, Equatable {
        let status: Int
        let code: String?
        let message: String?

        init(status: Int, code: String? = nil, message: String? = nil) {
            self.status = status
            self.code = code
            self.message = message
        }
    }

    /// What an action answers. `how` says where it went ("t3", "terminal", "app", "desktop"); `dismiss` and
    /// `undismiss` give the list's revision once it shows the change.
    struct Reply: Decodable, Equatable {
        var ok: Bool?
        var how: String?
        var opened: Bool?
        var conversationId: String?
        var itemId: String?
        var dismissed: Bool?
        var revision: Int?
    }

    static let longPollWait = 25

    /// A session for the long poll only: its requests wait up to 25 s by design.
    private static let pollSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = TimeInterval(longPollWait + 15)
        configuration.timeoutIntervalForResource = TimeInterval(longPollWait + 30)
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.connectionProxyDictionary = [:]
        return URLSession(configuration: configuration)
    }()

    /// `GET /v1/desktop/inbox` — at once without `after`, else blocking up to `wait` s for a newer revision.
    static func inbox(after revision: Int?, wait: Int) async -> Result<DockInbox, Failure> {
        var query: [URLQueryItem] = []
        if let revision {
            query.append(URLQueryItem(name: "after", value: String(revision)))
            query.append(URLQueryItem(name: "wait", value: String(max(0, min(25, wait)))))
        }
        guard let request = Config.request(Config.api("/v1/desktop/inbox", query: query), timeout: TimeInterval(wait + 15)) else {
            return .failure(Failure(status: -1))
        }
        do {
            let (data, response) = try await pollSession.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { return .failure(failure(status, data)) }
            return .success(try DockInbox.decode(data))
        } catch is DecodingError {
            return .failure(Failure(status: 502, code: "bad_inbox"))
        } catch {
            if (error as? URLError)?.code == .cancelled { return .failure(Failure(status: -2, code: "cancelled")) }
            return .failure(Failure(status: 0))
        }
    }

    static func item(_ id: String) async -> Result<DockItemDetail, Failure> {
        await call("GET", itemPath(id), body: nil)
    }

    static func targets() async -> Result<DockTargets, Failure> {
        await call("GET", "/v1/desktop/inbox/targets", body: nil)
    }

    static func approve(_ id: String, requestId: String, decision: String) async -> Result<Reply, Failure> {
        await call("POST", itemPath(id, "approve"), body: ["requestId": requestId, "decision": decision])
    }

    static func answer(_ id: String, requestId: String, answers: [String: Any]) async -> Result<Reply, Failure> {
        await call("POST", itemPath(id, "answer"), body: ["requestId": requestId, "answers": answers])
    }

    static func reply(_ id: String, text: String) async -> Result<Reply, Failure> {
        await call("POST", itemPath(id, "reply"), body: ["text": text])
    }

    static func stop(_ id: String) async -> Result<Reply, Failure> {
        await call("POST", itemPath(id, "stop"), body: [:])
    }

    static func seen(_ id: String) async -> Result<Reply, Failure> {
        await call("POST", itemPath(id, "seen"), body: [:])
    }

    /// A voice note's `act` (W8): its suggestion, `action` when given; a note that failed is tried again.
    static func act(_ id: String, action: String?) async -> Result<Reply, Failure> {
        await call("POST", itemPath(id, "act"), body: action.map { ["action": $0] } ?? [:])
    }

    static func open(_ id: String) async -> Result<Reply, Failure> {
        await call("POST", itemPath(id, "open"), body: [:])
    }

    /// Hidden until it changes (the bridge's own state: nothing reaches T3, Claude Code or Codex).
    static func dismiss(_ id: String) async -> Result<Reply, Failure> {
        await call("POST", itemPath(id, "dismiss"), body: [:])
    }

    /// The undo of `dismiss`.
    static func undismiss(_ id: String) async -> Result<Reply, Failure> {
        await call("POST", itemPath(id, "undismiss"), body: [:])
    }

    /// `POST /v1/desktop/inbox/new` — a new T3 thread and its first turn.
    static func create(text: String, choice: DockTargets.Choice) async -> Result<Reply, Failure> {
        var body: [String: Any] = ["text": text]
        if let projectId = choice.projectId { body["projectId"] = projectId }
        if let agent = choice.agent { body["agent"] = agent }
        if let model = choice.model { body["model"] = model }
        return await call("POST", "/v1/desktop/inbox/new", body: body)
    }

    /// `/v1/desktop/inbox/items/<id>[/<action>]`. Ids look like `t3:<id>`; anything outside a safe set is escaped
    /// (a `/` in an id must not become a path separator).
    static func itemPath(_ id: String, _ action: String? = nil) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~:"))
        let escaped = id.addingPercentEncoding(withAllowedCharacters: safe) ?? id
        return "/v1/desktop/inbox/items/\(escaped)" + (action.map { "/\($0)" } ?? "")
    }

    private static func call<T: Decodable>(_ method: String, _ path: String, body: [String: Any]?) async -> Result<T, Failure> {
        guard var request = Config.request(url(path), timeout: method == "GET" ? 10 : 20) else {
            return .failure(Failure(status: -1))
        }
        request.httpMethod = method
        if let body {
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else { return .failure(failure(status, data)) }
            if data.isEmpty, let empty = Reply() as? T { return .success(empty) }
            return .success(try JSONDecoder().decode(T.self, from: data))
        } catch is DecodingError {
            return .failure(Failure(status: 502, code: "bad_reply"))
        } catch {
            return .failure(Failure(status: 0))
        }
    }

    /// Config.api sets the path from a string, which would escape the `%` of an escaped id a second time.
    private static func url(_ path: String) -> URL {
        var components = URLComponents(url: Config.origin, resolvingAgainstBaseURL: false)!
        components.percentEncodedPath = path
        return components.url ?? Config.api(path)
    }

    private struct ErrorBody: Decodable {
        struct Inner: Decodable {
            let code: String?
            let message: String?
        }

        let error: Inner?
    }

    private static func failure(_ status: Int, _ data: Data) -> Failure {
        let inner = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
        return Failure(status: status, code: inner?.code, message: inner?.message)
    }
}
