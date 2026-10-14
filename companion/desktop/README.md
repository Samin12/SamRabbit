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
line tools; ~5 s; ad-hoc signed). The app icon is rendered from the R1's fluid-orb math
(`tools/render_icon.swift` + `Sources/OrbRenderer.swift`) and packed with `iconutil`.

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

## Agent Dock

A floating glass pill at the bottom of the screen with the agents that are waiting for you (CONTRACTS-WAVE6 §B):
T3 Code threads, Claude Code and Codex sessions and the recent SamRabbit chats, from the bridge's
`/v1/desktop/inbox` (long poll, desktop token, loopback). Sources: `Sources/Dock*.swift`.

- **The pill** (~44 pt on a laptop, bigger on wider screens): the orb (it moves for a moment when the counts change),
  "2 need you" (blue capsule), "4 working", and the mic (a dot when the "Hey Rabbit" listener is armed). Point at it
  for a moment and the list opens; click toggles the list; double-click opens the main window; drag it along the
  bottom edge (and to other screens; remembered as a screen + a fraction of its width, so it stays put when monitors
  change); drag an end of the pill up or down to size it (or ⌘+ / ⌘− / ⌘0 while the dock has the keys, or the menu).
- **The list** opens above the pill: Needs you, Working, Recent chats, Earlier (folded). A row opens in place with its
  last messages and what the item supports right now (`can`): Approve / Deny (each option), answers to questions,
  Reply (↩ sends, ⇧↩ new line), Stop, Open (`/open`; a SamRabbit chat opens in the main window), Mark seen. Actions
  show at once and roll back with a short inline error when the bridge says no; a live terminal session answers
  "It's open in Terminal — Open to answer there". The compose bar at the bottom sends a new prompt to a T3 project
  with a chosen agent and model (`/targets`, `/new`).
- **Keys** (when the list has the keys): J/K or ↓/↑, ↩ open a row (↩ again: Open), E approve with the recommended
  option, R reply, N compose, Esc close the row, then the list. **⌃⌥K** anywhere opens the list on the compose field
  (Carbon `RegisterEventHotKey`, no Accessibility permission; the voice work owns ⌃⌥Space).
- **When it shows:** whenever the main window is minimised, closed or hidden, or another app is in front; it steps
  aside while you are in the main window. Right-click (or "…"): Hide for 1 Hour, Hide Until Tomorrow (both come back by
  themselves), Turn Off the Dock (until **Show Agent Dock** in the menu bar extra or the app menu, ⌃⌥K), Always Listen
  for "Hey Rabbit", the voice shortcut, Open SamRabbit. During a voice conversation the pill becomes the voice bar
  (what was heard, the reply as it streams, mute, stop speaking, end; Esc ends).
- **Windows:** two non-activating panels (`NSPanel`, `.nonactivatingPanel`), each exactly the size of its glass, no
  system shadow, status-bar level, on every Space and over full-screen apps, never in ⌘-Tab or the Window menu. The
  list can take the keys without bringing SamRabbit forward (the frontmost app and its menu bar stay as they were).
  Glass: macOS 26 Liquid Glass when available, else `NSVisualEffectView` (.hudWindow); `defaults write
  com.samrabbit.desktop AgentDockGlass hud` (or `liquid`) picks one.
- **Notifications:** a new needs-you item posts one notification (once per need, not again while it keeps waiting);
  clicking it opens the list on that item.
- Settings (UserDefaults of the app): `AgentDockEnabled`, `AgentDockHiddenUntil`, `AgentDockSpot`, `AgentDockZoom`.
- Voice goes only through the `MacVoice` interface. Until the Mac voice work is merged,
  `Sources/DockVoicePlaceholder.swift` implements it with a silent scripted fixture (no microphone, no audio, no
  network): **delete that file when the real `MacVoice` lands.**

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
  states, the list, an open approval, a question, the compose menus, the voice bar, a terminal session, a white page
  and the offline state to PNGs from the fixtures and quits (no window, no screen access; the glass is simulated by
  blurring the backdrop).
- `SAMRABBIT_DOCK_SMOKE=<dir>` walks a running dev copy through open → expand → approve → new prompt → voice → hide →
  back without any synthetic click, logs what AppKit says about the windows at each step and draws each live state.
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
```
