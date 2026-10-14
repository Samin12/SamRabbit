import AppKit
import SwiftUI

/// "Agent Dock Settings…" (the dock's menu, the menu bar extra): the four shortcuts, each recorded anew with a click
/// (the next key combination is the shortcut; Esc cancels), with why one can't be used or isn't available; and the
/// dock itself on or off, and folded to the orb. While a shortcut is being recorded none of the four is registered
/// (DockShortcutCenter.pause), so the keys reach the recorder and ⌃⌥Space can't start a conversation meanwhile;
/// leaving the window (or closing it) ends the recording and gives them back.
@MainActor
final class DockSettingsModel: ObservableObject {
    struct Note: Equatable {
        var text: String
        var isError: Bool
    }

    @Published private(set) var recording: DockShortcutAction?
    /// The modifiers held while recording ("⌃⌥"), so Samin sees his keys land.
    @Published private(set) var held = ""
    /// What happened to the last recording of each action: why it was refused, or "Saved".
    @Published private(set) var notes: [DockShortcutAction: Note] = [:]
    @Published private(set) var dockOn = true
    @Published private(set) var minimized = false

    let center: DockShortcutCenter
    private let live: Bool
    private var monitor: Any?
    private var noteTasks: [DockShortcutAction: Task<Void, Never>] = [:]

    init() {
        center = DockShortcutCenter.shared
        live = true
    }

    /// Snapshots: a fixed state, nothing recorded or changed.
    init(fixture center: DockShortcutCenter, recording: DockShortcutAction?, held: String,
         notes: [DockShortcutAction: Note], dockOn: Bool, minimized: Bool) {
        self.center = center
        self.recording = recording
        self.held = held
        self.notes = notes
        self.dockOn = dockOn
        self.minimized = minimized
        live = false
    }

    /// The window came up: read the dock's switches again (the menus may have changed them).
    func reload() {
        guard live else { return }
        dockOn = DockController.shared.isEnabled
        minimized = DockController.shared.isMinimized
    }

    func setDockOn(_ on: Bool) {
        guard live else { return }
        DockController.shared.setEnabled(on)
        reload()
    }

    func setMinimized(_ on: Bool) {
        guard live else { return }
        DockController.shared.setMinimized(on)
        reload()
    }

    // MARK: recording

    func toggleRecording(_ action: DockShortcutAction) {
        recording == action ? finish(nil) : start(action)
    }

    private func start(_ action: DockShortcutAction) {
        guard live else { return }
        if recording != nil { finish(nil) }
        recording = action
        held = ""
        notes[action] = nil
        center.pause()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            let taken = MainActor.assumeIsolated { self?.recorded(event) ?? false }
            return taken ? nil : event
        }
        Log.write("settings: recording a shortcut (\(action.rawValue))")
    }

    /// Esc, the window going away, another click on the same recorder.
    func cancelRecording() {
        if recording != nil { finish(nil) }
    }

    /// true = the recorder took the key (it goes no further: ⌘Q is recorded, not quitting).
    private func recorded(_ event: NSEvent) -> Bool {
        guard recording != nil else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.type == .flagsChanged {
            held = DockShortcut.glyphs(modifierFlags: flags.rawValue)
            return true
        }
        // A key held down repeats: the first press was the shortcut.
        if event.isARepeat { return true }
        if event.keyCode == UInt16(DockKeys.escape) && flags.intersection([.control, .option, .shift, .command]).isEmpty {
            finish(nil)
            return true
        }
        finish(DockShortcut.from(keyCode: event.keyCode, modifierFlags: flags.rawValue))
        return true
    }

    private func finish(_ shortcut: DockShortcut?) {
        guard let action = recording else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
        held = ""
        center.resume()
        guard let shortcut else { return }
        show(center.set(action, to: shortcut), for: action)
    }

    func reset(_ action: DockShortcutAction) {
        guard live else { return }
        cancelRecording()
        show(center.reset(action), for: action)
    }

    private func show(_ outcome: DockShortcutCenter.Outcome, for action: DockShortcutAction) {
        noteTasks[action]?.cancel()
        switch outcome {
        case .unchanged:
            notes[action] = nil
        case .saved:
            notes[action] = Note(text: "Saved", isError: false)
            // "Saved" is a moment's confirmation; a refusal stays until the next try.
            noteTasks[action] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2.5))
                guard !Task.isCancelled else { return }
                if self?.notes[action]?.isError == false { self?.notes[action] = nil }
            }
        case .invalid(let text), .refused(let text):
            notes[action] = Note(text: text, isError: true)
        }
    }
}

struct DockSettingsView: View {
    @ObservedObject var model: DockSettingsModel
    @ObservedObject var center: DockShortcutCenter

    init(model: DockSettingsModel) {
        self.model = model
        center = model.center
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("Shortcuts")
                VStack(spacing: 0) {
                    ForEach(Array(DockShortcutAction.allCases.enumerated()), id: \.element) { index, action in
                        if index > 0 { Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1).padding(.leading, 16) }
                        row(action)
                    }
                }
                .background(card)
                Text("Click a shortcut, then press the new keys (Esc cancels). They work from any app, with no "
                     + "Accessibility permission; one another app already has can’t be used.")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("Dock")
                VStack(spacing: 0) {
                    switchRow("Show the Agent Dock",
                              detail: "Off until \(center.shortcut(.showHide).display) or “Show Agent Dock” brings it back.",
                              on: model.dockOn) { model.setDockOn(!model.dockOn) }
                    Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1).padding(.leading, 16)
                    switchRow("Minimized to the orb", detail: "Just the orb and a count of what needs you.",
                              on: model.minimized) { model.setMinimized(!model.minimized) }
                }
                .background(card)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 34)
        .padding(.bottom, 22)
        .frame(width: 470, alignment: .topLeading)
        .background(LinearGradient(colors: [Palette.backgroundTop, Palette.background], startPoint: .top, endPoint: .bottom))
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(spacing: 12) {
            DockOrbMark(size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text("Agent Dock").font(.system(size: 19, weight: .semibold)).foregroundStyle(Palette.ink)
                Text("Move it anywhere by dragging; it remembers each screen’s corner.")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 0)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .textCase(.uppercase)
            .kerning(0.7)
            .foregroundStyle(Palette.muted)
            .padding(.horizontal, 4)
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.045))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }

    private func row(_ action: DockShortcutAction) -> some View {
        let shortcut = center.shortcut(action)
        let recording = model.recording == action
        let unavailable = center.unavailable[action]
        let note = model.notes[action]
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(action.label).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.ink)
                    Text(action.detail).font(.system(size: 11)).foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if shortcut != action.defaultShortcut && !recording {
                    DockSettingsIconButton(symbol: "arrow.counterclockwise", help: "Back to \(action.defaultShortcut.display)") {
                        model.reset(action)
                    }
                }
                DockShortcutRecorder(text: recording ? (model.held.isEmpty ? "Type the shortcut…" : model.held + "…") : shortcut.display,
                                     recording: recording, dimmed: unavailable != nil && !recording) {
                    model.toggleRecording(action)
                }
            }
            if recording {
                line("Press the new keys now · Esc cancels", color: Palette.pale, symbol: "keyboard")
            } else if let note {
                line(note.text, color: note.isError ? DockPalette.error : Palette.pale,
                     symbol: note.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            } else if let unavailable {
                line("\(shortcut.display): \(unavailable)", color: DockPalette.error, symbol: "exclamationmark.triangle.fill")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private func line(_ text: String, color: Color, symbol: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
            Text(text).font(.system(size: 11.5, weight: .medium)).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(color)
    }

    private func switchRow(_ title: String, detail: String, on: Bool, toggle: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.ink)
                Text(detail).font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 8)
            DockSwitch(on: on, action: toggle)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}

/// The recorder: a keycap-like capsule with the shortcut; while recording it glows in the orb's blue.
struct DockShortcutRecorder: View {
    let text: String
    let recording: Bool
    var dimmed = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(recording ? Palette.pale : (dimmed ? Palette.muted : Palette.ink))
                .strikethrough(dimmed, color: Palette.muted)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(minWidth: 96, minHeight: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(recording ? Palette.orb.opacity(0.18) : Color.white.opacity(hover ? 0.12 : 0.08)))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(recording ? Palette.orb : Color.white.opacity(0.12), lineWidth: recording ? 1.5 : 1))
                .shadow(color: recording ? Palette.orb.opacity(0.45) : .clear, radius: 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(recording ? "Press the new shortcut (Esc cancels)" : "Click to record a new shortcut")
    }
}

/// A switch drawn like the dock's controls (an AppKit switch would draw as a placeholder in the snapshots).
struct DockSwitch: View {
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: on ? .trailing : .leading) {
                Capsule().fill(on ? Palette.orb : Color.white.opacity(0.14))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(on ? 0.22 : 0.1), lineWidth: 1))
                Circle().fill(Color.white).frame(width: 18, height: 18).padding(2)
                    .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
            }
            .frame(width: 38, height: 22)
            .contentShape(Capsule())
            .animation(.easeOut(duration: 0.15), value: on)
        }
        .buttonStyle(.plain)
        .accessibilityValue(on ? "on" : "off")
    }
}

struct DockSettingsIconButton: View {
    let symbol: String
    var help = ""
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hover ? Palette.ink : Palette.muted)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.white.opacity(hover ? 0.1 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

@MainActor
final class DockSettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = DockSettingsWindowController()
    let model = DockSettingsModel()

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 560),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Agent Dock Settings"
        // The sheet's own header names it; the title stays for the Window menu and VoiceOver.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(srgbRed: 9 / 255, green: 11 / 255, blue: 16 / 255, alpha: 1)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.delegate = self
        let hosting = NSHostingView(rootView: DockSettingsView(model: model))
        hosting.sizingOptions = [.intrinsicContentSize]
        window.contentView = hosting
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        guard let window else { return }
        model.reload()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // A recording never outlives the window having the keys: the shortcuts come back.
    func windowDidResignKey(_ notification: Notification) { model.cancelRecording() }

    func windowWillClose(_ notification: Notification) { model.cancelRecording() }
}
