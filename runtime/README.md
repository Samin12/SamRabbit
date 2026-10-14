# On-device runtime

This directory owns trusted Python runtime behavior. Android process lifecycle and Keystore bridging live in `android/runtime-host`; Android presentation code communicates with the runtime through the local API.

Dependency direction:

```text
entrypoint -> application -> api + agents + providers + MCP + storage
api + agents + providers + MCP -> storage interfaces
storage -> Python standard library SQLite
```

Module ownership:

- `api/http_server.py` — transport only (bind, threads, bearer auth, request/response mechanics). Routes live in `api/routes.py` (`RuntimeRoutes`); new endpoints are added there.
- `providers/openai/access.py` — the single access-path → credential/base-URL decision every OpenAI consumer (agents, embeddings, future agents) must use.
- `agents/sdk_runner.py` — the single Agents SDK execution path every agent runner uses.
- `domains/conversation_sync/` — the live mirror of every voice conversation to the SamRabbit app on the user's Mac: device-only `POST /v1/voice/conversation/events` and `/blobs` (from the R1 app), the `ToolCatalog` observer (`tool.completed`), `session.finalized` after finalize, and the `sam-conversation-sync` outbox worker that posts to the Mac bridge's `/v1/sync/*` (backoff 2/5/15/60/300 s; the bridge dedupes by event id). Observe-only: a sync failure never affects voice, tools or finalize. Bridge side: `companion/mac-bridge/README.md` ("Conversation sync").
- `domains/capture/` — side-button voice notes: device-only `POST /v1/capture {captureId, text, capturedAt}` (the R1's own transcript; the capture id is made when recording starts and is the idempotency key end to end), `GET /v1/capture/<id>`, `GET /v1/captures`. The note is stored in the `capture.outbox` provider setting before the Mac bridge's `POST /v1/capture` is tried; the `sam-capture` worker resends queued notes (backoff 2/5/15/60/300 s, at once when the bridge answers again) and follows notes the Mac is still routing, publishing a silent `capture.routed` announcement for outcomes the app did not see inline. Transcripts are never logged.
- `domains/briefing/` — the morning brief: the `sam-briefing` worker reads the Mac bridge's `GET /v1/briefing` (every 10 min 05:00–12:00 in the journal timezone, hourly otherwise, at once after `POST /v1/briefing/refresh`), caches a bounded copy in `briefing.latest`, and announces `briefing.ready` once a day (silent). Device-only `GET /v1/briefing`, `POST /v1/briefing/refresh`, `POST /v1/briefing/items/<id>/act {action}`; voice tools `briefing_read` / `briefing_act` (read only when asked). Only Draft reply (a Gmail draft made on the Mac, never sent), Make task, Block time, Remind me, Done, Dismiss and Open are ever offered. Shared bridge call plumbing: `domains/bridge_calls.py`.

Run the host-side lifecycle tests:

```bash
PYTHONPATH=runtime python3.13 -m unittest discover -s tests/runtime
```

The runtime is intentionally small. Additional domains enter this package only when their real device-facing behavior and tests are implemented.
