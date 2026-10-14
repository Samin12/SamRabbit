import Foundation
import Synchronization

/// Voice notes on their way to the Mac, kept on the device until the bridge has them. Each one is two files in
/// one folder (the App Group's `Captures/`): the recording `<captureId>.m4a` and `<captureId>.json` (`Entry`).
///
/// A note stays `waiting` (its recording kept) until the bridge answered the upload with `received` or later;
/// then the recording is deleted and the entry kept a day (`sent`, with what the Mac did) for the screens that
/// show it. Only a refusal that sending again can't change (`BridgeError.finalCaptureCodes`: too long, not audio,
/// another recording under its id) ends it `failed`. The watch's notes it handed to the iPhone
/// (`WCSession.transferFile`) are `handedOff` once the transfer finished. Waiting notes are tried again with a
/// growing pause (`backoff`), dropped after seven days, and at most `maxEntries` are kept. Nothing here logs what
/// was said: the recordings are never read but to upload them.
public final class CaptureOutbox: Sendable {
    public enum State: String, Codable, Sendable, Equatable {
        case waiting, sent, failed, handedOff
    }

    public struct Entry: Codable, Sendable, Equatable, Identifiable {
        public var meta: CaptureMeta
        public var state: State
        public var attempts: Int
        /// Not tried again before this (nil: now).
        public var nextAttemptAt: Date?
        /// The last problem (an error code, never content).
        public var lastError: String?
        /// The Mac's answer once it had it.
        public var status: CaptureStatus?
        /// When it reached the Mac (or was handed off, or failed for good).
        public var settledAt: Date?
        /// The iPhone sends this note for its watch (it came with `transferFile`): with the watch's own token.
        public var relayedFor: CaptureDevice?

        public var id: String { meta.captureId }

        public init(meta: CaptureMeta, state: State = .waiting, attempts: Int = 0, nextAttemptAt: Date? = nil,
                    lastError: String? = nil, status: CaptureStatus? = nil, settledAt: Date? = nil,
                    relayedFor: CaptureDevice? = nil) {
            self.meta = meta
            self.state = state
            self.attempts = attempts
            self.nextAttemptAt = nextAttemptAt
            self.lastError = lastError
            self.status = status
            self.settledAt = settledAt
            self.relayedFor = relayedFor
        }
    }

    /// How many notes are kept at most (the oldest settled ones go first, then the oldest waiting).
    public static let maxEntries = 50
    /// Waiting notes older than this are given up.
    public static let maxAge: TimeInterval = 7 * 86_400
    /// Settled entries are kept this long (for "Sent ✓" on the screens), then forgotten.
    public static let settledAge: TimeInterval = 86_400

    public static let shared = CaptureOutbox(folder: SharedContainer.shared.url("Captures"))

    public let folder: URL
    private let lock = Mutex(())

    public init(folder: URL) {
        self.folder = folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// A test outbox in its own temporary folder.
    public static func temporary() -> CaptureOutbox {
        CaptureOutbox(folder: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("samrabbit-captures-\(UUID().uuidString)", isDirectory: true))
    }

    /// The pause before attempt `attempts + 1`: 5 s, 30 s, 2 min, then every 10 min.
    public static func backoff(after attempts: Int) -> TimeInterval {
        switch attempts {
        case ..<1: 0
        case 1: 5
        case 2: 30
        case 3: 120
        default: 600
        }
    }

    public func audioURL(_ id: String) -> URL { folder.appendingPathComponent("\(id).\(VoiceFormat.fileExtension)") }
    private func entryURL(_ id: String) -> URL { folder.appendingPathComponent("\(id).json") }

    // MARK: - Adding

    /// Moves a finished recording in (`recording` is gone afterwards) and records it as waiting. A note with this
    /// id already here is left as it is (the same recording sent again).
    @discardableResult
    public func add(recording: URL, meta: CaptureMeta, relayedFor: CaptureDevice? = nil) throws -> Entry {
        guard CaptureMeta.isValid(meta.captureId) else { throw CocoaError(.fileWriteInvalidFileName) }
        return try lock.withLock { _ in
            if let existing = read(meta.captureId) {
                try? FileManager.default.removeItem(at: recording)
                return existing
            }
            let target = audioURL(meta.captureId)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: recording, to: target)
            Self.protect(target)
            let entry = Entry(meta: meta, relayedFor: relayedFor)
            write(entry)
            return entry
        }
    }

    // MARK: - Reading

    public func entry(_ id: String) -> Entry? { lock.withLock { _ in read(id) } }

    /// Every entry, oldest first.
    public func entries() -> [Entry] {
        lock.withLock { _ in readAll() }
    }

    /// The waiting notes whose pause is over, oldest first, but those in `excluding` (on their way now: an upload
    /// still running is not started again).
    public func due(now: Date = .now, excluding: Set<String> = []) -> [Entry] {
        entries().filter {
            $0.state == .waiting && ($0.nextAttemptAt ?? .distantPast) <= now && !excluding.contains($0.id)
        }
    }

    /// How many notes still wait for the Mac.
    public var waiting: Int { entries().filter { $0.state == .waiting }.count }

    /// When the next waiting note is due (nil: none waits), but those in `excluding` (on their way now: their
    /// upload's end decides what comes next, so nothing ticks while it runs).
    public func nextDue(now: Date = .now, excluding: Set<String> = []) -> Date? {
        entries().filter { $0.state == .waiting && !excluding.contains($0.id) }
            .map { max(now, $0.nextAttemptAt ?? now) }.min()
    }

    // MARK: - Outcomes

    /// The Mac has it: the recording goes, the answer stays a day.
    @discardableResult
    public func delivered(_ id: String, status: CaptureStatus?, now: Date = .now) -> Entry? {
        update(id) { entry in
            entry.state = .sent
            entry.status = status ?? entry.status
            entry.settledAt = entry.settledAt ?? now
            entry.lastError = nil
            entry.nextAttemptAt = nil
            try? FileManager.default.removeItem(at: audioURL(id))
        }
    }

    /// A later answer about a note that was sent (`GET …/capture/<id>`).
    @discardableResult
    public func record(_ status: CaptureStatus) -> Entry? {
        update(status.captureId) { entry in entry.status = status }
    }

    /// An attempt that didn't get through: tried again after `backoff`, or (`retryable: false`) given up.
    @discardableResult
    public func failed(_ id: String, error: String, retryable: Bool, now: Date = .now) -> Entry? {
        update(id) { entry in
            entry.attempts += 1
            entry.lastError = Formatting.clip(error, 80)
            if retryable {
                entry.nextAttemptAt = now.addingTimeInterval(Self.backoff(after: entry.attempts))
            } else {
                entry.state = .failed
                entry.settledAt = now
                entry.nextAttemptAt = nil
                try? FileManager.default.removeItem(at: audioURL(id))
            }
        }
    }

    /// The watch gave the recording to the iPhone, which sends it on (the transfer finished).
    @discardableResult
    public func handedOff(_ id: String, now: Date = .now) -> Entry? {
        update(id) { entry in
            entry.state = .handedOff
            entry.settledAt = now
            entry.nextAttemptAt = nil
            try? FileManager.default.removeItem(at: audioURL(id))
        }
    }

    /// Try every waiting note at once (the Mac is back, the app came to the front).
    public func retryNow() {
        lock.withLock { _ in
            for var entry in readAll() where entry.state == .waiting && entry.nextAttemptAt != nil {
                entry.nextAttemptAt = nil
                write(entry)
            }
        }
    }

    /// Forgets a note and its recording.
    public func remove(_ id: String) {
        lock.withLock { _ in
            try? FileManager.default.removeItem(at: audioURL(id))
            try? FileManager.default.removeItem(at: entryURL(id))
        }
    }

    /// Drops settled entries older than a day, waiting ones older than seven days (and any whose recording went
    /// missing), stray files, and the oldest beyond `maxEntries` (settled ones first). Returns how many went.
    @discardableResult
    public func prune(now: Date = .now) -> Int {
        lock.withLock { _ in
            var removed = 0
            var kept: [Entry] = []
            for entry in readAll() {
                let id = entry.id
                let old: Bool
                switch entry.state {
                case .waiting:
                    old = now.timeIntervalSince(entry.meta.capturedAt) > Self.maxAge
                        || !FileManager.default.fileExists(atPath: audioURL(id).path)
                case .sent, .failed, .handedOff:
                    old = now.timeIntervalSince(entry.settledAt ?? entry.meta.capturedAt) > Self.settledAge
                }
                if old {
                    drop(id)
                    removed += 1
                } else {
                    kept.append(entry)
                }
            }
            if kept.count > Self.maxEntries {
                let settled = kept.filter { $0.state != .waiting }
                let waiting = kept.filter { $0.state == .waiting }
                let excess = kept.count - Self.maxEntries
                for entry in (settled + waiting).prefix(excess) {
                    drop(entry.id)
                    removed += 1
                }
            }
            // Recordings without an entry (a crash between the move and the write).
            let ids = Set(readAll().map(\.id))
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            for name in names where name.hasSuffix(".\(VoiceFormat.fileExtension)") {
                let id = String(name.dropLast(VoiceFormat.fileExtension.count + 1))
                if !ids.contains(id) {
                    try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
                    removed += 1
                }
            }
            return removed
        }
    }

    // MARK: - Files (under the lock)

    private func update(_ id: String, _ change: (inout Entry) -> Void) -> Entry? {
        lock.withLock { _ in
            guard var entry = read(id) else { return nil }
            change(&entry)
            write(entry)
            return entry
        }
    }

    private func drop(_ id: String) {
        try? FileManager.default.removeItem(at: audioURL(id))
        try? FileManager.default.removeItem(at: entryURL(id))
    }

    private func read(_ id: String) -> Entry? {
        guard let data = try? Data(contentsOf: entryURL(id)) else { return nil }
        return try? BridgeJSON.decode(Entry.self, from: data)
    }

    private func readAll() -> [Entry] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }
            .compactMap { read(String($0.dropLast(5))) }
            .sorted { $0.meta.capturedAt < $1.meta.capturedAt }
    }

    private func write(_ entry: Entry) {
        guard let data = try? BridgeJSON.encoder().encode(entry) else { return }
        let url = entryURL(entry.id)
        #if os(iOS) || os(watchOS)
        // Readable after the first unlock: the upload finishes with the phone locked.
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try? data.write(to: url, options: [.atomic])
        #endif
    }

    private static func protect(_ url: URL) {
        #if os(iOS) || os(watchOS)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                               ofItemAtPath: url.path)
        #endif
    }
}
