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
        becomesKeyOnlyIfNeeded = true
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

    init(_ title: String, key: String = "", state: NSControl.StateValue = .off, enabled: Bool = true, handler: @escaping () -> Void = {}) {
        self.handler = handler
        super.init(title: title, action: enabled ? #selector(run) : nil, keyEquivalent: key)
        target = self
        self.state = state
        isEnabled = enabled
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func run() { handler() }
}

/// The Agent Dock: a floating glass pill at the bottom of the screen with the agents that are waiting for Samin
/// (T3 Code threads, Claude Code and Codex sessions, SamRabbit chats), a list that opens above it with inline
/// approve / answer / reply / stop / open, a compose bar for a new prompt, and the voice bar during a conversation.
/// It shows whenever the main window is minimised, closed or hidden, or another app is in front, and steps aside while
/// Samin is in the main window. See CONTRACTS-WAVE6 §B; the rules live in DockVisibility / DockPlacement /
/// DockKeyboard (unit-tested), this class wires them to AppKit.
@MainActor
final class DockController: NSObject {
    static let shared = DockController()

    let store = DockStore()
    let ui = DockUIState()
    private let voice = MacVoice.shared
    private let render = DockRender(glass: DockRender.liveGlass())
    private(set) var pill: DockPanelWindow?
    private(set) var list: DockPanelWindow?
    private var expansion = DockExpansion()
    private var openTimer: Timer?
    private var closeTimer: Timer?
    private var pointerTimer: Timer?
    private var followTimer: Timer?
    private var unhideTimer: Timer?
    private var hotKey: DockHotKey?
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var voiceSubscription: AnyCancellable?
    private var started = false
    private var visible = false
    private var summoned = false
    private var voiceActive = false
    private var lastReason: DockVisibility.Reason?
    private var screen: DockScreen?
    private var fraction = 0.5
    private var pillSize = CGSize.zero
    private var listSize = CGSize.zero
    private var pillControls: [CGRect] = []
    private var overPill = false
    private var overList = false
    /// The list should take the keys as soon as it is on screen (⌃⌥K, a click on the pill).
    private var listWantsKey = false

    private struct Press {
        var start: CGPoint
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
        static let spot = "AgentDockSpot"
        static let zoom = "AgentDockZoom"
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

    private var spot: DockSpot? {
        get { UserDefaults.standard.data(forKey: Key.spot).flatMap { try? JSONDecoder().decode(DockSpot.self, from: $0) } }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(data, forKey: Key.spot) }
            else { UserDefaults.standard.removeObject(forKey: Key.spot) }
        }
    }

    private var zoom: Double {
        get { DockMetrics.zoom(UserDefaults.standard.object(forKey: Key.zoom) as? Double) }
        set { UserDefaults.standard.set(DockMetrics.zoom(newValue), forKey: Key.zoom) }
    }

    var isEnabled: Bool { enabled }

    /// Dev runs: forget a hide (the smoke driver hides it once and puts it back).
    func clearHide() {
        hiddenUntil = nil
        refresh()
    }

    // MARK: start

    func start() {
        guard !started else { return }
        started = true
        store.onAnnounce = { [weak self] items in self?.announce(items) }
        store.onOpenConversation = { id in AppModel.shared.openMainWindow(conversation: id) }
        AppModel.shared.notifier.onOpenInboxItem = { [weak self] id in self?.reveal(id) }

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
        hotKey = DockHotKey(keyCode: kVK_ANSI_K, modifiers: controlKey | optionKey, name: "⌃⌥K") { [weak self] in
            self?.summon(focusCompose: true)
        }
        Log.write("dock: \(enabled ? "on" : "off") (glass \(render.glass.rawValue))")
        if enabled { store.start() }
        refresh()
        if let directory = ProcessInfo.processInfo.environment["SAMRABBIT_DOCK_SMOKE"] { DockSmoke.run(self, directory: directory) }
    }

    // MARK: visibility

    func refresh() {
        guard started else { return }
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
        input.summoned = summoned
        let reason = DockVisibility.reason(input)
        if reason != lastReason {
            Log.write("dock: \(DockVisibility.shows(input) ? "shown" : "hidden") (\(reason.rawValue))")
            lastReason = reason
        }
        if DockVisibility.shows(input) { show() } else { hide() }
        scheduleUnhide()
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
        send(.hidden)
        followTimer?.invalidate()
        pointerTimer?.invalidate()
        pointerTimer = nil
        overPill = false
        overList = false
        ui.pillHover = false
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
        openItem: { [weak self] item in self?.store.open(item) })

    private func pillWindow() -> DockPanelWindow {
        if let pill { return pill }
        let window = DockPanelWindow(role: .pill)
        window.controller = self
        let root = DockPillRoot(store: store, ui: ui, voice: voice, commands: commands, render: render,
                                onSize: { [weak self] size in self?.pillSized(size) },
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
        let root = DockPanelRoot(store: store, ui: ui, voice: voice, commands: commands, render: render,
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

    /// The screen it rests on: where Samin left it, else the one the pointer is on.
    private func chooseScreen() {
        guard let home = DockPlacement.home(spot: spot, pointer: NSEvent.mouseLocation, screens: screens()) else { return }
        screen = home.screen
        fraction = home.xFraction
        applyScale()
    }

    private func applyScale() {
        guard let screen else { return }
        let scale = DockMetrics.pillScale(screenWidth: screen.frame.width, zoom: zoom)
        if ui.pillScale != scale { ui.pillScale = scale }
        let panel = DockMetrics.panelScale(pillScale: scale)
        if ui.panelScale != panel { ui.panelScale = panel }
    }

    private func pillSized(_ size: CGSize) {
        let rounded = CGSize(width: ceil(size.width), height: ceil(size.height))
        guard rounded.width > 0, rounded.height > 0, rounded != pillSize else { return }
        pillSize = rounded
        if press == nil { placePill() }
    }

    private func listSized(_ size: CGSize) {
        let rounded = CGSize(width: ceil(size.width), height: ceil(size.height))
        guard rounded.width > 0, rounded.height > 0, rounded != listSize else { return }
        listSize = rounded
        placeList()
        if expansion.isOpen, let list, !list.isVisible { revealList() }
    }

    private func placePill() {
        guard let pill, let screen else { return }
        let size = pillSize == .zero ? CGSize(width: 240, height: DockMetrics.pillBaseHeight * ui.pillScale) : pillSize
        let frame = DockPlacement.pillFrame(size: size, screen: screen, xFraction: fraction)
        if pill.frame != frame { pill.setFrame(frame, display: true) }
        let maxHeight = DockPlacement.maxPanelHeight(pill: frame, screen: screen)
        if ui.maxPanelHeight != maxHeight { ui.maxPanelHeight = maxHeight }
        placeList()
    }

    private func placeList() {
        guard let list, let pill, let screen, listSize != .zero else { return }
        let frame = DockPlacement.panelFrame(size: listSize, pill: pill.frame, screen: screen)
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
        guard visible, spot == nil, press == nil, !expansion.isOpen, !voiceActive,
              let here = DockPlacement.screen(containing: NSEvent.mouseLocation, in: screens()),
              here.id != screen?.id, here.frame.contains(NSEvent.mouseLocation) else { return }
        screen = here
        fraction = 0.5
        applyScale()
        placePill()
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
                closeList()
            }
        }
        if ui.expanded != expansion.isOpen { ui.expanded = expansion.isOpen }
        watchPointer()
    }

    private func openList() {
        let list = listWindow()
        store.loadTargets()
        if case .offline = store.connection { store.retryNow() }
        if let row = ui.expandedRow { store.watched = row }
        if listSize != .zero { revealList() } else { list.orderOut(nil) }  // shown once it has measured itself
    }

    private func revealList() {
        guard let list, expansion.isOpen, visible else { return }
        placeList()
        list.alphaValue = 0
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
        if ui.pillHover != onPill { ui.pillHover = onPill }
        if !voiceActive { send(.pointer(overPill: onPill, overPanel: onList)) }
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
            // The two ends of the pill resize it (drag up to grow); anywhere else drags it along the bottom.
            let grip = !voiceActive && (point.x < 12 || point.x > window.frame.width - 12)
            press = Press(start: NSEvent.mouseLocation, frame: window.frame, grip: grip, leftGrip: point.x < 12, zoom: zoom)
            return true
        case .leftMouseDragged:
            guard var current = press else { return false }
            let location = NSEvent.mouseLocation
            let dx = location.x - current.start.x
            let dy = location.y - current.start.y
            if !current.moved && hypot(dx, dy) >= 4 {
                current.moved = true
                ui.dragging = true
                send(.dragStarted)
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
            } else if let moved = DockPlacement.dragged(from: current.frame, dx: dx, pointer: location, screens: screens()) {
                if moved.screen.id != screen?.id {
                    screen = moved.screen
                    applyScale()
                }
                window.setFrame(moved.frame, display: true)
                if let screen { fraction = DockPlacement.fraction(of: moved.frame, on: screen) }
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
                    spot = DockSpot(screenId: screen.id, xFraction: fraction)
                    Log.write("dock: moved to \(Int((fraction * 100).rounded()))% of a screen")
                }
                placePill()
                send(.dragEnded)
            } else if event.clickCount >= 2 {
                send(.escape)
                AppModel.shared.openMainWindow()
            } else if !voiceActive {
                send(.clickPill)
                if expansion.isOpen { takeKeys() }
            }
            return true
        case .rightMouseDown:
            showMenu()
            return true
        case .mouseMoved:
            let point = local(event, in: window)
            if !voiceActive && !onControl(point) && (point.x < 12 || point.x > window.frame.width - 12) {
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
            if editing && !flags.contains(.command) { return false }
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
        refresh()
    }

    // MARK: summon, reveal, menu

    /// ⌃⌥K: show the dock with its list open and the compose field taking the keys.
    func summon(focusCompose: Bool) {
        guard started else { return }
        summoned = true
        refresh()
        send(.summon)
        if focusCompose { ui.focusRequest = .compose }
        takeKeys()
    }

    /// The list takes the keys (J/K, typing) without bringing SamRabbit forward: the panel never activates the app.
    private func takeKeys() {
        if let list, list.isVisible {
            list.makeKey()
        } else {
            listWantsKey = true
        }
    }

    /// "Show Agent Dock" (menu bar extra, main menu): turns it back on, ends a hide, and opens it.
    func showFromMenu() {
        guard started else { return }
        let wasOff = !enabled
        enabled = true
        hiddenUntil = nil
        if wasOff {
            Log.write("dock: turned on")
            store.start()
        }
        summon(focusCompose: false)
    }

    /// A notification was clicked: open the list on that item.
    func reveal(_ id: String) {
        guard started else { return }
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
        for choice in DockVisibility.HideChoice.allCases {
            menu.addItem(DockMenuItem(choice.label) { [weak self] in self?.hide(for: choice) })
        }
        menu.addItem(DockMenuItem("Turn Off the Dock") { [weak self] in self?.turnOff() })
        menu.addItem(.separator())
        menu.addItem(DockMenuItem("Always Listen for “Hey Rabbit”", state: voice.wakeEnabled ? .on : .off) { [weak self] in
            guard let self else { return }
            self.voice.wakeEnabled.toggle()
        })
        menu.addItem(DockMenuItem("Voice Shortcut: \(voice.shortcutDescription)", enabled: false))
        menu.addItem(DockMenuItem("Open the Dock: ⌃⌥K", enabled: false))
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
        if spot != nil {
            menu.addItem(DockMenuItem("Move Back to the Middle") { [weak self] in
                guard let self else { return }
                self.spot = nil
                self.fraction = 0.5
                self.chooseScreen()
                self.placePill()
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
