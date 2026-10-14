import Foundation

// Unit tests of the wake phrase's pure parts (Sources/VoiceWakeMatcher.swift), on transcript strings and synthetic
// levels: no microphone, no speech framework. Run by tests/voice/run.sh.

var failures = 0
var checks = 0

func expect(_ condition: @autoclosure () -> Bool, _ what: String, line: Int = #line) {
    checks += 1
    if !condition() {
        failures += 1
        print("FAILED line \(line): \(what)")
    }
}

func words(_ text: String) -> [String] { text.split(whereSeparator: \.isWhitespace).map(String.init) }

@main
struct WakeMatcherTests {
    static func main() {
        matchesTheWakePhrases()
        ignoresEverythingElse()
        findsWhereThePhraseIs()
        takesOtherPhrases()
        theGateOpensForSpeechOnly()
        theRingKeepsTheLastSeconds()
        bargeInNeedsSustainedLoudSpeech()
        print(failures == 0 ? "OK \(checks) checks" : "FAILED \(failures) of \(checks) checks")
        exit(failures == 0 ? 0 : 1)
    }

    static func matchesTheWakePhrases() {
        let matcher = WakePhraseMatcher()
        for text in ["Hey Rabbit", "hey rabbit", "Hey rabbit.", "Hey, Rabbit!", "Hey rabbit, what's on my calendar?",
                     "Okay rabbit", "OK, Rabbit.", "ok rabbit", "Hey Sam Rabbit", "Hey SamRabbit", "hey sam-rabbit",
                     "Hey rabbits", "Hey, rabbit's", "Hay rabbit", "Um, hey rabbit", "so hey rabbit start a task",
                     "HEY RABBIT", "Hey rabid", "Hey-Rabbit"] {
            expect(matcher.matches(text), "matches “\(text)”")
        }
    }

    static func ignoresEverythingElse() {
        let matcher = WakePhraseMatcher()
        for text in ["", "   ", "Rabbit", "hey", "Hey there", "they rabbit", "hey there rabbit", "I saw a rabbit",
                     "hey robert", "Rabbit, hey", "okay", "hey sam", "the rabbit hole", "heyrabbi t", "Hey Rob it"] {
            expect(!matcher.matches(text), "ignores “\(text)”")
        }
    }

    static func findsWhereThePhraseIs() {
        let matcher = WakePhraseMatcher()
        expect(matcher.match(words: words("Um, hey Rabbit, what's on my calendar?")) == 1..<3, "after a filler")
        expect(matcher.match(words: words("Hey, Rabbit,")) == 0..<2, "with punctuation")
        expect(matcher.match(words: ["Hey", "SamRabbit", "go"]) == 0..<2, "a compound is one word of the transcript")
        expect(matcher.match(words: words("Hey Sam Rabbit, start")) == 0..<3, "the longest phrase at a position")
        expect(matcher.match(words: words("okay so hey rabbit")) == 2..<4, "the first place it is")
        expect(matcher.match(words: []) == nil, "no words")
        // The normalized words keep where they came from.
        let tokens = WakePhraseMatcher.tokens("O.K., Sam-Rabbit's")
        expect(tokens.map(\.word) == ["ok", "sam", "rabbits"], "normalized: \(tokens.map(\.word))")
        expect(tokens.map(\.source) == [0, 1, 1], "sources")
    }

    static func takesOtherPhrases() {
        let matcher = WakePhraseMatcher(phrases: ["Computer", "hello there friend"])
        expect(matcher.phrases == [["computer"], ["hello", "there", "friend"]], "parsed: \(matcher.phrases)")
        expect(matcher.matches("Computer, lights on"), "a one-word phrase")
        expect(matcher.matches("well hello there, friend"), "a three-word phrase")
        expect(!matcher.matches("hey rabbit"), "only the phrases given")
        // Nothing usable falls back to the defaults.
        expect(WakePhraseMatcher(phrases: ["", " ,. "]).phrases == WakePhraseMatcher().phrases, "fallback")
        expect(WakePhraseMatcher().phrases == [["hey", "rabbit"], ["hey", "sam", "rabbit"], ["okay", "rabbit"]], "defaults")
    }

    /// 20 ms windows: a quiet room (-60 dBFS), then speech (-25 dBFS), then quiet.
    static func theGateOpensForSpeechOnly() {
        var gate = WakeGate()
        var end: Int64 = 0
        var actions: [(Int64, WakeGate.Action)] = []
        func feed(_ power: Double, seconds: Double) {
            for _ in 0..<Int(seconds / 0.02) {
                end += 320
                if let action = gate.window(power: power, end: end) { actions.append((end, action)) }
            }
        }
        feed(-60, seconds: 2)
        expect(actions.isEmpty && !gate.isOpen, "a quiet room stays closed")
        expect(gate.floor.map { abs($0 + 60) < 0.01 } == true, "the floor is the room: \(String(describing: gate.floor))")
        feed(-25, seconds: 0.02)
        expect(actions.isEmpty, "one loud window (a click) doesn't open it")
        feed(-60, seconds: 1)
        let speechStart = end
        feed(-25, seconds: 1.5)
        guard case .open(let from)? = actions.first?.1 else {
            expect(false, "speech opens the gate")
            return
        }
        expect(from == speechStart - 9_600, "with 0.6 s before the speech: \(from) vs \(speechStart)")
        expect(actions.first.map { $0.0 - speechStart } == 960, "after 60 ms of speech")
        let speechEnd = end
        feed(-60, seconds: 0.5)
        expect(gate.isOpen && actions.count == 1, "a short pause keeps it open")
        feed(-60, seconds: 0.5)
        expect(actions.count == 2 && !gate.isOpen, "0.7 s of quiet closes it")
        if case .close(let through)? = actions.last?.1 {
            expect(through - speechEnd == 11_200, "closed 0.7 s after the speech: \(through - speechEnd)")
        } else {
            expect(false, "a close")
        }
        // Sound that never stops is finalized every 12 s while it goes on.
        actions = []
        feed(-20, seconds: 30)
        let finalizes = actions.filter { if case .finalize = $0.1 { true } else { false } }.count
        expect(finalizes >= 1, "long sound is finalized: \(actions.map(\.1))")
        // Digital silence isn't the room.
        var fresh = WakeGate()
        _ = fresh.window(power: -160, end: 320)
        expect(fresh.floor == nil, "digital silence ignored")
        _ = fresh.window(power: -95, end: 640)
        expect(fresh.floor == -80, "the floor stays above -80")
    }

    static func theRingKeepsTheLastSeconds() {
        var ring = SampleRing(capacity: 10)
        ring.append((0..<6).map { Int16($0) })
        expect(ring.start == 0 && ring.end == 6, "not full yet")
        expect(ring.samples(from: 2) == [2, 3, 4, 5], "from an index")
        ring.append((6..<15).map { Int16($0) })
        expect(ring.start == 5 && ring.end == 15, "wrapped: \(ring.start)..<\(ring.end)")
        expect(ring.samples(from: 0) == (5..<15).map { Int16($0) }, "clamped to what is kept")
        expect(ring.samples(from: 12, to: 14) == [12, 13], "a range")
        expect(ring.samples(from: 14, to: 20) == [14], "clamped to the newest")
        expect(ring.samples(from: 20).isEmpty, "nothing after the end")
        ring.append((15..<40).map { Int16($0) })
        expect(ring.samples(from: 0) == (30..<40).map { Int16($0) }, "more than it holds at once")
    }
}

/// A voice-like buzz at `dbfs` (about), 16 kHz.
func tone(_ seconds: Double, dbfs: Double) -> [Int16] {
    let amplitude = pow(10, dbfs / 20) * 1.414 * 32767
    return (0..<Int(seconds * 16_000)).map { Int16(clamping: Int(amplitude * sin(2 * .pi * 170 * Double($0) / 16_000))) }
}

extension WakeMatcherTests {
    static func bargeInNeedsSustainedLoudSpeech() {
        var detector = BargeInDetector()
        expect(!detector.feed(tone(2, dbfs: -50), floor: -60), "echo left over at -50 dBFS doesn't stop the reply")
        detector.reset()
        expect(!detector.feed(tone(0.2, dbfs: -25), floor: -60), "a short word or a cough doesn't")
        expect(!detector.feed(tone(0.3, dbfs: -70), floor: -60), "…and quiet after it starts over")
        expect(!detector.feed(tone(0.25, dbfs: -25), floor: -60), "another short one doesn't add up")
        detector.reset()
        var heard = false
        var fed = 0.0
        while !heard, fed < 2 {
            heard = detector.feed(tone(0.05, dbfs: -25), floor: -60)
            fed += 0.05
        }
        expect(heard && abs(fed - 0.35) < 0.051, "talking over it for 0.35 s does (after \(fed) s)")
        // Dips between syllables don't reset it.
        detector.reset()
        var syllables: [Int16] = []
        for _ in 0..<4 { syllables += tone(0.12, dbfs: -25) + tone(0.04, dbfs: -70) }
        expect(detector.feed(syllables, floor: -60), "syllables with short dips count as one stretch")
        // A loud room needs louder speech.
        detector.reset()
        expect(!detector.feed(tone(1, dbfs: -36), floor: -45), "not 15 dB above a loud room")
    }
}
