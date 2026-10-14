"""The bridge's voice-note capture routes (CONTRACTS-WAVE8 §A2), with canned outcomes, for ``fake_sync_server.py``
(behind the desktop token and the loopback check the server already does). Nothing is transcribed, journaled, filed
in T3 or put on a calendar: it only says it did.

* ``POST /v1/desktop/capture``: a recording (``audio/wav``, ``audio/mp4``, ``audio/x-m4a`` or ``audio/aac``; at most
  16 MiB and 300 s) or JSON ``{text}``, with ``X-SamRabbit-Capture`` (a UUID, required: the same id with the same bytes
  is the same note, with other bytes 409 ``capture_conflict``), ``X-SamRabbit-Captured-At`` and
  ``X-SamRabbit-Source`` -> 202 ``{captureId, state: "received"}``.
* ``GET /v1/desktop/capture/<id>?wait=0..10`` -> ``{captureId, state, heard, outcome: {kind, title, detail,
  threadId?, eventId?, noteId?}, suggestion?, receivedAt, updatedAt}``: "received" until ``delay`` seconds after it
  came (a wait blocks until then), then what the script says it heard and did (in turn: a journal line, a T3 task, a
  note with a suggestion, a calendar entry).
* ``GET /v1/desktop/captures?limit=`` (newest first) and ``POST /v1/desktop/captures/<id>/act {action}`` (``task``,
  ``journal``, ``note``, ``dismiss``, ``undo``).
* Dev controls: ``POST /dev/capture {mode?, delay?, script?}`` (modes ``ok``, ``outdated`` (404: a bridge without
  voice notes), ``busy`` (503), ``refuse`` (401), ``no_speech``, ``fail``; ``script``: ``[{heard, kind, title?,
  detail?, suggestion?}]``), ``GET /dev/capture`` (what arrived: ids, sources, times, content types, byte counts and
  lengths, never the audio), ``POST /dev/capture/reset``. With ``$SAMRABBIT_FAKE_CAPTURE_SAVE`` set to a folder each
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
from typing import Any, Dict, List, Optional
from urllib.parse import parse_qs, unquote

MAX_BYTES = 16 * 1024 * 1024
MAX_SECONDS = 300.5
MAX_TEXT = 8000
AUDIO_TYPES = ("audio/wav", "audio/x-wav", "audio/wave", "audio/mp4", "audio/x-m4a", "audio/aac")
MODES = ("ok", "outdated", "busy", "refuse", "no_speech", "fail")
ACTIONS = ("task", "journal", "note", "dismiss", "undo")
_UUID = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
SCRIPT: List[Dict[str, Any]] = [
    {"heard": "Put this in my journal: shipped the voice notes on the Mac today.", "kind": "journal",
     "title": "Journal", "detail": "shipped the voice notes on the Mac today."},
    {"heard": "Make a new task: fix the flaky long-poll test in the bridge suite.", "kind": "t3_task",
     "title": "Fix the flaky long-poll test in the bridge suite", "detail": "SamRabbit"},
    {"heard": "Call the bank about the replacement card.", "kind": "note", "title": "Voice note",
     "detail": "Call the bank about the replacement card.",
     "suggestion": {"label": "Start it as a T3 task?", "action": "task"}},
    {"heard": "Remind me tomorrow at nine to send Dana the SOW.", "kind": "calendar_event",
     "title": "Reminder: send Dana the SOW", "detail": "Tomorrow 9:00 AM"},
]


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
        digest = hashlib.sha256(body).hexdigest()
        with self.lock:
            known = self.captures.get(capture_id)
            if known is not None:
                if known["digest"] != digest:
                    raise Refusal(409, "capture_conflict", "This id already has another note.")
                known["repeats"] += 1
                return 200, self.public(known)
            now = time.time()
            entry = self.script[self.turn % len(self.script)] if self.script else {"heard": text or "", "kind": "note"}
            self.turn += 1
            capture = {
                "captureId": capture_id, "digest": digest, "receivedAt": now, "readyAt": now + self.delay,
                "receivedIso": iso_now(), "mode": self.mode, "entry": dict(entry), "text": text, "repeats": 0,
                "acted": None,
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
            return 202, {"captureId": capture_id, "state": "received", "receivedAt": capture["receivedIso"]}

    def public(self, capture: Dict[str, Any]) -> Dict[str, Any]:
        now = time.time()
        base = {"captureId": capture["captureId"], "receivedAt": capture["receivedIso"], "updatedAt": iso_now()}
        if now < capture["readyAt"]:
            return dict(base, state="received", heard=None, outcome=None)
        entry = capture["entry"]
        heard = capture["text"] or entry.get("heard") or ""
        if capture["mode"] == "no_speech":
            return dict(base, state="no_speech", heard=None, outcome=None, say="I didn't catch anything.")
        if capture["mode"] == "fail":
            return dict(base, state="failed", heard=heard, outcome={"kind": "failed", "title": "Not done",
                                                                     "detail": "T3 Code isn't connected."},
                        error={"code": "t3_not_connected"})
        kind = capture["acted"] or entry.get("kind") or "note"
        outcome: Dict[str, Any] = {"kind": kind, "title": entry.get("title") or "", "detail": entry.get("detail") or ""}
        if capture["acted"] and capture["acted"] != entry.get("kind"):
            # Done another way on Samin's tap: named by what he said.
            outcome.update(title=heard[:80], detail="")
        if kind == "t3_task":
            outcome["threadId"] = "th_note_%s" % capture["captureId"][:8]
        elif kind == "calendar_event":
            outcome["eventId"] = "ev_note_%s" % capture["captureId"][:8]
        elif kind == "note":
            outcome["noteId"] = "note:%s" % capture["captureId"]
        suggested = kind == "note" and entry.get("suggestion") and not capture["acted"]
        payload = dict(base, state="needs_you" if suggested else "done", heard=heard, outcome=outcome)
        if suggested:
            payload["suggestion"] = dict(entry["suggestion"])
        return payload

    def status(self, capture_id: str, wait: float) -> Dict[str, Any]:
        deadline = time.time() + wait
        with self.lock:
            capture = self.captures.get(capture_id.lower())
            if capture is None:
                raise Refusal(404, "capture_not_found", "No such capture.")
            while time.time() < min(deadline, capture["readyAt"]):
                self.changed.wait(timeout=max(0.01, min(deadline, capture["readyAt"]) - time.time()))
            return self.public(capture)

    def recent(self, limit: int) -> Dict[str, Any]:
        with self.lock:
            items = [self.public(self.captures[i]) for i in self.order[:limit]]
        return {"captures": items, "failed": sum(1 for c in items if c["state"] == "failed")}

    def act(self, capture_id: str, body: Dict[str, Any]) -> Dict[str, Any]:
        action = body.get("action")
        if action not in ACTIONS:
            raise Refusal(400, "invalid_action", "action must be one of %s." % ", ".join(ACTIONS))
        with self.lock:
            capture = self.captures.get(capture_id.lower().split(":", 1)[-1])
            if capture is None:
                raise Refusal(404, "capture_not_found", "No such capture.")
            capture["acted"] = {"task": "t3_task", "journal": "journal", "note": "note"}.get(action, capture["acted"])
            self.acts.append({"captureId": capture["captureId"], "action": action})
            return {"ok": True, **self.public(capture)}

    def summary(self) -> Dict[str, Any]:
        with self.lock:
            states = [self.public(self.captures[i])["state"] for i in self.order[:20]]
        return {"recent": len(states), "failed": states.count("failed")}

    # ------------------------------------------------------------------ dev controls

    def dev(self, body: Dict[str, Any]) -> Dict[str, Any]:
        with self.lock:
            if body.get("mode") in MODES:
                self.mode = body["mode"]
            if isinstance(body.get("delay"), (int, float)) and not isinstance(body.get("delay"), bool):
                self.delay = max(0.0, min(30.0, float(body["delay"])))
            if isinstance(body.get("script"), list):
                self.script = [dict(item) for item in body["script"] if isinstance(item, dict)]
                self.turn = 0
            return {"ok": True, "mode": self.mode, "delay": self.delay}

    def arrived(self) -> Dict[str, Any]:
        with self.lock:
            return {"fake": True, "mode": self.mode, "captures": [dict(item) for item in self.log],
                    "repeats": sum(c["repeats"] for c in self.captures.values()), "acts": list(self.acts)}


def new_capture_id() -> str:
    return str(uuid.uuid4())
