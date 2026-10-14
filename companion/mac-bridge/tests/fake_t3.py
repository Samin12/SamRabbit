"""An in-process stand-in for the T3 Code server used by the mobile tests (never the real one on :3773).

* ``POST /oauth/token`` accepts a credential the fake CLI (``fake_t3_cli.py``) wrote to ``<state>/credentials.json``
  (single use) and issues ``base64url(claims).sig`` tokens; the form is recorded in ``exchanges``.
* ``GET /api/auth/session``, ``GET /api/orchestration/shell``, ``GET /api/orchestration/threads/<id>`` serve
  ``shell`` / ``details``; ``POST /api/orchestration/dispatch`` records each command in ``dispatched``.
* ``GET /ws`` (a WebSocket, the bearer token on the upgrade) answers one Effect-RPC ``Request`` for
  ``server.getConfig`` with ``server_config`` (``Exit`` ``Success``), records its tag in ``ws_requests``; with
  ``ws_status`` set to anything but 101 the upgrade is refused with that status (an older T3).
* ``revoke_all()`` makes every issued token answer 401 (as after a revoke or the 30-day expiry);
  ``refuse_tokens = True`` makes every bearer token answer 401, even ones issued afterwards (a broken T3).
* ``delay``: ``{path: seconds}`` to answer slowly.
"""

from __future__ import annotations

import base64
import copy
import hashlib
import json
import os
import struct
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Dict, List, Optional
from urllib.parse import parse_qs, unquote, urlsplit

PROJECTS = [
    {"id": "p-agent", "title": "Hermes", "workspaceRoot": "/Users/test/.t3/hermes/workspace",
     "repositoryIdentity": None, "defaultModelSelection": None},
    {"id": "p-scratch", "title": "No project", "workspaceRoot": "/Users/test/.t3/scratch", "repositoryIdentity": None,
     "defaultModelSelection": None},
    {"id": "p-rabbit", "title": "SamRabbit", "workspaceRoot": "/Users/test/jackrabbit-src",
     "repositoryIdentity": {"name": "SamRabbit"}, "defaultModelSelection": None},
    {"id": "p-site", "title": "Website", "workspaceRoot": "/Users/test/code/website", "repositoryIdentity": None,
     "defaultModelSelection": {"instanceId": "codex", "model": "gpt-6"}},
]


def _thread(thread_id: str, project: str, title: str, *, minutes_ago: int, session: Optional[str] = "ready",
            latest: Optional[str] = "completed", session_extra: Optional[Dict[str, Any]] = None,
            **extra: Any) -> Dict[str, Any]:
    stamp = f"2026-10-08T{12 + (59 - minutes_ago) // 60:02d}:{(59 - minutes_ago) % 60:02d}:00.123Z"
    value: Dict[str, Any] = {
        "id": thread_id, "projectId": project, "title": title,
        "modelSelection": {"instanceId": "claudeAgent", "model": "claude-opus-5-5"},
        "runtimeMode": "full-access", "interactionMode": "default", "createdAt": "2026-10-08T09:00:00.000Z",
        "updatedAt": stamp, "archivedAt": None, "settledAt": None, "snoozedUntil": None,
        "latestUserMessageAt": stamp, "hasPendingApprovals": False, "hasPendingUserInput": False,
        "backgroundLiveness": None, "planProgress": None,
        "session": {"threadId": thread_id, "status": session, "activeTurnId": None, "lastError": None} if session
        else None,
        "latestTurn": {"turnId": "turn-" + thread_id, "state": latest, "requestedAt": stamp, "startedAt": stamp,
                       "completedAt": stamp if latest in ("completed", "error", "interrupted") else None}
        if latest else None,
    }
    if session_extra and value["session"]:
        value["session"].update(session_extra)
    value.update(extra)
    return value


def default_shell() -> Dict[str, Any]:
    threads = [
        _thread("t-approval", "p-rabbit", "Fix the login redirect", minutes_ago=5, hasPendingApprovals=True,
                session="running", latest="running"),
        _thread("t-input", "p-site", "Pick a database", minutes_ago=7, hasPendingUserInput=True),
        _thread("t-running", "p-rabbit", "Run the test suite", minutes_ago=2, session="running", latest="running",
                planProgress={"step": "Running unit tests", "completedSteps": 1, "totalSteps": 4},
                session_extra={"activeTurnId": "turn-active-1"}),
        _thread("t-starting", "p-agent", "Book a table", minutes_ago=1, session="starting", latest=None),
        _thread("t-background", "p-agent", "Watch the deploy", minutes_ago=20, backgroundLiveness="working"),
        _thread("t-error", "p-site", "Deploy preview", minutes_ago=30, session="error",
                session_extra={"lastError": "The provider stopped unexpectedly."}),
        _thread("t-settled-error", "p-site", "Old failure", minutes_ago=50, latest="error",
                settledAt="2026-10-08T11:00:00.000Z"),
        _thread("t-done", "p-agent", "Summarize my inbox", minutes_ago=15),
        _thread("t-new", "p-agent", "Draft for later", minutes_ago=40, session=None, latest=None),
        _thread("t-stopped", "p-rabbit", "Refactor sync", minutes_ago=45, latest="interrupted"),
        _thread("t-archived", "p-rabbit", "Archived thing", minutes_ago=3, archivedAt="2026-10-08T10:00:00.000Z"),
    ]
    return {"snapshotSequence": 100, "updatedAt": "2026-10-08T12:59:00.000Z", "projects": copy.deepcopy(PROJECTS),
            "threads": threads}


def default_server_config() -> Dict[str, Any]:
    """The parts of ``server.getConfig`` the bridge reads: Claude ready, a Codex instance that is not installed and
    a second Codex instance that is (as on Samin's Mac), and a provider of another kind."""
    def model(slug: str, name: str, **extra: Any) -> Dict[str, Any]:
        return {"slug": slug, "name": name, "isCustom": False, "capabilities": None, **extra}
    return {"environment": {}, "cwd": "/Users/test", "providers": [
        {"instanceId": "codex", "driver": "codex", "displayName": "ChatGPT sharing", "enabled": True,
         "installed": False, "status": "warning", "models": [model("gpt-6", "GPT-6", isDefault=True)]},
        {"instanceId": "codex_cli", "driver": "codex", "displayName": "Codex CLI", "enabled": True, "installed": True,
         "status": "ready", "models": [model("gpt-6.1", "GPT-6.1"), model("gpt-6", "GPT-6", isDefault=True),
                                       model("gpt-5", "GPT-5", isLegacy=True)]},
        {"instanceId": "claudeAgent", "driver": "claudeAgent", "displayName": "Claude", "enabled": True,
         "installed": True, "status": "ready",
         "models": [model("claude-opus-5-5", "Claude Opus 5.5"), model("claude-sonnet-5-5", "Claude Sonnet 5.5"),
                    model("claude-fable-5-1", "Claude Fable 5.1", isDefault=True),
                    model("claude-opus-4-5", "Claude Opus 4.5", isLegacy=True)]},
        {"instanceId": "cursor", "driver": "cursor", "displayName": "Cursor", "enabled": False, "installed": False,
         "status": "disabled", "models": [model("auto", "Auto")]},
    ], "settings": {"defaultModelSelection": {"instanceId": "claudeAgent", "model": "claude-opus-5-5"}}}


def default_details() -> Dict[str, Dict[str, Any]]:
    approval = {"messages": [
        {"id": "u1", "role": "user", "text": "Fix the login redirect please", "createdAt": "2026-10-08T12:50:00.000Z"},
        {"id": "reasoning:summary:x", "role": "system", "text": "thinking", "createdAt": "2026-10-08T12:50:01.000Z"},
        {"id": "assistant:a1", "role": "assistant", "text": "I will run the tests first.",
         "createdAt": "2026-10-08T12:50:02.000Z"}],
        "activities": [
            {"id": "a1", "kind": "tool.started", "createdAt": "2026-10-08T12:50:03.000Z",
             "payload": {"toolCallId": "c1", "title": "Command run", "status": "inProgress"}},
            {"id": "a2", "kind": "tool.completed", "createdAt": "2026-10-08T12:50:04.000Z",
             "payload": {"toolCallId": "c1", "title": "Command run", "status": "completed"}},
            {"id": "a3", "kind": "tool.started", "createdAt": "2026-10-08T12:50:05.000Z",
             "payload": {"toolCallId": "c2", "title": "Read file", "status": "inProgress"}},
            {"id": "a4", "kind": "approval.requested", "createdAt": "2026-10-08T12:50:06.000Z",
             "payload": {"requestId": "req-approve-1", "requestKind": "command", "requestType": "command_execution_approval",
                         "detail": "npm test -- --watch=false"}}]}
    question = {"messages": [{"id": "u2", "role": "user", "text": "Set up storage", "createdAt": "2026-10-08T12:40:00.000Z"}],
                "activities": [{"id": "q", "kind": "user-input.requested", "createdAt": "2026-10-08T12:41:00.000Z",
                                "payload": {"requestId": "req-input-1", "questions": [
                                    {"id": "q1", "header": "Database", "question": "Which database should I use?",
                                     "options": [{"label": "SQLite", "value": "sqlite"}, {"label": "Postgres"}],
                                     "allowCustomAnswer": False, "multiSelect": False}]}}]}
    running = {"messages": [{"id": "u3", "role": "user", "text": "Run the tests", "createdAt": "2026-10-08T12:55:00.000Z"}],
               "activities": []}
    details = {}
    for thread_id, extra in (("t-approval", approval), ("t-input", question), ("t-running", running)):
        details[thread_id] = extra
    return details


class FakeT3:
    def __init__(self, state_dir: str) -> None:
        self.state_dir = state_dir
        self.lock = threading.Lock()
        self.shell = default_shell()
        self.details = default_details()
        self.tokens: Dict[str, bool] = {}  # token -> valid
        self.exchanges: List[Dict[str, Any]] = []
        self.dispatched: List[Dict[str, Any]] = []
        self.requests: List[str] = []
        self.dispatch_status = 200
        self.first_message_at: Dict[str, str] = {}  # threads made here that have no user message yet
        self.server_config: Any = default_server_config()
        self.ws_requests: List[str] = []
        self.ws_status = 101
        self.refuse_tokens = False
        self.delay: Dict[str, float] = {}
        self.counter = 0
        fake = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_args: Any) -> None:
                return

            def do_GET(self) -> None:  # noqa: N802
                fake.handle(self, "GET")

            def do_POST(self) -> None:  # noqa: N802
                fake.handle(self, "POST")

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)
        self.thread.start()
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}"

    def close(self) -> None:
        self.server.shutdown()
        self.server.server_close()

    # ------------------------------------------------------------------ helpers for tests
    def revoke_all(self) -> None:
        with self.lock:
            for token in self.tokens:
                self.tokens[token] = False

    def issue_token(self) -> str:
        with self.lock:
            self.counter += 1
            claims = {"v": 1, "kind": "session", "sid": f"sid-{self.counter}", "scopes": ["orchestration:read"]}
            head = base64.urlsafe_b64encode(json.dumps(claims).encode()).decode().rstrip("=")
            token = f"{head}.fakesignature{self.counter:04d}"
            self.tokens[token] = True
            return token

    def count(self, prefix: str) -> int:
        with self.lock:
            return sum(1 for item in self.requests if item.startswith(prefix))

    def get_thread(self, thread_id: str) -> Dict[str, Any]:
        return next(item for item in self.shell["threads"] if item["id"] == thread_id)

    # ------------------------------------------------------------------ HTTP
    def _send(self, handler: BaseHTTPRequestHandler, status: int, value: Any) -> None:
        body = json.dumps(value).encode()
        handler.send_response(status)
        handler.send_header("Content-Type", "application/json")
        handler.send_header("Content-Length", str(len(body)))
        handler.end_headers()
        handler.wfile.write(body)

    def _authorized(self, handler: BaseHTTPRequestHandler) -> bool:
        header = handler.headers.get("Authorization", "")
        token = header[7:] if header.startswith("Bearer ") else ""
        with self.lock:
            return self.tokens.get(token) is True and not self.refuse_tokens

    def _websocket(self, handler: BaseHTTPRequestHandler) -> None:
        """One Effect-RPC call over a WebSocket: the upgrade, one masked client frame, one ``Exit`` answer."""
        if not self._authorized(handler):
            return self._send(handler, 401, {"code": "auth_invalid", "reason": "invalid_credential"})
        if self.ws_status != 101:
            return self._send(handler, self.ws_status, {"code": "not_found"})
        key = handler.headers.get("Sec-WebSocket-Key", "")
        accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest())
        handler.send_response(101)
        handler.send_header("Upgrade", "websocket")
        handler.send_header("Connection", "Upgrade")
        handler.send_header("Sec-WebSocket-Accept", accept.decode())
        handler.end_headers()
        handler.wfile.flush()
        request = self._ws_read(handler)
        with self.lock:
            self.ws_requests.append(str(request.get("tag")))
            config = copy.deepcopy(self.server_config)
        self._ws_write(handler, {"_tag": "Ping"})  # Effect RPC's own ping: the client answers it and reads on
        pong = self._ws_read(handler)
        with self.lock:
            self.ws_requests.append(str(pong.get("_tag")))
        exit_value = {"_tag": "Success", "value": config} if config is not None else \
            {"_tag": "Failure", "cause": [{"_tag": "Fail", "error": {"_tag": "ServerSettingsError"}}]}
        self._ws_write(handler, [{"_tag": "Exit", "requestId": request.get("id"), "exit": exit_value}])
        handler.wfile.write(bytes([0x88, 0x00]))
        handler.close_connection = True

    @staticmethod
    def _ws_read(handler: BaseHTTPRequestHandler) -> Dict[str, Any]:
        _first, second = handler.rfile.read(2)
        size = second & 0x7F
        if size == 126:
            size = struct.unpack(">H", handler.rfile.read(2))[0]
        elif size == 127:
            size = struct.unpack(">Q", handler.rfile.read(8))[0]
        mask = handler.rfile.read(4)
        data = bytes(byte ^ mask[index % 4] for index, byte in enumerate(handler.rfile.read(size)))
        return json.loads(data.decode())

    @staticmethod
    def _ws_write(handler: BaseHTTPRequestHandler, value: Any) -> None:
        body = json.dumps(value).encode()
        if len(body) < 126:
            head = bytes([0x81, len(body)])
        elif len(body) < 65536:
            head = bytes([0x81, 126]) + struct.pack(">H", len(body))
        else:
            head = bytes([0x81, 127]) + struct.pack(">Q", len(body))
        handler.wfile.write(head + body)

    def handle(self, handler: BaseHTTPRequestHandler, method: str) -> None:
        parts = urlsplit(handler.path)
        path = parts.path
        if method == "GET" and path == "/ws":
            with self.lock:
                self.requests.append("GET /ws")
            return self._websocket(handler)
        length = int(handler.headers.get("Content-Length") or 0)
        raw = handler.rfile.read(length) if length else b""
        with self.lock:
            self.requests.append(f"{method} {path}")
            pause = self.delay.get(path, 0.0)
        if pause:
            time.sleep(pause)
        if method == "POST" and path == "/oauth/token":
            form = {key: values[0] for key, values in parse_qs(raw.decode()).items()}
            with self.lock:
                self.exchanges.append(form)
            credentials_file = os.path.join(self.state_dir, "credentials.json")
            try:
                with open(credentials_file) as handle:
                    credentials = json.load(handle)
            except (OSError, ValueError):
                credentials = {}
            code = form.get("subject_token", "")
            if credentials.get(code) != "unused":
                return self._send(handler, 401, {"code": "auth_invalid", "reason": "invalid_credential"})
            credentials[code] = "used"
            with open(credentials_file, "w") as handle:
                json.dump(credentials, handle)
            token = self.issue_token()
            return self._send(handler, 200, {"access_token": token, "token_type": "Bearer", "expires_in": 2592000,
                                             "scope": "orchestration:read orchestration:operate"})
        if not self._authorized(handler):
            if path == "/api/auth/session":
                return self._send(handler, 200, {"authenticated": False})
            return self._send(handler, 401, {"_tag": "EnvironmentAuthInvalidError", "code": "auth_invalid",
                                             "reason": "invalid_credential"})
        if method == "GET" and path == "/api/auth/session":
            return self._send(handler, 200, {"authenticated": True, "expiresAt": "2026-11-07T12:00:00.000Z",
                                             "sessionMethod": "bearer-access-token"})
        if method == "GET" and path == "/api/orchestration/shell":
            with self.lock:
                value = copy.deepcopy(self.shell)
            return self._send(handler, 200, value)
        if method == "GET" and path.startswith("/api/orchestration/threads/"):
            thread_id = unquote(path[len("/api/orchestration/threads/"):])
            with self.lock:
                base = next((item for item in self.shell["threads"] if item["id"] == thread_id), None)
                extra = copy.deepcopy(self.details.get(thread_id, {"messages": [], "activities": []}))
            if base is None:
                return self._send(handler, 404, {"code": "not_found", "reason": "thread_not_found"})
            thread = {key: value for key, value in copy.deepcopy(base).items()
                      if key not in ("hasPendingApprovals", "hasPendingUserInput", "backgroundLiveness",
                                     "planProgress", "latestUserMessageAt")}
            thread.update(extra)
            return self._send(handler, 200, {"snapshotSequence": 100, "thread": thread,
                                             "page": {"hasMore": False}})
        if method == "POST" and path == "/api/orchestration/dispatch":
            command = json.loads(raw.decode())
            with self.lock:
                self.dispatched.append(command)
                status = self.dispatch_status
                if status == 200 and command.get("type") == "thread.create":
                    created = _thread(command["threadId"], command["projectId"], command["title"], minutes_ago=0,
                                      latest=None)
                    if isinstance(command.get("modelSelection"), dict):
                        created["modelSelection"] = dict(command["modelSelection"])
                    if command.get("runtimeMode"):
                        created["runtimeMode"] = command["runtimeMode"]
                    self.first_message_at[created["id"]] = created["latestUserMessageAt"]
                    created["latestUserMessageAt"] = None  # as T3: no user message until a turn starts
                    self.shell["threads"].append(created)
                elif status == 200 and command.get("type") == "thread.turn.start":
                    thread = next((item for item in self.shell["threads"] if item["id"] == command.get("threadId")),
                                  None)
                    if thread is not None and thread["id"] in self.first_message_at:  # made here: its first message
                        thread["latestUserMessageAt"] = self.first_message_at.pop(thread["id"])
                        detail = self.details.setdefault(thread["id"], {"messages": [], "activities": []})
                        detail["messages"].append({"id": "u-" + str(command.get("commandId")), "role": "user",
                                                   "text": (command.get("message") or {}).get("text") or "",
                                                   "turnId": None, "streaming": False,
                                                   "createdAt": thread["latestUserMessageAt"]})
            if status != 200:
                return self._send(handler, status, {"code": "internal_error", "reason": "orchestration_dispatch_failed"})
            return self._send(handler, 200, {"sequence": 101 + len(self.dispatched)})
        return self._send(handler, 404, {"code": "not_found"})
