"""The watch's voice assistant (``/v1/mobile/assistant/*``) end to end against fakes.

A real bridge on a random loopback port (``MobileBase``: fake T3 server and CLI, fake Composio, fake Heptabase, fake
cua-driver, temp tokens), a fake speech-to-text helper, a fake Claude Code CLI (``fake_assistant_claude.py``) that
starts the real MCP server (``samrabbit_assistant_mcp.py``) and calls its tools against that bridge, and a fake
ElevenLabs server. Nothing here reaches the real Claude, ElevenLabs, T3 Code, Google Calendar, the Heptabase journal
or the live bridge.

Run: cd companion/mac-bridge && /usr/bin/python3 -m unittest tests.test_assistant -q
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
from pathlib import Path
import queue
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Dict, List, Optional, Tuple
from urllib.parse import urlsplit

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(HERE))

import samrabbit_assistant as assistant  # noqa: E402
import samrabbit_assistant_mcp as tools  # noqa: E402
import samrabbit_bridge as bridge  # noqa: E402
import samrabbit_calendar as gcal  # noqa: E402
import samrabbit_inbox as inbox  # noqa: E402
import samrabbit_t3 as t3  # noqa: E402
from test_installed_copy import DESKTOP as DEV_DESKTOP, TOKEN as DEV_TOKEN  # noqa: E402
from test_installed_copy import FakesMixin, ISOLATED, _call, _restore  # noqa: E402
from test_mac_control import UID, _console_user, _ioreg_root  # noqa: E402
from test_mobile import TOKEN, FakeHandler  # noqa: E402
from test_transcribe import WORDS, TranscribeBase, wav  # noqa: E402

KEY = "test-eleven-key-" + "k" * 24
MP3 = b"ID3\x04\x00\x00\x00\x00\x00\x00" + b"\xff\xfb\x90\x64" + b"\x00" * 400
UTTERANCE = "what needs me about the secret 7781 plan?"
REPLY = "Two tasks need you: Fix the login redirect and Pick a database."
NOW_LINE = "[Now: Thursday, October 8, 2026, 2:37 PM America/New_York · device: watch]"
FLAGS = ("--setting-sources", "", "--strict-mcp-config", "--tools", "", "--allowedTools", "mcp__samrabbit",
         "--permission-mode", "dontAsk", "--disable-slash-commands", "--max-turns", "6")
SHELL_ENV = {"PWD", "SHLVL", "_", "OLDPWD", "__CF_USER_TEXT_ENCODING"}  # /bin/sh and macOS add these


class FakeElevenLabs:
    """``POST /v1/text-to-speech/<voice>?output_format=...`` answering a small MP3. ``mode``: ok, fail (500),
    unauthorized (401), slow (``delay`` s, then ok)."""

    def __init__(self) -> None:
        self.mode = "ok"
        self.delay = 3.0
        self.requests: List[Dict[str, Any]] = []
        fake = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_args: Any) -> None:
                return

            def do_POST(self) -> None:  # noqa: N802
                length = int(self.headers.get("Content-Length") or 0)
                body = json.loads(self.rfile.read(length) or b"{}")
                parts = urlsplit(self.path)
                fake.requests.append({"path": parts.path, "query": parts.query, "body": body,
                                      "key": self.headers.get("xi-api-key"), "accept": self.headers.get("Accept")})
                if fake.mode == "slow":
                    time.sleep(fake.delay)
                if fake.mode in ("fail", "unauthorized"):
                    payload = json.dumps({"detail": {"status": "nope"}}).encode()
                    self.send_response(500 if fake.mode == "fail" else 401)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(payload)))
                    self.end_headers()
                    self.wfile.write(payload)
                    return
                self.send_response(200)
                self.send_header("Content-Type", "audio/mpeg")
                self.send_header("Content-Length", str(len(MP3)))
                self.end_headers()
                try:
                    self.wfile.write(MP3)
                except OSError:
                    pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}"

    def close(self) -> None:
        self.server.shutdown()
        self.server.server_close()


def fake_claude(bin_dir: Path, state: Path) -> Path:
    state.mkdir(exist_ok=True)
    path = bin_dir / "claude-assistant"
    path.write_text(f'#!/bin/sh\nexec "{sys.executable}" "{HERE / "fake_assistant_claude.py"}" --state "{state}" "$@"\n')
    path.chmod(0o755)
    return path


class AssistantBase(TranscribeBase):
    with_t3 = True
    agent_timeout = 15.0
    tts_timeout = 2.0

    def make_assistant(self, bin_dir: Path) -> Any:
        self.claude_state = self.root / "claude-assistant"
        self.claude = fake_claude(bin_dir, self.claude_state)
        self.eleven = FakeElevenLabs()
        self.addCleanup(self.eleven.close)
        self.key_file = self.root / "config" / "elevenlabs-key"
        self.key_file.write_text(KEY + "\n")
        self.key_file.chmod(0o600)
        self.settings_file = self.root / "config" / "assistant.json"
        self.workdir = self.root / "assistant"
        return assistant.make_service(installed=False, claude=str(self.claude), workdir=str(self.workdir),
                                      key_file=str(self.key_file), tts_url=self.eleven.url,
                                      settings_file=str(self.settings_file), agent_timeout=self.agent_timeout,
                                      tts_timeout=self.tts_timeout, clock=self.clock.time)

    def setUp(self) -> None:
        super().setUp()
        self.watch = self.pair("watchos", "Sam's Watch")["token"]

    # ------------------------------------------------------------------ helpers
    def script(self, *steps: Dict[str, Any]) -> None:
        (self.claude_state / "script.json").write_text(json.dumps(list(steps)))

    def claude_calls(self) -> List[Dict[str, Any]]:
        path = self.claude_state / "calls.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def say(self, text: str, *, conversation: Optional[str] = None, turn: Optional[str] = None,
            token: Optional[str] = None) -> Tuple[int, Dict[str, Any]]:
        body: Dict[str, Any] = {"text": text, "turnId": turn or str(uuid.uuid4())}
        if conversation:
            body["conversationId"] = conversation
        return self.call("POST", "/v1/mobile/assistant/turn", body, token=token or self.watch)

    def speak(self, audio: bytes, *, conversation: str = "", turn: Optional[str] = None,
              content_type: str = "audio/wav") -> Tuple[int, Dict[str, Any]]:
        status, _headers, raw = self.request("POST", "/v1/mobile/assistant/turn", raw=audio, token=self.watch,
                                             headers={"Content-Type": content_type,
                                                      "X-SamRabbit-Conversation": conversation,
                                                      "X-SamRabbit-Turn": turn or str(uuid.uuid4()),
                                                      "X-SamRabbit-Device-Time": "2026-10-08T14:37:40-04:00"})
        return status, json.loads(raw) if raw else {}

    def poll(self, conversation: str, since: Optional[int] = None) -> Dict[str, Any]:
        query = f"?conversationId={conversation}" + (f"&since={since}" if since is not None else "")
        status, value = self.call("GET", "/v1/mobile/assistant/announcements" + query, token=self.watch)
        self.assertEqual(200, status, value)
        return value

    def events(self, conversation: str) -> List[Dict[str, Any]]:
        store = self.server.sync.store
        return [json.loads(payload) for _cursor, payload in store.events_after(0, 500, "watch-" + conversation)]

    def assert_clean_log(self, *extra: str) -> None:
        text = self.log.getvalue()
        for secret in (UTTERANCE, "7781", REPLY, KEY, self.watch, self.phone, *extra):
            self.assertNotIn(secret, text)
        token_file = self.workdir / "assistant-token"
        if token_file.exists():
            self.assertNotIn(token_file.read_text().strip(), text)

    def wait_for(self, condition: Any, seconds: float = 15.0) -> None:
        deadline = time.monotonic() + seconds
        while not condition():
            if time.monotonic() > deadline:
                self.fail("timed out")
            time.sleep(0.05)


# ====================================================================== turns


class TurnTest(AssistantBase):
    def test_a_text_turn_runs_the_isolated_agent_with_its_tools_and_speaks_with_jarvis(self) -> None:
        self.script({"tools": [{"name": "get_status", "arguments": {}}], "reply": REPLY})
        status, value = self.say(UTTERANCE)
        self.assertEqual(200, status, value)
        self.assertEqual({"conversationId", "turnId", "heard", "say", "audio", "expectReply", "endConversation",
                          "actions", "timings", "brain"}, set(value))
        self.assertEqual("claude", value["brain"], "ChatGPT is not connected: the Claude brain answers")
        self.assertEqual((UTTERANCE, REPLY, False, False, []),
                         (value["heard"], value["say"], value["expectReply"], value["endConversation"],
                          value["actions"]))
        self.assertEqual({"mime": "audio/mpeg", "b64": base64.b64encode(MP3).decode()}, value["audio"])
        self.assertEqual({"stt", "agent", "tts"}, set(value["timings"]))
        self.assertTrue(all(isinstance(item, int) and item >= 0 for item in value["timings"].values()))
        [call] = self.claude_calls()
        args = call["args"]
        # The exact isolation flags, the session, the model, the prompt files.
        self.assertEqual("-p", args[0])
        for flag, following in zip(FLAGS[::1], FLAGS[1:] + ("",)):
            if flag.startswith("--") and following != "" and not following.startswith("--"):
                self.assertEqual(following, args[args.index(flag) + 1], flag)
        self.assertEqual("", args[args.index("--setting-sources") + 1])
        self.assertEqual("", args[args.index("--tools") + 1])
        for flag in ("--strict-mcp-config", "--disable-slash-commands", "--verbose"):
            self.assertIn(flag, args)
        self.assertEqual("stream-json", args[args.index("--output-format") + 1])
        self.assertEqual("claude-haiku-5-5", call["model"])
        self.assertNotIn("--bare", args)
        self.assertNotIn("--safe-mode", args)
        self.assertNotIn("--append-system-prompt", args)
        self.assertIsNone(call["session"]["resume"])
        self.assertRegex(call["session"]["new"], r"^[0-9a-f-]{36}$")
        self.assertEqual(str(self.workdir / "mcp.json"), args[args.index("--mcp-config") + 1])
        self.assertEqual(assistant.SYSTEM_PROMPT, call["systemPrompt"])
        self.assertNotIn(UTTERANCE, " ".join(args), "the utterance goes in on stdin, never in argv")
        self.assertEqual(f"{NOW_LINE}\n{UTTERANCE}", call["stdin"])
        # Its own empty folder and a minimal environment.
        self.assertEqual(os.path.realpath(self.workdir / "cwd"), os.path.realpath(call["cwd"]))
        self.assertEqual([], call["cwdEntries"])
        self.assertEqual(set(), set(call["envKeys"]) - set(assistant.CLAUDE_ENV_KEYS) - {"PATH"} -
                         set(assistant.CLAUDE_FLAGS_ENV) - SHELL_ENV)
        self.assertNotIn("SAMRABBIT_TEST_SECRET", call["envKeys"])
        self.assertEqual({"PATH": assistant.CLAUDE_PATH, "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
                          "CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1", "DISABLE_AUTOUPDATER": "1"},
                         {key: item for key, item in call["env"].items() if key != "HOME"})
        # The MCP config: private, only SamRabbit's server, the token in a 0600 file (never in the config or argv).
        self.assertEqual(0o600, call["mcpMode"])
        self.assertEqual(0o700, stat.S_IMODE(self.workdir.stat().st_mode))
        server = call["mcpConfig"]["mcpServers"]
        self.assertEqual(["samrabbit"], list(server))
        self.assertEqual((sys.executable, ["-I", assistant.MCP_SCRIPT]), (server["samrabbit"]["command"],
                                                                          server["samrabbit"]["args"]))
        env = server["samrabbit"]["env"]
        self.assertEqual(f"http://127.0.0.1:{self.port}", env["SAMRABBIT_ASSISTANT_URL"])
        token_file = Path(env["SAMRABBIT_ASSISTANT_TOKEN_FILE"])
        self.assertEqual(0o600, stat.S_IMODE(token_file.stat().st_mode))
        self.assertNotIn(token_file.read_text().strip(), json.dumps(call["mcpConfig"]))
        # The MCP exchange: server/discover answered at once with method-not-found, then the tools.
        mcp = call["mcp"]
        self.assertEqual(-32601, mcp["discover"]["error"]["code"])
        self.assertLess(mcp["discoverMs"], 2000)
        self.assertEqual("2025-11-25", mcp["initialize"]["result"]["protocolVersion"])
        self.assertEqual("samrabbit", mcp["initialize"]["result"]["serverInfo"]["name"])
        self.assertEqual(sorted(tools.TOOL_NAMES), sorted(mcp["tools"]))
        self.assertTrue(mcp["schemasOk"])
        [tool_call] = mcp["calls"]
        self.assertFalse(tool_call["isError"])
        status_value = json.loads(tool_call["text"])
        self.assertEqual((2, 3), (status_value["tasks"]["needsYouCount"], status_value["tasks"]["workingCount"]))
        self.assertEqual({"Fix the login redirect", "Pick a database"},
                         {item["title"] for item in status_value["tasks"]["needsYou"]})
        # ElevenLabs: the Jarvis voice, Flash v2.5, mp3 44.1 kHz 64 kbps, the key from its file.
        [tts] = self.eleven.requests
        self.assertEqual(("/v1/text-to-speech/sI8FqE1zOcqXDhRwCwAx", "output_format=mp3_44100_64", KEY),
                         (tts["path"], tts["query"], tts["key"]))
        self.assertEqual({"text": "Two tasks need you: Fix the login redirect and Pick a database.",
                          "model_id": "eleven_flash_v2_5",
                          "voice_settings": {"stability": 0.5, "similarity_boost": 0.75, "style": 0}}, tts["body"])
        self.assertIn("POST /v1/mobile/assistant/turn 200", self.log.getvalue())
        self.assert_clean_log()

    def test_turns_resume_the_conversations_session_and_report_what_they_did(self) -> None:
        self.script({"tools": [{"name": "start_task", "arguments": {"text": "Book a table for two at seven"}}],
                     "reply": "Okay, I started that in Hermes."},
                    {"reply": "It just started."},
                    {"reply": "Hi."})
        status, first = self.say("book a table for two at seven")
        self.assertEqual(200, status, first)
        [action] = first["actions"]
        self.assertEqual("task_started", action["kind"])
        self.assertEqual("Hermes", action["project"])
        self.assertTrue(action["threadId"])
        self.assertTrue(action["title"])
        created = [item for item in self.fake_t3.dispatched if item["type"] == "thread.create"]
        self.assertEqual(1, len(created), "the task went to the (fake) T3")
        self.assertEqual(action["threadId"], created[0]["threadId"])
        status, second = self.say("is it done?", conversation=first["conversationId"])
        self.assertEqual(200, status, second)
        self.assertEqual(first["conversationId"], second["conversationId"])
        status, other = self.say("hello")
        self.assertEqual(200, status, other)
        self.assertNotEqual(first["conversationId"], other["conversationId"])
        calls = self.claude_calls()
        session = calls[0]["session"]["new"]
        self.assertEqual({"new": None, "resume": session}, calls[1]["session"], "the same conversation resumes")
        self.assertNotIn(calls[2]["session"]["new"], (None, session), "another conversation, another session")
        self.assertIn("--resume", calls[1]["args"])

    def test_an_audio_turn_is_transcribed_first(self) -> None:
        self.script({"reply": "Sure."})
        body = wav(1.5)
        status, value = self.speak(body)
        self.assertEqual(200, status, value)
        self.assertEqual((WORDS, "Sure."), (value["heard"], value["say"]))
        [helper] = self.helper_calls()
        self.assertEqual((len(body), hashlib.sha256(body).hexdigest()), (helper["size"], helper["sha256"]))
        self.assertEqual("en-US", helper["args"][helper["args"].index("--locale") + 1])
        self.assert_gone(helper)
        self.assertTrue(self.claude_calls()[0]["stdin"].endswith("\n" + WORDS))
        status, value = self.speak(b"not audio at all" * 10, conversation=value["conversationId"])
        self.assertEqual((415, "unsupported_audio"), (status, value["error"]["code"]), "the bytes decide")
        status, value = self.speak(wav(61, rate=8000, width=1))
        self.assertEqual((413, "audio_too_long"), (status, value["error"]["code"]))
        self.assert_clean_log(WORDS)

    def test_nothing_heard_keeps_listening_without_the_agent(self) -> None:
        self.fake("mode", "no_speech")
        status, value = self.speak(wav(1.0))
        self.assertEqual(200, status, value)
        self.assertEqual({"heard": "", "say": "", "audio": None, "expectReply": True, "endConversation": False,
                          "actions": []}, {key: value[key] for key in ("heard", "say", "audio", "expectReply",
                                                                       "endConversation", "actions")})
        for noise in ("", "uh", "Hmm.", "um, er"):
            with self.subTest(noise=noise):
                status, value = self.say(noise)
                self.assertEqual((200, "", True), (status, value["say"], value["expectReply"]))
        self.assertEqual([], self.claude_calls(), "the agent never ran")
        self.assertEqual([], self.eleven.requests, "nothing was synthesized")
        self.assertEqual([], self.events(value["conversationId"]), "nothing was recorded")

    def test_a_goodbye_ends_the_conversation_without_the_agent(self) -> None:
        self.script({"reply": "Nothing needs you right now. Want me to check the calendar?"})
        status, first = self.say("what needs me?")
        self.assertEqual((200, True), (status, first["expectReply"]), "it asked a question")
        for goodbye, say in (("thanks, that's all", "You're welcome. Talk soon."), ("bye", "Okay, talk soon.")):
            with self.subTest(goodbye=goodbye):
                status, value = self.say(goodbye, conversation=first["conversationId"])
                self.assertEqual(200, status, value)
                self.assertEqual((True, False, say), (value["endConversation"], value["expectReply"], value["say"]))
                self.assertIsNotNone(value["audio"])
        self.assertEqual(1, len(self.claude_calls()))
        types = [event["type"] for event in self.events(first["conversationId"])]
        self.assertEqual("conversation.ended", types[types.index("message.assistant.done", 3) + 1])
        self.assertEqual(2, types.count("conversation.started"), "talking again after a goodbye starts it again")

    def test_the_agents_failures_are_honest_errors(self) -> None:
        for error, code, reason in (("busy", "assistant_unavailable", "claude_busy"),
                                    ("signed_out", "assistant_unavailable", "claude_signed_out"),
                                    ("model", "assistant_unavailable", "model_unavailable"),
                                    ("crash", "assistant_unavailable", "claude_failed")):
            with self.subTest(error=error):
                self.script({"error": error})
                status, value = self.say("what needs me?")
                self.assertEqual((503, code, reason), (status, value["error"]["code"], value["error"]["reason"]))
        self.script({"error": "max_turns"})
        status, value = self.say("do ten things")
        self.assertEqual(200, status, value)
        self.assertIn("more steps", value["say"], "a spoken fallback, never a claim that it worked")

    def test_a_lost_session_starts_a_new_one(self) -> None:
        self.script({"reply": "One."}, {"reply": "unused", "lose_sessions": True}, {"reply": "Two."})
        status, first = self.say("one")
        status, second = self.say("two", conversation=first["conversationId"])
        self.assertEqual((200, "Two."), (status, second["say"]))
        calls = self.claude_calls()
        self.assertEqual(("missing", "ran"), (calls[1]["outcome"], calls[2]["outcome"]))
        self.assertIsNotNone(calls[2]["session"]["new"], "resume failed: a new session")
        self.assertNotEqual(calls[0]["session"]["new"], calls[2]["session"]["new"])

    def test_bad_requests(self) -> None:
        for body, code in (({"text": "hi"}, "invalid_turn"), ({"text": "hi", "turnId": "x" * 200}, "invalid_turn"),
                           ({"text": "hi", "turnId": "t1", "conversationId": "../etc"}, "invalid_conversation"),
                           ({"text": 5, "turnId": "t1"}, "invalid_text")):
            with self.subTest(body=body):
                status, value = self.call("POST", "/v1/mobile/assistant/turn", body, token=self.watch)
                self.assertEqual((400, code), (status, value["error"]["code"]))
        status, value = self.call("POST", "/v1/mobile/assistant/turn", raw=b"hello", token=self.watch,
                                  headers={"Content-Type": "text/plain"})
        self.assertEqual((415, "unsupported_media"), (status, value["error"]["code"]))
        status, value = self.call("POST", "/v1/mobile/assistant/turn", {"text": "hi", "turnId": "t1"})
        self.assertEqual(401, status, "a paired device's token is required")
        handler = FakeHandler("8.8.8.8", "/v1/mobile/assistant/turn", {"Authorization": "Bearer " + self.watch},
                              json.dumps({"text": "hi", "turnId": "t1"}).encode())
        self.service.serve(handler, "POST", "/v1/mobile/assistant/turn")
        self.assertEqual(403, handler.status, "LAN and Tailscale peers only")
        status, first = self.say("hi")
        status, value = self.say("hi", conversation=first["conversationId"], token=self.phone)
        self.assertEqual((404, "conversation_not_found"), (status, value["error"]["code"]),
                         "another device cannot join this watch's conversation")


class TimeoutTest(AssistantBase):
    agent_timeout = 2.0
    tts_timeout = 1.0

    def test_the_agent_times_out_and_its_whole_process_group_is_killed(self) -> None:
        self.script({"child": True, "sleep": 30, "reply": "never"}, {"reply": "Back again."})
        turn = str(uuid.uuid4())
        started = time.monotonic()
        status, value = self.say("what needs me?", turn=turn)
        self.assertLess(time.monotonic() - started, 10.0)
        self.assertEqual((504, "assistant_timeout", True),
                         (status, value["error"]["code"], value["error"]["retryable"]))
        child = int((self.claude_state / "child.pid").read_text())
        leader = self.claude_calls()[0]["pid"]

        def gone(pid: int) -> bool:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return True
            except PermissionError:
                return False
            # a zombie of ours is still "there" until reaped; /bin/sleep is not our child
            return False

        self.wait_for(lambda: gone(child) and gone(leader), 10.0)
        status, again = self.say("what needs me?", turn=turn)
        self.assertEqual((504, "assistant_timeout"), (status, again["error"]["code"]),
                         "a retry of the timed-out turn gets the same answer (it may have acted)")
        self.assertEqual(1, len(self.claude_calls()), "without running the agent again")
        status, value = self.say("hello again", conversation=None)
        self.assertEqual((200, "Back again."), (status, value["say"]))

    def test_slow_speech_to_text_and_voice_answer_within_their_limits(self) -> None:
        self.script({"reply": "Okay."})
        self.eleven.mode = "slow"
        started = time.monotonic()
        status, value = self.say("hi there")
        self.assertEqual(200, status, value)
        self.assertIsNone(value["audio"], "the voice took too long: the watch speaks it itself")
        self.assertLess(value["timings"]["tts"], 2500)
        self.assertLess(time.monotonic() - started, 8.0)


class VoiceTest(AssistantBase):
    def test_a_failing_voice_answers_without_audio(self) -> None:
        self.script({"reply": "Okay."})
        self.eleven.mode = "fail"
        status, value = self.say("hi there")
        self.assertEqual((200, "Okay.", None), (status, value["say"], value["audio"]))
        self.eleven.mode = "unauthorized"
        status, value = self.say("hi again")
        self.assertEqual((200, None), (status, value["audio"]))
        requests = len(self.eleven.requests)
        self.server._health = None  # noqa: SLF001
        health = self.call("GET", "/health", token=TOKEN)[1]["assistant"]
        self.assertEqual((False, "key_rejected"), (health["voice"]["available"], health["voice"]["reason"]))
        self.assertTrue(health["available"], "the assistant itself still works")
        self.eleven.mode = "ok"
        status, value = self.say("and again")
        self.assertEqual((200, None), (status, value["audio"]))
        self.assertEqual(requests, len(self.eleven.requests), "a rejected key pauses the voice instead of retrying")
        self.assert_clean_log()

    def test_numbers_are_said_in_words(self) -> None:
        self.script({"reply": "You have 3 meetings; the next is at 2:30 PM, 50% booked."})
        status, value = self.say("how many meetings?")
        self.assertEqual("You have 3 meetings; the next is at 2:30 PM, 50% booked.", value["say"],
                         "the text stays as written (the watch's own voice reads it fine)")
        self.assertEqual("You have three meetings; the next is at two thirty PM, fifty percent booked.",
                         self.eleven.requests[0]["body"]["text"])

    def test_settings_choose_the_model_and_the_voice(self) -> None:
        self.script({"reply": "Okay."})
        self.settings_file.write_text(json.dumps({"model": "claude-sonnet-5-5", "voice": "abcdefgh12345678"}))
        self.say("hi")
        self.assertEqual("claude-sonnet-5-5", self.claude_calls()[-1]["model"])
        self.assertEqual("/v1/text-to-speech/abcdefgh12345678", self.eleven.requests[-1]["path"])
        self.assertEqual("claude-sonnet-5-5", self.call("GET", "/v1/mobile/summary", token=self.watch)[1]
                         ["assistant"]["model"])
        self.settings_file.write_text(json.dumps({"assistant": {"model": "not a model"}}))
        self.say("hi")
        self.assertEqual("claude-haiku-5-5", self.claude_calls()[-1]["model"], "a bad value falls back")


class IdempotencyTest(AssistantBase):
    def test_a_retried_turn_gets_the_same_answer_and_runs_once(self) -> None:
        self.script({"tools": [{"name": "calendar_block", "arguments": {"minutes": 30}}],
                     "reply": "Blocked thirty minutes."})
        turn = str(uuid.uuid4())
        status, first = self.say("block thirty minutes", turn=turn)
        self.assertEqual(200, status, first)
        status, again = self.say("block thirty minutes", turn=turn)
        self.assertEqual((200, first), (status, again))
        self.assertEqual(1, len(self.claude_calls()))
        writes = [call for call in self.composio_calls() if call.get("slug") == "GOOGLECALENDAR_CREATE_EVENT"]
        self.assertEqual(1, len(writes), "the calendar was changed once")
        [action] = first["actions"]
        self.assertEqual(("event_created", "Focus"), (action["kind"], action["title"]))

    def test_a_retry_that_arrives_while_the_turn_runs_waits_for_it(self) -> None:
        self.script({"sleep": 1.5, "reply": "Done waiting."})
        turn = str(uuid.uuid4())
        results: "queue.Queue[Tuple[int, Dict[str, Any]]]" = queue.Queue()
        first = threading.Thread(target=lambda: results.put(self.say("wait", turn=turn)))
        first.start()
        self.wait_for(lambda: len(self.claude_calls()) == 1)
        second = self.say("wait", turn=turn)
        first.join(timeout=20)
        self.assertEqual(second, results.get(timeout=1))
        self.assertEqual((200, "Done waiting."), (second[0], second[1]["say"]))
        self.assertEqual(1, len(self.claude_calls()))

    def test_one_turn_per_conversation_at_a_time(self) -> None:
        self.script({"reply": "First."}, {"sleep": 2, "reply": "Slow."}, {"reply": "Other."})
        status, first = self.say("start")
        conversation = first["conversationId"]
        results: "queue.Queue[Tuple[int, Dict[str, Any]]]" = queue.Queue()
        slow = threading.Thread(target=lambda: results.put(self.say("slow one", conversation=conversation)))
        slow.start()
        self.wait_for(lambda: len(self.claude_calls()) == 2)
        status, value = self.say("meanwhile", conversation=conversation)
        self.assertEqual((409, "assistant_busy", True), (status, value["error"]["code"], value["error"]["retryable"]))
        status, value = self.say("another conversation")
        self.assertEqual((200, "Other."), (status, value["say"]), "other conversations are not held up")
        slow.join(timeout=20)
        self.assertEqual((200, "Slow."), (results.get(timeout=1)[0], "Slow."))


# ====================================================================== announcements


class AnnouncementsTest(AssistantBase):
    def change(self, thread_id: str, **fields: Any) -> None:
        with self.fake_t3.lock:
            thread = self.fake_t3.get_thread(thread_id)
            for key, value in fields.items():
                if isinstance(value, dict) and isinstance(thread.get(key), dict):
                    thread[key].update(value)
                else:
                    thread[key] = value
        self.hub.invalidate()

    def test_tasks_that_need_him_finish_or_fail_are_announced_once(self) -> None:
        self.script({"reply": "Okay."}, {"reply": "Approving it?"})
        status, first = self.say("hello")
        conversation = first["conversationId"]
        self.assertEqual({"items": [], "cursor": 0}, self.poll(conversation), "nothing old is announced")
        self.change("t-running", session={"status": "ready", "activeTurnId": None}, planProgress=None,
                    latestTurn={"state": "completed", "completedAt": "2026-10-08T13:10:00.000Z"},
                    updatedAt="2026-10-08T13:10:00.000Z")
        self.change("t-new", hasPendingApprovals=True, session={"threadId": "t-new", "status": "running",
                                                                "activeTurnId": "turn-x", "lastError": None},
                    latestTurn={"turnId": "turn-x", "state": "running", "requestedAt": "2026-10-08T13:11:00.000Z"},
                    updatedAt="2026-10-08T13:11:00.000Z")
        value = self.poll(conversation)
        items = {item["threadId"]: item for item in value["items"]}
        self.assertEqual({"t-running", "t-new"}, set(items))
        self.assertEqual(("done", "“Run the test suite” in SamRabbit is done."),
                         (items["t-running"]["kind"], items["t-running"]["say"]))
        self.assertEqual(("needs_you", "“Draft for later” in Hermes needs your approval."),
                         (items["t-new"]["kind"], items["t-new"]["say"]))
        self.assertEqual({"mime": "audio/mpeg", "b64": base64.b64encode(MP3).decode()}, items["t-new"]["audio"])
        self.assertEqual({"id", "say", "audio", "kind", "threadId", "title"}, set(items["t-new"]))
        cursor = value["cursor"]
        self.assertEqual([], self.poll(conversation)["items"], "announced once")
        self.assertEqual([], self.poll(conversation, since=0)["items"], "even when asked again from the start")
        self.assertEqual([], self.poll(conversation, since=cursor)["items"])
        status, other = self.say("hi")
        self.assertEqual([], self.poll(other["conversationId"])["items"], "a new conversation hears only new things")
        self.change("t-input", hasPendingUserInput=False, session={"status": "error", "lastError": "boom"},
                    updatedAt="2026-10-08T13:12:00.000Z")
        self.assertEqual(["“Pick a database” in Website ran into a problem."],
                         [item["say"] for item in self.poll(other["conversationId"])["items"]])
        # The next turn tells the agent what was announced, so "approve it" means that task.
        self.say("approve it", conversation=conversation)
        stdin = self.claude_calls()[-1]["stdin"]
        self.assertIn("[Announced to him since his last message: “Draft for later” in Hermes needs your approval. "
                      "(task id t-new)]", stdin)
        self.assertTrue(stdin.endswith("\napprove it"))
        recorded = [event for event in self.events(conversation) if event["type"] == "host.t3_update"]
        self.assertEqual({"t-running", "t-new"}, {event["threadId"] for event in recorded})
        status, value = self.call("GET", "/v1/mobile/assistant/announcements?conversationId=x", token=self.watch)
        self.assertEqual((400, "invalid_conversation"), (status, value["error"]["code"]))

    def test_a_bridge_without_t3_announces_nothing(self) -> None:
        self.service.t3 = t3.UnavailableHub("t3_dev_copy", "dev")
        self.assertEqual([], self.poll("c-without-t3")["items"])


# ====================================================================== the sync store


class SyncTest(AssistantBase):
    def test_turns_are_recorded_as_a_watch_conversation(self) -> None:
        self.script({"tools": [{"name": "get_status", "arguments": {}}], "reply": REPLY})
        status, value = self.say(UTTERANCE)
        conversation = value["conversationId"]
        events = self.events(conversation)
        self.assertEqual(["conversation.started", "message.user", "tool.completed", "message.assistant.done"],
                         [event["type"] for event in events])
        self.assertEqual({"watch"}, {event["origin"] for event in events})
        self.assertEqual(UTTERANCE, events[1]["text"])
        self.assertEqual(("get_status", {}, False), (events[2]["tool"], events[2]["arguments"], events[2]["isError"]))
        self.assertEqual(2, json.loads(events[2]["result"])["tasks"]["needsYouCount"])
        self.assertEqual(REPLY, events[3]["text"])
        # The desktop app and the iPhone's Chats list it.
        status, listing = self.call("GET", "/v1/sync/conversations", desktop=True)
        found = next(item for item in listing["conversations"] if item["conversationId"] == "watch-" + conversation)
        self.assertEqual(("Watch: " + UTTERANCE, REPLY), (found["title"], found["preview"]))
        status, mine = self.call("GET", "/v1/mobile/conversations", token=self.phone)
        self.assertIn("watch-" + conversation, [item["conversationId"] for item in mine["conversations"]])
        summary = self.call("GET", "/v1/mobile/summary", token=self.phone)[1]
        self.assertFalse(summary["r1"]["live"], "a watch conversation is not the R1")
        # A conversation nobody spoke in for a while is recorded as ended.
        self.clock.advance(assistant.IDLE_END_SECONDS + 1)
        self.assistant.sweep()
        self.assertEqual("conversation.ended", self.events(conversation)[-1]["type"])

    def test_mac_look_is_an_image_the_model_sees_and_the_timeline_keeps(self) -> None:
        self.script({"tools": [{"name": "mac_look", "arguments": {}}], "reply": "Your editor is open."})
        status, value = self.say("what's on my screen?")
        self.assertEqual(200, status, value)
        [look] = self.claude_calls()[0]["mcp"]["calls"]
        self.assertEqual((False, ["image", "text"], ["image/jpeg"]), (look["isError"], look["types"],
                                                                      look["mimeTypes"]))
        [tool] = [event for event in self.events(value["conversationId"]) if event["type"] == "tool.completed"]
        self.assertTrue(tool["blobId"].startswith("sha256:"))
        self.assertEqual("image/jpeg", tool["mime"])
        self.assertIsNotNone(self.server.sync.store.blob(tool["blobId"][7:]))
        # Locked: the model is told so in words.
        state = json.loads((self.cua_dir / "state.json").read_text())
        state["ioreg"] = _ioreg_root(_console_user(UID, locked=True), console_locked=True)
        (self.cua_dir / "state.json").write_text(json.dumps(state))
        self.script({"tools": [{"name": "mac_look", "arguments": {}}], "reply": "Your Mac is locked."})
        status, value = self.say("and now?")
        look = self.claude_calls()[-1]["mcp"]["calls"][0]
        self.assertEqual(["text"], look["types"])

    def test_a_visual_from_the_watch_goes_into_the_watch_conversation(self) -> None:
        self.script({"tools": [{"name": "generate_ui", "arguments": {"prompt": "a chart of my week"}}],
                     "reply": "It will appear on your phone and Mac."})
        status, value = self.say("make a chart of my week")
        [action] = value["actions"]
        self.assertEqual(("ui_generated", "a chart of my week"), (action["kind"], action["title"]))
        self.assertTrue(action["artifactId"].startswith("ui_"))
        meta = self.genui.store.meta(action["artifactId"])
        self.assertEqual("watch-" + value["conversationId"], meta["conversationId"])
        status, listing = self.call("GET", "/v1/sync/conversations", desktop=True)
        self.assertNotIn("Phone", [item["title"] for item in listing["conversations"]], "not the Phone one")


# ====================================================================== the MCP server on its own


class McpServerTest(AssistantBase):
    def start_server(self, *, token: Optional[str] = None) -> Any:
        self.assistant.prepare()
        token_file = self.workdir / "assistant-token"
        if token is not None:
            token_file = self.root / "wrong-token"
            token_file.write_text(token)
        process = subprocess.Popen([sys.executable, "-I", assistant.MCP_SCRIPT], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   env={"PATH": "/usr/bin:/bin", "SAMRABBIT_ASSISTANT_URL": self.base,
                                        "SAMRABBIT_ASSISTANT_TOKEN_FILE": str(token_file)})
        self.addCleanup(lambda: (process.kill(), process.wait(), process.stdout.close(), process.stderr.close(),
                                 process.stdin.close()))
        return process

    @staticmethod
    def rpc(process: Any, message: Any) -> Dict[str, Any]:
        process.stdin.write(((message if isinstance(message, str) else json.dumps(message)) + "\n").encode())
        process.stdin.flush()
        return json.loads(process.stdout.readline())

    def test_the_protocol(self) -> None:
        process = self.start_server()
        started = time.monotonic()
        discover = self.rpc(process, {"jsonrpc": "2.0", "id": "server-discover-probe-1", "method": "server/discover"})
        self.assertLess(time.monotonic() - started, 2.0, "answered at once")
        self.assertEqual({"jsonrpc": "2.0", "id": "server-discover-probe-1",
                          "error": {"code": -32601, "message": "method not found"}}, discover)
        init = self.rpc(process, {"jsonrpc": "2.0", "id": 1, "method": "initialize",
                                  "params": {"protocolVersion": "2025-06-18", "capabilities": {}}})
        self.assertEqual({"protocolVersion": "2025-06-18", "capabilities": {"tools": {"listChanged": False}},
                          "serverInfo": {"name": "samrabbit", "version": tools.SERVER_VERSION}}, init["result"])
        process.stdin.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
        self.assertEqual({"jsonrpc": "2.0", "id": 2, "result": {}},
                         self.rpc(process, {"jsonrpc": "2.0", "id": 2, "method": "ping"}),
                         "the notification got no answer: the next line is the ping's")
        listed = self.rpc(process, {"jsonrpc": "2.0", "id": 3, "method": "tools/list"})["result"]["tools"]
        self.assertEqual(16, len(listed))
        self.assertEqual({"get_status", "list_tasks", "read_task", "start_task", "reply_task", "respond_task",
                          "stop_task", "mark_seen", "calendar_agenda", "calendar_block", "calendar_create", "journal_add",
                          "mac_open", "mac_look", "generate_ui", "recent_conversations"},
                         {tool["name"] for tool in listed})

        def call(number: int, name: str, arguments: Dict[str, Any]) -> Dict[str, Any]:
            return self.rpc(process, {"jsonrpc": "2.0", "id": number, "method": "tools/call",
                                      "params": {"name": name, "arguments": arguments}})["result"]

        needs = call(4, "list_tasks", {"filter": "needs_you"})
        self.assertFalse(needs["isError"])
        value = json.loads(needs["content"][0]["text"])
        self.assertEqual(2, value["count"])
        approval = next(item for item in value["tasks"] if item["id"] == "t-approval")
        self.assertEqual("needs_approval", approval["status"])
        read = json.loads(call(5, "read_task", {"id": "t-approval"})["content"][0]["text"])
        self.assertEqual(("approval", "req-approve-1"), (read["waitingFor"]["kind"], read["waitingFor"]["requestId"]))
        answered = call(6, "respond_task", {"id": "t-approval", "requestId": "req-approve-1", "decision": "approve"})
        self.assertFalse(answered["isError"], answered)
        self.assertEqual("thread.approval.respond", self.fake_t3.dispatched[-1]["type"])
        look = call(7, "mac_look", {})
        self.assertEqual("image", look["content"][0]["type"])
        self.assertEqual("image/jpeg", look["content"][0]["mimeType"])
        self.assertTrue(base64.b64decode(look["content"][0]["data"]).startswith(b"\xff\xd8"))
        agenda = json.loads(call(8, "calendar_agenda", {"withinMinutes": 30})["content"][0]["text"])
        self.assertEqual(["Mom's birthday", "Standup 6612"], [item["title"] for item in agenda["events"]],
                         "happening now or within 30 minutes (the dentist at five is not)")
        journal = call(9, "journal_add", {"text": "call mom"})
        self.assertFalse(journal["isError"])
        self.assertTrue(json.loads(journal["content"][0]["text"])["added"])
        for number, (name, arguments, code) in enumerate((
                ("start_task", {}, "invalid_arguments"), ("respond_task", {"id": "t-approval"}, "invalid_arguments"),
                ("calendar_block", {"minutes": 2}, "invalid_arguments"), ("read_task", {"id": "no-such"},
                                                                          "t3_thread_not_found"),
                ("start_task", {"text": "x", "project": "Nope"}, "project_not_found"),
                ("mark_seen", {}, "invalid_arguments"),
                ("nonexistent", {}, "unknown_tool"))):
            with self.subTest(tool=name, arguments=arguments):
                result = call(20 + number, name, arguments)
                self.assertTrue(result["isError"])
                self.assertEqual(code, json.loads(result["content"][0]["text"])["error"])
        self.assertEqual(-32700, self.rpc(process, "not json")["error"]["code"])
        self.assertEqual(-32601, self.rpc(process, {"jsonrpc": "2.0", "id": 40, "method": "resources/list"})
                         ["error"]["code"])

    def test_mark_seen_settles_a_failure_he_saw(self) -> None:
        own = inbox.InboxService(home=str(self.root / "home-seen"))
        self.addCleanup(own.close)
        self.server.inbox = own
        own.attach(self.server)
        own.refresh(force=True)  # the first look: what is there is seen ...
        with self.fake_t3.lock:  # ... so the deploy preview fails again: news, in Needs you
            self.fake_t3.get_thread("t-error")["session"]["updatedAt"] = "2026-10-08T18:00:00.000Z"
        self.hub.invalidate()
        own.refresh_soon()
        process = self.start_server()
        self.rpc(process, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})

        def call(number: int, arguments: Dict[str, Any]) -> Dict[str, Any]:
            result = self.rpc(process, {"jsonrpc": "2.0", "id": number, "method": "tools/call",
                                        "params": {"name": "mark_seen", "arguments": arguments}})["result"]
            return dict(json.loads(result["content"][0]["text"]), isError=result["isError"])

        missing = call(2, {"item": "the moon landing"})
        self.assertEqual(("not_found", True), (missing["error"], missing["isError"]))
        marked = call(3, {"item": "deploy preview"})
        self.assertEqual((False, 1, ["Deploy preview"], 1),
                         (marked["isError"], marked["marked"], marked["titles"], marked["settled"]))
        own.refresh_soon()
        settled = next(item for item in own.refresh(force=True).items if item["id"] == "t3:t-error")
        self.assertEqual(("idle", False), (settled["status"], settled["unread"]), "out of Needs you")
        self.assertEqual(0, call(4, {"all": True})["marked"], "nothing else finished or failed unseen")

    def test_a_wrong_token_gets_nothing(self) -> None:
        process = self.start_server(token="sra_" + "x" * 43)
        self.rpc(process, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
        result = self.rpc(process, {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
                                    "params": {"name": "get_status", "arguments": {}}})["result"]
        self.assertTrue(result["isError"])
        self.assertEqual("unauthorized", json.loads(result["content"][0]["text"])["error"])

    def test_the_internal_token_is_loopback_only_and_limited(self) -> None:
        self.assistant.prepare()
        token = (self.workdir / "assistant-token").read_text().strip()
        for address, path, method, expected in (
                ("127.0.0.1", "/v1/mobile/summary", "GET", 200),
                ("192.168.1.20", "/v1/mobile/summary", "GET", 401),
                ("127.0.0.1", "/v1/mobile/assistant/turn", "POST", 403),
                ("127.0.0.1", "/v1/mobile/assistant/announcements", "GET", 403),
                ("127.0.0.1", "/v1/mobile/devices/child", "POST", 403),
                ("127.0.0.1", "/v1/mobile/unpair", "POST", 403),
                ("127.0.0.1", "/v1/mobile/stream", "GET", 403),
                ("127.0.0.1", "/v1/mobile/transcribe", "POST", 403)):
            with self.subTest(address=address, path=path):
                handler = FakeHandler(address, path, {"Authorization": "Bearer " + token}, b"{}")
                self.service.serve(handler, method, path)
                self.assertEqual(expected, handler.status, handler.wfile.getvalue()[:200])
        self.assertEqual(401, self.call("GET", "/health", token=token)[0], "not a bridge token either")
        self.assertNotIn(token, self.log.getvalue())


# ====================================================================== health, summary, pure helpers


class HealthTest(AssistantBase):
    def test_health_and_summary(self) -> None:
        health = self.call("GET", "/health", token=TOKEN)[1]["assistant"]
        realtime = health.pop("realtime")
        self.assertEqual({"available": True, "brain": "claude", "brainSetting": "auto", "model": "claude-haiku-5-5",
                          "modelName": "Claude Haiku 5.5", "claude": True, "copy": "dev",
                          "voice": {"available": True, "voice": "sI8FqE1zOcqXDhRwCwAx", "voiceName": "Jarvis",
                                    "model": "eleven_flash_v2_5"}, "conversations": 0}, health)
        self.assertEqual((False, "chatgpt_dev_copy", "gpt-realtime-2.1", "marin", {"connected": False}),
                         (realtime["available"], realtime["reason"], realtime["model"], realtime["voice"],
                          realtime["chatgpt"]), "a dev copy without --chatgpt-auth-file never uses a ChatGPT login")
        summary = self.call("GET", "/v1/mobile/summary", token=self.watch)[1]["assistant"]
        self.assertEqual({"available": True, "brain": "claude", "model": "claude-haiku-5-5",
                          "chatgpt": {"connected": False}}, summary)
        self.key_file.unlink()
        self.server._health = None  # noqa: SLF001
        voice = self.call("GET", "/health", token=TOKEN)[1]["assistant"]["voice"]
        self.assertEqual((False, "no_key"), (voice["available"], voice["reason"]))

    def test_without_claude_the_assistant_is_off(self) -> None:
        os.unlink(self.claude)
        status, value = self.say("hi")
        self.assertEqual((503, "assistant_unavailable", "claude_missing"),
                         (status, value["error"]["code"], value["error"]["reason"]))
        self.assertEqual({"available": False, "brain": "claude", "reason": "claude_missing", "model": "claude-haiku-5-5",
                          "chatgpt": {"connected": False}},
                         self.call("GET", "/v1/mobile/summary", token=self.watch)[1]["assistant"])


class SpokenTextTest(unittest.TestCase):
    def test_speakable(self) -> None:
        for text, expected in (
                ("at 2:30 PM", "at two thirty PM"), ("3 pm", "three PM"), ("at 14:05", "at two oh five PM"),
                ("at 9:00", "at nine o'clock"), ("$12.50", "twelve dollars and fifty cents"), ("$1", "one dollar"),
                ("50%", "fifty percent"), ("the 21st", "the twenty-first"), ("the 12th", "the twelfth"),
                ("in 2026", "in twenty twenty-six"), ("in 2005", "in two thousand five"), ("1,250 steps",
                                                                                          "one thousand two hundred fifty steps"),
                ("Haiku 5.5", "Haiku five point five"), ("T3 and 3D", "T3 and 3D"), ("0 tasks", "zero tasks"),
                ("115 emails", "one hundred fifteen emails")):
            with self.subTest(text=text):
                self.assertEqual(expected, assistant.speakable(text))

    def test_spoken(self) -> None:
        self.assertEqual("Done! Two things: one. two", assistant.spoken("**Done!** Two things:\n- one\n- two"))
        self.assertEqual("See the docs", assistant.spoken("See [the docs](https://example.com/x)").replace(
            " the docs", " the docs"))
        self.assertEqual("Open the link now.", assistant.spoken("Open https://example.com/a?b=1 now."))
        self.assertLessEqual(len(assistant.spoken("word " * 1000)), assistant.MAX_SAY_CHARS + 1)

    def test_closers_and_noise(self) -> None:
        for text in ("bye", "Bye!", "thanks, that's all", "Okay, thank you.", "stop", "never mind", "that's it",
                     "no thanks", "goodbye Jarvis", "I'm done, thanks", "thanks"):
            with self.subTest(closer=text):
                self.assertTrue(assistant.is_closer(text))
        for text in ("stop the deploy task", "what needs me?", "no", "thanks, now block an hour",
                     "cancel the dentist", "bye the way, what's next"):
            with self.subTest(not_closer=text):
                self.assertFalse(assistant.is_closer(text))
        for text in ("", "  ", "uh", "Um, hmm.", "...", "er", "Hmm, um, er."):
            self.assertTrue(assistant.is_noise(text), text)
        # Short confirmations answer "Should I approve it?": never dropped as noise.
        for text in ("what", "hi", "no", "okay", "OK.", "yes", "Yeah.", "yep", "sure", "mhm", "uh huh", "um, okay"):
            self.assertFalse(assistant.is_noise(text), text)
        self.assertTrue(assistant.expects_reply("Should I approve it?"))
        self.assertFalse(assistant.expects_reply("Done."))


class Python39Test(unittest.TestCase):
    def test_the_modules_parse_as_python_3_9_and_import_isolated(self) -> None:
        import ast

        for name in ("samrabbit_assistant.py", "samrabbit_assistant_mcp.py"):
            ast.parse((ROOT / name).read_text(), feature_version=(3, 9))
        # As the LaunchAgent runs it: the macOS system Python, isolated mode, from another folder.
        code = ("import sys; sys.path.append(sys.argv[1]); import samrabbit_mobile, samrabbit_assistant_mcp; "
                "print(samrabbit_mobile._assistant is not None)")
        done = subprocess.run(["/usr/bin/python3", "-I", "-c", code, str(ROOT)], capture_output=True, text=True,
                              timeout=60, cwd=tempfile.gettempdir())
        self.assertEqual("True", done.stdout.strip(), done.stderr)


# ====================================================================== isolation (dev copies)


class DevCopyIsolationTest(FakesMixin, unittest.TestCase):
    """A bridge run from the checkout with HOME pointing at a temp folder (``test_installed_copy``'s fakes): its
    assistant runs only with an explicit claude, never speaks with ElevenLabs without an explicit key file, and its
    tools reach only its own dev-safe answers."""

    def setUp(self) -> None:
        self.setup_fakes()
        saved = {key: os.environ.get(key) for key in set(self.env) | set(ISOLATED)}
        for key in ISOLATED:
            os.environ.pop(key, None)
        os.environ.update(self.env)
        for key, value in saved.items():
            self.addCleanup(_restore, key, value)
        self.eleven = FakeElevenLabs()
        self.addCleanup(self.eleven.close)
        canary = self.config / "elevenlabs-key"  # where the real key would be
        canary.write_text("canary-eleven-key-" + "z" * 20 + "\n")
        canary.chmod(0o600)
        for module, name, value in ((t3, "DEFAULT_SERVER_URL", self.fake_t3.url), (t3, "T3_EXECUTABLE", str(self.t3_cli)),
                                    (t3, "T3_ASAR", str(self.t3_cli)), (bridge, "FALLBACK_CLI", self.missing),
                                    (gcal, "FALLBACK_COMPOSIO", (self.missing,)),
                                    (assistant, "TTS_URL", self.eleven.url),
                                    (assistant, "DEFAULT_KEY_FILE", str(canary)),
                                    (assistant, "DEFAULT_SETTINGS_FILE", str(self.config / "assistant.json")),
                                    (assistant, "FALLBACK_CLAUDE", (self.missing,))):
            self.addCleanup(setattr, module, name, getattr(module, name))
            setattr(module, name, value)

    def start(self, **kwargs: Any) -> str:
        server = bridge.make_server("127.0.0.1", 0, token_file=str(self.config / "bridge-token"),
                                    desktop_token_file=str(self.config / "desktop-token"),
                                    mobile_devices_file=str(self.config / "mobile-devices.json"),
                                    t3_token_file=str(self.config / "t3-token"), driver=self.missing,
                                    agent_browser=self.missing, artifacts_dir=str(self.root / "artifacts"),
                                    transcribe_helper=self.missing, mobile_hosts=["10.0.0.2"],
                                    sync_dir=str(self.root / "sync"), **kwargs)
        thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        self.server = server
        return f"http://127.0.0.1:{server.server_address[1]}"

    def watch_token(self, base: str) -> str:
        status, code = _call(base, "POST", "/v1/mobile/pairing/start", {},
                             headers={"X-SamRabbit-Desktop": DEV_DESKTOP})
        status, paired = _call(base, "POST", "/v1/mobile/pair", {"code": code["code"], "platform": "watchos"})
        self.assertEqual(200, status, paired)
        return paired["token"]

    def test_a_dev_copy_runs_no_agent_and_no_voice_by_default(self) -> None:
        base = self.start()
        helper = self.server.mobile.assistant
        self.assertEqual("assistant_dev_copy", helper.off_reason())
        status, health = _call(base, "GET", "/health", token=DEV_TOKEN)
        self.assertEqual(({"available": False, "reason": "assistant_dev_copy"}, "voice_dev_copy"),
                         ({key: health["assistant"][key] for key in ("available", "reason")},
                          health["assistant"]["voice"]["reason"]))
        watch = self.watch_token(base)
        status, value = _call(base, "POST", "/v1/mobile/assistant/turn", {"text": "what needs me?", "turnId": "t1"},
                              token=watch)
        self.assertEqual((503, "assistant_dev_copy"), (status, value["error"]["reason"]))
        self.assertIsNone(helper.voice.key_file, "the real key file is not even looked at")
        self.assertEqual([], self.eleven.requests)
        self.assertIsNone(helper.workdir, "no agent, no working folder at all")
        self.assert_nothing_ran()

    def test_a_dev_copys_tools_reach_only_its_own_dev_safe_answers(self) -> None:
        state = self.root / "claude-state"
        claude = fake_claude(self.bin, state)
        (state / "script.json").write_text(json.dumps([{"tools": [
            {"name": "start_task", "arguments": {"text": "deploy the site"}},
            {"name": "calendar_block", "arguments": {"minutes": 30}},
            {"name": "journal_add", "arguments": {"text": "a note that must stay in the dry run"}},
            {"name": "list_tasks", "arguments": {}}], "reply": "Some of that is off on this copy."}]))
        base = self.start(claude=str(claude))
        watch = self.watch_token(base)
        status, value = _call(base, "POST", "/v1/mobile/assistant/turn", {"text": "do it all", "turnId": "t1"},
                              token=watch)
        self.assertEqual(200, status, value)
        self.assertIsNone(value["audio"], "no ElevenLabs without an explicit key file")
        self.assertEqual([], self.eleven.requests)
        calls = json.loads((state / "calls.jsonl").read_text().splitlines()[0])["mcp"]["calls"]
        outcome = {call["name"]: (call["isError"], json.loads(call["text"]).get("error")) for call in calls}
        self.assertEqual({"start_task": (True, "t3_dev_copy"), "calendar_block": (True, "calendar_dev_copy"),
                          "journal_add": (False, None), "list_tasks": (True, "t3_dev_copy")}, outcome)
        journal = next(call for call in calls if call["name"] == "journal_add")
        self.assertIn("dry run", json.loads(journal["text"])["note"])
        self.assertEqual(["journal_added"], [action["kind"] for action in value["actions"]])
        helper = self.server.mobile.assistant
        self.assertTrue(helper.temporary)
        self.assertTrue(os.path.realpath(helper.workdir).startswith(os.path.realpath(tempfile.gettempdir())),
                        "a dev copy keeps its files in a temp folder, never the installed copy's")
        self.assertNotEqual(os.path.realpath(os.path.expanduser(assistant.DEFAULT_DIR)),
                            os.path.realpath(helper.workdir))
        self.assert_nothing_ran()

    def test_a_t3_url_alone_never_runs_the_t3_app_cli(self) -> None:
        for choice in (None, "auto"):
            with self.subTest(t3_cli=choice):
                base = self.start(t3_url=self.fake_t3.url, t3_cli=choice)
                status, code = _call(base, "POST", "/v1/mobile/pairing/start", {},
                                     headers={"X-SamRabbit-Desktop": DEV_DESKTOP})
                status, paired = _call(base, "POST", "/v1/mobile/pair", {"code": code["code"], "platform": "ios"})
                status, value = _call(base, "GET", "/v1/mobile/t3/threads", token=paired["token"])
                self.assertEqual((503, "t3_dev_copy"), (status, value["error"]["code"]), value)
                self.assertFalse(self.server.mobile.t3.session.cli.available())
        self.assert_nothing_ran()
        self.assertFalse((self.config / "t3-token").exists())
        # An explicit CLI path is a deliberate choice (here: the fakes).
        base = self.start(t3_url=self.fake_t3.url, t3_cli=str(self.t3_cli_path))
        self.assertEqual(t3.T3Cli(str(self.t3_cli_path)).command(), self.server.mobile.t3.session.cli.command())

    def test_the_t3_command_line_needs_an_explicit_cli_path_too(self) -> None:
        import io
        from contextlib import redirect_stdout

        token_file = self.config / "t3-token"
        for args in (["--url", self.fake_t3.url], ["--url", self.fake_t3.url, "--cli", "auto"]):
            with self.subTest(args=args):
                out = io.StringIO()
                with redirect_stdout(out):
                    code = t3.main(["ensure-paired", "--token-file", str(token_file), *args])
                self.assertEqual((3, True), (code, "t3_dev_copy" in out.getvalue()))
        os.environ["SAMRABBIT_T3_URL"] = self.fake_t3.url
        out = io.StringIO()
        with redirect_stdout(out):
            self.assertEqual(3, t3.main(["ensure-paired", "--token-file", str(token_file)]))
        self.assert_nothing_ran()
        self.assertFalse(token_file.exists())


if __name__ == "__main__":
    unittest.main()
