"""Voice notes from the R1 (CONTRACTS-WAVE8 B2): the app's own transcript goes to the Mac bridge, which decides
what it is (journal line, T3 task, calendar entry or a saved note) and does it.

``submit`` stores the note in the outbox first (``provider_settings`` ``capture.outbox``, no migration), then tries
the bridge at once and waits a few seconds for the outcome, so the app can say "Sent ✓ — Added to your journal".
When the Mac is not reachable the note stays queued and the ``sam-capture`` worker sends it later (backoff 2, 5, 15,
60, 300 s, and at once when the bridge answers again); a note the Mac is still working on is followed until it is
done. Outcomes that arrive after the app was answered are published as one silent ``capture.routed`` announcement
(the app shows a chip and acknowledges it "seen"; nothing is ever spoken).

The capture id (a UUID the app makes when recording starts) is the idempotency key end to end: the app may send the
same note again, the bridge keeps one note per id. Transcripts are never logged (ids, states and lengths only).
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import UTC, datetime
import re
import sqlite3
import threading
import time
import uuid

from sam_runtime.core.logging import runtime_logger
from sam_runtime.domains.bridge_calls import BridgeCallFailure
from sam_runtime.storage.announcements import AnnouncementRepository
from sam_runtime.storage.database import RuntimeDatabase
from sam_runtime.storage.json_settings import JsonSetting

from . import outcome as lines
from .client import CaptureBridgeClient, permanent

OUTBOX_KEY = "capture.outbox"
RECENT_KEY = "capture.recent"
KIND_ROUTED = "capture.routed"
MAX_OUTBOX = 50
MAX_RECENT = 30
MAX_TEXT_CHARS = 8000
INLINE_WAIT_SECONDS = 8
FOLLOW_WAIT_SECONDS = 8
FOLLOW_FOR_SECONDS = 10 * 60.0
BACKOFF_SECONDS = (2, 5, 15, 60, 300)
# A bridge that refuses the R1 (token, outdated route, not paired) is not retried fast; a re-pairing wakes it.
SLOW_CODES = frozenset({"mac_unauthorized", "mac_token_unavailable", "bridge_outdated", "mac_not_configured"})
TRIGGERS = frozenset({"triple_press", "hold", "tap", "debug"})
WAKE_DEBOUNCE_SECONDS = 5.0
_CAPTURE_ID = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
_LOG = runtime_logger()


class CaptureRejected(ValueError):
    """The app sent something that is not a voice note (400)."""


def backoff_seconds(attempts: int) -> int:
    return BACKOFF_SECONDS[min(max(attempts, 1), len(BACKOFF_SECONDS)) - 1]


@dataclass
class PendingCapture:
    capture_id: str
    text: str
    captured_at: str
    duration_ms: int
    trigger: str
    created_at: float
    state: str = "queued"          # queued (not yet with the Mac) | sent (the Mac has it, outcome pending)
    attempts: int = 0
    next_at: float = 0.0
    last_error: str | None = None
    sent_at: float | None = None

    def record(self) -> dict[str, object]:
        return {"captureId": self.capture_id, "text": self.text, "capturedAt": self.captured_at,
                "durationMs": self.duration_ms, "trigger": self.trigger, "createdAt": self.created_at,
                "state": self.state, "attempts": self.attempts, "nextAt": self.next_at,
                "lastError": self.last_error, "sentAt": self.sent_at}

    @staticmethod
    def from_record(record: object) -> "PendingCapture | None":
        if not isinstance(record, dict):
            return None
        capture_id = record.get("captureId")
        text = record.get("text")
        if not isinstance(capture_id, str) or not _CAPTURE_ID.match(capture_id) or not isinstance(text, str):
            return None
        state = record.get("state") if record.get("state") in ("queued", "sent") else "queued"
        return PendingCapture(
            capture_id=capture_id.lower(), text=text, captured_at=str(record.get("capturedAt") or ""),
            duration_ms=_int(record.get("durationMs")), trigger=str(record.get("trigger") or "other"),
            created_at=_number(record.get("createdAt")), state=state, attempts=_int(record.get("attempts")),
            next_at=_number(record.get("nextAt")), last_error=_text(record.get("lastError")),
            sent_at=_number(record.get("sentAt")) or None)


@dataclass
class FinishedCapture:
    capture_id: str
    state: str                     # done | sent | failed
    say: str
    kind: str = ""
    outcome: dict[str, object] | None = None
    suggestion: str | None = None
    finished_at: float = field(default_factory=time.time)

    def view(self) -> dict[str, object]:
        value: dict[str, object] = {"captureId": self.capture_id, "state": self.state, "say": self.say,
                                    "kind": self.kind, "finishedAt": _iso(self.finished_at)}
        if self.outcome is not None:
            value["outcome"] = self.outcome
        if self.suggestion:
            value["suggestion"] = self.suggestion
        return value

    @staticmethod
    def from_record(record: object) -> "FinishedCapture | None":
        if not isinstance(record, dict) or not isinstance(record.get("captureId"), str):
            return None
        outcome = record.get("outcome") if isinstance(record.get("outcome"), dict) else None
        return FinishedCapture(str(record["captureId"]), str(record.get("state") or "done"),
                               str(record.get("say") or ""), str(record.get("kind") or ""), outcome,
                               _text(record.get("suggestion")), _number(record.get("finishedAt")) or time.time())

    def record(self) -> dict[str, object]:
        return {"captureId": self.capture_id, "state": self.state, "say": self.say, "kind": self.kind,
                "outcome": self.outcome, "suggestion": self.suggestion, "finishedAt": self.finished_at}


class CaptureService:
    def __init__(self, client: CaptureBridgeClient, database: RuntimeDatabase,
                 announcements: AnnouncementRepository, *, clock: Callable[[], float] = time.time) -> None:
        self._client = client
        self._announcements = announcements
        self._clock = clock
        self._outbox_setting = JsonSetting(database, OUTBOX_KEY)
        self._recent_setting = JsonSetting(database, RECENT_KEY)
        self._lock = threading.Lock()
        self._wake = threading.Condition(self._lock)
        self._outbox: dict[str, PendingCapture] = {}
        self._recent: list[FinishedCapture] = []
        self._in_flight: set[str] = set()
        self._loaded = False
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
        self._thread = threading.Thread(target=self._run, name="sam-capture", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        with self._wake:
            self._wake.notify_all()
        if self._thread is not None:
            self._thread.join(timeout=3.0)
            self._thread = None

    def wake(self) -> None:
        """The bridge was (re)paired or answered someone: queued notes go now (debounced)."""
        now = self._clock()
        with self._wake:
            if now - self._last_wake < WAKE_DEBOUNCE_SECONDS:
                return
            queued = [item for item in self._outbox.values() if item.state == "queued" and item.next_at > now]
            if not queued:
                return
            self._last_wake = now
            for item in queued:
                item.next_at = now
            self._wake.notify_all()

    # ------------------------------------------------------------------ API
    def submit(self, payload: dict[str, object]) -> dict[str, object]:
        """Stores the note, tries the Mac, and answers ``{captureId, state, say, kind?, outcome?}``."""
        capture = self._validated(payload)
        self._load()
        with self._lock:
            done = self._finished(capture.capture_id)
            if done is not None:
                return done.view()
            existing = self._outbox.get(capture.capture_id)
            if existing is None:
                self._trim_outbox_locked()
                capture.next_at = self._clock()
                self._outbox[capture.capture_id] = capture
                if not self._save_locked():
                    _LOG.warning("capture.outbox_unsaved", extra={"captureId": capture.capture_id})
                _LOG.info("capture.received", extra={"captureId": capture.capture_id, "chars": len(capture.text),
                                                     "trigger": capture.trigger})
            else:
                capture = existing
        if not self._claim(capture.capture_id):
            return self.view(capture.capture_id) or {"captureId": capture.capture_id, "state": "queued",
                                                     "say": lines.QUEUED_LINE}
        try:
            return self._process(capture, inline=True)
        finally:
            self._release(capture.capture_id)

    def view(self, capture_id: str) -> dict[str, object] | None:
        self._load()
        key = capture_id.lower()
        with self._lock:
            done = self._finished(key)
            if done is not None:
                return done.view()
            pending = self._outbox.get(key)
            return None if pending is None else self._pending_view(pending)

    def summary(self, limit: int = 10) -> dict[str, object]:
        self._load()
        with self._lock:
            queued = sum(1 for item in self._outbox.values() if item.state == "queued")
            sending = sum(1 for item in self._outbox.values() if item.state == "sent")
            recent = [item.view() for item in reversed(self._recent[-max(1, min(limit, MAX_RECENT)):])]
        return {"queued": queued, "sending": sending, "recent": recent}

    def run_due(self) -> int:
        """Sends or follows every note that is due; returns how many finished. Used by the worker and tests."""
        self._load()
        now = self._clock()
        with self._lock:
            due = [item for item in self._outbox.values() if item.next_at <= now and item.capture_id not in self._in_flight]
        finished = 0
        for item in sorted(due, key=lambda value: value.created_at):
            if self._stop.is_set() or not self._claim(item.capture_id):
                continue
            try:
                view = self._process(item, inline=False)
            except Exception:  # noqa: BLE001 - one bad note never stops the others
                _LOG.exception("capture.process_failed")
                continue
            finally:
                self._release(item.capture_id)
            if view.get("state") in ("done", "failed") or item.capture_id not in self._outbox:
                finished += 1
        return finished

    def pending_count(self) -> int:
        self._load()
        with self._lock:
            return len(self._outbox)

    # ------------------------------------------------------------------ work
    def _process(self, capture: PendingCapture, *, inline: bool) -> dict[str, object]:
        if capture.state == "sent":
            return self._follow(capture, wait=INLINE_WAIT_SECONDS if inline else FOLLOW_WAIT_SECONDS, inline=inline)
        try:
            result = self._client.submit(capture.capture_id, capture.text, capture.captured_at)
        except BridgeCallFailure as failure:
            if permanent(failure):
                _LOG.warning("capture.refused", extra={"captureId": capture.capture_id, "code": failure.code})
                return self._finish(capture, "failed", lines.FAILED_LINE, None, announce=not inline)
            return self._requeue(capture, failure.code)
        with self._lock:
            capture.state = "sent"
            capture.sent_at = self._clock()
            capture.last_error = None
            self._save_locked()
        _LOG.info("capture.sent", extra={"captureId": capture.capture_id, "state": lines.bridge_state(result)})
        if lines.finished(result):
            return self._finish_result(capture, result, announce=not inline)
        return self._follow(capture, wait=INLINE_WAIT_SECONDS if inline else FOLLOW_WAIT_SECONDS, inline=inline)

    def _follow(self, capture: PendingCapture, *, wait: int, inline: bool) -> dict[str, object]:
        try:
            result = self._client.status(capture.capture_id, wait=wait)
        except BridgeCallFailure as failure:
            if failure.code == "bridge_outdated" or failure.status == 404:
                # Received, but this bridge cannot report the outcome: the note is safe on the Mac.
                return self._finish(capture, "sent", lines.SENT_LINE, None, announce=False)
            return self._later(capture, inline=inline)
        if lines.finished(result):
            return self._finish_result(capture, result, announce=not inline)
        return self._later(capture, inline=inline)

    def _later(self, capture: PendingCapture, *, inline: bool) -> dict[str, object]:
        now = self._clock()
        if capture.sent_at is not None and now - capture.sent_at > FOLLOW_FOR_SECONDS:
            return self._finish(capture, "sent", lines.SENT_LINE, None, announce=False)
        with self._lock:
            capture.next_at = now + (2.0 if inline else 3.0)
            self._save_locked()
        return self._pending_view(capture)

    def _requeue(self, capture: PendingCapture, code: str) -> dict[str, object]:
        with self._lock:
            capture.attempts += 1
            capture.last_error = code
            delay = backoff_seconds(capture.attempts)
            if code in SLOW_CODES:
                delay = max(delay, 60)
            capture.next_at = self._clock() + delay
            self._save_locked()
            self._wake.notify_all()
        _LOG.info("capture.queued", extra={"captureId": capture.capture_id, "code": code,
                                           "attempts": capture.attempts})
        return self._pending_view(capture)

    def _finish_result(self, capture: PendingCapture, result: dict[str, object], *, announce: bool
                       ) -> dict[str, object]:
        state = "failed" if lines.bridge_state(result) == "failed" else "done"
        return self._finish(capture, state, lines.line(result), result, announce=announce)

    def _finish(self, capture: PendingCapture, state: str, say: str, result: dict[str, object] | None, *,
                announce: bool) -> dict[str, object]:
        suggestion = None
        if result is not None:
            raw = result.get("suggestion")
            suggestion = lines.flat(raw.get("label"), 60) if isinstance(raw, dict) else (lines.flat(raw, 60) or None)
        done = FinishedCapture(capture.capture_id, state, say, lines.kind(result or {}),
                               lines.app_outcome(result or {}), suggestion or None, self._clock())
        with self._lock:
            self._outbox.pop(capture.capture_id, None)
            self._recent = [item for item in self._recent if item.capture_id != capture.capture_id][-(MAX_RECENT - 1):]
            self._recent.append(done)
            self._save_locked()
        _LOG.info("capture.finished", extra={"captureId": capture.capture_id, "state": state, "kind": done.kind})
        if announce and state in ("done", "failed"):
            try:
                self._announcements.publish(KIND_ROUTED, "Voice note", say, done.view())
            except sqlite3.Error:
                _LOG.warning("capture.announce_failed")
        return done.view()

    def _pending_view(self, capture: PendingCapture) -> dict[str, object]:
        if capture.state == "sent":
            return {"captureId": capture.capture_id, "state": "sent", "say": lines.SENT_LINE}
        return {"captureId": capture.capture_id, "state": "queued",
                "say": lines.queued_line(capture.last_error or ""), "error": capture.last_error}

    def _run(self) -> None:
        while not self._stop.is_set():
            try:
                self.run_due()
            except Exception:  # noqa: BLE001 - keep the outbox moving
                _LOG.exception("capture.worker_failed")
            with self._wake:
                if self._stop.is_set():
                    break
                upcoming = [item.next_at for item in self._outbox.values() if item.capture_id not in self._in_flight]
                delay = min(upcoming) - self._clock() if upcoming else 300.0
                self._wake.wait(timeout=max(0.2, min(300.0, delay)))

    # ------------------------------------------------------------------ state
    def _validated(self, payload: dict[str, object]) -> PendingCapture:
        capture_id = payload.get("captureId")
        if not isinstance(capture_id, str) or not _CAPTURE_ID.match(capture_id.strip()):
            raise CaptureRejected("captureId must be a UUID made when recording started.")
        text = payload.get("text")
        words = " ".join(text.split()) if isinstance(text, str) else ""
        if not words:
            raise CaptureRejected("text is required.")
        if len(words) > MAX_TEXT_CHARS:
            raise CaptureRejected(f"text is limited to {MAX_TEXT_CHARS} characters.")
        captured_at = payload.get("capturedAt")
        if not isinstance(captured_at, str) or _parsed(captured_at) is None:
            raise CaptureRejected("capturedAt must be an ISO time with its offset.")
        trigger = payload.get("trigger")
        return PendingCapture(capture_id=str(uuid.UUID(capture_id.strip())), text=words,
                              captured_at=captured_at.strip(), duration_ms=max(0, _int(payload.get("durationMs"))),
                              trigger=trigger if isinstance(trigger, str) and trigger in TRIGGERS else "other",
                              created_at=self._clock())

    def _finished(self, capture_id: str) -> FinishedCapture | None:
        for item in self._recent:
            if item.capture_id == capture_id:
                return item
        return None

    def _claim(self, capture_id: str) -> bool:
        with self._lock:
            if capture_id in self._in_flight:
                return False
            self._in_flight.add(capture_id)
            return True

    def _release(self, capture_id: str) -> None:
        with self._wake:
            self._in_flight.discard(capture_id)
            self._wake.notify_all()

    def _trim_outbox_locked(self) -> None:
        while len(self._outbox) >= MAX_OUTBOX:
            oldest = min(self._outbox.values(), key=lambda item: item.created_at)
            self._outbox.pop(oldest.capture_id, None)
            _LOG.warning("capture.outbox_full_dropped", extra={"captureId": oldest.capture_id})

    def _load(self) -> None:
        with self._lock:
            if self._loaded:
                return
        stored = self._outbox_setting.load()
        recent = self._recent_setting.load()
        with self._lock:
            if self._loaded:
                return
            self._loaded = True
            for record in stored if isinstance(stored, list) else []:
                item = PendingCapture.from_record(record)
                if item is not None:
                    self._outbox.setdefault(item.capture_id, item)
            known = {item.capture_id for item in self._recent}
            for record in recent if isinstance(recent, list) else []:
                item = FinishedCapture.from_record(record)
                if item is not None and item.capture_id not in known:
                    self._recent.append(item)
            self._recent = self._recent[-MAX_RECENT:]

    def _save_locked(self) -> bool:
        if not self._loaded:
            return False
        saved = self._outbox_setting.save([item.record() for item in self._outbox.values()])
        return self._recent_setting.save([item.record() for item in self._recent]) and saved


def _parsed(value: str) -> datetime | None:
    try:
        parsed = datetime.fromisoformat(value.strip().replace("Z", "+00:00"))
    except ValueError:
        return None
    return parsed if parsed.tzinfo is not None else None


def _iso(epoch: float) -> str:
    return datetime.fromtimestamp(epoch, UTC).isoformat(timespec="seconds").replace("+00:00", "Z")


def _int(value: object) -> int:
    return int(value) if isinstance(value, (int, float)) and not isinstance(value, bool) else 0


def _number(value: object) -> float:
    return float(value) if isinstance(value, (int, float)) and not isinstance(value, bool) else 0.0


def _text(value: object) -> str | None:
    return value if isinstance(value, str) and value else None
