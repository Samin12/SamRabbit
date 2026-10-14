import XCTest

/// Voice notes on the iPhone (CONTRACTS-WAVE8 §C2), driven in the simulator against the fake bridge's capture routes
/// (`/v1/mobile/capture`, `/capture/<id>`, `/captures/<id>/act`), with real taps.
///
/// The debug build's made-up voice (`-SamRabbitVoiceFixture speech|hold`, the watch's `VoiceFixtureSource`, compiled
/// into the iPhone app too) stands in for the microphone and writes a real AAC m4a; everything after it is real: the
/// silence detector, the outbox in the App Group, the background `URLSession` upload with the note's headers, the
/// Mac's outcome, the Live Activity, Tasks. The simulator never records through the Mac's microphone and plays
/// nothing.
///
///     TEST_RUNNER_SAMRABBIT_FAKE_BRIDGE=127.0.0.1:3807 xcodebuild test -scheme SamRabbit \
///       -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -only-testing:SamRabbitUITests/VoiceNoteUITests
///
/// Opt-in like the other walkthroughs (`TEST_RUNNER_SAMRABBIT_FAKE_BRIDGE`; `TEST_RUNNER_SAMRABBIT_FAKE_PAIR=1` pairs
/// again); screenshots `phone-note-…` (also to `TEST_RUNNER_SAMRABBIT_SHOTS`).
@MainActor
final class VoiceNoteUITests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "com.samrabbit.mobile")
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    nonisolated private let bridge = ProcessInfo.processInfo.environment["SAMRABBIT_FAKE_BRIDGE"] ?? ""

    nonisolated static let journal = "Put this in my journal: called the dentist and moved the cleaning to Friday"
    nonisolated static let note = "Look at the pricing page tonight before the launch"

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard !bridge.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_SAMRABBIT_FAKE_BRIDGE=127.0.0.1:<port> (apple/dev/fake_bridge.py) to run.")
        }
        guard fakeGet("capture")["mode"] != nil else {
            throw XCTSkip("The fake bridge isn't answering on \(bridge) (start this branch's apple/dev/fake_bridge.py).")
        }
        fake("capture", ["mode": "ok", "delay": 1.0, "clear": true, "heard": Self.journal])
    }

    override func tearDownWithError() throws {
        guard !bridge.isEmpty else { return }
        fake("capture", ["mode": "ok", "delay": 1.2])
    }

    // MARK: - Tests

    /// Home's Voice note: the recorder records at once, the made-up voice speaks and pauses, and it sends itself:
    /// "Sent ✓ — Added to your journal" with his words, then it closes. The Mac got the m4a with the note's id, its
    /// time and the source; the journal line is his words after the cue.
    func testVoiceNoteFromHomeSendsItselfAfterAPause() throws {
        try launch(voice: "speech")
        let tile = homeTile("Voice note")
        XCTAssertTrue(tile.isHittable, "Home's Voice note tile")
        snap("phone-note-0-home")
        tile.tap()
        XCTAssertTrue(app.staticTexts["capture-timer"].waitForExistence(timeout: 8), "it records at once")
        XCTAssertTrue(waitFor(app.staticTexts["capture-state"], containing: "Recording", timeout: 5))
        snap("phone-note-1-recording", settle: 1.2)
        // The voice stops after about 2 s; 2.5 s of quiet later it sends itself.
        let result = app.staticTexts["capture-result"]
        XCTAssertTrue(result.waitForExistence(timeout: 20), "sent by itself after the pause")
        XCTAssertEqual(result.label, "Sent ✓")
        XCTAssertTrue(waitFor(app.staticTexts["capture-outcome"], containing: "Added to your journal", timeout: 5))
        XCTAssertTrue(app.staticTexts["capture-detail"].label.contains("moved the cleaning to Friday"))
        snap("phone-note-2-sent")
        XCTAssertTrue(waitUntil(timeout: 6) { !result.exists }, "it closes by itself")
        // Home says what the latest note became (`summary.captures`).
        let line = app.descendants(matching: .any)["home-voice-notes"]
        XCTAssertTrue(waitUntil(timeout: 15) { line.exists && line.label.contains("Added to your journal") },
                      "Home's voice-notes line")
        snap("phone-note-2b-home-line")

        let upload = try XCTUnwrap((fakeGet("capture")["uploads"] as? [[String: Any]])?.last)
        XCTAssertEqual(upload["source"] as? String, "iphone")
        XCTAssertEqual(upload["kind"] as? String, "mp4", "the m4a itself")
        XCTAssertEqual(upload["platform"] as? String, "ios")
        let id = try XCTUnwrap(upload["captureId"] as? String)
        XCTAssertNotNil(UUID(uuidString: id), "a UUID made at the start")
        XCTAssertNotNil(upload["capturedAt"] as? String)
        let lines = fakeGet("journal")["lines"] as? [String] ?? []
        XCTAssertTrue(lines.last?.hasSuffix("called the dentist and moved the cleaning to Friday") == true,
                      "his words after the cue, verbatim: \(lines)")
    }

    /// Stop & send; the Mac only saved it, so it waits in Tasks with its suggestion, and Start task turns it into a
    /// T3 task with his words.
    func testASavedNoteWaitsInTasksAndBecomesATask() throws {
        fake("capture", ["heard": Self.note])
        try launch(voice: "hold")
        homeTile("Voice note").tap()
        let stop = app.buttons["capture-stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 8))
        Thread.sleep(forTimeInterval: 1.5)
        stop.tap()
        XCTAssertTrue(waitFor(app.staticTexts["capture-outcome"], containing: "Saved as a note", timeout: 20))
        XCTAssertTrue(app.staticTexts["capture-detail"].label.contains("Start it as a T3 task?"))
        snap("phone-note-3-saved")
        app.buttons["capture-done"].tap()

        app.tabBars.buttons["Tasks"].tap()
        let start = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'note-act-'")).firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 15), "the note under Needs you, with its suggestion")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'pricing page tonight'"))
            .firstMatch.waitForExistence(timeout: 5), "what he said, as its title")
        XCTAssertTrue(app.staticTexts["Start it as a T3 task?"].exists, "what it suggests")
        for _ in 0..<6 where !(start.isHittable && start.frame.maxY < app.frame.maxY - 140) {
            app.swipeUp(velocity: .slow)
        }
        snap("phone-note-4-tasks")
        start.tap()
        XCTAssertTrue(app.staticTexts["Started a T3 task"].waitForExistence(timeout: 10), "the Mac started it")
        XCTAssertTrue(waitUntil(timeout: 10) {
            ((self.fakeGet("capture")["acts"] as? [[String: Any]])?.last?["action"] as? String) == "task"
        })
        XCTAssertTrue(waitUntil(timeout: 10) { !start.exists }, "the note left Needs you")
        snap("phone-note-5-task-started")
    }

    /// Nothing heard in it: the Mac says so and nothing is saved; Try again records again.
    func testNothingHeardSaysSoAndOffersAnotherTry() throws {
        fake("capture", ["mode": "no_speech"])
        try launch(voice: "hold")
        homeTile("Voice note").tap()
        let stop = app.buttons["capture-stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 8))
        Thread.sleep(forTimeInterval: 1.2)
        stop.tap()
        XCTAssertTrue(waitFor(app.staticTexts["capture-result"], containing: "I didn't catch anything", timeout: 20))
        XCTAssertEqual(app.staticTexts["capture-detail"].label, "Nothing was saved.")
        XCTAssertTrue(app.buttons["capture-again"].exists, "Try again")
        snap("phone-note-12-nothing-heard")
        app.buttons["capture-close"].tap()
    }

    /// The Mac out of reach: "Saved", kept on the iPhone, and Home says it waits; once the Mac answers again, Home's
    /// "Tap to try now" sends it at once, whatever pause the outbox had it in (the same note, the same id), and Home's
    /// line follows.
    func testTheMacOutOfReachKeepsTheNoteAndSendsItLater() throws {
        fake("capture", ["mode": "drop"])
        try launch(voice: "hold")
        homeTile("Voice note").tap()
        let stop = app.buttons["capture-stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 8))
        Thread.sleep(forTimeInterval: 1.2)
        stop.tap()
        let result = app.staticTexts["capture-result"]
        XCTAssertTrue(waitFor(result, containing: "Saved", timeout: 30), "kept on the iPhone")
        XCTAssertTrue(app.staticTexts["capture-detail"].label.contains("when your Mac is reachable"))
        snap("phone-note-6-queued")
        let dropped = (fakeGet("capture")["uploads"] as? [[String: Any]] ?? []).compactMap { $0["captureId"] as? String }
        let id = try XCTUnwrap(dropped.last, "it tried")
        // The recorder closes by itself; Home says the note waits on this iPhone.
        XCTAssertTrue(waitUntil(timeout: 10) { !result.exists }, "the recorder closes")
        let line = app.descendants(matching: .any)["home-voice-notes"]
        XCTAssertTrue(waitUntil(timeout: 15) { line.exists && line.isHittable && line.label.contains("waiting for your Mac") },
                      "Home's line")
        snap("phone-note-6b-home-waiting")
        // The Mac answers again: "Tap to try now" sends it at once, whatever pause it was in (the same note, the same
        // id), and Home's line follows without leaving the app.
        fake("capture", ["mode": "ok"])
        line.tap()
        XCTAssertTrue(waitUntil(timeout: 15) {
            (self.fakeGet("capture")["captures"] as? [[String: Any]] ?? []).contains { $0["captureId"] as? String == id }
        }, "the same note reached the Mac once it answered again")
        XCTAssertTrue(waitUntil(timeout: 10) { !(line.exists && line.label.contains("waiting for your Mac")) },
                      "Home no longer says it waits: \(line.exists ? line.label : "-")")
        snap("phone-note-6c-home-sent")
    }

    /// The Action Button's intent (`-SamRabbitIntent note`) opens the recorder recording; the intent again (the second
    /// press) stops and sends it.
    func testTheIntentRecordsAndTheSecondPressSends() throws {
        try launch(voice: "hold", extra: ["-SamRabbitIntent", "note", "-SamRabbitIntentAgain", "9"])
        XCTAssertTrue(app.buttons["capture-stop"].waitForExistence(timeout: 8), "recording from the intent")
        snap("phone-note-11-from-the-intent")
        XCTAssertTrue(waitFor(app.staticTexts["capture-result"], containing: "Sent", timeout: 25),
                      "the second press stopped and sent it (the voice never paused)")
    }

    /// The Action Button again while the last note is still sending (the Mac takes its time to say what it did): the
    /// next note records at once, and the first still reaches the Mac (two notes, two ids), as does the second.
    func testTheIntentWhileSendingStartsTheNextNote() throws {
        fake("capture", ["delay": 8.0])
        let ids = { (self.fakeGet("capture")["uploads"] as? [[String: Any]] ?? []).compactMap { $0["captureId"] as? String } }
        let before = ids().count
        try launch(voice: "hold", extra: ["-SamRabbitIntent", "note", "-SamRabbitIntentAgain", "5,1.5"])
        XCTAssertTrue(app.buttons["capture-stop"].waitForExistence(timeout: 8), "recording from the intent")
        let state = app.staticTexts["capture-state"]
        XCTAssertTrue(waitFor(state, containing: "Sending", timeout: 10), "the second press stopped and sends it")
        XCTAssertTrue(waitUntil(timeout: 5) { ids().count == before + 1 }, "the first note is on its way")
        snap("phone-note-13-sending")
        // The third press, while the first still sends: the next note records at once.
        XCTAssertTrue(waitFor(state, containing: "Recording", timeout: 8), "the next note records: \(state.label)")
        XCTAssertTrue(app.staticTexts["capture-timer"].exists)
        snap("phone-note-14-next-note")
        let first = try XCTUnwrap(ids().last)
        Thread.sleep(forTimeInterval: 1.2)
        app.buttons["capture-stop"].tap()
        XCTAssertTrue(waitFor(app.staticTexts["capture-result"], containing: "Sent", timeout: 25), "the second sent too")
        let all = ids()
        XCTAssertEqual(all.count, before + 2, "two notes went")
        XCTAssertNotEqual(all.last, first, "each with its own id")
        XCTAssertTrue(waitUntil(timeout: 15) {
            (self.fakeGet("capture")["captures"] as? [[String: Any]] ?? []).contains { $0["captureId"] as? String == first }
        }, "the first is on the Mac")
    }

    /// A link from outside the app (`samrabbit://capture` from a web page or a message) opens the recorder but never
    /// turns the microphone on: it waits for a tap.
    func testALinkFromOutsideWaitsForATap() throws {
        try launch(voice: "speech")
        let before = (fakeGet("capture")["uploads"] as? [Any] ?? []).count
        XCUIDevice.shared.system.open(URL(string: "samrabbit://capture")!)
        allowOpenAlert()
        let record = app.buttons["capture-record"]
        XCTAssertTrue(record.waitForExistence(timeout: 10), "the recorder, waiting")
        XCTAssertFalse(app.staticTexts["capture-timer"].exists, "not recording")
        snap("phone-note-7-from-a-link")
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual((fakeGet("capture")["uploads"] as? [Any] ?? []).count, before, "nothing was sent")
        record.tap()
        XCTAssertTrue(app.staticTexts["capture-timer"].waitForExistence(timeout: 5), "a tap records")
        app.buttons["capture-close"].tap() // Cancel: dropped
        XCTAssertTrue(app.buttons["home-talk"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertEqual((fakeGet("capture")["uploads"] as? [Any] ?? []).count, before, "a cancelled note is never sent")
    }

    /// Recording goes on with the phone locked: the Live Activity on the Lock Screen shows the timer and Stop, its
    /// Stop sends the note, and what the Mac did shows there without anything of what was said.
    func testTheLiveActivityStopsAndSends() throws {
        try launch(voice: "hold")
        homeTile("Voice note").tap()
        XCTAssertTrue(app.staticTexts["capture-timer"].waitForExistence(timeout: 8))
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        snap("phone-note-8-dynamic-island", settle: 1.5)
        let lock = NSSelectorFromString("pressLockButton")
        guard XCUIDevice.shared.responds(to: lock) else { throw XCTSkip("This Xcode can't lock the simulator.") }
        XCUIDevice.shared.perform(lock)
        Thread.sleep(forTimeInterval: 1.5)
        XCUIDevice.shared.press(.home) // wakes the screen (still locked)
        let stop = springboard.buttons["Stop and send"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10), "the Live Activity on the Lock Screen, with Stop")
        snap("phone-note-9-lock-screen", settle: 1)
        let before = (fakeGet("capture")["uploads"] as? [Any] ?? []).count
        stop.tap()
        XCTAssertTrue(waitUntil(timeout: 20) { (self.fakeGet("capture")["uploads"] as? [Any] ?? []).count > before },
                      "sent from the Lock Screen")
        // What the Mac did, on the locked phone: where it went, never his words (a journal line is private).
        let outcome = springboard.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Added to your journal'"))
        XCTAssertTrue(outcome.firstMatch.waitForExistence(timeout: 12), "the outcome on the Lock Screen")
        snap("phone-note-10-lock-screen-sent", settle: 1.2) // past the text's transition, before it goes (4 s)
        // (The fixtures' calendar has its own "dentist" in a Lock Screen widget: look for his words, the note's own.)
        XCTAssertFalse(springboard.staticTexts.matching(NSPredicate(format: "label CONTAINS 'cleaning to Friday'"))
                        .firstMatch.exists, "nothing of what was said: \(outcome.firstMatch.label)")
        XCTAssertFalse(outcome.firstMatch.label.contains("“"), outcome.firstMatch.label)
        springboard.swipeUp()
        app.activate()
    }

    /// Settings > Action Button explains Talk and Voice Note (and what a note does), and "Try a voice note here" records
    /// like the button does; the widget gallery shows the Dashboard's Talk and Voice note, the brief's widgets and the
    /// voice note's Lock Screen faces and Live Activity.
    func testTheActionButtonHelpAndTheWidgetGallery() throws {
        try launch(voice: "hold")
        app.tabBars.buttons["Settings"].tap()
        let help = app.buttons["action-button-help"]
        for _ in 0..<6 where !(help.exists && help.isHittable) { app.swipeUp() }
        help.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Voice Note'")).firstMatch
            .waitForExistence(timeout: 5), "both choices")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Put this in my journal'")).firstMatch.exists,
                      "what a note does")
        snap("phone-help-1-action-button")
        let tryNote = app.buttons["help-try-note"]
        for _ in 0..<6 where !(tryNote.exists && tryNote.isHittable) { app.swipeUp() }
        snap("phone-help-2-try-and-experiment")
        tryNote.tap()
        XCTAssertTrue(app.staticTexts["capture-timer"].waitForExistence(timeout: 8), "it records, like the button")
        app.buttons["capture-close"].tap() // Cancel: nothing is sent
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let gallery = app.buttons["Widget gallery"]
        for _ in 0..<6 where !(gallery.exists && gallery.isHittable) { app.swipeUp() }
        gallery.tap()
        for (title, name) in [("Large · Dashboard", "phone-gallery-1-dashboard"),
                              ("Medium · Morning brief", "phone-gallery-2-brief-medium"),
                              ("Large · Morning brief", "phone-gallery-3-brief-large"),
                              ("Voice note · Lock Screen and Live Activity", "phone-gallery-4-voice-note")] {
            let heading = app.staticTexts[title.uppercased()] // the gallery's eyebrows
            for _ in 0..<12 where !(heading.exists && heading.frame.minY < 420) {
                app.swipeUp(velocity: .slow)
            }
            XCTAssertTrue(heading.exists, title)
            snap(name)
        }
    }

    // MARK: - Helpers

    private func launch(voice: String, extra: [String] = []) throws {
        app.launchArguments = ["-SamRabbitVoiceFixture", voice, "-SamRabbitOpenLinks", "off"] + extra
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

    /// A quick action on Home (below the morning brief before noon: scrolled to).
    private func homeTile(_ title: String) -> XCUIElement {
        XCTAssertTrue(app.buttons["home-talk"].waitForExistence(timeout: 15), "Home")
        let tile = app.buttons[title]
        for _ in 0..<6 where !(tile.exists && tile.isHittable) {
            app.swipeUp()
        }
        return tile
    }

    private func allowOpenAlert() {
        let open = springboard.buttons["Open"]
        if open.waitForExistence(timeout: 2) { open.tap() }
    }

    private func waitFor(_ element: XCUIElement, containing text: String, timeout: TimeInterval) -> Bool {
        waitUntil(timeout: timeout) { element.exists && element.label.localizedCaseInsensitiveContains(text) }
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

    private func snap(_ name: String, settle: TimeInterval = 0.6) {
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
