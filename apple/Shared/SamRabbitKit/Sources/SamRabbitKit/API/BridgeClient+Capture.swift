import Foundation

// The voice-note and morning-brief routes (CONTRACTS-WAVE8 §A2–A3), in their own file beside the rest of the
// client.

extension BridgeClient {
    // MARK: - Voice notes

    /// The request line and headers of a voice note (the body is the recording): `POST /v1/mobile/capture[?wait=&
    /// lang=]` with `X-SamRabbit-Capture`, `X-SamRabbit-Captured-At` and `X-SamRabbit-Source`. The id makes it safe
    /// to send again (another address, the relay, after a timeout): the bridge keeps one note per id.
    public func captureRequest(_ meta: CaptureMeta, wait: Int = 0, timeout: TimeInterval = 30) -> BridgeRequest {
        var query: [URLQueryItem] = []
        if wait > 0 { query.append(URLQueryItem(name: "wait", value: String(min(wait, 10)))) }
        if let language = meta.language, !language.isEmpty { query.append(URLQueryItem(name: "lang", value: language)) }
        var request = BridgeRequest(method: "POST", path: "/v1/\(api.rawValue)/capture", query: query, body: nil,
                                    authorized: true, accept: "application/json", timeout: timeout,
                                    contentType: meta.contentType, headers: meta.headers)
        request.idempotent = true
        return request
    }

    /// Sends a voice note (the recording in `file`): directly (each address in turn), else through the relay (the
    /// watch: the iPhone, in chunks). The Mac answers as soon as it stored it (`received`); with `wait` it holds the
    /// answer up to that many seconds for what it did. Throws `BridgeError` (`.unreachable` when neither route got
    /// through: keep it in the outbox).
    public func capture(file: URL, meta: CaptureMeta, wait: Int = 0, timeout: TimeInterval = 30) async throws
        -> CaptureStatus {
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0 else {
            throw BridgeError.server(status: 400, code: "empty_audio", message: "The recording is empty.", retryable: false)
        }
        guard size <= CaptureFormat.maxBytes else {
            throw BridgeError.server(status: 413, code: "body_too_large", message: "That note is too long.",
                                     retryable: false)
        }
        let request = captureRequest(meta, wait: wait, timeout: timeout + TimeInterval(wait))
        return try Self.captureStatus(try await captureUpload(request, .file(file), meta: meta), meta: meta)
    }

    /// The iPhone's side of the watch's relay: the bridge's status and body for a voice note, without throwing for
    /// HTTP errors. Direct only; throws `BridgeError.unreachable` when no address answered.
    public func rawCapture(audio: Data, meta: CaptureMeta, wait: Int = 0, timeout: TimeInterval = 30) async throws
        -> (status: Int, body: Data) {
        do {
            let (body, response) = try await upload(captureRequest(meta, wait: wait, timeout: timeout), .data(audio))
            return (response.statusCode, body)
        } catch let failure as NoRoute {
            throw BridgeError.unreachable(failure.reason)
        }
    }

    /// The `URLRequest` of a voice note for a background upload (`URLSession` background tasks upload from a file and
    /// take one address): to `host`, else the address requests go to first.
    public func captureUploadRequest(_ meta: CaptureMeta, host: BridgeHost? = nil) -> URLRequest? {
        guard let host = host ?? currentHost else { return nil }
        return makeRequest(captureRequest(meta, timeout: 60), host: host)
    }

    /// `GET /v1/mobile/capture/<id>?wait=0..10`: what became of a voice note (held up to `wait` seconds until it
    /// moves on).
    public func captureStatus(_ captureId: String, wait: Int = 0) async throws -> CaptureStatus {
        let seconds = min(max(wait, 0), 10)
        let query = seconds > 0 ? [URLQueryItem(name: "wait", value: String(seconds))] : []
        return try await json(.get("/v1/\(api.rawValue)/capture/\(Self.segment(captureId))", query: query,
                                   timeout: TimeInterval(seconds) + 8))
    }

    /// `GET /v1/mobile/captures?limit=`: the latest voice notes, newest first.
    public func captures(limit: Int = 20) async throws -> [CaptureStatus] {
        let list: CaptureList = try await json(.get("/v1/\(api.rawValue)/captures",
                                                    query: [URLQueryItem(name: "limit", value: String(limit))]))
        return list.captures
    }

    /// `POST /v1/mobile/captures/<id>/act {action}`: does it another way, by his tap (the suggestion's `action`:
    /// `task`, `journal`, `note`, `undo`, ...). Returns the note as it is now when the Mac says.
    @discardableResult
    public func captureAct(_ captureId: String, action: String) async throws -> CaptureStatus? {
        let body = try await data(.post("/v1/\(api.rawValue)/captures/\(Self.segment(captureId))/act",
                                        body: ["action": .string(action)], timeout: 25))
        return try? BridgeJSON.decode(CaptureStatus.self, from: body)
    }

    /// Dismisses a saved voice note (`note:<captureId>`): the inbox's `POST /v1/mobile/inbox/items/<id>/dismiss`, or
    /// on a bridge whose inbox can't dismiss it yet (404, 409 `unsupported_action`) the note's own
    /// `POST …/captures/<id>/act {action: "dismiss"}`.
    public func dismissNote(_ itemId: String) async throws {
        do {
            try await send(.post(Self.inboxPath(itemId, "dismiss"), body: [:]))
        } catch let error as BridgeError where error.isRouteMissing || error.code == "unsupported_action" {
            let key = itemId.hasPrefix("note:") ? String(itemId.dropFirst(5)) : itemId
            try await captureAct(key, action: "dismiss")
        }
    }

    /// Directly, or through the relay first when it is preferred right now, else after the direct route failed (a
    /// note is safe to send again: timeouts move on too).
    private func captureUpload(_ request: BridgeRequest, _ source: UploadBody, meta: CaptureMeta) async throws
        -> (status: Int, body: Data) {
        guard let relay else {
            do {
                let (body, response) = try await upload(request, source)
                return (response.statusCode, body)
            } catch let failure as NoRoute {
                throw BridgeError.unreachable(failure.reason)
            }
        }
        var relayTried = false
        if relay.prefersRelay {
            relayTried = true
            do {
                let answer = try await relay.relayCapture(try source.bytes(), meta: meta)
                // 0: the phone couldn't reach the Mac either; the phone's own refusal (not paired, busy): the Mac never
                // saw it. Either way: try directly.
                if answer.status != 0, !Self.phoneRefused(answer) { return answer }
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
        return try Self.relayed(try await relay.relayCapture(try source.bytes(), meta: meta))
    }

    /// The iPhone turned the watch's relay down itself (`WatchRelay.Response.refusal`: it isn't paired, it passes on
    /// too much right now), so the Mac never saw the note: another way may still get it there.
    static func phoneRefused(_ answer: (status: Int, body: Data)) -> Bool {
        guard !(200..<300).contains(answer.status),
              case .server(_, let code, _, _) = BridgeError.from(status: answer.status, data: answer.body) else { return false }
        return WatchRelay.phoneRefusalCodes.contains(code)
    }

    /// What an upload's answer means (a background upload reads its answer itself): the note as the Mac has it, or
    /// the bridge's error (`isRetryableCapture` says whether to keep it in the outbox).
    public static func captureAnswer(status: Int, body: Data, meta: CaptureMeta) -> Result<CaptureStatus, BridgeError> {
        do {
            return .success(try captureStatus((status, body), meta: meta))
        } catch let error as BridgeError {
            return .failure(error)
        } catch {
            return .failure(.invalidResponse("capture"))
        }
    }

    /// The bridge's answer to an upload as a `CaptureStatus` (an answer without the note's id is this note's).
    static func captureStatus(_ answer: (status: Int, body: Data), meta: CaptureMeta) throws -> CaptureStatus {
        guard (200..<300).contains(answer.status) else { throw BridgeError.from(status: answer.status, data: answer.body) }
        if let status = try? BridgeJSON.decode(CaptureStatus.self, from: answer.body) { return status }
        let value = (try? BridgeJSON.decode(JSONValue.self, from: answer.body)) ?? .null
        return CaptureStatus(captureId: meta.captureId, state: CaptureState(raw: value["state"].text))
    }

    // MARK: - The morning brief

    /// `GET /v1/mobile/briefing[?after=&wait=]`: today's brief (with `after` = the revision last seen and `wait` up
    /// to 25 s, the Mac answers once it changed). An older bridge answers 404 (`BridgeError.isRouteMissing`).
    public func briefing(after revision: Int64? = nil, wait: Int? = nil, timeout: TimeInterval? = nil) async throws
        -> Briefing {
        var query: [URLQueryItem] = []
        if let revision { query.append(URLQueryItem(name: "after", value: String(revision))) }
        let seconds = wait.map { min(max($0, 0), 25) }
        if let seconds, seconds > 0 { query.append(URLQueryItem(name: "wait", value: String(seconds))) }
        let budget = timeout ?? (seconds.map { TimeInterval($0) + 10 } ?? 15)
        return try await json(.get("/v1/\(api.rawValue)/briefing", query: query, timeout: budget))
    }

    /// `POST /v1/mobile/briefing/refresh`: builds it again now (at most every five minutes on the Mac).
    public func refreshBriefing() async throws {
        try await send(.post("/v1/\(api.rawValue)/briefing/refresh", body: [:], timeout: 15))
    }

    /// `POST /v1/mobile/briefing/items/<id>/act {action, …}`: one of the item's buttons, by his tap. A draft reply
    /// becomes a Gmail draft (never sent) and comes back with its link. `options`: the verb's own words (Remind me's
    /// `in`: `1h`, `2pm`, `tonight`, `tomorrow`; Block's `minutes`).
    public func briefingAct(_ itemId: String, action: String, options: [String: JSONValue] = [:]) async throws
        -> BriefingActResult {
        var fields = options
        fields["action"] = .string(action)
        let body = try await data(.post("/v1/\(api.rawValue)/briefing/items/\(Self.segment(itemId))/act",
                                        body: fields, timeout: 45))
        return (try? BridgeJSON.decode(BriefingActResult.self, from: body)) ?? BriefingActResult()
    }
}
