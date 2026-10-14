"""SamRabbit mobile API on the Mac bridge (``/v1/mobile/*``): the iPhone app, its widgets and the Apple Watch.

One hub, one token per device. Phones pair with an 8-character code the desktop app (or ``pair-phone.sh``) shows,
then call every route with ``Authorization: Bearer <mobile token>``. The bridge keeps only SHA-256 hashes of the
tokens, in ``~/.config/samrabbit/mobile-devices.json`` (0600): ``{deviceId, name, platform, createdAt, lastSeenAt,
tokenHash[, parentId]}``. Peers must be loopback, private-LAN or Tailscale (100.64.0.0/10) addresses.

Routes (CONTRACTS-WAVE4 "Mobile API"):

* Pairing: ``POST /v1/mobile/pairing/start`` and ``GET|DELETE /v1/mobile/devices[/<id>]`` (desktop app only:
  loopback peer + desktop token, like the desktop sync API), ``POST /v1/mobile/pair {code, deviceName, platform}``,
  ``POST /v1/mobile/devices/child {name, platform: "watchos"}`` (a phone mints its watch's own token) and
  ``POST /v1/mobile/unpair`` (a device forgets itself).
* ``GET /v1/mobile/summary``: the dashboard for widgets and complications, assembled from caches that a background
  worker keeps warm while a device is active (T3 every ~10 s, calendar every 120 s), including
  ``transcribe: {available, reason?}`` (can the phone and the watch send recordings to the Mac?), ``captures:
  {recent, failed, pending, notes}`` (voice notes, ``samrabbit_capture``) and ``briefing: {available, date, status,
  revision, headline, needsYou}`` (the morning brief, ``samrabbit_briefing``).
* R1 conversations, reusing ``samrabbit_sync``'s desktop handlers: ``GET /v1/mobile/conversations``,
  ``/conversations/<id>[/events]``, ``/stream`` (SSE), ``/blobs/<sha256>``; generated UIs:
  ``GET /v1/mobile/ui/artifacts/<id>[/image|/document]`` and ``POST /v1/mobile/ui/generate {prompt, data?}``
  (recorded into the day's "Phone" conversation, so the desktop app shows it too).
* T3 (``samrabbit_t3``): ``GET /v1/mobile/t3/threads?filter=``, ``GET /v1/mobile/t3/threads/<id>``,
  ``POST .../message|respond|stop``, ``POST /v1/mobile/t3/threads {text, projectId?}``, ``GET /v1/mobile/t3/projects``.
* Calendar (Composio, ``samrabbit_calendar``): ``GET /v1/mobile/calendar/agenda?hours=24`` (or ``?days=``: whole days),
  ``POST /v1/mobile/calendar/block {minutes, title?}``, ``POST /v1/mobile/calendar/events {title, startsAt, endsAt}``.
* ``POST /v1/mobile/journal {text}``: ``**HH:MM** <text>`` appended to today's Heptabase journal (explicit notes only;
  codes, passwords and API keys in the words are redacted first, as on the R1).
* Mac: ``GET /v1/mobile/mac/state``, ``POST /v1/mobile/mac/open {app|url}``, ``GET /v1/mobile/mac/screenshot`` (JPEG).
* ``POST /v1/mobile/transcribe[?lang=en-US]``: a raw recording (``audio/mp4``, ``audio/x-m4a``, ``audio/wav`` or
  ``audio/aac``; at most 2 MiB and 90 s) turned into words on the Mac (``samrabbit_transcribe``, on-device macOS
  speech recognition) -> ``{text, durationMs, engine, locale}``. The audio and the words are never logged or kept.
* The voice assistant (``samrabbit_assistant``): ``POST /v1/mobile/assistant/turn`` (one utterance: audio or JSON
  text -> what to say; streamed with ``Accept: application/x-samrabbit-stream``), ``POST
  /v1/mobile/assistant/session`` (warm-up), ``POST /v1/mobile/assistant/cancel`` (stop the reply),
  ``GET /v1/mobile/assistant/announcements``, ``POST /v1/mobile/assistant/end``; the summary's ``assistant:
  {available, brain, reason?, model, chatgpt: {connected}}``. Its tools come back here with the bridge's internal
  assistant token (loopback only, and only the routes in ``INTERNAL_ROUTES``). The Mac's ChatGPT login for its
  realtime voice (desktop app only: loopback peer + desktop token): ``POST /v1/assistant/chatgpt/start``,
  ``GET /v1/assistant/chatgpt/status``, ``POST /v1/assistant/chatgpt/disconnect``.
* The desktop app's voice (the Agent Dock): ``/v1/desktop/assistant/turn|session|cancel|end|announcements``, the same
  handlers as the watch's, for the desktop token from this Mac only, as the one device ``mac``
  (``samrabbit_assistant.MAC_DEVICE``: "Mac" conversations, the Mac's instructions). The dock's list itself is
  ``samrabbit_inbox`` (``/v1/desktop/inbox*``), which checks the desktop token with ``desktop_denied`` here; its
  phone twin ``/v1/mobile/inbox*`` checks the mobile token with ``device_denied``.
* The SamRabbit window on the Mac (CONTRACTS-WAVE7), the same handlers for the desktop token from this Mac only:
  ``GET /v1/desktop/summary`` (the phone's summary, plus ``r1.online`` and the paired ``devices``),
  ``GET /v1/desktop/calendar/agenda?days=`` (today from its midnight and the days after it),
  ``POST /v1/desktop/calendar/block {minutes, title?}``, ``POST /v1/desktop/journal {text}`` (an explicit note, as
  from the phone), ``GET /v1/desktop/devices`` and ``DELETE /v1/desktop/devices/<id>``. Whatever talks to the bridge
  with the R1's token from the network (the journal, Mac control, conversation sync) tells this module the R1 was there
  (``r1_heard``).

Errors are ``{"error": {"code", "message", "retryable"}}``. Times in the routes this module answers itself are ISO
8601 (``...Z`` or with the calendar's offset); the reused sync routes keep their epoch milliseconds. Tokens, codes,
thread text, prompts, notes, events and images are never logged. Stdlib only, Python 3.9.
"""

from __future__ import annotations

import argparse
import base64
from datetime import date as Date, datetime, timedelta, timezone, tzinfo
import hashlib
import hmac
import ipaddress
import json
import logging
import os
import re
import secrets
import socket
import subprocess
import sys
import tempfile
import threading
import time
from typing import Any, Callable, Dict, List, Optional, Tuple
from urllib.parse import parse_qs, parse_qsl, quote, unquote, urlsplit, urlunsplit
import uuid

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.append(_HERE)

try:  # the conversation store; mobile works without it (conversations then answer 503)
    import samrabbit_sync as _sync  # type: ignore
except Exception:  # noqa: BLE001
    _sync = None  # type: ignore[assignment]

try:  # generated UIs (only its document policy is needed here)
    import samrabbit_genui as _genui  # type: ignore
except Exception:  # noqa: BLE001
    _genui = None  # type: ignore[assignment]

try:  # speech to text for the watch and the phone; mobile works without it (transcribe then answers 503)
    import samrabbit_transcribe as _transcribe  # type: ignore
except Exception:  # noqa: BLE001
    _transcribe = None  # type: ignore[assignment]

try:  # the voice assistant (its routes answer 503 without it)
    import samrabbit_assistant as _assistant  # type: ignore
except Exception:  # noqa: BLE001
    _assistant = None  # type: ignore[assignment]

import samrabbit_t3 as t3  # noqa: E402

_LOG = logging.getLogger("samrabbit-bridge.mobile")

PREFIX = "/v1/mobile/"
ASSISTANT_PREFIX = "/v1/assistant/"
DESKTOP_ASSISTANT_PREFIX = "/v1/desktop/assistant/"  # the desktop app's voice: the same handlers, the "mac" device
# The SamRabbit window's twins of the phone's routes (the inbox's /v1/desktop/inbox* is samrabbit_inbox's).
DESKTOP_TWINS = ("/v1/desktop/summary", "/v1/desktop/calendar/", "/v1/desktop/journal", "/v1/desktop/devices")
DEFAULT_DEVICES_FILE = "~/.config/samrabbit/mobile-devices.json"
DEFAULT_TIMEZONE = "America/New_York"
CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"  # no I, O, 0 or 1
CODE_LENGTH = 8
CODE_TTL_SECONDS = 10 * 60
BAD_CODE_LIMIT = 10
BAD_CODE_WINDOW_SECONDS = 10 * 60
MAX_DEVICES = 24
MAX_CHILDREN = 3
TOUCH_EVERY_SECONDS = 60.0
MAX_BODY_BYTES = 64 * 1024
MAX_NOTE_CHARS = 4000
MAX_TITLE_CHARS = 300
MIN_BLOCK_MINUTES = 5
MAX_BLOCK_MINUTES = 12 * 60
DEFAULT_BLOCK_TITLE = "Focus"
MAX_AGENDA_HOURS = 7 * 24
MAX_AGENDA_DAYS = 7
MAX_AGENDA_EVENTS = 250  # a week of a busy calendar (a day's agenda asks for 50)
SUMMARY_CACHE_SECONDS = 2.0
T3_REFRESH_SECONDS = 10.0
CALENDAR_REFRESH_SECONDS = 120.0
JOURNAL_REFRESH_SECONDS = 300.0  # the probe reads today's journal; a phone note also tells
SCREEN_REFRESH_SECONDS = 15.0
TRANSCRIBE_REFRESH_SECONDS = 60.0  # the transcriber caches its own check for 10 minutes; this only reads it
R1_ONLINE_SECONDS = 15 * 60  # the R1 sends no heartbeat: "online" is "talked to this bridge this recently"
FAILED_REFRESH_SECONDS = 20.0
DEMAND_WINDOW_SECONDS = 10 * 60
COLD_WAIT_SECONDS = 1.5
HOSTS_CACHE_SECONDS = 30.0
MAX_MOBILE_STREAMS = 4  # live streams for all phones and watches together (of the sync store's 8; the rest stay
MAX_DEVICE_STREAMS = 2  # free for the desktop app); per device, a newer stream replaces the oldest
PENDING_ON_DEMAND = 4  # a thread list reads at most this many uncached open requests before answering ...
PENDING_BUDGET_SECONDS = 2.5  # ... within about this long
DEFAULT_SCREENSHOT_SIDE = 1600
PHONE_TITLE = "Phone"
PUBLIC, DESKTOP, DEVICE = "public", "desktop", "device"
_CGNAT = ipaddress.ip_network("100.64.0.0/10")
_PRIVATE_V4 = tuple(ipaddress.ip_network(net) for net in
                    ("127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16",
                     "100.64.0.0/10"))
_PRIVATE_V6 = tuple(ipaddress.ip_network(net) for net in ("::1/128", "fc00::/7", "fe80::/10"))
_DEVICE_ID = re.compile(r"^dev_[0-9a-f]{16}$")
_CLIENT_REQUEST_ID = re.compile(r"^[A-Za-z0-9._:\-]{1,96}$")
_JOURNAL_DOWN = frozenset({"heptabase_app_unavailable", "heptabase_cli_missing"})
_CONTROL = re.compile(r"[\x00-\x1f\x7f]")


# --------------------------------------------------------------------------- errors and small helpers


class MobileError(Exception):
    def __init__(self, status: int, code: str, message: str, *, retryable: bool = False) -> None:
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message
        self.retryable = retryable

    def payload(self) -> Dict[str, Any]:
        return {"error": {"code": self.code, "message": self.message, "retryable": self.retryable}}


def _bad(code: str, message: str) -> MobileError:
    return MobileError(400, code, message)


def iso_utc(epoch: float) -> str:
    return datetime.fromtimestamp(epoch, timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _ms_iso(value: Any) -> Optional[str]:
    return iso_utc(value / 1000.0) if isinstance(value, (int, float)) and not isinstance(value, bool) and value > 0 \
        else None


def mobile_peer_allowed(address: str) -> bool:
    """Loopback, private-LAN or Tailscale (100.64.0.0/10, fd7a:115c:a1e0::/48 is inside fc00::/7) peers only."""
    try:
        ip = ipaddress.ip_address(str(address).split("%", 1)[0])
    except ValueError:
        return False
    if ip.version == 6 and ip.ipv4_mapped is not None:
        ip = ip.ipv4_mapped
    return any(ip in network for network in (_PRIVATE_V4 if ip.version == 4 else _PRIVATE_V6))


def _loopback(address: str) -> bool:
    try:
        ip = ipaddress.ip_address(str(address).split("%", 1)[0])
    except ValueError:
        return False
    if ip.version == 6 and ip.ipv4_mapped is not None:
        ip = ip.ipv4_mapped
    return ip.is_loopback


def load_zone(name: Optional[str]) -> tzinfo:
    try:
        from zoneinfo import ZoneInfo

        return ZoneInfo(name or DEFAULT_TIMEZONE)
    except Exception:  # noqa: BLE001 - unknown name or no tz database: the Mac's own zone
        return datetime.now().astimezone().tzinfo or timezone.utc


def _clean_name(value: Any, default: str, limit: int = 60) -> str:
    text = " ".join(_CONTROL.sub(" ", value).split()) if isinstance(value, str) else ""
    return text[:limit] or default


# --------------------------------------------------------------------------- this Mac's addresses


def interface_addresses(ifconfig: str = "/sbin/ifconfig") -> List[Tuple[str, str]]:
    """``(interface, IPv4)`` pairs from ``ifconfig`` (read-only)."""
    try:
        done = subprocess.run([ifconfig], stdin=subprocess.DEVNULL, capture_output=True, timeout=3.0, check=False)
    except (OSError, subprocess.SubprocessError):
        return []
    pairs: List[Tuple[str, str]] = []
    current = ""
    for line in done.stdout.decode("utf-8", errors="replace").splitlines():
        head = re.match(r"^([A-Za-z0-9]+):", line)
        if head:
            current = head.group(1)
            continue
        found = re.match(r"^\s+inet (\d+\.\d+\.\d+\.\d+)\b", line)
        if found and current:
            pairs.append((current, found.group(1)))
    return pairs


def pick_hosts(pairs: List[Tuple[str, str]]) -> List[str]:
    """The LAN IPv4 address (en0/en1 first; never loopback, link-local, VM bridges or AirDrop links), then the
    Tailscale address when one exists."""
    lan: List[Tuple[int, str]] = []
    tailnet: List[str] = []
    for name, value in pairs:
        try:
            ip = ipaddress.ip_address(value)
        except ValueError:
            continue
        if ip in _CGNAT:
            tailnet.append(value)
            continue
        if ip.is_loopback or ip.is_link_local or not ip.is_private:
            continue
        if name.startswith(("bridge", "vmnet", "utun", "awdl", "llw", "lo", "anpi", "ap")):
            continue
        rank = {"en0": 0, "en1": 1}.get(name, 2)
        lan.append((rank, value))
    hosts = [value for _rank, value in sorted(lan)][:1]
    return hosts + tailnet[:1]


# --------------------------------------------------------------------------- devices


def token_hash(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


class DeviceRegistry:
    """Paired phones and watches. Only SHA-256 hashes of their tokens are kept (0600 file, atomic writes, re-read
    when the file changes)."""

    def __init__(self, path: str = DEFAULT_DEVICES_FILE, *, clock: Callable[[], float] = time.time) -> None:
        self.path = os.path.expanduser(path)
        self._clock = clock
        self._lock = threading.RLock()
        self._stamp: Optional[Tuple[int, int, int]] = None
        self._devices: List[Dict[str, Any]] = []
        self._touched: Dict[str, float] = {}

    def _load(self) -> List[Dict[str, Any]]:
        try:
            info = os.stat(self.path)
        except OSError:
            self._stamp, self._devices = None, []
            return self._devices
        stamp = (info.st_mtime_ns, info.st_size, info.st_ino)
        if stamp == self._stamp:
            return self._devices
        devices: List[Dict[str, Any]] = []
        try:
            if info.st_mode & 0o077:
                os.chmod(self.path, 0o600)
            with open(self.path, "r", encoding="utf-8") as handle:
                value = json.load(handle)
            for item in value.get("devices") if isinstance(value, dict) else []:
                if isinstance(item, dict) and isinstance(item.get("deviceId"), str) and \
                        isinstance(item.get("tokenHash"), str) and re.match(r"^[0-9a-f]{64}$", item["tokenHash"]):
                    devices.append(item)
        except (OSError, ValueError, AttributeError):
            _LOG.warning("mobile devices file unreadable; no devices until it is fixed")
            devices = []
        self._stamp, self._devices = stamp, devices
        return devices

    def _save(self, devices: List[Dict[str, Any]]) -> None:
        folder = os.path.dirname(self.path) or "."
        os.makedirs(folder, mode=0o700, exist_ok=True)
        handle, temp = tempfile.mkstemp(prefix=".mobile-devices.", dir=folder)
        try:
            os.fchmod(handle, 0o600)
            with os.fdopen(handle, "w", encoding="utf-8") as file:
                json.dump({"version": 1, "devices": devices}, file, indent=1)
            os.replace(temp, self.path)
        except BaseException:
            try:
                os.unlink(temp)
            except OSError:
                pass
            raise
        self._stamp = None
        self._load()

    @staticmethod
    def view(record: Dict[str, Any]) -> Dict[str, Any]:
        value = {key: record.get(key) for key in ("deviceId", "name", "platform", "createdAt", "lastSeenAt")}
        if record.get("parentId"):
            value["parentId"] = record["parentId"]
        return value

    def count(self) -> int:
        with self._lock:
            return len(self._load())

    def list(self) -> List[Dict[str, Any]]:
        with self._lock:
            return [self.view(item) for item in self._load()]

    def create(self, name: str, platform: str, parent_id: Optional[str] = None) -> Tuple[str, Dict[str, Any]]:
        token = "srm_" + secrets.token_urlsafe(32)
        now = iso_utc(self._clock())
        record = {"deviceId": "dev_" + secrets.token_hex(8), "name": name, "platform": platform, "createdAt": now,
                  "lastSeenAt": now, "tokenHash": token_hash(token)}
        if parent_id:
            record["parentId"] = parent_id
        with self._lock:
            devices = [dict(item) for item in self._load()]
            if parent_id:
                children = [item for item in devices if item.get("parentId") == parent_id]
                same = [item for item in children if item.get("name") == name]
                # A phone that provisions its watch again replaces that watch's old token.
                drop = {item["deviceId"] for item in same} | \
                    {item["deviceId"] for item in children[:max(0, len(children) - MAX_CHILDREN + 1)]
                     if not same}
                devices = [item for item in devices if item["deviceId"] not in drop]
            if len(devices) >= MAX_DEVICES:
                raise MobileError(409, "too_many_devices", "Too many devices are paired. Revoke one on the Mac first.")
            devices.append(record)
            self._save(devices)
        return token, self.view(record)

    def authenticate(self, presented: str) -> Optional[Dict[str, Any]]:
        if not presented or len(presented) > 200:
            return None
        digest = token_hash(presented)
        with self._lock:
            found = None
            for item in self._load():
                if hmac.compare_digest(str(item.get("tokenHash")), digest):
                    found = item
            if found is None:
                return None
            self._touch(found)
            return dict(found)

    def _touch(self, record: Dict[str, Any]) -> None:
        now = self._clock()
        device_id = record["deviceId"]
        if now - self._touched.get(device_id, 0.0) < TOUCH_EVERY_SECONDS:
            return
        self._touched[device_id] = now
        devices = [dict(item) for item in self._load()]
        for item in devices:
            if item["deviceId"] == device_id:
                item["lastSeenAt"] = iso_utc(now)
        try:
            self._save(devices)
        except OSError:
            _LOG.warning("mobile devices file not updated")

    def revoke(self, device_id: str) -> List[str]:
        """Removes the device and the devices it provisioned (its watch). Returns the ids that went."""
        with self._lock:
            devices = self._load()
            gone = {device_id} | {item["deviceId"] for item in devices if item.get("parentId") == device_id}
            kept = [dict(item) for item in devices if item["deviceId"] not in gone]
            removed = [item["deviceId"] for item in devices if item["deviceId"] in gone]
            if removed:
                self._save(kept)
            return removed


# --------------------------------------------------------------------------- pairing codes


class PairingCodes:
    """One pairing code at a time (a new start replaces the old one): 8 characters, single use, 10 minutes.
    More than ``BAD_CODE_LIMIT`` wrong codes in ``BAD_CODE_WINDOW_SECONDS`` lock pairing until the window passes."""

    def __init__(self, *, clock: Callable[[], float] = time.time,
                 monotonic: Callable[[], float] = time.monotonic) -> None:
        self._clock = clock
        self._monotonic = monotonic
        self._lock = threading.Lock()
        self._code: Optional[Tuple[str, float]] = None  # (code, expires epoch)
        self._failures: List[float] = []

    def start(self) -> Tuple[str, float]:
        code = "".join(secrets.choice(CODE_ALPHABET) for _ in range(CODE_LENGTH))
        expires = self._clock() + CODE_TTL_SECONDS
        with self._lock:
            self._code = (code, expires)
        return code, expires

    def limited(self) -> bool:
        with self._lock:
            now = self._monotonic()
            self._failures = [at for at in self._failures if now - at < BAD_CODE_WINDOW_SECONDS]
            return len(self._failures) >= BAD_CODE_LIMIT

    def redeem(self, presented: Any) -> bool:
        text = "".join(char for char in str(presented or "")[:64] if char.isascii() and char.isalnum()).upper()
        with self._lock:
            current = self._code
            ok = current is not None and len(text) == CODE_LENGTH and current[1] > self._clock() and \
                hmac.compare_digest(text, current[0])
            if ok:
                self._code = None  # single use
            else:
                self._failures.append(self._monotonic())
            return ok


# --------------------------------------------------------------------------- Google links (port of google_account.py)

GOOGLE_HOSTS = frozenset({"calendar.google.com", "mail.google.com", "drive.google.com", "docs.google.com",
                          "meet.google.com"})
_HOME_PATHS = {"calendar.google.com": "/calendar/r", "mail.google.com": "/mail/", "drive.google.com": "/drive/"}
_EMAIL = re.compile(r"^[A-Za-z0-9._%+'-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}$")
_ACCOUNT_INDEX = re.compile(r"/u/\d+(?=/|$)")
_ACCOUNT_NUMBER = re.compile(r"^\d{0,3}$")


def normalize_email(value: Any) -> Optional[str]:
    if not isinstance(value, str):
        return None
    text = value.strip().strip("<>").strip()
    if text.lower().startswith("mailto:"):
        text = text[7:]
    return text.lower() if len(text) <= 254 and _EMAIL.match(text) else None


def is_google_link(url: str) -> bool:
    try:
        parts = urlsplit(url.strip())
    except ValueError:
        return False
    return parts.scheme.lower() in ("http", "https") and (parts.hostname or "").lower() in GOOGLE_HOSTS


def with_google_account(url: str, email: Optional[str]) -> str:
    """``url`` with ``authuser=<email>`` for Google Calendar, Gmail, Drive, Docs and Meet links that don't name an
    account by email yet (an account index such as ``authuser=1`` or ``/u/1`` is replaced)."""
    account = normalize_email(email)
    if account is None:
        return url
    try:
        parts = urlsplit(url.strip())
    except ValueError:
        return url
    host = (parts.hostname or "").lower()
    if parts.scheme.lower() not in ("http", "https") or host not in GOOGLE_HOSTS:
        return url
    kept: List[str] = []
    for item in parts.query.split("&") if parts.query else []:
        pairs = parse_qsl(item, keep_blank_values=True)
        key, value = pairs[0] if pairs else ("", "")
        if key.strip().lower() != "authuser":
            kept.append(item)
        elif not _ACCOUNT_NUMBER.match(value.strip()):
            return url
    path = _ACCOUNT_INDEX.sub("", parts.path) or ""
    if path in ("", "/") and host in _HOME_PATHS:
        path = _HOME_PATHS[host]
    kept.append("authuser=" + quote(account, safe="@"))
    return urlunsplit((parts.scheme, parts.netloc, path, "&".join(kept), parts.fragment))


# --------------------------------------------------------------------------- journal notes (port of format.py)

_INLINE = re.compile(r"([\\`*_~\[\]<>|$])")
_ENTITY = re.compile(r"&(?=#?[A-Za-z0-9]+;)")
# Value-pattern secret scrub, as the R1 applies to explicit notes (heptabase_journal/format.py, redact_secrets on).
_SECRET_PATTERNS = (
    re.compile(r"\b(?:sk|rk|pk)_(?:live|test)_[A-Za-z0-9]{6,}"),
    re.compile(r"\bsk-(?:proj-|ant-)?[A-Za-z0-9_\-]{20,}"),
    re.compile(r"\bgh[pousr]_[A-Za-z0-9]{20,}"),
    re.compile(r"\bgithub_pat_[A-Za-z0-9_]{20,}"),
    re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
    re.compile(r"\bAIza[0-9A-Za-z_\-]{35}"),
    re.compile(r"\bxox[abposr]-[A-Za-z0-9\-]{10,}"),
    re.compile(r"\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}"),
    re.compile(r"(?i)\bbearer\s+[A-Za-z0-9._~+/\-]{16,}=*"),
    re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z ]*PRIVATE KEY-----|$)"),
)
_CODE_AFTER = re.compile(
    r"(?i)\b((?:verification|security|login|one[- ]time|2fa|auth|access|confirmation)?\s*"
    r"(?:code|pin|passcode|otp)\s*(?:is|was|=|:)?\s*)(\d(?:[\s-]?\d){3,7})\b"
)
_PASSWORD_AFTER = re.compile(r"(?i)\b(password\s*(?:is|was|=|:)\s*)([^\s,;!?]+)")
REDACTED = "[redacted]"


def scrub_secrets(text: str) -> str:
    """API keys, tokens, private keys, "the code is 123456" and "password is …" replaced by ``[redacted]``."""
    value = text
    for pattern in _SECRET_PATTERNS:
        value = pattern.sub(REDACTED, value)
    value = _CODE_AFTER.sub(lambda match: match.group(1) + REDACTED, value)
    value = _PASSWORD_AFTER.sub(lambda match: match.group(1) + REDACTED, value)
    return value


def escape_verbatim(text: str) -> str:
    """The user's words as one line, Markdown and Hepta syntax escaped so they render literally."""
    value = " ".join(str(text).replace("\r", "\n").split())
    value = _INLINE.sub(r"\\\1", value)
    value = _ENTITY.sub(r"\\&", value)
    return value.replace("{{", "{\\{")


def journal_note(words: str, moment: datetime) -> str:
    """``**HH:MM** <words>``: the explicit-note format the R1 uses (no added prose), secrets redacted first."""
    return f"**{moment.strftime('%H:%M')}** {escape_verbatim(scrub_secrets(' '.join(str(words).split())))}"


# --------------------------------------------------------------------------- calendar


def block_window(now: datetime, minutes: int) -> Tuple[datetime, datetime]:
    """"Block N minutes": from now, rounded down to the minute, for N minutes (both in ``now``'s zone; the end is
    computed in UTC so a daylight-saving change in between keeps the real length)."""
    start = now.replace(second=0, microsecond=0)
    end = (start.astimezone(timezone.utc) + timedelta(minutes=minutes)).astimezone(now.tzinfo)
    return start, end


_MEETING_URL = re.compile(r"https://(?:[a-z0-9-]+\.)?(?:zoom\.us|meet\.google\.com|teams\.microsoft\.com|"
                          r"teams\.live\.com|webex\.com|whereby\.com)/[^\s<>\"']+", re.IGNORECASE)


def _event_time(part: Any, zone: tzinfo) -> Tuple[Optional[datetime], bool]:
    if not isinstance(part, dict):
        return None, False
    if isinstance(part.get("dateTime"), str):
        parsed = t3.parse_time(part["dateTime"])
        return (parsed.astimezone(zone) if parsed else None), False
    if isinstance(part.get("date"), str):
        try:
            day = Date.fromisoformat(part["date"][:10])
        except ValueError:
            return None, True
        return datetime(day.year, day.month, day.day, tzinfo=zone), True
    return None, False


def agenda_event(item: Any, zone: tzinfo) -> Optional[Dict[str, Any]]:
    """One Google event as the phone shows it, or None for cancelled, declined and working-location entries."""
    if not isinstance(item, dict) or item.get("status") == "cancelled" or item.get("eventType") == "workingLocation":
        return None
    for attendee in item.get("attendees") or []:
        if isinstance(attendee, dict) and attendee.get("self") and attendee.get("responseStatus") == "declined":
            return None
    start, all_day = _event_time(item.get("start"), zone)
    end, _ = _event_time(item.get("end"), zone)
    if start is None:
        return None
    if end is None or end <= start:
        end = start + (timedelta(days=1) if all_day else timedelta(minutes=30))
    meeting = item.get("hangoutLink") if isinstance(item.get("hangoutLink"), str) else None
    conference = item.get("conferenceData") if isinstance(item.get("conferenceData"), dict) else {}
    points = conference.get("entryPoints") if isinstance(conference.get("entryPoints"), list) else []
    if not meeting:
        for point in points:
            if isinstance(point, dict) and point.get("entryPointType") == "video" and isinstance(point.get("uri"), str):
                meeting = point["uri"]
                break
    location = item.get("location") if isinstance(item.get("location"), str) else None
    if not meeting and location:
        found = _MEETING_URL.search(location)
        meeting = found.group(0) if found else None
    title = item.get("summary") if isinstance(item.get("summary"), str) and item["summary"].strip() else "(No title)"
    return {"eventId": item.get("id") if isinstance(item.get("id"), str) else None, "title": title.strip()[:300],
            "startsAt": start.isoformat(timespec="seconds"), "endsAt": end.isoformat(timespec="seconds"),
            "allDay": all_day, "location": location[:300] if location else None,
            "meetingUrl": meeting[:500] if meeting else None}


def _items(data: Any) -> List[Any]:
    if isinstance(data, dict):
        if isinstance(data.get("items"), list):
            return data["items"]
        nested = data.get("response_data")
        if isinstance(nested, dict) and isinstance(nested.get("items"), list):
            return nested["items"]
    return []


def _person_account(value: Any) -> Optional[str]:
    """The email of a Google event ``creator`` / ``organizer`` that is the signed-in account (``self: true``);
    calendar addresses (``…@group.calendar.google.com``, resources) are not accounts."""
    if not isinstance(value, dict) or value.get("self") is not True:
        return None
    email = normalize_email(value.get("email"))
    return email if email and not email.endswith("calendar.google.com") else None


def account_from_events(data: Any, calendar_id: Optional[str]) -> Optional[str]:
    """The Google account behind a ``GOOGLECALENDAR_EVENTS_LIST`` answer: an event its owner created
    (``creator.self``), else, on the primary calendar, one it organizes (``organizer.self``) or the calendar's own
    name (Google names the primary calendar after the account's email), else the calendar id when it is an email."""
    items = [item for item in _items(data) if isinstance(item, dict)]
    for item in items:
        found = _person_account(item.get("creator"))
        if found:
            return found
    primary = calendar_id in (None, "", "primary")
    if primary:
        for item in items:
            found = _person_account(item.get("organizer"))
            if found:
                return found
        for container in (data, data.get("response_data") if isinstance(data, dict) else None):
            if isinstance(container, dict):
                found = normalize_email(container.get("summary"))
                if found and not found.endswith("calendar.google.com"):
                    return found
    found = normalize_email(calendar_id)
    return found if found and not found.endswith("calendar.google.com") else None


# --------------------------------------------------------------------------- the service


class _Route:
    def __init__(self, pattern: str, label: str, methods: Dict[str, Tuple[str, str]]) -> None:
        self.pattern = re.compile("^" + pattern + "$")
        self.label = label
        self.methods = methods


_TID = r"(?P<tid>[A-Za-z0-9][A-Za-z0-9._:%\-]{0,190})"
ROUTES: Tuple[_Route, ...] = (
    _Route(r"/v1/mobile/pairing/start", "/v1/mobile/pairing/start", {"POST": ("pairing_start", DESKTOP)}),
    _Route(r"/v1/mobile/pair", "/v1/mobile/pair", {"POST": ("pair", PUBLIC)}),
    _Route(r"/v1/mobile/devices", "/v1/mobile/devices", {"GET": ("devices", DESKTOP)}),
    _Route(r"/v1/mobile/devices/child", "/v1/mobile/devices/child", {"POST": ("child", DEVICE)}),
    _Route(r"/v1/mobile/devices/(?P<id>[A-Za-z0-9_]{1,40})", "/v1/mobile/devices/{id}",
           {"DELETE": ("revoke", DESKTOP)}),
    _Route(r"/v1/mobile/unpair", "/v1/mobile/unpair", {"POST": ("unpair", DEVICE)}),
    _Route(r"/v1/mobile/summary", "/v1/mobile/summary", {"GET": ("summary", DEVICE)}),
    _Route(r"/v1/mobile/conversations", "/v1/mobile/conversations", {"GET": ("sync", DEVICE)}),
    _Route(r"/v1/mobile/conversations/(?P<cid>[^/]{1,80})", "/v1/mobile/conversations/{id}", {"GET": ("sync", DEVICE)}),
    _Route(r"/v1/mobile/conversations/(?P<cid>[^/]{1,80})/events", "/v1/mobile/conversations/{id}/events",
           {"GET": ("sync", DEVICE)}),
    _Route(r"/v1/mobile/stream", "/v1/mobile/stream", {"GET": ("sync", DEVICE)}),
    _Route(r"/v1/mobile/blobs/(?P<blob>[^/]{1,80})", "/v1/mobile/blobs/{sha256}", {"GET": ("sync", DEVICE)}),
    _Route(r"/v1/mobile/ui/generate", "/v1/mobile/ui/generate", {"POST": ("ui_generate", DEVICE)}),
    _Route(r"/v1/mobile/ui/artifacts/(?P<aid>ui_[0-9a-f]{24})(?P<part>/image|/document)?",
           "/v1/mobile/ui/artifacts/{id}", {"GET": ("ui_artifact", DEVICE)}),
    _Route(r"/v1/mobile/t3/threads", "/v1/mobile/t3/threads",
           {"GET": ("t3_threads", DEVICE), "POST": ("t3_create", DEVICE)}),
    _Route(r"/v1/mobile/t3/projects", "/v1/mobile/t3/projects", {"GET": ("t3_projects", DEVICE)}),
    _Route(r"/v1/mobile/t3/threads/" + _TID, "/v1/mobile/t3/threads/{id}", {"GET": ("t3_thread", DEVICE)}),
    _Route(r"/v1/mobile/t3/threads/" + _TID + r"/(?P<action>message|respond|stop)",
           "/v1/mobile/t3/threads/{id}/{action}", {"POST": ("t3_action", DEVICE)}),
    _Route(r"/v1/mobile/calendar/agenda", "/v1/mobile/calendar/agenda", {"GET": ("agenda", DEVICE)}),
    _Route(r"/v1/mobile/calendar/block", "/v1/mobile/calendar/block", {"POST": ("block", DEVICE)}),
    _Route(r"/v1/mobile/calendar/events", "/v1/mobile/calendar/events", {"POST": ("event", DEVICE)}),
    _Route(r"/v1/mobile/journal", "/v1/mobile/journal", {"POST": ("journal", DEVICE)}),
    _Route(r"/v1/mobile/mac/state", "/v1/mobile/mac/state", {"GET": ("mac_state", DEVICE)}),
    _Route(r"/v1/mobile/mac/open", "/v1/mobile/mac/open", {"POST": ("mac_open", DEVICE)}),
    _Route(r"/v1/mobile/mac/screenshot", "/v1/mobile/mac/screenshot", {"GET": ("mac_screenshot", DEVICE)}),
    _Route(r"/v1/mobile/transcribe", "/v1/mobile/transcribe", {"POST": ("transcribe", DEVICE)}),
    _Route(r"/v1/mobile/assistant/turn", "/v1/mobile/assistant/turn", {"POST": ("assistant_turn", DEVICE)}),
    _Route(r"/v1/mobile/assistant/announcements", "/v1/mobile/assistant/announcements",
           {"GET": ("assistant_announcements", DEVICE)}),
    _Route(r"/v1/mobile/assistant/end", "/v1/mobile/assistant/end", {"POST": ("assistant_end", DEVICE)}),
    _Route(r"/v1/mobile/assistant/session", "/v1/mobile/assistant/session",
           {"POST": ("assistant_session", DEVICE)}),
    _Route(r"/v1/mobile/assistant/cancel", "/v1/mobile/assistant/cancel", {"POST": ("assistant_cancel", DEVICE)}),
    # The desktop app's voice (CONTRACTS-WAVE6): the mobile assistant's own handlers, for the desktop token from this
    # Mac only, as the one device "mac" (its conversations are the sync store's "Mac" ones).
    _Route(r"/v1/desktop/assistant/turn", "/v1/desktop/assistant/turn", {"POST": ("assistant_turn", DESKTOP)}),
    _Route(r"/v1/desktop/assistant/announcements", "/v1/desktop/assistant/announcements",
           {"GET": ("assistant_announcements", DESKTOP)}),
    _Route(r"/v1/desktop/assistant/end", "/v1/desktop/assistant/end", {"POST": ("assistant_end", DESKTOP)}),
    _Route(r"/v1/desktop/assistant/session", "/v1/desktop/assistant/session",
           {"POST": ("assistant_session", DESKTOP)}),
    _Route(r"/v1/desktop/assistant/cancel", "/v1/desktop/assistant/cancel", {"POST": ("assistant_cancel", DESKTOP)}),
    # The SamRabbit window (CONTRACTS-WAVE7): the phone's own handlers for the desktop token from this Mac only.
    _Route(r"/v1/desktop/summary", "/v1/desktop/summary", {"GET": ("desktop_summary", DESKTOP)}),
    _Route(r"/v1/desktop/calendar/agenda", "/v1/desktop/calendar/agenda", {"GET": ("agenda", DESKTOP)}),
    _Route(r"/v1/desktop/calendar/block", "/v1/desktop/calendar/block", {"POST": ("block", DESKTOP)}),
    _Route(r"/v1/desktop/journal", "/v1/desktop/journal", {"POST": ("journal", DESKTOP)}),
    _Route(r"/v1/desktop/devices", "/v1/desktop/devices", {"GET": ("devices", DESKTOP)}),
    _Route(r"/v1/desktop/devices/(?P<id>[A-Za-z0-9_]{1,40})", "/v1/desktop/devices/{id}",
           {"DELETE": ("revoke", DESKTOP)}),
    _Route(r"/v1/assistant/chatgpt/start", "/v1/assistant/chatgpt/start", {"POST": ("chatgpt_start", DESKTOP)}),
    _Route(r"/v1/assistant/chatgpt/status", "/v1/assistant/chatgpt/status", {"GET": ("chatgpt_status", DESKTOP)}),
    _Route(r"/v1/assistant/chatgpt/disconnect", "/v1/assistant/chatgpt/disconnect",
           {"POST": ("chatgpt_disconnect", DESKTOP)}),
)
# What the assistant's own tools (the internal token, from loopback) may call: reads, and the actions its tools take.
INTERNAL_ROUTES = frozenset({"summary", "sync", "t3_threads", "t3_thread", "t3_action", "t3_create", "t3_projects",
                             "agenda", "block", "event", "journal", "mac_state", "mac_open", "mac_screenshot",
                             "ui_generate", "ui_artifact"})
# Desktop routes that keep the summary's caches warm while the SamRabbit window reads them (a device's every request
# does).
WARMING_ROUTES = frozenset({"desktop_summary", "agenda"})


class _Bytes:
    """A non-JSON answer (JPEG, HTML)."""

    def __init__(self, body: bytes, content_type: str, headers: Optional[Dict[str, str]] = None) -> None:
        self.body = body
        self.content_type = content_type
        self.headers = dict(headers or {})


class _Written:
    """The route wrote its own response (SSE, the reused sync handlers); ``status`` is for the log line."""

    def __init__(self, status: int) -> None:
        self.status = status


class MobileService:
    """``handles(route)`` / ``serve(handler, method, route)`` for the bridge; ``attach(server)`` gives it the
    bridge's sync store, generated UIs, Mac control, calendar writer and journal append."""

    def __init__(self, *, devices_file: str = DEFAULT_DEVICES_FILE, t3_hub: Any = None,
                 desktop_token_file: Optional[str] = None,
                 timezone_name: Optional[str] = None, google_account: Optional[str] = None,
                 hosts: Optional[List[str]] = None, bridge_version: str = "",
                 transcriber: Any = None, transcribe_helper: Optional[str] = None, assistant: Any = None,
                 clock: Callable[[], float] = time.time, monotonic: Callable[[], float] = time.monotonic) -> None:
        self.devices = DeviceRegistry(devices_file, clock=clock)
        self.assistant = assistant  # samrabbit_assistant.AssistantService (or None: its routes answer 503)
        # Speech to text (POST /v1/mobile/transcribe): the Swift helper install.sh builds next to the bridge.
        self.transcriber = transcriber if transcriber is not None else (
            _transcribe.Transcriber(transcribe_helper) if _transcribe is not None else None)
        # The desktop app's token, for pairing and the device list when the sync store is off (with it on, the
        # sync service's own token file is used, which the bridge configures the same way).
        self._desktop_token = _sync.DesktopToken(desktop_token_file or _sync.DEFAULT_DESKTOP_TOKEN_FILE) \
            if _sync is not None else None
        self.codes = PairingCodes(clock=clock, monotonic=monotonic)
        self.t3 = t3_hub if t3_hub is not None else t3.UnavailableHub(
            "t3_dev_copy", "This copy of the Mac bridge is not the installed one, so it does not talk to T3 Code.")
        self.zone_name = timezone_name or os.environ.get("SAMRABBIT_TIMEZONE") or DEFAULT_TIMEZONE
        self.zone = load_zone(self.zone_name)
        self._google_account = normalize_email(google_account or os.environ.get("SAMRABBIT_GOOGLE_ACCOUNT"))
        self._learned_account: Optional[str] = None  # from the agenda (EVENTS_LIST) answers
        self._fixed_hosts = hosts
        self.bridge_version = bridge_version
        self._clock = clock
        self._monotonic = monotonic
        self.server: Any = None
        self._lock = threading.RLock()
        self._changed = threading.Condition(self._lock)
        self._cache: Dict[str, Tuple[float, Any]] = {}
        self._loading: Dict[str, bool] = {}
        self._summary: Optional[Tuple[float, Dict[str, Any]]] = None
        self._agenda: Dict[Any, Tuple[float, Dict[str, Any]]] = {}  # hours, or ("days", days, today's date)
        self._hosts: Optional[Tuple[float, List[str]]] = None
        self._streams: Dict[str, List[Any]] = {}  # device id -> handlers of its open live streams (oldest first)
        self._r1_heard: Optional[float] = None  # when the R1 last talked to the bridge (this run only)
        self._demand_at = -1e12
        self._worker: Optional[threading.Thread] = None
        self._wake = threading.Event()
        self._stopping = threading.Event()

    # ------------------------------------------------------------------ lifecycle
    def attach(self, server: Any) -> None:
        self.server = server
        if self.assistant is not None:
            self.assistant.attach(server, self)

    def start(self) -> None:
        """The background refresher (summary caches). Pre-warms when devices are already paired. Also removes the
        recording folders a bridge that stopped mid-transcription left behind."""
        if self._worker is not None:
            return
        starter = getattr(self.transcriber, "start", None)
        if callable(starter):
            starter()
        if self.devices.count():
            self._demand_at = self._monotonic()
        self._worker = threading.Thread(target=self._work, name="samrabbit-mobile", daemon=True)
        self._worker.start()
        self._wake.set()
        if self.assistant is not None:
            self.assistant.start()

    def close(self) -> None:
        self._stopping.set()
        self._wake.set()
        if self._worker is not None:
            self._worker.join(timeout=3.0)
            self._worker = None
        if self.transcriber is not None:
            self.transcriber.close()
        if self.assistant is not None:
            self.assistant.close()

    @staticmethod
    def handles(route: str) -> bool:
        return route.startswith(PREFIX) or route.startswith(ASSISTANT_PREFIX) or \
            route.startswith(DESKTOP_ASSISTANT_PREFIX) or route.startswith(DESKTOP_TWINS)

    @staticmethod
    def route_label(route: str) -> str:
        for spec in ROUTES:
            match = spec.pattern.match(route)
            if match:
                action = match.groupdict().get("action")
                return spec.label.replace("{action}", action) if action else spec.label
        if route.startswith(DESKTOP_ASSISTANT_PREFIX):
            return "/v1/desktop/assistant/(other)"
        return "/v1/desktop/(other)" if route.startswith(DESKTOP_TWINS) else "/v1/mobile/(other)"

    def health(self) -> Dict[str, Any]:
        status = self.t3.status() if self.t3 is not None else {"paired": False, "ok": False}
        return {"available": True, "devices": self.devices.count(),
                "t3": {"paired": bool(status.get("paired")), "ok": bool(status.get("ok")),
                       **({"reason": status["lastError"]} if status.get("lastError") else {})},
                "transcribe": self.transcribe_status()}

    def transcribe_status(self) -> Dict[str, Any]:
        """``{available, engine?, locale?, reason?}``: whether the Mac can turn a recording into words."""
        if self.transcriber is None:
            return {"available": False, "reason": "helper_missing"}
        try:
            return dict(self.transcriber.status())
        except Exception:  # noqa: BLE001 - transcription must never break the health check
            _LOG.warning("transcription status failed")
            return {"available": False, "reason": "check_failed"}

    # ------------------------------------------------------------------ HTTP
    def serve(self, handler: Any, method: str, route: str) -> Tuple[int, Optional[str]]:
        try:
            if not mobile_peer_allowed(str(handler.client_address[0])):
                raise MobileError(403, "forbidden", "Only devices on your local network or tailnet may use this.")
            found = None
            for spec in ROUTES:
                match = spec.pattern.match(route)
                if match:
                    found = (spec, match.groupdict())
                    break
            if found is None:
                self._authorize(handler, DESKTOP if route.startswith("/v1/desktop/") else DEVICE)
                raise MobileError(404, "not_found", "Not found.")
            spec, params = found
            entry = spec.methods.get(method)
            if entry is None:
                kinds = {auth for _name, auth in spec.methods.values()}
                self._authorize(handler, DEVICE if DEVICE in kinds else next(iter(kinds)))
                raise MobileError(405, "method_not_allowed", "Use " + "/".join(sorted(spec.methods)) + ".")
            name, auth = entry
            device = self._authorize(handler, auth)
            if device is not None and device.get("internal") and (
                    name not in INTERNAL_ROUTES or (name == "sync" and route != PREFIX + "conversations")):
                raise MobileError(403, "forbidden", "The assistant's tools cannot use this route.")
            if auth == DESKTOP and name in WARMING_ROUTES:
                self._wanted()  # the SamRabbit window reads the summary: keep its caches warm, as for a phone
            result = getattr(self, "_r_" + name)(handler, params, device, route)
            if isinstance(result, _Written):
                return result.status, None
            if getattr(result, "streamed", False):  # a streamed assistant turn wrote its own response
                return int(getattr(result, "status", 200)), None
            status, payload = result
        except Exception as error:  # noqa: BLE001 - every module's error answers with its own envelope
            status, payload = _error_answer(error)
        _send(handler, status, payload)
        code = payload.get("error", {}).get("code") if isinstance(payload, dict) and \
            isinstance(payload.get("error"), dict) else None
        return status, code

    def desktop_denied(self, handler: Any) -> Optional[Exception]:
        """The desktop app's rule (loopback peer, loopback Host/Origin, the desktop token), as the desktop sync API
        and the ChatGPT login routes apply it: None when allowed, else the error to answer. The desktop inbox
        (``samrabbit_inbox``) uses it too."""
        service = getattr(self.server, "sync", None)
        if service is not None:
            return service.desktop_denied(handler)
        if _sync is not None and self._desktop_token is not None:
            return _sync._desktop_denied(handler, self._desktop_token)  # noqa: SLF001 - the same rule
        return MobileError(503, "desktop_unavailable", "The desktop token check is not installed.")

    def device_denied(self, handler: Any) -> Optional[Exception]:
        """The phone's rule (a LAN or tailnet peer with a paired device's own token; never the assistant's internal
        token), as every ``/v1/mobile/*`` route here applies it: None when allowed, else the error to answer. The
        inbox's phone routes (``samrabbit_inbox``, ``/v1/mobile/inbox*``) use it."""
        if not mobile_peer_allowed(str(handler.client_address[0])):
            return MobileError(403, "forbidden", "Only devices on your local network or tailnet may use this.")
        try:
            device = self._device(handler)
        except MobileError as error:
            return error
        if device.get("internal"):
            return MobileError(403, "forbidden", "The assistant's tools cannot use this route.")
        return None

    def caller(self, handler: Any, surface: str) -> Dict[str, Any]:
        """Who calls a route another module serves under three prefixes (voice notes, the morning brief):
        ``mobile`` (``/v1/mobile/…``: a paired phone or watch, ``device_denied``), ``desktop`` (``/v1/desktop/…``: the
        Mac app, ``desktop_denied``) or ``r1`` (``/v1/…``: the bridge token from a private-LAN peer). Returns
        ``{surface, source: iphone | watch | mac | r1, device}``; raises the error to answer otherwise."""
        if surface == "r1":
            check = getattr(self.server, "bridge_token_denied", None)
            denied = check(handler) if callable(check) else MobileError(503, "unavailable", "Not set up on the bridge.")
            if denied is not None:
                raise denied
            return {"surface": surface, "source": "r1", "device": "r1"}
        if surface == "desktop":
            denied = self.desktop_denied(handler)
            if denied is not None:
                raise denied
            return {"surface": surface, "source": "mac", "device": "mac"}
        denied = self.device_denied(handler)
        if denied is not None:
            raise denied
        scheme, _, value = str(handler.headers.get("Authorization", "")).partition(" ")
        device = self.devices.authenticate(value.strip()) if scheme.lower() == "bearer" else None
        return {"surface": surface, "source": "watch" if (device or {}).get("platform") == "watchos" else "iphone",
                "device": (device or {}).get("deviceId") or "phone"}

    def _authorize(self, handler: Any, auth: str) -> Optional[Dict[str, Any]]:
        if auth == PUBLIC:
            return None
        if auth == DESKTOP:
            denied = self.desktop_denied(handler)
            if denied is not None:
                raise denied
            return None
        return self._device(handler)

    def _device(self, handler: Any) -> Dict[str, Any]:
        header = handler.headers.get("Authorization", "")
        scheme, _, value = header.partition(" ")
        device = None
        if scheme.lower() == "bearer" and self.assistant is not None:
            # The assistant's tools (samrabbit_assistant_mcp.py): the internal token, from loopback only.
            device = self.assistant.internal_device(value.strip(), str(handler.client_address[0]))
        if device is None and scheme.lower() == "bearer":
            device = self.devices.authenticate(value.strip())
        if device is None:
            raise MobileError(401, "unauthorized", "Pair this device with the Mac again.")
        self._wanted()
        return device

    def _wanted(self) -> None:
        """Someone reads the summary's parts: the worker keeps them fresh for the next ``DEMAND_WINDOW_SECONDS``."""
        self._demand_at = self._monotonic()
        self._wake.set()

    # ------------------------------------------------------------------ pairing
    def bridge_name(self) -> str:
        name = None
        control = getattr(self.server, "mac", None)
        if control is not None:
            try:
                name = control.computer()
            except Exception:  # noqa: BLE001
                name = None
        return _clean_name(name or socket.gethostname().split(".")[0], "Mac", 80)

    def hosts(self) -> List[str]:
        port = int(self.server.server_address[1]) if self.server is not None else 3780
        if self._fixed_hosts is not None:
            base = list(self._fixed_hosts)
        else:
            env = os.environ.get("SAMRABBIT_MOBILE_HOSTS")
            if env:
                base = [item.strip() for item in env.split(",") if item.strip()]
            else:
                cached = self._hosts
                if cached is None or self._monotonic() - cached[0] > HOSTS_CACHE_SECONDS:
                    cached = (self._monotonic(), pick_hosts(interface_addresses()))
                    self._hosts = cached
                base = cached[1]
        return [item if re.search(r":\d+$", item) and item.count(":") == 1 else f"{item}:{port}"
                for item in base] or [f"127.0.0.1:{port}"]

    def _r_pairing_start(self, handler: Any, _params: Dict[str, str], _device: Any, _route: str) -> Tuple[int, Any]:
        _optional_body(handler)
        code, expires = self.codes.start()
        hosts = self.hosts()
        name = self.bridge_name()
        url = "samrabbit://pair?h=" + ",".join(quote(host, safe=":[]") for host in hosts) + "&c=" + code + \
            "&n=" + quote(name, safe="")
        _LOG.info("mobile pairing code issued")
        return 200, {"code": code, "expiresAt": iso_utc(expires), "pairUrl": url, "hosts": hosts,
                     "bridgeName": name, "devices": self.devices.list()}

    def _r_pair(self, handler: Any, _params: Dict[str, str], _device: Any, _route: str) -> Tuple[int, Any]:
        if self.codes.limited():
            raise MobileError(429, "pairing_rate_limited", "Too many wrong codes. Wait a few minutes, then make a "
                              "new code on the Mac.", retryable=True)
        body = _json_body(handler)
        platform = body.get("platform")
        if platform not in ("ios", "watchos"):
            raise _bad("invalid_platform", "platform must be ios or watchos.")
        if not self.codes.redeem(body.get("code")):
            _LOG.info("mobile pairing refused (wrong or expired code)")
            raise MobileError(401, "invalid_code", "That code is wrong or expired. Make a new one on the Mac.")
        name = _clean_name(body.get("deviceName"), "iPhone" if platform == "ios" else "Apple Watch")
        token, record = self.devices.create(name, str(platform))
        _LOG.info("mobile device paired (%s)", platform)
        return 200, {"token": token, "deviceId": record["deviceId"], "bridgeName": self.bridge_name(),
                     "bridgeVersion": self.bridge_version}

    def _r_devices(self, _handler: Any, _params: Dict[str, str], _device: Any, _route: str) -> Tuple[int, Any]:
        return 200, {"devices": self.devices.list()}

    def _r_revoke(self, handler: Any, params: Dict[str, str], _device: Any, _route: str) -> Tuple[int, Any]:
        device_id = params["id"]
        if not _DEVICE_ID.match(device_id):
            raise MobileError(404, "device_not_found", "No such device.")
        removed = self.devices.revoke(device_id)
        if not removed:
            raise MobileError(404, "device_not_found", "No such device.")
        self._close_streams(removed)
        _LOG.info("mobile device revoked (%d)", len(removed))
        return 200, {"ok": True, "revoked": len(removed)}

    def _r_child(self, handler: Any, _params: Dict[str, str], device: Dict[str, Any], _route: str) -> Tuple[int, Any]:
        if device.get("parentId") or device.get("platform") != "ios":
            raise MobileError(403, "forbidden", "Only a paired iPhone can add its watch.")
        body = _json_body(handler)
        if body.get("platform", "watchos") != "watchos":
            raise _bad("invalid_platform", "platform must be watchos.")
        name = _clean_name(body.get("name"), "Apple Watch")
        token, record = self.devices.create(name, "watchos", parent_id=device["deviceId"])
        _LOG.info("mobile watch token issued")
        return 200, {"token": token, "deviceId": record["deviceId"], "bridgeName": self.bridge_name(),
                     "bridgeVersion": self.bridge_version}

    def _r_unpair(self, handler: Any, _params: Dict[str, str], device: Dict[str, Any], _route: str) -> Tuple[int, Any]:
        _optional_body(handler)
        removed = self.devices.revoke(device["deviceId"])
        self._close_streams(removed)
        return 200, {"ok": True, "revoked": len(removed)}

    # ------------------------------------------------------------------ caches and the worker
    def _work(self) -> None:
        while not self._stopping.is_set():
            self._wake.wait(timeout=1.0)
            self._wake.clear()
            if self._stopping.is_set():
                break
            if self._monotonic() - self._demand_at > DEMAND_WINDOW_SECONDS:
                continue
            for name in self._components():
                if self._due(name) and not self._loading.get(name):
                    # One thread per part: a slow Composio call never holds up the T3 snapshot.
                    threading.Thread(target=self._refresh, args=(name,), name="samrabbit-mobile-" + name,
                                     daemon=True).start()

    def _components(self) -> Dict[str, Tuple[float, Callable[[], Any]]]:
        return {"screen": (SCREEN_REFRESH_SECONDS, self._load_screen), "t3": (T3_REFRESH_SECONDS, self._load_t3),
                "journal": (JOURNAL_REFRESH_SECONDS, self._load_journal),
                "calendar": (CALENDAR_REFRESH_SECONDS, self._load_calendar),
                "transcribe": (TRANSCRIBE_REFRESH_SECONDS, self.transcribe_status)}

    def _due(self, name: str) -> bool:
        ttl = self._components()[name][0]
        with self._lock:
            entry = self._cache.get(name)
        if entry is None:
            return True
        failed = isinstance(entry[1], dict) and entry[1].get("_failed")
        return self._monotonic() - entry[0] >= (min(ttl, FAILED_REFRESH_SECONDS) if failed else ttl)

    def _refresh(self, name: str) -> Any:
        with self._lock:
            if self._loading.get(name):
                return self._cache.get(name, (0.0, None))[1]
            self._loading[name] = True
        try:
            loader = self._components()[name][1]
            try:
                value = loader()
            except Exception:  # noqa: BLE001 - a summary part never fails the summary
                _LOG.warning("mobile %s refresh failed", name)
                value = {"_failed": True}
            with self._lock:
                self._cache[name] = (self._monotonic(), value)
                self._summary = None
                self._changed.notify_all()
            return value
        finally:
            with self._lock:
                self._loading[name] = False

    def _parts(self, names: Tuple[str, ...]) -> Dict[str, Any]:
        """Cached summary parts. Stale or missing parts are refreshed by the worker (kicked; missing ones are
        awaited together for at most ``COLD_WAIT_SECONDS``) or, without a worker (tests, one-off use), right here."""
        worker = self._worker is not None and self._worker.is_alive()
        missing = []
        for name in names:
            with self._lock:
                entry = self._cache.get(name)
            if entry is not None and not self._due(name):
                continue
            if not worker:
                self._refresh(name)
            elif entry is None:
                missing.append(name)
        if worker:
            self._wake.set()
            if missing:
                deadline = self._monotonic() + COLD_WAIT_SECONDS
                with self._changed:
                    while any(name not in self._cache for name in missing) and self._monotonic() < deadline:
                        self._changed.wait(timeout=0.1)
        with self._lock:
            return {name: (self._cache[name][1] if name in self._cache else {"_loading": True}) for name in names}

    def _load_t3(self) -> Dict[str, Any]:
        if not self.t3.available():
            return {"_failed": True, "reason": getattr(self.t3, "code", "t3_unavailable")}
        try:
            self.t3.snapshot(max_age=0.0)
        except t3.T3Error as error:
            return {"_failed": True, "reason": error.code}
        try:
            self.t3.refresh_pending()
        except t3.T3Error:
            pass
        return {"ok": True}

    def _load_calendar(self) -> Dict[str, Any]:
        return self.agenda(24, fresh=True)

    def _load_journal(self) -> Dict[str, Any]:
        """Is the Heptabase journal reachable? One read of today through the bridge's own ``read`` (its read
        slots: never more than two Heptabase CLI reads at once), every ``JOURNAL_REFRESH_SECONDS`` while a device
        is active; a note added from the phone refreshes it too."""
        server = self.server
        if server is None:
            return {"available": False, "reason": "journal_unavailable"}
        if getattr(server, "dry_run", False):
            return {"available": True, "dryRun": True}
        cli = getattr(server, "cli", None)
        if cli is None or cli.executable() is None:
            return {"available": False, "reason": "heptabase_cli_missing"}
        try:
            server.read(self._now().date().isoformat())
        except Exception as error:  # noqa: BLE001 - BridgeError: the app is closed, the CLI is off or busy
            return {"available": False, "reason": str(getattr(error, "code", "") or "heptabase_unavailable")}
        return {"available": True}

    def _load_screen(self) -> Dict[str, Any]:
        control = getattr(self.server, "mac", None)
        try:
            return {"locked": control.screen_locked() if control is not None else None}
        except Exception:  # noqa: BLE001
            return {"locked": None}

    def _now(self) -> datetime:
        return datetime.fromtimestamp(self._clock(), self.zone)

    # ------------------------------------------------------------------ summary
    def summary(self) -> Dict[str, Any]:
        with self._lock:
            cached = self._summary
        if cached is not None and self._monotonic() - cached[0] < SUMMARY_CACHE_SECONDS:
            return cached[1]
        parts = self._parts(("screen", "t3", "journal", "calendar", "transcribe"))
        t3_state, calendar, journal, screen = (parts[name] or {} for name in ("t3", "calendar", "journal", "screen"))
        if calendar.get("_loading"):
            calendar = {"available": False, "reason": "loading"}
        if journal.get("_loading"):
            journal = {"available": False, "reason": "loading"}
        t3_part = self.t3.summary_part(self.t3.cached())
        if t3_state.get("_failed") and t3_state.get("reason"):
            t3_part["reason"] = t3_state["reason"]
            if t3_part.get("available"):
                t3_part["stale"] = True
        elif t3_state.get("_loading") and not t3_part.get("available"):
            t3_part.setdefault("reason", "loading")
        now = self._clock()
        upcoming = []
        if calendar.get("available"):
            events = [item for item in calendar.get("events") or []
                      if (t3.parse_time(item.get("endsAt")) or datetime.min.replace(tzinfo=timezone.utc)).timestamp()
                      > now]
            timed = [item for item in events if not item.get("allDay")]
            upcoming = (timed + [item for item in events if item.get("allDay")])[:3]
        value = {
            "generatedAt": iso_utc(now),
            "mac": {"name": self.bridge_name(), "online": True, "screenLocked": screen.get("locked")},
            "r1": {"lastSeenAt": None, "live": False, "liveConversationId": None, "liveTitle": None},
            "t3": t3_part,
            "calendar": {"available": bool(calendar.get("available")),
                         "next": [{key: item.get(key) for key in ("title", "startsAt", "endsAt", "allDay", "location",
                                                                  "meetingUrl")} for item in upcoming],
                         **({"reason": calendar["reason"]} if calendar.get("reason") else {})},
            "latestConversation": None,
            "journal": {"available": bool(journal.get("available")),
                        **({"dryRun": True} if journal.get("dryRun") else {}),
                        **({"reason": journal["reason"]} if journal.get("reason") and not journal.get("available")
                           else {})},
            "transcribe": self._transcribe_part(parts["transcribe"]),
            "assistant": self._assistant_part(),
            "captures": self._service_part("capture"),
            "briefing": self._service_part("briefing"),
        }
        value["r1"], value["latestConversation"] = self._r1_part()
        with self._lock:
            self._summary = (self._monotonic(), value)
        return value

    def _transcribe_part(self, loaded: Any) -> Dict[str, Any]:
        """``{available, reason?}``: can the phone and the watch send recordings to ``/v1/mobile/transcribe``? What
        the transcriber knows right now (a transcription that just worked or failed) wins over the cached part."""
        value: Any = None
        try:
            if self.transcriber is not None and callable(getattr(self.transcriber, "cached_status", None)):
                value = self.transcriber.cached_status()
        except Exception:  # noqa: BLE001 - never fails the summary
            value = None
        if value is None:
            value = loaded if isinstance(loaded, dict) else {}
            if value.get("_loading"):
                value = {"available": False, "reason": "loading"}
            elif value.get("_failed"):
                value = {"available": False, "reason": "check_failed"}
        available = value.get("available") is True
        reason = value.get("reason")
        return {"available": available,
                **({"reason": reason} if not available and isinstance(reason, str) and reason else {})}

    def _service_part(self, name: str) -> Dict[str, Any]:
        """``captures`` / ``briefing``: what the voice notes and the morning brief services say (cheap: their own
        stored state, never a build or a network call)."""
        service = getattr(self.server, name, None)
        if service is None or not hasattr(service, "summary_part"):
            return {"available": False}
        try:
            return dict(service.summary_part())
        except Exception:  # noqa: BLE001 - never fails the summary
            _LOG.warning("mobile summary: %s part failed", name)
            return {"available": False, "reason": "check_failed"}

    def summary_changed(self) -> None:
        """Something the summary shows changed (a voice note finished, the brief was rebuilt): the next one is new."""
        with self._lock:
            self._summary = None

    def _assistant_part(self) -> Dict[str, Any]:
        """``{available, brain, reason?, model, chatgpt: {connected}}``: can the watch talk to the assistant?"""
        if self.assistant is None:
            return {"available": False, "reason": "assistant_missing"}
        try:
            return self.assistant.summary_part()
        except Exception:  # noqa: BLE001 - never fails the summary
            _LOG.warning("assistant status failed")
            return {"available": False, "reason": "check_failed"}

    def _r1_part(self) -> Tuple[Dict[str, Any], Optional[Dict[str, Any]]]:
        """``lastSeenAt``: the later of the R1's last conversation activity and its last request to the bridge."""
        r1: Dict[str, Any] = {"lastSeenAt": None, "live": False, "liveConversationId": None, "liveTitle": None}
        heard = self._r1_heard
        if heard is not None:
            r1["lastSeenAt"] = iso_utc(heard)
        service = getattr(self.server, "sync", None)
        if service is None:
            return r1, None
        try:
            conversations = service.store.conversations(limit=30, before=None, query="")
        except Exception:  # noqa: BLE001
            _LOG.warning("mobile summary: conversations unavailable")
            return r1, None
        mine = [item for item in conversations if (item.get("device") or "r1") != "mac"]
        if mine:
            latest = max(int(item.get("lastAt") or 0) for item in mine)
            if heard is None or latest / 1000.0 > heard:
                r1["lastSeenAt"] = _ms_iso(latest) or r1["lastSeenAt"]
        live = next((item for item in mine if item.get("live")), None)
        if live is not None:
            r1.update({"live": True, "liveConversationId": live["conversationId"],
                       "liveTitle": live.get("title") or "Live conversation"})
        latest = mine[0] if mine else None
        return r1, ({"conversationId": latest["conversationId"], "title": latest.get("title") or "Conversation",
                     "lastAt": _ms_iso(latest.get("lastAt")), "preview": latest.get("preview"),
                     "live": bool(latest.get("live"))} if latest else None)

    def _r_summary(self, _handler: Any, _params: Dict[str, str], _device: Any, _route: str) -> Tuple[int, Any]:
        return 200, self.summary()

    def desktop_summary(self) -> Dict[str, Any]:
        """The phone's summary for the SamRabbit window on the Mac, plus what the Mac's Home and Settings show:
        ``r1.online`` (it talked to this bridge in the last ``R1_ONLINE_SECONDS``, or a conversation on it is live; the
        R1 reports no battery) and the paired phones and watches (``devices``, as ``GET /v1/desktop/devices``)."""
        value = dict(self.summary())  # the cached summary is shared: never changed in place
        r1 = dict(value.get("r1") or {})
        heard = self._r1_heard
        r1["online"] = bool(r1.get("live")) or (heard is not None and self._clock() - heard < R1_ONLINE_SECONDS)
        value["r1"] = r1
        value["devices"] = self.devices.list()
        return value

    def r1_heard(self, address: str) -> None:
        """The bridge took a request with the R1's own token (the journal, Mac control, conversation sync, ``/health``)
        from ``address``. Only a peer on the network counts: on this Mac's loopback that token is install.sh's check."""
        if mobile_peer_allowed(address) and not _loopback(address):
            self._r1_heard = self._clock()

    def _r_desktop_summary(self, _handler: Any, _params: Dict[str, str], _device: Any, _route: str) -> Tuple[int, Any]:
        return 200, self.desktop_summary()

    # ------------------------------------------------------------------ conversations (samrabbit_sync handlers)
    def _r_sync(self, handler: Any, _params: Dict[str, str], device: Dict[str, Any], route: str) -> Any:
        service = getattr(self.server, "sync", None)
        if service is None:
            raise MobileError(503, "sync_unavailable", "Conversation sync is off on the Mac.", retryable=True)
        mapped = "/v1/sync/" + route[len(PREFIX):]
        stream = route == PREFIX + "stream"
        if stream:
            self._open_stream(device["deviceId"], handler)
        try:
            status = service._desktop(handler, mapped)  # noqa: SLF001 - the desktop API's handlers, authorized here
        except Exception as error:  # noqa: BLE001 - SyncError and friends answer with their own envelope
            return _error_answer(error)
        finally:
            if stream:
                self._stream_ended(device["deviceId"], handler)
        return _Written(int(status or 200))

    # ------------------------------------------------------------------ live streams
    def _open_stream(self, device_id: str, handler: Any) -> None:
        """Phones and watches share ``MAX_MOBILE_STREAMS`` of the sync store's streams, so the desktop app always
        has slots left. A device opening one more than ``MAX_DEVICE_STREAMS`` (a reconnect after a network
        change) closes its own oldest stream instead of being refused."""
        with self._lock:
            mine = self._streams.setdefault(device_id, [])
            total = sum(len(items) for items in self._streams.values())
            stale = []
            if len(mine) >= MAX_DEVICE_STREAMS or (total >= MAX_MOBILE_STREAMS and mine):
                stale.append(mine.pop(0))
            elif total >= MAX_MOBILE_STREAMS:
                if not mine:
                    self._streams.pop(device_id, None)
                raise MobileError(503, "too_many_streams", "Too many live streams from phones and watches are "
                                  "open.", retryable=True)
            mine.append(handler)
        for old in stale:
            _shut(old)

    def _stream_ended(self, device_id: str, handler: Any) -> None:
        with self._lock:
            items = self._streams.get(device_id)
            if items is not None:
                if handler in items:
                    items.remove(handler)
                if not items:
                    self._streams.pop(device_id, None)

    def _close_streams(self, device_ids: List[str]) -> None:
        """A revoked device's open live streams end now, not when it disconnects."""
        with self._lock:
            handlers = [handler for device_id in device_ids for handler in self._streams.pop(device_id, [])]
        for handler in handlers:
            _shut(handler)

    # ------------------------------------------------------------------ generated UIs
    def _phone_conversation(self, prompt: str, event_id: str) -> Optional[str]:
        """Today's "Phone" conversation in the sync store, with the request as its user line (``event_id`` makes a
        retried request record it once)."""
        service = getattr(self.server, "sync", None)
        if service is None:
            return None
        conversation = "phone-" + self._now().strftime("%Y%m%d")
        try:
            service.store.record_local(conversation, {"id": event_id, "type": "message.user", "text": prompt,
                                                      "origin": "phone"})
            store = service.store
            # The store titles a conversation after its first user line and calls it live until it ends: this one
            # is "Phone" and never live (it is not an R1 voice session).
            with store._lock:  # noqa: SLF001
                store._db.execute(  # noqa: SLF001
                    "UPDATE conversations SET title = ?, live = 0, ended_at = COALESCE(ended_at, started_at) "
                    "WHERE conversation_id = ?", (PHONE_TITLE, conversation))
        except Exception:  # noqa: BLE001 - the timeline is a mirror: generation goes on without it
            _LOG.warning("mobile: phone conversation not recorded")
        return conversation

    def _r_ui_generate(self, handler: Any, _params: Dict[str, str], _device: Any, _route: str) -> Tuple[int, Any]:
        """Everything the generator would refuse is checked first, so a refused request leaves no user line in the
        "Phone" conversation. ``requestId`` (optional, from the phone) makes a retry after a timeout return the
        same visual instead of making a second one."""
        body = _json_body(handler)
        prompt = body.get("prompt")
        limit = int(getattr(_genui, "MAX_PROMPT_CHARS", 4000))
        if not isinstance(prompt, str) or not prompt.strip() or len(prompt) > limit or "\x00" in prompt:
            raise _bad("invalid_prompt", f"prompt must be 1 to {limit} characters.")
        prompt = prompt.strip()
        client_id = body.get("requestId")
        if client_id is not None and (not isinstance(client_id, str) or not _CLIENT_REQUEST_ID.match(client_id)):
            raise _bad("invalid_request_id", "requestId must be 1 to 96 letters, digits or . _ : -")
        data = body.get("data")
        if data is not None and not isinstance(data, str):
            data = json.dumps(data, ensure_ascii=False)
        data_limit = int(getattr(_genui, "MAX_DATA_CHARS", 24000))
        if isinstance(data, str) and (len(data) > data_limit or "\x00" in data):
            raise _bad("invalid_data", f"data must be at most {data_limit} characters.")
        genui = getattr(self.server, "genui", None)
        if genui is None:
            raise MobileError(503, "genui_unavailable", "Generated UIs are off on the Mac.")
        internal = bool(_device and _device.get("internal"))
        request_id = ("watch:" if internal else "phone:") + (client_id or uuid.uuid4().hex)
        existing = None
        if _genui is not None and hasattr(_genui, "artifact_id_for"):
            existing = genui.store.meta(_genui.artifact_id_for(request_id))
        if existing is not None:
            conversation = existing.get("conversationId") if isinstance(existing.get("conversationId"), str) else None
        else:
            queued = int((genui.capabilities() or {}).get("queued") or 0)
            if queued >= int(getattr(_genui, "MAX_QUEUE", 8)):
                raise MobileError(503, "genui_busy", "The Mac is already making several visuals. Try again in a "
                                  "minute.", retryable=True)
            # From the watch (the assistant's tool): its own conversation, which already has the spoken request.
            conversation = self.assistant.sync_conversation(handler) if internal and self.assistant is not None \
                else self._phone_conversation(prompt, request_id + ":prompt")
        request: Dict[str, Any] = {"requestId": request_id, "prompt": prompt, "size": "r1"}
        if data is not None:
            request["data"] = data
        if conversation:
            request["conversationId"] = conversation
        status, value = genui.submit(request)
        result = {"artifactId": value.get("artifactId"), "status": value.get("status")}
        if conversation:
            result["conversationId"] = conversation
        return status, result

    def _r_ui_artifact(self, _handler: Any, params: Dict[str, str], _device: Any, _route: str) -> Tuple[int, Any]:
        genui = getattr(self.server, "genui", None)
        if genui is None:
            raise MobileError(503, "genui_unavailable", "Generated UIs are off on the Mac.")
        artifact_id, part = params["aid"], params.get("part")
        meta = genui.artifact(artifact_id)
        if not part:
            return 200, genui.view(meta)
        if part == "/image":
            data = genui.store.read_bytes(artifact_id, "preview.jpg") if meta.get("status") == "ready" else None
            if data is None:
                raise MobileError(409, "image_not_ready", "The picture is not ready yet.",
                                  retryable=meta.get("status") == "generating")
            return 200, _Bytes(data, "image/jpeg")
        document = genui.store.read_bytes(artifact_id, "document.html")
        if document is None:
            raise MobileError(409, "document_not_ready", "The visual is not ready yet.",
                              retryable=meta.get("status") == "generating")
        policy = getattr(_genui, "CSP_POLICY", "default-src 'none'")
        return 200, _Bytes(document, "text/html; charset=utf-8",
                           {"Content-Security-Policy": policy + " sandbox allow-scripts;",
                            "Referrer-Policy": "no-referrer"})

    # ------------------------------------------------------------------ T3
    def _r_t3_threads(self, handler: Any, _params: Dict[str, str], _device: Any, _route: str) -> Tuple[int, Any]:
        query = _query(handler)
        filter_name = _one(query, "filter")
        limit = _int(query, "limit", 40, 1, 100)
        threads = self.t3.threads(filter_name, limit=limit)
        missing = [item["threadId"] for item in threads if item["status"] in t3.MOBILE_NEEDS_YOU and
                   "pending" not in item]
        if missing:
            # A thread that just started needing you has no cached request yet: read it now (bounded), so the
            # Approve / Reply cards show the command or the question on the first load.
            try:
                fetched = self.t3.refresh_pending(PENDING_ON_DEMAND, only=missing, budget=PENDING_BUDGET_SECONDS)
            except t3.T3Error:
                fetched = 0
            if fetched:
                threads = self.t3.threads(filter_name, limit=limit, max_age=60.0)
        with self._lock:
            self._summary = None
        return 200, {"threads": threads, "updatedAt": iso_utc(self._clock())}

    def _r_t3_thread(self, _handler: Any, params: Dict[str, str], _device: Any, _route: str) -> Tuple[int, Any]:
        return 200, self.t3.thread_view(unquote(params["tid"]))

    def _r_t3_action(self, handler: Any, params: Dict[str, str], _device: Any, _route: str) -> Tuple[int, Any]:
        thread_id = unquote(params["tid"])
        action = params["action"]
        if action == "stop":
            _optional_body(handler)
            value = self.t3.stop(thread_id)
        elif action == "message":
            value = self.t3.send_message(thread_id, _json_body(handler).get("text"))
        else:
            value = self.t3.respond(thread_id, _json_body(handler))
        self._t3_changed()
        return 200, value

    def _r_t3_create(self, handler: Any, _params: Dict[str, str], _device: Any, _route: str) -> Tuple[int, Any]:
        body = _json_body(handler)
        project_id = body.get("projectId")
        if project_id is not None and not isinstance(project_id, str):
            raise _bad("invalid_project", "projectId must be a project id.")
        title = body.get("title") if isinstance(body.get("title"), str) else None
        value = self.t3.create(body.get("text"), project_id=project_id or None, title=title)
        self._t3_changed()
        return 200, value

    def _t3_changed(self) -> None:
        """After a command from the phone, the next summary reads T3 again instead of waiting out the cache."""
        with self._lock:
            self._cache.pop("t3", None)
            self._summary = None

    def _r_t3_projects(self, _handler: Any, _params: Dict[str, str], _device: Any, _route: str) -> Tuple[int, Any]:
        return 200, self.t3.projects()

    # ------------------------------------------------------------------ calendar
    def _writer(self) -> Any:
        writer = getattr(self.server, "calendar", None)
        if writer is None or not hasattr(writer, "create"):
            code = getattr(writer, "code", None) or "calendar_unavailable"
            message = getattr(writer, "message", None) or "Google Calendar is not set up on the Mac bridge."
            raise MobileError(503, code, message)
        return writer

    def agenda(self, hours: int = 24, *, days: Optional[int] = None, fresh: bool = False) -> Dict[str, Any]:
        """The next ``hours`` of the configured Google calendar (``GOOGLECALENDAR_EVENTS_LIST``, single events,
        ordered by start), cached for ``CALENDAR_REFRESH_SECONDS``. ``days``: whole days in the bridge's timezone
        instead, today (from its midnight, so what already happened today is there too) and the ``days - 1`` after
        it (the SamRabbit window's agenda by day)."""
        now = self._now()
        if days is not None:
            # Midnights by calendar date: same-zone arithmetic is wall time, so a daylight-saving change in between
            # makes that day 23 or 25 hours long instead of moving the next midnight.
            low = now.replace(hour=0, minute=0, second=0, microsecond=0)
            high = low + timedelta(days=days)
            key: Any = ("days", days, low.date().isoformat())
        else:
            low, high, key = now, now + timedelta(hours=hours), hours
        with self._lock:
            cached = self._agenda.get(key)
        if cached is not None and not fresh and self._monotonic() - cached[0] < CALENDAR_REFRESH_SECONDS:
            return dict(cached[1], cached=True)
        try:
            writer = self._writer()
        except MobileError as error:
            return {"available": False, "reason": error.code, "events": []}
        arguments = {"calendarId": writer.calendar_id, "timeMin": low.isoformat(timespec="seconds"),
                     "timeMax": high.isoformat(timespec="seconds"), "singleEvents": True, "orderBy": "startTime",
                     "maxResults": 50 if (high - low) <= timedelta(hours=24) else MAX_AGENDA_EVENTS,
                     "maxAttendees": 1, "timeZone": self.zone_name}
        try:
            data = writer._call("GOOGLECALENDAR_EVENTS_LIST", arguments, writing=False)  # noqa: SLF001
        except Exception as error:  # noqa: BLE001 - CalendarError: Composio missing, signed out, Google busy
            failed = {"available": False, "reason": str(getattr(error, "code", "calendar_unavailable")), "events": []}
            if cached is not None:
                return dict(cached[1], cached=True, stale=True, reason=failed["reason"])
            return failed
        account = account_from_events(data, writer.calendar_id)
        if account:
            self._learned_account = account  # for Google links opened from the phone (``google_account``)
        events = [event for event in (agenda_event(item, self.zone) for item in _items(data)) if event]
        events.sort(key=lambda item: (item["startsAt"], item["title"]))
        value = {"available": True, "timezone": self.zone_name, "from": arguments["timeMin"],
                 "to": arguments["timeMax"], "calendarId": writer.calendar_id, "events": events,
                 "updatedAt": iso_utc(self._clock())}
        with self._lock:
            if days is not None:  # the days read on an earlier date are never asked for again
                for name in [name for name in self._agenda if isinstance(name, tuple) and name[2] != key[2]]:
                    del self._agenda[name]
            self._agenda[key] = (self._monotonic(), value)
        return dict(value, cached=False)

    def _calendar_changed(self) -> None:
        with self._lock:
            self._agenda.clear()
            self._cache.pop("calendar", None)
            self._summary = None

    def calendar_changed(self) -> None:
        """Another module (a voice note, the morning brief) changed the calendar: the agenda is read again."""
        self._calendar_changed()

    def _r_agenda(self, handler: Any, _params: Dict[str, str], _device: Any, _route: str) -> Tuple[int, Any]:
        """``?hours=`` (the phone; default 24, from now) or ``?days=`` (the SamRabbit window's agenda by day: today
        from its midnight and the days after it, 1 to 7 days)."""
        query = _query(handler)
        if _one(query, "days") is not None:
            value = self.agenda(days=_int(query, "days", 1, 1, MAX_AGENDA_DAYS))
        else:
            value = self.agenda(_int(query, "hours", 24, 1, MAX_AGENDA_HOURS))
        if not value.get("available") and not value.get("events"):
            raise MobileError(503, str(value.get("reason") or "calendar_unavailable"),
                              "Google Calendar can't be read from the Mac right now.", retryable=True)
        return 200, value

    def _r_block(self, handler: Any, _params: Dict[str, str], _device: Any, _route: str) -> Tuple[int, Any]:
        body = _json_body(handler)
        minutes = body.get("minutes")
        if isinstance(minutes, float) and minutes.is_integer():
            minutes = int(minutes)
        if isinstance(minutes, bool) or not isinstance(minutes, int) or \
                not MIN_BLOCK_MINUTES <= minutes <= MAX_BLOCK_MINUTES:
            raise _bad("invalid_minutes", f"minutes must be a whole number from {MIN_BLOCK_MINUTES} to "
                       f"{MAX_BLOCK_MINUTES}.")
        title = body.get("title")
        title = _clean_name(title, DEFAULT_BLOCK_TITLE, MAX_TITLE_CHARS) if title is not None else DEFAULT_BLOCK_TITLE
        writer = self._writer()
        start, end = block_window(self._now(), minutes)
        value = writer.create({"title": title, "startsAt": start.isoformat(timespec="seconds"),
                               "endsAt": end.isoformat(timespec="seconds"), "timezone": self.zone_name})
        self._calendar_changed()
        _LOG.info("mobile calendar block added (%d min)", minutes)
        return 200, dict(value, minutes=minutes)

    def _r_event(self, handler: Any, _params: Dict[str, str], _device: Any, _route: str) -> Tuple[int, Any]:
        body = _json_body(handler)
        writer = self._writer()
        request = {key: body.get(key) for key in ("title", "startsAt", "endsAt", "location", "description")
                   if body.get(key) is not None}
        request["timezone"] = self.zone_name
        value = writer.create(request)
        self._calendar_changed()
        _LOG.info("mobile calendar event added")
        return 200, value

    # ------------------------------------------------------------------ journal
    def _r_journal(self, handler: Any, _params: Dict[str, str], _device: Any, _route: str) -> Tuple[int, Any]:
        text = _json_body(handler).get("text")
        if not isinstance(text, str) or not text.strip():
            raise _bad("invalid_text", "text must be the note to add.")
        if len(text) > MAX_NOTE_CHARS or "\x00" in text:
            raise _bad("invalid_text", f"The note must be at most {MAX_NOTE_CHARS} characters.")
        if self.server is None:
            raise MobileError(503, "journal_unavailable", "The journal is not set up on the Mac bridge.")
        moment = self._now()
        words = " ".join(text.split())
        try:
            result = self.server.append(moment.date().isoformat(), journal_note(words, moment))
        except Exception as error:  # noqa: BLE001 - BridgeError: answered with its own envelope
            code = str(getattr(error, "code", "") or "")
            if code in _JOURNAL_DOWN:
                self._journal_state({"available": False, "reason": code})
            raise
        _LOG.info("mobile journal note added")
        value = {"recorded": True, "date": result.get("date"), "time": moment.strftime("%H:%M")}
        if scrub_secrets(words) != words:
            value["redacted"] = True  # a code, password or key in the words was written as [redacted]
        if result.get("dryRun"):
            value["dryRun"] = True
        self._journal_state({"available": True, **({"dryRun": True} if result.get("dryRun") else {})})
        return 200, value

    def _journal_state(self, value: Dict[str, Any]) -> None:
        """A note that went in (or failed because Heptabase is off) is as good as the periodic probe."""
        with self._lock:
            self._cache["journal"] = (self._monotonic(), value)
            self._summary = None

    # ------------------------------------------------------------------ Mac
    def _control(self) -> Any:
        control = getattr(self.server, "mac", None)
        if control is None:
            raise MobileError(503, "mac_unavailable", "Mac control is not set up on the bridge.")
        return control

    def google_account(self, *, wait: bool = False) -> Optional[str]:
        """The Google account for ``authuser=``: ``SAMRABBIT_GOOGLE_ACCOUNT`` (install.sh ``--google-account``),
        else the account the calendar writer saw on an event it created, else the one the agenda shows (learned on
        every calendar refresh, so it is known soon after the bridge starts). ``wait``: when none is known yet,
        load the agenda first (at most ``COLD_WAIT_SECONDS`` with the worker running)."""
        if self._google_account:
            return self._google_account
        writer = getattr(self.server, "calendar", None)
        try:
            found = normalize_email((writer.capabilities() or {}).get("account")) if writer is not None else None
        except Exception:  # noqa: BLE001
            found = None
        if found is None and self._learned_account is None and wait and writer is not None and \
                hasattr(writer, "create"):
            self._parts(("calendar",))
        return found or self._learned_account

    def _r_mac_state(self, _handler: Any, _params: Dict[str, str], _device: Any, _route: str) -> Tuple[int, Any]:
        control = self._control()
        try:
            value = dict(control.state())
            value["available"] = True
        except Exception as error:  # noqa: BLE001 - MacError: no Accessibility, busy, no driver
            status, payload = _error_answer(error)
            value = {"available": False, "computer": self.bridge_name(), "screenLocked": control.screen_locked(),
                     "error": payload.get("error") if isinstance(payload, dict) else {"code": "mac_unavailable"}}
        value.setdefault("computer", self.bridge_name())
        return 200, value

    def _r_mac_open(self, handler: Any, _params: Dict[str, str], _device: Any, _route: str) -> Tuple[int, Any]:
        body = _json_body(handler)
        kinds = [key for key in ("app", "url") if body.get(key) not in (None, "")]
        if len(kinds) != 1 or body.get("path") not in (None, ""):
            raise _bad("invalid_open", "Send exactly one of app or url.")
        value = body[kinds[0]]
        if not isinstance(value, str):
            raise _bad("invalid_open", f"{kinds[0]} must be text.")
        if kinds[0] == "url":
            value = value.strip()
            value = with_google_account(value, self.google_account(wait=is_google_link(value)))
        result = self._control().open({kinds[0]: value})
        _LOG.info("mobile mac open (%s)", kinds[0])
        return 200, result

    def _r_mac_screenshot(self, handler: Any, _params: Dict[str, str], _device: Any, _route: str) -> Tuple[int, Any]:
        side = _int(_query(handler), "max", DEFAULT_SCREENSHOT_SIDE, 320, 1600)
        shot = self._control().screenshot(None, side)
        data = base64.b64decode(str(shot.get("base64") or ""))
        if not data:
            raise MobileError(502, "capture_failed", "The Mac could not take the screenshot.", retryable=True)
        return 200, _Bytes(data, str(shot.get("mime") or "image/jpeg"),
                           {"X-Image-Width": str(shot.get("width") or 0), "X-Image-Height": str(shot.get("height") or 0)})

    # ------------------------------------------------------------------ voice
    def transcription_changed(self) -> None:
        """After a recording (here or in an assistant turn): the summary's ``transcribe`` part is what the transcriber
        knows now (a recording that worked clears a stale ``permission_denied``, whatever its language), or is checked
        again."""
        known = None
        try:
            if self.transcriber is not None and callable(getattr(self.transcriber, "cached_status", None)):
                known = self.transcriber.cached_status()
        except Exception:  # noqa: BLE001
            known = None
        with self._lock:
            if known is not None:
                self._cache["transcribe"] = (self._monotonic(), dict(known))
            else:
                self._cache.pop("transcribe", None)
            self._summary = None

    def _assistant(self) -> Any:
        if self.assistant is None:
            raise MobileError(503, "assistant_unavailable", "The voice assistant is not installed on the Mac bridge.")
        return self.assistant

    @staticmethod
    def _speaker(device: Optional[Dict[str, Any]]) -> Dict[str, Any]:
        """Who talks: the paired phone or watch, or (the desktop token on /v1/desktop/assistant/*, no device) the
        Mac itself."""
        if device is not None:
            return device
        return dict(_assistant.MAC_DEVICE) if _assistant is not None else {"deviceId": "mac", "platform": "macos"}

    def _r_assistant_turn(self, handler: Any, _params: Dict[str, str], device: Optional[Dict[str, Any]],
                          _route: str) -> Tuple[int, Any]:
        return self._assistant().turn(handler, self._speaker(device))

    def _r_assistant_announcements(self, handler: Any, _params: Dict[str, str], device: Optional[Dict[str, Any]],
                                   _route: str) -> Tuple[int, Any]:
        return self._assistant().announcements(handler, self._speaker(device))

    def _r_assistant_end(self, handler: Any, _params: Dict[str, str], device: Optional[Dict[str, Any]],
                         _route: str) -> Tuple[int, Any]:
        return self._assistant().end(handler, self._speaker(device))

    def _r_assistant_session(self, handler: Any, _params: Dict[str, str], device: Optional[Dict[str, Any]],
                             _route: str) -> Tuple[int, Any]:
        return self._assistant().session(handler, self._speaker(device))

    def _r_assistant_cancel(self, handler: Any, _params: Dict[str, str], device: Optional[Dict[str, Any]],
                            _route: str) -> Tuple[int, Any]:
        return self._assistant().cancel(handler, self._speaker(device))

    def _chatgpt(self, handler: Any, action: str) -> Tuple[int, Any]:
        if action != "status":
            _optional_body(handler)
        status, value = self._assistant().chatgpt_route(action)
        if action != "status":
            _LOG.info("mobile chatgpt %s", action)
        return status, value

    def _r_chatgpt_start(self, handler: Any, _params: Dict[str, str], _device: Any, _route: str) -> Tuple[int, Any]:
        return self._chatgpt(handler, "start")

    def _r_chatgpt_status(self, handler: Any, _params: Dict[str, str], _device: Any, _route: str) -> Tuple[int, Any]:
        return self._chatgpt(handler, "status")

    def _r_chatgpt_disconnect(self, handler: Any, _params: Dict[str, str], _device: Any,
                              _route: str) -> Tuple[int, Any]:
        return self._chatgpt(handler, "disconnect")

    def _r_transcribe(self, handler: Any, _params: Dict[str, str], _device: Any, _route: str) -> Tuple[int, Any]:
        """A recording from the watch or the phone (the raw body) -> ``{text, durationMs, engine, locale}``. Checked
        before anything runs: the Content-Type, ``?lang=``, the size (2 MiB), the container's own bytes and its
        length (90 s). The audio lives only in a private temp file while the helper runs; nothing is logged."""
        if self.transcriber is None or _transcribe is None:
            raise MobileError(503, "transcribe_unavailable", "Transcription is not installed on the Mac bridge.")
        declared = _transcribe.content_kind(handler.headers.get("Content-Type"))
        language = _transcribe.normalize_language(_one(_query(handler), "lang"))
        length = _length(handler, _transcribe.MAX_AUDIO_BYTES)
        if not length:
            raise _bad("invalid_audio", "Send the recording as the request body.")
        try:
            data = handler.rfile.read(length)
        except OSError:  # includes the socket timeout
            data = b""
        if len(data) != length:
            raise MobileError(400, "invalid_audio", "The recording did not arrive completely.", retryable=True)
        kind, _seconds = _transcribe.check_audio(data, declared)
        try:
            result = self.transcriber.transcribe(data, kind, language)
        finally:
            self.transcription_changed()  # the summary's "transcribe" part reflects what this recording showed
        _LOG.info("mobile transcription done (%s, %d ms of audio)", result.get("engine"), result.get("durationMs", 0))
        return 200, result


# --------------------------------------------------------------------------- HTTP plumbing


def _shut(handler: Any) -> None:
    """End a streaming response from another thread: the stream's next peer check or write fails and it returns."""
    connection = getattr(handler, "connection", None)
    if connection is None:
        return
    try:
        connection.shutdown(socket.SHUT_RDWR)
    except OSError:
        pass


def _error_answer(error: Exception) -> Tuple[int, Dict[str, Any]]:
    status = getattr(error, "status", None)
    payload = getattr(error, "payload", None)
    if isinstance(status, int) and callable(payload):
        value = payload()
        if isinstance(value, dict) and isinstance(value.get("error"), dict):
            value["error"].setdefault("retryable", False)
            return status, value
    _LOG.error("mobile request failed unexpectedly (%s)", type(error).__name__)
    return 500, MobileError(500, "internal_error", "The bridge failed unexpectedly.").payload()


def _query(handler: Any) -> Dict[str, List[str]]:
    try:
        return parse_qs(urlsplit(handler.path).query, max_num_fields=8)
    except ValueError:
        raise _bad("invalid_query", "Too many query parameters.") from None


def _one(query: Dict[str, List[str]], key: str) -> Optional[str]:
    values = query.get(key) or []
    value = values[0].strip() if values else ""
    if len(value) > 200:
        raise _bad("invalid_query", f"{key} is too long.")
    return value or None


def _int(query: Dict[str, List[str]], key: str, default: int, low: int, high: int) -> int:
    value = _one(query, key)
    if value is None:
        return default
    if not value.isdigit() or len(value) > 6:
        raise _bad("invalid_query", f"{key} must be a whole number.")
    return max(low, min(high, int(value)))


def _length(handler: Any, limit: int = MAX_BODY_BYTES) -> int:
    if handler.headers.get("Transfer-Encoding"):
        raise MobileError(411, "length_required", "Send a Content-Length body.")
    raw = handler.headers.get("Content-Length")
    if raw in (None, ""):
        return 0
    try:
        length = int(raw)
    except ValueError:
        raise MobileError(411, "length_required", "Send a Content-Length body.") from None
    if length < 0 or length > limit:
        raise MobileError(413, "body_too_large", f"The body must be at most {limit} bytes.")
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
    if not length:
        return {}
    raw = handler.rfile.read(length)
    try:
        value = json.loads(raw.decode("utf-8")) if raw.strip() else {}
    except (UnicodeDecodeError, ValueError):
        raise _bad("invalid_json", "The body must be a JSON object.") from None
    return value if isinstance(value, dict) else {}


def _send(handler: Any, status: int, payload: Any) -> None:
    if isinstance(payload, _Bytes):
        body, content_type, extra = payload.body, payload.content_type, payload.headers
        extra = dict(extra, **{"X-Content-Type-Options": "nosniff"})
    else:
        body = json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
        content_type, extra = "application/json; charset=utf-8", {}
    try:
        handler.send_response(status)
        handler.send_header("Content-Type", content_type)
        handler.send_header("Content-Length", str(len(body)))
        handler.send_header("Cache-Control", "no-store")
        for name, value in extra.items():
            handler.send_header(name, value)
        if status == 401:
            handler.send_header("WWW-Authenticate", 'Bearer realm="samrabbit-mobile"')
        handler.send_header("Connection", "close")
        handler.end_headers()
        handler.wfile.write(body)
    except OSError:
        pass  # the device went away


# --------------------------------------------------------------------------- command line (pair-phone.sh)


def print_pairing_code(port: int, desktop_token_file: str) -> int:
    """Ask the running bridge (loopback, desktop token) for a pairing code and print it for the user."""
    import urllib.error  # noqa: PLC0415
    import urllib.request  # noqa: PLC0415

    try:
        with open(os.path.expanduser(desktop_token_file), "r", encoding="utf-8") as handle:
            token = handle.read().strip()
    except OSError:
        print("No desktop token; run companion/mac-bridge/install.sh first.", file=sys.stderr)
        return 2
    request = urllib.request.Request(f"http://127.0.0.1:{port}/v1/mobile/pairing/start", data=b"{}", method="POST",
                                     headers={"X-SamRabbit-Desktop": token, "Content-Type": "application/json"})
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))  # loopback: never a system proxy
    try:
        with opener.open(request, timeout=10) as response:
            value = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as error:
        print(f"The bridge refused (HTTP {error.code}); is it up to date? Run companion/mac-bridge/install.sh.",
              file=sys.stderr)
        return 1
    except (OSError, ValueError):
        print(f"The bridge is not answering on port {port}.", file=sys.stderr)
        return 1
    code = str(value.get("code") or "")
    expires = t3.parse_time(value.get("expiresAt"))
    until = expires.astimezone().strftime("%H:%M") if expires else "in 10 minutes"
    print("Pair an iPhone with SamRabbit")
    print(f"  Code:  {code[:4]} {code[4:]}   (single use, valid until {until})")
    print("  Mac:   " + str(value.get("bridgeName") or ""))
    print("  Host:  " + ", ".join(value.get("hosts") or []))
    print("  Link:  " + str(value.get("pairUrl") or ""))
    print("In the SamRabbit app: Settings > Pair with Mac > Enter code (or scan the QR in SamRabbit > Pair iPhone…).")
    return 0


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="SamRabbit mobile API helpers.")
    parser.add_argument("command", choices=("pair-code",))
    parser.add_argument("--port", type=int, default=int(os.environ.get("SAMRABBIT_BRIDGE_PORT", "3780")))
    parser.add_argument("--desktop-token-file", default=os.environ.get("SAMRABBIT_DESKTOP_TOKEN_FILE") or
                        "~/.config/samrabbit/desktop-token")
    options = parser.parse_args(argv)
    return print_pairing_code(options.port, options.desktop_token_file)


if __name__ == "__main__":
    sys.exit(main())
