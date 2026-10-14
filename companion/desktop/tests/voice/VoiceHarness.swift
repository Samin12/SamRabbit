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
///     voice-harness mute      mute ends with the conversation; muted, "Hey Rabbit" waits; a muted one ends by itself
///     voice-harness devices   this Mac's audio inputs and the wake listener's choice (read only)
///     voice-harness listen N  only the wake listener, for N seconds (for its CPU use)
///     voice-harness note      a voice note from the dock's button: it stops on the pause, goes to the bridge, says how
///                             it went; "Hey Rabbit" waits meanwhile and no conversation starts
///     voice-harness note-hold ⌃⌥N held while it is said, released: sent on the release
///     voice-harness note-offline  the bridge refuses it for now (503): kept in the outbox, then sent when it is back
///     voice-harness note-suggest  the bridge keeps it as a note and suggests a task: the bar's button does it
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
            await post("/dev/announce", ["say": "“Fix login redirect” in Website finished."])
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
        case "mute":
            // Mute is the conversation's: it ends with it and "Hey Rabbit" listens again; muted while no conversation
            // runs, "Hey Rabbit" waits and says why, and asking to talk unmutes; a muted conversation still ends by
            // itself (after four times the quiet end: SAMRABBIT_VOICE_IDLE=5, so 20 s).
            voice.activate(shortcut: false)
            ok = check(await waitUntil(within: 20) { voice.wakeArmed }, "listening for the wake phrase")
            voice.start(reason: "button")
            ok = await waitUntil(within: 10) { voice.state == .listening } && ok
            voice.micMuted = true
            ok = check(!voice.wakeArmed && voice.wakeProblem == nil, "muted in a conversation: no listener, nothing to explain") && ok
            voice.end()
            ok = await waitUntil(within: 10) { voice.wakeArmed } && ok
            ok = check(!voice.micMuted && voice.wakeArmed && voice.wakeProblem == nil,
                       "the end unmuted it and the wake listener is back") && ok
            voice.micMuted = true
            ok = check(!voice.wakeArmed && voice.wakeProblem == MacVoice.mutedProblem, "muted while idle: paused, and says why") && ok
            voice.start(reason: "shortcut")
            ok = check(!voice.micMuted && voice.wakeProblem == nil, "asking to talk unmutes") && ok
            ok = await waitUntil(within: 10) { voice.state == .listening } && ok
            voice.micMuted = true
            let mutedAt = Date()
            _ = await waitUntil(within: 40) { voice.state == .idle }
            let after = Date().timeIntervalSince(mutedAt)
            ok = check(voice.state == .idle && after >= 12,
                       String(format: "a muted conversation ended by itself (after %.0f s, not 5)", after)) && ok
            ok = check(!voice.micMuted, "…and unmuted") && ok
            ok = check(await waitUntil(within: 10) { voice.wakeArmed }, "the wake listener is back") && ok
        case "devices":
            // This Mac's audio inputs and the wake listener's choice (CoreAudio, read only: no microphone opened).
            let devices = AudioInputs.devices()
            let defaultInput = AudioInputs.defaultInput()
            for device in devices where device.hasInput {
                print("HARNESS_INPUT \(device.transport)" + (device.id == defaultInput ? " (the default)" : ""))
            }
            let choice = WakeMicrophoneChoice.choose(devices, defaultInput: defaultInput)
            switch choice {
            case .systemDefault: print("HARNESS_CHOICE the default input")
            case .device: print("HARNESS_CHOICE the built-in microphone rather than the default input")
            case .waiting: print("HARNESS_CHOICE wait")
            }
            ok = check(!devices.isEmpty, "the audio devices were read")
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
        case "note", "note-hold", "note-offline", "note-suggest":
            ok = await note(scenario, voice: voice)
        default:
            Log.write("harness: unknown scenario \(scenario)")
        }
        print("HARNESS_STATES " + states.joined(separator: ","))
        print(ok ? "HARNESS_OK \(scenario)" : "HARNESS_FAILED \(scenario)")
        exit(ok ? 0 : 1)
    }

    /// The voice note scenarios (VoiceNotes with the fixture microphone and the fake's /v1/desktop/capture; the outbox
    /// in the temp folder headless.sh names in SAMRABBIT_CAPTURE_OUTBOX).
    @MainActor
    static func note(_ scenario: String, voice: MacVoice) async -> Bool {
        guard ProcessInfo.processInfo.environment["SAMRABBIT_CAPTURE_OUTBOX"] != nil else {
            return check(false, "SAMRABBIT_CAPTURE_OUTBOX names a temp outbox")
        }
        let notes = VoiceNotes()
        var phases: [String] = []
        notes.$snapshot.map { "\($0.phase)" }.removeDuplicates().sink { phase in
            phases.append(phase)
            Log.write("harness: note \(phase)")
        }.store(in: &bag)
        voice.activate(shortcut: false)
        var ok = check(await waitUntil(within: 20) { voice.wakeArmed }, "listening for the wake phrase before")
        if scenario == "note-offline" { await post("/dev/capture", ["mode": "busy"]) }
        if scenario == "note-suggest" {
            await postJSON("/dev/capture", ["script": [["heard": "Call the bank about the replacement card.", "kind": "note",
                                                        "title": "Voice note",
                                                        "suggestion": ["label": "Start it as a T3 task?", "action": "task"]]]])
        }
        if scenario == "note-hold" {
            notes.press()
            ok = check(await waitUntil(within: 2) { notes.isRecording }, "⌃⌥N down: recording at once") && ok
            // Held while the file is said (0.6 s of room, then about 3 s of words), then let go.
            try? await Task.sleep(for: .seconds(6))
            ok = check(notes.isRecording, "still recording while held (a pause doesn't send a held note)") && ok
            notes.release()
            ok = check(!notes.isRecording, "the release sends it") && ok
        } else {
            notes.toggle(source: "button")
            ok = check(await waitUntil(within: 2) { notes.isRecording }, "recording at once") && ok
            ok = check(!voice.wakeArmed, "“Hey Rabbit” waits while a note records") && ok
            voice.start(reason: "button")
            ok = check(voice.state == .idle, "no conversation starts while a note records") && ok
            // It stops by itself: the file, then 3 s of quiet.
            ok = check(await waitUntil(within: 15) { !notes.isRecording }, "a tapped note ends on the pause") && ok
        }
        if scenario == "note-offline" {
            ok = check(await waitUntil(within: 10) { notes.snapshot.phase == .queued }, "the bridge refused it for now: kept") && ok
            ok = check(notes.outbox.items().count == 1 && notes.snapshot.waiting == 1, "one note in the outbox") && ok
            ok = check(notes.snapshot.line == "Saved on this Mac", "the bar says so (\(notes.snapshot.detail))") && ok
            await post("/dev/capture", ["mode": "ok"])
            notes.retryNow()
            ok = check(await waitUntil(within: 15) { notes.outbox.items().isEmpty }, "sent once the bridge took it again") && ok
            ok = check(notes.snapshot.waiting == 0, "nothing waits") && ok
        } else if scenario == "note-suggest" {
            ok = check(await waitUntil(within: 25) { notes.snapshot.offer == "Start as task" },
                       "kept as a note, the bar offers the suggestion (\(notes.snapshot.line) / \(notes.snapshot.detail))") && ok
            notes.takeSuggestion()
            ok = check(await waitUntil(within: 10) { notes.snapshot.line == "Started a T3 task" },
                       "the button did it (\(notes.snapshot.line) / \(notes.snapshot.detail))") && ok
            ok = check(notes.snapshot.offer.isEmpty, "and offers nothing more") && ok
            let acts = (await get("/dev/capture"))?["acts"] as? [[String: Any]] ?? []
            ok = check(acts.count == 1 && acts.first?["action"] as? String == "task", "one act, a task, went to the bridge") && ok
        } else {
            ok = check(await waitUntil(within: 25) { notes.snapshot.line == "Added to your journal" },
                       "the bar says what the bridge did (\(notes.snapshot.line) / \(notes.snapshot.detail))") && ok
            ok = check(notes.outbox.items().isEmpty, "the outbox let it go once the bridge had it") && ok
            ok = check(phases.contains("sending") && phases.contains("sent"), "recording, sending, sent: \(phases)") && ok
        }
        ok = check(await waitUntil(within: 10) { voice.wakeArmed }, "the wake listener is back after the note") && ok
        // What the fake received: one note, from the Mac, a WAV of about the right length.
        guard let arrived = await get("/dev/capture"), let captures = arrived["captures"] as? [[String: Any]] else {
            return check(false, "the fake says what arrived")
        }
        ok = check(captures.count == 1, "one capture arrived (\(captures.count))") && ok
        if let first = captures.first {
            let seconds = first["seconds"] as? Double ?? 0
            ok = check(first["source"] as? String == "mac" && first["contentType"] as? String == "audio/wav", "a WAV from the Mac") && ok
            ok = check(seconds >= 3 && seconds <= 9, String(format: "about the length said (%.1f s)", seconds)) && ok
            ok = check((first["capturedAt"] as? String)?.count == 25, "captured-at with its offset") && ok
        }
        print("HARNESS_NOTE_PHASES " + phases.joined(separator: ","))
        return ok
    }

    /// A dev control with any JSON body.
    static func postJSON(_ path: String, _ body: [String: Any]) async {
        var request = URLRequest(url: Config.origin.appendingPathComponent(String(path.dropFirst())))
        request.httpMethod = "POST"
        request.setValue(Config.token(), forHTTPHeaderField: "X-SamRabbit-Desktop")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: request)
    }

    /// A dev read on the fake server (desktop token).
    static func get(_ path: String) async -> [String: Any]? {
        var request = URLRequest(url: Config.origin.appendingPathComponent(String(path.dropFirst())))
        request.setValue(Config.token(), forHTTPHeaderField: "X-SamRabbit-Desktop")
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
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
