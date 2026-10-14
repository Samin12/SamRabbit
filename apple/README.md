# SamRabbit for iPhone and Apple Watch

Native apps that control SamRabbit (the R1's voice orchestrator, T3 Code tasks, the calendar, the Heptabase
journal, the Mac, generated UIs and the R1's conversations) through one hub: the Mac bridge's mobile API
(`/v1/mobile/*`, see `CONTRACTS-WAVE4`). Phone, widgets and watch talk only to the bridge, with a
per-device bearer token, over the local network (or Tailscale).

```
apple/
  project.yml            XcodeGen spec (the .xcodeproj is generated, never committed or hand-edited)
  generate.sh            generates SamRabbit.xcodeproj (and renders the icon if it is missing)
  Config/Signing.xcconfig   the one place for signing (DEVELOPMENT_TEAM)
  Shared/SamRabbitKit/   Swift package used by every target (models, client, storage, orb, theme, ...)
  Shared/Intents/        App Intents compiled into the app and the widget extension
  iOS/App/               the iPhone app (SamRabbit, com.samrabbit.mobile); iOS/App/Talk: the live conversation
  iOS/Widgets/           widget extension (com.samrabbit.mobile.widgets): widgets, control, Live Activity
  iOS/WidgetViews/       widget faces, shared by the extension and the app (gallery, render harness)
  iOS/UITests/           the iPhone's Action Button test (opt-in, presses the simulator's button)
  iOS/Resources/         asset catalog (AppIcon from the orb, accent and launch colours)
  watchOS/App/           the Apple Watch app (SamRabbitWatch, com.samrabbit.mobile.watchkitapp), embedded in the iPhone app;
                         watchOS/App/Assistant (the conversation engine) is compiled into the iPhone app too
  watchOS/Widgets/       complications and the Ask control (com.samrabbit.mobile.watchkitapp.widgets)
  watchOS/Intents/       the watch's App Intents (the Ask control's), compiled into the watch app and its extension
  watchOS/ComplicationViews/  complication faces, shared by the complications and the watch app's preview renderer
  watchOS/UITests/       the watch walkthrough (real taps against the fake bridge) and the watch-face setup
  watchOS/Resources/     the watch's asset catalog (the same orb icon)
  tools/render_icon.swift   renders the 1024 px icon with SamRabbitKit's orb math
  dev/fake_bridge.py     the whole mobile API with fixtures, for simulator work and tests
  dev/run-sim.sh         build, install and launch on a simulator
  dev/run-watch.sh       build, install and launch the watch app on the watch paired with the booted iPhone
```

## Quick start (simulator, no Apple ID needed)

```sh
apple/generate.sh                                   # needs XcodeGen 2.46+ (brew install xcodegen)
/usr/bin/python3 -I apple/dev/fake_bridge.py        # fake bridge on 127.0.0.1:3799, pairing code SAMRABBT
apple/dev/run-sim.sh                                # build + install + launch on the booted iPhone simulator
xcrun simctl openurl booted 'samrabbit://pair?h=127.0.0.1:3799&c=SAMRABBT&n=Fake%20Mac'
```

Or in the app: Settings > Enter code manually, address `127.0.0.1:3799`, code `SAMR-ABBT`.

The Apple Watch pairs itself through the iPhone (no code on the watch):

```sh
xcrun simctl pair <watch-udid> <iphone-udid>        # once; e.g. Apple Watch Series 12 (46mm) with iPhone 18 Pro
apple/dev/run-watch.sh                              # build + install + launch on that watch
apple/dev/run-watch.sh -- -SamRabbitPage needs      # open on a page (status, needs, working, upnext, quick)
```

Installing the iPhone app also carries the watch app (`SamRabbit.app/Watch/`); on a real iPhone the Watch app
installs it. On the simulator `run-watch.sh` installs it directly.

The fake bridge never touches T3, Google Calendar, Heptabase, the R1 or the live bridge on :3780. It invents
everything in memory (only pairings persist, in `apple/dev/.state/`). Approving, answering and replying move
threads along on their own; new tasks run about 45 s (so the Live Activity has something to show); the live R1
conversation gets a streamed exchange every minute (`--no-chatter` turns that off). Loopback helpers:
`POST /__fake/reset`, `POST /__fake/settle` (finish every pending step), `POST /__fake/chatter`,
`GET /__fake/journal`, `POST /__fake/rerequest {threadId, text?}` (the open approval or question was answered
elsewhere and T3 asks a new one: same thread, new `requestId`) and `POST /__fake/t3 {available}` (T3 Code stops
answering: the summary says `t3.available=false`, every `/v1/mobile/t3/*` route answers 503 `t3_unavailable`) and
`POST /__fake/transcribe {mode?, text?, delay?}` / `GET /__fake/transcribe` (what the watch's voice route answers:
`ok` with the canned `text`, `empty`, `unavailable`, `permission`, `failed`, `busy`, `no_speech` or `missing`, an
older bridge without the route; GET lists the recordings that arrived: size, type, lang, device).
`POST /v1/mobile/transcribe` checks a recording like the real bridge (Content-Type, Content-Length, 2 MiB, the
container's own bytes, the m4a's length) and the summary carries `transcribe: {available, reason?}`.
The watch's assistant (CONTRACTS-WAVE5, the streaming turn protocol) is there too, with canned answers:
`POST /v1/mobile/assistant/turn` (a 16 kHz WAV utterance or `{text|announce}`; with `Accept:
application/x-samrabbit-stream` a chunked stream of `J` JSON events and `A` PCM16 16 kHz frames of a made-up voice,
else the buffered JSON answer), `/assistant/session`, `/assistant/cancel` (the stream ends with
`done{interrupted:true}`), `/assistant/end`, `GET /assistant/announcements`, and `assistant: {available, brain,
model, chatgpt}` in the summary. `POST /__fake/assistant {mode?, say?, heard?, delay?, pace?, brain?, clear?, code?,
hold?, ping?, busyFor?}` / `GET /__fake/assistant` (what arrived: turns, sessions, cancels, ends, turns refused 409)
and `POST /__fake/announce {say?, kind?, audio?}` (`audio: "broken"`: a clip no player can read); `hold` keeps the
stream quiet after `heard` (a long tool call) with a `{"type":"ping"}` every `ping` seconds, `busyFor` refuses turns
409 for that long from the first one, `code` is the `error` mode's code (then `done`, like the real bridge); modes
`ok`, `noaudio`, `noise`, `end`, `error`, `slow`, `busy`, `unavailable`, `drop` (no answer at all),
`buffered`, `buffered_clip` (an AAC clip, like the Claude fallback's MP3) and `missing` (an older bridge).
A turn that hears "task", "draft", "notes" or "start" reports the task it started (`t3.started`, thread
`t_relnotes`) and that thread then exists (working), so the iPhone's Talk can open it in Tasks; "calendar", "next"
or "meeting" brings an "Up next" card. Text turns (`{text}`, the iPhone's keyboard in Talk) are answered the same way.
The Mac app's twin of these routes, `/v1/desktop/assistant/*`, answers the same with the desktop token
(`X-SamRabbit-Desktop: fake-desktop-token`, loopback only), recorded with `deviceId: "mac"`.
Pending approvals and questions carry `requestId` (questions also `questionId`) and `respond` refuses a stale id
with 409 `t3_request_not_pending`, exactly like the real bridge.
The inbox (CONTRACTS-WAVE6 §A with the phone's rules of WAVE7 C): `GET /v1/mobile/inbox[?after=&wait=]` (one list
of the T3 threads, seven Claude Code and Codex sessions on a made-up Mac and the recent chats, in the contract's
order, with a revision that grows on every change and a long-poll), `GET /inbox/items/<id>` (the item and its last
messages), `/inbox/targets`, `POST /inbox/new {text, projectId?, agent?, model?}` and `POST /inbox/items/<id>/approve |
answer | reply | stop | seen`. Like the real bridge the phone's items never list `open` (`POST …/open` answers 409
`unsupported_action`); a reply to a Claude Code or Codex CLI session nobody runs "continues in a new Terminal window
on the Mac" (`202 {how: "terminal", message}`; it is then live there and finishes six seconds later), a live one
answers 409 `session_live`, a Codex Desktop thread 409 `unsupported_action`. `POST /__fake/inbox {missing?, id?, live?,
unread?, unsure?, status?, clear?}` / `GET /__fake/inbox` (`missing`: an older bridge without the inbox, every route 404;
change one session; `unsure`: the Mac's process list didn't answer, so neither `live` nor `reply` and a reply gets 503
`session_check_failed`; what arrived: replies, seen, new tasks, refusals).

## Tests

```sh
cd apple/Shared/SamRabbitKit && swift test          # 263 tests on macOS, including the client against the fake bridge
# the same suite (minus the fake-bridge tests) on the watch simulator, and compiled for the watch's hardware:
(cd apple/Shared/SamRabbitKit && xcodebuild -scheme SamRabbitKit -destination 'platform=watchOS Simulator,name=Apple Watch Series 12 (46mm)' test)
(cd apple/Shared/SamRabbitKit && xcodebuild -scheme SamRabbitKit -destination generic/platform=watchOS \
  build-for-testing CODE_SIGNING_ALLOWED=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES)
xcodebuild -project apple/SamRabbit.xcodeproj -scheme SamRabbitWatch -destination generic/platform=watchOS \
  CODE_SIGNING_ALLOWED=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES build   # arm64 and arm64_32 slices
xcodebuild -project apple/SamRabbit.xcodeproj -scheme SamRabbit \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' test   # the same suite minus the fake-bridge tests, on iOS
curl -X POST 127.0.0.1:3799/__fake/reset             # then the watch walkthrough (real taps, screenshots attached):
xcodebuild -project apple/SamRabbit.xcodeproj -scheme SamRabbitWatch \
  -destination 'platform=watchOS Simulator,name=Apple Watch Series 12 (46mm)' test
# just the voice input: -only-testing:SamRabbitWatchUITests/WatchVoiceTests
# the conversation:    -only-testing:SamRabbitWatchUITests/WatchConversationTests
# the iPhone's Talk (opt-in: the address of this branch's fake bridge; pairs the app with it when unpaired, or always
# with TEST_RUNNER_SAMRABBIT_FAKE_PAIR=1; screenshots also go to TEST_RUNNER_SAMRABBIT_SHOTS, and
# TEST_RUNNER_SAMRABBIT_ANIMATED=1 keeps the orb moving for them):
TEST_RUNNER_SAMRABBIT_FAKE_BRIDGE=127.0.0.1:3799 xcodebuild -project apple/SamRabbit.xcodeproj -scheme SamRabbit \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' test -only-testing:SamRabbitUITests/TalkUITests
# Tasks with every agent on the Mac (the inbox; the same opt-in variables):
TEST_RUNNER_SAMRABBIT_FAKE_BRIDGE=127.0.0.1:3799 xcodebuild -project apple/SamRabbit.xcodeproj -scheme SamRabbit \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' test -only-testing:SamRabbitUITests/TasksUITests
# voice notes and the morning brief (wave 8; the same opt-in variables):
TEST_RUNNER_SAMRABBIT_FAKE_BRIDGE=127.0.0.1:3799 xcodebuild -project apple/SamRabbit.xcodeproj -scheme SamRabbit \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' test -only-testing:SamRabbitUITests/VoiceNoteUITests \
  -only-testing:SamRabbitUITests/BriefingUITests
TEST_RUNNER_SAMRABBIT_FAKE_BRIDGE=127.0.0.1:3799 xcodebuild -project apple/SamRabbit.xcodeproj -scheme SamRabbitWatch \
  -destination 'platform=watchOS Simulator,name=Apple Watch Series 12 (46mm)' test \
  -only-testing:SamRabbitWatchUITests/WatchVoiceNoteTests
```

`VoiceNoteUITests` (iPhone, the made-up voice, real taps, nothing played): Home's Voice note records at once and sends
itself after a pause ("Sent ✓ — Added to your journal", his words after the cue in the fake journal, the m4a with
the note's id, time and source, Home's voice-notes line); Stop & send of a note the Mac only saved, waiting in Tasks
with its suggestion, Start task; nothing heard (Try again); the Mac out of reach (kept, Home says it waits, "Tap to
try now" sends it at once with the same id and the line follows); the intent (`-SamRabbitIntent note`) and its second
press, and a third while it sends (`-SamRabbitIntentAgain 5,1.5`: the next note records at once, both reach the Mac); a `samrabbit://capture` link waits for a tap and a cancelled note is never sent; the Live Activity's Stop on
the Lock Screen and the outcome there without his words. `BriefingUITests` (`-SamRabbitBriefAllDay
YES` lifts the noon limit in debug builds): the brief at the top of Home, Draft reply (a draft, Open draft, the Mac's
line), Remind me at 2 PM (the menu), Make task (its words first: Cancel starts nothing, Start sends what he typed),
the headline's time in 12-hour style, Lunch (no link) not "Join Lunch",
Block 30 min on the clash, Done, Today's conflict, FYI and Dismiss, what it read, an agent's Review
opening its task, Refresh; no brief yet leaves Home as it was. `WatchVoiceNoteTests`: the Voice Note control's intent
records and sends itself, Stop & send through the iPhone with the watch's token, the Brief page and Done, Make task's
confirm page (its exact words, then Start sends them).

`TasksUITests` (iPhone, real taps against the fake bridge's inbox): Home counts every agent's needs-you (line and tab
badge) and shows a Claude Code card beside T3's; Tasks lists T3, Claude Code and Codex with their glyphs under Needs
you / Working / Recent, filters by source, Mark seen on a failed Codex run (the Mac is told, the badge drops) and
Approve on a T3 card exactly as before; a finished Claude Code session takes a reply (it continues in a Terminal
window on the Mac, then shows live there with no reply field, then its answer), one waiting for a permission in its
terminal says so with what it asks and offers no reply, a Codex Desktop thread says the app runs it; opening a
finished task is seeing it (a Claude Code session, again when it finishes while open; a T3 thread that finished
leaves Needs you and the badge drops; a T3 failure is marked seen and stays); a session the Mac couldn't check says
"Can't tell if it's open on your Mac" and offers no reply; T3 Code down keeps the Claude Code and
Codex rows with "T3 not connected", T3's last rows at the end, read-only and out of the badge; an older bridge without
the inbox gets T3's thread list as before; New task goes with Codex and its model to `/inbox/new`.
`InboxTests` / `InboxBridgeTests` (SamRabbitKit): decoding and the contract's order, where each item waits (`can`
without `open`, `live`, the bridge's words), T3 items as their threads, the counts past the 60-item cap, the summary
overlay (a hiccup keeps the last counts, an older bridge leaves T3's), the widgets' cache and reloads (a working
agent's every line doesn't reload them), "what needs me", the alerts for Claude Code and Codex prompts (not
time-sensitive, guesses skipped, stand-in request ids), seeing an item (`seenMark`, `markedSeen`), when a screen reads
its item again (`changeMark`), a session the Mac couldn't check, T3's last rows while it is down and the T3-list
fallback (`InboxRows`), older lists (`isNewer`), 32-bit safety, and the client against the fake bridge: the long-poll waking
up, reply / `session_live`, seen, T3 through the inbox, targets and new tasks, T3 down, an older bridge.

`TalkUITests` (iPhone, real taps, the made-up voice instead of the microphone, the simulator muted): Home's Talk button
opens Talk listening; the voice is heard, the reply streams in as the caption with the task it started, and it listens
again; a typed turn (`{text}`) with its card; mute and unmute; Stop during a long reply (the Mac is told to cancel); the
bar over the tab bar and back; the transcript, and its task opened in Tasks while the conversation goes on; End from
the bar (the Mac is told). Typing while a reply plays: while the Mac still sends it, the reply is cancelled there and
the typed turn is answered in full (never stopped by that cancel); once the Mac has sent all of it, no cancel goes at
all. `samrabbit://talk` opens straight into a conversation and End closes it; a Mac that drops
the turn is said and shown with what to do. The conversation goes on in the background (the second utterance is
heard and answered behind the Home Screen), the Dynamic Island and the Lock Screen show the Live Activity, and its End
(`EndTalkIntent`, run by the app) ends the conversation and the activity.

**32-bit watch hardware.** The watch's arm64_32 slice has a 32-bit `Int`, while every simulator is 64-bit: epoch
milliseconds (`at`, `lastAt`, `nextBefore`, ...), cursors, sequence numbers and millisecond durations are `Int64` in
SamRabbitKit, JSON numbers become integers only through `JSONNumbers` / `JSONValue.int64` (never `Int(Double)`, which
traps), and frame and WAV lengths are read as `UInt32`. `Watch32BitTests` decodes payloads with real millisecond
values and checks with `Int32Range.violations(in:)` that no `Int` in the decoded models holds a value a 32-bit `Int`
can't; building the tests for `generic/platform=watchOS` also compiles them for arm64_32 (a 64-bit literal in an
`Int` fails there).

The fake-bridge tests start `fake_bridge.py` on a free port per test (macOS only: the iOS simulator cannot spawn
processes). They cover pairing (a wrong or expired code, the rate limit, host failover and promotion), unpairing
(the Mac revokes the phone and its watch), re-provisioning the watch (the old child token stops working), one
reused client per pairing, the summary, threads
(approve/answer/reply/stop/create, a stale card refused with 409, T3 down while the summary works), conversations
and events into the timeline, SSE, blobs, generated UIs,
calendar, the journal, the Mac, child (watch) tokens and the shared actions/notification planning. The relay tests
run the watch's `BridgeClient` against a closed port, a port that never answers and the fake bridge, with the iPhone's
half of the relay in process (`BridgeAccount.performRelayed`): reads and unsent writes go through the phone with the
watch's own token (a revoked watch gets 401 through the phone too), pairing/unpairing/device routes are never relayed,
a write that may have reached the Mac (a POST that timed out) is never sent twice, and the bridge's error envelope
survives the relay. Unit tests cover the links (every link that writes needs confirmation), the notification keys
and the widget reload rule (compared as encoded bytes, so sub-millisecond dates don't reload every time), and
re-pairing (the same Mac retires the old device; a wrong code keeps the old pairing; another Mac is left alone).
Voice (`VoiceTests`, `VoiceBridgeTests`): chunking and the phone's reassembly (any order, repeats, mismatched or
oversized pieces, stalled recordings), the upload as the bridge sees it (`audio/mp4`, the file's exact bytes,
`?lang=`, the device's token), the recording format (AVFoundation encodes `VoiceFormat.recorderSettings`), every
error code to its friendly words, when a recording ends (`VoiceActivity`), and the iPhone relay (chunks, the watch's
own token, a revoked watch refused, a Mac that times out tried through the phone).

The watch walkthrough (`watchOS/UITests/WatchWalkthroughTests.swift`, needs the fake bridge and the paired simulators)
opens every page, approves, answers a question, taps Approve on a card whose request was replaced on the Mac
(refused: "Request changed", the new request shows), opens a task, blocks 30 minutes, says a journal note and a new
task (voice, see below), runs a request through the iPhone (`-SamRabbitRoute phone`) and, after the watch's token is
revoked on the bridge, reconnects through the iPhone (these run with `-SamRabbitConversation off`).
`WatchVoiceTests` drives the voice capture:
listening, transcribing, review and Send for a new task, Reply, Answer and a journal note; Stop and Say again; voice
unavailable (from the summary and from the Mac), a failed transcription and no speech; through the iPhone in chunks;
the microphone refused; and checks that no keyboard or text field ever appears. `WatchFaceTests` (opt-in, `TEST_RUNNER_SAMRABBIT_FACES=setup`)
adds Infograph, Modular and Activity Digital faces with the SamRabbit complications and screenshots them.
`WatchConversationTests` drives the conversation with the made-up voice: it opens listening, hears, streams the reply
(caption, the task it started) and listens again; tap to interrupt (the Mac is told to cancel); a reply without audio
spoken by the watch; a Mac that can't be reached (said, then the end); an announcement between turns; the end after a
quiet while and by the Mac; the buffered fallback with a clip; the Action Button's intent opening the conversation;
the whole turn through the iPhone with the watch's own token; Stop; Stop while the audio is still starting (the
microphone stays off, and Stop then Talk inside that window runs one start); a warm-up refused while the audio starts
(said once it runs, then the problem); a 45 s tool call with no keep-alive waited for; the Digital Crown during a reply
and straight back (it goes on listening); a fatal `error` event mid-stream (said, then the end); a 0.22 s "yes"
(`-SamRabbitFixtureLength 0.22`) sent like any utterance; 409 through the iPhone retried until the Mac answers; an
announcement clip that can't be read, said by the watch. In debug builds the state line's accessibility value says `audio on`/`audio off`
(whether the microphone is live) for these checks.

The Action Button tests press the simulator's real Action Button (`XCUIDevice.press(.action)`); both are opt-in:
`ActionButtonUITests` (iPhone, `TEST_RUNNER_SAMRABBIT_ACTION_BUTTON=1`, after setting the simulator's Action Button to
the SamRabbit control) and `WatchActionButtonTests` (Apple Watch Ultra simulator, `=1` sets the watch's Action Button,
`=press` only presses). See "The Action Button" below.

## Installing on your own iPhone and Apple Watch

1. Xcode > Settings > Accounts: add your Apple ID.
2. Create `apple/Config/Signing.local.xcconfig` (git-ignored):
   ```
   DEVELOPMENT_TEAM = ABCDE12345
   CODE_SIGN_STYLE = Automatic
   CODE_SIGN_IDENTITY = Apple Development
   ```
3. `apple/generate.sh --open`, pick your iPhone, Run. Automatic signing registers the App Group
   `group.com.samrabbit.mobile` and the keychain group for every target (the watch app and its complications too).
4. On the Mac: SamRabbit > Pair iPhone… and scan the QR code with the Camera app (or in Settings > Scan).
5. The watch app comes with the iPhone app: install it from the Watch app on the iPhone (My Watch > SamRabbit), or
   run the `SamRabbitWatch` scheme on the watch. It connects through the iPhone by itself; add the complications by
   editing a watch face (SamRabbit > Needs You / Next Up).

## How it is built

**SamRabbitKit** (local Swift package, iOS 26 / watchOS 26 / macOS 26, Swift 6 language mode). Public API:

| Area | Types |
|---|---|
| Models (lenient decoding, ISO-8601 or epoch-ms dates) | `MobileSummary`, `TaskThread`, `ThreadStatus`, `PendingAction`, `ThreadDetail`, `ConversationSummary`, `SyncEvent`, `CalendarEvent`, `Agenda`, `MacState`, `GeneratedArtifact`, `JSONValue`, `MobileSummary.sample()`; the inbox: `InboxSnapshot`, `InboxItem` (`heldOnMac`: `InboxHold`; `seenMark`, `markedSeen`, `changeMark`), `InboxRows` (what Tasks lists; T3's last rows while it is down), `InboxSource`, `InboxPending`, `InboxItemDetail`, `InboxTargets`, `InboxReplyResult`, `CreatedInboxTask`, `InboxOverview` (`summary.inbox`, `needsYouCount` / `workingCount`) |
| Client | `BridgeClient` (every mobile route, multi-host failover, `stream(after:)` SSE, `raw(_:)`; the inbox: `inbox(after:wait:)`, `inboxItem`, `inboxReply`, `inboxSeen`, `inboxApprove`, `inboxAnswer`, `inboxStop`, `inboxTargets`, `inboxNew`), `BridgeError` (`isRouteMissing`, `isSessionLive`, `isSessionCheckFailed`), `LiveSyncFeed` (reconnecting SSE), `ServerSentEventParser` |
| Pairing and links | `PairLink` (`samrabbit://pair?h=&c=&n=`), `AppLink` / `LinkAction` (every `samrabbit://` link; the ones that write become `.confirm`), `BridgeHost`, `PairingCode`, `Pairer` (tries hosts in order), `PairResponse` |
| Storage | `BridgeAccount` (pairing in the App Group, token in the Keychain, one cached `BridgeClient` per pairing, `unpair()` tells the bridge, the watch's child token and `performRelayed`), `KeychainStore`, `SharedContainer`, `SummaryCache` (`publish`: reloads widgets only on change), `TaskTracker` |
| Shared behaviour | `SamRabbitActions` (ask, block, note, open on Mac, approve, answer, refresh + widget reload with the inbox's counts on the iPhone (`includesInbox`), spoken "what needs me"), `AlertPlanner` (keyed by thread + request id; Claude Code / Codex prompts by item + tool call), `SpokenSummary`, `Formatting` |
| Conversations | `ConversationTimeline` (port of the desktop `store.js`), `TimelineItem`, `GenCard` |
| Look | `SamTheme` (colours, `glassCard()`, `samScreen()`, `StatusChip`, `PulseDot`, `SectionHeader`), `OrbView(mood:)`, `OrbRenderer`, `OrbMood`, `SourceGlyph` (T3 / Claude / Codex / SamRabbit tiles, the dock's marks) |
| Watch link | `WatchContext` (applicationContext), `WatchRelay` (sendMessage relay), `BridgeRelay` (the client's second route) |
| Assistant | `ConversationMachine` (the conversation's rules; the iPhone adds `typed` turns and `muted`), `SpeechDetector` + `NoiseFloor`, `AssistantStream` / `AssistantStreamParser` (frames), `AssistantEvent`, `AssistantReply` (buffered), `AssistantTurnRequest` / `AssistantTurnResponse`, `BridgeClient.assistantTurn` / `assistantSession` / `assistantCancel` / `assistantEnd` / `assistantAnnouncements`, `TurnRelay` + `TurnRelayHost` (turns through the iPhone), `WAV`, `PCM16`, `AssistantStatus` (`summary.assistant`), `AudioSessionClaims` (who holds the app's audio session: Talk, dictation); `device: .mac` for the desktop app's wording; `BridgeClient(api: .desktop)`: the same calls through the bridge's desktop API (`/v1/desktop/assistant/*`, the desktop token), used by the Mac app (`companion/desktop`, which compiles SamRabbitKit as a static library) |
| Live Activity | `TaskActivityAttributes` (iOS); Talk's `TalkActivityAttributes` (iOS), `TalkActivityState` and `TalkPhase` (what Talk shows in a word, the Live Activity's line and when it updates) |

**The orb** is the desktop `OrbRenderer.swift` math, unchanged, evaluated on the CPU: `OrbRenderer.field`
renders only the surface at about one sample per point (soft gradients, bilinear upscaling), and `OrbView`
clips it to a vector circle and draws the halo as a gradient, at 30 fps in a `TimelineView` (paused with Reduce
Motion; `animated: false` for widgets). No Metal shader: it would need the separately downloaded Metal toolchain
on every Mac that builds the app.

**The app**: Home (orb header, quick actions, Needs you with inline Approve/Deny/answers, Working, Up next,
latest conversation), Chats (search, live badges, timeline with cards/images/generated UIs, live over SSE,
generated UIs open interactive in a `WKWebView` with a non-persistent store and a content rule list that only
allows the four CDNs the documents import from: `GeneratedUISandbox`, one rule per scheme and host because WebKit
rejects `|` in `url-filter`; the list is compiled before anything loads and the viewer refuses to open the document
when it does not compile; `SandboxTests` compile it and, on macOS, check in a real web view that a page reaches a
local server without the list and nothing with it), Tasks (every agent on the Mac, see below: sections, source
filter, Markdown thread detail, approve/deny/answer, composer with dictation, Stop, New task with Claude or Codex,
its model and a project), Mac (state, open app or link, screenshot with
pinch zoom, Generate UI), Settings (QR scan via VisionKit, manual entry, `samrabbit://pair` links, bridge
addresses, notifications, widget gallery, Action Button help). Dictation: the keyboard mic everywhere, plus a mic
button (`SFSpeechRecognizer`, on-device when available, Apple's speech service when the on-device model isn't there;
the speech, audio-tap and result callbacks are nonisolated, since Swift 6 traps a main-actor closure called on
another queue).

**Deep links** (`AppLink`): `samrabbit://pair?…`, `ask[?text=]`, `note[?text=]`, `generate[?text=]`,
`block[?minutes=&title=]`, `mac/open?app=|url=`, `thread/<id>`, `inbox/<itemId>` (a Claude Code or Codex session in
Tasks; only opens it), `conversation/<id>`,
`tab/<home|chats|tasks|mac|settings>`, `mac/screenshot`, `talk` (also `voice`, `assistant`: Talk, started at once,
like the watch's complications; the link writes nothing itself). A link can come from any web page or message, so the ones
that write (`block`, and `ask`/`note`/`generate`/`mac/open` with content) never act on their own: they open a
confirmation sheet ("A link wants to Block 45 minutes on your calendar", now until when, Confirm / Cancel, and Edit
first for text). Without content they only open the empty composer. App Intents (Siri, Shortcuts, the widgets'
buttons, the control) still run directly: the person started them.

**Widgets** (`SamRabbitWidgets`): Status (small), Tasks (medium), Up Next (medium, interactive Block 30m),
Dashboard (large, Talk + Voice note: the live call and a voice note, `TalkToSamRabbitIntent` / `VoiceNoteIntent`),
Morning Brief (medium + large, Done and Dismiss on the items, `BriefingItemIntent` in the background; Lock Screen
rectangular "3 to do" and the headline), Needs You (Lock Screen circular + inline), Next Up (Lock Screen rectangular),
Talk (Lock Screen circular + rectangular: opens Talk), Voice Note (Lock Screen circular + rectangular, a
`Button(intent:)`: a link never starts the microphone), the controls "Talk (SamRabbit)" (`AskControl`, the Wave 4
kind, now the live call), "Talk to SamRabbit" and "Voice Note" (`VoiceNoteControl`), and the "Task running", Talk
and Voice note Live Activities (Lock Screen + Dynamic Island). The timeline
provider reads the summary the app saved in the App Group and fetches a fresh one itself (8 s budget), every
15 minutes. The app, the background refresh and the actions hand fresh summaries to `SummaryCache.publish`, which
reloads the timelines only when what the faces draw changed (`generatedAt` aside; the inbox rows' last words and
times move with every line a working agent writes, so those reload at most every 5 minutes) or the last reload is 30
minutes old.
The counts and the Tasks / Dashboard rows cover every agent: the app, the background refresh, the intents and the
provider's own fetch read `/v1/mobile/inbox` beside the summary and put its counts and first five agents' items into
it (`summary.inbox`); without it (an older bridge, or the watch) they are T3's. A Claude Code or Codex row opens
`samrabbit://inbox/<id>`.

**App Intents** (Siri and Shortcuts, phrases in `AppShortcuts.swift`): Talk to SamRabbit ("Talk to SamRabbit",
"Chat with SamRabbit": a live conversation, `TalkToSamRabbitIntent`), Voice Note ("SamRabbit note", "Take a note
with SamRabbit": `VoiceNoteIntent`, the recorder, recording), Ask SamRabbit, Ask by Voice ("Dictate to
SamRabbit", "Ask SamRabbit by voice": opens Ask listening), Block Time ("Block 30 minutes with SamRabbit"), Add Journal Note, What Needs Me
(spoken), Open on Mac, Screenshot My Mac. The two that open the app use `supportedModes = .foreground(.immediate)`
(iOS 26's replacement for `openAppWhenRun`).

## The Action Button

Apps can't read the button or assign it; the person picks an action in Settings. SamRabbit offers:

- **iPhone 15 Pro and later, Talk**: the "Talk to SamRabbit" control (`TalkControl`, `TalkToSamRabbitIntent`), or
  the "Talk" App Shortcut under Shortcut. Press and hold: SamRabbit opens in a live conversation; pressed again while
  talking it acts like a tap on the orb (send now, or interrupt). Settings > Action Button in the app has the steps.
- **iPhone 15 Pro and later, the control set in Wave 4**: `AskControl` keeps its kind (`com.samrabbit.control.ask`,
  so every place it was put keeps working) but now runs `TalkToSamRabbitIntent` and is called "Talk (SamRabbit)": his
  button opens the live call with nothing to change (wave 8). Ask with dictation stays the "Ask by Voice" shortcut.
- **iPhone 15 Pro and later, Voice Note**: the "Voice Note" control (`VoiceNoteControl`, `com.samrabbit.control.note`,
  "Hold to Record a voice note") or the "Voice Note" shortcut (also for Back Tap). It opens the recorder already
  recording; pressed again while it records it stops and sends. See "Voice notes" below.
- **Apple Watch Ultra (watchOS 26+)**: the watch's own "Ask SamRabbit" control (`WatchAskControl` in the
  complications extension, `OpenSamRabbitWatchIntent` in `watchOS/Intents`, compiled into the watch app and the
  extension). The iPhone's control opens the iPhone app, so watchOS doesn't offer it on the watch. On the watch:
  Settings > Action Button > **Action** (watchOS 27: Choose Action) > **Control**, then **Control** (it says Configure
  until set) > SamRabbit > **Ask SamRabbit**. One press opens SamRabbit straight into a live conversation (pressed
  again while talking: like a tap on the orb, send now or interrupt). Siri on the watch: "Ask SamRabbit", "Talk to
  SamRabbit" (`SamRabbitWatchShortcuts`).

How it works: the intent leaves `samrabbit://ask?listen=1` in the App Group (`PendingRoute`, SamRabbitKit) and posts
`PendingRoute.didChange`. The app takes it when it becomes active, or at once when it is already in front (on the
iPhone pressing the button again starts dictation again; on the watch it acts on the conversation). A route older than two minutes is dropped. Only the
app's own intents may turn the microphone on: `AppLink(url:fromApp:)` keeps `listen` only for them, and a
`samrabbit://ask?listen=1` link from a web page just opens the empty composer. The help is in Settings > Action
Button (iPhone, with "Try it here") and at the bottom of the watch's Quick page.

Checked in the simulators: on the iPhone 18 Pro simulator the control is offered in Settings > Action Button >
Controls and "Ask by Voice" under Shortcut. Pressing the simulator's Action Button (both ways) opens Ask and starts
dictation, cold and while the app is open. The Simulator has no speech recognizer, so dictation then stops with
"Dictation stopped before it heard anything". On the Apple Watch Ultra 4 simulator the control can be set as the
Action Button's control, and pressing the button opens SamRabbit. In that simulator the control picker listed only
the system's own controls, and a watch app freshly installed by `xcodebuild test` isn't registered yet (the press
then fails with "“Ask SamRabbit” failed"). Install with `simctl install` and wait a moment.

**Notifications** (no push): `BGAppRefreshTask` (`com.samrabbit.mobile.refresh`, about every 15 min) and the
foreground refresh (every 20 s) run `AlertPlanner`: a local notification for each new needs-you request and for
tasks started from the phone that finish. Needs-you alerts are keyed by thread id + T3 request id (kept a week in
the App Group), never by the pending text or the list they came from, so the foreground and background agree and a
request is announced once; a thread whose request id is not known yet (summary threads) waits for one. A Claude
Code or Codex session waiting for a prompt in its terminal (or the Codex app) is announced the same way, keyed by
its item id + the tool call it waits on ("Waiting for you in the terminal: Bash: …"), and opens that item; only
the Mac answers those, so they are normal alerts, not time-sensitive. A prompt the bridge only guesses at ("May be
waiting for you …": a Codex tool call that went quiet, which a long build is too) is not announced; one whose tool
call the bridge doesn't know (its stand-ins `terminal` / `codex`) is keyed with the time it started waiting. The
icon's badge counts every agent that needs you and follows every check (it drops after Mark seen or an answer). On the simulator the alerts are silent unless `-SamRabbitAudioOut on`
(Talk's rule: nothing out loud).

**Pairing again** while paired with the same Mac (an address in common) retires the old device there: once the
Mac accepted the new code, the old token calls `POST /v1/mobile/unpair` (the old iPhone and its watch go), then the
new token replaces it here. A wrong code keeps the old pairing working; pairing with another Mac only forgets the
first one here.

**Unpair** (Settings) calls `POST /v1/mobile/unpair` first (the Mac revokes this iPhone and the watch it
provisioned; best effort, 6 s), then forgets the pairing, the token and the watch's token here either way. A wrong
or expired pairing code (401 `invalid_code`) says "That code is wrong or expired — get a new one on your Mac", too
many tries (429) says to wait; neither is confused with a token the Mac stopped accepting. The Simulator has no `BGTaskScheduler` ("not available on this
platform"), so the background part only runs on a device; to try it there from the debugger:
`e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"com.samrabbit.mobile.refresh"]`.

## Talk: the live conversation on the iPhone

Like talking to the R1 or ChatGPT Voice (CONTRACTS-WAVE6 D). **Entry points**: the big Talk button on Home (and the
Home orb), `samrabbit://talk`, Siri and Shortcuts ("Talk to SamRabbit"), the Action Button (the Talk control or the
Talk shortcut), the Control Center control and the Lock Screen widget. The intents leave `samrabbit://talk` as a
`PendingRoute` like Ask does.

**The engine is the watch's**: `watchOS/App/Assistant` (`ConversationEngine`, `AudioGraph`, `ConversationFixture`) is
compiled into the iPhone app as well, with `#if os(...)` where they differ, and the rules stay SamRabbitKit's
`ConversationMachine`. On the iPhone the session is `.playAndRecord` / `.voiceChat` with `.defaultToSpeaker`,
`.allowBluetoothHFP`, `.allowBluetoothA2DP`, and the microphone goes through voice processing (echo cancellation);
voice processing is switched on while the engine is new, before anything is connected (it changes the formats);
AirPods coming or going restart the engine's input (the watch's route handling). A call pauses it; when the call is
over and iOS says the audio may go on (`onResumable`, only for the interruption that stopped this conversation) it goes
on within three minutes, at once with SamRabbit in front, else when SamRabbit is in front again (the microphone never
comes back on behind the Lock Screen with no Live Activity to stop it). End or Close on the paused screen means it:
nothing goes on afterwards. Turns go straight to the Mac with the iPhone's own
token, streamed (`/v1/mobile/assistant/*`): warm-up, live caption, barge-in, announcements every ~20 s, listening
again after each reply, and the end about two minutes after the last words, on "bye" (`endConversation`) or on End.
`UIBackgroundModes: audio` keeps it going with the app in the background or the screen locked. Haptics are the
iPhone's own (soft start, light click, error).

**The Talk screen** (`iOS/App/Talk`, full screen): the fluid orb (it follows your voice and pulses with the reply;
tap it to send now or to interrupt), a state pill (Listening… / Hearing you… / Thinking… / Speaking… / Muted), the
line it heard and the reply as it streams in, the tasks it started (tap: the thread in Tasks; Talk steps aside and
the conversation goes on) and the cards it showed, and Type (a `{text}` turn; it interrupts a reply: a reply the Mac
is still sending is cancelled there first and the typed turn goes once the cancel is through, since the Mac cancels
whatever turn holds the conversation; a reply that only still plays here needs no cancel; words that can't go yet wait
for the conversation to listen, or come back in the field), Mute (the microphone is muted in voice processing too; the
quiet end comes after five minutes instead of two, announcements still play but don't keep it open, and the mute
stays across a call), Stop (the reply: cancel on the Mac, listen at once) and End. The top left minimizes it: the
conversation goes on in a bar over the tab bar (`tabViewBottomAccessory`: mute, end, tap for Talk). The top right
shows the transcript (the last twelve exchanges). One microphone: dictation in a composer ends a conversation first, and Talk stops a dictation that listens. The audio
session is the app's: `AudioSessionClaims` (SamRabbitKit) records who activated it, and only the last holder gives it
back, so a mic button that never listened (every composer's, when its screen goes) never deactivates it under Talk.

**The Live Activity** (`TalkActivityAttributes`, `TalkLiveActivity`): while a conversation runs, the Dynamic Island
(orb + "Listening" / "Speaking", expanded with the last line and End) and the Lock Screen (orb, state, the last line,
a timer and End). End runs `EndTalkIntent`, a `LiveActivityIntent` the app performs. It is updated when the phase
changes and at most every 1.5 s while a reply streams in, and ended with the conversation (leftovers from a closed
app at launch). A request iOS refused (the app wasn't in front yet) is tried again when SamRabbit is in front.

**Debug launch arguments** (iPhone): `-SamRabbitTalk start` (Talk opens at launch), and the watch's
`-SamRabbitVoiceFixture speech|hold|quiet`, `-SamRabbitFixtureTurns`, `-SamRabbitFixtureLead`,
`-SamRabbitFixtureLength`, `-SamRabbitIdleSeconds`, `-SamRabbitStillOrb`, `-SamRabbitAudioOut` work the same. The
simulator never listens through the Mac's microphone (no fixture: silence) and plays nothing out loud unless
`-SamRabbitAudioOut on`.

## Tasks: every agent on the Mac

Like the Mac's Agent Dock (CONTRACTS-WAVE6 §A, WAVE7 C), Tasks and Home show the bridge's inbox
(`/v1/mobile/inbox`): T3 Code threads, the Claude Code and Codex sessions on the Mac (CLI and Codex Desktop), in the
dock's order (approvals, questions, failures, finished and unseen, working, the rest). SamRabbit chats in the inbox
stay in Chats. Each row and card carries its source as a small tile (`SourceGlyph`: "T3", Claude's asterisk, Codex's
chevrons; a T3 tile has the model family running it in its corner); with more than one source a filter (All · T3 ·
Claude · Codex, with counts) sits on top. The badge, Home's line, the orb, Siri's "what needs me" and the widgets
count every agent.

- **T3 items** act as before, through the T3 routes and with the request id the inbox showed: Approve / Deny and the
  answers on the card, the thread's own screen (`ThreadDetailView`) with reply, Stop and Mark seen.
- **Claude Code / Codex** (`InboxItemView`: the last messages, project, folder, where it is): a session no terminal
  owns takes a reply; the Mac continues it in a new Terminal window (`claude --resume` / `codex resume` with the
  words), so its own permission prompts stay on the Mac, and the app says so ("Sent to your Mac"). A session open in a
  terminal (`live`) says "Open in a terminal on your Mac" (the Mac refuses a reply with 409 `session_live`, said as
  "It's open in Terminal on your Mac"); one waiting for a permission or a question in its terminal says "Waiting for
  you in the terminal" with what it asks (the command, the question and its choices) and has no reply field; a Codex
  Desktop thread says the app runs it. A Claude Code session the Mac couldn't check (its process list didn't
  answer: neither `live` nor `reply`) says "Can't tell if it's open on your Mac" (a reply would be refused with 503
  `session_check_failed`); a Codex CLI session in that state reads as the app's, since nothing in the item tells the
  two apart. Opening things on the Mac's screen is the Mac's own: the phone's items never list `open`.
- **Seen**: "Needs you" is the dock's (approvals, questions, failures, finished and unseen). Opening a finished or
  failed item (either screen) is seeing it: it is marked seen quietly, once per state (`seenMark`: a session that
  finishes again while its screen is open is marked again), here and on the dock; Mark seen on the cards and screens
  does the same. A Claude Code or Codex failure then settles; a T3 one stays an error (and in Needs you) until T3
  settles it, as on the Mac.
- **Live**: besides the 20 s refresh, the app follows the inbox's long-poll (`?after=<revision>&wait=25`) while it is
  in front, so a prompt answered on the Mac or a session that finished shows within a moment. Only later revisions
  apply (a refresh that lands after the long-poll changes nothing, nor undoes a Mark seen on its way); a screen reads
  its item again when that item moved on (`changeMark`), not on every revision; the widgets reload for what they draw.
- **T3 Code down**: the inbox still answers without T3's items (`sources.t3.connected: false`); the Claude Code and
  Codex rows stay fresh, and T3's last rows stay at the end ("Last from T3 Code"), dimmed and read-only (their screens
  show the last state with no Approve or reply), counted nowhere, like the bridge's counts and the widgets. **The
  inbox failing** while the Mac answers (a server error, a timeout on its first scan): T3's own thread list stands in
  beside the other agents' last rows ("Claude Code and Codex didn't update"). **An older bridge** (404 on `/inbox`):
  Tasks is T3's thread list, as before.
- **New task**: the "+" sheet offers the agents and models T3 has (`/inbox/targets`: Automatic, Claude, Codex, and
  the model, defaulting to the one the Mac used last for that agent) and the project; with an agent it goes to
  `/inbox/new`, without one to `/t3/threads` (automatic placement) as before.
- **The watch** keeps T3's summary and pages (`SamRabbitActions.includesInbox` is off there).

## Voice notes and the morning brief (wave 8)

**Voice notes** (CONTRACTS-WAVE8 §C2–C3, the bridge's `samrabbit_capture.py`): "tap, talk, it's sent", nothing said
back. On the iPhone the Action Button (the Voice Note control or shortcut), the Lock Screen widget, the Dashboard's
Voice note button, Control Center, Siri and Home's tile run `VoiceNoteIntent` (`.foreground(.immediate)`: iOS 26
doesn't let a third-party app start recording from the background), which leaves `samrabbit://capture` for the app;
only that route records at once (`AppLink.capture(record:)`: a link from a page or a message opens the recorder
waiting for a tap). `CaptureModel` + `CaptureView`: a full-screen recorder that records the moment it opens
(`AVAudioRecorder`, AAC 16 kHz mono 32 kbps, the watch's `MicrophoneSource` now in `Shared/Voice`; the session claimed
as `AudioSessionClaims.Holder.capture`, so Talk ends and dictation stops first), a timer and the orb following the
level, and it stops on 2.5 s of quiet after speech, Stop, the intent again (a second press), a call, or 180 s; under
0.4 s is dropped. The intent while the last note still sends records the next one at once (the outbox has the first,
which goes on by itself; Home and Tasks follow what it became). The Live Activity (`CaptureActivityAttributes`, `CaptureLiveActivity`) shows the timer and Stop
(`StopVoiceNoteIntent`) on the Lock Screen and the Dynamic Island; with `UIBackgroundModes: audio` it keeps recording
locked or in the background. The recording goes into the App Group outbox (`CaptureOutbox`: `<id>.m4a` + `<id>.json`,
kept until the Mac says `received`, retried after 5 s, 30 s, 2 min, then every 10 min, and at once, whatever the
pause, when the app comes to the front, on Home's "Tap to try now" and when the network comes back; also in the
background refresh; 50 notes, 7 days; a note on its way is left to its upload. Only a refusal sending again can't change
ends a note and deletes its recording, `BridgeError.finalCaptureCodes`: too long, not audio, too big, another
recording under its id; a `retryable` answer, an unknown code or the iPhone turning the watch's relay down keep it)
and up with `CaptureUploader` (a quick upload
in front, else a background `URLSession` upload task that finishes with the app suspended) to `POST
/v1/mobile/capture` with `X-SamRabbit-Capture` (a UUID made when it started: sending it again is harmless),
`X-SamRabbit-Captured-At` (with the offset) and `X-SamRabbit-Source: iphone`; then `GET …/capture/<id>?wait=8`
for what the Mac did: "Sent ✓ — Added to your journal", "Started a T3 task · Started “Fix login” in Website.",
"On your calendar", "Saved as a note · Start it as a T3 task? It's in Tasks.", "I didn't catch anything", or "Saved ·
it goes when your Mac is reachable". A saved note waits in Tasks (`note:<captureId>`, source `note`, its suggestion
as a button, Keep as note, Dismiss), and Home has a line for notes waiting on the iPhone (it follows each upload as
it ends), the failed notes Tasks shows, or what the latest one became. The Live Activity's last line, on a locked
phone, says only where the note went ("Sent ✓ · Added to your journal", "Saved as a note · It's in Tasks."), never what
was said; a note the Mac has but couldn't do (or heard nothing in) says "Sent" with what went wrong, "Not sent" only
for one it never got. `VoiceNoteBackgroundIntent` (an `AudioRecordingIntent`, off unless Settings > Action Button >
"Record without opening SamRabbit") tries to record with the app staying in the background and continues in the
foreground whenever iOS refuses. On the watch: `WatchDestination.note`, the "Voice Note" control (the Ultra's Action
Button), a Voice note complication (circular, corner), Quick's Voice note and Siri "SamRabbit note" open
`VoiceCapture` with `VoicePurpose.capture` (120 s, 2.5 s of quiet, no Review step, double tap is Stop); the recording
goes into the watch's outbox, then directly, else through the iPhone in chunks with the watch's token
(`relayCapture`, `BridgeAccount.performRelayedCapture`), else handed over with `WCSession.transferFile` (the iPhone's
`WatchLink` keeps it in its outbox as the watch's and sends it on).

**The morning brief** (§C4, the bridge's `samrabbit_briefing.py`): `GET /v1/mobile/briefing` (`Briefing`: the
headline, `sections[]` Do first / Today / Agents / FYI, each item with one or two verbs, `can`, its state and what a
verb did) and `summary.briefing` (`BriefingOverview`, headline and count). Home shows a Morning section at the top
until noon (Hark-style: the verb is the button): Do first and Agents as cards with their verbs (Draft reply makes a
Gmail **draft**, never sent, and offers Open draft in the right account; Make task first shows the words the task
starts with, editable (`BriefTaskSheet`; the item's title and why, or the Mac's `taskText` when it sends it), and sends
exactly those as `text`, since they come from an email (`BridgeClient.briefingAct` refuses Make task without
`text`, `task_text_required`, before any request); Block 30 min; Remind me: in an
hour, at 2 PM, tonight or tomorrow, the item keeping its verbs; Open / Join; an agent's Review opens its task in
Tasks) and Done / Dismiss, Today's events in the order of the day with the conflict flagged (an event without a
meeting link isn't "Join …": `shownTitle`), FYI
folded (a tap opens the email), what it read, and a refresh (one build every five minutes on the Mac). A handled item
says what the Mac did ("Blocked 30 min at 10:05 AM."). The headline's times read like every other time
(`Formatting.clockTimes`: the Mac's "first at 16:00" is "first at 4:00 PM" on a 12-hour clock). The widgets draw the first open items the iPhone adds to the
summary (`with(briefing:)`; Done then Dismiss, in Home's order); the watch has a Brief page (headline, the first verb
and Done; Make task shows its exact words on a confirm page first) and a complication
(rectangular, inline). `samrabbit://brief[/<id>]` opens Home at the brief.

**turnId**: the iPhone's Talk and the watch send `turnId` with `POST /assistant/cancel` (one engine,
`ConversationEngine`), so a cancel that arrives late never stops the next turn.

## What the app expects where the contract leaves room

Field names follow CONTRACTS-WAVE4 exactly; decoding is lenient everywhere (unknown fields ignored, missing ones
defaulted, alternative names accepted), so these are the shapes `fake_bridge.py` serves:

- Dates: ISO-8601 text (with or without fractional seconds or an offset) or epoch milliseconds.
- `GET /conversations` → `{conversations:[{conversationId,title,startedAt,lastAt,endedAt,live,messageCount,preview,device,cursor}],cursor,nextBefore?}`; events → `{events:[{…,cursor}],cursor,more}`; `/stream` like the desktop stream (`: ready <cursor>`, `id:`/`event: sync`/`data:`).
- `GET /t3/projects` → `{projects:[{projectId|id, name|title}]}`. `POST /t3/threads` → `{threadId,title,projectName}`. Message/respond/stop → any 2xx.
- `pending` → `{kind:"approval"|"question", requestId, questionId?, text, options?}`. Approve / Deny / Answer send `{decision, requestId}` / `{answer, requestId}` for the request the card shows; 409 `t3_request_not_pending` means it changed: the app and the watch say "That request changed, check it again" and refresh. A card without a `requestId` (summary threads carry no pending details) only opens the thread.
- The summary and the thread list are fetched side by side and fail on their own: while T3 Code is not running (`/t3/threads` 503 `t3_unavailable`, `t3_app_missing`, …) Home, the orb, the calendar and the widgets stay fresh and only Needs you / Tasks (and the watch's task pages) say "T3 not connected", over the last list.
- `pending.options` for questions: strings or `{value|decision, label}` objects.
- `GET /calendar/agenda` → `{events:[{eventId?,title,startsAt,endsAt,allDay,location,meetingUrl}]}`; block/events → `{event:{…}}` (an optional `dryRun:true` is shown as "test copy").
- `POST /journal` → `{recorded,state:"sent"|"queued",date}`.
- `GET /mac/state` → the `/v1/mac/state` shape plus `name`/`online` (`computer`, `front:{app,window}`, `visible:[{app,windows}]`, `running`, `screenLocked`, `screenVision`).
- `POST /ui/generate` → `{artifactId}`; artifact status as `/v1/ui/artifacts/<id>`; `/document` is served as HTML.
- `POST /devices/child` → `{token,deviceId,…}` like `pair`.
- Errors: `{error:{code,message,retryable}}`; 401 means "pair again".
- The inbox (`/v1/mobile/inbox`): `{revision, updatedAt, counts:{needsYou,working,total}, sources:{t3:{connected,reason?},
  claude|codex|samrabbit:{available,reason?}}, items:[InboxItem]}` (CONTRACTS-WAVE6 §A; `revision` is 64-bit, it starts
  from the time in milliseconds). Items without an id are dropped, unknown statuses read as unknown, `chat:` ids are
  SamRabbit chats (shown in Chats, never in Tasks), at most 60 are drawn. A 404 `not_found` on `/inbox` means an older
  bridge: Tasks then reads `/t3/threads` as before. Reply → `202 {ok, how, message?, dryRun?}`; 409 `session_live`.

## The Apple Watch app

**Pages** (Digital Crown or swipe, a vertically paged `TabView`):

1. **SamRabbit** (the main screen, `AssistantPage`): a live conversation with the assistant, like talking to the R1
   (below). The orb listens, thinks and speaks; one line of status above it ("2 need you · 1 working", or the next
   event); a live caption of what was heard and what is being said, cards and the actions it took; the last turns
   further down. Tap the orb to talk, to send now, or to interrupt; the top-left button stops.
2. **Needs you**: a card per waiting task with **Approve** / **Deny** for approvals, the offered answers as buttons for
   questions, and **Reply** / **Answer** by voice. Tap a card for the task.
3. **Working**: running tasks; a task shows its latest messages with Reply / Answer (voice), Approve / Deny and **Stop**.
4. **Up next**: the next events from the summary, with "Now" / "in 25m", place or video call.
5. **Quick**: **Block 30m** (a Focus block from now), **Journal note** (your own words, by voice), **New task** (a
   T3 task by voice, the words checked before they go), and which Mac, which route (direct or via iPhone) and how
   fresh, with a refresh.

**The conversation** (CONTRACTS-WAVE5/5b; the rules are `ConversationMachine` in SamRabbitKit, unit-tested; the
watch app's `ConversationEngine` carries them out):

- **Always on.** The app opens straight into a conversation: launched, back from the background, the Action Button,
  Siri ("Ask SamRabbit", "Talk to SamRabbit") and the complications (`samrabbit://talk`). It warms the Mac up at
  once (`POST /assistant/session`), listens, and after each reply listens again by itself. Wrist down keeps it going
  (`UIBackgroundModes: audio`); the wrist coming back up continues it; the Digital Crown lets the reply finish and
  pauses (back within three minutes: the same conversation; back while the reply still plays: it just goes on). It
  ends on Stop, when the Mac says so (`endConversation`), or about two minutes after the last turn that heard words
  (noise, coughs and empty transcripts never keep it open, even in a room so noisy it never looks "listening"), and
  tells the Mac (`/assistant/end`).
- **One audio graph per conversation** (`AudioGraph`): `AVAudioSession` play-and-record (AirPods allowed), one
  `AVAudioEngine` started in front and kept running between turns (watchOS can't start recording from the
  background): the input's tap converted to 16 kHz mono 16-bit, and an `AVAudioPlayerNode` for replies.
- **Speech detection** (`SpeechDetector`): energy 10 dB over the room's noise floor (and over -50 dBFS) for 150 ms
  starts speech; 1 s of quiet ends it; at least 0.18 s from the start of speech to its last loud moment (a short
  "yes" or "ok" confirms approvals and gets through; a click doesn't); cut at 30 s; 300 ms before speech kept. The noise
  floor ignores digital silence (readings at or below -100 dBFS) and never goes below -80 dBFS (`NoiseFloor`, also
  in the voice capture's `VoiceActivity`). Half duplex: the microphone is ignored while a turn is on its way and while
  anything plays, and the reply's echo (300 ms) is skipped.
- **Turns stream** (`BridgeClient.assistantTurn`): the utterance goes up as a 16 kHz WAV with
  `X-SamRabbit-Conversation`, `X-SamRabbit-Turn` (a uuid: a retry gets the same answer) and
  `X-SamRabbit-Device-Time`, `Accept: application/x-samrabbit-stream`; the answer's frames (`AssistantStreamParser`)
  are played as they arrive, after a 0.2 s jitter buffer (`PlaybackJitterBuffer`: the realtime voice arrives at the
  pace it is spoken; it starts at 0.2 s buffered, 0.35 s after the first frame, or at the end of the stream, and
  buffers again if it runs dry), and `say.delta` is the live caption. The stream may stay quiet for 90 s (a long tool
  call; the bridge's `{"type":"ping"}` keep-alives are skipped), but the bridge must answer within 50 s (so a Mac out
  of reach falls back to the iPhone quickly). An older bridge or the Claude fallback answers in one piece
  (`AssistantReply`): a 16 kHz WAV plays the same way, an MP3/AAC clip is decoded and played. "Still answering" (409)
  is retried for a few seconds, through the iPhone too (the phone runs a refused turn again with the recording it
  kept; the watch doesn't send it twice). An `error` event in the stream follows the same rules as a refusal:
  `assistant_unavailable` or a revoked watch is said and ends the conversation (a revoked watch shows Reconnect at
  once); `assistant_interrupted` says "I got cut off" (tools may have acted: never "try again"); a conversation the
  Mac forgot starts a new one.
- **Playback never hangs on "Speaking"**: an audio route change (AirPods coming or going) reports what was playing as
  played out, scheduled audio that is long overdue is dropped (`AudioGraph.checkStalled`), and a finished reply that
  never reports its end is over after a minute.
- **Barge-in**: a tap while it thinks or speaks stops playback, drops the stream and `POST /assistant/cancel`s; it
  listens at once.
- **The watch's own voice**: a reply without audio is said with `AVSpeechSynthesizer` (the best en-US voice, written
  into the same player). A Mac out of reach (neither directly nor through the iPhone) is said out loud: "I can't
  reach your Mac right now", with a failure haptic, then the conversation ends ("Can't reach your Mac" under the orb).
- **Announcements**: while a conversation is open the watch polls `/assistant/announcements` about every 20 s and plays
  them between turns: their own clip if they carry one (one the watch can't read is said in its own voice), else as a
  `{"announce": id}` turn in the conversation's voice (if that fails, the watch says the line itself). The bridge
  counts one as told once the watch has it, so none is dropped: one queued while someone spoke plays once it listens
  again; one waiting at the quiet end is said instead of ending; one waiting when the conversation ends (Stop, a
  fatal failure, a late poll) is said first in the next one; the Mac's goodbye waits until they were said.
- **Through the iPhone** (`TurnRelay`): when the Mac can't be reached directly the utterance goes to the phone in
  `VoiceRelay` chunks (purpose `turn`), the phone sends the turn with the watch's own child token and the watch pulls
  the answer back in pieces of at most 40 KB as it streams in (`TurnRelayHost` on the phone). A stream, a buffered
  answer and an error envelope come through unchanged. The phone holds a background-task assertion
  (`RelayAwake`) around every request it passes on, and for a turn from its start until the watch has the last piece.
- **Haptics**: start (listening), click (sent, the thinking tick), notification (an announcement), failure, stop.
- Nothing heard or said, and no audio, is ever logged; the logs say only which phase it moved to.

**Voice only, never a keyboard.** watchOS has no speech recognizer, and the system text input offers the keyboard
and Scribble, so the watch never opens it (no `TextFieldLink`, no `presentTextInputController`, no text fields).
Every place that takes text (Ask, Reply, Answer, Journal note, and the Action Button / Siri route into Ask) opens
`VoiceCaptureView` (`watchOS/App/Voice/`), full screen:

- It listens at once: `AVAudioRecorder`, AAC `.m4a`, 16 kHz mono at about 32 kbps, metering on, the `.record`
  audio session, after `AVAudioApplication.requestRecordPermission()`. The orb swells and stirs with the input level;
  a big **Stop**. It stops by itself about 1.5 s after you stop speaking (`VoiceActivity`: the noise floor follows
  the room, speech is 10 dB above it for 150 ms), at 60 s at the latest; a clip under 0.4 s is discarded
  ("Didn't catch that").
- "Writing it down…": the file goes to `POST /v1/mobile/transcribe?lang=<watch locale>` with the watch's own token
  (`BridgeClient.transcribe(file:)`, `URLSession.upload(fromFile:)`). If the Mac can't be reached (or doesn't answer
  in time: transcribing changes nothing, so it is safe to resend), it goes through the iPhone: WatchConnectivity
  `sendMessage` with raw `Data` chunks of at most 40 KB (`VoiceRelay`: `id`, `seq`, `of`, each acknowledged); the
  iPhone puts it back together (`VoiceRelay.Assembler`) and uploads it with the watch's child token
  (`BridgeAccount.performRelayedTranscription`, the same rules as `performRelayed`), answering the last chunk with
  the bridge's status and body. Recordings are deleted right after (and leftovers at launch).
- The words, large, with **Send** and **Say again** (close the sheet to cancel). Send performs the original action
  (a new task, the reply, the answer with the card's `requestId`, the journal note) and closes; if it fails the words
  stay with what went wrong.
- When the Mac can't transcribe (`summary.transcribe.available == false`, or the bridge's
  `transcribe_unavailable` / `transcribe_permission` / `transcribe_failed` / `no_speech` / `audio_too_long` /
  `body_too_large` / `unsupported_audio` / ...), a friendly line says why (`VoiceProblem`), with **Say again**. A
  refused microphone says where to allow it. An older bridge without the route says to update it.

A result line slides in after every action; failures say why ("Mac and iPhone are out of reach").

**Pairing and networking.** The watch never pairs on its own. The iPhone issues the watch its own child token
(`POST /v1/mobile/devices/child`, revocable from the Mac) and sends it with the bridge addresses in
`applicationContext` (`WatchContext`); a watch without a pairing asks for it with `sendMessage`
(`WatchContext.requestKey`). The watch stores it like the phone does (App Group + Keychain), so the complications use
it too. Every request goes to the bridge directly (`URLSession`, 6 s). The watch's `BridgeClient` has the iPhone as
its `BridgeRelay` (`watchOS/App/PhoneLink.swift`): a request that reached no address goes to the phone with
`sendMessage` (`WatchRelay`), the phone performs it with the watch's own child token (which it keeps in its Keychain;
never the phone's token) and answers with the bridge's status and body, so a watch revoked on the Mac is refused
through the phone too. Only the watch's own kinds of request are relayed (summary, tasks, calendar, journal,
conversations, generated UIs, Mac); pairing, `unpair` and device management never are.
After a direct failure the watch prefers the phone for two minutes. A POST that may have reached the Mac (it timed
out) is never sent again another way. If the Mac revokes the watch, the status page offers **Reconnect**, which asks
the phone for a new child token (`WatchContext.reissueValue`). Re-pairing the iPhone reissues the watch's token too.
A new child token replaces the old one: the bridge drops this phone's earlier watch of the same name, and the phone
revokes a still older watch token (from before it re-paired) with `POST /v1/mobile/unpair`.

**Complications** (`SamRabbitWatchWidgets`, WidgetKit accessory families): **Needs You**: circular (the count in a
ring of everything open), corner (the count, with the next event along the bezel), inline ("2 need you · 2 working",
shorter when the slot is small); **Next Up**: rectangular (next event, time and "in 20m", working and needs-you
counts). The timeline reads the summary the watch app saved and fetches a fresh one itself, with an entry every 5
minutes for an hour (so "in 20m" stays right) and a refresh every 15 minutes; the watch app reloads them only when
the summary it fetched (every 30 s) says something new (`SummaryCache.publish`).
Tapping opens the matching page (`samrabbit://tab/needs`, `samrabbit://tab/upnext`).

**Debug launch arguments**: `-SamRabbitPage <status|needs|working|upnext|quick>`, `-SamRabbitRoute phone` (everything
through the iPhone), `-SamRabbitIntent <ask|needs|working|upnext|quick>` (runs the Action Button's intent at launch),
`-SamRabbitRenderComplications YES` (renders the complication faces into Documents/renders),
`-SamRabbitConversation off` (no conversation by itself), `-SamRabbitIdleSeconds <n>` (end after n quiet seconds
instead of two minutes), `-SamRabbitStillOrb YES` (UI tests: no orb animation), `-SamRabbitAudioOut on|mute` (the
simulator is muted unless `on`). Debug builds only (not compiled into Release): `-SamRabbitVoiceFixture
speech|hold|quiet` replaces the microphone with a made-up voice for the simulator and the UI tests (the voice capture:
`VoiceFixtureSource`, real levels and a real AAC file; the conversation: `ConversationFixture`, which speaks
`-SamRabbitFixtureTurns n` times, `-SamRabbitFixtureLead s` seconds after the microphone opens;
`-SamRabbitFixtureMicDelay s` allows the microphone only after s seconds, like the first launch's prompt or Siri still
holding it), and `-SamRabbitVoicePermission denied` acts as if the microphone was refused. The simulator never listens through the
Mac's own microphone: without a fixture the conversation hears silence there.

**Kit additions for the watch**: `BridgeRelay` and `BridgeClient(relay:)`, `BridgeAccount(relay:)`,
`WatchContext.requestKey`/`reissueValue`, `OrbView(frameRate:level:)`; for voice `Transcript`, `TranscribeStatus`
(`MobileSummary.transcribe`), `VoiceFormat`, `VoiceActivity`, `VoiceProblem`, `VoiceRelay`,
`BridgeClient.transcribe(file:|audio:)`, `BridgeRelay.relayTranscription`. The iPhone side (`iOS/App/WatchLink.swift`) answers
context requests and relays with the watch's token; the logic is in the Kit (`BridgeAccount.provisionWatch`,
`performRelayed`) so `swift test` covers it.

## Screenshots

Voice notes and the brief (wave 8): `~/jr-scratch/w8-shots/apple-*.png` (the recorder recording, sent to the journal,
saved as a note and in Tasks, a task started from it, nothing heard, the Mac out of reach, a link waiting for a tap,
the Live Activity on the Lock Screen and in the Dynamic Island; the brief on Home, drafted, handled, Today, FYI, an
agent's task; the widgets; the watch's recorder, result and Brief page).

Tasks with every agent (wave 7): `~/jr-scratch/w7-shots/phone-*.png` (Home with the inbox's counts and cards, Tasks
with T3 / Claude Code / Codex, the Claude filter, a Claude Code session, typing and after a reply, one waiting in its
terminal, a Codex Desktop thread, T3 down, an older bridge, New task with Codex).

Talk on the iPhone (wave 6): `~/jr-scratch/w6-shots/phone-*.png` (listening, speaking with the caption, the task
card, a card from a typed turn, muted, minimized over the tab bar, the transcript, the Dynamic Island, the Live
Activity on the Lock Screen, a Mac out of reach, Home with the Talk button).

`~/Movies/SamRabbit-tests/wave4/ios-*.png` (each tab, thread detail, chats with a generated UI, pairing,
Home Screen and Lock Screen widgets added in the simulator, Live Activity) and `widget-renders/` (the
`-SamRabbitRenderWidgets` launch argument renders every widget face with `ImageRenderer` into the app's
Documents/renders), `ios-stale-request-refused.png`, `ios-home-t3-down.png`, `ios-tasks-t3-down.png`. The watch:
`watch-1…9-*.png` (every page and action from the walkthrough, `watch-2b-request-changed.png` the stale approval
refused), `watch-needs-you-t3-down.png` and
`watch-face-*.png` (the complications on Infograph, Modular and Activity Digital faces), plus `watch-renders/`.
`wave5/watch-*.png`: the conversation (listening, hearing, speaking with the live caption, listening again, tap to
interrupt, the watch's own voice, can't reach the Mac, an announcement, the end after a quiet while and by the Mac, the
buffered fallback, the Action Button, through the iPhone, Stop).
`voice-*.png`: the watch's voice input (listening, transcribing, review, sent; Stop and Say again; unavailable,
failed, no speech; Reply, Answer, journal note; the Action Button's route; through the iPhone; the microphone refused).
`action-button/`: the iPhone's Action Button settings with the SamRabbit control and shortcut, the button pressed
(Ask with dictation, a task started, pressed again in the app), the help screens, the watch's Ask opened by the intent
and the Watch Ultra's Action Button set to the control and pressed.
