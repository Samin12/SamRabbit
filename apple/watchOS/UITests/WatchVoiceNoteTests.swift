import XCTest

/// Voice notes and the morning brief on the watch (CONTRACTS-WAVE8 §C3–C4), with real taps in the simulator against
/// the fake bridge's capture and brief routes.
///
/// The debug build's made-up voice (`-SamRabbitVoiceFixture speech|hold`) stands in for the microphone; the note,
/// the AAC file, the outbox, the upload (directly, or through the iPhone in chunks with `-SamRabbitRoute phone`)
/// and the Mac's outcome are real. Nothing is said back: the watch only shows that it went.
///
/// Needs this branch's `apple/dev/fake_bridge.py` (default 127.0.0.1:3807, or `TEST_RUNNER_SAMRABBIT_FAKE_BRIDGE`),
/// the iPhone simulator paired with it and this watch paired with that iPhone (skips otherwise). Synchronous on
/// purpose, like the other watch tests.
@MainActor
final class WatchVoiceNoteTests: XCTestCase {
    nonisolated private let bridge = ProcessInfo.processInfo.environment["SAMRABBIT_FAKE_BRIDGE"] ?? "127.0.0.1:3807"

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard fakeGet("capture")["mode"] != nil else {
            throw XCTSkip("This branch's fake bridge isn't answering on \(bridge).")
        }
        fake("capture", ["mode": "ok", "delay": 0.8, "clear": true,
                         "heard": "Put this in my journal: the walk by the river was great"])
        fake("briefing", ["mode": "ready", "reset": true, "clear": true])
    }

    /// The Voice Note control's intent: the recorder records at once, the voice pauses and it sends itself, "Sent ✓"
    /// with what the Mac did, then it closes. The Mac got the watch's m4a with its own token.
    func test1_VoiceNoteFromTheControlSendsItself() throws {
        let app = try launch(intent: "note")
        XCTAssertTrue(any(app, "voice-listening").waitForExistence(timeout: 10), "recording at once")
        XCTAssertEqual(app.buttons["voice-stop"].label, "Stop and send")
        snap("watch-note-1-recording")
        let result = app.staticTexts["voice-result"]
        XCTAssertTrue(result.waitForExistence(timeout: 25), "it sent itself after the pause")
        XCTAssertEqual(result.label, "Sent ✓")
        XCTAssertTrue(app.staticTexts["voice-outcome"].label.contains("Added to your journal"))
        snap("watch-note-2-sent")
        XCTAssertFalse(app.buttons["voice-send"].exists, "no review step")
        XCTAssertTrue(waitUntil(timeout: 6) { !result.exists }, "and it closes by itself")
        let upload = try XCTUnwrap((fakeGet("capture")["uploads"] as? [[String: Any]])?.last)
        XCTAssertEqual(upload["source"] as? String, "watch")
        XCTAssertEqual(upload["platform"] as? String, "watchos", "the watch's own token")
        XCTAssertEqual(upload["kind"] as? String, "mp4")
    }

    /// Stop & send, through the iPhone (`-SamRabbitRoute phone`): the note goes in chunks, the phone uploads it with
    /// the watch's token; a note the Mac could only save says so.
    func test2_StopAndSendThroughTheIPhone() throws {
        fake("capture", ["heard": "Look at the pricing page tonight"])
        let app = try launch(intent: "note", voice: "hold", route: "phone")
        let stop = app.buttons["voice-stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        pause(1.5)
        stop.tap()
        let result = app.staticTexts["voice-result"]
        XCTAssertTrue(result.waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["voice-outcome"].label.contains("Saved as a note"))
        snap("watch-note-3-saved")
        let upload = try XCTUnwrap((fakeGet("capture")["uploads"] as? [[String: Any]])?.last)
        XCTAssertEqual(upload["source"] as? String, "watch")
        XCTAssertEqual(upload["platform"] as? String, "watchos")
    }

    /// The Brief page: the headline and what to do first; Done on an item tells the Mac and takes it off.
    func test3_TheBriefPage() throws {
        let app = try launch(page: "brief")
        let headline = app.staticTexts["brief-headline"]
        XCTAssertTrue(headline.waitForExistence(timeout: 20), "the Brief page")
        XCTAssertTrue(headline.label.contains("things need you"))
        snap("watch-brief-1")
        let done = app.buttons["brief-done-bi_dana"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
        XCTAssertTrue(waitUntil(timeout: 10) {
            ((self.fakeGet("briefing")["acts"] as? [[String: String]])?.last ?? [:]) == ["itemId": "bi_dana", "action": "done"]
        })
        XCTAssertTrue(waitUntil(timeout: 10) { !app.staticTexts["Reply to Dana about the SOW"].exists })
        snap("watch-brief-2-done")
    }

    // MARK: - Helpers

    private func launch(page: String = "status", intent: String? = nil, voice: String = "speech",
                        route: String? = nil) throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-SamRabbitPage", page, "-SamRabbitVoiceFixture", voice, "-SamRabbitConversation", "off"]
        if let intent { app.launchArguments += ["-SamRabbitIntent", intent] }
        if let route { app.launchArguments += ["-SamRabbitRoute", route] }
        app.launch()
        // The intent records the moment the app is up (and a short note sends itself a few seconds later): look for
        // the recorder at once rather than wait the pairing screen's three seconds out.
        let unpaired = app.staticTexts["Pair on your iPhone"]
        let recorder = any(app, "voice-listening")
        _ = waitUntil(timeout: 3) { unpaired.exists || (intent != nil && recorder.exists) }
        if unpaired.exists {
            throw XCTSkip("The watch isn't paired (pair the iPhone simulator with the fake bridge first).")
        }
        return app
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
        _ = done.wait(timeout: .now() + 10)
        return answer
    }

    private func any(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return condition()
    }

    private func pause(_ seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }

    private func snap(_ name: String) {
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
