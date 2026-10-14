import XCTest

/// Presses the simulator's Action Button (`XCUIDevice.press(.action)`) and checks that SamRabbit opens in a live
/// conversation (Talk): the "Ask SamRabbit" control Samin set in Wave 4 keeps its kind but now runs
/// `TalkToSamRabbitIntent` (CONTRACTS-WAVE8 §C1), so his button opens the call with nothing to change. Pressed again
/// while SamRabbit is in front, the intent runs in the app (the orb's tap: send now or interrupt). In the simulator
/// Talk never listens through the Mac's microphone (no fixture: silence).
///
/// Opt-in, because it needs the simulator's Action Button set to the SamRabbit control first
/// (Settings > Action Button > Controls > Choose a Control… > SamRabbit > Talk (SamRabbit), or Talk to SamRabbit):
///
///     TEST_RUNNER_SAMRABBIT_ACTION_BUTTON=1 xcodebuild test -scheme SamRabbit \
///       -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -only-testing:SamRabbitUITests/ActionButtonUITests
///
/// Needs `apple/dev/fake_bridge.py` with the simulator paired to it. Screenshots are attached as `ios-action-button-…`.
/// (The Voice Note control is checked through its intent in `VoiceNoteUITests`: the simulator's button holds one
/// control at a time.)
@MainActor
final class ActionButtonUITests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "com.samrabbit.mobile")

    override func setUp() async throws {
        continueAfterFailure = false
    }

    func testActionButtonOpensTalk() throws {
        guard ProcessInfo.processInfo.environment["SAMRABBIT_ACTION_BUTTON"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_SAMRABBIT_ACTION_BUTTON=1 after setting the simulator's Action Button.")
        }
        guard XCUIDevice.shared.hasHardwareButton(.action) else { throw XCTSkip("This simulator has no Action Button.") }

        // From the Home Screen, with SamRabbit not running: the cold start.
        app.terminate()
        XCUIDevice.shared.press(.home)
        wait(1.5)
        XCUIDevice.shared.press(.action)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15), "the Action Button opens SamRabbit")
        let state = app.staticTexts["talk-state"]
        XCTAssertTrue(state.waitForExistence(timeout: 15), "straight into Talk, the live call")
        snap("ios-action-button-1-talk")

        // Pressed again while SamRabbit is in front: the intent runs in the app, and Talk stays up.
        wait(3)
        XCUIDevice.shared.press(.action)
        wait(1.5)
        XCTAssertTrue(state.exists, "Talk is still up")
        snap("ios-action-button-2-pressed-in-app")
        if app.buttons["talk-end"].exists { app.buttons["talk-end"].tap() }
    }

    // MARK: - Helpers

    private func wait(_ seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }

    private func snap(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
