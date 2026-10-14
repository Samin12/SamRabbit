import AppKit
import WebKit

// The window's page under a real mouse (run by ../clicks.sh against the fake sync server). A click is a press and a
// release on the same element: a page that replaces the element in between (a redraw on every voice push, every
// streamed word, every inbox change) loses it, which a script's `.click()` never shows. So: a WKWebView in a window off
// every display loads the app, the voice and the inbox change underneath it at their live rates (MacVoice's level about
// 12 times a second, the reply at word rate, working threads every 0.15 s), and NSEvent mouse downs and ups 110 ms
// apart go to the buttons; the page's requests to the shell arrive through the same `samrabbit` message handler the app
// uses. Then the keys (⌃N / ⌃K stay a text field's; nothing moves behind a sheet), and the window is ordered out: a
// hidden window must stop reading the bridge, and read it once when it is back.

@MainActor
final class OffscreenWindow: NSWindow {
    // AppKit moves a window that is off every display back onto one when it is ordered in: this one stays away.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor
final class Runner: NSObject, WKScriptMessageHandler {
    let base: URL
    let token: String
    let window = OffscreenWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 1280, height: 800),
                                 styleMask: [.borderless], backing: .buffered, defer: false)
    let web: WKWebView
    var messages: [[String: Any]] = []
    var failures: [String] = []
    var eventNumber = 0

    init(base: URL, token: String) {
        self.base = base
        self.token = token
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800), configuration: configuration)
        super.init()
        configuration.userContentController.add(self, name: "samrabbit")
        web.setValue(false, forKey: "windowOcclusionDetectionEnabled")
        window.contentView = web
        window.isReleasedWhenClosed = false
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if let body = message.body as? [String: Any] { messages.append(body) }
    }

    // MARK: the run

    func run() async -> Int32 {
        window.orderFrontRegardless()
        guard !NSScreen.screens.contains(where: { $0.frame.intersects(window.frame) }) else {
            window.orderOut(nil)
            print("the window would have shown on a display; stopped")
            return 2
        }
        let cookie = HTTPCookie(properties: [.name: "sr_desktop", .value: token, .path: "/", .domain: base.host ?? "127.0.0.1",
                                             .originURL: base])!
        await web.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
        web.load(URLRequest(url: base.appendingPathComponent("app/")))
        guard await waitFor(20, { self.messages.contains { $0["type"] as? String == "ready" } }) else {
            print("the page never said it was ready")
            return 1
        }
        await pause(1.5)
        await evaluate(Self.simulator)

        await talkButton()
        await voicePanel()
        await evaluate("__sim.idle(); document.dispatchEvent(new KeyboardEvent('keydown', {key: 'Escape', bubbles: true}))")
        await pause(0.5)
        await tasks()
        await keys()
        await hiddenWindow()

        if failures.isEmpty {
            print("window clicks: all passed")
            return 0
        }
        print("window clicks: \(failures.count) failed")
        return 1
    }

    // MARK: scenarios

    func talkButton() async {
        await evaluate("SamRabbitApp.show('home'); __sim.voice('listening', {levels: false})")
        await pause(0.4)
        var ends = await count(presses: 3, on: ".talk-btn .talk-label", action: "end")
        check(ends == 3, "control: the Talk button with nothing changing takes 3 of 3 presses (\(ends))")

        await evaluate("__sim.voice('listening')")
        await pause(0.4)
        ends = await count(presses: 6, on: ".talk-btn .talk-label", action: "end")
        check(ends == 6, "the Talk button takes 6 of 6 presses while the level moves 12 times a second (\(ends))")
        ends = await count(presses: 4, on: ".talk-btn .talk-end", action: "end")
        check(ends == 4, "its End takes 4 of 4 presses meanwhile (\(ends))")
    }

    func voicePanel() async {
        await evaluate("__sim.voice('speaking', {stream: true})")
        await pause(1.0)
        let ends = await count(presses: 6, on: ".voice-panel .voice-btn.danger", action: "end")
        check(ends == 6, "the voice panel's End takes 6 of 6 presses while the reply streams (\(ends))")
        let stops = await count(presses: 4, on: ".voice-panel .voice-btn[aria-label='Stop speaking']", action: "stopSpeaking")
        check(stops == 4, "Stop speaking takes 4 of 4 presses meanwhile (\(stops))")
        let mutes = await count(presses: 3, on: ".voice-panel .voice-btn[aria-label='Mute the microphone']", action: "mute")
        check(mutes == 3, "Mute takes 3 of 3 presses meanwhile (\(mutes))")
    }

    func tasks() async {
        await evaluate("SamRabbitApp.show('tasks')")
        await pause(1.5)
        let ids = await evaluate("""
            [...document.querySelectorAll('.tasks-scroll .item-row')].filter((row) => {
              const box = row.getBoundingClientRect();
              return box.top > 70 && box.bottom < innerHeight - 20 && !row.classList.contains('selected');
            }).map((row) => row.dataset.id).slice(0, 6)
            """) as? [String] ?? []
        var taken = 0
        for id in ids {
            await press(".tasks-scroll .item-row[data-id='\(id)'] .item-title")
            await pause(0.3)
            let selected = await evaluate("(document.querySelector('.tasks-scroll .item-row.selected') || {dataset: {}}).dataset.id") as? String
            if selected == id { taken += 1 }
        }
        check(ids.count >= 4 && taken == ids.count, "Tasks rows take \(taken) of \(ids.count) presses while working threads move")

        let working = "t3:th_dark_mode"
        await evaluate("document.querySelector(\"[data-id='\(working)']\").click()")
        await pause(1.2)
        await press(".detail-actions button[title='Stop']")
        await pause(1.5)  // the request goes, the inbox comes back
        let status = await item(working)?["status"] as? String
        check(status == "idle", "the detail pane's Stop takes the press while the thread moves (status \(status ?? "?"))")

        // Dismiss: the ✕ that shows on a row under the pointer, inside the row's own button, takes the press (it
        // dismisses, it doesn't select); the toast's Undo brings it back; the detail pane's Dismiss too. The rows move
        // meanwhile (working threads every 0.15 s): the press must survive the redraws.
        let failed = "t3:th_watch_previews"
        await hover(".tasks-scroll .item-row[data-id='\(failed)']")
        await press(".tasks-scroll .item-row[data-id='\(failed)'] .row-dismiss")
        await pause(1.0)
        let gone = await evaluate("!document.querySelector(\".tasks-scroll .item-row[data-id='\(failed)']\")") as? Bool
        let hidden = await dismissedIds()
        check(gone == true && hidden == [failed], "a row's ✕ takes the press and dismisses it (gone: \(gone ?? false), bridge: \(hidden))")
        await hover(nil)
        await press(".toast-action")
        await pause(1.2)
        let back = await evaluate("Boolean(document.querySelector(\".tasks-scroll .item-row[data-id='\(failed)']\"))") as? Bool
        let after = await dismissedIds()
        check(back == true && after.isEmpty, "the toast's Undo takes the press and brings it back (\(back ?? false), bridge: \(after))")
        await evaluate("document.querySelector(\"[data-id='\(failed)']\").click()")
        await pause(1.0)
        await press(".detail-actions button[title^='Dismiss']")
        await pause(1.0)
        let viaPane = await dismissedIds()
        check(viaPane == [failed], "the detail pane's Dismiss takes the press (bridge: \(viaPane))")
        await press(".toast-action")
        await pause(1.0)
    }

    /// The row as it is under the pointer. A WKWebView off every display never gets the moves :hover needs, so a style
    /// rule shows the row's ✕ as :hover does (a rule, not a class: the row is redrawn as the threads move); the press
    /// on it is a real one. nil takes the rule away.
    func hover(_ selector: String?) async {
        let css = selector.map { "\($0) .row-dismiss { display: grid; } \($0) .item-time { display: none; }" } ?? ""
        await evaluate("(() => { let s = document.getElementById('test-hover'); if (!s) { s = document.createElement('style'); "
            + "s.id = 'test-hover'; document.head.append(s); } s.textContent = \(json(css)); return true; })()")
        await pause(0.1)
    }

    /// What the fake bridge keeps dismissed.
    func dismissedIds() async -> [String] {
        let items = (await get("/v1/desktop/inbox?include=dismissed"))?["items"] as? [[String: Any]] ?? []
        return items.filter { $0["dismissed"] as? Bool == true }.compactMap { $0["id"] as? String }
    }

    /// ⌃N and ⌃K in a text field are the field's (Cocoa's next line and kill line), not New Task and Search; behind a
    /// sheet the ⌘ keys and the menus' calls leave the view alone. (Keys go through the page's own keydown handler.)
    func keys() async {
        await evaluate("SamRabbitApp.show('tasks'); document.querySelector(\"[data-id='t3:th_pairing_redirect']\").click()")
        await pause(0.8)
        await evaluate("document.querySelector('.reply-input').focus()")
        for key in ["n", "k"] {
            await evaluate("document.activeElement.dispatchEvent(new KeyboardEvent('keydown', {key: '\(key)', ctrlKey: true, bubbles: true, cancelable: true}))")
            await pause(0.3)
        }
        let state = await evaluate("JSON.stringify([SamRabbitApp.summary().view, document.activeElement.className, Boolean(document.querySelector('.compose-input') && document.querySelector('.compose-input').isConnected)])") as? String
        check(state == "[\"tasks\",\"reply-input\",false]", "⌃N and ⌃K in the reply field leave the view, the focus and the composer alone (\(state ?? "?"))")
        await evaluate("SamRabbitApp.show('home')")
        await pause(0.5)
        await evaluate("[...document.querySelectorAll('.quick')].find((b) => b.textContent.includes('Journal')).click()")
        await pause(0.4)
        await evaluate("document.dispatchEvent(new KeyboardEvent('keydown', {key: '2', metaKey: true, bubbles: true, cancelable: true})); SamRabbitApp.newTask(); SamRabbitApp.show('calendar')")
        await pause(0.4)
        let behind = await evaluate("JSON.stringify([SamRabbitApp.summary().view, Boolean(document.querySelector('.overlay .dialog.journal'))])") as? String
        check(behind == "[\"home\",true]", "⌘2, New Task and a view from the menus do nothing behind the Journal sheet (\(behind ?? "?"))")
        await evaluate("document.dispatchEvent(new KeyboardEvent('keydown', {key: 'Escape', bubbles: true}))")
        await pause(0.4)
        await evaluate("document.dispatchEvent(new KeyboardEvent('keydown', {key: '2', metaKey: true, bubbles: true, cancelable: true}))")
        await pause(0.4)
        let after = await evaluate("SamRabbitApp.summary().view") as? String
        check(after == "tasks", "with the sheet closed ⌘2 opens Tasks (\(after ?? "?"))")
    }

    func hiddenWindow() async {
        await evaluate("SamRabbitApp.show('home')")
        await pause(1.0)
        window.orderOut(nil)
        await pause(1.2)
        let hidden = await evaluate("document.visibilityState") as? String
        check(hidden == "hidden", "an ordered-out window's page is hidden (\(hidden ?? "?"))")
        let readsBefore = await reads()
        let pollsBefore = await polls()
        await evaluate("SamRabbitApp.refresh()")
        await pause(3.0)
        let pollsHidden = (await polls()) - pollsBefore
        let readsHidden = await reads()
        check(pollsHidden <= 1, "a hidden window doesn't long-poll the inbox (\(pollsHidden) reads in 3 s; ~20 when shown)")
        check(readsHidden["summary"] == readsBefore["summary"] && readsHidden["agenda"] == readsBefore["agenda"],
              "a hidden window reads neither the summary nor the agenda, even when asked to refresh (\(readsBefore) → \(readsHidden))")

        window.orderFrontRegardless()
        await pause(2.0)
        let shown = await evaluate("document.visibilityState") as? String
        let pollsShown = (await polls()) - pollsBefore - pollsHidden
        let readsShown = await reads()
        check(shown == "visible", "the page is visible again (\(shown ?? "?"))")
        check(pollsShown >= 3, "back on screen, the inbox is polled again (\(pollsShown) reads in 2 s)")
        check(readsShown["summary"] == (readsBefore["summary"] ?? 0) + 1 && readsShown["agenda"] == (readsBefore["agenda"] ?? 0) + 1,
              "back on screen, the summary and the agenda are read once (\(readsHidden) → \(readsShown))")
    }

    // MARK: the mouse

    /// Presses `selector`'s middle `presses` times and counts the `{type: "voice", action}` requests that arrived.
    func count(presses: Int, on selector: String, action: String) async -> Int {
        let before = voiceRequests(action)
        for _ in 0..<presses { await press(selector) }
        await pause(0.2)
        return voiceRequests(action) - before
    }

    func voiceRequests(_ action: String) -> Int {
        messages.filter { $0["type"] as? String == "voice" && $0["action"] as? String == action }.count
    }

    /// Mouse down in the middle of the element, 110 ms, mouse up at the same spot (a finger doesn't move).
    func press(_ selector: String, hold: Double = 0.11) async {
        let script = "(() => { const el = document.querySelector(\(json(selector))); if (!el) return null; "
            + "const r = el.getBoundingClientRect(); return [r.left, r.top, r.width, r.height]; })()"
        guard let box = await evaluate(script) as? [Double], box.count == 4 else {
            failures.append("nothing matches \(selector)")
            print("  FAILED: nothing matches \(selector)")
            return
        }
        let point = NSPoint(x: box[0] + box[2] / 2, y: web.bounds.height - (box[1] + box[3] / 2))
        post(.mouseMoved, at: point)
        post(.leftMouseDown, at: point)
        await pause(hold)
        post(.leftMouseUp, at: point)
        await pause(0.15)
    }

    func post(_ type: NSEvent.EventType, at point: NSPoint) {
        eventNumber += 1
        let event: NSEvent?
        if type == .mouseMoved {
            event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: eventNumber, clickCount: 0, pressure: 0)
        } else {
            event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: eventNumber, clickCount: 1,
                                       pressure: type == .leftMouseDown ? 1 : 0)
        }
        if let event { window.sendEvent(event) }
    }

    // MARK: the fake server

    func get(_ path: String) async -> [String: Any]? {
        var request = URLRequest(url: URL(string: path, relativeTo: base)!, timeoutInterval: 5)
        request.setValue(token, forHTTPHeaderField: "X-SamRabbit-Desktop")
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    func polls() async -> Int { (await get("/dev/inbox/fake"))?["polls"] as? Int ?? -1 }

    func reads() async -> [String: Int] { (await get("/dev/desktop"))?["reads"] as? [String: Int] ?? [:] }

    func item(_ id: String) async -> [String: Any]? {
        let path = "/v1/desktop/inbox/items/" + (id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id)
        return (await get(path))?["item"] as? [String: Any]
    }

    // MARK: helpers

    func check(_ condition: Bool, _ what: String) {
        print((condition ? "  ok: " : "  FAILED: ") + what)
        if !condition { failures.append(what) }
    }

    @discardableResult
    func evaluate(_ script: String) async -> Any? {
        await withCheckedContinuation { continuation in
            web.evaluateJavaScript(script) { value, _ in continuation.resume(returning: value) }
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

    func json(_ text: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [text])
        return String((data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]").dropFirst().dropLast())
    }

    /// The shell's pushes as MainWindowBridge sends them (`SamRabbitApp.native(…)`): the level about 12 times a second
    /// (its throttle), a reply streaming a word every 120 ms with a new question now and then.
    static let simulator = """
        window.__sim = (() => {
          const base = { conversationId: 'mac-clicks-1', brain: 'realtime', shortcut: '⌃⌥Space', shortcutProblem: null,
            wakeEnabled: true, wakeArmed: false, wakeProblem: null, micMuted: false, error: null };
          const words = ['You', 'have', 'the', 'one', 'on', 'one', 'with', 'Priya', 'at', 'two,', 'then', 'the', 'gym.'];
          let timers = [];
          const stop = () => { timers.forEach(clearInterval); timers = []; };
          SamRabbitApp.native({ app: { version: 'test', bridge: location.host }, dock: { enabled: true, canCustomize: false },
            shortcuts: [{ id: 'talk', label: 'Talk to SamRabbit', keys: '⌃⌥Space', problem: null }] });
          return {
            stop,
            voice(state, { stream = false, levels = true } = {}) {
              stop();
              let heard = state === 'speaking' ? 'What is on my calendar this afternoon?' : '';
              let count = stream ? 1 : 0;
              let level = 0.2;
              let turn = 0;
              let heardId = heard ? 'x1' : null;
              const caption = () => Array.from({ length: count }, (_, i) => words[i % words.length]).join(' ');
              const push = () => SamRabbitApp.native({ voice: { ...base, state, heard, heardId, caption: caption(), level } });
              push();
              if (levels) timers.push(setInterval(() => { level = level > 0.6 ? 0.12 : level + 0.09; push(); }, 83));
              if (stream) timers.push(setInterval(() => {
                count += 1;
                if (count > 30) { count = 1; turn += 1; heard = 'And after that, number ' + turn + '?'; heardId = 'x' + (turn + 1); }
                push();
              }, 120));
            },
            idle() {
              stop();
              SamRabbitApp.native({ voice: { ...base, state: 'idle', heard: '', caption: '', level: 0 } });
            },
          };
        })();
        """
}

@main
enum Clicks {
    static func main() {
        let environment = ProcessInfo.processInfo.environment
        guard let raw = environment["SR_BASE"], let base = URL(string: raw), base.port != 3780,
              let tokenFile = environment["SR_TOKEN_FILE"],
              let token = try? String(contentsOfFile: tokenFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) else {
            print("needs SR_BASE (the fake sync server, never :3780) and SR_TOKEN_FILE")
            exit(2)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            let runner = Runner(base: base, token: token)
            exit(await runner.run())
        }
        app.run()
    }
}
