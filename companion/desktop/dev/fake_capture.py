"""The bridge's voice-note capture routes (CONTRACTS-WAVE8 §A2), with canned outcomes, for ``fake_sync_server.py``
(behind the desktop token and the loopback check the server already does). Nothing is transcribed, journaled, filed
in T3 or put on a calendar: it only says it did, in the bridge's words (``companion/mac-bridge/samrabbit_capture.py``).

* ``POST /v1/desktop/capture``: a recording (``audio/wav``, ``audio/mp4``, ``audio/x-m4a`` or ``audio/aac``; at most
  16 MiB and 300 s) or JSON ``{text}``, with ``X-SamRabbit-Capture`` (a UUID, required: the same id with the same bytes
  is the same note, with other bytes 409 ``capture_conflict``), ``X-SamRabbit-Captured-At`` and
  ``X-SamRabbit-Source`` (``r1`` | ``iphone`` | ``watch`` | ``mac``) -> 202 with the note as below (``state:
  "received"``).
* ``GET /v1/desktop/capture/<id>?wait=0..10`` -> ``{captureId, state: received | transcribed | done | failed, source,
  kind: audio | text, capturedAt, receivedAt, updatedAt, heard, outcome: {kind: journal | task | event | note | nothing
  | failed, title, detail, threadId?, eventId?, noteId?, journalDate?}, suggestion?: {action, label}, say, seen,
  dismissed, error?}``: "received" until ``delay`` seconds after it came (a wait blocks until then), then what the
  script says it heard and did (in turn: a journal line, a T3 task, a note with a suggestion, a calendar entry).
* ``GET /v1/desktop/captures?limit=`` (newest first) and ``POST /v1/desktop/captures/<id>/act {action}`` (``task``,
  ``journal``, ``event``, ``note``, ``undo``, ``dismiss``, ``seen``, ``retry``; a note not done yet 409
  ``capture_not_ready``, undoing a journal line or a task 409 ``cannot_undo``).
* In the inbox (``fake_sync_server.py``, ``POST /dev/inbox/notes``): two voice notes as the bridge lists them
  (``samrabbit_capture`` ``inbox_items``: ``note:<captureId>``, one kept with a suggestion, one that failed, ``can``
  act/dismiss/seen) and their ``act``/``seen`` (``note_inbox_action``, as the bridge's ``inbox_action``).
* Dev controls: ``POST /dev/capture {mode?, delay?, hold?, script?}`` (modes ``ok``, ``outdated`` (404: a bridge
  without voice notes), ``busy`` (503), ``refuse`` (401), ``no_speech``, ``fail``; ``hold``: seconds each upload's
  answer waits, a slow bridge; ``script``: ``[{heard, kind, title?, detail?, suggestion?}]``), ``GET /dev/capture``
  (what arrived: ids, sources, times, content types, byte counts and lengths, never the audio; ``polls``: the
  outcome reads), ``POST /dev/capture/reset``. With ``$SAMRABBIT_FAKE_CAPTURE_SAVE`` set to a folder each
  recording is also saved there (``capture-<n>.wav``) for the voice tests to transcribe.

Stdlib only.
"""

from __future__ import annotations

import hashlib
import io
import json
import os
import re
import threading
import time
import uuid
import wave
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional, Tuple
from urllib.parse import parse_qs, unquote

MAX_BYTES = 16 * 1024 * 1024
MAX_SECONDS = 300.5
MAX_TEXT = 8000
AUDIO_TYPES = ("audio/wav", "audio/x-wav", "audio/wave", "audio/mp4", "audio/x-m4a", "audio/aac")
MODES = ("ok", "outdated", "busy", "refuse", "no_speech", "fail")
ACTIONS = ("task", "journal", "event", "note", "undo", "dismiss", "seen", "retry")
SOURCES = ("r1", "iphone", "watch", "mac")
_UUID = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
SCRIPT: List[Dict[str, Any]] = [
    {"heard": "Put this in my journal: shipped the voice notes on the Mac today.", "kind": "journal",
     "title": "Journal", "detail": "Added to your journal."},
    {"heard": "Make a new task: fix the flaky long-poll test in the bridge suite.", "kind": "task",
     "title": "Fix the flaky long-poll test in the bridge suite",
     "detail": "Started “Fix the flaky long-poll test in the bridge suite” in SamRabbit."},
    {"heard": "Call the bank about the replacement card.", "kind": "note",
     "title": "Call the bank about the replacement card.", "detail": "Saved as a note.",
     "suggestion": {"action": "task", "label": "Start it as a T3 task?"}},
    {"heard": "Remind me tomorrow at nine to send Dana the SOW.", "kind": "event",
     "title": "Send Dana the SOW", "detail": "Added “Send Dana the SOW” for tomorrow 9:00 AM."},
]


def title_from(text: str, limit: int = 60) -> str:
    """The bridge's ``t3.title_from_prompt``."""
    flat = " ".join(str(text).split())
    if len(flat) <= limit:
        return flat or "New task"
    cut = flat[:limit]
    space = cut.rfind(" ")
    if space > limit * 0.5:
        cut = cut[:space]
    return cut.rstrip(" ,;:-.") + "…"


class Refusal(Exception):
    def __init__(self, status: int, code: str, message: str, retryable: bool = False) -> None:
        super().__init__(message)
        self.status, self.code, self.message, self.retryable = status, code, message, retryable


def iso_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")[:-4] + "Z"


def wav_seconds(body: bytes) -> Optional[float]:
    try:
        with wave.open(io.BytesIO(body), "rb") as clip:
            return clip.getnframes() / float(clip.getframerate() or 1)
    except (wave.Error, EOFError, ValueError):
        return None


class FakeCapture:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.changed = threading.Condition(self.lock)
        self.save = os.environ.get("SAMRABBIT_FAKE_CAPTURE_SAVE")
        self.reset()

    def reset(self) -> None:
        with self.lock:
            self.mode = "ok"
            self.delay = 1.2
            self.hold = 0.0
            self.polls = 0
            self.script = [dict(item) for item in SCRIPT]
            self.turn = 0
            self.captures: Dict[str, Dict[str, Any]] = {}
            self.order: List[str] = []
            self.log: List[Dict[str, Any]] = []
            self.acts: List[Dict[str, Any]] = []

    @staticmethod
    def handles(path: str) -> bool:
        return path in ("/v1/desktop/capture", "/v1/desktop/captures", "/dev/capture", "/dev/capture/reset") \
            or path.startswith(("/v1/desktop/capture/", "/v1/desktop/captures/"))

    # ------------------------------------------------------------------ dispatch

    def handle(self, handler: Any, method: str, path: str, query: str) -> None:
        try:
            if path == "/dev/capture/reset":
                self.only(method, "POST")
                self.json_body(handler)  # read, so a kept-alive connection's next request starts clean
                self.reset()
                return handler.json(200, {"ok": True})
            if path == "/dev/capture":
                if method == "POST":
                    return handler.json(200, self.dev(self.json_body(handler)))
                self.only(method, "GET")
                return handler.json(200, self.arrived())
            self.gate()
            if path == "/v1/desktop/capture":
                self.only(method, "POST")
                status, payload = self.receive(handler)
                if self.hold:
                    time.sleep(self.hold)  # a slow bridge: the answer comes late (outside the lock)
                return handler.json(status, payload)
            if path.startswith("/v1/desktop/capture/"):
                self.only(method, "GET")
                capture_id = unquote(path[len("/v1/desktop/capture/"):])
                wait = self.number(parse_qs(query).get("wait"), 0, 10)
                return handler.json(200, self.status(capture_id, wait))
            if path == "/v1/desktop/captures":
                self.only(method, "GET")
                limit = int(self.number(parse_qs(query).get("limit"), 1, 50, default=20))
                return handler.json(200, self.recent(limit))
            if path.startswith("/v1/desktop/captures/") and path.endswith("/act"):
                self.only(method, "POST")
                capture_id = unquote(path[len("/v1/desktop/captures/"):-len("/act")])
                return handler.json(200, self.act(capture_id, self.json_body(handler)))
            raise Refusal(404, "not_found", "Not found.")
        except Refusal as refusal:
            handler.json(refusal.status, {"error": {"code": refusal.code, "message": refusal.message,
                                                    "retryable": refusal.retryable}})

    def gate(self) -> None:
        mode = self.mode
        if mode == "outdated":
            raise Refusal(404, "not_found", "Not found.")
        if mode == "busy":
            raise Refusal(503, "capture_unavailable", "The bridge is busy.", True)
        if mode == "refuse":
            raise Refusal(401, "unauthorized", "Desktop token required.")

    @staticmethod
    def only(method: str, allowed: str) -> None:
        if method != allowed:
            raise Refusal(405, "method_not_allowed", "Method not allowed.")

    @staticmethod
    def number(values: Optional[List[str]], low: float, high: float, default: float = 0) -> float:
        try:
            value = float((values or [""])[0])
        except ValueError:
            return default
        return max(low, min(high, value))

    @staticmethod
    def read(handler: Any, limit: int) -> bytes:
        try:
            length = int(handler.headers.get("Content-Length") or 0)
        except ValueError:
            length = 0
        if length > limit:
            handler.close_connection = True
            raise Refusal(413, "body_too_large", "At most %d bytes." % limit)
        return handler.rfile.read(length) if length > 0 else b""

    def json_body(self, handler: Any) -> Dict[str, Any]:
        raw = self.read(handler, 65536)
        if not raw:
            return {}
        try:
            value = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            raise Refusal(400, "invalid_json", "Send a JSON object.")
        if not isinstance(value, dict):
            raise Refusal(400, "invalid_json", "Send a JSON object.")
        return value

    # ------------------------------------------------------------------ routes

    def receive(self, handler: Any) -> Any:
        capture_id = (handler.headers.get("X-SamRabbit-Capture") or "").strip()
        if not _UUID.match(capture_id):
            raise Refusal(400, "invalid_capture_id", "X-SamRabbit-Capture must be a UUID.")
        capture_id = capture_id.lower()
        kind = (handler.headers.get("Content-Type") or "").split(";")[0].strip().lower()
        body = self.read(handler, MAX_BYTES)
        text = None
        seconds = None
        if kind == "application/json":
            try:
                value = json.loads(body.decode("utf-8"))
            except (UnicodeDecodeError, ValueError):
                raise Refusal(400, "invalid_json", "Send {text}.")
            text = value.get("text") if isinstance(value, dict) else None
            if not isinstance(text, str) or not text.strip() or len(text) > MAX_TEXT:
                raise Refusal(400, "invalid_text", "text must be the note (at most %d characters)." % MAX_TEXT)
        elif kind in AUDIO_TYPES:
            if not body:
                raise Refusal(400, "unsupported_audio", "The recording is empty.")
            if "wav" in kind or "wave" in kind:
                seconds = wav_seconds(body)
                if seconds is None:
                    raise Refusal(415, "unsupported_audio", "That is not a WAV file.")
                if seconds > MAX_SECONDS:
                    raise Refusal(400, "audio_too_long", "Five minutes at most.")
        else:
            raise Refusal(415, "unsupported_audio", "Send audio/wav, audio/mp4, audio/aac or JSON {text}.")
        source = (handler.headers.get("X-SamRabbit-Source") or "").strip().lower()
        if source and source not in SOURCES:
            raise Refusal(400, "invalid_source", "X-SamRabbit-Source must be r1, iphone, watch or mac.")
        digest = hashlib.sha256(body).hexdigest()
        with self.lock:
            known = self.captures.get(capture_id)
            if known is not None:
                if known["digest"] != digest:
                    raise Refusal(409, "capture_conflict", "This id already has another note.")
                known["repeats"] += 1
                view = self.public(known)
                return (200 if view["state"] in ("done", "failed") else 202), view
            now = time.time()
            entry = self.script[self.turn % len(self.script)] if self.script else {"heard": text or "", "kind": "note"}
            self.turn += 1
            capture = {
                "captureId": capture_id, "digest": digest, "receivedAt": now, "readyAt": now + self.delay,
                "receivedIso": iso_now(), "mode": self.mode, "entry": dict(entry), "text": text, "repeats": 0,
                "acted": None, "source": source or "mac", "kind": "text" if text is not None else "audio",
                "capturedAt": handler.headers.get("X-SamRabbit-Captured-At") or iso_now(), "seen": False,
                "dismissed": False,
            }
            self.captures[capture_id] = capture
            self.order.insert(0, capture_id)
            self.log.append({
                "captureId": capture_id, "contentType": kind, "bytes": len(body),
                "seconds": round(seconds, 2) if seconds is not None else None,
                "source": handler.headers.get("X-SamRabbit-Source"),
                "capturedAt": handler.headers.get("X-SamRabbit-Captured-At"), "text": text is not None,
            })
            if self.save and kind != "application/json":
                os.makedirs(self.save, exist_ok=True)
                with open(os.path.join(self.save, "capture-%d.wav" % len(self.log)), "wb") as out:
                    out.write(body)
            self.changed.notify_all()
            return 202, self.public(capture)

    def public(self, capture: Dict[str, Any]) -> Dict[str, Any]:
        """The note as the bridge's ``view()`` shows it."""
        now = time.time()
        base = {"captureId": capture["captureId"], "source": capture["source"], "kind": capture["kind"],
                "capturedAt": capture["capturedAt"], "receivedAt": capture["receivedIso"], "updatedAt": iso_now(),
                "seen": capture["seen"], "dismissed": capture["dismissed"]}
        if now < capture["readyAt"]:
            state = "transcribed" if capture["text"] is not None else "received"
            return dict(base, state=state, heard=capture["text"], outcome=None, suggestion=None, say="Sent.")
        entry = capture["entry"]
        heard = capture["text"] or entry.get("heard") or ""
        if capture["mode"] == "no_speech":
            outcome = {"kind": "nothing", "title": "Nothing heard", "detail": "I didn't catch anything."}
            return dict(base, state="done", heard="", outcome=outcome, suggestion=None, say=outcome["detail"])
        if capture["mode"] == "fail":
            outcome = {"kind": "failed", "title": "Voice note", "detail": "Couldn't save it: T3 Code isn't connected."}
            return dict(base, state="failed", heard=heard, outcome=outcome, suggestion=None, say=outcome["detail"],
                        error={"code": "t3_not_connected", "message": "T3 Code isn't connected."})
        kind = capture["acted"] or entry.get("kind") or "note"
        outcome: Dict[str, Any] = {"kind": kind, "title": entry.get("title") or title_from(heard),
                                   "detail": entry.get("detail") or ""}
        if capture["acted"] and capture["acted"] != entry.get("kind"):
            # Done another way on Samin's tap: named by what he said, in the bridge's words.
            title = title_from(heard)
            outcome = {"kind": kind, "title": title, "detail": {
                "task": "Started “%s” in SamRabbit." % title, "journal": "Added to your journal.",
                "event": "Added “%s” for tomorrow 9:00 AM." % title,
                "note": "Saved as a note."}.get(kind, "")}
            if kind == "journal":
                outcome["title"] = "Journal"
        if kind == "task":
            outcome.update(threadId="th_note_%s" % capture["captureId"][:8], projectName="SamRabbit")
        elif kind == "event":
            outcome["eventId"] = "ev_note_%s" % capture["captureId"][:8]
        elif kind == "note":
            outcome["noteId"] = "note:%s" % capture["captureId"]
        elif kind == "journal":
            outcome.update(journalDate=capture["capturedAt"][:10], time=capture["capturedAt"][11:16])
        suggested = kind == "note" and entry.get("suggestion") and not capture["acted"]
        return dict(base, state="done", heard=heard, outcome=outcome,
                    suggestion=dict(entry["suggestion"]) if suggested else None, say=outcome["detail"] or None)

    def status(self, capture_id: str, wait: float) -> Dict[str, Any]:
        deadline = time.time() + wait
        with self.lock:
            self.polls += 1
            capture = self.captures.get(capture_id.lower())
            if capture is None:
                raise Refusal(404, "capture_not_found", "No such capture.")
            while time.time() < min(deadline, capture["readyAt"]):
                self.changed.wait(timeout=max(0.01, min(deadline, capture["readyAt"]) - time.time()))
            return self.public(capture)

    def recent(self, limit: int) -> Dict[str, Any]:
        with self.lock:
            every = [self.public(self.captures[i]) for i in self.order]
        return {"captures": every[:limit], "pending": sum(1 for c in every if c["state"] not in ("done", "failed")),
                "updatedAt": iso_now()}

    def act(self, capture_id: str, body: Dict[str, Any]) -> Dict[str, Any]:
        """As the bridge's ``act``: the note done another way (``task``, ``journal``, ``event``, ``note``), ``undo``,
        ``dismiss``, ``seen``, ``retry``; the answer is the note."""
        action = body.get("action")
        if action not in ACTIONS:
            raise Refusal(400, "invalid_action", "action must be one of %s." % ", ".join(ACTIONS))
        with self.lock:
            capture = self.captures.get(capture_id.lower())
            if capture is None:
                raise Refusal(404, "capture_not_found", "There is no such voice note.")
            self.acts.append({"captureId": capture["captureId"], "action": action})
            if action in ("seen", "dismiss"):
                capture["seen"] = True
                capture["dismissed"] = capture["dismissed"] or action == "dismiss"
                return self.public(capture)
            view = self.public(capture)
            if action == "retry":
                if view["state"] != "failed":
                    raise Refusal(409, "not_failed", "Only a note that failed can be tried again.")
                capture["mode"] = "ok"
                capture["readyAt"] = time.time() + self.delay
                return self.public(capture)
            if view["state"] != "done" or not view["heard"]:
                raise Refusal(409, "capture_not_ready", "That note isn't finished yet.", True)
            kind = (view["outcome"] or {}).get("kind")
            if action == "undo":
                if kind == "journal":
                    raise Refusal(409, "cannot_undo", "A journal line can't be taken back from here: remove it in Heptabase.")
                if kind == "task":
                    raise Refusal(409, "cannot_undo", "A task that started can't be taken back from here: stop it in Tasks.")
                if kind == "event":
                    capture["acted"] = "note"
                else:
                    capture["dismissed"] = capture["seen"] = True
                return self.public(capture)
            if action != kind:
                capture["acted"] = action
            capture["seen"] = True
            return self.public(capture)

    def summary(self) -> Dict[str, Any]:
        """``summary.captures``, as the bridge's ``summary_part()``."""
        with self.lock:
            every = [self.public(self.captures[i]) for i in self.order]
        recent = [{"captureId": c["captureId"], "state": c["state"], "kind": (c["outcome"] or {}).get("kind"),
                   "title": (c["outcome"] or {}).get("title"), "say": (c["outcome"] or {}).get("detail"),
                   "at": c["capturedAt"]} for c in every[:3]]
        return {"available": True, "recent": recent,
                "failed": sum(1 for c in every if c["state"] == "failed" and not c["dismissed"]),
                "pending": sum(1 for c in every if c["state"] not in ("done", "failed")),
                "notes": sum(1 for c in every if (c["outcome"] or {}).get("kind") == "note" and not c["dismissed"])}

    # ------------------------------------------------------------------ dev controls

    def dev(self, body: Dict[str, Any]) -> Dict[str, Any]:
        with self.lock:
            if body.get("mode") in MODES:
                self.mode = body["mode"]
            if isinstance(body.get("delay"), (int, float)) and not isinstance(body.get("delay"), bool):
                self.delay = max(0.0, min(30.0, float(body["delay"])))
            if isinstance(body.get("hold"), (int, float)) and not isinstance(body.get("hold"), bool):
                self.hold = max(0.0, min(10.0, float(body["hold"])))
            if isinstance(body.get("script"), list):
                self.script = [dict(item) for item in body["script"] if isinstance(item, dict)]
                self.turn = 0
            return {"ok": True, "mode": self.mode, "delay": self.delay, "hold": self.hold}

    def arrived(self) -> Dict[str, Any]:
        with self.lock:
            return {"fake": True, "mode": self.mode, "captures": [dict(item) for item in self.log],
                    "repeats": sum(c["repeats"] for c in self.captures.values()), "acts": list(self.acts),
                    "polls": self.polls}


def new_capture_id() -> str:
    return str(uuid.uuid4())


KEPT_NOTE = "note:3f2b8c1e-7d4a-4e9b-8f21-6a5c0d9e1b47"
FAILED_NOTE = "note:9c4e2a7b-1f3d-4b8e-a6c5-2d7f0e8b3a91"
NOTE_ACTS = {"task": "task", "t3_task": "task", "journal": "journal", "event": "event"}


def note_items(now_ms: int) -> List[Dict[str, Any]]:
    """Two voice notes in the inbox, in the bridge's shape (``samrabbit_capture.CaptureService.inbox_items``)."""
    def at(minutes: float) -> str:
        return datetime.fromtimestamp(now_ms / 1000 - minutes * 60, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    def item(item_id: str, **fields: Any) -> Dict[str, Any]:
        base = {"id": item_id, "source": "note", "agent": None, "project": "Voice note", "cwd": None,
                "unread": True, "pending": {"approvals": [], "inputs": []}, "can": ["act", "dismiss", "seen"],
                "live": False, "progress": None, "phase": None, "captureId": item_id[5:]}
        base.update(fields)
        return base
    return [
        item(KEPT_NOTE, title="Look into why the watch build is slow", status="needs-input",
             statusLabel="Start it as a T3 task?", summary="Look into why the watch build is slow on the release machine.",
             updatedAt=at(3), capturedAt=at(3), suggestion={"action": "task", "label": "Start it as a T3 task?"},
             _messages=[{"role": "user", "text": "Look into why the watch build is slow on the release machine.",
                         "at": at(3)}, {"role": "assistant", "text": "Saved as a note.", "at": at(2.9)}]),
        item(FAILED_NOTE, title="Voice note", status="error", statusLabel="Couldn't hear it",
             summary="Couldn't save it: transcription is not installed on the Mac bridge.", updatedAt=at(41),
             capturedAt=at(41), suggestion=None,
             _messages=[{"role": "assistant", "text": "Couldn't save it: transcription is not installed on the Mac "
                                                      "bridge.", "at": at(41)}]),
    ]


def note_inbox_action(item: Dict[str, Any], action: str, body: Dict[str, Any]) -> Tuple[int, Dict[str, Any], bool]:
    """``POST /v1/desktop/inbox/items/note:<id>/act|seen`` as ``samrabbit_capture.inbox_action``: ``act`` does the
    suggestion (or ``body.action``), a failed note is tried again; ``seen``. Returns (status, answer, gone): a note done
    another way, or tried again, leaves the inbox. Nothing is journaled, filed or put on a calendar."""
    capture = {"captureId": item["captureId"], "state": "done", "seen": True, "dismissed": False}
    if action == "seen":
        item["unread"] = False
        if item.get("status") == "needs-input":
            item["status"] = "idle"
        return 200, {"ok": True, "capture": capture}, False
    if action != "act":
        raise Refusal(409, "unsupported", "A voice note can be acted on, dismissed or marked seen.")
    chosen = body.get("action") or (item.get("suggestion") or {}).get("action") or \
        ("retry" if item.get("status") == "error" else None)
    if chosen == "retry":
        if item.get("status") != "error":
            raise Refusal(409, "not_failed", "Only a note that failed can be tried again.")
        return 202, {"ok": True, "capture": dict(capture, state="received")}, True
    kind = NOTE_ACTS.get(str(chosen))
    if kind is None:
        raise Refusal(400, "invalid_action", "Say what to do with it: task, journal or event.")
    title = title_from(item.get("summary") or item.get("title") or "")
    detail = {"task": "Started “%s” in SamRabbit." % title, "journal": "Added to your journal.",
              "event": "Added “%s” for tomorrow 9:00 AM." % title}[kind]
    return 200, {"ok": True, "capture": dict(capture, outcome={"kind": kind, "title": title, "detail": detail})}, True
