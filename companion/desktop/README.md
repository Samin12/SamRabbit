# SamRabbit desktop app

A native macOS app that mirrors every R1 voice conversation live, so no thread gets lost: what you
said, the answers (streaming), GenUI cards, T3 updates, tool calls, screenshots and camera photos,
and the UIs the Mac generates — all in one searchable timeline per conversation.

```
R1 app ─▶ R1 runtime ─▶ Mac bridge (sync store) ─▶ SamRabbit.app  (WKWebView ◀─ /app/ + /v1/sync/*)
```

- `SamRabbit.app` (bundle id `com.samrabbit.desktop`) is a small Swift/SwiftUI shell: a Dock app with a
  menu bar extra (live status, R1 last seen, recent conversations, Open SamRabbit) and one window that hosts
  a `WKWebView` on `http://127.0.0.1:3780/app/`.
- The UI itself is plain HTML/CSS/ES modules in `web/` (no build step). The bridge serves it at `/app/`
  from the installed bundle (`Contents/Resources/web`) through `companion/mac-bridge/samrabbit_app.py`.
- Data comes from the bridge's desktop sync API (CONTRACTS-WAVE3 hop 3): `GET /v1/sync/conversations`,
  `GET /v1/sync/conversations/<id>/events?after=`, the live `GET /v1/sync/stream` (SSE), blobs and
  generated-UI documents. Generated UIs run in sandboxed iframes (`sandbox="allow-scripts"`, no same-origin).

## Install

```sh
companion/desktop/install.sh            # options: --no-open, --no-login-item, --apps-dir /Applications
companion/mac-bridge/install.sh         # the bridge must be new enough to serve /app/ and /v1/sync/*
```

`install.sh` can be run again at any time. It builds the app (`build.sh`), replaces
`/Applications/SamRabbit.app` (quitting it first), creates the desktop token
`~/.config/samrabbit/desktop-token` (random, 0600, never printed) when missing, installs the login item
(LaunchAgent `com.samrabbit.desktop.login`: `open -g -a SamRabbit --args --login`, which starts it in
the background without a window), opens the app, and tells you whether the bridge already serves the page.

`uninstall.sh` removes the app and the login item (`--purge` also removes the desktop token, the log and
the app's settings).

Build only: `companion/desktop/build.sh` → `companion/desktop/build/SamRabbit.app` (needs Xcode's command
line tools and the macOS 26+ SDK; macOS 26 or later; ~15 s, plus ~25 s the first time for SamRabbitKit). The voice
reuses `apple/Shared/SamRabbitKit`, compiled by `tools/build_samrabbitkit.sh` into a Swift 6 static library next to
the app (cached until its sources change). The app is signed with the keychain's "Apple Development" identity when
there is one (`security find-identity -v -p codesigning`), so macOS keeps its microphone grant across rebuilds;
otherwise, or with `--adhoc`, ad-hoc. `--bundle-id com.samrabbit.desktop.dev` builds a development copy with its own
settings and grants. The app icon is rendered from the R1's fluid-orb math (`tools/render_icon.swift` +
`Sources/OrbRenderer.swift`) and packed with `iconutil`.

## How it connects

- The app reads the desktop token and sets it as the `sr_desktop` cookie (HttpOnly, SameSite=Lax) in the web
  view's cookie store before loading the page; the first request also carries `X-SamRabbit-Desktop`. The
  bridge accepts the desktop token only from loopback peers; it opens nothing else on the bridge.
- Until the page loads, the window shows a native "Waiting for the SamRabbit bridge…" screen that says what
  is missing (bridge not running, bridge too old to serve `/app/`, token missing or rejected) and retries
  every few seconds. Once loaded, the page handles bridge restarts itself (SSE reconnect with backoff, resume
  by cursor, gap fill).
- Independently of the window, the app follows the SSE stream natively for the menu bar status and for
  notifications ("New conversation on your R1", "Generated UI ready"). Notifications are silent, appear only
  while SamRabbit isn't frontmost, and are skipped when permission is off (the menu then offers
  "Turn On Notifications…").
- Closing the window keeps SamRabbit running (menu bar + notifications); clicking the Dock icon reopens it.

Settings (for development; loopback URLs only):

```sh
defaults write com.samrabbit.desktop BaseURL http://127.0.0.1:3790/app/   # default http://127.0.0.1:3780/app/
defaults write com.samrabbit.desktop TokenFile /path/to/desktop-token     # default ~/.config/samrabbit/desktop-token
defaults delete com.samrabbit.desktop BaseURL                              # back to the real bridge
```

(`--base-url` / `--token-file` arguments and `SAMRABBIT_APP_URL` / `SAMRABBIT_DESKTOP_TOKEN_FILE` work too.)

Log: `~/Library/Logs/samrabbit-desktop.log` (0600) — states, HTTP statuses and counts only; never the token or
conversation content. Lines like `page loaded`, `page: status api=ok conversations=12 live=1` and
`page: diag images=3 imagesFailed=0 frames=2` confirm what the window loaded.

## Pair iPhone

**Pair iPhone…** (menu bar extra, the app menu with ⇧⌘P, or the phone button in the sidebar header) opens a native
window (`Sources/PairingWindow.swift`) that pairs the SamRabbit iPhone app with this Mac's bridge:

- it calls `POST /v1/mobile/pairing/start` (loopback + the desktop token, like the rest of the app) and shows the
  answer: a QR code of the `samrabbit://pair?h=<host:port>&c=<code>&n=<Mac name>` link (CoreImage
  `CIQRCodeGenerator`), the 8-character code, this Mac's name and address, and a countdown (codes are single use and
  last 10 minutes; **New Code** makes another and the old one stops working);
- below it, the paired iPhones and watches (`GET /v1/mobile/devices`, read every 2 s while a code is on screen and
  nothing has paired with it yet, so a phone that just paired shows "… is paired" at once, and every 30 s otherwise)
  with **Revoke** (`DELETE /v1/mobile/devices/<id>`; a phone's watch goes
  with it);
- if the bridge is missing, too old (404) or refuses the desktop token, it says which installer to run.

The code is shown only in this window; the log says just "pairing code shown". Without the desktop app,
`companion/mac-bridge/pair-phone.sh` prints a code and the link in the terminal.

## Connect ChatGPT

**Connect ChatGPT…** (menu bar extra and the app menu, next to Pair iPhone…) opens a native window
(`Sources/ChatGPTWindow.swift`) that gives the Mac its own ChatGPT login, for the watch assistant's realtime voice
(gpt-realtime on the ChatGPT subscription, like the R1):

- **Get a Code** calls `POST /v1/assistant/chatgpt/start` (loopback + the desktop token) and shows the one-time code
  and the login link; **Open Browser** opens it (https://auth.openai.com/codex/device), where Samin signs in and
  types the code; **Copy Code** copies it;
- the bridge finishes the login by itself; the window reads `GET /v1/assistant/chatgpt/status` every 2 s while the
  code is on screen (every 30 s otherwise) and then shows "ChatGPT is connected" with the account and plan;
- **Disconnect…** (`POST /v1/assistant/chatgpt/disconnect`) puts the watch back on the Claude brain; the R1 keeps its
  own login.

The code is shown only in this window and the tokens never reach the app; the log says just "chatgpt login started" /
"chatgpt connected". Without the desktop app, `companion/mac-bridge/connect-chatgpt.sh` does the same in the
terminal.

## Talk to SamRabbit

The Mac has the watch's voice assistant (`Sources/Voice*.swift`; CONTRACTS-WAVE6 "Mac voice"). Start a conversation
with the dock's mic button, **⌃⌥Space** from any app (Carbon `RegisterEventHotKey`: no Accessibility permission),
**Talk to SamRabbit** in the menu bar extra, or by saying **"Hey Rabbit"**. A soft chime says it is listening.

- **The conversation** (`MacVoice`, `VoiceEngine.swift`) runs SamRabbitKit's `ConversationMachine` (the watch's rules,
  with Mac wording), its `SpeechDetector` (end of utterance after about a second of quiet) and its streaming turns,
  through the bridge's desktop routes: `POST /v1/desktop/assistant/session` on start (warm-up),
  `POST /v1/desktop/assistant/turn` per utterance (16 kHz WAV, `Accept: application/x-samrabbit-stream`; `heard`,
  `say.delta` as the live caption, PCM frames played as they arrive through the jitter buffer), `/cancel` on
  barge-in (`stopSpeaking()`), `/end` on `end()`, and `/announcements` about every 20 s (T3 tasks that finished or
  need you, said between turns as `{"announce": id}` turns). Loopback, the desktop token. It listens again after
  each reply and ends when the assistant says so ("bye", "that's all"), on ⌃⌥Space or after 90 s without speech.
- **Talking over a reply** stops it too when turned on (`defaults write com.samrabbit.desktop VoiceBargeIn -bool
  true`; off by default until it has been tried with real speakers): with echo cancellation running, sustained speech
  well above the room (`BargeInDetector`: 0.35 s, 15 dB over the room and above -40 dBFS) cancels the reply, and what
  was said over it is the start of the next question.
- **Audio** (`VoiceAudio.swift`): one `AVAudioEngine` per conversation with voice processing on the microphone (echo
  cancellation: the assistant's voice through the speakers never counts as you speaking; other apps are ducked as
  little as macOS allows). Muting the microphone uses voice processing's own mute; mute belongs to the conversation
  (the next one, and "Hey Rabbit", hear again), and a muted conversation still ends by itself, after four times the
  quiet end (6 minutes).
- **"Hey Rabbit"** (`VoiceWake.swift`, `VoiceWakeMatcher.swift`) listens whenever no conversation does, entirely on
  this Mac: `SpeechAnalyzer` + `SpeechTranscriber` (macOS 26, on device; no Speech Recognition permission, no
  network), fed only while the room is loud enough for speech (an energy gate, so a quiet room costs about nothing).
  Each stretch of sound is its own recognizer run: fed from 0.6 s before the sound in 100 ms pieces on an unbroken
  clock, then 0.25 s of the quiet after it, then finished, so its final words (with their times) come at once. (One
  analyzer fed the stretches with gaps between them lost the first word of every later stretch and gave its final
  words only when more sound came, so "Hey Rabbit" failed after any earlier sound and when said on its own.) Results
  are matched for "hey rabbit", "hey sam rabbit" and "okay rabbit" (normalized, with common mishearings): a partial
  match asks for the final words at once, the final words' times say where the phrase ended, and what you said after
  it ("Hey Rabbit, what's on my calendar?") becomes the conversation's first question. Said on its own, it wakes
  about a second after you stop. Nothing heard is sent anywhere before the phrase, and transcripts are never logged.
  It pauses for conversations and while the microphone is muted. Turn it off in the menu bar extra (or the dock);
  other phrases: `defaults write com.samrabbit.desktop WakePhrases -array "hey rabbit" "computer"`. When it can't
  listen (no on-device speech, the microphone refused, muted), the menu says why. A recognizer that keeps failing
  pauses it a few seconds, then once a minute (the menu says so); it never gives up for good.
- **Its microphone** is the default input unless that is a Bluetooth headset or an iPhone (Continuity): holding
  AirPods' microphone open all day would put everything they play in call quality. Then it listens with the Mac's
  built-in microphone; a Mac without one (Mac Studio, Mac mini) waits ("Paused while “AirPods” is the microphone") and
  starts again when the inputs change. A conversation uses the default input.
- **The shortcut**: when another app already has ⌃⌥Space, the menu says "Shortcut unavailable" instead of showing it
  (`MacVoice.shortcutDescription` is then empty and `shortcutProblem` says why).
- The app asks for the microphone the first time it listens (`NSMicrophoneUsageDescription`). If the "Apple
  Development" identity can't sign (a locked keychain in a non-GUI session, a denied key prompt), `build.sh` says
  why and signs ad-hoc; the SamRabbitKit library is rebuilt when the compiler or its file list changes.

Development: `SAMRABBIT_VOICE_FIXTURE=/tmp/a.wav,/tmp/b.wav` makes the microphone "say" those files (one each time it
opens; `SAMRABBIT_VOICE_FIXTURE_WAKE=1` plays the first to the wake listener) and renders all playback silently into
memory: nothing is recorded and nothing plays out loud. `SAMRABBIT_NO_MIC=1` keeps the microphone off altogether.
`SAMRABBIT_VOICE_IDLE=<s>` changes the quiet end; `SAMRABBIT_VOICE_BARGE_IN=1` turns on talking over a reply even
without echo cancellation (fixture mode). The fake sync server answers `/v1/desktop/assistant/*` with canned
streamed turns (`dev/fake_assistant.py`: `POST /dev/assistant {mode}`, `POST /dev/announce {say}`).

## Agent Dock

A floating glass pill with the agents that are waiting for you (CONTRACTS-WAVE6 §B, WAVE7 §B2):
T3 Code threads, Claude Code and Codex sessions and the recent SamRabbit chats, from the bridge's
`/v1/desktop/inbox` (long poll, desktop token, loopback). Sources: `Sources/Dock*.swift`.

- **The pill** (~44 pt on a laptop, bigger on wider screens): the orb (it moves for a moment when the counts change),
  "2 need you" (blue capsule), "4 working", and the mic (a dot when the "Hey Rabbit" listener is armed). Point at it
  for a moment and the list opens; click toggles the list (it opens with the compose field taking the keys);
  double-click opens the main window; drag an end of the pill up or down to size it (or ⌘+ / ⌘− / ⌘0 while pointing
  at the dock or while it has the keys, or the menu).
- **Anywhere:** it rests at the bottom centre of the screen the pointer is on until you drag it (the pill or the orb)
  anywhere on any screen. It stays wholly inside the visible frame (never under the menu bar or the Dock) and
  soft-snaps to an edge, a corner or the middle of the screen within 16 pt. Where you leave it is remembered per
  screen as its nearest corner and the gap from it (never a desktop point), so it stays in its corner when monitors are
  plugged in, moved or change resolution; while that screen is away, the pointer's screen lends it its own spot, else
  the same corner and gap. When it changes size (counts, the orb, the voice bar) the edges by its corner stay put.
  "Move Back to the Middle" forgets it. Wave 6's bottom-edge spot is turned into a corner and gap once.
- **Minimize:** a "–" appears at the pill's far end (away from the edge it is kept against) while you point at it;
  it, "Minimize to Orb" in the menus, or **⌃⌥M** fold the dock to the orb: a ~36 pt glass circle with a count of what
  needs you (it pulses once when that changes) and the mic's dot while "Hey Rabbit" listens. Click the orb for the
  pill again; pointing still opens the list, a drag moves it, right-click has the menu. During a voice conversation
  the orb becomes the voice bar, and the orb again after it. Remembered across launches.
- **The list** opens on the side with room (above a low dock, below a high one), lined up with the dock's outer edge
  (left edges on the left half, right edges on the right): Needs you, Working, Recent chats, Earlier (folded). A row opens in place with its
  last messages and what the item supports right now (`can`): Approve / Deny (each option), answers to questions,
  Reply (↩ sends, ⇧↩ new line), Stop, Open (`/open`; a SamRabbit chat opens in the main window), Mark seen. Actions
  show at once and roll back with a short inline error when the bridge says no; a live terminal session answers
  "It's open in Terminal — Open to answer there". The compose bar at the bottom sends a new prompt to a T3 project
  with a chosen agent and model (`/targets`, `/new`); its project and agent menus open upward over the list (the panel
  grows to fit them, and a long list scrolls).
- **Keys** (when the list has the keys and no field does — Esc leaves a field): J/K or ↓/↑, ↩ open a row (↩ again:
  Open), E approve the open row with the recommended option (only an open row: its command is on screen), R reply,
  N compose, Esc close the row, then the list. ⌘ keys in the dock never reach the app's menus (⌘0 there would open the
  main window); editing keys and ⌃⌘Space still work in its fields.
- **Shortcuts** (Carbon `RegisterEventHotKey`, no Accessibility permission, shown in the menus): **⌃⌥Space** talk,
  **⌃⌥K** the list on the compose field (it also turns a dock that was turned off back on), **⌃⌥D** show / hide (hidden
  until pressed again; pressed while the dock is on another screen it comes to yours; it lifts a hide for a while,
  "off" and stepping aside for the main window), **⌃⌥M** orb ↔ pill. Each can be recorded anew in **Agent Dock
  Settings…** (the dock's menu, the menu bar extra, the app menu): click it and press the new keys (Esc cancels; the
  four are let go meanwhile so the keys reach the recorder). Keys you type with, macOS's well-known shortcuts and
  duplicates are refused with why. Each is registered exclusively: one another app holds that way says "Not available —
  taken by another app", and one of macOS's own (System Settings › Keyboard Shortcuts, read with
  `CopySymbolicHotKeys`) "Not available — macOS uses it" (there and in the menus; a newly recorded one that is refused
  leaves the old one working). An app that registered the same combination without exclusivity can't be detected:
  Carbon then shares it. The talk shortcut goes through `MacVoice.setShortcut`.
- **When it shows:** whenever the main window is minimised, closed or hidden, or another app is in front; it steps
  aside while you are in the main window. Right-click (or "…"): Minimize to Orb, Hide the Dock (⌃⌥D), Hide for 1 Hour,
  Hide Until Tomorrow (both come back by themselves), Turn Off the Dock (until **Show Agent Dock** in the menu bar extra
  or the app menu, ⌃⌥K, ⌃⌥D or Settings), Talk, New Task, Always Listen for "Hey Rabbit", Shortcuts & Settings…, sizes,
  Open SamRabbit. During a voice conversation the pill becomes the voice bar
  (what was heard, the reply as it streams, mute, stop speaking, end). Esc ends it once the bar has the keys: started
  from the dock's mic, or after a click on the bar. The bar never takes Esc from the app you are in (a terminal's Esc
  interrupts Claude Code).
- **Windows:** two non-activating panels (`NSPanel`, `.nonactivatingPanel`), each exactly the size of its glass, no
  system shadow, status-bar level, on every Space and over full-screen apps, never in ⌘-Tab or the Window menu. The
  list can take the keys without bringing SamRabbit forward (the frontmost app and its menu bar stay as they were).
  Glass: macOS 26 Liquid Glass when available, else `NSVisualEffectView` (.hudWindow); `defaults write
  com.samrabbit.desktop AgentDockGlass hud` (or `liquid`) picks one.
- **Notifications:** a new needs-you item posts one notification (once per need, not again while it keeps waiting);
  clicking it opens the list on that item.
- Settings (UserDefaults of the app): `AgentDockEnabled`, `AgentDockHiddenUntil`, `AgentDockPlace` (the screen and
  each screen's corner + gap; Wave 6's `AgentDockSpot` is read once and left alone), `AgentDockZoom`,
  `AgentDockPutAway` (⌃⌥D), `AgentDockMinimized`, `AgentDockShortcuts` (only the changed ones, as "⌃⌥D").
- Voice goes only through the `MacVoice` interface (`Sources/Voice*.swift`, "Talk to SamRabbit" above).

Developing it without touching the real bridge:

```sh
python3 companion/desktop/dev/fake_sync_server.py --port 3811 --token-file /tmp/dock/token   # serves /v1/desktop/inbox* too
curl -X POST -H "X-SamRabbit-Desktop: $(cat /tmp/dock/token)" http://127.0.0.1:3811/dev/inbox/needs-you
# a dev copy: build into a temp dir, give it another bundle id, run it quietly against the fake
companion/desktop/build.sh --out /tmp/dock/build && cp -R /tmp/dock/build/SamRabbit.app /tmp/dock/Dev.app
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.samrabbit.desktop.dockdev" /tmp/dock/Dev.app/Contents/Info.plist
codesign -s - --force --deep /tmp/dock/Dev.app
SAMRABBIT_NO_NOTIFICATIONS=1 SAMRABBIT_DESKTOP_LOG=/tmp/dock/app.log \
  /tmp/dock/Dev.app/Contents/MacOS/SamRabbit --base-url http://127.0.0.1:3811/app/ --token-file /tmp/dock/token --login
```

- `--render-dock-snapshots <dir> [--dock-fixture dev/samples/inbox.json] [--dock-backdrop <image>]` draws the pill, its
  states, the list, an open approval, a question, the compose menus, the voice bar, a terminal session, a white page,
  the offline state, the orb, the "–", the dock on a screen at the top left (list below) and minimized in the bottom
  right corner (list above), and the Settings sheet to PNGs from the fixtures and quits (no window, no screen access;
  the glass is simulated by blurring the backdrop). Run it with `SAMRABBIT_NO_MIC=1`.
- `SAMRABBIT_DOCK_SMOKE=<dir>` walks a running dev copy through open → expand → approve → new prompt → voice → hide →
  back without any synthetic click, logs what AppKit says about the windows at each step and draws each live state.
  It approves and creates a task, so it refuses to run unless the app points at the fake server: not the default
  address, not port 3780, and the server must answer `GET /dev/inbox/fake`.
- `SAMRABBIT_DOCK_SMOKE_PLACES=1` (same guard, reads only) leaves a running dev copy at the top left of its screen and
  opens the list, folds it to the orb and back, leaves it as the orb in the bottom-right corner with its list,
  hides and shows it as ⌃⌥D does and puts it back in the middle, logging the frames of both windows and what each of
  the four shortcuts registered as. Give the dev copy other shortcuts first (`defaults write <dev bundle id>
  AgentDockShortcuts -dict talk "⌃⌥⇧F17" compose "⌃⌥⇧F18"`) so it never shares the installed app's.
- `SAMRABBIT_DOCK_FIXTURE_WAKE=1` makes the voice placeholder report the wake listener as armed (the mic's dot).

## Developing the UI

`dev/fake_sync_server.py` is a stdlib stand-in for the bridge's sync API with realistic sample conversations
(cards, a Mac screenshot, an R1 camera photo, T3 updates, tool calls, generated UIs) and a live conversation
that streams in:

```sh
python3 companion/desktop/dev/fake_sync_server.py --port 3790          # --empty, --no-sync, --live-loop 60
defaults write com.samrabbit.desktop BaseURL http://127.0.0.1:3790/app/ # the real app, against the fake
companion/desktop/dev/shoot.sh /tmp/shots 3790                          # or headless screenshots
curl -X POST -H "X-SamRabbit-Desktop: $(cat ~/.config/samrabbit/desktop-token)" http://127.0.0.1:3790/dev/live
defaults delete com.samrabbit.desktop BaseURL                           # back to the real bridge
```

(A plain browser can't open the page: every route needs the `sr_desktop` cookie, which `shoot.sh` sets.)

`shoot.sh` drives headless Chrome (agent-browser) and takes screenshots; `STEPS="open:<id> top shot:name …"`
scripts states. `?chrome=1` draws stand-in traffic lights so the page looks like it does in the app.

Event types the UI renders (`web/store.js`): `message.user`, `message.assistant.delta|done|interrupted`,
`card.shown|updated|dismissed`, `host.t3_update`, `host.note`, `host.completion`, `ui.event`, `image`,
`tool.call|completed` (GenUI card tools hidden, `ui_generate` hidden behind its UI card, `blobId` on a tool shows
the image), `ui.generating|generated|failed`, `conversation.started|ended`, `session.connected` (reconnects),
`session.ended` (failures only), `session.finalized`. Unknown types are ignored; every event is applied once by
`id` (drafts with a `messageId` and `seq` by their `seq`: an equal or older draft is ignored). An item that cannot
be drawn shows "This item could not be shown" on its own; the rest of the conversation still renders.

Links from generated UIs: a click inside the UI (it has focus, the window is focused) opens the link in the browser
at most once a second; anything else, including a UI navigating its own frame, only offers it in a toast.

## Tests

```sh
node --test companion/desktop/tests/*.mjs                   # timeline/store logic, API paging
python3 -m unittest discover -s companion/desktop/tests     # install.sh / uninstall.sh, the fake inbox routes
companion/desktop/tests/swift/run.sh                        # Agent Dock logic: inbox, placement, visibility, keys
python3 -m unittest discover -s companion/mac-bridge/tests  # includes the /app/ route (test_desktop_app.py)
companion/desktop/tests/voice/run.sh                        # the wake phrase matcher and runs, gate, ring, mic choice
companion/desktop/tests/voice/headless.sh                   # the voice end to end against the fake, silently
companion/desktop/tests/voice/headless.sh listen 60         # the wake listener's CPU in a quiet room
```

`headless.sh` builds a harness from `Sources/Voice*.swift` and SamRabbitKit and runs it in fixture mode against
its own fake server (a free port, a temp token): `turns` (⌃⌥Space, two turns, the assistant ends it), `wake` ("Hey
Rabbit, what's on my calendar this afternoon?" in one breath), `wake-alone` ("Hey Rabbit." on its own, the question
once it listens), `wake-pause` ("Hey Rabbit.", 3 s, the question), `wake-later` (a sentence, 2 s, "So, hey Rabbit,
what's on my calendar…"), `wake-noise` (20 bursts of noise a second apart, then the phrase; the listener must never
stop or pause) — in each the first utterance sent is transcribed again by the bridge's on-device transcriber and must
be the question without the phrase —, `bargein` (barge-in, an announcement, `end()`), `talkover` (the next question
said over the reply, voice barge-in forced on: it must arrive whole), `mute` (mute ends with the conversation; muted,
"Hey Rabbit" waits and says why; a muted conversation still ends by itself) and `devices` (this Mac's audio inputs
and the listener's choice, read only). Fixture voices come from `say -o` (written to a file, never played).
`tests/test_install.py` also checks `build.sh`'s ad-hoc fallback and the SamRabbitKit cache.
