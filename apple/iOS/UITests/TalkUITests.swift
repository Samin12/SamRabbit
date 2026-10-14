import XCTest

/// Talk, the iPhone's live conversation with SamRabbit, driven in the simulator against the fake bridge's assistant
/// (`/v1/mobile/assistant/*`, the streaming turn protocol), with real taps.
///
/// The debug build's made-up voice (`-SamRabbitVoiceFixture speech`, the watch's `ConversationFixture`, compiled
/// into the iPhone app too) stands in for the microphone: after the microphone opens it "says" something for 1.6 s.
/// Everything after it is real: the speech detector, the 16 kHz WAV, the streamed turn, the PCM frames on the
/// player, the captions, the cards, mute, Stop, typed turns, the bar over the tab bar and End. The simulator never
/// listens (no microphone session, no permission prompt) and plays nothing out loud (`AudioGraph` is muted there).
///
///     TEST_RUNNER_SAMRABBIT_FAKE_BRIDGE=127.0.0.1:3797 xcodebuild test -scheme SamRabbit \
///       -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -only-testing:SamRabbitUITests/TalkUITests
///
/// Opt-in: runs only with `TEST_RUNNER_SAMRABBIT_FAKE_BRIDGE` set to the address of this branch's
/// `apple/dev/fake_bridge.py` (it skips when that doesn't answer), so the plain `xcodebuild test` stays the unit
/// tests. An unpaired app is paired with it first (`samrabbit://pair`, code SAMRABBT); `TEST_RUNNER_SAMRABBIT_FAKE_PAIR=1`
/// pairs again even when paired. Screenshots are attached as `phone-talk-…` (and written to
/// `TEST_RUNNER_SAMRABBIT_SHOTS` when set). Synchronous on purpose, like the watch's tests.
@MainActor
final class TalkUITests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "com.samrabbit.mobile")
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    nonisolated private let bridge = ProcessInfo.processInfo.environment["SAMRABBIT_FAKE_BRIDGE"] ?? ""

    nonisolated static let heard = "Draft the release notes for build 2.4"
    nonisolated static let say = "Okay, I started the release notes for build 2.4 in Hermes. Anything else?"

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard !bridge.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_SAMRABBIT_FAKE_BRIDGE=127.0.0.1:<port> (apple/dev/fake_bridge.py) to run.")
        }
        guard fakeGet("assistant")["mode"] != nil else {
            throw XCTSkip("The fake bridge isn't answering on \(bridge) (start apple/dev/fake_bridge.py).")
        }
        fake("assistant", ["mode": "ok", "delay": 0.35, "pace": 0.8, "clear": true, "heard": Self.heard,
                           "say": Self.say])
    }

    override func tearDownWithError() throws {
        guard !bridge.isEmpty else { return }
        fake("assistant", ["mode": "ok", "delay": 0.35, "pace": 0.5, "hold": 0, "ping": 0, "busyFor": 0,
                           "code": "assistant_failed", "heard": Self.heard, "say": Self.say])
    }

    // MARK: - The conversation

    /// Home's Talk button opens Talk listening; it hears the made-up voice, streams the reply with its caption and
    /// the task it started, and listens again. Then a typed turn with a card, mute, Stop during a reply, the bar
    /// over the tab bar, the task opened in Tasks, and End.
    func testTalkFromHome() throws {
        try launch()
        let talkButton = app.buttons["home-talk"]
        XCTAssertTrue(talkButton.waitForExistence(timeout: 10), "Home has the Talk button")
        snap("phone-talk-0-home")
        talkButton.tap()

        XCTAssertNotNil(waitFor(state: "Listening…", "Starting…", timeout: 10), "Talk opens and listens")
        waitFor(state: "Listening…")
        XCTAssertEqual(state.value as? String, "audio on", "the conversation's audio runs (the fixture, muted)")
        snap("phone-talk-1-listening")

        // The made-up voice speaks: heard, sent, answered.
        XCTAssertNotNil(waitFor(state: "Hearing you…", "Thinking…", "Speaking…", timeout: 15), "it hears the voice")
        let say = app.staticTexts["talk-say"]
        XCTAssertTrue(waitFor(say, containing: "release notes", timeout: 20), "the reply streams in as the caption")
        XCTAssertEqual(app.staticTexts["talk-heard"].label, "“\(Self.heard)”", "the line it heard")
        if waitFor(state: "Speaking…", timeout: 6) != nil { snap("phone-talk-2-speaking") }
        let action = app.descendants(matching: .any)["talk-action"]
        XCTAssertTrue(action.waitForExistence(timeout: 20), "the task it started shows as a card")
        XCTAssertTrue(action.label.contains("Release notes for build 2.4"))
        XCTAssertNotNil(waitFor(state: "Listening…", timeout: 20), "and it listens again by itself")
        snap("phone-talk-3-task-card")

        let first = waitForTurns(1)
        XCTAssertEqual(first.last?["kind"] as? String, "audio")
        XCTAssertEqual(first.last?["platform"] as? String, "ios", "straight to the Mac with the iPhone's own token")
        XCTAssertEqual(first.last?["stream"] as? Bool, true)
        XCTAssertEqual(first.last?["contentType"] as? String, "audio/wav")
        XCTAssertFalse((fakeGet("assistant")["sessions"] as? [Any] ?? []).isEmpty, "the Mac was warmed up")

        // A typed turn: the keyboard, then the reply with a card.
        app.buttons["talk-keyboard"].tap()
        let field = app.textFields["talk-field"].exists ? app.textFields["talk-field"] : app.textViews["talk-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the keyboard's field")
        field.typeText("What's next on my calendar?")
        snap("phone-talk-4-typing")
        app.buttons["talk-send"].tap()
        let card = app.descendants(matching: .any)["talk-card"]
        XCTAssertTrue(card.waitForExistence(timeout: 20), "the card it showed")
        XCTAssertTrue(card.label.contains("Design review"), card.label)
        XCTAssertTrue(waitFor(say, containing: "design review", timeout: 10))
        XCTAssertEqual(app.staticTexts["talk-heard"].label, "“What's next on my calendar?”")
        XCTAssertNotNil(waitFor(state: "Listening…", timeout: 20))
        snap("phone-talk-5-card")
        XCTAssertEqual(waitForTurns(2).last?["kind"] as? String, "text", "sent as a {text} turn")

        // Mute and unmute.
        app.buttons["talk-mute"].tap()
        XCTAssertNotNil(waitFor(state: "Muted", timeout: 5), "muted")
        XCTAssertTrue(app.buttons["Unmute"].exists)
        snap("phone-talk-6-muted")
        app.buttons["talk-mute"].tap()
        XCTAssertNotNil(waitFor(state: "Listening…", timeout: 5), "listening again")

        // Stop while it speaks: the Mac is told to cancel, and it listens at once.
        fake("assistant", ["pace": 1.0, "say": "Here is everything that changed since Monday, one project at a time, "
                           + "starting with the website, then the assistant, then the release itself."])
        app.buttons["talk-keyboard"].tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Tell me everything that changed")
        app.buttons["talk-send"].tap()
        XCTAssertNotNil(waitFor(state: "Speaking…", timeout: 20), "the long reply plays")
        let cancelsBefore = (fakeGet("assistant")["cancels"] as? [Any] ?? []).count
        app.buttons["talk-stop"].tap()
        XCTAssertNotNil(waitFor(state: "Listening…", timeout: 5), "Stop interrupts and listens")
        XCTAssertTrue(waitUntil(timeout: 8) { (self.fakeGet("assistant")["cancels"] as? [Any] ?? []).count > cancelsBefore },
                      "the Mac was told to cancel")

        // Minimize: the conversation goes on over the tab bar; tap the bar for Talk.
        app.buttons["talk-minimize"].tap()
        let bar = app.descendants(matching: .any)["talk-bar"]
        XCTAssertTrue(bar.waitForExistence(timeout: 5), "the bar over the tab bar")
        snap("phone-talk-7-minimized")
        bar.tap()
        XCTAssertNotNil(waitFor(state: "Listening…", timeout: 5), "back in Talk, still listening")

        // The task card opens the thread in Tasks (from the transcript).
        app.buttons["talk-transcript"].tap()
        let list = app.descendants(matching: .any)["talk-transcript-list"]
        XCTAssertTrue(list.waitForExistence(timeout: 5), "the transcript")
        snap("phone-talk-8-transcript")
        let started = list.buttons["Release notes for build 2.4"]
        XCTAssertTrue(started.waitForExistence(timeout: 5))
        started.tap()
        XCTAssertTrue(app.staticTexts["Release notes for build 2.4"].waitForExistence(timeout: 10),
                      "the thread opens in Tasks")
        XCTAssertTrue(bar.waitForExistence(timeout: 5), "the conversation goes on meanwhile")
        snap("phone-talk-9-thread")

        // End (from the bar): the conversation ends and tells the Mac.
        let endsBefore = (fakeGet("assistant")["ends"] as? [Any] ?? []).count
        app.buttons["talk-bar-end"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { !bar.exists }, "the bar goes")
        XCTAssertTrue(waitUntil(timeout: 8) { (self.fakeGet("assistant")["ends"] as? [Any] ?? []).count > endsBefore },
                      "the Mac was told it ended")
    }

    /// `samrabbit://talk` (the Lock Screen widget, a Shortcut's Open URL) opens straight into a conversation; End on
    /// the Talk screen closes it.
    func testTalkLink() throws {
        try launch(voice: "quiet")
        XCUIDevice.shared.system.open(URL(string: "samrabbit://talk")!)
        allowOpenAlert()
        XCTAssertNotNil(waitFor(state: "Listening…", "Starting…", timeout: 15), "the link opens Talk listening")
        waitFor(state: "Listening…")
        XCTAssertTrue(app.staticTexts["talk-hint"].exists, "a hint while nothing was said yet")
        let endsBefore = (fakeGet("assistant")["ends"] as? [Any] ?? []).count
        app.buttons["talk-end"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { !self.state.exists }, "End closes Talk")
        XCTAssertTrue(app.buttons["home-talk"].waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil(timeout: 8) { (self.fakeGet("assistant")["ends"] as? [Any] ?? []).count > endsBefore })
    }

    /// The conversation goes on in the background (`UIBackgroundModes: audio`): the made-up voice speaks again while
    /// SamRabbit is not in front and the turn reaches the Mac. The Live Activity shows it in the Dynamic Island and on
    /// the Lock Screen, and its End button ends the conversation (`EndTalkIntent`, run by the app).
    func testBackgroundAndLiveActivity() throws {
        // The voice waits 4 s after the microphone opens: the second time, SamRabbit is in the background by then.
        try launch(turns: 2, lead: 4)
        app.buttons["home-talk"].tap()
        XCTAssertNotNil(waitFor(state: "Listening…", "Starting…", timeout: 10))
        waitForTurns(1, timeout: 25)
        XCTAssertNotNil(waitFor(state: "Listening…", timeout: 25), "the first reply is over")

        // Home: the second utterance is heard and sent with the app in the background.
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        snap("phone-talk-11-dynamic-island", settle: 1.5)
        waitForTurns(2, timeout: 30)
        XCTAssertEqual(app.state, .runningBackground, "still running behind the Home Screen")

        // The Lock Screen: the Live Activity with End.
        let lock = NSSelectorFromString("pressLockButton")
        guard XCUIDevice.shared.responds(to: lock) else { throw XCTSkip("This Xcode can't lock the simulator.") }
        XCUIDevice.shared.perform(lock)
        Thread.sleep(forTimeInterval: 1.5)
        XCUIDevice.shared.press(.home) // wakes the screen (still locked)
        let end = springboard.buttons["End the conversation"]
        XCTAssertTrue(end.waitForExistence(timeout: 10), "the Live Activity on the Lock Screen")
        snap("phone-talk-12-lock-screen", settle: 1)
        let endsBefore = (fakeGet("assistant")["ends"] as? [Any] ?? []).count
        end.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { (self.fakeGet("assistant")["ends"] as? [Any] ?? []).count > endsBefore },
                      "End on the Live Activity ended the conversation")
        XCTAssertTrue(waitUntil(timeout: 10) { !end.exists }, "and the Live Activity went")
        // Unlock (no passcode in the simulator) and back to the app.
        springboard.swipeUp()
        app.activate()
        XCTAssertTrue(app.buttons["home-talk"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["talk-bar"].exists, "no conversation any more")
    }

    /// The Mac can't be reached: said, then the conversation ends with what to do about it.
    func testMacOutOfReach() throws {
        fake("assistant", ["mode": "drop"])
        try launch()
        app.buttons["home-talk"].tap()
        let problem = app.staticTexts["talk-problem"]
        XCTAssertTrue(problem.waitForExistence(timeout: 40), "it says what went wrong")
        snap("phone-talk-10-unreachable")
        XCTAssertTrue(app.buttons["talk-start"].exists, "and offers to talk again")
        app.buttons["talk-close"].tap()
        XCTAssertTrue(app.buttons["home-talk"].waitForExistence(timeout: 5))
    }

    // MARK: - Helpers

    private func launch(voice: String = "speech", turns: Int = 1, lead: Double = 1.5) throws {
        app.launchArguments = ["-SamRabbitVoiceFixture", voice, "-SamRabbitFixtureTurns", String(turns),
                               "-SamRabbitFixtureLead", String(lead)]
        // A still orb keeps the app idle between frames (quick queries); `SAMRABBIT_ANIMATED=1` for screenshots.
        if ProcessInfo.processInfo.environment["SAMRABBIT_ANIMATED"] != "1" {
            app.launchArguments += ["-SamRabbitStillOrb", "YES"]
        }
        app.launch()
        try pairIfNeeded()
    }

    /// Pairs with the fake bridge when the app isn't paired (or `SAMRABBIT_FAKE_PAIR=1`).
    private func pairIfNeeded() throws {
        let unpaired = app.staticTexts["Not paired yet"].waitForExistence(timeout: 3)
        guard unpaired || ProcessInfo.processInfo.environment["SAMRABBIT_FAKE_PAIR"] == "1" else { return }
        XCUIDevice.shared.system.open(URL(string: "samrabbit://pair?h=\(bridge)&c=SAMRABBT&n=Fake%20Mac")!)
        allowOpenAlert()
        let pair = app.buttons["Pair"]
        guard pair.waitForExistence(timeout: 10) else { throw XCTSkip("The pairing sheet didn't open.") }
        pair.tap()
        guard app.buttons["home-talk"].waitForExistence(timeout: 20) else {
            throw XCTSkip("Pairing with the fake bridge on \(bridge) didn't work.")
        }
    }

    /// iOS may ask "Open in “SamRabbit”?" for a link the test opens.
    private func allowOpenAlert() {
        let open = springboard.buttons["Open"]
        if open.waitForExistence(timeout: 2) { open.tap() }
    }

    private var state: XCUIElement { app.staticTexts["talk-state"] }

    /// Waits until the state pill says one of `texts`. Returns the one it saw.
    @discardableResult
    private func waitFor(state texts: String..., timeout: TimeInterval = 15) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if state.exists {
                let label = state.label
                if let found = texts.first(where: { label.hasPrefix($0) }) { return found }
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return nil
    }

    private func waitFor(_ element: XCUIElement, containing text: String, timeout: TimeInterval) -> Bool {
        waitUntil(timeout: timeout) { element.exists && element.label.localizedCaseInsensitiveContains(text) }
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return condition()
    }

    @discardableResult
    private func waitForTurns(_ count: Int, timeout: TimeInterval = 20) -> [[String: Any]] {
        var turns: [[String: Any]] = []
        _ = waitUntil(timeout: timeout) {
            turns = self.fakeGet("assistant")["turns"] as? [[String: Any]] ?? []
            return turns.count >= count
        }
        XCTAssertGreaterThanOrEqual(turns.count, count, "the Mac got \(turns.count) turns")
        return turns
    }

    @discardableResult
    nonisolated private func fake(_ name: String, _ body: [String: Any] = [:]) -> [String: Any] {
        var request = URLRequest(url: URL(string: "http://\(bridge)/__fake/\(name)")!)
        request.httpMethod = "POST"
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return exchange(request)
    }

    nonisolated private func fakeGet(_ name: String) -> [String: Any] {
        exchange(URLRequest(url: URL(string: "http://\(bridge)/__fake/\(name)")!))
    }

    nonisolated private func exchange(_ request: URLRequest) -> [String: Any] {
        nonisolated(unsafe) var answer: [String: Any] = [:]
        let done = DispatchSemaphore(value: 0)
        var request = request
        request.timeoutInterval = 5
        URLSession.shared.dataTask(with: request) { data, _, _ in
            answer = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 8)
        return answer
    }

    private func snap(_ name: String, settle: TimeInterval = 0.6) {
        Thread.sleep(forTimeInterval: settle) // transitions finish
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let folder = ProcessInfo.processInfo.environment["SAMRABBIT_SHOTS"] {
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
        }
    }
}
