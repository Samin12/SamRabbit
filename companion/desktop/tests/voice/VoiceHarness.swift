import Combine
import Foundation

/// The Mac voice end to end without a microphone or a speaker (tests/voice/headless.sh): `MacVoice` in fixture mode
/// (WAV files instead of the microphone, playback rendered silently into memory) against the fake sync server's
/// canned `/v1/desktop/assistant/*`. Prints what the dock would show; exits 0 when the scenario went as expected.
///
///     voice-harness turns     ⌃⌥Space, two turns, the assistant ends the conversation
///     voice-harness wake      "Hey Rabbit, what's on my calendar this afternoon?" in one breath, then a second turn
///     voice-harness bargein   a turn, barge-in while it speaks, an announcement, then end()
///     voice-harness talkover  a turn, then the next question said over the reply (SAMRABBIT_VOICE_BARGE_IN=1)
///     voice-harness listen N  only the wake listener, for N seconds (for its CPU use)
///
/// The wake phrase setting comes from the arguments (`-VoiceWakeEnabled YES|NO`, the argument domain), so nothing is
/// written to any defaults.
@main
struct VoiceHarness {
    static var states: [String] = []
    static var heard: [String] = []
    static var captions: [String] = []
    static var bag: Set<AnyCancellable> = []

    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let scenario = arguments.first ?? "turns"
        let voice = MacVoice.shared
        voice.$state.removeDuplicates().sink { state in
            let name = Self.name(state)
            states.append(name)
            Log.write("harness: state \(name)")
        }.store(in: &bag)
        voice.$heard.removeDuplicates().filter { !$0.isEmpty }.sink { text in
            heard.append(text)
            Log.write("harness: heard “\(text)”")
        }.store(in: &bag)
        voice.$wakeArmed.removeDuplicates().sink { Log.write("harness: wakeArmed \($0)") }.store(in: &bag)
        var ok = false
        switch scenario {
        case "turns":
            voice.activate(shortcut: false)
            voice.toggle(reason: "shortcut")
            ok = await waitForEnd(voice, within: 60)
            ok = ok && check(states.contains("thinking") && states.contains("speaking"), "it thought and spoke")
            ok = ok && check(heard == ["What's on my calendar this afternoon?", "Thanks, that's all."], "two turns heard")
            ok = ok && check(voice.caption == "Okay. Talk soon.", "the last caption")
        case "wake":
            voice.activate(shortcut: false)
            ok = await waitForEnd(voice, within: 90)
            ok = ok && check(states.contains("listening") && states.contains("speaking"), "a conversation ran")
            ok = ok && check(heard.count == 2, "two turns heard")
            // The listener comes back after the conversation.
            ok = await waitUntil(within: 15) { voice.wakeArmed } && ok
            ok = ok && check(voice.wakeArmed, "listening for the wake phrase again")
        case "bargein":
            voice.activate(shortcut: false)
            voice.start(reason: "button")
            ok = await waitUntil(within: 30) { voice.state == .speaking }
            ok = ok && check(voice.state == .speaking, "speaking")
            try? await Task.sleep(for: .milliseconds(500))
            voice.stopSpeaking()
            ok = await waitUntil(within: 5) { voice.state == .listening } && ok
            ok = ok && check(voice.state == .listening, "listening again after the barge-in")
            await post("/dev/announce", ["say": "“Fix login redirect” in Hermes finished."])
            // The first poll comes 4 s into the conversation; the announcement is said as a turn.
            ok = await waitUntil(within: 30) { voice.caption.contains("Fix login redirect") } && ok
            ok = ok && check(voice.caption.contains("Fix login redirect"), "the announcement was said")
            ok = await waitUntil(within: 20) { voice.state == .listening } && ok
            voice.end()
            ok = check(voice.state == .idle, "end() ends it at once") && ok
            try? await Task.sleep(for: .seconds(1)) // its POST /end goes out meanwhile
        case "talkover":
            voice.activate(shortcut: false)
            voice.start(reason: "button")
            ok = await waitUntil(within: 30) { voice.state == .speaking }
            ok = ok && check(voice.state == .speaking, "speaking")
            // Samin talks over the reply: the fixture says its next file now.
            FixtureMicrophone.shared?.opened()
            ok = await waitUntil(within: 5) { voice.state == .listening } && ok
            ok = ok && check(voice.state == .listening, "talking over the reply stopped it")
            ok = await waitForEnd(voice, within: 30) && ok
            ok = ok && check(heard == ["What's on my calendar this afternoon?", "Thanks, that's all."], "the second turn heard")
        case "listen":
            let seconds = Double(arguments.dropFirst().first ?? "60") ?? 60
            voice.activate(shortcut: false)
            _ = await waitUntil(within: 20) { voice.wakeArmed }
            Log.write("harness: armed; listening for \(Int(seconds)) s")
            var before = rusage()
            getrusage(RUSAGE_SELF, &before)
            let started = Date()
            try? await Task.sleep(for: .seconds(seconds))
            var after = rusage()
            getrusage(RUSAGE_SELF, &after)
            let cpu = cpuSeconds(after.ru_utime) + cpuSeconds(after.ru_stime) - cpuSeconds(before.ru_utime) - cpuSeconds(before.ru_stime)
            let wall = Date().timeIntervalSince(started)
            print(String(format: "HARNESS_CPU %.2f%% (%.2f s of CPU in %.1f s)", cpu / wall * 100, cpu, wall))
            ok = check(voice.wakeArmed && voice.state == .idle, "still listening, nothing started")
        default:
            Log.write("harness: unknown scenario \(scenario)")
        }
        print("HARNESS_STATES " + states.joined(separator: ","))
        print(ok ? "HARNESS_OK \(scenario)" : "HARNESS_FAILED \(scenario)")
        exit(ok ? 0 : 1)
    }

    static func name(_ state: MacVoice.State) -> String {
        switch state {
        case .idle: "idle"
        case .starting: "starting"
        case .listening: "listening"
        case .thinking: "thinking"
        case .speaking: "speaking"
        case .error(let message): "error(\(message))"
        }
    }

    static func cpuSeconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000 }

    @MainActor
    static func waitUntil(within seconds: TimeInterval, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    /// Waits for a conversation to start and end again.
    @MainActor
    static func waitForEnd(_ voice: MacVoice, within seconds: TimeInterval) async -> Bool {
        let began = await waitUntil(within: seconds) { voice.state != .idle }
        let ended = await waitUntil(within: seconds) { voice.state == .idle }
        return check(began && ended, "a conversation started and ended")
    }

    static func check(_ condition: Bool, _ what: String) -> Bool {
        Log.write("harness: " + (condition ? "ok: " : "FAILED: ") + what)
        return condition
    }

    /// A dev control on the fake server (desktop token).
    static func post(_ path: String, _ body: [String: String]) async {
        var request = URLRequest(url: Config.origin.appendingPathComponent(String(path.dropFirst())))
        request.httpMethod = "POST"
        request.setValue(Config.token(), forHTTPHeaderField: "X-SamRabbit-Desktop")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: request)
    }
}
