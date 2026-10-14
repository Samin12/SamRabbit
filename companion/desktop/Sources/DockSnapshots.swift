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
        // 19–21, the voice note's bar and the Morning section (CONTRACTS-WAVE8 §D1, §D2): their own function below.
        guard notesAndMorning(to: out, fixture: fixture, backdrop: wallpaper, idleVoice: idleVoice) else { return 1 }

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
        // 12. Minimized to the orb: needs you (with "Hey Rabbit" armed), pointed at, only working, all clear without the
        //     wake phrase, offline, many waiting, and on a 3200 pt screen.
        do {
            let (needs, plain) = fixture.make()
            let (_, hovered) = fixture.make()
            hovered.pillHover = true
            let working = fixture.make(keep: { $0.status == .working }).0
            let clear = fixture.make(keep: { _ in false }).0
            let offline = fixture.make(connection: .offline(0)).0
            // The bridge counts more than the list carries: 12 in all.
            var crowded = fixture.inbox
            crowded.counts = DockCounts(needsYou: 12, working: crowded.counts.working, total: crowded.items.count + 12)
            let many = Fixture(inbox: crowded, details: fixture.details, targets: fixture.targets, now: fixture.now).make().0
            let (_, big) = fixture.make()
            big.pillScale = DockMetrics.pillScale(screenWidth: 3200, zoom: 1)
            let quiet = DockVoiceSnapshot(phase: .idle, wakeArmed: false)
            let orbs: [(String, DockStore, DockUIState, DockVoiceSnapshot)] = [
                ("\(needs.needsYouCount) need you · “Hey Rabbit” on", needs, plain, idleVoice), ("pointed at", needs, hovered, idleVoice),
                ("\(working.workingCount) working only", working, plain, idleVoice), ("all clear · no wake", clear, plain, quiet),
                ("bridge offline", offline, plain, quiet), ("\(many.needsYouCount) need you", many, plain, idleVoice),
                ("3200 pt screen", needs, big, idleVoice),
            ]
            save("dock-12-orb.png", CGSize(width: 860, height: 230), HStack(alignment: .bottom, spacing: 30) {
                ForEach(Array(orbs.enumerated()), id: \.offset) { _, orb in
                    VStack(spacing: 12) {
                        DockOrb(store: orb.1, ui: orb.2, voice: orb.3).fixedSize()
                        caption(orb.0)
                    }
                }
            }.padding(.bottom, 30))
        }
        // 13. The "–" that appears on the pill while it is pointed at: at the far end from the edge the pill is kept
        //     against (right of a pill on the left half or in the middle, left of one on the right), and the orb it
        //     folds into.
        do {
            let (store, ui) = fixture.make()
            ui.pillHover = true
            ui.minimizeSlot = .trailing
            let (_, leading) = fixture.make()
            leading.pillHover = true
            leading.minimizeSlot = .leading
            let (_, orbUI) = fixture.make()
            save("dock-13-minimize.png", CGSize(width: 760, height: 380), VStack(spacing: 18) {
                HStack(spacing: 14) {
                    DockPill(store: store, ui: ui, voice: idleVoice, commands: DockCommands()).fixedSize()
                    caption("left half or middle")
                }
                HStack(spacing: 14) {
                    caption("right half")
                    DockPill(store: store, ui: leading, voice: idleVoice, commands: DockCommands()).fixedSize()
                }
                HStack(spacing: 14) {
                    Image(systemName: "arrow.down").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.white.opacity(0.7))
                    DockOrb(store: store, ui: orbUI, voice: idleVoice).fixedSize()
                    caption("click → the pill again")
                }
            }.padding(.bottom, 30))
        }
        // 14–15. On a screen, placed by DockPlacement: dragged up to the top-left (the list opens below it, its left
        //        edge lined up), and minimized in the bottom-right corner (the list opens above it, right edges lined up).
        do {
            let size = CGSize(width: 1180, height: 980)
            let topLeft = DockSpot(corner: .topLeft, dx: DockMetrics.edgeGap, dy: DockMetrics.edgeGap)
            save("dock-14-top-left.png", size,
                 onScreen(fixture, size: size, spot: topLeft, minimized: false, open: nil, backdrop: wallpaper))
            let corner = DockSpot(corner: .bottomRight, dx: DockMetrics.edgeGap, dy: DockMetrics.bottomGap)
            save("dock-15-orb-corner.png", size,
                 onScreen(fixture, size: size, spot: corner, minimized: true, open: nil, backdrop: wallpaper))
        }
        // 16–18. Settings: the four shortcuts (one recorded anew, one another app has), the dock's switches; recording
        //        one, with why the last try couldn't be used; and recording after a combination that went to another
        //        app (nothing came with ⌃⌥), with ⌃ alone refused, while the dock is put away (its switch off).
        do {
            var bindings = DockShortcuts.defaults
            bindings[.minimize] = DockShortcut(keyCode: 31, modifiers: DockShortcut.control | DockShortcut.option)
            let center = DockShortcutCenter(fixture: bindings, unavailable: [.showHide: DockShortcutCenter.takenMessage])
            let rest = DockSettingsModel(fixture: center, recording: nil, held: "",
                                         notes: [.minimize: .init(text: "Saved", isError: false)], dockOn: true, minimized: false)
            let recording = DockSettingsModel(fixture: center, recording: .talk, held: "⌃⌥",
                                              notes: [.compose: .init(text: "⇧⌘4 is macOS’s shortcut for screenshots.", isError: true)],
                                              dockOn: true, minimized: true)
            let missed = DockSettingsModel(fixture: center, recording: .showHide, held: "",
                                           missed: DockSettingsModel.missedMessage("⌃⌥"),
                                           notes: [.minimize: .init(text: "⌃ alone is a terminal’s key (⌃C stops a command, ⌃D ends input): add ⌥ or ⌘.",
                                                                    isError: true)],
                                           dockOn: false, minimized: false)
            for (model, name) in [(rest, "dock-16-settings.png"), (recording, "dock-17-settings-recording.png"),
                                  (missed, "dock-18-settings-missed.png")] {
                let sheet = settingsSheet(model)
                let measured = measure(sheet)
                let canvas = CGSize(width: measured.width + 120, height: measured.height + 120)
                save(name, canvas, VStack { sheet }.frame(width: canvas.width, height: canvas.height))
            }
        }
        for path in written { print(path) }
        return written.count == 18 ? 0 : 1
    }

    /// A small label under a state (dev snapshots only).
    private static func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.85))
            .shadow(color: .black.opacity(0.6), radius: 2)
            .fixedSize()
    }

    /// What a view measures at its own size (an NSHostingView that is never in a window).
    private static func measure(_ view: some View) -> CGSize {
        let hosting = NSHostingView(rootView: view.fixedSize().environment(\.colorScheme, .dark))
        let size = hosting.fittingSize
        return CGSize(width: ceil(size.width), height: ceil(size.height))
    }

    /// The dock on a screen the size of the canvas (a menu bar at the top, a Dock at the bottom): placed at `spot` by
    /// DockPlacement, as the pill or the orb, with its list (and `open`'s row open) on the side DockPlacement picks.
    private static func onScreen(_ fixture: Fixture, size: CGSize, spot: DockSpot, minimized: Bool, open: String?,
                                 backdrop: NSImage) -> some View {
        let menuBar: CGFloat = 26
        let dockBar: CGFloat = 70
        let screen = DockScreen(id: "snapshot", frame: CGRect(origin: .zero, size: size),
                                visibleFrame: CGRect(x: 0, y: dockBar, width: size.width, height: size.height - menuBar - dockBar))
        let (store, ui) = fixture.make()
        let voice = DockVoiceSnapshot(phase: .idle, wakeArmed: true)
        ui.minimized = minimized
        let pill: AnyView = minimized ? AnyView(DockOrb(store: store, ui: ui, voice: voice))
            : AnyView(DockPill(store: store, ui: ui, voice: voice, commands: DockCommands()))
        let pillFrame = DockPlacement.frame(for: spot, size: measure(pill), on: screen)
        ui.expanded = true
        ui.listBelow = DockPlacement.panelOpensBelow(pill: pillFrame, screen: screen)
        ui.maxPanelHeight = DockPlacement.maxPanelHeight(pill: pillFrame, screen: screen)
        ui.selected = open ?? store.items.first?.id
        ui.expandedRow = open
        let panel = DockPanel(store: store, ui: ui, voice: voice, commands: DockCommands())
        let listFrame = DockPlacement.panelFrame(size: measure(panel), pill: pillFrame, screen: screen)
        func top(_ frame: CGRect) -> CGFloat { size.height - frame.maxY }
        return ZStack(alignment: .topLeading) {
            fakeMenuBar(width: size.width, height: menuBar)
            fakeDock(width: 560, height: dockBar - 14)
                .padding(.leading, (size.width - 560) / 2)
                .padding(.top, size.height - dockBar + 7)
            panel.fixedSize()
                .frame(width: listFrame.width, height: listFrame.height, alignment: ui.listBelow ? .top : .bottom)
                .clipped()
                .padding(.leading, listFrame.minX)
                .padding(.top, top(listFrame))
            pill.fixedSize()
                .padding(.leading, pillFrame.minX)
                .padding(.top, top(pillFrame))
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private static func fakeMenuBar(width: CGFloat, height: CGFloat) -> some View {
        HStack(spacing: 18) {
            Image(systemName: "apple.logo").font(.system(size: 13, weight: .semibold))
            Text("Ghostty").font(.system(size: 13, weight: .bold))
            ForEach(["File", "Edit", "View", "Window", "Help"], id: \.self) { Text($0).font(.system(size: 13)) }
            Spacer()
            Text("Wed 14 Oct  9:41").font(.system(size: 13, weight: .medium))
        }
        .foregroundStyle(Color.white.opacity(0.92))
        .padding(.horizontal, 16)
        .frame(width: width, height: height)
        .background(Color.black.opacity(0.28))
    }

    private static func fakeDock(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color.white.opacity(0.16))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
            .overlay(HStack(spacing: 12) {
                ForEach(0..<9, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(hue: Double(index) / 9, saturation: 0.45, brightness: 0.85).opacity(0.85))
                        .frame(width: height - 14, height: height - 14)
                }
            })
            .frame(width: width, height: height)
    }

    /// The Settings window as it draws (its title bar is transparent and untitled: the traffic lights sit on the sheet).
    private static func settingsSheet(_ model: DockSettingsModel) -> some View {
        DockSettingsView(model: model)
            .overlay(alignment: .topLeading) {
                HStack(spacing: 8) {
                    ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18),
                             Color(red: 0.16, green: 0.79, blue: 0.25)], id: \.self) { color in
                        Circle().fill(color).frame(width: 12, height: 12)
                    }
                }
                .padding(.leading, 13)
                .padding(.top, 13)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
    }

    /// 19–21 (CONTRACTS-WAVE8): the voice note's bar in each of its states, and before noon the list opening with the
    /// morning brief, then after its actions. Printed and counted on their own (false: one didn't render).
    private static func notesAndMorning(to out: URL, fixture: Fixture, backdrop: NSImage, idleVoice: DockVoiceSnapshot) -> Bool {
        var written: [String] = []
        func save(_ name: String, _ size: CGSize, _ content: some View) {
            let renderer = ImageRenderer(content: SnapshotCanvas(size: size, backdrop: backdrop, content: content))
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
        // 19. The voice note's bar (CONTRACTS-WAVE8 §D1): recording after a tap and while ⌃⌥N is held, sending, sent
        //     with what the bridge did (its own outcomes: a journal line, a T3 task, a note with a suggestion, its button
        //     under the words and armed by a first click), kept on this Mac while the bridge is away, too short, nothing
        //     heard, and a note the bridge couldn't finish.
        do {
            let (_, ui) = fixture.make()
            func note(_ phase: VoiceNoteSnapshot.Phase, _ line: String = "", _ detail: String = "", level: Double = 0,
                      seconds: TimeInterval = 0) -> VoiceNoteSnapshot {
                var note = VoiceNoteSnapshot()
                note.phase = phase
                note.line = line
                note.detail = detail
                note.level = level
                note.startedAt = seconds > 0 ? Date().addingTimeInterval(-seconds) : nil
                return note
            }
            let states = [
                note(.recording(held: false), level: 0.62, seconds: 7.4),
                note(.recording(held: true), level: 0.2, seconds: 2.2),
                note(.sending, "On its way to your Mac’s bridge…"),
                note(.sent, "Added to your journal", "“Put this in my journal: shipped the voice notes on the Mac today.”"),
                note(.sent, "Started a T3 task", "Started “Fix the flaky long-poll test in the bridge suite” in SamRabbit."),
                {
                    var kept = note(.sent, "Saved as a note", "Start it as a T3 task?")
                    kept.offer = "Start as task"
                    return kept
                }(),
                {
                    var armed = note(.sent, "Saved as a note", "Add it to your journal?")
                    armed.offer = VoiceNoteText.confirm("journal")
                    armed.offerArmed = true
                    return armed
                }(),
                note(.queued, "Saved on this Mac", "The bridge isn’t running — it goes as soon as it can."),
                note(.discarded, "Too short", "Hold ⌃⌥N while you talk, or tap it, talk, and tap again."),
                {
                    // Nothing heard is not a "Sent ✓" (VoiceNoteText.phase).
                    let nothing = CaptureStatus(captureId: "", state: "done", heard: nil,
                                                outcome: CaptureOutcome(kind: "nothing", title: "Nothing heard", detail: "I didn't catch anything."))
                    let lines = VoiceNoteText.outcome(nothing)
                    return note(VoiceNoteText.phase(nothing), lines.line, lines.detail)
                }(),
                note(.failed, "The bridge couldn’t finish it", "Couldn't save it: T3 Code isn't connected."),
            ]
            save("dock-19-note.png", CGSize(width: 760, height: 1010), VStack(spacing: 16) {
                ForEach(Array(states.enumerated()), id: \.offset) { _, state in
                    DockNoteBar(note: state, scale: ui.pillScale, commands: DockCommands()).fixedSize()
                }
            }.padding(.bottom, 24))
        }
        // 20–21. Before noon, the list opens with the morning brief (CONTRACTS-WAVE8 §D2): the headline, what to do first
        //        with its verbs, today's next events. Then after Draft reply (saved in Gmail, opened, nothing sent), Make
        //        task asking first (the task's exact words), "Remind me" open on the clash and a failed try's note. At
        //        8:20 today, whatever the time.
        if let start = Calendar.current.date(bySettingHour: 8, minute: 20, second: 0, of: Date()),
           let early = Fixture.load(now: start), let brief = early.brief {
            do {
                let (store, ui) = early.make()
                ui.expanded = true
                save("dock-20-morning.png", CGSize(width: 680, height: 1200), Stage { panel(store, ui, idleVoice) })
            }
            do {
                let (store, ui) = early.make()
                ui.expanded = true
                let first = brief.section(.doFirst)?.items ?? []
                if first.count == 3 {
                    store.morning.act(first[0], "draft_reply")
                    store.morning.taskOpen = first[1].id
                    store.morning.showNote(DockStore.note(for: DockAPI.Failure(status: 502, code: "gmail_failed",
                                                                               message: "Gmail didn’t answer. Nothing was changed.")),
                                           for: first[2].id)
                    store.morning.remindOpen = first[2].id
                }
                save("dock-21-morning-acted.png", CGSize(width: 680, height: 1200), Stage { panel(store, ui, idleVoice) })
            }
        }
        // 22. Voice notes in the list (samrabbit_capture `inbox_items`): one kept with a suggestion, open with its button
        //     ("Start as task"), and one that failed (in Needs you with "Try again" once open, beside).
        do {
            let notes = Fixture.withNotes(fixture)
            let (kept, keptUI) = notes.make()
            keptUI.expanded = true
            keptUI.selected = Fixture.keptNoteId
            keptUI.expandedRow = Fixture.keptNoteId
            let (failed, failedUI) = notes.make()
            failedUI.expanded = true
            failedUI.selected = Fixture.failedNoteId
            failedUI.expandedRow = Fixture.failedNoteId
            save("dock-22-notes.png", CGSize(width: 1360, height: 1000), HStack(alignment: .top, spacing: 0) {
                Stage { panel(kept, keptUI, idleVoice) }
                Stage { panel(failed, failedUI, idleVoice) }
            })
        }
        for path in written { print(path) }
        return written.count == 4
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
        /// The morning brief (dev/samples/briefing.json next to the inbox), moved to `now`'s day.
        var brief: DockBrief? = nil

        /// `now`: the moment the fixture's times are moved to (the morning snapshots use 8:20 today).
        static func load(now: Date = Date()) -> Fixture? {
            let fallbacks: [String?] = [
                Config.argument("--dock-fixture"),
                ProcessInfo.processInfo.environment["SAMRABBIT_DOCK_FIXTURE"],
                FileManager.default.currentDirectoryPath + "/companion/desktop/dev/samples/inbox.json",
                FileManager.default.currentDirectoryPath + "/dev/samples/inbox.json",
                Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
                    .appendingPathComponent("dev/samples/inbox.json").path,
            ]
            for candidate in fallbacks.compactMap({ $0 }) {
                let path = (candidate as NSString).expandingTildeInPath
                guard let data = FileManager.default.contents(atPath: path),
                      var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
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
                let brief = briefing(next: path, now: now)
                return Fixture(inbox: inbox, details: details, targets: targets, now: now, brief: brief)
            }
            return nil
        }

        static let keptNoteId = "note:3f2b8c1e-7d4a-4e9b-8f21-6a5c0d9e1b47"
        static let failedNoteId = "note:9c4e2a7b-1f3d-4b8e-a6c5-2d7f0e8b3a91"

        /// The fixture with two voice notes in the bridge's own shape (samrabbit_capture `inbox_items`): kept with a
        /// suggestion, and one the Mac couldn't hear.
        static func withNotes(_ base: Fixture) -> Fixture {
            let formatter = ISO8601DateFormatter()
            func note(_ id: String, status: String, label: String, title: String, summary: String, minutes: Double,
                      suggestion: [String: Any]?) -> [String: Any] {
                ["id": id, "source": "note", "agent": NSNull(), "title": title, "project": "Voice note", "cwd": NSNull(),
                 "status": status, "statusLabel": label, "summary": summary,
                 "updatedAt": formatter.string(from: base.now.addingTimeInterval(-minutes * 60)), "unread": true,
                 "pending": ["approvals": [], "inputs": []], "can": ["act", "dismiss", "seen"], "live": false,
                 "progress": NSNull(), "phase": NSNull(), "suggestion": suggestion ?? NSNull(),
                 "captureId": String(id.dropFirst(5))]
            }
            let raw = [
                note(keptNoteId, status: "needs-input", label: "Start it as a T3 task?", title: "Look into why the watch build is slow",
                     summary: "Look into why the watch build is slow on the release machine.", minutes: 3,
                     suggestion: ["action": "task", "label": "Start it as a T3 task?"]),
                note(failedNoteId, status: "error", label: "Couldn't hear it", title: "Voice note",
                     summary: "Couldn't save it: transcription is not installed on the Mac bridge.", minutes: 41, suggestion: nil),
            ]
            var inbox = base.inbox
            let added = raw.compactMap { entry -> DockItem? in
                (try? JSONSerialization.data(withJSONObject: entry)).flatMap { try? JSONDecoder().decode(DockItem.self, from: $0) }
            }
            inbox.items = DockOrder.sorted(inbox.items + added)
            inbox.counts = DockCounts(needsYou: inbox.items.filter(\.needsYou).count,
                                      working: inbox.items.filter { $0.status == .working }.count, total: inbox.items.count)
            var details = base.details
            details[keptNoteId] = [DockMessage(role: "user", text: "Look into why the watch build is slow on the release machine.",
                                               at: base.now.addingTimeInterval(-180)),
                                   DockMessage(role: "assistant", text: "Saved as a note.", at: base.now.addingTimeInterval(-175))]
            details[failedNoteId] = [DockMessage(role: "assistant", text: "Couldn't save it: transcription is not installed on the Mac bridge.",
                                                 at: base.now.addingTimeInterval(-41 * 60))]
            return Fixture(inbox: inbox, details: details, targets: base.targets, now: base.now, brief: base.brief)
        }

        /// briefing.json beside the inbox fixture, moved by whole days to `now`'s (its clock times stay, like the fake's).
        static func briefing(next inboxPath: String, now: Date) -> DockBrief? {
            let path = (inboxPath as NSString).deletingLastPathComponent + "/briefing.json"
            guard let data = FileManager.default.contents(atPath: path),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let base = (json["base"] as? String).flatMap(DockDate.parse),
                  var brief = json["briefing"] as? [String: Any] else { return nil }
            let calendar = Calendar.current
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: base), to: calendar.startOfDay(for: now)).day ?? 0
            brief = shift(brief, by: TimeInterval(days) * 86_400) as? [String: Any] ?? brief
            brief["date"] = DockBrief.day(now)
            return DockBrief.from(brief)
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
                                          working: inbox.items.filter { $0.status == .working }.count,
                                          total: inbox.items.count)
            }
            var detailMap: [String: DockItemDetail] = [:]
            for item in inbox.items {
                if let messages = details[item.id] { detailMap[item.id] = DockItemDetail(item: item, messages: messages) }
            }
            let store = DockStore(fixture: inbox, details: detailMap, targets: targets, now: now, connection: connection, brief: brief)
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
/// It approves a real request and starts a task, so it runs only against dev/fake_sync_server.py: never the default
/// address or port 3780 (DockSmokeGuard), and only when the server answers `GET /dev/inbox/fake`.
@MainActor
enum DockSmoke {
    static func run(_ controller: DockController, directory: String) {
        if let reason = DockSmokeGuard.refusal(base: Config.baseURL, isDefaultBase: Config.isDefaultBase) {
            Log.write("dock smoke refused: \(reason) (it approves and creates tasks: point the app at dev/fake_sync_server.py)")
            return
        }
        Task { @MainActor in
            guard await isFakeServer() else {
                Log.write("dock smoke refused: the server is not dev/fake_sync_server.py (no /dev/inbox/fake)")
                return
            }
            steps(controller, directory: directory)
        }
    }

    /// `SAMRABBIT_DOCK_SMOKE_PLACES=1` (CONTRACTS-WAVE7 §B2): leaves the dock at the top left of its screen and opens its
    /// list, folds it to the orb, opens the list over the orb, unfolds it, leaves it in the bottom-right corner as the
    /// orb with its list, hides and shows it (⌃⌥D's path), hides it from the menu and shows it again, and puts it back
    /// in the middle, logging the screen, the resting frame and what AppKit says about both windows at each step, plus
    /// what the four shortcuts registered as. Those steps save what they change (the spot, the orb, the hide) as Samin's
    /// own moves would; the run puts back what the copy had kept at the start. The same guard as above (the fake
    /// server, never port 3780), and never with the installed app's bundle id.
    static func runPlaces(_ controller: DockController) {
        if let reason = DockSmokeGuard.placesRefusal(base: Config.baseURL, isDefaultBase: Config.isDefaultBase,
                                                     bundleId: Bundle.main.bundleIdentifier) {
            Log.write("dock places smoke refused: \(reason)")
            return
        }
        Task { @MainActor in
            guard await isFakeServer() else {
                Log.write("dock places smoke refused: the server is not dev/fake_sync_server.py (no /dev/inbox/fake)")
                return
            }
            places(controller)
        }
    }

    private static func places(_ controller: DockController) {
        let shortcuts = DockShortcutCenter.shared
        let registered = DockShortcutAction.allCases.map { action in
            "\(action.rawValue) \(shortcuts.shortcut(action).display): \(shortcuts.unavailable[action] ?? "registered")"
        }
        Log.write("dock places smoke: shortcuts " + registered.joined(separator: "; "))
        let kept = controller.devMemory
        let topLeft = DockSpot(corner: .topLeft, dx: DockMetrics.edgeGap, dy: DockMetrics.edgeGap)
        let corner = DockSpot(corner: .bottomRight, dx: DockMetrics.edgeGap, dy: DockMetrics.bottomGap)
        let steps: [(TimeInterval, String, () -> Void)] = [
            (2.5, "rest", {}),
            (3.5, "top-left", { controller.devPlace(topLeft) }),
            (4.5, "top-left-list", { controller.summon(focusCompose: false) }),
            (5.5, "orb", {
                controller.perform(.collapsePanel)
                controller.setMinimized(true)
            }),
            (6.5, "orb-list", { controller.summon(focusCompose: false) }),
            (7.5, "expanded", {
                controller.perform(.collapsePanel)
                controller.toggleMinimized()
            }),
            (8.5, "corner-orb", {
                controller.devPlace(corner)
                controller.setMinimized(true)
            }),
            (9.5, "corner-orb-list", { controller.summon(focusCompose: false) }),
            (10.5, "hidden", {
                controller.perform(.collapsePanel)
                controller.toggleShown()
            }),
            (11.5, "shown", { controller.toggleShown() }),
            (12.5, "menu-hidden", { controller.putAwayFromMenu() }),
            (13.5, "menu-shown", { controller.bringBackFromMenu() }),
            (14.5, "back", {
                controller.setMinimized(false)
                controller.devPlace(nil)
            }),
            (15.5, "restored", { controller.devRestore(kept) }),
        ]
        for (at, name, body) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + at) {
                body()
                // Let the windows measure and move first (well before the next step).
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    func frame(_ rect: CGRect) -> String { "\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height))" }
                    func describe(_ window: NSWindow?) -> String {
                        guard let window else { return "none" }
                        return "\(window.isVisible ? "visible" : "hidden") \(frame(window.frame))"
                    }
                    let state = controller.devState
                    let screen = state.screen.map { "visible \(frame($0.visibleFrame))" } ?? "none"
                    Log.write("dock places smoke \(name): screen \(screen); rest \(frame(state.rest)); pill \(describe(controller.pill));"
                              + " list \(describe(controller.list)); minimized=\(controller.ui.minimized) listBelow=\(controller.ui.listBelow)"
                              + " shown=\(controller.ui.shown) expanded=\(controller.ui.expanded)")
                    if name == "restored" { Log.write("dock places smoke done (the copy's own spot, orb and hide put back)") }
                }
            }
        }
    }

    /// `GET /dev/inbox/fake` → `{"fake": true}`: only the fake server says so.
    private static func isFakeServer() async -> Bool {
        guard let request = Config.request(Config.api("/dev/inbox/fake"), timeout: 5),
              let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return body["fake"] as? Bool == true
    }

    private static func steps(_ controller: DockController, directory: String) {
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
        // ⌘ keys through the app's own event queue (NSApp.postEvent: the route a real key takes, menus included):
        // ⌘0 resets the dock's size instead of opening the main window, ⌘K searches nothing.
        step(27.5, "command-keys") {
            controller.perform(.zoom(1))
            post(key: "0", code: 29, command: true, to: controller.list)
            post(key: "k", code: 40, command: true, to: controller.list)
        }
        step(29, "command-keys-after")
        // A click on the pill (posted the same way) opens the list with the compose field taking the keys: the
        // letters of a prompt go into it; and E on a selected approval row that is still closed approves nothing.
        step(29.5, "collapse") {
            controller.perform(.collapsePanel)
            Task { await devPost("/dev/inbox/needs-you") }  // a fresh approval for the stray E
        }
        step(30.5, "click-pill") { click(controller.pill) }
        step(31.5, "pill-clicked") {
            for (character, code) in [("e", UInt16(14)), ("x", UInt16(7)), ("p", UInt16(35))] {
                post(key: character, code: code, to: controller.list)
            }
        }
        step(32.5, "typed") {
            post(key: "\u{1b}", code: 53, to: controller.list)
            if let item = store.items.first(where: { $0.supports("approve") && !$0.pending.approvals.isEmpty }) {
                controller.perform(.select(item.id))
            }
            post(key: "e", code: 14, to: controller.list)
        }
        step(34, "stray-keys-after") { store.composeText = "" }

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
                          + " \(store.workingCount), items \(store.items.count); expanded=\(ui.expanded); selected=\(ui.selected ?? "-");"
                          + " open row=\(ui.expandedRow ?? "-"); editing=\(ui.editing.map { "\($0)" } ?? "-"); compose \(store.composeText.count) chars;"
                          + " voice=\(MacVoice.shared.state)")
                draw(controller, name: name, to: out)
                if name == "stray-keys-after" { Log.write("dock smoke done") }
            }
        }
    }

    /// A dev control of the fake server (it was checked to be the fake before the first step).
    private static func devPost(_ path: String) async {
        guard var request = Config.request(Config.api(path), timeout: 5) else { return }
        request.httpMethod = "POST"
        _ = try? await URLSession.shared.data(for: request)
    }

    /// A key into the app's own event queue (never the system's): AppKit routes it like a real one, menus first.
    private static func post(key: String, code: UInt16, command: Bool = false, to window: NSWindow?) {
        guard let window, let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: command ? [.command] : [],
                                                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                         context: nil, characters: key, charactersIgnoringModifiers: key,
                                                         isARepeat: false, keyCode: code) else { return }
        NSApp.postEvent(event, atStart: false)
    }

    /// A click on the pill's words (not on a control), through the app's own event queue.
    private static func click(_ window: NSWindow?) {
        guard let window else { return }
        let point = NSPoint(x: 70, y: window.frame.height / 2)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                              pressure: type == .leftMouseDown ? 1 : 0) {
                NSApp.postEvent(event, atStart: false)
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
