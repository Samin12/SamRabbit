#!/usr/bin/env python3
"""Samin's ChatGPT subscription on the Mac: the login the watch assistant's realtime voice uses.

The same Codex device authorization the R1 does (``runtime/sam_runtime/providers/openai/subscription.py``), with its
own login, so the Mac's tokens never rotate the R1's (refresh tokens rotate when they are used) and never write
ChatGPT.app's ``~/.codex``:

1. ``POST {issuer}/api/accounts/deviceauth/usercode {client_id}`` -> ``{device_auth_id, user_code, interval}``;
   Samin opens ``https://auth.openai.com/codex/device`` and types the code;
2. the bridge polls ``POST {issuer}/api/accounts/deviceauth/token {device_auth_id, user_code}`` (403/404: not yet)
   until it answers ``{authorization_code, code_verifier}`` (15 minutes at most);
3. ``POST {issuer}/oauth/token`` (form: ``grant_type=authorization_code``, the code, the device redirect URI, the
   client id and the verifier) -> ``{access_token, refresh_token, id_token, expires_in}``.

When the Mac has no login of its own, the installed bridge borrows the one Codex keeps in ``~/.codex/auth.json``
(``$CODEX_HOME`` when set; ``CodexLoginAuth``): Samin is signed in to Codex on this Mac with the same client, so the
token works for the realtime voice as it is. That file is only ever read: never written, never refreshed (its refresh
token rotates, so refreshing it here would sign Codex out). Codex refreshes it itself every few days. When the
borrowed token has expired the realtime voice is off (the Claude brain answers) until Codex has renewed it or Samin
connects the Mac's own login; when OpenAI refuses it, the realtime brain pauses as for the Mac's own login and tries
again later with whatever token the file then holds. ``SAMRABBIT_CODEX_LOGIN=0`` turns the borrowing off.

The tokens live in ``~/.config/samrabbit/chatgpt-auth.json`` (0600, written whole to a temp file and moved over) and
are refreshed (``grant_type=refresh_token``, JSON) five minutes before the access token expires; the rotated refresh
token is stored at once. Tokens, the user code and the account's email are never logged. A copy of the bridge run
from a checkout never uses that file: only an explicit ``--chatgpt-auth-file`` (``make_auth``).

Routes (``samrabbit_mobile``; loopback peer + the desktop app's token, like Pair iPhone):

* ``POST /v1/assistant/chatgpt/start`` -> ``{userCode, verificationUrl, expiresAt}`` (the bridge polls by itself);
* ``GET /v1/assistant/chatgpt/status`` -> ``{connected, plan?, email?, login: {state: "idle" | "waiting" | "done" |
  "expired" | "failed", userCode?, verificationUrl?, expiresAt?, reason?}}``;
* ``POST /v1/assistant/chatgpt/disconnect`` -> ``{connected: false}`` (the file is deleted).

Command line (``connect-chatgpt.sh``): ``python3 -I samrabbit_chatgpt.py connect|status|disconnect [--port 3780]
[--desktop-token-file ~/.config/samrabbit/desktop-token] [--open]``: asks the running bridge over loopback (no system
proxy), prints the code and the link, and waits for the login. Stdlib only, Python 3.9.
"""

from __future__ import annotations

import argparse
import base64
from datetime import datetime, timezone
import hashlib
import http.client
import json
import logging
import os
import secrets
import ssl
import stat
import subprocess
import sys
import tempfile
import threading
import time
from typing import Any, Callable, Dict, Optional, Tuple
from urllib.parse import urlencode, urlsplit

_LOG = logging.getLogger("samrabbit-bridge.chatgpt")

CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"
ISSUER = "https://auth.openai.com"
DEVICE_REDIRECT_PATH = "/deviceauth/callback"
VERIFICATION_PATH = "/codex/device"
AUTH_LIFETIME_SECONDS = 15 * 60
REFRESH_LEEWAY_SECONDS = 5 * 60
HTTP_TIMEOUT_SECONDS = 30.0
DEFAULT_AUTH_FILE = "~/.config/samrabbit/chatgpt-auth.json"
DEFAULT_CODEX_HOME = "~/.codex"
AUDIENCE = "https://api.openai.com/v1"
BORROWED_LEEWAY_SECONDS = 2 * 60
OFF_VALUES = ("0", "false", "off", "no")
USER_AGENT = "SamRabbit-Mac-Bridge/1.0"
START_ROUTE = "/v1/assistant/chatgpt/start"
STATUS_ROUTE = "/v1/assistant/chatgpt/status"
DISCONNECT_ROUTE = "/v1/assistant/chatgpt/disconnect"
MAX_FILE_BYTES = 64 * 1024
MAX_ANSWER_BYTES = 256 * 1024
REJECTED_PAUSE_SECONDS = 60.0

Transport = Callable[[str, str, Dict[str, str], bytes], Tuple[int, Dict[str, Any]]]


class ChatGPTError(Exception):
    """``{"error": {code, message, retryable}}``; ``reconnect``: only a new login helps."""

    def __init__(self, status: int, code: str, message: str, *, retryable: bool = False) -> None:
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message
        self.retryable = retryable

    @property
    def reconnect(self) -> bool:
        return self.code in ("chatgpt_not_connected", "chatgpt_reconnect_required")

    def payload(self) -> Dict[str, Any]:
        return {"error": {"code": self.code, "message": self.message, "retryable": self.retryable}}


def not_connected() -> ChatGPTError:
    return ChatGPTError(409, "chatgpt_not_connected", "ChatGPT is not connected on the Mac. Use SamRabbit > Connect "
                        "ChatGPT… (or connect-chatgpt.sh).")


def reconnect_required() -> ChatGPTError:
    return ChatGPTError(409, "chatgpt_reconnect_required", "ChatGPT needs to be connected again on the Mac.")


# --------------------------------------------------------------------------- HTTP (stdlib)


def _post(url: str, content_type: str, headers: Dict[str, str], body: bytes, *,
          timeout: float = HTTP_TIMEOUT_SECONDS) -> Tuple[int, Dict[str, Any]]:
    """One POST; ``(status, JSON object or {})``. HTTPS, or plain HTTP to loopback (a stand-in, in tests). Never
    through a system proxy; the body and the answer are never logged."""
    parts = urlsplit(url)
    host = parts.hostname or ""
    if parts.scheme == "https":
        connection: http.client.HTTPConnection = http.client.HTTPSConnection(
            host, parts.port or 443, timeout=timeout, context=ssl.create_default_context())
    elif parts.scheme == "http" and host in ("127.0.0.1", "localhost", "::1"):
        connection = http.client.HTTPConnection(host, parts.port or 80, timeout=timeout)
    else:
        raise ChatGPTError(500, "chatgpt_bad_url", "The ChatGPT login address is not allowed.")
    path = (parts.path or "/") + (("?" + parts.query) if parts.query else "")
    try:
        connection.request("POST", path, body=body, headers={
            "Content-Type": content_type, "Accept": "application/json", "User-Agent": USER_AGENT, **headers})
        response = connection.getresponse()
        status = response.status
        raw = response.read(MAX_ANSWER_BYTES + 1)
    except (OSError, http.client.HTTPException, ssl.SSLError):
        raise ChatGPTError(503, "chatgpt_unreachable", "ChatGPT login is not reachable right now.",
                           retryable=True) from None
    finally:
        connection.close()
    try:
        value = json.loads(raw.decode("utf-8")) if raw and len(raw) <= MAX_ANSWER_BYTES else {}
    except (UnicodeDecodeError, ValueError):
        value = {}
    return status, value if isinstance(value, dict) else {}


def default_transport(url: str, content_type: str, headers: Dict[str, str], body: bytes) -> Tuple[int, Dict[str, Any]]:
    return _post(url, content_type, headers, body)


# --------------------------------------------------------------------------- tokens


def jwt_claims(token: Any) -> Dict[str, Any]:
    """The claims of a JWT (not verified: only read for the plan, the email and the expiry), or {}."""
    if not isinstance(token, str) or token.count(".") < 2:
        return {}
    middle = token.split(".")[1]
    try:
        raw = base64.urlsafe_b64decode(middle + "=" * (-len(middle) % 4))
        value = json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return {}
    return value if isinstance(value, dict) else {}


def account_of(tokens: Dict[str, Any]) -> Dict[str, Any]:
    """``{email?, plan?, accountId?}`` from the id token (else the access token)."""
    found: Dict[str, Any] = {}
    for token in (tokens.get("id_token"), tokens.get("access_token")):
        claims = jwt_claims(token)
        auth = claims.get("https://api.openai.com/auth") if isinstance(claims.get("https://api.openai.com/auth"),
                                                                      dict) else {}
        profile = claims.get("https://api.openai.com/profile") \
            if isinstance(claims.get("https://api.openai.com/profile"), dict) else {}
        email = claims.get("email") or profile.get("email")
        if isinstance(email, str) and "@" in email and len(email) <= 254:
            found.setdefault("email", email)
        plan = auth.get("chatgpt_plan_type")
        if isinstance(plan, str) and plan and len(plan) <= 40:
            found.setdefault("plan", plan)
        account = auth.get("chatgpt_account_id") or auth.get("chatgpt_user_id") or claims.get("sub")
        if isinstance(account, str) and account and len(account) <= 200:
            found.setdefault("accountId", account)
    return found


def _positive_int(value: Any) -> Optional[int]:
    if isinstance(value, bool):
        return None
    try:
        parsed = int(value)
    except (TypeError, ValueError):
        return None
    return parsed if parsed > 0 else None


def _iso(epoch: float) -> str:
    return datetime.fromtimestamp(epoch, timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _write_private(path: str, text: str) -> None:
    folder = os.path.dirname(path) or "."
    os.makedirs(folder, mode=0o700, exist_ok=True)
    handle, temp = tempfile.mkstemp(prefix=".tmp-", dir=folder)
    try:
        os.fchmod(handle, 0o600)
        with os.fdopen(handle, "w", encoding="utf-8") as file:
            file.write(text)
        os.replace(temp, path)
    except BaseException:
        try:
            os.unlink(temp)
        except OSError:
            pass
        raise


class _Login:
    def __init__(self, device_auth_id: str, user_code: str, interval: int, expires_at: float) -> None:
        self.device_auth_id = device_auth_id
        self.user_code = user_code
        self.interval = interval
        self.expires_at = expires_at
        self.state = "waiting"  # waiting -> done | expired | failed | cancelled
        self.reason: Optional[str] = None
        self.cancelled = threading.Event()


class ChatGPTAuth:
    """The Mac's own ChatGPT login (module docstring). ``access_token()`` is what the realtime voice uses."""

    def __init__(self, auth_file: str, *, issuer: str = ISSUER, transport: Optional[Transport] = None,
                 clock: Callable[[], float] = time.time, poll_floor: float = 1.0) -> None:
        self.path = os.path.expanduser(auth_file)
        self.issuer = issuer.rstrip("/")
        self._transport = transport or default_transport
        self._clock = clock
        self._poll_floor = poll_floor  # tests poll faster than the 1 s the server allows
        self._lock = threading.RLock()
        self._refresh_lock = threading.Lock()
        self._login: Optional[_Login] = None
        self._thread: Optional[threading.Thread] = None
        self._cache: Optional[Tuple[Tuple[int, int], Dict[str, Any]]] = None
        self._rejected_at = -1e12
        self.off: Optional[str] = None
        # Called only when the login really changed: a new one is stored, a disconnect, or a refresh OpenAI refused
        # (never for a login attempt that expired or failed). The realtime brain then retires its sessions.
        self.on_change: Optional[Callable[[], None]] = None

    @property
    def verification_url(self) -> str:
        return self.issuer + VERIFICATION_PATH

    # ------------------------------------------------------------------ the file
    def _read(self) -> Optional[Dict[str, Any]]:
        try:
            info = os.stat(self.path)
        except OSError:
            return None
        stamp = (info.st_mtime_ns, info.st_size)
        with self._lock:
            if self._cache is not None and self._cache[0] == stamp:
                return self._cache[1]
        if info.st_mode & (stat.S_IRWXG | stat.S_IRWXO):
            try:
                os.chmod(self.path, 0o600)
                _LOG.warning("chatgpt auth file permissions tightened to 0600")
            except OSError:
                return None
        if info.st_size > MAX_FILE_BYTES:
            return None
        try:
            with open(self.path, "r", encoding="utf-8") as handle:
                value = json.load(handle)
        except (OSError, ValueError, UnicodeDecodeError):
            return None
        if not isinstance(value, dict) or not isinstance(value.get("tokens"), dict) or \
                not isinstance(value["tokens"].get("access_token"), str):
            return None
        with self._lock:
            self._cache = (stamp, value)
        return value

    def _store(self, payload: Dict[str, Any], previous: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        access = payload.get("access_token")
        if not isinstance(access, str) or not access:
            raise ChatGPTError(502, "chatgpt_token_invalid", "ChatGPT login returned no access token.")
        tokens = {key: payload[key] for key in ("access_token", "refresh_token", "id_token", "token_type", "scope")
                  if isinstance(payload.get(key), str) and payload.get(key)}
        if previous is not None:
            for key in ("refresh_token", "id_token"):
                if key not in tokens and isinstance(previous.get(key), str):
                    tokens[key] = previous[key]
        now = self._clock()
        expires_in = _positive_int(payload.get("expires_in"))
        expires_at = now + expires_in if expires_in else _positive_int(jwt_claims(access).get("exp"))
        record = {"version": 1, "tokens": tokens, "expiresAt": int(expires_at) if expires_at else None,
                  "account": account_of(tokens), "updatedAt": _iso(now)}
        with self._lock:
            old = self._read()
            record["connectedAt"] = (old or {}).get("connectedAt") if previous is not None else _iso(now)
            record["safetyId"] = (old or {}).get("safetyId") or secrets.token_hex(16)
            _write_private(self.path, json.dumps(record, indent=1) + "\n")
            self._cache = None
        return record

    # ------------------------------------------------------------------ status
    def connected(self) -> bool:
        record = self._read()
        return record is not None and not record.get("needsReconnect")

    def status(self) -> Dict[str, Any]:
        record = self._read()
        value: Dict[str, Any] = {"connected": record is not None and not record.get("needsReconnect")}
        if record is not None and record.get("needsReconnect"):
            value["reason"] = "reconnect_required"
        if record is not None:
            account = record.get("account") if isinstance(record.get("account"), dict) else {}
            for key in ("plan", "email"):
                if isinstance(account.get(key), str):
                    value[key] = account[key]
        with self._lock:
            login = self._login
            if login is not None and login.state == "waiting" and self._clock() >= login.expires_at:
                login.state = "expired"
            if login is None:
                value["login"] = {"state": "idle"}
            else:
                state = {"state": login.state}
                if login.state == "waiting":
                    state.update(userCode=login.user_code, verificationUrl=self.verification_url,
                                 expiresAt=_iso(login.expires_at))
                if login.reason:
                    state["reason"] = login.reason
                value["login"] = state
        return value

    def safety_id(self) -> str:
        """A stable, anonymous id for ``OpenAI-Safety-Identifier`` (hashed again by the caller)."""
        record = self._read() or {}
        account = record.get("account") if isinstance(record.get("account"), dict) else {}
        return str(account.get("accountId") or record.get("safetyId") or "unknown")

    # ------------------------------------------------------------------ the login
    def start(self) -> Dict[str, Any]:
        """A new device login (any earlier one that is still waiting is cancelled). The bridge polls by itself."""
        status, payload = self._transport(f"{self.issuer}/api/accounts/deviceauth/usercode", "application/json", {},
                                          json.dumps({"client_id": CLIENT_ID}).encode("utf-8"))
        if status >= 400:
            _LOG.warning("chatgpt login start failed (HTTP %d)", status)
            raise ChatGPTError(502, "chatgpt_login_failed", "ChatGPT login could not be started.", retryable=True)
        device_auth_id = payload.get("device_auth_id")
        user_code = payload.get("user_code") or payload.get("usercode")
        if not isinstance(device_auth_id, str) or not device_auth_id or not isinstance(user_code, str) or \
                not user_code or len(user_code) > 64:
            raise ChatGPTError(502, "chatgpt_login_invalid", "ChatGPT login returned an invalid answer.")
        interval = min(30, max(1, _positive_int(payload.get("interval")) or 5))
        login = _Login(device_auth_id, user_code, interval, self._clock() + AUTH_LIFETIME_SECONDS)
        with self._lock:
            if self._login is not None:
                self._login.cancelled.set()
                if self._login.state == "waiting":
                    self._login.state = "cancelled"
            self._login = login
            self._thread = threading.Thread(target=self._poll, args=(login,), name="samrabbit-chatgpt-login",
                                            daemon=True)
            self._thread.start()
        _LOG.info("chatgpt login started")
        return {"userCode": user_code, "verificationUrl": self.verification_url, "expiresAt": _iso(login.expires_at)}

    def _poll(self, login: _Login) -> None:
        while not login.cancelled.wait(timeout=max(self._poll_floor, float(login.interval))):
            if self._clock() >= login.expires_at:
                self._finish(login, "expired")
                return
            try:
                if self.poll_once(login):
                    return
            except ChatGPTError as error:
                if error.retryable:
                    continue  # the network blinked: try again at the next interval
                self._finish(login, "failed", error.code)
                return
            except Exception:  # noqa: BLE001 - never leaves a login hanging as "waiting"
                self._finish(login, "failed", "unexpected")
                return

    def poll_once(self, login: _Login) -> bool:
        """One poll: True when the login is over (done or failed)."""
        status, payload = self._transport(f"{self.issuer}/api/accounts/deviceauth/token", "application/json", {},
                                          json.dumps({"device_auth_id": login.device_auth_id,
                                                      "user_code": login.user_code}).encode("utf-8"))
        if status in (403, 404, 428):
            return False  # Samin has not approved it yet
        if status == 429:
            login.interval = min(30, login.interval + 5)
            return False
        if status >= 400:
            _LOG.warning("chatgpt login poll failed (HTTP %d)", status)
            self._finish(login, "failed", f"http_{status}")
            return True
        code, verifier = payload.get("authorization_code"), payload.get("code_verifier")
        if not isinstance(code, str) or not code or not isinstance(verifier, str) or not verifier:
            self._finish(login, "failed", "invalid_answer")
            return True
        form = urlencode({"grant_type": "authorization_code", "code": code,
                          "redirect_uri": self.issuer + DEVICE_REDIRECT_PATH, "client_id": CLIENT_ID,
                          "code_verifier": verifier}).encode("ascii")
        status, tokens = self._transport(f"{self.issuer}/oauth/token", "application/x-www-form-urlencoded", {}, form)
        if status >= 400:
            _LOG.warning("chatgpt token exchange failed (HTTP %d)", status)
            self._finish(login, "failed", f"http_{status}")
            return True
        if login.cancelled.is_set():
            return True
        try:
            self._store(tokens)
        except (ChatGPTError, OSError):
            self._finish(login, "failed", "not_stored")
            return True
        self._finish(login, "done")
        _LOG.info("chatgpt connected")
        return True

    def _finish(self, login: _Login, state: str, reason: Optional[str] = None) -> None:
        with self._lock:
            if login.state == "waiting":
                login.state, login.reason = state, reason
        if state != "done":
            # An expired code or a failed poll changed nothing: the stored login (and every live session made with
            # it) is still the one there was, so nobody is told.
            _LOG.info("chatgpt login %s%s", state, f" ({reason})" if reason else "")
            return
        self._changed()

    def _changed(self) -> None:
        callback = self.on_change
        if callable(callback):
            try:
                callback()
            except Exception:  # noqa: BLE001
                _LOG.warning("chatgpt change callback failed")

    def disconnect(self) -> Dict[str, Any]:
        with self._lock:
            if self._login is not None:
                self._login.cancelled.set()
                if self._login.state == "waiting":
                    self._login.state = "cancelled"
                self._login = None
            try:
                os.unlink(self.path)
            except FileNotFoundError:
                pass
            self._cache = None
        _LOG.info("chatgpt disconnected")
        self._changed()
        return {"connected": False}

    def close(self) -> None:
        with self._lock:
            if self._login is not None:
                self._login.cancelled.set()

    # ------------------------------------------------------------------ the access token
    def expires_in(self) -> Optional[float]:
        record = self._read()
        if record is None or not record.get("expiresAt"):
            return None
        return float(record["expiresAt"]) - self._clock()

    def access_token(self, *, force_refresh: bool = False) -> str:
        """The access token, refreshed first when it expires within five minutes (or ``force_refresh``: OpenAI just
        refused it). One refresh at a time: the refresh token rotates."""
        record = self._read()
        if record is None:
            raise not_connected()
        if record.get("needsReconnect"):
            raise reconnect_required()
        if not force_refresh and not self._expiring(record):
            return str(record["tokens"]["access_token"])
        with self._refresh_lock:
            current = self._read()
            if current is None:
                raise not_connected()
            if current.get("needsReconnect"):
                raise reconnect_required()
            if current["tokens"].get("access_token") != record["tokens"].get("access_token") and \
                    not self._expiring(current):
                return str(current["tokens"]["access_token"])  # another thread just refreshed it
            if self._clock() - self._rejected_at < REJECTED_PAUSE_SECONDS:
                raise ChatGPTError(503, "chatgpt_unreachable", "ChatGPT did not answer just now.", retryable=True)
            return self._refresh(current)

    def _expiring(self, record: Dict[str, Any]) -> bool:
        expires_at = _positive_int(record.get("expiresAt"))
        return expires_at is not None and expires_at <= self._clock() + REFRESH_LEEWAY_SECONDS

    def _refresh(self, record: Dict[str, Any]) -> str:
        refresh = record["tokens"].get("refresh_token")
        if not isinstance(refresh, str) or not refresh:
            raise reconnect_required()
        status, payload = self._transport(f"{self.issuer}/oauth/token", "application/json", {}, json.dumps(
            {"grant_type": "refresh_token", "client_id": CLIENT_ID, "refresh_token": refresh}).encode("utf-8"))
        if status in (400, 401, 403):
            _LOG.warning("chatgpt refresh refused (HTTP %d): connect ChatGPT again", status)
            self._mark_refused(record)
            raise reconnect_required()
        if status >= 400:
            self._rejected_at = self._clock()
            _LOG.warning("chatgpt refresh failed (HTTP %d)", status)
            raise ChatGPTError(503, "chatgpt_unreachable", "ChatGPT did not answer just now.", retryable=True)
        stored = self._store(payload, previous=record["tokens"])
        _LOG.info("chatgpt token refreshed")
        return str(stored["tokens"]["access_token"])

    def _mark_refused(self, record: Dict[str, Any]) -> None:
        """The refresh token was refused: the login is over (status says ``reconnect_required``) until a new one."""
        with self._lock:
            value = dict(record, needsReconnect=True, updatedAt=_iso(self._clock()))
            try:
                _write_private(self.path, json.dumps(value, indent=1) + "\n")
            except OSError:
                _LOG.warning("chatgpt auth file not updated")
            self._cache = None
        self._changed()

    def refresh_if_needed(self) -> None:
        """For a background worker: refresh ahead of time so a turn never waits for it."""
        record = self._read()
        if record is not None and not record.get("needsReconnect") and self._expiring(record):
            try:
                self.access_token()
            except ChatGPTError:
                pass


class UnavailableAuth:
    """A copy of the bridge that may not use a ChatGPT login (a checkout without ``--chatgpt-auth-file``)."""

    off = "chatgpt_dev_copy"
    path = ""
    on_change: Optional[Callable[[], None]] = None
    verification_url = ISSUER + VERIFICATION_PATH

    def connected(self) -> bool:
        return False

    def status(self) -> Dict[str, Any]:
        return {"connected": False, "reason": self.off, "login": {"state": "idle"}}

    def start(self) -> Dict[str, Any]:
        raise ChatGPTError(409, "chatgpt_dev_copy", "This copy of the Mac bridge is not the installed one, so it uses "
                           "a ChatGPT login only with an explicit --chatgpt-auth-file.")

    def disconnect(self) -> Dict[str, Any]:
        return {"connected": False}

    def access_token(self, *, force_refresh: bool = False) -> str:
        raise not_connected()

    def safety_id(self) -> str:
        return "dev"

    def expires_in(self) -> Optional[float]:
        return None

    def refresh_if_needed(self) -> None:
        return None

    def close(self) -> None:
        return None


class CodexLoginAuth:
    """Codex's own ChatGPT login on this Mac (``~/.codex/auth.json``), borrowed read-only (module docstring).

    Usable while it is a ChatGPT login (not an API key) of the same client for the OpenAI API whose access token is
    good for two more minutes. A token Codex renewed is used as soon as the file changes."""

    off: Optional[str] = None

    def __init__(self, auth_file: str, *, clock: Callable[[], float] = time.time) -> None:
        self.path = os.path.expanduser(auth_file)
        self._clock = clock
        self._lock = threading.Lock()
        self._cache: Optional[Tuple[Tuple[int, int], Optional[Dict[str, Any]]]] = None

    def _read(self) -> Optional[Dict[str, Any]]:
        """``{token, exp, account}`` of a usable-looking login, or None. Opens the file read-only, nothing else."""
        try:
            info = os.stat(self.path)
        except OSError:
            return None
        stamp = (info.st_mtime_ns, info.st_size)
        with self._lock:
            if self._cache is not None and self._cache[0] == stamp:
                return self._cache[1]
        found: Optional[Dict[str, Any]] = None
        if stat.S_ISREG(info.st_mode) and 0 < info.st_size <= MAX_FILE_BYTES:
            try:
                with open(self.path, "r", encoding="utf-8") as handle:
                    value = json.load(handle)
            except (OSError, ValueError, UnicodeDecodeError):
                value = None
            tokens = value.get("tokens") if isinstance(value, dict) else None
            access = tokens.get("access_token") if isinstance(tokens, dict) else None
            mode = value.get("auth_mode") if isinstance(value, dict) else None
            claims = jwt_claims(access)
            audience = claims.get("aud")
            audiences = audience if isinstance(audience, list) else [audience]
            if isinstance(access, str) and mode in (None, "chatgpt", "chatgptAuthTokens") and \
                    claims.get("client_id") == CLIENT_ID and AUDIENCE in audiences and _positive_int(claims.get("exp")):
                found = {"token": access, "exp": int(claims["exp"]), "account": account_of(tokens)}
        with self._lock:
            self._cache = (stamp, found)
        return found

    def _usable(self, record: Optional[Dict[str, Any]]) -> bool:
        return record is not None and record["exp"] > self._clock() + BORROWED_LEEWAY_SECONDS

    def connected(self) -> bool:
        return self._usable(self._read())

    def status(self) -> Dict[str, Any]:
        record = self._read()
        value: Dict[str, Any] = {"connected": self._usable(record), "source": "codex"}
        if record is not None:
            for key in ("plan", "email"):
                if isinstance(record["account"].get(key), str):
                    value[key] = record["account"][key]
        return value

    def access_token(self, *, force_refresh: bool = False) -> str:
        """The borrowed token. ``force_refresh`` (OpenAI just refused it) never refreshes: it reads the file again, so
        a token Codex renewed meanwhile is used; the same token again lets the caller's second refusal pause the
        realtime brain as it does for the Mac's own login."""
        if force_refresh:
            with self._lock:
                self._cache = None
        record = self._read()
        if not self._usable(record):
            raise ChatGPTError(409, "chatgpt_not_connected", "The Codex login on this Mac has expired; open Codex "
                               "or connect ChatGPT in SamRabbit.")
        return str(record["token"])  # type: ignore[index]

    def safety_id(self) -> str:
        record = self._read() or {}
        account = record.get("account") if isinstance(record.get("account"), dict) else {}
        return str(account.get("accountId") or "codex")

    def expires_in(self) -> Optional[float]:
        record = self._read()
        return float(record["exp"]) - self._clock() if record else None


class PreferredAuth:
    """The Mac's own login when it is connected, else Codex's login (borrowed). Logins, disconnects and the
    ``on_change`` hook are the Mac's own; only the token and the status come from whichever is in use."""

    def __init__(self, own: ChatGPTAuth, borrowed: CodexLoginAuth) -> None:
        self.own = own
        self.borrowed = borrowed
        self.off: Optional[str] = None
        self._issuer: Any = None  # the login that handed out the last token: a refusal goes back to it

    @property
    def path(self) -> str:
        return self.own.path

    @property
    def verification_url(self) -> str:
        return self.own.verification_url

    @property
    def on_change(self) -> Optional[Callable[[], None]]:
        return self.own.on_change

    @on_change.setter
    def on_change(self, value: Optional[Callable[[], None]]) -> None:
        self.own.on_change = value

    def _active(self) -> Any:
        return self.borrowed if not self.own.connected() and self.borrowed.connected() else self.own

    def connected(self) -> bool:
        return self.own.connected() or self.borrowed.connected()

    def status(self) -> Dict[str, Any]:
        value = self.own.status()
        if not value.get("connected") and self.borrowed.connected():
            borrowed = self.borrowed.status()
            value = {"connected": True, "source": "codex", "login": value.get("login") or {"state": "idle"},
                     **{key: borrowed[key] for key in ("plan", "email") if key in borrowed}}
        elif value.get("connected"):
            value["source"] = "samrabbit"
        return value

    def start(self) -> Dict[str, Any]:
        return self.own.start()

    def disconnect(self) -> Dict[str, Any]:
        """Only the Mac's own login (Codex's is Codex's): nothing happens, and no session is retired, without one."""
        if os.path.exists(self.own.path):
            self.own.disconnect()
        return {"connected": self.connected(), **({"source": "codex"} if self.connected() else {})}

    def access_token(self, *, force_refresh: bool = False) -> str:
        issuer = self._issuer if force_refresh and self._issuer is not None and self._issuer.connected() \
            else self._active()
        token = issuer.access_token(force_refresh=force_refresh)
        self._issuer = issuer
        return token

    def safety_id(self) -> str:
        return self._active().safety_id()

    def expires_in(self) -> Optional[float]:
        return self._active().expires_in()

    def refresh_if_needed(self) -> None:
        self.own.refresh_if_needed()  # never the borrowed login: refreshing it would sign Codex out

    def close(self) -> None:
        self.own.close()


def codex_auth_file() -> str:
    return os.path.join(os.environ.get("CODEX_HOME") or DEFAULT_CODEX_HOME, "auth.json")


def make_auth(*, installed: bool, auth_file: Optional[str] = None, issuer: Optional[str] = None,
              codex_file: Optional[str] = None) -> Any:
    """The installed copy: ``DEFAULT_AUTH_FILE``, else Codex's login (unless ``SAMRABBIT_CODEX_LOGIN=0``). Any other
    copy: only an explicit ``auth_file`` (and Codex's login only from an explicit ``codex_file``)."""
    if auth_file:
        own = ChatGPTAuth(auth_file, issuer=issuer or ISSUER)
        return PreferredAuth(own, CodexLoginAuth(codex_file)) if codex_file else own
    if installed:
        own = ChatGPTAuth(DEFAULT_AUTH_FILE, issuer=issuer or ISSUER)
        if os.environ.get("SAMRABBIT_CODEX_LOGIN", "1").strip().lower() in OFF_VALUES:
            return own
        return PreferredAuth(own, CodexLoginAuth(codex_file or codex_auth_file()))
    return UnavailableAuth()


def safety_identifier(source: str) -> str:
    return hashlib.sha256(f"sam-mac:{source}".encode("utf-8")).hexdigest()


# --------------------------------------------------------------------------- command line (connect-chatgpt.sh)


def _local(port: int, token: str, method: str, path: str) -> Tuple[int, Dict[str, Any]]:
    import urllib.error  # noqa: PLC0415
    import urllib.request  # noqa: PLC0415

    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))  # loopback: never a system proxy
    request = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=b"{}" if method == "POST" else None,
                                     method=method, headers={"X-SamRabbit-Desktop": token,
                                                             "Content-Type": "application/json"})
    try:
        with opener.open(request, timeout=40) as response:
            return response.status, json.loads(response.read().decode("utf-8") or "{}")
    except urllib.error.HTTPError as error:
        try:
            value = json.loads(error.read().decode("utf-8") or "{}")
        except (OSError, ValueError, UnicodeDecodeError):
            value = {}
        return error.code, value if isinstance(value, dict) else {}


def main(argv: Optional[list] = None) -> int:
    parser = argparse.ArgumentParser(description="Connect SamRabbit's Mac bridge to your ChatGPT subscription.")
    parser.add_argument("command", nargs="?", default="connect", choices=("connect", "status", "disconnect"))
    parser.add_argument("--port", type=int, default=int(os.environ.get("SAMRABBIT_BRIDGE_PORT", "3780")))
    parser.add_argument("--desktop-token-file", default=os.environ.get("SAMRABBIT_DESKTOP_TOKEN_FILE") or
                        "~/.config/samrabbit/desktop-token")
    parser.add_argument("--open", action="store_true", help="open the login page in the browser")
    parser.add_argument("--wait", type=float, default=AUTH_LIFETIME_SECONDS, help=argparse.SUPPRESS)
    options = parser.parse_args(argv)
    try:
        with open(os.path.expanduser(options.desktop_token_file), "r", encoding="utf-8") as handle:
            token = handle.read().strip()
    except OSError:
        print("No desktop token; run companion/mac-bridge/install.sh first.", file=sys.stderr)
        return 2
    try:
        if options.command == "status":
            status, value = _local(options.port, token, "GET", STATUS_ROUTE)
        elif options.command == "disconnect":
            status, value = _local(options.port, token, "POST", DISCONNECT_ROUTE)
        else:
            status, value = _local(options.port, token, "POST", START_ROUTE)
    except OSError:
        print(f"The bridge is not answering on port {options.port}.", file=sys.stderr)
        return 1
    if status != 200:
        error = value.get("error") if isinstance(value.get("error"), dict) else {}
        if status == 404:
            print("This bridge is too old to connect ChatGPT; run companion/mac-bridge/install.sh.", file=sys.stderr)
        else:
            print(f"The bridge refused (HTTP {status}{', ' + str(error.get('code')) if error.get('code') else ''}).",
                  file=sys.stderr)
        return 1
    if options.command in ("status", "disconnect"):
        connected = bool(value.get("connected"))
        plan = f" ({value['plan']})" if value.get("plan") else ""
        via = " via the Codex login on this Mac" if value.get("source") == "codex" else ""
        print(f"ChatGPT: {'connected' + plan + via if connected else 'not connected'}")
        return 0
    code, url = str(value.get("userCode") or ""), str(value.get("verificationUrl") or "")
    print("Connect SamRabbit to ChatGPT")
    print(f"  1. Open {url}")
    print(f"  2. Sign in and enter the code:  {code}")
    print("Waiting for you to approve it (up to 15 minutes; Ctrl-C to stop waiting)…", flush=True)
    if options.open and url.startswith("https://"):
        subprocess.run(["/usr/bin/open", url], check=False, stdin=subprocess.DEVNULL, capture_output=True)
    deadline = time.monotonic() + max(1.0, options.wait)
    try:
        while time.monotonic() < deadline:
            time.sleep(2.0)
            try:
                status, value = _local(options.port, token, "GET", STATUS_ROUTE)
            except OSError:
                continue
            login = value.get("login") if isinstance(value.get("login"), dict) else {}
            if value.get("connected") and login.get("state") in ("done", "idle"):
                plan = f" ({value['plan']} plan)" if value.get("plan") else ""
                print(f"ChatGPT connected{plan}. The watch assistant now talks with gpt-realtime.")
                return 0
            if login.get("state") in ("expired", "failed", "cancelled"):
                print(f"The login {login['state']}{' (' + str(login['reason']) + ')' if login.get('reason') else ''}"
                      "; run connect-chatgpt.sh again.", file=sys.stderr)
                return 1
    except KeyboardInterrupt:
        print("\nStopped waiting; the bridge keeps waiting for the code until it expires.", file=sys.stderr)
        return 130
    print("The code expired; run connect-chatgpt.sh again.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
