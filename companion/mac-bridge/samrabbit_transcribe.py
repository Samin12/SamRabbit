"""Speech to text on the Mac for the SamRabbit iPhone and Apple Watch apps (``POST /v1/mobile/transcribe``).

The watch (or the phone) records a short clip and sends it as the raw request body; the bridge answers with the
words: ``{text, durationMs, engine, locale}``. The words come from ``samrabbit-transcribe``, a small Swift helper
(``transcribe/samrabbit_transcribe.swift``) that ``install.sh`` compiles into the installed bridge folder. It uses
macOS's own on-device SpeechAnalyzer + SpeechTranscriber (macOS 26+): nothing leaves the Mac, no microphone is used
and there is no permission prompt (the input is a file).

* Body: ``audio/mp4`` / ``audio/x-m4a`` (an m4a, e.g. AAC from ``AVAudioRecorder``), ``audio/wav`` or ``audio/aac``
  (ADTS); at most 2 MiB and 90 s. The container is checked from the bytes (``ftyp`` at offset 4, ``RIFF....WAVE``
  or an ADTS frame) and its length read from the header before the helper runs.
* ``?lang=`` is a BCP 47 tag, made deterministic: a bare language is always the same locale (``en`` -> ``en-US``,
  ``fr`` -> ``fr-FR``, ``es`` -> ``es-ES``, ``de`` -> ``de-DE``, ...; ``DEFAULT_REGIONS``), never the Mac's own region,
  and the case is canonical (``EN_us`` -> ``en-US``). The default is ``en-US``.
* The audio is written to a private temp file (0600, in its own 0700 folder ``$TMPDIR/samrabbit-voice-<pid>-*``)
  only while the helper runs, then deleted; folders a stopped bridge left behind are removed when the bridge starts
  (``remove_leftovers``). Neither the audio nor the words are ever logged or kept.
* The helper runs in a session of its own with a deadline of its own (``--deadline``, a little under the bridge's
  45 s, so it answers ``transcribe_timeout`` and exits by itself, even if the bridge is gone); at the bridge's own
  timeout the bridge kills the helper's whole process group.
* Errors (the bridge's ``{error: {code, message, retryable}}``, with ``reason`` where it helps):
  ``transcribe_unavailable`` (503: no helper, no speech transcriber on this Mac, or the language's model is not on
  the Mac yet, which the bridge then downloads in the background), ``transcribe_permission`` (503: Speech
  Recognition is turned off for it in System Settings; ``status()`` then says ``reason: permission_denied``),
  ``transcribe_failed`` (502, or 504 when it took too long),
  ``transcribe_busy`` (503), ``unsupported_audio`` (415), ``audio_too_long`` / ``body_too_large`` (413),
  ``no_speech`` (422), ``unsupported_language`` (422) and ``invalid_lang`` (400).

Stdlib only, Python 3.9.
"""

from __future__ import annotations

import json
import logging
import os
import re
import shutil
import signal
import stat
import struct
import subprocess
import tempfile
import threading
import time
from typing import Any, Callable, Dict, List, Optional, Tuple

_HERE = os.path.dirname(os.path.abspath(__file__))
_LOG = logging.getLogger("samrabbit-bridge.transcribe")

HELPER_NAME = "samrabbit-transcribe"
MAX_AUDIO_BYTES = 2 * 1024 * 1024
MAX_AUDIO_SECONDS = 90
LENGTH_SLACK_SECONDS = 0.5  # AAC priming and padding
HELPER_TIMEOUT_SECONDS = 45.0
CHECK_TIMEOUT_SECONDS = 10.0
REAP_SECONDS = 2.0  # after a kill: how long the bridge waits for the helper's pipes to close
FOLDER_PREFIX = "samrabbit-voice-"
LEFTOVER_SECONDS = 120.0  # no recording folder lives this long (the helper is stopped after HELPER_TIMEOUT_SECONDS)
CHECK_CACHE_SECONDS = 10 * 60.0
PREPARE_TIMEOUT_SECONDS = 15 * 60.0
PREPARE_RETRY_SECONDS = 30 * 60.0
MAX_CONCURRENT = 2
BUSY_WAIT_SECONDS = 10.0
MAX_HELPER_OUTPUT = 256 * 1024
MAX_TEXT_CHARS = 8000
DEFAULT_LANGUAGE = "en-US"
ENGINES = ("SpeechTranscriber", "DictationTranscriber")

# Content-Type (without parameters) -> what the bytes must be. The four the API documents, plus common spellings.
CONTENT_TYPES: Dict[str, str] = {
    "audio/mp4": "mp4", "audio/x-m4a": "mp4", "audio/m4a": "mp4",
    "audio/wav": "wav", "audio/x-wav": "wav", "audio/wave": "wav", "audio/vnd.wave": "wav",
    "audio/aac": "aac", "audio/x-aac": "aac", "audio/aacp": "aac",
}
_SUFFIX = {"mp4": ".m4a", "wav": ".wav", "aac": ".aac"}
_ADTS_RATES = (96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350)
_LANGUAGE = re.compile(r"^[A-Za-z]{2,3}(?:[-_][A-Za-z0-9]{1,8}){0,3}$")
# A bare language as one fixed locale (never the Mac's own region), so ``en`` and ``en-US`` are the same request: one
# status check, one model download. Languages not listed stay bare (the helper finds their closest locale).
DEFAULT_REGIONS: Dict[str, str] = {
    "ar": "ar-SA", "ca": "ca-ES", "cs": "cs-CZ", "da": "da-DK", "de": "de-DE", "el": "el-GR", "en": "en-US",
    "es": "es-ES", "fi": "fi-FI", "fr": "fr-FR", "he": "he-IL", "hi": "hi-IN", "hr": "hr-HR", "hu": "hu-HU",
    "id": "id-ID", "it": "it-IT", "ja": "ja-JP", "ko": "ko-KR", "ms": "ms-MY", "nb": "nb-NO", "nl": "nl-NL",
    "no": "nb-NO", "pl": "pl-PL", "pt": "pt-BR", "ro": "ro-RO", "ru": "ru-RU", "sk": "sk-SK", "sv": "sv-SE",
    "th": "th-TH", "tr": "tr-TR", "uk": "uk-UA", "vi": "vi-VN", "wuu": "wuu-CN", "yue": "yue-CN", "zh": "zh-CN",
}
_SCRIPT_REGIONS = {"zh-Hans": "zh-CN", "zh-Hant": "zh-TW"}
_FOLDER = re.compile(r"^samrabbit-voice-(?:([0-9]{1,10})-)?[A-Za-z0-9_]{1,64}$")
_CONTROL = re.compile(r"[\x00-\x1f\x7f]")
_ERROR_DETAIL = re.compile(r"^[A-Za-z][A-Za-z0-9._]{0,63}#-?[0-9]{1,12}$")  # e.g. SFSpeechErrorDomain#2

# Helper answer code -> (HTTP status, message, retryable)
_FAILURES: Dict[str, Tuple[int, str, bool]] = {
    "transcribe_unavailable": (503, "Transcription is not available on the Mac.", False),
    "transcribe_permission": (503, "Speech Recognition is turned off for SamRabbit on the Mac (System Settings > "
                                   "Privacy & Security > Speech Recognition).", False),
    "unsupported_language": (422, "The Mac cannot transcribe that language.", False),
    "unsupported_audio": (415, "The Mac could not read that recording.", False),
    "audio_too_long": (413, f"Recordings can be at most {MAX_AUDIO_SECONDS} seconds.", False),
    "no_speech": (422, "No speech was heard in the recording.", False),
    "transcribe_failed": (502, "The Mac could not transcribe the recording.", True),
    "transcribe_timeout": (504, "Transcribing took too long on the Mac.", True),  # answered as transcribe_failed
}
_UNAVAILABLE_MESSAGES = {
    "helper_missing": "Transcription is not installed on the Mac. Run companion/mac-bridge/install.sh again (it "
                      "needs Xcode or the Command Line Tools).",
    "speech_unavailable": "This Mac has no on-device speech transcriber (it needs macOS 26 or newer).",
    "model_missing": "The speech model for that language is not on the Mac yet.",
    "model_downloading": "The Mac is downloading the speech model for that language. Try again in a minute.",
    "insufficient_resources": "The Mac is too busy to transcribe right now. Try again in a moment.",
}


class TranscribeError(Exception):
    def __init__(self, status: int, code: str, message: str, *, retryable: bool = False,
                 reason: Optional[str] = None) -> None:
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message
        self.retryable = retryable
        self.reason = reason

    def payload(self) -> Dict[str, Any]:
        error: Dict[str, Any] = {"code": self.code, "message": self.message, "retryable": self.retryable}
        if self.reason:
            error["reason"] = self.reason
        return {"error": error}


def unavailable(reason: str, *, retryable: bool = False) -> TranscribeError:
    return TranscribeError(503, "transcribe_unavailable", _UNAVAILABLE_MESSAGES.get(
        reason, _FAILURES["transcribe_unavailable"][1]), retryable=retryable, reason=reason)


# --------------------------------------------------------------------------- request checks


def content_kind(value: Optional[str]) -> str:
    """The container a Content-Type promises (``mp4``, ``wav`` or ``aac``); 415 for anything else."""
    kind = CONTENT_TYPES.get(str(value or "").split(";", 1)[0].strip().lower())
    if kind is None:
        raise TranscribeError(415, "unsupported_audio", "Send the recording as audio/mp4, audio/x-m4a, audio/wav or "
                              "audio/aac.")
    return kind


def normalize_language(value: Optional[str]) -> str:
    """``?lang=`` as one deterministic BCP 47 locale: canonical case (``en_us`` -> ``en-US``, ``zh-hant-tw`` ->
    ``zh-Hant-TW``), a bare language as its fixed locale (``DEFAULT_REGIONS``: ``en`` -> ``en-US``, ``fr`` ->
    ``fr-FR``; ``zh-Hans`` -> ``zh-CN``, ``zh-Hant`` -> ``zh-TW``); ``en-US`` when there is none."""
    if value is None or value == "":
        return DEFAULT_LANGUAGE
    if not _LANGUAGE.match(value):
        raise TranscribeError(400, "invalid_lang", "lang must be a language tag such as en-US.")
    first, *subtags = value.replace("_", "-").split("-")
    language = first.lower()
    rest = []
    for subtag in subtags:
        if len(subtag) == 4 and subtag.isalpha():
            rest.append(subtag.title())  # a script: Hant
        elif (len(subtag) == 2 and subtag.isalpha()) or (len(subtag) == 3 and subtag.isdigit()):
            rest.append(subtag.upper())  # a region: US, 419
        else:
            rest.append(subtag.lower())  # a variant
    if not rest:
        return DEFAULT_REGIONS.get(language, language)
    tag = "-".join([language, *rest])
    return _SCRIPT_REGIONS.get(tag, tag)


def _id3_length(data: bytes) -> int:
    """The size of a leading ID3v2 tag (some AAC files have one before the first frame)."""
    if len(data) < 10 or data[:3] != b"ID3":
        return 0
    size = 0
    for byte in data[6:10]:
        if byte & 0x80:
            return 0
        size = (size << 7) | byte
    return 10 + size + (10 if data[5] & 0x10 else 0)


def _adts_at(data: bytes, offset: int) -> bool:
    return len(data) >= offset + 7 and data[offset] == 0xFF and (data[offset + 1] & 0xF6) == 0xF0


def sniff(data: bytes) -> Optional[str]:
    """``mp4`` (``ftyp`` box first), ``wav`` (RIFF/WAVE) or ``aac`` (ADTS), from the bytes alone."""
    if len(data) >= 12 and data[4:8] == b"ftyp":
        return "mp4"
    if len(data) >= 12 and data[:4] == b"RIFF" and data[8:12] == b"WAVE":
        return "wav"
    if _adts_at(data, _id3_length(data)):
        return "aac"
    return None


def _wav_seconds(data: bytes) -> Optional[float]:
    position, byte_rate = 12, 0
    while position + 8 <= len(data):
        chunk, size = data[position:position + 4], struct.unpack("<I", data[position + 4:position + 8])[0]
        body = position + 8
        if chunk == b"fmt " and size >= 16 and body + 16 <= len(data):
            byte_rate = struct.unpack("<I", data[body + 8:body + 12])[0]
        elif chunk == b"data":
            if not byte_rate:
                return None
            return min(size, len(data) - body) / byte_rate  # a streaming writer may leave the size unset
        position = body + size + (size & 1)
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


def _mp4_seconds(data: bytes) -> Optional[float]:
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
                unknown = 0xFFFFFFFFFFFFFFFF
            else:
                scale, duration = struct.unpack(">II", data[body + 12:body + 20])
                unknown = 0xFFFFFFFF
            return duration / scale if scale and duration != unknown else None
    return None


def _aac_seconds(data: bytes) -> Optional[float]:
    position, samples, rate = _id3_length(data), 0, 0
    while _adts_at(data, position):
        index = (data[position + 2] >> 2) & 0x0F
        if index >= len(_ADTS_RATES):
            return None
        rate = _ADTS_RATES[index]
        length = ((data[position + 3] & 0x03) << 11) | (data[position + 4] << 3) | (data[position + 5] >> 5)
        if length < 7:
            break
        samples += 1024 * ((data[position + 6] & 0x03) + 1)
        position += length
    return samples / rate if rate else None


def audio_seconds(kind: str, data: bytes) -> Optional[float]:
    """The recording's length from its header (None when the header doesn't say; the helper checks again)."""
    try:
        return {"wav": _wav_seconds, "mp4": _mp4_seconds, "aac": _aac_seconds}[kind](data)
    except (KeyError, struct.error, ZeroDivisionError):
        return None


def check_audio(data: bytes, declared: str, *, max_seconds: int = MAX_AUDIO_SECONDS) -> Tuple[str, Optional[float]]:
    """``(container, seconds)`` for a body; 415 when it is not audio we read, 413 when it is longer than
    ``max_seconds`` (90 s; a voice note's capture allows 300). A container other than the declared one is accepted (an
    m4a sent as audio/aac is still an m4a); the bytes decide."""
    kind = sniff(data)
    if kind is None:
        raise TranscribeError(415, "unsupported_audio", "The body is not an m4a, WAV or AAC recording.")
    seconds = audio_seconds(kind, data)
    if seconds is not None and seconds > max_seconds + LENGTH_SLACK_SECONDS:
        raise TranscribeError(413, "audio_too_long", f"Recordings can be at most {max_seconds} seconds.")
    if declared != kind:
        _LOG.info("transcription body is %s, sent as %s", kind, declared)
    return kind, seconds


# --------------------------------------------------------------------------- the helper


def _child_env() -> Dict[str, str]:
    """A small, predictable environment (no inherited tokens or tool settings)."""
    env = {key: os.environ[key] for key in ("HOME", "USER", "LOGNAME", "LANG", "LC_ALL", "TMPDIR")
           if os.environ.get(key)}
    env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    return env


def _kill_group(process: "subprocess.Popen[bytes]") -> None:
    """SIGKILL to the helper's whole process group: it runs in a session of its own (``start_new_session``), so this
    reaches anything it started too. Only while the helper has not been reaped (until then its pid, and so its group
    id, cannot have been reused by another process)."""
    if process.returncode is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGKILL)
        return
    except OSError:
        pass
    try:
        process.kill()
    except OSError:
        pass


def _reap(process: "subprocess.Popen[bytes]") -> None:
    """Collects a killed helper without waiting forever (a process that left its group could hold its stdout)."""
    try:
        process.communicate(timeout=REAP_SECONDS)
        return
    except (subprocess.TimeoutExpired, OSError, ValueError):
        pass
    for stream in (process.stdout, process.stderr):
        if stream is not None:
            try:
                stream.close()
            except OSError:
                pass
    try:
        process.wait(timeout=REAP_SECONDS)
    except subprocess.TimeoutExpired:
        pass


def helper_deadline(timeout: float) -> str:
    """The helper's own ``--deadline`` (seconds) for a bridge timeout: a little earlier, so the helper answers and
    exits by itself first, and a helper whose bridge was killed never runs on."""
    return f"{max(1.0, round(float(timeout) - min(5.0, float(timeout) * 0.2), 1)):g}"


def _alive(pid: int) -> bool:
    if pid <= 0:
        return False
    if pid == os.getpid():
        return True
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except OSError:  # EPERM: it exists
        return True
    return True


def remove_leftovers(root: Optional[str] = None, *, now: Optional[float] = None,
                     min_age: float = LEFTOVER_SECONDS) -> int:
    """Removes the recording folders (``samrabbit-voice-*`` in the temp folder) a bridge that stopped in the middle of
    a transcription left behind: this user's own real folders (never a link) whose bridge process is gone, or older
    than any transcription can run (so another bridge's recording in progress is never touched). Returns how many."""
    folder = root or tempfile.gettempdir()
    moment = time.time() if now is None else now
    removed = 0
    try:
        names = os.listdir(folder)
    except OSError:
        return 0
    for name in names:
        match = _FOLDER.match(name)
        if match is None:
            continue
        path = os.path.join(folder, name)
        try:
            info = os.lstat(path)
        except OSError:
            continue
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
            continue
        owner = int(match.group(1)) if match.group(1) else 0
        if moment - info.st_mtime < min_age and (not owner or _alive(owner)):
            continue
        shutil.rmtree(path, ignore_errors=True)
        if not os.path.lexists(path):
            removed += 1
    return removed


def _not_stored() -> TranscribeError:
    return TranscribeError(502, "transcribe_failed", "The Mac could not store the recording to transcribe it.",
                           retryable=True)


def _write_private(folder: str, suffix: str, data: bytes) -> str:
    """``data`` in a new 0600 file in ``folder``; its descriptor is closed exactly once, whatever fails."""
    handle, path = tempfile.mkstemp(prefix="clip-", suffix=suffix, dir=folder)
    try:
        os.fchmod(handle, 0o600)
        view = memoryview(data)
        while view:
            view = view[os.write(handle, view):]
    finally:
        os.close(handle)
    return path


def default_helper() -> str:
    """Next to the bridge script: install.sh builds it into the installed bridge folder."""
    return os.path.join(_HERE, HELPER_NAME)


class Transcriber:
    """Runs the helper: ``status()`` for ``/health`` (cached), ``transcribe(data, kind, language)`` for the route."""

    def __init__(self, helper: Optional[str] = None, *, timeout: float = HELPER_TIMEOUT_SECONDS,
                 check_timeout: float = CHECK_TIMEOUT_SECONDS, prepare_timeout: float = PREPARE_TIMEOUT_SECONDS,
                 max_concurrent: int = MAX_CONCURRENT, busy_wait: float = BUSY_WAIT_SECONDS,
                 temp_root: Optional[str] = None, monotonic: Callable[[], float] = time.monotonic) -> None:
        self.helper = os.path.expanduser(helper) if helper else default_helper()
        self._temp_root = temp_root  # where recording folders go (default: the temp folder)
        self._timeout = min(float(timeout), HELPER_TIMEOUT_SECONDS)
        self._check_timeout = check_timeout
        self._prepare_timeout = prepare_timeout
        self._busy_wait = busy_wait
        self._monotonic = monotonic
        self._slots = threading.BoundedSemaphore(max(1, int(max_concurrent)))
        self._lock = threading.Lock()  # the state below
        self._check_lock = threading.Lock()  # one --check at a time (never held while answering a recording)
        self._status: Optional[Tuple[float, Dict[str, Any]]] = None
        self._preparing: Optional[str] = None
        self._prepare_process: Optional["subprocess.Popen[bytes]"] = None
        self._prepared_at: Dict[str, float] = {}
        self._running: Dict[str, Optional["subprocess.Popen[bytes]"]] = {}  # private folder -> its helper
        self._closed = False

    def executable(self) -> Optional[str]:
        path = self.helper
        return path if os.path.isfile(path) and os.access(path, os.X_OK) else None

    def start(self) -> None:
        """At bridge start: removes recording folders a bridge that stopped mid-transcription left behind."""
        try:
            removed = remove_leftovers(self._temp_root)
        except Exception:  # noqa: BLE001 - housekeeping never stops the bridge
            removed = 0
        if removed:
            _LOG.info("removed %d leftover recording folder%s", removed, "" if removed == 1 else "s")

    def close(self) -> None:
        """Stops a model download and any transcription still running (their whole process groups), and removes their
        recordings."""
        with self._lock:
            self._closed = True
            processes = [self._prepare_process, *self._running.values()]
            folders = list(self._running)
        for process in processes:
            if process is not None:
                _kill_group(process)
        for folder in folders:
            shutil.rmtree(folder, ignore_errors=True)

    # ------------------------------------------------------------------ running it
    def _start(self, args: List[str], cwd: str) -> "subprocess.Popen[bytes]":
        executable = self.executable()
        if executable is None:
            raise unavailable("helper_missing")
        try:
            # stderr is dropped unread: whatever a framework might print there never reaches the log.
            return subprocess.Popen([executable, *args], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                    stderr=subprocess.DEVNULL, env=_child_env(), cwd=cwd, start_new_session=True)
        except OSError:
            raise unavailable("helper_missing") from None

    def _finish(self, process: "subprocess.Popen[bytes]", timeout: float) -> Optional[Dict[str, Any]]:
        """The helper's one JSON object (None when it printed none); TimeoutExpired is re-raised after the kill."""
        try:
            out, _ = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            _kill_group(process)  # the whole group: nothing the helper started outlives the timeout
            _reap(process)
            raise
        if len(out) > MAX_HELPER_OUTPUT:
            return None
        lines = [line for line in out.decode("utf-8", errors="replace").splitlines() if line.strip()]
        try:
            value = json.loads(lines[-1]) if lines else None
        except ValueError:
            return None
        return value if isinstance(value, dict) else None

    def _run(self, args: List[str], timeout: float) -> Tuple[Optional[Dict[str, Any]], int]:
        process = self._start(args, tempfile.gettempdir())
        value = self._finish(process, timeout)
        return value, process.returncode

    # ------------------------------------------------------------------ /health
    def status(self, *, refresh: bool = False) -> Dict[str, Any]:
        """``{available, engine?, locale?, reason?}`` for the default language, checked at most every 10 minutes.
        ``reason: permission_denied`` when Speech Recognition is off for the helper (seen by the check, or by a
        transcription that failed with ``transcribe_permission``), until a later recording in any language works."""
        if self.executable() is None:
            return {"available": False, "reason": "helper_missing"}
        value = None if refresh else self._cached()
        if value is None:
            with self._check_lock:
                value = None if refresh else self._cached()  # another request may just have checked
                if value is None:
                    value = self._check()
                    with self._lock:
                        self._status = (self._monotonic(), value)
        return self._overlay(value)

    def cached_status(self) -> Optional[Dict[str, Any]]:
        """What ``status()`` answers, from what is already known (never runs the helper); None when a check is due."""
        if self.executable() is None:
            return {"available": False, "reason": "helper_missing"}
        value = self._cached()
        return None if value is None else self._overlay(value)

    def _overlay(self, value: Dict[str, Any]) -> Dict[str, Any]:
        value = dict(value)
        if not value.get("available") and value.get("reason") == "model_missing" and self._preparing:
            value["reason"] = "model_downloading"
        return value

    def _cached(self) -> Optional[Dict[str, Any]]:
        with self._lock:
            cached = self._status
        return cached[1] if cached is not None and self._monotonic() - cached[0] < CHECK_CACHE_SECONDS else None

    def _check(self) -> Dict[str, Any]:
        try:
            answer, _status = self._run(["--check", "--locale", DEFAULT_LANGUAGE, "--deadline",
                                         helper_deadline(self._check_timeout)], self._check_timeout)
        except subprocess.TimeoutExpired:
            return {"available": False, "reason": "check_timeout"}
        except TranscribeError as error:
            return {"available": False, "reason": error.reason or error.code}
        if answer and answer.get("ok") is False and answer.get("code") == "transcribe_timeout":
            return {"available": False, "reason": "check_timeout"}  # the helper's own deadline
        if not answer or answer.get("ok") is not True:
            return {"available": False, "reason": "check_failed"}
        value: Dict[str, Any] = {"available": answer.get("available") is True}
        if answer.get("engine") in ENGINES:
            value["engine"] = answer["engine"]
        if isinstance(answer.get("locale"), str) and _LANGUAGE.match(answer["locale"]):
            value["locale"] = answer["locale"]
        if answer.get("permission") in ("denied", "restricted"):
            # Speech Recognition is off for the helper (System Settings): the helper treats its failures as that.
            value.update({"available": False, "reason": "permission_denied"})
            return value
        if not value["available"]:
            reason = answer.get("reason")
            value["reason"] = reason if isinstance(reason, str) and re.match(r"^[a-z_]{1,40}$", reason) \
                else "unavailable"
        return value

    def _remember(self, value: Optional[Dict[str, Any]]) -> None:
        with self._lock:
            self._status = (self._monotonic(), value) if value is not None else None

    def _permission_works(self) -> None:
        """A recording (in a language other than the default) just worked, so Speech Recognition is allowed: a
        ``permission_denied`` the status still remembers is stale. It is dropped, so the next ``status()`` checks
        the default language again (what the recording proves about permission, not about that language's model)."""
        with self._lock:
            cached = self._status
            if cached is not None and cached[1].get("reason") == "permission_denied":
                self._status = None

    # ------------------------------------------------------------------ the model
    def _prepare_later(self, language: str) -> bool:
        """Download the language's model in the background (once at a time, at most every 30 minutes)."""
        with self._lock:
            if self._closed or self._preparing is not None:
                return self._preparing == language
            last = self._prepared_at.get(language)
            if last is not None and self._monotonic() - last < PREPARE_RETRY_SECONDS:
                return False
            self._preparing = language
        threading.Thread(target=self._prepare, args=(language,), name="samrabbit-transcribe-model",
                         daemon=True).start()
        return True

    def _prepare(self, language: str) -> None:
        outcome = "failed"
        try:
            process = self._start(["--prepare", "--locale", language, "--deadline",
                                   helper_deadline(self._prepare_timeout)], tempfile.gettempdir())
            with self._lock:
                self._prepare_process = process
            answer = self._finish(process, self._prepare_timeout)
            outcome = "ready" if answer and answer.get("ok") is True else "failed"
        except subprocess.TimeoutExpired:
            outcome = "timed out"
        except Exception:  # noqa: BLE001 - a background download must never take the bridge down
            outcome = "failed"
        finally:
            with self._lock:
                self._preparing = None
                self._prepare_process = None
                self._prepared_at[language] = self._monotonic()
            self._remember(None)
        _LOG.info("speech model download %s", outcome)

    # ------------------------------------------------------------------ the route
    def transcribe(self, data: bytes, kind: str, language: str = DEFAULT_LANGUAGE, *,
                   max_seconds: int = MAX_AUDIO_SECONDS, timeout: Optional[float] = None) -> Dict[str, Any]:
        """``{text, durationMs, engine, locale}`` for a checked body (``check_audio``); TranscribeError otherwise.
        ``max_seconds`` / ``timeout``: a longer recording's own limits (a voice note: up to 300 s, its timeout scaled
        with its length); the defaults are the watch's and the phone's 90 s and 45 s."""
        limit = self._timeout if timeout is None else max(1.0, float(timeout))
        if self.executable() is None:
            raise unavailable("helper_missing")
        if not self._slots.acquire(timeout=self._busy_wait):
            raise TranscribeError(503, "transcribe_busy", "The Mac is already transcribing. Try again in a moment.",
                                  retryable=True)
        try:
            # 0700, named after this process so a bridge starting later can tell a leftover (remove_leftovers)
            try:
                folder = tempfile.mkdtemp(prefix=f"{FOLDER_PREFIX}{os.getpid()}-", dir=self._temp_root)
            except OSError:
                raise _not_stored() from None
            with self._lock:
                self._running[folder] = None
            try:
                try:
                    path = _write_private(folder, _SUFFIX.get(kind, ".audio"), data)
                except OSError:
                    raise _not_stored() from None
                process = self._start(["--file", path, "--locale", language, "--max-seconds",
                                       str(int(max_seconds)), "--deadline", helper_deadline(limit)], folder)
                with self._lock:
                    self._running[folder] = process
                try:
                    answer = self._finish(process, limit)
                except subprocess.TimeoutExpired:
                    raise TranscribeError(504, "transcribe_failed", "Transcribing took too long on the Mac.",
                                          retryable=True) from None
            finally:
                with self._lock:
                    self._running.pop(folder, None)
                shutil.rmtree(folder, ignore_errors=True)  # the audio never outlives the request
        finally:
            self._slots.release()
        return self._answer(answer, process.returncode, language)

    def _answer(self, answer: Optional[Dict[str, Any]], status: int, language: str) -> Dict[str, Any]:
        if answer is not None and answer.get("ok") is True and isinstance(answer.get("text"), str):
            text = " ".join(_CONTROL.sub(" ", answer["text"]).split())[:MAX_TEXT_CHARS]
            if not text:
                raise TranscribeError(422, "no_speech", _FAILURES["no_speech"][1])
            duration = answer.get("durationMs")
            engine = answer.get("engine") if answer.get("engine") in ENGINES else "SpeechTranscriber"
            locale = answer.get("locale") if isinstance(answer.get("locale"), str) and \
                _LANGUAGE.match(answer["locale"]) else language
            if language == DEFAULT_LANGUAGE:
                self._remember({"available": True, "engine": engine, "locale": locale})
            else:
                self._permission_works()
            return {"text": text, "durationMs": int(duration) if isinstance(duration, (int, float)) and
                    not isinstance(duration, bool) and duration >= 0 else 0, "engine": engine, "locale": locale}
        code = answer.get("code") if answer is not None and answer.get("ok") is False else None
        if code not in _FAILURES:
            _LOG.warning("transcription helper failed (exit %s)", status)
            raise TranscribeError(502, "transcribe_failed", "The transcription helper failed on the Mac.",
                                  retryable=True)
        detail = answer.get("detail") if isinstance(answer.get("detail"), str) else ""
        if code == "transcribe_unavailable":
            reason = detail if detail in _UNAVAILABLE_MESSAGES else None
            if reason == "model_missing":
                if self._prepare_later(language):
                    raise unavailable("model_downloading", retryable=True)
                raise unavailable("model_missing")
            if language == DEFAULT_LANGUAGE:
                self._remember(None)  # /health checks again
            if reason == "insufficient_resources":
                raise unavailable(reason, retryable=True)
            raise unavailable(reason or "speech_unavailable")
        if code == "transcribe_timeout":  # the helper's own deadline: as if the bridge had stopped it
            raise TranscribeError(504, "transcribe_failed", _FAILURES[code][1], retryable=True)
        if code == "transcribe_permission":  # whatever the language: /health says so until the next check
            self._remember({"available": False, "reason": "permission_denied"})
        if code == "transcribe_failed":  # the detail is logged only as an error domain and number
            _LOG.warning("transcription failed (%s)", detail if _ERROR_DETAIL.match(detail) else "no detail")
        http, message, retryable = _FAILURES[code]
        raise TranscribeError(http, code, message, retryable=retryable)
