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
- **Audio** (`VoiceAudio.swift`): one `AVAudioEngine` per conversation with voice processing on the microphone (echo
  cancellation: the assistant's voice through the speakers never counts as you speaking; other apps are ducked as
  little as macOS allows). Muting the microphone uses voice processing's own mute and pauses the quiet end.
- **"Hey Rabbit"** (`VoiceWake.swift`, `VoiceWakeMatcher.swift`) listens whenever no conversation does, entirely on
  this Mac: `SpeechAnalyzer` + `SpeechTranscriber` (macOS 26, on device; no Speech Recognition permission, no
  network), fed only while the room is loud enough for speech (an energy gate, so a quiet room costs about nothing).
  Partial results are matched for "hey rabbit", "hey sam rabbit" and "okay rabbit" (normalized, with common
  mishearings); the final words' times say where the phrase ended, and what you said after it ("Hey Rabbit, what's
  on my calendar?") becomes the conversation's first question. Nothing heard is sent anywhere before the phrase, and
  transcripts are never logged. It pauses for conversations and while the microphone is muted. Turn it off in the
  menu bar extra (or the dock); other phrases: `defaults write com.samrabbit.desktop WakePhrases -array "hey rabbit"
  "computer"`. When it can't listen (no on-device speech, the microphone refused), the menu says why.
- The app asks for the microphone the first time it listens (`NSMicrophoneUsageDescription`).

Development: `SAMRABBIT_VOICE_FIXTURE=/tmp/a.wav,/tmp/b.wav` makes the microphone "say" those files (one each time it
opens; `SAMRABBIT_VOICE_FIXTURE_WAKE=1` plays the first to the wake listener) and renders all playback silently into
memory: nothing is recorded and nothing plays out loud. `SAMRABBIT_NO_MIC=1` keeps the microphone off altogether.
`SAMRABBIT_VOICE_IDLE=<s>` changes the quiet end. The fake sync server answers `/v1/desktop/assistant/*` with canned
streamed turns (`dev/fake_assistant.py`: `POST /dev/assistant {mode}`, `POST /dev/announce {say}`).

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
python3 -m unittest discover -s companion/desktop/tests     # install.sh / uninstall.sh in a throwaway home
python3 -m unittest discover -s companion/mac-bridge/tests  # includes the /app/ route (test_desktop_app.py)
companion/desktop/tests/voice/run.sh                        # the wake phrase matcher, energy gate, sample ring
companion/desktop/tests/voice/headless.sh                   # the voice end to end against the fake, silently
companion/desktop/tests/voice/headless.sh listen 60         # the wake listener's CPU in a quiet room
```

`headless.sh` builds a harness from `Sources/Voice*.swift` and SamRabbitKit and runs it in fixture mode against
its own fake server (a free port, a temp token): `turns` (⌃⌥Space, two turns, the assistant ends it), `wake` ("Hey
Rabbit, what's on my calendar this afternoon?" in one breath: the first utterance sent is transcribed again by the
bridge's on-device transcriber and must be the question without the phrase), `bargein` (barge-in, an announcement,
`end()`). Fixture voices come from `say -o` (written to a file, never played).
