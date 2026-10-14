import Foundation
import Synchronization

/// A voice recording sent from the Apple Watch through the iPhone when the watch can't reach the Mac
/// itself. WatchConnectivity messages are small, so the recording travels as raw `Data` chunks of at most
/// 40 KB (`id`, `seq`, `of`), one `sendMessage` each, in order: the phone acknowledges each chunk
/// (`ackKey`), puts the recording back together (`Assembler`) and, with the last chunk, uploads it to
/// `POST /v1/mobile/transcribe` with the watch's own child token (`BridgeAccount.performRelayedTranscription`,
/// the same rules as `performRelayed`). Its reply to the last chunk is the bridge's answer
/// (`WatchRelay.Response`: status and body), so the watch reads exactly what the bridge said.
public enum VoiceRelay {
    /// The chunk's header (JSON: id, seq, of, contentType, language).
    public static let chunkKey = "samrabbit.voice"
    /// The chunk's bytes (raw `Data`).
    public static let dataKey = "samrabbit.voice.data"
    /// The phone's reply to a chunk it kept (the chunk's `seq`).
    public static let ackKey = "samrabbit.voice.ack"
    public static let chunkSize = 40 * 1024
    public static let maxChunks = (VoiceFormat.maxBytes + chunkSize - 1) / chunkSize
    /// The phone drops a recording whose chunks stopped coming this long ago.
    static let expiry: TimeInterval = 90
    /// Recordings the phone puts together at once (the watch sends one at a time).
    static let maxOpen = 3

    public struct Chunk: Sendable, Equatable {
        public var id: String
        public var seq: Int
        public var of: Int
        public var contentType: String
        public var language: String?
        /// What the recording is for: nil (or `transcribe`) for words back, `turn` for an assistant turn
        /// (`TurnRelay`: the phone keeps it until the turn starts), `capture` for a voice note (`capture` says
        /// which, and when it was said).
        public var purpose: String?
        /// A voice note's id, time and source (`purpose == VoiceRelay.capturePurpose`).
        public var capture: CaptureMeta?
        public var data: Data

        public init(id: String, seq: Int, of: Int, contentType: String, language: String?, purpose: String? = nil,
                    capture: CaptureMeta? = nil, data: Data) {
            self.id = id
            self.seq = seq
            self.of = of
            self.contentType = contentType
            self.language = language
            self.purpose = purpose
            self.capture = capture
            self.data = data
        }

        private struct Header: Codable {
            var id: String
            var seq: Int
            var of: Int
            var contentType: String
            var language: String?
            var purpose: String?
            var capture: CaptureMeta?
        }

        public var isLast: Bool { seq == of - 1 }

        /// The `sendMessage` dictionary: a small JSON header and the raw bytes.
        public var message: [String: Any] {
            let header = Header(id: id, seq: seq, of: of, contentType: contentType, language: language, purpose: purpose,
                                capture: capture)
            guard let encoded = try? JSONEncoder().encode(header) else { return [:] }
            return [VoiceRelay.chunkKey: encoded, VoiceRelay.dataKey: data]
        }

        public init?(message: [String: Any]) {
            guard let encoded = message[VoiceRelay.chunkKey] as? Data,
                  let header = try? JSONDecoder().decode(Header.self, from: encoded),
                  let data = message[VoiceRelay.dataKey] as? Data else { return nil }
            self.init(id: header.id, seq: header.seq, of: header.of, contentType: header.contentType,
                      language: header.language, purpose: header.purpose, capture: header.capture, data: data)
        }
    }

    /// Splits a recording into chunks of at most `chunkSize` bytes (one empty chunk for no data).
    public static func chunks(of data: Data, id: String = UUID().uuidString, contentType: String = VoiceFormat.contentType,
                              language: String? = nil, purpose: String? = nil, capture: CaptureMeta? = nil,
                              size: Int = chunkSize) -> [Chunk] {
        let size = max(1, size)
        let count = max(1, (data.count + size - 1) / size)
        return (0..<count).map { seq in
            let start = data.startIndex + seq * size
            let end = min(data.endIndex, start + size)
            return Chunk(id: id, seq: seq, of: count, contentType: contentType, language: language, purpose: purpose,
                         capture: capture, data: Data(data[start..<end]))
        }
    }

    /// A whole recording, put back together on the phone.
    public struct Upload: Sendable, Equatable {
        public var id: String
        public var contentType: String
        public var language: String?
        public var purpose: String?
        /// A voice note's id, time and source (`purpose == VoiceRelay.capturePurpose`).
        public var capture: CaptureMeta?
        public var data: Data
    }

    /// The purpose of a voice note's chunks: the phone uploads it to `POST /v1/mobile/capture`.
    public static let capturePurpose = "capture"

    /// The phone's side: collects chunks by recording id until every one arrived. Thread-safe.
    public final class Assembler: Sendable {
        public enum Outcome: Sendable, Equatable {
            /// Kept; more to come.
            case waiting(received: Int)
            /// The last missing chunk: the whole recording.
            case complete(Upload)
            /// Not a chunk the phone takes (answered with the bridge's error envelope; the recording is dropped).
            case refused(WatchRelay.Response)
        }

        private struct Partial {
            var of: Int
            var contentType: String
            var language: String?
            var purpose: String?
            var capture: CaptureMeta?
            var parts: [Int: Data]
            var bytes: Int
            var touched: Date
        }

        private let open = Mutex<[String: Partial]>([:])

        public init() {}

        /// How many recordings are being put together.
        public var pending: Int { open.withLock { $0.count } }

        public func add(_ chunk: Chunk, now: Date = .now) -> Outcome {
            if let problem = Self.check(chunk) { return .refused(problem) }
            return open.withLock { open -> Outcome in
                open = open.filter { now.timeIntervalSince($0.value.touched) < VoiceRelay.expiry }
                var partial = open[chunk.id] ?? Partial(of: chunk.of, contentType: chunk.contentType,
                                                        language: chunk.language, purpose: chunk.purpose,
                                                        capture: chunk.capture, parts: [:], bytes: 0, touched: now)
                guard partial.of == chunk.of, partial.contentType == chunk.contentType,
                      partial.language == chunk.language else {
                    open[chunk.id] = nil
                    return .refused(.refusal(400, "invalid_audio", "The recording's pieces don't match."))
                }
                if open[chunk.id] == nil, open.count >= VoiceRelay.maxOpen {
                    return .refused(.refusal(503, "transcribe_busy", "The iPhone is passing on other recordings."))
                }
                partial.bytes += chunk.data.count - (partial.parts[chunk.seq]?.count ?? 0)
                partial.parts[chunk.seq] = chunk.data
                partial.touched = now
                guard partial.bytes <= VoiceFormat.maxBytes else {
                    open[chunk.id] = nil
                    return .refused(.refusal(413, "body_too_large", "Recordings can be at most 2 MB."))
                }
                guard partial.parts.count == partial.of else {
                    open[chunk.id] = partial
                    return .waiting(received: partial.parts.count)
                }
                open[chunk.id] = nil
                var data = Data(capacity: partial.bytes)
                for seq in 0..<partial.of { data.append(partial.parts[seq] ?? Data()) }
                return .complete(Upload(id: chunk.id, contentType: partial.contentType, language: partial.language,
                                        purpose: partial.purpose, capture: partial.capture, data: data))
            }
        }

        /// Forgets every recording (the pairing changed).
        public func reset() { open.withLock { $0.removeAll() } }

        static func check(_ chunk: Chunk) -> WatchRelay.Response? {
            let idOK = (1...64).contains(chunk.id.count)
                && chunk.id.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-") }
            guard idOK, (1...VoiceRelay.maxChunks).contains(chunk.of), (0..<chunk.of).contains(chunk.seq),
                  chunk.data.count <= VoiceRelay.chunkSize else {
                return .refusal(400, "invalid_audio", "That isn't a piece of a recording.")
            }
            guard VoiceFormat.acceptedTypes.contains(chunk.contentType) else {
                return .refusal(415, "unsupported_audio", "Send the recording as audio/mp4.")
            }
            if let language = chunk.language {
                let ok = (2...35).contains(language.count)
                    && language.unicodeScalars.allSatisfy {
                        $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_")
                    }
                guard ok else { return .refusal(400, "invalid_lang", "lang must be a language tag such as en-US.") }
            }
            return nil
        }
    }
}
