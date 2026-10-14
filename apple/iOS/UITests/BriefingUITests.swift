import XCTest

/// The morning brief on the iPhone's Home (CONTRACTS-WAVE8 §C4), driven in the simulator against the fake bridge's
/// brief (`/v1/mobile/briefing`, `/briefing/items/<id>/act`, `/briefing/refresh`), with real taps.
///
/// Home shows the brief at the top until noon; `-SamRabbitBriefAllDay YES` (debug builds) lifts that so the test runs
/// at any hour, and `-SamRabbitOpenLinks off` keeps the Gmail links in the app (no Safari). Nothing is ever sent: the
/// fake answers a draft with a made-up drafts link.
///
///     TEST_RUNNER_SAMRABBIT_FAKE_BRIDGE=127.0.0.1:3807 xcodebuild test -scheme SamRabbit \
///       -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -only-testing:SamRabbitUITests/BriefingUITests
///
/// Opt-in like the other walkthroughs; screenshots `phone-brief-…` (also to `TEST_RUNNER_SAMRABBIT_SHOTS`).
@MainActor
final class BriefingUITests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "com.samrabbit.mobile")
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    nonisolated private let bridge = ProcessInfo.processInfo.environment["SAMRABBIT_FAKE_BRIDGE"] ?? ""

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard !bridge.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_SAMRABBIT_FAKE_BRIDGE=127.0.0.1:<port> (apple/dev/fake_bridge.py) to run.")
        }
        guard fakeGet("briefing")["mode"] != nil else {
            throw XCTSkip("The fake bridge isn't answering on \(bridge) (start this branch's apple/dev/fake_bridge.py).")
        }
        fake("briefing", ["mode": "ready", "reset": true, "clear": true])
    }

    override func tearDownWithError() throws {
        guard !bridge.isEmpty else { return }
        fake("briefing", ["mode": "ready", "reset": true])
    }

    /// The brief leads Home: the headline, Do first with each item's verbs, Today with its conflict, the agent
    /// waiting, FYI folded. Draft reply saves a draft (never sent) and says so; Make task starts a task; Done takes
    /// the item off; Block prep blocks time; Dismiss on FYI; the refresh button builds it again.
    func testTheMorningBriefLeadsHomeAndItsVerbsResolveItems() throws {
        try launch()
        let headline = app.staticTexts["brief-headline"]
        XCTAssertTrue(headline.waitForExistence(timeout: 15), "the brief at the top of Home")
        XCTAssertTrue(headline.label.contains("things need you"), headline.label)
        XCTAssertTrue(app.staticTexts["Reply to Dana about the SOW"].exists)
        snap("phone-brief-0-home")

        // Draft reply: a Gmail draft, nothing sent.
        app.buttons["brief-draft_reply-bi_dana"].tap()
        XCTAssertTrue(app.staticTexts["Draft saved in Gmail"].waitForExistence(timeout: 10), "said so")
        let state = app.staticTexts["brief-state-bi_dana"]
        XCTAssertTrue(state.waitForExistence(timeout: 10))
        XCTAssertEqual(state.label, "Draft saved in Gmail")
        XCTAssertTrue(app.buttons["Open draft"].exists || app.links["Open draft"].exists, "the draft's link")
        XCTAssertEqual(lastTap(), ["itemId": "bi_dana", "action": "draft_reply"])
        snap("phone-brief-1-drafted")

        // Make task.
        let task = app.buttons["brief-make_task-bi_acme"]
        scrollTo(task)
        task.tap()
        XCTAssertTrue(app.staticTexts["Task started"].waitForExistence(timeout: 10))
        XCTAssertEqual(lastTap(), ["itemId": "bi_acme", "action": "make_task"])
        XCTAssertTrue(app.staticTexts["brief-state-bi_acme"].waitForExistence(timeout: 10))

        // Done: off the brief.
        let done = app.buttons["brief-done-bi_payout"]
        scrollTo(done)
        done.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { !self.app.staticTexts["Fix the failed Stripe payout"].exists })
        XCTAssertEqual(lastTap(), ["itemId": "bi_payout", "action": "done"])

        // Today: the conflict and Block prep.
        let block = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'brief-block_time-'")).firstMatch
        scrollTo(block)
        XCTAssertTrue(app.descendants(matching: .any)["brief-today"].exists)
        snap("phone-brief-2-today")
        block.tap()
        XCTAssertTrue(app.staticTexts["Time blocked"].waitForExistence(timeout: 10))
        XCTAssertEqual(lastTap()["action"], "block_time")

        // FYI, folded: open it and dismiss one.
        let fyi = app.buttons["brief-fyi"]
        scrollTo(fyi)
        fyi.tap()
        let dismiss = app.buttons["brief-dismiss-bi_fyi_renewal"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 5))
        snap("phone-brief-3-fyi")
        dismiss.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { !self.app.staticTexts["Domain renews in 9 days"].exists })
        XCTAssertEqual(lastTap(), ["itemId": "bi_fyi_renewal", "action": "dismiss"])

        // Build it again.
        app.swipeDown()
        app.swipeDown()
        let refresh = app.buttons["brief-refresh"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 5))
        refresh.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { !((self.fakeGet("briefing")["refreshes"] as? [Any]) ?? []).isEmpty })
    }

    /// No brief yet today: Home has no brief, the rest as always.
    func testNoBriefYetLeavesHomeAsItWas() throws {
        fake("briefing", ["mode": "none"])
        try launch()
        XCTAssertTrue(app.buttons["home-talk"].waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 2)
        XCTAssertFalse(app.staticTexts["brief-headline"].exists, "nothing to show")
    }

    // MARK: - Helpers

    private func launch() throws {
        app.launchArguments = ["-SamRabbitBriefAllDay", "YES", "-SamRabbitOpenLinks", "off", "-SamRabbitStillOrb", "YES"]
        app.launch()
        try pairIfNeeded()
    }

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

    /// The last tap the Mac got (item and action).
    private func lastTap() -> [String: String] {
        var last: [String: String] = [:]
        _ = waitUntil(timeout: 5) {
            let taps = self.fakeGet("briefing")["acts"] as? [[String: String]] ?? []
            last = taps.last ?? [:]
            return !taps.isEmpty
        }
        return last
    }

    private func scrollTo(_ element: XCUIElement) {
        for _ in 0..<8 where !(element.exists && element.isHittable) {
            app.swipeUp()
        }
        XCTAssertTrue(element.exists, "\(element) on Home")
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.25)
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
        Thread.sleep(forTimeInterval: settle)
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
