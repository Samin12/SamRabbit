"""The Agent Dock's inbox on the Mac bridge (``/v1/desktop/inbox*``): every agent on this Mac that is waiting for
Samin, working or done, in one list the SamRabbit desktop app shows at the bottom of the screen (CONTRACTS-WAVE6).

Sources (each optional; one that fails never empties the others):

* **T3 Code** threads, through the mobile API's own T3 session (``samrabbit_t3.T3Hub``; never a second session): the
  shell snapshot, statuses, open approvals and questions (read from the thread, a few per refresh), and T3's own
  dispatch for approve, answer, reply, stop and new tasks. Settled and snoozed threads that need nothing are left out.
* **Claude Code** CLI sessions: ``~/.claude/projects/<folder>/<session>.jsonl``, top level only (never
  ``subagents/``; sidechain records are skipped), and only sessions a person started in a terminal: the first record
  that names its ``entrypoint`` says ``cli`` (T3 and Agent SDK sessions say ``sdk-ts``, ``claude -p`` says ``sdk-cli``).
  The title is the session's ``custom-title`` / ``ai-title`` / ``summary`` record, else the first thing typed. The
  status comes from the last 64 KiB and, for a running CLI, from Claude Code's own registry of its processes
  (``~/.claude/sessions/<pid>.json``: ``busy``, ``idle``, or ``waiting`` with what for): a permission prompt is
  ``needs-approval`` ("Waiting for you in the terminal"; only the terminal can answer it). Without a registry entry
  the tail decides: an assistant ``tool_use`` with no ``tool_result`` after it and the file idle for 4 s means the
  prompt is waiting; text with ``end_turn`` is done; a file written in the last 15 s is working.
* **Codex** sessions: ``~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`` and nothing else under ``~/.codex`` (never
  ``auth.json``, ``config.toml`` or ``session_index.jsonl``: the walk starts inside ``sessions/``). Codex Desktop
  (originator ``Codex Desktop``) and the CLI (``codex_cli_rs``, ``codex-tui``); never T3's own Codex threads
  (originator ``T3 Code``: they are T3 items), ``codex exec`` runs or subagents; symlinks are never followed. The title
  is the first thing typed, looked for past the ~100 KB of instructions Codex Desktop writes first (up to 4 MB in,
  once). Status from the tail's events: ``task_started`` / ``task_complete`` (a failed turn is a ``task_complete``
  with an ``error``), ``turn_aborted``, an ``*_approval_request`` nothing answered yet (older Codex), ``error``.
  Codex writes no approval request into its rollouts today, so a tool call with no output that went quiet for 30 s
  "may be waiting" for Samin, unless the turn runs with approvals off (``approval_policy: never``).
* **SamRabbit chats**: the sync store's 6 most recent conversations (R1, Watch, iPhone, Mac), ``working`` while a
  reply is being made.

Claude and Codex sessions count only when written in the last 3 days. ``live`` (an interactive CLI owns the session
right now) comes from Claude Code's registry (its pids checked with ``ps -p`` at most every 5 s), else ``ps -ax`` (the
session id in the command line; at most every 30 s, only while a session is not in the registry) and ``lsof`` (the
working folder). A live session cannot be continued from here (``409 session_live``: answer
it where it runs); one that is not live is continued in a new Terminal window running ``claude --resume <id> --
<text>`` or ``codex resume <id> -- <text>`` in its folder, so Samin keeps the CLI's own permission prompts. A session
just resumed that way counts as live for 15 s (before ``ps`` can see it), so a second press never starts a second CLI.
A Claude or Codex session that failed needs Samin until he marked it seen; then it is idle ("Hit an error").

Routes (loopback peer + the desktop token only: the desktop sync API's rule, through ``samrabbit_mobile``):

* ``GET /v1/desktop/inbox?after=<revision>&wait=<0..25>`` -> ``{revision, updatedAt, counts: {needsYou, working,
  total}, sources: {t3: {connected, reason?}, claude: {available, reason?}, codex: {available, reason?}, samrabbit:
  {available}}, items}``. With ``after`` equal to the current revision the answer waits up to ``wait`` seconds for a
  change. ``revision`` grows by one whenever what the list shows changes (a hash of it); it starts from the time in
  ms, so a bridge started again is always past what it gave out before.
* ``GET /v1/desktop/inbox/items/<id>`` -> ``{item, messages: [{role, text, at}]}`` (the last 12, each at most 4000
  characters).
* ``POST /v1/desktop/inbox/items/<id>/approve {requestId, decision}`` · ``/answer {requestId, answers}`` ·
  ``/reply {text}`` (202) · ``/stop`` · ``/seen`` · ``/open`` -> ``{opened: true, how}``.
* ``GET /v1/desktop/inbox/targets`` -> ``{projects, agents, default}`` (where a new prompt can go: T3's projects, and
  the Claude and Codex providers T3 offers with their models, from T3's ``server.getConfig``).
* ``POST /v1/desktop/inbox/new {text, projectId?, agent?, model?, title?}`` -> ``202 {itemId: "t3:<id>", ...}``.

An item: ``{id: "t3:<threadId>" | "claude:<sessionId>" | "codex:<threadId>" | "chat:<conversationId>", source, agent,
title, project, cwd, status: needs-approval | needs-input | error | done | working | idle, statusLabel, summary (at
most 240 characters: what it needs, else its last answer), updatedAt, unread, pending: {approvals, inputs}, can,
live, progress, phase}``. "Needs you" is needs-approval, needs-input, error and done-and-unread. Order: needs-approval,
needs-input, error, done and unread, working, then the rest; newest first within each; at most 60.

What Samin has seen lives in ``inbox-state.json`` (0600, in the inbox folder): T3's seen markers as on the R1 (a
thread is unread when it finished or started needing him after he last looked), and for the others the time of what
he saw. The first look at a source marks everything there as seen, so the dock starts quiet.

Opening things uses LaunchServices only (``/usr/bin/open``: no AppleScript, no Automation prompt). A copy of the
bridge that is not the installed one opens nothing (``dryRun: true``) unless started with ``--inbox-launch``.

Nothing is logged but counts, statuses and error codes: never a title, a prompt, a message, a command or a path.
Stdlib only, Python 3.9.
"""

from __future__ import annotations

from datetime import datetime, timezone
import hashlib
import json
import logging
import os
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
import threading
import time
from typing import Any, Callable, Dict, List, Optional, Tuple
from urllib.parse import parse_qs, unquote, urlsplit

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.append(_HERE)

import samrabbit_t3 as t3  # noqa: E402

try:  # the desktop rule when the mobile API is not loaded
    import samrabbit_sync as _sync  # type: ignore
except Exception:  # noqa: BLE001  # pragma: no cover
    _sync = None  # type: ignore[assignment]

_LOG = logging.getLogger("samrabbit-bridge.inbox")

PREFIX = "/v1/desktop/inbox"
DEFAULT_DIR = "~/Library/Application Support/SamRabbit/inbox"
STATE_FILE = "inbox-state.json"
MAX_ITEMS = 60
RECENT_DAYS = 3
MAX_CHATS = 6
MAX_SUMMARY_CHARS = 240
MAX_TITLE_CHARS = 120
MAX_MESSAGE_CHARS = 4000
MAX_MESSAGES = 12
MAX_WAIT_SECONDS = 25
MAX_BODY_BYTES = 64 * 1024
MAX_REPLY_CHARS = 20_000
FAST_REFRESH_SECONDS = 2.0  # while a client is long-polling ...
SLOW_REFRESH_SECONDS = 15.0  # ... otherwise, while one asked in the last DEMAND_SECONDS
DEMAND_SECONDS = 10 * 60.0
REUSE_SECONDS = 1.0  # a request reuses a list built this recently
TAIL_BYTES = 64 * 1024
HEAD_BYTES = 96 * 1024
DETAIL_BYTES = 768 * 1024  # how far back an item's messages are looked for
CODEX_META_BYTES = 1024 * 1024  # a rollout's first record (session_meta: it carries the instructions), at most
CODEX_TITLE_BYTES = 4 * 1024 * 1024  # how far into a rollout its first typed message is looked for (once)
CODEX_LINE_BYTES = 256 * 1024  # a longer record there (a pasted image) is read this far, for its first words
WAITING_AFTER_SECONDS = 4.0  # a tool call nobody answered for this long is a prompt waiting in the terminal
WORKING_SECONDS = 15.0  # a session written to this recently is working
CODEX_QUIET_SECONDS = 120.0  # an open Codex turn with nothing written for this long is not "working" any more
CODEX_ASK_SECONDS = 30.0  # an open Codex tool call this quiet, with approvals on, may be a prompt waiting
LAUNCH_GRACE_SECONDS = 15.0  # a session just resumed in Terminal counts as live this long (before ps can see it)
LIVE_CHECK_SECONDS = 5.0  # Claude Code's registry and its pids, at most this often
TABLE_SECONDS = 30.0  # the whole process table (when a session is not in the registry), at most this often
T3_DETAILS_PER_REFRESH = 4  # thread reads (open requests, the last answer) per refresh, ...
T3_DETAIL_BUDGET_SECONDS = 2.5  # ... within about this long
DRAFT_FRESH_MS = 60_000  # an R1 reply still being written this recently: the chat is working
MAX_DAY_FOLDERS = 60
MAX_REGISTRY_FILES = 64
MAX_SEEN = 4000
SCRIPT_KEEP_SECONDS = 120.0
T3_BUNDLE_ID = "com.t3tools.t3code"  # T3 Code (Alpha): its t3code:// scheme opens only sign-in and settings pages
TERMINAL_BUNDLE_ID = "com.apple.Terminal"
CHATGPT_BUNDLE_ID = "com.openai.codex"  # the ChatGPT app is Codex Desktop; it opens codex://threads/<id>
CODEX_THREAD_URL = "codex://threads/"
_APP_OWNED = ("/ChatGPT.app", "/T3 Code (Alpha).app")  # apps that run codex for their own threads

NEEDS_APPROVAL, NEEDS_INPUT, ERROR, DONE, WORKING, IDLE = "needs-approval", "needs-input", "error", "done", \
    "working", "idle"
NEEDS_YOU = frozenset({NEEDS_APPROVAL, NEEDS_INPUT, ERROR})
_GROUP = {NEEDS_APPROVAL: 0, NEEDS_INPUT: 1, ERROR: 2}
_MOBILE = {"needs_approval": NEEDS_APPROVAL, "needs_input": NEEDS_INPUT, "working": WORKING, "error": ERROR,
           "done": DONE, "idle": IDLE}
ACTIONS = ("approve", "answer", "reply", "stop", "seen", "open")
AGENT_DRIVERS = {"claude": "claudeAgent", "codex": "codex"}
AGENT_LABELS = {"claude": "Claude", "codex": "Codex"}
_ITEM_ID = re.compile(r"^(t3|claude|codex|chat):([A-Za-z0-9][A-Za-z0-9._:\-]{0,190})$")
_UUID = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
_MODEL = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/@+\-]{0,119}$")
_DAY = re.compile(r"^\d{1,4}$")
_REGISTRY = re.compile(r"^\d{1,10}\.json$")
_PLACEHOLDER = re.compile(r"\[(?:Image|Pasted text) #\d+[^\]]*\]")
# Lines a person did not type: a slash command's wrapper, the resume caveat, what the harness adds.
_NOT_TYPED = re.compile(r"^(?:<command-name>|<command-message>|<command-args>|<local-command|<system-reminder>|"
                        r"<user-memory|<bash-input>|<bash-stdout>|Caveat: The messages below|"
                        r"This session is being continued from|\[Request interrupted)")
# What Codex puts into the user's turn itself: tagged blocks (environment, instructions) and AGENTS.md.
_CODEX_INJECTED = re.compile(r"^\s*(?:<[a-z_]+[^>]*>|#\s*AGENTS\.md instructions)", re.IGNORECASE)
_CLAUDE_SELF_RUNNING = frozenset({"Task", "Agent", "TodoWrite", "TaskCreate", "TaskUpdate"})
_CLAUDE_EDITS = frozenset({"Edit", "Write", "MultiEdit", "NotebookEdit"})
_CLAUDE_STOPS = frozenset({"end_turn", "stop_sequence"})
_CODEX_DESKTOP = "Codex Desktop"
_CODEX_CLI = frozenset({"codex_cli_rs", "codex-tui", "codex_tui", "codex-cli", "codex_cli"})
_CODEX_STARTS = frozenset({"task_started", "turn_started"})
_CODEX_ENDS = frozenset({"task_complete", "turn_complete"})
_CODEX_TURN_EVENTS = _CODEX_STARTS | _CODEX_ENDS | {"turn_aborted"}
_CODEX_APPROVALS = frozenset({"exec_approval_request", "apply_patch_approval_request", "request_permissions"})
_CODEX_QUESTIONS = frozenset({"request_user_input", "elicitation_request"})
_CODEX_RESOLVES = frozenset({"exec_command_begin", "exec_command_end", "patch_apply_begin", "patch_apply_end",
                             "user_message", "agent_message"})
_CODEX_CALLS = frozenset({"function_call", "custom_tool_call", "local_shell_call"})
# Codex's own tools that run (or return) by themselves: an open one never waits for an approval.
_CODEX_SELF_RUNNING = frozenset({"wait", "wait_agent", "sleep", "spawn_agent", "send_message", "followup_task",
                                 "list_agents", "request_user_input_async", "update_plan", "view_image"})
_APPROVAL_TEXT = dict(t3._APPROVAL_TEXT)  # noqa: SLF001 - the same words as the phone


# --------------------------------------------------------------------------- errors and small helpers


class InboxError(Exception):
    def __init__(self, status: int, code: str, message: str, *, retryable: bool = False) -> None:
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message
        self.retryable = retryable

    def payload(self) -> Dict[str, Any]:
        return {"error": {"code": self.code, "message": self.message, "retryable": self.retryable}}


def _bad(code: str, message: str) -> InboxError:
    return InboxError(400, code, message)


def _unsupported(message: str) -> InboxError:
    return InboxError(409, "unsupported_action", message)


def iso_utc(epoch: float) -> str:
    return datetime.fromtimestamp(epoch, timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _epoch(value: Any) -> float:
    parsed = t3.parse_time(value)
    return parsed.timestamp() if parsed is not None else 0.0


def _clip(text: Any, limit: int) -> str:
    return t3.condense(str(text or ""), limit)


def _message_text(text: Any) -> str:
    value = str(text or "").strip()
    return value if len(value) <= MAX_MESSAGE_CHARS else value[:MAX_MESSAGE_CHARS - 1] + "…"


def _dict(value: Any) -> Dict[str, Any]:
    return value if isinstance(value, dict) else {}


def _typed_line(text: str) -> str:
    """The first line of ``text`` a person typed (Markdown marks flattened), or "" when it is a wrapper."""
    for line in str(text or "").replace("\r", "").split("\n"):
        clean = _PLACEHOLDER.sub("", line).strip()
        if not clean:
            continue
        if _NOT_TYPED.match(clean):
            return ""
        clean = re.sub(r"^#{1,6}\s+", "", clean)
        clean = re.sub(r"^[-*+]\s+", "", clean)
        clean = clean.replace("**", "").replace("`", "").strip()
        if clean:
            return clean
    return ""


def _typed(text: str) -> bool:
    return bool(_typed_line(text))


def _open_file(path: str) -> Any:
    """``path`` for reading, never through a symlink (ELOOP): a session file is only ever the file it is."""
    return os.fdopen(os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)), "rb")


def _read_head(path: str, limit: int = HEAD_BYTES) -> Tuple[bytes, bool]:
    """The first ``limit`` bytes and whether that was the whole file."""
    with _open_file(path) as handle:
        data = handle.read(limit + 1)
    return data[:limit], len(data) <= limit


def _read_tail(path: str, size: int, limit: int) -> Tuple[bytes, bool]:
    """The last ``limit`` bytes of a file of ``size`` bytes, and whether they start mid-line."""
    with _open_file(path) as handle:
        start = max(0, size - limit)
        handle.seek(start)
        return handle.read(limit), start > 0


def _records(data: bytes, *, partial_first: bool = False, partial_last: bool = False) -> List[Dict[str, Any]]:
    lines = data.split(b"\n")
    if partial_first and lines:
        lines = lines[1:]
    if partial_last and lines:
        lines = lines[:-1]
    out = []
    for line in lines:
        line = line.strip()
        if not line.startswith(b"{"):
            continue
        try:
            value = json.loads(line)
        except ValueError:
            continue
        if isinstance(value, dict):
            out.append(value)
    return out


# --------------------------------------------------------------------------- opening things on the Mac


class Launcher:
    """Opens things on this Mac with LaunchServices (``/usr/bin/open``): an app by bundle id or path, a URL, or a new
    Terminal window running one command (a private ``.command`` script that deletes itself when it starts). Never
    AppleScript, so never an Automation prompt. ``run`` is how a command is run (tests record it instead); a
    ``dry_run`` launcher opens nothing (a copy of the bridge that is not the installed one)."""

    OPEN = "/usr/bin/open"

    def __init__(self, *, run: Optional[Callable[[List[str]], None]] = None, scratch: Optional[str] = None,
                 dry_run: bool = False) -> None:
        self._run = run or self._spawn
        self._scratch = scratch
        self._made: Optional[str] = None  # a temp folder made for the scripts (removed at close)
        self.dry_run = dry_run
        self._lock = threading.Lock()
        self._scripts: List[Tuple[float, str]] = []

    @staticmethod
    def _spawn(argv: List[str]) -> None:
        try:
            done = subprocess.run(argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                  stderr=subprocess.DEVNULL, timeout=10.0, check=False)
        except (OSError, subprocess.SubprocessError):
            raise InboxError(503, "open_failed", "The Mac could not open that.", retryable=True) from None
        if done.returncode != 0:
            raise InboxError(503, "open_failed", "The Mac could not open that.", retryable=True)

    def _go(self, argv: List[str]) -> None:
        if not self.dry_run:
            self._run(argv)

    def app(self, bundle_id: str) -> None:
        self._go([self.OPEN, "-b", bundle_id])

    def app_path(self, path: str) -> None:
        self._go([self.OPEN, "-a", path])

    def url(self, url: str) -> None:
        self._go([self.OPEN, url])

    def terminal(self, cwd: str, argv: List[str]) -> str:
        """A new Terminal window that runs ``argv`` in ``cwd``; returns the script's path. The script (0700 in a 0700
        folder) holds the command line, so it deletes itself first; whatever Terminal never ran is removed after
        ``SCRIPT_KEEP_SECONDS``."""
        self._sweep()
        if self.dry_run:
            return ""
        folder = self._folder()
        handle, path = tempfile.mkstemp(prefix="samrabbit-", suffix=".command", dir=folder)
        body = "#!/bin/sh\n" + 'rm -f "$0"\n' + f"cd {shlex.quote(cwd)} || exit 1\n" + \
            "exec " + " ".join(shlex.quote(part) for part in argv) + "\n"
        try:
            os.fchmod(handle, 0o700)
            with os.fdopen(handle, "w", encoding="utf-8") as file:
                file.write(body)
        except OSError:
            try:
                os.unlink(path)
            except OSError:
                pass
            raise InboxError(503, "open_failed", "The Mac could not open a Terminal window.", retryable=True) from None
        with self._lock:
            self._scripts.append((time.monotonic(), path))
        self._run([self.OPEN, "-a", "Terminal", path])
        return path

    def _folder(self) -> str:
        with self._lock:
            if self._scratch is None:
                self._scratch = self._made = tempfile.mkdtemp(prefix="samrabbit-inbox-")  # 0700
            os.makedirs(self._scratch, mode=0o700, exist_ok=True)
            return self._scratch

    def _sweep(self, everything: bool = False) -> None:
        now = time.monotonic()
        with self._lock:
            old = [path for at, path in self._scripts if everything or now - at > SCRIPT_KEEP_SECONDS]
            self._scripts = [(at, path) for at, path in self._scripts if path not in old]
        for path in old:
            try:
                os.unlink(path)
            except OSError:
                pass

    def close(self) -> None:
        self._sweep(everything=True)
        with self._lock:
            made = self._made
            if made:
                self._scratch = self._made = None
        if made:
            shutil.rmtree(made, ignore_errors=True)


# --------------------------------------------------------------------------- the processes on this Mac


class Process:
    def __init__(self, pid: int, ppid: int, started: str, args: str) -> None:
        self.pid = pid
        self.ppid = ppid
        self.started = started  # ps's lstart in UTC ("Wed Oct 7 14:35:55 2026"), as Claude Code's registry has it
        self.args = args  # the command line (its first word is how the program was started)

    @property
    def program(self) -> str:
        return self.args.split(" ", 1)[0].rsplit("/", 1)[-1] if self.args else ""


_LSTART = r"\S{3}\s+\S{3}\s+\d{1,2}\s+\d\d:\d\d:\d\d\s+\d{4}"
# Terminals whose shells hang off a helper outside their app bundle.
_TERMINAL_HELPERS = (("/iTerm2/iTermServer", "/Applications/iTerm.app"),)


class Processes:
    """This Mac's processes, from ``ps`` (every ``ps -ax`` costs about 0.1 s on a busy Mac, so the whole table is
    read at most every ``TABLE_SECONDS``, and only when a session is not already accounted for by Claude Code's own
    registry; the registry's pids are checked with a cheap ``ps -p``), and ``lsof`` for a process's working folder
    (once per process)."""

    def __init__(self, *, ps: str = "/bin/ps", lsof: str = "/usr/sbin/lsof",
                 monotonic: Callable[[], float] = time.monotonic) -> None:
        self.ps = ps
        self.lsof = lsof
        self._monotonic = monotonic
        self._lock = threading.Lock()
        self._table: Optional[Tuple[float, Optional[Dict[int, Process]]]] = None
        self._cwds: Dict[Tuple[int, str], Optional[str]] = {}

    @staticmethod
    def _output(argv: List[str]) -> Optional[str]:
        try:
            done = subprocess.run(argv, stdin=subprocess.DEVNULL, capture_output=True, timeout=4.0, check=False,
                                  env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TZ": "UTC", "LC_ALL": "C"})
        except (OSError, subprocess.SubprocessError):
            return None
        return done.stdout.decode("utf-8", errors="replace") if done.returncode in (0, 1) else None

    def table(self, *, fresh: bool = False) -> Optional[Dict[int, Process]]:
        """pid -> Process for every process, or None when ``ps`` failed (then nobody can tell what is live)."""
        with self._lock:
            cached = self._table
            if not fresh and cached is not None and self._monotonic() - cached[0] < TABLE_SECONDS:
                return cached[1]
        listing = self._output([self.ps, "-axww", "-o", "pid=,ppid=,lstart=,args="])
        table: Optional[Dict[int, Process]] = None
        if listing is not None:
            table = {}
            for line in listing.splitlines():
                match = re.match(r"^\s*(\d+)\s+(\d+)\s+(" + _LSTART + r")\s?(.*)$", line)
                if match:
                    pid = int(match.group(1))
                    table[pid] = Process(pid, int(match.group(2)), " ".join(match.group(3).split()),
                                         match.group(4).strip())
        with self._lock:
            self._table = (self._monotonic(), table)
        return table

    def started(self, pids: List[int]) -> Optional[Dict[int, str]]:
        """pid -> start time for those of ``pids`` that run (one ``ps -p``), or None when ``ps`` failed."""
        if not pids:
            return {}
        listing = self._output([self.ps, "-ww", "-o", "pid=,lstart=", "-p", ",".join(str(pid) for pid in pids)])
        if listing is None:
            return None
        found: Dict[int, str] = {}
        for line in listing.splitlines():
            match = re.match(r"^\s*(\d+)\s+(" + _LSTART + r")\s*$", line)
            if match:
                found[int(match.group(1))] = " ".join(match.group(2).split())
        return found

    def cwd(self, process: Process) -> Optional[str]:
        key = (process.pid, process.started)
        with self._lock:
            if key in self._cwds:
                return self._cwds[key]
        output = self._output([self.lsof, "-a", "-p", str(process.pid), "-d", "cwd", "-Fn"])
        found = None
        for line in (output or "").splitlines():
            if line.startswith("n") and line[1:].startswith("/"):
                found = line[1:]
                break
        with self._lock:
            if len(self._cwds) > 256:
                self._cwds.clear()
            self._cwds[key] = found
        return found

    def app_of(self, pid: int, table: Optional[Dict[int, Process]] = None) -> Optional[str]:
        """The ``.app`` bundle a process runs under (its terminal: Terminal, iTerm, Ghostty, T3 Code, an editor),
        found by walking its parents (in ``table``, else a fresh one); None when none is (tmux, ssh, a LaunchAgent)."""
        table = table if table is not None else (self.table(fresh=True) or {})
        seen = set()
        current = table.get(pid)
        while current is not None and current.pid not in seen and current.pid > 1:
            seen.add(current.pid)
            if current.pid != pid:
                index = current.args.find(".app/")
                if index > 0 and current.args.startswith("/"):
                    return current.args[:index + 4]
                for marker, app in _TERMINAL_HELPERS:
                    if marker in current.args:
                        return app
            current = table.get(current.ppid)
        return None


def _normal_started(value: Any) -> str:
    return " ".join(str(value or "").split())


def _command(process: Process, names: Tuple[str, ...]) -> Optional[List[str]]:
    """The command line's words from the program on (``node .../codex.js resume x`` counts as ``codex.js``), when
    the program is one of ``names``; else None."""
    words = process.args.split()
    if len(words) > 1 and words[0].rsplit("/", 1)[-1] in ("node", "bun"):
        words = words[1:]
    if not words:
        return None
    program = words[0].rsplit("/", 1)[-1]
    return words if program in names or ("claude" in names and "/claude/versions/" in words[0]) else None


def _is_claude_cli(process: Process) -> bool:
    """An interactive ``claude`` (never ``claude -p``, the Agent SDK's, or its MCP server)."""
    words = _command(process, ("claude", "cli.js"))
    if words is None or (words[0].endswith("cli.js") and "claude-code" not in words[0]):
        return False
    return not any(word in ("-p", "--print", "--output-format", "--sdk-url", "mcp") for word in words[1:])


_CODEX_VALUE_OPTIONS = frozenset({"-c", "--config", "-m", "--model", "-p", "--profile", "-C", "--cd", "-s",
                                   "--sandbox", "-a", "--ask-for-approval", "-i", "--image", "--add-dir",
                                   "--enable", "--disable", "--remote", "--remote-auth-token-env"})
_CODEX_NOT_INTERACTIVE = frozenset({"app-server", "exec", "e", "mcp-server", "mcp", "proto", "login", "logout",
                                    "apply", "a", "cloud", "sandbox", "debug", "completion", "responses-api-proxy",
                                    "stdio-to-uds", "features"})


def _is_codex_cli(process: Process) -> bool:
    """The interactive Codex CLI (never its app-server, which Codex Desktop and T3 run, nor ``codex exec``): the
    first word after the options is no such subcommand."""
    words = _command(process, ("codex", "codex.js"))
    if words is None:
        return False
    index = 1
    while index < len(words) and words[index].startswith("-"):
        index += 2 if words[index] in _CODEX_VALUE_OPTIONS else 1
    return index >= len(words) or words[index] not in _CODEX_NOT_INTERACTIVE


# --------------------------------------------------------------------------- what Samin has seen


class SeenState:
    """``inbox-state.json`` (0600): ``{version, seen: {itemId: marker}, baselines: {source: true}}``; with no
    ``path`` (a copy of the bridge that is not the installed one) it lives in memory only."""

    def __init__(self, path: Optional[str], *, clock: Callable[[], float] = time.time) -> None:
        self.path = path
        self._clock = clock
        self._lock = threading.Lock()
        self._seen: Dict[str, Tuple[str, float]] = {}  # item id -> (marker, when it was stored)
        self._baselines: Dict[str, bool] = {}
        self._load()

    def _load(self) -> None:
        if not self.path:
            return
        try:
            with open(self.path, "r", encoding="utf-8") as handle:
                value = json.load(handle)
        except (OSError, ValueError):
            return
        if not isinstance(value, dict):
            return
        for key, entry in _dict(value.get("seen")).items():
            if isinstance(entry, dict) and isinstance(entry.get("marker"), str):
                self._seen[str(key)] = (entry["marker"], float(entry.get("at") or 0.0))
        self._baselines = {str(key): True for key, flag in _dict(value.get("baselines")).items() if flag is True}

    def _save_locked(self) -> None:
        if len(self._seen) > MAX_SEEN:  # the most recently stored ones stay (never by age: old threads stay seen)
            self._seen = dict(sorted(self._seen.items(), key=lambda pair: pair[1][1], reverse=True)[:MAX_SEEN])
        if not self.path:
            return
        data = json.dumps({"version": 1, "seen": {key: {"marker": marker, "at": round(at, 3)}
                                                  for key, (marker, at) in self._seen.items()},
                           "baselines": self._baselines}, separators=(",", ":"))
        folder = os.path.dirname(self.path) or "."
        try:
            os.makedirs(folder, mode=0o700, exist_ok=True)
            handle, temp = tempfile.mkstemp(prefix=".tmp-", dir=folder)
            try:
                os.fchmod(handle, 0o600)
                with os.fdopen(handle, "w", encoding="utf-8") as file:
                    file.write(data + "\n")
                os.replace(temp, self.path)
            except BaseException:
                try:
                    os.unlink(temp)
                except OSError:
                    pass
                raise
        except OSError:
            _LOG.warning("inbox state not saved")

    def get(self, item_id: str) -> Optional[str]:
        with self._lock:
            entry = self._seen.get(item_id)
            return entry[0] if entry else None

    def mark(self, item_id: str, marker: str) -> None:
        with self._lock:
            self._seen[item_id] = (marker, self._clock())
            self._save_locked()

    def baselined(self, source: str) -> bool:
        with self._lock:
            return self._baselines.get(source) is True

    def baseline(self, source: str, markers: Dict[str, str]) -> None:
        """The first look at a source: everything it shows now counts as seen."""
        with self._lock:
            now = self._clock()
            for key, marker in markers.items():
                if marker:
                    self._seen[key] = (marker, now)
            self._baselines[source] = True
            self._save_locked()


# --------------------------------------------------------------------------- Claude Code sessions


class _ClaudeFile:
    def __init__(self, path: str) -> None:
        self.path = path
        self.key = (0, 0)  # (mtime_ns, size) the tail was read at
        self.inode = 0
        self.head_read = False
        self.entrypoint: Optional[str] = None
        self.session_id = ""
        self.cwd: Optional[str] = None
        self.first_prompt = ""
        self.mtime = 0.0
        self.titles: Dict[str, str] = {}  # custom / ai / summary
        self.last_at = 0.0
        self.last_kind = ""  # assistant_text | assistant_tool | assistant_error | user_prompt | user_result | ...
        self.last_text = ""  # the last assistant words
        self.pending: List[Dict[str, Any]] = []  # tool calls nothing answered yet: {id, name, input}
        self.permission_mode: Optional[str] = None


def _claude_user_text(record: Dict[str, Any]) -> Optional[str]:
    """What a person said in a user record (None for tool results, meta records and wrappers)."""
    if record.get("isMeta") is True:
        return None
    content = _dict(record.get("message")).get("content")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        if any(isinstance(block, dict) and block.get("type") == "tool_result" for block in content):
            return None
        texts = [str(block.get("text") or "") for block in content
                 if isinstance(block, dict) and block.get("type") == "text"]
        return "\n".join(texts) if texts else None
    return None


_CUT_TEXT = re.compile(rb'"(?:content|text)"\s*:\s*"((?:[^"\\]|\\.){1,600})')


def _cut_prompt(head: bytes) -> List[str]:
    """The first words of a first message the head cut off (a pasted screenshot makes it hundreds of KB): read
    straight from its JSON, as far as the head goes."""
    cut = head.rsplit(b"\n", 1)[-1]
    opening = cut[:8192].replace(b" ", b"")
    if b'"type":"user"' not in opening and b'"role":"user"' not in opening:
        return []
    match = _CUT_TEXT.search(cut)
    if not match:
        return []
    fragment = re.sub(rb"\\u?[0-9a-fA-F]{0,3}$|\\$", b"", match.group(1))
    try:
        text = json.loads(b'"' + fragment + b'"')
    except ValueError:
        return []
    return [text] if isinstance(text, str) and _typed(text) else []


def _claude_assistant_text(record: Dict[str, Any]) -> str:
    content = _dict(record.get("message")).get("content")
    if isinstance(content, str):
        return content
    return "\n".join(str(block.get("text") or "") for block in content or []
                     if isinstance(block, dict) and block.get("type") == "text").strip()


class ClaudeSessions:
    """``~/.claude/projects/<folder>/<session>.jsonl`` (top level only), incrementally: a file is read again only
    when its size or mtime changed; a file that is not a terminal session is never read past its head."""

    source = "claude"

    def __init__(self, root: str) -> None:
        self.root = root  # ~/.claude
        self.projects = os.path.join(root, "projects")
        self.registry_dir = os.path.join(root, "sessions")
        self._files: Dict[str, _ClaudeFile] = {}
        self._lock = threading.Lock()
        self._scan_lock = threading.Lock()  # the refresher and a request never read the same file at once

    def status(self) -> Dict[str, Any]:
        if os.path.isdir(self.projects):
            return {"available": True}
        return {"available": False, "reason": "not_installed"}

    def scan(self, now: float) -> List[_ClaudeFile]:
        with self._scan_lock:
            return self._scan(now)

    def _scan(self, now: float) -> List[_ClaudeFile]:
        cutoff = now - RECENT_DAYS * 86400
        found: List[_ClaudeFile] = []
        seen_paths = set()
        try:
            folders = [entry for entry in os.scandir(self.projects) if entry.is_dir(follow_symlinks=False)]
        except OSError:
            return []
        for folder in folders:
            try:
                entries = list(os.scandir(folder.path))
            except OSError:
                continue
            for entry in entries:
                if not entry.name.endswith(".jsonl") or not entry.is_file(follow_symlinks=False):
                    continue
                try:
                    info = entry.stat(follow_symlinks=False)
                except OSError:
                    continue
                if info.st_mtime < cutoff:
                    continue
                seen_paths.add(entry.path)
                with self._lock:
                    record = self._files.get(entry.path)
                    if record is None or record.inode != info.st_ino or info.st_size < record.key[1]:
                        record = self._files[entry.path] = _ClaudeFile(entry.path)
                        record.inode = info.st_ino
                try:
                    self._update(record, info)
                except OSError:
                    continue
                if record.entrypoint == "cli" and record.session_id:
                    found.append(record)
        with self._lock:
            for path in [path for path in self._files if path not in seen_paths]:
                self._files.pop(path, None)
        return found

    def find(self, session_id: str) -> Optional[_ClaudeFile]:
        with self._lock:
            return next((record for record in self._files.values()
                         if record.session_id == session_id and record.entrypoint == "cli"), None)

    def _update(self, record: _ClaudeFile, info: os.stat_result) -> None:
        if not record.head_read:
            data, whole = _read_head(record.path)
            prompts: List[str] = []
            for item in _records(data, partial_last=not whole):
                if record.entrypoint is None and isinstance(item.get("entrypoint"), str) and item["entrypoint"]:
                    record.entrypoint = item["entrypoint"]
                if not record.cwd and isinstance(item.get("cwd"), str) and item["cwd"]:
                    record.cwd = item["cwd"]
                if not record.session_id and isinstance(item.get("sessionId"), str):
                    record.session_id = item["sessionId"]
                if item.get("type") == "user" and item.get("isSidechain") is not True and len(prompts) < 6:
                    text = _claude_user_text(item)
                    if text and _typed(text):
                        prompts.append(text)
            if not prompts and not whole:
                prompts = _cut_prompt(data)
            record.first_prompt = _typed_line(prompts[0]) if prompts else ""
            if not record.session_id:
                record.session_id = os.path.basename(record.path)[:-6]
            record.head_read = True
        if record.entrypoint not in (None, "cli"):
            return  # T3, the Agent SDK, ``claude -p``: never read further
        key = (info.st_mtime_ns, info.st_size)
        record.mtime = info.st_mtime
        if key == record.key:
            return
        data, partial = _read_tail(record.path, info.st_size, TAIL_BYTES)
        record.key = key
        items = _records(data, partial_first=partial)
        if record.entrypoint is None:  # a head of one huge first message (a pasted screenshot): the tail says
            record.entrypoint = next((str(item["entrypoint"]) for item in items
                                      if isinstance(item.get("entrypoint"), str) and item["entrypoint"]), None)
            if record.entrypoint != "cli":
                return
        self._read_tail(record, items)

    @staticmethod
    def _read_tail(record: _ClaudeFile, items: List[Dict[str, Any]]) -> None:
        pending: Dict[str, Dict[str, Any]] = {}
        last_kind, last_text, last_at = "", "", 0.0
        for item in items:
            kind = item.get("type")
            if kind == "custom-title" and isinstance(item.get("customTitle"), str):
                record.titles["custom"] = item["customTitle"]
            elif kind == "ai-title" and isinstance(item.get("aiTitle"), str):
                record.titles["ai"] = item["aiTitle"]
            elif kind == "summary" and isinstance(item.get("summary"), str):
                record.titles["summary"] = item["summary"]
            elif kind == "permission-mode" and isinstance(item.get("permissionMode"), str):
                record.permission_mode = item["permissionMode"]
            if kind not in ("user", "assistant") or item.get("isSidechain") is True:
                continue
            stamp = _epoch(item.get("timestamp"))
            last_at = max(last_at, stamp)
            if isinstance(item.get("permissionMode"), str):
                record.permission_mode = item["permissionMode"]
            if kind == "assistant":
                message = _dict(item.get("message"))
                if item.get("isApiErrorMessage") is True:
                    last_kind, last_text = "assistant_error", _claude_assistant_text(item) or last_text
                    continue
                for block in message.get("content") or []:
                    if isinstance(block, dict) and block.get("type") == "tool_use" and block.get("id"):
                        pending[str(block["id"])] = {"id": str(block["id"]), "name": str(block.get("name") or ""),
                                                     "input": _dict(block.get("input"))}
                text = _claude_assistant_text(item)
                if text:
                    last_text = text
                has_tool = any(isinstance(block, dict) and block.get("type") == "tool_use"
                               for block in message.get("content") or [])
                if has_tool:
                    last_kind = "assistant_tool"
                elif text or message.get("stop_reason") in _CLAUDE_STOPS:
                    last_kind = "assistant_text" if message.get("stop_reason") in _CLAUDE_STOPS else "assistant_partial"
                continue
            content = _dict(item.get("message")).get("content")
            if isinstance(content, list):
                for block in content:
                    if isinstance(block, dict) and block.get("type") == "tool_result":
                        pending.pop(str(block.get("tool_use_id") or ""), None)
            said = _claude_user_text(item)
            if said is not None and said.strip().startswith("[Request interrupted"):
                last_kind = "user_interrupt"
                pending.clear()
            elif said is not None and _typed(said):
                last_kind = "user_prompt"
                pending.clear()
            elif said is None and item.get("isMeta") is not True:
                last_kind = "user_result"
        record.pending = list(pending.values())
        record.last_kind = last_kind or record.last_kind
        record.last_text = last_text or record.last_text
        record.last_at = last_at or record.last_at

    def title(self, record: _ClaudeFile) -> str:
        for key in ("custom", "ai", "summary"):
            value = " ".join(str(record.titles.get(key) or "").split())
            if value:
                return _clip(value, MAX_TITLE_CHARS)
        return _clip(record.first_prompt, MAX_TITLE_CHARS) or "Claude Code session"

    def messages(self, record: _ClaudeFile) -> List[Dict[str, Any]]:
        """The last messages (user prompts and assistant words; tool steps left out)."""
        try:
            size = os.path.getsize(record.path)
            data, partial = _read_tail(record.path, size, DETAIL_BYTES)
        except OSError:
            return []
        out: List[Dict[str, Any]] = []
        last_id = None
        for item in _records(data, partial_first=partial):
            if item.get("isSidechain") is True or item.get("type") not in ("user", "assistant"):
                continue
            at = t3.normal_time(item.get("timestamp"))
            if item["type"] == "user":
                said = _claude_user_text(item)
                if said and _typed(said):
                    out.append({"role": "user", "text": _message_text(said), "at": at})
                    last_id = None
                continue
            text = _claude_assistant_text(item)
            if not text:
                continue
            message_id = _dict(item.get("message")).get("id")
            if message_id and message_id == last_id and out and out[-1]["role"] == "assistant":
                out[-1]["text"] = _message_text(out[-1]["text"] + "\n\n" + text)  # one answer, several blocks
                continue
            out.append({"role": "assistant", "text": _message_text(text), "at": at})
            last_id = message_id
        return out[-MAX_MESSAGES:]


def read_claude_registry(folder: str) -> Dict[str, Dict[str, Any]]:
    """Claude Code's own registry of running sessions (``<pid>.json``: pid, sessionId, cwd, status busy | idle |
    waiting, waitingFor, entrypoint, procStart), by session id. Only ``<digits>.json`` files are read."""
    found: Dict[str, Dict[str, Any]] = {}
    try:
        names = sorted(name for name in os.listdir(folder) if _REGISTRY.match(name))[:MAX_REGISTRY_FILES]
    except OSError:
        return found
    for name in names:
        try:
            with open(os.path.join(folder, name), "rb") as handle:
                value = json.loads(handle.read(64 * 1024))
        except (OSError, ValueError):
            continue
        if not isinstance(value, dict) or not isinstance(value.get("sessionId"), str) or \
                not isinstance(value.get("pid"), int):
            continue
        found[value["sessionId"]] = value
    return found


# --------------------------------------------------------------------------- Codex sessions


class _CodexFile:
    def __init__(self, path: str) -> None:
        self.path = path
        self.key = (0, 0)
        self.inode = 0
        self.head_read = False
        self.keep = False
        self.thread_id = ""
        self.cwd: Optional[str] = None
        self.desktop = False
        self.first_prompt = ""
        self.mtime = 0.0
        self.started_at = 0.0
        self.last_at = 0.0
        self.title_at = 0  # where the search for the first typed message goes on from ...
        self.title_done = False  # ... until it found one or went CODEX_TITLE_BYTES in
        self.turn = ""  # open | done | failed | aborted | ""
        self.error: Optional[str] = None
        self.last_text = ""
        self.pending: Optional[Dict[str, Any]] = None  # {"kind": approval | question, "payload": {...}}
        self.open_calls = 0
        self.open_call: Optional[Dict[str, str]] = None  # the newest tool call with no output yet: {id, name, ...}
        self.approval_policy: Optional[str] = None  # the latest turn_context's: never | on-request | untrusted | ...


def _codex_user_text(payload: Dict[str, Any]) -> Optional[str]:
    if payload.get("type") == "user_message":
        return str(payload.get("message") or "")
    if payload.get("type") == "message" and payload.get("role") == "user":
        parts = [str(part.get("text") or "") for part in payload.get("content") or []
                 if isinstance(part, dict) and part.get("type") == "input_text"
                 and not _CODEX_INJECTED.match(str(part.get("text") or ""))]
        return "\n\n".join(part for part in parts if part.strip()) or None
    return None


def _codex_clean(text: str) -> str:
    """Codex Desktop puts the files Samin attached in front of what he asked ("## My request:")."""
    index = text.find("## My request:")
    return (text[index + len("## My request:"):] if index >= 0 else text).replace("<image>", "").replace(
        "</image>", "").strip()


def _codex_assistant_text(payload: Dict[str, Any]) -> Optional[str]:
    if payload.get("type") == "agent_message":
        return str(payload.get("message") or "")
    if payload.get("type") == "message" and payload.get("role") == "assistant":
        return "\n".join(str(part.get("text") or "") for part in payload.get("content") or []
                         if isinstance(part, dict) and part.get("type") == "output_text").strip() or None
    return None


def _codex_said(item: Dict[str, Any]) -> Optional[str]:
    """What a person typed in a rollout record: a user message (as a response item or an event), or the
    ``item_completed`` event of a ``UserMessage`` (how Codex Desktop writes it now: an image there is a path)."""
    payload = _dict(item.get("payload"))
    if item.get("type") == "event_msg" and payload.get("type") == "item_completed":
        entry = _dict(payload.get("item"))
        if entry.get("type") != "UserMessage":
            return None
        parts = [str(part.get("text") or "") for part in entry.get("content") or []
                 if isinstance(part, dict) and part.get("type") == "text"]
        return "\n\n".join(part for part in parts if part.strip()) or None
    if item.get("type") in ("event_msg", "response_item"):
        return _codex_user_text(payload)
    return None


def _codex_prompt(said: Optional[str]) -> str:
    """The title a user message gives: its first typed line, "" for what Codex injected."""
    if not said or _CODEX_INJECTED.match(said):
        return ""
    return _typed_line(_codex_clean(said))


def _codex_cut_prompt(line: bytes) -> str:
    """The first typed words of a user message longer than ``CODEX_LINE_BYTES`` (a pasted image), read straight
    from its JSON as far as it was read."""
    opening = line[:8192].replace(b" ", b"")
    if b'"role":"user"' not in opening and b'"UserMessage"' not in opening:
        return ""
    for match in _CUT_TEXT.finditer(line):
        fragment = re.sub(rb"\\u?[0-9a-fA-F]{0,3}$|\\$", b"", match.group(1))
        try:
            text = json.loads(b'"' + fragment + b'"')
        except ValueError:
            continue
        prompt = _codex_prompt(text) if isinstance(text, str) else ""
        if prompt:
            return prompt
    return ""


def _codex_error(value: Any) -> Optional[str]:
    """A turn's failure as ``task_complete`` carries it (``error: {message, codex_error_info}``), else None."""
    if isinstance(value, dict):
        return str(value.get("message") or "").strip() or "Codex hit an error."
    if isinstance(value, str) and value.strip():
        return value.strip()
    return None


def _codex_call(payload: Dict[str, Any]) -> Dict[str, str]:
    """A tool call as the inbox shows it while it may wait: {id, name, kind, detail} (never the code it runs)."""
    name = str(payload.get("name") or payload.get("type") or "")
    command: Any = _dict(payload.get("action")).get("command")
    raw = payload.get("arguments")
    if command is None and isinstance(raw, str) and len(raw) <= 64 * 1024:
        try:
            arguments = json.loads(raw)
        except ValueError:
            arguments = None
        if isinstance(arguments, dict):
            command = arguments.get("command") or arguments.get("cmd")
    if isinstance(command, list):
        command = " ".join(str(part) for part in command)
    if isinstance(command, str) and command.strip():
        kind, detail = "command", "Wants to run: " + _clip(command, 200)
    elif name == "apply_patch":
        kind, detail = "file-change", "Wants to edit files"
    elif name in ("exec", "shell", "exec_command", "local_shell_call", "container.exec"):
        kind, detail = "command", "Wants to run a command"
    else:
        kind, detail = "permission", "Wants to use " + _clip(name or "a tool", 80)
    return {"id": str(payload.get("call_id") or payload.get("id") or "codex"), "name": name, "kind": kind,
            "detail": detail}


def _codex_meta(path: str) -> Tuple[Optional[Dict[str, Any]], int, bool]:
    """A rollout's first record when it is its ``session_meta``, where the next record starts, and whether that is
    settled (False while the first line is still being written: look again next time)."""
    with _open_file(path) as handle:
        line = handle.readline(CODEX_META_BYTES + 1)
    if not line.endswith(b"\n"):
        return None, 0, len(line) > CODEX_META_BYTES  # longer than any session_meta: not one the inbox reads
    try:
        value = json.loads(line)
    except ValueError:
        return None, len(line), True
    if not isinstance(value, dict) or value.get("type") != "session_meta":
        return None, len(line), True
    return value, len(line), True


def _skip_line(handle: Any, limit: int) -> Tuple[int, bool]:
    """Reads on to the end of the current line, at most ``limit`` bytes: (bytes read, whether the line ended)."""
    skipped = 0
    while skipped < limit:
        chunk = handle.readline(min(CODEX_LINE_BYTES, limit - skipped))
        skipped += len(chunk)
        if chunk.endswith(b"\n"):
            return skipped, True
        if not chunk:
            break
    return skipped, False


def _codex_policy(record: _CodexFile, item: Dict[str, Any]) -> None:
    policy = _dict(item.get("payload")).get("approval_policy")
    if isinstance(policy, str) and policy:
        record.approval_policy = policy


def _real_folder(path: str) -> bool:
    """A folder that is one (never a symlink to one)."""
    try:
        return stat.S_ISDIR(os.lstat(path).st_mode)
    except OSError:
        return False


def _codex_kept(meta: Dict[str, Any]) -> Optional[bool]:
    """Whose session this is: True for Codex Desktop, False for the CLI, None for one the inbox leaves out (T3's own
    Codex threads, ``codex exec``, subagents, Codex's own reviewers, anything else)."""
    originator = str(meta.get("originator") or "")
    source = meta.get("source")
    thread_source = meta.get("thread_source")
    if isinstance(source, dict) or (isinstance(source, str) and (source == "exec" or source.startswith("sub"))):
        return None
    if thread_source not in (None, "user"):
        return None
    if originator == _CODEX_DESKTOP:
        return True
    if originator in _CODEX_CLI or (not originator and source == "cli"):
        return False
    return None


class CodexSessions:
    """``~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl``, incrementally, and nothing else under ``~/.codex``: the walk
    starts inside ``sessions/`` and only opens ``rollout-*.jsonl`` files."""

    source = "codex"

    def __init__(self, sessions_root: str) -> None:
        self.root = sessions_root  # ~/.codex/sessions
        self._files: Dict[str, _CodexFile] = {}
        self._days: Dict[str, Tuple[int, List[str]]] = {}  # day folder -> (its mtime_ns, rollout names)
        self._lock = threading.Lock()
        self._scan_lock = threading.Lock()

    def status(self) -> Dict[str, Any]:
        if os.path.isdir(self.root):
            return {"available": True}
        return {"available": False, "reason": "not_installed"}

    def _day_folders(self) -> List[str]:
        folders: List[str] = []

        def numbered(path: str) -> List[str]:
            try:
                names = [name for name in os.listdir(path) if _DAY.match(name)]
            except OSError:
                return []
            return sorted((name for name in names if _real_folder(os.path.join(path, name))), key=int, reverse=True)

        for year in numbered(self.root):
            for month in numbered(os.path.join(self.root, year)):
                for day in numbered(os.path.join(self.root, year, month)):
                    folders.append(os.path.join(self.root, year, month, day))
                    if len(folders) >= MAX_DAY_FOLDERS:
                        return folders
        return folders

    def scan(self, now: float) -> List[_CodexFile]:
        with self._scan_lock:
            return self._scan(now)

    def _scan(self, now: float) -> List[_CodexFile]:
        cutoff = now - RECENT_DAYS * 86400
        found: List[_CodexFile] = []
        seen_paths = set()
        for folder in self._day_folders():
            try:
                folder_info = os.lstat(folder)
            except OSError:
                continue
            if not stat.S_ISDIR(folder_info.st_mode):
                continue  # a symlink: never followed out of sessions/
            cached = self._days.get(folder)
            if cached is None or cached[0] != folder_info.st_mtime_ns:
                try:
                    names = sorted(name for name in os.listdir(folder)
                                   if name.startswith("rollout-") and name.endswith(".jsonl"))
                except OSError:
                    continue
                cached = self._days[folder] = (folder_info.st_mtime_ns, names)
            for name in cached[1]:
                path = os.path.join(folder, name)
                try:
                    info = os.lstat(path)
                except OSError:
                    continue
                if info.st_mtime < cutoff or not stat.S_ISREG(info.st_mode):
                    continue  # old, or not a plain file (a symlink is never followed)
                seen_paths.add(path)
                with self._lock:
                    record = self._files.get(path)
                    if record is None or record.inode != info.st_ino or info.st_size < record.key[1]:
                        record = self._files[path] = _CodexFile(path)
                        record.inode = info.st_ino
                try:
                    self._update(record, info)
                except OSError:
                    continue
                if record.keep and record.thread_id:
                    found.append(record)
        with self._lock:
            for path in [path for path in self._files if path not in seen_paths]:
                self._files.pop(path, None)
        return found

    def find(self, thread_id: str) -> Optional[_CodexFile]:
        with self._lock:
            return next((record for record in self._files.values()
                         if record.thread_id == thread_id and record.keep), None)

    def _update(self, record: _CodexFile, info: os.stat_result) -> None:
        if not record.head_read:
            first, record.title_at, settled = _codex_meta(record.path)
            if first is None:
                record.head_read = settled
                return
            meta = _dict(first.get("payload"))
            kept = _codex_kept(meta)
            record.head_read = True
            record.keep = kept is not None
            record.desktop = kept is True
            record.thread_id = str(meta.get("id") or meta.get("session_id") or "").strip()
            record.cwd = str(meta.get("cwd") or "") or None
            record.started_at = _epoch(meta.get("timestamp") or first.get("timestamp"))
        if not record.keep:
            return
        key = (info.st_mtime_ns, info.st_size)
        record.mtime = info.st_mtime
        if key == record.key:
            return
        if not record.title_done:
            self._find_title(record)
        data, partial = _read_tail(record.path, info.st_size, TAIL_BYTES)
        items = _records(data, partial_first=partial)
        if partial and not record.turn and not any(
                _dict(item.get("payload")).get("type") in _CODEX_TURN_EVENTS for item in items):
            # No turn seen yet and none in the tail (Codex Desktop writes a settings event each time a thread is
            # looked at): further back, until one is.
            data, partial = _read_tail(record.path, info.st_size, DETAIL_BYTES)
            items = _records(data, partial_first=partial)
        record.key = key
        self._read_tail(record, items)

    @staticmethod
    def _find_title(record: _CodexFile) -> None:
        """The first thing Samin typed, looked for on from where the last look stopped (a thread just started may not
        have it yet) and given up ``CODEX_TITLE_BYTES`` in: Codex Desktop writes about 100 KB of instructions and
        context first. Whole records only; one longer than ``CODEX_LINE_BYTES`` (a pasted image) gives the first
        typed words it starts with, else is skipped."""
        with _open_file(record.path) as handle:
            handle.seek(record.title_at)
            while record.title_at < CODEX_TITLE_BYTES:
                line = handle.readline(CODEX_LINE_BYTES)
                if not line.endswith(b"\n"):
                    if len(line) < CODEX_LINE_BYTES:
                        return  # the end of what is written so far: on from here next time
                    prompt = _codex_cut_prompt(line)
                    if prompt:
                        record.first_prompt, record.title_done = prompt, True
                        return
                    skipped, ended = _skip_line(handle, CODEX_TITLE_BYTES - record.title_at - len(line))
                    if not ended:
                        record.title_done = record.title_at + len(line) + skipped >= CODEX_TITLE_BYTES
                        return  # still being written (from its start next time), or past the limit
                    record.title_at += len(line) + skipped
                    continue
                record.title_at += len(line)
                try:
                    item = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(item, dict):
                    continue
                if item.get("type") == "turn_context" and record.approval_policy is None:
                    _codex_policy(record, item)  # the first turn's, until the tail has a newer one
                prompt = _codex_prompt(_codex_said(item))
                if prompt:
                    record.first_prompt, record.title_done = prompt, True
                    return
        record.title_done = True  # nothing typed that far in: the thread keeps its generic title

    @staticmethod
    def _read_tail(record: _CodexFile, items: List[Dict[str, Any]]) -> None:
        turn, error, pending, last_text, last_at = record.turn, record.error, None, "", 0.0
        calls: Dict[str, Dict[str, str]] = {}
        events_text = any(item.get("type") == "event_msg" and _dict(item.get("payload")).get("type") ==
                          "agent_message" for item in items)
        for item in items:
            last_at = max(last_at, _epoch(item.get("timestamp")))
            payload = _dict(item.get("payload"))
            kind = payload.get("type")
            if item.get("type") == "turn_context":
                _codex_policy(record, item)
                continue
            if item.get("type") == "response_item":
                if kind in _CODEX_CALLS:
                    call = _codex_call(payload)
                    calls[call["id"] if call["id"] != "codex" else str(len(calls))] = call
                elif kind in ("function_call_output", "custom_tool_call_output"):
                    calls.pop(str(payload.get("call_id") or ""), None)
                    pending = None
                elif not events_text:
                    said = _codex_assistant_text(payload)
                    if said:
                        last_text = said
                continue
            if item.get("type") != "event_msg":
                continue
            if kind in _CODEX_STARTS:
                turn, error, pending, calls = "open", None, None, {}
            elif kind in _CODEX_ENDS:
                # A failed turn ends too: ``error: {message, codex_error_info}`` and no last answer.
                error = _codex_error(payload.get("error"))
                turn, pending, calls = ("failed" if error else "done"), None, {}
                said = payload.get("last_agent_message")
                if isinstance(said, str) and said.strip():
                    last_text = said
            elif kind == "turn_aborted":  # Esc: whatever went wrong before is over
                turn, error, pending, calls = "aborted", None, None, {}
            elif kind in _CODEX_APPROVALS:
                pending = {"kind": "approval", "type": kind, "payload": payload}
            elif kind in _CODEX_QUESTIONS:
                pending = {"kind": "question", "type": kind, "payload": payload}
            elif kind == "error":
                error = str(payload.get("message") or "Codex hit an error.")
            elif kind in _CODEX_RESOLVES:
                if kind == "agent_message":  # commentary mid-turn: answers nothing
                    said = _codex_assistant_text(payload)
                    if said:
                        last_text = said
                    continue
                pending = None
                if kind == "user_message":
                    turn, error = "open", None
        record.turn = turn
        record.error = error
        record.pending = pending
        record.open_calls = len(calls)
        record.open_call = list(calls.values())[-1] if calls else None
        record.last_text = last_text or record.last_text
        record.last_at = last_at or record.last_at

    def title(self, record: _CodexFile) -> str:
        return _clip(record.first_prompt, MAX_TITLE_CHARS) or ("Codex thread" if record.desktop else "Codex session")

    def messages(self, record: _CodexFile) -> List[Dict[str, Any]]:
        try:
            size = os.path.getsize(record.path)
            data, partial = _read_tail(record.path, size, DETAIL_BYTES)
        except OSError:
            return []
        items = _records(data, partial_first=partial)
        # Each turn can be written twice (an event and a response item): per role, the events when there are any.
        kinds = {_dict(item.get("payload")).get("type") for item in items if item.get("type") == "event_msg"}
        wanted = {"user": "event_msg" if "user_message" in kinds else "response_item",
                  "assistant": "event_msg" if "agent_message" in kinds else "response_item"}
        out: List[Dict[str, Any]] = []
        for item in items:
            payload = _dict(item.get("payload"))
            at = t3.normal_time(item.get("timestamp"))
            said = _codex_user_text(payload)
            if said is not None:
                said = _codex_clean(said)
                if item.get("type") == wanted["user"] and said and _typed(said):
                    out.append({"role": "user", "text": _message_text(said), "at": at})
                continue
            answer = _codex_assistant_text(payload)
            if answer and item.get("type") == wanted["assistant"]:
                out.append({"role": "assistant", "text": _message_text(answer), "at": at})
        return out[-MAX_MESSAGES:]


# --------------------------------------------------------------------------- the service


class _State:
    def __init__(self, revision: int, built_at: float, items: List[Dict[str, Any]], sources: Dict[str, Any],
                 counts: Dict[str, int]) -> None:
        self.revision = revision
        self.built_at = built_at  # monotonic
        self.updated_at = ""
        self.items = items
        self.sources = sources
        self.counts = counts


class _Route:
    def __init__(self, pattern: str, label: str, methods: Dict[str, str]) -> None:
        self.pattern = re.compile("^" + pattern + "$")
        self.label = label
        self.methods = methods


_ID = r"(?P<id>[a-z0-9]{2,8}(?::|%3[Aa])[A-Za-z0-9._:%\-]{1,200})"
ROUTES: Tuple[_Route, ...] = (
    _Route(r"/v1/desktop/inbox", "/v1/desktop/inbox", {"GET": "inbox"}),
    _Route(r"/v1/desktop/inbox/targets", "/v1/desktop/inbox/targets", {"GET": "targets"}),
    _Route(r"/v1/desktop/inbox/new", "/v1/desktop/inbox/new", {"POST": "new"}),
    _Route(r"/v1/desktop/inbox/items/" + _ID, "/v1/desktop/inbox/items/{id}", {"GET": "item"}),
    _Route(r"/v1/desktop/inbox/items/" + _ID + r"/(?P<action>approve|answer|reply|stop|seen|open)",
           "/v1/desktop/inbox/items/{id}/{action}", {"POST": "action"}),
)


class InboxService:
    """``handles(route)`` / ``serve(handler, method, route)`` for the bridge; ``attach(server)`` gives it the mobile
    API's T3 hub and desktop rule, the sync store and the voice assistant."""

    def __init__(self, *, state_dir: Optional[str] = None, home: Optional[str] = None,
                 launcher: Optional[Launcher] = None, processes: Any = None,
                 claude_cli: Optional[str] = None, codex_cli: Optional[str] = None,
                 clock: Callable[[], float] = time.time, monotonic: Callable[[], float] = time.monotonic) -> None:
        """``state_dir``: where ``inbox-state.json`` is kept (0700); None keeps what was seen in memory only."""
        self.home = os.path.expanduser(home or "~")
        self.state_dir = os.path.expanduser(state_dir) if state_dir else None
        if self.state_dir:
            os.makedirs(self.state_dir, mode=0o700, exist_ok=True)
            os.chmod(self.state_dir, 0o700)
        self._clock = clock
        self._monotonic = monotonic
        self.seen = SeenState(os.path.join(self.state_dir, STATE_FILE) if self.state_dir else None, clock=clock)
        self.launcher = launcher or Launcher(scratch=os.path.join(self.state_dir, "scripts") if self.state_dir
                                             else None)
        self.processes = processes if processes is not None else Processes(monotonic=monotonic)
        self.claude = ClaudeSessions(os.path.join(self.home, ".claude"))
        self.codex = CodexSessions(os.path.join(self.home, ".codex", "sessions"))
        self._claude_cli = claude_cli
        self._codex_cli = codex_cli
        self.server: Any = None
        self._lock = threading.RLock()
        self._refresh_lock = threading.Lock()
        self._changed = threading.Condition(threading.Lock())
        # The revision starts from the time (in ms), so a bridge started again never answers a dock's ``after`` from
        # before with a list that changed meanwhile: it is always past every revision an earlier run gave out.
        self._state = _State(int(clock() * 1000), -1e12, [], {}, {"needsYou": 0, "working": 0, "total": 0})
        self._digest = ""  # "" until the first list is built
        self._launched: Dict[str, float] = {}  # item id -> when a Terminal window was opened to resume it
        self._t3_details: Dict[str, Tuple[str, Any, str]] = {}  # thread id -> (updatedAt, PendingRequests, answer)
        self._t3_threads: Dict[str, Dict[str, Any]] = {}  # the last snapshot's threads (for seen markers)
        self._live: Tuple[float, Dict[str, Dict[str, Any]]] = (-1e12, {})  # (read at, Claude Code's registry)
        self._waiters = 0
        self._last_wait = -1e12
        self._demand_at = -1e12
        self._worker: Optional[threading.Thread] = None
        self._wake = threading.Event()
        self._stopping = threading.Event()

    # ------------------------------------------------------------------ lifecycle
    def attach(self, server: Any) -> None:
        self.server = server

    def start(self) -> None:
        """The background refresher: about every 2 s while a client long-polls, 15 s while one asked in the last
        ten minutes, otherwise asleep (the next request then reads everything itself)."""
        if self._worker is not None:
            return
        self._worker = threading.Thread(target=self._work, name="samrabbit-inbox", daemon=True)
        self._worker.start()

    def close(self) -> None:
        self._stopping.set()
        self._wake.set()
        with self._changed:
            self._changed.notify_all()
        if self._worker is not None:
            self._worker.join(timeout=3.0)
            self._worker = None
        self.launcher.close()

    def _work(self) -> None:
        while not self._stopping.is_set():
            idle = self._monotonic() - self._demand_at > DEMAND_SECONDS
            fast = self._waiters > 0 or self._monotonic() - self._last_wait < 5.0
            self._wake.wait(timeout=60.0 if idle else (FAST_REFRESH_SECONDS if fast else SLOW_REFRESH_SECONDS))
            self._wake.clear()
            if self._stopping.is_set():
                break
            if self._monotonic() - self._demand_at > DEMAND_SECONDS:
                continue
            try:
                self.refresh(force=True)
            except Exception:  # noqa: BLE001 - the refresher never stops
                _LOG.warning("inbox refresh failed")

    def _worker_alive(self) -> bool:
        return self._worker is not None and self._worker.is_alive()

    def health(self) -> Dict[str, Any]:
        state = self._state
        return {"available": True, "revision": state.revision, "items": len(state.items),
                "needsYou": state.counts.get("needsYou", 0)}

    # ------------------------------------------------------------------ wiring
    def _hub(self) -> Any:
        mobile = getattr(self.server, "mobile", None)
        return getattr(mobile, "t3", None) if mobile is not None else None

    def _store(self) -> Any:
        service = getattr(self.server, "sync", None)
        return getattr(service, "store", None) if service is not None else None

    def _assistant(self) -> Any:
        mobile = getattr(self.server, "mobile", None)
        return getattr(mobile, "assistant", None) if mobile is not None else None

    def _desktop_denied(self, handler: Any) -> Optional[Exception]:
        mobile = getattr(self.server, "mobile", None)
        if mobile is not None and hasattr(mobile, "desktop_denied"):
            return mobile.desktop_denied(handler)
        service = getattr(self.server, "sync", None)
        if service is not None:
            return service.desktop_denied(handler)
        if _sync is not None:
            return _sync.desktop_request_denied(handler)
        return InboxError(503, "desktop_unavailable", "The desktop token check is not installed.")

    # ------------------------------------------------------------------ building the list
    def refresh(self, *, force: bool = False, blocking: bool = True) -> _State:
        """Read every source (incrementally) and rebuild the list; the revision moves only when what it shows
        changed. One refresh at a time: a caller that waited for another one uses its result; one that would not
        wait (``blocking=False``) gets the list as it is."""
        started = self._monotonic()
        if not self._refresh_lock.acquire(blocking=blocking):
            return self._state
        try:
            state = self._state
            if state.built_at >= started or (not force and self._monotonic() - state.built_at < REUSE_SECONDS):
                return state
            now = self._clock()
            items: List[Dict[str, Any]] = []
            sources: Dict[str, Any] = {}
            for name, reader in (("t3", self._t3_items), ("claude", self._claude_items),
                                 ("codex", self._codex_items), ("samrabbit", self._chat_items)):
                try:
                    found, status = reader(now)
                except Exception:  # noqa: BLE001 - one source never empties the others
                    _LOG.warning("inbox %s failed", name)
                    found, status = [], ({"connected": False, "reason": "failed"} if name == "t3" else
                                         {"available": False, "reason": "failed"})
                items.extend(found)
                sources[name] = status
            items.sort(key=_rank)
            counts = {"needsYou": sum(1 for item in items if _needs_you(item)),
                      "working": sum(1 for item in items if item["status"] == WORKING), "total": len(items)}
            items = items[:MAX_ITEMS]
            digest = hashlib.sha256(json.dumps({"items": items, "sources": sources}, sort_keys=True,
                                               ensure_ascii=False).encode("utf-8")).hexdigest()
            with self._changed:
                revision = self._state.revision
                updated_at = self._state.updated_at
                if digest != self._digest:
                    revision += 1
                    updated_at = iso_utc(now)
                    self._digest = digest
                    _LOG.debug("inbox revision %d (%d items, %d need you)", revision, counts["total"],
                               counts["needsYou"])
                fresh = _State(revision, self._monotonic(), items, sources, counts)
                fresh.updated_at = updated_at or iso_utc(now)
                self._state = fresh
                self._changed.notify_all()
            return fresh
        finally:
            self._refresh_lock.release()

    def _current(self) -> _State:
        state = self._state
        if self._monotonic() - state.built_at < REUSE_SECONDS:
            return state
        return self.refresh(blocking=not self._digest)  # a slow T3 never holds up a list that exists

    def _demand(self) -> None:
        idle = self._monotonic() - self._demand_at > DEMAND_SECONDS
        self._demand_at = self._monotonic()
        if idle:
            self._wake.set()

    def _changed_now(self) -> None:
        """After an action: rebuild soon (and tell the refresher)."""
        with self._changed:
            self._state.built_at = -1e12
        self._wake.set()

    # ------------------------------------------------------------------ T3
    def _t3_items(self, now: float) -> Tuple[List[Dict[str, Any]], Dict[str, Any]]:
        hub = self._hub()
        if hub is None:
            return [], {"connected": False, "reason": "t3_unavailable"}
        if not hub.available():
            return [], {"connected": False, "reason": str(getattr(hub, "code", None) or "t3_unavailable")}
        try:
            snapshot = hub.snapshot(max_age=1.5)
        except t3.T3Error as error:
            return [], {"connected": False, "reason": error.code}
        moment = datetime.fromtimestamp(now, timezone.utc)
        rows: List[Tuple[Dict[str, Any], Dict[str, Any]]] = []
        for thread_id, thread in snapshot.threads.items():
            base = hub.item(thread, snapshot.titles)
            status = _MOBILE.get(str(base.get("status")), IDLE)
            if status in (DONE, IDLE) and (t3.is_settled(thread) or t3.is_snoozed(thread, moment)):
                continue  # T3's own "settled" and "snoozed" shelves
            rows.append((thread, base))
        with self._lock:
            self._t3_threads = {str(thread.get("id")): thread for thread, _base in rows}
        if not self.seen.baselined("t3"):
            self.seen.baseline("t3", {"t3:" + str(thread.get("id")): t3.seen_marker(thread)
                                      for thread in snapshot.threads.values()})
        self._read_t3_details(hub, rows)
        workspace = {record["id"]: record.get("workspaceRoot") or None for record in snapshot.records}
        drivers = self._drivers(hub)
        items = [self._t3_item(thread, base, workspace, drivers) for thread, base in rows]
        return items, {"connected": True}

    def _read_t3_details(self, hub: Any, rows: List[Tuple[Dict[str, Any], Dict[str, Any]]]) -> None:
        """Open requests and last answers for the threads whose ``updatedAt`` changed: needs-you first, a few per
        refresh within a budget (working threads show their step instead)."""
        wanted = []
        for thread, base in rows:
            status = _MOBILE.get(str(base.get("status")), IDLE)
            if status == WORKING:
                continue
            marker = str(thread.get("updatedAt") or "")
            with self._lock:
                known = self._t3_details.get(str(thread.get("id")))
            if known is not None and known[0] == marker:
                continue
            wanted.append((0 if status in (NEEDS_APPROVAL, NEEDS_INPUT) else 1, -_epoch(marker), thread))
        wanted.sort(key=lambda entry: (entry[0], entry[1]))
        started = self._monotonic()
        for done, (_group, _stamp, thread) in enumerate(wanted):
            if done >= T3_DETAILS_PER_REFRESH or (done and self._monotonic() - started > T3_DETAIL_BUDGET_SECONDS):
                break
            thread_id = str(thread.get("id"))
            needs = t3.thread_status(thread) in t3.NEEDS_YOU
            try:
                pending = hub.pending(thread_id) if needs else t3.PendingRequests()
                detail = hub.detail(thread_id, turns=1)
            except t3.T3Error:
                continue
            answer = ""
            for message in reversed(_dict(detail.get("thread")).get("messages") or []):
                if isinstance(message, dict) and message.get("role") == "assistant" and \
                        str(message.get("text") or "").strip():
                    answer = str(message["text"])
                    break
            with self._lock:
                if len(self._t3_details) > 400:
                    self._t3_details.clear()
                self._t3_details[thread_id] = (str(thread.get("updatedAt") or ""), pending, answer)

    def _t3_item(self, thread: Dict[str, Any], base: Dict[str, Any], workspace: Dict[str, Any],
                 drivers: Optional[Dict[str, str]] = None) -> Dict[str, Any]:
        thread_id = str(thread.get("id") or "")
        item_id = "t3:" + thread_id
        status = _MOBILE.get(str(base.get("status")), IDLE)
        with self._lock:
            detail = self._t3_details.get(thread_id)
        pending = detail[1] if detail is not None and status in (NEEDS_APPROVAL, NEEDS_INPUT) else None
        answer = detail[2] if detail is not None else ""
        marker = None if status == WORKING else t3.unread_marker(thread, t3.thread_status(thread))
        unread = t3.is_unread(marker, self.seen.get(item_id))
        label = _t3_label(thread, status, base, pending)
        if pending is not None and pending.approvals:
            first = pending.approvals[0]
            summary = first.detail or _APPROVAL_TEXT.get(first.kind, "Needs your approval")
        elif pending is not None and pending.inputs:
            summary = pending.inputs[0].questions[0].question
        elif status == ERROR:
            summary = str(_dict(thread.get("session")).get("lastError") or "") or answer or label
        elif status == WORKING:
            summary = str(base.get("summary") or label)
        else:
            summary = answer or str(base.get("summary") or label)
        if status == NEEDS_APPROVAL:
            can = ["approve", "reply", "stop", "open"]
        elif status == NEEDS_INPUT:
            can = ["answer", "reply", "stop", "open"]
        elif status == WORKING:
            can = ["reply", "stop", "open"]
        else:
            can = ["reply", "open"]
        if unread:
            can.append("seen")
        project_id = str(thread.get("projectId") or "")
        return {
            "id": item_id, "source": "t3",
            "agent": self._agent_of(thread, drivers if drivers is not None else self._drivers(self._hub())),
            "title": _clip(base.get("title") or "Untitled task", MAX_TITLE_CHARS),
            "project": base.get("projectName"), "cwd": thread.get("worktreePath") or workspace.get(project_id),
            "status": status, "statusLabel": label, "summary": _clip(summary, MAX_SUMMARY_CHARS),
            "updatedAt": base.get("updatedAt") or t3.normal_time(thread.get("updatedAt")), "unread": unread,
            "pending": _pending_view(pending), "can": can, "live": False,
            "progress": base.get("progress") if status == WORKING else None,
            "phase": base.get("phase") if status == WORKING else None,
        }

    @staticmethod
    def _drivers(hub: Any) -> Dict[str, str]:
        """instance id -> driver, from T3's provider list when it was read (never a T3 call)."""
        config = hub.cached_server_config() if hasattr(hub, "cached_server_config") else None
        return {entry["instanceId"]: entry["driver"] for entry in (config or {}).get("providers") or []}

    @staticmethod
    def _agent_of(thread: Dict[str, Any], drivers: Dict[str, str]) -> Optional[str]:
        """``claude`` / ``codex`` for the provider a T3 thread runs on (its instance's driver when known)."""
        selection = _dict(thread.get("modelSelection"))
        instance = str(selection.get("instanceId") or "")
        provider = str(_dict(thread.get("session")).get("providerName") or "")
        driver = drivers.get(instance) or provider or instance
        return _family(driver, str(selection.get("model") or ""))

    # ------------------------------------------------------------------ Claude Code and Codex
    def _live_info(self, *, fresh: bool = False) -> Dict[str, Dict[str, Any]]:
        """Claude Code's registry of its running sessions, by session id, each pid checked with one ``ps -p`` (its
        start time too: a reused pid is not the session; ``kill -0`` when ``ps`` fails). Read at most every
        ``LIVE_CHECK_SECONDS``."""
        with self._lock:
            at, value = self._live
            if not fresh and self._monotonic() - at < LIVE_CHECK_SECONDS:
                return value
        entries = read_claude_registry(self.claude.registry_dir)
        started = self.processes.started(sorted({int(entry.get("pid") or 0) for entry in entries.values()}))
        registry: Dict[str, Dict[str, Any]] = {}
        for session_id, entry in entries.items():
            pid = int(entry.get("pid") or 0)
            if started is not None:
                wanted = _normal_started(entry.get("procStart"))
                if pid not in started or (wanted and wanted != started[pid]):
                    continue  # gone, or the pid was reused
            elif not _pid_alive(pid):
                continue
            registry[session_id] = entry
        with self._lock:
            self._live = (self._monotonic(), registry)
        return registry

    def _owners(self, records: List[Any], kind: str, *, fresh: bool = False) -> Tuple[
            Dict[str, Tuple[Optional[Dict[str, Any]], int]], bool]:
        """(session id -> (its registry entry, the owning pid), whether the rest are known not to be live: False
        when ``ps`` failed). In order: Claude Code's registry, the session id in a process's command line, then a
        process in the session's folder that names no session (a plain ``claude`` / ``codex``) for the newest session
        in that folder nobody else owns. The whole process table is read only when the registry left one out."""
        owners: Dict[str, Tuple[Optional[Dict[str, Any]], int]] = {}
        ids = {str(getattr(record, "session_id", "") or getattr(record, "thread_id", "")): record for record in records}
        claimed = set()
        if kind == "claude":
            for session_id, entry in self._live_info(fresh=fresh).items():
                if session_id in ids:
                    owners[session_id] = (entry, int(entry.get("pid") or 0))
                claimed.add(int(entry.get("pid") or 0))
        if not ids or all(session_id in owners for session_id in ids):
            return owners, True
        table = self.processes.table(fresh=fresh)
        if table is None:
            return owners, False
        wanted = _is_claude_cli if kind == "claude" else _is_codex_cli
        plain = []
        for process in table.values():
            if process.pid in claimed or not wanted(process):
                continue
            if kind == "codex" and (self.processes.app_of(process.pid, table) or "").endswith(_APP_OWNED):
                continue  # Codex Desktop's or T3's own codex: their threads are theirs
            named = next((session_id for session_id in ids if session_id in process.args), None)
            if named is not None:
                owners.setdefault(named, (None, process.pid))
            elif not any(_UUID.match(word) for word in process.args.split()[1:]):
                plain.append(process)
        for process in plain:
            folder = self.processes.cwd(process)
            if not folder:
                continue
            free = [record for session_id, record in ids.items() if session_id not in owners and record.cwd == folder]
            if free:
                newest = max(free, key=lambda record: record.mtime)
                key = str(getattr(newest, "session_id", "") or getattr(newest, "thread_id", ""))
                owners[key] = (None, process.pid)
        return owners, True

    def _claude_items(self, now: float) -> Tuple[List[Dict[str, Any]], Dict[str, Any]]:
        status = self.claude.status()
        if not status["available"]:
            return [], status
        records = self.claude.scan(now)
        if not self.seen.baselined("claude"):
            self.seen.baseline("claude", {"claude:" + record.session_id: iso_utc(_updated(record))
                                          for record in records})
        owners = self._owners(records, "claude")
        return [self._claude_item(record, now, owners) for record in records], status

    def _claude_item(self, record: _ClaudeFile, now: float,
                     owners: Tuple[Dict[str, Tuple[Optional[Dict[str, Any]], int]], bool]) -> Dict[str, Any]:
        owner = owners[0].get(record.session_id)
        item_id = "claude:" + record.session_id
        is_live: Optional[bool] = True if owner is not None or self._just_launched(item_id) else (
            False if owners[1] else None)
        status, label, summary, pending = _claude_state(record, now, is_live, owner[0] if owner else None)
        updated = iso_utc(_updated(record))
        unread = status not in (WORKING, IDLE) and t3.is_unread(updated, self.seen.get(item_id))
        status = _settled(status, unread)
        if status in (NEEDS_APPROVAL, NEEDS_INPUT):
            can = ["open"]  # the CLI owns its prompt: only the terminal can answer it
        else:
            can = (["open"] if is_live else ["reply", "open"]) + (["seen"] if unread else [])
        return {
            "id": item_id, "source": "claude", "agent": "claude", "title": self.claude.title(record),
            "project": os.path.basename(record.cwd.rstrip("/")) if record.cwd else None, "cwd": record.cwd,
            "status": status, "statusLabel": label, "summary": _clip(summary, MAX_SUMMARY_CHARS),
            "updatedAt": updated, "unread": unread, "pending": pending, "can": can, "live": bool(is_live),
            "progress": None, "phase": None,
        }

    def _codex_items(self, now: float) -> Tuple[List[Dict[str, Any]], Dict[str, Any]]:
        status = self.codex.status()
        if not status["available"]:
            return [], status
        records = self.codex.scan(now)
        if not self.seen.baselined("codex"):
            self.seen.baseline("codex", {"codex:" + record.thread_id: iso_utc(_updated(record))
                                         for record in records})
        cli = [record for record in records if not record.desktop]  # Codex Desktop owns its own threads
        owners = self._owners(cli, "codex")
        return [self._codex_item(record, now, owners) for record in records], status

    def _codex_item(self, record: _CodexFile, now: float,
                    owners: Tuple[Dict[str, Tuple[Optional[Dict[str, Any]], int]], bool]) -> Dict[str, Any]:
        item_id = "codex:" + record.thread_id
        is_live: Optional[bool] = False if record.desktop else (
            True if record.thread_id in owners[0] or self._just_launched(item_id) else (False if owners[1] else None))
        status, label, summary, pending = _codex_state(record, now, is_live)
        updated = iso_utc(_updated(record))
        unread = status not in (WORKING, IDLE) and t3.is_unread(updated, self.seen.get(item_id))
        status = _settled(status, unread)
        if record.desktop:
            can = ["open"]  # the app owns its threads
        elif status in (NEEDS_APPROVAL, NEEDS_INPUT) or is_live:
            can = ["open"]
        else:
            can = ["reply", "open"]
        if unread:
            can.append("seen")
        return {
            "id": item_id, "source": "codex", "agent": "codex", "title": self.codex.title(record),
            "project": os.path.basename(record.cwd.rstrip("/")) if record.cwd else None, "cwd": record.cwd,
            "status": status, "statusLabel": label, "summary": _clip(summary, MAX_SUMMARY_CHARS),
            "updatedAt": updated, "unread": unread, "pending": pending, "can": can, "live": bool(is_live),
            "progress": None, "phase": None,
        }

    # ------------------------------------------------------------------ SamRabbit chats
    def _chat_items(self, _now: float) -> Tuple[List[Dict[str, Any]], Dict[str, Any]]:
        store = self._store()
        if store is None:
            return [], {"available": False}
        conversations = store.conversations(limit=MAX_CHATS, before=None, query="")
        assistant = self._assistant()
        busy = set()
        if assistant is not None and hasattr(assistant, "busy_sync_ids"):
            try:
                busy = set(assistant.busy_sync_ids())
            except Exception:  # noqa: BLE001
                busy = set()
        now_ms = int(self._clock() * 1000)
        items = []
        for conversation in conversations:
            conversation_id = str(conversation["conversationId"])
            working = conversation_id in busy or _drafting(store, conversation, now_ms)
            items.append({
                "id": "chat:" + conversation_id, "source": "samrabbit", "agent": None,
                "title": _clip(conversation.get("title") or "Conversation", MAX_TITLE_CHARS),
                "project": _chat_kind(conversation), "cwd": None, "status": WORKING if working else IDLE,
                "statusLabel": "Answering" if working else ("Live" if conversation.get("live") else "Conversation"),
                "summary": _clip(conversation.get("preview") or "", MAX_SUMMARY_CHARS),
                "updatedAt": iso_utc(int(conversation.get("lastAt") or 0) / 1000.0), "unread": False,
                "pending": {"approvals": [], "inputs": []}, "can": ["open"], "live": bool(conversation.get("live")),
                "progress": None, "phase": None,
            })
        return items, {"available": True}

    def _chat_messages(self, conversation_id: str) -> List[Dict[str, Any]]:
        store = self._store()
        if store is None:
            return []
        out: List[Dict[str, Any]] = []
        finalized: List[Dict[str, Any]] = []
        cursor = 0
        for _page in range(40):
            rows = store.events_after(cursor, 500, conversation_id)
            if not rows:
                break
            cursor = rows[-1][0]
            for _cursor, payload in rows:
                try:
                    event = json.loads(payload)
                except ValueError:
                    continue
                kind = event.get("type")
                text = event.get("text")
                at = iso_utc(int(event.get("at") or 0) / 1000.0) if event.get("at") else None
                if kind == "message.user" and isinstance(text, str) and text.strip():
                    out.append({"role": "user", "text": _message_text(text), "at": at})
                elif kind in ("message.assistant.done", "message.assistant.interrupted") and isinstance(text, str) \
                        and text.strip():
                    out.append({"role": "assistant", "text": _message_text(text), "at": at})
                elif kind == "session.finalized":
                    for entry in event.get("entries") or []:
                        if isinstance(entry, dict) and entry.get("role") in ("user", "assistant") and \
                                isinstance(entry.get("text"), str) and entry["text"].strip():
                            finalized.append({"role": entry["role"], "text": _message_text(entry["text"]),
                                              "at": iso_utc(int(entry.get("at") or 0) / 1000.0)
                                              if entry.get("at") else at})
            out = out[-MAX_MESSAGES:]
            finalized = finalized[-MAX_MESSAGES:]
            if len(rows) < 500:
                break
        return (out or finalized)[-MAX_MESSAGES:]

    # ------------------------------------------------------------------ HTTP
    @staticmethod
    def handles(route: str) -> bool:
        return route == PREFIX or route.startswith(PREFIX + "/")

    @staticmethod
    def route_label(route: str) -> str:
        for spec in ROUTES:
            match = spec.pattern.match(route)
            if match:
                action = match.groupdict().get("action")
                return spec.label.replace("{action}", action) if action else spec.label
        return "/v1/desktop/inbox/(other)"

    def serve(self, handler: Any, method: str, route: str) -> Tuple[int, Optional[str]]:
        try:
            denied = self._desktop_denied(handler)
            if denied is not None:
                raise denied
            found = None
            for spec in ROUTES:
                match = spec.pattern.match(route)
                if match:
                    found = (spec, match.groupdict())
                    break
            if found is None:
                raise InboxError(404, "not_found", "Not found.")
            spec, params = found
            name = spec.methods.get(method)
            if name is None:
                raise InboxError(405, "method_not_allowed", "Use " + "/".join(sorted(spec.methods)) + ".")
            self._demand()
            status, payload = getattr(self, "_r_" + name)(handler, params)
        except Exception as error:  # noqa: BLE001 - every module's error answers with its own envelope
            status, payload = _error_answer(error)
        _send(handler, status, payload)
        code = payload.get("error", {}).get("code") if isinstance(payload.get("error"), dict) else None
        return status, code

    def _r_inbox(self, handler: Any, _params: Dict[str, str]) -> Tuple[int, Dict[str, Any]]:
        query = _query(handler)
        after = _number(query, "after")
        wait = min(MAX_WAIT_SECONDS, _number(query, "wait") or 0)
        state = self._current()
        if after is not None and after == state.revision and wait > 0:
            state = self._wait(after, wait)
        return 200, {"revision": state.revision, "updatedAt": state.updated_at, "counts": dict(state.counts),
                     "sources": state.sources, "items": state.items}

    def _wait(self, after: int, seconds: float) -> _State:
        """Long-poll: until the revision moves past ``after`` or ``seconds`` pass. The refresher speeds up while
        anyone waits; without one (tests, one-off use) the wait refreshes by itself."""
        deadline = self._monotonic() + seconds
        with self._changed:
            self._waiters += 1
        self._wake.set()
        try:
            while not self._stopping.is_set():
                left = deadline - self._monotonic()
                if left <= 0:
                    break
                with self._changed:
                    if self._state.revision != after:
                        break
                    self._changed.wait(timeout=min(left, FAST_REFRESH_SECONDS))
                    if self._state.revision != after:
                        break
                if not self._worker_alive() and deadline - self._monotonic() > 0:
                    self.refresh(force=True)
        finally:
            with self._changed:
                self._waiters -= 1
                self._last_wait = self._monotonic()
        return self._state

    def _r_item(self, _handler: Any, params: Dict[str, str]) -> Tuple[int, Dict[str, Any]]:
        source, key = _parse_id(params["id"])
        if source == "t3":
            return 200, self._t3_view(key)
        item = self._find(source + ":" + key)
        if item is None:
            raise InboxError(404, "item_not_found", "That is not in the inbox.")
        if source == "claude":
            record = self.claude.find(key)
            messages = self.claude.messages(record) if record is not None else []
        elif source == "codex":
            record = self.codex.find(key)
            messages = self.codex.messages(record) if record is not None else []
        else:
            messages = self._chat_messages(key)
        return 200, {"item": item, "messages": messages}

    def _t3_view(self, thread_id: str) -> Dict[str, Any]:
        """A T3 thread read now: its open requests and last messages from one thread read, and its item with them."""
        hub = self._t3_hub()
        detail = hub.detail(thread_id, turns=3, fresh=True)
        thread = _dict(detail.get("thread"))
        pending = t3.pending_requests(thread.get("activities"))
        try:
            snapshot = hub.snapshot(max_age=5.0)
        except t3.T3Error:
            snapshot = None
        shell = snapshot.threads.get(thread_id) if snapshot is not None else None
        if shell is None:
            raise InboxError(404, "item_not_found", "That T3 thread is not in the inbox.")
        if pending.count == 0 and t3.thread_status(shell) in t3.NEEDS_YOU:
            pending = hub.pending(thread_id)  # an older request: look further back
        messages = [entry for entry in t3.timeline(thread) if entry.get("role") in ("user", "assistant")
                    and str(entry.get("text") or "").strip()]
        answer = next((entry["text"] for entry in reversed(messages) if entry["role"] == "assistant"), "")
        with self._lock:
            self._t3_details[thread_id] = (str(shell.get("updatedAt") or ""), pending, answer)
        workspace = {record["id"]: record.get("workspaceRoot") or None for record in snapshot.records}
        item = self._t3_item(shell, hub.item(shell, snapshot.titles), workspace)
        return {"item": item, "messages": [{"role": entry["role"], "text": _message_text(entry.get("text")),
                                            "at": entry.get("at")} for entry in messages[-MAX_MESSAGES:]]}

    def _find(self, item_id: str) -> Optional[Dict[str, Any]]:
        """The item as the list shows it now (rebuilt when it is not there yet: a thread just made, a list older than
        a second)."""
        for attempt in (0, 1):
            state = self._current() if attempt == 0 else self.refresh(force=True)
            found = next((item for item in state.items if item["id"] == item_id), None)
            if found is not None:
                return found
        if item_id.startswith("t3:"):
            return self._t3_item_now(item_id[3:])
        return None

    def _t3_item_now(self, thread_id: str) -> Optional[Dict[str, Any]]:
        """A T3 thread the list leaves out (settled, snoozed, over the cap): its item all the same."""
        hub = self._t3_hub()
        try:
            snapshot = hub.snapshot(max_age=5.0)
        except t3.T3Error:
            return None
        thread = snapshot.threads.get(thread_id)
        if thread is None:
            return None
        workspace = {record["id"]: record.get("workspaceRoot") or None for record in snapshot.records}
        return self._t3_item(thread, hub.item(thread, snapshot.titles), workspace)

    def _t3_hub(self) -> Any:
        hub = self._hub()
        if hub is None:
            raise InboxError(503, "t3_unavailable", "T3 Code is not connected to the Mac bridge.")
        if not hub.available():
            raise hub.error() if hasattr(hub, "error") else InboxError(503, "t3_unavailable", "T3 Code is off.")
        return hub

    # ------------------------------------------------------------------ actions
    def _r_action(self, handler: Any, params: Dict[str, str]) -> Tuple[int, Dict[str, Any]]:
        source, key = _parse_id(params["id"])
        action = params["action"]
        body = _optional_body(handler) if action in ("stop", "seen", "open") else _json_body(handler)
        item_id = source + ":" + key
        if source == "t3":
            return self._t3_action(key, action, body)
        item = self._find(item_id)
        if item is None:
            raise InboxError(404, "item_not_found", "That is not in the inbox.")
        if action == "seen":
            self.seen.mark(item_id, str(item.get("updatedAt") or iso_utc(self._clock())))
            self._changed_now()
            return 200, {"ok": True}
        if action == "open":
            return 200, self._open(source, key, item)
        if action == "reply":
            return self._reply(source, key, item, body)
        if source == "chat":
            raise _unsupported("This is a SamRabbit conversation: open it in the app.")
        raise _unsupported("Only the terminal or the app that runs it can do that: open it to answer there.")

    def _t3_action(self, thread_id: str, action: str, body: Dict[str, Any]) -> Tuple[int, Dict[str, Any]]:
        hub = self._t3_hub()
        if action == "seen":
            thread = self._t3_threads.get(thread_id)
            if thread is None:
                try:
                    thread = hub.snapshot(max_age=10.0).threads.get(thread_id)
                except t3.T3Error:
                    thread = None
            if thread is None:
                raise InboxError(404, "item_not_found", "That T3 thread was not found.")
            self.seen.mark("t3:" + thread_id, t3.seen_marker(thread) or iso_utc(self._clock()))
            self._changed_now()
            return 200, {"ok": True}
        if action == "open":
            self.launcher.app(T3_BUNDLE_ID)
            _LOG.info("inbox opened t3")
            return 200, {"opened": True, "how": "app", **({"dryRun": True} if self.launcher.dry_run else {})}
        if action == "approve":
            decision = body.get("decision")
            if not isinstance(decision, str) or not decision:
                raise _bad("invalid_decision", "Send a decision (one of the approval's options, or approve / deny).")
            value = hub.respond(thread_id, {"decision": decision, **_request_id(body)})
        elif action == "answer":
            answers = body.get("answers")
            if not isinstance(answers, dict) or not answers:
                raise _bad("invalid_answers", "Send answers: {questionId: answer}.")
            value = hub.respond(thread_id, {"answers": answers, **_request_id(body)})
        elif action == "reply":
            value = hub.send_message(thread_id, _reply_text(body))
            self._changed_now()
            return 202, {"ok": True, "how": "t3", "threadId": value.get("threadId")}
        else:
            value = hub.stop(thread_id)
        self._changed_now()
        _LOG.info("inbox t3 %s", action)
        return 200, dict(value, ok=True)

    def _tool(self, name: str) -> str:
        """The CLI's absolute path when it is in one of the usual places, else its name (the Terminal window's own
        PATH finds it)."""
        explicit = self._claude_cli if name == "claude" else self._codex_cli
        if explicit:
            return explicit
        candidates = [os.path.join(self.home, ".local", "bin", name), "/opt/homebrew/bin/" + name,
                      "/usr/local/bin/" + name]
        for path in candidates:
            if os.path.isfile(path) and os.access(path, os.X_OK):
                return path
        return name

    def _open(self, source: str, key: str, item: Dict[str, Any]) -> Dict[str, Any]:
        dry = {"dryRun": True} if self.launcher.dry_run else {}
        if source == "chat":
            return {"opened": True, "how": "desktop", "conversationId": key}
        if source == "codex":
            record = self.codex.find(key)
            if record is not None and record.desktop:
                if _UUID.match(key):
                    self.launcher.url(CODEX_THREAD_URL + key)
                    _LOG.info("inbox opened codex desktop")
                    return {"opened": True, "how": "deeplink", **dry}
                self.launcher.app(CHATGPT_BUNDLE_ID)
                return {"opened": True, "how": "app", **dry}
        pid = self._owner(source, key)
        if pid is not None:
            app = self.processes.app_of(pid)
            if app:
                self.launcher.app_path(app)
            else:
                self.launcher.app(TERMINAL_BUNDLE_ID)
            _LOG.info("inbox opened a live %s session", source)
            return {"opened": True, "how": "terminal", **dry}
        if self._just_launched(source + ":" + key):  # its Terminal window is still starting: never a second CLI
            self.launcher.app(TERMINAL_BUNDLE_ID)
            _LOG.info("inbox opened a %s session just resumed", source)
            return {"opened": True, "how": "terminal", **dry}
        cwd = self._folder_of(item)
        argv = [self._tool("claude"), "--resume", key] if source == "claude" else [self._tool("codex"), "resume", key]
        self.launcher.terminal(cwd, argv)
        self._launched_now(source + ":" + key)
        _LOG.info("inbox resumed a %s session in Terminal", source)
        return {"opened": True, "how": "terminal", **dry}

    def _reply(self, source: str, key: str, item: Dict[str, Any], body: Dict[str, Any]) -> Tuple[int, Dict[str, Any]]:
        text = _reply_text(body)
        if source == "chat":
            raise _unsupported("This is a SamRabbit conversation: open it in the app.")
        if source == "codex":
            record = self.codex.find(key)
            if record is not None and record.desktop:
                raise _unsupported("Codex Desktop owns this thread: open it there to reply.")
        if item.get("live") or self._just_launched(source + ":" + key) or self._owner(source, key) is not None:
            raise InboxError(409, "session_live", "It's open in a terminal: open it to answer there.")
        cwd = self._folder_of(item)
        # ``--`` ends the options: a reply that starts with "-" (a list, "-p ...") is the prompt, never a flag.
        argv = [self._tool("claude"), "--resume", key, "--", text] if source == "claude" else \
            [self._tool("codex"), "resume", key, "--", text]
        self.launcher.terminal(cwd, argv)
        self._launched_now(source + ":" + key)
        _LOG.info("inbox continued a %s session in Terminal", source)
        return 202, {"ok": True, "how": "terminal", **({"dryRun": True} if self.launcher.dry_run else {})}

    def _launched_now(self, item_id: str) -> None:
        if self.launcher.dry_run:
            return  # nothing was opened
        with self._lock:
            now = self._monotonic()
            self._launched = {key: at for key, at in self._launched.items() if now - at < LAUNCH_GRACE_SECONDS}
            self._launched[item_id] = now
        self._changed_now()

    def _just_launched(self, item_id: str) -> bool:
        """A Terminal window was opened to resume this session moments ago: until its CLI shows in ``ps`` (Terminal
        starting, the login shell, the script) it counts as live, so a second press never starts a second CLI on
        the same session file."""
        with self._lock:
            at = self._launched.get(item_id)
            return at is not None and self._monotonic() - at < LAUNCH_GRACE_SECONDS

    def _owner(self, source: str, key: str) -> Optional[int]:
        """The pid of the CLI that owns a Claude or Codex session right now (looked up again: Samin may just have
        closed it), or None."""
        if source == "claude":
            records: List[Any] = self.claude.scan(self._clock())
        else:
            records = [record for record in self.codex.scan(self._clock()) if not record.desktop]
        owners = self._owners(records, source, fresh=True)
        owner = owners[0].get(key)
        return owner[1] if owner and owner[1] else None

    def _folder_of(self, item: Dict[str, Any]) -> str:
        cwd = item.get("cwd")
        if not isinstance(cwd, str) or not cwd.startswith("/") or not os.path.isdir(cwd):
            raise InboxError(409, "folder_missing", "The folder that session ran in is not there any more.")
        return cwd

    # ------------------------------------------------------------------ new tasks
    def _r_targets(self, _handler: Any, _params: Dict[str, str]) -> Tuple[int, Dict[str, Any]]:
        return 200, self.targets()

    def targets(self) -> Dict[str, Any]:
        """T3's projects (most recently active first), the Claude and Codex providers it offers with their models
        (``server.getConfig``; without it, what its threads use), and the default: the most recently active thread's
        provider and model, in the most recently active project."""
        hub = self._t3_hub()
        snapshot = hub.snapshot(max_age=10.0)
        active: Dict[str, float] = {}
        for thread in snapshot.threads.values():
            key = str(thread.get("projectId") or "")
            active[key] = max(active.get(key, 0.0), _epoch(t3.activity_time(thread)))
        projects = [{"id": record["id"], "title": record["title"],
                     "lastActiveAt": iso_utc(active[record["id"]]) if active.get(record["id"]) else None}
                    for record in snapshot.records if not record.get("scratch")]
        agents = self._agent_targets(hub, snapshot)
        recent = sorted(snapshot.threads.values(), key=lambda thread: _epoch(t3.activity_time(thread)), reverse=True)
        drivers = self._drivers(hub)
        default_agent, default_model = None, None
        for thread in recent:
            family = self._agent_of(thread, drivers)
            model = str(_dict(thread.get("modelSelection")).get("model") or "")
            if family in agents and model:
                default_agent = family
                default_model = model if model in agents[family]["models"] else agents[family]["default"]
                break
        if default_agent is None and agents:
            default_agent = "claude" if "claude" in agents else next(iter(agents))
            default_model = agents[default_agent]["default"]
        return {"projects": projects,
                "agents": [{"id": family, "label": AGENT_LABELS[family],
                            "models": [{"id": slug, "label": label} for slug, label in entry["labels"]]}
                           for family, entry in agents.items()],
                "default": {"projectId": projects[0]["id"] if projects else None, "agent": default_agent,
                            "model": default_model}}

    def _agent_targets(self, hub: Any, snapshot: Any) -> Dict[str, Dict[str, Any]]:
        """family -> {instanceId, models (slugs), labels [(slug, label)], default, options}: the provider instance a
        new Claude or Codex task runs on (the one its most recent thread used, else T3's default, else the first one
        that is set up) and its models."""
        recent = sorted(snapshot.threads.values(), key=lambda thread: _epoch(t3.activity_time(thread)), reverse=True)
        config = hub.server_config() if hasattr(hub, "server_config") else None
        agents: Dict[str, Dict[str, Any]] = {}
        if config is not None:
            default = config.get("defaultModelSelection") or {}
            for family, driver in AGENT_DRIVERS.items():
                usable = [entry for entry in config["providers"] if entry["driver"] == driver and entry["usable"]
                          and entry["models"]]
                if not usable:
                    continue
                ids = [entry["instanceId"] for entry in usable]
                used = next((_dict(thread.get("modelSelection")) for thread in recent
                             if _dict(thread.get("modelSelection")).get("instanceId") in ids), {})
                chosen_id = used.get("instanceId") or (default.get("instanceId") if default.get("instanceId") in ids
                                                       else ids[0])
                chosen = next(entry for entry in usable if entry["instanceId"] == chosen_id)
                slugs = [model["slug"] for model in chosen["models"]]
                fallback = next((model["slug"] for model in chosen["models"] if model["isDefault"]), slugs[0])
                if default.get("instanceId") == chosen_id and default.get("model") in slugs:
                    fallback = default["model"]
                if used.get("model") in slugs:
                    fallback = used["model"]
                agents[family] = {"instanceId": chosen_id, "models": slugs, "default": fallback,
                                  "labels": [(model["slug"], model["name"]) for model in chosen["models"]],
                                  "recent": used}
        else:
            for family in AGENT_DRIVERS:
                selections = [_dict(thread.get("modelSelection")) for thread in recent]
                selections += [_dict(record.get("defaultModelSelection")) for record in snapshot.records]
                mine = [selection for selection in selections if selection.get("instanceId") and
                        selection.get("model") and _family(str(selection["instanceId"]),
                                                           str(selection["model"])) == family]
                if not mine and family == "claude":
                    mine = [dict(t3.DEFAULT_MODEL_SELECTION)]
                if not mine:
                    continue
                instance = str(mine[0]["instanceId"])
                slugs = []
                for selection in mine:
                    if str(selection["instanceId"]) == instance and str(selection["model"]) not in slugs:
                        slugs.append(str(selection["model"]))
                agents[family] = {"instanceId": instance, "models": slugs, "default": slugs[0],
                                  "labels": [(slug, slug) for slug in slugs], "recent": mine[0]}
        return agents

    def _selection(self, agent: Optional[str], model: Optional[str]) -> Optional[Dict[str, Any]]:
        """The ``modelSelection`` for a new task, or None (neither given: the project's own choice, as from the
        phone)."""
        if agent is None and model is None:
            return None
        hub = self._t3_hub()
        agents = self._agent_targets(hub, hub.snapshot(max_age=10.0))
        if agent is None:
            agent = next((family for family, entry in agents.items() if model in entry["models"]),
                         _family("", str(model)))
        entry = agents.get(str(agent))
        if entry is None:
            raise InboxError(409, "agent_unavailable", f"{AGENT_LABELS.get(str(agent), 'That agent')} is not set up "
                             "in T3 Code.")
        chosen = model or entry["default"]
        if entry["models"] and chosen not in entry["models"]:
            raise _bad("invalid_model", "T3 Code does not offer that model for " + AGENT_LABELS[str(agent)] + ".")
        selection: Dict[str, Any] = {"instanceId": entry["instanceId"], "model": chosen}
        recent = _dict(entry.get("recent"))
        if recent.get("instanceId") == entry["instanceId"] and recent.get("model") == chosen and \
                isinstance(recent.get("options"), list):
            selection["options"] = recent["options"]  # the same effort / context settings as last time
        return selection

    def _r_new(self, handler: Any, _params: Dict[str, str]) -> Tuple[int, Dict[str, Any]]:
        body = _json_body(handler)
        text = body.get("text")
        project_id = body.get("projectId")
        agent = body.get("agent")
        model = body.get("model")
        title = body.get("title")
        if project_id is not None and not isinstance(project_id, str):
            raise _bad("invalid_project", "projectId must be a project id.")
        if agent is not None and agent not in AGENT_DRIVERS:
            raise _bad("invalid_agent", "agent must be claude or codex.")
        if model is not None and (not isinstance(model, str) or not _MODEL.match(model)):
            raise _bad("invalid_model", "model must be a model id.")
        if title is not None and not isinstance(title, str):
            raise _bad("invalid_title", "title must be text.")
        hub = self._t3_hub()
        selection = self._selection(agent, model)
        value = hub.create(text, project_id=project_id or None, title=title, model_selection=selection)
        self._changed_now()
        _LOG.info("inbox new t3 task (%s)", value.get("placement"))
        return 202, {"itemId": "t3:" + str(value["threadId"]), **value,
                     **({"agent": agent or _family(selection["instanceId"], selection["model"]),
                         "model": selection["model"]} if selection else {})}


# --------------------------------------------------------------------------- statuses


def _rank(item: Dict[str, Any]) -> Tuple[int, float, str]:
    status = item["status"]
    group = _GROUP.get(status, 5)
    if status == DONE and item.get("unread"):
        group = 3
    elif status == WORKING:
        group = 4
    return group, -_epoch(item.get("updatedAt")), item["id"]


def _needs_you(item: Dict[str, Any]) -> bool:
    return item["status"] in NEEDS_YOU or (item["status"] == DONE and bool(item.get("unread")))


def _settled(status: str, unread: bool) -> str:
    """A Claude Code or Codex session that failed needs Samin until he saw it (nothing else can settle it, unlike a
    T3 thread): then it is idle, its label still saying it hit an error. A new error makes it unread again."""
    return IDLE if status == ERROR and not unread else status


def _family(driver: str, model: str) -> Optional[str]:
    """``claude`` or ``codex`` for a T3 provider driver / instance (or, failing that, a model id), else None."""
    name = driver.lower()
    if name.startswith("claude"):
        return "claude"
    if "codex" in name:
        return "codex"
    if name:
        return None
    if model.startswith("claude"):
        return "claude"
    return "codex" if re.match(r"^(?:gpt-|o\d|codex)", model) else None


def _updated(record: Any) -> float:
    return max(float(getattr(record, "last_at", 0.0) or 0.0), 0.0) or float(record.mtime)


def _pid_alive(pid: int) -> bool:
    if pid <= 1:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return False
    return True


def _t3_label(thread: Dict[str, Any], status: str, base: Dict[str, Any], pending: Any) -> str:
    if status == NEEDS_APPROVAL:
        kind = pending.approvals[0].kind if pending is not None and pending.approvals else None
        return _APPROVAL_TEXT.get(kind or "", "Needs approval")
    if status == NEEDS_INPUT:
        return "Has a question"
    if status == WORKING:
        progress = _dict(thread.get("planProgress"))
        total, done = progress.get("totalSteps"), progress.get("completedSteps")
        if isinstance(total, int) and isinstance(done, int) and total > 0:
            return f"Working · step {min(done + 1, total)}/{total}"
        label = str(base.get("statusLabel") or "Working")
        return label if label in ("Starting", "Monitoring", "Background work") else "Working"
    if status == ERROR:
        return "Failed"
    if status == IDLE:
        return "New"
    return "Stopped" if _dict(thread.get("latestTurn")).get("state") == "interrupted" else "Finished"


def _pending_view(pending: Any) -> Dict[str, Any]:
    if pending is None:
        return {"approvals": [], "inputs": []}
    return {"approvals": [{"requestId": item.request_id, "kind": item.kind, "detail": _clip(item.detail, 600) or None,
                           "options": [dict(option) for option in item.options]} for item in pending.approvals],
            "inputs": [{"requestId": item.request_id,
                        "questions": [{"id": question.question_id, "header": question.header,
                                       "question": _clip(question.question, 600), "options": list(question.options),
                                       "allowCustom": question.allow_custom, "multiSelect": question.multi_select}
                                      for question in item.questions]} for item in pending.inputs]}


def _claude_tool_detail(tool: Dict[str, Any]) -> Tuple[str, str]:
    """(request kind, what the tool wants) for a Claude Code tool call nobody answered yet."""
    name = tool.get("name") or "a tool"
    data = _dict(tool.get("input"))
    if name == "Bash":
        return "command", "Wants to run: " + _clip(data.get("command"), 200)
    if name in _CLAUDE_EDITS:
        target = str(data.get("file_path") or data.get("notebook_path") or "")
        return "file-change", "Wants to edit " + (os.path.basename(target) or "files")
    if name in ("WebFetch", "WebSearch"):
        target = str(data.get("url") or data.get("query") or "")
        host = urlsplit(target).hostname if target.startswith("http") else target
        return "permission", "Wants to look up " + _clip(host or "the web", 120)
    if name == "ExitPlanMode":
        return "permission", "Wants to start on its plan"
    return "permission", "Wants to use " + _clip(name, 80)


def _claude_state(record: _ClaudeFile, now: float, live: Optional[bool],
                  entry: Optional[Dict[str, Any]]) -> Tuple[str, str, str, Dict[str, Any]]:
    """(status, label, summary, pending) of a Claude Code CLI session."""
    idle = now - record.mtime
    pending: Dict[str, Any] = {"approvals": [], "inputs": []}
    tool = record.pending[-1] if record.pending else None
    word = str((entry or {}).get("status") or "")
    waiting_for = str((entry or {}).get("waitingFor") or "")
    name = str((tool or {}).get("name") or "")
    asks = name == "AskUserQuestion"
    # Without the registry's word, an unanswered tool call is a prompt in the terminal once the file went quiet: a
    # question or a plan always asks; any other tool only when the session asks for permissions at all.
    needs_him = tool is not None and (asks or name == "ExitPlanMode" or (
        name not in _CLAUDE_SELF_RUNNING and record.permission_mode != "bypassPermissions"))
    waiting = word == "waiting" or (word == "" and needs_him and idle > WAITING_AFTER_SECONDS and live is not False)
    if waiting:
        question = asks or (word == "waiting" and not waiting_for.startswith("approve"))
        if question:
            questions = []
            for index, raw in enumerate(_dict((tool or {}).get("input")).get("questions") or []):
                if isinstance(raw, dict) and isinstance(raw.get("question"), str):
                    questions.append({"id": str(index), "header": str(raw.get("header") or "Question"),
                                      "question": _clip(raw["question"], 600),
                                      "options": [str(option.get("label")) for option in raw.get("options") or []
                                                  if isinstance(option, dict) and option.get("label")],
                                      "allowCustom": True, "multiSelect": raw.get("multiSelect") is True})
            if questions:
                pending["inputs"] = [{"requestId": str((tool or {}).get("id") or "terminal"), "questions": questions}]
            summary = questions[0]["question"] if questions else "Waiting for your answer in the terminal"
            return NEEDS_INPUT, "Has a question in the terminal", summary, pending
        if tool is not None:
            kind, detail = _claude_tool_detail(tool)
        else:
            kind, detail = "permission", "Wants approval: " + _clip(waiting_for[len("approve"):].strip(" :"), 200)
        pending["approvals"] = [{"requestId": str((tool or {}).get("id") or "terminal"), "kind": kind,
                                 "detail": detail, "options": []}]
        return NEEDS_APPROVAL, "Waiting for you in the terminal", detail, pending
    if word == "busy":
        return WORKING, "Working", record.last_text or "Working", pending
    if record.last_kind == "assistant_error":
        return ERROR, "Hit an error", record.last_text or "Claude Code hit an error.", pending
    if tool is not None and word != "idle" and (live is True or (live is None and idle <= CODEX_QUIET_SECONDS)):
        return WORKING, "Working", record.last_text or "Working", pending  # a tool (or a subagent) still running
    if record.last_kind == "assistant_text" and not record.pending:
        return DONE, "Finished", record.last_text, pending
    if idle <= WORKING_SECONDS and word != "idle":
        return WORKING, "Working", record.last_text or "Working", pending
    if record.last_kind == "user_interrupt" or record.pending:
        return IDLE, "Stopped", record.last_text or "Stopped", pending
    return IDLE, "Idle", record.last_text or "", pending


def _codex_state(record: _CodexFile, now: float, live: Optional[bool]) -> Tuple[str, str, str, Dict[str, Any]]:
    """(status, label, summary, pending) of a Codex session, from its tail's events."""
    idle = now - record.mtime
    where = "in Codex" if record.desktop else "in the terminal"
    pending: Dict[str, Any] = {"approvals": [], "inputs": []}
    if record.pending is not None and record.pending["kind"] == "approval":
        payload = record.pending["payload"]
        command = payload.get("command")
        if isinstance(command, list):
            command = " ".join(str(part) for part in command)
        kind = "file-change" if record.pending["type"] == "apply_patch_approval_request" else \
            ("command" if command else "permission")
        detail = ("Wants to run: " + _clip(command, 200)) if command else \
            ("Wants to edit files" if kind == "file-change" else _clip(payload.get("reason") or
                                                                        "Wants your approval", 200))
        pending["approvals"] = [{"requestId": str(payload.get("call_id") or payload.get("id") or "codex"),
                                 "kind": kind, "detail": detail, "options": []}]
        return NEEDS_APPROVAL, "Waiting for you " + where, detail, pending
    if record.pending is not None:
        payload = record.pending["payload"]
        questions = []
        for index, raw in enumerate(payload.get("questions") or []):
            if isinstance(raw, dict) and isinstance(raw.get("question"), str):
                questions.append({"id": str(raw.get("id") or index), "header": str(raw.get("header") or "Question"),
                                  "question": _clip(raw["question"], 600),
                                  "options": [str(option.get("label")) for option in raw.get("options") or []
                                              if isinstance(option, dict) and option.get("label")],
                                  "allowCustom": True, "multiSelect": raw.get("multiSelect") is True})
        if questions:
            pending["inputs"] = [{"requestId": str(payload.get("call_id") or payload.get("id") or "codex"),
                                  "questions": questions}]
        summary = questions[0]["question"] if questions else _clip(payload.get("message") or "Codex has a question",
                                                                    240)
        return NEEDS_INPUT, "Has a question " + where, summary, pending
    if record.error:  # a failed turn (or an error nothing ended yet); a finished or stopped turn clears it
        return ERROR, "Hit an error", record.error, pending
    if record.turn == "done":
        return DONE, "Finished", record.last_text, pending
    if record.turn == "aborted":
        return IDLE, "Stopped", record.last_text or "Stopped", pending
    if record.turn == "open":
        # Codex writes no approval request into its rollouts: a tool call with no output yet that went quiet may be
        # one, unless approvals are off for the turn ("never": it is running) or it is one of Codex's own tools.
        call = record.open_call
        if call is not None and call["name"] not in _CODEX_SELF_RUNNING and record.approval_policy != "never" and \
                (record.desktop or live is True) and idle > CODEX_ASK_SECONDS:
            pending["approvals"] = [{"requestId": call["id"], "kind": call["kind"], "detail": call["detail"],
                                     "options": []}]
            return NEEDS_APPROVAL, "May be waiting for you " + where, call["detail"], pending
        if idle <= CODEX_QUIET_SECONDS:
            return WORKING, "Working", record.last_text or "Working", pending
        return IDLE, "Quiet", record.last_text or "", pending
    if idle <= WORKING_SECONDS:
        return WORKING, "Working", record.last_text or "Working", pending
    if record.last_text:
        return DONE, "Finished", record.last_text, pending
    return IDLE, "Idle", "", pending


def _chat_kind(conversation: Dict[str, Any]) -> str:
    conversation_id = str(conversation.get("conversationId") or "")
    title = str(conversation.get("title") or "")
    if conversation_id.startswith("mac-"):
        return "Mac"
    if conversation_id.startswith("phone-"):
        return "iPhone"
    if conversation_id.startswith("watch-"):
        return "iPhone" if title.startswith("iPhone:") else "Watch"
    return "R1"


def _drafting(store: Any, conversation: Dict[str, Any], now_ms: int) -> bool:
    """An R1 reply is still being written: the sync store keeps its newest draft until the reply is done."""
    cursor = int(conversation.get("cursor") or 0)
    try:
        rows = store.events_after(max(0, cursor - 50), 50, str(conversation["conversationId"]))
    except Exception:  # noqa: BLE001
        return False
    for _cursor, payload in rows:
        try:
            event = json.loads(payload)
        except ValueError:
            continue
        if event.get("type") == "message.assistant.delta" and now_ms - int(event.get("at") or 0) < DRAFT_FRESH_MS:
            return True
    return False


# --------------------------------------------------------------------------- HTTP plumbing


def _parse_id(raw: str) -> Tuple[str, str]:
    match = _ITEM_ID.match(unquote(raw))
    if not match:
        raise InboxError(404, "item_not_found", "That is not an inbox item.")
    return match.group(1), match.group(2)


def _request_id(body: Dict[str, Any]) -> Dict[str, Any]:
    value = body.get("requestId")
    if value is None:
        return {}
    if not isinstance(value, str) or not value or len(value) > 300:
        raise _bad("invalid_request", "requestId must be the request's id.")
    return {"requestId": value}


def _reply_text(body: Dict[str, Any]) -> str:
    text = body.get("text")
    if not isinstance(text, str) or not text.strip():
        raise _bad("invalid_text", "Send the reply as text.")
    if len(text) > MAX_REPLY_CHARS or "\x00" in text:
        raise _bad("invalid_text", f"The reply must be at most {MAX_REPLY_CHARS} characters.")
    return text.strip()


def _error_answer(error: Exception) -> Tuple[int, Dict[str, Any]]:
    status = getattr(error, "status", None)
    payload = getattr(error, "payload", None)
    if isinstance(status, int) and callable(payload):
        value = payload()
        if isinstance(value, dict) and isinstance(value.get("error"), dict):
            value["error"].setdefault("retryable", False)
            return status, value
    _LOG.error("inbox request failed unexpectedly (%s)", type(error).__name__)
    return 500, InboxError(500, "internal_error", "The bridge failed unexpectedly.").payload()


def _query(handler: Any) -> Dict[str, List[str]]:
    try:
        return parse_qs(urlsplit(handler.path).query, max_num_fields=8)
    except ValueError:
        raise _bad("invalid_query", "Too many query parameters.") from None


def _number(query: Dict[str, List[str]], key: str) -> Optional[int]:
    values = query.get(key) or []
    value = values[0].strip() if values else ""
    if not value:
        return None
    if not value.isdigit() or len(value) > 16:  # a revision is a time in ms (13 digits) and on
        raise _bad("invalid_query", f"{key} must be a whole number.")
    return int(value)


def _length(handler: Any) -> int:
    if handler.headers.get("Transfer-Encoding"):
        raise InboxError(411, "length_required", "Send a Content-Length body.")
    raw = handler.headers.get("Content-Length")
    if raw in (None, ""):
        return 0
    try:
        length = int(raw)
    except ValueError:
        raise InboxError(411, "length_required", "Send a Content-Length body.") from None
    if length < 0 or length > MAX_BODY_BYTES:
        raise InboxError(413, "body_too_large", f"The body must be at most {MAX_BODY_BYTES} bytes.")
    return length


def _json_body(handler: Any) -> Dict[str, Any]:
    length = _length(handler)
    raw = handler.rfile.read(length) if length else b""
    try:
        value = json.loads(raw.decode("utf-8")) if raw else None
    except (UnicodeDecodeError, ValueError):
        value = None
    if not isinstance(value, dict):
        raise _bad("invalid_json", "The body must be a JSON object.")
    return value


def _optional_body(handler: Any) -> Dict[str, Any]:
    length = _length(handler)
    raw = handler.rfile.read(length) if length else b""
    if not raw.strip():
        return {}
    try:
        value = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        raise _bad("invalid_json", "The body must be a JSON object.") from None
    return value if isinstance(value, dict) else {}


def _send(handler: Any, status: int, payload: Dict[str, Any]) -> None:
    body = json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    try:
        handler.send_response(status)
        handler.send_header("Content-Type", "application/json; charset=utf-8")
        handler.send_header("Content-Length", str(len(body)))
        handler.send_header("Cache-Control", "no-store")
        handler.send_header("Connection", "close")
        handler.end_headers()
        handler.wfile.write(body)
    except OSError:
        pass  # the desktop app went away


def make_service(*, installed: bool, state_dir: Optional[str] = None, launch: bool = False) -> InboxService:
    """The installed copy keeps its state in ``DEFAULT_DIR`` and opens apps and Terminal windows; any other copy (a
    checkout, a test, a temp HOME) keeps it in memory unless ``state_dir`` is given and opens nothing unless
    ``launch`` (``--inbox-launch``)."""
    folder = state_dir or (DEFAULT_DIR if installed else None)
    scratch = os.path.join(os.path.expanduser(folder), "scripts") if folder else None
    return InboxService(state_dir=folder, launcher=Launcher(scratch=scratch, dry_run=not (installed or launch)))
