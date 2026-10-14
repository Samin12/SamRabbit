import AppKit
import SwiftUI

/// DEV ONLY: draws the Agent Dock's states to PNGs from the fixtures, without a window and without Screen Recording
/// permission, then quits.
///
///     SamRabbit.app/Contents/MacOS/SamRabbit --render-dock-snapshots <dir> [--dock-fixture <inbox.json>]
///                                            [--dock-backdrop <image>]
///
/// The fixtures are `companion/desktop/dev/samples/inbox.json` (found next to the build, or given), shifted to now.
/// The glass is simulated by blurring the backdrop picture under it (a real window samples the screen instead);
/// everything else is the dock's own SwiftUI views with the fixture data.
@MainActor
enum DockSnapshots {
    static func render(to directory: String) -> Int32 {
        let out = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        guard let fixture = Fixture.load() else {
            print("dock snapshots: no fixture (pass --dock-fixture companion/desktop/dev/samples/inbox.json)")
            return 2
        }
        let wallpaper = backdrop()
        let page = lightPage(CGSize(width: 1600, height: 1400))
        var written: [String] = []

        func save(_ name: String, _ size: CGSize, backdrop: NSImage? = nil, _ content: some View) {
            let image = backdrop ?? wallpaper
            let view = SnapshotCanvas(size: size, backdrop: image, content: content)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            renderer.proposedSize = ProposedViewSize(size)
            guard let cg = renderer.cgImage,
                  let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
                print("dock snapshots: could not render \(name)")
                return
            }
            let url = out.appendingPathComponent(name)
            do {
                try png.write(to: url)
                written.append(url.path)
            } catch {
                print("dock snapshots: could not write \(url.path)")
            }
        }

        let listening = DockVoiceSnapshot(phase: .listening, heard: "", caption: "", level: 0.55, wakeArmed: false)
        let idleVoice = DockVoiceSnapshot(phase: .idle, wakeArmed: true)

        // 1. The pill.
        do {
            let (store, ui) = fixture.make()
            save("dock-01-pill.png", CGSize(width: 760, height: 190), Stage { DockPill(store: store, ui: ui, voice: idleVoice, commands: DockCommands()) })
        }
        // 2. Its states: hovered, working only, all clear, offline, and at 1.34x (a 3200 pt screen).
        do {
            let (needs, hovered) = fixture.make()
            hovered.pillHover = true
            let working = fixture.make(keep: { $0.status == .working }).0
            let clear = fixture.make(keep: { _ in false }).0
            let offline = fixture.make(connection: .offline(0)).0
            let (_, big) = fixture.make()
            big.pillScale = DockMetrics.pillScale(screenWidth: 3200, zoom: 1)
            save("dock-02-pill-states.png", CGSize(width: 760, height: 560), VStack(spacing: 22) {
                DockPill(store: needs, ui: hovered, voice: idleVoice, commands: DockCommands())
                DockPill(store: working, ui: DockUIState(), voice: DockVoiceSnapshot(), commands: DockCommands())
                DockPill(store: clear, ui: DockUIState(), voice: DockVoiceSnapshot(), commands: DockCommands())
                DockPill(store: offline, ui: DockUIState(), voice: DockVoiceSnapshot(), commands: DockCommands())
                DockPill(store: needs, ui: big, voice: idleVoice, commands: DockCommands())
            }.padding(.bottom, 26))
        }
        // 3. The expanded panel above the pill.
        do {
            let (store, ui) = fixture.make()
            ui.expanded = true
            ui.selected = "t3:th_waitlist_db"
            save("dock-03-panel.png", CGSize(width: 680, height: 1000), Stage { panel(store, ui, idleVoice) })
        }
        // 4. An approval row open in place (3 options, the last messages).
        do {
            let (store, ui) = fixture.make()
            ui.expanded = true
            ui.selected = "t3:th_pairing_redirect"
            ui.expandedRow = "t3:th_pairing_redirect"
            save("dock-04-approval.png", CGSize(width: 680, height: 1000), Stage { panel(store, ui, idleVoice) })
        }
        // 5. A question with options and room to type.
        do {
            let (store, ui) = fixture.make()
            ui.expanded = true
            ui.selected = "t3:th_waitlist_db"
            ui.expandedRow = "t3:th_waitlist_db"
            store.selections["t3:th_waitlist_db"] = ["db": ["SQLite with Litestream"]]
            save("dock-05-question.png", CGSize(width: 680, height: 1000), Stage { panel(store, ui, idleVoice) })
        }
        // 6–7. The compose bar with its target menus.
        for (menu, name) in [(DockUIState.Menu.project, "dock-06-compose-project.png"), (.agent, "dock-07-compose-agent.png")] {
            let (store, ui) = fixture.make()
            ui.expanded = true
            ui.menu = menu
            ui.editing = .compose
            store.composeText = "Add a dark mode toggle to the settings page"
            save(name, CGSize(width: 680, height: 1000), Stage { panel(store, ui, idleVoice) })
        }
        // 8. The voice bar: listening, thinking, speaking (caption streaming), muted, a problem.
        do {
            let (store, ui) = fixture.make()
            let states = [
                listening,
                DockVoiceSnapshot(phase: .thinking, heard: "What needs me right now?"),
                DockVoiceSnapshot(phase: .speaking, heard: "What needs me right now?",
                                  caption: "Two things need you. The pairing fix wants to run its tests, and the waitlist task is asking which database to use.",
                                  level: 0.4),
                DockVoiceSnapshot(phase: .listening, heard: "Approve the tests", caption: "Done — the tests are running.", micMuted: true),
                DockVoiceSnapshot(phase: .error("I can’t reach your Mac’s bridge right now.")),
            ]
            _ = store
            save("dock-08-voice.png", CGSize(width: 760, height: 520), VStack(spacing: 18) {
                ForEach(Array(states.enumerated()), id: \.offset) { _, state in
                    DockVoiceBar(voice: state, scale: ui.pillScale, commands: DockCommands())
                }
            }.padding(.bottom, 24))
        }
        // 9. A Claude Code session that is open in Terminal: answered there.
        do {
            let (store, ui) = fixture.make()
            let id = "claude:5d0c6f2e-1a47-4f7e-9a51-3c2b1e0d9f88"
            ui.expanded = true
            ui.selected = id
            ui.expandedRow = id
            store.showNote(DockStore.note(for: DockAPI.Failure(status: 409, code: "session_live")), for: id)
            store.replyDrafts[id] = ""
            save("dock-09-terminal.png", CGSize(width: 680, height: 1000), Stage { panel(store, ui, idleVoice) })
        }
        // 10. Over a white page (one neutral glass whatever is behind it).
        do {
            let (store, ui) = fixture.make()
            ui.expanded = true
            ui.selected = "t3:th_release_notes"
            ui.expandedRow = "t3:th_release_notes"
            save("dock-10-light.png", CGSize(width: 680, height: 1000), backdrop: page, Stage { panel(store, ui, idleVoice) })
        }
        // 11. The bridge is down.
        do {
            let (store, ui) = fixture.make(connection: .offline(0))
            ui.expanded = true
            save("dock-11-offline.png", CGSize(width: 680, height: 560), Stage { panel(store, ui, DockVoiceSnapshot()) })
        }
        for path in written { print(path) }
        return written.count == 11 ? 0 : 1
    }

    private static func panel(_ store: DockStore, _ ui: DockUIState, _ voice: DockVoiceSnapshot) -> some View {
        VStack(spacing: DockMetrics.panelGap) {
            DockPanel(store: store, ui: ui, voice: voice, commands: DockCommands()).fixedSize()
            DockPill(store: store, ui: ui, voice: voice, commands: DockCommands()).fixedSize()
        }
    }

    // MARK: fixtures

    struct Fixture {
        let inbox: DockInbox
        let details: [String: [DockMessage]]
        let targets: DockTargets?
        let now: Date

        static func load() -> Fixture? {
            let fallbacks: [String?] = [
                Config.argument("--dock-fixture"),
                ProcessInfo.processInfo.environment["SAMRABBIT_DOCK_FIXTURE"],
                FileManager.default.currentDirectoryPath + "/companion/desktop/dev/samples/inbox.json",
                FileManager.default.currentDirectoryPath + "/dev/samples/inbox.json",
                Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
                    .appendingPathComponent("dev/samples/inbox.json").path,
            ]
            for candidate in fallbacks.compactMap({ $0 }) {
                guard let data = FileManager.default.contents(atPath: (candidate as NSString).expandingTildeInPath),
                      var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                let now = Date()
                if let base = (json["base"] as? String).flatMap(DockDate.parse) {
                    json = shift(json, by: now.timeIntervalSince(base)) as? [String: Any] ?? json
                }
                guard let inboxData = try? JSONSerialization.data(withJSONObject: json["inbox"] ?? [:]),
                      let inbox = try? DockInbox.decode(inboxData) else { continue }
                var details: [String: [DockMessage]] = [:]
                if let raw = json["details"] as? [String: Any] {
                    for (id, messages) in raw {
                        if let data = try? JSONSerialization.data(withJSONObject: messages),
                           let decoded = try? JSONDecoder().decode([DockMessage].self, from: data) {
                            details[id] = decoded
                        }
                    }
                }
                let targets = (try? JSONSerialization.data(withJSONObject: json["targets"] ?? [:]))
                    .flatMap { try? JSONDecoder().decode(DockTargets.self, from: $0) }
                return Fixture(inbox: inbox, details: details, targets: targets, now: now)
            }
            return nil
        }

        /// Moves every ISO time in the fixture by `delta`, so "2 minutes ago" stays 2 minutes ago.
        static func shift(_ value: Any, by delta: TimeInterval) -> Any {
            if let dict = value as? [String: Any] {
                return dict.mapValues { shift($0, by: delta) }
            }
            if let list = value as? [Any] { return list.map { shift($0, by: delta) } }
            if let text = value as? String, text.count >= 20, text.contains("T"), let date = DockDate.parse(text) {
                let formatter = ISO8601DateFormatter()
                return formatter.string(from: date.addingTimeInterval(delta))
            }
            return value
        }

        @MainActor func make(keep: ((DockItem) -> Bool)? = nil, connection: DockStore.Connection = .online) -> (DockStore, DockUIState) {
            var inbox = self.inbox
            if let keep {
                inbox.items = inbox.items.filter(keep)
                inbox.counts = DockCounts(needsYou: inbox.items.filter(\.needsYou).count,
                                          working: inbox.items.filter { $0.status == .working && !$0.isChat }.count,
                                          total: inbox.items.count)
            }
            var detailMap: [String: DockItemDetail] = [:]
            for item in inbox.items {
                if let messages = details[item.id] { detailMap[item.id] = DockItemDetail(item: item, messages: messages) }
            }
            let store = DockStore(fixture: inbox, details: detailMap, targets: targets, now: now, connection: connection)
            let ui = DockUIState()
            ui.pillScale = 1
            ui.panelScale = 1
            ui.maxPanelHeight = 860
            return (store, ui)
        }
    }

    // MARK: backdrops

    /// A real macOS wallpaper (scaled down once), else a gradient.
    private static func backdrop() -> NSImage {
        let candidates: [String?] = [Config.argument("--dock-backdrop"), "/System/Library/Desktop Pictures/Sonoma.heic",
                          "/System/Library/Desktop Pictures/Mac Blue.heic"]
        for path in candidates.compactMap({ $0 }) {
            if let image = NSImage(contentsOfFile: (path as NSString).expandingTildeInPath) {
                return scaled(image, maxSide: 2400)
            }
        }
        return NSImage(size: NSSize(width: 1600, height: 1200), flipped: false) { rect in
            NSGradient(colors: [NSColor(srgbRed: 0.1, green: 0.2, blue: 0.5, alpha: 1), NSColor(srgbRed: 0.6, green: 0.3, blue: 0.5, alpha: 1)])?
                .draw(in: rect, angle: 60)
            return true
        }
    }

    private static func scaled(_ image: NSImage, maxSide: CGFloat) -> NSImage {
        let size = image.size
        let factor = min(1, maxSide / max(size.width, size.height))
        let target = NSSize(width: (size.width * factor).rounded(), height: (size.height * factor).rounded())
        return NSImage(size: target, flipped: false) { rect in
            image.draw(in: rect)
            return true
        }
    }

    /// A white document page: the case where a dark-only widget turns into a black blob.
    private static func lightPage(_ size: CGSize) -> NSImage {
        NSImage(size: size, flipped: true) { rect in
            NSColor.white.setFill()
            rect.fill()
            NSColor(white: 0.96, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: rect.width, height: 120).fill()
            NSColor(white: 0.2, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: 120, y: 200, width: 640, height: 34), xRadius: 6, yRadius: 6).fill()
            NSColor(srgbRed: 0.2, green: 0.45, blue: 0.95, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: 120, y: 260, width: 220, height: 14), xRadius: 4, yRadius: 4).fill()
            var y: CGFloat = 320
            var line = 0
            while y < rect.height - 80 {
                NSColor(white: 0.78, alpha: 1).setFill()
                let width = line % 7 == 6 ? 520.0 : 1180.0 - CGFloat((line * 37) % 160)
                NSBezierPath(roundedRect: NSRect(x: 120, y: y, width: width, height: 11), xRadius: 4, yRadius: 4).fill()
                y += line % 7 == 6 ? 58 : 26
                line += 1
            }
            return true
        }
    }
}

/// DEV ONLY: `SAMRABBIT_DOCK_SMOKE=<dir>` drives the running dock through its states without any synthetic click
/// (open the list, expand an approval, approve it, send a new prompt, the voice bar with the placeholder voice, hide for
/// a while and back), logs what AppKit says about its windows at each step, and draws each state from the live store
/// into <dir> (drawn like the snapshots: the live views and data over a backdrop, since nothing may capture the screen).
@MainActor
enum DockSmoke {
    static func run(_ controller: DockController, directory: String) {
        let out = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var steps: [(TimeInterval, String, () -> Void)] = []
        func step(_ at: TimeInterval, _ name: String, _ body: @escaping () -> Void = {}) { steps.append((at, name, body)) }
        let store = controller.store
        let ui = controller.ui
        var approved: String?

        step(3, "pill")
        step(3.5, "summon") { controller.summon(focusCompose: false) }
        step(5, "panel")
        // J, J, K through the list window's own event path (the same NSEvent route a real key takes once the panel is
        // key); nothing is posted to the system.
        step(5.2, "keys") {
            for (character, code) in [("j", UInt16(38)), ("j", UInt16(38)), ("k", UInt16(40))] {
                guard let list = controller.list,
                      let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                   windowNumber: list.windowNumber, context: nil, characters: character,
                                                   charactersIgnoringModifiers: character, isARepeat: false, keyCode: code) else { continue }
                list.sendEvent(event)
            }
        }
        step(5.5, "expand") {
            if let item = store.items.first(where: { $0.supports("approve") && !$0.pending.approvals.isEmpty }) {
                approved = item.id
                controller.perform(.expand(item.id))
            }
        }
        step(7, "approval")
        step(7.5, "approve") {
            if let id = approved, let row = store.item(id).map(DockKeyRow.init), let approval = row.approval {
                controller.perform(.approve(id: id, requestId: approval.requestId, decision: approval.decision))
            }
        }
        step(10, "approved")
        step(10.5, "compose") {
            store.composeText = "Smoke test: list the TODOs in the bridge"
            store.sendCompose()
        }
        step(13, "new-task")
        step(13.5, "voice-start") {
            controller.perform(.collapsePanel)
            controller.toggleVoice()
        }
        step(16.5, "voice-heard")
        step(19.5, "voice-speaking")
        step(20, "voice-end") { MacVoice.shared.end() }
        step(21.5, "hide") { controller.hide(for: .hour) }
        step(23, "hidden")
        step(23.5, "unhide") { controller.clearHide() }
        step(25, "back")
        step(25.5, "hotkey") {
            controller.perform(.collapsePanel)
            controller.summon(focusCompose: true)
        }
        step(27, "hotkey-compose")

        for (at, name, body) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + at) {
                body()
                let pill = controller.pill
                let list = controller.list
                let main = AppModel.shared.window?.window
                func describe(_ window: NSWindow?) -> String {
                    guard let window else { return "none" }
                    let f = window.frame
                    let responder = window.firstResponder.map { $0 is NSTextView ? "text field" : "\(type(of: $0))" } ?? "none"
                    return "\(window.isVisible ? "visible" : "hidden") \(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))"
                        + " level=\(window.level.rawValue) key=\(window.isKeyWindow) keys=\(responder)"
                }
                Log.write("dock smoke \(name): pill \(describe(pill)); list \(describe(list)); front app=\(NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? "SamRabbit" : "other");"
                          + " main window visible=\(main?.isVisible ?? false); needs you \(store.needsYouCount), working"
                          + " \(store.workingCount), items \(store.items.count); expanded=\(ui.expanded); selected=\(ui.selected ?? "-"); voice=\(MacVoice.shared.state)")
                draw(controller, name: name, to: out)
                if name == "hotkey-compose" { Log.write("dock smoke done") }
            }
        }
    }

    private static func draw(_ controller: DockController, name: String, to out: URL) {
        let store = controller.store
        let ui = controller.ui
        let voice = DockVoiceSnapshot(MacVoice.shared)
        let size = CGSize(width: 680, height: ui.expanded ? 1000 : 260)
        let backdrop = NSImage(size: NSSize(width: 680, height: 1000), flipped: false) { rect in
            NSGradient(colors: [NSColor(srgbRed: 0.16, green: 0.2, blue: 0.32, alpha: 1), NSColor(srgbRed: 0.42, green: 0.3, blue: 0.4, alpha: 1)])?
                .draw(in: rect, angle: 70)
            return true
        }
        let content = VStack(spacing: DockMetrics.panelGap) {
            if ui.expanded {
                DockPanel(store: store, ui: ui, voice: voice, commands: DockCommands()).fixedSize()
            }
            if voice.active {
                DockVoiceBar(voice: voice, scale: ui.pillScale, commands: DockCommands()).fixedSize()
            } else {
                DockPill(store: store, ui: ui, voice: voice, commands: DockCommands()).fixedSize()
            }
        }
        .padding(.bottom, 26)
        let renderer = ImageRenderer(content: SnapshotCanvas(size: size, backdrop: backdrop, content: content))
        renderer.scale = 2
        guard let cg = renderer.cgImage, let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return }
        try? png.write(to: out.appendingPathComponent("smoke-\(name).png"))
    }
}

/// Bottom-centre staging, like the dock on a screen: 26 pt of room under the pill.
private struct Stage<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content.padding(.bottom, 26)
    }
}

private struct SnapshotCanvas<Content: View>: View {
    let size: CGSize
    let backdrop: NSImage
    let content: Content

    var body: some View {
        ZStack(alignment: .bottom) {
            Image(nsImage: backdrop)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size.width, height: size.height)
            content
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .coordinateSpace(name: DockRender.canvasSpace)
        .environment(\.dockRender, DockRender(glass: .hud, backdrop: backdrop, canvas: size))
        .environment(\.colorScheme, .dark)
    }
}
