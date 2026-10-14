import Foundation

// The pure parts of the Mac voice: for the "Hey Rabbit" listener (`VoiceWake`) which words count as the phrase, what
// one recognizer run's results say about it, when the room is loud enough to be worth transcribing, the last seconds
// of sound kept for what followed the phrase, which microphone to listen with and how to come back after the
// recognizer failed; for the conversation when talking over a reply counts as barging in. Foundation only, so
// `companion/desktop/tests/voice/run.sh` tests them without a microphone.

/// Finds a wake phrase ("hey rabbit", "hey sam rabbit", "okay rabbit") in the words of an on-device transcript.
///
/// Words are compared normalized: lower case, without punctuation or apostrophes ("Rabbit," and "rabbit's" are
/// "rabbit" and "rabbits"), hyphens split words, "SamRabbit" is "sam rabbit". A recognizer writes some words a few
/// ways, so each word of a phrase also matches what it is commonly heard as ("ok" for "okay", "hay" for "hey",
/// "rabbits"/"rabid" for "rabbit"). The phrase's words must follow each other; anything may come before or after it.
struct WakePhraseMatcher: Equatable {
    static let defaultPhrases = ["hey rabbit", "hey sam rabbit", "okay rabbit"]

    /// What a recognizer may write for a word of a phrase (the word itself included).
    static let heardAs: [String: Set<String>] = [
        "hey": ["hey", "hay", "hei", "heyy", "hej"],
        "okay": ["okay", "ok", "okey", "okie"],
        "rabbit": ["rabbit", "rabbits", "rabbi", "rabid", "rabbitt", "rabbet"],
        "sam": ["sam", "sams"],
    ]

    /// Single words that are two words of a phrase.
    static let compounds: [String: [String]] = [
        "samrabbit": ["sam", "rabbit"], "samrabbits": ["sam", "rabbits"], "heyrabbit": ["hey", "rabbit"],
        "okrabbit": ["ok", "rabbit"], "okayrabbit": ["okay", "rabbit"],
    ]

    /// Each phrase as its normalized words (phrases that normalize to nothing are dropped).
    let phrases: [[String]]

    init(phrases: [String] = WakePhraseMatcher.defaultPhrases) {
        let parsed = phrases.map { phrase in Self.tokens(phrase).map(\.word) }.filter { !$0.isEmpty }
        self.phrases = parsed.isEmpty ? Self.defaultPhrases.map { Self.tokens($0).map(\.word) } : parsed
    }

    /// The normalized words of a text, each with the index of the word it came from (split on white space).
    static func tokens(_ text: String) -> [(word: String, source: Int)] {
        tokens(words: text.split(whereSeparator: \.isWhitespace).map(String.init))
    }

    /// The normalized words of transcript words, each with the index of the word it came from.
    static func tokens(words: [String]) -> [(word: String, source: Int)] {
        var result: [(word: String, source: Int)] = []
        for (index, raw) in words.enumerated() {
            for part in raw.lowercased().split(whereSeparator: { $0 == "-" || $0 == "–" || $0 == "/" }) {
                let word = String(part.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
                    .map(Character.init))
                guard !word.isEmpty else { continue }
                for piece in compounds[word] ?? [word] { result.append((piece, index)) }
            }
        }
        return result
    }

    /// Whether `heard` (a normalized word) may be the phrase's `word`.
    static func sounds(_ heard: String, like word: String) -> Bool {
        heardAs[word]?.contains(heard) ?? (heard == word)
    }

    /// The range of `words` (transcript words, punctuation and all) that is a wake phrase, or nil. The earliest
    /// phrase wins; at one position the longest ("hey sam rabbit" over a phrase it starts with).
    func match(words: [String]) -> Range<Int>? {
        let tokens = Self.tokens(words: words)
        guard !tokens.isEmpty else { return nil }
        let longestFirst = phrases.sorted { $0.count > $1.count }
        for start in tokens.indices {
            for phrase in longestFirst where start + phrase.count <= tokens.count {
                let found = phrase.indices.allSatisfy { Self.sounds(tokens[start + $0].word, like: phrase[$0]) }
                if found { return tokens[start].source..<(tokens[start + phrase.count - 1].source + 1) }
            }
        }
        return nil
    }

    func matches(_ text: String) -> Bool {
        match(words: text.split(whereSeparator: \.isWhitespace).map(String.init)) != nil
    }
}

/// What one recognizer run (one stretch of sound the gate let through, `VoiceWake`) says about the wake phrase.
///
/// * A final result with the phrase is the phrase: its words' times say where it ended. The last words of the run's
///   previous final count too, so a phrase the recognizer finalized in two pieces is still found.
/// * A partial (volatile) result with the phrase asks for the final words at once (`finalizeNow`, once until the
///   next final): partial results carry no times of their own words, so they can't say where the phrase ended.
/// * A run that ends with the phrase in its last partial results (two in a row) and in no final heard it too (the
///   recognizer's final pass can drop the first words of a stretch): the phrase ended where the sound did.
struct WakeRunWords: Equatable {
    struct Word: Equatable {
        var text: String
        /// Where the word ended, seconds into the run (nil: the recognizer didn't say).
        var end: Double?
    }

    enum Verdict: Equatable {
        case none
        /// Ask the recognizer for its final words now.
        case finalizeNow
        /// The phrase, ending here (seconds into the run; nil: where the sound ended).
        case heard(end: Double?)
    }

    let matcher: WakePhraseMatcher
    /// The last words of the previous final.
    private var previous: [Word] = []
    /// Partial results in a row with the phrase.
    private var partialHits = 0
    private var finalizeAsked = false

    init(matcher: WakePhraseMatcher) {
        self.matcher = matcher
    }

    mutating func partial(_ words: [String]) -> Verdict {
        guard matcher.match(words: words) != nil else {
            partialHits = 0
            return .none
        }
        partialHits += 1
        guard !finalizeAsked else { return .none }
        finalizeAsked = true
        return .finalizeNow
    }

    mutating func final(_ words: [Word]) -> Verdict {
        finalizeAsked = false
        let joined = previous + words
        if !words.isEmpty { previous = Array(joined.suffix(3)) }
        // Only a phrase that ends in these words is new (one that ended in the previous final was heard then).
        guard let match = matcher.match(words: joined.map(\.text)), match.upperBound > joined.count - words.count else {
            return .none
        }
        return .heard(end: joined[match.upperBound - 1].end)
    }

    /// The run ended: all its finals are in.
    func finished() -> Verdict {
        partialHits >= 2 ? .heard(end: nil) : .none
    }
}

/// Decides when the room's sound is worth transcribing, so the on-device recognizer only runs while someone may be
/// speaking (in a quiet room it gets nothing at all). Fed the level of each 20 ms window of the microphone.
///
/// * The noise floor follows a quieter window at once and rises 1.5 dB a second when it gets louder (like
///   SamRabbitKit's `NoiseFloor`; digital silence at or below -100 dBFS is ignored, the floor stays above -80).
/// * Sound `margin` dB above the floor (and above `quietest`) for `attack` opens the gate: transcribing starts with
///   the `preRoll` before it (the first syllable).
/// * `hangover` of quiet closes it. The listener then feeds the `tail` after it (the recognizer gives its final words
///   only for sound it has heard past) and asks for the final words with their times. Sound that never stops (music,
///   a TV) is finalized every `maxOpen` seconds while it goes on.
struct WakeGate: Equatable {
    struct Settings: Equatable {
        var sampleRate = 16_000
        var margin = 8.0
        var quietest = -58.0
        var attack: TimeInterval = 0.06
        var hangover: TimeInterval = 0.7
        var preRoll: TimeInterval = 0.6
        var tail: TimeInterval = 0.25
        var maxOpen: TimeInterval = 12

        func samples(_ seconds: TimeInterval) -> Int64 { Int64(Double(sampleRate) * seconds) }
    }

    enum Action: Equatable {
        /// Start transcribing at this sample (the pre-roll before the sound that opened it).
        case open(from: Int64)
        /// Stop after this sample, and finalize what was sent.
        case close(through: Int64)
        /// Still open after `maxOpen`: finalize what was sent so far.
        case finalize(through: Int64)
    }

    let settings: Settings
    private(set) var isOpen = false
    private(set) var floor: Double?
    private var loudSince: Int64?
    private var lastLoud: Int64 = 0
    private var openedAt: Int64 = 0
    private var finalizedAt: Int64 = 0
    private var lastEnd: Int64 = 0

    init(settings: Settings = Settings()) {
        self.settings = settings
    }

    /// The level (dBFS) of the window of samples that ends at `end` (an absolute sample index).
    mutating func window(power: Double, end: Int64) -> Action? {
        let step = Double(max(0, end - lastEnd)) / Double(settings.sampleRate)
        lastEnd = end
        if power.isFinite, power > -100 {
            let reading = max(-80, min(0, power))
            if let current = floor {
                floor = reading < current ? reading : min(reading, current + 1.5 * step)
            } else {
                floor = reading
            }
        }
        let loud = floor.map { power >= max($0 + settings.margin, settings.quietest) } ?? false
        if loud {
            lastLoud = end
            if loudSince == nil { loudSince = end - Int64(step * Double(settings.sampleRate)) }
        } else {
            loudSince = nil
        }
        if !isOpen {
            guard let since = loudSince, end - since >= settings.samples(settings.attack) else { return nil }
            isOpen = true
            openedAt = end
            finalizedAt = end
            return .open(from: max(0, since - settings.samples(settings.preRoll)))
        }
        if end - lastLoud >= settings.samples(settings.hangover) {
            isOpen = false
            loudSince = nil
            return .close(through: end)
        }
        if end - finalizedAt >= settings.samples(settings.maxOpen) {
            finalizedAt = end
            return .finalize(through: end)
        }
        return nil
    }

    /// Forgets speech in progress (the listener stopped); the noise floor is kept.
    mutating func reset() {
        isOpen = false
        loudSince = nil
    }
}

/// The last few seconds of 16 kHz samples, addressed by absolute sample index (counted since the listener started):
/// what the recognizer is fed from, and what followed the wake phrase.
struct SampleRing: Equatable {
    let capacity: Int
    private var storage: [Int16]
    private var head = 0
    /// The absolute index after the newest sample.
    private(set) var end: Int64 = 0

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        storage = [Int16](repeating: 0, count: self.capacity)
    }

    /// The absolute index of the oldest sample kept.
    var start: Int64 { max(0, end - Int64(capacity)) }

    mutating func append(_ samples: [Int16]) {
        for sample in samples.suffix(capacity) {
            storage[head] = sample
            head = (head + 1) % capacity
        }
        end += Int64(samples.count)
    }

    /// The samples from `from` up to `to` (default: the newest), clamped to what is kept.
    func samples(from: Int64, to: Int64? = nil) -> [Int16] {
        let upper = min(to ?? end, end)
        let lower = max(from, start)
        guard upper > lower else { return [] }
        var out = [Int16]()
        out.reserveCapacity(Int(upper - lower))
        // The newest sample sits just before `head`; index `end - 1` maps to `head - 1`.
        for index in lower..<upper {
            let back = Int(end - index)
            out.append(storage[(head - back + capacity * 2) % capacity])
        }
        return out
    }
}

/// Which microphone "Hey Rabbit" listens with. The listener holds its microphone open all day, and a Bluetooth headset
/// (AirPods) whose microphone is open switches everything it plays to call quality (mono, narrowband); an iPhone used
/// as the Mac's microphone (Continuity) keeps its microphone on. So it listens with the default input unless that is
/// one of those; then with the built-in microphone; with neither it waits (and says why) until the inputs change. A
/// conversation itself uses the default input (call quality during a call is fine).
enum WakeMicrophoneChoice: Equatable {
    struct Device: Equatable {
        var id: UInt32
        var name: String
        var transport: Transport
        var hasInput: Bool
    }

    enum Transport: Equatable {
        case builtIn, bluetooth, continuity, other

        /// Not to be held open all day.
        var isBorrowed: Bool { self == .bluetooth || self == .continuity }
    }

    /// The system's default input.
    case systemDefault
    /// This device rather than the default input.
    case device(UInt32)
    /// Not now, because of this (shown in the menu).
    case waiting(String)

    static func choose(_ devices: [Device], defaultInput: UInt32?) -> WakeMicrophoneChoice {
        let inputs = devices.filter(\.hasInput)
        guard !inputs.isEmpty else { return .waiting("No microphone is connected") }
        guard let current = inputs.first(where: { $0.id == defaultInput }) else { return .systemDefault }
        guard current.transport.isBorrowed else { return .systemDefault }
        if let builtIn = inputs.first(where: { $0.transport == .builtIn }) { return .device(builtIn.id) }
        return .waiting("Paused while “\(current.name)” is the microphone")
    }

    /// The device it listens with (`defaultInput` for the default), or nil while it waits.
    func device(defaultInput: UInt32?) -> UInt32? {
        switch self {
        case .systemDefault: defaultInput
        case .device(let id): id
        case .waiting: nil
        }
    }
}

/// How the listener comes back after its recognizer failed `failures` times in a row (a run that gave words or
/// finished resets the count): at first the next sound just starts a new run, then it pauses a few seconds, then it
/// tries again once a minute and says so. It never gives up for good.
enum WakeRetry {
    static let slowProblem = "On-device speech recognition keeps stopping; trying again in a minute"

    /// Seconds to pause the listener before it starts again, or nil to go on listening.
    static func pause(afterFailures failures: Int) -> TimeInterval? {
        switch failures {
        case ..<3: nil
        case 3: 5
        case 4: 15
        default: 60
        }
    }

    /// What the menu says meanwhile (nil for a short pause).
    static func problem(afterFailures failures: Int) -> String? {
        (pause(afterFailures: failures) ?? 0) >= 60 ? slowProblem : nil
    }
}

/// Hears Samin talk over a reply (opt-in, `VoiceBargeIn`): with voice processing the reply's own voice is taken out of
/// the microphone, so what is left is the room and him. Stricter than the speech detector: sustained speech
/// (`sustain`, short dips between syllables allowed) well above the room and loud in itself, so a cough, a laugh,
/// someone across the room or what is left of the echo doesn't stop the reply.
struct BargeInDetector: Equatable {
    var margin = 15.0
    var quietest = -40.0
    var sustain: TimeInterval = 0.35
    /// Dips this long inside speech don't reset it.
    var gap: TimeInterval = 0.08
    var sampleRate = 16_000

    private var loud = 0
    private var quiet = 0
    private var pending: [Int16] = []

    /// Starts over (a reply begins).
    mutating func reset() {
        loud = 0
        quiet = 0
        pending.removeAll(keepingCapacity: true)
    }

    /// Feeds microphone samples while a reply plays; true once speech over it went on long enough. `floor` is the
    /// room's level while it listened (dBFS).
    mutating func feed(_ samples: [Int16], floor: Double?) -> Bool {
        pending.append(contentsOf: samples)
        let window = sampleRate / 50
        let threshold = max((floor ?? -60) + margin, quietest)
        var start = 0
        var heard = false
        while pending.count - start >= window {
            var sum = 0.0
            for sample in pending[start..<(start + window)] {
                let value = Double(sample) / 32768
                sum += value * value
            }
            let rms = (sum / Double(window)).squareRoot()
            let power = rms > 0 ? 20 * log10(rms) : -160
            if power >= threshold {
                loud += window
                quiet = 0
            } else {
                quiet += window
                if Double(quiet) > gap * Double(sampleRate) { loud = 0 }
            }
            if Double(loud) >= sustain * Double(sampleRate) { heard = true }
            start += window
        }
        pending.removeFirst(start)
        return heard
    }
}
