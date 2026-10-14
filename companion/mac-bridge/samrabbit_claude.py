"""One isolated ``claude -p`` answer as JSON, for the bridge's small model jobs: the voice-note router
(``samrabbit_capture``, Claude Haiku as a classifier) and the morning brief (``samrabbit_briefing``, Claude Sonnet).

    claude -p --model <model> --output-format json --tools "" --setting-sources "" --strict-mcp-config --safe-mode
           --disable-slash-commands --no-session-persistence --permission-mode dontAsk
           --system-prompt-file <0600 file> --json-schema <schema>
           [--effort <level>] [--fallback-model <model>] [--max-budget-usd <amount>]

The model gets no tools, no MCP servers, no skills, plugins, hooks, settings or CLAUDE.md files (``--safe-mode``,
``--setting-sources ""``: the user's own hooks would otherwise see the words, e.g. a memory plugin that uploads
messages), no session files, and an empty private working folder that is also its ``TMPDIR``. The prompt goes on
stdin, never argv; the answer is the envelope's ``structured_output`` (checked against ``--json-schema`` by the CLI,
and again by the caller). The bridge decides what happens with it: the model only ever proposes. Nothing but the
duration, the cost and an error code is logged. Never ``--bare`` (it would skip the Claude login). Stdlib only.
"""

from __future__ import annotations

import json
import logging
import os
import re
import shutil
import signal
import subprocess
import tempfile
import threading
from typing import Any, Dict, List, Optional, Tuple

_LOG = logging.getLogger("samrabbit-bridge.claude")

FALLBACK_CLAUDE = ("~/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "~/.claude/local/claude")
CLAUDE_PATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
CLAUDE_ENV_KEYS = ("HOME", "USER", "LOGNAME", "LANG")
CLAUDE_FLAGS_ENV = {"CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1", "CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1",
                    "DISABLE_AUTOUPDATER": "1"}
MAX_OUTPUT_BYTES = 2 * 1024 * 1024
_MODEL = re.compile(r"^claude-[a-z0-9][a-z0-9.\-]{1,60}$")
_EFFORT = frozenset({"low", "medium", "high", "max"})


class ClaudeError(Exception):
    def __init__(self, code: str, message: str, *, retryable: bool = False) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.retryable = retryable


def valid_model(value: Any) -> Optional[str]:
    return value.strip() if isinstance(value, str) and _MODEL.match(value.strip()) else None


def _kill_group(process: subprocess.Popen) -> None:
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except (OSError, ProcessLookupError):
        try:
            process.kill()
        except OSError:
            pass


class ClaudeJson:
    """``ask(system, prompt, schema)`` -> ``(answer, meta)``. ``explicit_only``: use only the executable given (a dev
    copy of the bridge never runs the user's real Claude Code by itself)."""

    def __init__(self, executable: Optional[str] = None, *, model: str, timeout: float,
                 fallback_model: Optional[str] = None, effort: Optional[str] = None,
                 max_budget_usd: Optional[float] = None, explicit_only: bool = False,
                 prefix: str = "samrabbit-claude-") -> None:
        self._explicit = executable
        self._explicit_only = explicit_only
        self.model = valid_model(model) or "claude-haiku-5-5"
        self.fallback_model = valid_model(fallback_model)
        self.effort = effort if effort in _EFFORT else None
        self.max_budget_usd = max_budget_usd
        self.timeout = timeout
        self._prefix = prefix
        self._lock = threading.Lock()
        self._processes: List[subprocess.Popen] = []

    def executable(self) -> Optional[str]:
        candidates: List[str] = []
        if self._explicit:
            candidates.append(os.path.expanduser(self._explicit))
        elif not self._explicit_only:
            if os.environ.get("SAMRABBIT_CLAUDE"):
                candidates.append(os.path.expanduser(os.environ["SAMRABBIT_CLAUDE"]))
            found = shutil.which("claude")
            if found:
                candidates.append(found)
            candidates += [os.path.expanduser(path) for path in FALLBACK_CLAUDE]
        for path in candidates:
            if os.path.isfile(path) and os.access(path, os.X_OK):
                return path
        return None

    def available(self) -> bool:
        return self.executable() is not None

    def stop(self) -> None:
        """Kills the calls still running (the bridge is stopping)."""
        with self._lock:
            processes = list(self._processes)
        for process in processes:
            if process.poll() is None:
                _kill_group(process)

    def arguments(self, executable: str, system_file: str, schema: Dict[str, Any], model: str) -> List[str]:
        args = [executable, "-p", "--model", model, "--output-format", "json", "--tools", "", "--setting-sources", "",
                "--strict-mcp-config", "--safe-mode", "--disable-slash-commands", "--no-session-persistence",
                "--permission-mode", "dontAsk", "--system-prompt-file", system_file,
                "--json-schema", json.dumps(schema, separators=(",", ":"))]
        if self.effort:
            args += ["--effort", self.effort]
        if self.fallback_model and self.fallback_model != model:
            args += ["--fallback-model", self.fallback_model]
        if self.max_budget_usd:
            args += ["--max-budget-usd", f"{float(self.max_budget_usd):.2f}"]
        return args

    def ask(self, *, system: str, prompt: str, schema: Dict[str, Any], model: Optional[str] = None,
            timeout: Optional[float] = None) -> Tuple[Dict[str, Any], Dict[str, Any]]:
        executable = self.executable()
        if executable is None:
            raise ClaudeError("claude_missing", "Claude Code is not installed on the Mac.")
        work = tempfile.mkdtemp(prefix=self._prefix)  # 0700
        try:
            cwd = os.path.join(work, "cwd")  # stays empty: the CLI's working folder and TMPDIR
            os.mkdir(cwd, 0o700)
            system_file = os.path.join(work, "system.md")
            with open(os.open(system_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w",
                      encoding="utf-8") as handle:
                handle.write(system)
            env = {key: os.environ[key] for key in CLAUDE_ENV_KEYS if os.environ.get(key)}
            env.setdefault("HOME", os.path.expanduser("~"))
            env.update(CLAUDE_FLAGS_ENV, PATH=CLAUDE_PATH, TMPDIR=cwd + "/")
            args = self.arguments(executable, system_file, schema, valid_model(model) or self.model)
            try:
                process = subprocess.Popen(args, cwd=cwd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                           stderr=subprocess.PIPE, env=env, start_new_session=True)
            except OSError:
                raise ClaudeError("claude_unavailable", "Claude Code could not be started on the Mac.",
                                  retryable=True) from None
            with self._lock:
                self._processes.append(process)
            try:
                out, err = process.communicate(prompt.encode("utf-8"), timeout=max(0.5, timeout or self.timeout))
            except subprocess.TimeoutExpired:
                _kill_group(process)
                process.communicate()
                raise ClaudeError("claude_timeout", "Claude took too long.", retryable=True) from None
            finally:
                with self._lock:
                    if process in self._processes:
                        self._processes.remove(process)
        finally:
            shutil.rmtree(work, ignore_errors=True)
        return parse_envelope(out, process.returncode, err)


def parse_envelope(out: bytes, code: int, err: bytes = b"") -> Tuple[Dict[str, Any], Dict[str, Any]]:
    """The CLI's ``--output-format json`` envelope -> ``(structured_output, {costUsd, durationMs, model})``."""
    if len(out) > MAX_OUTPUT_BYTES:
        raise ClaudeError("claude_bad_output", "Claude's answer was too large.")
    try:
        envelope = json.loads(out.decode("utf-8")) if out.strip() else None
    except (UnicodeDecodeError, ValueError):
        envelope = None
    if not isinstance(envelope, dict):
        detail = err.decode("utf-8", errors="replace").lower()
        if "not logged in" in detail or "login" in detail:
            raise ClaudeError("claude_signed_out", "Claude Code on the Mac is signed out.")
        if code != 0:
            raise ClaudeError("claude_failed", "Claude Code failed on the Mac.", retryable=True)
        raise ClaudeError("claude_bad_output", "Claude Code answered with unreadable output.", retryable=True)
    if envelope.get("is_error") or envelope.get("subtype") not in (None, "success"):
        status = envelope.get("api_error_status")
        if status in (429, 529) or (isinstance(status, int) and status >= 500):
            raise ClaudeError("claude_busy", "Claude is busy right now.", retryable=True)
        text = str(envelope.get("result") or "").lower()
        if "login" in text or "authenticat" in text or status == 401:
            raise ClaudeError("claude_signed_out", "Claude Code on the Mac is signed out.")
        if "budget" in str(envelope.get("subtype") or "").lower() or "budget" in text:
            raise ClaudeError("claude_budget", "That would have cost more than the bridge allows.")
        raise ClaudeError("claude_failed", "Claude could not answer.", retryable=True)
    value = envelope.get("structured_output")
    if not isinstance(value, dict):
        raise ClaudeError("claude_bad_output", "Claude did not answer in the expected shape.", retryable=True)
    usage = envelope.get("modelUsage") if isinstance(envelope.get("modelUsage"), dict) else {}
    cost = envelope.get("total_cost_usd")
    duration = envelope.get("duration_ms")
    meta = {"costUsd": float(cost) if isinstance(cost, (int, float)) and not isinstance(cost, bool) else None,
            "durationMs": int(duration) if isinstance(duration, (int, float)) and not isinstance(duration, bool)
            else None,
            "model": next((name for name in usage if valid_model(name)), None)}
    return value, meta
