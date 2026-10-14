"""In-process stand-in for the voice-note and morning-briefing routes of the SamRabbit Mac bridge (wave 8).

``FakeCaptureBriefingBridge`` answers, behind a bearer token, ``POST /v1/capture`` (idempotent per
``X-SamRabbit-Capture``, like the real bridge), ``GET /v1/capture/<id>?wait=``, ``GET /v1/briefing``,
``POST /v1/briefing/refresh`` and ``POST /v1/briefing/items/<id>/act``. It records every request and can be scripted
per route (``responses``). It never touches Gmail, the journal, the calendar or T3: tests only.
"""

from __future__ import annotations

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import re
import secrets
import threading
import time
from urllib.parse import parse_qs, urlsplit

_CAPTURE = re.compile(r"^/v1/capture/([0-9a-fA-F-]{36})$")
_ACT = re.compile(r"^/v1/briefing/items/([A-Za-z0-9._:\-]+)/act$")

JOURNAL_DONE = {"state": "done", "heard": "put it in the journal ship the build",
                "outcome": {"kind": "journal", "title": "Journal", "detail": "Added at 09:41"}}


def sample_brief(date: str, *, revision: int = 3, needs_you: int = 2) -> dict[str, object]:
    """A bridge brief in the contract's layout, with a few things the R1 must drop (send, approve, a 4th Do first)."""
    return {
        "date": date, "revision": revision, "status": "ready", "updatedAt": date + "T11:01:00Z",
        "headline": "2 things need you · 3 meetings, first at 10:00 · 1 agent waiting",
        "spoken": "Two emails need replies, your first meeting is at ten, and one agent is waiting for you.",
        "needsYou": needs_you, "footer": "Skipped 182 promos · business 64 · personal 41 read",
        "sections": [
            {"id": "do_first", "title": "Do first", "items": [
                {"id": "bi_dana", "kind": "email", "account": "business", "title": "Reply to Dana: confirm Thu 2 pm",
                 "why": "She needs the SOW signed by Friday; asked twice",
                 "actions": [{"type": "draft_reply", "label": "Draft reply"}, {"type": "remind", "label": "Remind 4 pm"},
                             {"type": "send", "label": "Send"}]},
                {"id": "bi_payout", "kind": "email", "account": "business", "title": "Payout failed: update bank details",
                 "why": "Stripe retries tomorrow", "actions": [{"type": "open", "label": "Open"}]},
                {"id": "bi_bug", "kind": "email", "account": "personal", "title": "Bug report from Acme: checkout 500s",
                 "why": "Customer is blocked", "actions": ["make_task", "draft_reply"]},
                {"id": "bi_fourth", "kind": "email", "title": "A fourth thing", "actions": []},
            ]},
            {"id": "today", "title": "Today", "items": [
                {"id": "bi_standup", "kind": "event", "title": "Standup", "time": "10:00", "conflict": True,
                 "why": "Overlaps the dentist", "actions": [{"type": "block_time"}]},
            ]},
            {"id": "agents", "title": "Agents", "items": [
                {"id": "bi_agent", "kind": "agent", "title": "T3 'Fix login redirect' needs approval",
                 "why": "Wants to run the migration", "source": {"threadId": "thread-123"},
                 "actions": [{"type": "approve", "label": "Approve"}, {"type": "open", "label": "Open"}]},
            ]},
            {"id": "fyi", "title": "FYI", "items": [
                {"id": "bi_fyi", "kind": "fyi", "title": "Stripe payout arrived", "actions": []},
            ]},
        ],
    }


class FakeCaptureBriefingBridge:
    def __init__(self, token: str | None = None) -> None:
        self.token = token or "bridge-" + secrets.token_urlsafe(24)
        self.requests: list[dict[str, object]] = []
        self.responses: dict[str, tuple[int, dict[str, object]]] = {}
        self.captures: dict[str, dict[str, object]] = {}
        self.posts_per_capture: dict[str, int] = {}
        # How a new capture ends: its final result, or None to stay "received" until ``finish`` is called.
        self.capture_result: dict[str, object] | None = dict(JOURNAL_DONE)
        self.instant = False
        self.brief: dict[str, object] | None = None
        self.refreshes = 0
        self.lock = threading.Lock()
        self._server = ThreadingHTTPServer(("127.0.0.1", 0), _handler(self))
        self._server.daemon_threads = True
        self._thread = threading.Thread(target=self._server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)
        self._thread.start()
        self.url = f"http://127.0.0.1:{self._server.server_address[1]}"

    def close(self) -> None:
        self._server.shutdown()
        self._server.server_close()

    def finish(self, capture_id: str, result: dict[str, object] | None = None) -> None:
        with self.lock:
            self.captures[capture_id] = {"captureId": capture_id, **(result or JOURNAL_DONE)}

    def paths(self) -> list[str]:
        with self.lock:
            return [str(item["path"]) for item in self.requests]

    def last(self, path: str) -> dict[str, object]:
        with self.lock:
            return next(item for item in reversed(self.requests) if item["path"] == path)

    def posted(self, path_prefix: str) -> list[dict[str, object]]:
        with self.lock:
            return [item for item in self.requests if item["method"] == "POST"
                    and str(item["path"]).startswith(path_prefix)]


def _handler(fake: FakeCaptureBriefingBridge) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_args) -> None:  # noqa: ANN002
            pass

        def _json(self, status: int, payload: dict[str, object]) -> None:
            body = json.dumps(payload).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _serve(self, method: str) -> None:
            parsed = urlsplit(self.path)
            path = parsed.path
            length = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(length) if length else b""
            record = {"method": method, "path": path, "query": parse_qs(parsed.query),
                      "body": json.loads(raw) if raw else None,
                      "headers": {key: self.headers.get(key) for key in
                                  ("Authorization", "X-SamRabbit-Capture", "X-SamRabbit-Captured-At",
                                   "X-SamRabbit-Source", "Content-Type")}}
            with fake.lock:
                fake.requests.append(record)
                scripted = fake.responses.get(f"{method} {path}") or fake.responses.get(f"{method} *")
            if self.headers.get("Authorization", "") != f"Bearer {fake.token}":
                self._json(401, {"error": {"code": "unauthorized", "message": "A valid bridge token is required."}})
                return
            if scripted is not None:
                self._json(*scripted)
                return
            if path == "/v1/capture" and method == "POST":
                capture_id = str(self.headers.get("X-SamRabbit-Capture") or "")
                with fake.lock:
                    fake.posts_per_capture[capture_id] = fake.posts_per_capture.get(capture_id, 0) + 1
                    existing = fake.captures.get(capture_id)
                    if existing is None:
                        if fake.instant and fake.capture_result is not None:
                            existing = {"captureId": capture_id, **fake.capture_result}
                        else:
                            existing = {"captureId": capture_id, "state": "received"}
                        fake.captures[capture_id] = existing
                    view = dict(existing)
                self._json(200 if view["state"] == "done" else 202, view)
                return
            match = _CAPTURE.match(path)
            if match and method == "GET":
                capture_id = match.group(1)
                wait = float((parse_qs(parsed.query).get("wait") or ["0"])[0])
                with fake.lock:
                    current = fake.captures.get(capture_id)
                    if current is not None and current.get("state") == "received" and fake.capture_result is not None:
                        current = {"captureId": capture_id, **fake.capture_result}
                        fake.captures[capture_id] = current
                if current is None:
                    self._json(404, {"error": {"code": "capture_not_found", "message": "No such capture."}})
                    return
                if current.get("state") == "received":
                    time.sleep(min(wait, 0.3))
                self._json(200, dict(current))
                return
            if path == "/v1/briefing" and method == "GET":
                with fake.lock:
                    brief = fake.brief
                if brief is None:
                    self._json(200, {"status": "building", "date": None})
                else:
                    self._json(200, brief)
                return
            if path == "/v1/briefing/refresh" and method == "POST":
                with fake.lock:
                    fake.refreshes += 1
                self._json(202, {"status": "building"})
                return
            match = _ACT.match(path)
            if match and method == "POST":
                action = (json.loads(raw or b"{}") or {}).get("action")
                states = {"draft_reply": "drafted", "make_task": "tasked", "block_time": "blocked",
                          "remind": "snoozed", "done": "done", "dismiss": "dismissed"}
                result: dict[str, object] = {}
                if action == "draft_reply":
                    result = {"draftId": "r-123", "url": "https://mail.google.com/mail/u/0/#drafts?authuser=1"}
                if action == "open":
                    result = {"url": "https://mail.google.com/mail/u/0/#inbox/abc?authuser=samin%40aianswer.us"}
                self._json(200, {"ok": True, "state": states.get(str(action), "open"), "result": result})
                return
            self._json(404, {"error": {"code": "not_found", "message": "Not found."}})

        def do_GET(self) -> None:  # noqa: N802
            self._serve("GET")

        def do_POST(self) -> None:  # noqa: N802
            self._serve("POST")

    return Handler
