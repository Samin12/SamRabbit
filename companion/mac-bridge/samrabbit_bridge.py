#!/usr/bin/env python3
"""SamRabbit Mac bridge: the R1 writes to the Heptabase journal and controls this Mac.

The Heptabase desktop app ships a local CLI (``heptabase``) that talks to the
running app. This small HTTP server lets the R1 on the same network use two of
its commands:

* ``POST /v1/heptabase/journal/append`` runs ``heptabase journal append``.
* ``GET  /v1/heptabase/journal/read?date=YYYY-MM-DD`` runs ``heptabase journal read``
  and returns the day as plain text lines.
* ``GET  /health`` reports the CLI version and whether the app answers, plus the
  Mac-control capabilities.

and, for the R1's voice orchestrator, Mac control through the ``cua-driver`` CLI
and LaunchServices (``samrabbit_mac.py``): ``GET /v1/mac/state``, ``POST /v1/mac/open``,
``GET /v1/mac/read``, ``POST /v1/mac/act`` and ``GET /v1/mac/screenshot``; and generated UIs (charts,
diagrams, dashboards) made with the headless Claude Code CLI (``samrabbit_genui.py``): ``POST /v1/ui/generate``,
``GET /v1/ui/artifacts/<id>`` (+ ``/image``, ``/document``).

Conversation sync (``samrabbit_sync.py``): the R1 mirrors every conversation to ``/v1/sync/*``
and the SamRabbit desktop app reads it back over loopback with its own token.

Google Calendar changes (``samrabbit_calendar.py``): the R1 adds, moves and cancels events through the
signed-in Composio CLI: ``POST /v1/calendar/events`` (+ ``/update``, ``/delete``), ``GET /v1/calendar/status``.

The iPhone app, its widgets and the Apple Watch (``samrabbit_mobile.py``, T3 through ``samrabbit_t3.py``) use
``/v1/mobile/*`` with their own per-device tokens (see that module; speech to text for them is
``samrabbit_transcribe.py``, the watch's voice assistant ``samrabbit_assistant.py`` with its tools in
``samrabbit_assistant_mcp.py``, its realtime voice ``samrabbit_realtime.py`` on the Mac's own ChatGPT login
``samrabbit_chatgpt.py``); ``/health`` reports ``mobile`` and ``assistant``.

The desktop app's Agent Dock (``samrabbit_inbox.py``): ``/v1/desktop/inbox*`` lists the T3 Code threads, Claude Code and
Codex sessions and SamRabbit chats that wait for Samin, and acts on them; the dock's voice is
``/v1/desktop/assistant/*`` (the watch assistant's routes as the device "mac"). Loopback + the desktop token only.
The iPhone gets the same inbox at ``/v1/mobile/inbox*`` (its mobile token; ``open`` stays the Mac's), and the
SamRabbit window the phone's summary, agenda, block time, journal note and device list at ``/v1/desktop/summary``,
``/v1/desktop/calendar/*``, ``/v1/desktop/journal`` and ``/v1/desktop/devices*`` (``samrabbit_mobile.py``).

Quick voice notes (``samrabbit_capture.py``): ``POST /v1/capture`` (the R1, bridge token), ``/v1/mobile/capture`` (the
phone and the watch) and ``/v1/desktop/capture`` (the Mac app): stored at once, then heard, routed (journal, T3 task,
calendar, or a saved note) and recorded. The morning brief (``samrabbit_briefing.py``): ``GET /v1/briefing`` and its
``/v1/mobile`` and ``/v1/desktop`` twins, built from Gmail (through Composio, drafts only: nothing is ever sent), the
calendar and the inbox. Both share the Composio runner (``samrabbit_composio.py``) and the isolated ``claude -p``
(``samrabbit_claude.py``).

Every route needs ``Authorization: Bearer <token>`` (the token lives in
``~/.config/samrabbit/bridge-token``, mode 0600). Journal text and the token are
never logged. Stdlib only; runs on the macOS system Python 3.9+.
"""

from __future__ import annotations

import argparse
import atexit
from datetime import date as Date, datetime, timezone
import hashlib
import hmac
import ipaddress
import json
import logging
import os
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Dict, List, Optional, Tuple
from urllib.parse import parse_qs, urlsplit

# ``python3 -I`` (as the LaunchAgent runs us) leaves the script's folder off sys.path; the sibling
# module lives there. Appended, so it can never shadow the standard library.
_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.append(_HERE)

import samrabbit_mac as mac  # noqa: E402
import samrabbit_genui as genui  # noqa: E402

try:  # "is this the installed copy?"; without it every copy is a dev copy (the safe answer)
    import samrabbit_installed as installation  # noqa: E402
except Exception:  # noqa: BLE001  # pragma: no cover
    installation = None  # type: ignore[assignment]

try:  # conversation sync must never keep the journal or Mac control from starting
    import samrabbit_sync as sync  # noqa: E402
except Exception:  # noqa: BLE001
    sync = None  # type: ignore[assignment]

try:  # desktop web UI at /app/ (loopback + desktop token); optional so the bridge runs without it
    import samrabbit_app as desktop_app  # noqa: E402
except ImportError:  # pragma: no cover
    desktop_app = None  # type: ignore[assignment]

try:  # Google Calendar changes through Composio; optional so the bridge runs without it
    import samrabbit_calendar as gcal  # noqa: E402
except Exception:  # noqa: BLE001  # pragma: no cover
    gcal = None  # type: ignore[assignment]

try:  # the iPhone / Apple Watch API (/v1/mobile/*); optional so the bridge runs without it
    import samrabbit_mobile as mobile  # noqa: E402
    import samrabbit_t3 as t3  # noqa: E402
except Exception:  # noqa: BLE001  # pragma: no cover
    mobile = None  # type: ignore[assignment]
    t3 = None  # type: ignore[assignment]

try:  # the watch's voice assistant (/v1/mobile/assistant/*); optional so the bridge runs without it
    import samrabbit_assistant as assistant  # noqa: E402
except Exception:  # noqa: BLE001  # pragma: no cover
    assistant = None  # type: ignore[assignment]

try:  # the desktop app's Agent Dock (/v1/desktop/inbox*); optional so the bridge runs without it
    import samrabbit_inbox as inbox  # noqa: E402
except Exception:  # noqa: BLE001  # pragma: no cover
    inbox = None  # type: ignore[assignment]

try:  # quick voice notes (/v1/capture, /v1/{mobile,desktop}/capture*); optional so the bridge runs without it
    import samrabbit_capture as capture  # noqa: E402
except Exception:  # noqa: BLE001  # pragma: no cover
    capture = None  # type: ignore[assignment]

try:  # the morning brief (/v1/briefing, /v1/{mobile,desktop}/briefing*); optional so the bridge runs without it
    import samrabbit_briefing as briefing  # noqa: E402
except Exception:  # noqa: BLE001  # pragma: no cover
    briefing = None  # type: ignore[assignment]

VERSION = "1.2.0"
SERVICE = "samrabbit-bridge"
DEFAULT_HOST = "0.0.0.0"
DEFAULT_PORT = 3780
DEFAULT_TOKEN_FILE = "~/.config/samrabbit/bridge-token"
FALLBACK_CLI = "/opt/homebrew/bin/heptabase"
# Which Heptabase CLI a bridge uses (``--cli`` / SAMRABBIT_HEPTABASE_CLI): a path, ``auto`` or ``dry-run`` (nothing
# reaches Heptabase). Only the installed LaunchAgent copy uses the real CLI by itself: the folder install.sh writes in
# the account's own home (from the password database, never $HOME) with its ``.samrabbit-installed`` marker
# (``samrabbit_installed``); for it, ``auto`` and no choice both mean the real CLI on PATH (or FALLBACK_CLI). A copy run
# from a checkout, a test or a temp HOME is dry-run, ``auto`` included, so a stray test or dev bridge can never write to
# the user's journal; only an explicit path to a CLI makes such a copy use one.
CLI_AUTO = "auto"
CLI_DRY_RUN = "dry-run"
# ``/health`` ``cli.mode`` of a dry-run bridge. Its health also says ``dryRun: true`` and ``app.reachable: false``
# (detail ``bridge_dry_run``), and every journal answer carries ``dryRun: true``, so a runtime paired with it can
# never report an entry as written to Heptabase.
MODE_REAL = "real"
MODE_DRY_RUN = "dryRun"
DRY_RUN_DETAIL = "bridge_dry_run"
MAX_BODY_BYTES = 64 * 1024
MAX_CLI_OUTPUT_BYTES = 32 * 1024 * 1024
CLI_TIMEOUT_SECONDS = 30.0
HEALTH_CLI_TIMEOUT_SECONDS = 10.0
HEALTH_CACHE_SECONDS = 10.0
VERSION_CACHE_SECONDS = 300.0
MAX_CONCURRENT_READS = 2
MIN_TOKEN_CHARS = 16
_DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
_REASON = re.compile(r"[^A-Za-z0-9_.-]")
_APP_DOWN_MARKERS = ("cannot connect to the desktop app", "runtime was not found", "cli bundle was not found")
_LOG = logging.getLogger(SERVICE)


# --------------------------------------------------------------------------- errors


class BridgeError(Exception):
    """An error answered as ``{"error": {...}}``. ``written`` tells the R1 whether an
    append may have reached the journal: ``False`` (definitely not) or ``"unknown"``."""

    def __init__(self, status: int, code: str, message: str, *, retryable: bool = False,
                 written: Any = False, reason: Optional[str] = None) -> None:
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message
        self.retryable = retryable
        self.written = written
        self.reason = reason

    def payload(self) -> Dict[str, Any]:
        error: Dict[str, Any] = {"code": self.code, "message": self.message, "retryable": self.retryable,
                                 "written": self.written}
        if self.reason:
            error["reason"] = self.reason
        return {"error": error}


def _app_unavailable() -> BridgeError:
    return BridgeError(503, "heptabase_app_unavailable",
                       "The Heptabase app is not running on the Mac, or its CLI is turned off "
                       "(Heptabase > Settings > AI Features).", retryable=True, written=False)


# --------------------------------------------------------------------------- CLI


class HeptabaseCli:
    """Runs the ``heptabase`` CLI. Output is parsed, never logged."""

    mode = MODE_REAL

    def __init__(self, executable: Optional[str] = None) -> None:
        self._explicit = executable
        self._version: Optional[str] = None
        self._version_at = 0.0
        self._lock = threading.Lock()

    def executable(self) -> Optional[str]:
        if self._explicit:
            return self._explicit if os.access(self._explicit, os.X_OK) else None
        found = shutil.which("heptabase")
        if found:
            return found
        return FALLBACK_CLI if os.access(FALLBACK_CLI, os.X_OK) else None

    def version(self) -> Optional[str]:
        with self._lock:
            if self._version and time.monotonic() - self._version_at < VERSION_CACHE_SECONDS:
                return self._version
        executable = self.executable()
        if executable is None:
            return None
        try:
            done = subprocess.run([executable, "--version"], stdin=subprocess.DEVNULL, capture_output=True,
                                  timeout=HEALTH_CLI_TIMEOUT_SECONDS, check=False)
        except (OSError, subprocess.SubprocessError):
            return None
        text = done.stdout.decode("utf-8", errors="replace").strip().splitlines()
        value = text[0].strip()[:32] if done.returncode == 0 and text else None
        with self._lock:
            self._version, self._version_at = value, time.monotonic()
        return value

    def run(self, args: List[str], *, timeout: float, append: bool = False) -> Dict[str, Any]:
        """Run one CLI command and return its JSON result.

        Failures are mapped to ``BridgeError``. For appends, ``written`` is
        ``False`` whenever the app answered with an error (the app validates
        before it changes the journal) and ``"unknown"`` when the CLI timed out
        or died without a clear answer.
        """
        unknown: Any = "unknown" if append else False
        executable = self.executable()
        if executable is None:
            raise BridgeError(503, "heptabase_cli_missing",
                              "The heptabase CLI was not found on the Mac. Install it from Heptabase > Settings.",
                              retryable=True, written=False)
        try:
            done = subprocess.run([executable, *args], stdin=subprocess.DEVNULL, capture_output=True,
                                  timeout=timeout, check=False)
        except subprocess.TimeoutExpired:
            raise BridgeError(504, "heptabase_cli_timeout", "The Heptabase CLI did not answer in time.",
                              retryable=True, written=unknown) from None
        except OSError:
            raise BridgeError(503, "heptabase_cli_missing", "The heptabase CLI could not be started.",
                              retryable=True, written=False) from None
        if len(done.stdout) > MAX_CLI_OUTPUT_BYTES:
            raise BridgeError(502, "heptabase_cli_output_too_large", "The Heptabase CLI answer was too large.",
                              retryable=False, written=unknown)
        if done.returncode == 0:
            try:
                value = json.loads(done.stdout.decode("utf-8"))
            except (UnicodeDecodeError, ValueError):
                value = None
            if isinstance(value, dict):
                return value
            raise BridgeError(502, "heptabase_cli_bad_output", "The Heptabase CLI answered with unreadable output.",
                              retryable=True, written=unknown)
        raise _cli_failure(done.stderr, unknown)


class DryRunHeptabaseCli:
    """Stands in for the ``heptabase`` CLI without touching Heptabase: appends are kept in this process's
    memory only (and answered like the real CLI, plus ``dryRun: true``), reads return them. The default for
    every bridge that is not the installed LaunchAgent copy (see ``cli_for``)."""

    mode = MODE_DRY_RUN

    def __init__(self) -> None:
        self._journal: Dict[str, List[str]] = {}
        self._lock = threading.Lock()

    def executable(self) -> Optional[str]:
        return CLI_DRY_RUN

    def version(self) -> Optional[str]:
        return CLI_DRY_RUN

    def entries(self, journal_date: str) -> List[str]:
        with self._lock:
            return list(self._journal.get(journal_date, []))

    def run(self, args: List[str], *, timeout: float, append: bool = False) -> Dict[str, Any]:
        if len(args) >= 3 and args[:2] == ["journal", "append"]:
            journal_date = args[2]
            path = args[4] if len(args) >= 5 and args[3] == "--content-file" else None
            if path is None:
                raise BridgeError(400, "invalid_content", "Dry run: no content file.", written=False)
            with open(path, "rb") as handle:
                content = handle.read().decode("utf-8", errors="replace")
            with self._lock:
                day = self._journal.setdefault(journal_date, [])
                day.append(content)
                digest = hashlib.md5("".join(day).encode("utf-8")).hexdigest()  # noqa: S324 - not security
            return {"date": journal_date, "title": journal_date, "contentMd5": digest, "dryRun": True}
        if len(args) >= 3 and args[:2] == ["journal", "read"]:
            paragraphs = [block for item in self.entries(args[2]) for block in item.split("\n\n") if block.strip()]
            document = {"type": "doc", "content": [
                {"type": "paragraph", "content": [{"type": "text", "text": text}]} for text in paragraphs]}
            content = json.dumps(document)
            return {"date": args[2], "title": args[2], "content": content, "dryRun": True,
                    "contentMd5": hashlib.md5(content.encode("utf-8")).hexdigest()}  # noqa: S324
        raise BridgeError(400, "heptabase_rejected", "Dry run: unsupported command.", reason="unsupported")


def is_installed_copy(here: Optional[str] = None, **decision: Any) -> bool:
    """True only for the copy install.sh installed for this user (``samrabbit_installed.is_installed_copy``: the
    account's real home, never $HOME, plus the install marker). ``decision`` (``home``, ``environ``) is for tests of
    the decision itself."""
    if installation is None:
        return False
    try:
        return installation.is_installed_copy(here or _HERE, **decision)
    except Exception:  # noqa: BLE001 - when in doubt, a dev copy
        return False


def default_cli_choice(here: Optional[str] = None, **decision: Any) -> str:
    """``auto`` (the real CLI) for the installed LaunchAgent copy, ``dry-run`` for any other copy (a checkout, a
    test, a copy in a temp HOME)."""
    return CLI_AUTO if is_installed_copy(here, **decision) else CLI_DRY_RUN


def cli_for(choice: Optional[str], *, here: Optional[str] = None, installed: Optional[bool] = None) -> Any:
    """The CLI for ``--cli``: a path (used as given), ``dry-run``, ``auto`` or nothing. ``auto`` and nothing are the
    real CLI on PATH for the installed copy only (``installed``, default: ``is_installed_copy(here)``), a dry run for
    any other copy: there only an explicit path reaches a CLI."""
    value = (choice or "").strip()
    if value == CLI_DRY_RUN:
        return DryRunHeptabaseCli()
    if value in ("", CLI_AUTO):
        installed_copy = is_installed_copy(here) if installed is None else installed
        return HeptabaseCli(None) if installed_copy else DryRunHeptabaseCli()
    return HeptabaseCli(os.path.expanduser(value))


def _cli_failure(stderr: bytes, unknown: Any) -> BridgeError:
    text = stderr.decode("utf-8", errors="replace")
    try:
        parsed = json.loads(text)
    except ValueError:
        parsed = None
    error = parsed.get("error") if isinstance(parsed, dict) else None
    if isinstance(error, dict):  # structured app error: {code, message, retryable}
        reason = _REASON.sub("", str(error.get("code", "")))[:64] or "rejected"
        if error.get("retryable") is True:
            return BridgeError(503, "heptabase_busy", "The Heptabase app asked to retry later.",
                               retryable=True, written=False, reason=reason)
        return BridgeError(422, "heptabase_rejected", "The Heptabase app rejected the request.",
                           retryable=False, written=False, reason=reason)
    message = (error if isinstance(error, str) else text).strip().lower()
    if any(marker in message for marker in _APP_DOWN_MARKERS):
        return _app_unavailable()
    if re.match(r"^http 5\d\d$", message):
        return BridgeError(503, "heptabase_app_error", "The Heptabase app failed while handling the request.",
                           retryable=True, written=unknown)
    if isinstance(error, str) and message:
        # The app's own validation errors arrive as a plain message and are raised before any write.
        return BridgeError(422, "heptabase_rejected", "The Heptabase app rejected the request.",
                           retryable=False, written=False, reason="rejected")
    return BridgeError(503, "heptabase_cli_failed", "The Heptabase CLI failed without an explanation.",
                       retryable=True, written=unknown)


# --------------------------------------------------------------------------- ProseMirror to text

_LIST_ITEMS = ("bullet_list_item", "numbered_list_item", "todo_list_item", "toggle_list_item")
_SKIPPED_BLOCKS = frozenset({"image", "video", "audio", "file", "embed", "horizontal_rule", "mention"})


def _inline_text(nodes: Any) -> str:
    parts: List[str] = []
    for node in nodes if isinstance(nodes, list) else []:
        if not isinstance(node, dict):
            continue
        kind = node.get("type")
        attrs = node.get("attrs") if isinstance(node.get("attrs"), dict) else {}
        if kind == "text":
            parts.append(str(node.get("text", "")))
        elif kind == "hard_break":
            parts.append("\n")
        elif kind == "date":
            parts.append(str(attrs.get("date") or ""))
        elif kind == "web":
            parts.append(str(attrs.get("title") or attrs.get("url") or ""))
        elif isinstance(node.get("content"), list):
            parts.append(_inline_text(node["content"]))
    return "".join(parts)


def prosemirror_lines(document: Any) -> List[str]:
    """Plain text lines for a ProseMirror journal: paragraphs, headings, list items
    (``- ``, ``1. ``, ``[ ] ``/``[x] ``, ``+ `` for toggles), quotes, code and tables.
    Marks are dropped; nested blocks are indented two spaces; empty blocks vanish."""
    lines: List[str] = []

    def emit(text: str, depth: int, marker: str) -> None:
        indent = "  " * depth
        first = True
        for piece in text.split("\n"):
            piece = piece.rstrip()
            if not piece.strip():
                continue
            lines.append(indent + (marker if first else " " * len(marker)) + piece)
            first = False

    def blocks(nodes: Any, depth: int, marker: str = "") -> None:
        number = 0
        for node in nodes if isinstance(nodes, list) else []:
            if not isinstance(node, dict):
                continue
            kind = node.get("type")
            if kind == "numbered_list_item":
                order = (node.get("attrs") or {}).get("order") if isinstance(node.get("attrs"), dict) else None
                number = order if isinstance(order, int) and not isinstance(order, bool) and order > 0 else number + 1
            else:
                number = 0
            block(node, depth, marker, number)

    def block(node: Dict[str, Any], depth: int, marker: str, number: int) -> None:
        kind = node.get("type")
        attrs = node.get("attrs") if isinstance(node.get("attrs"), dict) else {}
        content = node.get("content") if isinstance(node.get("content"), list) else []
        if kind in ("paragraph", "heading", "code_block", "math_display"):
            emit(_inline_text(content), depth, marker)
        elif kind in _LIST_ITEMS:
            if kind == "bullet_list_item":
                item = "- "
            elif kind == "numbered_list_item":
                item = f"{number}. "
            elif kind == "todo_list_item":
                item = "[x] " if attrs.get("checked") else "[ ] "
            else:
                item = "+ "
            head, rest = (content[0], content[1:]) if content else (None, [])
            if isinstance(head, dict):
                emit(_inline_text(head.get("content")), depth, marker + item)
            blocks(rest, depth + 1)
        elif kind == "blockquote":
            blocks(content, depth, marker + "> ")
        elif kind == "table":
            for row in content:
                cells = []
                for cell in (row.get("content") if isinstance(row, dict) and isinstance(row.get("content"), list) else []):
                    inner: List[str] = []
                    for child in cell.get("content", []) if isinstance(cell, dict) else []:
                        if isinstance(child, dict):
                            inner.append(_inline_text(child.get("content")).replace("\n", " ").strip())
                    cells.append(" ".join(part for part in inner if part))
                if any(cells):
                    emit(" | ".join(cells), depth, marker)
        elif kind == "bookmark":
            emit(str(attrs.get("title") or attrs.get("url") or ""), depth, marker)
        elif kind in _SKIPPED_BLOCKS:
            return
        else:
            blocks(content, depth, marker)

    if isinstance(document, dict):
        blocks(document.get("content"), 0)
    return lines


# --------------------------------------------------------------------------- token and clients


class TokenFile:
    """Bearer token read from a 0600 file; re-read when the file changes."""

    def __init__(self, path: str) -> None:
        self.path = os.path.expanduser(path)
        self._token: Optional[bytes] = None
        self._stamp: Optional[Tuple[float, int]] = None
        self._lock = threading.Lock()
        self.load()

    def load(self) -> bytes:
        info = os.stat(self.path)
        if info.st_mode & (stat.S_IRWXG | stat.S_IRWXO):
            os.chmod(self.path, 0o600)
            _LOG.warning("token file permissions tightened to 0600")
        with open(self.path, "rb") as handle:
            token = handle.read().strip()
        if len(token) < MIN_TOKEN_CHARS or any(byte <= 0x20 or byte >= 0x7F for byte in token):
            raise ValueError("the bridge token file is empty or malformed; run install.sh again")
        with self._lock:
            self._token, self._stamp = token, (info.st_mtime, info.st_size)
        return token

    def matches(self, presented: str) -> bool:
        try:
            info = os.stat(self.path)
            if (info.st_mtime, info.st_size) != self._stamp:
                self.load()
        except (OSError, ValueError):
            pass  # keep the last good token
        with self._lock:
            token = self._token or b""
        candidate = presented.encode("utf-8", errors="replace")
        return bool(token) and hmac.compare_digest(candidate, token)


_PRIVATE_V4 = tuple(ipaddress.ip_network(net) for net in
                    ("127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16"))
_PRIVATE_V6 = tuple(ipaddress.ip_network(net) for net in ("::1/128", "fc00::/7", "fe80::/10"))


def client_allowed(address: str) -> bool:
    """Only loopback and private-LAN peers may talk to the bridge."""
    try:
        ip = ipaddress.ip_address(address.split("%", 1)[0])
    except ValueError:
        return False
    if ip.version == 6 and ip.ipv4_mapped is not None:
        ip = ip.ipv4_mapped
    networks = _PRIVATE_V4 if ip.version == 4 else _PRIVATE_V6
    return any(ip in network for network in networks)


# --------------------------------------------------------------------------- server


def _today() -> str:
    return datetime.now().astimezone().date().isoformat()


def _valid_date(value: Any) -> str:
    if not isinstance(value, str) or not _DATE.match(value):
        raise BridgeError(400, "invalid_date", "date must be YYYY-MM-DD.")
    try:
        Date.fromisoformat(value)
    except ValueError:
        raise BridgeError(400, "invalid_date", "date is not a real calendar day.") from None
    return value


class BridgeServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address: Tuple[str, int], *, token: TokenFile, cli: Any,
                 cli_timeout: float = CLI_TIMEOUT_SECONDS, allow_any_client: bool = False,
                 mac_control: Optional[mac.MacControl] = None, sync_dir: Optional[str] = None,
                 desktop_token_file: Optional[str] = None,
                 genui_service: Optional[genui.GenUiService] = None,
                 calendar_writer: Any = None, mobile_service: Any = None, installed_copy: bool = False,
                 inbox_service: Any = None, capture_service: Any = None, briefing_service: Any = None) -> None:
        self.token = token
        self.installed_copy = installed_copy  # the installed LaunchAgent copy (``is_installed_copy``), else a dev copy
        self.cli = cli
        self.mac = mac_control or mac.MacControl(mac.CuaDriver())
        self.genui = genui_service or genui.GenUiService.create()  # its worker starts in main() (or tests)
        self.cli_timeout = cli_timeout
        self.allow_any_client = allow_any_client
        self.append_lock = threading.Lock()
        self.read_slots = threading.BoundedSemaphore(MAX_CONCURRENT_READS)
        self.scratch = tempfile.mkdtemp(prefix="samrabbit-bridge-")  # 0700
        self._health: Optional[Tuple[float, Dict[str, Any]]] = None
        self._health_lock = threading.Lock()
        self.sync: Any = None  # samrabbit_sync.SyncService when a sync folder is given
        self.calendar: Any = calendar_writer  # samrabbit_calendar.CalendarWriter (or UnavailableWriter)
        if self.calendar is None and gcal is not None:
            self.calendar = gcal.make_writer_or_unavailable() if installed_copy else _dev_calendar()
        self.mobile: Any = mobile_service  # samrabbit_mobile.MobileService (its worker starts in main() or tests)
        self.inbox: Any = inbox_service  # samrabbit_inbox.InboxService (its refresher starts in main() or tests)
        self.capture: Any = capture_service  # samrabbit_capture.CaptureService (its worker starts in main() or tests)
        self.briefing: Any = briefing_service  # samrabbit_briefing.BriefingService (its timer starts in main())
        super().__init__(address, BridgeHandler)
        if self.mobile is not None:
            self.mobile.attach(self)
        if self.inbox is not None:
            self.inbox.attach(self)
        for service in (self.capture, self.briefing):
            if service is not None:
                service.attach(self)
        if sync is not None and sync_dir:
            try:
                self.sync = sync.SyncService(sync_dir, desktop_token_file or sync.DEFAULT_DESKTOP_TOKEN_FILE,
                                             peer_allowed=client_allowed)
            except Exception:  # noqa: BLE001
                _LOG.exception("conversation sync unavailable")

    def server_close(self) -> None:
        super().server_close()
        shutil.rmtree(self.scratch, ignore_errors=True)
        self.mac.close()
        if self.sync is not None:
            self.sync.close()
        if self.calendar is not None:
            self.calendar.close()
        if self.mobile is not None:
            self.mobile.close()
        if self.inbox is not None:
            self.inbox.close()
        for service in (self.capture, self.briefing):
            if service is not None:
                service.close()
        self.genui.stop()

    def r1_heard(self, address: str) -> None:
        """A request with the bridge token (the R1's) got in from ``address``: the summaries' ``r1`` say when it was
        last around (``samrabbit_mobile.MobileService.r1_heard``; loopback, install.sh's own check, does not count)."""
        if self.mobile is None:
            return
        try:
            self.mobile.r1_heard(str(address))
        except Exception:  # noqa: BLE001 - never fails the R1's request
            _LOG.warning("r1 presence not recorded")

    def bridge_token_denied(self, handler: Any) -> Optional[BridgeError]:
        """The R1's rule for routes other modules serve (a voice note, the morning brief): a private-LAN peer (even
        with ``--allow-any-client``) with the bridge token. None when allowed (the R1 is then seen), else the error."""
        if not client_allowed(str(handler.client_address[0])):
            return BridgeError(403, "forbidden", "Only devices on the local network may use this bridge.")
        scheme, _, value = str(handler.headers.get("Authorization", "")).partition(" ")
        if scheme.lower() != "bearer" or not value.strip() or not self.token.matches(value.strip()):
            return BridgeError(401, "unauthorized", "A valid bridge token is required.")
        self.r1_heard(handler.client_address[0])
        return None

    @property
    def dry_run(self) -> bool:
        """True when journal writes never reach Heptabase (``--cli dry-run`` or the default for a checkout)."""
        return getattr(self.cli, "mode", MODE_REAL) == MODE_DRY_RUN

    def health(self) -> Dict[str, Any]:
        with self._health_lock:
            cached = self._health
            if cached and time.monotonic() - cached[0] < HEALTH_CACHE_SECONDS:
                return cached[1]
            version = self.cli.version()
            reachable = False
            detail: Optional[str] = None
            dry_run = self.dry_run
            if dry_run:
                detail = DRY_RUN_DETAIL  # answers, but never reaches Heptabase: not "reachable"
            elif version is None:
                detail = "heptabase_cli_missing"
            else:
                try:
                    self.cli.run(["journal", "read", _today()], timeout=HEALTH_CLI_TIMEOUT_SECONDS)
                    reachable = True
                except BridgeError as error:
                    detail = error.code
            try:
                capabilities: Dict[str, Any] = self.mac.capabilities()
            except Exception:  # Mac control must never break the journal's health check
                _LOG.warning("mac capabilities failed")
                capabilities = {"driver": {"available": False}, "features": {}}
            try:
                generated_ui: Dict[str, Any] = self.genui.capabilities()
            except Exception:  # generative UI must never break the journal's health check
                _LOG.warning("genui capabilities failed")
                generated_ui = {"available": False}
            try:
                calendar_write: Dict[str, Any] = self.calendar.capabilities() if self.calendar is not None \
                    else {"available": False}
            except Exception:  # calendar changes must never break the journal's health check
                _LOG.warning("calendar capabilities failed")
                calendar_write = {"available": False}
            try:
                mobile_health: Dict[str, Any] = self.mobile.health() if self.mobile is not None \
                    else {"available": False}
            except Exception:  # the mobile API must never break the journal's health check
                _LOG.warning("mobile health failed")
                mobile_health = {"available": False}
            helper = getattr(self.mobile, "assistant", None) if self.mobile is not None else None
            try:
                assistant_health: Dict[str, Any] = helper.health() if helper is not None \
                    else {"available": False, "reason": "assistant_missing"}
            except Exception:  # the assistant must never break the journal's health check
                _LOG.warning("assistant health failed")
                assistant_health = {"available": False, "reason": "check_failed"}
            try:
                inbox_health: Dict[str, Any] = self.inbox.health() if self.inbox is not None \
                    else {"available": False}
            except Exception:  # the desktop inbox must never break the journal's health check
                _LOG.warning("inbox health failed")
                inbox_health = {"available": False}
            extra: Dict[str, Any] = {}
            for name, service in (("capture", self.capture), ("briefing", self.briefing)):
                try:  # voice notes and the morning brief never break the journal's health check either
                    extra[name] = service.health() if service is not None else {"available": False}
                except Exception:  # noqa: BLE001
                    _LOG.warning("%s health failed", name)
                    extra[name] = {"available": False}
            value: Dict[str, Any] = {
                "ok": True, "service": SERVICE, "version": VERSION,
                "cli": {"available": version is not None, "version": version,
                        "mode": MODE_DRY_RUN if dry_run else MODE_REAL},
                "app": {"reachable": reachable, "detail": detail},
                "dryRun": dry_run,
                "copy": "installed" if self.installed_copy else "dev",
                "mac": capabilities,
                "sync": self.sync.health() if self.sync is not None else {"available": False},
                "genui": generated_ui,
                "calendarWrite": calendar_write,
                "mobile": mobile_health,
                "assistant": assistant_health,
                "inbox": inbox_health,
                **extra,
                "checkedAt": datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
            }
            self._health = (time.monotonic(), value)
            return value

    def append(self, journal_date: str, content: str) -> Dict[str, Any]:
        if not self.append_lock.acquire(timeout=self.cli_timeout + 5):
            raise BridgeError(503, "bridge_busy", "Another journal write is still running.", retryable=True)
        try:
            handle, path = tempfile.mkstemp(prefix="entry-", suffix=".md", dir=self.scratch)
            try:
                os.fchmod(handle, 0o600)
                with os.fdopen(handle, "wb") as file:
                    file.write(content.encode("utf-8"))
                result = self.cli.run(["journal", "append", journal_date, "--content-file", path],
                                      timeout=self.cli_timeout, append=True)
            finally:
                try:
                    os.unlink(path)
                except FileNotFoundError:
                    pass
        finally:
            self.append_lock.release()
        with self._health_lock:
            self._health = None
        value = {"date": str(result.get("date") or journal_date), "title": result.get("title"),
                 "contentMd5": result.get("contentMd5")}
        if self.dry_run or result.get("dryRun") is True:
            value["dryRun"] = True  # kept in this process only: nothing reached Heptabase
        return value

    def read(self, journal_date: str) -> Dict[str, Any]:
        if not self.read_slots.acquire(timeout=self.cli_timeout + 5):
            raise BridgeError(503, "bridge_busy", "Too many journal reads at once.", retryable=True)
        try:
            result = self.cli.run(["journal", "read", journal_date], timeout=self.cli_timeout)
        finally:
            self.read_slots.release()
        raw = result.get("content")
        try:
            document = json.loads(raw) if isinstance(raw, str) and raw else (raw if isinstance(raw, dict) else {})
        except ValueError:
            raise BridgeError(502, "heptabase_cli_bad_output", "The journal content was unreadable.",
                              retryable=True) from None
        value = {"date": str(result.get("date") or journal_date), "title": result.get("title"),
                 "text": "\n".join(prosemirror_lines(document)), "contentMd5": result.get("contentMd5")}
        if self.dry_run or result.get("dryRun") is True:
            value["dryRun"] = True  # this process's own copy, not the Heptabase journal
        return value


class BridgeHandler(BaseHTTPRequestHandler):
    server: BridgeServer
    server_version = "SamRabbitBridge/" + VERSION
    sys_version = ""
    timeout = 20  # socket timeout while reading a request

    def log_message(self, format: str, *args: Any) -> None:  # noqa: A002
        return  # the default line includes the raw request target; we log our own summary

    def do_GET(self) -> None:  # noqa: N802
        self._dispatch("GET")

    def do_POST(self) -> None:  # noqa: N802
        self._dispatch("POST")

    def do_PUT(self) -> None:  # noqa: N802
        self._dispatch("PUT")

    def do_DELETE(self) -> None:  # noqa: N802
        self._dispatch("DELETE")

    def _dispatch(self, method: str) -> None:
        started = time.monotonic()
        route = urlsplit(self.path).path
        if desktop_app is not None and desktop_app.handles(route):
            desktop_app.serve(self, method)  # its own auth (loopback + desktop token) and logging
            return
        status = 500
        for service in (self.server.capture, self.server.briefing):
            if service is not None and service.handles(route):
                # Voice notes and the morning brief: their routes under /v1/, /v1/mobile/ and /v1/desktop/, each with
                # its own auth (the bridge token, a phone's token, the desktop token), errors and logging.
                status, code = service.serve(self, method, route)
                _LOG.info("%s %s %s %dms%s", method, service.route_label(route), status,
                          int((time.monotonic() - started) * 1000), f" {code}" if code else "")
                return
        if self.server.inbox is not None and self.server.inbox.handles(route):
            # /v1/desktop/inbox*: the Agent Dock (loopback + desktop token), and its phone twin /v1/mobile/inbox*
            # (the mobile token); its own errors and logging. Before the mobile API, which owns the rest of /v1/mobile/.
            status, code = self.server.inbox.serve(self, method, route)
            _LOG.info("%s %s %s %dms%s", method, self.server.inbox.route_label(route), status,
                      int((time.monotonic() - started) * 1000), f" {code}" if code else "")
            return
        if self.server.mobile is not None and self.server.mobile.handles(route):
            # /v1/mobile/*: per-device tokens from LAN or Tailscale peers (its own auth, errors and logging); also the
            # SamRabbit window's twins of its routes under /v1/desktop/* (loopback + desktop token).
            status, code = self.server.mobile.serve(self, method, route)
            _LOG.info("%s %s %s %dms%s", method, self.server.mobile.route_label(route), status,
                      int((time.monotonic() - started) * 1000), f" {code}" if code else "")
            return
        if self.server.sync is not None and self.server.sync.handles(route):
            # /v1/sync/*: bearer + private peer from the R1, loopback + desktop token for the app.
            status, code = self.server.sync.serve(self, method, route)
            if method in ("POST", "PUT") and status < 400:
                self.server.r1_heard(self.client_address[0])  # the R1's own token got in: it is around
            _LOG.info("%s %s %s %dms%s", method, self.server.sync.route_label(route), status,
                      int((time.monotonic() - started) * 1000), f" {code}" if code else "")
            return
        try:
            if not client_allowed(self.client_address[0]) and \
                    (not self.server.allow_any_client or
                     route.startswith((_MAC_PREFIX, genui.ROUTE_PREFIX, _CALENDAR_PREFIX))):
                # Mac control and calendar changes never leave the local network, even with --allow-any-client.
                raise BridgeError(403, "forbidden", "Only devices on the local network may use this bridge.")
            if self._authorized():
                self.server.r1_heard(self.client_address[0])
            elif not self.server.genui.desktop_authorized(self, method, route):
                raise BridgeError(401, "unauthorized", "A valid bridge token is required.")
            status, payload = self._route(method, route)
        except BridgeError as error:
            status, payload = error.status, error.payload()
        except mac.MacError as error:
            status, payload = error.status, error.payload()
        except Exception:  # never leak details (or journal text) to the caller or the log
            _LOG.exception("unexpected failure on %s %s", method, route)
            status, payload = 500, BridgeError(500, "internal_error", "The bridge failed unexpectedly.",
                                               written="unknown").payload()
        self._send(status, payload)
        code = payload.get("error", {}).get("code") if isinstance(payload.get("error"), dict) else None
        _LOG.info("%s %s %s %dms%s", method, route if route in _ROUTES else "(other)", status,
                  int((time.monotonic() - started) * 1000), f" {code}" if code else "")

    def _authorized(self) -> bool:
        header = self.headers.get("Authorization", "")
        scheme, _, value = header.partition(" ")
        if scheme.lower() != "bearer" or not value.strip():
            return False
        return self.server.token.matches(value.strip())

    def _route(self, method: str, route: str) -> Tuple[int, Dict[str, Any]]:
        if route == "/health":
            self._require(method, "GET")
            return 200, self.server.health()
        if route == "/v1/heptabase/journal/append":
            self._require(method, "POST")
            body = self._json_body()
            journal_date = _valid_date(body.get("date"))
            content = body.get("content")
            if not isinstance(content, str) or not content.strip():
                raise BridgeError(400, "invalid_content", "content must be non-empty markdown text.")
            if "\x00" in content:
                raise BridgeError(400, "invalid_content", "content must not contain NUL characters.")
            return 200, self.server.append(journal_date, content)
        if route == "/v1/heptabase/journal/read":
            self._require(method, "GET")
            query = parse_qs(urlsplit(self.path).query, max_num_fields=4)
            values = query.get("date") or [""]
            return 200, self.server.read(_valid_date(values[0]))
        if route.startswith(_MAC_PREFIX):
            return self._mac_route(method, route)
        if route.startswith(genui.ROUTE_PREFIX):
            return self.server.genui.route(self, method, route)
        if route.startswith(_CALENDAR_PREFIX) and self.server.calendar is not None:
            return self.server.calendar.route(self, method, route)
        raise BridgeError(404, "not_found", "Not found.")

    def _mac_route(self, method: str, route: str) -> Tuple[int, Dict[str, Any]]:
        control = self.server.mac
        if route == "/v1/mac/state":
            self._require(method, "GET")
            return 200, control.state()
        if route == "/v1/mac/open":
            self._require(method, "POST")
            return 200, control.open(self._json_body())
        if route == "/v1/mac/read":
            self._require(method, "GET")
            query = self._query()
            return 200, control.read(_one(query, "app"), _number(query, "max"))
        if route == "/v1/mac/act":
            self._require(method, "POST")
            return 200, control.act(self._json_body())
        if route == "/v1/mac/screenshot":
            self._require(method, "GET")
            query = self._query()
            shot = control.screenshot(_one(query, "app"), _number(query, "max"))
            if self.server.sync is not None:  # keep it in the conversation (blobId, imageEventId)
                shot = self.server.sync.screenshot_taken(shot, _one(query, "conversation"))
            return 200, shot
        raise BridgeError(404, "not_found", "Not found.")

    def _query(self) -> Dict[str, List[str]]:
        return parse_qs(urlsplit(self.path).query, max_num_fields=8)

    @staticmethod
    def _require(method: str, expected: str) -> None:
        if method != expected:
            raise BridgeError(405, "method_not_allowed", f"Use {expected}.")

    def _json_body(self) -> Dict[str, Any]:
        if self.headers.get("Transfer-Encoding"):
            raise BridgeError(411, "length_required", "Send a Content-Length body.")
        try:
            length = int(self.headers.get("Content-Length", ""))
        except ValueError:
            raise BridgeError(411, "length_required", "Send a Content-Length body.") from None
        if length < 0 or length > MAX_BODY_BYTES:
            raise BridgeError(413, "body_too_large", f"The body must be at most {MAX_BODY_BYTES} bytes.")
        raw = self.rfile.read(length)
        try:
            value = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            raise BridgeError(400, "invalid_json", "The body must be a JSON object.") from None
        if not isinstance(value, dict):
            raise BridgeError(400, "invalid_json", "The body must be a JSON object.")
        return value

    def _send(self, status: int, payload: Dict[str, Any]) -> None:
        if isinstance(payload, genui.Raw):  # an image or an HTML document
            payload.write(self, status)
            return
        body = json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
        try:
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            if status == 401:
                self.send_header("WWW-Authenticate", 'Bearer realm="samrabbit-bridge"')
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(body)
        except OSError:
            pass  # the client went away


_MAC_PREFIX = "/v1/mac/"
_CALENDAR_PREFIX = "/v1/calendar/"
_ROUTES = frozenset({"/health", "/v1/heptabase/journal/append", "/v1/heptabase/journal/read", "/v1/mac/state",
                     "/v1/mac/open", "/v1/mac/read", "/v1/mac/act", "/v1/mac/screenshot",
                     genui.GENERATE_ROUTE, *(gcal.ROUTES if gcal is not None else ())})


def _one(query: Dict[str, List[str]], key: str) -> Optional[str]:
    values = query.get(key) or []
    value = values[0].strip() if values else ""
    if len(value) > 200:
        raise BridgeError(400, "invalid_query", f"{key} is too long.")
    return value or None


def _number(query: Dict[str, List[str]], key: str) -> Optional[int]:
    value = _one(query, key)
    if value is None:
        return None
    if not value.isdigit() or len(value) > 6:
        raise BridgeError(400, "invalid_query", f"{key} must be a whole number.")
    return int(value)


def _dev_calendar() -> Any:
    return gcal.UnavailableWriter("calendar_dev_copy", "This copy of the Mac bridge is not the installed one, so it "
                                  "does not change Google Calendar. Pass --composio <path> to use a Composio CLI "
                                  "explicitly.")


def t3_cli_for(choice: Optional[str], *, installed: bool) -> Optional[str]:
    """The T3 CLI a bridge may pair with: the installed copy uses ``choice`` (``auto``: the T3 Code app's own CLI);
    any other copy only an explicit path, never ``auto`` (``--t3-url`` alone never opts into the real T3 app CLI)."""
    value = (choice or "").strip()
    if installed:
        return value or None
    return value if value and value != t3.CLI_AUTO else t3.CLI_NONE


def make_server(host: str = DEFAULT_HOST, port: int = DEFAULT_PORT, *, token_file: str = DEFAULT_TOKEN_FILE,
                cli: Optional[str] = None, cli_timeout: float = CLI_TIMEOUT_SECONDS,
                allow_any_client: bool = False, driver: Optional[str] = None,
                mac_control: Optional[mac.MacControl] = None, sync_dir: Optional[str] = None,
                desktop_token_file: Optional[str] = None,
                genui_service: Optional[genui.GenUiService] = None, artifacts_dir: Optional[str] = None,
                claude: Optional[str] = None, agent_browser: Optional[str] = None,
                genui_model: Optional[str] = None, composio: Optional[str] = None,
                calendar_id: Optional[str] = None, calendar_writer: Any = None,
                mobile_devices_file: Optional[str] = None, t3_url: Optional[str] = None,
                t3_cli: Optional[str] = None, t3_token_file: Optional[str] = None, t3_hub: Any = None,
                mobile_timezone: Optional[str] = None, google_account: Optional[str] = None,
                mobile_hosts: Optional[List[str]] = None, mobile_service: Any = None,
                transcribe_helper: Optional[str] = None, assistant_dir: Optional[str] = None,
                assistant_model: Optional[str] = None, assistant_voice: Optional[str] = None,
                elevenlabs_key_file: Optional[str] = None, elevenlabs_url: Optional[str] = None,
                assistant_settings_file: Optional[str] = None, assistant_brain: Optional[str] = None,
                chatgpt_auth_file: Optional[str] = None, chatgpt_issuer: Optional[str] = None,
                realtime_python: Optional[str] = None, realtime_api: Optional[str] = None,
                inbox_dir: Optional[str] = None, inbox_launch: bool = False,
                inbox_service: Any = None, capture_dir: Optional[str] = None, capture_service: Any = None,
                briefing_dir: Optional[str] = None, briefing_settings_file: Optional[str] = None,
                briefing_service: Any = None) -> BridgeServer:
    """Conversation sync runs only with a ``sync_dir`` (the command line passes the default one). ``cli`` is a
    path, ``auto`` or ``dry-run``; only the installed copy uses the real CLI without a path (``cli_for``). T3 for the
    mobile API: the installed copy pairs with T3 Code itself; any other copy (a checkout, a test, a copy in a temp
    HOME) answers ``t3_dev_copy`` and never reaches T3 unless given ``t3_url``, and even then pairs only through an
    explicit ``t3_cli`` path (never the T3 Code app's own CLI); it is ``calendar_dev_copy`` unless given ``composio``.
    ``transcribe_helper``: the speech-to-text helper for ``/v1/mobile/transcribe`` (default: ``samrabbit-transcribe``
    next to this script, which install.sh builds). The watch's assistant (``samrabbit_assistant.make_service``): a dev
    copy runs it only with an explicit ``claude``, speaks with ElevenLabs only with an explicit ``elevenlabs_key_file``,
    and uses the realtime voice only with an explicit ``chatgpt_auth_file`` and ``realtime_python``. The desktop
    inbox (``samrabbit_inbox.make_service``): a dev copy keeps what was seen in memory unless given ``inbox_dir`` and
    opens no app or Terminal window unless ``inbox_launch``. Voice notes (``samrabbit_capture.make_service``) and the
    morning brief (``samrabbit_briefing.make_service``): a dev copy keeps them in a temp folder unless given
    ``capture_dir`` / ``briefing_dir``, classifies and composes only with an explicit ``claude``, and reads Gmail only
    with an explicit ``composio``."""
    installed_copy = is_installed_copy()  # decided once: the journal, T3 and the calendar agree
    if calendar_writer is None and gcal is not None and composio is None and not installed_copy:
        # A dev copy (a checkout, a test, a temp HOME) never changes the real Google Calendar unless given --composio.
        calendar_writer = _dev_calendar()
    if calendar_writer is None and gcal is not None:
        # A bad SAMRABBIT_CALENDAR_ID or an unusable temp folder turns calendar changes off, never the bridge.
        calendar_writer = gcal.make_writer_or_unavailable(composio, calendar_id=calendar_id)
    if mobile_service is None and mobile is not None:
        if t3_hub is None and (t3_url or installed_copy):
            t3_hub = t3.make_hub(t3_url or t3.DEFAULT_SERVER_URL, token_file=t3_token_file or t3.DEFAULT_TOKEN_FILE,
                                 cli=t3_cli_for(t3_cli, installed=installed_copy))
        helper = None
        if assistant is not None:
            helper = assistant.make_service(installed=installed_copy, claude=claude, workdir=assistant_dir,
                                            key_file=elevenlabs_key_file, tts_url=elevenlabs_url,
                                            model=assistant_model, voice=assistant_voice,
                                            settings_file=assistant_settings_file or assistant.DEFAULT_SETTINGS_FILE,
                                            brain=assistant_brain, chatgpt_auth_file=chatgpt_auth_file,
                                            chatgpt_issuer=chatgpt_issuer, realtime_python=realtime_python,
                                            realtime_api=realtime_api)
        mobile_service = mobile.MobileService(devices_file=mobile_devices_file or mobile.DEFAULT_DEVICES_FILE,
                                              t3_hub=t3_hub, desktop_token_file=desktop_token_file,
                                              timezone_name=mobile_timezone,
                                              google_account=google_account, hosts=mobile_hosts,
                                              bridge_version=VERSION, transcribe_helper=transcribe_helper,
                                              assistant=helper)
    if inbox_service is None and inbox is not None:
        try:
            inbox_service = inbox.make_service(installed=installed_copy, state_dir=inbox_dir, launch=inbox_launch)
        except OSError:  # an unusable folder turns the dock's list off, never the bridge
            _LOG.warning("desktop inbox unavailable")
    if capture_service is None and capture is not None:
        try:
            capture_service = capture.make_service(installed=installed_copy, folder=capture_dir, claude_path=claude,
                                                   timezone_name=mobile_timezone)
        except OSError:  # an unusable folder turns voice notes off, never the bridge
            _LOG.warning("voice notes unavailable")
    if briefing_service is None and briefing is not None:
        try:
            briefing_service = briefing.make_service(installed=installed_copy, folder=briefing_dir,
                                                     composio=composio, claude_path=claude,
                                                     settings_file=briefing_settings_file,
                                                     timezone_name=mobile_timezone)
        except OSError:  # an unusable folder turns the morning brief off, never the bridge
            _LOG.warning("morning brief unavailable")
    return BridgeServer((host, port), token=TokenFile(token_file),
                        cli=cli_for(cli, installed=installed_copy),
                        cli_timeout=cli_timeout, allow_any_client=allow_any_client,
                        mac_control=mac_control or mac.MacControl(mac.CuaDriver(driver)),
                        sync_dir=sync_dir, desktop_token_file=desktop_token_file,
                        genui_service=genui_service or genui.GenUiService.create(
                            artifacts_dir or genui.DEFAULT_ARTIFACTS_DIR, claude=claude,
                            agent_browser=agent_browser, model=genui_model),
                        calendar_writer=calendar_writer, mobile_service=mobile_service,
                        installed_copy=installed_copy, inbox_service=inbox_service,
                        capture_service=capture_service, briefing_service=briefing_service)


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="SamRabbit Mac bridge for the Heptabase journal.")
    parser.add_argument("--host", default=os.environ.get("SAMRABBIT_BRIDGE_HOST", DEFAULT_HOST))
    parser.add_argument("--port", type=int, default=int(os.environ.get("SAMRABBIT_BRIDGE_PORT", DEFAULT_PORT)))
    parser.add_argument("--token-file", default=os.environ.get("SAMRABBIT_BRIDGE_TOKEN_FILE", DEFAULT_TOKEN_FILE))
    parser.add_argument("--cli", default=os.environ.get("SAMRABBIT_HEPTABASE_CLI") or None,
                        help="the heptabase CLI: a path, 'auto' or 'dry-run' (never writes to Heptabase). The "
                             "installed LaunchAgent copy uses the real one on PATH ('auto', the default there); any "
                             "other copy is a dry run ('auto' included) unless given a path")
    parser.add_argument("--cli-timeout", type=float, default=CLI_TIMEOUT_SECONDS)
    parser.add_argument("--cua-driver", default=os.environ.get("SAMRABBIT_CUA_DRIVER") or None,
                        help="path to the cua-driver CLI (default: found on PATH or in the usual install folders)")
    parser.add_argument("--artifacts-dir", default=os.environ.get("SAMRABBIT_ARTIFACTS_DIR") or None,
                        help="where generated UIs are kept (default: ~/Library/Application Support/SamRabbit/artifacts)")
    parser.add_argument("--claude", default=os.environ.get("SAMRABBIT_CLAUDE") or None,
                        help="path to the Claude Code CLI (default: found on PATH or in ~/.local/bin)")
    parser.add_argument("--agent-browser", default=os.environ.get("SAMRABBIT_AGENT_BROWSER") or None,
                        help="path to agent-browser for rendering generated UIs")
    parser.add_argument("--genui-model", default=os.environ.get("SAMRABBIT_GENUI_MODEL") or None,
                        help="model for generated UIs (default claude-sonnet-5-5; or set it in ~/.config/samrabbit/genui.json)")
    parser.add_argument("--composio", default=None,
                        help="path to the Composio CLI for Google Calendar changes (default: $SAMRABBIT_COMPOSIO, "
                             "which install.sh records, then PATH, ~/.local/bin, /opt/homebrew/bin, /usr/local/bin)")
    parser.add_argument("--calendar-id", default=os.environ.get("SAMRABBIT_CALENDAR_ID") or None,
                        help="Google calendar the R1 writes to (default: primary)")
    parser.add_argument("--allow-any-client", action="store_true",
                        help="accept peers outside loopback/private networks (not recommended)")
    parser.add_argument("--sync-dir", default=os.environ.get("SAMRABBIT_SYNC_DIR") or
                        (sync.DEFAULT_SYNC_DIR if sync is not None else ""),
                        help="conversation sync store (empty turns sync off)")
    parser.add_argument("--desktop-token-file", default=os.environ.get("SAMRABBIT_DESKTOP_TOKEN_FILE") or None,
                        help="token the SamRabbit desktop app sends (default ~/.config/samrabbit/desktop-token)")
    parser.add_argument("--mobile-devices-file", default=os.environ.get("SAMRABBIT_MOBILE_DEVICES_FILE") or None,
                        help="paired iPhones and watches (token hashes; default ~/.config/samrabbit/mobile-devices.json)")
    parser.add_argument("--t3-url", default=os.environ.get("SAMRABBIT_T3_URL") or None,
                        help="T3 Code server for the mobile API (default http://127.0.0.1:3773 for the installed "
                             "copy; a copy run from a checkout talks to T3 only when given this)")
    parser.add_argument("--t3-cli", default=os.environ.get("SAMRABBIT_T3_CLI") or None,
                        help="the T3 CLI used to pair: 'auto' (inside the T3 Code app; the installed copy only) or a "
                             "path (a copy run from a checkout pairs only through an explicit path)")
    parser.add_argument("--t3-token-file", default=os.environ.get("SAMRABBIT_T3_TOKEN_FILE") or None,
                        help="the bridge's own T3 token (default ~/.config/samrabbit/t3-token)")
    parser.add_argument("--transcribe-helper", default=os.environ.get("SAMRABBIT_TRANSCRIBE_HELPER") or None,
                        help="speech-to-text helper for the watch and the phone (default: samrabbit-transcribe next "
                             "to this script, built by install.sh)")
    parser.add_argument("--assistant-dir", default=os.environ.get("SAMRABBIT_ASSISTANT_DIR") or None,
                        help="the watch assistant's working folder (default ~/Library/Application Support/SamRabbit/"
                             "assistant for the installed copy, a temp folder for any other)")
    parser.add_argument("--assistant-model", default=os.environ.get("SAMRABBIT_ASSISTANT_MODEL") or None,
                        help="the watch assistant's model (default claude-haiku-5-5, or assistant.model in "
                             "~/.config/samrabbit/assistant.json)")
    parser.add_argument("--assistant-voice", default=os.environ.get("SAMRABBIT_ASSISTANT_VOICE") or None,
                        help="the ElevenLabs voice id (default Jarvis, or assistant.voice in assistant.json)")
    parser.add_argument("--elevenlabs-key-file", default=os.environ.get("SAMRABBIT_ELEVENLABS_KEY_FILE") or None,
                        help="the ElevenLabs key (default ~/.config/samrabbit/elevenlabs-key for the installed copy; "
                             "a copy run from a checkout speaks with ElevenLabs only when given this)")
    parser.add_argument("--elevenlabs-url", default=os.environ.get("SAMRABBIT_ELEVENLABS_URL") or None,
                        help=argparse.SUPPRESS)  # a stand-in ElevenLabs (tests)
    parser.add_argument("--assistant-brain", default=os.environ.get("SAMRABBIT_ASSISTANT_BRAIN") or None,
                        choices=("auto", "realtime", "claude"),
                        help="the watch assistant's brain: auto (realtime when ChatGPT is connected, else Claude; the "
                             "default, or assistant.brain in assistant.json), realtime or claude")
    parser.add_argument("--chatgpt-auth-file", default=os.environ.get("SAMRABBIT_CHATGPT_AUTH_FILE") or None,
                        help="the Mac's ChatGPT login for the realtime voice (default ~/.config/samrabbit/"
                             "chatgpt-auth.json for the installed copy; a copy run from a checkout uses one only when "
                             "given this)")
    parser.add_argument("--realtime-python", default=os.environ.get("SAMRABBIT_REALTIME_PYTHON") or None,
                        help="the realtime venv's Python (default ~/Library/Application Support/SamRabbit/"
                             "realtime-venv/bin/python for the installed copy; a copy run from a checkout only when "
                             "given this)")
    parser.add_argument("--chatgpt-issuer", default=os.environ.get("SAMRABBIT_CHATGPT_ISSUER") or None,
                        help=argparse.SUPPRESS)  # a stand-in ChatGPT login (tests)
    parser.add_argument("--realtime-api-url", default=os.environ.get("SAMRABBIT_REALTIME_API_URL") or None,
                        help=argparse.SUPPRESS)  # a stand-in OpenAI signaling server (tests)
    parser.add_argument("--inbox-dir", default=os.environ.get("SAMRABBIT_INBOX_DIR") or None,
                        help="the Agent Dock inbox's state folder (what was seen; default ~/Library/Application "
                             "Support/SamRabbit/inbox for the installed copy; any other copy keeps it in memory)")
    parser.add_argument("--inbox-launch", action="store_true",
                        help="let a copy that is not the installed one open apps and Terminal windows for the dock")
    parser.add_argument("--capture-dir", default=os.environ.get("SAMRABBIT_CAPTURE_DIR") or None,
                        help="where voice notes are kept (default ~/Library/Application Support/SamRabbit/capture for "
                             "the installed copy; any other copy uses a temp folder)")
    parser.add_argument("--briefing-dir", default=os.environ.get("SAMRABBIT_BRIEFING_DIR") or None,
                        help="where morning briefs are kept (default ~/Library/Application Support/SamRabbit/briefing "
                             "for the installed copy; any other copy uses a temp folder)")
    parser.add_argument("--briefing-settings", default=os.environ.get("SAMRABBIT_BRIEFING_SETTINGS") or None,
                        help="the morning brief's settings (default ~/.config/samrabbit/briefing.json)")
    options = parser.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s", stream=sys.stderr)
    try:
        server = make_server(options.host, options.port, token_file=options.token_file, cli=options.cli,
                             cli_timeout=options.cli_timeout, allow_any_client=options.allow_any_client,
                             driver=options.cua_driver, sync_dir=options.sync_dir or None,
                             desktop_token_file=options.desktop_token_file,
                             artifacts_dir=options.artifacts_dir, claude=options.claude,
                             agent_browser=options.agent_browser, genui_model=options.genui_model,
                             composio=options.composio, calendar_id=options.calendar_id,
                             mobile_devices_file=options.mobile_devices_file, t3_url=options.t3_url,
                             t3_cli=options.t3_cli, t3_token_file=options.t3_token_file,
                             transcribe_helper=options.transcribe_helper, assistant_dir=options.assistant_dir,
                             assistant_model=options.assistant_model, assistant_voice=options.assistant_voice,
                             elevenlabs_key_file=options.elevenlabs_key_file, elevenlabs_url=options.elevenlabs_url,
                             assistant_brain=options.assistant_brain, chatgpt_auth_file=options.chatgpt_auth_file,
                             chatgpt_issuer=options.chatgpt_issuer, realtime_python=options.realtime_python,
                             realtime_api=options.realtime_api_url, inbox_dir=options.inbox_dir,
                             inbox_launch=options.inbox_launch, capture_dir=options.capture_dir,
                             briefing_dir=options.briefing_dir, briefing_settings_file=options.briefing_settings)
    except (OSError, ValueError) as error:
        _LOG.error("cannot start: %s", error)
        return 2
    atexit.register(server.server_close)

    def stop(_signum: int, _frame: Any) -> None:
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    server.genui.start()
    if server.mobile is not None:
        server.mobile.start()
    if server.inbox is not None:
        server.inbox.start()
    for service in (server.capture, server.briefing):
        if service is not None:
            service.start()
    cli_path = server.cli.executable()
    if server.dry_run:
        _LOG.warning("heptabase CLI: dry-run, journal writes stay in this process and never reach Heptabase "
                     "(pass --cli <path to the heptabase CLI> to use one)")
    composio_found = server.calendar is not None and server.calendar.cli.executable() is not None
    mobile_line = "off"
    if server.mobile is not None:
        mobile_health = server.mobile.health()
        voice = mobile_health.get("transcribe") or {}
        mobile_line = f"{mobile_health['devices']} devices, T3 {'paired' if mobile_health['t3']['paired'] else 'not paired'}" \
            f", transcription {'on' if voice.get('available') else 'off (' + str(voice.get('reason')) + ')'}"
        helper = getattr(server.mobile, "assistant", None)
        if helper is not None:
            state = helper.health()
            speech = state.get("voice") or {}
            live = state.get("realtime") or {}
            mobile_line += f", assistant {'on' if state.get('available') else 'off (' + str(state.get('reason')) + ')'}" \
                f" brain {state.get('brain')}" \
                f", realtime {'on' if live.get('available') else 'off (' + str(live.get('reason')) + ')'}" \
                f", voice {'on' if speech.get('available') else 'off (' + str(speech.get('reason')) + ')'}"
    _LOG.info("%s %s listening on %s:%d (%s copy, cli %s, cua-driver %s, sync %s, composio %s, mobile %s)", SERVICE,
              VERSION, options.host, server.server_address[1], "installed" if server.installed_copy else "dev",
              cli_path or "missing",
              "found" if server.mac.driver.executable() else "missing", "on" if server.sync is not None else "off",
              "found" if composio_found else "missing", mobile_line)
    server.serve_forever(poll_interval=0.5)
    _LOG.info("stopped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
