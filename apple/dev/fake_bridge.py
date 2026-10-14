#!/usr/bin/env python3
"""A fake SamRabbit Mac bridge: the whole mobile API (CONTRACTS-WAVE4 "Mobile API") with fixtures.

For simulator work and SamRabbitKit's tests. It never touches T3 Code, Google Calendar, Heptabase,
the R1 or the live bridge on :3780: every thread, event, calendar entry and journal line lives in
memory and is invented here. Only pairings (token hashes) persist, in ``--state``.

    /usr/bin/python3 -I apple/dev/fake_bridge.py                 # 127.0.0.1:3799, code SAMRABBT
    /usr/bin/python3 -I apple/dev/fake_bridge.py --port 0 --print-port --quiet   # tests

Pair the simulator:
    xcrun simctl openurl booted 'samrabbit://pair?h=127.0.0.1:3799&c=SAMRABBT&n=Fake%20Mac'

What is in it:
* T3 threads in every state (an approval and a question waiting, two working, done, error, idle) with
  Markdown messages; approving, answering, replying and new tasks progress on their own.
* Three R1 conversations (one live, with a generated UI; one with a Mac screenshot; one with cards),
  served with the sync event format and an SSE stream; with ``--chatter`` (default on) the live one
  gets a new streamed exchange every minute.
* An agenda relative to now, Block / new events, an in-memory journal, Mac state, open and a
  screenshot JPEG, and generated UIs (``/ui/generate`` is ready after about four seconds).
* ``POST /v1/mobile/transcribe[?lang=]`` (the watch's voice input): checks a recording like the real bridge
  (Content-Type, Content-Length, 2 MiB, the container's own bytes, 90 s from an m4a's header, ``lang``) and
  answers canned words ``{text, durationMs, engine, locale}`` after a short pause; the summary says
  ``transcribe: {available, reason?}``. Nothing is transcribed and the audio is not kept (only its size, type
  and the device that sent it, for tests).

Devices follow the real bridge's rules: a wrong or expired code answers 401 ``invalid_code`` and ten wrong
codes in ten minutes 429 ``pairing_rate_limited``; ``POST /v1/mobile/devices/child`` works only with an
iPhone's token and replaces that phone's earlier watch of the same name; ``POST /v1/mobile/unpair`` (and the
desktop's ``DELETE /v1/mobile/devices/<id>``) revokes a device together with the watch it provisioned.

Pending approvals and questions carry a ``requestId`` (and questions a ``questionId``) like the real
bridge's; ``respond`` with a ``requestId`` that is no longer the open one answers 409
``t3_request_not_pending``, as the real bridge does.

Fake-only helpers (loopback, no token): ``POST /__fake/reset``, ``GET /__fake/journal``,
``POST /__fake/chatter``, ``POST /__fake/settle`` (finish every pending simulated step now),
``POST /__fake/rerequest {threadId, text?}`` (the open request was answered elsewhere and T3 asks a new one:
same thread, new ``requestId``), ``POST /__fake/t3 {available}`` (T3 Code stops or starts answering: the summary
says ``t3.available=false`` and every ``/v1/mobile/t3/*`` route answers 503 ``t3_unavailable``),
``POST /__fake/transcribe {mode?, text?, delay?}`` (what ``/transcribe`` answers: ``ok`` (the canned ``text``),
``empty``, ``unavailable`` (503 ``transcribe_unavailable``, reason ``model_downloading``; the summary says
unavailable), ``permission`` (503 ``transcribe_permission``), ``failed`` (502 ``transcribe_failed``), ``busy``
(503 ``transcribe_busy``), ``no_speech`` (422) or ``missing`` (an older bridge: 404 and no ``transcribe`` in the
summary)) and ``GET /__fake/transcribe`` (the mode and the uploads that arrived: bytes, type, lang, device).

The voice assistant (CONTRACTS-WAVE5, "Streaming turn protocol"), with canned answers:

* ``POST /v1/mobile/assistant/turn``: an utterance (``audio/wav`` 16 kHz, ``audio/mp4``, ``audio/x-m4a``; at most
  2 MiB and 60 s) or JSON ``{text | announce, conversationId?, turnId}``, with ``X-SamRabbit-Conversation``,
  ``X-SamRabbit-Turn`` (a retry of a turn gets the same answer) and ``X-SamRabbit-Device-Time``. With ``Accept:
  application/x-samrabbit-stream`` the answer is 200 ``application/x-samrabbit-stream``, chunked: frames of 1 byte
  type, 4-byte big-endian length, payload; ``J`` = one JSON event (``heard``, ``say.delta``, ``say.done``,
  ``action``, ``card``, ``done`` with ``conversationId, turnId, expectReply, endConversation, interrupted?, brain,
  timings {stt, firstAudio, total}``, or ``error``), ``A`` = PCM16LE mono 16 kHz (160 ms per frame, a made-up
  voice-like tone, sent at twice real time). Without that ``Accept``: the buffered JSON answer ``{conversationId,
  turnId, heard, say, audio: {mime: "audio/wav", b64} | null, expectReply, endConversation, actions, timings,
  brain}``. One turn per conversation at a time (409 ``assistant_busy``).
* ``POST /v1/mobile/assistant/session {conversationId?}`` -> ``{conversationId, brain, ready}``;
  ``POST /v1/mobile/assistant/cancel {conversationId}`` (the stream stops and ends with ``done{interrupted: true}``);
  ``POST /v1/mobile/assistant/end {conversationId}``;
  ``GET /v1/mobile/assistant/announcements?conversationId=&since=`` -> ``{items: [{id, say, audio | null, kind,
  threadId, title}], cursor}`` (each once per conversation); a turn ``{"announce": id}`` says it.
* The summary says ``assistant: {available, brain, reason?, model, chatgpt: {connected}}``.
* ``POST /__fake/assistant {mode?, say?, heard?, delay?, brain?, pace?, code?, hold?, ping?, busyFor?}`` /
  ``GET /__fake/assistant`` (the mode and what arrived: turns, sessions, cancels, ends, and turns refused 409). ``hold``: seconds the
  stream stays quiet after ``heard`` (a long tool call), with a ``{"type": "ping"}`` event every ``ping`` seconds
  (0: none, like an older bridge); ``busyFor``: turns are refused 409 ``assistant_busy`` for that many seconds,
  counted from the first turn that arrives after it was set (the Mac still finishing the last one). Modes: ``ok``; ``noaudio`` (no audio: the watch speaks the text
  itself); ``noise`` (nothing heard: keep listening); ``end`` (``endConversation``); ``error`` (an ``error`` event
  with ``code``, default ``assistant_failed``, then ``done``, like the real bridge);
  ``slow`` (4 s before the answer starts); ``busy`` (409); ``unavailable`` (503 ``assistant_unavailable``); ``drop``
  (the connection closes without an answer: "can't reach your Mac"); ``buffered`` (answers buffered JSON even when a
  stream was asked for, like the Claude fallback) and ``buffered_clip`` (the same with an AAC clip, ``audio/mp4``,
  instead of WAV); ``missing`` (an older bridge: 404 and no ``assistant`` in the summary).
  ``POST /__fake/announce {say?, kind?, threadId?, title?, audio?}`` queues an announcement (``audio: true`` with its
  own WAV clip, ``"broken"`` with a clip no player can read).
* The Mac app's twin of those routes (CONTRACTS-WAVE6): ``/v1/desktop/assistant/turn|session|cancel|end|announcements``
  with the desktop token (``X-SamRabbit-Desktop: fake-desktop-token``, loopback only) instead of a mobile token; the
  same answers, recorded with ``deviceId: "mac"``.
Stdlib only, Python 3.9.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import ipaddress
import json
import math
import os
import re
import secrets
import socket
import struct
import sys
import threading
import time
import uuid
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Callable, Dict, List, Optional, Tuple
from urllib.parse import parse_qs, quote, unquote, urlsplit

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURES = os.path.join(HERE, "fixtures")
VERSION = "fake-1.0"
DEFAULT_CODE = "SAMRABBT"
DESKTOP_TOKEN = "fake-desktop-token"
# Who the desktop assistant routes talk for (the Mac's own app).
MAC_DEVICE: Dict[str, Any] = {"deviceId": "mac", "name": "Mac", "platform": "mac"}
CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
HEARTBEAT_SECONDS = 15.0
# Voice (the real bridge's limits and answers, samrabbit_transcribe.py)
TRANSCRIBE_MAX_BYTES = 2 * 1024 * 1024
TRANSCRIBE_MAX_SECONDS = 90.5
TRANSCRIBE_TYPES = {"audio/mp4": "mp4", "audio/x-m4a": "mp4", "audio/m4a": "mp4", "audio/wav": "wav",
                    "audio/x-wav": "wav", "audio/wave": "wav", "audio/aac": "aac", "audio/x-aac": "aac"}
DEFAULT_TRANSCRIPT = "Draft the release notes for build 2.4 and post them in the team channel"
TRANSCRIBE_FAILURES: Dict[str, Tuple[int, str, str, bool, Optional[str]]] = {
    "unavailable": (503, "transcribe_unavailable", "The Mac is downloading the speech model for that language. "
                    "Try again in a minute.", True, "model_downloading"),
    "permission": (503, "transcribe_permission", "Speech Recognition is turned off for SamRabbit on the Mac "
                   "(System Settings > Privacy & Security > Speech Recognition).", False, None),
    "failed": (502, "transcribe_failed", "The Mac could not transcribe the recording.", True, None),
    "busy": (503, "transcribe_busy", "The Mac is transcribing other recordings. Try again in a moment.", True, None),
    "no_speech": (422, "no_speech", "No speech was heard in the recording.", False, None),
}
TRANSCRIBE_MODES = ("ok", "empty", "missing") + tuple(TRANSCRIBE_FAILURES)
_LANG = re.compile(r"^[A-Za-z]{2,3}(?:[-_][A-Za-z0-9]{1,8}){0,3}$")
# The voice assistant (the real bridge's rules, samrabbit_assistant.py)
STREAM_TYPE = "application/x-samrabbit-stream"
ASSISTANT_MODES = ("ok", "noaudio", "noise", "end", "error", "slow", "busy", "unavailable", "drop", "buffered",
                   "buffered_clip", "missing")
ASSISTANT_MAX_BYTES = 2 * 1024 * 1024
ASSISTANT_MAX_SECONDS = 60.5
ASSISTANT_TYPES = {"audio/wav": "wav", "audio/x-wav": "wav", "audio/wave": "wav", "audio/mp4": "mp4",
                   "audio/x-m4a": "mp4", "audio/m4a": "mp4"}
DEFAULT_HEARD = "Draft the release notes for build 2.4"
DEFAULT_SAY = "Okay, I started the release notes for build 2.4 in Hermes. Anything else?"
ASSISTANT_RATE = 16000
ASSISTANT_FRAME_SECONDS = 0.16
_CONVERSATION_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{2,56}$")
_TURN_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,95}$")
_SPEECH_CACHE: Dict[int, bytes] = {}


def speech_pcm(seconds: float) -> bytes:
    """A voice-like sound (a 170 Hz buzz with harmonics in syllables), PCM16LE mono 16 kHz."""
    key = int(seconds * 100)
    cached = _SPEECH_CACHE.get(key)
    if cached is not None:
        return cached
    count = int(seconds * ASSISTANT_RATE)
    out = bytearray(count * 2)
    phase = 0.0
    for index in range(count):
        t = index / ASSISTANT_RATE
        envelope = (0.5 + 0.5 * math.sin(2 * math.pi * 3.6 * t - math.pi / 2)) * min(1.0, t / 0.05,
                                                                                    (seconds - t) / 0.08)
        phase += 2 * math.pi * (170 + 25 * math.sin(2 * math.pi * 0.7 * t)) / ASSISTANT_RATE
        sample = (math.sin(phase) + 0.45 * math.sin(2 * phase) + 0.2 * math.sin(3 * phase)) / 1.65 * envelope * 0.16
        struct.pack_into("<h", out, index * 2, int(max(-1.0, min(1.0, sample)) * 32767))
    _SPEECH_CACHE[key] = bytes(out)
    return _SPEECH_CACHE[key]


def wav_bytes(pcm: bytes, rate: int = ASSISTANT_RATE) -> bytes:
    return (b"RIFF" + struct.pack("<I", 36 + len(pcm)) + b"WAVE" + b"fmt " +
            struct.pack("<IHHIIHH", 16, 1, 1, rate, rate * 2, 2, 16) + b"data" + struct.pack("<I", len(pcm)) + pcm)


def wav_seconds(data: bytes) -> Optional[float]:
    """A 16-bit WAV's length (None when its header can't be read)."""
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


def frame(kind: bytes, payload: bytes) -> bytes:
    return kind + struct.pack(">I", len(payload)) + payload


def event_frame(event: Dict[str, Any]) -> bytes:
    return frame(b"J", json.dumps(event, ensure_ascii=False, separators=(",", ":")).encode("utf-8"))


def spoken_seconds(say: str) -> float:
    return max(1.0, min(6.0, 0.3 * len(say.split()) + 0.4))


def now_ms() -> int:
    return int(time.time() * 1000)


def iso(ts: float) -> str:
    return datetime.fromtimestamp(ts, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def private_peer(address: str) -> bool:
    try:
        ip = ipaddress.ip_address(address.split("%")[0])
    except ValueError:
        return False
    if isinstance(ip, ipaddress.IPv6Address) and ip.ipv4_mapped:
        ip = ip.ipv4_mapped
    if ip.is_loopback or ip.is_private or ip.is_link_local:
        return True
    return isinstance(ip, ipaddress.IPv4Address) and ip in ipaddress.ip_network("100.64.0.0/10")


def loopback_peer(address: str) -> bool:
    try:
        ip = ipaddress.ip_address(address.split("%")[0])
    except ValueError:
        return False
    if isinstance(ip, ipaddress.IPv6Address) and ip.ipv4_mapped:
        ip = ip.ipv4_mapped
    return ip.is_loopback


class ApiError(Exception):
    def __init__(self, status: int, code: str, message: str, retryable: bool = False) -> None:
        super().__init__(code)
        self.status = status
        self.code = code
        self.message = message
        self.retryable = retryable


def read_fixture(name: str) -> bytes:
    with open(os.path.join(FIXTURES, name), "rb") as handle:
        return handle.read()


# --------------------------------------------------------------------------- generated UI documents

def sniff_audio(data: bytes) -> Optional[str]:
    """``mp4`` (``ftyp`` first), ``wav`` (RIFF/WAVE) or ``aac`` (ADTS), from the bytes alone (as the real bridge)."""
    if len(data) >= 12 and data[4:8] == b"ftyp":
        return "mp4"
    if len(data) >= 12 and data[:4] == b"RIFF" and data[8:12] == b"WAVE":
        return "wav"
    if len(data) >= 7 and data[0] == 0xFF and (data[1] & 0xF6) == 0xF0:
        return "aac"
    return None


def _mp4_boxes(data: bytes, start: int, end: int):  # type: ignore[no-untyped-def]
    position = start
    while position + 8 <= end:
        size, kind = struct.unpack(">I4s", data[position:position + 8])
        header = 8
        if size == 1:
            if position + 16 > end:
                return
            size = struct.unpack(">Q", data[position + 8:position + 16])[0]
            header = 16
        elif size == 0:
            size = end - position
        if size < header:
            return
        yield kind, position + header, min(position + size, end)
        position += size


def mp4_seconds(data: bytes) -> Optional[float]:
    """An m4a's length from its ``moov/mvhd`` box (None when it doesn't say)."""
    try:
        for kind, start, end in _mp4_boxes(data, 0, len(data)):
            if kind != b"moov":
                continue
            for inner, body, stop in _mp4_boxes(data, start, end):
                if inner != b"mvhd" or body + 20 > stop:
                    continue
                if data[body] == 1:
                    if body + 32 > stop:
                        return None
                    scale, duration = struct.unpack(">IQ", data[body + 20:body + 32])
                else:
                    scale, duration = struct.unpack(">II", data[body + 12:body + 20])
                return duration / scale if scale else None
    except struct.error:
        return None
    return None


def chart_document(title: str, subtitle: str, labels: List[str], values: List[float], unit: str) -> str:
    """A self-contained interactive bar chart (no network), styled like the bridge's generated UIs."""
    data = json.dumps({"title": title, "subtitle": subtitle, "labels": labels, "values": values, "unit": unit})
    return """<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>%(title)s</title>
<style>
:root { color-scheme: dark; }
html { min-height: 100%%; background: #0b0f18; }
body { margin: 0; min-height: 100vh; font: 15px/1.45 -apple-system, system-ui, sans-serif; color: #f5f8ff;
  background: radial-gradient(600px 300px at 90%% -10%%, rgba(26,115,242,.28), transparent 60%%) no-repeat, #0b0f18; }
#content { padding: 22px 18px 28px; }
.eyebrow { font-size: 11px; letter-spacing: .08em; text-transform: uppercase; color: #8c98ac; font-weight: 600; }
h1 { margin: 6px 0 2px; font-size: 26px; letter-spacing: -.01em; }
.sub { color: #60d6a0; font-size: 14px; }
.chart { display: flex; align-items: flex-end; gap: 10px; height: 220px; margin: 26px 0 10px; }
.col { flex: 1; display: flex; flex-direction: column; align-items: center; gap: 6px; cursor: pointer; }
.bar { width: 100%%; border-radius: 10px; background: linear-gradient(#1a73f2, rgba(26,115,242,.35));
  transition: transform .25s cubic-bezier(.2,.8,.2,1), background .2s; transform-origin: bottom; }
.col.on .bar { background: linear-gradient(#5ca2ff, rgba(92,162,255,.45)); }
.val { font-size: 12px; color: #a0c7ff; font-weight: 600; }
.lab { font-size: 12px; color: #8c98ac; }
.detail { margin-top: 14px; padding: 12px 14px; border-radius: 14px; background: rgba(22,27,39,.8);
  border: 1px solid rgba(190,210,255,.12); color: #d5ddec; min-height: 20px; }
</style></head>
<body><div id="content">
<div class="eyebrow">Generated on your Mac</div>
<h1 id="t"></h1><div class="sub" id="s"></div>
<div class="chart" id="c"></div>
<div class="detail" id="d">Tap a bar for details.</div>
</div>
<script>
const D = %(data)s;
document.getElementById('t').textContent = D.title;
document.getElementById('s').textContent = D.subtitle;
const max = Math.max(...D.values, 1);
const chart = document.getElementById('c');
D.values.forEach((v, i) => {
  const col = document.createElement('div'); col.className = 'col';
  col.innerHTML = '<div class="val"></div><div class="bar"></div><div class="lab"></div>';
  col.querySelector('.val').textContent = v;
  col.querySelector('.lab').textContent = D.labels[i];
  const bar = col.querySelector('.bar');
  bar.style.height = Math.max(6, v / max * 180) + 'px';
  bar.style.transform = 'scaleY(0)';
  setTimeout(() => { bar.style.transform = 'scaleY(1)'; }, 60 + i * 50);
  col.onclick = () => {
    chart.querySelectorAll('.col').forEach(c => c.classList.remove('on'));
    col.classList.add('on');
    document.getElementById('d').textContent = D.labels[i] + ': ' + v + ' ' + D.unit;
  };
  chart.appendChild(col);
});
</script></body></html>
""" % {"title": title.replace("<", "&lt;"), "data": data.replace("</", "<\\/")}


# --------------------------------------------------------------------------- state

class FakeBridge:
    def __init__(self, *, code: str, single_use: bool, state_path: Optional[str], mac_name: str,
                 chatter: bool, advertise: List[str], screen_locked: bool) -> None:
        self.lock = threading.RLock()
        self.changed = threading.Condition(self.lock)
        self.code = code
        self.single_use = single_use
        self.state_path = state_path
        self.mac_name = mac_name
        self.chatter = chatter
        self.advertise = advertise
        self.screen_locked = screen_locked
        self.port = 0
        self.closed = False
        self.devices: Dict[str, Dict[str, Any]] = {}
        self.bad_codes_all: List[float] = []
        self.used_codes: set = set()
        self.jobs: List[Tuple[float, Callable[[], None]]] = []
        self._load_devices()
        self.seed()

    # ------------------------------------------------------------------ persistence (pairings only)

    def _load_devices(self) -> None:
        if not self.state_path or not os.path.exists(self.state_path):
            return
        try:
            with open(self.state_path, "r", encoding="utf-8") as handle:
                self.devices = json.load(handle).get("devices", {})
        except (OSError, ValueError):
            self.devices = {}

    def _save_devices(self) -> None:
        if not self.state_path:
            return
        os.makedirs(os.path.dirname(self.state_path), exist_ok=True)
        tmp = self.state_path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as handle:
            json.dump({"devices": self.devices}, handle, indent=1)
        os.chmod(tmp, 0o600)
        os.replace(tmp, self.state_path)

    # ------------------------------------------------------------------ fixtures

    def seed(self) -> None:
        with self.lock:
            self.cursor = 0
            self.events: List[Tuple[int, str, Dict[str, Any]]] = []
            self.conversations: Dict[str, Dict[str, Any]] = {}
            self.blobs: Dict[str, Tuple[str, bytes]] = {}
            self.artifacts: Dict[str, Dict[str, Any]] = {}
            self.documents: Dict[str, str] = {}
            self.journal: List[str] = []
            self.jobs = []
            self.event_counter = 0
            self.chatter_count = 0
            self.r1_seen = time.time() - 40
            self.t3_available = True
            self.request_seq = 0
            self.transcribe_mode = "ok"
            self.transcript = DEFAULT_TRANSCRIPT
            self.transcribe_delay = 0.6
            self.uploads: List[Dict[str, Any]] = []
            self.assistant_mode = "ok"
            self.assistant_say = DEFAULT_SAY
            self.assistant_heard = DEFAULT_HEARD
            self.assistant_delay = 0.35
            self.assistant_pace = 0.5  # seconds of sending per second of audio
            self.assistant_brain = "realtime"
            self.assistant_code = "assistant_failed"
            self.assistant_hold = 0.0
            self.assistant_ping = 0.0
            self.assistant_busy_until = 0.0
            self.assistant_busy_for = 0.0
            self.assistant_log: Dict[str, List[Dict[str, Any]]] = {"turns": [], "sessions": [], "cancels": [],
                                                                    "ends": [], "refused": []}
            self.assistant_conversations: Dict[str, Dict[str, Any]] = {}
            self.assistant_turns: Dict[Tuple[str, str], Dict[str, Any]] = {}
            self.announcements: List[Dict[str, Any]] = []
            self.announcement_seq = 100
            now = time.time()
            self.focus_jpg = self.put_blob(read_fixture("genui-focus.jpg"))
            self.release_jpg = self.put_blob(read_fixture("genui-release.jpg"))
            self.screenshot_jpg = read_fixture("mac-screenshot.jpg")
            self.screenshot_blob = self.put_blob(self.screenshot_jpg)
            self._seed_threads(now)
            self._seed_calendar(now)
            self._seed_conversations(now)

    def _seed_threads(self, now: float) -> None:
        self.projects = [
            {"projectId": "p_assistant", "name": "Assistant"},
            {"projectId": "p_website", "name": "Website"},
            {"projectId": "p_samrabbit", "name": "SamRabbit"},
        ]

        def thread(tid: str, title: str, project: str, status: str, ago: float, summary: str,
                   messages: List[Tuple[str, str]], pending: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
            pid = {"Assistant": "p_assistant", "Website": "p_website", "SamRabbit": "p_samrabbit"}[project]
            start = now - ago - 60 * len(messages)
            return {"threadId": tid, "title": title, "projectId": pid, "projectName": project, "status": status,
                    "updatedAt": now - ago, "summary": summary, "pending": pending,
                    "messages": [{"role": role, "text": text, "at": start + 60 * i}
                                 for i, (role, text) in enumerate(messages)]}

        self.threads: Dict[str, Dict[str, Any]] = {}
        for item in [
            thread("t_deploy24", "Deploy release 2.4 to staging", "Assistant", "needs_approval", 120,
                   "Build 2.4.0-rc1 is ready; waiting for approval to deploy.",
                   [("user", "Ship release 2.4 to staging when the tests pass."),
                    ("assistant", "All **42 tests** pass on `main`. The release build is ready:\n\n"
                                  "- version `2.4.0-rc1`\n- 3 migrations (all reversible)\n- changelog updated\n\n"
                                  "I need your approval to run the staging deploy.")],
                   {"kind": "approval", "requestId": "req_deploy_1", "requestKind": "command",
                    "text": "Run ./deploy.sh staging (pushes build 2.4.0-rc1 to staging)"}),
            thread("t_loginfix", "Fix login redirect", "Website", "needs_input", 300,
                   "The open redirect is fixed; one question about the default page.",
                   [("user", "Logged-out users bounce to a blank page after login. Fix it."),
                    ("assistant", "Found it: `redirectAfterLogin` trusted the `next` parameter. It now only "
                                  "accepts same-site paths.\n\n```js\nreturn next.startsWith('/') ? next : '/home'\n```"),
                    ("assistant", "Where should people land when there is no `next`?")],
                   {"kind": "question", "requestId": "req_login_1", "questionId": "q_landing",
                    "header": "Landing page", "text": "Where should logged-out users land after signing in?",
                    "options": ["/home", "/pricing", "/dashboard"], "allowCustom": True, "multiSelect": False}),
            thread("t_weekly", "Weekly report from Linear", "Assistant", "working", 40,
                   "Collecting closed issues for the week…",
                   [("user", "Write my weekly report from Linear and put it in a doc."),
                    ("assistant", "On it. Pulling the 23 issues closed since Monday.")]),
            thread("t_calsync", "Refactor calendar sync", "SamRabbit", "working", 95,
                   "Moving the Composio writer behind one interface; 2 of 5 files done.",
                   [("user", "Refactor the calendar sync so reads and writes share one client."),
                    ("assistant", "Plan:\n1. Extract `CalendarClient`\n2. Port reads\n3. Port writes\n"
                                  "4. Tests\n5. Remove the old helpers")]),
            thread("t_pricing", "Pricing page copy", "Website", "done", 1800,
                   "Rewrote the hero and the FAQ; PR #42 is ready for review.",
                   [("user", "Tighten the pricing page copy, keep it friendly."),
                    ("assistant", "Done. The hero is now one line, the FAQ dropped from 11 to 6 questions, and "
                                  "the plan names match the app. **PR #42** is ready.")]),
            thread("t_backup", "Nightly backup check", "Assistant", "error", 3600 * 3,
                   "rsync failed: the backup disk is not mounted.",
                   [("user", "Check that last night's backup finished."),
                    ("assistant", "The backup did not run: `/Volumes/Backup` is not mounted, so rsync exited "
                                  "with code 23. Plug the disk in and I can run it again.")]),
            thread("t_widgets", "Ideas for the R1 widgets", "SamRabbit", "idle", 3600 * 26,
                   "Five widget ideas, waiting for your pick.",
                   [("user", "Brainstorm widgets for the R1 board."),
                    ("assistant", "Five ideas: weather strip, next meeting, focus timer, T3 queue, inbox zero.")]),
        ]:
            self.threads[item["threadId"]] = item

    def _seed_calendar(self, now: float) -> None:
        base = now - (now % 300)
        today = datetime.now().replace(hour=0, minute=0, second=0, microsecond=0)
        tomorrow7 = (today + timedelta(days=1)).replace(hour=7).timestamp()
        self.calendar = [
            {"eventId": "ev_allday", "title": "Release 2.4", "startsAt": today.strftime("%Y-%m-%d"),
             "endsAt": (today + timedelta(days=1)).strftime("%Y-%m-%d"), "allDay": True, "location": None,
             "meetingUrl": None},
            self._event("ev_standup", "Standup", base + 25 * 60, 15 * 60, meeting="https://meet.google.com/abc-defg-hij"),
            self._event("ev_lunch", "Lunch with Maya", base + 125 * 60, 60 * 60, location="Blue Bottle, Hayes St"),
            self._event("ev_review", "Design review", base + 245 * 60, 45 * 60, meeting="https://zoom.us/j/5550100"),
            self._event("ev_gym", "Gym", tomorrow7, 60 * 60, location="Equinox"),
        ]

    @staticmethod
    def _event(eid: str, title: str, start: float, length: float, *, location: Optional[str] = None,
               meeting: Optional[str] = None) -> Dict[str, Any]:
        return {"eventId": eid, "title": title, "startsAt": iso(start), "endsAt": iso(start + length), "allDay": False,
                "location": location, "meetingUrl": meeting, "_start": start, "_end": start + length}

    def _seed_conversations(self, now: float) -> None:
        # 3. Morning plan (cards, a note) - three hours ago, ended.
        c3 = "c_morning03"
        t = (now - 3 * 3600) * 1000
        self.add_conversation(c3, "Morning plan", t)
        self.emit(c3, {"type": "conversation.started"}, at=t)
        self.emit(c3, {"type": "message.user", "text": "What does my day look like?"}, at=t + 2000)
        self.emit(c3, {"type": "card.shown", "card": {
            "id": "card_day", "title": "Today", "eyebrow": "Calendar", "accent": "blue", "icon": "calendar",
            "body": [{"type": "list", "items": [
                {"title": "Standup", "detail": "Google Meet", "trailing": "10:30"},
                {"title": "Lunch with Maya", "detail": "Blue Bottle, Hayes St", "trailing": "12:00"},
                {"title": "Design review", "detail": "Zoom", "trailing": "14:00"}]},
                {"type": "kv", "columns": 2, "pairs": [{"k": "Meetings", "v": "3"}, {"k": "Free", "v": "4 h 15 min"}]}]}},
            at=t + 5000)
        self.emit(c3, {"type": "card.shown", "card": {
            "id": "card_weather", "title": "San Francisco", "eyebrow": "Weather", "accent": "amber",
            "body": [{"type": "weather", "condition": "partly-cloudy", "temp": "64°", "hi": "68°", "lo": "55°",
                      "place": "San Francisco"}]}}, at=t + 6000)
        self.emit(c3, {"type": "message.assistant.done", "messageId": "m_c3_1",
                       "text": "Three meetings today: standup at 10:30, lunch with Maya at noon and the design "
                               "review at 2. You have about four free hours, mostly after 3."}, at=t + 7000)
        self.emit(c3, {"type": "message.user", "text": "Add to my journal: slept well, feeling sharp."}, at=t + 30000)
        self.emit(c3, {"type": "host.note", "text": "[Journal] Added to today's journal."}, at=t + 32000)
        self.emit(c3, {"type": "message.assistant.done", "messageId": "m_c3_2", "text": "Added to your journal."},
                  at=t + 33000)
        self.emit(c3, {"type": "session.finalized", "summary": "Planned the day; one journal note.",
                       "memoryCount": 1}, at=t + 60000)
        self.emit(c3, {"type": "conversation.ended"}, at=t + 61000)

        # 2. Mac check-in (a screenshot, a T3 update) - fifty minutes ago, ended.
        c2 = "c_maccheck2"
        t = (now - 50 * 60) * 1000
        self.add_conversation(c2, "Mac check-in", t)
        self.emit(c2, {"type": "conversation.started"}, at=t)
        self.emit(c2, {"type": "message.user", "text": "What's on my Mac screen right now?"}, at=t + 1500)
        self.emit(c2, {"type": "tool.call", "tool": "mac_look", "toolCallId": "tc_look1", "arguments": {}}, at=t + 2500)
        self.emit(c2, {"type": "tool.completed", "tool": "mac_look", "toolCallId": "tc_look1",
                       "result": {"ok": True}}, at=t + 4500)
        self.emit(c2, {"type": "image", "source": "mac_screenshot", "blobId": self.screenshot_blob,
                       "mime": "image/jpeg", "width": 1600, "height": 1000, "origin": "mac"}, at=t + 4600)
        self.emit(c2, {"type": "message.assistant.done", "messageId": "m_c2_1",
                       "text": "T3 Code is open on “Fix login redirect” and Google Calendar shows four events "
                               "today. The login fix has a question waiting for you."}, at=t + 6000)
        self.emit(c2, {"type": "host.t3_update", "kind": "t3.thread.needs_input", "threadId": "t_loginfix",
                       "title": "Fix login redirect", "projectTitle": "Website", "status": "needs-input",
                       "text": "[T3 update] “Fix login redirect” in Website has a question. Last message: Where "
                               "should people land when there is no next?"}, at=t + 9000)
        self.emit(c2, {"type": "session.finalized", "summary": "Looked at the Mac screen.", "memoryCount": 0},
                  at=t + 40000)
        self.emit(c2, {"type": "conversation.ended"}, at=t + 41000)

        # 1. Weekly focus review (generated UI) - live now.
        c1 = "c_focus0001"
        t = (now - 6 * 60) * 1000
        self.add_conversation(c1, "Weekly focus review", t)
        self.emit(c1, {"type": "conversation.started"}, at=t)
        self.emit(c1, {"type": "session.connected"}, at=t + 200)
        self.emit(c1, {"type": "message.user", "text": "How did my focus time look this week? Show me a chart."},
                  at=t + 2000)
        art = "ui_" + sha(b"focus-artifact")[:24]
        self.artifacts[art] = {"artifactId": art, "status": "ready", "title": "Focus this week",
                               "summary": "18.5 h of deep work, best day Wednesday.",
                               "imageBlobId": self.focus_jpg, "width": 960, "height": 620,
                               "conversationId": c1, "createdAt": iso(now - 340)}
        self.documents[art] = chart_document("Focus this week", "18.5 h of deep work · best day Wednesday",
                                             ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"],
                                             [2.5, 3.0, 4.5, 3.5, 2.0, 1.5, 1.5], "hours")
        self.emit(c1, {"type": "tool.call", "tool": "ui_generate", "toolCallId": "tc_ui1",
                       "arguments": {"prompt": "Focus hours this week"}}, at=t + 3000)
        self.emit(c1, {"type": "ui.generating", "artifactId": art, "prompt": "Focus hours this week as a bar chart"},
                  at=t + 3200)
        self.emit(c1, {"type": "ui.generated", "artifactId": art, "title": "Focus this week",
                       "summary": "18.5 h of deep work, best day Wednesday.", "imageBlobId": self.focus_jpg,
                       "width": 960, "height": 620}, at=t + 21000)
        self.emit(c1, {"type": "message.assistant.done", "messageId": "m_c1_1",
                       "text": "You logged 18.5 hours of deep work, 3.2 more than last week. Wednesday was your "
                               "best day with 4.5 hours."}, at=t + 22000)
        self.emit(c1, {"type": "message.user", "text": "Nice. Block thirty minutes after lunch to plan next week."},
                  at=t + 60000)
        self.emit(c1, {"type": "card.shown", "card": {
            "id": "card_block", "title": "Plan next week", "eyebrow": "Calendar · added", "accent": "violet",
            "icon": "calendar", "body": [{"type": "kv", "pairs": [{"k": "When", "v": "1:15 – 1:45 PM"},
                                                                  {"k": "Calendar", "v": "Primary"}]}]}},
            at=t + 63000)
        self.emit(c1, {"type": "message.assistant.done", "messageId": "m_c1_2",
                       "text": "Done: “Plan next week” is on your calendar from 1:15 to 1:45."}, at=t + 64000)
        self.conversations[c1]["live"] = True

    # ------------------------------------------------------------------ sync store

    def put_blob(self, data: bytes, mime: str = "image/jpeg") -> str:
        digest = sha(data)
        self.blobs[digest] = (mime, data)
        return "sha256:" + digest

    def add_conversation(self, cid: str, title: str, at_ms: float) -> None:
        self.conversations[cid] = {"conversationId": cid, "title": title, "startedAt": int(at_ms),
                                   "lastAt": int(at_ms), "endedAt": None, "live": False, "messageCount": 0,
                                   "preview": None, "device": "r1", "cursor": 0}

    def emit(self, cid: str, event: Dict[str, Any], at: Optional[float] = None) -> Dict[str, Any]:
        with self.changed:
            self.event_counter += 1
            self.cursor += 1
            payload = dict(event)
            payload.setdefault("id", "%s:%06d" % (cid, self.event_counter))
            payload["conversationId"] = cid
            payload["at"] = int(at if at is not None else now_ms())
            self.events.append((self.cursor, cid, payload))
            conv = self.conversations[cid]
            kind = payload["type"]
            conv["lastAt"] = max(conv["lastAt"], payload["at"])
            conv["cursor"] = self.cursor
            if kind in ("message.user", "message.assistant.done"):
                conv["messageCount"] += 1
                conv["preview"] = (payload.get("text") or "")[:160]
            elif kind == "ui.generated":
                conv["preview"] = "Generated UI: " + (payload.get("title") or "")
            if kind == "conversation.ended":
                conv["live"] = False
                conv["endedAt"] = payload["at"]
            if kind == "conversation.started":
                conv["live"] = True
            self.changed.notify_all()
            return payload

    def conversation_list(self, limit: int, before: Optional[int], q: str) -> List[Dict[str, Any]]:
        items = sorted(self.conversations.values(), key=lambda c: c["lastAt"], reverse=True)
        if before is not None:
            items = [c for c in items if c["lastAt"] < before]
        if q:
            needle = q.lower()

            def matches(conv: Dict[str, Any]) -> bool:
                if needle in (conv["title"] or "").lower() or needle in (conv["preview"] or "").lower():
                    return True
                return any(cid == conv["conversationId"] and needle in json.dumps(p).lower()
                           for _, cid, p in self.events)
            items = [c for c in items if matches(c)]
        return [dict(c) for c in items[:limit]]

    def events_after(self, after: int, cid: Optional[str], limit: int) -> List[Tuple[int, Dict[str, Any]]]:
        rows = [(n, p) for n, c, p in self.events if n > after and (cid is None or c == cid)]
        return rows[:limit]

    # ------------------------------------------------------------------ simulation

    def later(self, seconds: float, job: Callable[[], None]) -> None:
        with self.lock:
            self.jobs.append((time.time() + seconds, job))

    def run_due(self, force: bool = False) -> int:
        with self.lock:
            now = time.time()
            due = [job for when, job in self.jobs if force or when <= now]
            self.jobs = [(when, job) for when, job in self.jobs if not (force or when <= now)]
        for job in due:
            try:
                job()
            except Exception as error:  # noqa: BLE001 - a fake: keep running
                sys.stderr.write("fake job failed: %r\n" % (error,))
        return len(due)

    def settle(self) -> None:
        for _ in range(20):
            if not self.run_due(force=True):
                break

    def chatter_exchange(self) -> None:
        live = [c for c in self.conversations.values() if c["live"]]
        if not live:
            return
        cid = live[0]["conversationId"]
        prompts = [("What's next on my calendar?", "Standup in a few minutes, then lunch with Maya at noon."),
                   ("Any tasks waiting for me?", "Two: the staging deploy needs your approval and the login "
                                                 "fix has a question."),
                   ("How long until the design review?", "About four hours. You have a focus block before it."),
                   ("Remind me what Wednesday looked like.", "Wednesday was your best day: four and a half hours "
                                                             "of focus, mostly before lunch."),
                   ("Thanks, that's all for now.", "Anytime. I'll keep an eye on the deploy.")]
        user, answer = prompts[self.chatter_count % len(prompts)]
        self.chatter_count += 1
        self.r1_seen = time.time()
        self.emit(cid, {"type": "message.user", "text": user})
        message_id = "m_live_%d" % self.event_counter
        words = answer.split(" ")

        def step(index: int) -> None:
            if index >= len(words):
                self.emit(cid, {"type": "message.assistant.done", "messageId": message_id, "text": answer})
                return
            self.emit(cid, {"type": "message.assistant.delta", "messageId": message_id, "seq": index,
                            "text": " ".join(words[: index + 1])})
            self.later(0.18, lambda: step(index + 1))
        self.later(1.2, lambda: step(0))

    def ticker(self) -> None:
        last_chatter = time.time()
        while not self.closed:
            time.sleep(0.1)
            self.run_due()
            if self.chatter and time.time() - last_chatter > 60:
                last_chatter = time.time()
                with self.lock:
                    self.chatter_exchange()

    # ------------------------------------------------------------------ T3

    def thread_view(self, t: Dict[str, Any], *, for_summary: bool = False) -> Dict[str, Any]:
        view = {"threadId": t["threadId"], "title": t["title"], "status": t["status"], "updatedAt": iso(t["updatedAt"]),
                "summary": t["summary"]}
        if for_summary:
            view["project"] = t["projectName"]
            return view
        view["projectId"] = t["projectId"]
        view["projectName"] = t["projectName"]
        view["pending"] = t["pending"]
        return view

    RANK = {"needs_approval": 0, "needs_input": 1, "working": 2, "error": 3, "done": 4, "idle": 5}

    def sorted_threads(self) -> List[Dict[str, Any]]:
        return sorted(self.threads.values(), key=lambda t: (self.RANK.get(t["status"], 9), -t["updatedAt"]))

    def thread_or_404(self, tid: str) -> Dict[str, Any]:
        thread = self.threads.get(tid)
        if thread is None:
            raise ApiError(404, "thread_not_found", "No such task.")
        return thread

    def next_request_id(self, prefix: str = "req") -> str:
        self.request_seq += 1
        return "%s_%d_%s" % (prefix, self.request_seq, uuid.uuid4().hex[:6])

    def say(self, t: Dict[str, Any], role: str, text: str) -> None:
        t["messages"].append({"role": role, "text": text, "at": time.time()})
        t["updatedAt"] = time.time()

    def finish(self, tid: str, text: str, summary: str, status: str = "done") -> None:
        with self.lock:
            t = self.threads.get(tid)
            if t is None or t["status"] != "working":
                return
            self.say(t, "assistant", text)
            t["status"] = status
            t["summary"] = summary
            t["pending"] = None

    def place(self, text: str) -> Dict[str, Any]:
        lowered = text.lower()
        if re.search(r"\b(website|pricing|landing|login|css)\b", lowered):
            return self.projects[1]
        if re.search(r"\b(fix|bug|refactor|repo|test|pr|samrabbit|swift|android)\b", lowered):
            return self.projects[2]
        return self.projects[0]

    # ------------------------------------------------------------------ summary

    def upcoming(self, hours: float, *, include_all_day: bool = True) -> List[Dict[str, Any]]:
        now = time.time()
        horizon = now + hours * 3600
        items = []
        for ev in self.calendar:
            if ev["allDay"]:
                if include_all_day:
                    items.append((0.0, ev))
                continue
            if ev["_end"] > now and ev["_start"] < horizon:
                items.append((ev["_start"], ev))
        items.sort(key=lambda pair: pair[0])
        return [{k: v for k, v in ev.items() if not k.startswith("_")} for _, ev in items]

    def summary(self) -> Dict[str, Any]:
        threads = self.sorted_threads()
        live = [c for c in self.conversations.values() if c["live"]]
        latest = max(self.conversations.values(), key=lambda c: c["lastAt"]) if self.conversations else None
        return {
            "generatedAt": iso(time.time()),
            "mac": {"name": self.mac_name, "online": True, "screenLocked": self.screen_locked},
            "r1": {"lastSeenAt": iso(self.r1_seen), "live": bool(live),
                   "liveConversationId": live[0]["conversationId"] if live else None,
                   "liveTitle": live[0]["title"] if live else None},
            "t3": {"available": True,
                   "needsYou": sum(1 for t in threads if t["status"] in ("needs_approval", "needs_input")),
                   "working": sum(1 for t in threads if t["status"] == "working"),
                   "threads": [self.thread_view(t, for_summary=True) for t in threads[:5]]}
            if self.t3_available else
            {"available": False, "needsYou": 0, "working": 0, "threads": [], "reason": "t3_unavailable"},
            "calendar": {"available": True, "next": self.upcoming(36, include_all_day=False)[:3]},
            "latestConversation": {"conversationId": latest["conversationId"], "title": latest["title"],
                                   "lastAt": latest["lastAt"], "preview": latest["preview"]} if latest else None,
            "journal": {"available": True},
            **self.transcribe_part(),
            **self.assistant_part(),
        }

    def transcribe_part(self) -> Dict[str, Any]:
        """The summary's ``transcribe`` part (none for an older bridge, mode ``missing``)."""
        if self.transcribe_mode == "missing":
            return {}
        if self.transcribe_mode == "unavailable":
            return {"transcribe": {"available": False, "reason": "model_downloading"}}
        if self.transcribe_mode == "permission":
            return {"transcribe": {"available": False, "reason": "permission_denied"}}
        return {"transcribe": {"available": True}}

    def assistant_part(self) -> Dict[str, Any]:
        """The summary's ``assistant`` part (none for an older bridge, mode ``missing``)."""
        if self.assistant_mode == "missing":
            return {}
        part: Dict[str, Any] = {"available": self.assistant_mode != "unavailable", "brain": self.assistant_brain,
                                "model": "gpt-realtime-2.1" if self.assistant_brain == "realtime" else
                                "claude-haiku-5-5", "chatgpt": {"connected": self.assistant_brain == "realtime"}}
        if self.assistant_mode == "unavailable":
            part["reason"] = "chatgpt_not_connected"
        return {"assistant": part}

    def assistant_conversation(self, conversation_id: Optional[str], device: Dict[str, Any]) -> Dict[str, Any]:
        """A conversation of this device (a new one without an id; an id from another device is refused)."""
        with self.lock:
            if conversation_id:
                found = self.assistant_conversations.get(conversation_id)
                if found is not None:
                    if found["deviceId"] != device["deviceId"]:
                        raise ApiError(404, "conversation_not_found", "No such conversation.")
                    return found
            else:
                conversation_id = "wc_" + uuid.uuid4().hex[:16]
            # Like the real bridge: a conversation hears only of what happens after it began.
            found = {"conversationId": conversation_id, "deviceId": device["deviceId"], "active": None,
                     "cancel": threading.Event(), "announced": set(), "turns": 0, "ended": False,
                     "cursor": max([a["id"] for a in self.announcements] or [0])}
            self.assistant_conversations[conversation_id] = found
            return found

    def add_announcement(self, say: str, kind: str, thread_id: Optional[str], title: Optional[str],
                         audio: Any) -> Dict[str, Any]:
        with self.lock:
            self.announcement_seq += 1
            if audio == "broken":
                # An MP3 the watch can't read (the Claude path's voice, an unsupported encoder).
                clip: Optional[Dict[str, Any]] = {"mime": "audio/mpeg", "b64": base64.b64encode(
                    b"ID3\x03\x00\x00\x00\x00\x00\x00" + bytes(range(256)) * 8).decode("ascii")}
            elif audio:
                clip = {"mime": "audio/wav",
                        "b64": base64.b64encode(wav_bytes(speech_pcm(spoken_seconds(say)))).decode("ascii")}
            else:
                clip = None
            item = {"id": self.announcement_seq, "say": say, "kind": kind, "threadId": thread_id, "title": title,
                    "audio": clip}
            self.announcements.append(item)
            return item

    # ------------------------------------------------------------------ auth

    def device_for(self, token: str) -> Optional[Dict[str, Any]]:
        digest = sha(token.encode("utf-8"))
        for device in self.devices.values():
            if hmac.compare_digest(device["tokenHash"], digest):
                return device
        return None

    def issue(self, name: str, platform: str, parent: Optional[str] = None) -> Tuple[str, Dict[str, Any]]:
        token = "srm_" + secrets.token_urlsafe(32)
        device = {"deviceId": "dev_" + uuid.uuid4().hex[:12], "name": name[:60] or "iPhone", "platform": platform,
                  "createdAt": iso(time.time()), "lastSeenAt": iso(time.time()), "tokenHash": sha(token.encode())}
        if parent:
            device["parentId"] = parent
        with self.lock:
            if parent:
                # A phone that provisions its watch again replaces that watch's old token (real bridge rule;
                # at most 3 watches per phone).
                children = [d for d, item in self.devices.items() if item.get("parentId") == parent]
                same = [d for d in children if self.devices[d].get("name") == device["name"]]
                drop = same or children[:max(0, len(children) - 2)]
                for d in drop:
                    self.devices.pop(d, None)
            self.devices[device["deviceId"]] = device
            self._save_devices()
        return token, device

    def revoke(self, device_id: str) -> List[str]:
        """Removes a device and the devices it provisioned (its watch), like the real bridge."""
        with self.lock:
            gone = [d for d, item in self.devices.items() if d == device_id or item.get("parentId") == device_id]
            for d in gone:
                self.devices.pop(d, None)
            if gone:
                self._save_devices()
            return gone

    def hosts(self) -> List[str]:
        return self.advertise or ["127.0.0.1:%d" % self.port]


# --------------------------------------------------------------------------- HTTP

class Handler(BaseHTTPRequestHandler):
    server_version = "SamRabbitFakeBridge/1.0"
    protocol_version = "HTTP/1.1"
    bridge: FakeBridge  # set on the class by serve()
    quiet = False

    def log_message(self, fmt: str, *args: Any) -> None:  # never log bodies or tokens
        if not self.quiet:
            sys.stderr.write("fake-bridge %s %s\n" % (self.command, urlsplit(self.path).path))

    # ------------------------------------------------------------------ plumbing

    def send_json(self, status: int, payload: Any) -> None:
        body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        if status == 401:
            self.send_header("WWW-Authenticate", 'Bearer realm="samrabbit-bridge"')
        self.end_headers()
        self.wfile.write(body)

    def send_bytes(self, data: bytes, mime: str) -> None:
        self.send_response(200)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "private, max-age=3600")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(data)

    def body(self) -> Dict[str, Any]:
        length = int(self.headers.get("Content-Length") or 0)
        if length > 256 * 1024:
            raise ApiError(413, "too_large", "Request body too large.")
        raw = self.rfile.read(length) if length else b""
        self.consumed = True
        if not raw:
            return {}
        try:
            value = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            raise ApiError(400, "invalid_json", "The body must be JSON.") from None
        if not isinstance(value, dict):
            raise ApiError(400, "invalid_json", "The body must be a JSON object.")
        return value

    def optional_body(self) -> Dict[str, Any]:
        """Like the real bridge's ``_optional_body``: no body or whitespace is ``{}``, a JSON object is read,
        anything else that is not JSON answers 400 ``invalid_json``."""
        length = int(self.headers.get("Content-Length") or 0)
        if length > 64 * 1024:
            raise ApiError(413, "body_too_large", "The body must be at most 65536 bytes.")
        raw = self.rfile.read(length) if length else b""
        self.consumed = True
        if not raw.strip():
            return {}
        try:
            value = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            raise ApiError(400, "invalid_json", "The body must be a JSON object.") from None
        return value if isinstance(value, dict) else {}

    def query(self) -> Dict[str, List[str]]:
        return parse_qs(urlsplit(self.path).query)

    def q1(self, key: str, default: Optional[str] = None) -> Optional[str]:
        return (self.query().get(key) or [default])[0]

    def require_mobile(self) -> Dict[str, Any]:
        header = self.headers.get("Authorization") or ""
        token = header[7:].strip() if header.lower().startswith("bearer ") else ""
        device = self.bridge.device_for(token) if token else None
        if device is None:
            raise ApiError(401, "unauthorized", "Pair this device again.")
        device["lastSeenAt"] = iso(time.time())
        return device

    def require_desktop(self) -> None:
        if not loopback_peer(self.client_address[0]):
            raise ApiError(403, "forbidden", "Only available on this Mac.")
        if not hmac.compare_digest(self.headers.get("X-SamRabbit-Desktop") or "", DESKTOP_TOKEN):
            raise ApiError(401, "unauthorized", "Desktop token required.")

    # ------------------------------------------------------------------ dispatch

    def do_GET(self) -> None:
        self.dispatch("GET")

    def do_POST(self) -> None:
        self.dispatch("POST")

    def do_DELETE(self) -> None:
        self.dispatch("DELETE")

    def dispatch(self, method: str) -> None:
        path = urlsplit(self.path).path
        self.consumed = False
        try:
            if not private_peer(self.client_address[0]):
                raise ApiError(403, "forbidden_peer", "Only devices on your own network can use the bridge.")
            if path == "/health":
                return self.send_json(200, self.health())
            if path.startswith("/__fake/"):
                return self.fake(method, path)
            if path.startswith("/v1/desktop/assistant/"):
                self.require_desktop()
                return self.assistant(method, path[len("/v1/desktop/"):], MAC_DEVICE)
            if not path.startswith("/v1/mobile/"):
                raise ApiError(404, "not_found", "Not found.")
            self.mobile(method, path)
        except ApiError as error:
            try:
                self.send_json(error.status, {"error": {"code": error.code, "message": error.message,
                                                        "retryable": error.retryable}})
            except OSError:
                pass
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            self.finish_body()

    def finish_body(self) -> None:
        """Reads a request body no route read (``/__fake/reset {}``, a refused request), so the next request on a
        kept-alive connection starts where it should; a body too large to read closes the connection instead."""
        if self.consumed:
            return
        self.consumed = True
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = -1
        if 0 < length <= TRANSCRIBE_MAX_BYTES:
            try:
                self.rfile.read(length)
            except OSError:
                self.close_connection = True
        elif length:
            self.close_connection = True

    def health(self) -> Dict[str, Any]:
        return {"ok": True, "service": "samrabbit-bridge", "version": VERSION, "fake": True,
                "mobile": {"available": True, "devices": len(self.bridge.devices), "t3": {"paired": True, "ok": True}}}

    def fake(self, method: str, path: str) -> None:
        if not loopback_peer(self.client_address[0]):
            raise ApiError(403, "forbidden", "Loopback only.")
        b = self.bridge
        if path == "/__fake/reset" and method == "POST":
            b.seed()
            return self.send_json(200, {"ok": True})
        if path == "/__fake/journal" and method == "GET":
            return self.send_json(200, {"lines": list(b.journal)})
        if path == "/__fake/chatter" and method == "POST":
            with b.lock:
                b.chatter_exchange()
            return self.send_json(200, {"ok": True})
        if path == "/__fake/settle" and method == "POST":
            b.settle()
            return self.send_json(200, {"ok": True})
        if path == "/__fake/rerequest" and method == "POST":
            body = self.body()
            with b.lock:
                t = b.thread_or_404(str(body.get("threadId") or ""))
                old = t["pending"] or {"kind": "approval"}
                fresh = dict(old)
                fresh["requestId"] = b.next_request_id("req")
                if old["kind"] == "question":
                    fresh["questionId"] = "q_" + uuid.uuid4().hex[:6]
                fresh["text"] = str(body.get("text") or "") or (
                    "Run ./deploy.sh production (pushes build 2.4.0-rc1 to production)"
                    if old["kind"] == "approval" else "Which page should signed-in users land on?")
                t["pending"] = fresh
                t["status"] = "needs_input" if fresh["kind"] == "question" else "needs_approval"
                t["updatedAt"] = time.time()
                return self.send_json(200, {"ok": True, "requestId": fresh["requestId"]})
        if path == "/__fake/transcribe":
            if method == "POST":
                body = self.body()
                with b.lock:
                    mode = str(body.get("mode") or b.transcribe_mode)
                    if mode not in TRANSCRIBE_MODES:
                        raise ApiError(400, "invalid_mode", "mode must be one of " + ", ".join(TRANSCRIBE_MODES))
                    b.transcribe_mode = mode
                    if "text" in body:
                        b.transcript = str(body.get("text") or "")
                    if "delay" in body:
                        b.transcribe_delay = max(0.0, min(30.0, float(body.get("delay") or 0)))
            with b.lock:
                return self.send_json(200, {"mode": b.transcribe_mode, "text": b.transcript,
                                            "delay": b.transcribe_delay, "uploads": list(b.uploads)})
        if path == "/__fake/assistant":
            if method == "POST":
                body = self.body()
                with b.lock:
                    mode = str(body.get("mode") or b.assistant_mode)
                    if mode not in ASSISTANT_MODES:
                        raise ApiError(400, "invalid_mode", "mode must be one of " + ", ".join(ASSISTANT_MODES))
                    b.assistant_mode = mode
                    if "say" in body:
                        b.assistant_say = str(body.get("say") or "")
                    if "heard" in body:
                        b.assistant_heard = str(body.get("heard") or "")
                    if "delay" in body:
                        b.assistant_delay = max(0.0, min(30.0, float(body.get("delay") or 0)))
                    if "pace" in body:
                        b.assistant_pace = max(0.0, min(2.0, float(body.get("pace") or 0)))
                    if body.get("brain") in ("realtime", "claude"):
                        b.assistant_brain = str(body["brain"])
                    if "code" in body:
                        b.assistant_code = str(body.get("code") or "assistant_failed")
                    if "hold" in body:
                        b.assistant_hold = max(0.0, min(120.0, float(body.get("hold") or 0)))
                    if "ping" in body:
                        b.assistant_ping = max(0.0, min(60.0, float(body.get("ping") or 0)))
                    if "busyFor" in body:
                        b.assistant_busy_for = max(0.0, min(60.0, float(body.get("busyFor") or 0)))
                        b.assistant_busy_until = 0.0
                    if body.get("clear"):
                        for log in b.assistant_log.values():
                            del log[:]
            with b.lock:
                return self.send_json(200, {"mode": b.assistant_mode, "say": b.assistant_say,
                                            "heard": b.assistant_heard, "delay": b.assistant_delay,
                                            "pace": b.assistant_pace, "brain": b.assistant_brain,
                                            "code": b.assistant_code, "hold": b.assistant_hold,
                                            "ping": b.assistant_ping,
                                            "busy": max(b.assistant_busy_for, b.assistant_busy_until - time.time()),
                                            **{k: list(v) for k, v in b.assistant_log.items()}})
        if path == "/__fake/announce" and method == "POST":
            body = self.body()
            audio = body.get("audio")
            item = b.add_announcement(str(body.get("say") or "“Fix login redirect” in Hermes finished."),
                                      str(body.get("kind") or "done"), body.get("threadId") or "t_login",
                                      body.get("title") or "Fix login redirect",
                                      "broken" if audio == "broken" else bool(audio))
            return self.send_json(200, {"ok": True, "id": item["id"]})
        if path == "/__fake/t3" and method == "POST":
            with b.lock:
                b.t3_available = bool(self.body().get("available", True))
            return self.send_json(200, {"ok": True, "available": b.t3_available})
        raise ApiError(404, "not_found", "Not found.")

    def mobile(self, method: str, path: str) -> None:
        b = self.bridge
        rest = path[len("/v1/mobile/"):]
        # --- pairing (no mobile token)
        if rest == "pairing/start":
            self.only(method, "POST")
            self.require_desktop()
            hosts = b.hosts()
            url = "samrabbit://pair?h=%s&c=%s&n=%s" % (",".join(hosts), b.code, quote(b.mac_name, safe=""))
            return self.send_json(200, {"code": b.code, "expiresAt": iso(time.time() + 600), "pairUrl": url,
                                        "hosts": hosts})
        if rest == "pair":
            self.only(method, "POST")
            return self.pair()
        if rest == "devices" and method == "GET":
            self.require_desktop()
            return self.send_json(200, {"devices": [{k: v for k, v in d.items() if k != "tokenHash"}
                                                    for d in b.devices.values()]})
        if rest.startswith("devices/") and method == "DELETE" and rest != "devices/child":
            self.require_desktop()
            removed = b.revoke(unquote(rest[len("devices/"):]))
            if not removed:
                raise ApiError(404, "device_not_found", "No such device.")
            return self.send_json(200, {"ok": True, "revoked": len(removed)})

        device = self.require_mobile()
        if rest == "devices/child":
            # Like the real bridge: only a paired iPhone (not a watch) adds its watch, and a new token for the
            # same name replaces that phone's earlier watch (its old token stops working).
            self.only(method, "POST")
            if device.get("parentId") or device.get("platform") != "ios":
                raise ApiError(403, "forbidden", "Only a paired iPhone can add its watch.")
            body = self.body()
            if (body.get("platform") or "watchos") != "watchos":
                raise ApiError(400, "invalid_platform", "platform must be watchos.")
            token, child = b.issue(str(body.get("name") or "Apple Watch")[:60] or "Apple Watch", "watchos",
                                   parent=device["deviceId"])
            return self.send_json(200, {"token": token, "deviceId": child["deviceId"], "bridgeName": b.mac_name,
                                        "bridgeVersion": VERSION})
        if rest == "unpair":
            # A device forgets itself (an iPhone takes its watch with it). The body is read like the real bridge
            # does (an empty or JSON-object body), so a kept-alive connection stays in step.
            self.only(method, "POST")
            self.optional_body()
            removed = b.revoke(device["deviceId"])
            return self.send_json(200, {"ok": True, "revoked": len(removed)})
        if rest == "summary":
            with b.lock:
                return self.send_json(200, b.summary())
        if rest == "transcribe":
            return self.transcribe(method, device)
        if rest.startswith("assistant/"):
            return self.assistant(method, rest, device)
        if rest == "stream":
            return self.stream()
        if rest == "conversations" or rest.startswith("conversations/"):
            return self.conversations(rest)
        if rest.startswith("blobs/"):
            digest = rest[len("blobs/"):].replace("sha256:", "")
            found = b.blobs.get(digest)
            if found is None:
                raise ApiError(404, "blob_not_found", "No such blob.", retryable=True)
            return self.send_bytes(found[1], found[0])
        if rest.startswith("ui/"):
            return self.ui(method, rest)
        if rest.startswith("t3/"):
            return self.t3(method, rest)
        if rest.startswith("calendar/"):
            return self.calendar(method, rest)
        if rest == "journal":
            self.only(method, "POST")
            text = str(self.body().get("text") or "").strip()
            if not text:
                raise ApiError(400, "empty_text", "Say what to add.")
            if len(text) > 4000:
                raise ApiError(400, "too_long", "Keep notes under 4000 characters.")
            line = "**%s** %s" % (datetime.now().strftime("%H:%M"), text)
            with b.lock:
                b.journal.append(line)
            return self.send_json(200, {"recorded": True, "state": "sent",
                                        "date": datetime.now().strftime("%Y-%m-%d")})
        if rest.startswith("mac/"):
            return self.mac(method, rest)
        raise ApiError(404, "not_found", "Not found.")

    @staticmethod
    def only(method: str, expected: str) -> None:
        if method != expected:
            raise ApiError(405, "method_not_allowed", "Use %s." % expected)

    def pair(self) -> None:
        # The real bridge's answers: 429 ``pairing_rate_limited`` after 10 wrong codes in 10 minutes (checked
        # first), 401 ``invalid_code`` for a wrong, used or expired code.
        b = self.bridge
        now = time.time()
        with b.lock:
            b.bad_codes_all = [t for t in b.bad_codes_all if now - t < 600]
            if len(b.bad_codes_all) >= 10:
                raise ApiError(429, "pairing_rate_limited", "Too many wrong codes. Wait a few minutes, then make a "
                               "new code on the Mac.", retryable=True)
        body = self.body()
        code = re.sub(r"[\s-]", "", str(body.get("code") or "")).upper()
        platform = body.get("platform")
        if platform not in ("ios", "watchos"):
            raise ApiError(400, "invalid_platform", "platform must be ios or watchos.")
        valid = len(code) == 8 and all(ch in CODE_ALPHABET for ch in code)
        if not valid or code != b.code or (b.single_use and code in b.used_codes):
            with b.lock:
                b.bad_codes_all.append(now)
            raise ApiError(401, "invalid_code", "That code is wrong or expired. Make a new one on the Mac.")
        if b.single_use:
            b.used_codes.add(code)
        token, device = b.issue(str(body.get("deviceName") or "iPhone"), platform)
        self.send_json(200, {"token": token, "deviceId": device["deviceId"], "bridgeName": b.mac_name,
                             "bridgeVersion": VERSION})

    # ------------------------------------------------------------------ conversations and SSE

    def conversations(self, rest: str) -> None:
        b = self.bridge
        if rest == "conversations":
            limit = max(1, min(200, int(self.q1("limit", "50") or 50)))
            before = self.q1("before")
            with b.lock:
                items = b.conversation_list(limit, int(before) if before and before.isdigit() else None,
                                            (self.q1("q", "") or "").strip()[:100])
                payload = {"conversations": items, "cursor": b.cursor}
            if len(items) == limit:
                payload["nextBefore"] = items[-1]["lastAt"]
            return self.send_json(200, payload)
        tail = rest[len("conversations/"):]
        cid, _, sub = tail.partition("/")
        cid = unquote(cid)
        with b.lock:
            conv = b.conversations.get(cid)
            if conv is None:
                raise ApiError(404, "conversation_not_found", "No such conversation.")
            if sub == "":
                return self.send_json(200, {"conversation": dict(conv)})
            if sub != "events":
                raise ApiError(404, "not_found", "Not found.")
            after = int(self.q1("after", "0") or 0)
            limit = max(1, min(500, int(self.q1("limit", "200") or 200)))
            if after > b.cursor:
                after = 0
            rows = b.events_after(after, cid, limit + 1)
            more = len(rows) > limit
            rows = rows[:limit]
            cursor = rows[-1][0] if more else max(after, b.cursor)
            events = [dict(p, cursor=n) for n, p in rows]
        self.send_json(200, {"events": events, "cursor": cursor, "more": more})

    def stream(self) -> None:
        b = self.bridge
        after = self.q1("after")
        if after is None:
            last = (self.headers.get("Last-Event-ID") or "").strip()
            after = last if last.isdigit() else None
        with b.lock:
            cursor = b.cursor if after is None or not str(after).isdigit() or int(after) > b.cursor else int(after)
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        try:
            self.wfile.write(("retry: 2000\n: ready %d\n\n" % cursor).encode("utf-8"))
            self.wfile.flush()
            beat = time.time()
            while not b.closed:
                with b.changed:
                    rows = b.events_after(cursor, None, 200)
                    if not rows:
                        b.changed.wait(timeout=1.0)
                        rows = b.events_after(cursor, None, 200)
                if rows:
                    chunk = "".join("id: %d\nevent: sync\ndata: %s\n\n" %
                                    (n, json.dumps(dict(p, cursor=n), ensure_ascii=False, separators=(",", ":")))
                                    for n, p in rows)
                    self.wfile.write(chunk.encode("utf-8"))
                    self.wfile.flush()
                    cursor = rows[-1][0]
                    beat = time.time()
                elif time.time() - beat >= HEARTBEAT_SECONDS:
                    self.wfile.write(b": heartbeat\n\n")
                    self.wfile.flush()
                    beat = time.time()
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass

    # ------------------------------------------------------------------ generated UI

    def ui(self, method: str, rest: str) -> None:
        b = self.bridge
        if rest == "ui/generate":
            self.only(method, "POST")
            body = self.body()
            prompt = str(body.get("prompt") or "").strip()
            if not prompt:
                raise ApiError(400, "invalid_prompt", "Describe what to show.")
            art = "ui_" + uuid.uuid4().hex[:24]
            release = bool(re.search(r"release|checklist|deploy|launch|steps", prompt, re.I))
            with b.lock:
                phone = "c_phone0001"
                if phone not in b.conversations:
                    b.add_conversation(phone, "Phone", now_ms())
                b.artifacts[art] = {"artifactId": art, "status": "generating", "title": "", "summary": "",
                                    "conversationId": phone, "createdAt": iso(time.time())}
                b.emit(phone, {"type": "message.user", "text": prompt, "origin": "phone"})
                b.emit(phone, {"type": "ui.generating", "artifactId": art, "prompt": prompt[:300]})

            def ready() -> None:
                with b.lock:
                    title = "Release 2.4 checklist" if release else "Your visual"
                    summary = "4 of 6 steps done; production deploy waits for approval." if release else \
                        "Made from: " + prompt[:80]
                    blob = b.release_jpg if release else b.focus_jpg
                    size = (960, 560) if release else (960, 620)
                    b.artifacts[art].update({"status": "ready", "title": title, "summary": summary,
                                             "imageBlobId": blob, "width": size[0], "height": size[1]})
                    b.documents[art] = chart_document(
                        title, summary, ["Tests", "Docs", "Staging", "Smoke", "Prod", "Announce"] if release
                        else ["Mon", "Tue", "Wed", "Thu", "Fri"],
                        [1, 1, 1, 1, 0, 0] if release else [3, 5, 2, 6, 4], "done" if release else "points")
                    b.emit("c_phone0001", {"type": "ui.generated", "artifactId": art, "title": title,
                                           "summary": summary, "imageBlobId": blob, "width": size[0],
                                           "height": size[1]})
            b.later(4.0, ready)
            return self.send_json(202, {"artifactId": art, "status": "generating"})
        match = re.match(r"^ui/artifacts/(ui_[0-9a-f]{24})(/image|/document)?$", rest)
        if not match or method != "GET":
            raise ApiError(404, "not_found", "Not found.")
        art, sub = match.group(1), match.group(2)
        with b.lock:
            meta = b.artifacts.get(art)
            if meta is None:
                raise ApiError(404, "artifact_not_found", "No such visual.")
            if not sub:
                return self.send_json(200, dict(meta))
            if meta["status"] != "ready":
                raise ApiError(409, "image_not_ready" if sub == "/image" else "document_not_ready",
                               "The visual is not ready yet.", retryable=True)
            if sub == "/image":
                mime, data = b.blobs[meta["imageBlobId"].replace("sha256:", "")]
                return self.send_bytes(data, mime)
            document = b.documents[art].encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(document)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(document)

    # ------------------------------------------------------------------ T3

    def t3(self, method: str, rest: str) -> None:
        b = self.bridge
        if not b.t3_available:  # what the real bridge answers while T3 Code is not running
            raise ApiError(503, "t3_unavailable", "T3 Code on the Mac is not answering. Is the T3 Code app running?",
                           retryable=True)
        if rest == "t3/projects":
            self.only(method, "GET")
            return self.send_json(200, {"projects": b.projects})
        if rest == "t3/threads":
            if method == "GET":
                flt = self.q1("filter")
                with b.lock:
                    items = b.sorted_threads()
                    if flt == "needs_you":
                        items = [t for t in items if t["status"] in ("needs_approval", "needs_input")]
                    elif flt == "working":
                        items = [t for t in items if t["status"] == "working"]
                    elif flt == "recent":
                        items = sorted([t for t in items if t["status"] in ("done", "error", "idle")],
                                       key=lambda t: -t["updatedAt"])
                    elif flt:
                        raise ApiError(400, "invalid_filter", "filter must be needs_you, working or recent.")
                    return self.send_json(200, {"threads": [b.thread_view(t) for t in items]})
            self.only(method, "POST")
            body = self.body()
            text = str(body.get("text") or "").strip()
            if not text:
                raise ApiError(400, "empty_text", "Say what to do.")
            with b.lock:
                project = next((p for p in b.projects if p["projectId"] == body.get("projectId")), None) \
                    or b.place(text)
                tid = "t_" + uuid.uuid4().hex[:10]
                title = text if len(text) <= 60 else text[:57].rstrip() + "…"
                title = title[0].upper() + title[1:]
                b.threads[tid] = {"threadId": tid, "title": title, "projectId": project["projectId"],
                                  "projectName": project["name"], "status": "working", "updatedAt": time.time(),
                                  "summary": "Starting…", "pending": None,
                                  "messages": [{"role": "user", "text": text, "at": time.time()}]}

            def progress(summary: str, line: Optional[str]) -> Callable[[], None]:
                def step() -> None:
                    with b.lock:
                        t = b.threads.get(tid)
                        if t and t["status"] == "working":
                            t["summary"] = summary
                            t["updatedAt"] = time.time()
                            if line:
                                b.say(t, "assistant", line)
                return step
            # About 45 s from start to finish, so phones can show the task running (Live Activity).
            b.later(3.0, progress("Reading the project and planning…", "Looking into it. I'll report back here."))
            b.later(18.0, progress("Making the changes (2 of 3)…", None))
            b.later(32.0, progress("Checking the result…", None))
            b.later(45.0, lambda: b.finish(tid, "Done. Here is what I did:\n\n- Read the request\n- Made the change\n"
                                                "- Checked it\n\n**All set.**", "Finished: all set."))
            return self.send_json(202, {"threadId": tid, "title": title, "projectName": project["name"]})
        match = re.match(r"^t3/threads/([A-Za-z0-9_-]{1,64})(?:/(message|respond|stop))?$", rest)
        if not match:
            raise ApiError(404, "not_found", "Not found.")
        tid, action = match.group(1), match.group(2)
        with b.lock:
            t = b.thread_or_404(tid)
            if action is None:
                self.only(method, "GET")
                messages = [{"role": m["role"], "text": m["text"], "at": iso(m["at"])} for m in t["messages"]]
                return self.send_json(200, {"thread": b.thread_view(t), "messages": messages[-40:],
                                            "pending": t["pending"]})
            self.only(method, "POST")
            body = self.body()
            if action == "message":
                text = str(body.get("text") or "").strip()
                if not text:
                    raise ApiError(400, "empty_text", "Say something.")
                b.say(t, "user", text)
                t["status"], t["pending"], t["summary"] = "working", None, "Working on your reply…"
                b.later(5.0, lambda: b.finish(tid, "Got it — done. " + ("I followed your note: “%s”." % text[:80]),
                                              "Replied to your message."))
                return self.send_json(202, {"ok": True})
            if action == "stop":
                if t["status"] != "working":
                    raise ApiError(409, "not_running", "That task is not running.")
                t["status"], t["summary"] = "idle", "Stopped from iPhone."
                b.say(t, "assistant", "Stopped.")
                return self.send_json(200, {"ok": True})
            # respond: like the real bridge, a requestId that is not the open request is refused (409), and
            # without one the open request of the right kind is answered.
            pending = t["pending"]
            wanted = body.get("requestId")
            if wanted is not None and not isinstance(wanted, str):
                raise ApiError(400, "invalid_request", "requestId must be a string.")
            if body.get("decision") is None and body.get("answer") is None:
                raise ApiError(400, "invalid_request", "Send {decision: approve|deny} or {answer}.")
            approving = body.get("decision") is not None
            kind = "approval" if approving else "question"
            if not pending or pending["kind"] != kind or wanted not in (None, pending.get("requestId")):
                raise ApiError(409, "t3_request_not_pending", "That %s is no longer pending." % kind)
            if approving:
                decision = body.get("decision")
                if decision not in ("approve", "deny"):
                    raise ApiError(400, "invalid_decision", "decision must be approve or deny.")
                t["pending"] = None
                if decision == "approve":
                    t["status"], t["summary"] = "working", "Approved; deploying…"
                    b.say(t, "user", "Approved.")
                    b.later(6.0, lambda: b.finish(tid, "Deployed **2.4.0-rc1** to staging. Smoke tests pass.",
                                                  "Deployed to staging; smoke tests pass."))
                else:
                    t["status"], t["summary"] = "done", "Denied: nothing was deployed."
                    b.say(t, "user", "Denied.")
                    b.say(t, "assistant", "Okay, I won't deploy. Nothing changed on staging.")
                return self.send_json(200, {"ok": True})
            answer = body.get("answer")
            if isinstance(answer, list):
                answer = ", ".join(str(a) for a in answer)
            answer = str(answer or "").strip()
            if not answer:
                raise ApiError(400, "empty_answer", "Give an answer.")
            t["pending"] = None
            t["status"], t["summary"] = "working", "Applying your answer…"
            b.say(t, "user", answer)
            b.later(6.0, lambda: b.finish(tid, "Updated: users without `next` now land on `%s`. Tests pass." %
                                          answer[:40], "Done: default landing page is %s." % answer[:40]))
            return self.send_json(200, {"ok": True})

    # ------------------------------------------------------------------ calendar

    # ------------------------------------------------------------------ voice

    def transcribe(self, method: str, device: Dict[str, Any]) -> None:
        """``POST /v1/mobile/transcribe``: the real bridge's checks, then canned words (see ``/__fake/transcribe``)."""
        b = self.bridge
        self.only(method, "POST")
        with b.lock:
            mode, text, delay = b.transcribe_mode, b.transcript, b.transcribe_delay
        if mode == "missing":
            self.drain()
            raise ApiError(404, "not_found", "Not found.")
        declared = TRANSCRIBE_TYPES.get((self.headers.get("Content-Type") or "").split(";", 1)[0].strip().lower())
        if declared is None:
            self.drain()
            raise ApiError(415, "unsupported_audio", "Send the recording as audio/mp4, audio/x-m4a, audio/wav or "
                           "audio/aac.")
        lang = (self.q1("lang") or "").strip()
        if lang and not _LANG.match(lang):
            self.drain()
            raise ApiError(400, "invalid_lang", "lang must be a language tag such as en-US.")
        if self.headers.get("Transfer-Encoding"):
            raise ApiError(411, "length_required", "Send a Content-Length body.")
        length = int(self.headers.get("Content-Length") or 0)
        if length > TRANSCRIBE_MAX_BYTES:
            raise ApiError(413, "body_too_large", "The body must be at most %d bytes." % TRANSCRIBE_MAX_BYTES)
        if not length:
            raise ApiError(400, "invalid_audio", "Send the recording as the request body.")
        data = self.rfile.read(length)
        self.consumed = True
        if len(data) != length:
            raise ApiError(400, "invalid_audio", "The recording did not arrive completely.", retryable=True)
        kind = sniff_audio(data)
        if kind is None:
            raise ApiError(415, "unsupported_audio", "The body is not an m4a, WAV or AAC recording.")
        seconds = mp4_seconds(data) if kind == "mp4" else None
        if seconds is not None and seconds > TRANSCRIBE_MAX_SECONDS:
            raise ApiError(413, "audio_too_long", "Recordings can be at most 90 seconds.")
        with b.lock:
            b.uploads.append({"bytes": length, "contentType": self.headers.get("Content-Type"), "kind": kind,
                              "lang": lang or None, "deviceId": device["deviceId"], "platform": device.get("platform"),
                              "parentId": device.get("parentId"), "seconds": seconds})
            del b.uploads[:-20]
        if delay:
            time.sleep(delay)
        failure = TRANSCRIBE_FAILURES.get(mode)
        if failure:
            status, code, message, retryable, reason = failure
            error: Dict[str, Any] = {"code": code, "message": message, "retryable": retryable}
            if reason:
                error["reason"] = reason
            return self.send_json(status, {"error": error})
        return self.send_json(200, {"text": "" if mode == "empty" else text,
                                    "durationMs": int((seconds or 0) * 1000), "engine": "FakeTranscriber",
                                    "locale": lang or "en-US"})

    def drain(self) -> None:
        """Reads a body that is refused before it is used (keeps a kept-alive connection in step)."""
        self.finish_body()

    # ------------------------------------------------------------------ the voice assistant

    def assistant(self, method: str, rest: str, device: Dict[str, Any]) -> None:
        b = self.bridge
        with b.lock:
            mode = b.assistant_mode
        if mode == "missing":
            self.drain()
            raise ApiError(404, "not_found", "Not found.")
        if rest == "assistant/turn":
            self.only(method, "POST")
            return self.assistant_turn(device, mode)
        if rest == "assistant/announcements":
            self.only(method, "GET")
            conversation_id = (self.q1("conversationId") or "").strip()
            if not _CONVERSATION_ID.match(conversation_id):
                raise ApiError(400, "invalid_conversation", "conversationId is required.")
            since = (self.q1("since") or "").strip()
            if since and not since.isdigit():
                raise ApiError(400, "invalid_since", "since must be the cursor of the last answer.")
            conversation = b.assistant_conversation(conversation_id, device)
            with b.lock:
                items = [dict(a) for a in b.announcements
                         if a["id"] > conversation["cursor"] and a["id"] not in conversation["announced"]
                         and (not since or a["id"] > int(since))]
                for item in items:
                    conversation["announced"].add(item["id"])
                cursor = max([a["id"] for a in b.announcements] or [0])
            return self.send_json(200, {"items": items, "cursor": cursor})
        body = self.body()
        self.only(method, "POST")
        conversation_id = body.get("conversationId")
        if rest == "assistant/session":
            if mode == "unavailable":
                raise ApiError(503, "assistant_unavailable", "Connect ChatGPT on the Mac first.")
            if conversation_id is not None and (not isinstance(conversation_id, str) or
                                                not _CONVERSATION_ID.match(conversation_id)):
                raise ApiError(400, "invalid_conversation", "The conversation id must be 3 to 57 letters, digits, "
                               "- or _.")
            conversation = b.assistant_conversation(conversation_id or None, device)
            with b.lock:
                conversation["ended"] = False
                b.assistant_log["sessions"].append({"conversationId": conversation["conversationId"],
                                                    "continued": bool(conversation_id),
                                                    "deviceId": device["deviceId"]})
            return self.send_json(200, {"conversationId": conversation["conversationId"], "brain": b.assistant_brain,
                                        "ready": True})
        if not isinstance(conversation_id, str) or not _CONVERSATION_ID.match(conversation_id):
            raise ApiError(400, "invalid_conversation", "conversationId is required.")
        with b.lock:
            found = b.assistant_conversations.get(conversation_id)
            mine = found is not None and found["deviceId"] == device["deviceId"]
        if rest == "assistant/cancel":
            cancelled = bool(mine and found["active"])
            if cancelled:
                found["cancel"].set()
            with b.lock:
                b.assistant_log["cancels"].append({"conversationId": conversation_id, "cancelled": cancelled})
            return self.send_json(200, {"ok": True, "cancelled": cancelled})
        if rest == "assistant/end":
            if mine:
                found["ended"] = True
            with b.lock:
                b.assistant_log["ends"].append({"conversationId": conversation_id, "ended": mine})
            return self.send_json(200, {"ok": True, "ended": mine})
        raise ApiError(404, "not_found", "Not found.")

    def assistant_turn(self, device: Dict[str, Any], mode: str) -> None:
        """``POST /v1/mobile/assistant/turn``: the real bridge's checks, then a canned answer, streamed or buffered."""
        b = self.bridge
        declared = (self.headers.get("Content-Type") or "").split(";", 1)[0].strip().lower()
        header_conversation = (self.headers.get("X-SamRabbit-Conversation") or "").strip() or None
        header_turn = (self.headers.get("X-SamRabbit-Turn") or "").strip() or None
        device_time = self.headers.get("X-SamRabbit-Device-Time")
        if device_time is not None and len(device_time) > 64:
            self.drain()
            raise ApiError(400, "invalid_device_time", "X-SamRabbit-Device-Time is too long.")
        record: Dict[str, Any] = {"deviceId": device["deviceId"], "platform": device.get("platform"),
                                  "parentId": device.get("parentId"), "deviceTime": bool(device_time),
                                  "accept": self.headers.get("Accept"), "lang": self.q1("lang")}
        text: Optional[str] = None
        announce: Optional[Dict[str, Any]] = None
        if declared in ASSISTANT_TYPES:
            if self.headers.get("Transfer-Encoding"):
                raise ApiError(411, "length_required", "Send a Content-Length body.")
            length = int(self.headers.get("Content-Length") or 0)
            if length > ASSISTANT_MAX_BYTES:
                raise ApiError(413, "body_too_large", "The body must be at most %d bytes." % ASSISTANT_MAX_BYTES)
            if not length:
                raise ApiError(400, "invalid_audio", "Send the recording as the request body.")
            data = self.rfile.read(length)
            self.consumed = True
            if len(data) != length:
                raise ApiError(400, "invalid_audio", "The recording did not arrive completely.", retryable=True)
            kind = sniff_audio(data)
            if kind is None or kind != ASSISTANT_TYPES[declared]:
                raise ApiError(415, "unsupported_audio", "The body is not the %s it says it is." % declared)
            seconds = wav_seconds(data) if kind == "wav" else mp4_seconds(data)
            if seconds is not None and seconds > ASSISTANT_MAX_SECONDS:
                raise ApiError(413, "audio_too_long", "Say it in at most 60 seconds.")
            record.update({"kind": "audio", "bytes": length, "contentType": declared, "seconds": seconds})
            conversation_id, turn_id = header_conversation, header_turn
        elif declared in ("application/json", ""):
            body = self.body()
            conversation_id = body.get("conversationId", header_conversation)
            turn_id = body.get("turnId", header_turn)
            if "announce" in body:
                wanted = str(body.get("announce") or "")
                with b.lock:
                    announce = next((dict(a) for a in b.announcements if str(a["id"]) == wanted), None)
                if announce is None:
                    raise ApiError(404, "announcement_not_found", "No such announcement.")
                record.update({"kind": "announce", "announce": wanted})
            else:
                text = body.get("text")
                if not isinstance(text, str) or len(text) > 4000 or "\x00" in text:
                    raise ApiError(400, "invalid_text", "text must be at most 4000 characters.")
                record.update({"kind": "text", "chars": len(text)})
            if conversation_id is not None and not isinstance(conversation_id, str):
                raise ApiError(400, "invalid_conversation", "conversationId must be an id.")
            if turn_id is not None and not isinstance(turn_id, str):
                raise ApiError(400, "invalid_turn", "turnId must be a uuid.")
            conversation_id = (conversation_id or "").strip() or None
        else:
            self.drain()
            raise ApiError(415, "unsupported_media", "Send audio/wav, audio/mp4 or audio/x-m4a, or JSON text.")
        if conversation_id is not None and not _CONVERSATION_ID.match(conversation_id):
            raise ApiError(400, "invalid_conversation", "The conversation id must be 3 to 57 letters, digits, - or _.")
        if not turn_id or not _TURN_ID.match(turn_id):
            raise ApiError(400, "invalid_turn", "Send X-SamRabbit-Turn (or turnId): a uuid for this turn.")
        if mode == "drop":
            # The Mac goes away mid-request: no answer at all.
            self.close_connection = True
            return
        if mode == "unavailable":
            raise ApiError(503, "assistant_unavailable", "Connect ChatGPT on the Mac first.")
        with b.lock:
            if b.assistant_busy_for:
                b.assistant_busy_until = time.time() + b.assistant_busy_for
                b.assistant_busy_for = 0.0
            busy = time.time() < b.assistant_busy_until
        if mode == "busy" or busy:
            with b.lock:
                b.assistant_log["refused"].append(dict(record, turnId=turn_id, code="assistant_busy"))
                del b.assistant_log["refused"][:-40]
            raise ApiError(409, "assistant_busy", "Still answering the last thing you said.", retryable=True)
        conversation = b.assistant_conversation(conversation_id, device)
        key = (device["deviceId"], turn_id)
        with b.lock:
            answer = b.assistant_turns.get(key)
            replay = answer is not None
            if not replay:
                if conversation["active"] and conversation["active"] != turn_id:
                    raise ApiError(409, "assistant_busy", "Still answering the last thing you said.", retryable=True)
                answer = self.assistant_answer(mode, text, announce)
                answer.update({"conversationId": conversation["conversationId"], "turnId": turn_id})
                b.assistant_turns[key] = answer
                conversation["active"] = turn_id
                conversation["cancel"].clear()
                conversation["turns"] += 1
            record.update({"turnId": turn_id, "conversationId": conversation["conversationId"], "replay": replay,
                           "mode": mode})
            b.assistant_log["turns"].append(record)
            del b.assistant_log["turns"][:-40]
        streamed = STREAM_TYPE in (self.headers.get("Accept") or "") and not mode.startswith("buffered")
        record["stream"] = streamed
        try:
            if answer["delay"]:
                time.sleep(answer["delay"])
            if streamed:
                record["interrupted"] = self.stream_answer(answer, conversation)
            else:
                record["interrupted"] = False
                self.send_json(200, self.buffered_answer(answer, clip=mode == "buffered_clip"))
        finally:
            with b.lock:
                if conversation["active"] == turn_id:
                    conversation["active"] = None

    def assistant_answer(self, mode: str, text: Optional[str], announce: Optional[Dict[str, Any]]) -> Dict[str, Any]:
        """What a turn answers (the same again for a retry of the turn)."""
        b = self.bridge
        heard = text if text is not None else b.assistant_heard
        say = b.assistant_say
        end = False
        actions: List[Dict[str, Any]] = []
        cards: List[Dict[str, Any]] = []
        if announce is not None:
            heard, say = "", announce["say"]
        elif mode == "noise":
            heard, say = "", ""
        elif mode == "end":
            heard, say, end = heard or "Thanks, that's all", "Okay. Talk soon.", True
        elif re.search(r"\b(task|draft|notes|start)\b", heard, re.I):
            actions.append({"kind": "t3.started", "title": "Release notes for build 2.4", "threadId": "t_relnotes",
                            "projectName": "Hermes"})
        if re.search(r"\b(calendar|next|meeting)\b", heard, re.I):
            cards.append({"title": "Up next", "body": "Design review at 3:00 PM"})
            if say == DEFAULT_SAY and not actions:
                say = "Next up is the design review at three. Want me to block time before it?"
        return {"heard": heard, "say": say, "end": end, "actions": actions, "cards": cards,
                "audio": mode not in ("noaudio", "noise", "error"), "error": mode == "error",
                "code": b.assistant_code, "hold": b.assistant_hold, "ping": b.assistant_ping,
                "delay": 4.0 if mode == "slow" else b.assistant_delay, "brain": b.assistant_brain}

    def buffered_answer(self, answer: Dict[str, Any], clip: bool) -> Dict[str, Any]:
        audio = None
        if answer["audio"] and answer["say"]:
            if clip:
                audio = {"mime": "audio/mp4", "b64": base64.b64encode(read_fixture("assistant-reply.m4a")).decode()}
            else:
                audio = {"mime": "audio/wav",
                         "b64": base64.b64encode(wav_bytes(speech_pcm(spoken_seconds(answer["say"])))).decode()}
        if answer["error"]:
            status = 503 if answer["code"] == "assistant_unavailable" else 502
            raise ApiError(status, answer["code"], "The assistant could not answer.", retryable=True)
        return {"conversationId": answer["conversationId"], "turnId": answer["turnId"], "heard": answer["heard"],
                "say": answer["say"], "audio": audio, "expectReply": answer["say"].rstrip().endswith("?"),
                "endConversation": answer["end"], "actions": answer["actions"], "cards": answer["cards"],
                "brain": "claude" if clip else answer["brain"], "timings": {"stt": 180, "agent": 900, "tts": 300}}

    def stream_answer(self, answer: Dict[str, Any], conversation: Dict[str, Any]) -> bool:
        """Streams the frames; returns whether the turn was cancelled (``POST /assistant/cancel``)."""
        b = self.bridge
        started = time.time()
        self.send_response(200)
        self.send_header("Content-Type", STREAM_TYPE)
        self.send_header("Transfer-Encoding", "chunked")
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()

        def write(data: bytes) -> None:
            self.wfile.write(b"%x\r\n" % len(data) + data + b"\r\n")
            self.wfile.flush()

        interrupted = False
        first_audio = None
        try:
            write(event_frame({"type": "heard", "text": answer["heard"]}))
            # A long tool call: nothing to say for a while, only keep-alive pings (none from an older bridge).
            quiet_until = time.time() + answer["hold"]
            next_ping = time.time() + (answer["ping"] or answer["hold"] + 1)
            while time.time() < quiet_until and not conversation["cancel"].is_set():
                time.sleep(max(0.0, min(0.1, quiet_until - time.time())))
                if answer["ping"] and time.time() >= next_ping:
                    write(event_frame({"type": "ping"}))
                    next_ping += answer["ping"]
            if answer["error"]:
                write(event_frame({"type": "error", "code": answer["code"],
                                   "message": "The realtime session failed."}))
            else:
                say = answer["say"]
                words = say.split(" ") if say else []
                pcm = speech_pcm(spoken_seconds(say)) if answer["audio"] and say else b""
                step = int(ASSISTANT_RATE * 2 * ASSISTANT_FRAME_SECONDS)
                frames = [pcm[i:i + step] for i in range(0, len(pcm), step)]
                count = max(len(frames), len(words))
                for index in range(count):
                    if conversation["cancel"].is_set():
                        interrupted = True
                        break
                    if index < len(words):
                        write(event_frame({"type": "say.delta", "text": (" " if index else "") + words[index]}))
                    if index < len(frames):
                        if first_audio is None:
                            first_audio = int((time.time() - started) * 1000)
                        write(frame(b"A", frames[index]))
                    time.sleep(ASSISTANT_FRAME_SECONDS * b.assistant_pace)
                if not interrupted:
                    write(event_frame({"type": "say.done", "text": say}))
                    for action in answer["actions"]:
                        write(event_frame(dict(action, type="action")))
                    for card in answer["cards"]:
                        write(event_frame(dict(card, type="card")))
            done: Dict[str, Any] = {"type": "done", "conversationId": answer["conversationId"],
                                    "turnId": answer["turnId"], "expectReply": answer["say"].rstrip().endswith("?"),
                                    "endConversation": answer["end"] and not interrupted, "brain": answer["brain"],
                                    "timings": {"stt": 180, "firstAudio": first_audio,
                                                "total": int((time.time() - started) * 1000)}}
            if interrupted:
                done["interrupted"] = True
            # Like the real bridge (``TurnSink.finish``): an error event is followed by ``done``.
            write(event_frame(done))
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            interrupted = True  # the watch hung up (barge-in)
            self.close_connection = True
        return interrupted

    def calendar(self, method: str, rest: str) -> None:
        b = self.bridge
        if rest == "calendar/agenda":
            self.only(method, "GET")
            hours = max(1, min(168, int(self.q1("hours", "24") or 24)))
            with b.lock:
                return self.send_json(200, {"available": True, "calendar": "primary",
                                            "events": b.upcoming(hours)})
        if rest in ("calendar/block", "calendar/events"):
            self.only(method, "POST")
            body = self.body()
            if rest == "calendar/block":
                minutes = body.get("minutes")
                if not isinstance(minutes, (int, float)) or not 5 <= minutes <= 480:
                    raise ApiError(400, "invalid_minutes", "minutes must be between 5 and 480.")
                start = time.time() - (time.time() % 60)
                end = start + int(minutes) * 60
                title = str(body.get("title") or "Focus").strip()[:120] or "Focus"
            else:
                title = str(body.get("title") or "").strip()[:200]
                try:
                    start = datetime.fromisoformat(str(body.get("startsAt")).replace("Z", "+00:00")).timestamp()
                    end = datetime.fromisoformat(str(body.get("endsAt")).replace("Z", "+00:00")).timestamp()
                except ValueError:
                    raise ApiError(400, "invalid_time", "startsAt and endsAt are required.") from None
                if not title or end <= start:
                    raise ApiError(400, "invalid_event", "A title and an end after the start are required.")
            event = b._event("ev_" + uuid.uuid4().hex[:10], title, start, end - start)
            with b.lock:
                b.calendar.append(event)
            public = {k: v for k, v in event.items() if not k.startswith("_")}
            return self.send_json(200, {"ok": True, "event": public, "fake": True})
        raise ApiError(404, "not_found", "Not found.")

    # ------------------------------------------------------------------ Mac

    def mac(self, method: str, rest: str) -> None:
        b = self.bridge
        if rest == "mac/state":
            self.only(method, "GET")
            return self.send_json(200, {
                "name": b.mac_name, "computer": b.mac_name, "online": True, "screenLocked": b.screen_locked,
                "screenVision": True, "front": {"app": "T3 Code", "window": "Fix login redirect"},
                "visible": [{"app": "T3 Code", "windows": ["Fix login redirect"]},
                            {"app": "Google Chrome", "windows": ["Google Calendar - Thursday"]}],
                "running": ["Finder", "Google Chrome", "Messages", "Notes", "Slack", "T3 Code"]})
        if rest == "mac/open":
            self.only(method, "POST")
            body = self.body()
            app, url = body.get("app"), body.get("url")
            if url:
                if not re.match(r"^https?://", str(url)):
                    raise ApiError(400, "invalid_url", "Use an http(s) link.")
                return self.send_json(200, {"ok": True, "opened": "url", "url": url, "app": "Google Chrome"})
            if not app:
                raise ApiError(400, "missing_target", "Say which app or link to open.")
            known = {"chrome": "Google Chrome", "google chrome": "Google Chrome", "notes": "Notes", "slack": "Slack",
                     "calendar": "Calendar", "t3": "T3 Code", "t3 code": "T3 Code", "safari": "Safari",
                     "finder": "Finder", "messages": "Messages", "music": "Music", "mail": "Mail"}
            name = known.get(str(app).strip().lower())
            if not name:
                raise ApiError(404, "app_not_found", "No app called “%s” on the Mac." % str(app)[:40])
            return self.send_json(200, {"ok": True, "opened": "app", "app": name, "wasRunning": True,
                                        "frontmost": True})
        if rest == "mac/screenshot":
            self.only(method, "GET")
            if b.screen_locked:
                raise ApiError(409, "screen_locked", "Your Mac's screen is locked, so I can't see it.")
            return self.send_bytes(b.screenshot_jpg, "image/jpeg")
        raise ApiError(404, "not_found", "Not found.")


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def serve(argv: Optional[List[str]] = None) -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=3799)
    parser.add_argument("--code", default=DEFAULT_CODE, help="the fixed pairing code (8 chars, no I/O/0/1)")
    parser.add_argument("--single-use", action="store_true", help="the code works once (like the real bridge)")
    parser.add_argument("--state", default=os.path.join(HERE, ".state", "fake-bridge.json"),
                        help="where pairings persist ('' = memory only)")
    parser.add_argument("--mac-name", default="Samin's MacBook Pro")
    parser.add_argument("--advertise", default="", help="hosts for pairUrl, comma separated (default this server)")
    parser.add_argument("--no-chatter", action="store_true", help="no streamed exchange every minute")
    parser.add_argument("--screen-locked", action="store_true")
    parser.add_argument("--quiet", action="store_true")
    parser.add_argument("--print-port", action="store_true", help="print 'PORT <n>' once listening")
    args = parser.parse_args(argv)
    code = args.code.upper()
    if len(code) != 8 or any(ch not in CODE_ALPHABET for ch in code):
        parser.error("the code must be 8 characters from %s" % CODE_ALPHABET)
    bridge = FakeBridge(code=code, single_use=args.single_use, state_path=args.state or None, mac_name=args.mac_name,
                        chatter=not args.no_chatter, advertise=[h for h in args.advertise.split(",") if h],
                        screen_locked=args.screen_locked)
    Handler.bridge = bridge
    Handler.quiet = args.quiet
    server = Server((args.host, args.port), Handler)
    bridge.port = server.server_address[1]
    threading.Thread(target=bridge.ticker, daemon=True).start()
    if args.print_port:
        print("PORT %d" % bridge.port, flush=True)
    if not args.quiet:
        sys.stderr.write("fake SamRabbit bridge on http://%s:%d  (pair: samrabbit://pair?h=%s&c=%s)\n"
                         % (args.host, bridge.port, ",".join(bridge.hosts()), code))
    try:
        server.serve_forever(poll_interval=0.2)
    except KeyboardInterrupt:
        pass
    finally:
        bridge.closed = True
        server.server_close()


if __name__ == "__main__":
    serve()
