"""The bridge's desktop voice routes (CONTRACTS-WAVE6 "Desktop voice routes"), with canned answers, for
``fake_sync_server.py``: the same bodies and streaming turn protocol as ``/v1/mobile/assistant/*`` (CONTRACTS-WAVE5),
behind the desktop token and the loopback check the server already does.

* ``POST /v1/desktop/assistant/session {conversationId?}`` -> ``{conversationId, brain, ready}``.
* ``POST /v1/desktop/assistant/turn``: an utterance (``audio/wav``, at most 2 MiB and 60 s) with
  ``X-SamRabbit-Conversation`` (an id, or empty for a new conversation), ``X-SamRabbit-Turn`` (a retry of a turn
  gets the same answer) and ``X-SamRabbit-Device-Time``; or JSON ``{text | announce, conversationId?, turnId}``.
  With ``Accept: application/x-samrabbit-stream`` the answer is 200 ``application/x-samrabbit-stream``, chunked:
  frames of 1 byte type, 4-byte big-endian length, payload (``J``: one JSON event, ``heard``, ``say.delta``,
  ``say.done``, ``action``, ``card``, ``done``; ``A``: PCM16LE mono 16 kHz, 160 ms a frame, a voice-like tone sent
  at twice real time). Without it, the buffered JSON answer (``audio: {mime: "audio/wav", b64}``). One turn per
  conversation at a time (409 ``assistant_busy``).
* ``POST /v1/desktop/assistant/cancel {conversationId}`` -> ``{ok, cancelled}`` (the stream ends with
  ``done {interrupted: true}``); ``POST /v1/desktop/assistant/end {conversationId}`` -> ``{ok, ended}``.
* ``GET /v1/desktop/assistant/announcements?conversationId=&since=`` -> ``{items: [{id, say, audio: null, kind,
  threadId, title}], cursor}`` (each once per conversation, only those queued after it began).

The canned conversation: the first utterance "hears" "What's on my calendar this afternoon?" and answers about the
design review; the next one hears "Thanks, that's all." and ends the conversation (``endConversation``). A text turn
hears its text. Dev controls (desktop token too): ``POST /dev/assistant {mode?, pace?, script?}`` (modes ``ok``,
``noaudio`` (no audio: the app says it with its own voice), ``noise`` (nothing heard), ``error`` (an ``error``
event, then ``done``), ``slow`` (3 s before the answer), ``unavailable`` (503 ``assistant_unavailable``); ``script``
replaces the canned answers: ``[{heard, say, end?}]``, one per turn), ``GET /dev/assistant`` (the mode and what
arrived: turns, sessions, cancels, ends; byte counts and ids only), ``POST /dev/announce {say, kind?, threadId?,
title?}``. With ``$SAMRABBIT_FAKE_ASSISTANT_SAVE`` set to a folder, each utterance is also saved there
(``turn-<n>.wav``) for the voice tests to transcribe. Stdlib only.
"""

from __future__ import annotations

import base64
import json
import math
import os
import re
import struct
import threading
import time
import uuid
from typing import Any, Dict, List, Optional
from urllib.parse import parse_qs

STREAM_TYPE = "application/x-samrabbit-stream"
RATE = 16000
FRAME_SECONDS = 0.16
MAX_BYTES = 2 * 1024 * 1024
MAX_SECONDS = 60.5
MODES = ("ok", "noaudio", "noise", "error", "slow", "unavailable")
_CONVERSATION_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{2,56}$")
_TURN_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,95}$")
CANNED: List[Dict[str, Any]] = [
    {"heard": "What's on my calendar this afternoon?",
     "say": "Next up is the design review at three. Want me to block time before it?",
     "cards": [{"title": "Up next", "body": "Design review at 3:00 PM"}]},
    {"heard": "Thanks, that's all.", "say": "Okay. Talk soon.", "end": True},
]


def frame(kind: bytes, payload: bytes) -> bytes:
    return kind + struct.pack(">I", len(payload)) + payload


def event_frame(event: Dict[str, Any]) -> bytes:
    return frame(b"J", json.dumps(event, ensure_ascii=False, separators=(",", ":")).encode("utf-8"))


def speech_pcm(seconds: float) -> bytes:
    """A voice-like sound (a 170 Hz buzz with harmonics in syllables), PCM16LE mono 16 kHz. Never real speech."""
    count = int(seconds * RATE)
    out = bytearray(count * 2)
    phase = 0.0
    for index in range(count):
        t = index / RATE
        envelope = (0.5 + 0.5 * math.sin(2 * math.pi * 3.6 * t - math.pi / 2)) * min(1.0, t / 0.05,
                                                                                    (seconds - t) / 0.08)
        phase += 2 * math.pi * (170 + 25 * math.sin(2 * math.pi * 0.7 * t)) / RATE
        sample = (math.sin(phase) + 0.45 * math.sin(2 * phase) + 0.2 * math.sin(3 * phase)) / 1.65 * envelope * 0.16
        struct.pack_into("<h", out, index * 2, int(max(-1.0, min(1.0, sample)) * 32767))
    return bytes(out)


def wav_bytes(pcm: bytes) -> bytes:
    return (b"RIFF" + struct.pack("<I", 36 + len(pcm)) + b"WAVE" + b"fmt " +
            struct.pack("<IHHIIHH", 16, 1, 1, RATE, RATE * 2, 2, 16) + b"data" + struct.pack("<I", len(pcm)) + pcm)


def wav_seconds(data: bytes) -> Optional[float]:
    """A 16-bit PCM WAV's length (None when it isn't one)."""
    if len(data) < 12 or data[:4] != b"RIFF" or data[8:12] != b"WAVE":
        return None
    position = 12
    rate = channels = bits = 0
    while position + 8 <= len(data):
        kind, size = data[position:position + 4], struct.unpack("<I", data[position + 4:position + 8])[0]
        body = position + 8
        if kind == b"fmt " and body + 16 <= len(data):
            _, channels, rate, _, _, bits = struct.unpack("<HHIIHH", data[body:body + 16])
        elif kind == b"data":
            if not rate or not channels or not bits:
                return None
            return min(size, len(data) - body) / float(rate * channels * bits // 8)
        position = body + size + (size & 1)
    return None


def spoken_seconds(say: str) -> float:
    return max(1.0, min(6.0, 0.3 * len(say.split()) + 0.4))


class Refusal(Exception):
    def __init__(self, status: int, code: str, message: str, retryable: bool = False) -> None:
        super().__init__(code)
        self.status, self.code, self.message, self.retryable = status, code, message, retryable


class FakeAssistant:
    """The desktop assistant's conversations, canned answers and a log of what arrived."""

    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.mode = "ok"
        self.pace = 0.5  # seconds of sending per second of audio
        self.script: List[Dict[str, Any]] = [dict(item) for item in CANNED]
        self.conversations: Dict[str, Dict[str, Any]] = {}
        self.answers: Dict[str, Dict[str, Any]] = {}
        self.announcements: List[Dict[str, Any]] = []
        self.log: Dict[str, List[Dict[str, Any]]] = {"turns": [], "sessions": [], "cancels": [], "ends": []}

    @staticmethod
    def handles(path: str) -> bool:
        return path.startswith("/v1/desktop/assistant/") or path in ("/dev/assistant", "/dev/announce")

    # ------------------------------------------------------------------ dispatch

    def handle(self, handler: Any, method: str, path: str, query: str) -> None:
        body = self.read_body(handler)
        try:
            if path == "/dev/assistant":
                return self.dev(handler, method, body)
            if path == "/dev/announce":
                self.only(method, "POST")
                return handler.json(200, self.announce(self.json_body(handler, body)))
            route = path[len("/v1/desktop/assistant/"):]
            if route == "turn":
                self.only(method, "POST")
                return self.turn(handler, body)
            if route == "announcements":
                self.only(method, "GET")
                return handler.json(200, self.pending(parse_qs(query)))
            self.only(method, "POST")
            payload = self.json_body(handler, body)
            if route == "session":
                return handler.json(200, self.session(payload))
            if route in ("cancel", "end"):
                return handler.json(200, self.stop(route, payload))
            raise Refusal(404, "not_found", "Not found.")
        except Refusal as refusal:
            handler.json(refusal.status, {"error": {"code": refusal.code, "message": refusal.message,
                                                    "retryable": refusal.retryable}})

    @staticmethod
    def read_body(handler: Any) -> bytes:
        try:
            length = int(handler.headers.get("Content-Length") or 0)
        except ValueError:
            length = 0
        if length > MAX_BYTES:
            handler.close_connection = True
            return b""
        return handler.rfile.read(length) if length > 0 else b""

    @staticmethod
    def only(method: str, expected: str) -> None:
        if method != expected:
            raise Refusal(405, "method_not_allowed", "Use %s." % expected)

    @staticmethod
    def json_body(handler: Any, body: bytes) -> Dict[str, Any]:
        if not body:
            return {}
        try:
            value = json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            raise Refusal(400, "invalid_json", "Send a JSON object.")
        if not isinstance(value, dict):
            raise Refusal(400, "invalid_json", "Send a JSON object.")
        return value

    def dev(self, handler: Any, method: str, body: bytes) -> None:
        if method == "POST":
            payload = self.json_body(handler, body)
            with self.lock:
                if payload.get("mode") in MODES:
                    self.mode = payload["mode"]
                if isinstance(payload.get("pace"), (int, float)):
                    self.pace = max(0.0, float(payload["pace"]))
                if isinstance(payload.get("script"), list):
                    self.script = [dict(item) for item in payload["script"] if isinstance(item, dict)]
        with self.lock:
            handler.json(200, {"mode": self.mode, "pace": self.pace, **{k: list(v) for k, v in self.log.items()}})

    # ------------------------------------------------------------------ conversations

    def conversation(self, conversation_id: Optional[str]) -> Dict[str, Any]:
        with self.lock:
            if conversation_id and conversation_id in self.conversations:
                return self.conversations[conversation_id]
            conversation_id = conversation_id or "mc_" + uuid.uuid4().hex[:16]
            found = {"conversationId": conversation_id, "active": None, "cancel": threading.Event(), "turns": 0,
                     "ended": False, "announced": set(),
                     "cursor": max([a["id"] for a in self.announcements] or [0])}
            self.conversations[conversation_id] = found
            return found

    def session(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        if self.mode == "unavailable":
            raise Refusal(503, "assistant_unavailable", "Connect ChatGPT on the Mac first.")
        conversation_id = payload.get("conversationId")
        if conversation_id is not None and (not isinstance(conversation_id, str) or
                                            not _CONVERSATION_ID.match(conversation_id)):
            raise Refusal(400, "invalid_conversation", "The conversation id must be 3 to 57 letters, digits, - or _.")
        conversation = self.conversation(conversation_id or None)
        with self.lock:
            conversation["ended"] = False
            self.log["sessions"].append({"conversationId": conversation["conversationId"],
                                         "continued": bool(conversation_id)})
        return {"conversationId": conversation["conversationId"], "brain": "realtime", "ready": True}

    def stop(self, route: str, payload: Dict[str, Any]) -> Dict[str, Any]:
        conversation_id = payload.get("conversationId")
        if not isinstance(conversation_id, str) or not _CONVERSATION_ID.match(conversation_id):
            raise Refusal(400, "invalid_conversation", "conversationId is required.")
        with self.lock:
            found = self.conversations.get(conversation_id)
            if route == "cancel":
                cancelled = bool(found and found["active"])
                if cancelled:
                    found["cancel"].set()
                self.log["cancels"].append({"conversationId": conversation_id, "cancelled": cancelled})
                return {"ok": True, "cancelled": cancelled}
            if found:
                found["ended"] = True
            self.log["ends"].append({"conversationId": conversation_id, "ended": bool(found)})
            return {"ok": True, "ended": bool(found)}

    def announce(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        with self.lock:
            item = {"id": len(self.announcements) + 1,
                    "say": str(payload.get("say") or "“Fix login redirect” in Hermes finished."),
                    "audio": None, "kind": str(payload.get("kind") or "done"),
                    "threadId": payload.get("threadId") or "t_login", "title": payload.get("title") or "Fix login redirect"}
            self.announcements.append(item)
            return dict(item)

    def pending(self, query: Dict[str, List[str]]) -> Dict[str, Any]:
        conversation_id = ((query.get("conversationId") or [""])[0]).strip()
        if not _CONVERSATION_ID.match(conversation_id):
            raise Refusal(400, "invalid_conversation", "conversationId is required.")
        since = ((query.get("since") or [""])[0]).strip()
        if since and not since.isdigit():
            raise Refusal(400, "invalid_since", "since must be the cursor of the last answer.")
        conversation = self.conversation(conversation_id)
        with self.lock:
            items = [dict(a) for a in self.announcements
                     if a["id"] > conversation["cursor"] and a["id"] not in conversation["announced"]
                     and (not since or a["id"] > int(since))]
            for item in items:
                conversation["announced"].add(item["id"])
            cursor = max([a["id"] for a in self.announcements] or [0])
        return {"items": items, "cursor": cursor}

    # ------------------------------------------------------------------ turns

    def turn(self, handler: Any, body: bytes) -> None:
        declared = (handler.headers.get("Content-Type") or "").split(";", 1)[0].strip().lower()
        conversation_id = (handler.headers.get("X-SamRabbit-Conversation") or "").strip() or None
        turn_id = (handler.headers.get("X-SamRabbit-Turn") or "").strip() or None
        record: Dict[str, Any] = {"accept": handler.headers.get("Accept"),
                                  "deviceTime": bool(handler.headers.get("X-SamRabbit-Device-Time"))}
        text: Optional[str] = None
        announce: Optional[Dict[str, Any]] = None
        if declared in ("audio/wav", "audio/x-wav", "audio/wave"):
            if not body:
                raise Refusal(400, "invalid_audio", "Send the recording as the request body.")
            seconds = wav_seconds(body)
            if seconds is None:
                raise Refusal(415, "unsupported_audio", "The body is not the audio/wav it says it is.")
            if seconds > MAX_SECONDS:
                raise Refusal(413, "audio_too_long", "Say it in at most 60 seconds.")
            record.update({"kind": "audio", "bytes": len(body), "seconds": round(seconds, 2)})
            folder = os.environ.get("SAMRABBIT_FAKE_ASSISTANT_SAVE")
            if folder:
                with self.lock:
                    saved = sum(1 for t in self.log["turns"] if t.get("kind") == "audio") + 1
                with open(os.path.join(folder, "turn-%d.wav" % saved), "wb") as handle:
                    handle.write(body)
        elif declared in ("application/json", ""):
            payload = self.json_body(handler, body)
            conversation_id = payload.get("conversationId", conversation_id)
            turn_id = payload.get("turnId", turn_id)
            if "announce" in payload:
                wanted = str(payload.get("announce") or "")
                with self.lock:
                    announce = next((dict(a) for a in self.announcements if str(a["id"]) == wanted), None)
                if announce is None:
                    raise Refusal(404, "announcement_not_found", "No such announcement.")
                record.update({"kind": "announce", "announce": wanted})
            else:
                text = payload.get("text")
                if not isinstance(text, str) or len(text) > 4000:
                    raise Refusal(400, "invalid_text", "text must be at most 4000 characters.")
                record.update({"kind": "text", "chars": len(text)})
            if isinstance(conversation_id, str):
                conversation_id = conversation_id.strip() or None
        else:
            raise Refusal(415, "unsupported_media", "Send audio/wav, or JSON text.")
        if conversation_id is not None and (not isinstance(conversation_id, str) or
                                            not _CONVERSATION_ID.match(conversation_id)):
            raise Refusal(400, "invalid_conversation", "The conversation id must be 3 to 57 letters, digits, - or _.")
        if not isinstance(turn_id, str) or not _TURN_ID.match(turn_id):
            raise Refusal(400, "invalid_turn", "Send X-SamRabbit-Turn (or turnId): a uuid for this turn.")
        if self.mode == "unavailable":
            raise Refusal(503, "assistant_unavailable", "Connect ChatGPT on the Mac first.")
        conversation = self.conversation(conversation_id)
        with self.lock:
            answer = self.answers.get(turn_id)
            replay = answer is not None
            if not replay:
                if conversation["active"] and conversation["active"] != turn_id:
                    raise Refusal(409, "assistant_busy", "Still answering the last thing you said.", retryable=True)
                answer = self.answer(conversation, text, announce)
                answer.update({"conversationId": conversation["conversationId"], "turnId": turn_id})
                self.answers[turn_id] = answer
                conversation["turns"] += 1
            conversation["active"] = turn_id
            conversation["cancel"].clear()
            streamed = STREAM_TYPE in (record["accept"] or "")
            record.update({"conversationId": conversation["conversationId"], "turnId": turn_id, "replay": replay,
                           "mode": self.mode, "stream": streamed})
            self.log["turns"].append(record)
            del self.log["turns"][:-40]
        try:
            if answer["delay"]:
                time.sleep(answer["delay"])
            if streamed:
                record["interrupted"] = self.stream(handler, answer, conversation)
            else:
                record["interrupted"] = False
                handler.json(200, self.buffered(answer))
        finally:
            with self.lock:
                if conversation["active"] == turn_id:
                    conversation["active"] = None

    def answer(self, conversation: Dict[str, Any], text: Optional[str],
               announce: Optional[Dict[str, Any]]) -> Dict[str, Any]:
        """What the next turn of `conversation` answers (the same again for a retry of the turn)."""
        mode = self.mode
        if self.script:
            canned = dict(self.script[min(conversation["turns"], len(self.script) - 1)])
        else:
            canned = {"heard": "", "say": ""}
        heard = text if text is not None else str(canned.get("heard") or "")
        say = str(canned.get("say") or "")
        end = bool(canned.get("end"))
        if announce is not None:
            heard, say, end = "", announce["say"], False
        elif mode == "noise":
            heard, say, end = "", "", False
        return {"heard": heard, "say": say, "end": end, "cards": list(canned.get("cards") or []),
                "actions": list(canned.get("actions") or []), "audio": mode not in ("noaudio", "noise", "error"),
                "error": mode == "error", "delay": 3.0 if mode == "slow" else 0.3}

    def buffered(self, answer: Dict[str, Any]) -> Dict[str, Any]:
        if answer["error"]:
            raise Refusal(502, "assistant_failed", "The assistant could not answer.", retryable=True)
        audio = None
        if answer["audio"] and answer["say"]:
            audio = {"mime": "audio/wav",
                     "b64": base64.b64encode(wav_bytes(speech_pcm(spoken_seconds(answer["say"])))).decode()}
        return {"conversationId": answer["conversationId"], "turnId": answer["turnId"], "heard": answer["heard"],
                "say": answer["say"], "audio": audio, "expectReply": answer["say"].rstrip().endswith("?"),
                "endConversation": answer["end"], "actions": answer["actions"], "cards": answer["cards"],
                "brain": "realtime", "timings": {"stt": 180, "agent": 900, "tts": 300}}

    def stream(self, handler: Any, answer: Dict[str, Any], conversation: Dict[str, Any]) -> bool:
        """Streams the frames; returns whether the turn was cancelled (``POST .../cancel`` or the app hung up)."""
        started = time.time()
        handler.send_response(200)
        handler.send_header("Content-Type", STREAM_TYPE)
        handler.send_header("Transfer-Encoding", "chunked")
        handler.send_header("Cache-Control", "no-store")
        handler.end_headers()

        def write(data: bytes) -> None:
            handler.wfile.write(b"%x\r\n" % len(data) + data + b"\r\n")
            handler.wfile.flush()

        interrupted = False
        first_audio = None
        try:
            write(event_frame({"type": "heard", "text": answer["heard"]}))
            if answer["error"]:
                write(event_frame({"type": "error", "code": "assistant_failed",
                                   "message": "The realtime session failed."}))
            else:
                say = answer["say"]
                words = say.split(" ") if say else []
                pcm = speech_pcm(spoken_seconds(say)) if answer["audio"] and say else b""
                step = int(RATE * 2 * FRAME_SECONDS)
                frames = [pcm[i:i + step] for i in range(0, len(pcm), step)]
                for index in range(max(len(frames), len(words))):
                    if conversation["cancel"].is_set():
                        interrupted = True
                        break
                    if index < len(words):
                        write(event_frame({"type": "say.delta", "text": (" " if index else "") + words[index]}))
                    if index < len(frames):
                        if first_audio is None:
                            first_audio = int((time.time() - started) * 1000)
                        write(frame(b"A", frames[index]))
                    time.sleep(FRAME_SECONDS * self.pace)
                if not interrupted:
                    write(event_frame({"type": "say.done", "text": say}))
                    for action in answer["actions"]:
                        write(event_frame(dict(action, type="action")))
                    for card in answer["cards"]:
                        write(event_frame(dict(card, type="card")))
            done: Dict[str, Any] = {"type": "done", "conversationId": answer["conversationId"],
                                    "turnId": answer["turnId"], "expectReply": answer["say"].rstrip().endswith("?"),
                                    "endConversation": answer["end"] and not interrupted, "brain": "realtime",
                                    "timings": {"stt": 180, "firstAudio": first_audio,
                                                "total": int((time.time() - started) * 1000)}}
            if interrupted:
                done["interrupted"] = True
            write(event_frame(done))
            handler.wfile.write(b"0\r\n\r\n")
            handler.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            interrupted = True  # the app hung up (barge-in)
            handler.close_connection = True
        return interrupted

