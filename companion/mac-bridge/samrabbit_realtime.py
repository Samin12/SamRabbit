"""The watch assistant's realtime brain: gpt-realtime on Samin's ChatGPT subscription, like the R1.

The R1 talks to OpenAI Realtime over WebRTC with the ChatGPT subscription's access token as a Bearer
(``POST https://api.openai.com/v1/realtime/calls``, multipart ``sdp`` + ``session``; a subscription token cannot open
a realtime WebSocket). The watch cannot do WebRTC, so the Mac is the peer:

* ``realtime/samrabbit_realtime_peer.py`` (the realtime venv's Python, aiortc) holds the ``RTCPeerConnection`` and
  the ``oai-events`` data channel, one process per watch conversation, and forwards the reply's audio as PCM16 16 kHz;
* this module (the bridge's Python 3.9, stdlib) does the signaling itself with the token from ``samrabbit_chatgpt``
  (so the token never leaves the bridge process, never on argv, never logged), sends the client events, runs the
  tools one at a time (like the R1's tool queue) and streams the turn to the watch through a sink.

A session is the R1's (``samrabbit_realtime_profile``): ``gpt-realtime-2.1``, the voice ``marin``, the R1's
instructions and tool names, manual turns. It opens when the conversation starts (``POST
/v1/mobile/assistant/session``) or with its first turn, and closes when the conversation ends, after three idle
minutes, or at 55 minutes (the next turn opens a new one with a short summary of the earlier one).

Per turn: ``conversation.item.create`` (the words, with the ``[Now: …]`` line when the minute changed) and
``response.create``; ``response.output_audio_transcript.delta`` -> what to say; the audio -> PCM frames; a function
call -> the tool runs on the Mac -> ``function_call_output`` -> ``response.create`` after ``response.done``;
``cancel`` -> ``response.cancel`` + ``output_audio_buffer.clear``. Announcements are said by the session too
(``response.create`` with instructions to say the line verbatim).

Nothing here logs words, events, audio, tool inputs or outputs, or tokens. Stdlib only, Python 3.9.
"""

from __future__ import annotations

import base64
from datetime import date as Date, datetime, timedelta, timezone
from difflib import SequenceMatcher
import hashlib
import http.client
import json
import logging
import math
import os
import queue
import re
import secrets
import signal
import ssl
import subprocess
import sys
import tempfile
import threading
import time
from collections import deque
from typing import Any, Callable, Deque, Dict, List, Optional, Tuple
from urllib.parse import quote, urlencode, urlsplit

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.append(_HERE)

import samrabbit_realtime_profile as profile  # noqa: E402

try:  # the tool code the Claude path's MCP server uses (loopback calls to the bridge's mobile API)
    import samrabbit_assistant_mcp as mcp  # type: ignore  # noqa: E402
except Exception:  # noqa: BLE001  # pragma: no cover
    mcp = None  # type: ignore[assignment]

try:
    import samrabbit_chatgpt as chatgpt  # type: ignore  # noqa: E402
except Exception:  # noqa: BLE001  # pragma: no cover
    chatgpt = None  # type: ignore[assignment]

_LOG = logging.getLogger("samrabbit-bridge.realtime")

API_ROOT = "https://api.openai.com/v1"
DEFAULT_VENV = "~/Library/Application Support/SamRabbit/realtime-venv"
HELPER_SCRIPT = os.path.join(_HERE, "realtime", "samrabbit_realtime_peer.py")
HELPER_ENV_KEYS = ("HOME", "USER", "LOGNAME", "TMPDIR", "LANG")
CHECK_TIMEOUT_SECONDS = 60.0
CHECK_CACHE_SECONDS = 600.0
READY_TIMEOUT_SECONDS = 15.0
OFFER_TIMEOUT_SECONDS = 15.0
SIGNAL_TIMEOUT_SECONDS = 20.0
CHANNEL_TIMEOUT_SECONDS = 15.0
FIRST_EVENT_SECONDS = 25.0
TURN_SECONDS = 150.0
AUDIO_WAIT_SECONDS = 2.0  # after the last response.done, how long to wait for its audio to start
IDLE_CLOSE_SECONDS = 180.0
MAX_SESSION_SECONDS = 55 * 60.0
ACTIVE_RETRY_SECONDS = 3.0  # an earlier response still active: ask again after its response.done, or after this
LOST_STATES = ("failed", "closed", "channel_closed")  # the helper's {"ev": "state"} values that end a session
MAX_TOOL_ROUNDS = 6
MAX_OUTPUT_CHARS = 12_000
MAX_EVENT_BYTES = 240 * 1024  # libwebrtc refuses data-channel messages over 256 KiB (the R1 caps at 240 KiB)
MAX_IMAGE_B64 = 190 * 1024
MAX_SDP_BYTES = 262_144
MAX_HISTORY = 12
PAUSE_REJECTED_SECONDS = 10 * 60.0
PAUSE_BUSY_SECONDS = 60.0
PAUSE_FAILED_SECONDS = 30.0
SCREENSHOT_SIDES = (768, 512)
SCREEN_LOCKED_NOTE = ("The Mac's screen is locked, so no screenshot was taken and there is no image. Tell the user "
                      "briefly that their Mac's screen is locked, so you can't see it, and to unlock it and ask again. "
                      "Do not describe the screen.")
_WORD = re.compile(r"[a-z0-9']+")


class RealtimeError(Exception):
    """A realtime turn that could not go on. ``pause``: seconds the brain stays off (a refused token, a busy
    account); ``reason``: the brain's off reason meanwhile; ``stale``: the session had already ended before this turn
    reached OpenAI (it died while idle): open a new one and go on, nothing is wrong with the brain."""

    def __init__(self, code: str, message: str, *, pause: float = 0.0, reason: Optional[str] = None,
                 stale: bool = False) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.pause = pause
        self.reason = reason or code
        self.stale = stale


def _stale() -> RealtimeError:
    return RealtimeError("realtime_session_lost", "The realtime connection had already ended.", stale=True)


def _closed() -> RealtimeError:
    return RealtimeError("realtime_closed", "The realtime session was closed on the Mac.")


# --------------------------------------------------------------------------- the helper process


def _helper_env() -> Dict[str, str]:
    env = {key: os.environ[key] for key in HELPER_ENV_KEYS if os.environ.get(key)}
    env.setdefault("HOME", os.path.expanduser("~"))
    env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    return env


class HelperCheck:
    """``<python> -I samrabbit_realtime_peer.py --check`` (about a second: it imports aiortc), cached for ten minutes:
    is the realtime venv usable? The summary must stay fast, so only the very first check (or ``refresh``) is waited
    for, and even then only briefly by anyone but its caller; a stale answer is renewed in the background."""

    def __init__(self, python: Optional[str], script: str = HELPER_SCRIPT, *,
                 timeout: float = CHECK_TIMEOUT_SECONDS) -> None:
        self.python = os.path.expanduser(python) if python else None
        self.script = script
        self.timeout = timeout
        self._lock = threading.Lock()
        self._value: Optional[Tuple[float, Dict[str, Any]]] = None
        self._running: Optional[threading.Thread] = None

    def status(self, *, refresh: bool = False, wait: float = 3.0) -> Dict[str, Any]:
        with self._lock:
            cached = self._value
            if cached is not None and not refresh and time.monotonic() - cached[0] < CHECK_CACHE_SECONDS:
                return dict(cached[1])
            running = self._running
            if running is None:
                running = self._running = threading.Thread(target=self._run, name="samrabbit-realtime-check",
                                                           daemon=True)
                running.start()
        if cached is not None and not refresh:
            return dict(cached[1])  # stale: renewed in the background
        running.join(timeout=self.timeout + 5.0 if refresh else wait)
        with self._lock:
            value = self._value
        return dict(value[1]) if value is not None else {"ready": False, "reason": "realtime_checking"}

    def _run(self) -> None:
        try:
            value = self._check()
        except Exception:  # noqa: BLE001  # pragma: no cover
            value = {"ready": False, "reason": "realtime_venv_broken"}
        with self._lock:
            self._value = (time.monotonic(), value)
            self._running = None

    def _check(self) -> Dict[str, Any]:
        if not self.python:
            return {"ready": False, "reason": "realtime_helper_missing"}
        if not os.path.isfile(self.script):
            return {"ready": False, "reason": "realtime_helper_missing"}
        if not (os.path.isfile(self.python) and os.access(self.python, os.X_OK)):
            return {"ready": False, "reason": "realtime_venv_missing"}
        try:
            done = subprocess.run([self.python, "-I", self.script, "--check"], stdin=subprocess.DEVNULL,
                                  capture_output=True, timeout=self.timeout, env=_helper_env(),
                                  cwd=tempfile.gettempdir(), check=False)
        except (OSError, subprocess.SubprocessError):
            return {"ready": False, "reason": "realtime_venv_broken"}
        lines = [line for line in done.stdout.decode("utf-8", "replace").splitlines() if line.strip()]
        try:
            value = json.loads(lines[-1]) if lines else {}
        except ValueError:
            value = {}
        if not isinstance(value, dict) or value.get("ok") is not True:
            reason = value.get("reason") if isinstance(value, dict) else None
            return {"ready": False, "reason": {"python_too_old": "realtime_python_too_old"}.get(
                str(reason), "realtime_venv_broken"),
                **({"python": value["python"]} if isinstance(value, dict) and value.get("python") else {})}
        return {"ready": True, "python": str(value.get("python") or ""), "aiortc": str(value.get("aiortc") or ""),
                "av": str(value.get("av") or "")}


class Helper:
    """One helper process (its own process group), JSON lines both ways; never logs what goes through it."""

    def __init__(self, python: str, script: str = HELPER_SCRIPT) -> None:
        try:
            self.process = subprocess.Popen([python, "-I", script], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                            stderr=subprocess.DEVNULL, env=_helper_env(), cwd=tempfile.gettempdir(),
                                            start_new_session=True)
        except OSError:
            raise RealtimeError("realtime_helper_failed", "The realtime helper could not start.",
                                pause=PAUSE_FAILED_SECONDS) from None
        self._messages: "queue.Queue[Optional[Dict[str, Any]]]" = queue.Queue()
        self._backlog: Deque[Dict[str, Any]] = deque()
        self._send_lock = threading.Lock()
        self.ended = False
        # The peer connection or the data channel ended (the helper said so). Set by the reader as the message comes
        # in, so a session that died between turns is never reused, even when nobody reads its queue (``drain``).
        self.lost = False
        threading.Thread(target=self._read, name="samrabbit-realtime-read", daemon=True).start()

    def _read(self) -> None:
        stream = self.process.stdout
        try:
            for raw in iter(stream.readline, b""):  # type: ignore[union-attr]
                try:
                    value = json.loads(raw.decode("utf-8"))
                except (UnicodeDecodeError, ValueError):
                    continue
                if isinstance(value, dict):
                    if (value.get("ev") == "state" and value.get("state") in LOST_STATES) or \
                            (value.get("ev") == "error" and value.get("code") == "not_open"):
                        self.lost = True
                    self._messages.put(value)
        except (OSError, ValueError):
            pass
        self._messages.put(None)

    def send(self, value: Dict[str, Any]) -> None:
        data = (json.dumps(value, separators=(",", ":"), ensure_ascii=False) + "\n").encode("utf-8")
        with self._send_lock:
            try:
                self.process.stdin.write(data)  # type: ignore[union-attr]
                self.process.stdin.flush()  # type: ignore[union-attr]
            except (OSError, ValueError):
                raise RealtimeError("realtime_connection_lost", "The realtime connection on the Mac ended.") from None

    def next(self, timeout: float) -> Optional[Dict[str, Any]]:
        """The next message; ``{}`` when nothing came in ``timeout``; None once the helper has exited."""
        if self._backlog:
            return self._backlog.popleft()
        if self.ended:
            return None
        try:
            value = self._messages.get(timeout=max(0.0, timeout))
        except queue.Empty:
            return {}
        if value is None:
            self.ended = True
        return value

    def wait(self, ev: str, timeout: float) -> Dict[str, Any]:
        """Until a message ``ev``; others are kept for later (``next``)."""
        deadline = time.monotonic() + timeout
        kept: List[Dict[str, Any]] = []
        try:
            while True:
                left = deadline - time.monotonic()
                if left <= 0:
                    raise RealtimeError("realtime_timeout", "The realtime connection did not open in time.",
                                        pause=PAUSE_FAILED_SECONDS)
                try:
                    value = self._messages.get(timeout=left)
                except queue.Empty:
                    continue
                if value is None:
                    self.ended = True
                    raise RealtimeError("realtime_helper_failed", "The realtime helper stopped.",
                                        pause=PAUSE_FAILED_SECONDS)
                if value.get("ev") == ev:
                    return value
                if value.get("ev") == "error" and ev in ("offer", "open"):
                    raise RealtimeError("realtime_helper_failed", "The realtime helper could not connect.",
                                        pause=PAUSE_FAILED_SECONDS)
                kept.append(value)
        finally:
            self._backlog.extend(kept)

    def drain(self) -> None:
        """Drop what is left from the last turn (late audio, stale events). A "connection ended" message among them
        has already marked the helper ``lost`` (the reader does that), so nothing that matters is thrown away."""
        self._backlog.clear()
        while True:
            try:
                value = self._messages.get_nowait()
            except queue.Empty:
                return
            if value is None:
                self.ended = True
                return

    def alive(self) -> bool:
        return not self.ended and not self.lost and self.process.poll() is None

    def close(self) -> None:
        try:
            self.send({"op": "close"})
        except RealtimeError:
            pass
        try:
            self.process.wait(timeout=3.0)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(self.process.pid, signal.SIGKILL)
            except OSError:
                try:
                    self.process.kill()
                except OSError:
                    pass
            try:
                self.process.wait(timeout=3.0)
            except subprocess.TimeoutExpired:  # pragma: no cover
                pass
        for stream in (self.process.stdin, self.process.stdout):
            try:
                if stream is not None:
                    stream.close()
            except OSError:
                pass


# --------------------------------------------------------------------------- signaling


def multipart(boundary: str, fields: Tuple[Tuple[str, str], ...]) -> bytes:
    """The R1's body (``platform.py`` ``_multipart``): one part per field, no file names."""
    chunks: List[bytes] = []
    for name, value in fields:
        chunks += [f"--{boundary}\r\n".encode(), f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode(),
                   value.encode("utf-8"), b"\r\n"]
    chunks.append(f"--{boundary}--\r\n".encode())
    return b"".join(chunks)


def create_call(api_root: str, token: str, safety_id: str, offer: str, session: Dict[str, Any], *,
                timeout: float = SIGNAL_TIMEOUT_SECONDS) -> Tuple[int, str, Dict[str, Any]]:
    """``POST {api_root}/realtime/calls`` exactly like the R1 (headers Authorization, Accept,
    OpenAI-Safety-Identifier, Content-Type). ``(status, answer SDP or "", OpenAI's error {type, code, param})``."""
    parts = urlsplit(api_root.rstrip("/") + "/realtime/calls")
    host = parts.hostname or ""
    if parts.scheme == "https":
        connection: http.client.HTTPConnection = http.client.HTTPSConnection(
            host, parts.port or 443, timeout=timeout, context=ssl.create_default_context())
    elif parts.scheme == "http" and host in ("127.0.0.1", "localhost", "::1"):
        connection = http.client.HTTPConnection(host, parts.port or 80, timeout=timeout)  # a stand-in, in tests
    else:
        raise RealtimeError("realtime_bad_url", "The realtime address is not allowed.")
    boundary = f"sam-{secrets.token_hex(16)}"
    body = multipart(boundary, (("sdp", offer), ("session", json.dumps(session, separators=(",", ":")))))
    try:
        connection.request("POST", parts.path, body=body, headers={
            "Authorization": f"Bearer {token}", "Accept": "application/json, application/sdp, text/plain",
            "OpenAI-Safety-Identifier": safety_id, "Content-Type": f"multipart/form-data; boundary={boundary}"})
        response = connection.getresponse()
        status = response.status
        raw = response.read(MAX_SDP_BYTES * 2)
    except (OSError, http.client.HTTPException, ssl.SSLError):
        raise RealtimeError("realtime_unreachable", "OpenAI is not reachable from the Mac right now.",
                            pause=PAUSE_FAILED_SECONDS) from None
    finally:
        connection.close()
    text = raw.decode("utf-8", errors="replace")
    if 200 <= status < 300:
        return status, text, {}
    detail: Dict[str, Any] = {}
    try:
        value = json.loads(text)
    except ValueError:
        value = None
    error = value.get("error") if isinstance(value, dict) and isinstance(value.get("error"), dict) else {}
    for key in ("type", "code", "param"):
        if isinstance(error.get(key), str) and len(error[key]) <= 80:
            detail[key] = error[key]
    return status, "", detail


# --------------------------------------------------------------------------- one session


class RealtimeSession:
    """One watch conversation's WebRTC session (one helper process)."""

    def __init__(self, brain: "RealtimeBrain", config: Dict[str, Any]) -> None:
        self.brain = brain
        self.config = config
        self.helper: Optional[Helper] = None
        self.state = "new"  # new -> opening -> open -> closed | failed
        self.error: Optional[RealtimeError] = None
        self.created_at = time.monotonic()
        self.opened_at = 0.0
        self.used_at = 0.0
        self.ready = threading.Event()
        self.lock = threading.Lock()  # one turn at a time
        self.now_minute: Optional[str] = None
        # Closed on the Mac (an end, a goodbye, the session cap, the bridge stopping), maybe while it was opening:
        # whatever open() was waiting for then fails as ``realtime_closed``, which never pauses the brain.
        self.closing = False
        self.retired = False  # made with a ChatGPT login that changed: finishes its turn, then closes (not usable)
        self.answered: set = set()  # the function calls that have their function_call_output (never two)

    def open(self) -> None:
        """Start the helper, make the offer, sign it with OpenAI, wait for the data channel (about a second)."""
        self.state = "opening"
        try:
            if self.closing:
                raise _closed()
            helper = Helper(self.brain.python(), self.brain.script)
            self.helper = helper
            if self.closing:  # closed while the helper started: close() may have missed it
                raise _closed()
            helper.wait("ready", READY_TIMEOUT_SECONDS)
            helper.send({"op": "offer"})
            offer = str(helper.wait("offer", OFFER_TIMEOUT_SECONDS).get("sdp") or "")
            if not offer.startswith("v=0") or len(offer) > MAX_SDP_BYTES:
                raise RealtimeError("realtime_helper_failed", "The realtime helper made a bad offer.",
                                    pause=PAUSE_FAILED_SECONDS)
            if self.closing:
                raise _closed()
            answer = self.brain.signal(offer, self.config)
            if self.closing:
                raise _closed()
            helper.send({"op": "answer", "sdp": answer})
            helper.wait("open", CHANNEL_TIMEOUT_SECONDS)
            if self.closing:
                raise _closed()
        except RealtimeError as error:
            if self.closing:  # the helper stopped because the Mac closed it: not the brain's fault
                error = _closed()
            self.state, self.error = ("closed" if self.closing else "failed"), error
            self.close()
            raise error from None
        except Exception:  # noqa: BLE001
            self.state = "closed" if self.closing else "failed"
            self.error = _closed() if self.closing else \
                RealtimeError("realtime_failed", "The realtime connection failed.", pause=PAUSE_FAILED_SECONDS)
            self.close()
            raise self.error from None
        finally:
            self.ready.set()
        self.state = "open"
        self.opened_at = self.used_at = time.monotonic()
        _LOG.info("realtime session open")

    def usable(self) -> bool:
        return self.state == "open" and not self.closing and not self.retired and self.helper is not None and \
            self.helper.alive()

    def retire(self) -> None:
        """No new turn may use it (its turn in progress goes on); the sweep or the next turn closes it."""
        self.retired = True

    def expired(self) -> bool:
        return self.state == "open" and time.monotonic() - self.opened_at >= MAX_SESSION_SECONDS

    def send(self, event: Dict[str, Any]) -> None:
        if self.helper is None:
            raise RealtimeError("realtime_connection_lost", "The realtime connection on the Mac ended.")
        data = json.dumps(event, separators=(",", ":"), ensure_ascii=False)
        if len(data.encode("utf-8")) > MAX_EVENT_BYTES:
            raise RealtimeError("realtime_event_too_large", "That was too much to send at once.")
        self.helper.send({"op": "send", "event": event})

    def drop_audio(self) -> None:
        if self.helper is not None:
            try:
                self.helper.send({"op": "drop_audio"})
            except RealtimeError:
                pass

    def close(self) -> None:
        """Idempotent. While it is still opening, open() sees ``closing`` and ends it (``realtime_closed``)."""
        self.brain.discard(self)  # sets ``closing`` (under the brain's lock: it never lands in the live set after)
        if self.state in ("open", "new"):
            self.state = "closed"
        helper, self.helper = self.helper, None
        if helper is not None:
            helper.close()
            if self.state == "closed":
                _LOG.info("realtime session closed")


# --------------------------------------------------------------------------- one turn


class TurnOutcome:
    def __init__(self) -> None:
        self.text = ""
        self.interrupted = False
        self.output_started = False
        self.first_audio: Optional[float] = None
        self.tools: List[Dict[str, Any]] = []  # {id, name, input, result, isError, images}
        self.actions: List[Dict[str, Any]] = []
        self.cards: List[Dict[str, Any]] = []
        self.rounds = 0
        self.max_rounds = False
        # The last response failed after a tool round or words: the turn ends with what it has (it is never answered
        # again by another brain); ``pause``: seconds the brain stays off (a busy account).
        self.failed = False
        self.pause = 0.0


def converse(session: RealtimeSession, items: List[Dict[str, Any]], response: Optional[Dict[str, Any]], sink: Any,
             runner: Optional["ToolRunner"], cancel: threading.Event, *, timeout: float = TURN_SECONDS) -> TurnOutcome:
    """One turn: send ``items`` and ``response.create``, stream the reply to ``sink`` (``say_delta(text)``,
    ``audio(pcm)``, ``action(dict)``, ``card(dict)``, ``tool(record)`` as soon as a function call has run), run the
    function calls one at a time, end when the last response is done and its audio has been forwarded. ``cancel``:
    barge-in. A ``RealtimeError`` can still come after a tool ran (a lost connection, the deadline): the sink has the
    record of what ran. A session found dead before anything of this turn reached OpenAI raises a ``stale`` error
    (no pause: the caller opens a new session).

    An earlier response that is still active (a cancel OpenAI had not finished, a turn that gave up) makes OpenAI
    refuse ``response.create`` (``conversation_already_has_active_response``): that response is cancelled, its words,
    audio and function calls are not this turn's (each of its calls gets a "cancelled" output), and the
    ``response.create`` is sent again once its ``response.done`` came."""
    helper = session.helper
    if helper is None or not session.usable():
        raise _stale()
    helper.drain()
    if not session.usable():  # its end was among what the drain dropped (the reader had marked it already)
        raise _stale()
    outcome = TurnOutcome()
    started = time.monotonic()
    deadline = started + timeout
    create = {"type": "response.create", **({"response": response} if response else {})}
    # Manual turns (no server VAD): the silent outbound track only fills the input buffer, so empty it first; nothing
    # from it is ever committed.
    session.send({"type": "input_audio_buffer.clear"})
    for item in items:
        session.send(item)
    session.send(create)
    last_create = create  # what to send again when OpenAI refuses it
    responding = True  # a response is requested or running
    any_event = False
    calls: List[Dict[str, Any]] = []
    seen_calls: set = set()
    audio_active = False
    saw_audio = False  # output_audio_buffer.started since the last response.created
    expects_audio = False
    final_at: Optional[float] = None
    final_chars = 0  # the last response's words: how long its audio may still play after response.done
    cancelled_at: Optional[float] = None
    texts: List[str] = []
    current = ""
    created: set = set()  # this turn's responses (the ids of their response.created)
    others: set = set()  # earlier responses still going in this turn (never this turn's words, audio or calls)
    waiting = False  # OpenAI refused response.create: until this turn's own response.created
    resent = False  # the response.create is sent again (after the refusal)
    retry_at: Optional[float] = None  # when to send it again if the earlier response.done never comes

    def send_output(call_id: str, output: str) -> None:
        session.send({"type": "conversation.item.create", "item": {
            "type": "function_call_output", "call_id": call_id, "output": output}})
        session.answered.add(call_id)

    def foreign(event: Dict[str, Any]) -> bool:
        """An event of a response this turn did not ask for (OpenAI's events carry their response id)."""
        response_id = event.get("response_id")
        if response_id is None and isinstance(event.get("response"), dict):
            response_id = event["response"].get("id")
        if isinstance(response_id, str) and response_id:
            return response_id in others or response_id not in created
        return waiting  # no id: while refused, nothing is this turn's yet

    def spoken_delta(delta: str) -> None:
        nonlocal current
        if not delta:
            return
        if not current and texts and not delta.startswith(" "):
            delta = " " + delta  # a new response after a tool call: one space between the sentences
        current += delta
        if cancelled_at is None:
            outcome.output_started = True
            sink.say_delta(delta)

    while True:
        now = time.monotonic()
        if cancel.is_set() and cancelled_at is None:
            cancelled_at = now
            outcome.interrupted = True
            session.drop_audio()
            # Like the R1 (VoicePageView): cancel the response (if it is still being made) and clear what is still
            # playing out; an inactive response's cancel only earns a harmless error event.
            session.send({"type": "response.cancel"})
            session.send({"type": "output_audio_buffer.clear"})
            if calls:  # never leave a call without its output: the next response would trip on it
                for call in calls:
                    send_output(call["call_id"], json.dumps({"isError": True, "error": "cancelled",
                                                             "message": "Samin interrupted."}))
                calls = []
        if cancelled_at is not None and (not responding or now - cancelled_at > 2.0):
            break
        if retry_at is not None and now >= retry_at and cancelled_at is None:
            retry_at, resent = None, True  # the earlier response.done never came: ask again
            session.send(last_create)
        if final_at is not None and not audio_active and (saw_audio or not expects_audio or
                                                          now - final_at > AUDIO_WAIT_SECONDS):
            break
        if final_at is not None and now - final_at > 5.0 + final_chars / 10.0:
            break  # audio that never ends (a lost stopped event): the words are all there
        if now > deadline:
            raise RealtimeError("realtime_timeout", "The answer took too long.")
        if not any_event and now - started > FIRST_EVENT_SECONDS:
            raise RealtimeError("realtime_timeout", "OpenAI did not answer in time.", pause=PAUSE_FAILED_SECONDS)
        message = helper.next(0.1)
        if message is None:
            if cancelled_at is not None:
                break
            raise RealtimeError("realtime_connection_lost", "The realtime connection on the Mac ended.",
                                pause=PAUSE_FAILED_SECONDS)
        if not message:
            continue
        ev = message.get("ev")
        if ev == "audio":
            if cancelled_at is None and not waiting:
                try:
                    pcm = base64.b64decode(str(message.get("pcm") or ""), validate=False)
                except (ValueError, TypeError):
                    continue
                if pcm:
                    if outcome.first_audio is None:
                        outcome.first_audio = time.monotonic()
                    outcome.output_started = True
                    sink.audio(pcm)
            continue
        if ev == "audio_end":
            audio_active = False
            continue
        if ev == "state":
            if message.get("state") in LOST_STATES:
                session.state = "failed"
                if cancelled_at is not None:
                    break
                if not any_event:  # it ended before OpenAI answered anything of this turn: nothing happened
                    raise _stale()
                raise RealtimeError("realtime_connection_lost", "The realtime connection dropped.",
                                    pause=PAUSE_FAILED_SECONDS)
            continue
        if ev == "error":
            if message.get("code") == "not_open":
                session.state = "failed"
                if not any_event:  # the data channel was already closed: nothing reached OpenAI
                    raise _stale()
                raise RealtimeError("realtime_connection_lost", "The realtime connection dropped.",
                                    pause=PAUSE_FAILED_SECONDS)
            continue
        if ev != "event" or not isinstance(message.get("event"), dict):
            continue
        event = message["event"]
        kind = str(event.get("type") or "")
        any_event = True
        if kind == "response.created":
            body = event.get("response") if isinstance(event.get("response"), dict) else {}
            response_id = body.get("id")
            if waiting and not resent:  # not this turn's: it never asked again yet
                if isinstance(response_id, str) and response_id:
                    others.add(response_id)
                continue
            if isinstance(response_id, str) and response_id:
                created.add(response_id)
            waiting = False
            responding = True
            saw_audio = False
            expects_audio = False
            current = ""
        elif kind == "output_audio_buffer.started":
            if not waiting:
                audio_active = saw_audio = True
        elif kind == "response.output_audio_transcript.delta":
            if not foreign(event):
                spoken_delta(str(event.get("delta") or ""))
        elif kind == "response.output_audio_transcript.done":
            transcript = str(event.get("transcript") or "")
            if transcript and not current and not foreign(event):
                spoken_delta(transcript)
        elif kind == "response.function_call_arguments.done":
            if not foreign(event):
                _add_call(calls, seen_calls, event)
        elif kind == "response.done":
            body = event.get("response") if isinstance(event.get("response"), dict) else {}
            if foreign(event):
                # An earlier response ended: its calls never run (each gets an output, so no response trips on a
                # call without one), and this turn's response.create goes again if OpenAI refused it.
                for item in body.get("output") or []:
                    if isinstance(item, dict) and item.get("type") == "function_call" and \
                            isinstance(item.get("call_id"), str) and item["call_id"] not in session.answered:
                        send_output(item["call_id"], json.dumps({"isError": True, "error": "cancelled"}))
                if waiting and not resent and cancelled_at is None:
                    retry_at, resent = None, True
                    session.send(last_create)
                continue
            responding = False
            for item in body.get("output") or []:
                if isinstance(item, dict) and item.get("type") == "function_call":
                    _add_call(calls, seen_calls, item)
                if isinstance(item, dict) and item.get("type") == "message":
                    for part in item.get("content") or []:
                        if isinstance(part, dict) and part.get("type") in ("output_audio", "audio"):
                            expects_audio = True
                            if not current and isinstance(part.get("transcript"), str):
                                spoken_delta(part["transcript"])
            if current:
                texts.append(current.strip())
                current = ""
            if cancelled_at is not None:
                for call in calls:  # a call only in the cancelled response's response.done: answered too
                    send_output(call["call_id"], json.dumps({"isError": True, "error": "cancelled",
                                                             "message": "Samin interrupted."}))
                calls = []
                break
            status = body.get("status")
            if status == "failed":
                details = body.get("status_details") if isinstance(body.get("status_details"), dict) else {}
                error = details.get("error") if isinstance(details.get("error"), dict) else {}
                code = str(error.get("code") or error.get("type") or "response_failed")[:60]
                _LOG.warning("realtime response failed (%s)", re.sub(r"[^a-z_]", "", code.lower())[:40])
                pause = PAUSE_BUSY_SECONDS if "rate" in code or "quota" in code else 0.0
                if not outcome.output_started and not calls and not outcome.tools:
                    raise RealtimeError("realtime_response_failed", "OpenAI could not answer that.", pause=pause)
                # A tool already ran (or words went out): no error that would have the turn answered again.
                outcome.failed, outcome.pause = True, max(outcome.pause, pause)
            if calls:
                if outcome.rounds >= MAX_TOOL_ROUNDS or runner is None:
                    outcome.max_rounds = True
                    for call in calls:
                        send_output(call["call_id"], json.dumps({"isError": True, "error": "too_many_steps"}))
                    calls = []
                    final_at = time.monotonic()
                    continue
                outcome.rounds += 1
                pending, calls = calls, []
                images: List[Dict[str, Any]] = []
                for call in pending:
                    if cancel.is_set():
                        send_output(call["call_id"], json.dumps({"isError": True, "error": "cancelled"}))
                        continue
                    result = runner.run(call["name"], call["arguments"])
                    record = {"id": call["call_id"], "name": call["name"], "input": result.arguments,
                              "result": result.text, "isError": result.is_error, "images": result.images}
                    outcome.tools.append(record)
                    sink.tool(record)  # at once: whatever fails next, the bridge knows this one acted
                    if result.action and not result.is_error:
                        outcome.actions.append(result.action)
                        sink.action(result.action)
                    if result.card is not None and not result.is_error:
                        outcome.cards.append(result.card)
                        sink.card(result.card)
                    send_output(call["call_id"], result.text)
                    for mime, data in result.images:
                        images.append(_image_item(mime, data))
                if cancel.is_set():
                    continue  # the top of the loop cancels
                for item in images:
                    try:
                        session.send(item)
                    except RealtimeError as error:
                        if error.code != "realtime_event_too_large":
                            raise
                last_create = {"type": "response.create"}
                session.send(last_create)
                responding = True
            else:
                final_at = time.monotonic()
                final_chars = len(texts[-1]) if texts else 0
        elif kind == "error":
            error = event.get("error") if isinstance(event.get("error"), dict) else {}
            code = str(error.get("code") or error.get("type") or "error")
            if code == "conversation_already_has_active_response":
                # An earlier response is still going (a cancel OpenAI had not finished yet, a turn that gave up):
                # it is stale, so cancel it (and what it still plays) and ask again once its response.done came.
                others.update(created)
                created.clear()
                waiting, resent = True, False
                retry_at = time.monotonic() + ACTIVE_RETRY_SECONDS
                if cancelled_at is None:
                    session.send({"type": "response.cancel"})
                    session.send({"type": "output_audio_buffer.clear"})
                continue
            if code in ("response_cancel_not_active",):
                continue
            _LOG.warning("realtime error event (%s)", re.sub(r"[^a-z_]", "", code.lower())[:40])
            if not outcome.output_started and final_at is None and not outcome.tools:
                raise RealtimeError("realtime_error", "OpenAI refused that.")
    if current:
        texts.append(current.strip())
    outcome.text = " ".join(text for text in texts if text)
    session.used_at = time.monotonic()
    return outcome


def _add_call(calls: List[Dict[str, Any]], seen: set, value: Dict[str, Any]) -> None:
    call_id = value.get("call_id")
    name = value.get("name")
    if not isinstance(call_id, str) or not call_id or call_id in seen or not isinstance(name, str):
        return
    seen.add(call_id)
    calls.append({"call_id": call_id, "name": name, "arguments": value.get("arguments")})


def _image_item(mime: str, data: bytes) -> Dict[str, Any]:
    return {"type": "conversation.item.create", "item": {"type": "message", "role": "user", "content": [
        {"type": "input_text", "text": "[Screenshot of the Mac from mac_look]"},
        {"type": "input_image", "image_url": f"data:{mime};base64," + base64.b64encode(data).decode("ascii")}]}}


def user_item(text: str) -> Dict[str, Any]:
    return {"type": "conversation.item.create", "item": {"type": "message", "role": "user",
                                                         "content": [{"type": "input_text", "text": text}]}}


def verbatim_response(line: str) -> Dict[str, Any]:
    """``response.create``'s ``response`` for saying one line word for word (announcements, goodbyes)."""
    return {"instructions": "Say exactly this to Samin, word for word, in your normal voice, and nothing else: "
                            f"“{line}”", "tool_choice": "none"}


# --------------------------------------------------------------------------- the tools


class ToolResult:
    def __init__(self, value: Any, *, is_error: bool = False, arguments: Optional[Dict[str, Any]] = None,
                 images: Optional[List[Tuple[str, bytes]]] = None, action: Optional[Dict[str, Any]] = None,
                 card: Optional[Dict[str, Any]] = None) -> None:
        clean = _compact(value)
        text = json.dumps(clean, ensure_ascii=False, separators=(",", ":"))
        if len(text) > MAX_OUTPUT_CHARS:
            text = json.dumps({"truncated": True, "partial": text[:MAX_OUTPUT_CHARS - 200]}, ensure_ascii=False)
        self.text = text
        self.is_error = is_error
        self.arguments = arguments or {}
        self.images = images or []
        self.action = action
        self.card = card


def _compact(value: Any) -> Any:
    if isinstance(value, dict):
        return {key: _compact(item) for key, item in value.items() if item not in (None, "", [], {})}
    if isinstance(value, list):
        return [_compact(item) for item in value]
    return value


class _Failure(Exception):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


_STOP = frozenset({"the", "a", "an", "thread", "chat", "task", "one", "my", "that", "about", "on", "for", "in", "of",
                   "to", "project"})
_RECENT = frozenset({"latest", "last", "newest", "recent", "most recent", "most recently"})


def _words(text: str) -> List[str]:
    return [word for word in re.findall(r"[a-z0-9]+", text.lower()) if word not in _STOP]


def _score(query: str, title: str) -> float:
    query_words, title_words = _words(query), _words(title)
    if not query_words or not title_words:
        return 0.0
    hits = 0.0
    for word in query_words:
        if word in title_words:
            hits += 1.0
        elif any(candidate.startswith(word) or word.startswith(candidate) for candidate in title_words
                 if min(len(candidate), len(word)) >= 3):
            hits += 0.75
    ratio = SequenceMatcher(None, " ".join(query_words), " ".join(title_words)).ratio()
    return 0.75 * (hits / len(query_words)) + 0.25 * ratio


def match_thread(query: str, items: List[Dict[str, Any]]) -> Tuple[Optional[Dict[str, Any]], List[Dict[str, Any]]]:
    """The R1's forgiving thread lookup (``domains/t3/matching.py``): an id, an id prefix, the title, "the latest",
    or the best-scoring title. ``(match, candidates)``."""
    text = " ".join(str(query or "").split())
    if not text or not items:
        return None, []
    lowered = text.lower()
    for item in items:
        if str(item.get("threadId", "")).lower() == lowered:
            return item, []
    compact = lowered.replace(" ", "")
    if len(compact) >= 6 and re.fullmatch(r"[0-9a-z_-]+", compact) and any(char.isdigit() for char in compact):
        prefixed = [item for item in items if str(item.get("threadId", "")).lower().startswith(compact)]
        if len(prefixed) == 1:
            return prefixed[0], []
    exact = [item for item in items if " ".join(str(item.get("title", "")).split()).lower() == lowered]
    if exact:
        return exact[0], exact[1:3]
    if lowered.strip(" .!?") in _RECENT or " ".join(_words(text)) in _RECENT:
        newest = sorted(items, key=lambda item: str(item.get("updatedAt") or ""), reverse=True)
        return newest[0], []
    scored = sorted(((_score(text, str(item.get("title", ""))), index, item) for index, item in enumerate(items)),
                    key=lambda entry: (-entry[0], entry[1]))
    best = scored[0]
    if best[0] >= 0.55 and (len(scored) == 1 or best[0] - scored[1][0] >= 0.12):
        return best[2], []
    return None, [entry[2] for entry in scored[:3] if entry[0] >= 0.3]


def _ago(value: Any, now: datetime) -> str:
    try:
        stamp = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return ""
    if stamp.tzinfo is None:
        return ""
    seconds = max(0.0, (now - stamp).total_seconds())
    if seconds < 60:
        return "just now"
    if seconds < 3600:
        return f"{int(seconds // 60)} min ago"
    if seconds < 86_400:
        return f"{int(seconds // 3600)} h ago"
    days = int(seconds // 86_400)
    return "yesterday" if days == 1 else f"{days} days ago"


def _condense(value: Any, limit: int) -> Optional[str]:
    if not isinstance(value, str):
        return None
    text = " ".join(value.split())
    return text if len(text) <= limit else text[:limit - 1].rstrip() + "…"


def _parse_time(value: Any, zone: Any) -> Optional[datetime]:
    if not isinstance(value, str) or not value.strip():
        return None
    text = value.strip()
    try:
        moment = datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        return None
    return moment if moment.tzinfo is not None else moment.replace(tzinfo=zone)


def _local(moment: datetime, zone: Any, now: datetime) -> str:
    local = moment.astimezone(zone)
    clock = f"{int(local.strftime('%I'))}:{local.strftime('%M %p')}"
    if local.date() == now.astimezone(zone).date():
        return f"today {clock}"
    if local.date() == now.astimezone(zone).date() + timedelta(days=1):
        return f"tomorrow {clock}"
    return local.strftime("%a %b ") + str(local.day) + " " + clock


def is_verbatim(text: str, said: List[str]) -> bool:
    """The journal gets only Samin's own words: at least 80 % of the note's words, in order, in what he said."""
    words = _WORD.findall(text.lower().replace("’", "'"))
    pool = _WORD.findall(" ".join(said).lower().replace("’", "'"))
    if not words or not pool:
        return False
    hits, position = 0, 0
    for word in words:
        try:
            found = pool.index(word, position)
        except ValueError:
            continue
        hits, position = hits + 1, found + 1
    return hits / len(words) >= 0.8


class ToolRunner:
    """The R1's tool names on the Mac: most through the bridge's own mobile API over loopback with the internal
    assistant token (the same calls the Claude path's MCP server makes), the rest in-process (``mac_read``,
    ``mac_act``, ``mac_look``, ``journal_read``)."""

    def __init__(self, *, bridge_url: str, token: str, session: str, server: Any, mobile: Any,
                 said: Callable[[], List[str]], clock: Callable[[], float] = time.time) -> None:
        if mcp is None:
            raise RealtimeError("realtime_tools_missing", "The assistant's tools are not installed.")
        self.bridge = mcp.Bridge(bridge_url, "", session)
        self.bridge._token = token  # noqa: SLF001 - in memory only, never in a file or argv
        self.server = server
        self.mobile = mobile
        self.said = said
        self.clock = clock
        self.zone = getattr(mobile, "zone", None) or timezone.utc
        self._threads: Optional[List[Dict[str, Any]]] = None

    def _now(self) -> datetime:
        return datetime.fromtimestamp(self.clock(), self.zone)

    def run(self, name: str, raw_arguments: Any) -> ToolResult:
        try:
            arguments = json.loads(raw_arguments) if isinstance(raw_arguments, str) and raw_arguments.strip() else \
                (raw_arguments if isinstance(raw_arguments, dict) else {})
        except ValueError:
            return ToolResult({"isError": True, "error": "invalid_arguments", "message": "The arguments were not "
                               "valid JSON."}, is_error=True)
        if not isinstance(arguments, dict):
            arguments = {}
        handler = getattr(self, "_t_" + name, None) if re.fullmatch(r"[a-z0-9_]{1,40}", str(name)) else None
        if handler is None:
            return ToolResult({"isError": True, "error": "unknown_tool", "message": "That tool is not available on "
                               "the watch."}, is_error=True, arguments=arguments)
        try:
            result = handler(arguments)
        except _Failure as failure:
            return ToolResult({"isError": True, "error": failure.code, "message": failure.message}, is_error=True,
                              arguments=arguments)
        except Exception as error:  # noqa: BLE001 - ToolFailure (mcp), MacError, BridgeError: their own codes
            code = str(getattr(error, "code", "") or "tool_failed")
            message = str(getattr(error, "message", "") or "That did not work on the Mac.")
            if not getattr(error, "code", None):
                _LOG.warning("realtime tool failed (%s)", type(error).__name__)
            return ToolResult({"isError": True, "error": code, "message": message}, is_error=True,
                              arguments=arguments)
        if isinstance(result, ToolResult):
            result.arguments = arguments
            return result
        return ToolResult(result, arguments=arguments)

    # ------------------------------------------------------------------ T3
    def _all_threads(self) -> List[Dict[str, Any]]:
        """Every thread, the ones Samin dismissed in the inbox too (``dismissed: true``): a thread is still found by
        name; the list and its counts leave them out (``_shown_threads``)."""
        if self._threads is None:
            value = self.bridge.call("GET", "/v1/mobile/t3/threads?limit=100&include=dismissed")
            self._threads = [item for item in value.get("threads") or [] if isinstance(item, dict)]
        return self._threads

    def _shown_threads(self) -> List[Dict[str, Any]]:
        return [item for item in self._all_threads() if not item.get("dismissed")]

    def _brief(self, item: Dict[str, Any]) -> Dict[str, Any]:
        return {"id": item.get("threadId"), "title": item.get("title"), "project": item.get("projectName"),
                "status": item.get("status"), "label": item.get("statusLabel"),
                "when": _ago(item.get("updatedAt"), self._now())}

    def _resolve(self, query: Any) -> Dict[str, Any]:
        text = " ".join(str(query or "").split())
        if not text:
            raise _Failure("invalid_arguments", "Say which thread.")
        items = self._all_threads()
        found, candidates = match_thread(text, items)
        if found is not None:
            return found
        if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:-]{5,190}", text) and any(char.isdigit() for char in text):
            view = self.bridge.call("GET", "/v1/mobile/t3/threads/" + quote(text, safe=""))
            if isinstance(view.get("thread"), dict):
                return view["thread"]
        if candidates:
            options = "; ".join(f"“{item.get('title')}” in {item.get('projectName')} (id {item.get('threadId')})"
                                for item in candidates)
            raise _Failure("t3_thread_ambiguous", f"No thread clearly matches “{text}”. Closest: {options}. Ask the "
                           "user which one.")
        raise _Failure("t3_thread_not_found", f"No thread matches “{text}”. List threads to find it.")

    def _t_t3_list_threads(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        mode = str(arguments.get("filter") or "all")
        if mode not in ("needs-you", "working", "recent", "all"):
            raise _Failure("invalid_arguments", "filter must be needs-you, working, recent or all.")
        limit = arguments.get("limit") if isinstance(arguments.get("limit"), int) else 6
        limit = max(1, min(12, int(limit)))
        threads = self._shown_threads()
        counts = {"needsYou": sum(1 for item in threads if item.get("status") in ("needs_approval", "needs_input")),
                  "working": sum(1 for item in threads if item.get("status") == "working"),
                  "error": sum(1 for item in threads if item.get("status") == "error"),
                  "done": sum(1 for item in threads if item.get("status") in ("done", "idle"))}
        if mode == "needs-you":
            threads = [item for item in threads if item.get("status") in ("needs_approval", "needs_input", "error")]
        elif mode == "working":
            threads = [item for item in threads if item.get("status") == "working"]
        elif mode == "recent":
            threads.sort(key=lambda item: str(item.get("updatedAt") or ""), reverse=True)
        shown = threads[:limit]
        result: Dict[str, Any] = {"counts": counts, "filter": mode, "threads": [self._brief(item) for item in shown]}
        if len(threads) > len(shown):
            result["more"] = len(threads) - len(shown)
        if not shown:
            result["note"] = {"needs-you": "Nothing is waiting on the user.",
                              "working": "Nothing is running right now."}.get(mode, "No threads yet.")
        return result

    def _t_t3_read_thread(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        item = self._resolve(arguments.get("thread"))
        count = arguments.get("messages") if isinstance(arguments.get("messages"), int) else 1
        count = max(1, min(5, int(count)))
        view = self.bridge.call("GET", "/v1/mobile/t3/threads/" + quote(str(item.get("threadId")), safe=""))
        messages = [message for message in view.get("messages") or [] if isinstance(message, dict)]
        last = next((message.get("text") for message in reversed(messages) if message.get("role") == "assistant"),
                    None)
        result: Dict[str, Any] = {"thread": self._brief(view.get("thread") or item),
                                  "lastAssistant": _condense(last, 1500)}
        if count > 1:
            result["recent"] = [{"role": message.get("role"), "text": _condense(message.get("text"), 400)}
                                for message in messages[-count:]]
        pending = view.get("pending") if isinstance(view.get("pending"), dict) else None
        if pending and pending.get("kind") == "approval":
            result["approvals"] = [{"requestId": pending.get("requestId"), "kind": pending.get("requestKind"),
                                    "detail": _condense(pending.get("text"), 300),
                                    "decisions": [option.get("decision") for option in pending.get("options") or []
                                                  if isinstance(option, dict)]}]
        elif pending and pending.get("kind") == "question":
            questions = pending.get("questions") if isinstance(pending.get("questions"), list) else []
            result["questions"] = [{"requestId": pending.get("requestId"), "questions": [
                {"id": question.get("id"), "question": _condense(question.get("text"), 300),
                 "options": [_condense(option, 80) for option in (question.get("options") or [])[:6]],
                 **({"allowCustom": True} if question.get("allowCustom") else {}),
                 **({"multiSelect": True} if question.get("multiSelect") else {})}
                for question in questions[:4] if isinstance(question, dict)]}]
        if view.get("activeTurnId"):
            result["working"] = True
        return result

    def _project(self, name: Any) -> Optional[str]:
        text = " ".join(str(name or "").split())
        if not text:
            return None
        project_id, _name = mcp._project_id(self.bridge, text)  # noqa: SLF001 - the same lookup as the MCP tools
        return project_id

    def _create(self, text: str, title: Any, project: Any) -> Dict[str, Any]:
        body: Dict[str, Any] = {"text": text}
        project_id = self._project(project)
        if project_id:
            body["projectId"] = project_id
        if isinstance(title, str) and title.strip():
            body["title"] = " ".join(title.split())[:80]
        value = self.bridge.call("POST", "/v1/mobile/t3/threads", body, timeout=mcp.SLOW_TIMEOUT)
        self._threads = None
        return value

    def _t_t3_new_thread(self, arguments: Dict[str, Any]) -> ToolResult:
        prompt = mcp._text_arg(arguments, "prompt", limit=8000)  # noqa: SLF001
        value = self._create(str(prompt), arguments.get("title"), arguments.get("project"))
        result = {"started": True, "threadId": value.get("threadId"), "title": value.get("title"),
                  "project": value.get("projectName"), "status": "working"}
        return ToolResult(result, action={"kind": "task_started", "title": _condense(value.get("title") or prompt, 80)
                                          or "New task", "threadId": value.get("threadId")})

    def _t_t3_send_message(self, arguments: Dict[str, Any]) -> ToolResult:
        item = self._resolve(arguments.get("thread"))
        text = mcp._text_arg(arguments, "text", limit=8000)  # noqa: SLF001
        value = self.bridge.call("POST", f"/v1/mobile/t3/threads/{quote(str(item.get('threadId')), safe='')}/message",
                                 {"text": text}, timeout=mcp.SLOW_TIMEOUT)
        return ToolResult({"sent": True, "thread": item.get("title"), "queued": bool(value.get("wasWorking"))},
                          action={"kind": "task_replied", "title": "Message sent", "threadId": item.get("threadId")})

    def _t_t3_respond(self, arguments: Dict[str, Any]) -> ToolResult:
        item = self._resolve(arguments.get("thread"))
        thread_id = str(item.get("threadId"))
        decision = arguments.get("decision")
        answer = arguments.get("answer")
        answers = arguments.get("answers")
        body: Dict[str, Any] = {}
        if decision is not None:
            if decision not in ("accept", "acceptForSession", "decline", "cancel"):
                raise _Failure("invalid_arguments", "decision must be accept, acceptForSession, decline or cancel.")
            body["decision"] = decision
        elif isinstance(answer, str) and answer.strip():
            body["answer"] = answer.strip()
        elif isinstance(answers, list) and answers:
            view = self.bridge.call("GET", "/v1/mobile/t3/threads/" + quote(thread_id, safe=""))
            pending = view.get("pending") if isinstance(view.get("pending"), dict) else {}
            questions = [question for question in pending.get("questions") or [] if isinstance(question, dict)]
            if len(questions) < len(answers):
                raise _Failure("invalid_arguments", "There are fewer questions than answers. Read the thread again.")
            body["answers"] = {str(question.get("id")): [part.strip() for part in str(value).split(" | ")]
                               if question.get("multiSelect") else str(value)
                               for question, value in zip(questions, answers)}
        else:
            raise _Failure("invalid_arguments", "Pass decision for an approval, or answer / answers for a question.")
        request_id = arguments.get("requestId")
        if isinstance(request_id, str) and request_id.strip():
            body["requestId"] = request_id.strip()
        value = self.bridge.call("POST", f"/v1/mobile/t3/threads/{quote(thread_id, safe='')}/respond", body,
                                 timeout=mcp.SLOW_TIMEOUT)
        self._threads = None
        label = {"accept": "Approved", "acceptForSession": "Approved", "acceptAlways": "Approved",
                 "decline": "Denied", "cancel": "Cancelled"}.get(str(value.get("decision")), "Answered")
        return ToolResult({"done": True, "thread": item.get("title"), "decision": value.get("decision"),
                           "answered": bool(value.get("answers"))},
                          action={"kind": "task_answered", "title": label, "threadId": thread_id})

    def _t_t3_stop(self, arguments: Dict[str, Any]) -> ToolResult:
        item = self._resolve(arguments.get("thread"))
        thread_id = str(item.get("threadId"))
        value = self.bridge.call("POST", f"/v1/mobile/t3/threads/{quote(thread_id, safe='')}/stop", {},
                                 timeout=mcp.SLOW_TIMEOUT)
        stopped = bool(value.get("wasWorking"))
        self._threads = None
        return ToolResult({"stopped": stopped, "thread": item.get("title"),
                           "note": None if stopped else "It was not running."},
                          action={"kind": "task_stopped", "title": "Stopped", "threadId": thread_id} if stopped
                          else None)

    def _t_mark_seen(self, arguments: Dict[str, Any]) -> ToolResult:
        """The dock's Mark seen by voice (``mcp.mark_seen``), the thing found as the T3 tools find a thread."""
        items = mcp.inbox_items(self.bridge)
        if arguments.get("all") is True:
            targets = mcp.unseen_finished(items)
        else:
            text = " ".join(str(arguments.get("item") or "").split())
            if not text:
                raise _Failure("invalid_arguments", "Say which one, or all.")
            views = [dict(item, threadId=item["id"]) for item in items]
            found, candidates = match_thread(text, views)
            if found is None:  # a thread id from t3_list_threads
                found = next((view for view in views if view["threadId"] == "t3:" + text), None)
            if found is None:
                if candidates:
                    raise _Failure("item_ambiguous", "Nothing clearly matches “" + text + "”. Closest: " + "; ".join(
                        f"“{item.get('title')}”" for item in candidates) + ". Ask the user which one.")
                raise _Failure("item_not_found", f"Nothing in the inbox matches “{text}”.")
            targets = [next(item for item in items if item["id"] == found["threadId"])]
        value = mcp.mark_items_seen(self.bridge, targets)
        self._threads = None
        return ToolResult({key: item for key, item in value.items() if item is not None})

    # ------------------------------------------------------------------ calendar
    def _event_view(self, item: Dict[str, Any], now: datetime) -> Dict[str, Any]:
        start = _parse_time(item.get("startsAt"), self.zone)
        end = _parse_time(item.get("endsAt"), self.zone)
        value: Dict[str, Any] = {"title": _condense(item.get("title"), 120)}
        if item.get("allDay"):
            value["allDay"] = True
        if start is not None and not item.get("allDay"):
            value["startsLocal"] = _local(start, self.zone, now)
            value["startsInMinutes"] = int(math.floor((start - now).total_seconds() / 60))
        if end is not None and not item.get("allDay"):
            value["endsLocal"] = _local(end, self.zone, now)
        if item.get("location"):
            value["location"] = _condense(item.get("location"), 120)
        if item.get("meetingUrl"):
            value["hasMeetingLink"] = True
        return value

    def _t_calendar_list_upcoming(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        now = self._now()
        within = arguments.get("withinMinutes")
        if within is not None and (isinstance(within, bool) or not isinstance(within, int) or
                                   not 1 <= within <= 10080):
            raise _Failure("invalid_arguments", "withinMinutes must be 1 to 10080.")
        start, end = now, None
        if within:
            end = now + timedelta(minutes=int(within))
            label = f"the next {within} minutes"
        else:
            raw_from, raw_to = arguments.get("from"), arguments.get("to")
            if isinstance(raw_from, str) and raw_from.strip() and raw_from.strip().lower() != "now":
                start = _parse_time(raw_from, self.zone) or now
            if isinstance(raw_to, str) and raw_to.strip():
                end = _parse_time(raw_to, self.zone)
                if end is None:
                    raise _Failure("invalid_arguments", "to must be an ISO 8601 time.")
            label = None
        explicit = end is not None
        if end is None:
            end = start + timedelta(hours=12)
        if end <= max(start, now):
            raise _Failure("invalid_arguments", "That window is already over.")
        if label is None:
            label = f"{_local(start, self.zone, now)} to {_local(end, self.zone, now)}" if explicit else \
                "the next 12 hours"
        hours = max(1, min(168, int(math.ceil((end - now).total_seconds() / 3600))))
        value = self.bridge.call("GET", "/v1/mobile/calendar/agenda?" + urlencode({"hours": hours}))
        events = [item for item in value.get("events") or [] if isinstance(item, dict)]
        long_window = (end - start) >= timedelta(hours=6)
        in_window, all_day = [], []
        for item in events:
            item_start = _parse_time(item.get("startsAt"), self.zone)
            item_end = _parse_time(item.get("endsAt"), self.zone) or item_start
            if item_start is None:
                continue
            if item.get("allDay"):
                if item_start.date() <= end.date() and (item_end or item_start).date() >= start.date():
                    (in_window if long_window else all_day).append(item)
                continue
            if item_start < end and (item_end or item_start) > start:
                in_window.append(item)
        limit = arguments.get("limit") if isinstance(arguments.get("limit"), int) else 10
        shown = in_window[:max(1, min(50, int(limit)))]
        result: Dict[str, Any] = {"window": label, "count": len(in_window),
                                  "events": [self._event_view(item, now) for item in shown]}
        if all_day:
            result["allDayToday"] = [_condense(item.get("title"), 80) for item in all_day[:5]]
        if not in_window:
            result["note"] = "No events in that window."
        if value.get("stale"):
            result["stale"] = "From a cached copy; Google Calendar did not answer just now."
        return result

    def _t_calendar_create_event(self, arguments: Dict[str, Any]) -> ToolResult:
        title = mcp._text_arg(arguments, "title", limit=300)  # noqa: SLF001
        now = self._now().replace(second=0, microsecond=0)
        raw_start = mcp._text_arg(arguments, "startsAt", limit=64)  # noqa: SLF001
        start = now if str(raw_start).lower() == "now" else _parse_time(raw_start, self.zone)
        if start is None:
            raise _Failure("invalid_arguments", "startsAt must be an ISO 8601 time or now.")
        end = _parse_time(arguments.get("endsAt"), self.zone)
        duration = arguments.get("durationMinutes")
        if end is None and isinstance(duration, int) and not isinstance(duration, bool) and 1 <= duration <= 20160:
            end = start + timedelta(minutes=duration)
        if end is None:
            raise _Failure("missing_end", "Ask how long it should be (or when it ends).")
        if end <= start:
            raise _Failure("invalid_arguments", "The end must be after the start.")
        body: Dict[str, Any] = {"title": title, "startsAt": start.isoformat(timespec="seconds"),
                                "endsAt": end.isoformat(timespec="seconds")}
        for key in ("location", "description"):
            if isinstance(arguments.get(key), str) and arguments[key].strip():
                body[key] = arguments[key].strip()[:2000]
        value = self.bridge.call("POST", "/v1/mobile/calendar/events", body, timeout=mcp.SLOW_TIMEOUT)
        event = value.get("event") if isinstance(value.get("event"), dict) else {}
        now_full = self._now()
        result = {"added": True, "title": event.get("title") or title,
                  "startsLocal": _local(start, self.zone, now_full), "endsLocal": _local(end, self.zone, now_full)}
        return ToolResult(result, action={"kind": "event_created", "title": _condense(result["title"], 80) or "Event",
                                          "eventId": event.get("eventId")})

    # ------------------------------------------------------------------ journal
    def _t_journal_add(self, arguments: Dict[str, Any]) -> ToolResult:
        text = mcp._text_arg(arguments, "text", limit=4000)  # noqa: SLF001
        if not is_verbatim(str(text), self.said()):
            raise _Failure("not_verbatim", "Only the user's own words can go in the journal, and these are not what "
                           "they said. Ask them to say exactly what to add.")
        value = self.bridge.call("POST", "/v1/mobile/journal", {"text": text})
        if not value.get("recorded"):
            return ToolResult({"isError": True, "recorded": False, "reason": "not_recorded"}, is_error=True)
        result: Dict[str, Any] = {"recorded": True, "state": "sent", "date": value.get("date"),
                                  "time": value.get("time")}
        if value.get("redacted"):
            result["note"] = "A code, password or key in it was written as [redacted]."
        if value.get("dryRun"):
            result["dryRun"] = True
            result["note"] = "Test copy of the Mac bridge: kept in a dry run, not written to Heptabase."
        return ToolResult(result, action={"kind": "journal_added", "title": "Journal note"})

    def _t_journal_read(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        if self.server is None or not callable(getattr(self.server, "read", None)):
            raise _Failure("journal_unavailable", "The journal is not set up on the Mac.")
        raw = str(arguments.get("date") or "today").strip().lower()
        today = self._now().date()
        if raw in ("", "today"):
            day = today
        elif raw == "yesterday":
            day = today - timedelta(days=1)
        else:
            try:
                day = Date.fromisoformat(raw)
            except ValueError:
                raise _Failure("invalid_arguments", "date must be today, yesterday or YYYY-MM-DD.") from None
        value = self.server.read(day.isoformat())
        text = str(value.get("text") or "")
        scrub = getattr(sys.modules.get("samrabbit_mobile"), "scrub_secrets", None)
        if callable(scrub):
            text = scrub(text)
        result: Dict[str, Any] = {"date": day.isoformat(), "text": text[:4000] or None,
                                  "truncated": True if len(text) > 4000 else None}
        if not text:
            result["note"] = "Nothing in the journal that day."
        if value.get("dryRun"):
            result["dryRun"] = True
        return result

    # ------------------------------------------------------------------ the Mac
    def _control(self) -> Any:
        control = getattr(self.server, "mac", None)
        if control is None:
            raise _Failure("mac_unavailable", "Mac control is not set up on the bridge.")
        return control

    def _t_mac_status(self, _arguments: Dict[str, Any]) -> Dict[str, Any]:
        state = self.bridge.call("GET", "/v1/mobile/mac/state")
        if state.get("available") is False:
            error = state.get("error") if isinstance(state.get("error"), dict) else {}
            raise _Failure(str(error.get("code") or "mac_unavailable"),
                           str(error.get("message") or "The Mac could not be read right now."))
        result: Dict[str, Any] = {"computer": state.get("computer"), "front": state.get("front")}
        result["visible"] = [{"app": entry.get("app"), "windows": list(entry.get("windows") or [])[:2]}
                             for entry in state.get("visible") or [] if isinstance(entry, dict) and entry.get("app")][:8]
        chrome = []
        for window in state.get("chrome") or []:
            if isinstance(window, dict):
                tabs = list(window.get("tabs") or [])
                chrome.append({"activeTab": window.get("activeTab"), "tabCount": len(tabs), "tabs": tabs[:8],
                               "activeUrl": window.get("activeUrl")})
        result["chrome"] = chrome
        running = list(state.get("running") or [])
        result["running"] = running[:25]
        if len(running) > 25:
            result["moreRunning"] = len(running) - 25
        if state.get("screenVision") is False:
            result["screenVision"] = "off"
        if state.get("screenLocked") is True:
            result["screenLocked"] = True
        return result

    def _t_mac_open(self, arguments: Dict[str, Any]) -> ToolResult:
        given = {key: arguments[key].strip() for key in ("app", "url", "path")
                 if isinstance(arguments.get(key), str) and arguments[key].strip()}
        if len(given) != 1:
            raise _Failure("invalid_arguments", "Pass exactly one of app, url or path.")
        if "path" in given:
            value = self._control().open({"path": given["path"]})
            title = os.path.basename(given["path"].rstrip("/")) or given["path"]
        else:
            value = mcp.mac_open(self.bridge, given)
            title = value.get("app") or given.get("app") or given.get("url")
        return ToolResult({"opened": True, **{key: item for key, item in value.items() if key in
                                               ("app", "url", "path", "opened", "googleAccount")}},
                          action={"kind": "mac_opened", "title": _condense(title, 80) or "Opened on the Mac"})

    def _t_mac_read(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        limit = arguments.get("max") if isinstance(arguments.get("max"), int) else 4000
        app = arguments.get("app") if isinstance(arguments.get("app"), str) and arguments["app"].strip() else None
        result = self._control().read(app.strip() if app else None, max(500, min(6000, int(limit))))
        value: Dict[str, Any] = {"app": result.get("app"), "window": result.get("window"),
                                 "text": str(result.get("text") or "")}
        controls = [str(item) for item in result.get("controls") or []][:25]
        if controls:
            value["controls"] = controls
        if result.get("truncated"):
            value["truncated"] = True
        if result.get("note"):
            value["note"] = result["note"]
        return value

    def _t_mac_act(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        body = {key: value for key, value in arguments.items() if value not in (None, "", [])}
        return self._control().act(body)

    def _t_mac_look(self, arguments: Dict[str, Any]) -> ToolResult:
        app = arguments.get("app") if isinstance(arguments.get("app"), str) and arguments["app"].strip() else None
        shot: Dict[str, Any] = {}
        data = b""
        for side in SCREENSHOT_SIDES:
            try:
                shot = self._control().screenshot(app.strip() if app else None, side)
            except Exception as error:  # noqa: BLE001 - MacError
                code = str(getattr(error, "code", "") or "")
                if code == "screen_locked":
                    return ToolResult({"isError": True, "code": "screen_locked", "screenLocked": True, "image": "none",
                                       "message": SCREEN_LOCKED_NOTE}, is_error=True)
                if code == "screen_recording_required":
                    return ToolResult({"isError": True, "code": code, "message": (
                        "Screen vision is off on the Mac: macOS has not allowed cua-driver to record the screen. "
                        "Tell the user once, briefly: to turn it on, run 'cua-driver permissions grant' in a terminal "
                        "on the Mac and allow Screen Recording. Meanwhile use mac_read for what is on the screen.")},
                        is_error=True)
                raise
            try:
                data = base64.b64decode(str(shot.get("base64") or ""))
            except (ValueError, TypeError):
                data = b""
            if data and len(base64.b64encode(data)) <= MAX_IMAGE_B64:
                break
        if not data:
            raise _Failure("capture_failed", "The Mac could not take a screenshot.")
        mime = str(shot.get("mime") or "image/jpeg")
        attached = len(base64.b64encode(data)) <= MAX_IMAGE_B64
        summary = {"ok": True, "image": "attached" if attached else "too_large", "width": shot.get("width"),
                   "height": shot.get("height"), "app": shot.get("app"),
                   "note": "The screenshot is attached as an image. Describe only what matters, briefly." if attached
                   else "The screenshot was too large to show you; use mac_read instead."}
        return ToolResult(summary, images=[(mime, data)] if attached else [])

    def _t_mac_task(self, arguments: Dict[str, Any]) -> ToolResult:
        request = mcp._text_arg(arguments, "request", limit=4000)  # noqa: SLF001
        prompt = (f"{request}\n\n---\nYou are acting for Samin via the SamRabbit voice assistant on his Apple Watch, "
                  "on this Mac. You may use the cua-driver CLI/skill to see and control apps, the Aside browser, and "
                  "the terminal. Ask before anything destructive or outward-facing (deleting, sending messages or "
                  "email, purchases). Reply with a short summary when done; it is read aloud.")
        value = self._create(prompt, arguments.get("title") or str(request)[:60], arguments.get("project"))
        return ToolResult({"started": True, "threadId": value.get("threadId"), "title": value.get("title"),
                           "project": value.get("projectName"), "status": "working"},
                          action={"kind": "task_started", "title": _condense(value.get("title") or request, 80)
                                  or "Mac task", "threadId": value.get("threadId")})

    # ------------------------------------------------------------------ visuals and cards
    def _t_ui_generate(self, arguments: Dict[str, Any]) -> ToolResult:
        request = mcp._text_arg(arguments, "request", limit=4000)  # noqa: SLF001
        body: Dict[str, Any] = {"prompt": request}
        if isinstance(arguments.get("data"), str) and arguments["data"].strip():
            body["data"] = arguments["data"][:24000]
        value = self.bridge.call("POST", "/v1/mobile/ui/generate", body)
        return ToolResult({"started": True, "status": value.get("status") or "generating",
                           "artifactId": value.get("artifactId"),
                           "say": "Drawing that now; it will show up on your phone and your Mac.",
                           "note": "It appears on his iPhone and in the desktop app, not on the watch."},
                          action={"kind": "ui_generated", "title": _condense(request, 80) or "Visual",
                                  "artifactId": value.get("artifactId")})

    @staticmethod
    def _card(arguments: Dict[str, Any]) -> Dict[str, Any]:
        title = _condense(arguments.get("title"), 40) or ""
        lines = [line for line in (_condense(item, 48) for item in (arguments.get("lines") or [])[:3]
                                   if isinstance(item, str)) if line]
        subtitle = _condense(arguments.get("subtitle"), 60)
        body = "\n".join(([subtitle] if subtitle else []) + lines)
        return {"title": title, "body": body[:200]}

    def _t_show_card(self, arguments: Dict[str, Any]) -> ToolResult:
        card = self._card(arguments)
        if not card["title"]:
            raise _Failure("invalid_arguments", "A card needs a title.")
        return ToolResult({"shown": True, "on": "Apple Watch"}, card=card)

    def _t_update_card(self, arguments: Dict[str, Any]) -> ToolResult:
        card = self._card(arguments)
        if not card["title"]:
            return ToolResult({"updated": False, "note": "Nothing to show without a title."})
        return ToolResult({"updated": True, "on": "Apple Watch"}, card=card)

    def _t_dismiss_card(self, _arguments: Dict[str, Any]) -> Dict[str, Any]:
        return {"dismissed": True}

    # ------------------------------------------------------------------ the watch's own
    def _t_get_status(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        return mcp.get_status(self.bridge, arguments)

    def _t_recent_conversations(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        return mcp.recent_conversations(self.bridge, arguments)


# --------------------------------------------------------------------------- the brain


class RealtimeBrain:
    """Is the realtime voice usable (ChatGPT connected, the helper ready, not paused), and the signaling."""

    def __init__(self, auth: Any, *, python: Optional[str], script: str = HELPER_SCRIPT, api_root: str = API_ROOT,
                 model: Callable[[], str] = lambda: profile.DEFAULT_MODEL,
                 voice: Callable[[], str] = lambda: profile.DEFAULT_VOICE,
                 checker: Optional[HelperCheck] = None, monotonic: Callable[[], float] = time.monotonic) -> None:
        self.auth = auth
        self._python = os.path.expanduser(python) if python else None
        self.script = script
        self.api_root = api_root.rstrip("/")
        self.model = model
        self.voice = voice
        self.checker = checker or HelperCheck(self._python, script)
        self._monotonic = monotonic
        self._lock = threading.Lock()
        self._paused: Optional[Tuple[float, float, str]] = None
        self._live: set = set()
        self.last_error: Optional[str] = None

    def python(self) -> str:
        if not self._python:
            raise RealtimeError("realtime_helper_missing", "The realtime helper is not installed.")
        return self._python

    def helper_status(self) -> Dict[str, Any]:
        return self.checker.status()

    def pause(self, seconds: float, reason: str) -> None:
        if seconds > 0:
            with self._lock:
                self._paused = (self._monotonic(), seconds, reason)

    def resume(self) -> None:
        with self._lock:
            self._paused = None

    def paused(self) -> Optional[str]:
        with self._lock:
            paused = self._paused
            if paused is not None and self._monotonic() - paused[0] >= paused[1]:
                self._paused = paused = None
        return paused[2] if paused else None

    def off_reason(self) -> Optional[str]:
        off = getattr(self.auth, "off", None)
        if off:
            return str(off)
        if not self.auth.connected():
            status = self.auth.status()
            return "chatgpt_reconnect_required" if status.get("reason") == "reconnect_required" else \
                "chatgpt_not_connected"
        helper = self.helper_status()
        if not helper.get("ready"):
            return str(helper.get("reason") or "realtime_helper_missing")
        return self.paused()

    def status(self) -> Dict[str, Any]:
        reason = self.off_reason()
        account = self.auth.status()
        value: Dict[str, Any] = {"available": reason is None, "model": self.model(), "voice": self.voice(),
                                 "helper": self.helper_status(), "sessions": self.sessions,
                                 "chatgpt": {"connected": bool(account.get("connected")),
                                             **({"plan": account["plan"]} if account.get("plan") else {})}}
        if reason:
            value["reason"] = reason
        if self.last_error:
            value["lastError"] = self.last_error
        return value

    def signal(self, offer: str, config: Dict[str, Any]) -> str:
        """The R1's ``create_realtime_call``: the offer + session to OpenAI with the ChatGPT access token; a refused
        token is refreshed once. The token stays in this process."""
        token = self._token()
        safety = chatgpt.safety_identifier(self.auth.safety_id()) if chatgpt is not None else \
            hashlib.sha256(b"sam-mac:unknown").hexdigest()
        status, answer, detail = create_call(self.api_root, token, safety, offer, config)
        if status in (401, 403):
            token = self._token(force=True)
            status, answer, detail = create_call(self.api_root, token, safety, offer, config)
        if 200 <= status < 300 and answer.startswith("v=0"):
            self.last_error = None
            return answer
        code = re.sub(r"[^a-z0-9_]", "", str(detail.get("code") or detail.get("type") or "").lower())[:40]
        _LOG.warning("realtime call refused (HTTP %d%s)", status, f", {code}" if code else "")
        self.last_error = f"http_{status}" + (f"_{code}" if code else "")
        if status in (401, 403):
            raise RealtimeError("chatgpt_rejected", "OpenAI refused the ChatGPT login.", pause=PAUSE_REJECTED_SECONDS,
                                reason="chatgpt_rejected")
        if status == 429:
            raise RealtimeError("realtime_busy", "OpenAI is busy or the limit is reached.", pause=PAUSE_BUSY_SECONDS,
                                reason="realtime_busy")
        if status >= 500:
            raise RealtimeError("realtime_unavailable", "OpenAI could not start the session.",
                                pause=PAUSE_FAILED_SECONDS)
        raise RealtimeError("realtime_rejected", "OpenAI could not start this session.", pause=PAUSE_BUSY_SECONDS,
                            reason="realtime_rejected")

    def _token(self, *, force: bool = False) -> str:
        try:
            return self.auth.access_token(force_refresh=force)
        except Exception as error:  # noqa: BLE001 - ChatGPTError
            code = str(getattr(error, "code", "") or "chatgpt_not_connected")
            if code == "chatgpt_unreachable":
                raise RealtimeError("realtime_unreachable", "ChatGPT is not reachable right now.",
                                    pause=PAUSE_FAILED_SECONDS) from None
            raise RealtimeError(code, "ChatGPT needs to be connected on the Mac.", reason=code) from None

    def start(self, session: RealtimeSession) -> None:
        """Open ``session`` (blocks about a second); a refusal pauses the brain (``off_reason``)."""
        try:
            session.open()
        except RealtimeError as error:
            if error.pause and not session.closing:
                self.pause(error.pause, error.reason)
            raise
        with self._lock:
            # Closed while it opened (an end, the cap): it is not live, whatever the helper managed meanwhile.
            if session.closing or session.state != "open":
                closed = True
            else:
                closed = False
                self._live.add(session)
        if closed:
            session.error = _closed()
            session.close()
            raise session.error

    def discard(self, session: RealtimeSession) -> None:
        with self._lock:
            session.closing = True
            self._live.discard(session)

    @property
    def sessions(self) -> int:
        with self._lock:
            return len(self._live)


def pcm_to_wav(pcm: bytes, rate: int = 16_000) -> bytes:
    """PCM16LE mono -> a WAV file (the buffered JSON answer's ``audio``)."""
    import struct  # noqa: PLC0415

    size = len(pcm)
    return b"RIFF" + struct.pack("<I", 36 + size) + b"WAVEfmt " + struct.pack("<IHHIIHH", 16, 1, 1, rate, rate * 2, 2,
                                                                            16) + b"data" + struct.pack("<I", size) + pcm
