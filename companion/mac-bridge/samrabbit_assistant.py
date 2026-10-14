"""SamRabbit's voice assistant on the Mac bridge, for the Apple Watch (and the iPhone's Siri path).

The watch listens, sends one utterance at a time, plays the answer and listens again. The Mac does the rest, with
one of two brains (setting ``assistant.brain``: ``auto`` (the default), ``realtime`` or ``claude``):

* **realtime** (primary, like the R1): speech to text (samrabbit_transcribe) --> gpt-realtime-2.1 on Samin's ChatGPT
  subscription, the voice ``marin``, the R1's instructions and tool names (``samrabbit_realtime``: the Mac is the
  WebRTC peer; ``samrabbit_chatgpt``: the Mac's own ChatGPT login) --> the reply streamed as it is spoken;
* **claude** (the fallback when ChatGPT is not connected, the realtime helper is not installed, or OpenAI refuses):
  speech to text --> one agent turn (``claude -p``, Claude Haiku 5.5 by default, SamRabbit's own tools over MCP, the
  conversation's session resumed) --> ElevenLabs (the Jarvis voice).

``auto`` uses realtime when ChatGPT is connected and the helper is ready, else Claude; a realtime turn that fails
before it said anything is answered by Claude instead.

Streaming (``Accept: application/x-samrabbit-stream`` on a turn; the shared contract with the watch): ``200``,
``Content-Type: application/x-samrabbit-stream``, ``Transfer-Encoding: chunked`` (HTTP/1.1), then frames of one type
byte, a 4-byte big-endian length and the payload: ``J`` = one UTF-8 JSON event (``{"type": "heard", "text"}``,
``{"type": "say.delta", "text"}``, ``{"type": "say.done", "text"}``, ``{"type": "action", kind, title, threadId?,
artifactId?}``, ``{"type": "card", title, body}``, ``{"type": "done", conversationId, turnId, expectReply,
endConversation, interrupted?, brain, timings: {stt, firstAudio, total}}``, ``{"type": "error", code, message}``
(always followed by ``done``), ``{"type": "ping"}``), ``A`` = PCM16LE mono 16 kHz audio, up to 100 ms per frame.
Keep-alive: while a turn is open (or a retry waits for it), a stream that wrote nothing for 10 s writes a ping (the
watch gives up on 40 s of silence; a long tool call writes nothing); a ping may start the stream, and a failure after
that comes as ``error`` + ``done`` in it. Without that header a turn answers the buffered JSON below (a realtime
turn's audio as ``audio/wav``, Claude's as ``audio/mpeg``).

Routes (through ``samrabbit_mobile``: a paired device's token and the LAN / Tailscale peer check):

* ``POST /v1/mobile/assistant/turn``:
  - audio body (``audio/wav``, ``audio/mp4``, ``audio/x-m4a``; at most 2 MiB and 60 s) with the headers
    ``X-SamRabbit-Conversation`` (an id, or empty for a new conversation), ``X-SamRabbit-Turn`` (a uuid: a retry of
    the same turn gets the same answer, the agent runs once) and ``X-SamRabbit-Device-Time`` (optional); ``?lang=``
    as for ``/v1/mobile/transcribe``;
  - or a JSON body ``{text, conversationId?, turnId}`` (typed or debug input, the iPhone's Siri path), or
    ``{announce: "<announcement id>", conversationId, turnId}`` (say that announcement, in the session's voice);
  - -> ``{conversationId, turnId, heard, say, audio: {mime: "audio/mpeg" | "audio/wav", b64} | null, expectReply,
    endConversation, actions: [{kind, title, threadId?, artifactId?, eventId?}], timings: {stt, agent, tts}, brain}``.
    ``audio`` is null when the voice is off or failed (the watch then speaks ``say`` itself). Nothing heard (or only
    "uh", "um", "er", "hmm") answers ``{heard: "", say: "", audio: null, expectReply: true}`` without a brain; short
    confirmations ("okay", "yes", "yeah", "mhm") are words. "Bye", "stop", "thanks, that's all" end the conversation
    (``endConversation: true``) with a short goodbye.
  - One turn per conversation at a time: another one meanwhile answers 409 ``assistant_busy`` (retryable).
  - Limits: speech to text 45 s, the agent 25 s (504 ``assistant_timeout``; its whole process group is killed),
    the voice 10 s (then ``audio: null``), a realtime turn 150 s. Errors: ``assistant_unavailable`` (503, with
    ``reason``), ``assistant_timeout``, ``assistant_busy``, ``assistant_interrupted``, ``transcribe_*``, ``invalid_*``.
* ``POST /v1/mobile/assistant/session {conversationId?}`` -> ``{conversationId, brain, ready}``: warm up (the
  realtime session opens in the background, so the first turn does not wait for it).
* ``POST /v1/mobile/assistant/cancel {conversationId, turnId?}`` -> ``{ok, cancelled}``: stop the current reply (tap
  to interrupt); its stream ends with ``done {interrupted: true}``. With ``turnId`` only that turn is stopped: a cancel
  that arrives after it ended never stops the next one (``cancelled: false``).
* ``GET /v1/mobile/assistant/announcements?conversationId=&since=`` -> ``{items: [{id, say, audio | null, kind:
  "needs_you" | "done" | "error", threadId, title}], cursor}``: T3 tasks that started needing Samin, finished or
  failed since the conversation began, each announced once per conversation (the watch polls about every 20 s).
  With the realtime brain ``audio`` is null: the watch asks for ``{announce: id}`` and the session says it. The next
  turn tells the brain what was announced, so "approve it" works.
* ``POST /v1/mobile/assistant/end {conversationId}`` (optional): the watch stopped listening (the realtime session
  closes too).
* The desktop app's voice (the Agent Dock's mic, its shortcut, the wake phrase): the same five routes under
  ``/v1/desktop/assistant/*``, for the desktop token from this Mac only (``samrabbit_mobile``), as the device "mac"
  (``MAC_DEVICE``). Its conversations are "Mac" ones (``mac-<conversationId>``, titled ``Mac: <first words>``,
  origin ``mac``), the Claude brain gets ``MAC_SYSTEM_PROMPT`` (one to three sentences, his T3 threads in the dock) and
  ``device: mac``, the realtime brain the Mac addendum (``samrabbit_realtime_profile.MAC_INSTRUCTION``) instead of
  the watch's. The Mac and the watch never share a conversation.
* ChatGPT login (loopback + desktop token, for the desktop app and ``connect-chatgpt.sh``; see ``samrabbit_chatgpt``):
  ``POST /v1/assistant/chatgpt/start``, ``GET /v1/assistant/chatgpt/status``, ``POST /v1/assistant/chatgpt/disconnect``.

The agent is the headless Claude Code CLI, isolated from the user's own setup: ``--setting-sources ""`` (no user or
project settings, hooks, plugins, CLAUDE.md or MCP servers: the user's hooks would upload utterances),
``--strict-mcp-config --mcp-config <0600 file>`` (only ``samrabbit_assistant_mcp.py``), ``--tools ""`` (no built-in
tools), ``--allowedTools mcp__samrabbit``, ``--permission-mode dontAsk``, ``--disable-slash-commands``,
``--max-turns 6``, ``--system-prompt-file``, ``--session-id`` on a conversation's first turn and ``--resume``
after it; a minimal environment (``HOME USER LOGNAME TMPDIR LANG`` and ``PATH``, plus
``CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC CLAUDE_CODE_DISABLE_AUTO_MEMORY DISABLE_AUTOUPDATER``); an empty working
folder of its own; its own session (``start_new_session``) so a timeout kills the CLI and its MCP server together.
Never ``--bare`` (no login) or ``--safe-mode`` (no MCP servers). The prompt goes in on stdin, never in argv.

Its tools call this bridge's own mobile API over loopback with an internal assistant token (made at start, kept in
memory and in a 0600 file for the MCP server, never logged; loopback only; a short list of routes). A copy of the
bridge run from a checkout therefore only reaches its own dev-safe answers; it also runs the agent only with an
explicit ``--claude`` and the voice only with an explicit ``--elevenlabs-key-file`` (never the real key, never
ElevenLabs credits), and keeps its working files in a temp folder.

Settings (``~/.config/samrabbit/assistant.json``, re-read every turn): ``{"brain": "auto" | "realtime" | "claude",
"realtimeModel": "gpt-realtime-2.1", "realtimeVoice": "marin", "model": "claude-haiku-5-5" | "claude-sonnet-5-5",
"voice": "<ElevenLabs voice id>"}`` (``assistant.brain``, ``assistant.realtimeModel``, ``assistant.model``,
``assistant.voice``; the default ElevenLabs voice is Jarvis ``sI8FqE1zOcqXDhRwCwAx``); ``--assistant-brain``,
``--assistant-model`` / ``--assistant-voice`` (or SAMRABBIT_ASSISTANT_BRAIN / _MODEL / _VOICE) win. The voice key is
``~/.config/samrabbit/elevenlabs-key`` (0600; install.sh copies ELEVENLABS_API_KEY from ``~/.hermes/.env``). The
realtime brain needs the Mac's ChatGPT login (``~/.config/samrabbit/chatgpt-auth.json``) and the realtime venv
(``~/Library/Application Support/SamRabbit/realtime-venv``, made by install.sh); a copy run from a checkout uses them
only with an explicit ``--chatgpt-auth-file`` and ``--realtime-python``.

Every turn is recorded in the sync store as a "Watch" conversation (``watch-<conversationId>``): ``conversation.started``,
``message.user``, ``tool.completed`` (a ``mac_look`` screenshot as an image blob), ``message.assistant.done``,
``conversation.ended``; announcements as ``host.t3_update``; all with origin ``watch``, so the desktop app and the
iPhone's Chats show them. Utterances, replies, tool inputs and outputs, tokens, keys and audio are never logged.
Stdlib only, Python 3.9.
"""

from __future__ import annotations

import base64
from collections import OrderedDict, deque
from datetime import datetime, timezone
import hashlib
import hmac
import http.client
import json
import logging
import os
import queue
import re
import secrets
import shutil
import signal
import ssl
import stat
import struct
import subprocess
import sys
import tempfile
import threading
import time
from typing import Any, Callable, Deque, Dict, List, Optional, Tuple
from urllib.parse import parse_qs, quote, urlsplit
import uuid

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.append(_HERE)

try:  # speech to text (the audio turns); text turns work without it
    import samrabbit_transcribe as _transcribe  # type: ignore
except Exception:  # noqa: BLE001  # pragma: no cover
    _transcribe = None  # type: ignore[assignment]

try:  # the realtime brain (gpt-realtime on the ChatGPT subscription); without it only Claude answers
    import samrabbit_realtime as _realtime  # type: ignore
    import samrabbit_realtime_profile as _profile  # type: ignore
except Exception:  # noqa: BLE001  # pragma: no cover
    _realtime = None  # type: ignore[assignment]
    _profile = None  # type: ignore[assignment]

try:  # the Mac's own ChatGPT login
    import samrabbit_chatgpt as _chatgpt  # type: ignore
except Exception:  # noqa: BLE001  # pragma: no cover
    _chatgpt = None  # type: ignore[assignment]

_LOG = logging.getLogger("samrabbit-bridge.assistant")

TURN_ROUTE = "/v1/mobile/assistant/turn"
ANNOUNCEMENTS_ROUTE = "/v1/mobile/assistant/announcements"
END_ROUTE = "/v1/mobile/assistant/end"
SESSION_ROUTE = "/v1/mobile/assistant/session"
CANCEL_ROUTE = "/v1/mobile/assistant/cancel"
STREAM_TYPE = "application/x-samrabbit-stream"
PING_EVENT = b'{"type":"ping"}'
STREAM_FRAME_BYTES = 3200  # 100 ms of PCM16LE mono 16 kHz
BRAINS = ("auto", "realtime", "claude")
DEFAULT_BRAIN = "auto"
REALTIME_OPEN_WAIT = 20.0  # a turn waits this long for its session to open
MAX_SESSIONS_PER_DEVICE = 2  # live realtime sessions (each an OpenAI WebRTC call and a helper process) per device
MAX_SESSIONS = 4  # and on the Mac; the least recently used idle one closes to make room
STREAM_PING_SECONDS = 10.0  # a stream that wrote nothing for this long writes {"type": "ping"} (the watch's limit: 40 s)
REALTIME_TTS_FORMAT = "pcm_16000"
MAX_CACHED_AUDIO = 4  # turns whose audio a retry can replay (the rest replay without it)
HISTORY_TURNS = 8
MCP_SCRIPT = os.path.join(_HERE, "samrabbit_assistant_mcp.py")
MCP_SERVER = "samrabbit"
DEFAULT_DIR = "~/Library/Application Support/SamRabbit/assistant"
DEFAULT_SETTINGS_FILE = "~/.config/samrabbit/assistant.json"
DEFAULT_KEY_FILE = "~/.config/samrabbit/elevenlabs-key"
DEFAULT_MODEL = "claude-haiku-5-5"
MODEL_NAMES = {"claude-haiku-5-5": "Claude Haiku 5.5", "claude-sonnet-5-5": "Claude Sonnet 5.5"}
JARVIS_VOICE = "sI8FqE1zOcqXDhRwCwAx"
VOICE_NAMES = {JARVIS_VOICE: "Jarvis"}
TTS_URL = "https://api.elevenlabs.io"
TTS_MODEL = "eleven_flash_v2_5"
TTS_FORMAT = "mp3_44100_64"
TTS_SETTINGS = {"stability": 0.5, "similarity_boost": 0.75, "style": 0}
FALLBACK_CLAUDE = ("~/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "~/.claude/local/claude")
CLAUDE_PATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
CLAUDE_ENV_KEYS = ("HOME", "USER", "LOGNAME", "TMPDIR", "LANG")
CLAUDE_FLAGS_ENV = {"CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1", "CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1",
                    "DISABLE_AUTOUPDATER": "1"}
SESSION_HEADER = "X-SamRabbit-Assistant-Session"
STT_TIMEOUT_SECONDS = 45.0  # the transcriber's own limit (samrabbit_transcribe.HELPER_TIMEOUT_SECONDS)
AGENT_TIMEOUT_SECONDS = 25.0
TTS_TIMEOUT_SECONDS = 10.0
MAX_TURNS = 6
MAX_AUDIO_BYTES = 2 * 1024 * 1024
MAX_AUDIO_SECONDS = 60
MAX_BODY_BYTES = 64 * 1024
MAX_TEXT_CHARS = 4000
MAX_SAY_CHARS = 900
MAX_AGENT_OUTPUT = 24 * 1024 * 1024
MAX_STDERR = 64 * 1024
MAX_CONCURRENT_AGENTS = 3
TURN_WAIT_SECONDS = AGENT_TIMEOUT_SECONDS + STT_TIMEOUT_SECONDS + TTS_TIMEOUT_SECONDS + 10.0
TURN_CACHE_SECONDS = 15 * 60.0
TURN_CACHE_SIZE = 256
EXIT_GRACE_SECONDS = 5.0  # after the result event, how long the CLI may take to exit by itself
PREVIOUS_EXIT_WAIT = 3.0  # a conversation's next turn waits this long for the last CLI to have exited
IDLE_END_SECONDS = 5 * 60.0  # a conversation nobody spoke in for this long is recorded as ended
FORGET_SECONDS = 7 * 24 * 3600.0
MAX_CONVERSATIONS = 200
ANNOUNCE_SCAN_SECONDS = 5.0
ANNOUNCE_ACTIVE_SECONDS = 10 * 60.0  # the T3 watch runs while a conversation was active this recently
ANNOUNCE_KEEP_SECONDS = 60 * 60.0
ANNOUNCE_REFRESH_BUDGET = 2.0
MAX_NOTES = 5
SESSION_KEEP_SECONDS = 14 * 24 * 3600.0
TTS_CACHE_SIZE = 48
TTS_PAUSE_REJECTED = 10 * 60.0
TTS_PAUSE_BUSY = 30.0
MAX_TTS_BYTES = 4 * 1024 * 1024
_MODEL = re.compile(r"^claude-[a-z0-9][a-z0-9.\-]{1,60}$")
_REALTIME_MODEL = re.compile(r"^(?:gpt-realtime[a-z0-9.\-]{0,40}|gpt-live-1)$")
_VOICE = re.compile(r"^[A-Za-z0-9]{8,40}$")
_CONVERSATION_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{2,56}$")
_TURN_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,95}$")
_SESSION_ID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
_CONTROL = re.compile(r"[\x00-\x08\x0b-\x1f\x7f]")
SYNC_PREFIX = "watch-"
MAC_SYNC_PREFIX = "mac-"
INTERNAL_DEVICE_ID = "assistant"
# The desktop app's voice (the Agent Dock's mic, the shortcut, the wake phrase) is one device, "mac": the
# /v1/desktop/assistant/* routes (loopback + desktop token) turn with it.
MAC_DEVICE: Dict[str, Any] = {"deviceId": "mac", "name": "Mac", "platform": "macos"}


# --------------------------------------------------------------------------- errors


class AssistantError(Exception):
    """An answer of ``{"error": {code, message, retryable[, reason]}}``. ``cache``: the agent may already have acted,
    so a retry of the same turn gets this same answer instead of running it again."""

    def __init__(self, status: int, code: str, message: str, *, retryable: bool = False,
                 reason: Optional[str] = None, cache: bool = False) -> None:
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message
        self.retryable = retryable
        self.reason = reason
        self.cache = cache

    def payload(self) -> Dict[str, Any]:
        error: Dict[str, Any] = {"code": self.code, "message": self.message, "retryable": self.retryable}
        if self.reason:
            error["reason"] = self.reason
        return {"error": error}


_UNAVAILABLE = {
    "assistant_dev_copy": "This copy of the Mac bridge is not the installed one, so it runs the assistant only with an "
                          "explicit --claude.",
    "claude_missing": "Claude Code is not installed on the Mac.",
    "claude_signed_out": "Claude Code on the Mac is signed out. Run claude on the Mac and log in.",
    "claude_busy": "Claude is busy right now. Try again in a moment.",
    "claude_failed": "Claude Code failed on the Mac.",
    "model_unavailable": "The assistant's model is not available. Check assistant.model on the Mac.",
    "mcp_server_missing": "The assistant's tools are not installed next to the Mac bridge. Run install.sh again.",
    "assistant_dir_unusable": "The assistant's folder on the Mac could not be set up.",
    "assistant_starting": "The assistant is still starting on the Mac.",
    "too_many_turns": "The Mac is already answering several requests. Try again in a moment.",
    "chatgpt_not_connected": "ChatGPT is not connected on the Mac. Use SamRabbit > Connect ChatGPT…",
    "chatgpt_reconnect_required": "ChatGPT needs to be connected again on the Mac (SamRabbit > Connect ChatGPT…).",
    "chatgpt_dev_copy": "This copy of the Mac bridge is not the installed one, so it uses ChatGPT only with an "
                        "explicit --chatgpt-auth-file.",
    "chatgpt_rejected": "OpenAI refused the Mac's ChatGPT login just now.",
    "realtime_busy": "OpenAI is busy, or the ChatGPT plan's voice limit is reached. Try again in a moment.",
    "realtime_missing": "The realtime voice is not installed next to the Mac bridge. Run install.sh again.",
    "realtime_helper_missing": "The realtime voice helper is not installed. Run install.sh again.",
    "realtime_venv_missing": "The realtime voice needs its Python environment. Run install.sh again.",
    "realtime_venv_broken": "The realtime voice's Python environment is broken. Run install.sh again.",
    "realtime_python_too_old": "The realtime voice needs Python 3.12 or newer. Run install.sh again.",
    "realtime_unreachable": "OpenAI is not reachable from the Mac right now.",
    "realtime_failed": "The realtime voice failed on the Mac.",
    "realtime_checking": "The realtime voice is still starting on the Mac.",
}


def unavailable(reason: str, *, retryable: bool = False, cache: bool = False) -> AssistantError:
    return AssistantError(503, "assistant_unavailable", _UNAVAILABLE.get(reason, "The assistant is not available on "
                                                                                 "the Mac."),
                          retryable=retryable, reason=reason, cache=cache)


class _SessionMissing(Exception):
    """``--resume`` of a session the CLI does not have."""


class _SessionInUse(Exception):
    """``--session-id`` of a session that already exists."""


# --------------------------------------------------------------------------- spoken text


_ONES = ("zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
         "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen")
_TENS = ("", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety")
_ORDINAL_WORDS = {"one": "first", "two": "second", "three": "third", "five": "fifth", "eight": "eighth",
                  "nine": "ninth", "twelve": "twelfth"}


def number_words(value: int) -> str:
    """``42`` -> ``forty-two``, ``1250`` -> ``one thousand two hundred fifty`` (below a billion; digits otherwise)."""
    if value < 0:
        return "minus " + number_words(-value)
    if value < 20:
        return _ONES[value]
    if value < 100:
        tens, ones = divmod(value, 10)
        return _TENS[tens] + ("-" + _ONES[ones] if ones else "")
    if value < 1000:
        hundreds, rest = divmod(value, 100)
        return _ONES[hundreds] + " hundred" + (" " + number_words(rest) if rest else "")
    for size, name in ((1_000_000, "million"), (1000, "thousand")):
        if value >= size and value < size * 1000:
            head, rest = divmod(value, size)
            return number_words(head) + " " + name + (" " + number_words(rest) if rest else "")
    return str(value)


def year_words(value: int) -> str:
    """``2026`` -> ``twenty twenty-six``, ``2005`` -> ``two thousand five``, ``1999`` -> ``nineteen ninety-nine``."""
    century, rest = divmod(value, 100)
    if 2000 <= value <= 2009:
        return "two thousand" + (" " + _ONES[rest] if rest else "")
    if rest == 0:
        return number_words(century) + " hundred"
    return number_words(century) + " " + (number_words(rest) if rest >= 10 else "oh " + _ONES[rest])


def ordinal_words(value: int) -> str:
    words = number_words(value)
    head, _, last = words.rpartition(" ")
    first, dash, tail = last.rpartition("-")
    word = tail
    if word in _ORDINAL_WORDS:
        word = _ORDINAL_WORDS[word]
    elif word.endswith("y"):
        word = word[:-1] + "ieth"
    else:
        word += "th"
    last = first + dash + word
    return (head + " " + last) if head else last


def _time_words(hour: int, minute: int, meridiem: Optional[str]) -> str:
    spoken_hour = number_words(hour)
    if minute == 0:
        middle = "" if meridiem else " o'clock"
    elif minute < 10:
        middle = " oh " + _ONES[minute]
    else:
        middle = " " + number_words(minute)
    return spoken_hour + middle + (" " + meridiem.upper().replace(".", "") if meridiem else "")


_TIME = re.compile(r"\b([01]?\d|2[0-3]):([0-5]\d)(?:\s*([AaPp])\.?\s*[Mm]\b\.?)?")
_HOUR = re.compile(r"\b(1[0-2]|0?[1-9])\s*([AaPp])\.?\s*[Mm]\b\.?")
_MONEY = re.compile(r"\$(\d{1,3}(?:,\d{3})+|\d{1,7})(?:\.(\d{2}))?\b")
_PERCENT = re.compile(r"\b(\d{1,3}(?:\.\d{1,2})?)\s?%")
_ORDINAL = re.compile(r"\b(\d{1,4})(st|nd|rd|th)\b", re.IGNORECASE)
_YEAR = re.compile(r"\b(19\d\d|20\d\d)\b")
_DECIMAL = re.compile(r"\b(\d{1,7})\.(\d{1,3})\b")
_GROUPED = re.compile(r"\b\d{1,3}(?:,\d{3})+\b")
_INTEGER = re.compile(r"\b\d{1,9}\b")


def speakable(text: str) -> str:
    """Numbers written out in words where it is obvious how they are said (times, prices, percentages, ordinals,
    years, plain numbers), so a voice model that reads digits literally says them naturally."""
    value = text

    def clock(match: "re.Match[str]") -> str:
        hour, minute, meridiem = int(match.group(1)), int(match.group(2)), match.group(3)
        if meridiem:
            return _time_words(hour % 12 or 12, minute, meridiem + "M")
        if hour == 0:
            return _time_words(12, minute, "AM")
        if hour > 12:
            return _time_words(hour - 12, minute, "PM")
        return _time_words(hour, minute, None)

    value = _TIME.sub(clock, value)
    value = _HOUR.sub(lambda m: number_words(int(m.group(1))) + " " + (m.group(2) + "M").upper(), value)

    def money(match: "re.Match[str]") -> str:
        dollars = int(match.group(1).replace(",", ""))
        words = number_words(dollars) + (" dollar" if dollars == 1 else " dollars")
        cents = int(match.group(2)) if match.group(2) else 0
        return words + (" and " + number_words(cents) + (" cent" if cents == 1 else " cents") if cents else "")

    value = _MONEY.sub(money, value)
    value = _PERCENT.sub(lambda m: _decimal_words(m.group(1)) + " percent", value)
    value = _ORDINAL.sub(lambda m: ordinal_words(int(m.group(1))), value)
    value = _YEAR.sub(lambda m: year_words(int(m.group(1))), value)
    value = _DECIMAL.sub(lambda m: _decimal_words(m.group(0)), value)
    value = _GROUPED.sub(lambda m: number_words(int(m.group(0).replace(",", ""))), value)
    value = _INTEGER.sub(lambda m: number_words(int(m.group(0))), value)
    return value


def _decimal_words(text: str) -> str:
    whole, _, fraction = text.partition(".")
    words = number_words(int(whole))
    return words + (" point " + " ".join(_ONES[int(digit)] for digit in fraction) if fraction else "")


_FENCE = re.compile(r"```.*?```", re.S)
_LINK = re.compile(r"\[([^\]]{1,200})\]\((?:[^)\s]{1,2000})\)")
_URL = re.compile(r"https?://\S+")
_EMPHASIS = re.compile(r"(\*\*|__|\*|`|~~)")
_BULLET = re.compile(r"^\s*(?:[-*•]|\d{1,2}[.)])\s+", re.M)
_HEADING = re.compile(r"^\s*#{1,6}\s*", re.M)


def spoken(text: str) -> str:
    """The model's answer as something to say: no Markdown, lists or links, one paragraph, at most a few sentences."""
    value = _FENCE.sub(" ", str(text or ""))
    value = _LINK.sub(r"\1", value)
    value = _URL.sub("the link", value)
    value = _HEADING.sub("", value)
    lines = [line.strip() for line in _BULLET.sub("", value).splitlines() if line.strip()]
    joined = ""
    for line in lines:
        if joined and not joined.endswith((".", "!", "?", ":", ",", ";")):
            joined += "."
        joined = (joined + " " + line).strip()
    value = _EMPHASIS.sub("", joined)
    value = " ".join(_CONTROL.sub(" ", value).split())
    if len(value) > MAX_SAY_CHARS:
        cut = value[:MAX_SAY_CHARS]
        end = max(cut.rfind(". "), cut.rfind("? "), cut.rfind("! "))
        value = cut[:end + 1] if end > 80 else cut.rstrip() + "…"
    return value


# Only hesitation sounds are noise. Short confirmations ("okay", "ok", "yes", "yeah", "yep", "sure", "mhm", "uh huh")
# are answers: they confirm an approval the assistant just asked about.
_FILLERS = frozenset({"uh", "uhh", "uhm", "um", "umm", "er", "err", "erm", "hmm", "hmmm", "hm", "mm", "mmm"})
_WORDS = re.compile(r"[a-z0-9']+")
_CLOSER = re.compile(
    r"^(?:(?:ok(?:ay)?|alright|all right|cool|great|perfect|got it|no|nope|nah|that's great|sounds good|samrabbit|"
    r"jarvis|hey)[\s,.!]*)*"
    r"(?:(?:thanks|thank you|thanks a lot|thank you so much|cheers)(?: (?:samrabbit|jarvis))?[\s,.!]*)?"
    r"(?:that'?s all|that'?s it|that is all|that'?ll be all|that will be all|i'?m good|i'?m done|i'?m all set|"
    r"nothing else|no thanks|no thank you|bye(?:[- ]bye)?|goodbye|good night|see you(?: later)?|see ya|later|"
    r"talk (?:to you )?later|stop(?: listening)?|never ?mind|cancel|go to sleep|be quiet|end(?: the)? conversation|"
    r"thanks|thank you)"
    r"(?:[\s,.!]+(?:thanks|thank you|bye|goodbye|for now|samrabbit|jarvis|then))*[\s,.!]*$")


def is_noise(text: str) -> bool:
    """Nothing heard, or only hesitation sounds ("uh", "um", "er", "hmm"): keep listening without a brain."""
    words = _WORDS.findall(str(text or "").lower())
    return not words or all(word in _FILLERS for word in words)


def is_closer(text: str) -> bool:
    """The whole utterance is a goodbye ("bye", "stop", "thanks, that's all", "never mind")."""
    value = " ".join(str(text or "").lower().replace("’", "'").split())
    return bool(value) and len(value) <= 80 and bool(_CLOSER.match(value))


def goodbye(text: str) -> str:
    lowered = str(text or "").lower()
    return "You're welcome. Talk soon." if "thank" in lowered else "Okay, talk soon."


def expects_reply(say: str) -> bool:
    return say.rstrip().rstrip("\"'”’)").endswith("?")


# --------------------------------------------------------------------------- settings


class Settings:
    """``assistant.model`` and ``assistant.voice``: an explicit value (flag or environment) wins, then
    ``~/.config/samrabbit/assistant.json`` (``{"model", "voice"}`` or ``{"assistant": {...}}``), then the
    defaults. The file is read again when it changes."""

    def __init__(self, path: Optional[str] = DEFAULT_SETTINGS_FILE, *, model: Optional[str] = None,
                 voice: Optional[str] = None, brain: Optional[str] = None) -> None:
        self.path = os.path.expanduser(path) if path else None
        self._model = model
        self._voice = voice
        self._brain = brain
        self._lock = threading.Lock()
        self._stamp: Optional[Tuple[int, int]] = None
        self._value: Dict[str, Any] = {}

    def _file(self) -> Dict[str, Any]:
        if not self.path:
            return {}
        try:
            info = os.stat(self.path)
        except OSError:
            return {}
        stamp = (info.st_mtime_ns, info.st_size)
        with self._lock:
            if stamp == self._stamp:
                return self._value
        try:
            with open(self.path, "r", encoding="utf-8") as handle:
                raw = json.load(handle)
        except (OSError, ValueError):
            raw = {}
        value = raw.get("assistant") if isinstance(raw, dict) and isinstance(raw.get("assistant"), dict) else raw
        value = value if isinstance(value, dict) else {}
        with self._lock:
            self._stamp, self._value = stamp, value
        return value

    def model(self) -> str:
        for candidate in (self._model, os.environ.get("SAMRABBIT_ASSISTANT_MODEL"), self._file().get("model")):
            if isinstance(candidate, str) and _MODEL.match(candidate.strip()):
                return candidate.strip()
        return DEFAULT_MODEL

    def voice(self) -> str:
        for candidate in (self._voice, os.environ.get("SAMRABBIT_ASSISTANT_VOICE"), self._file().get("voice")):
            if isinstance(candidate, str) and _VOICE.match(candidate.strip()):
                return candidate.strip()
        return JARVIS_VOICE

    def brain(self) -> str:
        """``auto`` (realtime when it can, else Claude), ``realtime`` or ``claude``."""
        for candidate in (self._brain, os.environ.get("SAMRABBIT_ASSISTANT_BRAIN"), self._file().get("brain")):
            if isinstance(candidate, str) and candidate.strip().lower() in BRAINS:
                return candidate.strip().lower()
        return DEFAULT_BRAIN

    def realtime_model(self) -> str:
        value = self._file().get("realtimeModel")
        if isinstance(value, str) and _REALTIME_MODEL.match(value.strip()):
            return value.strip()
        return _profile.DEFAULT_MODEL if _profile is not None else "gpt-realtime-2.1"

    def realtime_voice(self) -> str:
        value = self._file().get("realtimeVoice")
        if isinstance(value, str) and re.match(r"^[a-z]{2,20}$", value.strip()):
            return value.strip()
        return _profile.DEFAULT_VOICE if _profile is not None else "marin"


def model_name(model: str) -> str:
    return MODEL_NAMES.get(model, model)


def voice_name(voice: str) -> str:
    return VOICE_NAMES.get(voice, "voice " + voice[:6])


# --------------------------------------------------------------------------- the voice (ElevenLabs)


class ElevenLabsVoice:
    """ElevenLabs text to speech: ``POST {base}/v1/text-to-speech/{voice}?output_format=mp3_44100_64`` with Flash
    v2.5. Any failure is ``None`` (the watch speaks the text itself). The key is read from its 0600 file only when it
    is used and is never logged; after a rejected key the voice pauses for 10 minutes. ``off`` is why there is no
    voice at all (a dev copy without an explicit key file)."""

    def __init__(self, key_file: Optional[str], *, voice: Callable[[], str], base_url: str = TTS_URL,
                 timeout: float = TTS_TIMEOUT_SECONDS, off: Optional[str] = None,
                 monotonic: Callable[[], float] = time.monotonic) -> None:
        self.key_file = os.path.expanduser(key_file) if key_file else None
        self._voice = voice
        self.base_url = base_url.rstrip("/")
        self.timeout = float(timeout)
        self.off = off if off else (None if self.key_file else "no_key")
        self._monotonic = monotonic
        self._lock = threading.Lock()
        self._paused: Optional[Tuple[float, float, str]] = None  # (since, seconds, reason)
        self._cache: "OrderedDict[Tuple[str, str], bytes]" = OrderedDict()
        self.last_error: Optional[str] = None
        self.requests = 0  # tests

    def _key(self) -> Optional[str]:
        if not self.key_file:
            return None
        try:
            info = os.stat(self.key_file)
            if info.st_mode & (stat.S_IRWXG | stat.S_IRWXO):
                os.chmod(self.key_file, 0o600)
                _LOG.warning("voice key file permissions tightened to 0600")
            with open(self.key_file, "r", encoding="utf-8") as handle:
                value = handle.read(4096).strip()
        except (OSError, UnicodeDecodeError):
            return None
        if not 16 <= len(value) <= 256 or any(ord(char) <= 0x20 or ord(char) >= 0x7F for char in value):
            return None
        return value

    def _pause_reason(self) -> Optional[str]:
        with self._lock:
            paused = self._paused
            if paused is not None and self._monotonic() - paused[0] >= paused[1]:
                self._paused = paused = None
        return paused[2] if paused else None

    def status(self) -> Dict[str, Any]:
        voice = self._voice()
        value: Dict[str, Any] = {"available": False, "voice": voice, "voiceName": voice_name(voice), "model": TTS_MODEL}
        reason = self.off or self._pause_reason() or (None if self._key() else "no_key")
        if reason:
            value["reason"] = reason
        else:
            value["available"] = True
        return value

    def speak(self, text: str) -> Optional[bytes]:
        """MP3 bytes for ``text`` (numbers already in words), or None."""
        text = " ".join(str(text or "").split())
        if not text or self.off or self._pause_reason():
            return None
        voice = self._voice()
        cache_key = (voice, text)
        with self._lock:
            if cache_key in self._cache:
                self._cache.move_to_end(cache_key)
                return self._cache[cache_key]
        key = self._key()
        if key is None:
            return None
        data = self._request(voice, text, key)
        if data is not None and len(text) <= 240:
            with self._lock:
                self._cache[cache_key] = data
                while len(self._cache) > TTS_CACHE_SIZE:
                    self._cache.popitem(last=False)
        return data

    def _request(self, voice: str, text: str, key: str) -> Optional[bytes]:
        parts = urlsplit(self.base_url)
        host = parts.hostname or ""
        if parts.scheme == "https":
            connection: http.client.HTTPConnection = http.client.HTTPSConnection(
                host, parts.port or 443, timeout=self.timeout, context=ssl.create_default_context())
        elif parts.scheme == "http" and host in ("127.0.0.1", "localhost", "::1"):
            connection = http.client.HTTPConnection(host, parts.port or 80, timeout=self.timeout)  # a fake, in tests
        else:
            self.last_error = "bad_url"
            return None
        path = f"/v1/text-to-speech/{quote(voice, safe='')}?output_format={TTS_FORMAT}"
        body = json.dumps({"text": text, "model_id": TTS_MODEL, "voice_settings": TTS_SETTINGS}).encode("utf-8")
        started = time.monotonic()
        self.requests += 1
        try:
            connection.request("POST", path, body=body, headers={
                "xi-api-key": key, "Content-Type": "application/json", "Accept": "audio/mpeg"})
            response = connection.getresponse()
            status = response.status
            kind = response.getheader("Content-Type", "") or ""
            data = response.read(MAX_TTS_BYTES + 1)
        except (OSError, http.client.HTTPException, ssl.SSLError):
            self.last_error = "timeout" if time.monotonic() - started >= self.timeout - 0.05 else "unreachable"
            _LOG.warning("voice synthesis failed (%s)", self.last_error)
            return None
        finally:
            connection.close()
        if status != 200 or not kind.lower().startswith("audio/") or not data or len(data) > MAX_TTS_BYTES:
            self.last_error = f"http_{status}"
            if status in (401, 403):
                self._pause(TTS_PAUSE_REJECTED, "key_rejected")
            elif status in (402, 429):
                self._pause(TTS_PAUSE_BUSY if status == 429 else TTS_PAUSE_REJECTED,
                            "voice_busy" if status == 429 else "voice_quota")
            _LOG.warning("voice synthesis failed (HTTP %d)", status)
            return None
        self.last_error = None
        return data

    def _pause(self, seconds: float, reason: str) -> None:
        with self._lock:
            self._paused = (self._monotonic(), seconds, reason)

    def stream_pcm(self, text: str, write: Callable[[bytes], None],
                   cancelled: Callable[[], bool] = lambda: False) -> bool:
        """``text`` as PCM16LE 16 kHz mono (``/stream?output_format=pcm_16000``), handed to ``write`` as it arrives
        (the streaming turn's ``A`` frames). True when any audio was written; any failure stops quietly."""
        text = " ".join(str(text or "").split())
        if not text or self.off or self._pause_reason():
            return False
        voice = self._voice()
        cache_key = (voice, text, REALTIME_TTS_FORMAT)
        with self._lock:
            cached = self._cache.get(cache_key)  # type: ignore[call-overload]
            if cached is not None:
                self._cache.move_to_end(cache_key)  # type: ignore[arg-type]
        if cached is not None:
            for offset in range(0, len(cached), STREAM_FRAME_BYTES):
                if cancelled():
                    break
                write(cached[offset:offset + STREAM_FRAME_BYTES])
            return True
        key = self._key()
        if key is None:
            return False
        parts = urlsplit(self.base_url)
        host = parts.hostname or ""
        if parts.scheme == "https":
            connection: http.client.HTTPConnection = http.client.HTTPSConnection(
                host, parts.port or 443, timeout=self.timeout, context=ssl.create_default_context())
        elif parts.scheme == "http" and host in ("127.0.0.1", "localhost", "::1"):
            connection = http.client.HTTPConnection(host, parts.port or 80, timeout=self.timeout)
        else:
            self.last_error = "bad_url"
            return False
        path = f"/v1/text-to-speech/{quote(voice, safe='')}/stream?output_format={REALTIME_TTS_FORMAT}"
        body = json.dumps({"text": text, "model_id": TTS_MODEL, "voice_settings": TTS_SETTINGS}).encode("utf-8")
        self.requests += 1
        kept = bytearray()
        wrote = False
        started = time.monotonic()
        try:
            connection.request("POST", path, body=body, headers={
                "xi-api-key": key, "Content-Type": "application/json", "Accept": "*/*"})
            response = connection.getresponse()
            if response.status != 200:
                status = response.status
                response.read(64 * 1024)
                self.last_error = f"http_{status}"
                if status in (401, 403):
                    self._pause(TTS_PAUSE_REJECTED, "key_rejected")
                elif status in (402, 429):
                    self._pause(TTS_PAUSE_BUSY if status == 429 else TTS_PAUSE_REJECTED,
                                "voice_busy" if status == 429 else "voice_quota")
                _LOG.warning("voice synthesis failed (HTTP %d)", status)
                return False
            remainder = b""
            total = 0
            while not cancelled():
                chunk = response.read(STREAM_FRAME_BYTES)
                if not chunk:
                    break
                total += len(chunk)
                if total > MAX_TTS_BYTES * 4:
                    break
                data = remainder + chunk
                cut = len(data) - len(data) % 2
                data, remainder = data[:cut], data[cut:]
                if data:
                    write(data)
                    wrote = True
                    if len(kept) <= 1024 * 1024:
                        kept += data
        except (OSError, http.client.HTTPException, ssl.SSLError):
            self.last_error = "timeout" if time.monotonic() - started >= self.timeout - 0.05 else "unreachable"
            _LOG.warning("voice synthesis failed (%s)", self.last_error)
            return wrote
        finally:
            connection.close()
        self.last_error = None
        if wrote and not cancelled() and len(text) <= 240 and len(kept) <= 1024 * 1024:
            with self._lock:
                self._cache[cache_key] = bytes(kept)  # type: ignore[index]
                while len(self._cache) > TTS_CACHE_SIZE:
                    self._cache.popitem(last=False)
        return wrote


# --------------------------------------------------------------------------- the agent (claude -p)


_PROMPT = """You are SamRabbit, Samin's voice assistant on his {device}, the same assistant as on his {others}. Everything you write is spoken aloud by a voice, then the {listener} listens for his answer.

How you talk:
- {length} Lead with the answer. No markdown, lists, headings, emoji, links or code.
- Say numbers, times and dates the way a person says them ("two thirty", "in about ten minutes", "Friday the ninth").
- Never read out ids, request ids or URLs.
- If you ask him something, end with a question mark. Don't add "anything else?" style questions.

Being honest:
- Use the tools to look things up and to act. Never guess about his tasks, calendar, journal or Mac.
- If a tool fails or says something is unavailable, say so plainly in a few words.
- Never say something is "still running", "working on it" or "in progress" unless a tool result says so. Never say you did something unless a tool result confirms it.

His T3 Code tasks:
- get_status for "what needs me" or "what's going on"; list_tasks and read_task for details.
- start_task for new work. Afterwards say which project it went to, from the tool result.
- Before you approve, deny, stop, cancel or delete anything, ask first ("Should I approve it?") and act only after a clear yes in his next message. Then use respond_task or stop_task.

Calendar:
- For "the next N minutes", "in the next hour" or "this afternoon", call calendar_agenda with that window (withinMinutes or hours).
- calendar_block blocks time starting now; calendar_create adds an event at a time he gives.

Journal:
- Only call journal_add when he explicitly asks to add something to his journal, with his own words, verbatim. Never write a summary or your own wording into his journal.

Mac and visuals:
- mac_open opens an app or a website; mac_look shows you the screen.
- For a chart, graph or other visual, use generate_ui and say it will appear {visuals}.
{addendum}
Each message starts with a line like [Now: Thursday, October 8, 2026, 2:37 PM America/New_York · device: {tag}]: that is his local time. Lines starting with [Announced to him ...] are what you just told him about his tasks, so "approve it" or "what does it need?" refers to them.
"""

# The watch (and the iPhone's Siri path).
SYSTEM_PROMPT = _PROMPT.format(device="Apple Watch", others="Rabbit R1", listener="watch",
                               length="One or two short sentences.", visuals="on his phone and Mac", addendum="",
                               tag="watch")
# The desktop app (the Agent Dock's voice): the same rules, a little more room, and what he does at his Mac.
MAC_SYSTEM_PROMPT = _PROMPT.format(
    device="Mac", others="Rabbit R1 and his Apple Watch", listener="Mac", length="One to three short sentences.",
    visuals="in the SamRabbit desktop app and on his phone", tag="mac", addendum="""
At his Mac:
- He is usually managing his T3 Code tasks from the SamRabbit Agent Dock: what needs him, approving, answering, replying to, starting and stopping them. Name a task by its title and say what it needs.
- The Mac tools act on this Mac: mac_open, mac_look.
""")


class AgentRun:
    """What one ``claude -p`` turn did: its spoken answer, its tool calls (with their results) and session facts."""

    def __init__(self) -> None:
        self.text = ""
        self.last_text = ""
        self.session_started = False
        self.mcp_status: Optional[str] = None
        self.tools: "OrderedDict[str, Dict[str, Any]]" = OrderedDict()
        self.result: Optional[Dict[str, Any]] = None
        self.max_turns = False
        self.num_turns = 0
        self.duration_ms = 0


def _kill_group(process: "subprocess.Popen[bytes]") -> None:
    """SIGKILL to the CLI's whole process group (its MCP server too); only while it is not reaped, so its group id
    cannot belong to anything else yet."""
    if process.returncode is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except OSError:
        try:
            process.kill()
        except OSError:
            pass


def _finish(process: "subprocess.Popen[bytes]", grace: float) -> None:
    """Let the CLI exit by itself for ``grace`` seconds, then kill its group; always reaped."""
    try:
        process.wait(timeout=grace)
    except subprocess.TimeoutExpired:
        _kill_group(process)
        try:
            process.wait(timeout=5.0)
        except subprocess.TimeoutExpired:  # pragma: no cover - a process that survives SIGKILL
            pass
    for stream in (process.stdout, process.stderr):
        try:
            if stream is not None:
                stream.close()
        except OSError:
            pass


def _session_problem(result: Optional[Dict[str, Any]]) -> Optional[str]:
    """``missing`` (``--resume`` of a session the CLI does not have) or ``in_use`` (``--session-id`` of one it
    has), from a failed result event's ``errors`` / ``result``."""
    if not isinstance(result, dict) or result.get("is_error") is not True:
        return None
    texts = [str(result.get("result") or "")]
    texts += [str(item) for item in result.get("errors") or [] if isinstance(item, (str, int, float))]
    joined = " ".join(texts).lower()
    if "no conversation found" in joined:
        return "missing"
    if "already in use" in joined:
        return "in_use"
    return None


def _tool_name(name: Any) -> str:
    text = str(name or "")
    prefix = f"mcp__{MCP_SERVER}__"
    return text[len(prefix):] if text.startswith(prefix) else text


def _tool_result(content: Any) -> Tuple[str, List[Tuple[str, bytes]]]:
    """The text and the images of a ``tool_result`` block (Claude's shape: a string or a list of blocks)."""
    if isinstance(content, str):
        return content, []
    texts: List[str] = []
    images: List[Tuple[str, bytes]] = []
    for block in content if isinstance(content, list) else []:
        if not isinstance(block, dict):
            continue
        if block.get("type") == "text" and isinstance(block.get("text"), str):
            texts.append(block["text"])
        elif block.get("type") == "image":
            source = block.get("source") if isinstance(block.get("source"), dict) else {}
            data = source.get("data") if isinstance(source.get("data"), str) else block.get("data")
            mime = source.get("media_type") or block.get("mimeType") or "image/jpeg"
            if isinstance(data, str):
                try:
                    images.append((str(mime), base64.b64decode(data, validate=False)))
                except (ValueError, TypeError):
                    pass
    return "\n".join(texts), images


class ClaudeAgent:
    """The headless Claude Code CLI with the isolation flags and environment in the module docstring."""

    def __init__(self, executable: Optional[str], *, search: bool, settings: Settings,
                 max_turns: int = MAX_TURNS) -> None:
        self._explicit = executable
        self._search = search  # the installed copy looks for claude itself; a dev copy uses only an explicit one
        self.settings = settings
        self.max_turns = max_turns
        self.workdir: Optional[str] = None
        self._lock = threading.Lock()
        self._running: List["subprocess.Popen[bytes]"] = []

    def configure(self, workdir: str) -> None:
        self.workdir = workdir

    @property
    def cwd(self) -> str:
        return os.path.join(str(self.workdir), "cwd")

    @property
    def mcp_config(self) -> str:
        return os.path.join(str(self.workdir), "mcp.json")

    @property
    def system_prompt_file(self) -> str:
        return os.path.join(str(self.workdir), "system-prompt.md")

    @property
    def mac_prompt_file(self) -> str:
        return os.path.join(str(self.workdir), "system-prompt-mac.md")

    def prompt_file_for(self, platform: str) -> str:
        """The desktop app's conversations get the Mac's prompt; the watch and the phone the watch's."""
        return self.mac_prompt_file if platform == "macos" else self.system_prompt_file

    def executable(self) -> Optional[str]:
        candidates: List[str] = []
        if self._explicit:
            candidates.append(os.path.expanduser(self._explicit))
        elif self._search:
            found = shutil.which("claude")
            if found:
                candidates.append(found)
            candidates += [os.path.expanduser(path) for path in FALLBACK_CLAUDE]
        for path in candidates:
            if os.path.isfile(path) and os.access(path, os.X_OK):
                return path
        return None

    def off_reason(self) -> Optional[str]:
        if not self._explicit and not self._search:
            return "assistant_dev_copy"
        if self.executable() is None:
            return "claude_missing"
        return None

    def arguments(self, executable: str, session_id: str, *, resume: bool,
                  prompt_file: Optional[str] = None) -> List[str]:
        args = [executable, "-p", "--model", self.settings.model(), "--output-format", "stream-json", "--verbose",
                "--setting-sources", "", "--strict-mcp-config", "--mcp-config", self.mcp_config,
                "--tools", "", "--allowedTools", "mcp__" + MCP_SERVER, "--permission-mode", "dontAsk",
                "--disable-slash-commands", "--max-turns", str(self.max_turns),
                "--system-prompt-file", prompt_file or self.system_prompt_file]
        return args + (["--resume", session_id] if resume else ["--session-id", session_id])

    @staticmethod
    def environment() -> Dict[str, str]:
        env = {key: os.environ[key] for key in CLAUDE_ENV_KEYS if os.environ.get(key)}
        env.setdefault("HOME", os.path.expanduser("~"))
        env["PATH"] = CLAUDE_PATH
        env.update(CLAUDE_FLAGS_ENV)
        return env

    def stop_all(self) -> None:
        with self._lock:
            running = list(self._running)
        for process in running:
            _kill_group(process)

    def run(self, message: str, session_id: str, *, resume: bool, timeout: float,
            progress: Dict[str, Any], prompt_file: Optional[str] = None) -> AgentRun:
        """One turn. ``progress["started"]`` becomes True once the CLI has the session (its init event), even when
        the turn then fails, so the next turn resumes it. ``progress["process"]`` is the CLI (still exiting)."""
        executable = self.executable()
        if executable is None:
            raise unavailable(self.off_reason() or "claude_missing")
        try:
            process = subprocess.Popen(self.arguments(executable, session_id, resume=resume, prompt_file=prompt_file),
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                       cwd=self.cwd, env=self.environment(), start_new_session=True)
        except OSError:
            raise unavailable("claude_failed", retryable=True) from None
        progress["process"] = process
        with self._lock:
            self._running.append(process)
        lines: "queue.Queue[Optional[bytes]]" = queue.Queue()
        stderr = bytearray()

        def read_out() -> None:
            try:
                for raw in iter(process.stdout.readline, b""):  # type: ignore[union-attr]
                    lines.put(raw)
            except (OSError, ValueError):
                pass
            lines.put(None)

        def read_err() -> None:
            try:
                while True:
                    chunk = process.stderr.read(4096)  # type: ignore[union-attr]
                    if not chunk:
                        break
                    if len(stderr) < MAX_STDERR:
                        stderr.extend(chunk[:MAX_STDERR - len(stderr)])
            except (OSError, ValueError):
                pass

        readers = [threading.Thread(target=read_out, name="samrabbit-assistant-out", daemon=True),
                   threading.Thread(target=read_err, name="samrabbit-assistant-err", daemon=True)]
        for reader in readers:
            reader.start()
        try:
            process.stdin.write(message.encode("utf-8"))  # type: ignore[union-attr]
            process.stdin.close()  # type: ignore[union-attr]
        except OSError:
            pass
        run = AgentRun()
        deadline = time.monotonic() + max(0.5, timeout)
        total = 0
        try:
            while True:
                left = deadline - time.monotonic()
                if left <= 0:
                    raise TimeoutError
                try:
                    raw = lines.get(timeout=left)
                except queue.Empty:
                    raise TimeoutError from None
                if raw is None:
                    break
                total += len(raw)
                if total > MAX_AGENT_OUTPUT:
                    _kill_group(process)
                    raise unavailable("claude_failed", retryable=True, cache=True)
                try:
                    event = json.loads(raw.decode("utf-8"))
                except (UnicodeDecodeError, ValueError):
                    continue
                if isinstance(event, dict) and self._event(run, event, progress):
                    break
        except TimeoutError:
            _kill_group(process)
            _finish(process, 0.0)
            self._forget(process)
            raise AssistantError(504, "assistant_timeout", "Answering took too long on the Mac.", retryable=True,
                                 cache=True) from None
        except BaseException:
            _kill_group(process)
            _finish(process, 0.0)
            self._forget(process)
            raise
        if run.result is None:
            _finish(process, 2.0)
            readers[1].join(timeout=1.0)
            self._forget(process)
            detail = bytes(stderr).decode("utf-8", errors="replace").lower()
            if "no conversation found" in detail:
                raise _SessionMissing()
            if "already in use" in detail:
                raise _SessionInUse()
            if "not logged in" in detail or "/login" in detail:
                raise unavailable("claude_signed_out", cache=bool(progress.get("started")))
            raise unavailable("claude_failed", retryable=True, cache=bool(run.tools))
        problem = _session_problem(run.result)
        if problem is not None:
            # The real CLI reports a lost or taken session as a result event ({"subtype": "error_during_execution",
            # "errors": ["No conversation found with session ID: ..."]}) on stdout as well as on stderr.
            _finish(process, 2.0)
            self._forget(process)
            raise _SessionMissing() if problem == "missing" else _SessionInUse()
        # The answer is here: the CLI exits by itself (about half a second); a reaper makes sure it does.
        threading.Thread(target=self._reap, args=(process,), name="samrabbit-assistant-reap", daemon=True).start()
        return self._interpret(run)

    def _reap(self, process: "subprocess.Popen[bytes]") -> None:
        _finish(process, EXIT_GRACE_SECONDS)
        self._forget(process)

    def _forget(self, process: "subprocess.Popen[bytes]") -> None:
        with self._lock:
            if process in self._running:
                self._running.remove(process)

    @staticmethod
    def _event(run: AgentRun, event: Dict[str, Any], progress: Dict[str, Any]) -> bool:
        kind = event.get("type")
        if kind == "system" and event.get("subtype") == "init":
            run.session_started = True
            progress["started"] = True
            for server in event.get("mcp_servers") or []:
                if isinstance(server, dict) and server.get("name") == MCP_SERVER:
                    run.mcp_status = str(server.get("status") or "")
        elif kind in ("assistant", "user"):
            message = event.get("message") if isinstance(event.get("message"), dict) else {}
            content = message.get("content")
            blocks = content if isinstance(content, list) else []
            texts = []
            for block in blocks:
                if not isinstance(block, dict):
                    continue
                if kind == "assistant" and block.get("type") == "tool_use" and isinstance(block.get("id"), str):
                    run.tools[block["id"]] = {"id": block["id"], "name": _tool_name(block.get("name")),
                                              "input": block.get("input") if isinstance(block.get("input"), dict)
                                              else {}, "result": None, "isError": False, "images": []}
                elif kind == "assistant" and block.get("type") == "text" and isinstance(block.get("text"), str):
                    texts.append(block["text"])
                elif kind == "user" and block.get("type") == "tool_result":
                    tool = run.tools.get(str(block.get("tool_use_id") or ""))
                    if tool is not None:
                        tool["result"], tool["images"] = _tool_result(block.get("content"))
                        tool["isError"] = block.get("is_error") is True
            if texts:
                run.last_text = "\n".join(texts)
        elif kind == "result":
            run.result = event
            return True
        return False

    @staticmethod
    def _interpret(run: AgentRun) -> AgentRun:
        result = run.result or {}
        run.num_turns = int(result.get("num_turns") or 0) if isinstance(result.get("num_turns"), int) else 0
        run.duration_ms = int(result.get("duration_ms") or 0) if isinstance(result.get("duration_ms"), int) else 0
        subtype = result.get("subtype")
        if subtype == "error_max_turns":
            run.max_turns = True
            run.text = ""
            return run
        if result.get("is_error") is True or subtype not in (None, "success"):
            status = result.get("api_error_status")
            text = str(result.get("result") or "").lower()
            acted = bool(run.tools)
            if status in (429, 529) or (isinstance(status, int) and not isinstance(status, bool) and status >= 500):
                raise unavailable("claude_busy", retryable=True, cache=acted)
            if status == 401 or "login" in text or "authenticat" in text:
                raise unavailable("claude_signed_out", cache=acted)
            if status == 404:
                raise unavailable("model_unavailable", cache=acted)
            raise unavailable("claude_failed", retryable=True, cache=acted)
        run.text = str(result.get("result") or "") or run.last_text
        return run


# --------------------------------------------------------------------------- T3 announcements


class _Announcement:
    def __init__(self, number: int, at: float, kind: str, item: Dict[str, Any]) -> None:
        self.id = number
        self.at = at
        self.kind = kind
        self.thread_id = str(item.get("threadId") or "")
        self.title = str(item.get("title") or "A task")
        self.project = str(item.get("projectName") or "")
        self.status = str(item.get("status") or "")
        pending = item.get("pending") if isinstance(item.get("pending"), dict) else {}
        self.say = announcement_text(kind, self.title, self.project, self.status, pending)


def announcement_text(kind: str, title: str, project: str, status: str, pending: Dict[str, Any]) -> str:
    name = " ".join(title.split())
    if len(name) > 70:
        name = name[:69].rstrip() + "…"
    where = f"“{name}”" + (f" in {project}" if project else "")
    if kind == "needs_you":
        if status == "needs_input" or pending.get("kind") == "question":
            return f"{where} has a question for you."
        return f"{where} needs your approval."
    if kind == "error":
        return f"{where} ran into a problem."
    return f"{where} is done."


class T3Announcer:
    """Watches the T3 snapshot for tasks that start needing Samin, finish or fail, as numbered events (the last hour).
    The first look is the baseline: nothing that was already so is announced."""

    def __init__(self, hub: Callable[[], Any], *, clock: Callable[[], float] = time.time,
                 monotonic: Callable[[], float] = time.monotonic) -> None:
        self._hub = hub
        self._clock = clock
        self._monotonic = monotonic
        self._lock = threading.Lock()
        self._scan_lock = threading.Lock()
        self._known: Optional[Dict[str, Tuple[str, str]]] = None
        self._baseline_at = ""
        self._events: Deque[_Announcement] = deque(maxlen=200)
        self._next = 1
        self._scanned = -1e12

    def head(self) -> int:
        with self._lock:
            return self._next - 1

    def after(self, cursor: int) -> List[_Announcement]:
        cutoff = self._clock() - ANNOUNCE_KEEP_SECONDS
        with self._lock:
            return [event for event in self._events if event.id > cursor and event.at >= cutoff]

    def get(self, number: int) -> Optional[_Announcement]:
        cutoff = self._clock() - ANNOUNCE_KEEP_SECONDS
        with self._lock:
            return next((event for event in self._events if event.id == number and event.at >= cutoff), None)

    def refresh(self, budget: float = ANNOUNCE_REFRESH_BUDGET) -> None:
        """Before a new conversation takes its cursor: catch up with T3 now (a snapshot at most a scan interval old),
        so whatever changed while nobody was talking is numbered before the cursor and never announced to it. A T3
        that hangs delays the conversation by ``budget`` seconds at most (the catch-up then finishes by itself)."""
        worker = threading.Thread(target=self.scan, kwargs={"min_interval": 0.0, "blocking": True,
                                                            "max_age": ANNOUNCE_SCAN_SECONDS},
                                  name="samrabbit-assistant-catch-up", daemon=True)
        worker.start()
        worker.join(timeout=budget)

    def scan(self, *, min_interval: float = ANNOUNCE_SCAN_SECONDS - 0.5, blocking: bool = False,
             max_age: Optional[float] = None) -> None:
        if not self._scan_lock.acquire(blocking=blocking, timeout=15.0 if blocking else -1):
            return  # another scan is running; its result serves this one too
        try:
            if self._monotonic() - self._scanned < min_interval:
                return
            hub = self._hub()
            if hub is None or not hub.available():
                return
            try:
                items = hub.threads(None, limit=100, max_age=max_age if max_age is not None else max(1.0, min_interval))
            except Exception:  # noqa: BLE001 - T3 down or not paired: nothing to announce
                return
            self._scanned = self._monotonic()
            current = {str(item.get("threadId")): (str(item.get("status") or ""), str(item.get("updatedAt") or ""))
                       for item in items if isinstance(item, dict) and item.get("threadId")}
            with self._lock:
                if self._known is None:
                    self._known = current
                    self._baseline_at = max((value[1] for value in current.values()), default="")
                    return
                known = self._known
                for item in items:
                    if not isinstance(item, dict) or item.get("settled"):
                        continue
                    thread_id = str(item.get("threadId") or "")
                    status, updated = current.get(thread_id, ("", ""))
                    before = known.get(thread_id)
                    kind = _transition(before[0] if before else None, status)
                    if kind is None or (before is None and updated <= self._baseline_at):
                        continue
                    self._events.append(_Announcement(self._next, self._clock(), kind, item))
                    self._next += 1
                self._known = current
        finally:
            self._scan_lock.release()


def _transition(before: Optional[str], now: str) -> Optional[str]:
    needs = ("needs_approval", "needs_input")
    if now in needs and before != now:
        return "needs_you"
    if now == "done" and (before is None or before in ("working",) + needs):
        return "done"
    if now == "error" and before != "error":
        return "error"
    return None


# --------------------------------------------------------------------------- conversations


class _Conversation:
    def __init__(self, conversation_id: str, device: Dict[str, Any], *, now: float, cursor: int,
                 session_id: Optional[str] = None, started: bool = False) -> None:
        self.id = conversation_id
        self.device_id = str(device.get("deviceId") or "")
        self.platform = str(device.get("platform") or "watchos")
        mac = self.platform == "macos"
        self.sync_id = (MAC_SYNC_PREFIX if mac else SYNC_PREFIX) + conversation_id
        self.prefix = "mac" if mac else "watch"  # its timeline events' ids: "<prefix>:<turn>:user", ...
        self.session_id = session_id or str(uuid.uuid4())
        self.started = started  # the CLI has this session (resume it)
        self.created_at = now
        self.last_at = now
        self.cursor = cursor
        self.first_cursor = cursor  # announcements numbered after this one belong to this conversation
        self.announced: set = set()
        self.notes: List[str] = []
        self.lock = threading.Lock()
        self.process: Optional["subprocess.Popen[bytes]"] = None
        self.recorded_start = False
        self.ended = False
        self.turns = 0
        # The realtime brain: this conversation's session (opened in the background), what was said (for the summary
        # a new session starts with after 55 minutes). ``current``: the turn being answered, its id and its cancel
        # switch as one value (set and cleared at once), so a cancel that names a turn reads that turn's own switch.
        self.realtime: Any = None
        self.realtime_lock = threading.Lock()
        self.history: Deque[Tuple[str, str]] = deque(maxlen=HISTORY_TURNS)
        self.said: Deque[str] = deque(maxlen=3)
        self.current: Optional[Tuple[str, threading.Event]] = None

    @property
    def cancel(self) -> Optional[threading.Event]:
        """The current turn's cancel switch (None between turns)."""
        current = self.current
        return current[1] if current is not None else None

    def record(self) -> Dict[str, Any]:
        return {"sessionId": self.session_id, "started": self.started, "deviceId": self.device_id,
                "platform": self.platform, "createdAt": self.created_at, "lastAt": self.last_at,
                "ended": self.ended, "recordedStart": self.recorded_start}


class _TurnEntry:
    def __init__(self, now: float) -> None:
        self.at = now
        self.event = threading.Event()
        self.response: Optional[Tuple[int, Dict[str, Any]]] = None
        self.result: Optional["_TurnResult"] = None  # a finished turn: what a retry replays (JSON or a stream)
        self.keep = False


class _TurnRequest:
    def __init__(self, *, conversation_id: Optional[str], turn_id: str, text: Optional[str] = None,
                 audio: Optional[bytes] = None, container: str = "", language: str = "en-US",
                 announce: Optional[int] = None) -> None:
        self.conversation_id = conversation_id
        self.turn_id = turn_id
        self.text = text
        self.audio = audio
        self.container = container
        self.language = language
        self.announce = announce


class _TurnResult:
    """What a turn said and did, for the buffered JSON answer, the stream's ``done`` and a retry's replay."""

    def __init__(self, conversation_id: str, turn_id: str) -> None:
        self.conversation_id = conversation_id
        self.turn_id = turn_id
        self.heard = ""
        self.heard_sent = False
        self.say = ""
        self.audio: Optional[bytes] = None
        self.audio_mime = ""
        self.expect_reply = True
        self.end = False
        self.interrupted = False
        self.brain = "claude"
        self.actions: List[Dict[str, Any]] = []
        self.cards: List[Dict[str, Any]] = []
        self.timings: Dict[str, Any] = {"stt": 0, "agent": 0, "tts": 0}

    def json(self) -> Dict[str, Any]:
        return {"conversationId": self.conversation_id, "turnId": self.turn_id, "heard": self.heard, "say": self.say,
                "audio": {"mime": self.audio_mime, "b64": base64.b64encode(self.audio).decode("ascii")}
                if self.audio else None,
                "expectReply": self.expect_reply, "endConversation": self.end, "actions": list(self.actions),
                "timings": {key: self.timings.get(key, 0) for key in ("stt", "agent", "tts")}, "brain": self.brain}

    def done_event(self) -> Dict[str, Any]:
        value: Dict[str, Any] = {"type": "done", "conversationId": self.conversation_id, "turnId": self.turn_id,
                                 "expectReply": self.expect_reply, "endConversation": self.end, "brain": self.brain,
                                 "timings": {"stt": self.timings.get("stt", 0),
                                             "firstAudio": self.timings.get("firstAudio"),
                                             "total": self.timings.get("total", 0)}}
        if self.interrupted:
            value["interrupted"] = True
        return value


class Streamed:
    """The turn wrote its own (streamed) response; ``status`` is for the log line (``samrabbit_mobile``)."""

    streamed = True

    def __init__(self, status: int = 200) -> None:
        self.status = status


class StreamWriter:
    """The streaming turn protocol on one HTTP response: HTTP/1.1, chunked; each frame = 1 type byte (``J`` JSON,
    ``A`` audio), a 4-byte big-endian length, the payload. Starts the response with its first frame, so anything
    that fails before that answers as a normal JSON error. A client that went away just stops the writing.

    ``keep_alive()``: while the turn is open, a ``{"type": "ping"}`` event whenever nothing was written for
    ``ping_every`` seconds (a long tool call writes nothing, and the watch gives up on a silent stream after 40 s). A
    ping may be the first frame: the stream has then started, and a later failure comes as ``error`` + ``done`` in
    it. ``stop_pings()`` (``finish()`` does it too) returns once no other ping can be written."""

    def __init__(self, handler: Any, *, ping_every: float = STREAM_PING_SECONDS) -> None:
        self.handler = handler
        self.started = False
        self.broken = False
        self._audio = bytearray()
        self._lock = threading.Lock()  # the turn's frames and the pings, one at a time
        self._ping_every = ping_every
        self._last = time.monotonic()
        self._stop = threading.Event()
        self._pinger: Optional[threading.Thread] = None

    def _start(self) -> None:
        handler = self.handler
        handler.protocol_version = "HTTP/1.1"  # this response only: chunked needs 1.1 (the bridge is 1.0)
        handler.send_response(200)
        handler.send_header("Content-Type", STREAM_TYPE)
        handler.send_header("Transfer-Encoding", "chunked")
        handler.send_header("Cache-Control", "no-store")
        handler.send_header("X-Content-Type-Options", "nosniff")
        handler.send_header("Connection", "close")
        handler.end_headers()
        self.started = True

    def _write(self, kind: bytes, payload: bytes) -> None:
        """One frame (``self._lock`` held)."""
        if self.broken:
            return
        try:
            if not self.started:
                self._start()
            data = kind + struct.pack(">I", len(payload)) + payload
            self.handler.wfile.write(b"%X\r\n" % len(data) + data + b"\r\n")
            self.handler.wfile.flush()
            self._last = time.monotonic()
        except (OSError, ValueError):
            self.broken = True

    def frame(self, kind: bytes, payload: bytes) -> None:
        with self._lock:
            self._write(kind, payload)

    def keep_alive(self) -> None:
        if self._ping_every <= 0 or self._pinger is not None or self._stop.is_set():
            return
        self._pinger = threading.Thread(target=self._ping, name="samrabbit-stream-ping", daemon=True)
        self._pinger.start()

    def _ping(self) -> None:
        while True:
            with self._lock:
                if self._stop.is_set() or self.broken:
                    return
                due = self._last + self._ping_every - time.monotonic()
                if due <= 0:
                    self._write(b"J", PING_EVENT)
                    due = self._ping_every
            if self._stop.wait(timeout=due):
                return

    def stop_pings(self) -> None:
        with self._lock:  # a ping being written finishes first; none starts after this
            self._stop.set()

    def event(self, value: Dict[str, Any]) -> None:
        self.flush_audio()
        self.frame(b"J", json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8"))

    def audio(self, pcm: bytes) -> None:
        self._audio += pcm
        while len(self._audio) >= STREAM_FRAME_BYTES:
            chunk = bytes(self._audio[:STREAM_FRAME_BYTES])
            del self._audio[:STREAM_FRAME_BYTES]
            self.frame(b"A", chunk)

    def flush_audio(self) -> None:
        if self._audio:
            chunk, self._audio = bytes(self._audio), bytearray()
            self.frame(b"A", chunk)

    def finish(self) -> None:
        self.flush_audio()
        self.stop_pings()
        with self._lock:
            if self.started and not self.broken:
                try:
                    self.handler.wfile.write(b"0\r\n\r\n")
                    self.handler.wfile.flush()
                except (OSError, ValueError):
                    self.broken = True


class TurnSink:
    """Where a turn's output goes: the stream (when the watch asked for one) and the result (always). It also keeps,
    as they happen, the words, actions and cards that went out and the realtime function calls that ran, so a turn
    that fails halfway knows it must not be answered again (``committed``)."""

    def __init__(self, result: _TurnResult, stream: Optional[StreamWriter], *, monotonic: Callable[[], float],
                 started: float, keep_audio: bool) -> None:
        self.result = result
        self.stream = stream
        self._monotonic = monotonic
        self._started = started
        self._keep_audio = keep_audio
        self._pcm = bytearray()
        self.cancel = threading.Event()
        self.said = ""  # every say.delta so far
        self.actions: List[Dict[str, Any]] = []  # every action so far
        self.tools: List[Dict[str, Any]] = []  # the realtime function calls that ran: {id, name, input, result, ...}

    @property
    def started(self) -> bool:
        return self.stream is not None and self.stream.started

    @property
    def committed(self) -> bool:
        """A tool already ran, or words, audio, an action or a card went out: another brain answering this turn again
        would do or say it twice."""
        return bool(self.tools or self.said or self.actions or self.result.cards or
                    self.result.timings.get("firstAudio") is not None)

    def heard(self, text: str) -> None:
        self.result.heard = text
        self.result.heard_sent = True
        if self.stream is not None:
            self.stream.event({"type": "heard", "text": text})

    def say_delta(self, text: str) -> None:
        if not text:
            return
        self.said += text
        if self.stream is not None:
            self.stream.event({"type": "say.delta", "text": text})

    def audio(self, pcm: bytes) -> None:
        if self.result.timings.get("firstAudio") is None:
            self.result.timings["firstAudio"] = int(round((self._monotonic() - self._started) * 1000))
        if self._keep_audio and len(self._pcm) <= 8 * 1024 * 1024:
            self._pcm += pcm
        if self.stream is not None:
            self.stream.audio(pcm)

    def action(self, value: Dict[str, Any]) -> None:
        self.actions.append(value)
        if self.stream is not None:
            self.stream.event({"type": "action", **{key: value[key] for key in ("kind", "title", "threadId",
                                                                                 "artifactId")
                                                     if value.get(key) not in (None, "")}})

    def tool(self, record: Dict[str, Any]) -> None:
        """A realtime function call ran (its effect happened, whatever the turn does next)."""
        self.tools.append(record)

    def card(self, value: Dict[str, Any]) -> None:
        self.result.cards.append(value)
        if self.stream is not None:
            self.stream.event({"type": "card", "title": str(value.get("title") or ""),
                               "body": str(value.get("body") or "")})

    def pcm(self) -> bytes:
        return bytes(self._pcm)

    def finish(self, error: Optional[AssistantError] = None) -> None:
        """``say.done`` (or ``error``), then ``done``, then the end of the stream."""
        result = self.result
        result.timings["total"] = int(round((self._monotonic() - self._started) * 1000))
        if self.stream is None:
            return
        if error is not None:
            self.stream.event({"type": "error", "code": error.code, "message": error.message})
        elif result.say:
            self.stream.event({"type": "say.done", "text": result.say})
        self.stream.event(result.done_event())
        self.stream.finish()


ACTION_KINDS = {"start_task": "task_started", "reply_task": "task_replied", "respond_task": "task_answered",
                "stop_task": "task_stopped", "calendar_block": "event_created", "calendar_create": "event_created",
                "journal_add": "journal_added", "mac_open": "mac_opened", "generate_ui": "ui_generated"}


def actions_from(run: AgentRun) -> List[Dict[str, Any]]:
    """What the turn changed, for the watch to show: from the tool calls that worked."""
    actions: List[Dict[str, Any]] = []
    for tool in run.tools.values():
        kind = ACTION_KINDS.get(tool["name"])
        if kind is None or tool.get("isError") or tool.get("result") is None:
            continue
        try:
            result = json.loads(tool["result"])
        except (TypeError, ValueError):
            result = {}
        result = result if isinstance(result, dict) else {}
        arguments = tool.get("input") or {}
        action: Dict[str, Any] = {"kind": kind}
        name = tool["name"]
        if name == "start_task":
            action.update(title=_clip(result.get("title") or arguments.get("text"), 80) or "New task",
                          threadId=result.get("id"), project=result.get("project"))
        elif name in ("reply_task", "respond_task", "stop_task"):
            if name == "stop_task" and result.get("stopped") is False:
                continue
            label = {"reply_task": "Message sent", "stop_task": "Stopped"}.get(name)
            if name == "respond_task":
                label = {"accept": "Approved", "acceptForSession": "Approved", "acceptAlways": "Approved",
                         "decline": "Denied", "cancel": "Cancelled"}.get(str(result.get("decision")), "Answered")
            action.update(title=label, threadId=result.get("id") or arguments.get("id"))
        elif name in ("calendar_block", "calendar_create"):
            action.update(title=_clip(result.get("title") or arguments.get("title"), 80) or "Event",
                          eventId=result.get("eventId"))
        elif name == "journal_add":
            action.update(title="Journal note")
        elif name == "mac_open":
            action.update(title=_clip(result.get("app") or arguments.get("app") or result.get("url") or
                                      arguments.get("url"), 80) or "Opened on the Mac")
        elif name == "generate_ui":
            action.update(title=_clip(arguments.get("prompt"), 80) or "Visual", artifactId=result.get("artifactId"))
        actions.append({key: value for key, value in action.items() if value not in (None, "")})
    return actions


def _tool_run(tools: List[Dict[str, Any]]) -> AgentRun:
    """The realtime function calls that ran (``TurnSink.tools``) as an ``AgentRun``: for the timeline and the log."""
    run = AgentRun()
    for item in tools:
        run.tools[str(item["id"])] = {"id": item["id"], "name": item["name"], "input": item.get("input") or {},
                                      "result": item.get("result"), "isError": bool(item.get("isError")),
                                      "images": list(item.get("images") or [])}
    return run


def _clip(value: Any, limit: int) -> str:
    text = " ".join(str(value or "").split())
    return text if len(text) <= limit else text[:limit - 1].rstrip() + "…"


def _ms(started: float) -> int:
    return int(round((time.monotonic() - started) * 1000))


def claude_project_dir(cwd: str) -> str:
    """Where the CLI keeps the sessions of ``cwd``: ``~/.claude/projects/<the folder, every other character as "-">``."""
    root = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
    return os.path.join(root, "projects", re.sub(r"[^A-Za-z0-9]", "-", os.path.realpath(cwd)))


# --------------------------------------------------------------------------- the service


class AssistantService:
    """The routes above, for ``samrabbit_mobile`` (``attach(server, mobile)`` gives it the transcriber, the T3 hub,
    the time zone and the sync store)."""

    def __init__(self, agent: ClaudeAgent, voice: ElevenLabsVoice, *, workdir: Optional[str],
                 temporary: bool = False,
                 installed: bool = False, clock: Callable[[], float] = time.time,
                 monotonic: Callable[[], float] = time.monotonic, agent_timeout: float = AGENT_TIMEOUT_SECONDS,
                 idle_end: float = IDLE_END_SECONDS, realtime: Any = None, chatgpt: Any = None) -> None:
        self.agent = agent
        self.voice = voice
        self.settings = agent.settings
        self.workdir = os.path.expanduser(workdir) if workdir else None  # None: a temp folder, made when needed
        self.temporary = temporary or not workdir
        self.installed = installed
        self._clock = clock
        self._monotonic = monotonic
        self.agent_timeout = agent_timeout
        self.idle_end = idle_end
        self.server: Any = None
        self.mobile: Any = None
        self.realtime = realtime  # samrabbit_realtime.RealtimeBrain (None: only Claude answers)
        self.chatgpt = chatgpt if chatgpt is not None else getattr(realtime, "auth", None)
        if self.chatgpt is not None:
            try:
                self.chatgpt.on_change = self._chatgpt_changed
            except AttributeError:  # pragma: no cover
                pass
        self.announcer = T3Announcer(lambda: getattr(self.mobile, "t3", None), clock=clock, monotonic=monotonic)
        self._token = "sra_" + secrets.token_urlsafe(32)
        self._token_hash = hashlib.sha256(self._token.encode("utf-8")).hexdigest()
        self._lock = threading.RLock()
        self._prepare_lock = threading.Lock()
        self._prepared: Optional[str] = None  # None: not yet; "": ready; else the reason it could not be
        self._conversations: Dict[str, _Conversation] = {}
        self._saved: Dict[str, Dict[str, Any]] = {}
        self._turns: "OrderedDict[Tuple[str, str], _TurnEntry]" = OrderedDict()
        self._agents = threading.BoundedSemaphore(MAX_CONCURRENT_AGENTS)
        self.stream_ping = STREAM_PING_SECONDS  # seconds without a frame before a ping (tests shorten it)
        self._last_turn: Optional[Dict[str, Any]] = None
        self._worker: Optional[threading.Thread] = None
        self._stopping = threading.Event()
        self._pruned_at = -1e12
        self._refreshed_at = -1e12
        if self.workdir:
            agent.configure(self.workdir)

    # ------------------------------------------------------------------ lifecycle
    def attach(self, server: Any, mobile: Any) -> None:
        self.server = server
        self.mobile = mobile

    def start(self) -> None:
        if self._worker is not None:
            return
        self.prepare()
        self._worker = threading.Thread(target=self._work, name="samrabbit-assistant", daemon=True)
        self._worker.start()

    def close(self) -> None:
        self._stopping.set()
        if self._worker is not None:
            self._worker.join(timeout=3.0)
            self._worker = None
        self.agent.stop_all()
        with self._lock:
            conversations = list(self._conversations.values())
        for conversation in conversations:
            self._close_session(conversation, background=False)
        if self.chatgpt is not None:
            try:
                self.chatgpt.close()
            except Exception:  # noqa: BLE001
                pass
        self._save()
        if self.temporary and self.workdir:
            shutil.rmtree(claude_project_dir(self.agent.cwd), ignore_errors=True)
            shutil.rmtree(self.workdir, ignore_errors=True)

    def _url(self) -> str:
        address = getattr(self.server, "server_address", ("127.0.0.1", 3780))
        host = str(address[0])
        if host in ("", "0.0.0.0", "::", "127.0.0.1", "localhost"):
            host = "127.0.0.1"
        return f"http://{host}:{int(address[1])}"

    def prepare(self) -> Optional[str]:
        """The working folder (0700): an empty ``cwd/`` for the CLI, the 0600 MCP config, token file and system
        prompt (rewritten at every start: the port or the interpreter may have changed). None when ready, else
        why not."""
        with self._prepare_lock:
            if self._prepared is not None:
                return self._prepared or None
            if self.server is None:
                return "assistant_starting"  # the MCP config needs the bridge's port
            if not os.path.isfile(MCP_SCRIPT):
                self._prepared = "mcp_server_missing"
                return self._prepared
            try:
                if self.workdir is None:
                    self.workdir = tempfile.mkdtemp(prefix="samrabbit-assistant-")  # 0700
                    self.agent.configure(self.workdir)
                os.makedirs(self.workdir, mode=0o700, exist_ok=True)
                os.chmod(self.workdir, 0o700)
                os.makedirs(self.agent.cwd, mode=0o700, exist_ok=True)
                os.chmod(self.agent.cwd, 0o700)
                token_file = os.path.join(self.workdir, "assistant-token")
                _write_private(token_file, self._token + "\n")
                _write_private(self.agent.system_prompt_file, SYSTEM_PROMPT)
                _write_private(self.agent.mac_prompt_file, MAC_SYSTEM_PROMPT)
                config = {"mcpServers": {MCP_SERVER: {
                    "type": "stdio", "command": sys.executable, "args": ["-I", MCP_SCRIPT],
                    "env": {"SAMRABBIT_ASSISTANT_URL": self._url(), "SAMRABBIT_ASSISTANT_TOKEN_FILE": token_file}}}}
                _write_private(self.agent.mcp_config, json.dumps(config, indent=1) + "\n")
                self._load()
            except OSError:
                _LOG.warning("assistant folder could not be set up")
                self._prepared = "assistant_dir_unusable"
                return self._prepared
            self._prepared = ""
            return None

    # ------------------------------------------------------------------ the internal token (the tools)
    def internal_device(self, presented: str, peer: str) -> Optional[Dict[str, Any]]:
        if not presented or not presented.startswith("sra_") or len(presented) > 200:
            return None
        if not hmac.compare_digest(hashlib.sha256(presented.encode("utf-8")).hexdigest(), self._token_hash):
            return None
        if str(peer).split("%", 1)[0] not in ("127.0.0.1", "::1", "::ffff:127.0.0.1"):
            return None
        return {"deviceId": INTERNAL_DEVICE_ID, "name": "SamRabbit assistant", "platform": "assistant",
                "internal": True}

    def busy_sync_ids(self) -> List[str]:
        """The sync-store ids of the conversations answering a turn right now (the desktop inbox shows them as
        working)."""
        with self._lock:
            return [item.sync_id for item in self._conversations.values() if item.lock.locked()]

    def sync_conversation(self, handler: Any) -> Optional[str]:
        """The watch conversation a tool call belongs to: by the CLI's (or the realtime turn's) session id
        (``X-SamRabbit-Assistant-Session``), else the only conversation with a turn running."""
        session = str(handler.headers.get(SESSION_HEADER) or "").strip().lower()
        with self._lock:
            if _SESSION_ID.match(session):
                for conversation in self._conversations.values():
                    if conversation.session_id == session:
                        return conversation.sync_id
            busy = [item for item in self._conversations.values() if item.lock.locked()]
        return busy[0].sync_id if len(busy) == 1 else None

    # ------------------------------------------------------------------ which brain
    def _claude_reason(self) -> Optional[str]:
        reason = self.agent.off_reason()
        if reason:
            return reason
        prepared = self._prepared
        if prepared is None:
            return self.prepare()
        return prepared or None

    def _realtime_reason(self) -> Optional[str]:
        if self.realtime is None or _realtime is None or _profile is None:
            return "realtime_missing"
        if self.server is None:
            return "assistant_starting"
        if getattr(_realtime, "mcp", None) is None:
            return "mcp_server_missing"
        try:
            return self.realtime.off_reason()
        except Exception:  # noqa: BLE001 - the brain's check must never fail a turn
            _LOG.warning("realtime status failed")
            return "realtime_failed"

    def brain(self) -> Tuple[Optional[str], Optional[str]]:
        """``(brain, None)`` for the next turn, or ``(None, why nothing can answer)``. ``auto``: realtime when
        ChatGPT is connected and the helper is ready, else Claude."""
        setting = self.settings.brain()
        if setting == "claude":
            reason = self._claude_reason()
            return ("claude", None) if reason is None else (None, reason)
        realtime_reason = self._realtime_reason()
        if setting == "realtime":
            return ("realtime", None) if realtime_reason is None else (None, realtime_reason)
        if realtime_reason is None:
            return "realtime", None
        claude_reason = self._claude_reason()
        if claude_reason is None:
            return "claude", None
        quiet = realtime_reason in ("realtime_missing", "chatgpt_not_connected", "chatgpt_dev_copy")
        return None, claude_reason if quiet else realtime_reason

    def off_reason(self) -> Optional[str]:
        brain, reason = self.brain()
        return None if brain is not None else (reason or "assistant_unavailable")

    def _preferred(self) -> str:
        setting = self.settings.brain()
        if setting in ("claude", "realtime"):
            return setting
        connected = False
        try:
            connected = self.chatgpt is not None and self.chatgpt.connected()
        except Exception:  # noqa: BLE001
            connected = False
        return "realtime" if connected else "claude"

    def _model_for(self, brain: str) -> str:
        return self.settings.realtime_model() if brain == "realtime" else self.settings.model()

    def _chatgpt_connected(self) -> bool:
        try:
            return bool(self.chatgpt is not None and self.chatgpt.connected())
        except Exception:  # noqa: BLE001
            return False

    # ------------------------------------------------------------------ status
    def health(self) -> Dict[str, Any]:
        brain, reason = self.brain()
        model = self.settings.model()
        value: Dict[str, Any] = {"available": brain is not None, "brain": brain or self._preferred(),
                                 "brainSetting": self.settings.brain(), "model": model,
                                 "modelName": model_name(model), "claude": self.agent.executable() is not None,
                                 "copy": "installed" if self.installed else "dev", "voice": self.voice.status(),
                                 "realtime": self._realtime_health()}
        if reason:
            value["reason"] = reason
        with self._lock:
            value["conversations"] = sum(1 for item in self._conversations.values()
                                         if self._clock() - item.last_at < self.idle_end and not item.ended)
            if self._last_turn is not None:
                value["lastTurn"] = dict(self._last_turn)
        return value

    def _realtime_health(self) -> Dict[str, Any]:
        if self.realtime is None or _realtime is None:
            return {"available": False, "reason": "realtime_missing",
                    "chatgpt": {"connected": self._chatgpt_connected()}}
        try:
            value = dict(self.realtime.status())
        except Exception:  # noqa: BLE001
            return {"available": False, "reason": "check_failed"}
        reason = self._realtime_reason()
        value["available"] = reason is None
        value.pop("reason", None)
        if reason:
            value["reason"] = reason
        value["model"] = self.settings.realtime_model()
        value["voice"] = self.settings.realtime_voice()
        return value

    def summary_part(self) -> Dict[str, Any]:
        """``{available, brain, reason?, model, chatgpt: {connected}}``: can the watch talk to the assistant?"""
        brain, reason = self.brain()
        chosen = brain or self._preferred()
        value: Dict[str, Any] = {"available": brain is not None, "brain": chosen, "model": self._model_for(chosen),
                                 "chatgpt": {"connected": self._chatgpt_connected()}}
        if reason:
            value["reason"] = reason
        return value

    # ------------------------------------------------------------------ ChatGPT (the desktop app's routes)
    def chatgpt_route(self, action: str) -> Tuple[int, Dict[str, Any]]:
        """``start`` / ``status`` / ``disconnect`` (``samrabbit_mobile`` checked the desktop token)."""
        auth = self.chatgpt
        if auth is None:
            raise AssistantError(503, "chatgpt_unavailable", "ChatGPT login is not installed on the Mac bridge.")
        try:
            if action == "start":
                return 200, auth.start()
            if action == "disconnect":
                return 200, auth.disconnect()
            return 200, auth.status()
        except Exception as error:  # noqa: BLE001 - ChatGPTError answers with its own envelope
            if isinstance(getattr(error, "status", None), int) and callable(getattr(error, "payload", None)):
                raise AssistantError(error.status, str(getattr(error, "code", "chatgpt_failed")),  # type: ignore
                                     str(getattr(error, "message", "ChatGPT login failed.")),
                                     retryable=bool(getattr(error, "retryable", False))) from None
            raise

    def _chatgpt_changed(self) -> None:
        """A new login, a disconnect or a refused refresh (``samrabbit_chatgpt`` calls this only then): every session
        was made with the old login. None is cut off mid-turn: each is retired (no new turn uses it), and the sweep
        (within a second, once its turn is over) or the next turn closes it."""
        if self.realtime is not None:
            self.realtime.resume()
        with self._lock:
            sessions = [item.realtime for item in self._conversations.values() if item.realtime is not None]
        for session in sessions:
            session.retire()

    # ------------------------------------------------------------------ conversations
    def _load(self) -> None:
        path = os.path.join(str(self.workdir), "conversations.json")
        try:
            with open(path, "r", encoding="utf-8") as handle:
                value = json.load(handle)
        except (OSError, ValueError):
            return
        items = value.get("conversations") if isinstance(value, dict) else None
        now = self._clock()
        with self._lock:
            for key, record in (items or {}).items() if isinstance(items, dict) else []:
                if isinstance(key, str) and _CONVERSATION_ID.match(key) and isinstance(record, dict) and \
                        isinstance(record.get("sessionId"), str) and _SESSION_ID.match(record["sessionId"]) and \
                        now - float(record.get("lastAt") or 0) < FORGET_SECONDS:
                    self._saved[key] = record

    def _save(self) -> None:
        if self._prepared != "":
            return
        now = self._clock()
        with self._lock:
            for conversation in self._conversations.values():
                self._saved[conversation.id] = conversation.record()
            kept = sorted(((key, record) for key, record in self._saved.items()
                           if now - float(record.get("lastAt") or 0) < FORGET_SECONDS),
                          key=lambda pair: float(pair[1].get("lastAt") or 0))[-MAX_CONVERSATIONS:]
            self._saved = dict(kept)
            data = json.dumps({"version": 1, "conversations": self._saved}, indent=1)
        try:
            _write_private(os.path.join(str(self.workdir), "conversations.json"), data + "\n")
        except OSError:
            _LOG.warning("assistant conversations not saved")

    def _conversation(self, conversation_id: Optional[str], device: Dict[str, Any]) -> _Conversation:
        device_id = str(device.get("deviceId") or "")
        with self._lock:
            if conversation_id:
                found = self._conversations.get(conversation_id)
                if found is not None:
                    if found.device_id != device_id:
                        raise AssistantError(404, "conversation_not_found", "No such conversation.")
                    return found
                saved = self._saved.get(conversation_id)
                if saved is not None and str(saved.get("deviceId") or "") != device_id:
                    raise AssistantError(404, "conversation_not_found", "No such conversation.")
        # A conversation that starts now takes the announcer's cursor: first catch up with T3, so whatever changed
        # while nobody talked is numbered before it and never announced as new.
        self.announcer.refresh()
        now = self._clock()
        with self._lock:
            if conversation_id:
                found = self._conversations.get(conversation_id)
                if found is not None:  # another request made it meanwhile
                    if found.device_id != device_id:
                        raise AssistantError(404, "conversation_not_found", "No such conversation.")
                    return found
            else:
                conversation_id = str(uuid.uuid4())
            saved = self._saved.get(conversation_id) or {}
            conversation = _Conversation(conversation_id, device, now=now, cursor=self.announcer.head(),
                                         session_id=saved.get("sessionId"), started=saved.get("started") is True)
            conversation.recorded_start = saved.get("recordedStart") is True and not saved.get("ended")
            self._conversations[conversation_id] = conversation
            return conversation

    # ------------------------------------------------------------------ the worker (T3 watch, housekeeping)
    def _work(self) -> None:
        last_sweep = -1e12
        while not self._stopping.wait(timeout=1.0):
            now = self._clock()
            with self._lock:
                active = any(now - item.last_at < ANNOUNCE_ACTIVE_SECONDS for item in self._conversations.values())
            if active:
                try:
                    self.announcer.scan()
                except Exception:  # noqa: BLE001 - never stops the worker
                    _LOG.warning("assistant: T3 watch failed")
            try:
                self.sweep_sessions()
            except Exception:  # noqa: BLE001
                _LOG.warning("assistant: realtime housekeeping failed")
            if self.chatgpt is not None and self._monotonic() - self._refreshed_at >= 60.0:
                self._refreshed_at = self._monotonic()
                try:
                    self.chatgpt.refresh_if_needed()  # a turn never waits for a token refresh
                except Exception:  # noqa: BLE001
                    _LOG.warning("assistant: chatgpt refresh failed")
            if self._monotonic() - last_sweep >= 30.0:
                last_sweep = self._monotonic()
                try:
                    self.sweep()
                except Exception:  # noqa: BLE001
                    _LOG.warning("assistant: housekeeping failed")

    def sweep(self) -> None:
        """Ends conversations nobody spoke in for a while (recorded as ``conversation.ended``), forgets old turn
        answers and, once a day, removes the CLI's session files older than two weeks."""
        now = self._clock()
        with self._lock:
            idle = [item for item in self._conversations.values()
                    if not item.ended and now - item.last_at >= self.idle_end and not item.lock.locked()]
            forgotten = [item for item in self._conversations.values()
                         if now - item.last_at >= ANNOUNCE_KEEP_SECONDS and not item.lock.locked()]
            for item in forgotten:
                self._saved[item.id] = item.record()
                self._conversations.pop(item.id, None)
            for key in [key for key, entry in self._turns.items()
                        if entry.event.is_set() and self._monotonic() - entry.at > TURN_CACHE_SECONDS]:
                self._turns.pop(key, None)
        # Outside self._lock: _close_session takes a conversation's realtime_lock, and _session() takes self._lock
        # with one held (the session cap), so the two locks are only ever taken in that order.
        for item in forgotten:
            self._close_session(item)
        for item in idle:
            self._end(item)
            self._close_session(item)
        if idle:
            self._save()
        if self.workdir and self._monotonic() - self._pruned_at >= 24 * 3600.0:
            self._pruned_at = self._monotonic()
            prune_sessions(claude_project_dir(self.agent.cwd), now - SESSION_KEEP_SECONDS)

    def sweep_sessions(self) -> None:
        """Realtime sessions idle for three minutes, or open for 55, close (the next turn opens a new one, with a
        summary of the conversation so far)."""
        if _realtime is None:
            return
        with self._lock:
            conversations = [item for item in self._conversations.values() if item.realtime is not None]
        for conversation in conversations:
            session = conversation.realtime
            if session is None or conversation.lock.locked():
                continue
            if session.state in ("failed", "closed") or (session.state == "open" and (
                    time.monotonic() - session.used_at >= _realtime.IDLE_CLOSE_SECONDS or session.expired() or
                    not session.usable())):
                self._close_session(conversation, session)

    # ------------------------------------------------------------------ realtime sessions
    def _session(self, conversation: _Conversation, *, wait: bool) -> Any:
        """This conversation's realtime session, opened in the background when there is none (or it is too old,
        retired, or its helper or connection ended); ``wait``: until it is open (or why it could not). A new one first
        makes room under the cap (``_make_room``): at most ``MAX_SESSIONS_PER_DEVICE`` per device and
        ``MAX_SESSIONS`` on the Mac; the least recently used idle sessions close for it."""
        assert _realtime is not None and self.realtime is not None
        stale = None
        victims: List[Tuple[_Conversation, Any]] = []
        try:
            with conversation.realtime_lock:
                session = conversation.realtime
                if session is not None and (session.state in ("failed", "closed") or (session.state == "open" and (
                        session.expired() or not session.usable()))):
                    # Too old, retired, or it died: detached here, closed below. Never _close_session() here: it
                    # takes this same (non-reentrant) lock.
                    stale, conversation.realtime, session = session, None, None
                if session is None:
                    victims = self._make_room(conversation)  # raises when every other session is mid-turn
                    session = _realtime.RealtimeSession(self.realtime, self._realtime_config(conversation))
                    conversation.realtime = session
                    threading.Thread(target=self._open_session, args=(session,), name="samrabbit-realtime-open",
                                     daemon=True).start()
        finally:
            if stale is not None:
                self._dispose_session(stale)
        for other, old in victims:
            _LOG.info("realtime session closed to make room")
            self._close_session(other, old)
        if not wait:
            return session
        if not session.ready.wait(REALTIME_OPEN_WAIT):
            raise _realtime.RealtimeError("realtime_timeout", "The realtime voice did not connect in time.",
                                          pause=_realtime.PAUSE_FAILED_SECONDS)
        if session.state != "open":
            raise session.error or _realtime.RealtimeError("realtime_failed", "The realtime voice failed.")
        return session

    def _make_room(self, conversation: _Conversation) -> List[Tuple[_Conversation, Any]]:
        """The sessions to close before ``conversation`` gets a new one, so that its device keeps at most
        ``MAX_SESSIONS_PER_DEVICE`` and the Mac at most ``MAX_SESSIONS`` (each is an OpenAI call on the subscription
        and a helper process): the least recently used first, never one whose conversation is mid-turn. Raises
        ``realtime_sessions_full`` (no pause: the turn goes to Claude) when that is not enough. Called with
        ``conversation.realtime_lock`` held; takes ``self._lock`` (never the other way round)."""
        assert _realtime is not None
        with self._lock:
            live = [(item, item.realtime) for item in self._conversations.values()
                    if item is not conversation and item.realtime is not None and
                    item.realtime.state in ("new", "opening", "open") and not item.realtime.closing]

        def last_used(pair: Tuple[_Conversation, Any]) -> float:
            return max(float(pair[1].used_at or 0.0), float(pair[1].created_at or 0.0))

        def idle(pairs: List[Tuple[_Conversation, Any]]) -> List[Tuple[_Conversation, Any]]:
            return sorted((pair for pair in pairs if not pair[0].lock.locked()), key=last_used)

        victims: List[Tuple[_Conversation, Any]] = []
        mine = [pair for pair in live if pair[0].device_id == conversation.device_id]
        over = len(mine) + 1 - MAX_SESSIONS_PER_DEVICE
        if over > 0:
            candidates = idle(mine)
            if len(candidates) < over:
                raise _realtime.RealtimeError("realtime_sessions_full", "This device already has its voice sessions "
                                              "open.")
            victims += candidates[:over]
        rest = [pair for pair in live if pair not in victims]
        over = len(rest) + 1 - MAX_SESSIONS
        if over > 0:
            candidates = idle(rest)
            if len(candidates) < over:
                raise _realtime.RealtimeError("realtime_sessions_full", "The Mac already has its voice sessions open.")
            victims += candidates[:over]
        return victims

    def _open_session(self, session: Any) -> None:
        try:
            self.realtime.start(session)
        except Exception:  # noqa: BLE001 - kept on the session (session.error) for the turn that waits
            if not session.ready.is_set():  # pragma: no cover
                session.ready.set()

    def _close_session(self, conversation: _Conversation, session: Any = None, *, background: bool = True) -> None:
        """Detach the conversation's session (only ``session``, when given) and close it. Takes
        ``conversation.realtime_lock``: never call it with that lock held."""
        with conversation.realtime_lock:
            current = conversation.realtime
            if session is not None and current is not session:
                return
            conversation.realtime = None
        if current is not None:
            self._dispose_session(current, background=background)

    @staticmethod
    def _dispose_session(session: Any, *, background: bool = True) -> None:
        """Close a session that no conversation holds any more (outside every lock)."""
        if background:
            threading.Thread(target=session.close, name="samrabbit-realtime-close", daemon=True).start()
        else:
            session.close()

    def _realtime_config(self, conversation: _Conversation) -> Dict[str, Any]:
        assert _profile is not None
        hub = getattr(self.mobile, "t3", None)
        t3_on = False
        items: Optional[List[Dict[str, Any]]] = None
        try:
            t3_on = hub is not None and bool(hub.available())
            if t3_on and hub.cached() is not None:
                items = hub.threads(None, limit=40, max_age=1e9)  # the cached snapshot only (no T3 call)
        except Exception:  # noqa: BLE001
            items = None
        writer = getattr(self.server, "calendar", None)
        calendar_on = writer is not None and hasattr(writer, "create")
        visuals = getattr(self.server, "genui", None) is not None
        mac_on = getattr(self.server, "mac", None) is not None
        earlier = None
        if conversation.history:
            earlier = _clip(" ".join(f"Samin said: {heard} You answered: {say}"
                                     for heard, say in list(conversation.history)[-6:]), 2000)
        tools = _profile.tool_definitions(t3=t3_on, mac=mac_on, calendar=calendar_on, journal=True, visuals=visuals)
        text = _profile.instructions(t3_items=items, t3=t3_on, mac=mac_on, visuals=visuals, earlier=earlier,
                                     device={"macos": "mac", "ios": "iphone"}.get(conversation.platform, "watch"))
        return _profile.session_config(model=self.settings.realtime_model(), voice=self.settings.realtime_voice(),
                                       instructions_text=text, tools=tools)

    def _runner(self, conversation: _Conversation) -> Any:
        assert _realtime is not None
        return _realtime.ToolRunner(bridge_url=self._url(), token=self._token, session=conversation.session_id,
                                    server=self.server, mobile=self.mobile, said=lambda: list(conversation.said),
                                    clock=self._clock)

    # ------------------------------------------------------------------ routes
    def turn(self, handler: Any, device: Dict[str, Any]) -> Any:
        """One turn: ``(status, JSON)``, or ``Streamed`` when the watch asked for the stream (``Accept:
        application/x-samrabbit-stream``) and it was written."""
        if device.get("internal"):
            raise AssistantError(403, "forbidden", "The assistant cannot talk to itself.")
        started = self._monotonic()
        brain, reason = self.brain()
        if brain is None:
            raise unavailable(reason or "assistant_unavailable")
        streaming = STREAM_TYPE in str(handler.headers.get("Accept") or "").lower()
        request = self._read_turn(handler)
        key = (str(device.get("deviceId") or ""), request.turn_id)
        with self._lock:
            entry = self._turns.get(key)
            owner = entry is None
            if owner:
                entry = self._turns[key] = _TurnEntry(self._monotonic())
                while len(self._turns) > TURN_CACHE_SIZE:
                    oldest = next(iter(self._turns))
                    if not self._turns[oldest].event.is_set():
                        break
                    self._turns.pop(oldest)
        assert entry is not None
        writer = StreamWriter(handler, ping_every=self.stream_ping) if streaming else None
        if writer is not None:
            writer.keep_alive()  # pings while the turn is open (and while a retry waits for it)
        if not owner:
            # A retry of a turn: the same answer (the brain runs once). Still running: wait for it.
            finished = entry.event.wait(timeout=TURN_WAIT_SECONDS)
            if writer is not None:
                writer.stop_pings()
            if not finished or (entry.response is None and entry.result is None):
                busy = AssistantError(409, "assistant_busy", "Still answering that.", retryable=True)
                if writer is not None and writer.started:
                    self._stream_error(writer, request, brain, busy.code, busy.message)
                    return Streamed(200)
                raise busy
            if entry.result is not None:
                if writer is not None:
                    self._replay(writer, entry.result)
                    return Streamed(200)
                return 200, entry.result.json()
            if writer is not None and writer.started:  # the pings started the stream: the error goes in it
                error_body = (entry.response[1] or {}).get("error") or {}
                self._stream_error(writer, request, brain, str(error_body.get("code") or "assistant_failed"),
                                   str(error_body.get("message") or "That did not work on the Mac."))
                return Streamed(200)
            return entry.response
        result = _TurnResult(request.conversation_id or "", request.turn_id)
        sink = TurnSink(result, writer, monotonic=self._monotonic, started=started, keep_audio=not streaming)
        try:
            self._turn(request, device, sink, brain)
            entry.result, entry.keep = result, True
            self._trim_cached_audio()
        except AssistantError as error:
            entry.response, entry.keep = (error.status, error.payload()), error.cache
            if writer is not None:
                writer.stop_pings()  # before looking at ``started``: a ping may just have started the stream
            if sink.started:
                sink.finish(error)
                return Streamed(200)
            raise
        except Exception as error:  # noqa: BLE001 - TranscribeError and friends: a retry may run again
            status = getattr(error, "status", None)
            payload = getattr(error, "payload", None)
            entry.response = (status, payload()) if isinstance(status, int) and callable(payload) else \
                (500, {"error": {"code": "internal_error", "message": "The bridge failed unexpectedly.",
                                 "retryable": True}})
            if writer is not None:
                writer.stop_pings()
            if sink.started:
                code = str(getattr(error, "code", "") or "internal_error")
                sink.finish(AssistantError(int(status) if isinstance(status, int) else 500, code,
                                           str(getattr(error, "message", "") or "The bridge failed unexpectedly.")))
                return Streamed(200)
            raise
        finally:
            entry.event.set()
            if not entry.keep:
                with self._lock:
                    if self._turns.get(key) is entry:
                        self._turns.pop(key, None)
        if streaming:
            sink.finish()
            return Streamed(200)
        return 200, result.json()

    def _trim_cached_audio(self) -> None:
        with self._lock:
            kept = 0
            for entry in reversed(list(self._turns.values())):
                if entry.result is not None and entry.result.audio:
                    kept += 1
                    if kept > MAX_CACHED_AUDIO:
                        entry.result.audio = None

    @staticmethod
    def _stream_error(writer: StreamWriter, request: _TurnRequest, brain: str, code: str, message: str) -> None:
        """A failure after pings started the stream: ``error`` then ``done``, like any turn that failed midway."""
        result = _TurnResult(request.conversation_id or "", request.turn_id)
        result.brain = brain
        writer.event({"type": "error", "code": code, "message": message})
        writer.event(result.done_event())
        writer.finish()

    def _replay(self, writer: StreamWriter, result: _TurnResult) -> None:
        """A retried streamed turn: what it said and did again (its audio only while it is still cached)."""
        if result.heard_sent:
            writer.event({"type": "heard", "text": result.heard})
        if result.say:
            writer.event({"type": "say.delta", "text": result.say})
        for action in result.actions:
            writer.event({"type": "action", **{key: action[key] for key in ("kind", "title", "threadId", "artifactId")
                                               if action.get(key) not in (None, "")}})
        for card in result.cards:
            writer.event({"type": "card", "title": str(card.get("title") or ""), "body": str(card.get("body") or "")})
        if result.audio and result.audio_mime == "audio/wav":
            writer.audio(result.audio[44:])
        if result.say:
            writer.event({"type": "say.done", "text": result.say})
        writer.event(result.done_event())
        writer.finish()

    def _read_turn(self, handler: Any) -> _TurnRequest:
        declared = str(handler.headers.get("Content-Type") or "").split(";", 1)[0].strip().lower()
        query = _query(handler)
        header_conversation = str(handler.headers.get("X-SamRabbit-Conversation") or "").strip() or None
        header_turn = str(handler.headers.get("X-SamRabbit-Turn") or "").strip() or None
        device_time = handler.headers.get("X-SamRabbit-Device-Time")
        if device_time is not None and len(str(device_time)) > 64:
            raise AssistantError(400, "invalid_device_time", "X-SamRabbit-Device-Time is too long.")
        if declared.startswith("audio/"):
            if _transcribe is None or getattr(self.mobile, "transcriber", None) is None:
                raise AssistantError(503, "transcribe_unavailable", "Transcription is not installed on the Mac "
                                     "bridge.")
            kind = _transcribe.content_kind(declared)
            language = _transcribe.normalize_language((query.get("lang") or [None])[0])
            length = _length(handler, MAX_AUDIO_BYTES)
            if not length:
                raise AssistantError(400, "invalid_audio", "Send the recording as the request body.")
            try:
                data = handler.rfile.read(length)
            except OSError:
                data = b""
            if len(data) != length:
                raise AssistantError(400, "invalid_audio", "The recording did not arrive completely.", retryable=True)
            container, seconds = _transcribe.check_audio(data, kind)
            if seconds is not None and seconds > MAX_AUDIO_SECONDS + 0.5:
                raise AssistantError(413, "audio_too_long", f"Say it in at most {MAX_AUDIO_SECONDS} seconds.")
            request = _TurnRequest(conversation_id=header_conversation, turn_id=header_turn or "", audio=data,
                                   container=container, language=language)
        elif declared in ("application/json", ""):
            body = _json_body(handler)
            text = body.get("text")
            announce = body.get("announce")
            conversation = body.get("conversationId", header_conversation)
            turn = body.get("turnId", header_turn)
            if conversation is not None and not isinstance(conversation, str):
                raise AssistantError(400, "invalid_conversation", "conversationId must be an id.")
            if turn is not None and not isinstance(turn, str):
                raise AssistantError(400, "invalid_turn", "turnId must be a uuid.")
            number: Optional[int] = None
            if announce is not None:
                if isinstance(announce, bool) or not (isinstance(announce, int) or
                                                      (isinstance(announce, str) and announce.strip().isdigit())):
                    raise AssistantError(400, "invalid_announce", "announce must be an announcement id.")
                number = int(str(announce).strip())
                if not conversation:
                    raise AssistantError(400, "invalid_conversation", "An announcement needs its conversationId.")
            elif not isinstance(text, str) or len(text) > MAX_TEXT_CHARS or "\x00" in text:
                raise AssistantError(400, "invalid_text", f"text must be at most {MAX_TEXT_CHARS} characters.")
            request = _TurnRequest(conversation_id=(conversation or "").strip() or None, turn_id=(turn or "").strip(),
                                   text=text if number is None else None, announce=number)
        else:
            raise AssistantError(415, "unsupported_media", "Send audio/wav, audio/mp4 or audio/x-m4a, or JSON text.")
        if request.conversation_id is not None and not _CONVERSATION_ID.match(request.conversation_id):
            raise AssistantError(400, "invalid_conversation", "The conversation id must be 3 to 57 letters, digits, "
                                 "- or _.")
        if not _TURN_ID.match(request.turn_id):
            raise AssistantError(400, "invalid_turn", "Send X-SamRabbit-Turn (or turnId): a uuid for this turn.")
        return request

    def _turn(self, request: _TurnRequest, device: Dict[str, Any], sink: TurnSink, brain: str) -> None:
        conversation = self._conversation(request.conversation_id, device)
        result = sink.result
        result.conversation_id = conversation.id
        result.brain = brain
        if not conversation.lock.acquire(blocking=False):
            raise AssistantError(409, "assistant_busy", "Still answering the last thing you said.", retryable=True)
        conversation.current = (request.turn_id, sink.cancel)
        try:
            conversation.last_at = self._clock()
            conversation.ended = False
            if request.announce is not None:
                self._announce_turn(conversation, request, sink, brain)
                self._done(conversation, request, result, None, record=False)  # host.t3_update is its record
                return
            heard = request.text or ""
            if request.audio is not None:
                started = time.monotonic()
                try:
                    heard = str(self.mobile.transcriber.transcribe(request.audio, request.container,
                                                                   request.language).get("text") or "")
                except Exception as error:  # noqa: BLE001 - TranscribeError: no_speech is "keep listening"
                    if getattr(error, "code", None) != "no_speech":
                        raise
                    heard = ""
                finally:
                    result.timings["stt"] = _ms(started)
                    changed = getattr(self.mobile, "transcription_changed", None)
                    if callable(changed):
                        changed()
            heard = " ".join(_CONTROL.sub(" ", heard).split())
            if is_noise(heard):
                result.heard, result.say, result.expect_reply = "", "", True
                sink.heard("")
                return
            sink.heard(heard)
            self._record_start(conversation, heard)
            self._record(conversation, {"id": f"{conversation.prefix}:{request.turn_id}:user", "type": "message.user",
                                        "text": heard, "origin": conversation_origin(conversation)})
            conversation.said.append(heard)
            if is_closer(heard):
                result.say, result.end, result.expect_reply = goodbye(heard), True, False
                self._say_line(conversation, result.say, sink, brain, open_session=False)
                self._done(conversation, request, result, None)
                self._end(conversation)
                self._close_session(conversation)
                return
            run: Optional[AgentRun] = None
            if brain == "realtime":
                try:
                    run = self._realtime_turn(conversation, request, heard, sink)
                except Exception as error:  # noqa: BLE001 - RealtimeError: Claude answers when nothing happened yet
                    if _realtime is None or not isinstance(error, _realtime.RealtimeError):
                        raise
                    self._realtime_failed(conversation, error)
                    if sink.cancel.is_set():
                        # Samin stopped this turn: it ends here, interrupted; nobody answers it again.
                        result.say, result.actions = spoken(sink.said), list(sink.actions)
                        result.interrupted, result.expect_reply = True, False
                        run = _tool_run(sink.tools)
                    elif sink.committed:
                        # A tool already acted (T3, calendar, journal, the Mac), or words, audio, an action or a card
                        # went out: answering again (Claude, or a retry) would do or say it twice.
                        did = "; ".join(_clip(f"{item.get('kind')} {item.get('title') or ''}", 100)
                                        for item in sink.actions)
                        conversation.history.append((heard, " ".join(part for part in (
                            spoken(sink.said), f"(Done before the voice connection dropped: {did}.)" if did else "")
                            if part)))
                        raise AssistantError(502, "assistant_interrupted", "The voice connection dropped.",
                                             retryable=True, cache=True) from None
                    elif self.settings.brain() == "auto" and self._claude_reason() is None:
                        _LOG.info("assistant: realtime failed (%s), Claude answers", error.code)
                        run = self._claude_turn(conversation, request, heard, sink)
                    else:
                        raise unavailable(error.reason if error.reason in _UNAVAILABLE else "realtime_failed",
                                          retryable=True) from None
            else:
                run = self._claude_turn(conversation, request, heard, sink)
            conversation.history.append((heard, result.say))
            self._done(conversation, request, result, run)
        finally:
            conversation.current = None
            conversation.lock.release()

    def _realtime_failed(self, conversation: _Conversation, error: Any) -> None:
        """A realtime turn that failed: the brain pauses when OpenAI said so; a broken session is closed (the next
        turn opens a new one)."""
        if error.pause and self.realtime is not None:
            self.realtime.pause(error.pause, error.reason)
        session = conversation.realtime
        if session is not None and (not session.usable() or
                                    error.code in ("realtime_timeout", "realtime_connection_lost")):
            self._close_session(conversation, session)
        _LOG.warning("assistant: realtime turn failed (%s)", error.code)

    def _done(self, conversation: _Conversation, request: _TurnRequest, result: _TurnResult,
              run: Optional[AgentRun], *, record: bool = True) -> None:
        if result.say and record:
            message_id = f"{conversation.prefix}:{request.turn_id}"
            self._record(conversation, {"id": message_id + ":assistant", "type": "message.assistant.done",
                                        "messageId": message_id, "text": result.say,
                                        "origin": conversation_origin(conversation)})
        conversation.turns += 1
        conversation.last_at = self._clock()
        self._save()
        with self._lock:
            self._last_turn = {"ok": True, "at": _iso(self._clock()), "brain": result.brain,
                               "agentMs": result.timings.get("agent", 0),
                               "tools": len(run.tools) if run is not None else 0,
                               "toolsConnected": (run.mcp_status == "connected")
                               if run is not None and result.brain == "claude" else None}
        _LOG.info("assistant turn (%s, %s): %d tool%s, stt %d ms, %s %d ms, tts %d ms, first audio %s, audio %s%s",
                  "audio" if request.audio is not None else "announce" if request.announce is not None else "text",
                  result.brain, len(run.tools) if run else 0, "" if run is not None and len(run.tools) == 1 else "s",
                  result.timings.get("stt", 0), "agent", result.timings.get("agent", 0),
                  result.timings.get("tts", 0),
                  f"{result.timings['firstAudio']} ms" if result.timings.get("firstAudio") is not None else "none",
                  "yes" if result.audio or result.timings.get("firstAudio") is not None else "no",
                  ", interrupted" if result.interrupted else "")

    def _claude_turn(self, conversation: _Conversation, request: _TurnRequest, heard: str,
                     sink: TurnSink) -> AgentRun:
        result = sink.result
        result.brain = "claude"
        if sink.cancel.is_set():  # stopped before Claude began: it never runs (nor its tools)
            result.interrupted, result.expect_reply = True, False
            return AgentRun()
        started = time.monotonic()
        try:
            run = self._think(conversation, self._message(conversation, heard))
        finally:
            result.timings["agent"] = _ms(started)
        say = spoken(run.text) or ("Sorry, that needed more steps than I can take at once. Try asking for one thing "
                                   "at a time." if run.max_turns else
                                   "Done." if actions_from(run) else "Sorry, I don't have an answer for that.")
        self._record_tools(conversation, request.turn_id, run)
        result.say = say
        result.actions = actions_from(run)
        result.expect_reply = expects_reply(say)
        sink.say_delta(say)
        for action in result.actions:
            sink.action(action)
        if sink.cancel.is_set():
            result.interrupted, result.expect_reply = True, False
            return run
        self._voice_out(say, sink)
        return run

    def _voice_out(self, say: str, sink: TurnSink) -> None:
        """ElevenLabs: streamed PCM for a stream, an mp3 for the buffered answer."""
        result = sink.result
        started = time.monotonic()
        try:
            if sink.stream is not None:
                self.voice.stream_pcm(speakable(say), sink.audio, cancelled=sink.cancel.is_set)
                if sink.cancel.is_set():
                    result.interrupted, result.expect_reply = True, False
            else:
                audio = self.voice.speak(speakable(say))
                if audio:
                    result.audio, result.audio_mime = audio, "audio/mpeg"
        finally:
            result.timings["tts"] = _ms(started)

    def _realtime_turn(self, conversation: _Conversation, request: _TurnRequest, heard: str,
                       sink: TurnSink) -> AgentRun:
        assert _realtime is not None
        result = sink.result
        result.brain = "realtime"
        started = time.monotonic()
        with self._lock:
            notes, conversation.notes = conversation.notes[-MAX_NOTES:], []
        try:
            for attempt in (1, 2):
                session = self._session(conversation, wait=True)
                message = self._realtime_message(conversation, session, heard, notes)
                try:
                    outcome = _realtime.converse(session, [_realtime.user_item(message)], None, sink,
                                                 self._runner(conversation), sink.cancel)
                    break
                except _realtime.RealtimeError as error:
                    # The session had died while idle (ICE consent, OpenAI closed it) and nothing of this turn
                    # reached OpenAI: a new session answers, without pausing the brain or handing over to Claude.
                    if not error.stale or attempt == 2 or sink.committed or sink.cancel.is_set():
                        raise
                    _LOG.info("assistant: the realtime session had ended; a new one answers")
                    self._close_session(conversation, session)
        finally:
            result.timings["agent"] = _ms(started)
            # What ran is in the timeline also when the turn failed after it (the sink has it as it happened).
            run = _tool_run(sink.tools)
            self._record_tools(conversation, request.turn_id, run)
        if outcome.pause and self.realtime is not None:
            self.realtime.pause(outcome.pause, "realtime_response_failed")
        result.say = spoken(outcome.text)
        if not result.say and outcome.max_rounds:
            result.say = "Sorry, that needed more steps than I can take at once."
        elif not result.say and outcome.failed and outcome.tools and not outcome.interrupted:
            result.say = "Sorry, I got cut off partway through that."
        result.actions = list(outcome.actions)
        result.interrupted = outcome.interrupted
        result.expect_reply = expects_reply(result.say) and not outcome.interrupted
        if sink.stream is None:
            pcm = sink.pcm()
            if pcm:
                result.audio, result.audio_mime = _realtime.pcm_to_wav(pcm), "audio/wav"
        return run

    def _realtime_message(self, conversation: _Conversation, session: Any, heard: str, notes: List[str]) -> str:
        line = self._now_line(conversation)
        lines = []
        if session.now_minute != line:
            lines.append(line)
            session.now_minute = line
        lines += [f"[T3 update] {note}" for note in notes]
        lines.append(heard)
        return "\n".join(lines)

    def _say_line(self, conversation: _Conversation, line: str, sink: TurnSink, brain: str, *,
                  open_session: bool, context: Optional[str] = None) -> None:
        """One line said word for word (a goodbye, an announcement): by the realtime session when there is one (the
        same voice as every answer), else by ElevenLabs."""
        result = sink.result
        if brain == "realtime" and _realtime is not None and self.realtime is not None:
            session = conversation.realtime
            try:
                if open_session or (session is not None and session.usable()):
                    session = self._session(conversation, wait=True)
                    items = [_realtime.user_item(context)] if context else []
                    started = time.monotonic()
                    try:
                        outcome = _realtime.converse(session, items, _realtime.verbatim_response(line), sink, None,
                                                     sink.cancel)
                    finally:
                        result.timings["agent"] = _ms(started)
                    result.interrupted = outcome.interrupted
                    if sink.stream is None and sink.pcm():
                        result.audio, result.audio_mime = _realtime.pcm_to_wav(sink.pcm()), "audio/wav"
                    if sink.result.timings.get("firstAudio") is not None or outcome.text:
                        return
            except Exception as error:  # noqa: BLE001 - RealtimeError: ElevenLabs says it instead
                if not isinstance(error, _realtime.RealtimeError):
                    raise
                self._realtime_failed(conversation, error)
                if sink.result.timings.get("firstAudio") is not None:
                    return
        if not sink.said:  # the session may have sent some of its words before it failed: not twice
            sink.say_delta(line)
        if not sink.cancel.is_set():
            self._voice_out(line, sink)

    def _announce_turn(self, conversation: _Conversation, request: _TurnRequest, sink: TurnSink, brain: str) -> None:
        event = self.announcer.get(int(request.announce or 0))
        if event is None or event.id <= conversation.first_cursor:
            raise AssistantError(404, "announcement_not_found", "That announcement is no longer there.")
        result = sink.result
        with self._lock:
            new = event.id not in conversation.announced
            conversation.announced.add(event.id)
            conversation.cursor = max(conversation.cursor, event.id)
            note = f"{event.say} (task id {event.thread_id})"
            if brain == "realtime":  # said in the session itself, with its id: no note for the next turn
                conversation.notes = [item for item in conversation.notes if item != note]
            elif new:
                conversation.notes = (conversation.notes + [note])[-MAX_NOTES:]
        if new:
            self._record_announcement(conversation, event)
        result.say = event.say
        result.expect_reply = False
        self._say_line(conversation, event.say, sink, brain, open_session=True,
                       context=f"[T3 update] {event.say} (thread id {event.thread_id})")

    def _record_announcement(self, conversation: _Conversation, event: _Announcement) -> None:
        self._record(conversation, {"id": f"{conversation.prefix}:{conversation.id}:announce:{event.id}",
                                    "type": "host.t3_update", "text": event.say, "threadId": event.thread_id,
                                    "title": event.title, "projectTitle": event.project, "status": event.status,
                                    "kind": {"needs_you": "t3.thread.needs_approval", "done": "t3.thread.finished",
                                             "error": "t3.thread.error"}[event.kind],
                                    "origin": conversation_origin(conversation)})

    def _now_line(self, conversation: _Conversation) -> str:
        zone = getattr(self.mobile, "zone", None) or timezone.utc
        zone_name = getattr(self.mobile, "zone_name", None) or "UTC"
        moment = datetime.fromtimestamp(self._clock(), zone)
        device = {"watchos": "watch", "ios": "phone", "macos": "mac"}.get(conversation.platform, "watch")
        stamp = moment.strftime("%A, %B ") + str(moment.day) + moment.strftime(", %Y, ") + \
            str(int(moment.strftime("%I"))) + moment.strftime(":%M %p")
        return f"[Now: {stamp} {zone_name} · device: {device}]"

    def _message(self, conversation: _Conversation, heard: str) -> str:
        lines = [self._now_line(conversation)]
        with self._lock:
            notes, conversation.notes = conversation.notes[-MAX_NOTES:], []
        lines += [f"[Announced to him since his last message: {note}]" for note in notes]
        lines.append(heard)
        return "\n".join(lines)

    def _think(self, conversation: _Conversation, message: str) -> AgentRun:
        if not self._agents.acquire(blocking=False):
            raise unavailable("too_many_turns", retryable=True)
        try:
            previous = conversation.process
            if previous is not None and previous.returncode is None:
                try:  # the last turn's CLI is still writing its session: never two at once (it would fork)
                    previous.wait(timeout=PREVIOUS_EXIT_WAIT)
                except subprocess.TimeoutExpired:
                    pass
            deadline = time.monotonic() + self.agent_timeout
            for _attempt in range(3):
                progress: Dict[str, Any] = {"started": False}
                resume = conversation.started
                if deadline - time.monotonic() < 1.0:
                    raise AssistantError(504, "assistant_timeout", "Answering took too long on the Mac.",
                                         retryable=True, cache=True)
                try:
                    run = self.agent.run(message, conversation.session_id, resume=resume,
                                         prompt_file=self.agent.prompt_file_for(conversation.platform),
                                         timeout=deadline - time.monotonic(), progress=progress)
                except _SessionMissing:
                    conversation.session_id, conversation.started = str(uuid.uuid4()), False
                    continue
                except _SessionInUse:
                    conversation.started = True
                    continue
                except AssistantError:
                    if progress.get("started"):
                        conversation.started = True
                    elif not resume:
                        conversation.session_id = str(uuid.uuid4())  # never reuse an id the CLI may have half-made
                    with self._lock:
                        self._last_turn = {"ok": False, "at": _iso(self._clock())}
                    raise
                finally:
                    conversation.process = progress.get("process")
                if run.session_started:
                    conversation.started = True
                if run.mcp_status not in (None, "connected"):
                    _LOG.warning("assistant tools did not start (%s)", re.sub(r"[^a-z_]", "", run.mcp_status)[:24])
                return run
            raise unavailable("claude_failed", retryable=True)
        finally:
            self._agents.release()

    # ------------------------------------------------------------------ the sync store
    def _store(self) -> Any:
        service = getattr(self.server, "sync", None)
        return getattr(service, "store", None) if service is not None else None

    def _record(self, conversation: _Conversation, event: Dict[str, Any]) -> None:
        store = self._store()
        if store is None:
            return
        try:
            store.record_local(conversation.sync_id, event)
        except Exception:  # noqa: BLE001 - the timeline is a mirror: the turn goes on without it
            _LOG.warning("assistant: event not recorded")

    def _record_start(self, conversation: _Conversation, heard: str) -> None:
        if conversation.recorded_start:
            return
        conversation.recorded_start = True
        origin = conversation_origin(conversation)
        self._record(conversation, {"id": f"{conversation.prefix}:{conversation.id}:started:{uuid.uuid4().hex[:16]}",
                                    "type": "conversation.started", "origin": origin})
        store = self._store()
        if store is None:
            return
        label = {"watch": "Watch", "mac": "Mac"}.get(origin, "iPhone")
        try:  # titled like the R1's ("Watch: what needs me?"), never an R1 voice session
            with store._lock:  # noqa: SLF001
                store._db.execute(  # noqa: SLF001
                    "UPDATE conversations SET title = ? WHERE conversation_id = ? AND (title IS NULL OR title = '')",
                    (_clip(f"{label}: {heard}", 80), conversation.sync_id))
        except Exception:  # noqa: BLE001
            _LOG.warning("assistant: conversation title not set")

    def _record_tools(self, conversation: _Conversation, turn_id: str, run: AgentRun) -> None:
        store = self._store()
        for number, tool in enumerate(run.tools.values()):
            event: Dict[str, Any] = {"id": f"{conversation.prefix}:{turn_id}:tool:{number}", "type": "tool.completed",
                                     "tool": tool["name"], "toolCallId": f"{conversation.prefix}:{turn_id}:{number}",
                                     "arguments": tool.get("input") or {},
                                     "result": _clip(tool.get("result"), 4000) if tool.get("result") else None,
                                     "isError": bool(tool.get("isError")), "origin": conversation_origin(conversation)}
            images = tool.get("images") or []
            if images and store is not None:
                mime, data = images[0]
                try:
                    blob_id, _created = store.put_blob(data, mime, conversation.sync_id, limit=16 * 1024 * 1024)
                    event.update(blobId=blob_id, mime=mime)
                    event["result"] = "A screenshot of the Mac."
                except Exception:  # noqa: BLE001
                    _LOG.warning("assistant: screenshot not stored")
            self._record(conversation, event)

    def _end(self, conversation: _Conversation) -> None:
        if conversation.ended:
            return
        conversation.ended = True
        if conversation.recorded_start:
            self._record(conversation, {"id": f"{conversation.prefix}:{conversation.id}:ended:{uuid.uuid4().hex[:16]}",
                                        "type": "conversation.ended", "origin": conversation_origin(conversation)})
        conversation.recorded_start = False

    # ------------------------------------------------------------------ announcements, warm-up, cancel, end
    def announcements(self, handler: Any, device: Dict[str, Any]) -> Tuple[int, Dict[str, Any]]:
        if device.get("internal"):
            raise AssistantError(403, "forbidden", "Not for the assistant itself.")
        query = _query(handler)
        conversation_id = (query.get("conversationId") or [""])[0].strip()
        if not _CONVERSATION_ID.match(conversation_id):
            raise AssistantError(400, "invalid_conversation", "conversationId is required.")
        since_text = (query.get("since") or [""])[0].strip()
        since: Optional[int] = None
        if since_text:
            if not since_text.isdigit() or len(since_text) > 16:
                raise AssistantError(400, "invalid_since", "since must be the cursor of the last answer.")
            since = int(since_text)
        conversation = self._conversation(conversation_id, device)
        conversation.last_at = self._clock()
        self.announcer.scan(min_interval=0.0)  # the T3 snapshot itself is reused for a second (and single flight)
        with self._lock:
            events = [event for event in self.announcer.after(conversation.cursor)
                      if event.id not in conversation.announced and
                      (since is None or (event.id > since if since < 10 ** 11 else event.at * 1000 > since))]
            for event in events:
                conversation.announced.add(event.id)
                conversation.cursor = max(conversation.cursor, event.id)
                conversation.notes.append(f"{event.say} (task id {event.thread_id})")
            conversation.notes = conversation.notes[-MAX_NOTES:]
            cursor = conversation.cursor
        realtime = self.brain()[0] == "realtime" if events else False
        items = []
        for event in events:
            # The realtime brain says it in the session's own voice (the watch asks with {"announce": id}).
            audio = None if realtime else self.voice.speak(speakable(event.say))
            items.append({"id": event.id, "say": event.say,
                          "audio": {"mime": "audio/mpeg", "b64": base64.b64encode(audio).decode("ascii")}
                          if audio else None,
                          "kind": event.kind, "threadId": event.thread_id, "title": event.title})
            self._record_announcement(conversation, event)
        if items:
            _LOG.info("assistant announcements: %d", len(items))
        return 200, {"items": items, "cursor": cursor}

    def session(self, handler: Any, device: Dict[str, Any]) -> Tuple[int, Dict[str, Any]]:
        """Warm-up: the conversation and, for the realtime brain, its session opening in the background. Without an
        id it is the device's latest conversation that is still going (not ended, a turn within the last five
        minutes: an app relaunch keeps its warm session instead of stacking another), else a new one."""
        if device.get("internal"):
            raise AssistantError(403, "forbidden", "Not for the assistant itself.")
        body = _optional_json(handler)
        conversation_id = body.get("conversationId")
        if conversation_id is not None and (not isinstance(conversation_id, str) or
                                            (conversation_id.strip() and
                                             not _CONVERSATION_ID.match(conversation_id.strip()))):
            raise AssistantError(400, "invalid_conversation", "conversationId must be an id.")
        brain, reason = self.brain()
        if brain is None:
            raise unavailable(reason or "assistant_unavailable")
        wanted = (conversation_id or "").strip() or None
        conversation = (self._latest_conversation(device) if wanted is None else None) or \
            self._conversation(wanted, device)
        conversation.last_at = self._clock()
        ready = True
        if brain == "realtime":
            try:
                session = self._session(conversation, wait=False)
                ready = session.state == "open"
            except Exception as error:  # noqa: BLE001 - RealtimeError (the cap): the first turn decides
                if _realtime is None or not isinstance(error, _realtime.RealtimeError):
                    raise
                ready = False
        return 200, {"conversationId": conversation.id, "brain": brain, "ready": ready}

    def _latest_conversation(self, device: Dict[str, Any]) -> Optional[_Conversation]:
        device_id = str(device.get("deviceId") or "")
        now = self._clock()
        with self._lock:
            going = [item for item in self._conversations.values()
                     if item.device_id == device_id and not item.ended and now - item.last_at < self.idle_end]
        return max(going, key=lambda item: item.last_at) if going else None

    def cancel(self, handler: Any, device: Dict[str, Any]) -> Tuple[int, Dict[str, Any]]:
        """Stop the reply being made. ``turnId`` (optional) names the turn the client means: a tap on a reply that
        ended meanwhile must not stop the next turn (one typed right after it), so a cancel for any other turn than
        the current one stops nothing."""
        if device.get("internal"):
            raise AssistantError(403, "forbidden", "Not for the assistant itself.")
        body = _json_body(handler)
        conversation_id = body.get("conversationId")
        if not isinstance(conversation_id, str) or not _CONVERSATION_ID.match(conversation_id):
            raise AssistantError(400, "invalid_conversation", "conversationId is required.")
        turn_id = body.get("turnId")
        if turn_id is not None and (not isinstance(turn_id, str) or not _TURN_ID.match(turn_id.strip())):
            raise AssistantError(400, "invalid_turn", "turnId must be the turn's id.")
        with self._lock:
            found = self._conversations.get(conversation_id)
        if found is None or found.device_id != str(device.get("deviceId") or ""):
            return 200, {"ok": True, "cancelled": False}
        current = found.current  # the turn being answered and its switch, read together
        if current is None or (turn_id is not None and current[0] != turn_id.strip()):
            return 200, {"ok": True, "cancelled": False}
        switch = current[1]
        if switch.is_set():
            return 200, {"ok": True, "cancelled": False}
        switch.set()
        _LOG.info("assistant reply cancelled")
        return 200, {"ok": True, "cancelled": True}

    def end(self, handler: Any, device: Dict[str, Any]) -> Tuple[int, Dict[str, Any]]:
        if device.get("internal"):
            raise AssistantError(403, "forbidden", "Not for the assistant itself.")
        conversation_id = _json_body(handler).get("conversationId")
        if not isinstance(conversation_id, str) or not _CONVERSATION_ID.match(conversation_id):
            raise AssistantError(400, "invalid_conversation", "conversationId is required.")
        with self._lock:
            found = self._conversations.get(conversation_id)
        if found is None or found.device_id != str(device.get("deviceId") or ""):
            return 200, {"ok": True, "ended": False}
        if found.cancel is not None:
            found.cancel.set()
        self._end(found)
        self._close_session(found)
        self._save()
        return 200, {"ok": True, "ended": True}


def conversation_origin(conversation: _Conversation) -> str:
    return {"ios": "phone", "macos": "mac"}.get(conversation.platform, "watch")


def prune_sessions(folder: str, older_than: float) -> int:
    """The CLI's session files (``<uuid>.jsonl``) of the assistant's folder that are older than ``older_than``."""
    removed = 0
    try:
        names = os.listdir(folder)
    except OSError:
        return 0
    for name in names:
        if not name.endswith(".jsonl") or not _SESSION_ID.match(name[:-6]):
            continue
        path = os.path.join(folder, name)
        try:
            info = os.lstat(path)
            if stat.S_ISREG(info.st_mode) and info.st_mtime < older_than:
                os.unlink(path)
                removed += 1
        except OSError:
            continue
    return removed


def _write_private(path: str, text: str) -> None:
    """``text`` in ``path`` (0600), written to a temp file next to it and moved over (never a partial file)."""
    folder = os.path.dirname(path) or "."
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


def _iso(epoch: float) -> str:
    return datetime.fromtimestamp(epoch, timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _query(handler: Any) -> Dict[str, List[str]]:
    try:
        return parse_qs(urlsplit(handler.path).query, max_num_fields=8)
    except ValueError:
        raise AssistantError(400, "invalid_query", "Too many query parameters.") from None


def _length(handler: Any, limit: int) -> int:
    if handler.headers.get("Transfer-Encoding"):
        raise AssistantError(411, "length_required", "Send a Content-Length body.")
    raw = handler.headers.get("Content-Length")
    if raw in (None, ""):
        return 0
    try:
        length = int(raw)
    except ValueError:
        raise AssistantError(411, "length_required", "Send a Content-Length body.") from None
    if length < 0 or length > limit:
        raise AssistantError(413, "body_too_large", f"The body must be at most {limit} bytes.")
    return length


def _json_body(handler: Any) -> Dict[str, Any]:
    length = _length(handler, MAX_BODY_BYTES)
    raw = handler.rfile.read(length) if length else b""
    try:
        value = json.loads(raw.decode("utf-8")) if raw else None
    except (UnicodeDecodeError, ValueError):
        value = None
    if not isinstance(value, dict):
        raise AssistantError(400, "invalid_json", "The body must be a JSON object.")
    return value


def _optional_json(handler: Any) -> Dict[str, Any]:
    length = _length(handler, MAX_BODY_BYTES)
    raw = handler.rfile.read(length) if length else b""
    if not raw.strip():
        return {}
    try:
        value = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        raise AssistantError(400, "invalid_json", "The body must be a JSON object.") from None
    if not isinstance(value, dict):
        raise AssistantError(400, "invalid_json", "The body must be a JSON object.")
    return value


def make_service(*, installed: bool, claude: Optional[str] = None, workdir: Optional[str] = None,
                 key_file: Optional[str] = None, tts_url: Optional[str] = None, model: Optional[str] = None,
                 voice: Optional[str] = None, settings_file: Optional[str] = DEFAULT_SETTINGS_FILE,
                 agent_timeout: float = AGENT_TIMEOUT_SECONDS, tts_timeout: float = TTS_TIMEOUT_SECONDS,
                 clock: Callable[[], float] = time.time,
                 monotonic: Callable[[], float] = time.monotonic, brain: Optional[str] = None,
                 chatgpt_auth_file: Optional[str] = None, chatgpt_issuer: Optional[str] = None,
                 realtime_python: Optional[str] = None, realtime_api: Optional[str] = None) -> AssistantService:
    """The installed copy: claude found by itself, ``DEFAULT_DIR``, the voice key in ``DEFAULT_KEY_FILE``, the
    ChatGPT login in ``~/.config/samrabbit/chatgpt-auth.json`` and the realtime venv install.sh made. Any other copy
    (a checkout, a test, a temp HOME): only an explicit ``claude``, a temp folder unless ``workdir`` is given, no voice
    unless ``key_file`` is given (so it never spends ElevenLabs credits with the real key), and the realtime brain only
    with an explicit ``chatgpt_auth_file`` and ``realtime_python`` (never the real login)."""
    settings = Settings(settings_file, model=model, voice=voice, brain=brain)
    agent = ClaudeAgent(claude, search=installed, settings=settings)
    folder: Optional[str] = os.path.expanduser(workdir) if workdir else \
        (os.path.expanduser(DEFAULT_DIR) if installed else None)  # None: a temp folder, made when first needed
    if key_file:
        speech = ElevenLabsVoice(key_file, voice=settings.voice, base_url=tts_url or TTS_URL, timeout=tts_timeout,
                                 monotonic=monotonic)
    elif installed:
        speech = ElevenLabsVoice(DEFAULT_KEY_FILE, voice=settings.voice, base_url=tts_url or TTS_URL,
                                 timeout=tts_timeout, monotonic=monotonic)
    else:
        speech = ElevenLabsVoice(None, voice=settings.voice, off="voice_dev_copy", monotonic=monotonic)
    auth: Any = None
    realtime: Any = None
    if _chatgpt is not None:
        auth = _chatgpt.make_auth(installed=installed, auth_file=chatgpt_auth_file, issuer=chatgpt_issuer)
    if _realtime is not None and auth is not None:
        python = realtime_python or (os.path.join(os.path.expanduser(_realtime.DEFAULT_VENV), "bin", "python")
                                     if installed else None)
        realtime = _realtime.RealtimeBrain(auth, python=python, api_root=realtime_api or _realtime.API_ROOT,
                                           model=settings.realtime_model, voice=settings.realtime_voice)
    return AssistantService(agent, speech, workdir=folder, installed=installed, clock=clock, monotonic=monotonic,
                            agent_timeout=agent_timeout, realtime=realtime, chatgpt=auth)
