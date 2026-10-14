# SamRabbit desktop app

SamRabbit on the Mac: one window with what needs you across T3 Code, Claude Code and Codex (approve, answer,
reply, stop, start a new task), every R1 / Watch / iPhone / Mac conversation live in one searchable timeline (what
you said, the answers as they stream, GenUI cards, T3 updates, tool calls, screenshots and camera photos, the UIs
the Mac generates), your calendar, your devices, and Talk — plus the Agent Dock when the window isn't in front.

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

## The window

A sidebar (the orb, **Talk**, and the views) and five views (CONTRACTS-WAVE7 §B; `web/app.js` routes them):

- **Home** (⌘1, `web/home.js`): a greeting with "6 need you · 4 working · Next: …", the quick actions **New task**,
  **Talk**, **Block time** (a popover: 15 min to 2 hr from now, a title; `POST /v1/desktop/calendar/block`) and
  **Journal note** (a sheet; the words go into today's Heptabase journal exactly as typed, only when you press Add:
  `POST /v1/desktop/journal`), the items that need you (an approval shows its command and its buttons right there),
  what is working, the next three events with Join, the R1 / iPhone / Watch / this Mac, and the latest conversation.
- **Tasks** (⌘2, `web/tasks.js`): the whole agent inbox (`/v1/desktop/inbox`, the dock's long poll and rules:
  `web/inbox.js` mirrors `Sources/DockModels.swift`) in Needs you / Working / Recent, filtered by T3 · Claude ·
  Codex (with their needs-you counts). A row opens in the detail pane: its last messages (`/items/<id>`), every
  action it supports right now (`can`): Approve / each option, answers to questions, Reply (↩ sends, ⇧↩ new line),
  Stop, Open (in T3, Terminal, Codex; a SamRabbit chat opens in Chats), Mark seen — at once, rolled back with a
  short note when the bridge says no ("It's open in Terminal — Open to answer there"). **New task** (N, ⌘N): the
  prompt, the T3 project, Claude or Codex and the model (`/targets`, `/new`); the task shows under Working at once.
- **Chats** (⌘3, `web/chats.js`): the conversation timeline as before (list, search ⌘K, live stream).
- **Calendar** (⌘4, `web/calendar.js`): the next seven days by day (`GET /v1/desktop/calendar/agenda?days=7`), a
  week strip, all-day chips, a now line, Join for meetings, **Block time** (B).
- **Settings** (⌘5 or ⌘,, `web/settings.js`): Devices (the R1; paired iPhones and their watches with **Unpair…**,
  `DELETE /v1/desktop/devices/<id>`; **Pair iPhone…**), ChatGPT (connected, plan, account, "Using your Codex login
  on this Mac"; **Connect ChatGPT…** / **Manage…**), Voice (the talk shortcut, "Listen for “Hey Rabbit”"), Agent
  Dock (on/off, its shortcut), About.
- **Talk** (the sidebar button, the Home action): the conversation is MacVoice's — the same one ⌃⌥Space, "Hey Rabbit"
  and the dock start. The page asks the shell (`{type: "voice", action: start|end|mute|unmute|stopSpeaking}`) and
  draws what the shell pushes back: a glass panel with your lines and the reply as it streams above, and under them
  the orb, Listening / Thinking / Speaking, mute, stop speaking, end (Esc). It stays a few seconds after the end, with
  Open in Chats. There is no audio in the page. The level comes about twelve times a second and the reply at word
  rate, so the button and the panel are built once and patched in place (a click is a press and a release on the
  same element; a redraw in between loses it), and the controls sit on the panel's bottom edge, which doesn't move
  while the transcript grows. Each exchange is its own line (`heardId`), so "Yes." twice is two lines.
- **Keys**: ⌘1–⌘5 views (also in the View menu), ⌘N new task, ⌘K search conversations, ⌘, Settings — ⌘ only (⌃N,
  ⌃K stay the text fields' next line / kill line), and nothing behind a sheet (a journal note, an unpair); in Tasks
  J/K or ↓/↑ move, ↩ open, E approve with the recommended option (the selected item's card is on screen), R reply, N
  new task, Esc closes the composer, then the selection; Esc ends a conversation first.
- **Live**: the inbox long poll (25 s), the sync stream, the summary every minute (`GET /v1/desktop/summary`: the
  phone's summary plus `r1.online` and `devices`), the agenda every five minutes and when a view opens — the
  summary, the agenda and the inbox only while the window is on screen. The page lives as long as the app (it loads
  at launch, with `--login` too, and stays when the window closes), and each summary read makes the bridge look at
  Google Calendar and the journal: closed, minimised, hidden or covered (WebKit's page visibility, and the shell's
  `window {visible}`), nothing is read; back on screen, what was asked meanwhile or has grown old is read once.
  Redraws of Home, Tasks, Calendar and Settings wait while a mouse button is held (`redrawWhenFree` in `web/ui.js`).
- Narrower than 1100 pt the sidebar becomes an icon rail.

**The shell's half** (`Sources/MainWindowBridge.swift`, rules in `MainWindowMessages.swift`): `WKScriptMessageHandler`
messages from the page — `ready`, `voice` (and `{action: "wake", on}`), `dock {enabled}`, `connectChatGPT`,
`pairPhone`, `open`, `copy`, `noDrag` — and pushes into `window.SamRabbitApp.native({voice, dock, shortcuts, app,
window})`: MacVoice's published state (state, heard and its exchange, caption, level, mute, wake armed/enabled/problem,
brain, conversation, shortcut), at once for anything but the level, the level at most twelve times a second; the
window shown, minimised or closed. The Settings dock switch is the dock's own `DockController.setEnabled(_:)` (on ends
a hide for a while, off is "Turn Off the Dock") and shows `isOn`: "Hidden for now" while it is on but hidden. All the
window knows of the dock is in `WindowDock` (with feat/w7-dock: its shortcut center and settings window go there).
Before the page loads, the menus' calls wait and run once it has.

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

**Pair iPhone…** (menu bar extra, the app menu with ⇧⌘P, or Settings → Devices in the window) opens a native
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

A floating glass pill at the bottom of the screen with the agents that are waiting for you (CONTRACTS-WAVE6 §B):
T3 Code threads, Claude Code and Codex sessions and the recent SamRabbit chats, from the bridge's
`/v1/desktop/inbox` (long poll, desktop token, loopback). Sources: `Sources/Dock*.swift`.

- **The pill** (~44 pt on a laptop, bigger on wider screens): the orb (it moves for a moment when the counts change),
  "2 need you" (blue capsule), "4 working", and the mic (a dot when the "Hey Rabbit" listener is armed). Point at it
  for a moment and the list opens; click toggles the list (it opens with the compose field taking the keys);
  double-click opens the main window; drag it along the bottom edge (and to other screens; remembered as a screen + a
  fraction of its width, so it stays put when monitors change); drag an end of the pill up or down to size it (or
  ⌘+ / ⌘− / ⌘0 while pointing at the dock or while it has the keys, or the menu).
- **The list** opens above the pill: Needs you, Working, Recent chats, Earlier (folded). A row opens in place with its
  last messages and what the item supports right now (`can`): Approve / Deny (each option), answers to questions,
  Reply (↩ sends, ⇧↩ new line), Stop, Open (`/open`; a SamRabbit chat opens in the main window), Mark seen. Actions
  show at once and roll back with a short inline error when the bridge says no; a live terminal session answers
  "It's open in Terminal — Open to answer there". The compose bar at the bottom sends a new prompt to a T3 project
  with a chosen agent and model (`/targets`, `/new`); its project and agent menus open upward over the list (the panel
  grows to fit them, and a long list scrolls).
- **Keys** (when the list has the keys and no field does — Esc leaves a field): J/K or ↓/↑, ↩ open a row (↩ again:
  Open), E approve the open row with the recommended option (only an open row: its command is on screen), R reply,
  N compose, Esc close the row, then the list. ⌘ keys in the dock never reach the app's menus (⌘0 there would open the
  main window); editing keys and ⌃⌘Space still work in its fields. **⌃⌥K** anywhere opens the list on the compose
  field, and turns a dock that was turned off back on (Carbon `RegisterEventHotKey`, no Accessibility permission; the
  voice work owns ⌃⌥Space).
- **When it shows:** whenever the main window is minimised, closed or hidden, or another app is in front; it steps
  aside while you are in the main window. Right-click (or "…"): Hide for 1 Hour, Hide Until Tomorrow (both come back by
  themselves), Turn Off the Dock (until **Show Agent Dock** in the menu bar extra or the app menu, ⌃⌥K), Always Listen
  for "Hey Rabbit", the voice shortcut, Open SamRabbit. During a voice conversation the pill becomes the voice bar
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
- Settings (UserDefaults of the app): `AgentDockEnabled`, `AgentDockHiddenUntil`, `AgentDockSpot`, `AgentDockZoom`.
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

- `--render-window-snapshots <dir> --base-url http://127.0.0.1:<fake>/app/ --token-file <token>` with
  `SAMRABBIT_VOICE_FIXTURE=<wav>` loads the main window against the fake, off every display (no Dock icon, no menu bar
  extra), draws Home, Tasks, Chats, Calendar and Settings (`window-*.png`, 2x), presses the page's Talk button with
  the mouse (a down and an up 110 ms apart, not a script's click; through the bridge to MacVoice in fixture mode: the
  WAV is the microphone, the reply is rendered silently into memory), draws the live transcript, presses the panel's
  End while the reply streams, and writes `window-smoke.json` (what the bridge received, how many voice pushes, the
  transcript). It refuses port 3780, a server that doesn't answer
  `/dev/inbox/fake`, the installed app's bundle id (build the copy with `--bundle-id`), and running without the
  fixture microphone. Make the WAV with `say -o ask.aiff "What's on my
  calendar this afternoon?"` and `afconvert -f WAVE -d LEI16@16000 -c 1 ask.aiff ask.wav` (nothing plays).
- `--render-dock-snapshots <dir> [--dock-fixture dev/samples/inbox.json] [--dock-backdrop <image>]` draws the pill, its
  states, the list, an open approval, a question, the compose menus, the voice bar, a terminal session, a white page
  and the offline state to PNGs from the fixtures and quits (no window, no screen access; the glass is simulated by
  blurring the backdrop).
- `SAMRABBIT_DOCK_SMOKE=<dir>` walks a running dev copy through open → expand → approve → new prompt → voice → hide →
  back without any synthetic click, logs what AppKit says about the windows at each step and draws each live state.
  It approves and creates a task, so it refuses to run unless the app points at the fake server: not the default
  address, not port 3780, and the server must answer `GET /dev/inbox/fake`.
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
scripts states (`view:tasks`, `eval:<file.js>`, `click:<selector>`, `key:n`, …). `?chrome=1` draws stand-in traffic
lights so the page looks like it does in the app. `dev/shots/native.js` pushes what the shell pushes once the page is
ready (MacVoice idle with "Hey Rabbit" armed, the dock on, the shortcuts) and `dev/shots/voice.js` a whole voice
conversation, so Settings and the Talk transcript can be shot in a browser:

```sh
STEPS="eval:companion/desktop/dev/shots/native.js shot:home view:tasks shot:tasks key:n shot:compose \
       eval:companion/desktop/dev/shots/voice.js shot:talk" SR_TOKEN_FILE=/tmp/t companion/desktop/dev/shoot.sh /tmp/shots 3790
```

The fake also answers the window's desktop routes (`dev/fake_desktop.py`): `GET /v1/desktop/summary`,
`GET /v1/desktop/calendar/agenda?days=` (a week of meetings on the clock, from now on), `POST …/calendar/block`,
`POST /v1/desktop/journal` (kept in memory: it never writes a journal), `GET|DELETE /v1/desktop/devices[/<id>]`
(an iPhone and its watch) and `GET /v1/assistant/chatgpt/status` (through the Codex login); `POST /dev/desktop
{calendar: false, chatgpt: "off", r1Online, journal}` shows the window's degraded states, `POST /dev/desktop/reset`;
`GET /dev/desktop` counts the window's reads (`reads`) and `GET /dev/inbox/fake` its inbox polls (`polls`).

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
node --test companion/desktop/tests/*.mjs                   # timeline/store logic, API paging, the inbox and its long
                                                            # poll, agenda, devices/ChatGPT status, the voice transcript
python3 -m unittest discover -s companion/desktop/tests     # install.sh / uninstall.sh, the fake inbox and desktop routes
companion/desktop/tests/window/run.sh                       # the window bridge's rules (page requests, voice pushes)
companion/desktop/tests/window/clicks.sh                    # the page under a real mouse while the voice and inbox
                                                            # change, and a hidden window reading nothing (WebKit,
                                                            # off screen, silent; its own fake server)
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
