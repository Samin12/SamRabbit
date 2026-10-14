import Foundation

/// The watch's always-on conversation with SamRabbit, as a pure state machine: the watch app feeds it what
/// happened (the microphone heard speech, a turn's stream said something, playback ran dry, a tap) and carries
/// out the effects it returns (open the microphone, send a turn, play, speak, cancel, end). No audio, network or
/// clock of its own, so every rule below is unit-tested.
///
///     idle -> starting -> listening -> hearing -> thinking -> speaking -> listening -> ...
///
/// * A conversation starts from the app's launch, the Action Button, Siri, a complication or a tap on the orb;
///   the Mac is warmed up at once (`warmUp`).
/// * Half duplex: the microphone is closed while a turn is on its way and while anything plays (no echo), and
///   reopened after (auto-continue).
/// * Barge-in: a tap while thinking or speaking cancels the turn on the Mac (`cancel`), stops playback and listens.
/// * A reply without audio is spoken by the watch itself (`speak`); a Mac that can't be reached is said out loud
///   ("I can't reach your Mac right now"), then the conversation ends. A warm-up that fails before the audio runs
///   (the microphone prompt, Siri still holding it) is said once it does (`audioReady`).
/// * Announcements (T3 tasks that finished or need Samin) wait until the conversation is listening, then play:
///   their own clip if they have one (the words, said by the watch, when the clip can't be read), else as a
///   `{"announce": id}` turn in the conversation's voice. The bridge counts one as told once the watch has it, so
///   none is ever dropped: one that waits when the conversation ends is said when the next one starts.
/// * It ends on Stop, when the Mac says so (`endConversation`), after `idleTimeout` (about 2 minutes) without a
///   turn that heard words (noise, coughs and empty transcripts don't count), or after the current reply when the
///   app leaves the screen (coming back while it plays keeps the conversation going).
public struct ConversationMachine: Sendable {
    public enum Phase: String, Sendable, Equatable {
        /// No conversation.
        case idle
        /// The audio session and engine are coming up.
        case starting
        /// The microphone is open, waiting for speech.
        case listening
        /// Someone is speaking.
        case hearing
        /// A turn is on its way; nothing plays yet.
        case thinking
        /// A reply, an announcement or the watch's own voice is playing.
        case speaking

        public var inConversation: Bool { self != .idle }
    }

    public enum Haptic: String, Sendable, Equatable {
        case start, click, stop, failure, retry, notification
    }

    /// What a turn sends.
    public enum Input: Sendable, Equatable {
        /// An utterance: 16 kHz mono 16-bit WAV.
        case audio(Data)
        case text(String)
        /// Speak this announcement (`{"announce": id}`).
        case announce(String)
    }

    public struct TurnRequest: Sendable, Equatable {
        public var turnId: String
        public var conversationId: String?
        public var input: Input
    }

    /// What the watch app does for the machine.
    public enum Effect: Sendable, Equatable {
        /// Set up the audio session and the engine (microphone tap and player).
        case startAudio
        case stopAudio
        /// `POST /v1/mobile/assistant/session` (optional; the first turn starts the conversation otherwise).
        case warmUp(conversationId: String?)
        /// Feed the speech detector again, from scratch (after a reply: skip its echo).
        case openMic
        /// Stop feeding the speech detector (half duplex).
        case closeMic
        /// End the utterance in progress now (a tap while speaking).
        case flushMic
        case send(TurnRequest)
        /// `POST /v1/mobile/assistant/cancel` and drop the turn's stream.
        case cancel(turnId: String, conversationId: String?)
        case stopPlayback
        /// Say this with the watch's own voice.
        case speak(String)
        /// Play an announcement's own clip.
        case play(AssistantAudio)
        case haptic(Haptic)
        /// `POST /v1/mobile/assistant/end`
        case end(conversationId: String)
        /// Poll announcements (about every 20 s) while true.
        case announcements(Bool)
    }

    /// Why a turn (or the warm-up) failed.
    public enum Failure: Sendable, Equatable {
        /// Neither the Mac nor the iPhone could be reached.
        case unreachable
        /// The Mac refused the watch's token.
        case unauthorized
        /// The Mac can't run the assistant now (`assistant_unavailable`, with its reason).
        case unavailable(String?)
        /// The Mac's bridge has no assistant yet (404).
        case outdated
        /// Still answering the last turn (409 after retries).
        case busy
        /// Anything else (a timeout, an error event in the stream).
        case failed(code: String, message: String)

        /// After these the conversation ends.
        public var isFatal: Bool {
            switch self {
            case .unreachable, .unauthorized, .unavailable, .outdated: true
            case .busy, .failed: false
            }
        }

        /// What a bridge error code means to the conversation: an HTTP refusal (with its status) or an `error`
        /// event in a stream (no status). The ones that can't get better by trying again end the conversation.
        public init(code: String, message: String = "", status: Int? = nil) {
            switch code {
            case "assistant_unavailable", "assistant_missing", "transcribe_unavailable", "transcribe_permission",
                 "chatgpt_unavailable", "chatgpt_not_connected":
                self = .unavailable(code)
            case "unauthorized", "invalid_token", "device_revoked":
                self = .unauthorized
            case "assistant_busy":
                self = .busy
            default:
                if status == 401 {
                    self = .unauthorized
                } else if status == 404, code != "conversation_not_found", code != "announcement_not_found" {
                    self = .outdated
                } else {
                    self = .failed(code: code, message: message)
                }
            }
        }

        /// What the watch says.
        public var spoken: String {
            switch self {
            case .unreachable: "I can't reach your Mac right now."
            case .unauthorized: "Your watch needs to reconnect. Open SamRabbit on your iPhone."
            case .unavailable: "The assistant isn't available on your Mac right now."
            case .outdated: "Update SamRabbit on your Mac to talk with me."
            case .busy: "One moment, I'm still on the last thing."
            // Tools may already have acted: never "try again" (that would do it twice).
            case .failed("assistant_interrupted", _): "Sorry, I got cut off partway through that."
            case .failed("conversation_not_found", _): "Sorry, I lost our conversation. Say that again?"
            case .failed: "Sorry, that didn't work. Try again."
            }
        }

        /// Shown under the orb once the conversation ended because of it.
        public var shown: String {
            switch self {
            case .unreachable: "Can't reach your Mac"
            case .unauthorized: "Reconnect through your iPhone"
            case .unavailable: "Assistant unavailable on the Mac"
            case .outdated: "Update SamRabbit on your Mac"
            case .busy: "Still answering"
            case .failed: "That didn't work"
            }
        }
    }

    /// What one turn's stream produced.
    public enum TurnEvent: Sendable, Equatable {
        case heard(String)
        case sayDelta(String)
        case sayDone(String)
        case action(AssistantAction)
        case card(AssistantCard)
        case done(AssistantDone)
        case failed(Failure)
    }

    public enum Event: Sendable, Equatable {
        /// Open a conversation (launch, Action Button, Siri, a complication, a tap on the idle orb).
        case start
        /// The audio engine runs (only ever after `startAudio`, never after the conversation ended).
        case audioReady
        /// The microphone or the engine couldn't start (the message is shown).
        case audioFailed(String)
        /// The warm-up answered.
        case session(AssistantSession)
        /// The warm-up failed (only a Mac out of reach, a refused watch or a missing assistant matter).
        case warmUpFailed(Failure)
        case speechStarted
        /// A finished utterance (WAV).
        case utterance(Data)
        /// Speech too short to send.
        case discarded
        case turn(String, TurnEvent)
        /// Something started playing (a reply's first frame, again after a gap, a clip, the watch's voice).
        case playing
        /// Everything scheduled has played.
        case drained
        /// An announcement's own clip couldn't be read (its words are said instead).
        case clipFailed
        /// The orb (or the Action Button again).
        case tap
        /// The Stop button.
        case stop
        /// About once a second while a conversation is open.
        case tick
        case announcements([Announcement])
        /// A call or Siri took the audio session.
        case interrupted
        /// The app left the screen (the Digital Crown): finish what plays, then pause.
        case background
        /// The app is in front again (wrist raised, reopened): continues a paused conversation, or keeps one whose
        /// reply was still playing going.
        case resume
        /// Words typed instead of said (the iPhone's keyboard): sent as a `{text}` turn. While a reply is on its
        /// way or playing it is interrupted first, like a tap.
        case typed(String)
        /// The microphone was muted (the iPhone's mute button) or unmuted. The app stops hearing; the machine only
        /// keeps the quiet end from ending a conversation while muted, and counts the quiet from the unmute.
        case muted(Bool)
    }

    /// One exchange, for the captions and the scrollable history.
    public struct Exchange: Sendable, Equatable, Identifiable {
        public enum Kind: String, Sendable, Equatable { case utterance, announcement, notice }
        public var id: String
        public var kind: Kind
        public var heard: String = ""
        public var say: String = ""
        public var actions: [AssistantAction] = []
        public var cards: [AssistantCard] = []
        public var interrupted = false
        public var failed = false
    }

    private struct Turn: Sendable {
        enum Kind: Sendable, Equatable {
            /// A turn on the Mac (an utterance or an announcement).
            case bridge
            /// An announcement's own clip.
            case clip
            /// The watch's own voice (a failure, an announcement whose turn failed).
            case local
        }
        var id: String
        var kind: Kind
        var announcement: Announcement?
        /// Nothing more will be scheduled: running dry finishes the turn.
        var complete = false
        var gotAudio = false
        var done: AssistantDone?
        var say = ""
        /// Words were heard or said (an announcement too): the conversation is in use. A turn of noise isn't.
        var accepted = false
        /// When it became complete (the speaking watchdog counts from here).
        var completedAt: Date?
    }

    public private(set) var phase: Phase = .idle
    public private(set) var conversationId: String?
    public private(set) var brain: AssistantBrain = .unknown
    /// Why the last conversation ended badly (shown while idle), or nil.
    public private(set) var problem: String?
    public private(set) var exchanges: [Exchange] = []
    /// The start, the last turn that heard (or said) words, an announcement, a tap: `idleTimeout` counts from here.
    /// Noise never moves it, so a café, a car or a TV can't keep the microphone open forever.
    public private(set) var lastActivity: Date = .distantPast
    public private(set) var expectReply = false
    /// The microphone is muted (`muted(true)`): nothing is heard, and the quiet end waits.
    public private(set) var micMuted = false
    public var idleTimeout: TimeInterval
    /// A conversation that stopped because the app left (or the audio was taken) is resumed within this long.
    public var resumeWindow: TimeInterval = 180
    public static let maxExchanges = 12
    /// Announcements kept for later at most (a burst of T3 events while nobody listens).
    public static let maxWaiting = 10
    /// A waiting announcement is said once the conversation has been listening this long with nobody speaking
    /// (after a barge-in, say).
    public static let announceAfterQuiet: TimeInterval = 1.5
    /// A finished reply whose playback never reports the end (a lost audio route, a stuck player) is over after this.
    public static let speakingLimit: TimeInterval = 60
    /// Speech that never ends (the microphone stopped delivering mid-utterance) is dropped after this; the speech
    /// detector itself cuts an utterance at 30 s.
    public static let hearingLimit: TimeInterval = 40

    private var current: Turn?
    private var queue: [Announcement] = []
    private var announced: Set<String> = []
    private var playing = false
    /// A fatal failure is being said: the conversation ends after it.
    private var endAfterPlayback = false
    /// The app left the screen while a reply played: the conversation pauses after it, unless the app comes back.
    private var pausing = false
    /// The Mac ended the conversation and announcements wait: they are said first, then it ends.
    private var closing = false
    private var listeningSince: Date = .distantPast
    private var hearingSince: Date = .distantPast
    private var reachable = true
    /// A fatal warm-up failure that came while the audio was still starting: said at `audioReady`.
    private var pendingFailure: Failure?
    /// The conversation stopped without being ended on purpose (background, interruption): `resume` continues it.
    private var resumable = false
    private var endedAt: Date?
    private let makeId: @Sendable () -> String

    public init(idleTimeout: TimeInterval = 120, makeId: @escaping @Sendable () -> String = { UUID().uuidString }) {
        self.idleTimeout = idleTimeout
        self.makeId = makeId
    }

    /// The turn whose stream the app should read (events of other turns are ignored).
    public var currentTurnId: String? { current?.kind == .bridge ? current?.id : nil }

    /// The exchange being heard or answered right now.
    public var live: Exchange? { current.flatMap { turn in exchanges.last { $0.id == turn.id } } }

    /// Announcements waiting for a pause.
    public var waitingAnnouncements: Int { queue.count }

    // MARK: - Events

    public mutating func handle(_ event: Event, at now: Date = .now) -> [Effect] {
        switch event {
        case .start:
            // Opened again while a reply plays (the Crown, then straight back): the conversation goes on.
            if phase.inConversation { return keepGoing() }
            return start(at: now)
        case .audioReady:
            guard phase == .starting else { return [] }
            phase = .listening
            listeningSince = now
            lastActivity = now
            if let failure = pendingFailure {
                // The warm-up failed while the audio came up: say why now that it can be heard, then end.
                pendingFailure = nil
                return fail(failure, at: now)
            }
            let effects: [Effect] = [.openMic, .haptic(.start), .announcements(true)]
            // Announcements that waited (the last conversation paused or ended with them) are said first.
            return queue.isEmpty ? effects : effects + announce(queue.removeFirst(), at: now)
        case .audioFailed(let message):
            guard phase.inConversation else { return [] }
            return finish(at: now, problem: message, haptic: .failure, tellMac: false)
        case .session(let session):
            if !session.conversationId.isEmpty, conversationId == nil { conversationId = session.conversationId }
            if session.brain != .unknown { brain = session.brain }
            return []
        case .warmUpFailed(let failure):
            // Only matters while nobody spoke yet; a turn reports its own failure.
            guard failure.isFatal, current == nil, phase == .listening || phase == .starting else { return [] }
            if phase == .starting {
                // Nothing can be heard (or stopped) before the audio runs: said at `audioReady`.
                if pendingFailure == nil { pendingFailure = failure }
                if failure == .unreachable { reachable = false }
                return []
            }
            return fail(failure, at: now)
        case .speechStarted:
            // Not activity yet: noise starts "speech" too. Only a turn that heard words counts.
            guard phase == .listening else { return [] }
            phase = .hearing
            hearingSince = now
            return []
        case .discarded:
            guard phase == .hearing else { return [] }
            phase = .listening
            listeningSince = now
            return listeningAgain(at: now)
        case .utterance(let wav):
            guard phase == .listening || phase == .hearing else { return [] }
            return send(.audio(wav), kind: .utterance)
        case .turn(let id, let turnEvent):
            guard current?.id == id, current?.kind == .bridge else { return [] }
            return turn(turnEvent, at: now)
        case .playing:
            playing = true
            guard current != nil else { return [] }
            current?.gotAudio = true
            if phase == .thinking { phase = .speaking }
            return []
        case .drained:
            playing = false
            guard let current, phase == .speaking || phase == .thinking else { return [] }
            return current.complete ? finishTurn(at: now) : []
        case .clipFailed:
            guard let turn = current, turn.kind == .clip else { return [] }
            playing = false
            if let item = turn.announcement, !item.say.isEmpty {
                // The words are known: the watch says them itself.
                current?.kind = .local
                current?.completedAt = now
                return [.speak(item.say)]
            }
            return finishTurn(at: now)
        case .tap:
            return tap(at: now)
        case .stop:
            guard phase.inConversation else { return [] }
            return finish(at: now, problem: nil, haptic: .stop, tellMac: true)
        case .tick:
            return tick(at: now)
        case .announcements(let items):
            // Kept even when they arrive after the conversation ended (a poll still on its way): the bridge counts
            // them as told already, so they are said when the next conversation starts.
            enqueue(items)
            guard phase == .listening, current == nil, !queue.isEmpty else { return [] }
            return announce(queue.removeFirst(), at: now)
        case .interrupted:
            guard phase.inConversation else { return [] }
            let effects = finish(at: now, problem: "Paused. Tap to talk.", haptic: .retry, tellMac: false)
            resumable = true
            return effects
        case .background:
            switch phase {
            case .idle: return []
            case .thinking, .speaking:
                pausing = true
                return []
            case .starting, .listening, .hearing:
                let effects = finish(at: now, problem: nil, haptic: nil, tellMac: false)
                resumable = true
                return effects
            }
        case .resume:
            if phase.inConversation { return keepGoing() }
            guard canContinue(at: now) else { return [] }
            return start(at: now)
        case .typed(let text):
            return typed(text, at: now)
        case .muted(let on):
            micMuted = on
            // Unmuted: the quiet end counts from now (not from the last words before the mute).
            if !on, phase.inConversation { lastActivity = now }
            return []
        }
    }

    /// A typed turn: sent at once while listening (an utterance being heard is dropped); a reply on its way or
    /// playing is interrupted first. Nothing while starting, idle or saying a fatal failure.
    private mutating func typed(_ text: String, at now: Date) -> [Effect] {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, !endAfterPlayback else { return [] }
        var effects: [Effect] = []
        switch phase {
        case .idle, .starting:
            return []
        case .listening, .hearing:
            break
        case .thinking, .speaking:
            if let current, current.kind == .bridge, current.done == nil || playing {
                effects.append(.cancel(turnId: current.id, conversationId: conversationId))
            }
            update { $0.interrupted = true }
            effects.append(.stopPlayback)
        }
        lastActivity = now
        effects += send(.text(words), kind: .utterance)
        current?.accepted = true
        update { $0.heard = words }
        return effects
    }

    /// Back in front while the reply still plays: it no longer pauses afterwards.
    private mutating func keepGoing() -> [Effect] {
        pausing = false
        resumable = false
        return []
    }

    /// About once a second: the quiet end, waiting announcements, and the watchdogs.
    private mutating func tick(at now: Date) -> [Effect] {
        switch phase {
        case .listening:
            guard current == nil else { return [] }
            if !queue.isEmpty, now.timeIntervalSince(listeningSince) >= Self.announceAfterQuiet {
                return announce(queue.removeFirst(), at: now)
            }
            guard !micMuted, now.timeIntervalSince(lastActivity) >= idleTimeout else { return [] }
            return finish(at: now, problem: nil, haptic: .stop, tellMac: true)
        case .hearing:
            guard now.timeIntervalSince(hearingSince) >= Self.hearingLimit else { return [] }
            // Speech that never ended: drop it (opening the microphone again resets the detector) and listen.
            phase = .listening
            listeningSince = now
            return [.openMic] + listeningAgain(at: now)
        case .thinking, .speaking:
            guard let turn = current, turn.complete, let since = turn.completedAt,
                  now.timeIntervalSince(since) >= Self.speakingLimit else { return [] }
            // The player never said it was done: stop it and go on.
            return [.stopPlayback] + finishTurn(at: now)
        case .idle, .starting:
            return []
        }
    }

    /// Listening again with nothing on its way (speech that was too short, speech that never ended): a waiting
    /// announcement goes first; a conversation that has been idle too long ends.
    private mutating func listeningAgain(at now: Date) -> [Effect] {
        if !queue.isEmpty { return announce(queue.removeFirst(), at: now) }
        guard now.timeIntervalSince(lastActivity) >= idleTimeout else { return [] }
        return finish(at: now, problem: nil, haptic: .stop, tellMac: true)
    }

    /// New announcements join the queue once each (the oldest go when too many wait).
    private mutating func enqueue(_ items: [Announcement]) {
        for item in items where !announced.contains(item.id) {
            announced.insert(item.id)
            queue.append(item)
        }
        if queue.count > Self.maxWaiting { queue.removeFirst(queue.count - Self.maxWaiting) }
    }

    // MARK: - Conversation

    /// A conversation that stopped because the app left or the audio was taken, recently enough to go on with.
    private func canContinue(at now: Date) -> Bool {
        resumable && endedAt.map { now.timeIntervalSince($0) < resumeWindow } == true
    }

    /// Opens a conversation, or continues the one that was paused a moment ago (same id, same captions).
    private mutating func start(at now: Date) -> [Effect] {
        guard phase == .idle else { return [] }
        if !canContinue(at: now) {
            conversationId = nil
            brain = .unknown
            exchanges = []
            // A new conversation hears of new events only; the ones still waiting are said in it.
            announced = Set(queue.map(\.id))
        }
        phase = .starting
        problem = nil
        current = nil
        playing = false
        endAfterPlayback = false
        pausing = false
        closing = false
        reachable = true
        pendingFailure = nil
        resumable = false
        endedAt = nil
        expectReply = false
        lastActivity = now
        return [.startAudio, .warmUp(conversationId: conversationId)]
    }

    /// Ends the conversation: stops what plays and listens, tells the Mac (unless it can't be reached).
    private mutating func finish(at now: Date, problem: String?, haptic: Haptic?, tellMac: Bool) -> [Effect] {
        var effects: [Effect] = []
        if let current, current.kind == .bridge, current.done == nil {
            effects.append(.cancel(turnId: current.id, conversationId: conversationId))
        }
        effects += [.stopPlayback, .closeMic, .stopAudio, .announcements(false)]
        if tellMac, reachable, let conversationId { effects.append(.end(conversationId: conversationId)) }
        if let haptic { effects.append(.haptic(haptic)) }
        phase = .idle
        current = nil
        // The queue stays: those announcements are said when the conversation goes on or the next one starts.
        playing = false
        endAfterPlayback = false
        pausing = false
        closing = false
        pendingFailure = nil
        resumable = false
        endedAt = now
        self.problem = problem
        return effects
    }

    // MARK: - Turns

    private mutating func send(_ input: Input, kind: Exchange.Kind, announcement: Announcement? = nil) -> [Effect] {
        let id = makeId()
        current = Turn(id: id, kind: .bridge, announcement: announcement, accepted: announcement != nil)
        playing = false
        phase = .thinking
        var exchange = Exchange(id: id, kind: kind)
        if let announcement { exchange.say = announcement.say }
        record(exchange)
        return [.closeMic, .send(TurnRequest(turnId: id, conversationId: conversationId, input: input)), .haptic(.click)]
    }

    private mutating func announce(_ item: Announcement, at now: Date) -> [Effect] {
        if let audio = item.audio {
            let id = makeId()
            current = Turn(id: id, kind: .clip, announcement: item, complete: true, accepted: true, completedAt: now)
            playing = false
            phase = .thinking
            record(Exchange(id: id, kind: .announcement, say: item.say))
            return [.closeMic, .haptic(.notification), .play(audio)]
        }
        var effects = send(.announce(item.id), kind: .announcement, announcement: item)
        effects.removeAll { $0 == .haptic(.click) }
        effects.append(.haptic(.notification))
        return effects
    }

    private mutating func turn(_ event: TurnEvent, at now: Date) -> [Effect] {
        guard var turn = current else { return [] }
        switch event {
        case .heard(let text):
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Words, not noise: the conversation is in use.
                current?.accepted = true
                lastActivity = now
            }
            update { $0.heard = text }
        case .sayDelta(let text):
            turn.say += text
            if !text.isEmpty { turn.accepted = true }
            current = turn
            // An announcement's caption is its own line already.
            if turn.announcement == nil { update { $0.say = turn.say } }
        case .sayDone(let text):
            turn.say = text
            if !text.isEmpty { turn.accepted = true }
            current = turn
            if !text.isEmpty { update { $0.say = text } }
        case .action(let action):
            update { $0.actions.append(action) }
        case .card(let card):
            update { $0.cards.append(card) }
        case .done(let done):
            turn.done = done
            turn.complete = true
            turn.completedAt = now
            current = turn
            if !done.conversationId.isEmpty { conversationId = done.conversationId }
            if done.brain != .unknown { brain = done.brain }
            expectReply = done.expectReply
            if done.interrupted { update { $0.interrupted = true } }
            if turn.gotAudio { return playing ? [] : finishTurn(at: now) }
            let say = turn.say.isEmpty ? (live?.say ?? "") : turn.say
            if !done.interrupted, !say.isEmpty {
                // No audio from the Mac: the watch says it itself.
                current?.kind = .local
                return [.speak(say)]
            }
            // Nothing to say (noise, or cancelled): keep listening.
            return finishTurn(at: now)
        case .failed(let failure):
            return fail(failure, at: now)
        }
        return []
    }

    /// A failed turn (or warm-up): the watch says why. An announcement whose turn failed is said by the watch
    /// instead. After a fatal failure the conversation ends once that was said.
    private mutating func fail(_ failure: Failure, at now: Date) -> [Effect] {
        var effects: [Effect] = []
        if playing { effects.append(.stopPlayback) }
        playing = false
        if let item = current?.announcement {
            // The watch has the line itself: say it (the next turn finds out what is wrong with the Mac).
            current?.kind = .local
            current?.complete = true
            current?.completedAt = now
            return effects + [.speak(item.say)]
        }
        if failure == .unreachable { reachable = false }
        // The Mac no longer knows the conversation (it restarted): the next turn starts a new one.
        if case .failed("conversation_not_found", _) = failure { conversationId = nil }
        update { exchange in
            exchange.failed = true
            // The caption shows what the watch says now (unless the reply had said something already).
            if exchange.say.isEmpty { exchange.say = failure.spoken }
        }
        let id = current?.id ?? makeId()
        if current == nil { record(Exchange(id: id, kind: .notice, say: failure.spoken, failed: true)) }
        current = Turn(id: id, kind: .local, complete: true, completedAt: now)
        phase = .thinking
        if failure.isFatal {
            endAfterPlayback = true
            problem = failure.shown
        }
        return effects + [.closeMic, .speak(failure.spoken), .haptic(.failure)]
    }

    /// The current turn is over (played out, or nothing to play): end, pause, announce, or listen again.
    private mutating func finishTurn(at now: Date) -> [Effect] {
        let turn = current
        current = nil
        playing = false
        // Only a turn with words counts: noise (an empty transcript) doesn't keep the conversation open.
        if turn?.accepted == true { lastActivity = now }
        if turn?.done?.endConversation == true { closing = true }
        if endAfterPlayback {
            // A fatal failure was said.
            return finish(at: now, problem: problem, haptic: nil, tellMac: false)
        }
        if pausing {
            // The app left while this played: pause (the same conversation goes on when it comes back).
            let effects = finish(at: now, problem: nil, haptic: nil, tellMac: false)
            resumable = true
            return effects
        }
        if !queue.isEmpty { return announce(queue.removeFirst(), at: now) }
        if closing { return finish(at: now, problem: nil, haptic: .stop, tellMac: false) }
        // Noise turns long after the last words: the quiet end (the tick may never see "listening" in a noisy room).
        if now.timeIntervalSince(lastActivity) >= idleTimeout {
            return finish(at: now, problem: nil, haptic: .stop, tellMac: true)
        }
        phase = .listening
        listeningSince = now
        return [.openMic]
    }

    private mutating func tap(at now: Date) -> [Effect] {
        switch phase {
        case .idle:
            return start(at: now)
        case .starting, .listening:
            return []
        case .hearing:
            lastActivity = now
            return [.flushMic]
        case .thinking, .speaking:
            // Barge in: stop the reply and listen.
            if endAfterPlayback { return finish(at: now, problem: problem, haptic: .stop, tellMac: false) }
            var effects: [Effect] = []
            if let current, current.kind == .bridge, current.done == nil || playing {
                effects.append(.cancel(turnId: current.id, conversationId: conversationId))
            }
            update { $0.interrupted = true }
            current = nil
            playing = false
            phase = .listening
            listeningSince = now
            lastActivity = now
            return effects + [.stopPlayback, .openMic, .haptic(.click)]
        }
    }

    // MARK: - Captions

    private mutating func record(_ exchange: Exchange) {
        exchanges.append(exchange)
        if exchanges.count > Self.maxExchanges { exchanges.removeFirst(exchanges.count - Self.maxExchanges) }
    }

    private mutating func update(_ change: (inout Exchange) -> Void) {
        guard let id = current?.id, let index = exchanges.lastIndex(where: { $0.id == id }) else { return }
        change(&exchanges[index])
    }
}
