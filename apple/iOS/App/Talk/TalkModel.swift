import ActivityKit
import Foundation
import Observation
import os
import SamRabbitKit
import SwiftUI

private let talkLog = Logger(subsystem: "com.samrabbit.mobile", category: "talk")

/// The iPhone's live conversation with SamRabbit ("Talk"), like talking to the R1 or ChatGPT Voice. The engine is
/// the watch's (`ConversationEngine` and `AudioGraph`, compiled into this app too, with the rules in SamRabbitKit's
/// `ConversationMachine`); this adds what the phone has around it:
///
/// * the Talk screen (`TalkView`, full screen) and, while it is minimized, the bar over the tab bar
///   (`TalkMiniBar`): the conversation goes on either way, and with the app in the background or the screen locked
///   (`UIBackgroundModes: audio`);
/// * the Live Activity on the Lock Screen and in the Dynamic Island, with End (`TalkActivityController`);
/// * mute, stop speaking, end and a typed turn.
///
/// Turns go straight to the Mac with the iPhone's own token (no relay), with the same streaming protocol as the
/// watch. Nothing heard or said is ever logged.
@MainActor
@Observable
final class TalkModel {
    let engine: ConversationEngine
    /// The Talk screen is up. While a conversation runs without it, the bar over the tab bar shows it.
    var presented = false
    /// The keyboard's field is open on the Talk screen.
    var typing = false
    /// The transcript (the conversation's earlier exchanges) is shown instead of the big orb.
    var transcript = false

    @ObservationIgnored private let account: BridgeAccount
    @ObservationIgnored private let activity = TalkActivityController()
    @ObservationIgnored private var lastPhase: ConversationMachine.Phase = .idle
    /// Words typed while no conversation listened yet: sent once it does.
    @ObservationIgnored private var pendingText: String?

    init(account: BridgeAccount) {
        self.account = account
        engine = ConversationEngine(account: account)
        engine.onUpdate = { [weak self] in self?.changed() }
        TalkRemote.onEnd = { [weak self] in self?.end() }
        TalkRemote.listen()
        // One microphone: dictation (the composer's mic) ends a conversation first.
        SpeechDictation.willStart = { [weak self] in
            guard let self, self.active else { return }
            self.end()
        }
        // Nothing talks at launch: a Live Activity left by an earlier run (the app was closed) goes.
        TalkActivityController.endLeftovers()
    }

    var active: Bool { engine.active }
    var machine: ConversationMachine { engine.machine }
    var phase: TalkPhase {
        TalkPhase(machine.phase, muted: engine.micMuted, announcing: machine.live?.kind == .announcement)
    }

    /// Opens Talk and starts the conversation (the Home button, `samrabbit://talk`, Siri, the Action Button, the
    /// control, the Lock Screen widget). A conversation already open just comes up.
    func start() {
        typing = false
        withAnimation(.smooth(duration: 0.35)) { presented = true }
        guard account.isPaired else { return }
        if !engine.active { engine.open() }
    }

    /// The app's own intent ran again while talking (the Action Button pressed again): like a tap on the orb, it
    /// sends what is being said now, or interrupts the reply.
    func pressedAgain() {
        withAnimation(.smooth(duration: 0.35)) { presented = true }
        if engine.active { engine.tap() } else { start() }
    }

    /// Back to the app; the conversation goes on (the bar over the tab bar, the Live Activity).
    func minimize() {
        typing = false
        withAnimation(.smooth(duration: 0.35)) { presented = false }
    }

    /// Ends the conversation (End, the Live Activity's End, dictation starting) and closes Talk.
    func end() {
        typing = false
        engine.stop()
        withAnimation(.smooth(duration: 0.35)) { presented = false }
    }

    /// The orb: talk, send now, or interrupt.
    func tapOrb() {
        guard account.isPaired else { return }
        engine.active ? engine.tap() : engine.open()
    }

    func toggleMute() {
        engine.setMuted(!engine.micMuted)
    }

    /// Stops the reply being said (barge-in) and listens.
    func stopSpeaking() {
        guard machine.phase == .speaking || machine.phase == .thinking else { return }
        engine.tap()
    }

    /// Sends a typed turn (`{text}`); the field closes. With no conversation listening (it ended meanwhile, or is
    /// still starting) one starts and the words go once it listens.
    func send(_ text: String) {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, account.isPaired else { return }
        typing = false
        switch machine.phase {
        case .idle, .starting:
            pendingText = words
            if !engine.active { engine.open() }
        default:
            engine.send(text: words)
        }
    }

    /// The reply is something you can stop.
    var canStopSpeaking: Bool { machine.phase == .speaking || machine.phase == .thinking }

    // MARK: - Following the conversation

    private func changed() {
        let now = machine.phase
        if now != lastPhase {
            talkLog.info("talk \(self.lastPhase.rawValue, privacy: .public) -> \(now.rawValue, privacy: .public)")
            lastPhase = now
            if let words = pendingText, now != .starting {
                pendingText = nil
                // Listening now: the typed words go (a conversation that couldn't start drops them).
                if now == .listening { engine.send(text: words) }
            }
        }
        var state = TalkActivityState(machine, muted: engine.micMuted)
        state.line = ConversationEngine.deviceWords(state.line)
        activity.follow(state)
    }
}

/// The conversation's Live Activity: started with the conversation (the app is in front then), updated when the
/// phase changes and (at most every 1.5 s) while a reply streams in, ended with it. Its End button runs
/// `EndTalkIntent`. Kept by id: ActivityKit's calls run off the main actor.
@MainActor
final class TalkActivityController {
    private var activityId: String?
    private var shown: TalkActivityState?
    private var shownAt: Date?
    private var latest: TalkActivityState?
    private var flush: Task<Void, Never>?
    /// A request failed (Live Activities are off, or the app is not in front): not asked again this conversation.
    private var refused = false

    func follow(_ state: TalkActivityState) {
        latest = state
        if state.phase == .ended {
            end()
            return
        }
        guard activityId != nil else {
            start(state)
            return
        }
        if state.update(from: shown, shownAt: shownAt, now: .now) {
            push(state)
        } else if state != shown, flush == nil {
            // A newer line waits for the interval, then goes (whatever is newest by then).
            flush = Task { [weak self] in
                try? await Task.sleep(for: .seconds(TalkActivityState.lineInterval))
                guard !Task.isCancelled, let self else { return }
                self.flush = nil
                if let latest = self.latest, latest != self.shown, latest.phase != .ended { self.push(latest) }
            }
        }
    }

    private func start(_ state: TalkActivityState) {
        guard !refused, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            let activity = try Activity.request(attributes: TalkActivityAttributes(),
                                                content: ActivityContent(state: state, staleDate: nil))
            activityId = activity.id
            shown = state
            shownAt = .now
        } catch {
            refused = true
            talkLog.notice("talk live activity not started: \(String(describing: error), privacy: .public)")
        }
    }

    private func push(_ state: TalkActivityState) {
        guard let id = activityId else { return }
        flush?.cancel()
        flush = nil
        shown = state
        shownAt = .now
        Task { await Self.update(id, to: state) }
    }

    private func end() {
        flush?.cancel()
        flush = nil
        refused = false
        shown = nil
        shownAt = nil
        guard let id = activityId else { return }
        activityId = nil
        Task { await Self.end([id]) }
    }

    /// Ends the Talk activities a closed app left behind (taken now, so a conversation starting right after keeps
    /// its own).
    static func endLeftovers() {
        let leftovers = Activity<TalkActivityAttributes>.activities.map(\.id)
        guard !leftovers.isEmpty else { return }
        Task { await end(leftovers) }
    }

    nonisolated private static func update(_ id: String, to state: TalkActivityState) async {
        guard let activity = Activity<TalkActivityAttributes>.activities.first(where: { $0.id == id }) else { return }
        await activity.update(ActivityContent(state: state, staleDate: nil))
    }

    nonisolated private static func end(_ ids: [String]) async {
        let final = ActivityContent(state: TalkActivityState(phase: .ended), staleDate: nil)
        for activity in Activity<TalkActivityAttributes>.activities where ids.contains(activity.id) {
            await activity.end(final, dismissalPolicy: .immediate)
        }
    }
}
