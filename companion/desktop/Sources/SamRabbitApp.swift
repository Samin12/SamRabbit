import AppKit
import SwiftUI

/// App state shared by the menu bar extra, the main window and notifications.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    enum Bridge: Equatable {
        case connecting
        case connected
        case unavailable(Int)  // HTTP status; 0 = unreachable
    }

    @Published private(set) var bridge: Bridge = .connecting
    @Published private(set) var conversations: [ConversationSummary] = []
    @Published private(set) var lastSeen: Date?
    @Published private(set) var now = Date()
    @Published private(set) var notificationsAllowed = true

    let monitor = SyncMonitor()
    let notifier = Notifier()
    private(set) var window: MainWindowController?
    private var pairing: PairingWindowController?
    private var chatgpt: ChatGPTWindowController?
    private var listTimer: Timer?
    private var refreshPending = false
    private var firstListDone = false
    private var lastPageStatus = ""
    private var lastListAttempt = Date.distantPast

    var live: Bool { conversations.contains { $0.live } }

    func start(showWindow: Bool) {
        notifier.setUp()
        notifier.onOpen = { [weak self] id in self?.openMainWindow(conversation: id) }
        notifier.onAuthorization = { [weak self] allowed in self?.notificationsAllowed = allowed }
        monitor.onEvent = { [weak self] event in self?.handle(event) }
        monitor.onStreamState = { [weak self] state in
            guard let self else { return }
            if case .live = state { self.scheduleRefresh(after: 0.2) }
        }
        let controller = MainWindowController()
        controller.onPageStatus = { [weak self] body in self?.pageStatus(body) }
        window = controller
        controller.start()
        if showWindow { controller.show() }
        DockController.shared.start()
        Task { await refreshList() }
        monitor.start()
        listTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.now = Date()
                // Every 20 s while synced; once a minute while the bridge has no sync API.
                if self.bridge == .connected || Date().timeIntervalSince(self.lastListAttempt) >= 59 {
                    await self.refreshList()
                }
            }
        }
    }

    func openMainWindow(conversation: String? = nil) {
        guard let window else { return }
        window.show()
        window.openConversation(conversation)
    }

    /// The window's views from the menus (⌘1–⌘5, Settings…): "home" | "tasks" | "chats" | "calendar" | "settings".
    func showView(_ view: String) {
        guard let window else { return }
        window.show()
        window.showView(view)
    }

    /// New Task (⌘N): the window's Tasks view with the composer open.
    func newTask() {
        guard let window else { return }
        window.show()
        window.newTask()
    }

    /// "Pair iPhone…": the QR code and one-time code for the SamRabbit iPhone app, and the paired devices.
    func openPairing() {
        if pairing == nil { pairing = PairingWindowController() }
        pairing?.show()
    }

    /// "Connect ChatGPT…": the Mac's own ChatGPT login for the watch assistant's realtime voice.
    func openChatGPT() {
        if chatgpt == nil { chatgpt = ChatGPTWindowController() }
        chatgpt?.show()
    }

    func reload() {
        window?.reload()
        monitor.reconnectNow()
        Task { await refreshList() }
    }

    func openNotificationSettings() {
        let pane = "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.samrabbit.desktop"
        if let url = URL(string: pane) { NSWorkspace.shared.open(url) }
    }

    func focusSearch() {
        openMainWindow()
        window?.focusSearch()
    }

    private func handle(_ event: [String: Any]) {
        if let at = ConversationSummary.parseDate(event["at"]) {
            lastSeen = max(lastSeen ?? .distantPast, min(at, Date()))
        }
        notifier.consider(event)
        // The menu shows titles, order and live state: drafts (every ~300 ms while the R1 speaks) change
        // none of that, and each refresh is a request and a bridge log line.
        if (event["type"] as? String) != "message.assistant.delta" { scheduleRefresh(after: 2.0) }
    }

    private func scheduleRefresh(after delay: TimeInterval) {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            Task { @MainActor in
                self.refreshPending = false
                await self.refreshList()
            }
        }
    }

    func refreshList() async {
        lastListAttempt = Date()
        switch await SyncAPI.conversations(limit: 8) {
        case .success(let list):
            if bridge != .connected { Log.write("bridge sync API reachable (\(list.count) recent conversations)") }
            bridge = .connected
            conversations = list
            if let newest = list.map(\.lastAt).max() { lastSeen = max(lastSeen ?? .distantPast, min(newest, Date())) }
            if !firstListDone {
                firstListDone = true
                notifier.known.formUnion(list.map(\.id))
            }
        case .failure(let failure):
            if bridge != .unavailable(failure.status) {
                Log.write(failure.status == 0 ? "bridge sync API not reachable"
                          : failure.status == 404 ? "bridge has no conversation sync API yet"
                          : "bridge sync API answered HTTP \(failure.status)")
            }
            bridge = .unavailable(failure.status)
        }
        now = Date()
    }

    private func pageStatus(_ body: [String: Any]) {
        let type = body["type"] as? String ?? ""
        var parts = [type]
        for key in ["api", "status", "code", "conversations", "live", "images", "imagesFailed", "frames"] {
            if let value = body[key] { parts.append("\(key)=\(value)") }
        }
        let line = parts.joined(separator: " ")
        guard line != lastPageStatus else { return }
        lastPageStatus = line
        Log.write("page: \(line)")
    }

    // MARK: menu bar text

    var headline: String {
        switch bridge {
        case .connecting: return "Connecting to the bridge…"
        case .unavailable(0): return "Waiting for the SamRabbit bridge…"
        case .unavailable(404): return "Bridge has no conversation sync yet"
        case .unavailable(401), .unavailable(403): return "Bridge didn’t accept the desktop token"
        case .unavailable(let status): return "Bridge problem (HTTP \(status))"
        case .connected: return live ? "Live conversation on your R1" : "Synced with your R1"
        }
    }

    var lastSeenLine: String {
        guard let lastSeen else { return "R1 not seen yet" }
        let seconds = max(0, now.timeIntervalSince(lastSeen))
        if seconds < 60 { return "R1 last seen just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "R1 last seen \(formatter.localizedString(for: lastSeen, relativeTo: now))"
    }

    func menuTitle(_ conversation: ConversationSummary) -> String {
        let title = conversation.title.count > 46 ? String(conversation.title.prefix(45)) + "…" : conversation.title
        if conversation.live { return "●  \(title)" }
        let formatter = DateFormatter()
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = Calendar.current.isDateInToday(conversation.lastAt) ? .none : .short
        formatter.timeStyle = Calendar.current.isDateInToday(conversation.lastAt) ? .short : .none
        return "\(title)  ·  \(formatter.string(from: conversation.lastAt))"
    }

    var menuIcon: NSImage { MenuIcon.image(live: live, connected: bridge == .connected) }
}

/// Menu bar glyph: the orb outline with its wave; filled core while a conversation is live.
enum MenuIcon {
    private static var cache: [String: NSImage] = [:]

    static func image(live: Bool, connected: Bool) -> NSImage {
        let key = "\(live)-\(connected)"
        if let cached = cache[key] { return cached }
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            let ring = NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 14, height: 14))
            NSColor.black.setStroke()
            NSColor.black.setFill()
            ring.lineWidth = 1.5
            ring.stroke()
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(ovalIn: NSRect(x: 2.75, y: 2.75, width: 12.5, height: 12.5)).addClip()
            let wave = NSBezierPath()
            wave.move(to: NSPoint(x: 1, y: 10))
            wave.curve(to: NSPoint(x: 9, y: 9.5), controlPoint1: NSPoint(x: 3.5, y: 7.5), controlPoint2: NSPoint(x: 6.5, y: 11.5))
            wave.curve(to: NSPoint(x: 17, y: 8.5), controlPoint1: NSPoint(x: 11.5, y: 7.5), controlPoint2: NSPoint(x: 14.5, y: 7))
            wave.line(to: NSPoint(x: 17, y: 17))
            wave.line(to: NSPoint(x: 1, y: 17))
            wave.close()
            if live || connected { wave.fill() } else {
                wave.lineWidth = 1
                wave.stroke()
            }
            NSGraphicsContext.restoreGraphicsState()
            if live {
                NSBezierPath(ovalIn: NSRect(x: 12.5, y: 0.5, width: 5, height: 5)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = live ? "SamRabbit: live conversation" : "SamRabbit"
        cache[key] = image
        return image
    }
}

struct MenuContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Text(model.headline)
        Text(model.lastSeenLine)
        Divider()
        VoiceMenuItems()
        Divider()
        if !model.conversations.isEmpty {
            Text("Recent conversations")
            ForEach(Array(model.conversations.prefix(6))) { conversation in
                Button(model.menuTitle(conversation)) { model.openMainWindow(conversation: conversation.id) }
            }
            Divider()
        }
        Button("Open SamRabbit") { model.openMainWindow() }
            .keyboardShortcut("o")
        Button("Show Agent Dock") { DockController.shared.showFromMenu() }
        Button("Pair iPhone…") { model.openPairing() }
        Button("Connect ChatGPT…") { model.openChatGPT() }
        if !model.notificationsAllowed {
            Button("Turn On Notifications…") { model.openNotificationSettings() }
        }
        Button("Reload") { model.reload() }
            .keyboardShortcut("r")
        Divider()
        Button("Quit SamRabbit") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Dev only: draw the Agent Dock's states to PNGs from fixtures and quit (DockSnapshots.swift).
        if let directory = Config.argument("--render-dock-snapshots") {
            MainActor.assumeIsolated { exit(DockSnapshots.render(to: directory)) }
        }
        // Dev only: load the window against a fake bridge, draw each view and a Talk conversation (MacVoice in
        // fixture mode) to PNGs, and quit (MainWindowSnapshots.swift).
        if let directory = Config.argument("--render-window-snapshots") {
            MainActor.assumeIsolated { MainWindowSnapshots.run(to: directory) }
            return
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let atLogin = CommandLine.arguments.contains("--login")
        Log.write("launch SamRabbit \(Config.version) pid=\(ProcessInfo.processInfo.processIdentifier) base=\(Config.baseURL.absoluteString)"
                  + (Config.isDefaultBase ? "" : " (override)") + (atLogin ? " at-login" : ""))
        MainActor.assumeIsolated {
            AppModel.shared.start(showWindow: !atLogin)
            MacVoice.shared.activate()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated {
            if !(AppModel.shared.window?.isVisible ?? false) { AppModel.shared.openMainWindow() }
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        Log.write("quit")
    }
}

@main
struct SamRabbitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var model = AppModel.shared

    var body: some Scene {
        // Not in the window snapshots (a dev run that draws the window to PNGs and quits).
        MenuBarExtra(isInserted: .constant(!MainWindowSnapshots.requested)) {
            MenuContent(model: model)
        } label: {
            Image(nsImage: model.menuIcon)
        }
        .menuBarExtraStyle(.menu)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { model.showView("settings") }
                    .keyboardShortcut(",")
            }
            CommandGroup(replacing: .newItem) {
                Button("New Task") { model.newTask() }
                    .keyboardShortcut("n")
                Button("Open SamRabbit Window") { model.openMainWindow() }
                    .keyboardShortcut("0")
                Button("Pair iPhone…") { model.openPairing() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Connect ChatGPT…") { model.openChatGPT() }
                Button("Show Agent Dock") { DockController.shared.showFromMenu() }
                    .keyboardShortcut("k", modifiers: [.control, .option])
            }
            CommandGroup(before: .toolbar) {
                Button("Home") { model.showView("home") }
                    .keyboardShortcut("1")
                Button("Tasks") { model.showView("tasks") }
                    .keyboardShortcut("2")
                Button("Chats") { model.showView("chats") }
                    .keyboardShortcut("3")
                Button("Calendar") { model.showView("calendar") }
                    .keyboardShortcut("4")
                Button("Settings") { model.showView("settings") }
                    .keyboardShortcut("5")
                Divider()
            }
            CommandGroup(after: .toolbar) {
                Button("Reload") { model.reload() }
                    .keyboardShortcut("r")
                Button("Search Conversations") { model.focusSearch() }
                    .keyboardShortcut("k")
            }
        }
    }
}
