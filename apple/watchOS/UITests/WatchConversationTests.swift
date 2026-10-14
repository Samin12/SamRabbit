import XCTest

/// The watch's live conversation with SamRabbit, driven in the simulator against the fake bridge's assistant
/// (`/v1/mobile/assistant/*`, the streaming turn protocol).
///
/// The debug build's made-up voice (`-SamRabbitVoiceFixture speech`, `ConversationFixture`) stands in for the
/// microphone: after the microphone opens it "says" something for 1.6 s; everything after it is real (the speech
/// detector, the 16 kHz WAV, the streamed turn, the PCM frames scheduled on the player, the captions, barge-in,
/// announcements). The simulator plays nothing out loud (`AudioGraph` is muted there).
///
/// Needs `apple/dev/fake_bridge.py` on 127.0.0.1:3799 (or `TEST_RUNNER_SAMRABBIT_FAKE_BRIDGE=<host:port>`), the
/// iPhone simulator paired with it and this watch paired
/// with that iPhone (skips otherwise). Screenshots are attached as `watch-…` (exported to
/// ~/Movies/SamRabbit-tests/wave5). Synchronous on purpose (see `WatchVoiceTests`).
@MainActor
final class WatchConversationTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        fake("assistant", ["mode": "ok", "delay": 0.35, "pace": 0.5, "clear": true])
    }

    override func tearDownWithError() throws {
        // Everything a test may have changed, even when it failed halfway (the next test expects the defaults).
        fake("assistant", ["mode": "ok", "delay": 0.35, "pace": 0.5, "hold": 0, "ping": 0, "busyFor": 0,
                           "code": "assistant_failed", "heard": Self.heard, "say": Self.say])
    }

    /// The fake bridge (`TEST_RUNNER_SAMRABBIT_FAKE_BRIDGE`, default 127.0.0.1:3799).
    nonisolated static let bridge = ProcessInfo.processInfo.environment["SAMRABBIT_FAKE_BRIDGE"] ?? "127.0.0.1:3799"

    nonisolated static let heard = "Draft the release notes for build 2.4"
    nonisolated static let say = "Okay, I started the release notes for build 2.4 in Hermes. Anything else?"

    // MARK: - Helpers

    private func launch(turns: Int = 1, lead: Double = 1.2, voice: String = "speech", idle: Int? = nil,
                        page: String? = nil, route: String? = nil, intent: String? = nil,
                        extra: [String] = []) throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-SamRabbitVoiceFixture", voice, "-SamRabbitFixtureTurns", String(turns),
                               "-SamRabbitFixtureLead", String(lead), "-SamRabbitStillOrb", "YES"]
        if let idle { app.launchArguments += ["-SamRabbitIdleSeconds", String(idle)] }
        if let page { app.launchArguments += ["-SamRabbitPage", page] }
        if let route { app.launchArguments += ["-SamRabbitRoute", route] }
        if let intent { app.launchArguments += ["-SamRabbitIntent", intent] }
        app.launchArguments += extra
        app.launch()
        if app.staticTexts["Pair on your iPhone"].waitForExistence(timeout: 3) {
            throw XCTSkip("The watch isn't paired (pair the iPhone simulator with the fake bridge first).")
        }
        return app
    }

    /// The microphone takes `seconds` to be allowed (the first launch's prompt, Siri still holding it), and the app
    /// waits for Talk.
    private func slowMicrophone(_ seconds: Double) -> [String] {
        ["-SamRabbitConversation", "off", "-SamRabbitFixtureMicDelay", String(seconds)]
    }

    /// Debug builds: "audio on" while the microphone is live (the state line's accessibility value).
    private func audio(_ app: XCUIApplication) -> String? { state(app).value as? String }

    private func stop(_ app: XCUIApplication) {
        let stops = app.buttons.matching(identifier: "assistant-stop")
        XCTAssertTrue(stops.firstMatch.waitForExistence(timeout: 5))
        let stop = (0..<stops.count).map { stops.element(boundBy: $0) }.first { $0.isHittable } ?? stops.firstMatch
        stop.tap()
    }

    @discardableResult
    nonisolated private func fake(_ name: String, _ body: [String: Any] = [:]) -> [String: Any] {
        var request = URLRequest(url: URL(string: "http://\(Self.bridge)/__fake/\(name)")!)
        request.httpMethod = "POST"
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return exchange(request)
    }

    nonisolated private func fakeGet(_ name: String) -> [String: Any] {
        exchange(URLRequest(url: URL(string: "http://\(Self.bridge)/__fake/\(name)")!))
    }

    nonisolated private func exchange(_ request: URLRequest) -> [String: Any] {
        nonisolated(unsafe) var answer: [String: Any] = [:]
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, _, _ in
            answer = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 10)
        return answer
    }

    private var assistant: [String: Any] { fakeGet("assistant") }
    private var refused: [[String: Any]] { assistant["refused"] as? [[String: Any]] ?? [] }

    /// Waits until the fake bridge has `count` turns (short exchanges can be over before the state line is read).
    @discardableResult
    private func waitForTurns(_ count: Int, timeout: TimeInterval = 25, file: StaticString = #filePath,
                              line: UInt = #line) -> [[String: Any]] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let seen = turns
            if seen.count >= count { return seen }
            Thread.sleep(forTimeInterval: 0.3)
        }
        XCTFail("the Mac got \(turns.count) turns, not \(count)", file: file, line: line)
        return turns
    }
    private var turns: [[String: Any]] { assistant["turns"] as? [[String: Any]] ?? [] }

    private func state(_ app: XCUIApplication) -> XCUIElement { app.staticTexts["assistant-state"] }

    /// Waits until the state line says one of `texts` (polling: the label changes in place; each query is slow
    /// while the orb animates, so short states are given alternatives). Returns the one it saw.
    @discardableResult
    private func waitFor(_ app: XCUIApplication, state texts: String..., timeout: TimeInterval = 15,
                         file: StaticString = #filePath, line: UInt = #line) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if state(app).exists {
                let label = state(app).label
                if let found = texts.first(where: { label.hasPrefix($0) }) { return found }
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTFail("the state never said “\(texts.joined(separator: "” or “"))” (it says “\(state(app).exists ? state(app).label : "-")”)",
                file: file, line: line)
        return nil
    }

    private func label(_ app: XCUIApplication, contains text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func snap(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func pause(_ seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }

    // MARK: - Tests

    /// Opened normally, the app goes straight into a conversation: listening, hearing, thinking, speaking (the
    /// streamed reply with its live caption), then listening again by itself.
    func test1_OpensIntoALiveConversation() throws {
        fake("assistant", ["pace": 1.0])
        let app = try launch(turns: 1, lead: 6) // the launch checks take a few seconds
        waitFor(app, state: "Listening")
        snap("watch-1-listening")
        if waitFor(app, state: "Hearing you", "Thinking", "Speaking") == "Hearing you" { snap("watch-2-hearing") }
        waitFor(app, state: "Speaking", timeout: 20)
        XCTAssertTrue(app.staticTexts["assistant-heard"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["assistant-heard"].label, "Draft the release notes for build 2.4")
        XCTAssertTrue(app.staticTexts["assistant-say"].waitForExistence(timeout: 5))
        pause(1.2)
        snap("watch-3-speaking")
        XCTAssertTrue(app.staticTexts["assistant-say"].label.hasPrefix("Okay, I started"))
        waitFor(app, state: "Listening", timeout: 20)
        XCTAssertEqual(app.staticTexts["assistant-say"].label,
                       "Okay, I started the release notes for build 2.4 in Hermes. Anything else?")
        XCTAssertTrue(label(app, contains: "Release notes for build 2.4").exists, "the task it started")
        pause(0.5)
        snap("watch-4-listening-again")
        // As the bridge saw it: a warm-up, then one streamed utterance from the watch (16 kHz WAV).
        let sessions = assistant["sessions"] as? [[String: Any]] ?? []
        XCTAssertEqual(sessions.count, 1)
        let turn = try XCTUnwrap(turns.last)
        XCTAssertEqual(turn["kind"] as? String, "audio")
        XCTAssertEqual(turn["contentType"] as? String, "audio/wav")
        XCTAssertEqual(turn["stream"] as? Bool, true)
        XCTAssertEqual(turn["platform"] as? String, "watchos")
        XCTAssertEqual(turn["deviceTime"] as? Bool, true)
        XCTAssertEqual(turn["conversationId"] as? String, sessions.first?["conversationId"] as? String)
        let seconds = try XCTUnwrap(turn["seconds"] as? Double)
        XCTAssertTrue(seconds > 1.5 && seconds < 2.6, "1.6 s of voice with its pre-roll and tail: \(seconds)")
    }

    /// Tap the orb while it speaks: the reply stops (the Mac is told to cancel), and it listens.
    func test2_TapToInterrupt() throws {
        fake("assistant", ["pace": 1.0])
        let app = try launch(turns: 1, lead: 1.0)
        waitFor(app, state: "Speaking", timeout: 20)
        pause(0.8)
        app.buttons["assistant-orb"].tap()
        waitFor(app, state: "Listening", timeout: 5)
        pause(0.4)
        snap("watch-5-interrupted")
        let cancels = assistant["cancels"] as? [[String: Any]] ?? []
        XCTAssertEqual(cancels.last?["cancelled"] as? Bool, true, "the Mac stopped the reply")
        pause(1.5)
        XCTAssertEqual(turns.last?["interrupted"] as? Bool, true)
    }

    /// A reply without audio (the voice failed on the Mac): the watch says it with its own voice.
    func test3_TheWatchSpeaksWhenTheReplyHasNoAudio() throws {
        fake("assistant", ["mode": "noaudio", "say": "It's sunny and 21 degrees."])
        let app = try launch(turns: 1)
        waitFor(app, state: "Speaking", timeout: 20)
        XCTAssertEqual(app.staticTexts["assistant-say"].label, "It's sunny and 21 degrees.")
        snap("watch-6-local-voice")
        waitFor(app, state: "Listening", timeout: 15)
        fake("assistant", ["say": "Okay, I started the release notes for build 2.4 in Hermes. Anything else?"])
    }

    /// The Mac can't be reached: the watch says so out loud, then the conversation ends.
    func test4_CantReachTheMac() throws {
        fake("assistant", ["mode": "drop"])
        let app = try launch(turns: 1)
        waitFor(app, state: "Can't reach your Mac", timeout: 40)
        XCTAssertTrue(app.buttons["assistant-talk"].exists, "Talk to try again")
        pause(0.4)
        snap("watch-7-cant-reach-mac")
    }

    /// While a conversation is open, announcements (T3 events) are polled and spoken between turns.
    func test5_AnnouncementsBetweenTurns() throws {
        let app = try launch(turns: 0)
        waitFor(app, state: "Listening")
        fake("announce", ["say": "“Fix login redirect” in Hermes finished.", "kind": "done"])
        waitFor(app, state: "Heads up", timeout: 30)
        XCTAssertEqual(app.staticTexts["assistant-say"].label, "“Fix login redirect” in Hermes finished.")
        pause(0.8)
        snap("watch-8-announcement")
        waitFor(app, state: "Listening", timeout: 15)
        XCTAssertEqual(turns.last?["kind"] as? String, "announce", "said in the conversation's voice")
    }

    /// No speech for a while (`-SamRabbitIdleSeconds 6`; about 2 minutes normally): the conversation ends.
    func test6_EndsAfterAQuietWhile() throws {
        let app = try launch(turns: 0, idle: 6)
        waitFor(app, state: "Listening")
        waitFor(app, state: "Tap to talk", timeout: 15)
        XCTAssertTrue(app.buttons["assistant-talk"].exists)
        pause(0.5)
        snap("watch-9-ended-quiet")
        let ends = assistant["ends"] as? [[String: Any]] ?? []
        XCTAssertEqual(ends.last?["ended"] as? Bool, true, "the Mac was told")
        // Talk starts a new one.
        app.buttons["assistant-talk"].tap()
        waitFor(app, state: "Listening")
    }

    /// The Mac ends the conversation ("thanks, that's all").
    func test7_TheMacEndsIt() throws {
        fake("assistant", ["mode": "end"])
        let app = try launch(turns: 1)
        waitFor(app, state: "Speaking", timeout: 20)
        waitFor(app, state: "Tap to talk", timeout: 15)
        XCTAssertEqual(app.staticTexts["assistant-say"].label, "Okay. Talk soon.")
        snap("watch-10-ended-by-the-mac")
    }

    /// The Claude fallback (or an older bridge) answers in one piece with an encoded clip: played the same way.
    func test8_TheFallbackAnswersInOnePiece() throws {
        fake("assistant", ["mode": "buffered_clip"])
        let app = try launch(turns: 1)
        waitFor(app, state: "Speaking", timeout: 25)
        snap("watch-11-buffered-clip")
        waitFor(app, state: "Listening", timeout: 15)
        XCTAssertEqual(turns.last?["stream"] as? Bool, false)
    }

    /// The Action Button's control and Siri ("Ask SamRabbit") run `OpenSamRabbitWatchIntent`: the app opens on the
    /// conversation, listening (here from the Quick page; the simulator has no Action Button to press).
    func test9_ActionButtonOpensTheConversation() throws {
        let app = try launch(turns: 0, page: "quick", intent: "ask")
        waitFor(app, state: "Listening", timeout: 12)
        XCTAssertTrue(app.buttons["assistant-orb"].exists, "on the main page")
        snap("watch-12-action-button")
    }

    /// Through the iPhone (`-SamRabbitRoute phone`): the utterance goes up in chunks, the phone sends the turn with
    /// the watch's own token and hands the stream back piece by piece.
    func test10_ThroughTheIPhone() throws {
        let app = try launch(turns: 1, route: "phone")
        waitFor(app, state: "Speaking", timeout: 40)
        waitFor(app, state: "Listening", timeout: 25)
        XCTAssertTrue(app.staticTexts["assistant-say"].label.hasPrefix("Okay, I started"))
        snap("watch-13-through-the-iphone")
        let turn = try XCTUnwrap(turns.last)
        XCTAssertEqual(turn["platform"] as? String, "watchos", "the watch's own token, not the phone's")
        XCTAssertNotNil(turn["parentId"] as? String)
        XCTAssertEqual(turn["stream"] as? Bool, true)
    }

    /// Stop ends it at once and tells the Mac.
    func test11_Stop() throws {
        let app = try launch(turns: 0)
        waitFor(app, state: "Listening")
        let stops = app.buttons.matching(identifier: "assistant-stop")
        XCTAssertTrue(stops.firstMatch.waitForExistence(timeout: 5))
        snap("watch-14-stop-button")
        let stop = (0..<stops.count).map { stops.element(boundBy: $0) }.first { $0.isHittable } ?? stops.firstMatch
        stop.tap()
        waitFor(app, state: "Tap to talk", timeout: 5)
        let ends = assistant["ends"] as? [[String: Any]] ?? []
        XCTAssertEqual(ends.last?["ended"] as? Bool, true)
        XCTAssertEqual(audio(app), "audio off")
    }

    /// Stop while the audio is still starting: the microphone never comes on behind "Tap to talk", not even once
    /// the start it interrupted would have finished. Stop then Talk inside that window: the newer start listens.
    func test12_StopWhileStarting() throws {
        let app = try launch(turns: 0, extra: slowMicrophone(4))
        app.buttons["assistant-talk"].tap()
        waitFor(app, state: "Starting")
        stop(app)
        waitFor(app, state: "Tap to talk", timeout: 5)
        pause(5) // past the microphone's delay
        XCTAssertTrue(state(app).label.hasPrefix("Tap to talk"))
        XCTAssertEqual(audio(app), "audio off", "the microphone stayed off")
        snap("watch-15-stopped-while-starting")
        // Stop, then Talk again while the first start still waits.
        app.buttons["assistant-talk"].tap()
        waitFor(app, state: "Starting")
        stop(app)
        waitFor(app, state: "Tap to talk", timeout: 5)
        app.buttons["assistant-talk"].tap()
        waitFor(app, state: "Listening", timeout: 12)
        XCTAssertEqual(audio(app), "audio on")
        stop(app)
        waitFor(app, state: "Tap to talk", timeout: 5)
        pause(4.5)
        XCTAssertEqual(audio(app), "audio off")
    }

    /// The Mac refuses the warm-up while the audio is still starting: once the audio runs the watch says why (before,
    /// nothing could play it), then the conversation ends with the problem shown and the microphone off.
    func test13_AWarmUpFailingWhileStartingIsSaid() throws {
        fake("assistant", ["mode": "unavailable"])
        let app = try launch(turns: 0, extra: slowMicrophone(5)) // longer than the watch's voice waits for a player
        app.buttons["assistant-talk"].tap()
        waitFor(app, state: "Starting")
        // "Speaking": it really plays (said into a player that isn't there yet, it would never get past "Thinking").
        waitFor(app, state: "Speaking", timeout: 12)
        XCTAssertEqual(app.staticTexts["assistant-say"].label, "The assistant isn't available on your Mac right now.")
        snap("watch-16-warm-up-failure-said")
        waitFor(app, state: "Assistant unavailable on the Mac", timeout: 15)
        pause(1)
        XCTAssertEqual(audio(app), "audio off")
        XCTAssertTrue(app.buttons["assistant-talk"].exists)
        snap("watch-17-warm-up-failure-shown")
        // The Mac is back: once the watch has the fresh summary, the next launch talks by itself again (a cached
        // "unavailable" from the last two minutes keeps it quiet on purpose).
        fake("assistant", ["mode": "ok"])
        app.terminate()
        let again = try launch(turns: 0, extra: ["-SamRabbitConversation", "off"])
        waitFor(again, state: "Tap to talk", timeout: 20)
        again.buttons["assistant-talk"].tap()
        waitFor(again, state: "Listening", timeout: 10)
        XCTAssertEqual(audio(again), "audio on")
        stop(again)
        waitFor(again, state: "Tap to talk", timeout: 5)
    }

    /// A tool that runs for a long while (45 s here) with no word on the stream, not even a keep-alive (an older
    /// bridge): the watch waits (90 s) instead of giving up at 40 s, then plays the reply.
    func test14_ALongQuietToolCallIsWaitedFor() throws {
        fake("assistant", ["hold": 45, "ping": 0])
        let app = try launch(turns: 1)
        waitFor(app, state: "Thinking", timeout: 20)
        pause(30)
        XCTAssertTrue(state(app).label.hasPrefix("Thinking"), "still waiting: \(state(app).label)")
        snap("watch-18-long-tool-call")
        waitFor(app, state: "Speaking", timeout: 40)
        waitFor(app, state: "Listening", timeout: 20)
        XCTAssertTrue(app.staticTexts["assistant-say"].label.hasPrefix("Okay, I started"))
        XCTAssertEqual(turns.count, 1)
    }

    /// The Digital Crown while a reply plays, then straight back to the app: the conversation goes on (it listens
    /// after the reply) instead of ending.
    func test15_CrownDuringAReplyThenBack() throws {
        fake("assistant", ["pace": 1.0])
        let app = try launch(turns: 1)
        waitFor(app, state: "Speaking", timeout: 20)
        XCUIDevice.shared.press(.home)
        pause(1)
        app.activate()
        XCTAssertEqual(waitFor(app, state: "Listening", "Tap to talk", timeout: 20), "Listening",
                       "back while it spoke: the conversation goes on")
        snap("watch-19-back-after-the-crown")
        let ends = assistant["ends"] as? [[String: Any]] ?? []
        XCTAssertTrue(ends.isEmpty, "the Mac wasn't told it ended")
    }

    /// The assistant goes away on the Mac in the middle of a turn (an `error` event that can't get better): the watch
    /// says so, then the conversation ends with the problem shown and the microphone off.
    func test16_AFatalErrorInTheStreamEndsIt() throws {
        fake("assistant", ["mode": "error", "code": "assistant_unavailable"])
        let app = try launch(turns: 1)
        waitFor(app, state: "Speaking", timeout: 25)
        XCTAssertEqual(app.staticTexts["assistant-say"].label, "The assistant isn't available on your Mac right now.")
        waitFor(app, state: "Assistant unavailable on the Mac", timeout: 15)
        pause(1)
        XCTAssertEqual(audio(app), "audio off")
        snap("watch-20-fatal-stream-error")
    }

    /// A short "yes" (about 0.2 s of voice) is sent like any utterance: it confirms approvals.
    func test17_AShortYesIsSent() throws {
        fake("assistant", ["heard": "Yes", "say": "Okay, approved."])
        let app = try launch(turns: 1, extra: ["-SamRabbitFixtureLength", "0.22"])
        let turn = try XCTUnwrap(waitForTurns(1).last)
        XCTAssertEqual(turn["kind"] as? String, "audio")
        let seconds = try XCTUnwrap(turn["seconds"] as? Double)
        XCTAssertTrue(seconds > 0.4 && seconds < 1.0, "0.22 s of voice with its pre-roll and tail: \(seconds)")
        waitFor(app, state: "Listening", timeout: 20)
        XCTAssertTrue(app.staticTexts["assistant-say"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["assistant-say"].label, "Okay, approved.")
        snap("watch-21-short-yes")
    }

    /// Through the iPhone while the Mac still finishes the last thing (409 for 2 s from the first try): the watch
    /// retries, the phone sends the turn to the Mac again, and the reply plays.
    func test18_ABusyMacThroughTheIPhone() throws {
        fake("assistant", ["busyFor": 2])
        let app = try launch(turns: 1, route: "phone")
        waitFor(app, state: "Speaking", timeout: 40)
        waitFor(app, state: "Listening", timeout: 25)
        // The reply, not "One moment, I'm still on the last thing".
        XCTAssertTrue(app.staticTexts["assistant-say"].label.hasPrefix("Okay, I started"))
        XCTAssertGreaterThanOrEqual(refused.count, 1, "the Mac said 409 first")
        XCTAssertEqual(turns.count, 1, "then answered the turn once")
        XCTAssertEqual(turns.last?["platform"] as? String, "watchos")
        snap("watch-22-busy-through-the-iphone")
    }

    /// An announcement whose own clip the watch can't read (an MP3 from the Claude path): its words are said by the
    /// watch instead of being skipped.
    func test19_AnUnreadableAnnouncementClipIsSpoken() throws {
        let app = try launch(turns: 0)
        waitFor(app, state: "Listening")
        fake("announce", ["say": "“Deploy staging” needs your approval.", "kind": "needs_you", "audio": "broken"])
        waitFor(app, state: "Heads up", timeout: 30)
        XCTAssertEqual(app.staticTexts["assistant-say"].label, "“Deploy staging” needs your approval.")
        snap("watch-23-unreadable-clip-spoken")
        waitFor(app, state: "Listening", timeout: 15)
    }
}
