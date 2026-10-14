import AppKit
import WebKit

/// Dev only: `--render-window-snapshots <dir> --base-url http://127.0.0.1:<fake>/app/ --token-file <token>` with
/// `SAMRABBIT_VOICE_FIXTURE=<wav>` loads the main window against the fake sync server, off screen (no Dock icon, no
/// menu bar extra, nothing on any display), draws Home, Tasks, Chats, Calendar and Settings to PNGs, then presses the
/// page's Talk button with the mouse (a real down and up, as a finger does: not a script's click): the request goes
/// through the WKScriptMessageHandler bridge to MacVoice (fixture microphone, the reply rendered silently into memory),
/// whose state comes back into the page's live transcript, which is drawn too; then the voice panel's End button is
/// pressed while the reply streams; then Home's Voice note button is pressed (the fixture microphone says the next file,
/// which goes to the fake's capture route, and the page's button follows the note). `window-smoke.json` lists what the
/// bridge received and pushed. It refuses the real
/// bridge (port 3780 or a server that doesn't answer `/dev/inbox/fake`) and a real microphone.
@MainActor
enum MainWindowSnapshots {
    nonisolated static var requested: Bool { Config.argument("--render-window-snapshots") != nil }

    static func run(to directory: String) {
        guard !Config.isDefaultBase, Config.baseURL.port != 3780 else {
            return quit(2, "window snapshots: refusing the real bridge (pass --base-url of the fake sync server)")
        }
        guard Bundle.main.bundleIdentifier != "com.samrabbit.desktop" else {
            return quit(2, "window snapshots: build a copy with --bundle-id (the installed app's settings stay untouched)")
        }
        guard FixtureMicrophone.shared != nil else {
            return quit(2, "window snapshots: refusing without SAMRABBIT_VOICE_FIXTURE (the microphone is never opened)")
        }
        NSApp.setActivationPolicy(.accessory)
        let runner = Runner(directory: URL(fileURLWithPath: (directory as NSString).expandingTildeInPath))
        Task { @MainActor in quit(await runner.run(), nil) }
    }

    private static func quit(_ code: Int32, _ message: String?) {
        if let message { FileHandle.standardError.write(Data((message + "\n").utf8)) }
        exit(code)
    }

    @MainActor
    private final class Runner {
        static let scale = 2.0
        let directory: URL
        let controller = MainWindowController(live: false)
        var shots: [String] = []
        var problems: [String] = []

        init(directory: URL) {
            self.directory = directory
        }

        func run() async -> Int32 {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard await fakeServer() else {
                say("window snapshots: \(Config.origin.absoluteString) isn't the fake sync server (no /dev/inbox/fake)")
                return 2
            }
            guard let window = controller.window else { return 1 }
            // Off every display: it renders, but nothing shows on Samin's screens. WebKit would treat a window nobody
            // can see as occluded and pause the page's animations and drawing: not here.
            controller.webView.setValue(false, forKey: "windowOcclusionDetectionEnabled")
            (window as? MainAppWindow)?.keepsOffscreen = true
            window.setFrameAutosaveName("")  // the off-screen frame is not remembered
            window.setFrame(NSRect(x: -30_000, y: -30_000, width: 1280, height: 800), display: false)
            window.orderFrontRegardless()
            guard !NSScreen.screens.contains(where: { $0.frame.intersects(window.frame) }) else {
                window.orderOut(nil)
                say("window snapshots: the window would have shown on a display; stopped")
                return 1
            }
            controller.start()
            guard await waitFor(25, { self.controller.bridge.received.contains("ready") }) else {
                say("window snapshots: the page never said it was ready")
                return 1
            }
            await pause(2.0)
            for view in ["home", "tasks", "chats", "calendar", "settings"] {
                await evaluate("SamRabbitApp.show('\(view)')")
                await pause(view == "chats" ? 2.0 : 1.4)
                await shoot("window-\(view)")
            }

            // Talk: the page's button → the bridge → MacVoice (fixture) → the bridge → the page's transcript.
            let voice = MacVoice.shared
            await evaluate("SamRabbitApp.show('home')")
            await pause(0.6)
            await press(".talk-btn .talk-label")
            let spoke = await waitFor(30) { voice.state == .speaking && !voice.caption.isEmpty }
            if !spoke { problems.append("MacVoice never spoke (state \(voice.state))") }
            await pause(1.2)
            await shoot("window-talk")
            let transcript = await evaluate("document.querySelector('.voice-transcript') ? document.querySelector('.voice-transcript').innerText : ''") as? String ?? ""
            let talkLabel = await evaluate("document.querySelector('.talk-btn').innerText") as? String ?? ""
            // While it speaks: the level and the caption are pushed under the pointer the whole time.
            await press(".voice-panel .voice-btn.danger")
            let ended = await waitFor(15) { voice.state == .idle }
            if !ended { problems.append("the conversation didn't end from the page (state \(voice.state))") }
            await pause(1.0)
            await shoot("window-talk-ended")
            // A voice note from Home's button (CONTRACTS-WAVE8 §D1): the bridge → VoiceNotes (the fixture microphone
            // says the next file) → the fake's /v1/desktop/capture → what it did, back on the page's button.
            let notes = VoiceNotes.shared
            await evaluate("SamRabbitApp.show('home')")
            // The ended conversation's panel lingers while the pointer is on it, and the press above left WebKit's
            // pointer there (no exit ever comes): close it with its ×, as Samin would, and draw the note without it.
            await press(".voice-panel .voice-btn[aria-label=\"Close\"]")
            await pause(0.6)
            if await evaluate("Boolean(document.querySelector('.voice-panel:not(.closing)'))") as? Bool == true {
                problems.append("the ended conversation's panel didn't close")
            }
            await press(".quick.note-quick")
            if !(await waitFor(5) { notes.isRecording }) { problems.append("the note didn't start from the page") }
            await pause(2.5)
            await shoot("window-note-recording")
            let noteLabel = await evaluate("document.querySelector('.quick.note-quick').innerText") as? String ?? ""
            if !noteLabel.hasPrefix("Send note") { problems.append("the page's note button said “\(noteLabel)” while recording") }
            if !(await waitFor(30) { notes.snapshot.phase == .sent && notes.snapshot.line == "Added to your journal" }) {
                problems.append("the note never came back as sent (\(notes.snapshot.phase): \(notes.snapshot.line))")
            }
            await pause(0.8)
            await shoot("window-note-sent")
            let received = controller.bridge.received
            for expected in ["ready", "voice.start", "voice.end", "note.toggle"] where !received.contains(expected) {
                problems.append("the bridge never received \(expected)")
            }
            if !transcript.contains("calendar") { problems.append("the page's transcript doesn't show what was heard") }
            let report: [String: Any] = [
                "received": received, "voicePushes": controller.bridge.voicePushes, "shots": shots,
                "transcript": transcript, "talkButtonWhileSpeaking": talkLabel, "noteButtonWhileRecording": noteLabel,
                "note": notes.snapshot.json, "problems": problems,
            ]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: directory.appendingPathComponent("window-smoke.json"))
            }
            say("window snapshots: \(shots.count) drawn, \(received.count) messages from the page, "
                + "\(controller.bridge.voicePushes) voice pushes" + (problems.isEmpty ? "" : "; problems: \(problems.joined(separator: "; "))"))
            return problems.isEmpty ? 0 : 1
        }

        // MARK: steps

        /// A mouse down in the middle of the element, 110 ms, and a mouse up at the same spot.
        func press(_ selector: String) async {
            let script = "(() => { const el = document.querySelector('\(selector)'); if (!el) return null; "
                + "const r = el.getBoundingClientRect(); return [r.left, r.top, r.width, r.height]; })()"
            guard let window = controller.window, let box = await evaluate(script) as? [Double], box.count == 4 else {
                problems.append("nothing to press at \(selector)")
                return
            }
            let web = controller.webView
            let (x, y) = (box[0] + box[2] / 2, box[1] + box[3] / 2)  // the page's CSS pixels, from the top left
            let inWindow = web.convert(NSPoint(x: x, y: web.isFlipped ? y : web.bounds.height - y), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: inWindow, modifierFlags: [],
                                                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                  context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) {
                    // Straight to the web view: this app isn't active (it must not take the focus from Samin), and an
                    // inactive window takes a first click as "come forward", not as a click.
                    if type == .leftMouseDown { web.mouseDown(with: event) } else { web.mouseUp(with: event) }
                }
                if type == .leftMouseDown { await pause(0.11) }
            }
            await pause(0.2)
        }

        @discardableResult
        func evaluate(_ script: String) async -> Any? {
            await withCheckedContinuation { continuation in
                controller.webView.evaluateJavaScript(script) { value, _ in continuation.resume(returning: value) }
            }
        }

        func pause(_ seconds: Double) async {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }

        func waitFor(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if condition() { return true }
                await pause(0.1)
            }
            return condition()
        }

        /// The page as WebKit draws it, with the window's own traffic lights on top (they are native views).
        func shoot(_ name: String) async {
            let configuration = WKSnapshotConfiguration()
            configuration.afterScreenUpdates = true
            // Off every display the window is 1x: ask WebKit for a Retina-sized picture.
            configuration.snapshotWidth = NSNumber(value: Double(controller.webView.bounds.width) * Self.scale)
            let image: NSImage? = await withCheckedContinuation { continuation in
                controller.webView.takeSnapshot(with: configuration) { image, _ in continuation.resume(returning: image) }
            }
            guard let image, let window = controller.window else {
                problems.append("no snapshot for \(name)")
                return
            }
            let scale = Self.scale
            let size = controller.webView.bounds.size
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
            rep.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            image.draw(in: NSRect(origin: .zero, size: size))
            // The traffic lights are native buttons (not in the page's picture), drawn where the window has them.
            let colors = [NSColor(srgbRed: 1, green: 0.373, blue: 0.341, alpha: 1), NSColor(srgbRed: 0.996, green: 0.737, blue: 0.18, alpha: 1),
                          NSColor(srgbRed: 0.157, green: 0.784, blue: 0.251, alpha: 1)]
            for (index, kind) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
                guard let button = window.standardWindowButton(kind), let content = window.contentView else { continue }
                let frame = button.convert(button.bounds, to: content)
                let side = min(frame.width, frame.height, 14)
                let dot = NSRect(x: frame.midX - side / 2, y: frame.midY - side / 2 + (size.height - content.bounds.height),
                                 width: side, height: side).insetBy(dx: 0.5, dy: 0.5)
                colors[index].setFill()
                NSBezierPath(ovalIn: dot).fill()
                NSColor.black.withAlphaComponent(0.18).setStroke()
                NSBezierPath(ovalIn: dot).stroke()
            }
            NSGraphicsContext.restoreGraphicsState()
            guard let png = rep.representation(using: .png, properties: [:]) else { return }
            let url = directory.appendingPathComponent(name + ".png")
            do {
                try png.write(to: url)
                shots.append(url.lastPathComponent)
            } catch {
                problems.append("couldn't write \(name).png")
            }
        }

        func fakeServer() async -> Bool {
            guard let request = Config.request(Config.api("/dev/inbox/fake"), timeout: 5) else { return false }
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return body["fake"] as? Bool == true
        }

        func say(_ line: String) {
            FileHandle.standardError.write(Data((line + "\n").utf8))
            Log.write(line)
        }
    }
}
