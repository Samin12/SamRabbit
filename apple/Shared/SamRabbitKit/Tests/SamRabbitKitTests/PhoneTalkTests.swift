import Foundation
import Synchronization
import Testing
@testable import SamRabbitKit

/// The iPhone's Talk: typed turns and the mute in `ConversationMachine`, what Talk shows in a word
/// (`TalkPhase`), the Live Activity's state and when it updates (`TalkActivityState`), and `samrabbit://talk`.
@Suite("Talk on the iPhone")
struct PhoneTalkTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let wav = WAV.encode(pcm: Data(count: 32_000))

    /// Started, warmed up, listening (turn ids t1, t2, ...).
    func listening(idle: TimeInterval = 120) -> ConversationMachine {
        let counter = Mutex(0)
        var m = ConversationMachine(idleTimeout: idle) {
            counter.withLock { value in
                value += 1
                return "t\(value)"
            }
        }
        _ = m.handle(.start, at: t0)
        _ = m.handle(.audioReady, at: t0)
        _ = m.handle(.session(AssistantSession(conversationId: "pc_1", brain: .realtime)), at: t0)
        #expect(m.phase == .listening)
        return m
    }

    func done(_ id: String) -> ConversationMachine.Event {
        .turn(id, .done(AssistantDone(conversationId: "pc_1", turnId: id, expectReply: true, endConversation: false,
                                      interrupted: false, brain: .realtime)))
    }

    // MARK: - Typed turns

    @Test func aTypedTurnIsSentAsText() {
        var m = listening()
        let effects = m.handle(.typed("  What's next on my calendar?  "), at: t0 + 5)
        #expect(effects == [.closeMic, .send(.init(turnId: "t1", conversationId: "pc_1",
                                                   input: .text("What's next on my calendar?"))), .haptic(.click)])
        #expect(m.phase == .thinking)
        #expect(m.currentTurnId == "t1")
        // The caption shows the words at once (before the Mac echoes them as `heard`).
        #expect(m.live?.heard == "What's next on my calendar?")
        #expect(m.lastActivity == t0 + 5)
        // The answer streams like any other turn, then it listens again.
        _ = m.handle(.turn("t1", .heard("What's next on my calendar?")), at: t0 + 5)
        _ = m.handle(.turn("t1", .sayDelta("Design review at three.")), at: t0 + 5)
        _ = m.handle(.playing, at: t0 + 6)
        #expect(m.phase == .speaking)
        _ = m.handle(done("t1"), at: t0 + 6)
        #expect(m.handle(.drained, at: t0 + 8) == [.openMic])
        #expect(m.phase == .listening)
        #expect(m.exchanges.last?.say == "Design review at three.")
    }

    @Test func aTypedTurnWhileSpeechIsHeardReplacesIt() {
        var m = listening()
        _ = m.handle(.speechStarted, at: t0)
        #expect(m.phase == .hearing)
        let effects = m.handle(.typed("Stop the deploy"), at: t0 + 1)
        #expect(effects.first == .closeMic)
        #expect(effects.contains(.send(.init(turnId: "t1", conversationId: "pc_1", input: .text("Stop the deploy")))))
        // The utterance that was being heard never becomes a turn.
        #expect(m.handle(.utterance(wav), at: t0 + 2).isEmpty)
    }

    @Test func aTypedTurnInterruptsTheReply() {
        var m = listening()
        _ = m.handle(.utterance(wav), at: t0)
        _ = m.handle(.turn("t1", .sayDelta("Here is a long")), at: t0)
        _ = m.handle(.playing, at: t0)
        #expect(m.phase == .speaking)
        let effects = m.handle(.typed("Never mind"), at: t0 + 2)
        #expect(effects == [.cancel(turnId: "t1", conversationId: "pc_1"), .stopPlayback, .closeMic,
                            .send(.init(turnId: "t2", conversationId: "pc_1", input: .text("Never mind"))),
                            .haptic(.click)])
        #expect(m.currentTurnId == "t2")
        #expect(m.exchanges.first { $0.id == "t1" }?.interrupted == true)
        // The old turn's stream is ignored from now on.
        #expect(m.handle(.turn("t1", .sayDelta(" answer")), at: t0 + 2).isEmpty)
        #expect(m.live?.heard == "Never mind")
    }

    @Test func nothingIsTypedOutsideAConversationOrWhileAFailureIsSaid() {
        var idle = ConversationMachine()
        #expect(idle.handle(.typed("Hello"), at: t0).isEmpty)
        _ = idle.handle(.start, at: t0)
        #expect(idle.phase == .starting)
        #expect(idle.handle(.typed("Hello"), at: t0).isEmpty) // the audio isn't up yet

        var m = listening()
        #expect(m.handle(.typed("   \n "), at: t0).isEmpty)
        _ = m.handle(.utterance(wav), at: t0)
        _ = m.handle(.turn("t1", .failed(.unreachable)), at: t0)
        // "I can't reach your Mac right now" is being said, then the conversation ends: no new turn.
        #expect(m.handle(.typed("Hello?"), at: t0 + 1).isEmpty)
    }

    // MARK: - Mute

    @Test func theQuietEndWaitsWhileMuted() {
        var m = listening(idle: 120)
        #expect(m.handle(.muted(true), at: t0 + 10).isEmpty)
        #expect(m.micMuted)
        // Long past the quiet end: muted, it keeps going (he is listening, or talking to someone else).
        #expect(m.handle(.tick, at: t0 + 600).isEmpty)
        #expect(m.phase == .listening)
        // Unmuted: the quiet counts from now.
        #expect(m.handle(.muted(false), at: t0 + 700).isEmpty)
        #expect(m.lastActivity == t0 + 700)
        #expect(m.handle(.tick, at: t0 + 700 + 119).isEmpty)
        let ended = m.handle(.tick, at: t0 + 700 + 121)
        #expect(ended.contains(.stopAudio))
        #expect(ended.contains(.end(conversationId: "pc_1")))
        #expect(m.phase == .idle)
    }

    @Test func mutedRepliesStillPlayAndTypedTurnsStillGo() {
        var m = listening()
        _ = m.handle(.muted(true), at: t0)
        // An announcement still plays while muted (only the microphone is off).
        let items = [Announcement(id: "a1", say: "“Fix login” finished.", kind: "done")]
        let announced = m.handle(.announcements(items), at: t0 + 1)
        #expect(announced.contains(.send(.init(turnId: "t1", conversationId: "pc_1", input: .announce("a1")))))
        _ = m.handle(done("t1"), at: t0 + 2)
        #expect(m.phase == .thinking) // the watch's voice says the line (no audio came)
        _ = m.handle(.drained, at: t0 + 4)
        #expect(m.phase == .listening)
        let typed = m.handle(.typed("Thanks"), at: t0 + 5)
        #expect(typed.contains(.send(.init(turnId: "t2", conversationId: "pc_1", input: .text("Thanks")))))
    }

    // MARK: - What Talk shows

    @Test func talkPhasesInAWord() {
        #expect(TalkPhase(.idle, muted: false) == .ended)
        #expect(TalkPhase(.starting, muted: false) == .starting)
        #expect(TalkPhase(.listening, muted: false) == .listening)
        #expect(TalkPhase(.hearing, muted: false) == .hearing)
        #expect(TalkPhase(.listening, muted: true) == .muted)
        #expect(TalkPhase(.hearing, muted: true) == .muted)
        // Muted, it still thinks and speaks.
        #expect(TalkPhase(.thinking, muted: true) == .thinking)
        #expect(TalkPhase(.speaking, muted: true) == .speaking)
        #expect(TalkPhase(.speaking, muted: false, announcing: true) == .announcing)
        #expect(TalkPhase.listening.word == "Listening…")
        #expect(TalkPhase.speaking.word == "Speaking…")
        #expect(TalkPhase.hearing.short == "Listening")
        #expect(TalkPhase.muted.symbol == "mic.slash.fill")
        #expect(TalkPhase.hearing.listens && !TalkPhase.muted.listens)
        for phase in TalkPhase.allCases {
            #expect(!phase.word.isEmpty && !phase.short.isEmpty && !phase.symbol.isEmpty)
        }
    }

    @Test func theLiveActivityShowsTheLastLine() {
        var m = listening()
        #expect(TalkActivityState(m, muted: false) == TalkActivityState(phase: .listening, line: ""))
        _ = m.handle(.utterance(wav), at: t0)
        _ = m.handle(.turn("t1", .heard("What's next?")), at: t0)
        #expect(TalkActivityState(m, muted: false) == TalkActivityState(phase: .thinking, line: "“What's next?”"))
        _ = m.handle(.turn("t1", .sayDelta("Next is the design review.")), at: t0)
        _ = m.handle(.playing, at: t0)
        #expect(TalkActivityState(m, muted: false) == TalkActivityState(phase: .speaking, line: "Next is the design review."))
        _ = m.handle(done("t1"), at: t0)
        _ = m.handle(.drained, at: t0 + 3)
        // Listening again: the last reply stays as the line.
        #expect(TalkActivityState(m, muted: true) == TalkActivityState(phase: .muted, line: "Next is the design review."))
        // Long replies are cut to fit.
        let long = TalkActivityState(phase: .speaking, line: String(repeating: "word ", count: 80))
        #expect(long.line.count == TalkActivityState.maxLine)
        #expect(long.line.hasSuffix("…"))
    }

    @Test func theLiveActivityUpdatesOnNewPhasesAndAtMostEverySoOftenForLines() throws {
        let listening = TalkActivityState(phase: .listening)
        #expect(listening.update(from: nil, shownAt: nil, now: t0))
        #expect(!listening.update(from: listening, shownAt: t0, now: t0 + 100))
        let thinking = TalkActivityState(phase: .thinking, line: "“What's next?”")
        #expect(thinking.update(from: listening, shownAt: t0, now: t0 + 0.1))
        let streaming = TalkActivityState(phase: .thinking, line: "“What's next?” Next is")
        #expect(!streaming.update(from: thinking, shownAt: t0, now: t0 + 0.5))
        #expect(streaming.update(from: thinking, shownAt: t0, now: t0 + TalkActivityState.lineInterval))
        // It travels to the widget extension as JSON.
        let data = try JSONEncoder().encode(streaming)
        #expect(try JSONDecoder().decode(TalkActivityState.self, from: data) == streaming)
    }

    // MARK: - samrabbit://talk

    @Test func theTalkLinkOpensTalk() throws {
        for raw in ["samrabbit://talk", "samrabbit://voice", "samrabbit://assistant", "SAMRABBIT://Talk",
                    PendingRoute.talk] {
            let url = try #require(URL(string: raw))
            #expect(AppLink(url: url) == .talk, "\(raw)")
            #expect(AppLink(url: url, fromApp: true) == .talk, "\(raw)")
        }
        // The Ask links stay what they were.
        #expect(AppLink(url: URL(string: PendingRoute.askListening)!, fromApp: true) == .compose(.ask, listen: true))
    }

    @Test func theTalkIntentsRouteIsTaken() {
        let defaults = UserDefaults(suiteName: "talk-\(UUID().uuidString)")!
        PendingRoute.set(PendingRoute.talk, in: defaults, now: t0)
        let url = PendingRoute.take(from: defaults, now: t0 + 1)
        #expect(url.flatMap { AppLink(url: $0, fromApp: true) } == .talk)
        #expect(PendingRoute.take(from: defaults, now: t0 + 2) == nil)
    }
}
