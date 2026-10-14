import Foundation

/// The bridge's capture routes for voice notes (CONTRACTS-WAVE8 §A2), through its desktop API: loopback and the desktop
/// token, like the rest of the app. `POST /v1/desktop/capture` takes the WAV with the note's id (the same id is the same
/// note, so a retry never makes a second) and answers 202 `received` at once; `GET /v1/desktop/capture/<id>?wait=` says
/// what the bridge heard and did. Nothing here logs what was said.
enum VoiceNoteAPI {
    /// Uploads and long polls: their own session, no proxy, no cache.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 40
        configuration.timeoutIntervalForResource = 90
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.connectionProxyDictionary = [:]
        return URLSession(configuration: configuration)
    }()

    private static func request(_ path: String, query: [URLQueryItem] = [], timeout: TimeInterval) -> URLRequest? {
        guard let token = Config.token(), var components = URLComponents(url: Config.origin, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue(token, forHTTPHeaderField: Config.tokenHeader)
        return request
    }

    /// `POST /v1/desktop/capture` with the note's WAV.
    static func upload(_ wav: Data, item: VoiceNoteOutbox.Item) async -> VoiceNoteDelivery {
        guard var request = request("/v1/desktop/capture", timeout: 40) else {
            return VoiceNoteDelivery.classify(status: -1, body: Data(), captureId: item.captureId)
        }
        request.httpMethod = "POST"
        for (name, value) in VoiceNoteUpload.headers(captureId: item.captureId, capturedAt: item.capturedAt) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        do {
            let (data, response) = try await session.upload(for: request, from: wav)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return VoiceNoteDelivery.classify(status: status, body: data, captureId: item.captureId)
        } catch {
            return VoiceNoteDelivery.classify(status: 0, body: Data(), captureId: item.captureId)
        }
    }

    /// `GET /v1/desktop/capture/<id>?wait=<s>`: nil when the bridge can't say.
    static func status(_ id: String, wait: Int) async -> CaptureStatus? {
        guard VoiceNoteUpload.isCaptureId(id),
              let request = request("/v1/desktop/capture/\(id)", query: [URLQueryItem(name: "wait", value: String(max(0, min(10, wait))))],
                                    timeout: TimeInterval(wait + 10)) else { return nil }
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return CaptureStatus.decode(data, fallbackId: id)
    }
}
