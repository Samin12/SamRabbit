"""Shared fakes for the T3 tests: a stdlib fake T3 Code server and small sanitized fixtures.

Fixture shapes follow T3 Code 0.1.4-nightly.20261027 (orchestration protocol 2):
``OrchestrationV2ThreadShell`` rows in the shell, ``{snapshotSequence,
projection}`` thread snapshots with ``runs`` / ``runtimeRequests`` / ``turnItems``
/ ``messages``, and the environment descriptor. They contain no user content.

The fake enforces what the real server does: orchestration HTTP routes answer a
bare 400 without ``x-t3-orchestration-protocol: 2``; ``GET /ws`` answers 426
without ``?orchestrationProtocol=2`` and 401 without a known bearer token; writes
exist only as Effect RPC over the WebSocket (``orchestration.dispatchCommand`` is
recorded in ``dispatched``, ``orchestration.launchThread`` in ``launched``). Each
RPC is preceded by a server ``Ping`` the client must answer.
"""

from __future__ import annotations

import base64
import copy
from datetime import datetime, timedelta
import gzip
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import struct
import tempfile
import threading
from urllib.parse import parse_qs, unquote, urlsplit

from sam_runtime.domains.t3.client import T3Endpoint
from sam_runtime.domains.t3.commands import T3CommandBuilder
from sam_runtime.domains.t3.repository import T3Repository
from sam_runtime.domains.t3.service import T3Service
from sam_runtime.security.credentials import ConnectionCredentialEnvelopes
from sam_runtime.storage.announcements import AnnouncementRepository
from sam_runtime.storage.database import RuntimeDatabase


PAIRING_CODE = "ABCD2345EFGH"
ENVIRONMENT_ID = "env-1"
PROJECT_MAIN = "11111111-1111-4111-8111-111111111111"
PROJECT_SIDE = "22222222-2222-4222-8222-222222222222"
PROJECT_SCRATCH = "33333333-3333-4333-8333-333333333333"
LIVE = frozenset({"preparing", "queued", "starting", "running", "waiting"})
_WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


class StubBridge:
    """Mimics the Java credential bridge without Keystore (tests only)."""

    def __init__(self) -> None:
        self.sealed: list[str] = []

    def sealConnectionCredential(self, record_name: str, plaintext: str) -> str:
        envelope = "stub." + base64.b64encode(f"{record_name}|{plaintext}".encode()).decode()
        self.sealed.append(envelope)
        return envelope

    def openConnectionCredential(self, record_name: str, envelope: str) -> str:
        raw = base64.b64decode(envelope.split(".", 1)[1]).decode()
        name, _, value = raw.partition("|")
        if name != record_name:
            raise ValueError("record mismatch")
        return value


def project(project_id: str, title: str, root: str) -> dict[str, object]:
    return {
        "id": project_id, "title": title, "workspaceRoot": root, "repositoryIdentity": None,
        "defaultModelSelection": None, "scripts": [], "createdAt": "2026-10-01T10:00:00.000Z",
        "updatedAt": "2026-10-01T10:00:00.000Z",
    }


def thread(
    thread_id: str,
    title: str,
    *,
    project_id: str = PROJECT_MAIN,
    status: str = "completed",
    run_id: str | None = None,
    completed_at: str | None = "2026-10-07T12:00:00.000Z",
    updated_at: str | None = None,
    request: str | None = None,
    blocking: bool | None = None,
    background: list[dict[str, object]] | None = None,
    activity: str | None = None,
    blocked: bool = False,
    settled: bool = False,
    model: str = "claude-opus-5-5",
    runtime_mode: str = "full-access",
    subagent: bool = False,
    preview: str | None = None,
) -> dict[str, object]:
    """One ``OrchestrationV2ThreadShell``. ``status`` is the latest run's (``idle``: never ran);
    ``request`` a pending runtime request kind (``command``, ``file-change``, ``user_input``...)."""
    has_run = status != "idle"
    run_id = (run_id or f"run-{thread_id}") if has_run else None
    live = status in LIVE
    started = _minus_minute(completed_at) if completed_at else "2026-10-07T11:59:00.000Z"
    pending = None
    if request is not None:
        pending = {"id": f"req-{thread_id}", "kind": request, "createdAt": "2026-10-07T11:59:40.000Z"}
        if blocking is not None:
            pending["blocking"] = blocking
    return {
        "createdBy": "user", "creationSource": "web",
        "id": thread_id, "projectId": project_id, "title": title,
        "providerInstanceId": "claudeAgent",
        "modelSelection": {"instanceId": "claudeAgent", "model": model, "options": [{"id": "effort", "value": "high"}]},
        "runtimeMode": runtime_mode, "interactionMode": "default", "branch": None, "worktreePath": None,
        "pullRequests": [],
        "lineage": {"relationshipToParent": "subagent", "parentThreadId": "parent"} if subagent else {"relationshipToParent": None},
        "forkedFrom": None, "activeProviderThreadId": f"pt-{thread_id}" if has_run else None,
        "latestRunId": run_id,
        "latestRunRequestedAt": started if has_run else None,
        "latestRunStartedAt": started if has_run else None,
        "latestRunCompletedAt": None if (live or not has_run) else completed_at,
        "activeRunId": run_id if live else None,
        "activityRunStatus": activity if activity is not None else (status if live else None),
        "blockedOnThreadWait": blocked,
        "status": status,
        "lastError": "Provider crashed" if status == "failed" else None,
        "pendingRuntimeRequest": pending,
        "latestVisibleMessage": (
            {"id": f"m-{thread_id}", "role": "assistant", "text": preview, "updatedAt": "2026-10-07T12:00:00.000Z"}
            if preview else None
        ),
        "latestUserMessageAt": started if has_run else None,
        "hasActionableProposedPlan": False,
        "pendingBackgroundTasks": list(background or []),
        "itemCount": 4, "visibleItemCount": 4,
        "createdAt": "2026-10-07T09:00:00.000Z",
        "updatedAt": updated_at or completed_at or "2026-10-07T12:00:00.000Z",
        "archivedAt": None,
        "settledOverride": "settled" if settled else None,
        "settledAt": "2026-10-07T12:30:00.000Z" if settled else None,
        "snoozedUntil": None,
        "deletedAt": None,
    }


def _minus_minute(value: str) -> str:
    stamp = datetime.fromisoformat(value.replace("Z", "+00:00")) - timedelta(minutes=1)
    return stamp.isoformat(timespec="milliseconds").replace("+00:00", "Z")


_APP_THREAD_KEYS = (
    "createdBy", "creationSource", "id", "projectId", "title", "providerInstanceId", "modelSelection", "runtimeMode",
    "interactionMode", "branch", "worktreePath", "pullRequests", "activeProviderThreadId", "lineage", "forkedFrom",
    "createdAt", "updatedAt", "archivedAt", "settledOverride", "settledAt", "snoozedUntil", "deletedAt",
)


def detail(shell_thread: dict[str, object], *, messages=None, requests=None, items=None) -> dict[str, object]:
    """A bounded thread snapshot for a shell row. ``requests``: pairs from ``approval_requested`` /
    ``input_requested`` (runtime request row + its turn item); ``items``: more turn items."""
    runs = []
    if shell_thread.get("latestRunId"):
        runs.append({
            "id": shell_thread["latestRunId"], "threadId": shell_thread["id"], "ordinal": 1,
            "providerInstanceId": "claudeAgent", "modelSelection": shell_thread["modelSelection"],
            "providerThreadId": shell_thread.get("activeProviderThreadId"), "userMessageId": "u1",
            "rootNodeId": None, "activeAttemptId": None, "status": shell_thread["status"],
            "requestedAt": shell_thread.get("latestRunRequestedAt"), "startedAt": shell_thread.get("latestRunStartedAt"),
            "completedAt": shell_thread.get("latestRunCompletedAt"), "checkpointId": None, "contextHandoffId": None,
        })
    turn_items = [pair["item"] for pair in requests or []] + list(items or [])
    for index, item in enumerate(turn_items):
        item.setdefault("ordinal", index + 1)
        item.setdefault("runId", shell_thread.get("latestRunId"))
        item.setdefault("threadId", shell_thread["id"])
    projection = {
        "thread": {key: shell_thread.get(key) for key in _APP_THREAD_KEYS},
        "runs": runs, "attempts": [], "nodes": [], "subagents": [], "providerSessions": [], "providerThreads": [],
        "providerTurns": [], "runtimeRequests": [pair["request"] for pair in requests or []],
        "messages": messages or [], "plans": [], "turnItems": turn_items, "checkpointScopes": [], "checkpoints": [],
        "contextHandoffs": [], "contextTransfers": [], "visibleTurnItems": [], "updatedAt": shell_thread["updatedAt"],
    }
    return {"snapshotSequence": 10, "projection": projection, "historyCursor": None, "hasMoreHistory": False,
            "latestLocalTurnOrdinal": None}


def message(message_id: str, role: str, text: str, *, at: str = "2026-10-07T11:59:30.000Z", streaming: bool = False) -> dict[str, object]:
    return {"id": message_id, "threadId": "t", "runId": None if role == "user" else "r", "nodeId": None, "role": role,
            "text": text, "attachments": [], "streaming": streaming, "createdAt": at, "updatedAt": at,
            "createdBy": "user" if role == "user" else "agent", "creationSource": "web"}


def _item(item_type: str, item_id: str, at: str, **fields: object) -> dict[str, object]:
    return {"id": item_id, "type": item_type, "nodeId": None, "providerThreadId": None, "providerTurnId": None,
            "nativeItemRef": None, "parentItemId": None, "status": "waiting", "title": None, "startedAt": at,
            "completedAt": None, "updatedAt": at, **fields}


def _request(request_id: str, kind: str, at: str, status: str, capability: str = "live") -> dict[str, object]:
    response = {"type": "live", "providerSessionId": "ps-1"} if capability == "live" else {"type": capability}
    return {"id": request_id, "nodeId": "n-1", "providerTurnId": None, "nativeRequestRef": None, "kind": kind,
            "status": status, "responseCapability": response, "createdAt": at,
            "resolvedAt": None if status == "pending" else at}


def approval_requested(request_id: str, *, at: str = "2026-10-07T11:59:40.000Z", kind: str = "command",
                       detail_text: str = "Run the unit tests", status: str = "pending",
                       options: list[dict[str, str]] | None = None) -> dict[str, dict[str, object]]:
    item = _item("approval_request", f"item-{request_id}", at, requestId=request_id, requestKind=kind, prompt=detail_text)
    if options is not None:
        item["options"] = options
    return {"request": _request(request_id, kind, at, status), "item": item}


def input_requested(request_id: str, *, at: str = "2026-10-07T11:59:45.000Z", options=("Use SQLite", "Use DuckDB"),
                    multi: bool = False, allow_custom: bool = True, message_mode: bool = False,
                    status: str = "pending") -> dict[str, dict[str, object]]:
    item = _item("user_input_request", f"item-{request_id}", at, requestId=request_id, questions=[{
        "id": "0", "header": "Storage", "question": "Which database should I use?",
        "options": [{"label": label, "description": "An option"} for label in options],
        "allowCustomAnswer": allow_custom, "multiSelect": multi,
    }])
    if message_mode:
        item["responseMode"] = "message"
    return {"request": _request(request_id, "user_input", at, status), "item": item}


def command_item(item_id: str, command: str, *, status: str = "running", title: str | None = "Command run",
                 at: str = "2026-10-07T11:59:41.000Z") -> dict[str, object]:
    return _item("command_execution", item_id, at, input=command, status=status, title=title)


def descriptor(environment_id: str = ENVIRONMENT_ID, label: str = "Test Mac") -> dict[str, object]:
    return {
        "environmentId": environment_id, "label": label,
        "platform": {"os": "darwin", "arch": "arm64", "machine": "mac-studio"},
        "serverVersion": "0.1.4-nightly.20261027.3783", "orchestrationProtocolVersion": 2,
        "capabilities": {"repositoryIdentity": True, "serverResolvedCommandContext": True, "threadStop": True},
    }


class FakeT3Server:
    """In-process T3 Code stand-in. Mutate ``shell``/``details`` between polls."""

    def __init__(self, *, environment_id: str = ENVIRONMENT_ID, label: str = "Test Mac", port: int = 0) -> None:
        self.codes = {PAIRING_CODE}
        self.tokens: set[str] = set()
        self.forms: list[dict[str, list[str]]] = []
        self.requests: list[dict[str, object]] = []
        self.dispatched: list[dict[str, object]] = []
        self.launched: list[dict[str, object]] = []
        self.rpcs: list[str] = []
        self.pongs = 0
        self.fail_dispatch_types: set[str] = set()
        self.descriptor = descriptor(environment_id, label)
        self.shell: dict[str, object] = {
            "schemaVersion": 1,
            "snapshotSequence": 1,
            "projects": [
                project(PROJECT_MAIN, "Workbench", "/Users/test/workbench"),
                project(PROJECT_SIDE, "Orbit Lab", "/Users/test/orbit"),
                project(PROJECT_SCRATCH, "No project", "/Users/test/.t3/scratch"),
            ],
            "threads": [],
            "archivedThreads": [],
        }
        self.details: dict[str, dict[str, object]] = {}
        self.unavailable = False
        self._lock = threading.Lock()
        self._server = self._bind(port)
        self._thread: threading.Thread | None = None

    def _bind(self, port: int) -> ThreadingHTTPServer:
        server = ThreadingHTTPServer(("127.0.0.1", port), self._handler())
        server.daemon_threads = True
        return server

    def _serve(self) -> None:
        self._thread = threading.Thread(target=self._server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)
        self._thread.start()

    def __enter__(self) -> "FakeT3Server":
        self._serve()
        return self

    def __exit__(self, *_: object) -> None:
        self.stop()

    def stop(self) -> None:
        if self._thread is not None:
            self._server.shutdown()
            self._thread = None
        self._server.server_close()

    def move(self) -> int:
        """T3 restarts on another port (same environment, same sessions). Returns the old port."""
        old = self.port
        self.stop()
        self._server = self._bind(0)
        self._serve()
        return old

    @property
    def port(self) -> int:
        return int(self._server.server_address[1])

    @property
    def url(self) -> str:
        return f"http://127.0.0.1:{self.port}"

    @property
    def endpoint(self) -> T3Endpoint:
        return T3Endpoint("http", "127.0.0.1", self.port)

    def set_threads(self, threads: list[dict[str, object]]) -> None:
        with self._lock:
            self.shell = {**self.shell, "threads": copy.deepcopy(threads),
                          "snapshotSequence": int(self.shell["snapshotSequence"]) + 1}

    def set_detail(self, thread_id: str, value: dict[str, object]) -> None:
        with self._lock:
            self.details[thread_id] = copy.deepcopy(value)

    def revoke_all(self) -> None:
        with self._lock:
            self.tokens.clear()

    def authorized_requests(self) -> list[dict[str, object]]:
        return [item for item in self.requests if "Authorization" in item["headers"]]

    def _rpc(self, tag: str, payload: dict[str, object]) -> dict[str, object]:
        """The ``exit`` of one RPC call."""
        with self._lock:
            self.rpcs.append(tag)
            if tag == "orchestration.dispatchCommand":
                if payload.get("type") in self.fail_dispatch_types:
                    return {"_tag": "Failure", "cause": {"_tag": "Fail", "error": {
                        "_tag": "OrchestrationV2DispatchCommandError", "commandId": payload.get("commandId"),
                        "commandType": payload.get("type"), "message": "Rejected"}}}
                self.dispatched.append(copy.deepcopy(payload))
                return {"_tag": "Success", "value": {"sequence": len(self.dispatched) + 100}}
            if tag == "orchestration.launchThread":
                if "launchThread" in self.fail_dispatch_types:
                    return {"_tag": "Failure", "cause": {"_tag": "Fail", "error": {
                        "_tag": "OrchestrationV2ThreadLaunchError", "commandId": payload.get("commandId"),
                        "projectId": payload.get("projectId"), "message": "Rejected"}}}
                self.launched.append(copy.deepcopy(payload))
                return {"_tag": "Success", "value": {"threadId": payload.get("threadId"), "resumed": False, "projection": {}}}
        return {"_tag": "Failure", "cause": {"_tag": "Die", "defect": "unknown method"}}

    def _handler(self):
        fake = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_: object) -> None:
                return

            def _send(self, status: int, payload: object) -> None:
                body = json.dumps(payload).encode() if payload is not None else b""
                gz = bool(body) and "gzip" in (self.headers.get("Accept-Encoding") or "")
                if gz:
                    body = gzip.compress(body)
                self.send_response(status)
                if body:
                    self.send_header("Content-Type", "application/json")
                if gz:
                    self.send_header("Content-Encoding", "gzip")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def _authed(self) -> bool:
                header = self.headers.get("Authorization") or ""
                return header.startswith("Bearer ") and header[7:] in fake.tokens

            def _record(self) -> None:
                fake.requests.append({"method": self.command, "path": self.path, "headers": dict(self.headers)})

            def do_GET(self) -> None:
                self._record()
                parts = urlsplit(self.path)
                if fake.unavailable:
                    self.close_connection = True
                    self.connection.close()
                    return
                if parts.path == "/.well-known/t3/environment":
                    self._send(200, fake.descriptor)
                    return
                if parts.path == "/ws":
                    self._websocket(parts)
                    return
                if parts.path == "/api/auth/session":
                    if self._authed():
                        self._send(200, {"authenticated": True, "scopes": ["orchestration:read", "orchestration:operate"],
                                         "sessionMethod": "bearer-access-token", "expiresAt": "2026-11-06T17:25:15.183Z"})
                    else:
                        self._send(200, {"authenticated": False})
                    return
                if not self._authed():
                    self._send(401, {"_tag": "EnvironmentAuthInvalidError", "code": "auth_invalid", "reason": "invalid_credential"})
                    return
                if parts.path.startswith("/api/orchestration/") and self.headers.get("x-t3-orchestration-protocol") != "2":
                    self._send(400, None)
                    return
                if parts.path == "/api/orchestration/shell":
                    with fake._lock:
                        self._send(200, fake.shell)
                    return
                if parts.path.startswith("/api/orchestration/threads/"):
                    rest = parts.path[len("/api/orchestration/threads/"):].split("/")
                    thread_id = unquote(rest[0])
                    with fake._lock:
                        value = fake.details.get(thread_id)
                        if value is None:
                            shell_thread = next((item for item in fake.shell["threads"] if item["id"] == thread_id), None)
                            value = detail(shell_thread) if shell_thread is not None else None
                    if value is None:
                        self._send(404, {"_tag": "EnvironmentResourceNotFoundError", "code": "not_found", "reason": "thread_not_found"})
                    elif len(rest) == 1:
                        self._send(200, {"snapshotSequence": value["snapshotSequence"], "projection": value["projection"]})
                    else:
                        self._send(200, value)
                    return
                self._send(404, {"code": "not_found"})

            def do_POST(self) -> None:
                self._record()
                length = int(self.headers.get("Content-Length") or 0)
                raw = self.rfile.read(length)
                parts = urlsplit(self.path)
                if parts.path == "/oauth/token":
                    form = parse_qs(raw.decode())
                    fake.forms.append(form)
                    code = (form.get("subject_token") or [""])[0]
                    if code in fake.codes:
                        fake.codes.discard(code)
                        token = f"tok-{len(fake.tokens) + 1}-" + "x" * 40
                        fake.tokens.add(token)
                        self._send(200, {"access_token": token, "issued_token_type": "urn:ietf:params:oauth:token-type:access_token",
                                         "token_type": "Bearer", "expires_in": 2591999, "scope": (form.get("scope") or [""])[0]})
                    else:
                        self._send(401, {"code": "auth_invalid", "reason": "invalid_credential"})
                    return
                # Protocol 2 has no HTTP write route (POST /api/orchestration/dispatch is gone).
                self._send(404, {"code": "not_found"})

            # -- WebSocket RPC ------------------------------------------------
            def _websocket(self, parts) -> None:
                if parse_qs(parts.query).get("orchestrationProtocol") != ["2"]:
                    self._send(426, {"code": "orchestration_protocol_incompatible", "orchestrationProtocolVersion": 2})
                    return
                if not self._authed():
                    self._send(401, {"code": "auth_invalid", "reason": "invalid_credential"})
                    return
                key = self.headers.get("Sec-WebSocket-Key") or ""
                accept = base64.b64encode(hashlib.sha1((key + _WS_GUID).encode()).digest()).decode()
                self.send_response(101)
                self.send_header("Upgrade", "websocket")
                self.send_header("Connection", "Upgrade")
                self.send_header("Sec-WebSocket-Accept", accept)
                self.end_headers()
                self.wfile.flush()
                self.close_connection = True
                request = self._read_json()
                if not isinstance(request, dict) or request.get("_tag") != "Request":
                    return
                self._write_json({"_tag": "Ping"})
                if self._read_json() == {"_tag": "Pong"}:
                    with fake._lock:
                        fake.pongs += 1
                exit_value = fake._rpc(str(request.get("tag")), dict(request.get("payload") or {}))
                # Effect RPC may batch several messages in one array.
                self._write_json([{"_tag": "Exit", "requestId": request.get("id"), "exit": exit_value}])

            def _read_json(self) -> object:
                head = self.rfile.read(2)
                if len(head) < 2:
                    return None
                size = head[1] & 0x7F
                if size == 126:
                    size = struct.unpack(">H", self.rfile.read(2))[0]
                elif size == 127:
                    size = struct.unpack(">Q", self.rfile.read(8))[0]
                mask = self.rfile.read(4) if head[1] & 0x80 else b""
                data = self.rfile.read(size)
                if mask:
                    data = bytes(byte ^ mask[index % 4] for index, byte in enumerate(data))
                return json.loads(data.decode())

            def _write_json(self, value: object) -> None:
                data = json.dumps(value).encode()
                head = bytearray([0x81])
                if len(data) < 126:
                    head.append(len(data))
                elif len(data) < 65536:
                    head += bytes([126]) + struct.pack(">H", len(data))
                else:
                    head += bytes([127]) + struct.pack(">Q", len(data))
                self.wfile.write(bytes(head) + data)
                self.wfile.flush()

        return Handler


class FixedIds:
    def __init__(self) -> None:
        self.count = 0

    def __call__(self) -> str:
        self.count += 1
        return f"00000000-0000-4000-8000-{self.count:012d}"


def make_service(fake: FakeT3Server | None = None, *, with_announcements: bool = True, probe_ports=None):
    """Return (service, announcements, repository, database, tempdir).

    ``probe_ports`` limits port rediscovery to the given ports (default: none, so a test never
    probes real ports on the machine running it)."""
    directory = tempfile.TemporaryDirectory()
    database = RuntimeDatabase(Path(directory.name) / "runtime.sqlite3")
    database.migrate()
    announcements = AnnouncementRepository(database) if with_announcements else None
    repository = T3Repository(database)
    service = T3Service(
        repository,
        ConnectionCredentialEnvelopes(StubBridge()),
        announcements=announcements,
        commands=T3CommandBuilder(new_id=FixedIds()),
        probe_ports=probe_ports or (lambda port: []),
    )
    return service, announcements, repository, database, directory
