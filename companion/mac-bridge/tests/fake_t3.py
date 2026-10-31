"""An in-process stand-in for the T3 Code server (orchestration protocol 2) used by the mobile tests (never the real
one).

* ``POST /oauth/token`` accepts a credential the fake CLI (``fake_t3_cli.py``) wrote to ``<state>/credentials.json``
  (single use) and issues ``base64url(claims).sig`` tokens; the form is recorded in ``exchanges``.
* ``GET /.well-known/t3/environment`` (no token) names ``environment_id``; ``GET /api/auth/session``.
* ``GET /api/orchestration/shell`` serves ``shell`` (v2 thread shells, ``OrchestrationV2ShellSnapshot``);
  ``GET /api/orchestration/threads/<id>`` and ``.../<id>/bounded`` serve an ``OrchestrationV2ThreadDetailSnapshot``
  built from the thread's shell (its run) and ``details[<id>]`` (``messages``, ``turnItems``, ``runtimeRequests``,
  ``plans``). Every orchestration route answers HTTP 400 with an empty body without
  ``x-t3-orchestration-protocol: 2``, as T3 does; ``POST /api/orchestration/dispatch`` is gone (404).
* ``GET /ws?orchestrationProtocol=2`` (a WebSocket, the bearer token on the upgrade; 426 without the query, as T3)
  answers one Effect-RPC ``Request``: ``server.getConfig`` with ``server_config`` (after a ``Ping`` the client must
  answer; both recorded in ``ws_requests``), ``orchestration.dispatchCommand`` (recorded in ``dispatched``; a
  ``message.dispatch`` to a thread made here becomes its first user message) and ``orchestration.launchThread``
  (recorded in ``launched``; makes the thread with its first message). ``writes`` has both, in order, as
  ``(tag, payload)``. ``dispatch_status`` other than 200 makes writes fail (``Exit`` ``Failure``); ``ws_status``
  other than 101 refuses the upgrade with that status.
* ``revoke_all()`` makes every issued token answer 401 (as after a revoke or the 30-day expiry);
  ``refuse_tokens = True`` makes every bearer token answer 401, even ones issued afterwards (a broken T3).
* ``delay``: ``{path: seconds}`` to answer slowly. ``ask_approval`` / ``ask_question`` / ``end_run`` change a thread
  the way T3 would (its shell and its detail together).
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
from typing import Any, Dict, List, Optional, Tuple
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
ENVIRONMENT_ID = "00000000-fake-4000-8000-0000000e0001"
ACTIVE = ("preparing", "queued", "starting", "running", "waiting")
TERMINAL = ("completed", "failed", "interrupted", "cancelled", "rolled_back")
APP_THREAD_KEYS = ("id", "projectId", "title", "providerInstanceId", "modelSelection", "runtimeMode", "interactionMode",
                   "branch", "worktreePath", "lineage", "forkedFrom", "activeProviderThreadId", "createdBy",
                   "creationSource", "createdAt", "updatedAt", "archivedAt", "settledOverride", "settledAt",
                   "snoozedUntil", "snoozedAt", "deletedAt")


def stamp_of(minutes_ago: int) -> str:
    return f"2026-10-08T{12 + (59 - minutes_ago) // 60:02d}:{(59 - minutes_ago) % 60:02d}:00.123Z"


def _thread(thread_id: str, project: str, title: str, *, minutes_ago: int, status: str = "completed",
            run_id: Optional[str] = None, request: Optional[Dict[str, Any]] = None, **extra: Any) -> Dict[str, Any]:
    """A v2 thread shell (``OrchestrationV2ThreadShell``). ``status``: the latest run's (``idle``: never ran);
    a ``preparing`` / ``starting`` / ``running`` / ``waiting`` run is the active one. ``request``: its
    ``pendingRuntimeRequest`` (``{id, kind, createdAt}``)."""
    stamp = stamp_of(minutes_ago)
    ran = status != "idle"
    run = (run_id or "run-" + thread_id) if ran else None
    active = status in ACTIVE
    value: Dict[str, Any] = {
        "id": thread_id, "projectId": project, "title": title, "providerInstanceId": "claudeAgent",
        "modelSelection": {"instanceId": "claudeAgent", "model": "claude-opus-5-5"},
        "runtimeMode": "full-access", "interactionMode": "default", "branch": None, "worktreePath": None,
        "lineage": {"parentThreadId": None, "relationshipToParent": None, "rootThreadId": thread_id},
        "forkedFrom": None, "activeProviderThreadId": "pt-" + thread_id if ran else None, "historyOrigin": "native",
        "createdBy": "user", "creationSource": "web",
        "latestRunId": run, "latestRunRequestedAt": stamp if ran else None,
        "latestRunStartedAt": stamp if ran and status not in ("preparing", "queued", "starting") else None,
        "latestRunCompletedAt": stamp if status in TERMINAL else None, "latestRunStopRequested": False,
        "activeRunId": run if active else None, "activityRunStartedAt": stamp if active else None,
        "activityRunStatus": status if active else None, "blockedOnThreadWait": False, "status": status,
        "lastError": None, "lastErrorClass": None, "lastErrorCode": None,
        "pendingRuntimeRequest": dict(request) if request else None, "pendingGuestMessageCount": 0,
        "latestVisibleMessage": None, "latestUserMessageAt": stamp, "latestUserAuthoredMessageAt": stamp,
        "hasActionableProposedPlan": False, "pendingBackgroundTasks": [], "providerInstanceHistory": [],
        "goal": None, "itemCount": 3 if ran else 0, "visibleItemCount": 3 if ran else 0,
        "createdAt": "2026-10-08T09:00:00.000Z", "updatedAt": stamp, "archivedAt": None, "settledOverride": None,
        "settledAt": None, "unsettledAt": None, "snoozedUntil": None, "snoozedAt": None, "deletedAt": None,
    }
    value.update(extra)
    return value


def default_shell() -> Dict[str, Any]:
    threads = [
        _thread("t-approval", "p-rabbit", "Fix the login redirect", minutes_ago=5, status="running",
                request={"id": "req-approve-1", "kind": "command", "createdAt": "2026-10-08T12:50:06.000Z"}),
        _thread("t-input", "p-site", "Pick a database", minutes_ago=7,
                request={"id": "req-input-1", "kind": "user_input", "createdAt": "2026-10-08T12:41:00.000Z"}),
        _thread("t-running", "p-rabbit", "Run the test suite", minutes_ago=2, status="running",
                run_id="run-active-1"),
        _thread("t-starting", "p-agent", "Book a table", minutes_ago=1, status="starting"),
        _thread("t-background", "p-agent", "Watch the deploy", minutes_ago=20, pendingBackgroundTasks=[
            {"taskId": "task-1", "kind": "subagent", "description": "Watch the deploy"}]),
        _thread("t-error", "p-site", "Deploy preview", minutes_ago=30, status="failed",
                lastError="The provider stopped unexpectedly.", lastErrorClass="provider_error"),
        _thread("t-settled-error", "p-site", "Old failure", minutes_ago=50, status="failed",
                lastError="Rate limited.", settledOverride="settled", settledAt="2026-10-08T11:00:00.000Z"),
        _thread("t-done", "p-agent", "Summarize my inbox", minutes_ago=15),
        _thread("t-new", "p-agent", "Draft for later", minutes_ago=40, status="idle"),
        _thread("t-stopped", "p-rabbit", "Refactor sync", minutes_ago=45, status="interrupted"),
    ]
    archived = [_thread("t-archived", "p-rabbit", "Archived thing", minutes_ago=3,
                        archivedAt="2026-10-08T10:00:00.000Z")]
    return {"schemaVersion": 1, "snapshotSequence": 100, "threads": threads, "archivedThreads": archived,
            "projects": copy.deepcopy(PROJECTS)}


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


def message(message_id: str, role: str, text: str, at: str, **extra: Any) -> Dict[str, Any]:
    """An ``OrchestrationV2ConversationMessage``."""
    return {"id": message_id, "threadId": "", "runId": None, "nodeId": None, "role": role, "text": text,
            "attachments": [], "streaming": False, "createdAt": at, "updatedAt": at,
            "createdBy": "user" if role == "user" else "agent", "creationSource": "web" if role == "user" else "provider",
            **extra}


def turn_item(item_id: str, kind: str, at: str, **fields: Any) -> Dict[str, Any]:
    """An ``OrchestrationV2TurnItem`` of type ``kind``."""
    return {"id": item_id, "threadId": "", "runId": None, "nodeId": None, "providerThreadId": None,
            "providerTurnId": None, "nativeItemRef": None, "parentItemId": None, "ordinal": 0, "status": "completed",
            "title": None, "startedAt": at, "completedAt": at, "updatedAt": at, "type": kind, **fields}


def runtime_request(request_id: str, kind: str, at: str, *, capability: str = "live") -> Dict[str, Any]:
    """An ``OrchestrationV2RuntimeRequest`` that is still pending."""
    answer = {"type": "live", "providerSessionId": "ps-1"} if capability == "live" else {"type": capability}
    return {"id": request_id, "nodeId": "node-1", "providerTurnId": None, "nativeRequestRef": None, "kind": kind,
            "status": "pending", "responseCapability": answer, "createdAt": at, "resolvedAt": None}


def default_details() -> Dict[str, Dict[str, Any]]:
    approval = {
        "messages": [message("u1", "user", "Fix the login redirect please", "2026-10-08T12:50:00.000Z"),
                     message("s1", "system", "thinking", "2026-10-08T12:50:01.000Z"),
                     message("assistant:a1", "assistant", "I will run the tests first.", "2026-10-08T12:50:02.000Z")],
        "turnItems": [
            turn_item("i-reason", "reasoning", "2026-10-08T12:50:01.500Z", text="thinking", streaming=False),
            turn_item("c1", "command_execution", "2026-10-08T12:50:03.000Z", title="Command run", input="npm test"),
            turn_item("c2", "file_search", "2026-10-08T12:50:05.000Z", title="Read file", status="inProgress"),
            turn_item("i-approve", "approval_request", "2026-10-08T12:50:06.000Z", requestId="req-approve-1",
                      requestKind="command", prompt="npm test -- --watch=false", status="inProgress")],
        "runtimeRequests": [runtime_request("req-approve-1", "command", "2026-10-08T12:50:06.000Z")]}
    question = {
        "messages": [message("u2", "user", "Set up storage", "2026-10-08T12:40:00.000Z")],
        "turnItems": [turn_item("i-ask", "user_input_request", "2026-10-08T12:41:00.000Z", requestId="req-input-1",
                                status="inProgress", questions=[
                                    {"id": "q1", "header": "Database", "question": "Which database should I use?",
                                     "options": [{"label": "SQLite", "description": "A file", "value": "sqlite"},
                                                 {"label": "Postgres", "description": "A server"}],
                                     "allowCustomAnswer": False, "multiSelect": False}])],
        "runtimeRequests": [runtime_request("req-input-1", "user_input", "2026-10-08T12:41:00.000Z")]}
    running = {
        "messages": [message("u3", "user", "Run the tests", "2026-10-08T12:55:00.000Z")],
        "plans": [{"id": "plan-1", "threadId": "t-running", "runId": "run-active-1", "nodeId": "node-1",
                   "status": "active", "kind": "todo_list", "steps": [
                       {"id": "s1", "text": "Build", "status": "completed"},
                       {"id": "s2", "text": "Running unit tests", "status": "running"},
                       {"id": "s3", "text": "Lint", "status": "pending"},
                       {"id": "s4", "text": "Report", "status": "pending"}]}]}
    return {"t-approval": approval, "t-input": question, "t-running": running}


class FakeT3:
    def __init__(self, state_dir: str) -> None:
        self.state_dir = state_dir
        self.lock = threading.Lock()
        self.shell = default_shell()
        self.details = default_details()
        self.environment_id = ENVIRONMENT_ID
        self.tokens: Dict[str, bool] = {}  # token -> valid
        self.exchanges: List[Dict[str, Any]] = []
        self.dispatched: List[Dict[str, Any]] = []
        self.launched: List[Dict[str, Any]] = []
        self.writes: List[Tuple[str, Dict[str, Any]]] = []
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
        return next(item for item in self.shell["threads"] + self.shell["archivedThreads"] if item["id"] == thread_id)

    def detail(self, thread_id: str) -> Dict[str, Any]:
        """The thread's detail parts (``messages``, ``turnItems``, ``runtimeRequests``, ``plans``), made if missing."""
        value = self.details.setdefault(thread_id, {})
        for name in ("messages", "turnItems", "runtimeRequests", "plans"):
            value.setdefault(name, [])
        return value

    def ask_approval(self, thread_id: str, request_id: str, *, kind: str = "command", prompt: Optional[str] = None,
                     at: str = "2026-10-08T13:00:00.000Z", options: Optional[List[Dict[str, str]]] = None) -> None:
        """The thread's run asks for an approval (its shell's ``pendingRuntimeRequest`` and its detail's request)."""
        thread = self.get_thread(thread_id)
        thread.update({"pendingRuntimeRequest": {"id": request_id, "kind": kind, "createdAt": at}, "updatedAt": at})
        detail = self.detail(thread_id)
        detail["runtimeRequests"].append(runtime_request(request_id, kind, at))
        fields: Dict[str, Any] = {"requestId": request_id, "requestKind": kind}
        if prompt is not None:
            fields["prompt"] = prompt
        if options is not None:
            fields["options"] = options
        detail["turnItems"].append(turn_item("i-" + request_id, "approval_request", at, **fields))

    def ask_question(self, thread_id: str, request_id: str, questions: List[Dict[str, Any]], *,
                     at: str = "2026-10-08T13:00:00.000Z", capability: str = "live") -> None:
        thread = self.get_thread(thread_id)
        thread.update({"pendingRuntimeRequest": {"id": request_id, "kind": "user_input", "createdAt": at},
                       "updatedAt": at})
        detail = self.detail(thread_id)
        detail["runtimeRequests"].append(runtime_request(request_id, "user_input", at, capability=capability))
        detail["turnItems"].append(turn_item("i-" + request_id, "user_input_request", at, requestId=request_id,
                                             questions=questions))

    def end_run(self, thread_id: str, at: str, *, status: str = "completed", run_id: Optional[str] = None,
                **extra: Any) -> None:
        """The thread's run ends (``completed``, ``failed``, ``interrupted``) at ``at``; open requests close.
        ``run_id``: a new run (it started and ended at ``at``), else the latest one."""
        thread = self.get_thread(thread_id)
        if run_id is not None:
            thread.update({"latestRunId": run_id, "latestRunRequestedAt": at, "latestRunStartedAt": at})
        thread.update({"status": status, "activeRunId": None, "activityRunStatus": None, "activityRunStartedAt": None,
                       "latestRunCompletedAt": at, "updatedAt": at, "pendingRuntimeRequest": None,
                       "latestRunId": thread.get("latestRunId") or "run-" + thread_id,
                       "latestRunRequestedAt": thread.get("latestRunRequestedAt") or at,
                       "latestRunStartedAt": thread.get("latestRunStartedAt") or at, **extra})
        for request in self.detail(thread_id)["runtimeRequests"]:
            request["status"] = "resolved"

    def start_run(self, thread_id: str, at: str, *, run_id: str, status: str = "running", **extra: Any) -> None:
        """A new run of the thread starts at ``at`` (a message was sent)."""
        thread = self.get_thread(thread_id)
        thread.update({"status": status, "latestRunId": run_id, "activeRunId": run_id, "activityRunStatus": status,
                       "activityRunStartedAt": at, "latestRunRequestedAt": at, "latestRunStartedAt": at,
                       "latestRunCompletedAt": None, "latestUserMessageAt": at, "updatedAt": at,
                       "activeProviderThreadId": thread.get("activeProviderThreadId") or "pt-" + thread_id, **extra})

    def projection(self, thread_id: str) -> Optional[Dict[str, Any]]:
        """``OrchestrationV2ThreadProjection`` of a thread (None when T3 does not have it)."""
        base = next((item for item in self.shell["threads"] + self.shell["archivedThreads"]
                     if item["id"] == thread_id), None)
        if base is None:
            return None
        extra = copy.deepcopy(self.detail(thread_id))
        runs = []
        if base.get("latestRunId"):
            runs.append({"id": base["latestRunId"], "threadId": thread_id, "ordinal": 1,
                         "providerInstanceId": base["providerInstanceId"], "modelSelection": base["modelSelection"],
                         "providerThreadId": base.get("activeProviderThreadId"), "userMessageId": "u-1",
                         "rootNodeId": None, "activeAttemptId": None,
                         "status": "completed" if base["status"] == "idle" else base["status"],
                         "requestedAt": base.get("latestRunRequestedAt"), "startedAt": base.get("latestRunStartedAt"),
                         "completedAt": base.get("latestRunCompletedAt"), "checkpointId": None,
                         "contextHandoffId": None})
        return {"thread": {key: copy.deepcopy(base.get(key)) for key in APP_THREAD_KEYS}, "runs": runs,
                "attempts": [], "nodes": [], "subagents": [], "providerSessions": [], "providerThreads": [],
                "providerTurns": [], "runtimeRequests": extra["runtimeRequests"], "messages": extra["messages"],
                "plans": extra["plans"], "turnItems": extra["turnItems"], "checkpointScopes": [], "checkpoints": [],
                "contextHandoffs": [], "contextTransfers": [], "visibleTurnItems": [], "updatedAt": base["updatedAt"]}

    # ------------------------------------------------------------------ HTTP
    def _send(self, handler: BaseHTTPRequestHandler, status: int, value: Any) -> None:
        body = json.dumps(value).encode() if value is not None else b""
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

    def _websocket(self, handler: BaseHTTPRequestHandler, query: str) -> None:
        """One Effect-RPC call over a WebSocket: the upgrade, one masked client frame, one ``Exit`` answer."""
        if parse_qs(query).get("orchestrationProtocol") != ["2"]:
            return self._send(handler, 426, {"code": "orchestration_protocol_incompatible",
                                             "orchestrationProtocolVersion": 2})
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
        tag = str(request.get("tag"))
        if tag == "server.getConfig":
            with self.lock:
                self.ws_requests.append(tag)
                config = copy.deepcopy(self.server_config)
            self._ws_write(handler, {"_tag": "Ping"})  # Effect RPC's own ping: the client answers it and reads on
            pong = self._ws_read(handler)
            with self.lock:
                self.ws_requests.append(str(pong.get("_tag")))
            exit_value = {"_tag": "Success", "value": config} if config is not None else \
                {"_tag": "Failure", "cause": [{"_tag": "Fail", "error": {"_tag": "ServerSettingsError"}}]}
        elif tag in ("orchestration.dispatchCommand", "orchestration.launchThread"):
            exit_value = self._write(tag, _dict(request.get("payload")))
        else:
            exit_value = {"_tag": "Failure", "cause": [{"_tag": "Die", "defect": {"_tag": "RpcNotFound"}}]}
        self._ws_write(handler, [{"_tag": "Exit", "requestId": request.get("id"), "exit": exit_value}])
        handler.wfile.write(bytes([0x88, 0x00]))
        handler.close_connection = True

    def _write(self, tag: str, payload: Dict[str, Any]) -> Dict[str, Any]:
        """A write as T3 would take it (only what the tests look at): a launch makes the thread and its first message;
        a ``message.dispatch`` gives a thread made here its first user message."""
        with self.lock:
            self.writes.append((tag, payload))
            (self.launched if tag == "orchestration.launchThread" else self.dispatched).append(payload)
            if self.dispatch_status != 200:
                return {"_tag": "Failure", "cause": [{"_tag": "Fail", "error": {
                    "_tag": "OrchestrationV2DispatchCommandError", "commandId": payload.get("commandId"),
                    "commandType": payload.get("type") or "launch", "message": "orchestration_dispatch_failed"}}]}
            self.counter += 1
            if tag == "orchestration.launchThread":
                thread_id = str(payload["threadId"])
                existing = next((item for item in self.shell["threads"] if item["id"] == thread_id), None)
                if existing is None:
                    created = _thread(thread_id, payload["projectId"], payload["title"], minutes_ago=0,
                                      status="idle", creationSource=payload.get("creationSource"))
                    created["latestUserMessageAt"] = None  # as T3: no user message until the message lands
                    if isinstance(payload.get("modelSelection"), dict):
                        created["modelSelection"] = dict(payload["modelSelection"])
                        created["providerInstanceId"] = payload["modelSelection"].get("instanceId")
                    created["runtimeMode"] = payload.get("runtimeMode") or created["runtimeMode"]
                    self.shell["threads"].append(created)
                    self.first_message_at[thread_id] = stamp_of(0)
                    if isinstance(payload.get("initialMessage"), dict):
                        self._first_message(thread_id, payload["initialMessage"].get("text"))
                projection = self.projection(thread_id)
                return {"_tag": "Success", "value": {"threadId": thread_id, "projection": projection,
                                                     "resumed": existing is not None}}
            if payload.get("type") == "message.dispatch":
                self._first_message(str(payload.get("threadId")), payload.get("text"))
            return {"_tag": "Success", "value": {"sequence": 100 + len(self.writes)}}

    def _first_message(self, thread_id: str, text: Any) -> None:
        """A thread made here gets its first user message (call with ``lock`` held)."""
        if thread_id not in self.first_message_at:
            return
        thread = next((item for item in self.shell["threads"] if item["id"] == thread_id), None)
        if thread is None:
            return
        thread["latestUserMessageAt"] = self.first_message_at.pop(thread_id)
        self.detail(thread_id)["messages"].append(message("u-" + str(self.counter), "user", str(text or ""),
                                                          thread["latestUserMessageAt"]))

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
            return self._websocket(handler, parts.query)
        length = int(handler.headers.get("Content-Length") or 0)
        raw = handler.rfile.read(length) if length else b""
        with self.lock:
            self.requests.append(f"{method} {path}")
            pause = self.delay.get(path, 0.0)
        if pause:
            time.sleep(pause)
        if method == "GET" and path == "/.well-known/t3/environment":
            return self._send(handler, 200, {"environmentId": self.environment_id, "label": "Test Mac",
                                             "serverVersion": "0.1.4-test", "orchestrationProtocolVersion": 2})
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
        if path.startswith("/api/orchestration/") and handler.headers.get("x-t3-orchestration-protocol") != "2":
            return self._send(handler, 400, None)  # T3 2: the protocol header is required, the body empty
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
            rest = path[len("/api/orchestration/threads/"):]
            bounded = rest.endswith("/bounded")
            thread_id = unquote(rest[:-len("/bounded")] if bounded else rest)
            with self.lock:
                projection = self.projection(thread_id)
            if projection is None:
                return self._send(handler, 404, {"code": "not_found", "reason": "thread_not_found"})
            value: Dict[str, Any] = {"snapshotSequence": 100, "projection": projection}
            if bounded:
                value.update({"historyCursor": None, "hasMoreHistory": False, "latestLocalTurnOrdinal": 1})
            return self._send(handler, 200, value)
        return self._send(handler, 404, {"code": "not_found"})


def _dict(value: Any) -> Dict[str, Any]:
    return value if isinstance(value, dict) else {}
