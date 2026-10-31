"""T3 Code for the SamRabbit bridge: the bridge's own T3 session, the thread snapshot and the phone's commands.

The bridge holds its own T3 Code session, separate from the R1's. It mints a one-time pairing credential with the
CLI bundled in the T3 Code app (``auto``: the app whose process is the live server, else the first of T3 Code
(Alpha) / (Nightly) / (Beta) / T3 Code in /Applications)::

    ELECTRON_RUN_AS_NODE=1 "/Applications/T3 Code (Nightly).app/Contents/MacOS/T3 Code (Nightly)" \\
        ".../app.asar/apps/server/dist/bin.mjs" auth pairing create --label "SamRabbit bridge" --ttl 10m \\
        --base-url http://127.0.0.1:3774 --json

exchanges it at ``POST /oauth/token`` and keeps the bearer token (30 days, no refresh) in
``~/.config/samrabbit/t3-token`` (0600, JSON). It pairs again by itself when the token is missing, about to expire,
or rejected (HTTP 401), at most once per request. Pairing never runs in a loop: a failed pairing waits 1 minute
before the next try (doubling up to 10 minutes); a token this process minted that T3 refuses before it ever worked
(or within a minute of being minted) means T3 is not taking the bridge's credentials, so no new pairing for 5 minutes
(doubling up to 1 hour); and there are never more than ``MAX_PAIRINGS_PER_HOUR`` pairings in an hour.

Where T3 listens: with no address configured (the installed copy), the port T3 wrote to ``server-runtime.json`` in
its state folder (``$T3CODE_HOME/userdata``, else ``~/.t3/userdata``) while its pid is alive, else
``DEFAULT_SERVER_URL``; the file is checked (its mtime) before every call, so a T3 that restarts on another port is
followed without pairing again (the token belongs to T3's auth store, not to a port). Another app can hold T3's old
port (Voyager, a T3-derived app with its own auth, has 127.0.0.1:3773), so before a token or a pairing credential
goes to a discovered address the server must answer ``GET /.well-known/t3/environment`` with the environment id in
T3's own ``environment-id`` file (checked once a minute per address); anything else is "T3 is not answering".

Orchestration protocol 2. Reads (each with ``x-t3-orchestration-protocol: 2``): ``GET /api/orchestration/shell``
(``?omitIdleSubagents=1``; a cached snapshot) and ``GET /api/orchestration/threads/<id>/bounded`` (the recent
window of a thread's projection; the whole ``/threads/<id>`` only when an open request's question is older than
the window), plus ``server.getConfig`` (the providers T3 offers and their models, for the desktop inbox's new tasks,
cached for 10 minutes). Writes and ``server.getConfig`` go over T3's Effect RPC WebSocket (``GET
/ws?orchestrationProtocol=2``, the same bearer token, one ``Request`` per connection): ``orchestration.launchThread``
(a new task: the thread and its first message in one call, ``workspaceStrategy: root``) and
``orchestration.dispatchCommand`` with ``message.dispatch`` (a message: ``start_immediately`` with ``deliveryIntent:
auto``, so T3 steers or queues it behind a running turn itself), ``runtime-request.respond`` (an approval's
``decision`` or a question's ``answers``) and ``thread.stop``. ``bridge_thread`` presents each v2 thread shell in the
shape the rest of the bridge reads (as T3's own ``presentThreadShell`` does, client-runtime/src/state/models.ts);
status, seen markers, pending requests, commands and project placement follow ``runtime/sam_runtime/domains/t3/``
(status.py, commands.py, placement.py) and T3's ``derivePendingThreadRequests``, ported to stdlib Python 3.9.

Thread text, prompts, the token and pairing credentials are never logged.

Command line (used by install.sh)::

    python3 -I samrabbit_t3.py status|ensure-paired [--token-file F] [--url U] [--cli auto|PATH] [--label L]

``ensure-paired`` pairs with the T3 server it finds (above) only from the installed copy of the bridge
(``samrabbit_installed``: the account's own home, never $HOME, plus install.sh's marker). Any other copy (a checkout,
a test, a copy installed into a temp HOME) answers ``t3_dev_copy`` unless given both ``--url`` (or
``SAMRABBIT_T3_URL``) and an explicit ``--cli`` path (or ``SAMRABBIT_T3_CLI``): a server address alone never runs the
T3 Code app's own CLI, so a test never mints a credential on the real T3 Code.
"""

from __future__ import annotations

import argparse
import base64
from collections import deque
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
import hashlib
from http.client import HTTPConnection, HTTPException, HTTPSConnection
import ipaddress
import json
import logging
import os
import re
import signal
import socket
import ssl
import struct
import subprocess
import sys
import tempfile
import threading
import time
from typing import Any, Callable, Deque, Dict, Iterable, List, Optional, Tuple
from urllib.parse import quote, urlencode, urlsplit
import uuid
import zlib

_LOG = logging.getLogger("samrabbit-bridge.t3")

DEFAULT_SERVER_URL = "http://127.0.0.1:3773"  # T3's usual port, when its server-runtime.json says nothing
DEFAULT_TOKEN_FILE = "~/.config/samrabbit/t3-token"
T3_HOME = "~/.t3"  # T3's state folder (``$T3CODE_HOME`` when set); its server writes userdata/server-runtime.json
T3_APP_NAMES = ("T3 Code (Alpha)", "T3 Code (Nightly)", "T3 Code (Beta)", "T3 Code")  # bundle id com.t3tools.t3code
T3_APPS = tuple(f"/Applications/{name}.app" for name in T3_APP_NAMES)
T3_SERVER_BIN = "apps/server/dist/bin.mjs"  # inside the app's asar archive (Electron reads it)
T3_EXECUTABLE: Optional[str] = None  # a fixed app executable and its app.asar (tests); None: ``find_app`` decides
T3_ASAR: Optional[str] = None
ORCHESTRATION_PROTOCOL = "2"  # every /api/orchestration route wants this header (else HTTP 400, an empty body)
PROTOCOL_HEADER = "x-t3-orchestration-protocol"
WS_PATH = "/ws?orchestrationProtocol=" + ORCHESTRATION_PROTOCOL  # without it the upgrade answers 426
CREATION_SOURCE = "mobile"  # what T3 records as where the bridge's threads and messages came from
IDENTITY_TTL = 60.0  # a discovered server's environment id is checked again after this long
CLI_AUTO = "auto"
CLI_NONE = "none"  # no pairing at all (a dev copy of the bridge that was not given a CLI path)
CLIENT_LABEL = "SamRabbit bridge"
PAIRING_TTL = "10m"
REQUESTED_SCOPES = "orchestration:read orchestration:operate"
GRANT_TYPE = "urn:ietf:params:oauth:grant-type:token-exchange"
SUBJECT_TOKEN_TYPE = "urn:t3:params:oauth:token-type:environment-bootstrap"
ACCESS_TOKEN_TYPE = "urn:ietf:params:oauth:token-type:access_token"
PAIRING_ALPHABET = frozenset("23456789ABCDEFGHJKLMNPQRSTUVWXYZ")
CLI_TIMEOUT_SECONDS = 30.0
HTTP_TIMEOUT_SECONDS = 6.0
REPAIR_BEFORE_EXPIRY = timedelta(days=1)  # a token this close to its end is replaced before it is used
PAIR_BACKOFF_SECONDS = 60.0  # after a failed pairing, the CLI is not run again for this long ...
PAIR_BACKOFF_MAX_SECONDS = 10 * 60.0  # ... doubling with each failed pairing in a row, up to this
REFUSED_BACKOFF_SECONDS = 5 * 60.0  # T3 refused a token this process had just minted: no new pairing for this long ...
REFUSED_BACKOFF_MAX_SECONDS = 60 * 60.0  # ... doubling each time it happens again, up to an hour
FRESH_TOKEN_SECONDS = 60.0  # a minted token T3 refuses this soon (or before it ever worked) counts as "just minted"
MAX_PAIRINGS_PER_HOUR = 6  # a hard cap on new "SamRabbit bridge" sessions, whatever the reason
MAX_RESPONSE_BYTES = 8 * 1024 * 1024
MAX_CLI_OUTPUT_BYTES = 256 * 1024
MAX_PROMPT_CHARS = 120_000
MAX_MESSAGE_CHARS = 6000
MAX_MESSAGES = 60
SHELL_MAX_AGE = 3.0  # seconds a route may reuse the snapshot
DETAIL_TTL = 1.5
PLAN_MAX_AGE = 15.0  # a running thread's task list (its step, in lists) is read again after this long ...
PLAN_READS_PER_SNAPSHOT = 4  # ... for at most this many threads per shell read
TURN_START_GRACE = 45.0
# ``server.getConfig`` (the providers and their models) and every write go over T3's WebSocket RPC; the provider list
# is read once in a while (a few hundred KB) and only the parts a new task needs are kept.
WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
WS_TIMEOUT_SECONDS = 5.0
DISPATCH_TIMEOUT_SECONDS = 10.0
LAUNCH_TIMEOUT_SECONDS = 20.0  # a new thread: T3 may prepare its folder before it answers
MAX_WS_MESSAGE_BYTES = 8 * 1024 * 1024
CONFIG_MAX_AGE = 10 * 60.0
CONFIG_RETRY_SECONDS = 60.0  # after a failed read, the thread list stands in for this long
# The orchestration project's default name: T3's built-in agent project (a project-name value, not code).
DEFAULT_ORCHESTRATION_TITLE = "Hermes"
DEFAULT_MODEL_SELECTION = {"instanceId": "claudeAgent", "model": "claude-opus-5-5"}
DEFAULT_RUNTIME_MODE = "full-access"
DEFAULT_INTERACTION_MODE = "default"
RUNTIME_MODES = frozenset({"approval-required", "auto-accept-edits", "auto", "full-access"})
APPROVAL_DECISIONS = frozenset({"accept", "acceptForSession", "acceptAlways", "decline", "cancel"})
_CGNAT = ipaddress.ip_network("100.64.0.0/10")
_THREAD_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:\-]{0,127}$")


# --------------------------------------------------------------------------- errors


class T3Error(Exception):
    """An answer of ``{"error": {"code", "message", "retryable"}}``; the message never carries thread text."""

    def __init__(self, status: int, code: str, message: str, *, retryable: bool = False) -> None:
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message
        self.retryable = retryable

    def payload(self) -> Dict[str, Any]:
        return {"error": {"code": self.code, "message": self.message, "retryable": self.retryable}}


class _Unavailable(Exception):
    """Network failure, timeout, an oversized or unreadable answer."""


class _Unauthorized(Exception):
    """HTTP 401 from T3: the bearer token (or pairing credential) was rejected."""


class _RequestFailed(Exception):
    def __init__(self, status: int, code: Optional[str], reason: Optional[str]) -> None:
        super().__init__(f"HTTP {status}")
        self.status = status
        self.code = code
        self.reason = reason


def unavailable() -> T3Error:
    return T3Error(503, "t3_unavailable", "T3 Code on the Mac is not answering. Is the T3 Code app running?",
                   retryable=True)


def _now_utc() -> datetime:
    return datetime.now(timezone.utc)


def iso_utc(value: datetime) -> str:
    return value.astimezone(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def parse_time(value: Any) -> Optional[datetime]:
    if not isinstance(value, str) or not value:
        return None
    text = value.strip().replace("Z", "+00:00")
    match = re.match(r"^(.*T\d{2}:\d{2}:\d{2})(\.\d+)?(.*)$", text)
    if match and match.group(2):  # Python 3.9 parses only 3 or 6 fraction digits
        text = match.group(1) + (match.group(2) + "000000")[:7] + match.group(3)
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        return None
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)


def normal_time(value: Any) -> Optional[str]:
    """Any T3 time as ``YYYY-MM-DDTHH:MM:SSZ`` (what Swift's ISO 8601 decoder reads), or None."""
    parsed = parse_time(value)
    return iso_utc(parsed) if parsed is not None else None


# --------------------------------------------------------------------------- HTTP


def _private_host(host: str) -> bool:
    if host == "localhost":
        return True
    try:
        address = ipaddress.ip_address(host.split("%", 1)[0])
    except ValueError:
        return False
    return address.is_loopback or address.is_private or address.is_link_local or \
        (address.version == 4 and address in _CGNAT)


def _parse_server(base_url: str) -> Tuple[str, str, int, str]:
    """``(scheme, host, port, base_url)`` of a T3 address; ValueError for anything but http(s)://host[:port] (plain
    http only for loopback / private / Tailscale hosts)."""
    parts = urlsplit(str(base_url or "").strip())
    scheme = parts.scheme.lower()
    host = (parts.hostname or "").lower()
    if scheme not in ("http", "https") or not host or parts.username or parts.password:
        raise ValueError("the T3 server address must be http(s)://host:port")
    if scheme == "http" and not _private_host(host):
        raise ValueError("plain http is allowed only for a T3 server on this Mac or the local network")
    port = int(parts.port or (443 if scheme == "https" else 80))
    shown = f"[{host}]" if ":" in host else host
    return scheme, host, port, f"{scheme}://{shown}:{port}"


def _pid_alive(pid: Any) -> bool:
    if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 1:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True  # alive, someone else's
    except OSError:
        return False
    return True


def t3_state_dir(environ: Optional[Dict[str, str]] = None) -> str:
    """T3's ``userdata`` folder: ``$T3CODE_HOME/userdata``, else ``~/.t3/userdata`` (as T3's server decides)."""
    env = os.environ if environ is None else environ
    home = (env.get("T3CODE_HOME") or "").strip()
    return os.path.join(os.path.expanduser(home or T3_HOME), "userdata")


class ServerLocator:
    """Where T3 Code's server is now and which environment it is, from the files T3 keeps in its state folder:
    ``server-runtime.json`` (``{version, pid, host, port, origin, serverVersion, ...}``, written by the running
    server) and ``environment-id``. Both are re-read only when their mtime or size changes; the runtime file counts
    only while its pid is alive. ``url()`` falls back to ``DEFAULT_SERVER_URL`` (read on each call)."""

    def __init__(self, state_dir: Optional[str] = None) -> None:
        self.state_dir = state_dir or t3_state_dir()
        self._lock = threading.Lock()
        self._files: Dict[str, Tuple[Optional[Tuple[int, int, int]], Any]] = {}

    def _read(self, name: str, parse: Callable[[str], Any]) -> Any:
        path = os.path.join(self.state_dir, name)
        try:
            info = os.stat(path)
            stamp: Optional[Tuple[int, int, int]] = (info.st_mtime_ns, info.st_size, info.st_ino)
        except OSError:
            stamp = None
        with self._lock:
            known = self._files.get(name)
            if known is not None and known[0] == stamp:
                return known[1]
        value = None
        if stamp is not None and stamp[1] <= 64 * 1024:
            try:
                with open(path, "r", encoding="utf-8") as handle:
                    value = parse(handle.read())
            except (OSError, ValueError, UnicodeDecodeError):
                value = None
        with self._lock:
            self._files[name] = (stamp, value)
        return value

    def runtime(self) -> Optional[Dict[str, Any]]:
        """The live server's runtime record, or None (no file, unreadable, or its process is gone)."""
        value = self._read("server-runtime.json", lambda text: json.loads(text))
        if not isinstance(value, dict) or not _pid_alive(value.get("pid")):
            return None
        port = value.get("port")
        if not isinstance(port, int) or isinstance(port, bool) or not 0 < port < 65536:
            return None
        return value

    def pid(self) -> Optional[int]:
        runtime = self.runtime()
        return int(runtime["pid"]) if runtime is not None else None

    def url(self) -> str:
        """``http://127.0.0.1:<port>`` of the live server (a wildcard or loopback bind), else ``DEFAULT_SERVER_URL``."""
        runtime = self.runtime()
        if runtime is None:
            return DEFAULT_SERVER_URL
        host = str(runtime.get("host") or "").strip().lower()
        if host in ("", "0.0.0.0", "::", "127.0.0.1", "localhost"):
            host = "127.0.0.1"
        try:
            ipaddress.ip_address(host)
        except ValueError:
            return DEFAULT_SERVER_URL
        shown = f"[{host}]" if ":" in host else host
        return f"http://{shown}:{int(runtime['port'])}"

    def environment_id(self) -> Optional[str]:
        """T3's own environment id (``environment-id``), or None when the file is not there."""
        value = self._read("environment-id", lambda text: text.strip())
        return value if isinstance(value, str) and 8 <= len(value) <= 200 else None


class T3Http:
    """Stdlib HTTP for one T3 server: plain http only for loopback / private / Tailscale hosts.

    ``base_url`` None: the server ``locator`` finds (``ServerLocator``), looked up again before every call, and checked
    to be T3 itself before anything secret goes to it (``_verified``). An explicit address is used as given."""

    def __init__(self, base_url: Optional[str] = DEFAULT_SERVER_URL, *, timeout: float = HTTP_TIMEOUT_SECONDS,
                 locator: Optional[ServerLocator] = None) -> None:
        self.auto = base_url is None
        self.locator = (locator or ServerLocator()) if self.auto else None
        self._lock = threading.Lock()
        self._identities: Dict[str, Tuple[float, str]] = {}  # base url -> (checked at, environment id)
        self.environment_id: Optional[str] = None  # the checked server's, in auto mode
        self.scheme, self.host, self.port, self.base_url = _parse_server(
            self.locator.url() if self.locator is not None else str(base_url))
        self.timeout = timeout

    def current(self) -> str:
        """The server address now (auto mode: the locator's; a move is logged without the port's old owner)."""
        if self.locator is None:
            return self.base_url
        url = self.locator.url()
        if url != self.base_url:
            try:
                parts = _parse_server(url)
            except ValueError:
                return self.base_url
            with self._lock:
                self.scheme, self.host, self.port, self.base_url = parts
            _LOG.info("t3 server is on port %d", parts[2])
        return self.base_url

    def _endpoint(self, secret: bool) -> Tuple[str, str, int]:
        self.current()
        with self._lock:
            target = (self.scheme, self.host, self.port, self.base_url)
        if secret and self.locator is not None:
            self._verified(target[3])
        return target[0], target[1], target[2]

    def _verified(self, base_url: str) -> None:
        """Auto mode: is the server at ``base_url`` T3 itself? Its ``/.well-known/t3/environment`` must name T3's
        own environment id (any id when T3's file is missing). Raises ``_Unavailable`` (nothing secret is sent)
        when it is another app (Voyager answers that path with its web page) or nothing answers."""
        expected = self.locator.environment_id() if self.locator is not None else None
        with self._lock:
            known = self._identities.get(base_url)
        if known is not None and time.monotonic() - known[0] < IDENTITY_TTL and expected in (None, known[1]):
            self.environment_id = known[1]
            return
        value = self.request("GET", "/.well-known/t3/environment", timeout=4.0)
        found = value.get("environmentId") if isinstance(value, dict) else None
        if not isinstance(found, str) or not found or (expected is not None and found != expected):
            _LOG.warning("t3: the server at port %d is not T3 Code; the token stays here", self.port)
            raise _Unavailable()
        with self._lock:
            self._identities[base_url] = (time.monotonic(), found)
        self.environment_id = found

    def request(self, method: str, path: str, *, token: Optional[str] = None, form: Optional[Dict[str, str]] = None,
                body: Optional[Dict[str, Any]] = None, timeout: Optional[float] = None) -> Any:
        scheme, host, port = self._endpoint(secret=bool(token) or form is not None)
        headers = {"Accept": "application/json", "Accept-Encoding": "gzip", "User-Agent": "SamRabbit-Bridge/1"}
        data: Optional[bytes] = None
        if token:
            headers["Authorization"] = "Bearer " + token
        if path.startswith("/api/orchestration/"):
            headers[PROTOCOL_HEADER] = ORCHESTRATION_PROTOCOL
        if form is not None:
            data = urlencode(form).encode("utf-8")
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        elif body is not None:
            data = json.dumps(body, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
            headers["Content-Type"] = "application/json"
        wait = timeout if timeout is not None else self.timeout
        if scheme == "https":
            connection: HTTPConnection = HTTPSConnection(host, port, timeout=wait,
                                                         context=ssl.create_default_context())
        else:
            connection = HTTPConnection(host, port, timeout=wait)
        try:
            connection.request(method, path, body=data, headers=headers)
            response = connection.getresponse()
            raw = response.read(MAX_RESPONSE_BYTES + 1)
            status = int(response.status)
            encoding = (response.getheader("Content-Encoding") or "").lower()
        except (OSError, HTTPException, ValueError):
            raise _Unavailable() from None
        finally:
            connection.close()
        if len(raw) > MAX_RESPONSE_BYTES:
            raise _Unavailable()
        if "gzip" in encoding and raw:
            raw = _gunzip(raw)
        value: Any = None
        if raw:
            try:
                value = json.loads(raw.decode("utf-8"))
            except (UnicodeDecodeError, ValueError):
                if status < 400:
                    raise _Unavailable() from None
        if status == 401:
            raise _Unauthorized()
        if status >= 400:
            code = value.get("code") if isinstance(value, dict) else None
            reason = value.get("reason") if isinstance(value, dict) else None
            raise _RequestFailed(status, str(code) if code else None, str(reason) if reason else None)
        return value

    def rpc(self, tag: str, payload: Dict[str, Any], *, token: str, timeout: float = WS_TIMEOUT_SECONDS) -> Any:
        """One call of T3's Effect RPC over ``GET /ws?orchestrationProtocol=2`` (``server.getConfig``,
        ``orchestration.dispatchCommand``, ``orchestration.launchThread``): the bearer token on the upgrade, one
        ``Request``, then the ``Exit`` value. Pings are answered; anything else is ignored. Raises like ``request``
        (401 on the upgrade: ``_Unauthorized``; a ``Failure`` exit: ``_RequestFailed`` with the error's ``_tag`` as
        its reason, e.g. ``OrchestrationV2DispatchCommandError``)."""
        scheme, host, port = self._endpoint(secret=True)
        deadline = time.monotonic() + timeout
        try:
            raw = socket.create_connection((host, port), timeout=timeout)
        except OSError:
            raise _Unavailable() from None
        connection = raw
        try:
            if scheme == "https":
                connection = ssl.create_default_context().wrap_socket(raw, server_hostname=host)
            channel = _WebSocket(connection, deadline)
            channel.handshake(host, port, token)
            channel.send_json({"_tag": "Request", "id": "1", "tag": tag, "payload": payload, "headers": []})
            while True:
                for message in channel.messages():
                    kind = message.get("_tag")
                    if kind == "Ping":
                        channel.send_json({"_tag": "Pong"})
                    elif kind == "Chunk" and message.get("requestId") is not None:
                        channel.send_json({"_tag": "Ack", "requestId": message["requestId"]})
                    elif kind == "Exit" and str(message.get("requestId")) == "1":
                        exit_value = _dict(message.get("exit"))
                        if exit_value.get("_tag") == "Success":
                            return exit_value.get("value")
                        raise _RequestFailed(500, "rpc_failed", _failure_tag(exit_value.get("cause")))
        except (OSError, ValueError, ssl.SSLError):
            raise _Unavailable() from None
        finally:
            try:
                connection.close()
            except OSError:
                pass


class _WebSocket:
    """Just enough of RFC 6455 for one RPC: a client handshake, masked text frames out, (fragmented) frames in."""

    def __init__(self, connection: socket.socket, deadline: float) -> None:
        self.connection = connection
        self.deadline = deadline
        self.buffer = b""

    def _remaining(self) -> float:
        left = self.deadline - time.monotonic()
        if left <= 0:
            raise _Unavailable()
        return left

    def _fill(self, size: int) -> bytes:
        while len(self.buffer) < size:
            self.connection.settimeout(self._remaining())
            chunk = self.connection.recv(65536)
            if not chunk:
                raise _Unavailable()
            self.buffer += chunk
        out, self.buffer = self.buffer[:size], self.buffer[size:]
        return out

    def handshake(self, host: str, port: int, token: str) -> None:
        key = base64.b64encode(os.urandom(16)).decode("ascii")
        shown = f"[{host}]" if ":" in host else host
        request = (f"GET {WS_PATH} HTTP/1.1\r\nHost: {shown}:{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                   f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\nAuthorization: Bearer {token}\r\n"
                   "User-Agent: SamRabbit-Bridge/1\r\n\r\n")
        self.connection.settimeout(self._remaining())
        self.connection.sendall(request.encode("ascii"))
        while b"\r\n\r\n" not in self.buffer:
            if len(self.buffer) > 16 * 1024:
                raise _Unavailable()
            self.connection.settimeout(self._remaining())
            chunk = self.connection.recv(4096)
            if not chunk:
                raise _Unavailable()
            self.buffer += chunk
        head, self.buffer = self.buffer.split(b"\r\n\r\n", 1)
        lines = head.decode("latin-1").split("\r\n")
        parts = lines[0].split(" ")
        status = int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else 0
        if status == 401:
            raise _Unauthorized()
        if status != 101:
            raise _RequestFailed(status or 502, "websocket_refused", None)
        headers = {name.strip().lower(): value.strip() for name, _, value in
                   (line.partition(":") for line in lines[1:])}
        expected = base64.b64encode(hashlib.sha1((key + WS_GUID).encode("ascii")).digest()).decode("ascii")
        if headers.get("sec-websocket-accept") != expected:
            raise _Unavailable()

    def _send(self, opcode: int, data: bytes) -> None:
        head = bytearray([0x80 | opcode])
        if len(data) < 126:
            head.append(0x80 | len(data))
        elif len(data) < 65536:
            head += bytes([0x80 | 126]) + struct.pack(">H", len(data))
        else:
            head += bytes([0x80 | 127]) + struct.pack(">Q", len(data))
        mask = os.urandom(4)
        self.connection.settimeout(self._remaining())
        self.connection.sendall(bytes(head) + mask + bytes(byte ^ mask[index % 4] for index, byte in enumerate(data)))

    def send_json(self, value: Dict[str, Any]) -> None:
        self._send(0x1, json.dumps(value, separators=(",", ":")).encode("utf-8"))

    def messages(self) -> List[Dict[str, Any]]:
        """The next complete text message as JSON objects (Effect RPC may batch several in one array)."""
        message = b""
        while True:
            first, second = self._fill(2)
            opcode, size = first & 0x0F, second & 0x7F
            if size == 126:
                size = struct.unpack(">H", self._fill(2))[0]
            elif size == 127:
                size = struct.unpack(">Q", self._fill(8))[0]
            if size + len(message) > MAX_WS_MESSAGE_BYTES:
                raise _Unavailable()
            mask = self._fill(4) if second & 0x80 else b""  # a server never masks; tolerated anyway
            data = self._fill(size)
            if mask:
                data = bytes(byte ^ mask[index % 4] for index, byte in enumerate(data))
            if opcode == 0x8:
                raise _Unavailable()
            if opcode == 0x9:
                self._send(0xA, data[:125])
                continue
            if opcode == 0xA:
                continue
            message += data
            if first & 0x80:
                break
        value = json.loads(message.decode("utf-8"))
        items = value if isinstance(value, list) else [value]
        return [item for item in items if isinstance(item, dict)]


def _failure_tag(cause: Any) -> Optional[str]:
    """The ``_tag`` of the first error in an Effect ``Cause`` (``[{_tag: Fail, error: {_tag, ...}}]`` or one such
    object), never its message (it can quote thread text)."""
    for item in cause if isinstance(cause, list) else [cause]:
        error = _dict(_dict(item).get("error") or _dict(item).get("defect"))
        if isinstance(error.get("_tag"), str):
            return error["_tag"][:80]
    return None


def _gunzip(raw: bytes) -> bytes:
    decoder = zlib.decompressobj(16 + zlib.MAX_WBITS)
    try:
        out = decoder.decompress(raw, MAX_RESPONSE_BYTES)
    except zlib.error:
        raise _Unavailable() from None
    if decoder.unconsumed_tail:
        raise _Unavailable()
    return out


# --------------------------------------------------------------------------- the token file


def _valid_token(value: Any) -> bool:
    return isinstance(value, str) and 16 <= len(value) <= 4096 and all(0x20 < ord(char) < 0x7F for char in value)


class TokenStore:
    """``t3-token``: ``{token, expiresAt, serverUrl, label, createdAt, sessionId}`` (0600, written atomically,
    re-read when the file changes, e.g. after install.sh paired)."""

    def __init__(self, path: str = DEFAULT_TOKEN_FILE) -> None:
        self.path = os.path.expanduser(path)
        self._lock = threading.Lock()
        self._stamp: Optional[Tuple[int, int, int]] = None
        self._value: Optional[Dict[str, Any]] = None

    def load(self) -> Optional[Dict[str, Any]]:
        try:
            info = os.stat(self.path)
        except OSError:
            with self._lock:
                self._stamp, self._value = None, None
            return None
        stamp = (info.st_mtime_ns, info.st_size, info.st_ino)
        with self._lock:
            if stamp == self._stamp:
                return dict(self._value) if self._value else None
        value: Optional[Dict[str, Any]] = None
        try:
            if info.st_mode & 0o077:
                os.chmod(self.path, 0o600)
            with open(self.path, "r", encoding="utf-8") as handle:
                parsed = json.load(handle)
            if isinstance(parsed, dict) and _valid_token(parsed.get("token")):
                value = parsed
        except (OSError, ValueError):
            value = None
        with self._lock:
            self._stamp, self._value = stamp, value
        return dict(value) if value else None

    def save(self, record: Dict[str, Any]) -> None:
        folder = os.path.dirname(self.path) or "."
        os.makedirs(folder, mode=0o700, exist_ok=True)
        handle, temp = tempfile.mkstemp(prefix=".t3-token.", dir=folder)
        try:
            os.fchmod(handle, 0o600)
            with os.fdopen(handle, "w", encoding="utf-8") as file:
                json.dump(record, file, separators=(",", ":"))
            os.replace(temp, self.path)
        except BaseException:
            try:
                os.unlink(temp)
            except OSError:
                pass
            raise
        self.load()

    def clear(self) -> None:
        try:
            os.unlink(self.path)
        except OSError:
            pass
        self.load()


def session_id_of(token: str) -> Optional[str]:
    """The ``sid`` claim of a T3 access token (``base64url(JSON claims).signature``); not secret on its own."""
    head = token.split(".", 1)[0]
    try:
        claims = json.loads(base64.urlsafe_b64decode(head + "=" * (-len(head) % 4)).decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return None
    sid = claims.get("sid") if isinstance(claims, dict) else None
    return str(sid)[:80] if isinstance(sid, str) and sid else None


# --------------------------------------------------------------------------- the T3 CLI (pairing credentials)


def _child_env() -> Dict[str, str]:
    env = {key: os.environ[key] for key in ("HOME", "USER", "LOGNAME", "LANG", "LC_ALL", "TMPDIR")
           if os.environ.get(key)}
    env.setdefault("HOME", os.path.expanduser("~"))
    env["PATH"] = os.environ.get("PATH") or "/usr/bin:/bin:/usr/sbin:/sbin"
    env["ELECTRON_RUN_AS_NODE"] = "1"  # the app's executable runs the server bundle as plain Node
    return env


def app_parts(app: str) -> Tuple[str, str]:
    """``(executable, app.asar)`` of a T3 Code app bundle (the executable is named after the bundle)."""
    name = os.path.basename(app.rstrip("/"))[:-len(".app")]
    return os.path.join(app, "Contents", "MacOS", name), os.path.join(app, "Contents", "Resources", "app.asar")


def _app_of_pid(pid: Optional[int]) -> Optional[str]:
    """The T3 Code app bundle a process runs from (``ps -o comm=``), or None (not a T3 Code app, or no answer)."""
    if pid is None:
        return None
    try:
        done = subprocess.run(["/bin/ps", "-o", "comm=", "-p", str(int(pid))], stdin=subprocess.DEVNULL,
                              capture_output=True, timeout=5.0)
    except (OSError, subprocess.SubprocessError, ValueError):
        return None
    path = done.stdout.decode("utf-8", errors="replace").strip()
    marker = ".app/Contents/MacOS/"
    if done.returncode != 0 or marker not in path:
        return None
    app = path[:path.index(marker) + len(".app")]
    return app if os.path.basename(app).startswith("T3 Code") else None


def find_app(pid: Optional[int] = None) -> Optional[Tuple[str, str]]:
    """The T3 Code app whose CLI pairs: the one running the live server (``pid``, from its server-runtime.json),
    else the first of ``T3_APPS`` that is installed. ``(executable, app.asar)`` or None."""
    candidates = [app for app in (_app_of_pid(pid),) if app] + list(T3_APPS)
    for app in candidates:
        executable, asar = app_parts(app)
        if os.access(executable, os.X_OK) and os.path.isfile(asar):
            return executable, asar
    return None


class T3Cli:
    """``auth pairing create`` of the CLI inside the T3 Code app. ``choice`` is ``auto`` (the app running T3's
    server, else the first T3 Code app in /Applications: ``find_app``), ``none`` (never pairs: a dev copy of the
    bridge without a CLI path) or the path of an executable that takes the CLI arguments itself (tests)."""

    def __init__(self, choice: Optional[str] = None, *, timeout: float = CLI_TIMEOUT_SECONDS,
                 locator: Optional[ServerLocator] = None) -> None:
        self.choice = (choice or "").strip() or CLI_AUTO
        self.timeout = timeout
        self.locator = locator
        self._found: Optional[Tuple[float, Optional[int], Optional[Tuple[str, str]]]] = None  # (at, pid, app)

    def _app(self) -> Optional[Tuple[str, str]]:
        """``find_app`` for the live server's pid, kept for a minute (``status`` asks on every health check)."""
        if T3_EXECUTABLE and T3_ASAR:
            ok = os.access(T3_EXECUTABLE, os.X_OK) and os.path.isfile(T3_ASAR)
            return (T3_EXECUTABLE, T3_ASAR) if ok else None
        pid = self.locator.pid() if self.locator is not None else None
        known = self._found
        if known is not None and known[1] == pid and time.monotonic() - known[0] < 60.0:
            return known[2]
        found = find_app(pid)
        self._found = (time.monotonic(), pid, found)
        return found

    def command(self) -> Optional[List[str]]:
        if self.choice == CLI_NONE:
            return None
        if self.choice == CLI_AUTO:
            found = self._app()
            return [found[0], found[1] + "/" + T3_SERVER_BIN] if found is not None else None
        path = os.path.expanduser(self.choice)
        return [path] if os.path.isfile(path) and os.access(path, os.X_OK) else None

    def available(self) -> bool:
        return self.command() is not None

    def create_credential(self, base_url: str, label: str) -> str:
        command = self.command()
        if self.choice == CLI_NONE:
            raise T3Error(503, "t3_dev_copy", "This copy of the Mac bridge is not the installed one, so it pairs with "
                          "T3 Code only through an explicit T3 CLI path (--t3-cli).", retryable=False)
        if command is None:
            raise T3Error(503, "t3_app_missing", "The T3 Code app was not found on the Mac, so the bridge can't pair "
                          "with it.", retryable=False)
        args = command + ["auth", "pairing", "create", "--label", label, "--ttl", PAIRING_TTL,
                          "--base-url", base_url, "--json"]
        try:
            process = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                       env=_child_env(), cwd=tempfile.gettempdir(), start_new_session=True)
        except OSError:
            raise T3Error(503, "t3_cli_failed", "The T3 Code CLI could not be started.", retryable=True) from None
        try:
            out, _err = process.communicate(timeout=self.timeout)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except OSError:
                process.kill()
            process.communicate()
            raise T3Error(504, "t3_cli_timeout", "The T3 Code CLI did not answer in time.", retryable=True) from None
        if process.returncode != 0 or len(out) > MAX_CLI_OUTPUT_BYTES:
            raise T3Error(502, "t3_cli_failed", "The T3 Code CLI could not create a pairing link.", retryable=True)
        value = _json_object(out.decode("utf-8", errors="replace"))
        credential = value.get("credential") if isinstance(value, dict) else None
        code = "".join(char for char in str(credential or "") if char.isalnum()).upper()
        if len(code) != 12 or any(char not in PAIRING_ALPHABET for char in code):
            raise T3Error(502, "t3_cli_failed", "The T3 Code CLI answered without a pairing credential.",
                          retryable=True)
        return code


def _json_object(text: str) -> Optional[Dict[str, Any]]:
    """The JSON object in the CLI's output (pretty-printed; may follow warning lines)."""
    stripped = text.strip()
    for candidate in (stripped, stripped[stripped.find("{"):stripped.rfind("}") + 1] if "{" in stripped else ""):
        if not candidate:
            continue
        try:
            value = json.loads(candidate)
        except ValueError:
            continue
        if isinstance(value, dict):
            return value
    return None


# --------------------------------------------------------------------------- the session (auto-pairing)


def _backoff(base: float, ceiling: float, count: int) -> float:
    """``base`` for the first time, doubling for each time in a row after that, at most ``ceiling``."""
    return min(ceiling, base * (2 ** max(0, min(count - 1, 16))))


class T3Session:
    """The bridge's T3 credential: paired on first need, again on expiry or a 401 (single flight, never in a
    loop: see ``token``)."""

    def __init__(self, http: T3Http, store: TokenStore, cli: T3Cli, *, label: str = CLIENT_LABEL,
                 clock: Callable[[], datetime] = _now_utc, monotonic: Callable[[], float] = time.monotonic) -> None:
        self.http = http
        self.store = store
        self.cli = cli
        self.label = label
        self._clock = clock
        self._monotonic = monotonic
        self._lock = threading.Lock()  # held while pairing (single flight)
        self._state_lock = threading.Lock()  # the small fields below that successful calls update
        self._failed: Optional[Tuple[float, float, T3Error]] = None  # (since, seconds, error): no pairing till then
        self._pair_failures = 0  # failed pairings in a row
        self._refusals = 0  # minted tokens T3 refused right away, in a row
        self._paired_at: Deque[float] = deque()  # when this process paired (monotonic), for the hourly cap
        self._minted: Optional[Tuple[float, str]] = None  # (monotonic, token) of this process's last pairing
        self._accepted: Optional[str] = None  # the last token T3 accepted
        self._rejected: Optional[str] = None  # the last token T3 refused (never used again)
        self._last_ok: Optional[str] = None
        self._last_error: Optional[str] = None
        self.pairings = 0  # how many times this process paired (tests, /health)

    # ------------------------------------------------------------------ state
    def _usable(self, record: Optional[Dict[str, Any]]) -> bool:
        """A token that is valid, not refused, not about to expire, and for this server: with a fixed address, the
        one it was paired with; with a discovered one (``T3Http.auto``), any port, since the token belongs to T3's
        auth store and the server is checked to be T3 before the token goes out."""
        if not record or not _valid_token(record.get("token")) or record.get("token") == self._rejected:
            return False
        if not self.http.auto and record.get("serverUrl") and \
                str(record["serverUrl"]).rstrip("/") != self.http.base_url:
            return False  # paired with another server
        expires = parse_time(record.get("expiresAt"))
        return expires is None or expires - self._clock() > REPAIR_BEFORE_EXPIRY

    def status(self) -> Dict[str, Any]:
        record = self.store.load()
        paired = self._usable(record)
        with self._state_lock:
            last_ok, last_error = self._last_ok, self._last_error
        value = {"paired": paired, "ok": paired and last_error is None, "expiresAt": (record or {}).get("expiresAt"),
                 "serverUrl": self.http.current(), "lastOkAt": last_ok, "lastError": last_error,
                 "cli": self.cli.available()}
        failed = self._failed
        if failed is not None and not paired:
            left = failed[1] - (self._monotonic() - failed[0])
            if left > 0:
                value["nextPairingInSeconds"] = int(left)
        return value

    def note_ok(self) -> None:
        with self._state_lock:
            self._last_ok = iso_utc(self._clock())
            self._last_error = None

    def note_error(self, code: str) -> None:
        with self._state_lock:
            self._last_error = code

    # ------------------------------------------------------------------ tokens
    def token(self, *, rejected: Optional[str] = None, force: bool = False) -> str:
        """A usable token, pairing when there is none. ``rejected`` is a token T3 just refused (see ``_refused``):
        pair again unless another request already replaced it.

        Pairing never runs in a loop (each one is an Electron CLI run and a new "SamRabbit bridge" session in T3):
        while a back-off is on, this raises its error without pairing (unless ``force``, install.sh). A failed
        pairing waits ``PAIR_BACKOFF_SECONDS`` (doubling up to ``PAIR_BACKOFF_MAX_SECONDS``); a refused fresh token
        waits ``REFUSED_BACKOFF_SECONDS`` (doubling up to an hour); and at most ``MAX_PAIRINGS_PER_HOUR``
        pairings happen in any hour."""
        with self._lock:
            if rejected is not None:
                self._refused(rejected)
            record = self.store.load()
            if self._usable(record):
                return str(record["token"])
            now = self._monotonic()
            failed = self._failed
            if failed is not None and not force and now - failed[0] < failed[1]:
                raise failed[2]
            while self._paired_at and now - self._paired_at[0] >= 3600.0:
                self._paired_at.popleft()
            if not force and len(self._paired_at) >= MAX_PAIRINGS_PER_HOUR:
                wait = max(60.0, 3600.0 - (now - self._paired_at[0]))
                code = failed[2].code if failed is not None else "t3_unauthorized"
                error = T3Error(502, code, "The bridge tried to pair with T3 Code too often in the last hour; it tries "
                                f"again in about {int(wait // 60) or 1} minutes.", retryable=True)
                self._failed = (now, wait, error)
                self.note_error(error.code)
                _LOG.warning("t3 pairing paused: %d pairings in the last hour", len(self._paired_at))
                raise error
            self._paired_at.append(now)
            try:
                token = self._pair()
            except T3Error as error:
                self._pair_failures += 1
                self._failed = (self._monotonic(), _backoff(PAIR_BACKOFF_SECONDS, PAIR_BACKOFF_MAX_SECONDS,
                                                            self._pair_failures), error)
                self.note_error(error.code)
                raise
            self._pair_failures = 0
            self._minted = (self._monotonic(), token)
            return token

    def _refused(self, token: str) -> None:
        """T3 answered 401 to ``token`` (call with ``_lock`` held). An older token (revoked, expired, or one
        install.sh wrote) is simply replaced by the next ``token()``. A token this process minted that T3 refuses
        before it ever worked, or within ``FRESH_TOKEN_SECONDS`` of minting, means T3 is not taking the bridge's
        credentials right now: pairing again would only pile up sessions, so the next pairing waits
        ``REFUSED_BACKOFF_SECONDS``, doubling each time this happens again (up to an hour)."""
        if self._rejected == token:
            return  # already counted (several requests were refused with the same token)
        self._rejected = token
        minted = self._minted
        if minted is None or minted[1] != token:
            return
        now = self._monotonic()
        with self._state_lock:
            worked = self._accepted == token
            if worked and now - minted[0] >= FRESH_TOKEN_SECONDS:
                return  # it worked for a while, then was revoked: pairing again is the fix
            self._refusals += 1
            refusals = self._refusals
        wait = _backoff(REFUSED_BACKOFF_SECONDS, REFUSED_BACKOFF_MAX_SECONDS, refusals)
        minutes = int(wait // 60)
        self._failed = (now, wait, T3Error(502, "t3_unauthorized", "T3 Code refused the bridge's new credential. "
                                           f"The bridge pairs with it again in about {minutes} minutes.",
                                           retryable=True))
        self.note_error("t3_unauthorized")
        _LOG.warning("t3 refused the bridge's new token; next pairing in %d min", minutes)

    def _worked(self, token: str) -> None:
        """T3 accepted ``token``. Once a token has kept working past ``FRESH_TOKEN_SECONDS``, earlier refusals no
        longer count towards the next back-off."""
        with self._state_lock:
            self._accepted = token
            if self._refusals:
                minted = self._minted
                if minted is None or minted[1] != token or self._monotonic() - minted[0] >= FRESH_TOKEN_SECONDS:
                    self._refusals = 0

    def _pair(self) -> str:
        try:
            self.http._endpoint(secret=True)  # noqa: SLF001 - a discovered server must be T3 before T3's CLI runs
        except _Unavailable:
            raise unavailable() from None
        credential = self.cli.create_credential(self.http.base_url, self.label)
        form = {"grant_type": GRANT_TYPE, "subject_token": credential, "subject_token_type": SUBJECT_TOKEN_TYPE,
                "requested_token_type": ACCESS_TOKEN_TYPE, "scope": REQUESTED_SCOPES, "client_label": self.label,
                "client_device_type": "bot", "client_os": "macos"}
        try:
            value = self.http.request("POST", "/oauth/token", form=form)
        except _Unauthorized:
            raise T3Error(502, "t3_pairing_rejected", "T3 Code did not accept the bridge's pairing credential.",
                          retryable=True) from None
        except _RequestFailed:
            raise T3Error(502, "t3_pairing_rejected", "T3 Code refused to pair with the bridge.",
                          retryable=True) from None
        except _Unavailable:
            raise unavailable() from None
        token = value.get("access_token") if isinstance(value, dict) else None
        if not _valid_token(token):
            raise T3Error(502, "t3_pairing_rejected", "T3 Code answered the pairing without a token.", retryable=True)
        now = self._clock()
        expires_at: Optional[str] = None
        if isinstance(value.get("expires_in"), (int, float)) and not isinstance(value.get("expires_in"), bool):
            expires_at = iso_utc(now + timedelta(seconds=float(value["expires_in"])))
        try:
            session = self.http.request("GET", "/api/auth/session", token=str(token), timeout=4.0)
            if isinstance(session, dict) and normal_time(session.get("expiresAt")):
                expires_at = normal_time(session.get("expiresAt"))
        except (_Unavailable, _Unauthorized, _RequestFailed):
            pass
        self.store.save({"token": token, "expiresAt": expires_at, "serverUrl": self.http.base_url,
                         "label": self.label, "createdAt": iso_utc(now), "sessionId": session_id_of(str(token))})
        self._failed = None
        self.pairings += 1
        _LOG.info("t3 paired (expires %s)", (expires_at or "unknown")[:10])
        return str(token)

    def ensure_paired(self) -> Dict[str, Any]:
        """install.sh: pair now when there is no usable token (never when there is one)."""
        self.token(force=True)
        return self.status()

    def call(self, request: Callable[[str], Any]) -> Any:
        """Run ``request(token)``; on a 401, pair again once and repeat (``token`` decides whether pairing is
        allowed right now). Maps transport failures to T3Error."""
        token = self.token()
        for attempt in (1, 2):
            try:
                value = request(token)
            except _Unauthorized:
                if attempt == 2:
                    with self._lock:
                        self._refused(token)  # usually the token minted a moment ago: back off
                    self.note_error("t3_unauthorized")
                    raise T3Error(502, "t3_unauthorized", "T3 Code keeps refusing the bridge's credential.",
                                  retryable=True) from None
                _LOG.info("t3 rejected the bridge's token")
                token = self.token(rejected=token)
                continue
            except _Unavailable:
                self.note_error("t3_unavailable")
                raise unavailable() from None
            except _RequestFailed as failure:
                self.note_error("t3_request_failed")
                if failure.status == 404:
                    raise T3Error(404, "t3_thread_not_found", "That T3 thread was not found.") from None
                raise T3Error(502, "t3_request_failed", f"T3 Code answered HTTP {failure.status}.",
                              retryable=failure.status >= 500) from None
            self._worked(token)
            self.note_ok()
            return value
        raise unavailable()  # pragma: no cover - the loop always returns or raises


# --------------------------------------------------------------------------- status (port of status.py)

NEEDS_APPROVAL = "needs-approval"
NEEDS_INPUT = "needs-input"
WORKING = "working"
ERROR = "error"
DONE = "done"
STATUS_ORDER = {NEEDS_APPROVAL: 0, NEEDS_INPUT: 1, WORKING: 2, ERROR: 3, DONE: 4}
NEEDS_YOU = frozenset({NEEDS_APPROVAL, NEEDS_INPUT})
# The phone's names (CONTRACTS-WAVE4): idle is a thread that never ran a turn.
MOBILE_STATUS = {NEEDS_APPROVAL: "needs_approval", NEEDS_INPUT: "needs_input", WORKING: "working", ERROR: "error",
                 DONE: "done"}
MOBILE_NEEDS_YOU = frozenset({"needs_approval", "needs_input"})
MOBILE_RECENT = frozenset({"done", "error", "idle"})
DEFAULT_APPROVAL_OPTIONS = (
    {"decision": "accept", "label": "Approve"},
    {"decision": "acceptForSession", "label": "Always allow this session"},
    {"decision": "decline", "label": "Decline"},
    {"decision": "cancel", "label": "Cancel"},
)
_REQUEST_KIND_BY_TYPE = {
    "command_execution_approval": "command", "exec_command_approval": "command", "dynamic_tool_call": "command",
    "file_read_approval": "file-read", "file_change_approval": "file-change", "apply_patch_approval": "file-change",
    "mcp_elicitation_approval": "mcp-elicitation", "permission_approval": "permission",
}
_REQUEST_KINDS = frozenset({"command", "file-read", "file-change", "mcp-elicitation", "permission"})
_APPROVAL_TEXT = {
    "command": "Wants to run a command", "file-change": "Wants to edit files", "file-read": "Wants to read files",
    "permission": "Is asking for a permission", "mcp-elicitation": "Wants approval for a tool request",
}


def _dict(value: Any) -> Dict[str, Any]:
    return value if isinstance(value, dict) else {}


def _text(value: Any) -> Optional[str]:
    return value.strip() if isinstance(value, str) and value.strip() else None


# --------------------------------------------------------------------------- v2 thread shells, as the bridge reads them

ACTIVE_RUN = frozenset({"preparing", "queued", "starting", "running", "waiting"})
_RUN_STATE = {"completed": "completed", "idle": "completed", "rolled_back": "completed", "failed": "error",
              "interrupted": "interrupted", "cancelled": "interrupted"}
_NOT_APPROVALS = frozenset({"user_input", "auth_refresh", "dynamic_tool_call"})  # T3 answers these itself


def is_subagent(shell: Dict[str, Any]) -> bool:
    return _dict(shell.get("lineage")).get("relationshipToParent") == "subagent"


def _holding_tasks(shell: Dict[str, Any]) -> List[Dict[str, Any]]:
    """Background work the agent waits on (T3's ``backgroundWorkHoldsCompletion``): subagents and background tasks,
    or anything marked awaited. Commands and monitors left running (a dev server) do not hold a thread."""
    return [task for task in shell.get("pendingBackgroundTasks") or [] if isinstance(task, dict)
            and (task.get("awaited") is True or task.get("kind") in ("subagent", "background_task"))]


def _runtime_status(shell: Dict[str, Any]) -> Optional[str]:
    """T3's ``shellRuntime(...).status``: None for a thread that never ran, ``idle`` while background work holds it,
    else the activity run's status (the latest run's when there is none)."""
    park = bool(_holding_tasks(shell)) and shell.get("status") != "failed"
    if shell.get("latestRunId") is None and shell.get("activeProviderThreadId") is None and not park:
        return None
    return "idle" if park else str(shell.get("activityRunStatus") or shell.get("status") or "idle")


def subagent_requests(shells: Iterable[Dict[str, Any]]) -> Dict[str, Tuple[str, List[str]]]:
    """Open requests of app-owned subagent threads, on each of their parents (T3's ``pendingSubagentRequestsByThread``:
    a provider-native subagent asks on its parent itself; a child whose run ended no longer holds its parent):
    ``{parent id: ("approval" | "user_input", [child ids])}``, approval winning."""
    by_id = {str(shell.get("id")): shell for shell in shells if isinstance(shell, dict) and shell.get("id")}
    found: Dict[str, Tuple[str, List[str]]] = {}
    for child_id, child in by_id.items():
        kind = _dict(child.get("pendingRuntimeRequest")).get("kind")
        live = child.get("activityRunStatus") is not None if "activityRunStatus" in child else \
            child.get("status") in ("preparing", "starting", "running", "waiting")
        if not kind or kind == "auth_refresh" or not is_subagent(child) or child.get("creationSource") == "provider" \
                or not live:
            continue
        need = "user_input" if kind == "user_input" else "approval"
        seen = {child_id}
        current: Optional[Dict[str, Any]] = child
        while current is not None and is_subagent(current):
            parent = _dict(current.get("lineage")).get("parentThreadId")
            if not isinstance(parent, str) or parent in seen:
                break
            seen.add(parent)
            known = found.get(parent)
            found[parent] = ("approval" if known and known[0] == "approval" else need,
                             (known[1] if known else []) + [child_id])
            current = by_id.get(parent)
    return found


def bridge_thread(shell: Dict[str, Any], subagent: Optional[Tuple[str, List[str]]] = None) -> Dict[str, Any]:
    """A v2 thread shell (``OrchestrationV2ThreadShell``) with the fields the bridge's status code reads, derived as
    T3's own ``presentThreadShell`` does:

    * ``hasPendingApprovals`` / ``hasPendingUserInput`` from ``pendingRuntimeRequest`` (an async question only while
      the run is not working) or an app-owned subagent's request (``subagent``; its children in
      ``pendingChildThreadIds``);
    * ``session`` (``{threadId, status: starting|running|ready|error, activeTurnId, lastError, providerName,
      updatedAt}``) from the runtime: preparing / starting / a queued run with an active run id are ``starting``,
      running / waiting are ``running``, failed is ``error``; ``activeTurnId`` is the active run's id; ``updatedAt``
      the failed run's end (a shell's ``updatedAt`` moves with T3's own bookkeeping);
    * ``latestTurn`` (``{turnId, state: running|completed|error|interrupted, requestedAt, startedAt, completedAt}``)
      from ``latestRun*``; ``backgroundLiveness`` (``working`` / ``monitoring``) while background work holds it;
      ``planProgress`` None (only a thread's detail has its task list).

    Everything else is the shell's own (``settledAt``, ``snoozedUntil``, ``latestUserMessageAt``, ``modelSelection``,
    ``runtimeMode``, ...)."""
    value = dict(shell)
    thread_id = str(shell.get("id") or "")
    runtime = _runtime_status(shell)
    active_id = shell.get("activeRunId")
    if runtime is None:
        session: Optional[Dict[str, Any]] = None
    else:
        if runtime in ("preparing", "starting") or (runtime == "queued" and active_id):
            state = "starting"
        elif runtime in ("running", "waiting"):
            state = "running"
        elif runtime == "failed":
            state = "error"
        else:
            state = "ready"
        session = {"threadId": thread_id, "status": state,
                   "activeTurnId": str(active_id) if active_id and state in ("starting", "running") else None,
                   "lastError": _text(shell.get("lastError")) if state == "error" else None, "providerName": None,
                   "updatedAt": shell.get("latestRunCompletedAt") if state == "error" else None}
    status = str(shell.get("status") or "idle")
    latest: Optional[Dict[str, Any]] = None
    if shell.get("latestRunId"):
        turn_state = _RUN_STATE.get(status, "running")
        completed = None
        if turn_state != "running":
            completed = shell.get("latestRunCompletedAt") if "latestRunCompletedAt" in shell else \
                shell.get("updatedAt")
        latest = {"turnId": str(shell["latestRunId"]), "state": turn_state,
                  "requestedAt": shell.get("latestRunRequestedAt"), "startedAt": shell.get("latestRunStartedAt"),
                  "completedAt": completed}
    elif shell.get("historyOrigin") == "v1_import" or (isinstance(shell.get("itemCount"), int)
                                                       and shell["itemCount"] > 0):
        # History from before protocol 2 (or another client) without a v2 run: finished, not new.
        latest = {"turnId": None, "state": "completed", "requestedAt": None, "startedAt": None,
                  "completedAt": _dict(shell.get("latestVisibleMessage")).get("updatedAt")
                  or shell.get("latestUserMessageAt") or shell.get("updatedAt")}
    request = _dict(shell.get("pendingRuntimeRequest"))
    kind = request.get("kind")
    working_now = runtime in ("preparing", "starting", "running")
    holding = _holding_tasks(shell) if runtime == "idle" else []
    value.update({
        "session": session, "latestTurn": latest, "planProgress": None,
        "hasPendingApprovals": bool(kind) and kind not in _NOT_APPROVALS
        or (subagent is not None and subagent[0] == "approval"),
        "hasPendingUserInput": (kind == "user_input" and (request.get("blocking") is not False or not working_now))
        or (subagent is not None and subagent[0] == "user_input"),
        "pendingChildThreadIds": list(subagent[1]) if subagent is not None else [],
        "backgroundLiveness": None if not holding else
        "monitoring" if all(task.get("kind") == "monitor" for task in holding) else "working",
    })
    return value


def shell_of_projection(projection: Dict[str, Any]) -> Dict[str, Any]:
    """A thread shell built from a thread's projection (``OrchestrationV2ThreadProjection``), for a thread the shell
    snapshot does not have yet: its latest and active runs, its first open request, its latest user message."""
    thread = dict(_dict(projection.get("thread")))
    runs = sorted((run for run in projection.get("runs") or [] if isinstance(run, dict)),
                  key=lambda run: run.get("ordinal") if isinstance(run.get("ordinal"), int) else 0)
    latest = runs[-1] if runs else None
    active = next((run for run in reversed(runs) if run.get("status") in ACTIVE_RUN), None)
    request = next((item for item in projection.get("runtimeRequests") or [] if isinstance(item, dict)
                    and item.get("status") == "pending" and item.get("kind") != "auth_refresh"), None)
    users = [str(message.get("createdAt")) for message in projection.get("messages") or []
             if isinstance(message, dict) and message.get("role") == "user" and message.get("createdAt")]
    failure = next((_dict(item.get("failure")).get("message") for item in reversed(projection.get("turnItems") or [])
                    if isinstance(item, dict) and item.get("type") == "error"), None)
    thread.update({
        "status": str(latest.get("status")) if latest else "idle",
        "latestRunId": latest.get("id") if latest else None,
        "latestRunRequestedAt": latest.get("requestedAt") if latest else None,
        "latestRunStartedAt": latest.get("startedAt") if latest else None,
        "latestRunCompletedAt": latest.get("completedAt") if latest else None,
        "activeRunId": active.get("id") if active else None,
        "activityRunStatus": active.get("status") if active else None,
        "pendingRuntimeRequest": {"id": request.get("id"), "kind": request.get("kind"),
                                  "createdAt": request.get("createdAt")} if request else None,
        "latestUserMessageAt": max(users, key=lambda stamp: parse_time(stamp) or datetime.min.replace(
            tzinfo=timezone.utc)) if users else None,
        "lastError": failure if latest and latest.get("status") == "failed" else None,
        "pendingBackgroundTasks": [],
    })
    return thread


def is_settled(thread: Dict[str, Any]) -> bool:
    return thread.get("settledAt") is not None and thread.get("settledOverride") != "active"


def is_snoozed(thread: Dict[str, Any], now: datetime) -> bool:
    until = parse_time(thread.get("snoozedUntil"))
    return until is not None and until > now


def raw_status(thread: Dict[str, Any]) -> str:
    session = _dict(thread.get("session"))
    latest = _dict(thread.get("latestTurn"))
    if thread.get("hasPendingApprovals") is True:
        return NEEDS_APPROVAL
    if thread.get("hasPendingUserInput") is True:
        return NEEDS_INPUT
    if session.get("status") in ("running", "starting"):
        return WORKING
    if session.get("status") == "error":
        return ERROR
    if thread.get("backgroundLiveness") in ("working", "monitoring"):
        return WORKING
    if latest.get("state") == "error":
        return ERROR
    return DONE


def thread_status(thread: Dict[str, Any]) -> str:
    status = raw_status(thread)
    return DONE if status == ERROR and is_settled(thread) else status


def status_label(thread: Dict[str, Any], status: str) -> str:
    session = _dict(thread.get("session"))
    latest = _dict(thread.get("latestTurn"))
    if status == NEEDS_APPROVAL:
        return "Needs approval"
    if status == NEEDS_INPUT:
        return "Has a question"
    if status == WORKING:
        progress = _dict(thread.get("planProgress"))
        total, done = progress.get("totalSteps"), progress.get("completedSteps")
        if session.get("status") == "starting":
            return "Starting"
        if session.get("status") != "running" and thread.get("backgroundLiveness") == "monitoring":
            return "Monitoring"
        if session.get("status") != "running" and thread.get("backgroundLiveness") == "working":
            return "Background work"
        if isinstance(total, int) and isinstance(done, int) and total > 0:
            return f"Step {min(done + 1, total)} of {total}"
        return "Working"
    if status == ERROR:
        return "Failed"
    if not latest:
        return "New"
    if latest.get("state") == "interrupted":
        return "Stopped"
    return "Done"


def plan_phase(thread: Dict[str, Any]) -> Tuple[Optional[str], Optional[float]]:
    progress = _dict(thread.get("planProgress"))
    step = _text(progress.get("step"))
    total, done = progress.get("totalSteps"), progress.get("completedSteps")
    fraction = None
    if isinstance(total, int) and isinstance(done, int) and total > 0:
        fraction = round(max(0.0, min(1.0, done / total)), 3)
    return (step[:80] if step else None), fraction


def plan_progress(plans: Any) -> Optional[Dict[str, Any]]:
    """A thread's ``planProgress`` (``{step, completedSteps, totalSteps}``) from its active task list (the last
    ``todo_list`` plan that is ``active`` in its detail's ``plans``): the running step, else the next one."""
    lists = [plan for plan in plans if isinstance(plan, dict) and plan.get("kind") == "todo_list"
             and plan.get("status") == "active"] if isinstance(plans, list) else []
    steps = [step for step in (lists[-1].get("steps") if lists else None) or [] if isinstance(step, dict)]
    if not steps:
        return None
    current = next((step for step in steps if step.get("status") == "running"), None) or \
        next((step for step in steps if step.get("status") == "pending"), None)
    return {"step": _text(_dict(current).get("text")), "totalSteps": len(steps),
            "completedSteps": sum(1 for step in steps if step.get("status") == "completed")}


def activity_time(thread: Dict[str, Any]) -> str:
    latest = _dict(thread.get("latestTurn"))
    best: Optional[Tuple[datetime, str]] = None
    for value in (latest.get("completedAt"), latest.get("startedAt"), latest.get("requestedAt"),
                  thread.get("latestUserMessageAt"), thread.get("createdAt")):
        parsed = parse_time(value)
        if parsed is not None and (best is None or parsed > best[0]):
            best = (parsed, str(value))
    return best[1] if best is not None else str(thread.get("updatedAt") or "")


def summary_time(thread: Dict[str, Any], status: str) -> str:
    if status in NEEDS_YOU:
        return str(thread.get("updatedAt") or activity_time(thread))
    return activity_time(thread)


def condense(text: Optional[str], limit: int) -> str:
    if not text:
        return ""
    flat = " ".join(str(text).replace("```", " ").split())
    if len(flat) <= limit:
        return flat
    cut = flat[:max(1, limit - 1)]
    space = cut.rfind(" ")
    if space > limit * 0.6:
        cut = cut[:space]
    return cut.rstrip(" ,;:-") + "…"


def mobile_status(thread: Dict[str, Any]) -> str:
    status = thread_status(thread)
    if status == DONE and not _dict(thread.get("latestTurn")):
        return "idle"
    return MOBILE_STATUS[status]


# Seen markers (port of status.py ``completed_at``/``unread_marker``/``seen_marker``/``is_unread``): a thread is unread
# when its marker is newer than the one stored when Samin last looked at it (the desktop inbox keeps them).


def completed_at(thread: Dict[str, Any]) -> Optional[str]:
    latest = _dict(thread.get("latestTurn"))
    if latest.get("state") in ("completed", "error", "interrupted"):
        value = latest.get("completedAt")
        return str(value) if value else None
    return None


def unread_marker(thread: Dict[str, Any], status: str) -> Optional[str]:
    """Compared against the stored seen marker; None means never unread (a thread that is working)."""
    if status == WORKING:
        return None
    if status in NEEDS_YOU:
        return str(thread.get("updatedAt") or "") or None
    return completed_at(thread)


def seen_marker(thread: Dict[str, Any]) -> str:
    """Stored when Samin looks at a thread (covers both done and needs-you): the later of completedAt and updatedAt."""
    parsed = [(parse_time(value), str(value)) for value in (completed_at(thread), thread.get("updatedAt")) if value]
    stamped = [item for item in parsed if item[0] is not None]
    return max(stamped, key=lambda item: item[0])[1] if stamped else ""


def is_unread(marker: Optional[str], seen: Optional[str]) -> bool:
    if not marker:
        return False
    if not seen:
        return True
    marker_time, seen_time = parse_time(marker), parse_time(seen)
    if marker_time is None or seen_time is None:
        return marker != seen
    return marker_time > seen_time


@dataclass(frozen=True)
class PendingApproval:
    request_id: str
    kind: str
    detail: Optional[str]
    options: Tuple[Dict[str, str], ...]
    created_at: str
    thread_id: Optional[str] = None  # the subagent thread that asked, when not the thread itself


@dataclass(frozen=True)
class PendingQuestion:
    question_id: str
    header: str
    question: str
    options: Tuple[str, ...]
    allow_custom: bool
    multi_select: bool
    values: Tuple[str, ...] = ()  # what T3 expects for each option: option.value ?? option.label

    def answer_value(self, index: int) -> str:
        return self.values[index] if index < len(self.values) else self.options[index]


@dataclass(frozen=True)
class PendingInput:
    request_id: str
    questions: Tuple[PendingQuestion, ...]
    dismissible: bool
    created_at: str
    thread_id: Optional[str] = None  # the subagent thread that asked, when not the thread itself


@dataclass(frozen=True)
class PendingRequests:
    approvals: Tuple[PendingApproval, ...] = ()
    inputs: Tuple[PendingInput, ...] = ()
    unmatched: int = 0  # open requests whose question or approval item is older than the detail's window

    @property
    def count(self) -> int:
        return len(self.approvals) + len(self.inputs)

    def asked_by(self, thread_id: str) -> "PendingRequests":
        """The same requests, each marked as asked by ``thread_id`` (a subagent of the thread being answered)."""
        return PendingRequests(tuple(PendingApproval(item.request_id, item.kind, item.detail, item.options,
                                                     item.created_at, thread_id) for item in self.approvals),
                               tuple(PendingInput(item.request_id, item.questions, item.dismissible, item.created_at,
                                                  thread_id) for item in self.inputs), self.unmatched)


def _questions(value: Any) -> Tuple[PendingQuestion, ...]:
    result = []
    for raw in value if isinstance(value, list) else []:
        if not isinstance(raw, dict) or not isinstance(raw.get("options"), list):
            continue
        kept = [option for option in raw["options"] if isinstance(option, dict) and isinstance(option.get("label"), str)]
        options = tuple(str(option["label"]) for option in kept)
        values = tuple(str(option["value"]) if isinstance(option.get("value"), str) else str(option["label"])
                       for option in kept)
        allow_custom = raw.get("allowCustomAnswer") is not False
        if (not options and not allow_custom) or not all(isinstance(raw.get(key), str)
                                                         for key in ("id", "header", "question")):
            continue
        result.append(PendingQuestion(str(raw["id"]), str(raw["header"]), str(raw["question"]), options,
                                      allow_custom, raw.get("multiSelect") is True, values))
    return tuple(result)


def pending_requests(thread: Any) -> PendingRequests:
    """Mirror of T3 ``derivePendingThreadRequests`` (packages/client-runtime/src/state/threadRequests.ts): the
    thread's ``runtimeRequests`` that are still ``pending``, each with its turn item (``user_input_request``: the
    questions; ``approval_request``: ``prompt`` and ``options``). Auth refreshes and dynamic tool calls are T3's own
    business; a question whose item is not in ``turnItems`` (older than a bounded detail's window) is counted in
    ``unmatched`` so the caller can read the whole thread. ``thread``: a detail's ``thread`` (``T3Hub.detail``) or a
    projection."""
    source = _dict(thread)
    approval_items: Dict[str, Dict[str, Any]] = {}
    input_items: Dict[str, Dict[str, Any]] = {}
    for item in source.get("turnItems") or []:
        if isinstance(item, dict) and isinstance(item.get("requestId"), str):
            if item.get("type") == "approval_request":
                approval_items[item["requestId"]] = item  # the last one wins, as T3's findLast
            elif item.get("type") == "user_input_request":
                input_items[item["requestId"]] = item
    approvals: List[PendingApproval] = []
    inputs: List[PendingInput] = []
    unmatched = 0
    for request in source.get("runtimeRequests") or []:
        if not isinstance(request, dict) or request.get("status") != "pending":
            continue
        request_id = request.get("id")
        if not isinstance(request_id, str) or not request_id:
            continue
        kind = request.get("kind")
        created = str(request.get("createdAt") or "")
        capability = _dict(request.get("responseCapability")).get("type")
        if kind == "user_input":
            item = input_items.get(request_id)
            if item is None:
                unmatched += 1
                continue
            questions = _questions(item.get("questions"))
            if questions:
                inputs.append(PendingInput(request_id, questions,
                                           item.get("responseMode") == "message" or capability == "message", created))
            continue
        if kind in _NOT_APPROVALS:
            continue
        item = approval_items.get(request_id) or {}
        request_kind = kind if kind in _REQUEST_KINDS else _REQUEST_KIND_BY_TYPE.get(str(kind), "command")
        options = tuple({"decision": str(option["decision"]), "label": str(option["label"])}
                        for option in item.get("options") or []
                        if isinstance(option, dict) and option.get("decision") in APPROVAL_DECISIONS
                        and isinstance(option.get("label"), str))
        approvals.append(PendingApproval(request_id, str(request_kind),
                                         _text(item.get("prompt")) or _text(item.get("reason")),
                                         options or DEFAULT_APPROVAL_OPTIONS, created))
    return PendingRequests(tuple(sorted(approvals, key=lambda item: item.created_at)),
                           tuple(sorted(inputs, key=lambda item: item.created_at)), unmatched)


def pending_view(pending: PendingRequests) -> Optional[Dict[str, Any]]:
    """The first open request as the phone shows it: ``{kind: approval|question, text, options?, ...}``."""
    if pending.approvals:
        approval = pending.approvals[0]
        return {"kind": "approval", "requestId": approval.request_id, "requestKind": approval.kind,
                "text": condense(approval.detail, 400) or _APPROVAL_TEXT.get(approval.kind, "Needs your approval"),
                "options": [dict(option) for option in approval.options]}
    if pending.inputs:
        request = pending.inputs[0]
        first = request.questions[0]
        return {"kind": "question", "requestId": request.request_id, "questionId": first.question_id,
                "header": first.header, "text": condense(first.question, 600), "options": list(first.options),
                "allowCustom": first.allow_custom, "multiSelect": first.multi_select,
                "questions": [{"id": item.question_id, "header": item.header, "text": condense(item.question, 600),
                               "options": list(item.options), "allowCustom": item.allow_custom,
                               "multiSelect": item.multi_select} for item in request.questions]}
    return None


def resolve_answers(request: PendingInput, answers: Dict[str, Any]) -> Dict[str, Any]:
    """Map tapped or typed answers onto option values; free text only when allowed (port of service.py)."""
    resolved: Dict[str, Any] = {}
    for question in request.questions:
        raw = answers.get(question.question_id)
        if raw is None and len(request.questions) == 1 and len(answers) == 1:
            raw = next(iter(answers.values()))
        if raw is None:
            raise T3Error(400, "invalid_request", f"Answer the question “{condense(question.question, 80)}”.")
        values = raw if isinstance(raw, list) else [raw]
        picked = [_pick_option(question, str(value)) for value in values if str(value).strip()]
        if not picked:
            raise T3Error(400, "invalid_request", f"Answer the question “{condense(question.question, 80)}”.")
        if question.multi_select and not request.dismissible:
            resolved[question.question_id] = picked
        else:
            resolved[question.question_id] = ", ".join(picked) if len(picked) > 1 else picked[0]
    return resolved


_ORDINALS = {"first": 0, "second": 1, "third": 2, "fourth": 3, "fifth": 4}


def _pick_option(question: PendingQuestion, value: str) -> str:
    """The value T3 expects for one answer: ``option.value ?? option.label``, or free text (port of service.py)."""
    text = " ".join(value.split())
    options = list(question.options)
    lowered = text.lower().strip(" .!")
    for index, option in enumerate(options):
        if option.lower() == lowered or question.answer_value(index).lower() == lowered:
            return question.answer_value(index)
    numeric_labels = any(option.strip().isdigit() for option in options)
    if lowered.isdigit() and not numeric_labels and 1 <= int(lowered) <= len(options):
        return question.answer_value(int(lowered) - 1)
    # "the first one", "second option" (dictated on the watch) pick by position, as on the R1.
    for word, index in _ORDINALS.items():
        if index < len(options) and lowered in {word, f"the {word}", f"{word} one", f"the {word} one",
                                                f"{word} option", f"the {word} option"}:
            return question.answer_value(index)
    shortened = [index for index, option in enumerate(options) if lowered and lowered in option.lower()]
    if len(shortened) == 1:
        return question.answer_value(shortened[0])
    if question.allow_custom:
        return text
    containing = [index for index, option in enumerate(options) if option.lower() in lowered]
    if len(containing) == 1:
        return question.answer_value(containing[0])
    raise T3Error(400, "invalid_request", "Choose one of: " + "; ".join(options) + ".")


# --------------------------------------------------------------------------- commands (port of commands.py)


class CommandBuilder:
    """Orchestration v2 shapes (``OrchestrationV2Command`` for ``orchestration.dispatchCommand``,
    ``OrchestrationV2ThreadLaunchInput`` for ``orchestration.launchThread``), as T3's own clients build them
    (packages/client-runtime/src/operations/commands.ts). Every command gets a fresh UUIDv4 ``commandId``: T3 keeps a
    receipt per command id, so a retry with the same command is answered with the first result."""

    def __init__(self, *, new_id: Callable[[], str] = lambda: str(uuid.uuid4())) -> None:
        self.new_id = new_id

    def launch(self, *, thread_id: str, project_id: str, title: str, text: str, model_selection: Dict[str, Any],
               runtime_mode: str, interaction_mode: str = DEFAULT_INTERACTION_MODE) -> Dict[str, Any]:
        """A new thread and its first message in one call, in the project's own folder (``root``); T3 names it from
        the message (``generateTitle``; ``title`` stands until then)."""
        return {"commandId": self.new_id(), "creationSource": CREATION_SOURCE, "threadId": thread_id,
                "projectId": project_id, "title": title, "generateTitle": True,
                "modelSelection": dict(model_selection), "runtimeMode": runtime_mode,
                "interactionMode": interaction_mode, "workspaceStrategy": {"type": "root"},
                "initialMessage": {"messageId": self.new_id(), "text": text, "attachments": []}}

    def message(self, *, thread_id: str, text: str) -> Dict[str, Any]:
        """A user message. ``start_immediately`` with ``deliveryIntent: auto``: T3 starts a turn, or steers / queues
        the message behind the running one, as its composer's default does (``serverResolvedCommandContext``)."""
        return {"type": "message.dispatch", "commandId": self.new_id(), "createdBy": "user",
                "creationSource": CREATION_SOURCE, "threadId": thread_id, "messageId": self.new_id(), "text": text,
                "attachments": [], "deliveryIntent": "auto", "dispatchMode": {"type": "start_immediately"}}

    def approval_respond(self, *, thread_id: str, request_id: str, decision: str) -> Dict[str, Any]:
        if decision not in APPROVAL_DECISIONS:
            raise ValueError("invalid decision")
        return {"type": "runtime-request.respond", "commandId": self.new_id(), "threadId": thread_id,
                "requestId": request_id, "decision": decision}

    def user_input_respond(self, *, thread_id: str, request_id: str, answers: Dict[str, Any]) -> Dict[str, Any]:
        return {"type": "runtime-request.respond", "commandId": self.new_id(), "threadId": thread_id,
                "requestId": request_id, "answers": dict(answers)}

    def stop(self, *, thread_id: str) -> Dict[str, Any]:
        """Stop the thread: its run and the background work and delegated tasks under it (``threadStop``)."""
        return {"type": "thread.stop", "commandId": self.new_id(), "threadId": thread_id}


def title_from_prompt(text: str, limit: int = 60) -> str:
    flat = " ".join(str(text).split())
    if len(flat) <= limit:
        return flat or "New task"
    cut = flat[:limit]
    space = cut.rfind(" ")
    if space > limit * 0.5:
        cut = cut[:space]
    return cut.rstrip(" ,;:-.") + "…"


# --------------------------------------------------------------------------- placement (port of placement.py)

ORCHESTRATION = "orchestration"
MENTIONED = "mentioned"
CODING = "coding"
CHOSEN = "chosen"
_AGENT_WORKSPACE = re.compile(r"/\.t3/(?!scratch(?:/|$))[^/]+/workspace/?$")
_WORD = re.compile(r"[a-z0-9]+")
_GENERIC = frozenset({
    "workspace", "project", "projects", "home", "documents", "document", "desktop", "downloads", "download",
    "scratch", "code", "src", "app", "apps", "music", "pictures", "movies", "library", "users", "user", "tmp",
    "notes", "files", "folder", "work", "test", "tests", "new", "main", "default", "repo", "repos", "web",
})
_CODING = re.compile(
    r"\b(code|coding|codebase|bug|bugs|debug\w*|refactor\w*|repo|repos|repository|commit\w*|branch\w*|merge\w*|"
    r"rebase|pull request|pr|prs|tests?|unit tests?|test suite|build|builds|compile\w*|deploy\w*|function|functions|"
    r"class|classes|module|modules|implement\w*|api|apis|endpoint\w*|lint\w*|typescript|javascript|python|swift|"
    r"kotlin|java|rust|golang|react|css|html|sql|schema|migration\w*|stack ?trace|exception|crash\w*|npm|pnpm|"
    r"gradle|xcode|git|github|ci|pipeline|docker|backend|frontend|unit|regression|typecheck\w*|stack)\b")
_GENERAL = re.compile(
    r"\b(open|close|quit|launch|browser|chrome|safari|aside|website|web ?site|web ?page|tab|tabs|youtube|google|"
    r"search for|look up|find me|email|emails|e-mail|mail|inbox|gmail|calendar|meeting|meetings|schedule|"
    r"remind\w*|message|messages|imessage|slack|whatsapp|telegram|discord|zoom|spotify|music|play|playlist|"
    r"heptabase|notion|journal|book|booking|buy|order|purchase|shop\w*|flight|hotel|restaurant|trip|travel|"
    r"downloads|folder|folders|desktop|screenshot|organi[sz]e|clean up|summari[sz]e|research|draft|reply|"
    r"tweet|invoice|spreadsheet|excel|slides|deck|pdf|photo|photos|video|videos|wifi|bluetooth|volume|"
    r"computer|mac)\b")
_SOFTWARE = re.compile(
    r"\b(widgets?|features?|buttons?|ui|ux|components?|card|(?<!web )pages?|sync\w*|bridge|runtime|server|client|"
    r"endpoint\w*|readme|documentation|animation\w*|fonts?|icons?|integration\w*|plugins?|android|ios|r1|"
    r"bugs?|crash\w*|broken|not working|doesn t work|does not work|isn t working|faster|slower|performance|"
    r"latency)\b")


def words(text: Any) -> List[str]:
    return _WORD.findall(str(text or "").lower().replace("’", "'"))


def is_coding_task(text: str) -> bool:
    """Building or fixing software: coding signals at least as strong as everyday ones, or anything about software.
    Everything else (a computer or life task, or nothing to go on) goes to the orchestration project."""
    lowered = " ".join(words(text))
    coding = len(_CODING.findall(lowered))
    general = len(_GENERAL.findall(lowered))
    return (coding > 0 and coding >= general) or _SOFTWARE.search(lowered) is not None


def is_scratch(project: Dict[str, Any]) -> bool:
    root = str(project.get("workspaceRoot") or "").rstrip("/")
    return root.endswith("/.t3/scratch") or str(project.get("title") or "").strip().lower() == "no project"


def _names(record: Dict[str, Any]) -> List[str]:
    names = [str(record.get("title") or "")]
    root = str(record.get("workspaceRoot") or "").rstrip("/")
    if root:
        names.append(root.rsplit("/", 1)[-1])
    identity = record.get("repository")
    if isinstance(identity, dict):
        for key in ("name", "repo", "repository", "displayName"):
            if isinstance(identity.get(key), str):
                names.append(identity[key])
        for key in ("remote", "url", "remoteUrl", "originUrl"):
            value = identity.get(key)
            if isinstance(value, str) and value.strip():
                last = value.rstrip("/").rsplit("/", 1)[-1]
                names.append(last[:-4] if last.endswith(".git") else last)
    result: List[str] = []
    for name in names:
        phrase = " ".join(words(name))
        if len(phrase.replace(" ", "")) >= 3 and phrase not in _GENERIC and phrase not in result:
            result.append(phrase)
    return result


def mentioned_project(text: str, records: List[Dict[str, Any]]) -> Optional[Dict[str, Any]]:
    haystack = " " + " ".join(words(text)) + " "
    best: Optional[Tuple[int, Dict[str, Any]]] = None
    for record in records:
        if record.get("scratch"):
            continue
        for phrase in _names(record):
            if f" {phrase} " in haystack and (best is None or len(phrase) > best[0]):
                best = (len(phrase), record)
    return best[1] if best else None


def orchestration_project(records: List[Dict[str, Any]], *, project_id: Optional[str] = None,
                          title: Optional[str] = DEFAULT_ORCHESTRATION_TITLE) -> Optional[Dict[str, Any]]:
    """The configured project, else the project with the configured title (default: T3's agent project), else T3's
    agent workspace project (``~/.t3/<agent>/workspace``), else the most recently active one."""
    usable = [record for record in records if not record.get("scratch")]
    if project_id:
        for record in usable:
            if record["id"] == project_id:
                return record
    wanted = " ".join(str(title or "").split()).lower()
    if wanted:
        for record in usable:
            if " ".join(str(record.get("title") or "").split()).lower() == wanted:
                return record
    for record in usable:
        if _AGENT_WORKSPACE.search(str(record.get("workspaceRoot") or "")):
            return record
    if usable:
        return usable[0]
    return records[0] if records else None


def place(text: str, records: List[Dict[str, Any]], *, orchestration_id: Optional[str] = None,
          orchestration_title: Optional[str] = DEFAULT_ORCHESTRATION_TITLE) -> Tuple[Dict[str, Any], str]:
    """Where a new task from the phone goes (CONTRACTS-WAVE4): a project the request names, coding work to the most
    recently active repo project, everything else to the orchestration project.

    Two differences from the R1's ``placement.py`` on purpose: a request with nothing to go on goes to the
    orchestration project here (the R1's ``t3_new_thread`` is its coding tool, so there "unsure" means coding), and
    coding work never lands in the orchestration project while a repo project exists (the R1's "most recently
    active" fallback can pick it). The orchestration project is the bridge's own setting
    (``SAMRABBIT_T3_ORCHESTRATION_PROJECT`` / ``_TITLE``); the R1's ``t3.orchestration_project_id`` lives on the
    R1 and is not read here."""
    if not records:
        raise T3Error(409, "t3_no_projects", "T3 Code has no projects yet. Add one on the Mac first.")
    mentioned = mentioned_project(text, records)
    if mentioned is not None:
        return mentioned, MENTIONED
    orchestration = orchestration_project(records, project_id=orchestration_id, title=orchestration_title)
    if is_coding_task(text):
        # The most recently active project that is a code project (not the scratch space, not the orchestration
        # project); with nothing else there, the orchestration project after all.
        repos = [record for record in records if not record.get("scratch")
                 and (orchestration is None or record["id"] != orchestration["id"])]
        if repos:
            return repos[0], CODING
    if orchestration is not None:
        return orchestration, ORCHESTRATION
    return records[0], ORCHESTRATION


# --------------------------------------------------------------------------- the hub


def project_records(shell: Dict[str, Any], threads: Optional[Iterable[Dict[str, Any]]] = None) -> List[Dict[str, Any]]:
    """Projects most recently active first (by ``threads``, as ``bridge_thread`` presents them; default: the
    shell's own threads), with the fields placement needs. Deleted projects are left out."""
    projects = [project for project in shell.get("projects") or [] if isinstance(project, dict) and project.get("id")
                and not project.get("deletedAt")]
    recency: Dict[str, datetime] = {}
    if threads is None:
        threads = [bridge_thread(thread) for thread in shell.get("threads") or [] if isinstance(thread, dict)]
    for thread in threads:
        if not isinstance(thread, dict):
            continue
        stamp = parse_time(activity_time(thread))
        key = str(thread.get("projectId") or "")
        if stamp is not None and (key not in recency or stamp > recency[key]):
            recency[key] = stamp
    floor = datetime.min.replace(tzinfo=timezone.utc)
    ordered = sorted(projects, key=lambda project: recency.get(str(project["id"]), floor), reverse=True)
    records = []
    for project in ordered:
        identity = project.get("repositoryIdentity")
        records.append({"id": str(project["id"]), "title": str(project.get("title") or "Project"),
                        "workspaceRoot": str(project.get("workspaceRoot") or ""),
                        "repository": identity if isinstance(identity, dict) else None,
                        "defaultModelSelection": project.get("defaultModelSelection")
                        if isinstance(project.get("defaultModelSelection"), dict) else None,
                        "scratch": is_scratch(project)})
    return records


def trim_server_config(config: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    """The providers T3 offers (``ServerProvider``: instanceId, driver, enabled, installed, status, availability,
    models) and ``settings.defaultModelSelection``, without everything else in ``server.getConfig``."""
    providers = []
    for raw in config.get("providers") or []:
        if not isinstance(raw, dict) or not isinstance(raw.get("instanceId"), str) or not raw["instanceId"]:
            continue
        usable = raw.get("enabled") is True and raw.get("installed") is not False and \
            raw.get("availability") != "unavailable" and raw.get("status") not in ("disabled", "error")
        models = [{"slug": str(model["slug"]), "name": str(model.get("name") or model["slug"]),
                   "isDefault": model.get("isDefault") is True}
                  for model in raw.get("models") or []
                  if isinstance(model, dict) and isinstance(model.get("slug"), str) and model["slug"]
                  and model.get("isLegacy") is not True]
        providers.append({"instanceId": raw["instanceId"], "driver": str(raw.get("driver") or raw["instanceId"]),
                          "displayName": str(raw.get("displayName") or raw["instanceId"]), "usable": usable,
                          "models": models})
    if not providers:
        return None
    default = _dict(_dict(config.get("settings")).get("defaultModelSelection"))
    return {"providers": providers,
            "defaultModelSelection": {"instanceId": str(default["instanceId"]), "model": str(default["model"])}
            if isinstance(default.get("instanceId"), str) and isinstance(default.get("model"), str) else None}


@dataclass
class _Snapshot:
    at: float
    shell: Dict[str, Any]
    threads: Dict[str, Dict[str, Any]] = field(default_factory=dict)
    titles: Dict[str, str] = field(default_factory=dict)
    records: List[Dict[str, Any]] = field(default_factory=list)


class T3Hub:
    """The phone's view of T3: a cached shell snapshot, thread lists and details, and the commands."""

    def __init__(self, session: T3Session, *, orchestration_id: Optional[str] = None,
                 orchestration_title: Optional[str] = DEFAULT_ORCHESTRATION_TITLE,
                 commands: Optional[CommandBuilder] = None, monotonic: Callable[[], float] = time.monotonic,
                 clock: Callable[[], datetime] = _now_utc) -> None:
        self.session = session
        self.orchestration_id = orchestration_id or None
        self.orchestration_title = orchestration_title
        self.commands = commands or CommandBuilder()
        self._monotonic = monotonic
        self._clock = clock
        self._lock = threading.RLock()
        self._fetch_lock = threading.Lock()
        self._pending_lock = threading.Lock()
        self._snapshot: Optional[_Snapshot] = None
        self._details: Dict[Tuple[str, int], Tuple[float, Dict[str, Any]]] = {}
        self._pending: Dict[str, Tuple[str, Optional[Dict[str, Any]]]] = {}  # thread id -> (updatedAt, view)
        self._turn_requests: Dict[str, Tuple[float, Optional[str]]] = {}
        self._config: Optional[Tuple[float, Optional[Dict[str, Any]]]] = None  # (read at, trimmed config or None)
        self._config_lock = threading.Lock()
        self._chosen_modes: Dict[str, str] = {}  # thread id -> the runtime mode ``create`` was told (not inherited)
        self._plans: Dict[str, Tuple[float, Optional[Dict[str, Any]]]] = {}  # thread id -> (read at, planProgress)
        self.shell_fetches = 0  # tests: how often the shell was read from T3

    # ------------------------------------------------------------------ snapshot
    def available(self) -> bool:
        return True

    def status(self) -> Dict[str, Any]:
        return self.session.status()

    def cached(self) -> Optional[_Snapshot]:
        with self._lock:
            return self._snapshot

    def age(self) -> Optional[float]:
        snapshot = self.cached()
        return None if snapshot is None else self._monotonic() - snapshot.at

    def snapshot(self, max_age: float = SHELL_MAX_AGE) -> _Snapshot:
        current = self.cached()
        if current is not None and self._monotonic() - current.at < max_age:
            return current
        with self._fetch_lock:  # single flight: concurrent requests share one fetch
            current = self.cached()
            if current is not None and self._monotonic() - current.at < max_age:
                return current
            shell = self.session.call(lambda token: self.session.http.request(
                "GET", "/api/orchestration/shell?omitIdleSubagents=1", token=token, timeout=15.0))
            if not isinstance(shell, dict) or not isinstance(shell.get("threads"), list):
                raise T3Error(502, "t3_bad_answer", "T3 Code answered with an unexpected thread list.", retryable=True)
            self.shell_fetches += 1
            raw = [thread for thread in shell.get("threads") or [] if isinstance(thread, dict) and thread.get("id")]
            asking = subagent_requests(raw)
            # The top-level threads (T3's own lists leave subagents out: their requests show on their parents).
            threads = {str(thread["id"]): bridge_thread(thread, asking.get(str(thread["id"]))) for thread in raw
                       if thread.get("archivedAt") is None and thread.get("deletedAt") is None
                       and not is_subagent(thread)}
            titles = {str(project.get("id")): str(project.get("title") or "Project")
                      for project in shell.get("projects") or [] if isinstance(project, dict) and project.get("id")}
            self._plan_progress(threads)
            snapshot = _Snapshot(self._monotonic(), shell, threads, titles,
                                 project_records(shell, threads.values()))
            with self._lock:
                self._snapshot = snapshot
                for thread_id in [key for key in self._pending if key not in threads]:
                    self._pending.pop(thread_id, None)
            return snapshot

    def _plan_progress(self, threads: Dict[str, Dict[str, Any]]) -> None:
        """``planProgress`` for the threads with a turn running (``bridge_thread`` has none: v2 keeps a thread's task
        list in its detail only): each one's bounded detail read at most every ``PLAN_MAX_AGE`` seconds, at most
        ``PLAN_READS_PER_SNAPSHOT`` reads per shell read; a failed read leaves the thread without a step."""
        now = self._monotonic()
        reads = 0
        with self._lock:
            known = {key: value for key, value in self._plans.items() if key in threads}
        for thread_id, thread in threads.items():
            if _dict(thread.get("session")).get("status") not in ("running", "starting") or \
                    thread.get("hasPendingApprovals") or thread.get("hasPendingUserInput"):
                known.pop(thread_id, None)
                continue
            cached = known.get(thread_id)
            if (cached is None or now - cached[0] >= PLAN_MAX_AGE) and reads < PLAN_READS_PER_SNAPSHOT:
                reads += 1
                try:
                    detail = self.detail(thread_id, fresh=True)
                    cached = (now, plan_progress(_dict(detail.get("thread")).get("plans")))
                except T3Error:
                    cached = (now, None)
                known[thread_id] = cached
            if cached is not None and cached[1] is not None:
                thread["planProgress"] = dict(cached[1])
        with self._lock:
            self._plans = known

    def invalidate(self, thread_id: Optional[str] = None) -> None:
        """The next read is fresh: the shell, and the thread's detail, open request and step (``thread_id``), or
        every thread's step (none given)."""
        with self._lock:
            if self._snapshot is not None:
                self._snapshot = _Snapshot(-1e9, self._snapshot.shell, self._snapshot.threads, self._snapshot.titles,
                                           self._snapshot.records)
            if thread_id:
                for key in [key for key in self._details if key[0] == thread_id]:
                    self._details.pop(key, None)
                self._pending.pop(thread_id, None)
                self._plans.pop(thread_id, None)
            else:
                self._plans.clear()

    # ------------------------------------------------------------------ items
    def _awaiting_turn(self, thread_id: str, thread: Dict[str, Any]) -> bool:
        with self._lock:
            requested = self._turn_requests.get(thread_id)
            if requested is None:
                return False
            at, previous = requested
            session = _dict(thread.get("session"))
            latest = _dict(thread.get("latestTurn"))
            turn_id = str(latest.get("turnId")) if latest.get("turnId") else None
            if session.get("status") in ("running", "starting") or turn_id != previous or \
                    self._monotonic() - at > TURN_START_GRACE:
                self._turn_requests.pop(thread_id, None)
                return False
            return True

    def _note_turn(self, thread_id: str, previous_turn: Any) -> None:
        with self._lock:
            self._turn_requests[thread_id] = (self._monotonic(), str(previous_turn) if previous_turn else None)
            if len(self._turn_requests) > 32:
                oldest = min(self._turn_requests, key=lambda key: self._turn_requests[key][0])
                self._turn_requests.pop(oldest, None)

    def item(self, thread: Dict[str, Any], titles: Dict[str, str]) -> Dict[str, Any]:
        thread_id = str(thread.get("id") or "")
        status = mobile_status(thread)
        label = status_label(thread, thread_status(thread))
        if status in MOBILE_RECENT and self._awaiting_turn(thread_id, thread):
            status, label = "working", "Starting"
        phase, progress = plan_phase(thread)
        project_id = str(thread.get("projectId") or "")
        with self._lock:
            pending = self._pending.get(thread_id)
        pending_value = pending[1] if pending and status in MOBILE_NEEDS_YOU else None
        if pending_value is not None:
            summary = condense(pending_value.get("text"), 160)
        elif status == "working" and phase:
            summary = f"{label}: {phase}" if label.startswith("Step") else phase
        elif status == "error":
            summary = condense(str(_dict(thread.get("session")).get("lastError") or ""), 160) or label
        else:
            summary = label
        value: Dict[str, Any] = {
            "threadId": thread_id,
            "title": str(thread.get("title") or "Untitled task"),
            "projectId": project_id,
            "projectName": titles.get(project_id, "Project"),
            "status": status,
            "statusLabel": label,
            "updatedAt": normal_time(summary_time(thread, thread_status(thread))) or normal_time(thread.get("updatedAt")),
            "summary": summary,
            "settled": is_settled(thread),
        }
        if status == "working":
            value["phase"] = phase
            value["progress"] = progress
        if pending_value is not None:
            value["pending"] = pending_value
        model = _dict(thread.get("modelSelection")).get("model")
        if isinstance(model, str) and model:
            value["model"] = model
        return value

    def _ordered(self, snapshot: _Snapshot) -> List[Tuple[Dict[str, Any], Dict[str, Any]]]:
        now = self._clock()
        pairs = []
        for thread in snapshot.threads.values():
            item = self.item(thread, snapshot.titles)
            shelved = 1 if item["status"] in MOBILE_RECENT and (is_settled(thread) or is_snoozed(thread, now)) else 0
            order = {"needs_approval": 0, "needs_input": 1, "working": 2, "error": 3, "done": 4, "idle": 5}
            stamp = parse_time(item.get("updatedAt"))
            pairs.append(((shelved, order.get(item["status"], 9), -(stamp.timestamp() if stamp else 0.0),
                           item["threadId"]), thread, item))
        pairs.sort(key=lambda entry: entry[0])
        return [(thread, item) for _key, thread, item in pairs]

    def threads(self, filter_name: Optional[str] = None, *, limit: int = 40, max_age: float = SHELL_MAX_AGE,
                hide: Optional[Callable[[Dict[str, Any]], bool]] = None) -> List[Dict[str, Any]]:
        """The threads, most urgent first. ``hide``: True for an item to leave out (the inbox's dismissed threads,
        ``samrabbit_inbox.InboxService.t3_dismissed``), before the filter and the limit."""
        snapshot = self.snapshot(max_age)
        ordered = [item for _thread, item in self._ordered(snapshot) if hide is None or not hide(item)]
        if filter_name == "needs_you":
            ordered = [item for item in ordered if item["status"] in MOBILE_NEEDS_YOU]
        elif filter_name == "working":
            ordered = [item for item in ordered if item["status"] == "working"]
        elif filter_name == "recent":
            ordered = [item for item in ordered if item["status"] in MOBILE_RECENT]
            ordered.sort(key=lambda item: item.get("updatedAt") or "", reverse=True)
        elif filter_name not in (None, ""):
            raise T3Error(400, "invalid_filter", "filter must be needs_you, working or recent.")
        return ordered[:max(1, min(100, limit))]

    def summary_part(self, snapshot: Optional[_Snapshot], *,
                     hide: Optional[Callable[[Dict[str, Any]], bool]] = None) -> Dict[str, Any]:
        """``summary.t3``: the counts and the first five threads, less what ``hide`` leaves out (as ``threads``)."""
        if snapshot is None:
            return {"available": False, "needsYou": 0, "working": 0, "threads": []}
        items = [item for _thread, item in self._ordered(snapshot) if hide is None or not hide(item)]
        return {"available": True,
                "needsYou": sum(1 for item in items if item["status"] in MOBILE_NEEDS_YOU),
                "working": sum(1 for item in items if item["status"] == "working"),
                "threads": [{"threadId": item["threadId"], "title": item["title"], "project": item["projectName"],
                             "status": item["status"], "updatedAt": item["updatedAt"], "summary": item["summary"]}
                            for item in items[:5]]}

    def projects(self) -> Dict[str, Any]:
        snapshot = self.snapshot()
        orchestration = orchestration_project(snapshot.records, project_id=self.orchestration_id,
                                              title=self.orchestration_title)
        return {"projects": [{"projectId": record["id"], "name": record["title"],
                              "orchestration": orchestration is not None and record["id"] == orchestration["id"]}
                             for record in snapshot.records if not record.get("scratch")],
                "orchestrationProjectId": orchestration["id"] if orchestration else None}

    def cached_server_config(self) -> Optional[Dict[str, Any]]:
        """The provider list as last read (never a T3 call)."""
        with self._config_lock:
            return self._config[1] if self._config is not None else None

    def server_config(self) -> Optional[Dict[str, Any]]:
        """``server.getConfig`` trimmed to what a new task needs: ``{providers: [{instanceId, driver, displayName,
        usable, models: [{slug, name, isDefault}]}], defaultModelSelection}`` (legacy models left out), read over T3's
        WebSocket RPC and cached for ``CONFIG_MAX_AGE``; None when T3 does not answer it (a failure is remembered for
        ``CONFIG_RETRY_SECONDS``), so callers fall back to the selections the thread list shows."""
        with self._config_lock:
            cached = self._config
            if cached is not None and self._monotonic() - cached[0] < (
                    CONFIG_MAX_AGE if cached[1] is not None else CONFIG_RETRY_SECONDS):
                return cached[1]
        try:  # never through ``session.call``: a T3 without this RPC must not mark the session as failing
            raw = self.session.http.rpc("server.getConfig", {}, token=self.session.token())
        except (T3Error, _Unavailable, _Unauthorized, _RequestFailed):
            raw = None
        value = trim_server_config(raw) if isinstance(raw, dict) else None
        if value is None:
            _LOG.info("t3 provider list unavailable")
        with self._config_lock:  # never held across the call: ``cached_server_config`` answers meanwhile
            self._config = (self._monotonic(), value)
        return value

    # ------------------------------------------------------------------ details
    def detail(self, thread_id: str, *, turns: int = 2, fresh: bool = False, full: bool = False) -> Dict[str, Any]:
        """One thread read: ``{snapshotSequence, hasMoreHistory, thread}`` where ``thread`` is the thread as
        ``bridge_thread`` presents it (from its projection) plus the projection's ``messages`` (``{id, role, text,
        createdAt, streaming, ...}``), ``turnItems``, ``runtimeRequests`` and ``plans``. The bounded snapshot (T3's
        recent window: about 10 user turns, at most ~1 MB) unless ``full`` (the whole projection, for a request older
        than the window). ``turns`` is kept for callers; the window does not depend on it."""
        thread_id = _thread_id(thread_id)
        key = (thread_id, 1 if full else 0)
        if not fresh:
            with self._lock:
                cached = self._details.get(key)
            if cached is not None and self._monotonic() - cached[0] < DETAIL_TTL:
                return cached[1]
        path = f"/api/orchestration/threads/{quote(thread_id, safe='')}" + ("" if full else "/bounded")
        value = self.session.call(lambda token: self.session.http.request("GET", path, token=token, timeout=15.0))
        projection = _dict(value).get("projection")
        if not isinstance(projection, dict) or not isinstance(projection.get("thread"), dict):
            raise T3Error(502, "t3_bad_answer", "T3 Code answered with an unexpected thread.", retryable=True)
        thread = bridge_thread(shell_of_projection(projection))
        for name in ("messages", "turnItems", "runtimeRequests", "plans"):
            items = projection.get(name)
            thread[name] = [item for item in items if isinstance(item, dict)] if isinstance(items, list) else []
        result = {"snapshotSequence": value.get("snapshotSequence"), "hasMoreHistory": value.get("hasMoreHistory")
                  is True, "thread": thread}
        with self._lock:
            if len(self._details) > 24:
                self._details.clear()
            self._details[key] = (self._monotonic(), result)
        return result

    def pending(self, thread_id: str, *, wider: bool = True) -> PendingRequests:
        """The thread's open requests, read now. ``wider``: the whole thread when a request's question is older than
        the bounded window, and the subagents that ask through this thread (``pendingChildThreadIds``) when it has
        none of its own (each request then names the child in ``thread_id``: answers go there)."""
        detail = self.detail(thread_id, turns=1, fresh=True)
        found = pending_requests(detail.get("thread"))
        if found.unmatched and wider:
            found = pending_requests(self.detail(thread_id, fresh=True, full=True).get("thread"))
        if found.count == 0 and wider:
            snapshot = self.cached()
            shell = snapshot.threads.get(_thread_id(thread_id)) if snapshot is not None else None
            for child in (shell or {}).get("pendingChildThreadIds") or []:
                try:
                    asked = self.pending(str(child), wider=False)
                except T3Error:
                    continue
                if asked.count:
                    return asked.asked_by(str(child))
        return found

    def refresh_pending(self, limit: int = 6, *, only: Optional[Iterable[str]] = None,
                        budget: Optional[float] = None) -> int:
        """Fetch the open request of each needs-you thread (of ``only``, when given) whose ``updatedAt`` changed:
        at most ``limit`` threads, and none after ``budget`` seconds. One refresh at a time (the background worker
        and a thread list share the results). Returns how many threads were read."""
        snapshot = self.cached()
        if snapshot is None:
            return 0
        wanted = set(only) if only is not None else None
        started = time.monotonic()
        fetched = 0
        with self._pending_lock:
            for thread_id, thread in snapshot.threads.items():
                if (wanted is not None and thread_id not in wanted) or thread_status(thread) not in NEEDS_YOU:
                    continue
                marker = str(thread.get("updatedAt") or "")
                with self._lock:
                    known = self._pending.get(thread_id)
                if known is not None and known[0] == marker:
                    continue
                if fetched >= limit or (budget is not None and fetched and time.monotonic() - started > budget):
                    break
                fetched += 1
                try:
                    view = pending_view(self.pending(thread_id))
                except T3Error:
                    continue
                with self._lock:
                    self._pending[thread_id] = (marker, view)
        return fetched

    def thread_view(self, thread_id: str) -> Dict[str, Any]:
        thread_id = _thread_id(thread_id)
        detail = self.detail(thread_id, turns=3)
        thread = _dict(detail.get("thread"))
        pending = pending_requests(thread)
        snapshot = self.cached()
        titles = snapshot.titles if snapshot else {}
        shell_thread = snapshot.threads.get(thread_id) if snapshot else None
        if shell_thread is None:
            shell_thread = {key: value for key, value in thread.items()
                            if key not in ("messages", "turnItems", "runtimeRequests", "plans")}
        elif pending.count == 0 and (pending.unmatched or shell_thread.get("pendingChildThreadIds")):
            pending = self.pending(thread_id)  # an older question, or a subagent asking through this thread
        progress = plan_progress(thread.get("plans"))
        if progress is not None:
            shell_thread = dict(shell_thread, planProgress=progress)
        view = pending_view(pending)
        with self._lock:
            self._pending[thread_id] = (str(shell_thread.get("updatedAt") or ""), view)
        item = self.item(shell_thread, titles)
        if view is None:
            item.pop("pending", None)
        session = _dict(thread.get("session"))
        active = session.get("activeTurnId") if session.get("status") in ("running", "starting") else None
        return {"thread": item, "messages": timeline(thread), "pending": view,
                "activeTurnId": str(active) if active else None}

    # ------------------------------------------------------------------ commands
    def _thread(self, thread_id: str) -> Dict[str, Any]:
        thread_id = _thread_id(thread_id)
        snapshot = self.snapshot(max_age=10.0)
        thread = snapshot.threads.get(thread_id)
        if thread is not None:
            return thread
        found = _dict(self.detail(thread_id, turns=1).get("thread"))
        if not found:
            raise T3Error(404, "t3_thread_not_found", "That T3 thread was not found.")
        return found

    def _write(self, tag: str, payload: Dict[str, Any], timeout: float) -> Any:
        """One write over T3's RPC (``tag``: ``orchestration.dispatchCommand`` / ``orchestration.launchThread``),
        tried once more when the connection fails (the same ``commandId``: T3 answers a retry with the first
        result). T3 refusing it is ``t3_dispatch_failed``; the session's own failures pass through."""
        def send(token: str) -> Any:
            try:
                return self.session.http.rpc(tag, payload, token=token, timeout=timeout)
            except _Unavailable:
                return self.session.http.rpc(tag, payload, token=token, timeout=timeout)
        try:
            return self.session.call(send)
        except T3Error as error:
            if error.code in ("t3_unavailable", "t3_unauthorized", "t3_app_missing", "t3_pairing_rejected",
                              "t3_cli_failed", "t3_cli_timeout"):
                raise
            raise T3Error(502, "t3_dispatch_failed", "T3 Code did not accept that.", retryable=False) from None

    def _dispatch(self, command: Dict[str, Any]) -> None:
        self._write("orchestration.dispatchCommand", command, DISPATCH_TIMEOUT_SECONDS)

    def send_message(self, thread_id: str, text: Any) -> Dict[str, Any]:
        body = _prompt(text, "The message is empty.")
        thread = self._thread(thread_id)
        self._dispatch(self.commands.message(thread_id=str(thread["id"]), text=body))
        session = _dict(thread.get("session"))
        was_working = session.get("status") in ("running", "starting")
        if not was_working:
            self._note_turn(str(thread["id"]), _dict(thread.get("latestTurn")).get("turnId"))
        self.invalidate(str(thread["id"]))
        _LOG.info("t3 message sent")
        return {"ok": True, "threadId": str(thread["id"]), "wasWorking": was_working}

    def respond(self, thread_id: str, body: Dict[str, Any]) -> Dict[str, Any]:
        thread_id = _thread_id(thread_id)
        decision = body.get("decision")
        answer = body.get("answer")
        answers = body.get("answers")
        request_id = body.get("requestId") if isinstance(body.get("requestId"), str) else None
        if decision is None and answer is None and answers is None:
            raise T3Error(400, "invalid_request", "Send {decision: approve|deny} or {answer}.")
        pending = self.pending(thread_id)
        if decision is not None:
            wanted = {"approve": "accept", "allow": "accept", "deny": "decline", "decline": "decline"}.get(
                str(decision), str(decision))
            if wanted not in APPROVAL_DECISIONS:
                raise T3Error(400, "invalid_request", "decision must be approve or deny.")
            approval = next((item for item in pending.approvals if request_id in (None, item.request_id)), None)
            if approval is None:
                raise T3Error(409, "t3_request_not_pending", "That approval is no longer pending.")
            offered = [option["decision"] for option in approval.options]
            # "Approve" / "Deny" pick the closest choice T3 offers for this request.
            fallbacks = {"accept": ("accept", "acceptForSession", "acceptAlways"), "decline": ("decline", "cancel")}
            if wanted not in offered and wanted in fallbacks:
                wanted = next((choice for choice in fallbacks[wanted] if choice in offered), wanted)
            if wanted not in offered:
                raise T3Error(400, "invalid_request", "That choice is not offered for this approval.")
            self._dispatch(self.commands.approval_respond(thread_id=approval.thread_id or thread_id,
                                                          request_id=approval.request_id, decision=wanted))
            self.invalidate(thread_id)
            _LOG.info("t3 approval answered (%s)", wanted)
            return {"ok": True, "threadId": thread_id, "requestId": approval.request_id, "decision": wanted}
        request = next((item for item in pending.inputs if request_id in (None, item.request_id)), None)
        if request is None:
            raise T3Error(409, "t3_request_not_pending", "That question is no longer pending.")
        if isinstance(answers, dict) and answers:
            given: Dict[str, Any] = answers
        elif isinstance(answer, (str, list)) and answer:
            given = {request.questions[0].question_id: answer}
            if len(request.questions) > 1:
                raise T3Error(400, "invalid_request", "This request has several questions: send answers by id.")
        else:
            raise T3Error(400, "invalid_request", "answer must be text (or answers by question id).")
        resolved = resolve_answers(request, given)
        self._dispatch(self.commands.user_input_respond(thread_id=request.thread_id or thread_id,
                                                        request_id=request.request_id, answers=resolved))
        if request.dismissible:
            snapshot = self.cached()
            cached = snapshot.threads.get(thread_id, {}) if snapshot else {}
            if _dict(cached.get("session")).get("status") not in ("running", "starting"):
                self._note_turn(thread_id, _dict(cached.get("latestTurn")).get("turnId"))
        self.invalidate(thread_id)
        _LOG.info("t3 question answered")
        return {"ok": True, "threadId": thread_id, "requestId": request.request_id, "answers": resolved}

    def stop(self, thread_id: str) -> Dict[str, Any]:
        thread = self._thread(thread_id)
        session = _dict(thread.get("session"))
        running = session.get("status") in ("running", "starting")
        background = thread.get("backgroundLiveness") in ("working", "monitoring")
        if not running and not background:
            return {"ok": True, "threadId": str(thread["id"]), "wasWorking": False}
        self._dispatch(self.commands.stop(thread_id=str(thread["id"])))
        self.invalidate(str(thread["id"]))
        _LOG.info("t3 stop sent")
        return {"ok": True, "threadId": str(thread["id"]), "wasWorking": True}

    def create(self, text: Any, *, project_id: Optional[str] = None, title: Optional[str] = None,
               model_selection: Optional[Dict[str, Any]] = None, thread_id: Optional[str] = None,
               runtime_mode: Optional[str] = None) -> Dict[str, Any]:
        """``orchestration.launchThread``: the thread and its first message at once. The model: ``model_selection``
        when given (the desktop inbox's
        chosen provider instance and model), else the project's most recent thread's, else the project default.
        ``thread_id``: the new thread's id chosen by the caller (a voice note saves it before dispatching, so a retry
        after a crash can look for that thread instead of making a second one). ``runtime_mode``: one of
        ``RUNTIME_MODES`` (a task the bridge starts from words Samin did not type, e.g. ``approval-required``), else
        the project's most recent thread's (never one that was given its own mode here), else ``full-access``."""
        prompt = _prompt(text, "Say what the new task should do.")
        if thread_id is not None:
            thread_id = _thread_id(thread_id)
        snapshot = self.snapshot(max_age=10.0)
        records = snapshot.records
        if project_id:
            chosen = next((record for record in records if record["id"] == str(project_id).strip()), None)
            if chosen is None:
                raise T3Error(400, "invalid_project", "That project was not found in T3 Code.")
            reason = CHOSEN
        else:
            chosen, reason = place(prompt, records, orchestration_id=self.orchestration_id,
                                   orchestration_title=self.orchestration_title)
        siblings = [thread for thread in snapshot.threads.values() if str(thread.get("projectId")) == chosen["id"]]
        floor = datetime.min.replace(tzinfo=timezone.utc)
        siblings.sort(key=lambda thread: parse_time(activity_time(thread)) or floor, reverse=True)
        recent = siblings[0] if siblings else None
        selection: Optional[Dict[str, Any]] = dict(model_selection) if model_selection else None
        if selection is None and recent is not None and _dict(recent.get("modelSelection")).get("model"):
            selection = dict(recent["modelSelection"])
        elif selection is None and _dict(chosen.get("defaultModelSelection")).get("model"):
            selection = dict(chosen["defaultModelSelection"])
        selection = selection or dict(DEFAULT_MODEL_SELECTION)
        if runtime_mode in RUNTIME_MODES:
            mode = str(runtime_mode)
        else:  # never from a thread the bridge gave its own mode (a voice note's approval-required task)
            mine = self._chosen_modes
            usual = next((thread for thread in siblings if str(thread.get("id")) not in mine), None)
            mode = str(usual.get("runtimeMode")) if usual is not None and usual.get("runtimeMode") in \
                RUNTIME_MODES else DEFAULT_RUNTIME_MODE
        name = " ".join(str(title or "").split())[:80] or title_from_prompt(prompt)
        thread_id = thread_id or self.commands.new_id()
        if runtime_mode in RUNTIME_MODES:
            with self._lock:
                self._chosen_modes[thread_id] = mode
                while len(self._chosen_modes) > 200:
                    self._chosen_modes.pop(next(iter(self._chosen_modes)))
        launched = self._write("orchestration.launchThread", self.commands.launch(
            thread_id=thread_id, project_id=chosen["id"], title=name, text=prompt, model_selection=selection,
            runtime_mode=mode), LAUNCH_TIMEOUT_SECONDS)
        if isinstance(_dict(launched).get("threadId"), str) and _THREAD_ID.match(launched["threadId"]):
            thread_id = str(launched["threadId"])  # T3's answer names the thread (the one asked for)
        self._note_turn(thread_id, None)
        self.invalidate()
        _LOG.info("t3 task created (%s)", reason)
        return {"threadId": thread_id, "title": name, "projectId": chosen["id"], "projectName": chosen["title"],
                "placement": reason}


def has_user_message(hub: Any, thread_id: str, thread: Optional[Dict[str, Any]] = None) -> bool:
    """Has T3 got the thread's first message? The shell's own marks (``latestUserMessageAt``, a ``latestTurn``) when
    it has them, else one fresh read of the thread for a user message. A T3Error when it can't tell."""
    if thread is not None and (thread.get("latestUserMessageAt") or _dict(thread.get("latestTurn")).get("turnId")):
        return True
    detail = hub.detail(thread_id, turns=2, fresh=True)
    return any(isinstance(message, dict) and message.get("role") == "user"
               for message in _dict(detail.get("thread")).get("messages") or [])


def start_task(hub: Any, text: str, *, thread_id: str, title: Optional[str] = None,
               runtime_mode: Optional[str] = None, look_first: bool = True) -> Dict[str, Any]:
    """A task whose thread id the caller saved before calling, started exactly once with ``text`` as its first message.

    ``orchestration.launchThread`` makes the thread and sends its first message in one call, but a try can still stop
    after T3 took it and before its answer arrived (or T3 can hold a thread without its message, made by an older
    bridge). So when a thread with that id is in T3 already (``look_first``, and after a failed launch), its first
    message is sent only if T3 doesn't have it, never a second thread and never the message twice. Raises
    T3Error when T3 can't take it now (the caller tries again later with the same id). The answer is ``create``'s, with
    ``created`` (False when the thread was found) and ``sent`` (False when T3 already had the message)."""
    def existing() -> Optional[Tuple[Any, Dict[str, Any]]]:
        snapshot = hub.snapshot(max_age=0.0)
        thread = snapshot.threads.get(thread_id)
        return (snapshot, thread) if thread is not None else None

    def finish(found: Tuple[Any, Dict[str, Any]]) -> Dict[str, Any]:
        snapshot, thread = found
        sent = False
        if not has_user_message(hub, thread_id, thread):
            hub.send_message(thread_id, text)
            sent = True
        titles = snapshot.titles if isinstance(getattr(snapshot, "titles", None), dict) else {}
        return {"threadId": thread_id, "title": str(thread.get("title") or title or ""),
                "projectId": thread.get("projectId"), "projectName": titles.get(str(thread.get("projectId")), ""),
                "placement": None, "created": False, "sent": sent}

    if look_first:
        found = existing()
        if found is not None:
            return finish(found)
    try:
        value = hub.create(text, title=title, thread_id=thread_id, runtime_mode=runtime_mode)
    except T3Error as error:
        if error.code != "t3_dispatch_failed":
            raise
        found = existing()  # ``thread.create`` may have gone through and only the first message failed
        if found is None:
            raise
        return finish(found)
    return dict(value, created=True, sent=True)


def _thread_id(value: Any) -> str:
    text = str(value or "").strip()
    if not _THREAD_ID.match(text):
        raise T3Error(400, "invalid_thread", "That is not a T3 thread id.")
    return text


def _prompt(value: Any, empty: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise T3Error(400, "invalid_request", empty)
    if len(value) > MAX_PROMPT_CHARS or "\x00" in value:
        raise T3Error(400, "invalid_request", "That is too long.")
    return value.strip()


_TOOL_ITEMS = {"command_execution": "Command run", "file_change": "File change", "file_search": "File search",
               "web_search": "Web search", "dynamic_tool": "Tool call", "subagent": "Subagent"}


def timeline(thread: Dict[str, Any]) -> List[Dict[str, Any]]:
    """User and assistant messages (a detail's ``messages``; T3's own wake-ups and compactions left out), with each
    run of tool steps between them (its ``turnItems``: commands, file changes, searches, tool calls, subagents) as one
    ``tool`` line."""
    entries: List[Tuple[datetime, int, Dict[str, Any]]] = []
    floor = datetime.min.replace(tzinfo=timezone.utc)
    for index, message in enumerate(thread.get("messages") or []):
        if not isinstance(message, dict) or message.get("role") not in ("user", "assistant") or \
                message.get("notification") or message.get("idleCompaction"):
            continue
        text = str(message.get("text") or "")
        if not text.strip() and not message.get("streaming"):
            continue
        if len(text) > MAX_MESSAGE_CHARS:
            text = text[:MAX_MESSAGE_CHARS - 1] + "…"
        at = parse_time(message.get("createdAt"))
        entries.append((at or floor, index, {"id": str(message.get("id") or ""), "role": str(message["role"]),
                                             "text": text, "at": iso_utc(at) if at else None,
                                             "streaming": message.get("streaming") is True}))
    steps: Dict[str, Tuple[datetime, str]] = {}
    for item in thread.get("turnItems") or []:
        if not isinstance(item, dict) or item.get("type") not in _TOOL_ITEMS:
            continue
        key = str(item.get("id") or len(steps))
        at = parse_time(item.get("startedAt")) or parse_time(item.get("updatedAt")) or floor
        named = _text(item.get("title")) or (_text(item.get("toolName")) if item.get("type") == "dynamic_tool"
                                             else None)
        title = condense(named or _TOOL_ITEMS[str(item["type"])], 40)
        if key not in steps:
            steps[key] = (at, title)
    for number, (at, title) in enumerate(sorted(steps.values(), key=lambda item: item[0])):
        entries.append((at, 1_000_000 + number, {"role": "tool", "text": title, "at": iso_utc(at)}))
    entries.sort(key=lambda entry: (entry[0], entry[1]))
    result: List[Dict[str, Any]] = []
    run: List[Dict[str, Any]] = []

    def flush() -> None:
        if not run:
            return
        names: List[str] = []
        for step in run:
            if step["text"] not in names:
                names.append(step["text"])
        shown = ", ".join(names[:3]) + (f" (+{len(run) - 3} more)" if len(run) > 3 else "")
        result.append({"role": "tool", "text": f"{len(run)} step{'s' if len(run) != 1 else ''}: {shown}",
                       "at": run[-1]["at"], "steps": len(run)})
        run.clear()

    for _at, _order, entry in entries:
        if entry["role"] == "tool":
            run.append(entry)
            continue
        flush()
        result.append(entry)
    flush()
    return result[-MAX_MESSAGES:]


class UnavailableHub:
    """Stands in for ``T3Hub`` when this bridge does not talk to T3 (a copy run from a checkout, or a bad URL)."""

    def __init__(self, code: str, message: str) -> None:
        self.code = code
        self.message = message
        self.session = None

    def available(self) -> bool:
        return False

    def status(self) -> Dict[str, Any]:
        return {"paired": False, "ok": False, "lastError": self.code}

    def cached(self) -> None:
        return None

    def age(self) -> None:
        return None

    def error(self) -> T3Error:
        return T3Error(503, self.code, self.message)

    def summary_part(self, _snapshot: Any, **_kwargs: Any) -> Dict[str, Any]:
        return {"available": False, "needsYou": 0, "working": 0, "threads": [], "reason": self.code}

    def __getattr__(self, name: str) -> Any:
        if name in ("threads", "projects", "thread_view", "send_message", "respond", "stop", "create", "snapshot",
                    "refresh_pending"):
            def refuse(*_args: Any, **_kwargs: Any) -> Any:
                raise self.error()
            return refuse
        raise AttributeError(name)


def make_session(url: Optional[str], *, token_file: str = DEFAULT_TOKEN_FILE, cli: Optional[str] = None,
                 label: str = CLIENT_LABEL) -> T3Session:
    """The bridge's T3 session. ``url`` None: the server T3 itself says it runs (``ServerLocator``; checked to be T3
    before the token goes out); ``cli`` ``auto`` pairs through the app that runs it. ValueError for a bad ``url``."""
    locator = ServerLocator()
    http = T3Http(url or None, locator=locator)
    return T3Session(http, TokenStore(token_file), T3Cli(cli, locator=locator), label=label)


def make_hub(url: Optional[str], *, token_file: str = DEFAULT_TOKEN_FILE, cli: Optional[str] = None,
             label: str = CLIENT_LABEL, orchestration_id: Optional[str] = None,
             orchestration_title: Optional[str] = None) -> Any:
    """``url`` None (the installed copy's default): wherever T3 runs now (``make_session``)."""
    try:
        session = make_session(url, token_file=token_file, cli=cli, label=label)
    except ValueError:
        return UnavailableHub("t3_url_invalid", "The T3 Code address configured on the Mac is not valid.")
    title = orchestration_title if orchestration_title is not None else \
        os.environ.get("SAMRABBIT_T3_ORCHESTRATION_TITLE", DEFAULT_ORCHESTRATION_TITLE)
    return T3Hub(session,
                 orchestration_id=orchestration_id or os.environ.get("SAMRABBIT_T3_ORCHESTRATION_PROJECT") or None,
                 orchestration_title=title)


# --------------------------------------------------------------------------- command line (install.sh)


def _installed_copy() -> bool:
    """Is this file the installed bridge's copy? (``samrabbit_installed`` next to it; when in doubt, no.)"""
    here = os.path.dirname(os.path.abspath(__file__))
    if here not in sys.path:
        sys.path.append(here)  # ``python3 -I`` leaves the script's folder off sys.path; appended, never shadowing
    try:
        import samrabbit_installed  # noqa: PLC0415
        return bool(samrabbit_installed.is_installed_copy(here))
    except Exception:  # noqa: BLE001
        return False


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="The SamRabbit bridge's own T3 Code session.")
    parser.add_argument("command", choices=("status", "ensure-paired"))
    parser.add_argument("--token-file", default=os.environ.get("SAMRABBIT_T3_TOKEN_FILE") or DEFAULT_TOKEN_FILE)
    parser.add_argument("--url", default=os.environ.get("SAMRABBIT_T3_URL") or None,
                        help="the T3 Code server (default: the port T3 wrote to ~/.t3/userdata/server-runtime.json, "
                             f"else {DEFAULT_SERVER_URL}; a copy that is not the installed bridge pairs only with a "
                             "server given here)")
    parser.add_argument("--cli", default=os.environ.get("SAMRABBIT_T3_CLI") or CLI_AUTO,
                        help="'auto' (the T3 Code app; the installed copy only) or a path to a stand-in CLI")
    parser.add_argument("--label", default=CLIENT_LABEL)
    options = parser.parse_args(argv)
    explicit_cli = (options.cli or "").strip() not in ("", CLI_AUTO, CLI_NONE)
    if options.command == "ensure-paired" and not (options.url and explicit_cli) and not _installed_copy():
        print("T3 not paired: t3_dev_copy (this copy of the bridge is not the installed one, so it pairs with T3 "
              "Code only when given --url and a --cli path)")
        return 3
    try:
        session = make_session(options.url, token_file=options.token_file, cli=options.cli, label=options.label)
    except ValueError as error:
        print(f"T3 not paired: {error}")
        return 3
    if options.command == "status":
        status = session.status()
        print("T3 paired" + (f" (expires {str(status['expiresAt'])[:10]})" if status.get("expiresAt") else "")
              if status["paired"] else "T3 not paired")
        return 0
    try:
        status = session.ensure_paired()
    except T3Error as error:
        print(f"T3 not paired: {error.code} ({error.message})")
        return 3
    print("T3 paired" + (f" (expires {str(status['expiresAt'])[:10]})" if status.get("expiresAt") else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
