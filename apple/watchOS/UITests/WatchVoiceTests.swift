import XCTest

/// The watch's voice-only input, driven with real taps in the simulator against the fake bridge.
///
/// The debug build's made-up voice (`-SamRabbitVoiceFixture speech|hold|quiet`, `VoiceFixtureSource`)
/// stands in for the microphone: the capture, the level-driven orb, the stop on quiet, the AAC file, the
/// upload (directly, or through the iPhone in chunks with `-SamRabbitRoute phone`) and the bridge's
/// checks are all real; the fake bridge answers with canned words (`/__fake/transcribe`).
///
/// Needs `apple/dev/fake_bridge.py` on 127.0.0.1:3799, the iPhone simulator paired with it and this watch
/// paired with that iPhone (skips otherwise). Screenshots are attached as `voice-…`. The tests are
/// synchronous on purpose: a UI failure inside an async XCTest with `continueAfterFailure = false` can hang
/// the run.
@MainActor
final class WatchVoiceTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        fake("transcribe", ["mode": "ok", "delay": 0.8, "text": "Draft the release notes for build 2.4"])
    }

    override func tearDownWithError() throws {
        fake("transcribe", ["mode": "ok", "delay": 0.6,
                            "text": "Draft the release notes for build 2.4 and post them in the team channel"])
    }

    // MARK: - Helpers

    private func launch(page: String = "status", voice: String = "speech", route: String? = nil,
                        intent: String? = nil, extra: [String] = []) throws -> XCUIApplication {
        let app = XCUIApplication()
        // The conversation on the main page has the microphone otherwise.
        app.launchArguments = ["-SamRabbitPage", page, "-SamRabbitVoiceFixture", voice, "-SamRabbitConversation", "off"] + extra
        if let route { app.launchArguments += ["-SamRabbitRoute", route] }
        if let intent { app.launchArguments += ["-SamRabbitIntent", intent] }
        app.launch()
        if app.staticTexts["Pair on your iPhone"].waitForExistence(timeout: 3) {
            throw XCTSkip("The watch isn't paired (pair the iPhone simulator with the fake bridge first).")
        }
        return app
    }

    /// `POST <fake bridge>/__fake/<name>` (the fake bridge's loopback helpers; `TEST_RUNNER_SAMRABBIT_FAKE_BRIDGE`,
    /// default 127.0.0.1:3799), waiting for the answer.
    @discardableResult
    nonisolated private func fake(_ name: String, _ body: [String: Any] = [:]) -> [String: Any] {
        var request = URLRequest(url: URL(string: "http://\(WatchConversationTests.bridge)/__fake/\(name)")!)
        request.httpMethod = "POST"
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return exchange(request)
    }

    nonisolated private func fakeGet(_ name: String) -> [String: Any] {
        exchange(URLRequest(url: URL(string: "http://\(WatchConversationTests.bridge)/__fake/\(name)")!))
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

    private func any(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func label(_ app: XCUIApplication, beginsWith text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", text)).firstMatch
    }

    private func snap(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func pause(_ seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }

    /// The Quick page has the Mac's fresh summary (so the capture knows whether voice is available).
    private func waitForSummary(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["newTask"].waitForExistence(timeout: 15))
        XCTAssertTrue(label(app, beginsWith: "Samin's MacBook Pro").waitForExistence(timeout: 15))
        pause(1.5)
    }

    /// No text input of any kind is ever on screen.
    private func assertNoKeyboard(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(app.keyboards.firstMatch.exists, "a keyboard", file: file, line: line)
        XCTAssertFalse(app.textViews.firstMatch.exists, "a text view", file: file, line: line)
        XCTAssertFalse(app.textFields.firstMatch.exists, "a text field", file: file, line: line)
    }

    /// The sheet's close button (top left; the tree can list it twice).
    private func close(_ app: XCUIApplication) {
        let buttons = app.buttons.matching(NSPredicate(format: "label IN %@ OR identifier IN %@",
                                                       ["Close", "Cancel", "Dismiss"], ["Close", "Cancel", "Dismiss"]))
        for index in 0..<buttons.count {
            let button = buttons.element(boundBy: index)
            if button.isHittable {
                button.tap()
                return
            }
        }
        XCTFail("no close button: \(app.debugDescription)")
    }

    // MARK: - Tests

    /// New task: listening (the orb follows the voice, Stop), "Writing it down…", the words large with Send and
    /// Say again, Send starts the task.
    func test1_AskListensTranscribesAndSends() throws {
        fake("transcribe", ["delay": 2.0, "text": "Draft the release notes for build 2.4"])
        let app = try launch(page: "quick")
        waitForSummary(app)
        app.buttons["newTask"].tap()
        XCTAssertTrue(any(app, "voice-stop").waitForExistence(timeout: 8))
        XCTAssertTrue(label(app, beginsWith: "Listening").waitForExistence(timeout: 3), "speech was heard")
        assertNoKeyboard(app)
        snap("voice-1-ask-listening")
        XCTAssertTrue(any(app, "voice-transcribing").waitForExistence(timeout: 8), "stopped by itself after the quiet")
        snap("voice-2-transcribing")
        let transcript = app.staticTexts["voice-transcript"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 15))
        XCTAssertEqual(transcript.label, "Draft the release notes for build 2.4")
        XCTAssertTrue(app.buttons["voice-again"].exists)
        assertNoKeyboard(app)
        pause(0.4)
        snap("voice-3-ask-review")
        let uploads = fakeGet("transcribe")["uploads"] as? [[String: Any]] ?? []
        let last = try XCTUnwrap(uploads.last)
        XCTAssertEqual(last["contentType"] as? String, "audio/mp4")
        XCTAssertEqual(last["kind"] as? String, "mp4")
        XCTAssertEqual(last["platform"] as? String, "watchos")
        XCTAssertNotNil(last["lang"] as? String)
        let seconds = try XCTUnwrap(last["seconds"] as? Double)
        XCTAssertTrue(seconds > 3 && seconds < 5, "about 2 s of voice and 1.5 s of quiet: \(seconds)")
        app.buttons["voice-send"].tap()
        XCTAssertTrue(label(app, beginsWith: "Started").waitForExistence(timeout: 20))
        XCTAssertFalse(any(app, "voice-transcript").exists, "the capture closed")
        pause(0.5)
        snap("voice-4-ask-started")
    }

    /// Stop ends a recording that never goes quiet; Say again listens again; closing cancels.
    func test2_StopSayAgainAndClose() throws {
        let app = try launch(page: "quick", voice: "hold")
        waitForSummary(app)
        app.buttons["newTask"].tap()
        let stop = any(app, "voice-stop")
        XCTAssertTrue(stop.waitForExistence(timeout: 8))
        pause(2.5)
        XCTAssertTrue(stop.exists, "still listening while the voice goes on")
        snap("voice-5-hold-listening")
        stop.tap()
        XCTAssertTrue(app.staticTexts["voice-transcript"].waitForExistence(timeout: 15))
        app.buttons["voice-again"].tap()
        XCTAssertTrue(any(app, "voice-stop").waitForExistence(timeout: 8), "listening again")
        snap("voice-6-say-again-listening")
        close(app)
        XCTAssertTrue(app.buttons["newTask"].waitForExistence(timeout: 5), "back on the page")
        XCTAssertFalse(any(app, "voice-stop").exists)
    }

    /// The Mac can't transcribe (the summary says so): a friendly message first, with Say again. Then the
    /// bridge's own errors: unavailable, a failed transcription, no speech. Never a keyboard.
    func test3_UnavailableAndErrors() throws {
        fake("transcribe", ["mode": "unavailable", "delay": 0.3])
        let app = try launch(page: "quick")
        waitForSummary(app)
        pause(1)
        app.buttons["newTask"].tap()
        let problem = app.staticTexts["voice-problem"]
        XCTAssertTrue(problem.waitForExistence(timeout: 8))
        XCTAssertEqual(problem.label, "Your Mac is getting ready")
        XCTAssertFalse(any(app, "voice-stop").exists, "doesn't record for nothing")
        assertNoKeyboard(app)
        snap("voice-7-unavailable")

        app.buttons["voice-again"].tap() // records anyway; the bridge answers 503
        XCTAssertTrue(any(app, "voice-stop").waitForExistence(timeout: 8))
        XCTAssertTrue(label(app, beginsWith: "Voice isn't available").waitForExistence(timeout: 15))
        snap("voice-8-unavailable-from-the-mac")

        fake("transcribe", ["mode": "failed"])
        app.buttons["voice-again"].tap()
        XCTAssertTrue(label(app, beginsWith: "Couldn't make out the words").waitForExistence(timeout: 20))
        snap("voice-9-transcription-failed")

        fake("transcribe", ["mode": "no_speech"])
        app.buttons["voice-again"].tap()
        XCTAssertTrue(label(app, beginsWith: "I didn't hear anything").waitForExistence(timeout: 20))
        assertNoKeyboard(app)
        snap("voice-10-no-speech")

        fake("transcribe", ["mode": "ok"])
        app.buttons["voice-again"].tap()
        XCTAssertTrue(app.staticTexts["voice-transcript"].waitForExistence(timeout: 20), "works again")
        close(app)
    }

    /// Needs you: Reply to an approval and Answer a question, by voice.
    func test4_ReplyAndAnswerByVoice() throws {
        fake("reset")
        fake("transcribe", ["mode": "ok", "delay": 0.8, "text": "Hold off until the smoke tests pass"])
        let app = try launch(page: "needs")
        let reply = app.buttons["reply-t_deploy24"]
        XCTAssertTrue(reply.waitForExistence(timeout: 10))
        reply.tap()
        XCTAssertTrue(app.staticTexts["voice-transcript"].waitForExistence(timeout: 20))
        XCTAssertEqual(app.staticTexts["voice-transcript"].label, "Hold off until the smoke tests pass")
        XCTAssertTrue(label(app, beginsWith: "Reply to").exists)
        pause(0.4)
        snap("voice-11-reply-review")
        app.buttons["voice-send"].tap()
        XCTAssertTrue(label(app, beginsWith: "Reply sent").waitForExistence(timeout: 20))
        snap("voice-12-reply-sent")

        fake("transcribe", ["text": "Send them to the dashboard"])
        let answer = app.buttons["answer-t_loginfix"]
        for _ in 0..<4 where !answer.isHittable {
            app.swipeUp()
            pause(0.6)
        }
        XCTAssertTrue(answer.waitForExistence(timeout: 10))
        answer.tap()
        XCTAssertTrue(app.staticTexts["voice-transcript"].waitForExistence(timeout: 20))
        XCTAssertEqual(app.staticTexts["voice-transcript"].label, "Send them to the dashboard")
        XCTAssertTrue(label(app, beginsWith: "Answer for").exists)
        pause(0.4)
        snap("voice-13-answer-review")
        app.buttons["voice-send"].tap()
        XCTAssertTrue(label(app, beginsWith: "Answer sent").waitForExistence(timeout: 20))
        snap("voice-14-answer-sent")
        fake("reset")
    }

    /// Quick: a journal note in the person's own words.
    func test5_JournalNoteByVoice() throws {
        fake("transcribe", ["text": "Long walk at lunch, felt clear headed after"])
        let app = try launch(page: "quick")
        let note = app.buttons["journalNote"]
        XCTAssertTrue(note.waitForExistence(timeout: 10))
        note.tap()
        XCTAssertTrue(app.staticTexts["voice-transcript"].waitForExistence(timeout: 20))
        XCTAssertEqual(app.staticTexts["voice-transcript"].label, "Long walk at lunch, felt clear headed after")
        XCTAssertTrue(label(app, beginsWith: "Today's journal").exists)
        pause(0.4)
        snap("voice-15-journal-review")
        app.buttons["voice-send"].tap()
        XCTAssertTrue(label(app, beginsWith: "Added to journal").waitForExistence(timeout: 15))
        snap("voice-16-journal-added")
        let lines = fakeGet("journal")["lines"] as? [String] ?? []
        XCTAssertTrue(lines.last?.hasSuffix("Long walk at lunch, felt clear headed after") == true)
    }

    // The Action Button and Siri open the conversation now: `WatchConversationTests.test9_ActionButtonOpensTheConversation`.

    /// Through the iPhone (`-SamRabbitRoute phone`): the recording travels in chunks over WatchConnectivity
    /// and the phone uploads it with the watch's own token.
    func test7_ThroughTheIPhone() throws {
        fake("transcribe", ["text": "Check whether the nightly build passed"])
        let before = (fakeGet("transcribe")["uploads"] as? [[String: Any]] ?? []).count
        let app = try launch(page: "quick", route: "phone")
        XCTAssertTrue(app.buttons["newTask"].waitForExistence(timeout: 15))
        pause(2)
        app.buttons["newTask"].tap()
        let transcript = app.staticTexts["voice-transcript"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 30), "the words came back through the iPhone")
        XCTAssertEqual(transcript.label, "Check whether the nightly build passed")
        pause(0.4)
        snap("voice-18-through-the-iphone")
        let uploads = fakeGet("transcribe")["uploads"] as? [[String: Any]] ?? []
        XCTAssertEqual(uploads.count, min(20, before + 1))
        XCTAssertEqual(uploads.last?["platform"] as? String, "watchos", "the watch's own token, not the phone's")
        close(app)
    }

    /// The watch's microphone permission was refused: say how to allow it (no keyboard fallback).
    func test8_MicrophoneDenied() throws {
        let app = try launch(page: "quick", extra: ["-SamRabbitVoicePermission", "denied"])
        waitForSummary(app)
        app.buttons["newTask"].tap()
        let problem = app.staticTexts["voice-problem"]
        XCTAssertTrue(problem.waitForExistence(timeout: 8))
        XCTAssertEqual(problem.label, "Microphone is off")
        assertNoKeyboard(app)
        snap("voice-19-microphone-denied")
        close(app)
    }
}
