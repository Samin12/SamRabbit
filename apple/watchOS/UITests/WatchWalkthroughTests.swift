import XCTest

/// A walkthrough of the Apple Watch app with real taps, against the fake bridge.
///
/// Needs: `apple/dev/fake_bridge.py` on 127.0.0.1:3799 (reset it first: `curl -X POST
/// 127.0.0.1:3799/__fake/reset`), the iPhone simulator paired with it and this watch simulator
/// paired with that iPhone (the watch gets its token from the phone). Skips itself when the watch
/// isn't paired. Every step attaches a screenshot (named `watch-…`).
@MainActor
final class WatchWalkthroughTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    /// `voice`: the debug build's made-up voice (`VoiceFixtureSource`) instead of the microphone.
    private func launch(page: String, route: String? = nil, intent: String? = nil,
                        voice: String = "speech") throws -> XCUIApplication {
        let app = XCUIApplication()
        // The conversation on the main page stays off (it has its own tests: `WatchConversationTests`).
        app.launchArguments = ["-SamRabbitPage", page, "-SamRabbitVoiceFixture", voice, "-SamRabbitConversation", "off"]
        if let route { app.launchArguments += ["-SamRabbitRoute", route] }
        if let intent { app.launchArguments += ["-SamRabbitIntent", intent] }
        app.launch()
        if app.staticTexts["Pair on your iPhone"].waitForExistence(timeout: 3) {
            throw XCTSkip("The watch isn't paired (pair the iPhone simulator with the fake bridge first).")
        }
        return app
    }

    private func element(_ app: XCUIApplication, labelBeginsWith text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", text)).firstMatch
    }

    private func snap(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func element(_ app: XCUIApplication, labelContains text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// Lets the data settle and animations finish before a screenshot.
    private func settle(_ seconds: TimeInterval = 1.2) {
        _ = XCUIApplication().wait(for: .runningForeground, timeout: seconds)
        Thread.sleep(forTimeInterval: seconds)
    }


    func test1_StatusPage() throws {
        let app = try launch(page: "status")
        XCTAssertTrue(app.buttons["assistant-talk"].waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, labelBeginsWith: "2 need you").waitForExistence(timeout: 10))
        settle()
        snap("watch-1-status")
    }

    func test2_NeedsYouApproveAndAnswer() throws {
        let app = try launch(page: "needs")
        let approve = app.buttons["approve-t_deploy24"]
        XCTAssertTrue(approve.waitForExistence(timeout: 10))
        settle()
        snap("watch-2-needs-you")
        app.swipeUp()
        settle(0.8)
        snap("watch-2-needs-you-question")
        app.swipeDown()
        settle(0.8)
        approve.tap()
        XCTAssertTrue(element(app, labelBeginsWith: "Approved").waitForExistence(timeout: 15))
        snap("watch-2-needs-you-approved")
        // The question offers answers as buttons.
        let option = app.buttons["/home"]
        XCTAssertTrue(option.waitForExistence(timeout: 10))
        option.tap()
        XCTAssertTrue(element(app, labelBeginsWith: "Answer sent").waitForExistence(timeout: 15))
        settle(0.5)
        snap("watch-2-needs-you-answered")
    }

    /// `POST <fake bridge>/__fake/<name>` (the fake bridge's loopback helpers; `TEST_RUNNER_SAMRABBIT_FAKE_BRIDGE`,
    /// default 127.0.0.1:3799).
    private func fake(_ name: String, _ body: [String: Any] = [:]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "http://\(WatchConversationTests.bridge)/__fake/\(name)")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: request)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// The card shows approval A; on the Mac A was answered elsewhere and T3 asked approval B. Tapping
    /// Approve on the stale card must not approve B: the bridge refuses A's id (409), the watch says
    /// so and shows B instead.
    func test2b_StaleApprovalIsRefused() async throws {
        _ = try await fake("reset")
        let app = try launch(page: "needs")
        let approve = app.buttons["approve-t_deploy24"]
        XCTAssertTrue(approve.waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, labelContains: "deploy.sh staging").waitForExistence(timeout: 5))
        _ = try await fake("rerequest", ["threadId": "t_deploy24",
                                         "text": "Run ./deploy.sh production (pushes build 2.4.0-rc1 to production)"])
        approve.tap()
        XCTAssertTrue(element(app, labelBeginsWith: "Request changed").waitForExistence(timeout: 15))
        XCTAssertTrue(element(app, labelContains: "deploy.sh production").waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["approve-t_deploy24"].exists, "B still waits for an answer")
        settle(0.4)
        snap("watch-2b-request-changed")
        _ = try await fake("reset")
    }

    func test3_WorkingAndThreadDetail() throws {
        let app = try launch(page: "working")
        let row = element(app, labelBeginsWith: "Weekly report from Linear")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        settle()
        snap("watch-3-working")
        row.tap()
        XCTAssertTrue(app.buttons["Stop"].waitForExistence(timeout: 10) || app.buttons["Reply"].waitForExistence(timeout: 5))
        settle()
        snap("watch-3-thread-detail")
    }

    func test4_UpNext() throws {
        let app = try launch(page: "upnext")
        XCTAssertTrue(element(app, labelBeginsWith: "Lunch with Maya").waitForExistence(timeout: 10))
        settle()
        snap("watch-4-up-next")
    }

    func test5_QuickBlock() throws {
        let app = try launch(page: "quick")
        let block = app.buttons["block30"]
        XCTAssertTrue(block.waitForExistence(timeout: 10))
        settle()
        snap("watch-5-quick")
        block.tap()
        XCTAssertTrue(element(app, labelBeginsWith: "Blocked 30 min").waitForExistence(timeout: 20))
        snap("watch-5-quick-blocked")
    }

    /// The voice capture: it listens by itself, stops after the quiet that follows the (made-up) voice,
    /// shows the Mac's words, and Send performs the action. No keyboard anywhere.
    private func speakAndSend(_ app: XCUIApplication, snapshot name: String, tapStop: Bool = false) {
        let stop = app.descendants(matching: .any)["voice-stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 12), "listening")
        snap("\(name)-listening")
        if tapStop { stop.tap() }
        let transcript = app.staticTexts["voice-transcript"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 20), "the words came back")
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        XCTAssertFalse(app.textViews.firstMatch.exists)
        XCTAssertFalse(app.textFields.firstMatch.exists)
        settle(0.5)
        snap("\(name)-review")
        app.buttons["voice-send"].tap()
    }

    func test6_JournalNoteByVoice() throws {
        fakeSync("transcribe", ["mode": "ok", "delay": 0.8, "text": "Walked the dog before standup"])
        let app = try launch(page: "quick")
        let note = app.buttons["journalNote"]
        XCTAssertTrue(note.waitForExistence(timeout: 10))
        note.tap()
        speakAndSend(app, snapshot: "watch-6-journal-note")
        XCTAssertTrue(element(app, labelBeginsWith: "Added to journal").waitForExistence(timeout: 15))
        snap("watch-6-journal-note-added")
        let journal = fakeGet("journal")["lines"] as? [String] ?? []
        XCTAssertTrue(journal.last?.hasSuffix("Walked the dog before standup") == true)
    }

    /// Quick > New task: a T3 task by voice (the words checked before they go).
    func test7_NewTaskByVoice() throws {
        fakeSync("transcribe", ["mode": "ok", "delay": 0.8, "text": "Draft the release notes for 2.4"])
        let app = try launch(page: "quick")
        let ask = app.buttons["newTask"]
        XCTAssertTrue(ask.waitForExistence(timeout: 10))
        ask.tap()
        speakAndSend(app, snapshot: "watch-7-ask")
        XCTAssertTrue(element(app, labelBeginsWith: "Started").waitForExistence(timeout: 20))
        settle(0.6)
        snap("watch-7-ask-started")
    }

    // The Action Button and Siri open the conversation: `WatchConversationTests.test9_ActionButtonOpensTheConversation`.

    /// The fake bridge's loopback helpers, synchronously (these tests stay synchronous: a UI failure in
    /// an async test with `continueAfterFailure = false` can hang the run).
    @discardableResult
    private func fakeSync(_ name: String, _ body: [String: Any]) -> [String: Any] {
        var request = URLRequest(url: URL(string: "http://\(WatchConversationTests.bridge)/__fake/\(name)")!)
        request.httpMethod = "POST"
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return exchange(request)
    }

    private func fakeGet(_ name: String) -> [String: Any] {
        exchange(URLRequest(url: URL(string: "http://\(WatchConversationTests.bridge)/__fake/\(name)")!))
    }

    private func exchange(_ request: URLRequest) -> [String: Any] {
        nonisolated(unsafe) var answer: [String: Any] = [:]
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, _, _ in
            answer = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 10)
        return answer
    }

    /// The Quick page says where to set the Action Button.
    func test5b_QuickPageActionButtonHint() throws {
        let app = try launch(page: "quick")
        let hint = app.descendants(matching: .any)["action-button-hint"]
        XCTAssertTrue(app.buttons["block30"].waitForExistence(timeout: 10))
        app.swipeUp()
        XCTAssertTrue(hint.waitForExistence(timeout: 5))
        settle(0.8)
        snap("watch-5b-quick-action-button-hint")
    }

    /// Every request goes through the iPhone (`-SamRabbitRoute phone`): the summary and an action.
    func test8_RelayThroughThePhone() throws {
        let app = try launch(page: "quick", route: "phone")
        let viaPhone = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "via iPhone"))
        XCTAssertTrue(viaPhone.firstMatch.waitForExistence(timeout: 15))
        settle()
        snap("watch-8-relay-quick")
        app.buttons["block30"].tap()
        XCTAssertTrue(element(app, labelBeginsWith: "Blocked 30 min").waitForExistence(timeout: 25))
        snap("watch-8-relay-blocked")
    }

    /// After the Mac revoked the watch's own token (the desktop app's device list), the watch
    /// offers Reconnect, which asks the iPhone for a new child token. Skips unless the token was
    /// revoked first (`DELETE /v1/mobile/devices/<watch id>` on the fake bridge).
    func test9_ReconnectAfterTheMacRevokedTheWatch() throws {
        let app = try launch(page: "status")
        let reconnect = app.buttons["Reconnect"]
        guard reconnect.waitForExistence(timeout: 12) else {
            throw XCTSkip("The watch's token is still accepted (revoke it on the fake bridge to run this).")
        }
        settle(0.5)
        snap("watch-9-revoked")
        reconnect.tap()
        XCTAssertTrue(app.buttons["assistant-talk"].waitForExistence(timeout: 25))
        XCTAssertFalse(app.buttons["Reconnect"].exists)
        settle()
        snap("watch-9-reconnected")
    }
}
