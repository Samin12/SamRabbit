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

    /// The Mac's reply is over (`done` came) but its audio still plays here: a typed turn stops the playback and goes,
    /// with no cancel. The Mac cancels whatever turn holds the conversation, so a cancel sent with the typed turn
    /// could reach the Mac after it and stop the typed turn itself.
    @Test func aTypedTurnAfterTheReplyCameSendsNoCancel() {
        var m = listening()
        _ = m.handle(.utterance(wav), at: t0)
        _ = m.handle(.turn("t1", .sayDelta("Here is everything that changed")), at: t0)
        _ = m.handle(.playing, at: t0)
        _ = m.handle(done("t1"), at: t0 + 1)
        #expect(m.phase == .speaking) // the rest of the reply plays here
        let effects = m.handle(.typed("Never mind"), at: t0 + 2)
        #expect(effects == [.stopPlayback, .closeMic,
                            .send(.init(turnId: "t2", conversationId: "pc_1", input: .text("Never mind"))),
                            .haptic(.click)])
        #expect(m.exchanges.first { $0.id == "t1" }?.interrupted == true)
        #expect(m.currentTurnId == "t2")
        // A reply still coming from the Mac is cancelled there (the app sends the typed turn once that is through).
        _ = m.handle(.turn("t2", .sayDelta("Okay")), at: t0 + 2)
        _ = m.handle(.playing, at: t0 + 2)
        let again = m.handle(.typed("Actually, what's next?"), at: t0 + 3)
        #expect(again.first == .cancel(turnId: "t2", conversationId: "pc_1"))
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

    /// Muted, the quiet end waits longer (he is talking to someone else), but it still comes: muted and pocketed, the
    /// conversation doesn't hold the microphone and read announcements out loud until he is back.
    @Test func aMutedConversationEndsAfterALongerQuiet() {
        var m = listening(idle: 120)
        #expect(m.mutedTimeout == 300)
        #expect(m.handle(.muted(true), at: t0 + 10).isEmpty)
        #expect(m.micMuted)
        #expect(m.lastActivity == t0 + 10) // counted from the mute
        // Past the usual two minutes: muted, it goes on.
        #expect(m.handle(.tick, at: t0 + 10 + 200).isEmpty)
        #expect(m.phase == .listening)
        // An announcement still plays while muted, but T3 events alone don't keep it open.
        let items = [Announcement(id: "a1", say: "“Fix login” finished.", kind: "done")]
        #expect(m.handle(.announcements(items), at: t0 + 250).contains(.send(.init(turnId: "t1", conversationId: "pc_1",
                                                                                      input: .announce("a1")))))
        _ = m.handle(.playing, at: t0 + 251)
        _ = m.handle(done("t1"), at: t0 + 251)
        #expect(m.handle(.drained, at: t0 + 254) == [.openMic])
        #expect(m.lastActivity == t0 + 10)
        #expect(m.handle(.tick, at: t0 + 10 + 299).isEmpty)
        let ended = m.handle(.tick, at: t0 + 10 + 301)
        #expect(ended.contains(.stopAudio))
        #expect(ended.contains(.end(conversationId: "pc_1")), "the Mac is told, like any quiet end")
        #expect(m.phase == .idle)
        #expect(m.problem == nil)

        // Unmuted: the usual quiet end, counted from the unmute.
        var u = listening(idle: 120)
        _ = u.handle(.muted(true), at: t0 + 10)
        #expect(u.handle(.muted(false), at: t0 + 200).isEmpty)
        #expect(u.lastActivity == t0 + 200)
        #expect(u.handle(.tick, at: t0 + 200 + 119).isEmpty)
        #expect(u.handle(.tick, at: t0 + 200 + 121).contains(.end(conversationId: "pc_1")))

        // A turn that finishes long after the mute ends it too (not only the tick).
        var n = listening(idle: 120)
        _ = n.handle(.muted(true), at: t0)
        _ = n.handle(.announcements(items), at: t0 + 299)
        _ = n.handle(done("t1"), at: t0 + 299)
        #expect(n.phase == .thinking) // said by the phone itself (no audio came)
        #expect(n.handle(.drained, at: t0 + 302).contains(.stopAudio))
    }

    /// A call pauses the conversation (`interrupted`): it keeps its mute when it goes on. End or Close on the paused
    /// screen means it: the end of the call doesn't bring the microphone back.
    @Test func aPausedConversationKeepsItsMuteAndStopWhilePausedMeansIt() {
        var m = listening()
        _ = m.handle(.muted(true), at: t0 + 1)
        let paused = m.handle(.interrupted, at: t0 + 2)
        #expect(paused.contains(.stopAudio))
        #expect(!paused.contains(.end(conversationId: "pc_1")), "paused, not ended")
        #expect(m.phase == .idle)
        #expect(m.problem == "Paused. Tap to talk.")
        #expect(m.micMuted, "the mute stays across the pause")
        // The call is over: the same conversation goes on, still muted.
        #expect(m.handle(.resume, at: t0 + 30) == [.startAudio, .warmUp(conversationId: "pc_1")])
        _ = m.handle(.audioReady, at: t0 + 31)
        #expect(m.phase == .listening)
        #expect(m.micMuted)
        #expect(TalkPhase(m.phase, muted: m.micMuted) == .muted)

        // Paused again, then End while paused: nothing goes on by itself afterwards.
        _ = m.handle(.interrupted, at: t0 + 40)
        #expect(m.handle(.stop, at: t0 + 41).isEmpty)
        #expect(m.handle(.resume, at: t0 + 60).isEmpty)
        #expect(m.phase == .idle)
        // Talk again: a new conversation, unmuted.
        #expect(m.handle(.start, at: t0 + 70) == [.startAudio, .warmUp(conversationId: nil)])
        #expect(!m.micMuted)
        #expect(m.exchanges.isEmpty)
    }

    // MARK: - The audio session

    /// The audio session is the app's, shared by Talk and dictation: a mic button that never listened (its screen
    /// went away) gives nothing back, and dictation never deactivates the session under a conversation using it.
    @Test func onlyTheLastHolderGivesTheAudioSessionBack() {
        var claims = AudioSessionClaims()
        // An idle mic button leaving its screen: nothing to give back.
        var deactivate = claims.release(.dictation)
        #expect(!deactivate)
        #expect(claims.holders.isEmpty)
        // Talk runs; dictation that started meanwhile stops: the session stays for Talk.
        claims.claim(.conversation)
        claims.claim(.dictation)
        deactivate = claims.release(.dictation)
        #expect(!deactivate)
        deactivate = claims.release(.dictation)
        #expect(!deactivate)
        #expect(claims.holders == [.conversation])
        // Talk ends: it was the last one.
        deactivate = claims.release(.conversation)
        #expect(deactivate)
        #expect(claims.holders.isEmpty)
        // Dictation alone, claimed twice (a restart without the on-device model): one release gives it back.
        claims.claim(.dictation)
        claims.claim(.dictation)
        deactivate = claims.release(.dictation)
        #expect(deactivate)
        deactivate = claims.release(.conversation)
        #expect(!deactivate)
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
