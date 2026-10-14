import XCTest

/// Tasks and Home with every agent on the Mac (the inbox, `/v1/mobile/inbox`: T3 Code threads, Claude Code and Codex
/// sessions), driven in the simulator against the fake bridge's inbox with real taps.
///
///     TEST_RUNNER_SAMRABBIT_FAKE_BRIDGE=127.0.0.1:3796 xcodebuild test -scheme SamRabbit \
///       -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -only-testing:SamRabbitUITests/TasksUITests
///
/// Opt-in like `TalkUITests`: runs only with `TEST_RUNNER_SAMRABBIT_FAKE_BRIDGE` set to the address of this branch's
/// `apple/dev/fake_bridge.py` (it skips when that doesn't answer or has no inbox). Each test resets the fake. An
/// unpaired app is paired with it first; `TEST_RUNNER_SAMRABBIT_FAKE_PAIR=1` pairs again even when paired.
/// Screenshots are attached as `phone-…` (and written to `TEST_RUNNER_SAMRABBIT_SHOTS` when set).
@MainActor
final class TasksUITests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "com.samrabbit.mobile")
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    nonisolated private let bridge = ProcessInfo.processInfo.environment["SAMRABBIT_FAKE_BRIDGE"] ?? ""

    nonisolated static let flaky = "claude:5d0c6f2e-1a47-4f7e-9a51-3c2b1e0d9f88"
    nonisolated static let changelog = "claude:8b1e2c3d-4f5a-4b6c-8d7e-9f0a1b2c3d4e"
    nonisolated static let retry = "claude:c41f9a70-2b6d-4e8a-9c35-7d1e0f2a3b4c"
    nonisolated static let pytest = "codex:019a1f2e-3d4c-7b5a-9687-a5b4c3d2e1f0"
    nonisolated static let onboarding = "codex:019a6c7d-8e9f-7a01-b2c3-d4e5f6a7b8c9"

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard !bridge.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_SAMRABBIT_FAKE_BRIDGE=127.0.0.1:<port> (apple/dev/fake_bridge.py) to run.")
        }
        guard fakeGet("inbox")["missing"] != nil else {
            throw XCTSkip("The fake bridge on \(bridge) isn't answering or has no inbox (start apple/dev/fake_bridge.py).")
        }
        fake("reset")
        fake("inbox", ["missing": false, "clear": true])
        fake("t3", ["available": true])
    }

    override func tearDownWithError() throws {
        guard !bridge.isEmpty else { return }
        fake("inbox", ["missing": false])
        fake("t3", ["available": true])
    }

    // MARK: - The whole inbox

    /// Home counts every agent and shows their cards; Tasks lists T3, Claude Code and Codex with their glyphs in Needs
    /// you / Working / Recent, filters by source, approves a T3 request inline as before and marks a failed Codex run
    /// seen.
    func testEveryAgentOnHomeAndInTasks() throws {
        try launch()
        let headline = app.staticTexts["7 tasks need you"]
        XCTAssertTrue(headline.waitForExistence(timeout: 20), "Home counts every agent's needs-you (the inbox)")
        XCTAssertTrue(card(Self.flaky).waitForExistence(timeout: 10), "a Claude Code session among Home's cards")
        XCTAssertTrue(card("t3:t_deploy24").exists, "and the T3 approval")
        snap("phone-home")
        app.swipeUp()
        snap("phone-home-2")

        openTasks()
        XCTAssertTrue(card(Self.flaky).waitForExistence(timeout: 10))
        XCTAssertTrue(card(Self.flaky).staticTexts["Waiting for you in the terminal"].exists,
                      "a Claude Code permission prompt waits in the terminal")
        XCTAssertTrue(card("t3:t_deploy24").buttons["Approve"].exists, "T3 approvals are answered inline, as before")
        XCTAssertTrue(card(Self.pytest).exists, "a Codex run that failed")
        snap("phone-tasks")
        app.swipeUp()
        XCTAssertTrue(row(Self.retry).waitForExistence(timeout: 5), "a live Claude Code session under Working")
        XCTAssertTrue(row(Self.onboarding).exists, "a Codex Desktop thread under Working")
        snap("phone-tasks-2")
        app.swipeUp()
        snap("phone-tasks-3")
        app.swipeDown()
        app.swipeDown()

        // The source filter.
        app.buttons["tasks-filter-claude"].tap()
        XCTAssertTrue(waitUntil(timeout: 5) { !self.card("t3:t_deploy24").exists }, "Claude only")
        XCTAssertTrue(card(Self.flaky).exists)
        snap("phone-tasks-claude")
        app.buttons["tasks-filter-codex"].tap()
        XCTAssertTrue(card(Self.pytest).waitForExistence(timeout: 5))
        XCTAssertFalse(card(Self.flaky).exists, "Codex only")
        app.buttons["tasks-filter-all"].tap()
        XCTAssertTrue(card("t3:t_deploy24").waitForExistence(timeout: 5))

        // T3: Approve, exactly as before (the T3 route with the card's request id).
        card("t3:t_deploy24").buttons["Approve"].tap()
        XCTAssertTrue(waitUntil(timeout: 10) { !self.card("t3:t_deploy24").exists }, "approved: it leaves Needs you")

        // Codex: Mark seen.
        let seen = card(Self.pytest).buttons["inbox-seen-\(Self.pytest)"]
        XCTAssertTrue(seen.exists)
        seen.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { !self.card(Self.pytest).exists }, "seen: it leaves Needs you")
        XCTAssertTrue(waitUntil(timeout: 5) {
            (self.fakeGet("inbox")["seen"] as? [[String: Any]] ?? []).contains { $0["id"] as? String == Self.pytest }
        }, "the Mac was told")
        XCTAssertEqual(app.staticTexts["5 tasks need you"].exists || app.tabBars.buttons["Tasks"].value as? String == "5",
                       true, "one fewer from each")
    }

    // MARK: - Claude Code

    /// A Claude Code session that no terminal owns takes a reply: the Mac resumes it in a new Terminal window
    /// (`how: "terminal"`), and it shows live and working, then finished. One waiting for a permission in its
    /// terminal says so, with what it asks, and has no reply field.
    func testClaudeSessionReplyAndWaiting() throws {
        try launch()
        openTasks()
        let reply = card(Self.changelog).buttons["inbox-reply-\(Self.changelog)"]
        XCTAssertTrue(reply.waitForExistence(timeout: 15), "a finished Claude Code session offers Reply")
        reply.tap()
        let title = app.staticTexts["inbox-detail-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10), "its screen")
        XCTAssertEqual(title.label, "Summarize this week's merged PRs for the changelog")
        XCTAssertTrue(app.staticTexts["Claude Code"].exists)
        let field = app.textFields["Reply to Claude Code"].exists ? app.textFields["Reply to Claude Code"]
            : app.textViews["Reply to Claude Code"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the reply field")
        XCTAssertTrue(app.descendants(matching: .any)["inbox-detail-seen"].exists, "Mark seen")
        snap("phone-claude-item")

        field.tap()
        field.typeText("Yes, open the PR")
        snap("phone-claude-typing")
        app.buttons["Send"].tap()
        XCTAssertTrue(waitUntil(timeout: 10) {
            (self.fakeGet("inbox")["replies"] as? [[String: Any]] ?? []).contains { $0["id"] as? String == Self.changelog }
        }, "the reply reached the Mac")
        XCTAssertTrue(app.staticTexts["Sent to your Mac"].waitForExistence(timeout: 5), "it says where it went")
        let open = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'open in Terminal'")).firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 10), "now live in a terminal on the Mac")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Yes, open the PR'")).firstMatch.exists,
                      "the reply in the conversation")
        XCTAssertTrue(app.descendants(matching: .any)["inbox-hold"].waitForExistence(timeout: 10),
                      "open in a terminal: answered there, no reply field")
        snap("phone-claude-replied")
        let finished = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'I followed your note'")).firstMatch
        XCTAssertTrue(finished.waitForExistence(timeout: 20), "and its answer once it finished")

        // The one waiting for a permission in its terminal.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let waiting = card(Self.flaky)
        XCTAssertTrue(waiting.waitForExistence(timeout: 10))
        waiting.buttons["Investigate the flaky long-poll test in the bridge suite"].tap()
        let hold = app.descendants(matching: .any)["inbox-hold"]
        XCTAssertTrue(hold.waitForExistence(timeout: 10))
        XCTAssertTrue(hold.label.contains("Waiting for you in the terminal"), hold.label)
        XCTAssertTrue(app.staticTexts["Wants to run a command"].exists, "what it asks")
        XCTAssertFalse(app.textFields["Reply to Claude Code"].exists || app.textViews["Reply to Claude Code"].exists,
                       "no reply from here: only the terminal answers it")
        snap("phone-claude-waiting")

        // Codex Desktop owns its thread.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let onboarding = row(Self.onboarding)
        scrollTo(onboarding)
        onboarding.tap()
        XCTAssertTrue(app.descendants(matching: .any)["inbox-hold"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["inbox-hold"].label.contains("Codex app"))
        snap("phone-codex-app")
    }

    // MARK: - T3 Code down, an older bridge, a new task

    /// T3 Code stops answering: the Claude Code and Codex rows stay fresh, the T3 rows stay as they were under
    /// "T3 not connected".
    func testT3DownKeepsTheOthers() throws {
        try launch()
        openTasks()
        XCTAssertTrue(card("t3:t_deploy24").waitForExistence(timeout: 15))
        fake("t3", ["available": false])
        app.swipeDown() // pull to refresh
        XCTAssertTrue(app.staticTexts["T3 not connected"].waitForExistence(timeout: 15), "only the T3 part says so")
        XCTAssertTrue(card("t3:t_deploy24").exists, "the last T3 rows stay")
        XCTAssertTrue(card(Self.flaky).exists, "Claude Code is still there")
        snap("phone-tasks-t3-down")
    }

    /// A bridge without the inbox (before Wave 7): Tasks is T3's thread list, as before.
    func testOlderBridgeWithoutTheInbox() throws {
        fake("inbox", ["missing": true])
        try launch()
        openTasks()
        XCTAssertTrue(card("t3:t_deploy24").waitForExistence(timeout: 20), "T3's threads")
        XCTAssertTrue(card("t3:t_deploy24").buttons["Approve"].exists)
        XCTAssertFalse(card(Self.flaky).exists, "no Claude Code without the inbox")
        XCTAssertFalse(app.buttons["tasks-filter-all"].exists, "one source: no filter")
        snap("phone-tasks-older-bridge")
    }

    /// New task: Codex and its model, sent to `/inbox/new`.
    func testNewTaskWithAnAgent() throws {
        try launch()
        openTasks()
        app.navigationBars.buttons["New task"].tap()
        let codex = app.segmentedControls["new-task-agent"].buttons["Codex"]
        XCTAssertTrue(codex.waitForExistence(timeout: 10), "the agents T3 offers")
        codex.tap()
        XCTAssertTrue(app.buttons["Model"].waitForExistence(timeout: 5) || app.staticTexts["GPT-5.5 Codex"].exists,
                      "and its model")
        let field = app.textViews["What should be done?"].exists ? app.textViews["What should be done?"]
            : app.textFields["What should be done?"]
        field.tap()
        field.typeText("Add a dark mode to the pricing page")
        snap("phone-new-task-codex")
        app.buttons["Start"].tap()
        XCTAssertTrue(waitUntil(timeout: 10) {
            (self.fakeGet("inbox")["new"] as? [[String: Any]] ?? []).contains {
                $0["agent"] as? String == "codex" && $0["model"] as? String == "gpt-5.5-codex"
            }
        }, "sent with Codex and its model")
        XCTAssertTrue(app.staticTexts["Add a dark mode to the pricing page"].waitForExistence(timeout: 10),
                      "the new task shows under Working")
    }

    // MARK: - Helpers

    private func launch() throws {
        app.launchArguments = ["-SamRabbitStillOrb", "YES"]
        app.launch()
        try pairIfNeeded()
    }

    private func openTasks() {
        app.tabBars.buttons["Tasks"].tap()
    }

    private func card(_ id: String) -> XCUIElement { app.descendants(matching: .any)["inbox-card-\(id)"] }

    private func row(_ id: String) -> XCUIElement { app.descendants(matching: .any)["inbox-row-\(id)"] }

    private func scrollTo(_ element: XCUIElement) {
        for _ in 0..<6 where !(element.exists && element.isHittable) { app.swipeUp() }
    }

    /// Pairs with the fake bridge when the app isn't paired (or `SAMRABBIT_FAKE_PAIR=1`).
    private func pairIfNeeded() throws {
        let unpaired = app.staticTexts["Not paired yet"].waitForExistence(timeout: 3)
        guard unpaired || ProcessInfo.processInfo.environment["SAMRABBIT_FAKE_PAIR"] == "1" else { return }
        XCUIDevice.shared.system.open(URL(string: "samrabbit://pair?h=\(bridge)&c=SAMRABBT&n=Fake%20Mac")!)
        let open = springboard.buttons["Open"]
        if open.waitForExistence(timeout: 2) { open.tap() }
        let pair = app.buttons["Pair"]
        guard pair.waitForExistence(timeout: 10) else { throw XCTSkip("The pairing sheet didn't open.") }
        pair.tap()
        guard app.buttons["home-talk"].waitForExistence(timeout: 20) else {
            throw XCTSkip("Pairing with the fake bridge on \(bridge) didn't work.")
        }
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

    private func snap(_ name: String, settle: TimeInterval = 0.8) {
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
