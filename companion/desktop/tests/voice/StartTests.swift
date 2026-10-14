import Foundation

// Unit tests of how a conversation's microphone starts (Sources/VoiceStart.swift, `MicrophoneStart`): fake engine
// starts, a fake clock and fake waits; no microphone, no audio, no defaults. Run by tests/voice/run.sh.

var failures = 0
var checks = 0

func expect(_ condition: @autoclosure () -> Bool, _ what: String, line: Int = #line) {
    checks += 1
    if !condition() {
        failures += 1
        print("FAILED line \(line): \(what)")
    }
}

struct EngineFailed: Error {}

/// One microphone: how its starts go, and what was asked of it.
@MainActor
final class Rig {
    var clock = Date(timeIntervalSince1970: 1_000_000)
    /// Every start, in order: with echo cancellation or plain.
    var starts: [Bool] = []
    var waits = 0
    /// The first this many plain starts fail.
    var plainFailures = 0
    var echoFails = false
    /// How long a voice-processing start takes to fail.
    var echoTakes: TimeInterval = 0
    var stillWanted = true
    /// Runs during a wait (a stop, another start).
    var duringWait: (() throws -> Void)?
    var lines: [String] = []

    func run(_ policy: MicrophoneStart, echo: Bool, input: UInt32? = 70) async throws -> MicrophoneStart.Outcome {
        try await policy.run(
            echoCancellation: echo, input: input, now: { self.clock },
            start: { withEcho in
                self.starts.append(withEcho)
                if withEcho {
                    guard !self.echoFails else {
                        self.clock += self.echoTakes
                        throw EngineFailed()
                    }
                    return
                }
                if self.starts.filter({ !$0 }).count <= self.plainFailures { throw EngineFailed() }
            },
            wait: {
                self.waits += 1
                self.clock += 0.3
                try self.duringWait?()
            },
            current: { self.stillWanted },
            log: { self.lines.append($0) })
    }

    /// The outcome, or what it threw ("GaveUp", "CancellationError", ...).
    func result(_ policy: MicrophoneStart, echo: Bool, input: UInt32? = 70) async -> String {
        do {
            return "\(try await run(policy, echo: echo, input: input))"
        } catch is MicrophoneStart.GaveUp {
            return "GaveUp"
        } catch is CancellationError {
            return "CancellationError"
        } catch {
            return "\(error)"
        }
    }
}

@main
struct StartTests {
    @MainActor
    static func main() async {
        await thePlainMicrophoneStartsAtOnce()
        await aBusyMicrophoneIsTriedThreeTimes()
        await threeFailuresGiveUp()
        await echoCancellationIsOptIn()
        await aSlowEchoFailureIsNotTriedAgainOnThatMicrophone()
        await aQuickEchoFailureIsTriedAgainNextTime()
        await aStopWhileWaitingStartsNothing()
        await aCancelledWaitStartsNothing()
        print(failures == 0 ? "OK \(checks) checks" : "FAILED \(failures) of \(checks) checks")
        exit(failures == 0 ? 0 : 1)
    }

    @MainActor
    static func thePlainMicrophoneStartsAtOnce() async {
        let rig = Rig()
        let outcome = await rig.result(MicrophoneStart(), echo: false)
        expect(outcome == "\(MicrophoneStart.Outcome.plain(attempt: 1))", "plain, first try: \(outcome)")
        expect(rig.starts == [false] && rig.waits == 0 && rig.lines.isEmpty, "one start, no wait, nothing logged")
    }

    @MainActor
    static func aBusyMicrophoneIsTriedThreeTimes() async {
        for failing in 1...2 {
            let rig = Rig()
            rig.plainFailures = failing
            let outcome = await rig.result(MicrophoneStart(), echo: false)
            expect(outcome == "\(MicrophoneStart.Outcome.plain(attempt: failing + 1))", "try \(failing + 1): \(outcome)")
            expect(rig.starts == Array(repeating: false, count: failing + 1), "\(failing + 1) plain starts")
            expect(rig.waits == failing, "a wait before each try after the first")
            expect(rig.lines.count == failing && rig.lines.allSatisfy { $0.hasPrefix("audio did not start (try ") },
                   "each failure logged: \(rig.lines)")
            expect(rig.lines.allSatisfy { $0.contains("EngineFailed#") }, "errors as domain#code: \(rig.lines)")
        }
        expect(MicrophoneStart.pause == .milliseconds(300) && MicrophoneStart.tries == 3, "three tries 0.3 s apart")
    }

    @MainActor
    static func threeFailuresGiveUp() async {
        let rig = Rig()
        rig.plainFailures = 3
        let outcome = await rig.result(MicrophoneStart(), echo: false)
        expect(outcome == "GaveUp", "every try failed: \(outcome)")
        expect(rig.starts == [false, false, false] && rig.waits == 2, "three starts, two waits, no fourth try")
        expect(rig.lines.last?.hasPrefix("audio did not start (try 3: ") == true, "\(rig.lines)")
    }

    @MainActor
    static func echoCancellationIsOptIn() async {
        let policy = MicrophoneStart()
        let off = Rig()
        _ = await off.result(policy, echo: false)
        expect(off.starts == [false], "off: never voice processing")
        let on = Rig()
        let outcome = await on.result(policy, echo: true)
        expect(outcome == "\(MicrophoneStart.Outcome.echoCancellation)", "on: \(outcome)")
        expect(on.starts == [true] && on.waits == 0, "voice processing first, nothing else")
    }

    @MainActor
    static func aSlowEchoFailureIsNotTriedAgainOnThatMicrophone() async {
        let policy = MicrophoneStart()
        let first = Rig()
        first.echoFails = true
        first.echoTakes = 12  // Samin's Mac: -10875 after about 12 s
        let outcome = await first.result(policy, echo: true, input: 70)
        expect(outcome == "\(MicrophoneStart.Outcome.plain(attempt: 1))", "it goes on without it: \(outcome)")
        expect(first.starts == [true, false], "voice processing, then plain")
        expect(first.lines.first?.contains("not tried again on this microphone") == true, "\(first.lines)")
        expect(policy.echoFailedOn == [70], "remembered for that microphone")
        let next = Rig()
        _ = await next.result(policy, echo: true, input: 70)
        expect(next.starts == [false], "the next conversation goes straight to the plain microphone")
        let other = Rig()
        _ = await other.result(policy, echo: true, input: 71)
        expect(other.starts == [true], "another microphone gets voice processing again")
        expect(!policy.triesEchoCancellation(false, input: 71), "never while it is off")
    }

    @MainActor
    static func aQuickEchoFailureIsTriedAgainNextTime() async {
        let policy = MicrophoneStart()
        let first = Rig()
        first.echoFails = true
        first.echoTakes = 0.05  // a microphone busy for a moment
        _ = await first.result(policy, echo: true, input: 70)
        expect(first.starts == [true, false], "voice processing, then plain")
        expect(policy.echoFailedOn.isEmpty, "a quick failure is not remembered")
        expect(first.lines.first?.contains("not tried again") == false, "\(first.lines)")
        let next = Rig()
        _ = await next.result(policy, echo: true, input: 70)
        expect(next.starts == [true], "tried again next time")
    }

    @MainActor
    static func aStopWhileWaitingStartsNothing() async {
        // stop() or another start() while it waits between tries: it gives up, and no second engine starts.
        let rig = Rig()
        rig.plainFailures = 3
        rig.duringWait = { rig.stillWanted = false }
        let outcome = await rig.result(MicrophoneStart(), echo: false)
        expect(outcome == "CancellationError", "overtaken: \(outcome)")
        expect(rig.starts == [false] && rig.waits == 1, "nothing started after the wait")
        // The same after a slow voice-processing failure.
        let echo = Rig()
        echo.echoFails = true
        echo.echoTakes = 12
        echo.plainFailures = 1
        echo.duringWait = { echo.stillWanted = false }
        let after = await echo.result(MicrophoneStart(), echo: true)
        expect(after == "CancellationError" && echo.starts == [true, false], "\(after) \(echo.starts)")
    }

    @MainActor
    static func aCancelledWaitStartsNothing() async {
        let rig = Rig()
        rig.plainFailures = 1
        rig.duringWait = { throw CancellationError() }
        let outcome = await rig.result(MicrophoneStart(), echo: false)
        expect(outcome == "CancellationError" && rig.starts == [false], "\(outcome) \(rig.starts)")
    }
}
