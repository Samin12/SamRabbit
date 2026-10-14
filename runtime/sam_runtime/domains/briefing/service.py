"""The morning briefing on the R1 (CONTRACTS-WAVE8 B4): fetched from the Mac bridge, cached, acted on by tap or
voice.

* ``sam-briefing`` worker: fetches at start, every 10 minutes in the morning (until 12:00 in the user's timezone, the
  journal setting, America/New_York by default) and hourly otherwise; at once after a refresh request (then again
  at +5, +15, +30, +60 s while the Mac rebuilds) and when the bridge answers again after a failure. Failures back
  off 2, 5, 15, 60, 300 s.
* The quiet hour before the build: the bridge builds the day's brief at 06:40 (retry 06:52), and any request after
  05:00 with no brief for today makes it build at once (its "lazy" build, for a Mac that was off at 06:40). So the
  worker never asks the bridge on its own from 05:00 until ``BUILD_TIME`` + 2 min (06:42): a background fetch due
  in that stretch waits for 06:42, and the first morning fetch is at 06:42 sharp. A tap on refresh and a spoken
  "read my brief" still ask at once (the user wants it now). A bridge that publishes its own ``buildTime``
  ("HH:MM", the ``time`` in its briefing.json) moves that stretch with it.
* Cache: ``provider_settings`` ``briefing.latest`` (the normalized brief, at most 64 KB) and ``briefing.meta``
  (fetch time, last error, the date a ``briefing.ready`` announcement was made). No migration.
* ``briefing.ready``: one silent announcement per day, for the first brief that has something to do first. The app
  only acknowledges it ("seen"): the R1 never reads the brief out unless asked.
* Actions go to the bridge (``draft_reply`` makes a Gmail DRAFT there; nothing is ever sent). ``open`` on an email
  opens its Gmail link in Chrome on the Mac; on an agent item with a T3 thread the app opens the thread itself.

Nothing from the brief is logged (counts, revisions and codes only).
"""

from __future__ import annotations

from collections.abc import Callable
from datetime import UTC, datetime, timedelta
import json
import re
import sqlite3
import threading
import time
from urllib.parse import urlsplit

from sam_runtime.core.logging import runtime_logger
from sam_runtime.domains.bridge_calls import BridgeCallFailure
from sam_runtime.domains.heptabase_journal.localtime import DEFAULT_TIMEZONE, US_EASTERN_FALLBACK, UnknownTimezone, \
    local_datetime, resolve_zone
from sam_runtime.storage.announcements import AnnouncementRepository
from sam_runtime.storage.database import RuntimeDatabase
from sam_runtime.storage.json_settings import JsonSetting

from . import model
from .client import BriefingBridgeClient

LATEST_KEY = "briefing.latest"
META_KEY = "briefing.meta"
KIND_READY = "briefing.ready"
MORNING_START_HOUR = 5
MORNING_END_HOUR = 12
# The bridge's defaults (samrabbit_briefing.BUILD_TIME, LAZY_AFTER): a request in between makes it build early.
BUILD_TIME = (6, 40)
LAZY_AFTER = (5, 0)
# The first background fetch comes this long after the build time (the bridge's timer ticks every 30 s).
AFTER_BUILD_SECONDS = 2 * 60.0
MORNING_INTERVAL_SECONDS = 10 * 60.0
OTHER_INTERVAL_SECONDS = 60 * 60.0
UNCONFIGURED_INTERVAL_SECONDS = 5 * 60.0
BACKOFF_SECONDS = (2, 5, 15, 60, 300)
REFRESH_POLLS_SECONDS = (5.0, 15.0, 30.0, 60.0)
AFTER_ACT_SECONDS = 4.0
STALE_SECONDS = 2 * 60 * 60.0
WAKE_DEBOUNCE_SECONDS = 30.0
MAX_CACHE_BYTES = 64 * 1024
_UNREACHABLE = frozenset({"mac_unreachable", "mac_no_answer", "mac_not_configured", "mac_token_unavailable"})
_STATE_AFTER = {"draft_reply": "drafted", "make_task": "tasked", "block_time": "blocked", "remind": "reminded",
                "done": "done", "dismiss": "dismissed"}
_SAY = {"draft_reply": "Saved as a draft in Gmail. Open it on your phone to send.",
        "make_task": "Started a T3 task for it.", "block_time": "Blocked time on your calendar.",
        "remind": "I'll bring it back later.", "done": "Marked done.", "dismiss": "Dismissed."}
_FAILED = {"mac_unreachable": "Your Mac is unreachable right now.", "mac_no_answer": "Your Mac did not answer in time.",
           "mac_not_configured": "Connect your Mac first.", "mac_unauthorized": "Connect the Mac bridge again.",
           "bridge_outdated": "The Mac bridge is too old for the morning brief.",
           "item_not_found": "That item is no longer in the brief."}
_LOG = runtime_logger()


class BriefingActionRejected(ValueError):
    def __init__(self, code: str, message: str, status: int = 400) -> None:
        super().__init__(message)
        self.code = code
        self.status = status


def backoff_seconds(failures: int) -> int:
    return BACKOFF_SECONDS[min(max(failures, 1), len(BACKOFF_SECONDS)) - 1]


class BriefingService:
    def __init__(self, client: BriefingBridgeClient, database: RuntimeDatabase,
                 announcements: AnnouncementRepository, *, timezone_name: Callable[[], str | None] = lambda: None,
                 open_on_mac: Callable[[str], object] | None = None, clock: Callable[[], float] = time.time) -> None:
        self._client = client
        self._announcements = announcements
        self._timezone_name = timezone_name
        self._open_on_mac = open_on_mac
        self._clock = clock
        self._latest = JsonSetting(database, LATEST_KEY)
        self._meta_setting = JsonSetting(database, META_KEY)
        self._lock = threading.Lock()
        self._wake = threading.Condition(self._lock)
        self._loaded = False
        self._brief: dict[str, object] | None = None
        self._meta: dict[str, object] = {}
        self._failures = 0
        self._next_at = -1.0  # not scheduled yet: the first worker step plans it (quiet stretch included)
        self._polls: list[float] = []
        self._refresh_requested = False
        self._last_wake = 0.0
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        client.store.add_listener(self.wake)

    # ------------------------------------------------------------------ lifecycle
    def start(self) -> None:
        if self._thread is not None:
            return
        self._load()
        self._stop.clear()
        self._thread = threading.Thread(target=self._run, name="sam-briefing", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        with self._wake:
            self._wake.notify_all()
        if self._thread is not None:
            self._thread.join(timeout=3.0)
            self._thread = None

    def wake(self) -> None:
        """The bridge answered someone or was re-paired: fetch now if the last fetch could not reach it
        (debounced). An outdated bridge or an HTTP error waits for the normal cadence."""
        now = self._clock()
        with self._wake:
            if self._meta.get("fetchedAt") is not None and \
                    (self._failures == 0 or self._meta.get("error") not in _UNREACHABLE):
                return
            if now - self._last_wake < WAKE_DEBOUNCE_SECONDS:
                return
            self._last_wake = now
            self._next_at = self._background_at(now)
            self._wake.notify_all()

    # ------------------------------------------------------------------ API
    def configured(self) -> bool:
        return self._client.configured()

    def view(self) -> dict[str, object]:
        """``{configured, available, status, fetchedAt, stale, error, today, morning, openCount, briefing}``
        from the cache only (no network); ``briefing`` is today's brief or null."""
        self._load()
        now = self._clock()
        local = local_datetime(now, self._zone())
        today = local.date().isoformat()
        configured = self._client.configured()
        with self._lock:
            brief = self._brief
            meta = dict(self._meta)
            never = meta.get("fetchedAt") is None
        current = brief if brief is not None and brief.get("date") == today else None
        error = meta.get("error") if isinstance(meta.get("error"), str) else None
        if not configured:
            status = "unconfigured"
        elif error == "bridge_outdated":
            status = "off"
        elif current is None:
            status = "loading" if never else ("stale" if brief is not None else str(meta.get("status") or "none"))
        else:
            status = str(current.get("status") or "ready")
        fetched = meta.get("fetchedAt") if isinstance(meta.get("fetchedAt"), (int, float)) else None
        if configured and never:
            self._kick()
        return {
            "configured": configured,
            "available": configured and current is not None and status not in ("off", "failed"),
            "status": status,
            "fetchedAt": _iso(fetched) if fetched is not None else None,
            "stale": fetched is None or now - float(fetched) > STALE_SECONDS or error is not None,
            "error": error,
            "today": today,
            "morning": MORNING_START_HOUR <= local.hour < MORNING_END_HOUR,
            "openCount": model.open_count(current),
            "briefing": current,
        }

    def fetch_once(self) -> bool:
        """One fetch from the bridge into the cache; True when the brief was read."""
        self._load()
        try:
            raw = self._client.fetch()
        except BridgeCallFailure as failure:
            self._record_failure(failure.code)
            return False
        brief = model.normalize(raw, self._zone())
        body = raw.get("briefing") if isinstance(raw.get("briefing"), dict) else raw
        status = model.flat(body.get("status"), 16)
        build_time = _clock_setting(body.get("buildTime"))
        now = self._clock()
        with self._lock:
            if brief is not None:
                self._brief = brief
            self._meta.update({"fetchedAt": now, "error": None, "status": status or None})
            if build_time is not None:
                self._meta["buildTime"] = f"{build_time[0]:02d}:{build_time[1]:02d}"
            self._failures = 0
            self._save_locked()
        if brief is not None:
            self._maybe_announce(brief)
            _LOG.info("briefing.fetched", extra={"revision": brief["revision"], "items": len(model.items(brief))})
        else:
            _LOG.info("briefing.fetched_empty", extra={"status": status[:16]})
        return True

    def request_refresh(self) -> dict[str, object]:
        """Ask the Mac to rebuild (at most what the bridge allows); the worker does it and fetches the result."""
        if not self._client.configured():
            return {"status": "unconfigured"}
        with self._wake:
            self._refresh_requested = True
            self._next_at = self._clock()
            self._wake.notify_all()
        return {"status": "refreshing"}

    def fetch_soon(self) -> None:
        """The user asked for the brief (by voice) and the R1 has none for today: ask the Mac now, even in the quiet
        stretch before its build time (then the bridge builds one at once, which is what they want)."""
        if not self._client.configured():
            return
        with self._wake:
            now = self._clock()
            if self._next_at < 0 or self._next_at > now:
                self._next_at = now
            self._wake.notify_all()

    def act(self, item_id: str, action: object) -> dict[str, object]:
        """One tap (or a voice confirm) on an item: ``{ok, itemId, action, state, say, open?}``."""
        self._load()
        kind = model.action_type(action)
        with self._lock:
            brief = self._brief
        item = model.find(brief, item_id)
        if item is None:
            raise BriefingActionRejected("item_not_found", _FAILED["item_not_found"], 404)
        if kind is None or not model.allowed(item, kind):
            raise BriefingActionRejected("action_not_offered", "That item doesn't offer that action.")
        if kind == "open" and isinstance(item.get("threadId"), str):
            return {"ok": True, "itemId": item_id, "action": kind, "state": item.get("state"),
                    "say": "Opening it in T3.", "open": {"t3Thread": item["threadId"]}}
        try:
            result = self._client.act(item_id, kind)
        except BridgeCallFailure as failure:
            _LOG.info("briefing.act_failed", extra={"action": kind, "code": failure.code})
            message = _FAILED.get(failure.code) or (failure.message[:160] if failure.message else
                                                     "That didn't work. Try again from your phone.")
            return {"ok": False, "itemId": item_id, "action": kind, "state": item.get("state"), "error": failure.code,
                    "say": message}
        answered = result.get("item") if isinstance(result.get("item"), dict) else result
        state = model.state(answered.get("state")) if isinstance(answered.get("state"), str) \
            else _STATE_AFTER.get(kind, str(item.get("state") or "open"))
        inner = result.get("result") if isinstance(result.get("result"), dict) else {}
        say = model.flat(inner.get("say"), 160) or _SAY.get(kind, "Done.")
        view: dict[str, object] = {"ok": result.get("ok") is not False, "itemId": item_id, "action": kind,
                                   "state": state, "say": say}
        if kind == "open":
            view["say"] = self._open(result)
        with self._wake:
            if self._brief is not None and model.find(self._brief, item_id) is not None:
                self._brief = model.with_state(self._brief, item_id, state)
                self._save_locked()
            now = self._clock()
            self._polls = sorted({*self._polls, now + AFTER_ACT_SECONDS})
            self._wake.notify_all()
        _LOG.info("briefing.acted", extra={"action": kind, "state": state})
        return view

    # ------------------------------------------------------------------ work
    def run_due(self) -> bool:
        """One worker step (refresh request, a due fetch); True when it fetched. Used by the worker and tests."""
        now = self._clock()
        with self._lock:
            if self._next_at < 0:
                self._next_at = self._background_at(now)
            refresh = self._refresh_requested
            self._refresh_requested = False
            due = now >= self._next_at or any(at <= now for at in self._polls)
            self._polls = [at for at in self._polls if at > now]
        if refresh:
            try:
                self._client.refresh()
                with self._lock:
                    self._polls = sorted({*self._polls, *(now + delay for delay in REFRESH_POLLS_SECONDS)})
            except BridgeCallFailure as failure:
                _LOG.info("briefing.refresh_failed", extra={"code": failure.code})
            due = True
        if not due:
            return False
        ok = self.fetch_once()
        with self._lock:
            now = self._clock()
            if ok:
                wanted = now + self._interval()
            elif self._meta.get("error") == "mac_not_configured":
                wanted = now + UNCONFIGURED_INTERVAL_SECONDS
            elif self._meta.get("error") == "bridge_outdated":
                wanted = now + self._interval()  # an old bridge: no fast retries
            else:
                wanted = now + min(self._interval(), backoff_seconds(self._failures))
            self._next_at = self._background_at(wanted)
        return ok

    def _run(self) -> None:
        while not self._stop.is_set():
            try:
                self.run_due()
            except Exception:  # noqa: BLE001 - keep polling
                _LOG.exception("briefing.worker_failed")
            with self._wake:
                if self._stop.is_set():
                    break
                upcoming = [self._next_at, *self._polls]
                delay = min(upcoming) - self._clock()
                if not self._refresh_requested:
                    self._wake.wait(timeout=max(0.5, min(OTHER_INTERVAL_SECONDS, delay)))

    def _kick(self) -> None:
        with self._wake:
            now = self._clock()
            soon = self._background_at(now)
            if self._next_at > soon:
                self._next_at = soon
                self._wake.notify_all()

    def _interval(self) -> float:
        hour = local_datetime(self._clock(), self._zone()).hour
        return MORNING_INTERVAL_SECONDS if MORNING_START_HOUR <= hour < MORNING_END_HOUR else OTHER_INTERVAL_SECONDS

    def _background_at(self, wanted: float) -> float:
        """``wanted``, or the end of the quiet stretch (05:00 to the build time + 2 min, local) when it falls in it:
        a fetch there would make the bridge build the day's brief early ("lazy") and skip its 06:40 build. Once the
        R1 has that day's brief (a refresh he asked for), the bridge has one too: no quiet stretch then."""
        zone = self._zone()
        local = local_datetime(wanted, zone)
        brief = self._brief  # callers may hold the lock (a plain read needs none)
        if brief is not None and brief.get("date") == local.date().isoformat():
            return wanted
        build = self._build_time()
        quiet_from = local.replace(hour=LAZY_AFTER[0], minute=LAZY_AFTER[1], second=0, microsecond=0)
        quiet_until = local.replace(hour=build[0], minute=build[1], second=0, microsecond=0) + \
            timedelta(seconds=AFTER_BUILD_SECONDS)
        if quiet_from <= local < quiet_until:
            return quiet_until.timestamp()
        return wanted

    def _build_time(self) -> tuple[int, int]:
        # Callers may hold the lock (a dict read needs none).
        published = _clock_setting(self._meta.get("buildTime"))
        if published is None or published < LAZY_AFTER:
            return BUILD_TIME
        return published

    def _zone(self):  # noqa: ANN202 - tzinfo
        try:
            return resolve_zone(self._timezone_name() or DEFAULT_TIMEZONE)
        except (UnknownTimezone, Exception):  # noqa: BLE001 - a broken setting never stops the brief
            return US_EASTERN_FALLBACK

    def _record_failure(self, code: str) -> None:
        with self._lock:
            self._failures += 1
            self._meta.update({"error": code, "attemptAt": self._clock()})
            self._save_locked()
        if code not in _UNREACHABLE:
            _LOG.info("briefing.fetch_failed", extra={"code": code})

    def _maybe_announce(self, brief: dict[str, object]) -> None:
        today = local_datetime(self._clock(), self._zone()).date().isoformat()
        with self._lock:
            if brief.get("date") != today or self._meta.get("announcedDate") == today:
                return
            if not isinstance(brief.get("needsYou"), int) or int(brief["needsYou"]) <= 0:
                return
            self._meta["announcedDate"] = today
            self._save_locked()
        headline = str(brief.get("headline") or "Your morning brief is ready")
        try:
            self._announcements.publish(KIND_READY, headline, headline, {
                "date": brief.get("date"), "revision": brief.get("revision"), "needsYou": brief.get("needsYou")})
        except sqlite3.Error:
            _LOG.warning("briefing.announce_failed")

    def _open(self, result: dict[str, object]) -> str:
        inner = result.get("result") if isinstance(result.get("result"), dict) else {}
        url = inner.get("url") or result.get("url")
        parsed = urlsplit(url) if isinstance(url, str) else None
        if parsed is None or parsed.scheme != "https" or not parsed.hostname or self._open_on_mac is None:
            return "Open it on your phone."
        try:
            self._open_on_mac(url)
        except Exception:  # noqa: BLE001 - the Mac may be locked or away
            return "Couldn't open it on your Mac. Open it on your phone."
        return "Opened it on your Mac."

    # ------------------------------------------------------------------ cache
    def _load(self) -> None:
        with self._lock:
            if self._loaded:
                return
        brief = self._latest.load()
        meta = self._meta_setting.load()
        with self._lock:
            if self._loaded:
                return
            self._loaded = True
            self._brief = model.normalize(brief) if isinstance(brief, dict) else None
            self._meta = dict(meta) if isinstance(meta, dict) else {}

    def _save_locked(self) -> None:
        if not self._loaded:
            return
        if self._brief is not None and len(json.dumps(self._brief, ensure_ascii=False)) <= MAX_CACHE_BYTES:
            self._latest.save(self._brief)
        self._meta_setting.save(self._meta)


def _clock_setting(value: object) -> tuple[int, int] | None:
    """``"06:40"`` as (6, 40); None for anything else."""
    match = re.match(r"^(\d{1,2}):(\d{2})$", value.strip()) if isinstance(value, str) else None
    if match is None or int(match.group(1)) > 23 or int(match.group(2)) > 59:
        return None
    return int(match.group(1)), int(match.group(2))


def _iso(epoch: float) -> str:
    return datetime.fromtimestamp(float(epoch), UTC).isoformat(timespec="seconds").replace("+00:00", "Z")
