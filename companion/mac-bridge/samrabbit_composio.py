"""The Composio CLI for the SamRabbit bridge: one runner shared by Google Calendar (``samrabbit_calendar``) and Gmail
(``samrabbit_briefing``).

    composio execute <SLUG> -d - --account <connection>

* A hard allow-list of tool slugs (``ALLOWED_SLUGS``): the calendar's four, and Gmail's reads plus
  ``GMAIL_CREATE_EMAIL_DRAFT``. Anything else (``GMAIL_SEND_EMAIL``, ``GMAIL_REPLY_TO_THREAD``, which sends,
  ``GMAIL_SEND_DRAFT``, ``GMAIL_FORWARD_MESSAGE``, deletes, label changes, any other toolkit) is refused before a
  process starts. A runner can narrow it further (``allowed=``): the morning brief's draft writer runs only the draft
  tool and one metadata read. Nothing on this list sends an email.
* ``--account`` is always passed (an alias, word id or account id): with several connections for one toolkit,
  Composio's own pick is never relied on.
* The JSON arguments go on stdin, never argv; no shell; a small environment; the CLI's own process group, killed at
  the timeout; at most 4 MiB of output, parsed and never logged.
* Every call runs in a fresh private folder (0700) that is both its working folder and its ``TMPDIR``, removed right
  after the call: the CLI writes any answer over about 40 KB to ``$TMPDIR/composio/adhoc_*/<SLUG>_OUTPUT_*.json`` and
  never deletes it, so a week of calendar or a page of email would otherwise stay on disk.

Errors are ``ComposioError`` (``{"error": {code, message, retryable, written[, fix]}}``) in the words of the toolkit
that ran the call (``Toolkit``). Stdlib only, Python 3.9.
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
from typing import Any, Callable, Dict, FrozenSet, Iterable, List, Optional

_LOG = logging.getLogger("samrabbit-bridge.composio")

CLI_TIMEOUT_SECONDS = 30.0
MAX_OUTPUT_BYTES = 4 * 1024 * 1024
FALLBACK_COMPOSIO = ("~/.local/bin/composio", "/opt/homebrew/bin/composio", "/usr/local/bin/composio")

CALENDAR_SLUGS = frozenset({"GOOGLECALENDAR_CREATE_EVENT", "GOOGLECALENDAR_PATCH_EVENT",
                            "GOOGLECALENDAR_DELETE_EVENT", "GOOGLECALENDAR_EVENTS_LIST"})
GMAIL_READ_SLUGS = frozenset({"GMAIL_FETCH_EMAILS", "GMAIL_FETCH_MESSAGE_BY_THREAD_ID",
                              "GMAIL_FETCH_MESSAGE_BY_MESSAGE_ID", "GMAIL_GET_PROFILE", "GMAIL_LIST_LABELS",
                              "GMAIL_LIST_HISTORY"})
GMAIL_DRAFT_SLUG = "GMAIL_CREATE_EMAIL_DRAFT"  # a draft in Gmail; Samin sends it himself, or never
GMAIL_SLUGS = GMAIL_READ_SLUGS | {GMAIL_DRAFT_SLUG}
ALLOWED_SLUGS: FrozenSet[str] = CALENDAR_SLUGS | GMAIL_SLUGS

_ACCOUNT = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._@+\-]{0,127}$")  # an alias, a word id (gmail_ectype-tait) or an id


class ComposioError(Exception):
    """An answer of ``{"error": {"code", "message", "retryable", "written"[, "fix"]}}``."""

    def __init__(self, status: int, code: str, message: str, *, retryable: bool = False, written: Any = False,
                 fix: Optional[str] = None) -> None:
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message
        self.retryable = retryable
        self.written = written
        self.fix = fix

    def payload(self) -> Dict[str, Any]:
        error: Dict[str, Any] = {"code": self.code, "message": self.message, "retryable": self.retryable,
                                 "written": self.written}
        if self.fix:
            error["fix"] = self.fix
        return {"error": error}


class Toolkit:
    """How one toolkit's callers hear about the CLI: the error class, the words, the slugs it may run and how
    Composio's ``{"successful": false, ...}`` answers map to its errors (``failure(value, writing)``)."""

    def __init__(self, *, label: str, code_prefix: str, slugs: Iterable[str], missing: str, signed_out: str,
                 signed_out_fix: str, failure: Callable[[Dict[str, Any], bool], Exception],
                 error: Callable[..., Exception] = ComposioError) -> None:
        self.label = label
        self.code_prefix = code_prefix
        self.slugs = frozenset(slugs) & ALLOWED_SLUGS  # never wider than the bridge's own list
        self.missing = missing
        self.signed_out = signed_out
        self.signed_out_fix = signed_out_fix
        self.failure = failure
        self.error = error


def _child_env(private_tmp: str) -> Dict[str, str]:
    """A small, predictable environment for the CLI (no inherited tokens or tool settings); ``TMPDIR`` is the call's
    own private folder, so whatever the CLI writes there goes with it."""
    env = {key: os.environ[key] for key in ("HOME", "USER", "LOGNAME", "LANG", "LC_ALL", "SHELL")
           if os.environ.get(key)}
    env.setdefault("HOME", os.path.expanduser("~"))
    env["PATH"] = os.environ.get("PATH") or "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    env["TMPDIR"] = private_tmp.rstrip("/") + "/"
    return env


def _kill_group(process: subprocess.Popen) -> None:
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except (OSError, ProcessLookupError):
        try:
            process.kill()
        except OSError:
            pass


class ComposioCli:
    """Runs ``composio execute <slug> -d - --account <connection>``. Output is parsed, never logged."""

    def __init__(self, executable: Optional[str] = None, *, toolkit: Toolkit, timeout: float = CLI_TIMEOUT_SECONDS,
                 allowed: Optional[Iterable[str]] = None, workdir: Optional[str] = None,
                 prefix: str = "samrabbit-composio-", explicit_only: bool = False) -> None:
        """``explicit_only``: never look for a CLI by itself (a dev copy of the bridge that was not given one)."""
        self._explicit = executable
        self._explicit_only = explicit_only
        self._timeout = timeout
        self.toolkit = toolkit
        self.allowed = toolkit.slugs if allowed is None else frozenset(allowed) & toolkit.slugs
        self._workdir = workdir or tempfile.mkdtemp(prefix=prefix)  # 0700; each call gets a folder inside it

    def close(self) -> None:
        shutil.rmtree(self._workdir, ignore_errors=True)

    def executable(self) -> Optional[str]:
        """``--composio`` when given (and nothing else, so tests never reach a real CLI); otherwise the path
        install.sh recorded (``SAMRABBIT_COMPOSIO``), ``PATH``, then the usual install folders."""
        candidates: List[str] = []
        if self._explicit:
            candidates.append(os.path.expanduser(self._explicit))
        elif not self._explicit_only:
            if os.environ.get("SAMRABBIT_COMPOSIO"):
                candidates.append(os.path.expanduser(os.environ["SAMRABBIT_COMPOSIO"]))
            found = shutil.which("composio")
            if found:
                candidates.append(found)
            candidates += [os.path.expanduser(path) for path in self._fallbacks()]
        for path in candidates:
            if os.path.isfile(path) and os.access(path, os.X_OK):
                return path
        return None

    def _fallbacks(self) -> Iterable[str]:
        return FALLBACK_COMPOSIO

    def permits(self, slug: str) -> bool:
        return isinstance(slug, str) and slug in self.allowed

    def execute(self, slug: str, arguments: Dict[str, Any], *, writing: bool, account: Optional[str]) -> Dict[str, Any]:
        """The tool's ``data`` on success; the toolkit's error otherwise. A slug off the allow-list or a missing
        account is refused before anything runs."""
        kit = self.toolkit
        if not self.permits(slug):
            _LOG.warning("composio tool refused (not on the allow-list)")
            raise kit.error(403, "composio_tool_refused", "The Mac bridge never runs that Composio tool.",
                            written=False)
        if not isinstance(account, str) or not _ACCOUNT.match(account):
            raise kit.error(503, "composio_account_missing", f"No Composio connection is chosen for {kit.label} on "
                            "the Mac.", written=False, fix=kit.signed_out_fix)
        unknown: Any = "unknown" if writing else False
        executable = self.executable()
        if executable is None:
            raise kit.error(503, "composio_missing", kit.missing, written=False)
        os.makedirs(self._workdir, mode=0o700, exist_ok=True)
        try:
            private = tempfile.mkdtemp(prefix="call-", dir=self._workdir)  # its cwd and TMPDIR, gone after the call
        except OSError:
            raise kit.error(503, "composio_failed", "The Mac bridge could not make a private folder for Composio.",
                            written=False) from None
        try:
            try:
                process = subprocess.Popen([executable, "execute", slug, "-d", "-", "--account", account],
                                           stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                           env=_child_env(private), cwd=private, start_new_session=True)
            except OSError:
                raise kit.error(503, "composio_missing", "The Composio CLI could not be started on the Mac.",
                                written=False) from None
            try:
                out, _err = process.communicate(json.dumps(arguments, ensure_ascii=False).encode("utf-8"),
                                                timeout=self._timeout)
            except subprocess.TimeoutExpired:
                _kill_group(process)
                process.communicate()
                raise kit.error(504, kit.code_prefix + "_timeout", f"{kit.label} did not answer in time.",
                                retryable=not writing, written=unknown) from None
        finally:
            shutil.rmtree(private, ignore_errors=True)
        if len(out) > MAX_OUTPUT_BYTES:
            raise kit.error(502, kit.code_prefix + "_bad_answer", "The Composio CLI sent too much at once.",
                            written=unknown)
        text = out.decode("utf-8", errors="replace").strip()
        if not text:
            if process.returncode == 0:  # what a signed-out CLI does
                raise kit.error(503, "composio_signed_out", kit.signed_out, written=False, fix=kit.signed_out_fix)
            raise kit.error(502, "composio_failed", "The Composio CLI failed on the Mac.", written=unknown)
        try:
            value = json.loads(text)
        except ValueError:
            value = None
        if not isinstance(value, dict):
            raise kit.error(502, kit.code_prefix + "_bad_answer", "The Composio CLI answered with something "
                            "unreadable.", written=unknown)
        if value.get("successful") is True:
            data = value.get("data")
            return data if isinstance(data, dict) else {}
        raise kit.failure(value, writing)
