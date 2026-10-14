import Foundation
import Network
import os
import SamRabbitKit
import Synchronization
import UIKit

private let uploadLog = Logger(subsystem: "com.samrabbit.mobile", category: "capture")

/// Sends the voice notes in the outbox (`CaptureOutbox`, the App Group's `Captures/`) to the Mac. With SamRabbit in
/// front a note goes at once (a plain upload over the bridge's addresses, LAN then Tailscale, 15 s); in the background
/// (the phone locked while it recorded), or after a quick try failed, it goes with a background `URLSession`
/// (`uploadTask(with:fromFile:)`), which finishes even if SamRabbit is suspended, and iOS wakes the app for its
/// answer (`handleEventsForBackgroundURLSession`).
///
/// A note leaves the outbox's waiting list only when the Mac answered `received` (or later). A connection that fails
/// or a Mac that is busy keeps it for another try (5 s, 30 s, 2 min, then every 10 min; each try the next address);
/// a refusal that sending again can't change ends it. It tries again when the app comes to the front, when the
/// network comes back (`NWPathMonitor`), in the background refresh and after each new note. Notes the Apple Watch
/// handed over (`WCSession.transferFile`) go with the watch's own token. Nothing about what was said is ever logged:
/// ids and status codes only.
final class CaptureUploader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = CaptureUploader()
    static let sessionIdentifier = "com.samrabbit.mobile.capture"

    let outbox: CaptureOutbox
    private let account: BridgeAccount

    private struct State {
        /// Answer bodies by task.
        var bodies: [Int: Data] = [:]
        /// Who waits for a note's answer (the recorder), by capture id.
        var waiters: [String: [CheckedContinuation<Result<CaptureStatus, BridgeError>, Never>]] = [:]
        /// Notes being uploaded now, by capture id.
        var inFlight: Set<String> = []
        /// iOS's completion for a background launch, called once the session's events are delivered.
        var eventsDone: (@Sendable () -> Void)?
        var retry: Task<Void, Never>?
    }

    private let state = Mutex(State())
    private let monitor = NWPathMonitor()
    private var session: URLSession!

    init(outbox: CaptureOutbox = .shared, account: BridgeAccount = .shared) {
        self.outbox = outbox
        self.account = account
        super.init()
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.allowsCellularAccess = true
        // A background upload that can't get through in ten minutes fails, and the outbox's next try takes over.
        configuration.timeoutIntervalForResource = 10 * 60
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        // Uploads still running from before (the app was suspended or relaunched).
        session.getAllTasks { [weak self] tasks in
            let ids = tasks.filter { $0.state == .running }.compactMap(\.taskDescription)
            self?.state.withLock { $0.inFlight.formUnion(ids) }
        }
        monitor.pathUpdateHandler = { [weak self] path in
            if path.status == .satisfied { self?.flush() }
        }
        monitor.start(queue: DispatchQueue(label: "com.samrabbit.mobile.capture.path"))
    }

    /// How many notes still wait for the Mac.
    var waiting: Int { outbox.waiting }

    // MARK: - Sending

    /// Sends one note now (unless it is on its way already) and returns the Mac's answer once the upload finished:
    /// the note as the Mac has it, or why it didn't go (it stays in the outbox when `isRetryableCapture`). `quick`:
    /// SamRabbit is in front, so a plain upload goes first; if it can't get through, the background upload carries
    /// on (the answer is the quick try's).
    func send(_ entry: CaptureOutbox.Entry, quick: Bool) async -> Result<CaptureStatus, BridgeError> {
        if quick, let client = client(for: entry) {
            let started = state.withLock { state -> Bool in state.inFlight.insert(entry.id).inserted }
            guard started else { return await wait(for: entry) }
            let result = await BridgeError.capture {
                try await client.capture(file: self.outbox.audioURL(entry.id), meta: entry.meta, timeout: 15)
            }
            if case .failure(let error) = result, error.isRetryableCapture {
                // Out of reach now: the background upload keeps trying (the app may be suspended any moment).
                outbox.failed(entry.id, error: error.code ?? Self.word(error), retryable: true)
                if let fresh = outbox.entry(entry.id) { start(fresh) }
                return result
            }
            finish(entry.id, result)
            return result
        }
        return await wait(for: entry)
    }

    /// The background upload's answer (it starts one unless it is on its way already).
    private func wait(for entry: CaptureOutbox.Entry) async -> Result<CaptureStatus, BridgeError> {
        await withCheckedContinuation { continuation in
            let already = state.withLock { state -> Bool in
                state.waiters[entry.id, default: []].append(continuation)
                return !state.inFlight.insert(entry.id).inserted
            }
            if !already { start(entry) }
        }
    }

    /// Sends every note whose pause is over (fire and forget: the outbox keeps the result); `quick` with SamRabbit in
    /// front.
    func flush(quick: Bool = false) {
        outbox.prune()
        for entry in outbox.due() {
            if quick {
                Task { _ = await self.send(entry, quick: true) }
                continue
            }
            let busy = state.withLock { state -> Bool in !state.inFlight.insert(entry.id).inserted }
            if !busy { start(entry) }
        }
        scheduleRetry()
    }

    /// The client a note goes with: the watch's own token for a note it handed over.
    private func client(for entry: CaptureOutbox.Entry) -> BridgeClient? {
        entry.relayedFor == .watch ? account.watchClient() ?? account.client() : account.client()
    }

    private func start(_ entry: CaptureOutbox.Entry) {
        state.withLock { _ = $0.inFlight.insert(entry.id) }
        guard let client = client(for: entry), !client.hosts.isEmpty else {
            finish(entry.id, .failure(.notPaired), retryable: true)
            return
        }
        // Each try the next address (the first is the one that answered last).
        let host = client.hosts[entry.attempts % client.hosts.count]
        let audio = outbox.audioURL(entry.id)
        guard FileManager.default.fileExists(atPath: audio.path), var request = client.captureUploadRequest(entry.meta, host: host) else {
            finish(entry.id, .failure(.invalidResponse("the recording is missing")), retryable: false)
            return
        }
        if entry.relayedFor == .watch { request.setValue("watch", forHTTPHeaderField: "X-SamRabbit-Relayed-For") }
        request.timeoutInterval = 45
        let task = session.uploadTask(with: request, fromFile: audio)
        task.taskDescription = entry.id
        uploadLog.info("capture upload \(entry.id.prefix(8), privacy: .public) try \(entry.attempts + 1)")
        task.resume()
    }

    /// Records the answer in the outbox and wakes whoever waits for it.
    private func finish(_ id: String, _ result: Result<CaptureStatus, BridgeError>, retryable: Bool? = nil) {
        switch result {
        case .success(let status):
            outbox.delivered(id, status: status)
            uploadLog.info("capture \(id.prefix(8), privacy: .public) received")
        case .failure(let error):
            let again = retryable ?? error.isRetryableCapture
            outbox.failed(id, error: error.code ?? Self.word(error), retryable: again)
            uploadLog.notice("capture \(id.prefix(8), privacy: .public) not sent: \(error.code ?? Self.word(error), privacy: .public)")
        }
        let waiters = state.withLock { state -> [CheckedContinuation<Result<CaptureStatus, BridgeError>, Never>] in
            state.inFlight.remove(id)
            return state.waiters.removeValue(forKey: id) ?? []
        }
        for waiter in waiters { waiter.resume(returning: result) }
        scheduleRetry()
    }

    /// While the app runs: the next try when the next note's pause is over.
    private func scheduleRetry() {
        guard let next = outbox.nextDue() else { return }
        let delay = max(1, next.timeIntervalSinceNow)
        state.withLock { state in
            state.retry?.cancel()
            state.retry = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                let quick = await MainActor.run { UIApplication.shared.applicationState == .active }
                self?.flush(quick: quick)
            }
        }
    }

    private static func word(_ error: BridgeError) -> String {
        switch error {
        case .unreachable: "unreachable"
        case .invalidResponse: "invalid_response"
        case .cancelled: "cancelled"
        case .notPaired: "not_paired"
        case .unauthorized: "unauthorized"
        case .server(let status, _, _, _): "http_\(status)"
        }
    }

    // MARK: - Background launches

    /// iOS launched (or woke) the app for this session's events: `completion` once they are delivered.
    func handleEvents(_ completion: @escaping @Sendable () -> Void) {
        state.withLock { $0.eventsDone = completion }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let done = state.withLock { state -> (@Sendable () -> Void)? in
            defer { state.eventsDone = nil }
            return state.eventsDone
        }
        if let done { DispatchQueue.main.async { done() } }
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        state.withLock { $0.bodies[dataTask.taskIdentifier, default: Data()].append(data) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let body = state.withLock { $0.bodies.removeValue(forKey: task.taskIdentifier) } ?? Data()
        guard let id = task.taskDescription else { return }
        guard let entry = outbox.entry(id) else {
            state.withLock { _ = $0.inFlight.remove(id) }
            return
        }
        if let error {
            let code = (error as? URLError)?.code
            finish(id, .failure(.unreachable(code.map { "URLError(\($0.rawValue))" } ?? "upload failed")), retryable: true)
            return
        }
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        finish(id, BridgeClient.captureAnswer(status: status, body: body, meta: entry.meta))
    }
}
