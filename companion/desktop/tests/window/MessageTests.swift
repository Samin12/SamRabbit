import Foundation

func parsesTheVoiceRequests() {
    for action in WindowCommand.VoiceAction.allCases {
        expectEqual(WindowCommand.parse(["type": "voice", "action": action.rawValue]), .voice(action), action.rawValue)
    }
    expectEqual(WindowCommand.parse(["type": "voice", "action": "wake", "on": false]), .wake(false))
    expectEqual(WindowCommand.parse(["type": "voice", "action": "wake", "on": true]), .wake(true))
    expect(WindowCommand.parse(["type": "voice", "action": "wake"]) == nil, "wake without on")
    expect(WindowCommand.parse(["type": "voice", "action": "shout"]) == nil, "an unknown action")
    expect(WindowCommand.parse(["type": "voice"]) == nil, "no action")
    expect(WindowCommand.parse(["type": "voice", "action": 1]) == nil, "an action that isn't text")
}

func parsesSettingsAndReady() {
    expectEqual(WindowCommand.parse(["type": "dock", "enabled": false]), .dock(false))
    expectEqual(WindowCommand.parse(["type": "dock", "enabled": true]), .dock(true))
    expect(WindowCommand.parse(["type": "dock", "enabled": "yes"]) == nil, "enabled must be a Bool")
    expectEqual(WindowCommand.parse(["type": "ready"]), .ready)
    expectEqual(WindowCommand.parse(["type": "connectChatGPT"]), .connectChatGPT)
    expectEqual(WindowCommand.parse(["type": "dockSettings"]), .dockSettings)
}

func leavesTheWindowsOwnMessagesAlone() {
    for type in ["open", "copy", "noDrag", "status", "diag", "pairPhone", "nonsense"] {
        expect(WindowCommand.parse(["type": type]) == nil, type)
    }
    expect(WindowCommand.parse([:]) == nil, "no type")
}

func voiceStateAsThePageReadsIt() {
    var state = WindowVoiceState()
    state.state = "error"
    state.error = "The bridge isn't answering"
    state.heard = "What's on my calendar?"
    state.level = 1.7
    state.shortcut = "⌃⌥Space"
    let json = state.json
    expectEqual(json["state"] as? String, "error")
    expectEqual(json["error"] as? String, "The bridge isn't answering")
    expectEqual(json["level"] as? Double, 1.0, "the level is clamped to 0...1")
    expect(json["brain"] is NSNull, "nil goes as null, not missing")
    expect(json["conversationId"] is NSNull)
    expectEqual(json["wakeEnabled"] as? Bool, true)
    expect(JSONSerialization.isValidJSONObject(json), "valid JSON")
    state.level = 0.123_456
    expectEqual(state.json["level"] as? Double, 0.12, "rounded to a hundredth")
    var other = state
    other.level = 0.9
    expect(state.sameApartFromLevel(other))
    other.caption = "Next up"
    expect(!state.sameApartFromLevel(other))
}

func throttlesOnlyTheLevel() {
    var throttle = WindowPushThrottle()
    let start = Date(timeIntervalSince1970: 1_000)
    var state = WindowVoiceState()
    state.state = "listening"
    expectEqual(throttle.decide(state, now: start), .now, "the first state goes at once")
    throttle.pushed(state, at: start)
    var louder = state
    louder.level = 0.5
    if case .after(let wait) = throttle.decide(louder, now: start.addingTimeInterval(0.02)) {
        expect(wait > 0 && wait <= throttle.levelInterval, "a level change waits for its tick")
    } else {
        expect(false, "a level change right after a push waits")
    }
    expectEqual(throttle.decide(louder, now: start.addingTimeInterval(0.2)), .now, "after the interval it goes")
    var tiny = state
    tiny.level = 0.01
    expectEqual(throttle.decide(tiny, now: start.addingTimeInterval(1)), .skip, "a flicker of the level isn't worth a push")
    var heard = louder
    heard.state = "thinking"
    heard.heard = "What's on my calendar?"
    expectEqual(throttle.decide(heard, now: start.addingTimeInterval(0.01)), .now, "anything else goes at once")
    throttle.reset()
    expectEqual(throttle.decide(state, now: start.addingTimeInterval(0.01)), .now, "after a reload everything goes again")
}

func scriptIsSafeJavaScript() {
    let script = WindowScript.native(["voice": ["caption": "Line\u{2028}two </script> \"quoted\""]]) ?? ""
    expect(script.hasPrefix("window.SamRabbitApp && window.SamRabbitApp.native({"), script)
    expect(!script.contains("\u{2028}"), "U+2028 is escaped")
    expect(script.contains("\\u2028"))
    expect(script.contains("\\\"quoted\\\""), "quotes stay inside the JSON string")
    expect(WindowScript.native(["bad": Date()]) == nil, "something that isn't JSON is not sent")
}

func shortcutsSayWhenTalkIsTaken() {
    let shortcuts = WindowScript.shortcuts(talk: "", talkProblem: "⌃⌥Space is used by another app")
    expectEqual(shortcuts.count, 2)
    expectEqual(shortcuts[0]["id"] as? String, "talk")
    expectEqual(shortcuts[0]["problem"] as? String, "⌃⌥Space is used by another app")
    expectEqual(shortcuts[1]["keys"] as? String, "⌃⌥K")
    expect(shortcuts[1]["problem"] is NSNull)
    expect(JSONSerialization.isValidJSONObject(shortcuts))
}
