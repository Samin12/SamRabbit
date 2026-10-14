import AppKit
import Carbon
import Combine
import SwiftUI

/// One of the dock's two windows: the pill (or voice bar), and the list that opens above it. Each is exactly the
/// size of what it shows (no padded click-through margin), clear, without a system shadow (the glass draws its own
/// edge), above normal windows, on every Space and over full-screen apps, and never in the Window menu or ⌘-Tab.
/// It may become key, so its fields take typing, WITHOUT activating SamRabbit: a press on the dock never brings the
/// main window forward (`.nonactivatingPanel`).
final class DockPanelWindow: NSPanel {
    enum Role {
        case pill, list
    }

    let role: Role
    weak var controller: DockController?
    /// Set when the list comes on screen: the next time it becomes key it keeps the keys itself.
    var keepKeysOnNextKey = false

    init(role: Role) {
        self.role = role
        super.init(contentRect: NSRect(x: 0, y: 0, width: 240, height: 44), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isFloatingPanel = true  // before the level: it sets the level to .floating
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        // A click in the list gives it the keys (J/K, E, R…); the pill takes them only for a voice conversation.
        becomesKeyOnlyIfNeeded = role == .pill
        isExcludedFromWindowsMenu = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        isMovable = false
        acceptsMouseMovedEvents = true
        worksWhenModal = true
        appearance = NSAppearance(named: .darkAqua)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// AppKit gives the first text field the keys when a window first becomes key; the list keeps them (J/K, E, R…)
    /// unless a field was asked for (N, R, ⌃⌥K) or clicked, which happens right after this.
    override func becomeKey() {
        super.becomeKey()
        guard keepKeysOnNextKey else { return }
        keepKeysOnNextKey = false
        if firstResponder is NSTextView { makeFirstResponder(nil) }
    }

    override func sendEvent(_ event: NSEvent) {
        if let controller, MainActor.assumeIsolated({ controller.handle(event, in: self) }) { return }
        super.sendEvent(event)
    }
}

/// Hosting view for the dock: takes the first click even though SamRabbit isn't active, and tells the controller when
/// the pointer comes onto it (from there the controller follows the real cursor until it has left the dock).
final class DockHostingView<Content: View>: NSHostingView<Content> {
    var onPointerEntered: (() -> Void)?
    private var area: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        self.area = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onPointerEntered?()
    }
}

/// A menu item that runs a closure.
final class DockMenuItem: NSMenuItem {
    private let handler: () -> Void

    /// `shortcut`: shown at the right of the item, as the menus of the app show theirs (the global hot key does the work).
    init(_ title: String, key: String = "", shortcut: DockShortcut? = nil, state: NSControl.StateValue = .off, enabled: Bool = true,
         handler: @escaping () -> Void = {}) {
        self.handler = handler
        super.init(title: title, action: enabled ? #selector(run) : nil, keyEquivalent: key)
        target = self
        self.state = state
        isEnabled = enabled
        if let shortcut, let key = shortcut.menuKey {
            keyEquivalent = key
            keyEquivalentModifierMask = NSEvent.ModifierFlags(rawValue: shortcut.menuModifierFlags)
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func run() { handler() }
}

/// The Agent Dock: a floating glass pill with the agents that are waiting for Samin (T3 Code threads, Claude Code and
/// Codex sessions, SamRabbit chats), a list that opens beside it with inline approve / answer / reply / stop / open, a
/// compose bar for a new prompt, and the voice bar during a conversation. It rests at the bottom of the screen until
/// Samin drags it anywhere on any screen (remembered per screen as a corner and a gap), folds to the orb (⌃⌥M, the
/// "–"), and ⌃⌥D puts it away and brings it back. It shows whenever the main window is minimised, closed or hidden, or
/// another app is in front, and steps aside while Samin is in the main window. See CONTRACTS-WAVE6 §B and WAVE7 §B2;
/// the rules live in DockVisibility / DockPlacement / DockKeyboard / DockShortcut (unit-tested), this class wires
/// them to AppKit.
@MainActor
final class DockController: NSObject {
    static let shared = DockController()

    let store = DockStore()
    let ui = DockUIState()
    private let voice = MacVoice.shared
    /// What each window draws of the voice: the pill follows the mic level during a conversation, the list never.
    private lazy var pillVoice = DockVoiceFeed(voice, keepsLevel: true)
    private lazy var listVoice = DockVoiceFeed(voice, keepsLevel: false)
    /// Voice notes (CONTRACTS-WAVE8 §D1): ⌃⌥N, the pill's note button, the menu; their bar takes the pill's place.
    private let notes = VoiceNotes.shared
    private lazy var noteFeed = DockNoteFeed(notes)
    private var noteSubscription: AnyCancellable?
    private var noteActive = false
    private let render = DockRender(glass: DockRender.liveGlass())
    private(set) var pill: DockPanelWindow?
    private(set) var list: DockPanelWindow?
    private var expansion = DockExpansion()
    private var openTimer: Timer?
    private var closeTimer: Timer?
    private var pointerTimer: Timer?
    private var followTimer: Timer?
    private var unhideTimer: Timer?
    private let shortcuts = DockShortcutCenter.shared
    /// ⌘+ / ⌘− / ⌘0, held only while the pointer is on the dock.
    private var zoomKeys: [DockHotKey] = []
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var voiceSubscription: AnyCancellable?
    private var editingSubscription: AnyCancellable?
    private var started = false
    private var visible = false
    private var summoned = false
    private var voiceActive = false
    private var lastReason: DockVisibility.Reason?
    /// ⌃⌥D's hide, the orb, "over the app" (DockPresence; the first two are kept in UserDefaults).
    private var presence = DockPresence()
    /// The screen it is on and its spot there (from `place`, or the bottom middle).
    private var screen: DockScreen?
    private var spotHere = DockSpot.home
    /// What the pill window measured: its size, and how much of that is the "–".
    private var pillSize = CGSize.zero
    private var slotWidth: CGFloat = 0
    /// Where the pill rests without the "–" (the list lines up with this, so the button doesn't move it).
    private var restFrame = CGRect.zero
    private var listSize = CGSize.zero
    private var pillControls: [CGRect] = []
    private var overPill = false
    private var overList = false
    private var otherScreenTicks = 0
    /// The list should take the keys as soon as it is on screen (⌃⌥K, a click on the pill).
    private var listWantsKey = false
    /// A field asked for the keys (⌃⌥K → compose): revealing the list must not take them back.
    private var fieldWanted = false

    private struct Press {
        var start: CGPoint
        /// The resting frame (without the "–", which goes while dragging).
        var frame: CGRect
        var grip: Bool
        var leftGrip: Bool
        var zoom: Double
        var moved = false
    }

    private var press: Press?

    // MARK: settings (UserDefaults of the app's bundle id)

    private enum Key {
        static let enabled = "AgentDockEnabled"
        static let hiddenUntil = "AgentDockHiddenUntil"
        // AgentDockPlace, Wave 6's AgentDockSpot and AgentDockPlaceMigrated: DockPlaceMemory.
        static let zoom = "AgentDockZoom"
        static let putAway = "AgentDockPutAway"
        static let minimized = "AgentDockMinimized"
    }

    private var enabled: Bool {
        get { UserDefaults.standard.object(forKey: Key.enabled) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Key.enabled) }
    }

    private var hiddenUntil: Date? {
        get {
            let value = UserDefaults.standard.double(forKey: Key.hiddenUntil)
            return value > 0 ? Date(timeIntervalSince1970: value) : nil
        }
        set {
            if let newValue { UserDefaults.standard.set(newValue.timeIntervalSince1970, forKey: Key.hiddenUntil) }
            else { UserDefaults.standard.removeObject(forKey: Key.hiddenUntil) }
        }
    }

    private let memory = DockPlaceMemory(defaults: UserDefaults.standard)

    /// Where Samin left it (nil: never moved, or "Move Back to the Middle").
    private var place: DockPlace? {
        get { memory.place }
        set { memory.place = newValue }
    }

    /// Wave 6 remembered a fraction of the bottom edge: the same place as a corner and a gap, at the first launch only.
    private func migratePlace() {
        let size = CGSize(width: 260, height: DockMetrics.pillBaseHeight)
        if let converted = memory.migrate(size: size, screens: screens()) {
            Log.write("dock: its spot is a corner and a gap now (\(converted.spot.corner.rawValue))")
        }
    }

    private func savePresence() {
        UserDefaults.standard.set(presence.hidden, forKey: Key.putAway)
        UserDefaults.standard.set(presence.minimized, forKey: Key.minimized)
        if ui.minimized != presence.minimized { ui.minimized = presence.minimized }
    }

    private var zoom: Double {
        get { DockMetrics.zoom(UserDefaults.standard.object(forKey: Key.zoom) as? Double) }
        set { UserDefaults.standard.set(DockMetrics.zoom(newValue), forKey: Key.zoom) }
    }

    /// The switch in AgentDockEnabled (off = "Turn Off the Dock" until it is turned on again).
    var isEnabled: Bool { enabled }

    /// What Settings' "Show the Agent Dock" says: turned on, and not put away (⌃⌥D, "Hide Agent Dock") or hidden for a
    /// while. Stepping aside for the main window doesn't count: that is the dock's own doing.
    var isOn: Bool {
        guard enabled, !presence.hidden else { return false }
        return hiddenUntil.map { $0 <= Date() } ?? true
    }

    var isMinimized: Bool { presence.minimized }

    /// Dev runs: forget a hide (the smoke driver hides it once and puts it back).
    func clearHide() {
        hiddenUntil = nil
        refresh()
    }

    /// Dev runs: leave the dock at `spot` on the screen it is on, as a drag ending there would (nil: forget every
    /// spot, as "Move Back to the Middle").
    func devPlace(_ spot: DockSpot?) {
        guard let screen else { return }
        place = spot.map { DockPlacement.remember($0, on: screen, in: place) }
        chooseScreen()
        placePill()
    }

    /// Dev runs: the screen it is on, and the frame it rests at there (without the "–").
    var devState: (screen: DockScreen?, rest: CGRect) { (screen, restFrame) }

    /// Dev runs: what the dock keeps of Samin's moves (its spot, the orb, ⌃⌥D's hide), to put back after a smoke run.
    struct DevMemory {
        let place: DockPlace?
        let minimized: Bool
        let putAway: Bool
    }

    var devMemory: DevMemory { DevMemory(place: place, minimized: presence.minimized, putAway: presence.hidden) }

    func devRestore(_ kept: DevMemory) {
        place = kept.place
        presence.minimized = kept.minimized
        presence.hidden = kept.putAway
        presence.overApp = false
        savePresence()
        chooseScreen()
        refresh()
        if visible { placePill() }
    }

    // MARK: start

    func start() {
        guard !started else { return }
        started = true
        store.onAnnounce = { [weak self] items in self?.announce(items) }
        store.onOpenConversation = { id in AppModel.shared.openMainWindow(conversation: id) }
        // A morning brief's agent item opens in the list itself.
        store.morning.onOpenInboxItem = { [weak self] id in self?.perform(.expand(id)) }
        AppModel.shared.notifier.onOpenInboxItem = { [weak self] id in self?.reveal(id) }
        presence.hidden = UserDefaults.standard.bool(forKey: Key.putAway)
        presence.minimized = UserDefaults.standard.bool(forKey: Key.minimized)
        ui.minimized = presence.minimized
        migratePlace()

        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
            NSApplication.didHideNotification, NSApplication.didUnhideNotification,
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification,
        ]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    if let window = note.object as? NSWindow, window is DockPanelWindow { return }
                    // A closing window is still visible while this runs: look again a moment later.
                    DispatchQueue.main.async { self?.refresh() }
                }
            })
        }
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didWakeNotification,
                     NSWorkspace.activeSpaceDidChangeNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        voiceSubscription = voice.$state.sink { [weak self] state in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.voiceChanged(active: state != .idle) } }
        }
        noteSubscription = notes.$snapshot.map(\.active).removeDuplicates().sink { [weak self] active in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.noteChanged(active: active) } }
        }
        // While a field has the keys, a list that opened on hover doesn't close under the pointer.
        editingSubscription = ui.$editing.removeDuplicates().sink { [weak self] editing in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.send(.editing(editing != nil)) } }
        }
        // A click anywhere outside the dock closes a list that is open. Mouse-down monitoring needs no permission.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.clickedOutside() }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            MainActor.assumeIsolated {
                if !(event.window is DockPanelWindow) { self?.clickedOutside() }
            }
            return event
        }) { monitors.append(local) }
        // AppKit offers ⌘ keys to the main menu before the key window sees them (⌘0 there opens the main window): while
        // a dock window has the keys, the dock decides first (DockCommandKey).
        if let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            let keep = MainActor.assumeIsolated { self?.keepCommandKey(event) ?? true }
            return keep ? event : nil
        }) { monitors.append(keys) }
        // ⌃⌥Space talk (MacVoice toggles itself), ⌃⌥K the list on compose, ⌃⌥D show / hide, ⌃⌥M orb ↔ pill: or
        // what Settings recorded instead.
        shortcuts.start([
            .compose: { [weak self] in self?.summon(focusCompose: true) },
            .showHide: { [weak self] in self?.toggleShown() },
            .minimize: { [weak self] in self?.toggleMinimized() },
            .voiceNote: { [weak self] in self?.notes.press() },
        ], releases: [
            .voiceNote: { [weak self] in self?.notes.release() },
        ])
        Log.write("dock: \(enabled ? "on" : "off")\(presence.hidden ? ", put away (⌃⌥D)" : "")\(presence.minimized ? ", minimized" : "")"
                  + " (glass \(render.glass.rawValue))")
        if enabled { store.start() }
        refresh()
        if let directory = ProcessInfo.processInfo.environment["SAMRABBIT_DOCK_SMOKE"] { DockSmoke.run(self, directory: directory) }
        if ProcessInfo.processInfo.environment["SAMRABBIT_DOCK_SMOKE_PLACES"] == "1" { DockSmoke.runPlaces(self) }
    }

    // MARK: visibility

    /// What decides whether it shows, as AppKit says it now (without Samin's own say: DockPresence adds that).
    private func visibilityInput() -> DockVisibilityInput {
        let main = AppModel.shared.window?.window
        var input = DockVisibilityInput()
        input.enabled = enabled
        input.hiddenUntil = hiddenUntil
        input.now = Date()
        // "SamRabbit is in front" is the frontmost app, not NSApp.isActive: a dock panel taking the keys makes AppKit
        // call the app active while the app Samin is in keeps the front and the menu bar.
        input.appActive = NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        input.mainWindowVisible = main?.isVisible ?? false
        input.mainWindowKey = main?.isKeyWindow ?? false
        input.mainWindowMinimized = main?.isMiniaturized ?? false
        input.voiceActive = voiceActive
        input.noteActive = noteActive
        input.summoned = summoned
        return input
    }

    func refresh() {
        guard started else { return }
        let seen = visibilityInput()
        presence.settle(seen)
        let input = presence.applied(to: seen)
        let reason = DockVisibility.reason(input)
        if reason != lastReason {
            Log.write("dock: \(DockVisibility.shows(input) ? "shown" : "hidden") (\(reason.rawValue))")
            lastReason = reason
        }
        if DockVisibility.shows(input) { show() } else { hide() }
        scheduleUnhide()
        let on = isOn
        if ui.switchedOn != on { ui.switchedOn = on }
    }

    private func scheduleUnhide() {
        unhideTimer?.invalidate()
        guard let until = hiddenUntil else { return }
        if until <= Date() {
            hiddenUntil = nil
            return
        }
        unhideTimer = Timer.scheduledTimer(withTimeInterval: until.timeIntervalSinceNow + 0.5, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.hiddenUntil = nil
                self?.refresh()
            }
        }
    }

    private func show() {
        let pill = pillWindow()
        if !visible {
            visible = true
            ui.shown = true
            chooseScreen()
            placePill()
            pill.alphaValue = 0
            pill.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                pill.animator().alphaValue = 1
            }
            startFollowingPointer()
        } else if !pill.isVisible {
            pill.orderFrontRegardless()
        }
    }

    private func hide() {
        guard visible else { return }
        visible = false
        ui.shown = false
        send(.hidden)
        followTimer?.invalidate()
        pointerTimer?.invalidate()
        pointerTimer = nil
        overPill = false
        overList = false
        updateZoomKeys()
        ui.pillHover = false
        updateMinimizeSlot()
        guard let pill else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.14
            pill.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.visible else { return }
                pill.orderOut(nil)
                pill.alphaValue = 1
            }
        })
    }

    // MARK: windows

    private lazy var commands = DockCommands(
        toggleVoice: { [weak self] in self?.toggleVoice() },
        setMicMuted: { [weak self] muted in self?.voice.micMuted = muted },
        stopSpeaking: { [weak self] in self?.voice.stopSpeaking() },
        endVoice: { [weak self] in self?.voice.end() },
        showMenu: { [weak self] in self?.showMenu() },
        collapse: { [weak self] in self?.send(.escape) },
        interact: { [weak self] in self?.send(.interact) },
        openItem: { [weak self] item in self?.store.open(item) },
        minimize: { [weak self] in self?.setMinimized(true) },
        toggleNote: { [weak self] in self?.toggleNote() },
        sendNote: { [weak self] in self?.notes.send() },
        cancelNote: { [weak self] in self?.notes.cancel() })

    private func pillWindow() -> DockPanelWindow {
        if let pill { return pill }
        let window = DockPanelWindow(role: .pill)
        window.controller = self
        let root = DockPillRoot(store: store, ui: ui, voice: pillVoice, note: noteFeed, commands: commands, render: render,
                                onMeasure: { [weak self] measure in self?.pillMeasured(measure) },
                                onHitRects: { [weak self] rects in self?.pillControls = rects })
        let hosting = DockHostingView(rootView: root)
        hosting.sizingOptions = []
        hosting.onPointerEntered = { [weak self] in self?.pointerEntered() }
        window.contentView = hosting
        window.setAccessibilityLabel("SamRabbit Agent Dock")
        pill = window
        return window
    }

    private func listWindow() -> DockPanelWindow {
        if let list { return list }
        let window = DockPanelWindow(role: .list)
        window.controller = self
        let root = DockPanelRoot(store: store, ui: ui, voice: listVoice, commands: commands, render: render,
                                 onSize: { [weak self] size in self?.listSized(size) })
        let hosting = DockHostingView(rootView: root)
        hosting.sizingOptions = []
        hosting.onPointerEntered = { [weak self] in self?.pointerEntered() }
        window.contentView = hosting
        window.setAccessibilityLabel("SamRabbit agents")
        list = window
        return window
    }

    // MARK: placement

    private func screens() -> [DockScreen] {
        NSScreen.screens.map { DockScreen(id: Self.screenId($0), frame: $0.frame, visibleFrame: $0.visibleFrame) }
    }

    static func screenId(_ screen: NSScreen) -> String {
        if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
           let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue(),
           let text = CFUUIDCreateString(nil, uuid) as String? {
            return text
        }
        return "\(screen.localizedName)-\(Int(screen.frame.width))x\(Int(screen.frame.height))"
    }

    /// The screen it rests on and its spot there: where Samin left it, else the pointer's screen (DockPlacement.home).
    private func chooseScreen() {
        guard let home = DockPlacement.home(place: place, pointer: NSEvent.mouseLocation, screens: screens()) else { return }
        screen = home.screen
        spotHere = home.spot
        applyScale()
    }

    private func applyScale() {
        guard let screen else { return }
        let scale = DockMetrics.pillScale(screenWidth: screen.frame.width, zoom: zoom)
        if ui.pillScale != scale { ui.pillScale = scale }
        let panel = DockMetrics.panelScale(pillScale: scale)
        if ui.panelScale != panel { ui.panelScale = panel }
    }

    private func pillMeasured(_ measure: DockPillMeasure) {
        let rounded = CGSize(width: ceil(measure.size.width), height: ceil(measure.size.height))
        let slot = measure.slot > 0 ? ceil(measure.slot) : 0
        guard rounded.width > 0, rounded.height > 0, rounded != pillSize || slot != slotWidth else { return }
        pillSize = rounded
        slotWidth = min(slot, rounded.width - 1)
        if press == nil { placePill() }
    }

    private func listSized(_ size: CGSize) {
        let rounded = CGSize(width: ceil(size.width), height: ceil(size.height))
        guard rounded.width > 0, rounded.height > 0, rounded != listSize else { return }
        listSize = rounded
        placeList()
        if expansion.isOpen, let list, !list.isVisible { revealList() }
    }

    /// The pill's size without the "–" (before it has measured itself: a guess at the pill or the orb).
    private var restSize: CGSize {
        guard pillSize != .zero else {
            let orb = ((DockMetrics.orbBaseSize + DockMetrics.orbBadgeRoom) * ui.pillScale).rounded()
            return ui.minimized ? CGSize(width: orb, height: orb) : CGSize(width: 240, height: DockMetrics.pillBaseHeight * ui.pillScale)
        }
        return CGSize(width: pillSize.width - slotWidth, height: pillSize.height)
    }

    /// The pill window at its spot: the resting frame by its corner and gap, plus the "–" on its side.
    private func placePill() {
        guard let pill, let screen else { return }
        let rest = DockPlacement.frame(for: spotHere, size: restSize, on: screen)
        restFrame = rest
        let anchor = Self.anchor(spotHere.corner)
        if ui.pillAnchor != anchor { ui.pillAnchor = anchor }
        let frame = DockPlacement.withSlot(rest, width: slotWidth, onLeft: ui.minimizeSlot == .leading, on: screen)
        if pill.frame != frame { pill.setFrame(frame, display: true) }
        let below = DockPlacement.panelOpensBelow(pill: rest, screen: screen)
        if ui.listBelow != below { ui.listBelow = below }
        let maxHeight = DockPlacement.maxPanelHeight(pill: rest, screen: screen)
        if ui.maxPanelHeight != maxHeight { ui.maxPanelHeight = maxHeight }
        placeList()
    }

    /// The pill window's content sits against the dock's corner (the window follows a new size a moment later).
    private static func anchor(_ corner: DockCorner) -> Alignment {
        switch (corner.isTop, corner.side) {
        case (true, .left): return .topLeading
        case (true, .middle): return .top
        case (true, .right): return .topTrailing
        case (false, .left): return .bottomLeading
        case (false, .middle): return .bottom
        case (false, .right): return .bottomTrailing
        }
    }

    /// The list on the side with room, lined up with the pill's resting frame (the "–" coming and going moves nothing).
    private func placeList() {
        guard let list, pill != nil, let screen, listSize != .zero, restFrame != .zero else { return }
        let frame = DockPlacement.panelFrame(size: listSize, pill: restFrame, screen: screen)
        if list.frame != frame { list.setFrame(frame, display: true) }
    }

    private func screensChanged() {
        guard visible else { return }
        chooseScreen()
        placePill()
    }

    /// Never dragged anywhere: it follows the pointer to whichever screen it was last on (checked once a second).
    private func startFollowingPointer() {
        followTimer?.invalidate()
        followTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.followPointer() }
        }
    }

    private func followPointer() {
        guard visible, place == nil, press == nil, !expansion.isOpen, !voiceActive, !noteActive,
              let here = DockPlacement.screen(containing: NSEvent.mouseLocation, in: screens()),
              here.id != screen?.id, here.frame.contains(NSEvent.mouseLocation) else {
            otherScreenTicks = 0
            return
        }
        // Passing through another screen moves nothing; staying there for two checks does.
        otherScreenTicks += 1
        guard otherScreenTicks >= 2 else { return }
        otherScreenTicks = 0
        screen = here
        spotHere = .home
        applyScale()
        placePill()
    }

    /// ⌃⌥D on another screen: the dock comes to the one the pointer is on (its own spot there, else the same corner).
    private func bringHere() {
        guard let here = DockPlacement.screen(containing: NSEvent.mouseLocation, in: screens()) else { return }
        let moved = DockPlacement.bringing(place, current: spotHere, to: here)
        place = moved.place
        screen = here
        spotHere = moved.spot
        applyScale()
        Log.write("dock: brought to the screen the pointer is on")
        if visible { placePill() }
    }

    /// The dock is on (or would come back on) another screen than the pointer's.
    private func isElsewhere() -> Bool {
        let all = screens()
        guard let here = DockPlacement.screen(containing: NSEvent.mouseLocation, in: all) else { return false }
        let there = visible ? screen : DockPlacement.home(place: place, pointer: NSEvent.mouseLocation, screens: all)?.screen
        return there.map { $0.id != here.id } ?? false
    }

    /// The "–" while the pointer is on the pill (not the orb, not the voice bar, not while dragging), at the end away
    /// from the edge the pill is kept against; the side is chosen as it appears, so it doesn't hop under the pointer.
    private func updateMinimizeSlot() {
        let wanted = visible && overPill && !ui.minimized && !voiceActive && !noteActive && !(press?.moved ?? false)
        let slot: HorizontalEdge?
        if !wanted {
            slot = nil
        } else if let current = ui.minimizeSlot {
            slot = current
        } else if let screen {
            slot = DockPlacement.minimizeOnLeft(restFrame, on: screen) ? .leading : .trailing
        } else {
            slot = .trailing
        }
        guard slot != ui.minimizeSlot else { return }
        ui.minimizeSlot = slot
        if slot == nil, slotWidth != 0 {
            // Gone at once (the next measure agrees): the pill is back at its resting frame.
            slotWidth = 0
            pillSize = restFrame.size == .zero ? pillSize : restFrame.size
            if press == nil { placePill() }
        }
    }

    private func setZoom(_ value: Double) {
        zoom = value
        applyScale()
        Log.write("dock: size \(String(format: "%.2f", zoom))x")
    }

    // MARK: the list (open / close)

    private func send(_ event: DockExpansion.Event) {
        for effect in expansion.handle(event) {
            switch effect {
            case .scheduleOpen:
                openTimer?.invalidate()
                openTimer = Timer.scheduledTimer(withTimeInterval: DockExpansion.openDelay, repeats: false) { [weak self] _ in
                    Task { @MainActor in
                        self?.readPointer()
                        self?.send(.openTimer)
                    }
                }
            case .cancelOpen:
                openTimer?.invalidate()
            case .scheduleClose:
                closeTimer?.invalidate()
                closeTimer = Timer.scheduledTimer(withTimeInterval: DockExpansion.closeDelay, repeats: false) { [weak self] _ in
                    Task { @MainActor in
                        self?.readPointer()
                        self?.send(.closeTimer)
                    }
                }
            case .cancelClose:
                closeTimer?.invalidate()
            case .show:
                openList()
            case .hide:
                Log.write("dock: list closed (\(Self.describe(event)))")
                closeList()
            }
        }
        if ui.expanded != expansion.isOpen { ui.expanded = expansion.isOpen }
        watchPointer()
    }

    private static func describe(_ event: DockExpansion.Event) -> String {
        switch event {
        case .pointer: return "pointer left"
        case .closeTimer: return "pointer left"
        case .clickPill: return "pill clicked"
        case .escape: return "escape"
        case .clickOutside: return "click elsewhere"
        case .dragStarted: return "drag"
        case .voiceStarted: return "voice"
        case .hidden: return "dock hidden"
        default: return "\(event)"
        }
    }

    private func openList() {
        let list = listWindow()
        store.loadTargets()
        store.morning.listOpened()
        if enabled, case .offline = store.connection { store.retryNow() }
        if let row = ui.expandedRow { store.watched = row }
        if listSize != .zero { revealList() } else { list.orderOut(nil) }  // shown once it has measured itself
    }

    private func revealList() {
        guard let list, expansion.isOpen, visible else { return }
        placeList()
        list.alphaValue = 0
        list.keepKeysOnNextKey = !fieldWanted && ui.focusRequest == nil
        fieldWanted = false
        list.orderFrontRegardless()
        if listWantsKey {
            listWantsKey = false
            list.makeKey()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            list.animator().alphaValue = 1
        }
    }

    private func closeList() {
        listWantsKey = false
        fieldWanted = false
        ui.menu = nil
        ui.expandedRow = nil
        ui.focusRequest = nil
        store.watched = nil
        if let list, list.isVisible {
            list.orderOut(nil)
        }
        if summoned {
            summoned = false
            refresh()
        }
    }

    private func clickedOutside() {
        guard expansion.isOpen else { return }
        readPointer()
        send(.clickOutside)
    }

    // MARK: the pointer

    /// The pointer came onto the dock: follow the real cursor a few times a second until it has left both windows
    /// and the list is closed (a missed exit event can't leave the list open).
    private func pointerEntered() {
        readPointer()
        watchPointer()
    }

    private func watchPointer() {
        let engaged = overPill || overList || expansion.phase != .collapsed
        if engaged && pointerTimer == nil {
            pointerTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.readPointer()
                    if !(self.overPill || self.overList || self.expansion.phase != .collapsed) {
                        self.pointerTimer?.invalidate()
                        self.pointerTimer = nil
                    }
                }
            }
        }
    }

    private func readPointer() {
        guard press == nil else { return }
        let location = NSEvent.mouseLocation
        let onPill = visible && (pill?.isVisible ?? false) && (pill?.frame.contains(location) ?? false)
        let onList = (list?.isVisible ?? false) && (list?.frame.contains(location) ?? false)
        guard onPill != overPill || onList != overList else { return }
        overPill = onPill
        overList = onList
        updateZoomKeys()
        if ui.pillHover != onPill { ui.pillHover = onPill }
        updateMinimizeSlot()
        if !voiceActive && !noteActive { send(.pointer(overPill: onPill, overPanel: onList)) }
    }

    /// ⌘+ / ⌘− / ⌘0 size the dock while the pointer is on it, whichever app has the keys: Carbon hot keys (no
    /// permission), taken from the frontmost app only while Samin points at the dock and given back when he leaves.
    private func updateZoomKeys() {
        let wanted = visible && (overPill || overList)
        guard wanted == zoomKeys.isEmpty else { return }
        if wanted {
            let keys: [(Int, Int, Int)] = [(kVK_ANSI_Equal, cmdKey, 1), (kVK_ANSI_Equal, cmdKey | shiftKey, 1),
                                           (kVK_ANSI_KeypadPlus, cmdKey, 1), (kVK_ANSI_Minus, cmdKey, -1),
                                           (kVK_ANSI_KeypadMinus, cmdKey, -1), (kVK_ANSI_0, cmdKey, 0)]
            zoomKeys = keys.compactMap { code, modifiers, steps in
                DockHotKey(keyCode: code, modifiers: modifiers, name: "dock size", quiet: true) { [weak self] in
                    self?.perform(.zoom(steps))
                }
            }
        } else {
            zoomKeys.forEach { $0.unregister() }
            zoomKeys = []
        }
    }

    /// A ⌘ key while a dock window has the keys: the dock's own size keys, editing in its fields, and nothing that
    /// would run one of the app's menu items from the dock (false = the event goes no further).
    private func keepCommandKey(_ event: NSEvent) -> Bool {
        guard event.window is DockPanelWindow, event.modifierFlags.contains(.command) else { return true }
        let flags = event.modifierFlags
        switch DockCommandKey.route(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers ?? "",
                                    shift: flags.contains(.shift), control: flags.contains(.control),
                                    option: flags.contains(.option)) {
        case .zoom(let steps):
            perform(.zoom(steps))
            return false
        case .pass:
            return true
        case .swallow:
            return false
        }
    }

    // MARK: events from the windows

    /// true = handled here (the event goes no further).
    func handle(_ event: NSEvent, in window: DockPanelWindow) -> Bool {
        switch window.role {
        case .pill: return handlePill(event, window)
        case .list: return handleList(event, window)
        }
    }

    private func local(_ event: NSEvent, in window: NSWindow) -> CGPoint {
        guard let view = window.contentView else { return .zero }
        let point = view.convert(event.locationInWindow, from: nil)
        return view.isFlipped ? point : CGPoint(x: point.x, y: view.bounds.height - point.y)
    }

    private func onControl(_ point: CGPoint) -> Bool {
        pillControls.contains { $0.insetBy(dx: -2, dy: -2).contains(point) }
    }

    private func handlePill(_ event: NSEvent, _ window: DockPanelWindow) -> Bool {
        switch event.type {
        case .leftMouseDown:
            let point = local(event, in: window)
            if onControl(point) { return false }
            if event.modifierFlags.contains(.control) {
                showMenu()
                return true
            }
            // A click on the voice bar gives it the keys, so Esc ends the conversation (without bringing SamRabbit
            // forward). The bar never takes them by itself: Esc stays with the app Samin is in (a terminal's Esc
            // interrupts Claude Code). The same for a voice note's bar (Esc throws the note away, ↩ sends it).
            if (voiceActive || notes.isRecording) && !window.isKeyWindow { window.makeKey() }
            // The two ends of the pill resize it (drag up to grow); anywhere else (and anywhere on the orb) moves it.
            let grip = !voiceActive && !noteActive && !ui.minimized && (point.x < 12 || point.x > window.frame.width - 12)
            let rest = restFrame == .zero ? window.frame : restFrame
            press = Press(start: NSEvent.mouseLocation, frame: rest, grip: grip, leftGrip: point.x < 12, zoom: zoom)
            return true
        case .leftMouseDragged:
            guard var current = press else { return false }
            let location = NSEvent.mouseLocation
            let dx = location.x - current.start.x
            let dy = location.y - current.start.y
            if !current.moved && hypot(dx, dy) >= 4 {
                current.moved = true
                press = current
                ui.dragging = true
                send(.dragStarted)
                // The "–" goes while it moves: the window is the resting pill from here (set just below).
                updateMinimizeSlot()
            }
            press = current
            guard current.moved else { return true }
            if current.grip {
                let wanted = DockMetrics.zoomFromDrag(startZoom: current.zoom, startHeight: current.frame.height, up: dy,
                                                      outward: current.leftGrip ? -dx : dx)
                if wanted != zoom {
                    zoom = wanted
                    applyScale()
                }
            } else if let moved = DockPlacement.dragged(from: current.frame, dx: dx, dy: dy, pointer: location, screens: screens()) {
                if moved.screen.id != screen?.id {
                    screen = moved.screen
                    applyScale()
                }
                restFrame = moved.frame
                window.setFrame(moved.frame, display: true)
            }
            return true
        case .leftMouseUp:
            guard let done = press else { return false }
            press = nil
            if done.moved {
                ui.dragging = false
                if done.grip {
                    Log.write("dock: size \(String(format: "%.2f", zoom))x (dragged)")
                } else if let screen {
                    // Remembered as this screen's corner and gap (never as a desktop point).
                    spotHere = DockPlacement.spot(for: restFrame, on: screen)
                    place = DockPlacement.remember(spotHere, on: screen, in: place)
                    Log.write("dock: moved to \(spotHere.corner.rawValue) +\(Int(spotHere.dx)),\(Int(spotHere.dy)) of a screen")
                }
                placePill()
                send(.dragEnded)
                updateMinimizeSlot()
            } else if event.clickCount >= 2 {
                send(.escape)
                AppModel.shared.openMainWindow()
            } else if noteActive {
                // The note's bar: its buttons do the work; a click elsewhere on it does nothing.
            } else if ui.minimized && !voiceActive {
                // A click on the orb opens it into the pill (pointing at it opens the list, as on the pill).
                setMinimized(false)
            } else if !voiceActive {
                send(.clickPill)
                // The list opens with the compose field taking the keys: what Samin types becomes a new prompt, and a
                // stray letter can't act on a row. Esc leaves the field for J/K, ↩, E and R.
                if expansion.isOpen {
                    askForCompose()
                    takeKeys()
                }
            }
            return true
        case .rightMouseDown:
            showMenu()
            return true
        case .mouseMoved:
            let point = local(event, in: window)
            if !voiceActive && !noteActive && !ui.minimized && !onControl(point) && (point.x < 12 || point.x > window.frame.width - 12) {
                NSCursor.resizeUpDown.set()
            } else {
                NSCursor.arrow.set()
            }
            return false
        case .keyDown:
            if event.keyCode == 53 && voiceActive {
                voice.end()
                return true
            }
            if notes.isRecording && (event.keyCode == 53 || event.keyCode == 36 || event.keyCode == 76) {
                if event.keyCode == 53 { notes.cancel() } else { notes.send() }
                return true
            }
            return false
        default:
            return false
        }
    }

    private func handleList(_ event: NSEvent, _ window: DockPanelWindow) -> Bool {
        switch event.type {
        case .leftMouseDown, .rightMouseDown:
            send(.interact)
            return false
        case .keyDown:
            let flags = event.modifierFlags
            let editing = window.firstResponder is NSTextView
            if event.keyCode == 53 {
                if ui.menu != nil {
                    ui.menu = nil
                    return true
                }
                if voiceActive && !editing {
                    voice.end()
                    return true
                }
            }
            // ⌘ keys never get here (keepCommandKey); a field keeps every other key.
            if editing { return false }
            guard let key = DockKey.from(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers ?? "",
                                         command: flags.contains(.command), control: flags.contains(.control),
                                         option: flags.contains(.option)) else { return false }
            perform(DockKeyboard.action(for: key, rows: keyRows(), selected: ui.selected, expanded: ui.expandedRow))
            return true
        default:
            return false
        }
    }

    private func keyRows() -> [DockKeyRow] {
        DockSection.visibleIds(store.sections, earlierOpen: ui.earlierOpen).compactMap { store.item($0) }.map(DockKeyRow.init)
    }

    func perform(_ action: DockKeyAction) {
        switch action {
        case .none:
            break
        case .select(let id):
            ui.selected = id
        case .expand(let id):
            ui.selected = id
            ui.expandedRow = id
            store.watched = id
        case .collapseRow:
            ui.expandedRow = nil
            store.watched = nil
        case .open(let id):
            if let item = store.item(id) { store.open(item) }
        case .approve(let id, let requestId, let decision):
            if let item = store.item(id) { store.approve(item, requestId: requestId, decision: decision) }
        case .reply(let id):
            ui.selected = id
            ui.expandedRow = id
            store.watched = id
            ui.focusRequest = .reply(id)
        case .compose:
            ui.focusRequest = .compose
        case .collapsePanel:
            send(.escape)
        case .zoom(let steps):
            setZoom(steps == 0 ? 1 : DockMetrics.zoomStepped(zoom, by: steps))
        }
    }

    // MARK: voice

    func toggleVoice() {
        voice.toggle(reason: "button")
        // A conversation started from the dock takes the keys, so Esc ends it.
        if voice.state != .idle {
            if expansion.isOpen, let list, list.isKeyWindow { return }
            pill?.makeKey()
        }
    }

    private func voiceChanged(active: Bool) {
        guard active != voiceActive else { return }
        voiceActive = active
        if active {
            send(.voiceStarted)
        } else if let pill, pill.isKeyWindow {
            // Give the keys back to the app Samin was in.
            pill.orderOut(nil)
            if visible { pill.orderFrontRegardless() }
        }
        updateMinimizeSlot()
        refresh()
    }

    // MARK: voice notes

    /// The pill's note button and the dock's menu: start a note, or send the one recording. Started from the dock, its
    /// bar takes the keys (Esc throws it away, ↩ sends it) without bringing SamRabbit forward.
    func toggleNote() {
        notes.toggle(source: "dock")
        if notes.isRecording {
            send(.voiceStarted)
            pill?.makeKey()
        }
    }

    private func noteChanged(active: Bool) {
        guard active != noteActive else { return }
        noteActive = active
        if active {
            // Like a conversation: the list closes, the bar shows through every hide.
            send(.voiceStarted)
        } else if let pill, pill.isKeyWindow, !voiceActive {
            pill.orderOut(nil)
            if visible { pill.orderFrontRegardless() }
        }
        updateMinimizeSlot()
        refresh()
    }

    // MARK: summon, reveal, menu

    /// ⌃⌥K: show the dock with its list open and the compose field taking the keys. A dock that was turned off comes
    /// back on (⌃⌥K is "Show Agent Dock"'s shortcut); a hide for a while stays: the dock shows until the list closes.
    func summon(focusCompose: Bool) {
        guard started else { return }
        if !enabled { turnOn() }
        summoned = true
        refresh()
        send(.summon)
        if focusCompose { askForCompose() }
        takeKeys()
    }

    /// The compose field takes the keys once the list has them.
    private func askForCompose() {
        fieldWanted = true
        ui.focusRequest = .compose
    }

    /// The list takes the keys (J/K, typing) without bringing SamRabbit forward: the panel never activates the app.
    private func takeKeys() {
        if let list, list.isVisible {
            list.makeKey()
        } else {
            listWantsKey = true
        }
    }

    /// "Show Agent Dock" (menu bar extra, main menu): turns it back on, ends a hide (⌃⌥D's too), and opens it.
    func showFromMenu() {
        guard started else { return }
        if !enabled { turnOn() }
        hiddenUntil = nil
        _ = presence.handle(.showFromMenu, visibilityInput())
        savePresence()
        summon(focusCompose: false)
    }

    /// ⌃⌥D: on screen here → put away until pressed again; away (for any reason: ⌃⌥D, a hide for a while, turned
    /// off, stepped aside for the main window) → back as it was; on screen on another display → brought to this one.
    /// The hot key only: the menus use putAwayFromMenu / bringBackFromMenu, which never look at the pointer.
    func toggleShown() {
        guard started else { return }
        let effects = presence.handle(.toggleShown(elsewhere: isElsewhere()), visibilityInput())
        Log.write("dock: ⌃⌥D, " + (presence.hidden ? "put away" : effects.contains(.bringHere) ? "brought here" : "shown"))
        carry(effects)
    }

    /// "Hide Agent Dock" (the menu bar extra), "Hide the Dock" (its own menu): put away where it is, until ⌃⌥D or
    /// "Show Agent Dock". Never moved: in the menu bar extra the pointer is on the menu bar's display.
    func putAwayFromMenu() {
        guard started else { return }
        carry(presence.handle(.putAway, visibilityInput()))
        Log.write("dock: put away (menu)")
    }

    /// "Show Agent Dock" in the menu bar extra: back as it was and where it was, as ⌃⌥D brings it back (on again, a
    /// hide for a while over, over the main window), without moving it to the menu bar's display.
    func bringBackFromMenu() {
        guard started else { return }
        carry(presence.handle(.bringBack, visibilityInput()))
        Log.write("dock: shown (menu)")
    }

    /// ⌃⌥M (and "Minimize to Orb" / "Expand the Dock"): orb ↔ pill; a dock that isn't on screen comes back so (the hot
    /// key brings it to the pointer's screen; a menu item leaves it on its own).
    func toggleMinimized(fromMenu: Bool = false) {
        guard started else { return }
        let effects = presence.handle(.toggleMinimized(elsewhere: !fromMenu && isElsewhere()), visibilityInput())
        Log.write("dock: " + (presence.minimized ? "minimized to the orb" : "expanded to the pill"))
        carry(effects)
    }

    /// The "–", a click on the orb, Settings.
    func setMinimized(_ on: Bool) {
        guard started, on != presence.minimized else { return }
        _ = presence.handle(on ? .minimize : .expand, visibilityInput())
        Log.write("dock: " + (on ? "minimized to the orb" : "expanded to the pill"))
        carry([])
    }

    /// Settings (and the main window's Settings): the dock on or off (off for good, until it is turned on again). On
    /// also ends ⌃⌥D's hide and a hide for a while, even when it was never turned off: the switch then says it shows.
    func setEnabled(_ on: Bool) {
        guard started else { return }
        if on {
            guard !isOn else { return }
            if !enabled { turnOn() }
            hiddenUntil = nil
            _ = presence.handle(.showFromMenu, visibilityInput())
            savePresence()
            refresh()
        } else if enabled {
            turnOff()
        }
    }

    /// "Agent Dock Settings…" (the dock's menu, the menu bar extra): the shortcuts, the dock on/off and the orb.
    func openSettings() {
        send(.escape)
        DockSettingsWindowController.shared.show()
    }

    /// What DockPresence asked for, then the windows again.
    private func carry(_ effects: [DockPresence.Effect]) {
        for effect in effects {
            switch effect {
            case .turnOn: if !enabled { turnOn() }
            case .endHide: hiddenUntil = nil
            case .bringHere: bringHere()
            case .closeList:
                summoned = false
                send(.escape)
            }
        }
        savePresence()
        updateMinimizeSlot()
        refresh()
        if visible { placePill() }
    }

    private func turnOn() {
        enabled = true
        Log.write("dock: turned on")
        store.start()
    }

    /// A notification was clicked: open the list on that item (not while the dock is turned off: its list is stale).
    func reveal(_ id: String) {
        guard started else { return }
        guard enabled else {
            Log.write("dock: off, a notification click opens nothing")
            return
        }
        summoned = true
        refresh()
        send(.summon)
        ui.selected = id
        ui.expandedRow = id
        store.watched = id
    }

    func hide(for choice: DockVisibility.HideChoice) {
        hiddenUntil = DockVisibility.hiddenUntil(choice, now: Date())
        summoned = false
        send(.escape)
        Log.write("dock: hidden for a while (\(choice.rawValue))")
        refresh()
    }

    private func turnOff() {
        enabled = false
        summoned = false
        send(.escape)
        store.stop()
        Log.write("dock: turned off (Show Agent Dock turns it back on)")
        refresh()
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(DockMenuItem("Open SamRabbit") { AppModel.shared.openMainWindow() })
        menu.addItem(.separator())
        menu.addItem(DockMenuItem(presence.minimized ? "Expand the Dock" : "Minimize to Orb",
                                  shortcut: shortcuts.working(.minimize)) { [weak self] in self?.toggleMinimized(fromMenu: true) })
        menu.addItem(DockMenuItem("Hide the Dock", shortcut: shortcuts.working(.showHide)) { [weak self] in self?.putAwayFromMenu() })
        for choice in DockVisibility.HideChoice.allCases {
            menu.addItem(DockMenuItem(choice.label) { [weak self] in self?.hide(for: choice) })
        }
        menu.addItem(DockMenuItem("Turn Off the Dock") { [weak self] in self?.turnOff() })
        menu.addItem(.separator())
        menu.addItem(DockMenuItem(voice.state == .idle || voice.isShowingError ? "Talk to SamRabbit" : "End Conversation",
                                  shortcut: shortcuts.working(.talk)) { [weak self] in self?.toggleVoice() })
        menu.addItem(DockMenuItem(notes.isRecording ? "Send Voice Note" : "Voice Note", shortcut: shortcuts.working(.voiceNote)) { [weak self] in
            self?.toggleNote()
        })
        menu.addItem(DockMenuItem("New Task", shortcut: shortcuts.working(.compose)) { [weak self] in
            self?.summon(focusCompose: true)
        })
        menu.addItem(DockMenuItem("Always Listen for “Hey Rabbit”", state: voice.wakeEnabled ? .on : .off) { [weak self] in
            guard let self else { return }
            self.voice.wakeEnabled.toggle()
        })
        if let problem = voice.wakeProblem, voice.wakeEnabled {
            menu.addItem(DockMenuItem("“Hey Rabbit”: \(problem)", enabled: false))
        }
        // A shortcut the system refused is said, not shown as if it worked.
        for action in DockShortcutAction.allCases {
            if let problem = shortcuts.unavailable[action] {
                menu.addItem(DockMenuItem("\(shortcuts.shortcut(action).display) (\(action.label)): \(problem)", enabled: false))
            }
        }
        menu.addItem(DockMenuItem("Shortcuts & Settings…") { [weak self] in self?.openSettings() })
        menu.addItem(.separator())
        menu.addItem(DockMenuItem("Bigger") { [weak self] in
            guard let self else { return }
            self.setZoom(DockMetrics.zoomStepped(self.zoom, by: 1))
        })
        menu.addItem(DockMenuItem("Smaller") { [weak self] in
            guard let self else { return }
            self.setZoom(DockMetrics.zoomStepped(self.zoom, by: -1))
        })
        if zoom != 1 { menu.addItem(DockMenuItem("Default Size") { [weak self] in self?.setZoom(1) }) }
        if place != nil {
            menu.addItem(DockMenuItem("Move Back to the Middle") { [weak self] in
                guard let self else { return }
                // Forgotten on every screen: the bottom middle of the pointer's screen, following it again.
                self.place = nil
                self.chooseScreen()
                self.placePill()
                Log.write("dock: back to the middle")
            })
        }
        guard let view = pill?.contentView else { return }
        let point = view.convert(pill?.convertPoint(fromScreen: NSEvent.mouseLocation) ?? .zero, from: nil)
        menu.popUp(positioning: nil, at: point, in: view)
    }

    // MARK: notifications

    private func announce(_ items: [DockItem]) {
        // Samin is looking at the list already.
        guard !(expansion.isOpen && visible) else { return }
        for item in items.prefix(3) {
            let title: String
            switch item.status {
            case .needsApproval: title = "Needs your approval"
            case .needsInput: title = "Has a question for you"
            case .error: title = "Something failed"
            default: title = "Finished"
            }
            let who = DockText.meta(item.project, item.isChat ? nil : item.agentLabel)
            let body = item.summary.isEmpty ? item.statusLabel : item.summary
            AppModel.shared.notifier.inboxItem(id: item.id, title: who.isEmpty ? title : "\(title) · \(who)",
                                               subtitle: item.title, body: body)
        }
    }
}
