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
        theGateOpensAgainSoonAfterItClosed()
        theRingKeepsTheLastSeconds()
        aRunHearsThePhraseInItsFinalWords()
        aRunTrustsPartialsTheFinalPassDropped()
        theMicrophoneIsNeverABluetoothHeadset()
        failuresPauseAndNeverStopForGood()
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

extension WakeMatcherTests {
    /// Sound a second after the last (a cough, dishes): each stretch opens it again, from its own pre-roll. The
    /// listener gives each stretch its own recognizer run, so a pre-roll that reaches back before the last close (the
    /// 0.25 s tail, the 0.7 s hangover) never feeds audio twice.
    static func theGateOpensAgainSoonAfterItClosed() {
        var gate = WakeGate()
        var end: Int64 = 0
        var actions: [WakeGate.Action] = []
        func feed(_ power: Double, seconds: Double) {
            for _ in 0..<Int((seconds / 0.02).rounded()) {
                end += 320
                if let action = gate.window(power: power, end: end) { actions.append(action) }
            }
        }
        feed(-60, seconds: 2)
        for _ in 0..<5 {
            feed(-29, seconds: 0.16)
            feed(-60, seconds: 1)
        }
        let opens = actions.filter { if case .open = $0 { true } else { false } }.count
        let closes = actions.filter { if case .close = $0 { true } else { false } }.count
        expect(opens == 5 && closes == 5, "each burst opens and closes it: \(actions)")
        var lastClose: Int64 = -1
        var reachedBack = false
        for action in actions {
            switch action {
            case .open(let from): if lastClose >= 0, from < lastClose { reachedBack = true }
            case .close(let through): lastClose = through
            case .finalize: break
            }
        }
        expect(reachedBack, "a burst a second later opens it from before the last close (a run of its own)")
        expect(WakeGate.Settings().tail == 0.25, "the tail")
        expect(WakeGate.Settings().samples(0.25) == 4_000, "the tail in samples")
    }

    static func aRunHearsThePhraseInItsFinalWords() {
        typealias Word = WakeRunWords.Word
        var run = WakeRunWords(matcher: WakePhraseMatcher())
        // Partial results: the first match asks for the final words, once until a final comes.
        expect(run.partial(words("Hey")) == .none, "no phrase yet")
        expect(run.partial(words("Hey Rabbit")) == .finalizeNow, "a partial match asks for the final words")
        expect(run.partial(words("Hey Rabbit, what's")) == .none, "asked once")
        // The final: where "Rabbit," ended.
        let final = [Word(text: "Hey,", end: 1.42), Word(text: "Rabbit,", end: 1.90), Word(text: "what's", end: 2.3)]
        expect(run.final(final) == .heard(end: 1.90), "heard, ending with “Rabbit,”")

        // Earlier speech in the same run doesn't matter; the phrase anywhere in a final does.
        var later = WakeRunWords(matcher: WakePhraseMatcher())
        expect(later.final([Word(text: "I", end: 0.8), Word(text: "was", end: 1.0), Word(text: "testing.", end: 1.6)])
               == .none, "no phrase")
        expect(later.final([Word(text: "So,", end: 4.68), Word(text: "hey,", end: 5.04), Word(text: "rabbit,", end: 5.58),
                            Word(text: "what's", end: 6.0)]) == .heard(end: 5.58), "after a filler")

        // A phrase finalized in two pieces.
        var split = WakeRunWords(matcher: WakePhraseMatcher())
        expect(split.final([Word(text: "music", end: 11.5), Word(text: "hey", end: 11.9)]) == .none, "half of it")
        expect(split.final([Word(text: "rabbit", end: 12.3), Word(text: "stop", end: 12.6)]) == .heard(end: 12.3),
               "the rest in the next final")
        // A final with no times says nothing about where; the listener takes where the sound ended.
        var untimed = WakeRunWords(matcher: WakePhraseMatcher())
        expect(untimed.final([Word(text: "Okay", end: nil), Word(text: "rabbit.", end: nil)]) == .heard(end: nil), "untimed")
        // A final without it lets a later partial match ask again.
        var again = WakeRunWords(matcher: WakePhraseMatcher())
        expect(again.partial(words("Hey Rabbit")) == .finalizeNow, "asked")
        expect(again.final([Word(text: "Hey", end: 1), Word(text: "Robert.", end: 1.4)]) == .none, "the final disagrees")
        expect(again.partial(words("hey rabbit")) == .finalizeNow, "asked again")
        var once = WakeRunWords(matcher: WakePhraseMatcher())
        _ = once.partial(words("hey rabbit"))
        expect(once.finished() == .none, "one partial isn't enough at the end")
    }

    static func aRunTrustsPartialsTheFinalPassDropped() {
        // "Hey Rabbit." alone: the partials kept it, the final pass dropped the first words.
        var run = WakeRunWords(matcher: WakePhraseMatcher())
        _ = run.partial(words("Hey"))
        _ = run.partial(words("Hey Rabbit"))
        _ = run.partial(words("Hey Rabbit."))
        expect(run.final([WakeRunWords.Word(text: ",..,", end: 1.2)]) == .none, "the final lost it")
        expect(run.finished() == .heard(end: nil), "the run ends: heard, where the sound ended")
        // Later partials without it (the run went on to other words): not heard.
        var moved = WakeRunWords(matcher: WakePhraseMatcher())
        _ = moved.partial(words("hey rabbit"))
        _ = moved.partial(words("hey rabbit what"))
        _ = moved.final([WakeRunWords.Word(text: "you.", end: 1)])
        _ = moved.partial(words("on my calendar"))
        expect(moved.finished() == .none, "the partials moved on")
        var nothing = WakeRunWords(matcher: WakePhraseMatcher())
        _ = nothing.partial(words("I was testing"))
        expect(nothing.finished() == .none, "no phrase at all")
    }

    static func theMicrophoneIsNeverABluetoothHeadset() {
        typealias Device = WakeMicrophoneChoice.Device
        let builtIn = Device(id: 10, name: "MacBook Pro Microphone", transport: .builtIn, hasInput: true)
        let speakers = Device(id: 11, name: "MacBook Pro Speakers", transport: .builtIn, hasInput: false)
        let airPods = Device(id: 20, name: "AirPods Pro", transport: .bluetooth, hasInput: true)
        let usb = Device(id: 30, name: "USB Microphone", transport: .other, hasInput: true)
        let all = [speakers, builtIn, airPods, usb]
        expect(WakeMicrophoneChoice.choose(all, defaultInput: 10) == .systemDefault, "the built-in one is the default")
        expect(WakeMicrophoneChoice.choose(all, defaultInput: 30) == .systemDefault, "a USB microphone he chose")
        expect(WakeMicrophoneChoice.choose(all, defaultInput: 20) == .device(10), "AirPods are the input: the built-in one")
        expect(WakeMicrophoneChoice.choose([airPods, usb], defaultInput: 20) == .waiting("Paused while “AirPods Pro” is the microphone"),
               "only another non-built-in one: waits (it doesn't pick a microphone he didn't choose)")
        expect(WakeMicrophoneChoice.choose([airPods], defaultInput: 20) == .waiting("Paused while “AirPods Pro” is the microphone"),
               "a Mac without a microphone of its own and AirPods: waits")
        let iPhone = Device(id: 40, name: "iPhone Microphone", transport: .continuity, hasInput: true)
        expect(WakeMicrophoneChoice.choose([builtIn, iPhone], defaultInput: 40) == .device(10),
               "an iPhone as the microphone (Continuity): the built-in one")
        expect(WakeMicrophoneChoice.choose([iPhone, usb], defaultInput: 40) == .waiting("Paused while “iPhone Microphone” is the microphone"),
               "an iPhone and no microphone of its own: waits")
        expect(WakeMicrophoneChoice.choose([iPhone, usb], defaultInput: 30) == .systemDefault, "the USB one is the default")
        expect(WakeMicrophoneChoice.choose([speakers], defaultInput: nil) == .waiting("No microphone is connected"), "none")
        expect(WakeMicrophoneChoice.choose(all, defaultInput: nil) == .systemDefault, "the default unknown")
        expect(WakeMicrophoneChoice.choose(all, defaultInput: 11) == .systemDefault, "the default not an input")
        expect(WakeMicrophoneChoice.device(10).device(defaultInput: 20) == 10, "the device it listens with")
        expect(WakeMicrophoneChoice.systemDefault.device(defaultInput: 30) == 30, "the default")
        expect(WakeMicrophoneChoice.waiting("x").device(defaultInput: 30) == nil, "none while waiting")
    }

    static func failuresPauseAndNeverStopForGood() {
        expect(WakeRetry.pause(afterFailures: 1) == nil && WakeRetry.pause(afterFailures: 2) == nil,
               "the first failures: the next sound starts a new run")
        expect(WakeRetry.pause(afterFailures: 3) == 5 && WakeRetry.pause(afterFailures: 4) == 15, "then short pauses")
        expect((5...500).allSatisfy { WakeRetry.pause(afterFailures: $0) == 60 }, "then once a minute, for ever")
        expect(WakeRetry.problem(afterFailures: 4) == nil, "a short pause says nothing")
        expect(WakeRetry.problem(afterFailures: 9) == WakeRetry.slowProblem, "the slow retry says why")
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
