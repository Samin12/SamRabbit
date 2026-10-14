# SamRabbit Mac bridge (Heptabase journal and Mac control)

The R1 writes what you ask it to add into your Heptabase journal (and, only if you turn on
"Record every voice conversation in my journal", your words and activity lines from each voice
session). This bridge lets it do that through the Heptabase desktop app on your Mac, using the
app's own CLI (`heptabase journal append` / `journal read`). There is no
Heptabase sign-in and nothing to click in Heptabase.

The same bridge also lets the R1's voice orchestrator see and control this Mac
(what is open, reading a window, opening apps and links, simple clicks and
shortcuts, and screenshots once screen vision is allowed). See "Mac control" below.

It also keeps a live copy of every R1 voice conversation for the SamRabbit desktop app.
See "Conversation sync" below.

And it is the hub for the SamRabbit iPhone app, its widgets and the Apple Watch app (`/v1/mobile/*`, with
per-device tokens, T3 Code tasks through the bridge's own T3 session). See "Mobile API" below.

For the desktop app's Agent Dock it keeps one list of every agent on this Mac that waits for Samin (T3 Code threads,
Claude Code and Codex sessions, SamRabbit chats) and acts on them, and it is the dock's voice. See "Agent Dock" below.

```
R1 runtime ──HTTP (LAN, bearer token)──▶ samrabbit_bridge.py on the Mac ──▶ heptabase CLI ──▶ Heptabase app
```

## Requirements

- The Heptabase desktop app is running, with its CLI turned on
  (Heptabase > Settings > AI Features). `heptabase --version` should print `0.7.x`.
- macOS system Python 3.9+ (`/usr/bin/python3`). The bridge uses only the standard library.
- The R1 and the Mac are on the same local network.
- For Mac control: the `cua-driver` CLI with its daemon running and Accessibility granted to CuaDriver.app.
  The bridge finds it on `PATH`, in `/Applications/CuaDriver.app`, or in `~/.hermes/tools/cua-driver-*`
  (newest version), or use `--cua-driver <path>` / `SAMRABBIT_CUA_DRIVER`.
- For Google Calendar changes: the Composio CLI (`composio`), signed in, with Google Calendar linked
  (`composio link googlecalendar`). See "Google Calendar changes" below.
- For speech to text from the Apple Watch and the iPhone: macOS 26 or newer and Xcode or the Command Line Tools
  (to build the small helper once). See "Speech to text (watch and phone)" below.

## Install

```sh
companion/mac-bridge/install.sh            # options: --port 3780 --host 0.0.0.0 --python /usr/bin/python3
                                           #   --google-account you@example.com --t3-orchestration-project <id>
```

You can run it again at any time. It:

1. creates `~/.config/samrabbit/bridge-token` (random, mode 0600) if it doesn't exist yet, and never prints it;
   the same for `~/.config/samrabbit/desktop-token` (the desktop app's own token), and creates the conversation store
   folder `~/Library/Application Support/SamRabbit/sync/` (0700). It copies `ELEVENLABS_API_KEY` from
   `~/.hermes/.env`, when it is there, to `~/.config/samrabbit/elevenlabs-key` (0600, never printed; the watch
   assistant's voice) and prints `voice key: copied …`, `up to date`, `keeping …` or `none …`; `--assistant-model`,
   `--assistant-voice` and `--assistant-brain auto|realtime|claude` are recorded in
   `~/.config/samrabbit/assistant.json`;
2. copies the bridge (`samrabbit_bridge.py` and its modules: `samrabbit_mac.py`, `samrabbit_sync.py`, `samrabbit_genui.py`,
   `samrabbit_calendar.py`, `samrabbit_app.py`, `samrabbit_mobile.py`, `samrabbit_t3.py`, `samrabbit_transcribe.py`,
   `samrabbit_installed.py`, `samrabbit_assistant.py`, `samrabbit_assistant_mcp.py`, `samrabbit_chatgpt.py`,
   `samrabbit_realtime.py`, `samrabbit_realtime_profile.py`, `realtime/samrabbit_realtime_peer.py`) to
   `~/Library/Application Support/SamRabbit/bridge/`, writes the install marker
   `.samrabbit-installed` there (the folder's path; see "Which copy is the installed one" below) and prints
   `bridge copy: installed` (or `dev (<reason>)` for an install into another home), and builds the speech-to-text
   helper `samrabbit-transcribe` there (only when its source or the compiler changed), downloads the en-US speech
   model if it is missing, transcribes one clip that `say -o` writes to a file, and prints `transcription: on
   (SpeechTranscriber, en-US, a test clip took 0.2 s)` or `transcription: off (<reason>)`. A failed build never fails
   the install. It also makes the realtime voice's venv (`~/Library/Application Support/SamRabbit/realtime-venv`,
   Python 3.12 via `uv`, `aiortc` and `av` from `realtime/requirements.txt`: pinned with hashes, wheels only; made in a
   temp folder and swapped in only when the helper's `--check` passes; remade when the requirements change, and once
   per run when the venv's stamp matches but its `--check` fails: `the realtime venv does not pass its check; making
   it again`) and prints `realtime helper: ready (Python 3.12.x, aiortc 1.15.0, av 17.1.0)` or `realtime helper: off
   (<reason>)` (no `uv`: `brew install uv`). It never fails the install either;
3. writes `~/Library/LaunchAgents/com.samrabbit.bridge.plist` (RunAtLoad, KeepAlive, a PATH that includes
   `/opt/homebrew/bin`, `--sync-dir`, `--desktop-token-file` (no `--cli`: the install marker makes the installed copy
   use the real Heptabase CLI; see "Which Heptabase CLI" below), the Composio CLI's absolute path as
   `SAMRABBIT_COMPOSIO` when it is found, `--mobile-devices-file` and `--t3-token-file`, and logs to
   `~/Library/Logs/samrabbit-bridge.log`). `--google-account` / `--t3-orchestration-project` (or the same
   `SAMRABBIT_GOOGLE_ACCOUNT` / `SAMRABBIT_T3_ORCHESTRATION_PROJECT` in the environment) are recorded in the agent's
   environment and kept on later runs; an empty value removes one (see "Mobile API");
4. pairs the bridge with T3 Code once (`samrabbit_t3.py ensure-paired`: only when there is no good token yet; see
   "Mobile API" below), printing `T3 paired (expires …)` or a warning (the bridge then pairs by itself later);
5. reloads the agent (`launchctl bootout`/`bootstrap`/`kickstart`), waits for `/health`, prints one status line per
   feature (ending with `mobile: on (T3 paired, N devices, transcription on)`, `assistant: on (gpt-realtime-2.1 on
   ChatGPT, voice marin; fallback Claude Haiku 5.5, Jarvis voice)` (or `assistant: on (Claude Haiku 5.5, Jarvis
   voice)` until ChatGPT is connected, or why it is off), `realtime: on|off (<reason>)` and `chatgpt: connected (pro
   plan)` or `not connected`), the bridge URL, and how to pair an iPhone and connect ChatGPT.

Connect ChatGPT once for the watch's realtime voice: SamRabbit (desktop app) > Connect ChatGPT…, or
`companion/mac-bridge/connect-chatgpt.sh` (it prints a code and https://auth.openai.com/codex/device; sign in there,
enter the code, and it waits until the Mac is connected; `connect-chatgpt.sh status` / `disconnect`).

Then point the R1 at the bridge from the R1's management page (Connections > Heptabase journal >
"Connect through your Mac"), and paste the URL and token.

If you use the Heptabase sign-in instead of the bridge, `heptabase-connect.py` in this folder finishes it from the
Mac: `python3 companion/mac-bridge/heptabase-connect.py --r1 https://<R1 address>:8443 --pairing-code <code on the R1>`.
It pairs a management session, listens on the loopback redirect the R1 returns, opens Heptabase's Allow screen,
and forwards the one-time code to the R1, which does the token exchange itself. It uses only the standard library.

`uninstall.sh` stops and removes the agent (and the realtime venv) and keeps the tokens. `uninstall.sh --purge` also
deletes both tokens, the bridge's T3 token, the list of paired phones and the Mac's ChatGPT login.
Neither ever deletes the synced conversations in `~/Library/Application Support/SamRabbit/sync/`.

To update an installed bridge (for example to add conversation sync), run `install.sh` again: it keeps both tokens
and the R1's pairing, copies the new files and restarts the agent (a few seconds of downtime; the R1's journal and
sync outboxes simply retry).

## HTTP API

Every route needs `Authorization: Bearer <token>`, and the token is compared in constant time. Only loopback and
private-LAN peers are accepted (10/8, 172.16/12, 192.168/16, 169.254/16, fc00::/7, fe80::/10).

| Route | Result |
|---|---|
| `GET /health` | `{ok, service, version, cli:{available, version, mode ("real" or "dryRun")}, app:{reachable, detail}, dryRun, copy ("installed" or "dev"), mac:{…capabilities, screenLocked}, sync, genui, calendarWrite:{available, composio, path, calendarId, account, lastError, lastOkAt}, mobile, checkedAt}` (cached 10 s) |
| `POST /v1/heptabase/journal/append` `{date:"YYYY-MM-DD", content:"<markdown>"}` | the CLI's `{date, title, contentMd5}` (plus `dryRun: true` on a dry-run bridge) |
| `GET /v1/heptabase/journal/read?date=YYYY-MM-DD` | `{date, title, text, contentMd5}` (plus `dryRun: true` on a dry-run bridge): the day as plain text lines (paragraphs, headings, `- ` bullets, `1. ` numbers, `[ ]`/`[x]` todos, `+ ` toggles, `> ` quotes; marks removed; nested items indented) |

- `content` is Markdown as the desktop CLI parses it: CommonMark plus Heptabase's list (`+` toggles, `- [ ]` todos)
  and `{{...}}` mention syntax. Hepta Markdown tags such as `<hepta-color>` are **not** parsed and would show as
  literal text, so the R1 sends its gray action lines as italics on this path.
- The body may be at most 64 KB. `content` is written to a private 0600 temp file, passed with
  `--content-file`, and deleted right after.
- Appends run one at a time. Each CLI call has a 30 s limit.
- Errors look like `{"error":{"code","message","retryable","written"[,"reason"]}}`. `written` is `false` when the
  journal definitely wasn't changed and `"unknown"` when it might have been, for example after a CLI timeout. The
  R1's outbox retries `false` errors with backoff. For `"unknown"` it first reads the day back and looks for the
  entry, and resends only if it's missing.

| Status | Code | Meaning |
|---|---|---|
| 401 | `unauthorized` | missing or wrong token |
| 400 / 411 / 413 | `invalid_date`, `invalid_content`, `invalid_json`, `length_required`, `body_too_large` | bad request |
| 422 | `heptabase_rejected` (+ `reason`) | the app refused the content |
| 503 | `heptabase_app_unavailable` | the Heptabase app is closed or its CLI is off (retry later) |
| 503 | `heptabase_cli_missing`, `heptabase_busy`, `heptabase_app_error`, `bridge_busy` | retry later |
| 504 | `heptabase_cli_timeout` | the CLI didn't answer in 30 s (`written: "unknown"`) |

## Mac control

All `/v1/mac/*` routes need the token **and** a loopback or private-LAN peer, even when the bridge runs with
`--allow-any-client`. They drive the Mac only through the `cua-driver` CLI (one call at a time, JSON on stdin, 15 s
per call) and LaunchServices `/usr/bin/open`. There is no AppleScript (no Automation prompts), no shell and no
`kill_app`.

| Route | Result |
|---|---|
| `GET /v1/mac/state` | `{computer, front:{app, window}, visible:[{app, windows}], running:[names], chrome:[{window, activeTab, activeUrl, tabs}], screenVision, screenLocked}`: titles trimmed, URLs without query or fragment; `screenLocked` is `true`/`false`, or `null` when it can't be told |
| `POST /v1/mac/open` `{app}` \| `{url}` \| `{path}` | app: matched against installed apps (`list_apps`), started with `launch_app`, then `bring_to_front` (LaunchServices `open -b` as a fallback) so it really comes forward. url: http(s) only, `open -a "Google Chrome" <url>`. path: inside the home folder only; hidden folders, `~/Library`, apps, scripts, executables, Finder aliases and location files (`.webloc`, `.vncloc`, …) are refused |
| `GET /v1/mac/read?app=&max=` | `{app, window, text, controls, truncated?}`: the front (or named) app's front window as readable text (≤ 6000 chars) plus its button labels, from the accessibility tree (`get_window_state` without a screenshot) |
| `POST /v1/mac/act` `{action, …}` | one allowlisted step in the front (or `app`) window (background delivery first; when cua-driver refuses it, e.g. keys for an app with several windows, it is retried once in the foreground and the answer says `delivery: "foreground"`): `bring_to_front`; `hotkey` `{keys:"cmd+w"\|[…]}` (one key alone = a key press; log out, force quit, lock and delete-file chords are refused); `type_text` `{text ≤ 2000, label?}`; `click` `{label, role?, index?}` (an accessibility element from a fresh snapshot; several matches answer 409 `ambiguous` with `options`); `invoke_menu` `{path:["File","New Window"]}` (no Apple menu, shut down, log out, empty trash, move to trash); `scroll` `{direction, amount?, by?}`. In terminal apps (Terminal, iTerm2, Warp, Ghostty, …) and Script Editor, `type_text` and plain keys (return, arrows, ctrl+c, paste) answer 403 `terminal_blocked`: terminal work goes to a T3 agent (`mac_task`) |
| `GET /v1/mac/screenshot?max=1024&app=` | `{mime:"image/jpeg", base64, width, height, bytes}`: the screen (or the app's window), downscaled with `sips` to at most `max` px and 150 KB. While the screen is locked it answers **409** `{"error":{"code":"screen_locked","message":"Your Mac's screen is locked, so I can't see it. Unlock it and ask again.","retryable":true,"screenLocked":true}}` and captures nothing (a locked Mac would be all black). Without Screen Recording it answers **409** `{"code":"screen_recording_required","fix":"Run on the Mac: <path>/cua-driver permissions grant", "error":{…}}` and does not try to capture |

The lock check reads `/usr/sbin/ioreg -n Root -d1 -a` (about 25 ms, 2 s limit): the screen counts as locked when this
user's console session has `CGSSessionScreenIsLocked`, or when no session (the login window) or another user's session
is on the console. If `ioreg` fails or its answer is unclear, the lock state is unknown and nothing is blocked. `/health`
also reports it as `mac.screenLocked`.

Errors look like `{"error":{"code","message","retryable"[,"fix"][,"suggestions"|"options"]}}`, for example 404
`app_not_found` / `app_not_running` / `element_not_found`, 409 `accessibility_required` / `window_gone` / `ambiguous`,
503 `driver_missing` / `driver_unavailable` / `mac_busy`, 504 `driver_timeout`.

Screen vision needs one manual step on the Mac (it shows macOS consent dialogs, so only you can do it):
`~/.hermes/tools/cua-driver-0.21.0-darwin-arm64/CuaDriver.app/Contents/MacOS/cua-driver permissions grant`,
then allow CuaDriver under Screen & System Audio Recording. `/health` shows the exact command as
`mac.screenRecordingFix` while it is missing.

## Conversation sync

The R1 mirrors every voice conversation here, live, so the SamRabbit desktop app can show it (`samrabbit_sync.py`).
Nothing is ever deleted by the bridge.

```
R1 app ──(device-only)──▶ R1 runtime outbox ──POST /v1/sync/events, PUT /v1/sync/blobs──▶ bridge store
                                                                                           │
                         SamRabbit desktop app ◀──loopback + desktop token: list, events, SSE, blobs
```

Storage: `~/Library/Application Support/SamRabbit/sync/conversations.db` (SQLite, WAL, 0600) and content-addressed
images in `sync/blobs/<2 hex>/<sha256>` (folders 0700, files 0600). The bridge runs sync only when it has a sync folder:
the command line defaults to the one above (`--sync-dir`, `SAMRABBIT_SYNC_DIR`; an empty value turns sync off).

**From the R1** (bearer token + loopback/private-LAN peer, never relaxed by `--allow-any-client`):

| Route | Result |
|---|---|
| `POST /v1/sync/events` `{device:"r1", events:[…]}` (≤ 256 KB) | `{accepted, duplicates, rejected, cursor}`. `INSERT OR IGNORE` by event id, so a resend is harmless; malformed events are counted, never stored |
| `PUT /v1/sync/blobs/<sha256>` raw bytes, `Content-Type` (≤ 1 MB) | `{blobId:"sha256:<hex>", bytes, created}`; the hash is verified, a repeat is a no-op |

Events follow the shared contract: `id, type, conversationId, at` (epoch ms) and usually `sessionId, seq, origin`.
`message.assistant.delta` drafts keep only the newest copy per `messageId` and are removed once
`message.assistant.done`/`.interrupted` arrives.

**For the desktop app** (loopback peer only, a loopback `Host`/`Origin`, and the desktop token from
`~/.config/samrabbit/desktop-token` as header `X-SamRabbit-Desktop` or cookie `sr_desktop`; the R1's bearer token
is not accepted here, and the desktop token is not accepted on the R1 routes):

| Route | Result |
|---|---|
| `GET /v1/sync/conversations?limit=50&before=<lastAt>&q=` | `{conversations:[{conversationId, title, startedAt, lastAt, endedAt, live, messageCount, preview, device, cursor}], cursor, nextBefore?}` newest first. `title` is the first user utterance (or the first user line of a session's transcript); `live` = started, not ended and active in the last 20 minutes; `q` searches titles, previews and message text |
| `GET /v1/sync/conversations/<id>` | `{conversation}` |
| `GET /v1/sync/conversations/<id>/events?after=<cursor>&limit=200` | `{events:[…event, cursor], cursor, more}` in arrival order (sort by `at`/`seq` to display). Keep the returned `cursor` |
| `GET /v1/sync/stream?after=<cursor>` | Server-sent events across all conversations: `id: <cursor>`, `event: sync`, `data: <event JSON with cursor>`; a `: heartbeat` comment every 15 s; `Last-Event-ID` resumes; without `after` it starts at the newest event. At most 8 streams |
| `GET /v1/sync/blobs/<sha256>` | the bytes (`Content-Type` from the store, cached as immutable); 404 `blob_not_found` until it arrives |
| `GET /v1/sync/status` | `{conversations, events, blobs, cursor, lastReceivedAt, version}` |

Other bridge modules (generative UI) add to the same timeline in-process:
`samrabbit_sync.record_local_event(conversation_id, {"type": "ui.generated", …})` (id `mac:<uuid>`, `origin: "mac"`)
and `samrabbit_sync.put_blob(bytes, mime) -> "sha256:<hex>"`. Both return None (never raise) when sync is off.
`samrabbit_sync.desktop_request_denied(handler)` (None = allowed, else a `SyncError` with `status`, `code`,
`payload()`) is the shared desktop-auth rule for their loopback routes; it works even when sync is off.

`GET /v1/mac/screenshot?conversation=<id>` (the R1 runtime passes it for `mac_look` while it syncs images) also keeps
the JPEG in the store (`blobId`) and files an `image` event (`source: "mac_screenshot"`, `imageEventId`); without a
conversation nothing is kept.
`/health` reports `sync: {available, version, desktopToken}`.

Try it against a second instance (never the one the R1 uses):

```sh
python3 -I companion/mac-bridge/samrabbit_bridge.py --port 3794 --token-file /tmp/t/bridge-token \
  --sync-dir /tmp/t/sync --desktop-token-file /tmp/t/desktop-token
curl -s -H "X-SamRabbit-Desktop: $(cat /tmp/t/desktop-token)" http://127.0.0.1:3794/v1/sync/conversations
```
## Generated UIs

When you ask the R1's voice for a chart, a diagram, a dashboard or an explainer, it calls the `ui_generate` voice
tool and the bridge makes the widget on this Mac (`samrabbit_genui.py`, assets in `genui/`):

1. `claude -p` (the headless Claude Code CLI with your own login; default model `claude-sonnet-5-5`) writes one JSON
   object `{title, summary, initialHeight, css, html, jsFunctions, jsExpressions}` following `genui/skill.md`, a
   condensed version of OpenGenerativeUI's skills (MIT, see `genui/NOTICE.md`). The CLI runs with every tool
   off (`--tools ""`), no MCP servers, no skills, plugins or hooks (`--safe-mode`), no session files, in an empty
   temporary folder; the prompt goes in on stdin. Invalid answers (and JavaScript errors at render time) get one
   repair round. The whole Claude phase is limited to 120 s.
2. The widget is assembled like OpenGenerativeUI's `buildFinalFrameContent` (CSP with the four CDN origins for
   scripts and connect, importmap, the design-system CSS mapped to the R1's dark palette, the widget css and html)
   plus a small bridge script (`widget-resize`, `send-prompt`, `open-link`, `widget-ready` postMessages to the
   host page, and a Chart.js helper). Its `sendPrompt` / `openLink` helpers post only during a real user gesture,
   but generated code can post any message itself: the host must check the gesture and treat them as untrusted.
3. agent-browser renders it in a sandboxed iframe at 480 px wide (2x), and `sips` makes the R1 preview JPEG
   (at most 960 px wide and 150 KB).

One request runs at a time (up to 8 wait in a queue); requests still running when the bridge stops are picked up
again on start (if under 30 minutes old). Artifacts stay in `~/Library/Application Support/SamRabbit/artifacts/<id>/`
(`meta.json`, `request.json`, `args.json`, `document.html`, `preview.png`, `preview.jpg`; private to you; kept by
`uninstall.sh`). With the conversation-sync module installed, `ui.generating` / `ui.generated` / `ui.failed` events
and the preview image land in the conversation's timeline.

| Route | Result |
|---|---|
| `POST /v1/ui/generate` `{requestId, prompt ≤ 4000, data? ≤ 24000 chars (string or JSON), conversationId?, size?: "r1"\|"desktop"}` | `202 {artifactId, status:"generating"}` at once. Idempotent per `requestId` (same artifact; `200` with the current state once finished). 503 `genui_busy` when 8 are queued |
| `GET /v1/ui/artifacts/<id>` | `{artifactId, status:"generating"\|"ready"\|"failed", title, summary, error?, errorMessage?, imageBlobId?, width?, height?, conversationId?, createdAt, readyAt?, generationMs?, renderMs?, totalMs?}` |
| `GET /v1/ui/artifacts/<id>/image` | the preview JPEG (`image/jpeg`), 409 `image_not_ready` before it is ready |
| `GET /v1/ui/artifacts/<id>/document` | the assembled HTML document for a sandboxed iframe (`sandbox="allow-scripts"`), served with a `sandbox` CSP; desktop app only |

The R1 uses the bridge token from the local network for the first three routes. The desktop app reads the three GET
routes from loopback with its own token (`~/.config/samrabbit/desktop-token`, mode 0600) in the `X-SamRabbit-Desktop`
header or the `sr_desktop` cookie (and a loopback `Host`, no foreign `Origin`, like the sync module's desktop API);
`/document` answers only the desktop app (403 `desktop_only` for the bearer token). Failures use stable codes: `generation_timeout`, `claude_busy`, `claude_signed_out`,
`claude_missing`, `invalid_widget`, `renderer_missing`, `render_timeout`, `image_too_large`, `interrupted`.

Settings: `--claude`, `--agent-browser`, `--artifacts-dir`, `--genui-model` (or `SAMRABBIT_CLAUDE`,
`SAMRABBIT_AGENT_BROWSER`, `SAMRABBIT_ARTIFACTS_DIR`, `SAMRABBIT_GENUI_MODEL`). To switch the model without
reinstalling, write `{"model": "claude-opus-5-5"}` to `~/.config/samrabbit/genui.json` (read on every
generation). The CLI is found on `PATH`, then `~/.local/bin/claude`; agent-browser on `PATH`, then the newest
`~/.hermes/tools/agent-browser-*`. `/health` reports `genui: {available, claude, renderer, model, queued, sync}`.
## Google Calendar changes

The R1 reads your Google Calendar from its secret iCal address, which is read-only. To add, move or cancel an event
from Voice, the R1 asks the bridge, and the bridge runs the Composio CLI on this Mac (`samrabbit_calendar.py`), which
is signed in with managed Google auth:

```
R1 runtime ──POST /v1/calendar/events…──▶ bridge ──composio execute GOOGLECALENDAR_* -d - (JSON on stdin)──▶ Google Calendar
```

| Route | Result |
|---|---|
| `GET /v1/calendar/status` | `{available, composio, path, calendarId, account, lastError, lastOkAt}` (no CLI run, no network) |
| `POST /v1/calendar/events` `{title, startsAt, endsAt, timezone?, description?, location?, calendarId?}` | `{ok, calendarId, account, event:{eventId, iCalUID, calendarId, title, startsAt, endsAt, timezone, allDay, status}}` |
| `POST /v1/calendar/events/update` `{iCalUID \| eventId, recurrenceId?, title?, startsAt?, endsAt?, timezone?, description?, location?, calendarId?}` | the same shape; at least one change is required |
| `POST /v1/calendar/events/delete` `{iCalUID \| eventId, recurrenceId?, calendarId?}` | `{ok, deleted:true, calendarId, eventId}` |

- Times are RFC 3339 with an offset (`2026-10-08T10:33:00-04:00`); events end after they start and last at most 31 days.
  All-day events are not supported yet.
- `calendarId` defaults to `primary` (`--calendar-id` / `SAMRABBIT_CALENDAR_ID` to change it). The R1 sends the
  calendar its iCal address shows, so new events land where the R1 reads them. A malformed `--calendar-id` (or a
  private working folder that can't be created) turns calendar changes off, never the bridge: it logs the reason,
  `/health` says `calendarWrite.available: false` with `lastError` `calendar_id_invalid` / `calendar_setup_failed`,
  and changes answer 503 `calendar_unavailable`.
- An iCal UID `<eventId>@google.com` is the event id directly; any other UID is looked up first with the read-only
  `GOOGLECALENDAR_EVENTS_LIST`. `recurrenceId` (`YYYYMMDD` or `YYYYMMDDTHHMMSSZ`, the occurrence's original start) makes
  the instance id `<seriesId>_<recurrenceId>`, so one occurrence of a repeating event is changed alone, never the series.
- New events have no Meet link and no attendee list (`create_meeting_room: false`, `exclude_organizer: true`); no
  change sends emails (`send_updates: "none"`). Update answers carry `event.guests`, Google's count of the event's
  guests (not you, not rooms), so the R1 can say that the guests were not notified.
- One CLI call at a time (another request waits up to 15 s, then 503 `calendar_busy`), 30 s per call, no shell, a small
  environment, its own private working folder, and the whole process group is killed on timeout.
- Errors are `{"error":{"code","message","retryable","written"[,"fix"]}}`: 409 `calendar_not_connected` (fix:
  `composio link googlecalendar`), 403 `calendar_forbidden` (not the organizer, or a read-only calendar; Google's 403
  `rateLimitExceeded` / `userRateLimitExceeded` and any 429 are 503 `calendar_rate_limited`, retryable), 404
  `calendar_event_not_found` / `calendar_not_found`, 400 `calendar_invalid_request` / `invalid_time` / `invalid_event`,
  422 `calendar_rejected`, 503 `composio_missing` / `composio_signed_out` / `calendar_rate_limited`, 502
  `calendar_google_error` / `calendar_bad_answer` / `composio_failed`, 504 `calendar_timeout`. `written` is `"unknown"`
  when the change may have reached Google (a timeout, a crash, a Google server error); otherwise `false`.
- The CLI is `--composio` / `SAMRABBIT_COMPOSIO` (install.sh records its absolute path, because a LaunchAgent's PATH
  has no `~/.local/bin`), else `PATH`, `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`. `account` is the Google
  account of the last successful change (or `SAMRABBIT_CALENDAR_ACCOUNT`).

On the R1, `calendar_create_event` and `calendar_update_event` on the Google Calendar subscription (or with no
calendar named) go here right away and are copied into the R1's calendar store at once, under the feed's own key,
so the next iCal refresh updates that row instead of adding a second one. `calendar_delete_event` still asks the user
first (`calendar_confirm_action`).

## Mobile API (iPhone, widgets, Apple Watch)

`samrabbit_mobile.py` answers `/v1/mobile/*` for the SamRabbit iPhone app (CONTRACTS-WAVE4); T3 goes through
`samrabbit_t3.py`. One hub, one token per device:

- **Peers:** loopback, private LAN (10/8, 172.16/12, 192.168/16, link-local) and Tailscale (100.64.0.0/10,
  fd7a:115c:a1e0::/48) only; anything else gets 403. (The R1 routes stay LAN-only; Tailscale is accepted here so
  the phone keeps working away from home once Tailscale is signed in.)
- **Tokens:** every route except `pair` needs `Authorization: Bearer <mobile token>`. The bridge keeps only SHA-256
  hashes in `~/.config/samrabbit/mobile-devices.json` (0600): `{deviceId, name, platform, createdAt, lastSeenAt,
  tokenHash[, parentId]}`. The R1's bridge token and the desktop token open none of these routes.
- **Pairing:** the desktop app (SamRabbit > **Pair iPhone…**) or `companion/mac-bridge/pair-phone.sh` calls
  `POST /v1/mobile/pairing/start` (loopback + desktop token, like the desktop sync API) and shows
  `{code, expiresAt, pairUrl, hosts}`: an 8-character code (A–Z and 2–9 without I, O, 0, 1; single use; 10 minutes;
  a new code replaces the previous one), the LAN address (+ the Tailscale address when there is one) and
  `samrabbit://pair?h=<host:port>[,<host2:port>]&c=<code>&n=<Mac name>` (the QR). The phone answers with
  `POST /v1/mobile/pair {code, deviceName, platform: "ios"|"watchos"}` → `{token, deviceId, bridgeName,
  bridgeVersion}`. Ten wrong codes in ten minutes lock pairing (429 `pairing_rate_limited`) until the window passes.
- **Devices:** `GET /v1/mobile/devices` and `DELETE /v1/mobile/devices/<id>` (desktop app only) list and revoke
  (revoking a phone also revokes its watch). The phone mints its watch's own token with
  `POST /v1/mobile/devices/child {name, platform: "watchos"}` (provisioning the same watch again replaces its old
  token); `POST /v1/mobile/unpair` lets a device forget itself.

Routes (all JSON unless noted; errors `{"error": {code, message, retryable}}`; times are ISO 8601, except the reused
sync routes, which keep epoch milliseconds):

| Route | What |
|---|---|
| `GET /v1/mobile/summary` | `{generatedAt, mac: {name, online, screenLocked}, r1: {lastSeenAt, live, liveConversationId, liveTitle}, t3: {available, needsYou, working, threads: [top 5 {threadId, title, project, status, updatedAt, summary}]}, calendar: {available, next: [≤3 {title, startsAt, endsAt, allDay, location, meetingUrl}]}, latestConversation: {conversationId, title, lastAt, preview, live}, journal: {available}, transcribe: {available, reason?}}`. Served from caches (< 300 ms) that a worker refreshes while a device is active (T3 every 10 s, calendar every 120 s, journal every 5 min, screen lock every 15 s, transcription every 60 s). `transcribe` tells the phone and the watch whether `POST /v1/mobile/transcribe` works now (the same `reason`s as `/health`, e.g. `helper_missing`, `model_downloading`, `permission_denied`); a recording that just worked or failed updates it at once. The journal check is one read of today through the bridge's own read slots (at most two Heptabase CLI reads at once), and a note added from the phone counts as a check. A part that can't be read says `available: false` with a `reason` (`loading` while a cold start is still reading it). |
| `GET /v1/mobile/conversations?limit=&before=&q=`, `GET /v1/mobile/conversations/<id>[/events?after=]`, `GET /v1/mobile/stream?after=` (SSE), `GET /v1/mobile/blobs/<sha256>` | the desktop sync API's own handlers (same JSON and SSE format), authorized by the mobile token. Phones and watches share 4 of the sync store's 8 live streams (so the desktop app always has some; 503 `too_many_streams` beyond that), at most 2 per device (a third one, e.g. a reconnect, closes that device's oldest); revoking a device ends its open streams at once |
| `GET /v1/mobile/ui/artifacts/<id>` (+ `/image` JPEG, `/document` HTML with the generated-UI CSP) | a generated UI's status and content |
| `POST /v1/mobile/ui/generate {prompt, data?, requestId?}` | → `202 {artifactId, status, conversationId}`; the request and the result are recorded in the day's **"Phone"** conversation (`phone-YYYYMMDD`, never live), so the desktop app shows them too. A request the generator would refuse (bad `data`, 503 `genui_busy`) records nothing. With the phone's own `requestId` (1–96 of `A-Z a-z 0-9 . _ : -`), a retry after a timeout answers the same visual and records the request once |
| `GET /v1/mobile/t3/threads?filter=needs_you\|working\|recent` | `{threads: [{threadId, title, projectId, projectName, status: needs_approval\|needs_input\|working\|done\|error\|idle, statusLabel, updatedAt, summary, settled, pending?: {kind: approval\|question, text, options, requestId, …}}]}` (idle = never ran a turn). Needs-you threads whose open request is not cached yet are read before answering (up to 4, about 2.5 s at most), so `pending` is there on the first load |
| `GET /v1/mobile/t3/threads/<id>` | `{thread, messages: [{role: user\|assistant\|tool, text, at}], pending, activeTurnId}` (a run of tool steps is one `tool` line) |
| `POST /v1/mobile/t3/threads/<id>/message {text}` · `/respond {decision: "approve"\|"deny"}` or `{answer}` (or `{answers: {questionId: …}}`) · `/stop` | `thread.turn.start` / `thread.approval.respond` (approve → accept, deny → decline) / `thread.user-input.respond` (option values as T3 expects; as on the R1, an answer may be the label, a shortened label, a number or a position such as "the first one"; other words go as free text only when the question allows it) / `thread.turn.interrupt` |
| `POST /v1/mobile/t3/threads {text, projectId?, title?}` | `thread.create` + `thread.turn.start` → `{threadId, title, projectId, projectName, placement}`. Without `projectId`: a project the request names, coding work to the most recently active code project, everything else to the orchestration project (`SAMRABBIT_T3_ORCHESTRATION_PROJECT` id, e.g. from `install.sh --t3-orchestration-project`, else the project titled `SAMRABBIT_T3_ORCHESTRATION_TITLE`, default T3's agent project "Hermes", else T3's agent workspace project, else the most recent one). See "Placement compared with the R1" below. |
| `GET /v1/mobile/t3/projects` | `{projects: [{projectId, name, orchestration}], orchestrationProjectId}` |
| `GET /v1/mobile/calendar/agenda?hours=24` | Composio `GOOGLECALENDAR_EVENTS_LIST` (single events, by start time) on the bridge's calendar (`primary`), cached 120 s: `{available, timezone, from, to, events: [{eventId, title, startsAt, endsAt, allDay, location, meetingUrl}], cached}` (no cancelled, declined or working-location entries) |
| `POST /v1/mobile/calendar/block {minutes, title?}` | an event from now (rounded down to the minute) for `minutes` (5–720), in `SAMRABBIT_TIMEZONE` (default America/New_York), default title "Focus" |
| `POST /v1/mobile/calendar/events {title, startsAt, endsAt}` | the same writer as `/v1/calendar/events` |
| `POST /v1/mobile/journal {text}` | appends `**HH:MM** <text>` (the words escaped, nothing added) to today's Heptabase journal; explicit notes only. As on the R1 (its "redact secrets" setting is on by default), API keys, tokens, private keys, "the code is 123456" and "password is …" are written as `[redacted]`, and the answer then says `redacted: true` |
| `POST /v1/mobile/transcribe[?lang=en-US]` | a raw recording as the body → `{text, durationMs, engine, locale}`; see "Speech to text (watch and phone)" below |
| `GET /v1/mobile/mac/state` · `POST /v1/mobile/mac/open {app\|url}` · `GET /v1/mobile/mac/screenshot?max=` | Mac control; the screenshot is a JPEG, or 409 `screen_locked` / `screen_recording_required`. `open` pins Google Calendar, Gmail, Drive, Docs and Meet links to one account with `authuser=`: `SAMRABBIT_GOOGLE_ACCOUNT` (`install.sh --google-account`), else the account on an event the bridge created, else the account the agenda shows (an event its owner created, the primary calendar's own name, or a calendar id that is an email), learned on every calendar refresh, so right after a restart too (a Google link with nothing known yet reads the agenda first) |

`/health` adds `mobile: {available, devices, t3: {paired, ok, reason?}, transcribe: {available, engine?, locale?, reason?}}`.

### Speech to text (watch and phone)

watchOS has no speech recognizer an app can use, and the system text input can't be forced into dictation, so the
watch records a clip itself and the Mac turns it into words. `samrabbit_transcribe.py` runs `samrabbit-transcribe`,
a small Swift helper (`transcribe/samrabbit_transcribe.swift`, with `transcribe/Info.plist` embedded) that uses
macOS's own on-device SpeechAnalyzer + SpeechTranscriber (macOS 26+; DictationTranscriber when this Mac has no
SpeechTranscriber). Nothing leaves the Mac, no microphone is involved and there is no permission prompt: the input is
a file. A 6 s clip takes about 0.2–0.3 s.

`POST /v1/mobile/transcribe[?lang=en-US]` with the mobile token, from a LAN or Tailscale peer like every mobile route:

- Body: the raw recording with `Content-Type: audio/mp4` / `audio/x-m4a` (an m4a, e.g. AAC 16 kHz mono from
  `AVAudioRecorder`), `audio/wav` or `audio/aac` (ADTS), also spelled `audio/m4a`, `audio/x-wav`, `audio/wave`,
  `audio/vnd.wave`, `audio/x-aac` or `audio/aacp`; `Content-Length` required; at most 2 MiB and 90 s. The
  container is checked from the bytes (`ftyp` at offset 4, `RIFF…WAVE`, an ADTS frame) and its length read from the
  header before anything runs; the helper checks the length again.
- Answer: `{text, durationMs, engine: "SpeechTranscriber"|"DictationTranscriber", locale}`. `lang` is a BCP 47 tag
  (default `en-US`), made deterministic: a bare language is always the same locale, never the Mac's own region
  (`en` → `en-US`, `fr` → `fr-FR`, `es` → `es-ES`, `de` → `de-DE`, `it` → `it-IT`, `ja` → `ja-JP`, `pt` → `pt-BR`,
  `zh` → `zh-CN`, …; `zh-Hans` → `zh-CN`, `zh-Hant` → `zh-TW`), and the case is canonical (`EN_us` → `en-US`), so
  `en` and `en-US` share one status check and one model download. SpeechTranscriber knows about 45 locales, and a
  locale whose model is not on the Mac yet is downloaded in the background on its first use.
- The audio is written to a private temp file (0600 in its own 0700 folder `$TMPDIR/samrabbit-voice-<pid>-…`) only
  while the helper runs, and deleted right after; when the bridge starts it removes the folders a bridge that stopped
  mid-transcription left behind (its process is gone, or older than any transcription runs). The helper runs in a
  session of its own with a deadline of its own (`--deadline 40`: it answers `transcribe_timeout` and exits by
  itself, even with no bridge left to stop it); at the bridge's own 45 s it kills the helper's whole process group.
  At most 2 transcriptions run at once. Neither the audio nor the words are logged or kept; the helper prints them
  only on its stdout, and its stderr is discarded.
- Errors (`{error: {code, message, retryable, reason?}}`):

| Status | Code | When |
|---|---|---|
| 503 | `transcribe_unavailable` | `reason`: `helper_missing` (not built: run `install.sh` with Xcode or the Command Line Tools), `speech_unavailable` (no on-device transcriber on this Mac), `model_downloading` (retryable: the language's model is downloading now), `model_missing` (its download failed; tried again after 30 minutes), `insufficient_resources` (retryable) |
| 503 | `transcribe_permission` | Speech Recognition is turned off for it (System Settings > Privacy & Security > Speech Recognition) |
| 502 / 504 | `transcribe_failed` | the helper failed or crashed, or the recording could not be stored (502), or it ran out of time (504: its own 40 s deadline or the bridge's 45 s); retryable |
| 503 | `transcribe_busy` | two transcriptions were still running after a 10 s wait for a free slot (retryable) |
| 415 | `unsupported_audio` | another Content-Type, or bytes that are not an m4a, WAV or ADTS AAC recording |
| 413 | `body_too_large` / `audio_too_long` | over 2 MiB / over 90 s |
| 422 | `no_speech` / `unsupported_language` | nothing was said / the Mac can't transcribe that language |
| 400 | `invalid_lang` / `invalid_audio` | a bad `lang` / an empty or incomplete body |

`/health` says `mobile.transcribe: {available: true, engine: "SpeechTranscriber", locale: "en-US"}` (checked with
`samrabbit-transcribe --check` at most every 10 minutes; a transcription that worked counts as a check), or
`{available: false, reason}`: `reason` is `permission_denied` when Speech Recognition is turned off for the helper
(seen by the check, or by a recording that failed with `transcribe_permission`, whatever its language), and also
`helper_missing`, `speech_unavailable`, `model_missing`, `model_downloading`, `check_timeout` or `check_failed`. The
summary's `transcribe` says the same. The bridge finds the helper next to its script; `--transcribe-helper <path>`
(`SAMRABBIT_TRANSCRIBE_HELPER`) points it elsewhere. By hand:
`samrabbit-transcribe --check | --prepare | --file clip.m4a [--locale en-US] [--deadline <seconds>]` prints one JSON
object (its own deadlines without `--deadline`: 40 s for a file, 20 s for a check, 15 minutes for a download).
A later recording that works, in any language, clears a `permission_denied` the status still remembered.

### Voice assistant (the watch)

The watch talks to SamRabbit like the R1: it listens, sends one utterance at a time, plays the answer and listens
again (`samrabbit_assistant.py`). The Mac turns the recording into words (the speech-to-text helper above), runs one
agent turn with the headless Claude Code CLI (Claude Haiku 5.5 by default) and SamRabbit's own tools, and speaks the
answer with ElevenLabs (the Jarvis voice). Every route takes the mobile token, from a LAN or Tailscale peer.

| Route | Answer |
|---|---|
| `POST /v1/mobile/assistant/turn` | audio body (`audio/wav`, `audio/mp4`, `audio/x-m4a`; ≤ 2 MiB and 60 s) with `X-SamRabbit-Conversation` (an id, or empty for a new conversation), `X-SamRabbit-Turn` (a uuid; a retry gets the same answer and the agent runs once), optional `X-SamRabbit-Device-Time`, optional `?lang=`; or JSON `{text, conversationId?, turnId}` → `{conversationId, turnId, heard, say, audio: {mime: "audio/mpeg", b64} \| null, expectReply, endConversation, actions: [{kind, title, threadId?, artifactId?, eventId?, project?}], timings: {stt, agent, tts}}` |
| `GET /v1/mobile/assistant/announcements?conversationId=&since=` | `{items: [{id, say, audio \| null, kind: needs_you \| done \| error, threadId, title}], cursor}`: T3 tasks that started needing Samin, finished or failed since the conversation began, each once per conversation; the next turn tells the agent what was announced ("approve it") |
| `POST /v1/mobile/assistant/end {conversationId}` | optional: the watch stopped listening (`conversation.ended`) |

- Nothing heard, or only "uh" / "hmm": `{heard: "", say: "", audio: null, expectReply: true}` without the agent.
  "Bye", "stop", "never mind", "thanks, that's all": a short goodbye with `endConversation: true`, without the agent.
  `expectReply` is true when the answer asks a question. `actions` lists what the tools changed (`task_started`,
  `task_replied`, `task_answered`, `task_stopped`, `event_created`, `journal_added`, `mac_opened`, `ui_generated`).
- Limits: speech to text 45 s, the agent 25 s (504 `assistant_timeout`; the CLI's whole process group is killed), the
  voice 10 s (then `audio: null` and the watch speaks `say` itself). One turn per conversation at a time (409
  `assistant_busy`, retryable). Errors: 503 `assistant_unavailable` with `reason` (`claude_missing`,
  `claude_signed_out`, `claude_busy`, `claude_failed`, `model_unavailable`, `assistant_dev_copy`, …), `transcribe_*`,
  `invalid_*`.
- The agent: `claude -p --model <assistant.model> --output-format stream-json --verbose --setting-sources ""
  --strict-mcp-config --mcp-config <0600 file> --tools "" --allowedTools mcp__samrabbit --permission-mode dontAsk
  --disable-slash-commands --max-turns 6 --system-prompt-file <file>`, `--session-id <uuid>` on a conversation's
  first turn and `--resume <uuid>` after it, the utterance on stdin (prefixed `[Now: Thursday, October 8, 2026, 2:37
  PM America/New_York · device: watch]`), in an empty folder of its own
  (`~/Library/Application Support/SamRabbit/assistant/cwd`), with only `HOME USER LOGNAME TMPDIR LANG PATH` and
  `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 CLAUDE_CODE_DISABLE_AUTO_MEMORY=1 DISABLE_AUTOUPDATER=1`. No user or
  project settings, hooks, plugins, CLAUDE.md or MCP servers load (the user's hooks would upload utterances); never
  `--bare` (no login) or `--safe-mode` (no MCP servers). Its session files are pruned after two weeks.
- Its tools (`samrabbit_assistant_mcp.py`, a stdio MCP server: `get_status`, `list_tasks`, `read_task`,
  `start_task`, `reply_task`, `respond_task`, `stop_task`, `calendar_agenda`, `calendar_block`, `calendar_create`,
  `journal_add`, `mac_open`, `mac_look` (an image the model sees), `generate_ui`, `recent_conversations`) call this
  bridge's own mobile API over loopback with an internal assistant token (made at start, in a 0600 file; loopback
  only; a short list of routes, never pairing, the stream or the assistant itself).
- Settings: `~/.config/samrabbit/assistant.json` `{"model": "claude-haiku-5-5" | "claude-sonnet-5-5", "voice":
  "<ElevenLabs voice id>"}` (re-read every turn), or `--assistant-model` / `--assistant-voice`
  (`SAMRABBIT_ASSISTANT_MODEL` / `SAMRABBIT_ASSISTANT_VOICE`). The voice: `POST
  https://api.elevenlabs.io/v1/text-to-speech/<voice>?output_format=mp3_44100_64`, `eleven_flash_v2_5`, stability
  0.5, similarity 0.75, style 0, numbers written out in words first; the key from `--elevenlabs-key-file` (default
  `~/.config/samrabbit/elevenlabs-key`); a rejected key pauses it for 10 minutes.
- Every turn is recorded in the sync store as a "Watch" conversation (`watch-<conversationId>`, titled `Watch: <first
  words>`): `conversation.started`, `message.user`, `tool.completed` (a `mac_look` screenshot as an image),
  `message.assistant.done`, `conversation.ended` (after a goodbye, `/end`, or 5 minutes without a turn), and
  announcements as `host.t3_update`, all with origin `watch`. Visuals made from the watch land in the same
  conversation. Utterances, replies, tool inputs and outputs, tokens, keys and audio are never logged.
- `/health` adds `assistant: {available, reason?, model, modelName, claude, copy, voice: {available, reason?, voice,
  voiceName, model}, conversations, lastTurn?}`; the summary adds `assistant: {available, reason?, model}`.
- A dev copy (see "Which copy is the installed one") runs the agent only with an explicit `--claude`, speaks with
  ElevenLabs only with an explicit `--elevenlabs-key-file` (never the real key, never ElevenLabs credits), keeps its
  working files in a temp folder (`--assistant-dir` to choose one), and its tools only reach its own dev-safe answers.

### Realtime voice (the watch's primary brain, like the R1)

The watch assistant answers like the R1 (`samrabbit_realtime.py`): **gpt-realtime-2.1** on Samin's ChatGPT
subscription, the voice **marin**, the R1's own instructions and tool names. Setting `assistant.brain` (in
`assistant.json`, or `--assistant-brain`): `auto` (default: realtime when ChatGPT is connected and the helper is
ready, else Claude), `realtime` or `claude`. A realtime turn that fails before anything happened (OpenAI refused, the
network, the helper) is answered by Claude instead, and a refusal pauses realtime for a while (`401/403`: 10 minutes,
`429`: 1 minute). Once a tool ran, or words, audio, an action or a card went out, nobody answers that turn again
(that would create the T3 task, the event or the note twice): a failed response ends it with what it has ("Sorry, I
got cut off partway through that."), a lost connection with `error {assistant_interrupted}` (a retry of the same turn
gets the same answer); the tools that ran are in the timeline either way. A turn Samin stopped (`cancel`) ends
interrupted, never answered by Claude. The summary says `assistant: {available, brain, reason?, model, chatgpt:
{connected}}`.

- **The login** (`samrabbit_chatgpt.py`): the R1's Codex device flow (`app_EMoamEEZ73f0CkXaXp7hrann`,
  `https://auth.openai.com`: `deviceauth/usercode`, `deviceauth/token`, `oauth/token`), but the Mac's own login, so
  it never rotates the R1's refresh token, and it never reads or writes `~/.codex`. Tokens live in
  `~/.config/samrabbit/chatgpt-auth.json` (0600) and are refreshed five minutes before they expire (and once when
  OpenAI refuses one); a refused refresh means connect again. Only a real change (a new login stored, a disconnect,
  a refused refresh; never a code that expired or a poll that failed) retires the live sessions: each finishes the
  turn it is in, then closes (the next turn opens a new one). Routes for the desktop app (loopback + desktop token):
  `POST /v1/assistant/chatgpt/start` → `{userCode, verificationUrl, expiresAt}` (the bridge then polls by itself),
  `GET /v1/assistant/chatgpt/status` → `{connected, plan?, email?, login: {state, …}}`,
  `POST /v1/assistant/chatgpt/disconnect`. A dev copy uses a login only with an explicit `--chatgpt-auth-file`.
- **The WebRTC peer**: the watch cannot do WebRTC and a subscription token cannot open a realtime WebSocket, so the
  Mac is the peer. `realtime/samrabbit_realtime_peer.py` runs in the realtime venv, one process per watch
  conversation: an `RTCPeerConnection` with no ICE servers (like the R1), a silent outbound audio track and the
  `oai-events` data channel; it forwards the reply's audio (Opus) as PCM16 16 kHz mono. The bridge does the
  signaling itself, exactly like the R1's `platform.py` (`POST https://api.openai.com/v1/realtime/calls`, multipart
  `sdp` + `session`, headers `Authorization: Bearer <access token>`, `Accept`, `OpenAI-Safety-Identifier`,
  `Content-Type`), so the token never reaches the helper (never on argv, never logged). Helper protocol: JSON lines
  on stdin/stdout (see the helper's docstring); it never logs anything. Its data channel advertises an SCTP
  `max-message-size` of 256 KiB like libwebrtc (aiortc's default says 64 KiB, so OpenAI would drop a bigger event,
  such as the echo of a `mac_look` screenshot); events the bridge sends stay under 240 KiB. A reply's audio never
  starts with an earlier one's: the pre-roll holds only the response being made (emptied on `response.created` and
  on a cleared buffer, nothing kept after a barge-in), and the packets aiortc's jitter buffer held over a pause in
  RTP are dropped when a new response began meanwhile.
- **The session**: the R1's `_realtime_session` shape with manual turns: `{type: realtime, model: gpt-realtime-2.1,
  output_modalities: [audio], audio: {input: {format: audio/pcm 24 kHz, turn_detection: null}, output: {format,
  voice: marin}}, tools, tool_choice: auto}`. Instructions: `PRIMARY_VOICE_INSTRUCTION` (verbatim from
  `runtime/sam_runtime/realtime/modes.py`), `T3_VOICE_INSTRUCTION` with the live T3 status block, the Mac and visuals
  addenda (all verbatim; `tests/test_realtime_profile.py` fails when the runtime's text changes), then a short watch
  addendum. Tools: the R1's `t3_*` and `mac_*` specs verbatim, `calendar_list_upcoming`, `calendar_create_event`,
  `journal_add` (only Samin's own words: the Mac checks them against what he said), `journal_read`, `ui_generate`
  (it appears on the iPhone and in the desktop app), `show_card` / `update_card` / `dismiss_card` (a small card on the
  watch), plus `get_status` and `recent_conversations`. They run on the Mac one at a time (like the R1's tool queue),
  through the same mobile API calls as the Claude path's tools (loopback, never through a system proxy).
- **A conversation's session** opens with `POST /v1/mobile/assistant/session` (or the first turn) and closes on
  `/end`, a goodbye, three idle minutes, or after 55 minutes (the next turn opens a new one with a short summary).
  A warm-up without a `conversationId` reuses the device's latest conversation that is still going (not ended, a
  turn in the last five minutes), so relaunching the watch app keeps one warm session instead of stacking calls. At
  most 2 sessions live per device and 4 on the Mac (each is an OpenAI call on the subscription and a helper
  process): a new one closes the least recently used idle one; when every other one is mid-turn, that turn is
  answered by Claude (no pause). A session whose connection ended while idle (the helper reported it, or the data
  channel was already closed when the turn sent its words) is never reused: the turn opens a new one and goes on,
  without pausing the brain or handing over to Claude. Closing a session while it is still opening (an end, the cap)
  never pauses the brain or counts it as live.
  Per turn: `conversation.item.create` (the words, with `[Now: …]` when the minute changed) and `response.create`;
  the transcript deltas and the audio stream to the watch as they come; a function call runs on the Mac, then
  `function_call_output` and `response.create` after `response.done`; every function call gets an output, also one
  that only appears in a cancelled response's `response.done`. When OpenAI refuses `response.create` because an
  earlier response is still active (`conversation_already_has_active_response`), the bridge cancels that stale
  response, ignores its words, audio and calls (each call gets a "cancelled" output and never runs), and sends
  `response.create` again after its `response.done` (or after 3 s). `POST /v1/mobile/assistant/cancel` sends
  `response.cancel` and `output_audio_buffer.clear` (the stream ends with `done {interrupted: true}`). Announcements
  are said by the session itself (`{"announce": id}` turns: a `[T3 update]` item and `response.create` with
  instructions to say the line verbatim).
- A live check: `/usr/bin/python3 -I companion/mac-bridge/realtime/smoke_turn.py` pairs a temporary device, sends one
  streamed text turn to the running bridge (nothing is played; the audio is only counted), ends the conversation,
  revokes the device and prints only the brain, the events, the seconds of audio and the timings.
- `/health` adds `assistant.brain`, `assistant.brainSetting` and `assistant.realtime: {available, reason?, model,
  voice, helper: {ready, python?, aiortc?, av?, reason?}, sessions, chatgpt: {connected, plan?}, lastError?}`.

**Streaming turns** (the contract with the watch). `POST /v1/mobile/assistant/turn` with `Accept:
application/x-samrabbit-stream` answers `200`, `Content-Type: application/x-samrabbit-stream`, `Transfer-Encoding:
chunked` (HTTP/1.1), as frames of 1 type byte, a 4-byte big-endian length and the payload: `J` = a UTF-8 JSON event
(`heard`, `say.delta`, `say.done`, `action`, `card`, `done {conversationId, turnId, expectReply, endConversation,
interrupted?, brain, timings: {stt, firstAudio, total}}`, `error {code, message}` (then `done`), `ping`), `A` =
PCM16LE mono 16 kHz audio, up to 100 ms per frame (often shorter: buffered audio is flushed before each `J` event). The
Claude brain streams the same way (ElevenLabs `pcm_16000`). Without that header the answer is the buffered JSON above
(a realtime turn's audio as `audio/wav`), so old clients keep working. A retried turn id replays the same answer
without running again (text, actions and cards; audio only while it is still cached).

- **Keep-alive:** while a turn is open (also while a retry of the same turn id waits for it), a stream that wrote no
  frame for 10 s writes `J {"type":"ping"}`, so a long tool call (`ui_generate`, `mac_look`, T3) never looks like a
  dead connection (the watch gives up after 40 s of silence). Clients ignore it (and any other unknown event type).
  A ping can be the stream's first frame: then the response is already `200`, and a failure after it comes as
  `error` + `done` in the stream instead of a JSON error envelope.
- Failures before the first frame (`409 assistant_busy`, `503 assistant_unavailable`, `transcribe_*`, `invalid_*`)
  answer the normal JSON error envelope with that status, even with the stream's `Accept`.

**T3 Code.** The bridge has its own T3 session ("SamRabbit bridge", scopes `orchestration:read orchestration:operate`),
separate from the R1's. It mints a pairing credential with the CLI inside the T3 Code app
(`ELECTRON_RUN_AS_NODE=1 "/Applications/T3 Code (Alpha).app/Contents/MacOS/T3 Code (Alpha)" …/app.asar/apps/server/dist/bin.mjs
auth pairing create --label "SamRabbit bridge" --ttl 10m --base-url http://127.0.0.1:3773 --json`), exchanges it
at `POST /oauth/token` and keeps the 30-day token in `~/.config/samrabbit/t3-token` (0600, JSON with its expiry and
session id). It pairs again by itself when the token is missing, has less than a day left, or T3 answers 401 (at most
once per request), but never in a loop, since each pairing runs the Electron CLI and adds a "SamRabbit bridge" session
in T3: a failed pairing waits 1 minute before the next one (doubling up to 10 minutes); a token the bridge minted that
T3 refuses before it ever worked, or within a minute, means T3 is not taking its credentials, so the next pairing
waits 5 minutes (doubling up to an hour; every request meanwhile answers 502 `t3_unauthorized` without pairing); a
token that worked for a while and is then revoked is replaced at once; and there are never more than 6 pairings in
an hour. `/health` then says `mobile.t3: {paired: false, ok: false, reason}`. `install.sh` pairs once;
`python3 -I samrabbit_t3.py status` shows the state. Options:
`--t3-url`, `--t3-cli`, `--t3-token-file` (`SAMRABBIT_T3_URL`, `SAMRABBIT_T3_CLI`, `SAMRABBIT_T3_TOKEN_FILE`).
A copy of the bridge that is not the installed one (a checkout, a test, a copy installed into a temp HOME; see "Which
copy is the installed one") never talks to T3 unless given `--t3-url` (it answers 503 `t3_dev_copy`), just as it
never changes Google Calendar unless given `--composio` (`calendar_dev_copy`) or writes the journal (dry run). Even
with `--t3-url` (or `SAMRABBIT_T3_URL`) it pairs only through an explicit `--t3-cli <path>`: the T3 Code app's own CLI
(`auto`) is for the installed copy only, so a server address alone never mints a credential on the real T3 Code
(pairing answers `t3_dev_copy`). `samrabbit_t3.py ensure-paired` follows the same rule: from any other copy it pairs
only with a server given by `--url` (or `SAMRABBIT_T3_URL`) and a `--cli` path, and otherwise prints `T3 not paired:
t3_dev_copy`.

**Placement compared with the R1.** New tasks from the phone follow the R1's `placement.py` (a project the request
names wins; the same coding and everyday word lists) with three differences:

- A request with nothing to go on ("Tell me a joke") goes to the orchestration project. On the R1, `t3_new_thread`
  is the coding tool, so there an unsure request goes to the most recently active project.
- Coding work goes to the most recently active project that is not the orchestration project (while there is one).
  The R1's "most recently active" fallback can pick the orchestration project.
- The orchestration project is the bridge's own setting (`SAMRABBIT_T3_ORCHESTRATION_PROJECT` /
  `SAMRABBIT_T3_ORCHESTRATION_TITLE`, default T3's agent project). The R1 keeps its choice
  (`t3.orchestration_project_id`) in its own database, which the bridge can't read; changing it on the R1 does not
  change the phone. To use the same project, pass its T3 id to `install.sh --t3-orchestration-project`.

## Agent Dock (`/v1/desktop/*`)

The SamRabbit desktop app's Agent Dock (a small glass panel at the bottom of the screen) shows what waits for Samin
across his agents and lets him approve, answer, reply, stop, open and start them (`samrabbit_inbox.py`). Every
`/v1/desktop/*` route is the desktop app's alone: a loopback peer, a loopback `Host` / no foreign `Origin`, and the
desktop token (`X-SamRabbit-Desktop` or the `sr_desktop` cookie), the same rule as the desktop sync API (401 without
the token, 403 from any other machine, even with it).

**Sources** (one that fails never empties the others; `sources` in the answer says which are up):

- **T3 Code** threads through the mobile API's own T3 session (never a second one): the shell snapshot, statuses,
  open approvals and questions (read from the thread, at most 4 threads a refresh), T3's own dispatch for the
  actions. Threads T3 settled or snoozed that need nothing are left out, archived ones are not in the shell.
- **Claude Code** sessions Samin started in a terminal: `~/.claude/projects/<folder>/<session>.jsonl`, top level only
  (never `subagents/`; sidechain records are skipped), only when the first record that names an `entrypoint` says
  `cli` (T3 and Agent SDK sessions say `sdk-ts`, `claude -p` says `sdk-cli`: left out), written in the last 3 days. The
  title is the `custom-title` / `ai-title` / `summary` record, else the first thing he typed. Status: Claude Code's own
  registry of its running sessions (`~/.claude/sessions/<pid>.json`, only `<pid>.json` files: `busy`, `idle`, or
  `waiting` and what for; the pid's start time is checked against `ps`) decides first; without an entry, the last 64 KiB
  do: an assistant `tool_use` with no `tool_result` after it and the file quiet for 4 s is a prompt waiting in the
  terminal (`needs-approval`, "Waiting for you in the terminal"; `AskUserQuestion` is `needs-input`; never while
  permissions are bypassed or for a subagent's `Task`), text that ended its turn is `done`, a file written in the last
  15 s is `working`, an API error message is `error`, else `idle`.
- **Codex**: `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` and **nothing else under `~/.codex`** (never `auth.json`,
  `config.toml` or `session_index.jsonl`: the walk starts inside `sessions/`), written in the last 3 days, also when
  filed under an older day. Codex Desktop (originator `Codex Desktop`) and the CLI (`codex_cli_rs`, `codex-tui`);
  never T3's own Codex threads (originator `T3 Code`: they are T3 items), `codex exec`, subagents or Codex's reviewers.
  The title is the first message Samin typed (what Codex injects into it is left out). Status from the tail's events:
  an `exec_approval_request` / `apply_patch_approval_request` / `request_permissions` nothing answered yet
  (`needs-approval`), `request_user_input` (`needs-input`), `error` in the open turn, `task_complete` (`done`),
  `turn_aborted` (`idle`, "Stopped"), an open turn written in the last 2 minutes (`working`).
- **SamRabbit chats**: the sync store's 6 most recent conversations (R1, Watch, iPhone, Mac), `working` while the
  assistant is answering one (or an R1 reply is still being written), else `idle`.

`live` (a CLI owns the session right now): Claude Code's registry, else `ps` (the session id in a process's command
line), else `lsof` (a plain `claude` / `codex` in the session's folder owns the newest session there nobody else owns);
`ps` at most every 5 s, a process's folder read once. Scanning is incremental: a file is read again only when its size
or mtime changed, a session that is not a terminal one never past its head; a refresh takes a few milliseconds.

| Route | Answer |
|---|---|
| `GET /v1/desktop/inbox?after=<revision>&wait=<0..25>` | `{revision, updatedAt, counts: {needsYou, working, total}, sources: {t3: {connected, reason?}, claude: {available, reason?}, codex: {available, reason?}, samrabbit: {available}}, items}`. With `after` equal to the current revision it waits up to `wait` s for a change (long poll). `revision` grows by one whenever what the list shows changes (a hash of it). A background refresher keeps it fresh: about every 2 s while a client waits, every 15 s while one asked in the last ten minutes, asleep otherwise |
| `GET /v1/desktop/inbox/items/<id>` | `{item, messages: [{role: user\|assistant, text (≤ 4000 characters), at}]}`, the last 12 (tool steps and what Codex injects left out). A T3 item is read from T3 at that moment (its open requests too) |
| `POST /v1/desktop/inbox/items/<id>/approve {requestId, decision}` | T3: `thread.approval.respond` (`decision`: one of the request's options, or `approve` / `deny`, mapped as for the phone) |
| `POST /v1/desktop/inbox/items/<id>/answer {requestId, answers: {questionId: answer \| [answers]}}` | T3: `thread.user-input.respond` (option labels become the values T3 expects) |
| `POST /v1/desktop/inbox/items/<id>/reply {text}` | `202 {ok, how}`: T3 `thread.turn.start` (`how: "t3"`); a Claude or Codex CLI session nobody owns: a new Terminal window running `claude --resume <id> <text>` / `codex resume <id> <text>` in its folder, so the CLI's own permission prompts stay (`how: "terminal"`). A live session: 409 `session_live` ("open it to answer there"); Codex Desktop's threads and chats: 409 `unsupported_action` |
| `POST /v1/desktop/inbox/items/<id>/stop` | T3: `thread.turn.interrupt` (with the active turn), nothing when it is not working |
| `POST /v1/desktop/inbox/items/<id>/seen` | `{ok}`: unread clears. T3 uses the R1's seen markers (a thread is unread when it finished or started needing him after he last looked); the others the time of what he saw |
| `POST /v1/desktop/inbox/items/<id>/open` | `{opened: true, how}`: T3 → activates T3 Code (`how: "app"`; its `t3code://` scheme opens only sign-in and settings pages in 0.0.45, no thread); a live Claude / Codex CLI → the app its terminal runs in, found by walking the process's parents (Terminal, iTerm, Ghostty, T3 Code, an editor; Terminal itself when there is none, e.g. tmux); one nobody owns → a Terminal window running `claude --resume <id>` / `codex resume <id>` (`how: "terminal"`); Codex Desktop → `codex://threads/<id>`, the ChatGPT app's own deep link (`how: "deeplink"`); a chat → `{how: "desktop", conversationId}` (the app shows it itself) |
| `GET /v1/desktop/inbox/targets` | `{projects: [{id, title, lastActiveAt}], agents: [{id: "claude"\|"codex", label, models: [{id, label}]}], default: {projectId, agent, model}}`: T3's projects (most recently active first, no scratch project) and the Claude and Codex providers it offers, from T3's `server.getConfig` (only its WebSocket RPC answers it: one call with the bridge's token, cached 10 minutes; providers that are not set up and legacy models are left out; without it, what the threads use). The default is the most recently active thread's provider and model |
| `POST /v1/desktop/inbox/new {text, projectId?, agent?, model?, title?}` | `202 {itemId: "t3:<threadId>", threadId, title, projectId, projectName, placement, agent?, model?}`: `thread.create` + `thread.turn.start` as from the phone (without `projectId` the phone's placement). `agent` picks the provider instance its most recent thread used (else T3's default, else the first one that is set up), `model` one it offers (400 `invalid_model`), neither: the project's last model, as from the phone |

An item: `{id: "t3:<threadId>" | "claude:<sessionId>" | "codex:<threadId>" | "chat:<conversationId>", source: t3 |
claude | codex | samrabbit, agent: claude | codex | null (a T3 thread's provider), title, project, cwd, status:
needs-approval | needs-input | error | done | working | idle, statusLabel ("Wants to run a command", "Working · step
3/5", "Finished", "Waiting for you in the terminal"), summary (≤ 240 characters: what it needs, else its last answer),
updatedAt, unread, pending: {approvals: [{requestId, kind, detail, options: [{decision, label}]}], inputs: [{requestId,
questions: [{id, header, question, options, allowCustom, multiSelect}]}]}, can, live, progress, phase}`. `can` is what
the item supports now: `approve` / `answer` / `stop` only for T3; `reply` for T3 and for CLI sessions nobody owns;
`seen` only while it is unread; a Claude or Codex prompt waiting in a terminal can only be opened. "Needs you" =
needs-approval, needs-input, error, and done-and-unread. Order: needs-approval, needs-input, error, done and unread,
working, then the rest, newest first in each; at most 60 items (`counts` are over all of them).

What Samin has seen is `~/Library/Application Support/SamRabbit/inbox/inbox-state.json` (0600; `--inbox-dir`). The
first look at a source marks everything there as seen, so the dock starts quiet. Terminal windows open through a
private `.command` script (0700 in a 0700 folder) that deletes itself first; LaunchServices (`/usr/bin/open`) only,
no AppleScript, so no Automation prompt. A copy of the bridge that is not the installed one keeps what was seen in
memory and opens nothing (answers say `dryRun: true`) unless started with `--inbox-launch`. Errors are the usual
`{error: {code, message, retryable}}`: 404 `item_not_found`, 409 `session_live` / `unsupported_action` /
`folder_missing` / `agent_unavailable`, 400 `invalid_*`, and T3's own (`t3_request_not_pending`, `t3_unavailable`, …).
`/health` adds `inbox: {available, revision, items, needsYou}`.

**The dock's voice** (`/v1/desktop/assistant/turn | session | cancel | end | announcements`): the watch assistant's
routes (above), bodies and streaming protocol unchanged, for the desktop token from this Mac only, as the one device
"mac". Its conversations are "Mac" ones in the sync store (`mac-<conversationId>`, titled `Mac: <first words>`, origin
`mac`), so they show in the desktop app and the iPhone's Chats; the same brain choice (realtime when ChatGPT is
connected and the helper is ready, else Claude) and the same tools; the realtime session ends its instructions with a
Mac addendum instead of the watch's (`MAC_INSTRUCTION`: he is at his Mac, usually managing his T3 threads; one to three
sentences), the Claude brain gets the Mac's own prompt (`system-prompt-mac.md`) and `[Now: … · device: mac]`. The Mac
and the watch never share a conversation.

## Desktop app page (`/app/`)

`samrabbit_app.py` serves the SamRabbit desktop app's web UI (see `companion/desktop/README.md`) at
`GET /app/…`. It has its own rules, separate from the LAN routes above:

- the peer must be **loopback** (127.0.0.0/8, ::1); LAN peers get 403 even with `--allow-any-client`;
- the **desktop token** (`~/.config/samrabbit/desktop-token`, 0600, created by `companion/desktop/install.sh`)
  must be sent as the header `X-SamRabbit-Desktop` or the cookie `sr_desktop`. The bridge bearer token is not
  accepted here, and the desktop token opens none of the LAN routes;
- files come from `$SAMRABBIT_APP_WEB_DIR`, else `/Applications/SamRabbit.app/Contents/Resources/web`, else
  `companion/desktop/web` next to the bridge checkout. Only regular files with a known extension inside that folder
  are served (no listings, dotfiles, `..` or symlink escapes), with `Cache-Control: no-cache`, `nosniff` and a
  strict Content-Security-Policy on HTML. `/app` redirects to `/app/`.
- 401/403/404/503 answers are small HTML pages (a missing token file or app install says to run
  `companion/desktop/install.sh`). The log line is just `GET /app <status> <ms>`.

## Privacy

- The log has one line per request: method, route, status, duration, and an error code if there is one. It never
  contains journal text, window text, typed text, links, file names, query strings, CLI output or the token. Sync
  routes are logged as templates (`/v1/sync/conversations/{id}/events`), so not even conversation ids or image hashes
  are written; conversation text and image bytes never are.
  Generated UIs log only the artifact id, the outcome and timings: never the prompt, the data or the widget.
  Calendar changes log only the route, the status and an error code: never a title, a time or Composio's output.
  The desktop inbox logs route templates (`/v1/desktop/inbox/items/{id}/reply`) and what kind of action it took:
  never an item id, a title, a prompt, a reply, a command, a message or a folder.
  Mobile routes are logged as templates (`/v1/mobile/t3/threads/{id}/respond`) with the status and an error code:
  never a mobile token, a pairing code, a device id, thread text, prompts, notes, events or images; T3 pairing logs
  only "t3 paired (expires <date>)" and its back-off notices ("next pairing in N min"). Transcriptions log only the
  engine and the length of the audio (and, when the helper fails, its exit status or an error domain and number):
  never the audio or the words.
- Error replies never repeat the CLI's own messages, because they could quote journal content.
- The token file is re-read when it changes. To rotate it, delete the file, run `install.sh`, and connect the R1
  again.

## Which copy is the installed one (test and dev bridges never reach the real journal, T3 or calendar)

Only the installed copy reaches the real Heptabase journal, T3 Code and Google Calendar by default
(`samrabbit_installed.py`). It is the one that runs from `<home>/Library/Application Support/SamRabbit/bridge/`
where `<home>` is the account's home from the password database (`pwd.getpwuid(os.getuid()).pw_dir`, never
`$HOME`), with `$HOME` (when set) being that same home, and with the marker `install.sh` writes there,
`.samrabbit-installed` (a regular file, not a link, owned by the user), naming exactly that folder. Every other copy
is a **dev copy**: a checkout, a test, a second bridge on another port, or a copy `install.sh` put into a temp HOME
(`SAMRABBIT_HOME` or `HOME` pointing elsewhere), even when started with that temp HOME. A dev copy's Heptabase CLI is
a dry run, its T3 answers `t3_dev_copy` and its calendar `calendar_dev_copy`, unless it is given a `--cli` path,
`--t3-url` with a `--t3-cli` path, or `--composio` explicitly; its watch assistant needs an explicit `--claude` and
speaks with ElevenLabs only with an explicit `--elevenlabs-key-file`; its Agent Dock inbox keeps what was seen in memory and
opens no app or Terminal window unless given `--inbox-launch`. `/health` says `copy: "installed"` or `"dev"`, the start log line says
`(installed copy, …)` or `(dev copy, …)`, and `python3 -I samrabbit_installed.py [<folder>]` prints `installed` or
`dev (<reason>)`. `install.sh` warns when the bridge it started does not say `installed`.

### Which Heptabase CLI

`--cli` (or `SAMRABBIT_HEPTABASE_CLI`) picks it: a path (used as given), `auto` or `dry-run` (nothing reaches
Heptabase: appends stay in the bridge's memory and are answered with `dryRun: true`; reads return them, also with
`dryRun: true`). For the installed copy (above), `auto` and no choice both mean the real `heptabase` on `PATH` (or
`/opt/homebrew/bin/heptabase`); every other copy, such as a second bridge run from a checkout on another port, is
`dry-run` even with `--cli auto`: only a path to a CLI makes it use one. The LaunchAgent passes no `--cli` (the install
marker decides). `/health` reports it as `cli.mode` (`real` or `dryRun`) and `dryRun`; a dry-run bridge's `app` is
`{reachable: false, detail: "bridge_dry_run"}`, and it logs a warning at start. An R1 paired with a dry-run bridge
keeps its journal entries queued (never "sent") and shows "test copy (dry run)" on its Heptabase card. To test against
a fake CLI, pass its path; pass the real CLI's path only when you really want a dev copy to write to your Heptabase
journal.

## Tests

```sh
python3 -m unittest discover -s companion/mac-bridge/tests
```

The tests pass a fake `heptabase` executable by path (`tests/fake_heptabase.py`); the CLI-choice tests
(`tests/test_heptabase_cli_choice.py`) run with a PATH that holds only their recording fake, point the
`/opt/homebrew/bin/heptabase` fallback at a missing file, and check the resolved CLI is the fake before anything runs.
They drive Mac control through a fake `cua-driver` / `open` / `lsappinfo` (`tests/fake_cua_driver.py`), generate UIs
with a fake `claude` (`tests/fake_claude.py`) and a fake renderer (one test renders for real when agent-browser is
installed), change a fake Google calendar through a fake `composio` (`tests/fake_composio.py`; no test ever runs the
real CLI), and run the installer against a throwaway home with `SAMRABBIT_SKIP_LAUNCHCTL=1`. `tests/test_mobile.py`
drives the mobile API against a fake T3 server and CLI (`tests/fake_t3.py`, `tests/fake_t3_cli.py`), the fake
Composio, Heptabase and cua-driver above, temp tokens and a fake clock: pairing (single use, expiry, rate limit, peer
check), auth on every route, the summary and its caches, T3 status mapping, dispatch payloads, placement and
re-pairing, the block math across daylight-saving changes, the journal format, the reused conversation routes and
the "Phone" conversation. `tests/test_transcribe.py` drives `/v1/mobile/transcribe` with a fake helper
(`tests/fake_transcribe.py`): the private temp file and its removal, the size, length, type and language checks,
every helper failure, the timeout, the busy limit, the background model download and `/health`; it also builds the
real helper and transcribes clips made with `say -o` (skipped without Xcode or the Command Line Tools).
`tests/test_installed_copy.py` points HOME at a temp folder (and installs a copy there with `install.sh`, then runs
it) and checks that every such copy is a dev copy for the journal, T3 and the calendar, with recording fakes standing
in for every real service in case it were not. `tests/test_t3.py` covers the T3 port and a Python 3.9 `-I` import
check. `tests/test_assistant.py` drives the watch assistant against the same fakes plus a fake Claude Code
(`tests/fake_assistant_claude.py`, which starts the real MCP server and calls its tools against the test bridge), a
fake ElevenLabs server and the fake speech-to-text helper: the isolation flags and environment, sessions (new,
resumed, lost), the MCP protocol (`server/discover`, `initialize`, `tools/list`, `tools/call`, the image block),
empty and noise turns, goodbyes, timeouts (the process group is killed), voice failures, idempotent turn ids, one turn
per conversation, announcements (once each), the "Watch" conversation in the sync store, and that a dev copy reaches
no real Claude, ElevenLabs, T3, journal or calendar. `tests/test_realtime.py` drives the realtime brain with a fake
helper (`tests/fake_realtime_peer.py`: the helper protocol plus OpenAI's data-channel events from a script), a fake
signaling server and a fake ChatGPT login (`tests/fake_openai.py`): the session's exact shape and headers, the
stream's frames, the `[Now: …]` line, tools and cards, the journal's verbatim check, cancel, warm-up, idle and 55-minute
sessions (a stale one replaced without a deadlock), announcements, the fallback to Claude (never after a tool ran or a
cancel), a session that died between turns (replaced, no pause), a refused `response.create` while another response
is active, outputs for a cancelled response's calls, the session cap and the warm-up's reuse, a close while opening, a
login change mid-turn and which login events count as a change, pings (also while a retry waits), the token refresh,
brain settings, the device login and its routes,
and that the token, words and audio never reach the log. `tests/test_realtime_profile.py` checks the vendored R1
text and tools against `runtime/sam_runtime`. The helper itself (real WebRTC with aiortc) is tested in the realtime
venv: `<venv>/bin/python -m unittest discover -s companion/mac-bridge/realtime -p 'test_*.py'`
(`realtime/test_realtime_peer.py`: the helper against a local aiortc peer standing in for OpenAI, which like
libwebrtc never sends an event over the advertised max-message-size: a 100 KB event arrives whole, a cut-off reply's
audio never plays in front of the next one when the server sends no RTP between replies, and the real bridge end to
end with it). `tests/test_sync.py` covers the conversation store, dedupe, drafts, blobs, the auth matrix (R1 token vs desktop token, loopback vs a real
LAN peer through this Mac's own address), SSE and screenshots. `tests/test_inbox.py` drives the Agent Dock's inbox against
the fake T3 server (with its WebSocket `server.getConfig`), a temp HOME with synthetic `~/.claude/projects`,
`~/.claude/sessions` and `~/.codex/sessions` trees and decoy `~/.codex/auth.json`, `config.toml` and
`session_index.jsonl` (chmod 000, with `open`, `os.open`, `stat`, `listdir` and `scandir` guarded so a touch fails the
test), a fake process table instead of `ps` / `lsof` and a launcher that records what it would open (nothing is ever
launched): the desktop-token auth (401, 403 from the LAN or a foreign Origin), every status of every source and what
is left out, the order, the cap and the counts, revisions and the long poll (woken by a change, by the refresher, or
after its wait), seen and unread (kept across restarts), each action's dispatch body, `session_live`, what `open` and
`reply` would run, targets with and without T3's provider list, new tasks with a project, agent and model, a dev
copy's dry run, incremental reads, and that nothing about an item reaches the log. `tests/test_desktop_assistant.py`
drives `/v1/desktop/assistant/*` with the watch assistant's fakes: the auth, the "Mac" conversation in the sync store
(and that the Mac and the watch never share one), the Mac's prompt and time line, warm-up, cancel, end and
announcements, and a streamed realtime turn with the Mac addendum.

## Troubleshooting

- The watch answers with Claude, not gpt-realtime: `/health` `assistant.realtime.reason` says why:
  `chatgpt_not_connected` (SamRabbit > Connect ChatGPT…, or `connect-chatgpt.sh`), `chatgpt_reconnect_required` (the
  login was revoked: connect again), `realtime_venv_missing` / `realtime_venv_broken` / `realtime_python_too_old`
  (run `install.sh` again; it needs `uv`), `chatgpt_rejected` / `realtime_busy` (OpenAI refused for now; it tries
  again by itself), `lastError` names OpenAI's last answer (`http_<status>_<code>`).

- `app: reachable false, detail heptabase_app_unavailable`: open Heptabase, or run `heptabase start`, and check that
  CLI is enabled in Settings > AI Features. Entries wait on the R1 and go out once the app is back.
- Nothing answers on port 3780: run `launchctl print gui/$(id -u)/com.samrabbit.bridge` and
  `tail ~/Library/Logs/samrabbit-bridge.log`.
- The desktop app shows no conversations: `/health` should say `sync.available: true` (else run `install.sh` again
  to install `samrabbit_sync.py`), and `desktopToken: true` (else the desktop token file is missing). The R1's
  management API (`GET /v1/management/conversation-sync`) shows its outbox: `pending`, `lastError`
  (`bridge_outdated` = this bridge predates sync), `lastOkAt`.
- The Mac's IP changed: run `install.sh` again to print the new address, then update the URL on the R1's management page.
- The R1 says Google Calendar can't be changed: `/health` should say `calendarWrite.available: true` (else install the
  Composio CLI and run `install.sh` again). `lastError` names the last failure: `calendar_not_connected` = run
  `composio link googlecalendar`; `composio_signed_out` = run `composio login`.
