"""The watch assistant's realtime brain end to end against fakes (stdlib, the system Python 3.9).

A real bridge on a random loopback port (``AssistantBase``: fake T3, Composio, Heptabase, cua-driver, speech to
text, Claude and ElevenLabs), plus:

* ``fake_realtime_peer.py`` as the realtime helper (the helper's JSON-lines protocol, and OpenAI's events on the data
  channel from a script),
* ``FakeSignaling`` for ``POST /v1/realtime/calls`` and ``FakeIssuer`` for the ChatGPT device login,
* a ChatGPT login file with fake tokens (``--chatgpt-auth-file``).

Nothing here reaches OpenAI, ChatGPT, ElevenLabs, T3 Code, Google Calendar, the Heptabase journal or the live bridge.
The helper itself (aiortc, real WebRTC) has its own tests in ``realtime/test_realtime_peer.py`` (the realtime venv).

Run: cd companion/mac-bridge && /usr/bin/python3 -m unittest tests.test_realtime -q
"""

from __future__ import annotations

import hashlib
import http.client
import json
import os
import re
from pathlib import Path
import stat
import struct
import sys
import tempfile
import threading
import time
import unittest
import uuid
from typing import Any, Callable, Dict, List, Optional, Tuple

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(HERE))

import samrabbit_assistant as assistant  # noqa: E402
import samrabbit_chatgpt as chatgpt  # noqa: E402
import samrabbit_inbox as inbox  # noqa: E402
import samrabbit_realtime as realtime  # noqa: E402
import samrabbit_realtime_profile as profile  # noqa: E402
from fake_openai import FakeIssuer, FakeSignaling, jwt  # noqa: E402
from test_assistant import AssistantBase, KEY, fake_claude, FakeElevenLabs  # noqa: E402
from test_mobile import DESKTOP, TOKEN, FakeHandler  # noqa: E402

ACCESS = "fake-access-token-" + "z" * 40
REFRESH = "fake-refresh-token-" + "y" * 40
UTTERANCE = "what needs me about the secret 7781 plan?"
ANSWER = "Two tasks need you right now."
STREAM = "application/x-samrabbit-stream"


def auth_record(*, expires_in: float = 3600.0, now: Optional[float] = None) -> Dict[str, Any]:
    stamp = now if now is not None else time.time()
    return {"version": 1, "tokens": {"access_token": ACCESS, "refresh_token": REFRESH,
                                     "id_token": jwt({"email": "samin@example.com", "https://api.openai.com/auth": {
                                         "chatgpt_plan_type": "pro", "chatgpt_account_id": "acct-fake-1"}})},
            "expiresAt": int(stamp + expires_in), "account": {"email": "samin@example.com", "plan": "pro",
                                                              "accountId": "acct-fake-1"},
            "connectedAt": "2026-10-08T18:00:00Z", "updatedAt": "2026-10-08T18:00:00Z", "safetyId": "safety-1"}


def write_auth(path: Path, record: Dict[str, Any]) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    path.write_text(json.dumps(record))
    path.chmod(0o600)


def frames(raw: bytes) -> List[Tuple[str, bytes]]:
    out, index = [], 0
    while index < len(raw):
        kind = chr(raw[index])
        length = struct.unpack(">I", raw[index + 1:index + 5])[0]
        out.append((kind, raw[index + 5:index + 5 + length]))
        index += 5 + length
    return out


class RealtimeBase(AssistantBase):
    """``AssistantBase`` with the realtime brain on: a fake helper, fake signaling, a fake ChatGPT login."""

    brain_setting: Optional[str] = None
    connected = True

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
        self.issuer = FakeIssuer()
        self.addCleanup(self.issuer.close)
        self.signaling = FakeSignaling()
        self.addCleanup(self.signaling.close)
        self.rt_state = self.root / "realtime"
        self.rt_state.mkdir()
        self.rt_python = bin_dir / "realtime-python"
        self.rt_python.write_text(f'#!/bin/sh\nexec "{sys.executable}" "{HERE / "fake_realtime_peer.py"}" '
                                  f'--state "{self.rt_state}" "$@"\n')
        self.rt_python.chmod(0o755)
        self.auth_file = self.root / "config" / "chatgpt-auth.json"
        if self.connected:
            write_auth(self.auth_file, auth_record())
        return assistant.make_service(installed=False, claude=str(self.claude), workdir=str(self.workdir),
                                      key_file=str(self.key_file), tts_url=self.eleven.url,
                                      settings_file=str(self.settings_file), agent_timeout=self.agent_timeout,
                                      tts_timeout=self.tts_timeout, clock=self.clock.time, brain=self.brain_setting,
                                      chatgpt_auth_file=str(self.auth_file), chatgpt_issuer=self.issuer.url,
                                      realtime_python=str(self.rt_python), realtime_api=self.signaling.url + "/v1")

    # ------------------------------------------------------------------ helpers
    def rt_script(self, *steps: Dict[str, Any]) -> None:
        (self.rt_state / "script.json").write_text(json.dumps(list(steps)))

    def received(self, *, clears: bool = False) -> List[Dict[str, Any]]:
        """The client events OpenAI got (without the ``input_audio_buffer.clear`` each turn starts with)."""
        path = self.rt_state / "received.jsonl"
        events = [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
        return events if clears else [event for event in events if event.get("type") != "input_audio_buffer.clear"]

    def ops(self) -> List[str]:
        path = self.rt_state / "ops.jsonl"
        return [json.loads(line)["op"] for line in path.read_text().splitlines()] if path.exists() else []

    def helpers_started(self) -> int:
        path = self.rt_state / "pids.txt"
        return len(path.read_text().split()) if path.exists() else 0

    def stream(self, body: Dict[str, Any], *, token: Optional[str] = None,
               on_frame: Optional[Callable[[str, bytes], None]] = None) -> Tuple[int, Dict[str, str], Any]:
        """A streamed turn: ``(status, headers, [(kind, payload)])`` (or the JSON error when not 200)."""
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=30)
        data = json.dumps(body).encode()
        connection.request("POST", "/v1/mobile/assistant/turn", body=data, headers={
            "Authorization": "Bearer " + (token or self.watch), "Accept": STREAM, "Content-Type": "application/json"})
        response = connection.getresponse()
        headers = {key.lower(): value for key, value in response.getheaders()}
        if response.status != 200:
            value = json.loads(response.read() or b"{}")
            connection.close()
            return response.status, headers, value
        if not headers.get("content-type", "").startswith(STREAM):
            value = json.loads(response.read() or b"{}")
            connection.close()
            return response.status, headers, value
        out: List[Tuple[str, bytes]] = []
        while True:
            head = response.read(5)
            if len(head) < 5:
                break
            kind, length = chr(head[0]), struct.unpack(">I", head[1:5])[0]
            payload = response.read(length)
            out.append((kind, payload))
            if on_frame is not None:
                on_frame(kind, payload)
        connection.close()
        return 200, headers, out

    @staticmethod
    def events_of(items: List[Tuple[str, bytes]]) -> List[Dict[str, Any]]:
        return [json.loads(payload) for kind, payload in items if kind == "J"]

    @staticmethod
    def audio_of(items: List[Tuple[str, bytes]]) -> bytes:
        return b"".join(payload for kind, payload in items if kind == "A")

    def say_turn(self, text: str, **kwargs: Any) -> Dict[str, Any]:
        body = {"text": text, "turnId": str(uuid.uuid4()), **kwargs}
        status, headers, items = self.stream(body)
        self.assertEqual(200, status, items)
        return {"events": self.events_of(items), "audio": self.audio_of(items), "frames": items, "headers": headers}

    def done(self, turn: Dict[str, Any]) -> Dict[str, Any]:
        last = turn["events"][-1]
        self.assertEqual("done", last["type"])
        return last


# ====================================================================== streaming turns


class StreamTurnTest(RealtimeBase):
    def test_a_streamed_turn_is_heard_said_and_played_by_the_realtime_session(self) -> None:
        self.rt_script({"say": ANSWER, "ms": 600})
        turn = self.say_turn(UTTERANCE)
        headers = turn["headers"]
        self.assertEqual(STREAM, headers["content-type"])
        self.assertEqual("chunked", headers["transfer-encoding"])
        events = turn["events"]
        self.assertEqual({"type": "heard", "text": UTTERANCE}, events[0])
        deltas = "".join(event["text"] for event in events if event["type"] == "say.delta")
        self.assertEqual(ANSWER, deltas)
        self.assertEqual({"type": "say.done", "text": ANSWER}, [event for event in events
                                                                if event["type"] == "say.done"][0])
        done = self.done(turn)
        self.assertEqual({"type", "conversationId", "turnId", "expectReply", "endConversation", "brain", "timings"},
                         set(done))
        self.assertEqual(("realtime", False, False), (done["brain"], done["expectReply"], done["endConversation"]))
        self.assertEqual({"stt", "firstAudio", "total"}, set(done["timings"]))
        self.assertIsInstance(done["timings"]["firstAudio"], int)
        audio = turn["audio"]
        self.assertEqual(600 * 32, len(audio), "600 ms of PCM16 16 kHz mono")
        sizes = [len(payload) for kind, payload in turn["frames"] if kind == "A"]
        self.assertTrue(all(size == 3200 for size in sizes), "100 ms frames")
        order = [kind if kind == "A" else json.loads(payload)["type"] for kind, payload in turn["frames"]]
        self.assertLess(order.index("heard"), order.index("A"))
        self.assertLess(order.index("A"), order.index("done"))
        # What OpenAI got: the user's words with the [Now: ...] line, then response.create.
        self.assertEqual(["input_audio_buffer.clear", "conversation.item.create", "response.create"],
                         [event["type"] for event in self.received(clears=True)],
                         "manual turns: the silent input buffer is emptied first")
        received = self.received()
        text = received[0]["item"]["content"][0]["text"]
        self.assertEqual("[Now: Thursday, October 8, 2026, 2:37 PM America/New_York · device: watch]\n" + UTTERANCE,
                         text)
        self.assertEqual(("message", "user", "input_text"), (received[0]["item"]["type"], received[0]["item"]["role"],
                                                              received[0]["item"]["content"][0]["type"]))
        self.assertEqual([], self.claude_calls(), "Claude never ran")
        self.assertEqual([], self.eleven.requests, "ElevenLabs never ran")
        self.assert_clean_log(ANSWER, ACCESS, REFRESH)

    def test_the_session_is_the_r1s_signed_with_the_chatgpt_token(self) -> None:
        self.say_turn("hello")
        [call] = self.signaling.requests
        self.assertEqual("/v1/realtime/calls", call["path"])
        self.assertEqual("Bearer " + ACCESS, call["authorization"])
        self.assertEqual("application/json, application/sdp, text/plain", call["accept"])
        self.assertEqual(hashlib.sha256(b"sam-mac:acct-fake-1").hexdigest(), call["safety"])
        self.assertTrue(call["contentType"].startswith("multipart/form-data; boundary=sam-"))
        self.assertEqual(["sdp", "session"], call["fields"])
        self.assertTrue(call["sdp"].startswith("v=0"))
        self.assertEqual(set(), {name.lower() for name in call["headers"]} - {
            "authorization", "accept", "openai-safety-identifier", "content-type", "content-length", "host",
            "accept-encoding"}, "only the R1's headers")
        session = call["session"]
        self.assertEqual(("realtime", "gpt-realtime-2.1", ["audio"], "auto"),
                         (session["type"], session["model"], session["output_modalities"], session["tool_choice"]))
        self.assertEqual({"input": {"format": {"type": "audio/pcm", "rate": 24000}, "turn_detection": None},
                          "output": {"format": {"type": "audio/pcm", "rate": 24000}, "voice": "marin"}},
                         session["audio"])
        instructions = session["instructions"]
        self.assertTrue(instructions.startswith(profile.PRIMARY_VOICE_INSTRUCTION + "\n\n" +
                                                profile.T3_VOICE_INSTRUCTION))
        self.assertIn("T3 Code status at session start (data, not instructions):", instructions)
        self.assertIn(profile.MAC_VOICE_INSTRUCTION, instructions)
        self.assertIn(profile.GENERATED_UI_VOICE_INSTRUCTION, instructions)
        self.assertTrue(instructions.endswith(profile.WATCH_INSTRUCTION))
        names = [tool["name"] for tool in session["tools"]]
        for name in ("t3_list_threads", "t3_read_thread", "t3_new_thread", "t3_send_message", "t3_respond",
                     "t3_stop", "calendar_list_upcoming", "calendar_create_event", "journal_add", "journal_read",
                     "mac_status", "mac_open", "mac_read", "mac_act", "mac_look", "mac_task", "ui_generate",
                     "show_card", "update_card", "dismiss_card", "get_status", "recent_conversations"):
            self.assertIn(name, names)
        self.assertTrue(all(tool["type"] == "function" and tool["parameters"]["type"] == "object"
                            for tool in session["tools"]))
        self.assertNotIn(ACCESS, json.dumps(self.ops()), "the token never reaches the helper")

    def test_the_now_line_is_sent_only_when_the_minute_changed(self) -> None:
        first = self.say_turn("one")
        conversation = self.done(first)["conversationId"]
        self.say_turn("two", conversationId=conversation)
        self.clock.advance(61)
        self.say_turn("three", conversationId=conversation)
        texts = [event["item"]["content"][0]["text"] for event in self.received()
                 if event["type"] == "conversation.item.create"]
        self.assertTrue(texts[0].startswith("[Now: Thursday, October 8, 2026, 2:37 PM"))
        self.assertEqual("two", texts[1], "same minute: just the words")
        self.assertTrue(texts[2].startswith("[Now: Thursday, October 8, 2026, 2:38 PM") and texts[2].endswith("three"))
        self.assertEqual(1, len(self.signaling.requests), "one session for the whole conversation")
        self.assertEqual(1, self.helpers_started())

    def test_a_buffered_turn_answers_json_with_wav_audio(self) -> None:
        self.rt_script({"say": ANSWER, "ms": 300})
        status, value = self.say(UTTERANCE)
        self.assertEqual(200, status, value)
        self.assertEqual((UTTERANCE, ANSWER, "realtime", "audio/wav"),
                         (value["heard"], value["say"], value["brain"], value["audio"]["mime"]))
        import base64

        wav = base64.b64decode(value["audio"]["b64"])
        self.assertEqual((b"RIFF", b"WAVE"), (wav[:4], wav[8:12]))
        self.assertEqual(300 * 32, len(wav) - 44)
        self.assertEqual(16000, struct.unpack("<I", wav[24:28])[0])

    def test_noise_and_goodbyes(self) -> None:
        turn = self.say_turn("um, er")
        self.assertEqual([{"type": "heard", "text": ""}], turn["events"][:-1])
        self.assertTrue(self.done(turn)["expectReply"])
        self.assertEqual([], self.received(), "noise never reaches OpenAI")
        first = self.say_turn("okay")  # a confirmation is not noise
        conversation = self.done(first)["conversationId"]
        self.rt_script({"verbatim": True, "ms": 200})
        bye = self.say_turn("thanks, that's all", conversationId=conversation)
        self.assertEqual("Okay, talk soon." if "thank" not in "thanks" else "You're welcome. Talk soon.",
                         [event for event in bye["events"] if event["type"] == "say.done"][0]["text"])
        done = self.done(bye)
        self.assertEqual((True, False), (done["endConversation"], done["expectReply"]))
        self.assertGreater(len(bye["audio"]), 0, "the goodbye is in the session's own voice")
        last = self.received()[-1]
        self.assertEqual(("response.create", "none"), (last["type"], last["response"]["tool_choice"]))
        self.assertIn("“You're welcome. Talk soon.”", last["response"]["instructions"])
        self.wait_for(lambda: "close" in self.ops(), 10)

    def test_a_long_reply_plays_to_the_end_after_its_words_are_done(self) -> None:
        # response.done (the words) comes long before the audio has played out over WebRTC.
        words = "Here is a longer answer with quite a few words in it, about as long as two spoken sentences get."
        self.rt_script({"say": words, "ms": 6000, "pace": 0.1})
        turn = self.say_turn("tell me more")
        self.assertEqual(6000 * 32, len(turn["audio"]), "all 6 s of it")
        self.assertEqual("done", turn["events"][-1]["type"])

    def test_a_retried_streamed_turn_replays_without_running_again(self) -> None:
        turn_id = str(uuid.uuid4())
        status, _headers, first = self.stream({"text": "hello", "turnId": turn_id})
        status, _headers, again = self.stream({"text": "hello", "turnId": turn_id})
        self.assertEqual(200, status)
        self.assertEqual([event["type"] for event in self.events_of(first)],
                         [event["type"] for event in self.events_of(again)])
        self.assertEqual(2, len(self.received()), "OpenAI got the turn once")


# ====================================================================== tools


class ToolTest(RealtimeBase):
    def test_a_function_call_runs_on_the_mac_and_the_answer_follows(self) -> None:
        self.rt_script({"call": "t3_list_threads", "arguments": {"filter": "needs-you"}},
                       {"say": "Two need you: the login redirect and the database.", "ms": 300})
        turn = self.say_turn("what needs me")
        received = self.received()
        self.assertEqual(["conversation.item.create", "response.create", "conversation.item.create",
                          "response.create"], [event["type"] for event in received])
        output = received[2]["item"]
        self.assertEqual(("function_call_output", "call_1"), (output["type"], output["call_id"]))
        value = json.loads(output["output"])
        self.assertEqual("needs-you", value["filter"])
        titles = [item["title"] for item in value["threads"]]
        self.assertIn("Fix the login redirect", titles)
        self.assertIn("Pick a database", titles)
        self.assertEqual(2, value["counts"]["needsYou"])
        self.assertTrue(all(set(item) <= {"id", "title", "project", "status", "label", "when"}
                            for item in value["threads"]))
        self.assertEqual("realtime", self.done(turn)["brain"])
        recorded = [event for event in self.events(self.done(turn)["conversationId"]) if event["type"] ==
                    "tool.completed"]
        self.assertEqual(["t3_list_threads"], [event["tool"] for event in recorded])

    def test_threads_by_title_and_actions(self) -> None:
        self.rt_script({"call": "t3_read_thread", "arguments": {"thread": "the login redirect"}},
                       {"call": "t3_new_thread", "arguments": {"prompt": "add dark mode to the website",
                                                               "project": "Website"}},
                       {"say": "Started it in Website.", "ms": 200})
        turn = self.say_turn("read the login one, then start dark mode on the website")
        outputs = [json.loads(event["item"]["output"]) for event in self.received()
                   if event["type"] == "conversation.item.create" and event["item"]["type"] == "function_call_output"]
        self.assertEqual("Fix the login redirect", outputs[0]["thread"]["title"])
        self.assertIn("approvals", outputs[0], "the pending approval with its requestId")
        self.assertTrue(outputs[1]["started"])
        self.assertEqual("Website", outputs[1]["project"])
        actions = [event for event in turn["events"] if event["type"] == "action"]
        self.assertEqual(["task_started"], [action["kind"] for action in actions])
        self.assertEqual({"type", "kind", "title", "threadId"}, set(actions[0]))

    def test_a_thread_dismissed_in_the_inbox_is_not_listed_but_is_still_found(self) -> None:
        # An inbox of its own (nothing but what was dismissed: it reads no sessions here), the login thread dismissed.
        dismissed = inbox.InboxService(home=str(self.root / "home-inbox"))
        self.addCleanup(dismissed.close)
        self.server.inbox = dismissed
        dismissed.attach(self.server)
        approval = next(item for item in self.hub.threads(None) if item["threadId"] == "t-approval")
        dismissed.seen.dismiss("t3:t-approval", {"status": "needs-approval", "requests": None,
                                                 "at": approval["updatedAt"]}, "seen")
        self.rt_script({"call": "t3_list_threads", "arguments": {"filter": "needs-you"}},
                       {"call": "t3_read_thread", "arguments": {"thread": "the login redirect"}},
                       {"say": "Only the database question needs you.", "ms": 200})
        self.say_turn("what needs me")
        outputs = [json.loads(event["item"]["output"]) for event in self.received()
                   if event["type"] == "conversation.item.create" and event["item"]["type"] == "function_call_output"]
        self.assertEqual(["Pick a database", "Deploy preview"], [item["title"] for item in outputs[0]["threads"]])
        self.assertEqual(1, outputs[0]["counts"]["needsYou"])
        self.assertEqual("Fix the login redirect", outputs[1]["thread"]["title"], "still found by name")
        instructions = self.signaling.last_session()["instructions"]
        self.assertIn("1 need the user", instructions, "the session's T3 status leaves it out too")
        self.assertNotIn("Fix the login redirect", instructions)

    def test_mark_it_as_seen_settles_it_like_the_docks_button(self) -> None:
        # Samin: "if I say 'Mark as seen,' it should settle it, and I shouldn't be seeing it in 'Needs You.'"
        own = inbox.InboxService(home=str(self.root / "home-seen"))
        self.addCleanup(own.close)
        self.server.inbox = own
        own.attach(self.server)
        own.refresh(force=True)  # the first look: what is there is seen ...
        with self.fake_t3.lock:  # ... so the deploy preview fails again: news, in Needs you
            self.fake_t3.get_thread("t-error")["session"]["updatedAt"] = "2026-10-08T18:00:00.000Z"
        self.hub.invalidate()
        own.refresh_soon()
        failed = next(item for item in own.refresh(force=True).items if item["id"] == "t3:t-error")
        self.assertEqual(("error", True), (failed["status"], failed["unread"]))
        self.rt_script({"call": "mark_seen", "arguments": {"item": "the deploy preview"}},
                       {"call": "mark_seen", "arguments": {"all": True}},
                       {"call": "mark_seen", "arguments": {"item": "the moon landing"}},
                       {"say": "Marked the deploy preview as seen.", "ms": 200})
        self.say_turn("mark the deploy preview as seen")
        outputs = [json.loads(event["item"]["output"]) for event in self.received()
                   if event["type"] == "conversation.item.create" and event["item"]["type"] == "function_call_output"]
        self.assertEqual({"marked": 1, "titles": ["Deploy preview"], "settled": 1}, outputs[0])
        self.assertEqual(0, outputs[1]["marked"], "nothing else finished or failed unseen")
        self.assertEqual(("item_not_found", True), (outputs[2]["error"], outputs[2]["isError"]))
        own.refresh_soon()
        settled = next(item for item in own.refresh(force=True).items if item["id"] == "t3:t-error")
        self.assertEqual(("idle", False), (settled["status"], settled["unread"]), "out of Needs you")
        self.assertEqual([], [command for command in self.fake_t3.dispatched
                              if command.get("threadId") == "t-error"], "seeing it tells T3 nothing")

    def test_cards_show_on_the_watch(self) -> None:
        self.rt_script({"call": "show_card", "arguments": {"id": "next", "title": "Next up",
                                                           "lines": ["Dentist 3 PM", "Standup 4 PM"]}},
                       {"say": "Here's what's next.", "ms": 200})
        turn = self.say_turn("what's next")
        cards = [event for event in turn["events"] if event["type"] == "card"]
        self.assertEqual([{"type": "card", "title": "Next up", "body": "Dentist 3 PM\nStandup 4 PM"}], cards)

    def test_the_journal_takes_only_his_own_words(self) -> None:
        self.rt_script({"call": "journal_add", "arguments": {"text": "Samin had a productive afternoon"}},
                       {"say": "I can only add your own words.", "ms": 100},
                       {"call": "journal_add", "arguments": {"text": "the demo went great"}},
                       {"say": "Added.", "ms": 100})
        first = self.say_turn("add to my journal that the demo went great")
        outputs = [json.loads(event["item"]["output"]) for event in self.received()
                   if event["type"] == "conversation.item.create" and event["item"]["type"] == "function_call_output"]
        self.assertEqual(("not_verbatim", True), (outputs[0]["error"], outputs[0]["isError"]))
        self.say_turn("add to my journal that the demo went great",
                      conversationId=self.done(first)["conversationId"])
        outputs = [json.loads(event["item"]["output"]) for event in self.received()
                   if event["type"] == "conversation.item.create" and event["item"]["type"] == "function_call_output"]
        self.assertEqual((True, "sent"), (outputs[1]["recorded"], outputs[1]["state"]))
        written = (self.hepta_dir / "journal.json").read_text()
        self.assertIn("the demo went great", written, "the fake Heptabase got his words")
        self.assertNotIn("productive", written)

    def test_unknown_tools_and_bad_arguments_are_honest_errors(self) -> None:
        self.rt_script({"call": "voice_mode_switch", "arguments": {"modeKey": "goal_intake"}},
                       {"call": "calendar_create_event", "arguments": {"title": "Focus", "startsAt": "now"}},
                       {"say": "Sorry.", "ms": 100})
        self.say_turn("delegate this")
        outputs = [json.loads(event["item"]["output"]) for event in self.received()
                   if event["type"] == "conversation.item.create" and event["item"]["type"] == "function_call_output"]
        self.assertEqual(("unknown_tool", True), (outputs[0]["error"], outputs[0]["isError"]))
        self.assertEqual("missing_end", outputs[1]["error"])

    def test_loopback_tool_calls_never_go_through_a_proxy(self) -> None:
        # Review note: a proxy in the environment (or System Settings) must never see the internal token. A fresh
        # process, as the MCP server is: urllib reads the proxy settings when it first opens a URL.
        import subprocess

        token_file = self.root / "internal-token"
        token_file.write_text(self.assistant._token)  # noqa: SLF001
        token_file.chmod(0o600)
        code = ("import sys; sys.path.append(sys.argv[1]); import samrabbit_assistant_mcp as tools; "
                "print(sorted(tools.Bridge(sys.argv[2], sys.argv[3], None).call('GET', '/v1/mobile/summary')))")
        env = {"PATH": "/usr/bin:/bin", "HOME": str(self.root), "http_proxy": "http://127.0.0.1:9",
               "HTTP_PROXY": "http://127.0.0.1:9"}  # nothing listens on port 9
        done = subprocess.run(["/usr/bin/python3", "-c", code, str(ROOT), self.base, str(token_file)], env=env,
                              capture_output=True, text=True, timeout=60)
        self.assertEqual(0, done.returncode, done.stderr[-500:])
        self.assertIn("'assistant'", done.stdout)

    def test_tools_stop_after_six_rounds(self) -> None:
        self.rt_script({"call": "get_status", "arguments": {}})
        turn = self.say_turn("loop forever")
        outputs = [event for event in self.received() if event["type"] == "conversation.item.create" and
                   event["item"]["type"] == "function_call_output"]
        self.assertEqual(7, len(outputs), "six rounds run, the seventh call is refused")
        self.assertEqual("too_many_steps", json.loads(outputs[-1]["item"]["output"])["error"])
        self.assertIn("more steps", [event for event in turn["events"] if event["type"] == "say.done"][0]["text"])


# ====================================================================== cancel, warm-up, announcements


class SessionTest(RealtimeBase):
    def test_warm_up_opens_the_session_before_the_first_turn(self) -> None:
        status, value = self.call("POST", "/v1/mobile/assistant/session", {}, token=self.watch)
        self.assertEqual(200, status, value)
        self.assertEqual({"conversationId", "brain", "ready"}, set(value))
        self.assertEqual("realtime", value["brain"])
        self.wait_for(lambda: self.signaling.requests and "answer" in self.ops())
        conversation = value["conversationId"]
        time.sleep(0.2)
        status, again = self.call("POST", "/v1/mobile/assistant/session", {"conversationId": conversation},
                                  token=self.watch)
        self.assertEqual((conversation, True), (again["conversationId"], again["ready"]))
        self.say_turn("hello", conversationId=conversation)
        self.assertEqual(1, len(self.signaling.requests), "the turn used the warm session")

    def test_tap_to_interrupt_cancels_the_reply(self) -> None:
        self.rt_script({"say": "This is a long answer that goes on and on.", "ms": 5000, "pace": 0.05})
        first = self.say_turn("hi")
        conversation = self.done(first)["conversationId"]
        cancelled: List[Dict[str, Any]] = []

        def on_frame(kind: str, _payload: bytes) -> None:
            if kind == "A" and not cancelled:
                cancelled.append(self.call("POST", "/v1/mobile/assistant/cancel", {"conversationId": conversation},
                                           token=self.watch)[1])

        started = time.monotonic()
        status, _headers, items = self.stream({"text": "tell me everything", "turnId": str(uuid.uuid4()),
                                               "conversationId": conversation}, on_frame=on_frame)
        self.assertLess(time.monotonic() - started, 4.0, "stopped long before the 5 s reply ended")
        self.assertEqual([{"ok": True, "cancelled": True}], cancelled)
        done = self.events_of(items)[-1]
        self.assertEqual(("done", True, False), (done["type"], done.get("interrupted"), done["expectReply"]))
        self.assertLess(len(self.audio_of(items)), 5000 * 32 // 2)
        self.wait_for(lambda: "output_audio_buffer.clear" in [event["type"] for event in self.received()], 5)
        self.assertIn("response.cancel", [event["type"] for event in self.received()])
        self.assertIn("drop_audio", self.ops())
        status, value = self.call("POST", "/v1/mobile/assistant/cancel", {"conversationId": conversation},
                                  token=self.watch)
        self.assertEqual({"ok": True, "cancelled": False}, value, "nothing is running now")

    def test_a_cancel_names_its_turn_and_never_stops_the_next_one(self) -> None:
        # The iPhone review: a tap on a reply that ended meanwhile stopped the turn typed right after it.
        long = "This is a long answer that goes on and on."
        self.rt_script({"say": ANSWER, "ms": 300}, {"say": long, "ms": 3000, "pace": 0.05})
        first = self.done(self.say_turn("hi"))
        conversation, first_turn = first["conversationId"], first["turnId"]
        second_turn = str(uuid.uuid4())
        answers: List[Dict[str, Any]] = []

        def late_tap(kind: str, _payload: bytes) -> None:
            if kind == "A" and not answers:
                answers.append(self.call("POST", "/v1/mobile/assistant/cancel",
                                         {"conversationId": conversation, "turnId": first_turn}, token=self.watch)[1])

        status, _headers, items = self.stream({"text": "and the next one?", "turnId": second_turn,
                                               "conversationId": conversation}, on_frame=late_tap)
        self.assertEqual(200, status, items)
        self.assertEqual([{"ok": True, "cancelled": False}], answers, "the first turn is over: nothing to stop")
        done = self.events_of(items)[-1]
        self.assertEqual(("done", second_turn, None), (done["type"], done["turnId"], done.get("interrupted")))
        self.assertEqual(3000 * 32, len(self.audio_of(items)), "the second reply played to its end")
        self.assertNotIn("response.cancel", [event["type"] for event in self.received()])
        # A cancel that names the turn being said stops it, as one without a turn id does.
        third_turn = str(uuid.uuid4())
        answers.clear()

        def tap(kind: str, _payload: bytes) -> None:
            if kind == "A" and not answers:
                answers.append(self.call("POST", "/v1/mobile/assistant/cancel",
                                         {"conversationId": conversation, "turnId": third_turn}, token=self.watch)[1])

        status, _headers, items = self.stream({"text": "tell me everything", "turnId": third_turn,
                                               "conversationId": conversation}, on_frame=tap)
        self.assertEqual([{"ok": True, "cancelled": True}], answers)
        done = self.events_of(items)[-1]
        self.assertEqual((third_turn, True), (done["turnId"], done.get("interrupted")))
        self.assertLess(len(self.audio_of(items)), 3000 * 32)
        for body, code in (({"conversationId": conversation, "turnId": 7}, "invalid_turn"),
                           ({"conversationId": conversation, "turnId": "not a turn!"}, "invalid_turn"),
                           ({"turnId": third_turn}, "invalid_conversation")):
            with self.subTest(body=body):
                status, value = self.call("POST", "/v1/mobile/assistant/cancel", body, token=self.watch)
                self.assertEqual((400, code), (status, value["error"]["code"]))

    def test_the_smoke_test_script(self) -> None:
        import subprocess

        self.rt_script({"say": ANSWER, "ms": 500})
        before = self.call("GET", "/v1/mobile/devices", desktop=True)[1]["devices"]
        done = subprocess.run(["/usr/bin/python3", "-I", str(ROOT / "realtime" / "smoke_turn.py"), "--port",
                               str(self.port), "--desktop-token-file", str(self.desktop_file)],
                              capture_output=True, text=True, timeout=120)
        self.assertEqual(0, done.returncode, done.stdout + done.stderr)
        self.assertIn("warm-up: brain=realtime", done.stdout)
        self.assertIn("audio: 0.5 s of PCM16 16 kHz in 5 frames", done.stdout)
        self.assertIn("done: brain=realtime", done.stdout)
        self.assertIn("temporary device revoked: True", done.stdout)
        self.assertTrue(done.stdout.strip().endswith("smoke test: ok"))
        for secret in (ANSWER, "quick test", ACCESS, DESKTOP):
            self.assertNotIn(secret, done.stdout + done.stderr)
        self.assertEqual(before, self.call("GET", "/v1/mobile/devices", desktop=True)[1]["devices"])

    def test_end_closes_the_session_and_idle_sessions_close(self) -> None:
        turn = self.say_turn("hello")
        conversation = self.done(turn)["conversationId"]
        status, value = self.call("POST", "/v1/mobile/assistant/end", {"conversationId": conversation},
                                  token=self.watch)
        self.assertEqual({"ok": True, "ended": True}, value)
        self.wait_for(lambda: "close" in self.ops())
        other = self.done(self.say_turn("hi again"))["conversationId"]
        self.assertEqual(2, self.helpers_started())
        found = self.assistant._conversations[other]  # noqa: SLF001
        found.realtime.used_at -= realtime.IDLE_CLOSE_SECONDS + 1
        self.assistant.sweep_sessions()
        self.wait_for(lambda: self.ops().count("close") == 2)
        self.assertIsNone(found.realtime)
        # The next turn opens a new session that starts with a summary of the conversation so far.
        self.say_turn("and now?", conversationId=other)
        self.assertEqual(3, len(self.signaling.requests))
        self.assertIn("Earlier in this watch conversation", self.signaling.last_session()["instructions"])
        self.assertIn("Samin said: hi again", self.signaling.last_session()["instructions"])

    def test_a_crashed_helper_mid_reply_ends_the_stream_honestly(self) -> None:
        first = self.say_turn("hi")
        conversation = self.done(first)["conversationId"]
        self.rt_script({"say": "x", "ms": 100}, {"die": True})
        turn = self.say_turn("and this?", conversationId=conversation)
        events = turn["events"]
        self.assertEqual("heard", events[0]["type"])
        done = events[-1]
        self.assertEqual("done", done["type"])
        # Nothing was said yet, so Claude answered instead (auto).
        self.assertEqual("claude", done["brain"])
        self.assertEqual(1, len(self.claude_calls()))
        self.rt_script({"say": "Back again.", "ms": 100})
        self.assistant.realtime.resume()
        again = self.say_turn("still there?", conversationId=conversation)
        self.assertEqual("realtime", self.done(again)["brain"], "a new session")

    def test_announcements_are_said_by_the_session(self) -> None:
        turn = self.say_turn("hello")
        conversation = self.done(turn)["conversationId"]
        self.assertEqual([], self.poll(conversation)["items"])
        with self.fake_t3.lock:
            thread = self.fake_t3.get_thread("t-new")
            thread["hasPendingApprovals"] = True
            thread["session"] = {"threadId": "t-new", "status": "running", "activeTurnId": "turn-x", "lastError": None}
            thread["latestTurn"] = {"turnId": "turn-x", "state": "running", "requestedAt": "2026-10-08T13:11:00.000Z"}
            thread["updatedAt"] = "2026-10-08T13:11:00.000Z"
        self.hub.invalidate()
        items = self.poll(conversation)["items"]
        self.assertEqual(1, len(items))
        self.assertIsNone(items[0]["audio"], "the realtime brain says it itself")
        self.assertEqual([], self.eleven.requests)
        self.rt_script({"verbatim": True, "ms": 300})
        status, _headers, frames_ = self.stream({"announce": str(items[0]["id"]), "conversationId": conversation,
                                                 "turnId": str(uuid.uuid4())})
        self.assertEqual(200, status, frames_)
        events = self.events_of(frames_)
        self.assertNotIn("heard", [event["type"] for event in events])
        self.assertEqual("“Draft for later” in Hermes needs your approval.",
                         [event for event in events if event["type"] == "say.done"][0]["text"])
        self.assertGreater(len(self.audio_of(frames_)), 0)
        context, create = self.received()[-2:]
        self.assertEqual("[T3 update] “Draft for later” in Hermes needs your approval. (thread id t-new)",
                         context["item"]["content"][0]["text"])
        self.assertEqual("none", create["response"]["tool_choice"])
        status, _headers, value = self.stream({"announce": "99999", "conversationId": conversation,
                                               "turnId": str(uuid.uuid4())})
        self.assertEqual((404, "announcement_not_found"), (status, value["error"]["code"]))

    def test_an_old_change_is_never_announced_to_a_new_conversation(self) -> None:
        # Review note: a conversation that starts after a quiet spell must not hear what changed during it.
        first = self.say_turn("hello")
        self.poll(self.done(first)["conversationId"])  # the announcer's baseline
        with self.fake_t3.lock:
            thread = self.fake_t3.get_thread("t-running")
            thread["session"]["status"] = "ready"
            thread["session"]["activeTurnId"] = None
            thread["latestTurn"] = {"state": "completed", "completedAt": "2026-10-08T13:10:00.000Z"}
            thread["planProgress"] = None
            thread["updatedAt"] = "2026-10-08T13:10:00.000Z"
        self.hub.invalidate()
        later = self.say_turn("anything new?")  # a new conversation, nobody polled meanwhile
        self.assertEqual([], self.poll(self.done(later)["conversationId"])["items"])


# ====================================================================== brain selection and fallback


class BrainTest(RealtimeBase):
    def test_a_refused_call_falls_back_to_claude_and_pauses_realtime(self) -> None:
        self.signaling.statuses = [429]
        self.script({"reply": "Claude here."})
        turn = self.say_turn("hello")
        done = self.done(turn)
        self.assertEqual("claude", done["brain"])
        self.assertEqual("Claude here.", [event for event in turn["events"] if event["type"] == "say.done"][0]["text"])
        self.assertGreater(len(turn["audio"]), 0, "ElevenLabs PCM in the stream")
        self.assertTrue(self.eleven.requests[-1]["path"].endswith("/stream"))
        self.assertEqual("output_format=pcm_16000", self.eleven.requests[-1]["query"])
        summary = self.call("GET", "/v1/mobile/summary", token=self.watch)[1]["assistant"]
        self.assertEqual(("claude", True, {"connected": True}), (summary["brain"], summary["available"],
                                                                  summary["chatgpt"]))
        self.server._health = None  # noqa: SLF001
        health = self.call("GET", "/health", token=TOKEN)[1]["assistant"]
        self.assertEqual(("claude", "realtime_busy"), (health["brain"], health["realtime"]["reason"]))

    def test_a_rejected_token_is_refreshed_once(self) -> None:
        self.signaling.statuses = [401]
        turn = self.say_turn("hello")
        self.assertEqual("realtime", self.done(turn)["brain"])
        self.assertEqual(2, len(self.signaling.requests))
        refreshes = [request for request in self.issuer.requests if request["body"].get("grant_type") ==
                     "refresh_token"]
        self.assertEqual(1, len(refreshes))
        self.assertEqual((chatgpt.CLIENT_ID, REFRESH), (refreshes[0]["body"]["client_id"],
                                                        refreshes[0]["body"]["refresh_token"]))
        self.assertNotEqual("Bearer " + ACCESS, self.signaling.requests[1]["authorization"])
        stored = json.loads(self.auth_file.read_text())
        self.assertEqual("refresh-1", stored["tokens"]["refresh_token"], "the rotated refresh token is kept")
        self.assertEqual(0o600, stat.S_IMODE(self.auth_file.stat().st_mode))
        self.assert_clean_log(ACCESS, REFRESH, "refresh-1", stored["tokens"]["access_token"])

    def test_brain_settings(self) -> None:
        self.settings_file.write_text(json.dumps({"brain": "claude"}))
        self.script({"reply": "Claude."})
        self.assertEqual("claude", self.done(self.say_turn("hi"))["brain"])
        self.assertEqual([], self.signaling.requests)
        self.settings_file.write_text(json.dumps({"brain": "realtime", "realtimeModel": "gpt-realtime-2.1-mini"}))
        self.assertEqual("realtime", self.done(self.say_turn("hi"))["brain"])
        self.assertEqual("gpt-realtime-2.1-mini", self.signaling.last_session()["model"])
        self.auth_file.unlink()
        status, _headers, value = self.stream({"text": "hi", "turnId": str(uuid.uuid4())})
        self.assertEqual((503, "assistant_unavailable", "chatgpt_not_connected"),
                         (status, value["error"]["code"], value["error"]["reason"]))
        self.settings_file.write_text(json.dumps({"brain": "auto"}))
        self.assertEqual("claude", self.done(self.say_turn("hi"))["brain"], "auto without ChatGPT: Claude")

    def test_without_the_helper_the_brain_is_claude(self) -> None:
        (self.rt_state / "check.json").write_text(json.dumps({"ok": False, "reason": "python_too_old",
                                                             "python": "3.9.6"}))
        self.assistant.realtime.checker.status(refresh=True)
        self.server._health = None  # noqa: SLF001
        health = self.call("GET", "/health", token=TOKEN)[1]["assistant"]
        self.assertEqual(("claude", "realtime_python_too_old"), (health["brain"], health["realtime"]["reason"]))
        self.assertEqual("claude", self.done(self.say_turn("hi"))["brain"])


# ====================================================================== a turn that fails halfway, a stale session


class HalfwayTest(RealtimeBase):
    """Review fixes: a turn whose realtime tools already acted, or that Samin stopped, is never answered again by
    Claude; a session that is too old or whose helper died is replaced without a deadlock."""

    def creates(self) -> List[Dict[str, Any]]:
        return [item for item in self.fake_t3.dispatched if item["type"] == "thread.create"]

    def tools_recorded(self, conversation: str) -> List[str]:
        return [event["tool"] for event in self.events(conversation) if event["type"] == "tool.completed"]

    def test_a_failed_response_after_a_tool_ends_the_turn_without_claude(self) -> None:
        self.rt_script({"call": "t3_new_thread", "arguments": {"prompt": "fix the login bug"}},
                       {"fail": "server_error"})
        turn = self.say_turn("have T3 fix the login bug")
        events = turn["events"]
        self.assertEqual(["heard", "action", "say.done", "done"], [event["type"] for event in events])
        self.assertEqual("task_started", events[1]["kind"])
        self.assertEqual("Sorry, I got cut off partway through that.", events[2]["text"], "the watch says it")
        done = self.done(turn)
        self.assertEqual(("realtime", None), (done["brain"], done.get("interrupted")))
        self.assertEqual(1, len(self.creates()), "the T3 task was made once")
        self.assertEqual([], self.claude_calls(), "Claude never answered the same words again")
        self.assertEqual(["t3_new_thread"], self.tools_recorded(done["conversationId"]))
        self.assertIsNone(self.assistant.realtime.paused(), "a server error does not pause the brain")

    def test_a_rate_limited_response_after_a_tool_still_pauses_the_brain(self) -> None:
        self.rt_script({"call": "get_status", "arguments": {}}, {"fail": "rate_limit_exceeded"})
        done = self.done(self.say_turn("how are things"))
        self.assertEqual("realtime", done["brain"])
        self.assertEqual([], self.claude_calls())
        self.assertEqual("realtime_response_failed", self.assistant.realtime.paused())

    def test_a_lost_connection_after_a_tool_is_not_answered_again(self) -> None:
        self.rt_script({"call": "t3_new_thread", "arguments": {"prompt": "fix the login bug"}}, {"die": True})
        body = {"text": "have T3 fix the login bug", "turnId": str(uuid.uuid4())}
        status, _headers, items = self.stream(body)
        self.assertEqual(200, status, items)
        events = self.events_of(items)
        self.assertEqual(["heard", "action", "error", "done"], [event["type"] for event in events])
        self.assertEqual("assistant_interrupted", events[2]["code"])
        done = events[-1]
        self.assertEqual("realtime", done["brain"])
        self.assertEqual([], self.claude_calls())
        self.assertEqual(1, len(self.creates()))
        conversation = done["conversationId"]
        self.assertEqual(["t3_new_thread"], self.tools_recorded(conversation), "in the timeline all the same")
        heard, said = self.assistant._conversations[conversation].history[-1]  # noqa: SLF001
        self.assertEqual("have T3 fix the login bug", heard)
        self.assertIn("task_started", said, "the next session's summary knows the task was started")
        # The watch retrying the same turn gets the same answer: nothing runs again.
        status, _headers, value = self.stream(body)
        self.assertEqual((502, "assistant_interrupted"), (status, value["error"]["code"]))
        self.assertEqual((1, []), (len(self.creates()), self.claude_calls()))

    def test_a_stopped_turn_whose_session_fails_is_not_answered_by_claude(self) -> None:
        conversation = self.done(self.say_turn("hi"))["conversationId"]
        found = self.assistant._conversations[conversation]  # noqa: SLF001
        found.realtime.helper.process.kill()  # the next turn needs a new session
        found.realtime.helper.process.wait()
        self.assistant.sweep_sessions()
        self.assertIsNone(found.realtime)
        brain = self.assistant.realtime

        def refused(_offer: str, _config: Dict[str, Any]) -> str:
            time.sleep(1.0)  # Samin taps stop meanwhile
            raise realtime.RealtimeError("realtime_unavailable", "OpenAI could not start the session.")

        brain.signal = refused
        self.addCleanup(vars(brain).pop, "signal", None)
        out: Dict[str, Any] = {}
        worker = threading.Thread(target=lambda: out.update(turn=self.stream(
            {"text": "what's next", "turnId": str(uuid.uuid4()), "conversationId": conversation})), daemon=True)
        worker.start()
        self.wait_for(lambda: found.cancel is not None)
        status, value = self.call("POST", "/v1/mobile/assistant/cancel", {"conversationId": conversation},
                                  token=self.watch)
        self.assertEqual({"ok": True, "cancelled": True}, value)
        worker.join(30.0)
        status, _headers, items = out["turn"]
        self.assertEqual(200, status, items)
        events = self.events_of(items)
        self.assertEqual(["heard", "done"], [event["type"] for event in events])
        self.assertEqual((True, False, "realtime"), (events[-1].get("interrupted"), events[-1]["expectReply"],
                                                     events[-1]["brain"]))
        self.assertEqual([], self.claude_calls(), "a stopped turn is not answered by anyone")
        self.assertEqual([], self.eleven.requests)

    def test_claude_never_starts_a_turn_that_was_already_stopped(self) -> None:
        conversation = self.assistant._conversations[self.done(self.say_turn("hi"))["conversationId"]]  # noqa: SLF001
        result = assistant._TurnResult(conversation.id, str(uuid.uuid4()))  # noqa: SLF001
        sink = assistant.TurnSink(result, None, monotonic=time.monotonic, started=time.monotonic(), keep_audio=True)
        sink.cancel.set()
        request = assistant._TurnRequest(conversation_id=conversation.id, turn_id=result.turn_id,  # noqa: SLF001
                                         text="start a task")
        run = self.assistant._claude_turn(conversation, request, "start a task", sink)  # noqa: SLF001
        self.assertEqual(({}, True, False), (dict(run.tools), result.interrupted, result.expect_reply))
        self.assertEqual([], self.claude_calls())

    def test_an_announcement_whose_session_dies_mid_words_is_said_once(self) -> None:
        conversation = self.done(self.say_turn("hello"))["conversationId"]
        self.poll(conversation)  # the announcer's baseline
        with self.fake_t3.lock:
            thread = self.fake_t3.get_thread("t-new")
            thread["hasPendingApprovals"] = True
            thread["session"] = {"threadId": "t-new", "status": "running", "activeTurnId": "turn-x", "lastError": None}
            thread["latestTurn"] = {"turnId": "turn-x", "state": "running", "requestedAt": "2026-10-08T13:11:00.000Z"}
            thread["updatedAt"] = "2026-10-08T13:11:00.000Z"
        self.hub.invalidate()
        [item] = self.poll(conversation)["items"]
        self.rt_script({"verbatim": True, "die_after": "words"})
        status, _headers, items = self.stream({"announce": str(item["id"]), "conversationId": conversation,
                                               "turnId": str(uuid.uuid4())})
        self.assertEqual(200, status, items)
        events = self.events_of(items)
        line = "“Draft for later” in Hermes needs your approval."
        self.assertEqual(line, "".join(event["text"] for event in events if event["type"] == "say.delta"),
                         "the words once, not the session's and then ElevenLabs' again")
        self.assertEqual(line, [event for event in events if event["type"] == "say.done"][0]["text"])
        self.assertGreater(len(self.audio_of(items)), 0, "ElevenLabs said it")
        self.assertTrue(self.eleven.requests[-1]["path"].endswith("/stream"))

    def test_a_stale_session_is_replaced_without_a_deadlock(self) -> None:
        # Review repro: _session() closed a stale session with the (non-reentrant) realtime_lock held.
        conversation = self.done(self.say_turn("hi"))["conversationId"]
        found = self.assistant._conversations[conversation]  # noqa: SLF001

        def helper_died(session: Any) -> None:
            session.helper.process.kill()
            session.helper.process.wait()

        def fifty_five_minutes(session: Any) -> None:
            session.opened_at -= realtime.MAX_SESSION_SECONDS + 1

        for make_stale in (helper_died, fifty_five_minutes):
            old = found.realtime
            # Like a turn (or an announcement turn) of this conversation: it holds the conversation's lock, so the
            # 1 s sweep leaves the stale session to it.
            with found.lock:
                make_stale(old)
                self.assistant.sweep_sessions()
                self.assertIs(old, found.realtime)
                self.assertEqual("open", old.state, "the sweep has not closed it")
                worker = threading.Thread(target=self.assistant._session, args=(found,),  # noqa: SLF001
                                          kwargs={"wait": True}, daemon=True)
                worker.start()
                worker.join(10.0)
                if worker.is_alive():
                    found.realtime_lock.release()  # so the bridge can still shut down
                    self.fail(f"_session() deadlocked on a stale session ({make_stale.__name__})")
            self.assertFalse(found.realtime_lock.locked())
            self.assertIsNot(old, found.realtime)
            self.assertEqual("open", found.realtime.state)
            self.wait_for(lambda: old.state == "closed" and old.helper is None)
        self.assertEqual(3, self.helpers_started())
        again = self.say_turn("still there?", conversationId=conversation)
        self.assertEqual("realtime", self.done(again)["brain"])
        status, value = self.call("POST", "/v1/mobile/assistant/end", {"conversationId": conversation},
                                  token=self.watch)
        self.assertEqual({"ok": True, "ended": True}, value, "end() does not block either")


# ====================================================================== second review round: dead sessions, a
#                                                                         response still active, the cap, pings


class PolishTest(RealtimeBase):
    """Review notes (round two): a session that died between turns is replaced without a pause or Claude; a refused
    ``response.create`` waits for the active response; a cancelled response's calls get outputs; live sessions are
    capped and a warm-up reuses the device's conversation; closing a session while it opens never pauses the brain;
    a new login never cuts a turn off; a silent stream pings."""

    def conversation_of(self, turn: Dict[str, Any]) -> Any:
        return self.assistant._conversations[self.done(turn)["conversationId"]]  # noqa: SLF001

    def said(self, turn: Dict[str, Any]) -> str:
        return "".join(event["text"] for event in turn["events"] if event["type"] == "say.delta")

    def outputs(self) -> Dict[str, str]:
        return {event["item"]["call_id"]: event["item"]["output"] for event in self.received()
                if event.get("type") == "conversation.item.create" and
                event["item"]["type"] == "function_call_output"}

    def creates(self) -> List[Dict[str, Any]]:
        return [item for item in self.fake_t3.dispatched if item["type"] == "thread.create"]

    def test_a_session_that_died_between_turns_is_replaced_without_a_pause(self) -> None:
        self.rt_script({"say": ANSWER, "ms": 200})
        # "lose": the helper says the peer connection failed (the reader marks the session at once, even though the
        # next turn's drain drops that message); "lose_quietly": nothing is said, the data channel is just closed, so
        # the turn finds out from its first send.
        for op in ("lose", "lose_quietly"):
            with self.subTest(op=op):
                conversation = self.conversation_of(self.say_turn("hello"))
                old = conversation.realtime
                old.helper.send({"op": op})
                if op == "lose":
                    self.wait_for(lambda: old.helper is None or old.helper.lost)
                    self.assertFalse(old.usable())
                started = self.helpers_started()
                turn = self.say_turn("are you there?", conversationId=conversation.id)
                done = self.done(turn)
                self.assertEqual(("realtime", None), (done["brain"], done.get("interrupted")))
                self.assertEqual(ANSWER, self.said(turn))
                self.assertNotIn("error", [event["type"] for event in turn["events"]])
                self.assertEqual(started + 1, self.helpers_started(), "a new session answered")
                self.assertIsNot(old, conversation.realtime)
                self.wait_for(lambda: old.helper is None)
                self.assertIsNone(self.assistant.realtime.paused(), "a session that died idle never pauses the brain")
                self.assertEqual([], self.claude_calls())
                self.assertEqual([], self.eleven.requests)

    def test_a_refused_response_create_waits_for_the_active_response(self) -> None:
        # OpenAI refuses response.create while an earlier response is still active: that one is cancelled, its words
        # and its function call are not this turn's (the call gets a "cancelled" output and never runs), and this
        # turn's response.create goes again after its response.done.
        self.rt_script({"active": True, "old_call": "t3_new_thread"}, {"say": ANSWER, "ms": 200})
        turn = self.say_turn("what needs me")
        self.assertEqual(ANSWER, self.said(turn), "not the earlier response's words")
        done = self.done(turn)
        self.assertEqual("realtime", done["brain"])
        self.assertEqual(["conversation.item.create", "response.create", "response.cancel", "output_audio_buffer.clear",
                          "conversation.item.create", "response.create"],
                         [event["type"] for event in self.received()])
        self.assertEqual({"call_old": json.dumps({"isError": True, "error": "cancelled"})}, self.outputs())
        self.assertEqual([], self.creates(), "the earlier response's call never ran")
        self.assertEqual([], self.claude_calls())
        self.assertEqual([], [event["tool"] for event in self.events(done["conversationId"])
                              if event["type"] == "tool.completed"])

    def test_a_refused_response_create_is_sent_again_when_no_response_done_comes(self) -> None:
        self.addCleanup(setattr, realtime, "ACTIVE_RETRY_SECONDS", realtime.ACTIVE_RETRY_SECONDS)
        realtime.ACTIVE_RETRY_SECONDS = 0.5
        self.rt_script({"active": "no_done"}, {"say": ANSWER, "ms": 200})
        turn = self.say_turn("what needs me")
        self.assertEqual((ANSWER, "realtime"), (self.said(turn), self.done(turn)["brain"]))
        self.assertEqual(2, [event["type"] for event in self.received()].count("response.create"))

    def test_a_call_only_in_a_cancelled_response_still_gets_its_output(self) -> None:
        self.rt_script({"say": "Hi.", "ms": 100},
                       {"say": "Let me look that up", "ms": 3000, "call_on_cancel": "t3_list_threads"})
        conversation = self.done(self.say_turn("hi"))["conversationId"]
        cancelled: List[Any] = []

        def on_frame(kind: str, _payload: bytes) -> None:
            if kind == "A" and not cancelled:
                cancelled.append(self.call("POST", "/v1/mobile/assistant/cancel", {"conversationId": conversation},
                                           token=self.watch)[1])

        status, _headers, items = self.stream({"text": "what is running", "turnId": str(uuid.uuid4()),
                                               "conversationId": conversation}, on_frame=on_frame)
        self.assertEqual(200, status, items)
        self.assertTrue(self.events_of(items)[-1].get("interrupted"))
        self.assertEqual({"call_cancel_2": json.dumps({"isError": True, "error": "cancelled",
                                                       "message": "Samin interrupted."})}, self.outputs())

    # ------------------------------------------------------------------ the cap, the warm-up
    def live(self) -> List[Any]:
        return [item for item in self.assistant._conversations.values()  # noqa: SLF001
                if item.realtime is not None and item.realtime.state in ("new", "opening", "open")]

    def test_live_sessions_are_capped_per_device_and_on_the_mac(self) -> None:
        self.rt_script({"say": "Okay.", "ms": 100})
        watch = [self.done(self.say_turn(f"watch {number}"))["conversationId"] for number in range(3)]
        self.assertIsNone(self.assistant._conversations[watch[0]].realtime,  # noqa: SLF001
                          "the watch's least recently used session closed for its third")
        self.assertEqual(3, self.helpers_started())
        self.wait_for(lambda: self.assistant.realtime.sessions == 2 and self.ops().count("close") == 1)
        phone = [self.done(self.turn_as(self.phone, f"phone {number}"))["conversationId"] for number in range(2)]
        self.assertEqual(4, len(self.live()))
        other = self.pair("watchos", "Second Watch")["token"]
        third = self.done(self.turn_as(other, "another watch"))["conversationId"]
        self.assertIsNone(self.assistant._conversations[watch[1]].realtime,  # noqa: SLF001
                          "the Mac's least recently used session closed for a fifth")
        self.assertEqual({watch[2], *phone, third}, {item.id for item in self.live()})
        self.wait_for(lambda: self.assistant.realtime.sessions == 4 and self.ops().count("close") == 2)
        self.assertEqual(6, self.helpers_started())

    def turn_as(self, token: str, text: str) -> Dict[str, Any]:
        status, _headers, items = self.stream({"text": text, "turnId": str(uuid.uuid4())}, token=token)
        self.assertEqual(200, status, items)
        return {"events": self.events_of(items), "audio": self.audio_of(items)}

    def test_when_every_session_is_mid_turn_claude_answers(self) -> None:
        self.script({"reply": "Claude here."})
        first = self.conversation_of(self.say_turn("one"))
        second = self.conversation_of(self.say_turn("two"))
        busy = [first.lock, second.lock]  # as if both were mid-turn: neither may be closed for a third
        for lock in busy:
            lock.acquire()
        try:
            turn = self.say_turn("three")
        finally:
            for lock in busy:
                lock.release()
        self.assertEqual("claude", self.done(turn)["brain"])
        self.assertEqual(2, self.helpers_started(), "no third OpenAI call")
        self.assertIsNone(self.assistant.realtime.paused(), "the cap never pauses the brain")
        self.assertIsNotNone(first.realtime)
        self.assertIsNotNone(second.realtime)

    def test_a_warm_up_without_an_id_reuses_the_devices_conversation(self) -> None:
        status, first = self.call("POST", "/v1/mobile/assistant/session", {}, token=self.watch)
        self.assertEqual(200, status, first)
        self.wait_for(lambda: "answer" in self.ops())
        for _ in range(3):  # an app relaunched again and again keeps one conversation and one OpenAI call
            status, again = self.call("POST", "/v1/mobile/assistant/session", {}, token=self.watch)
            self.assertEqual((200, first["conversationId"]), (status, again["conversationId"]))
        self.assertEqual(1, len(self.signaling.requests))
        status, phone = self.call("POST", "/v1/mobile/assistant/session", {}, token=self.phone)
        self.assertNotEqual(first["conversationId"], phone["conversationId"], "another device: its own")
        self.call("POST", "/v1/mobile/assistant/end", {"conversationId": first["conversationId"]}, token=self.watch)
        status, fresh = self.call("POST", "/v1/mobile/assistant/session", {}, token=self.watch)
        self.assertNotEqual(first["conversationId"], fresh["conversationId"], "an ended conversation is not reused")
        self.clock.now += assistant.IDLE_END_SECONDS + 1
        status, later = self.call("POST", "/v1/mobile/assistant/session", {}, token=self.watch)
        self.assertNotIn(later["conversationId"], (first["conversationId"], fresh["conversationId"]),
                         "nor one nobody spoke in for five minutes")

    def test_closing_a_session_while_it_opens_never_pauses_the_brain(self) -> None:
        (self.rt_state / "open_delay").write_text("1.0")
        status, value = self.call("POST", "/v1/mobile/assistant/session", {}, token=self.watch)
        self.assertEqual(200, status, value)
        session = self.assistant._conversations[value["conversationId"]].realtime  # noqa: SLF001
        self.wait_for(lambda: "answer" in self.ops())
        self.assertEqual("opening", session.state)
        status, ended = self.call("POST", "/v1/mobile/assistant/end", {"conversationId": value["conversationId"]},
                                  token=self.watch)
        self.assertEqual({"ok": True, "ended": True}, ended)
        self.wait_for(lambda: session.ready.is_set() and session.helper is None)
        self.assertEqual(("closed", "realtime_closed"), (session.state, session.error.code))
        self.assertIsNone(self.assistant.realtime.paused(), "a local close is not OpenAI's fault")
        time.sleep(0.3)
        self.assertEqual(0, self.assistant.realtime.sessions, "never counted as live")
        (self.rt_state / "open_delay").unlink()
        self.assertEqual("realtime", self.done(self.say_turn("hello"))["brain"])

    def test_a_new_login_never_cuts_a_turn_off(self) -> None:
        self.rt_script({"say": "Hi.", "ms": 100}, {"say": ANSWER, "ms": 300, "delay": 1.0}, {"say": "Again.", "ms": 100})
        conversation = self.conversation_of(self.say_turn("hello"))
        old = conversation.realtime
        out: Dict[str, Any] = {}
        worker = threading.Thread(target=lambda: out.update(turn=self.say_turn("what needs me",
                                                                               conversationId=conversation.id)),
                                  daemon=True)
        worker.start()
        self.wait_for(lambda: conversation.lock.locked() and any(
            event.get("type") == "response.create" for event in self.received()[2:]))
        self.assistant._chatgpt_changed()  # noqa: SLF001 - what a new login, a disconnect or a refused refresh does
        worker.join(30.0)
        turn = out["turn"]
        self.assertEqual(("realtime", ANSWER), (self.done(turn)["brain"], self.said(turn)), "the turn finished")
        self.assertTrue(old.retired)
        self.assertIs(old, conversation.realtime)
        self.assistant.sweep_sessions()  # the worker's once-a-second sweep: the turn is over, so it closes now
        self.assertIsNone(conversation.realtime)
        self.wait_for(lambda: old.helper is None, 10.0)
        again = self.say_turn("still there?", conversationId=conversation.id)
        self.assertEqual("realtime", self.done(again)["brain"])
        self.assertEqual(2, self.helpers_started(), "the next turn made a new session")
        self.assertEqual([], self.claude_calls())

    # ------------------------------------------------------------------ pings
    def test_a_silent_stream_pings_until_the_answer(self) -> None:
        self.assistant.stream_ping = 0.2
        self.rt_script({"say": ANSWER, "ms": 200, "delay": 1.2})
        turn = self.say_turn("what needs me")
        kinds = [event["type"] for event in turn["events"]]
        self.assertEqual("heard", kinds[0])
        first_words = kinds.index("say.delta")
        self.assertGreaterEqual(kinds[:first_words].count("ping"), 3, kinds)
        self.assertTrue(all(event == {"type": "ping"} for event in turn["events"] if event["type"] == "ping"))
        self.assertEqual(("done", ANSWER), (kinds[-1], self.said(turn)))

    def test_a_retry_waiting_for_its_turn_pings_then_replays(self) -> None:
        self.assistant.stream_ping = 0.2
        self.rt_script({"say": ANSWER, "ms": 200, "delay": 1.5})
        body = {"text": "what needs me", "turnId": str(uuid.uuid4())}
        out: Dict[str, Any] = {}
        worker = threading.Thread(target=lambda: out.update(first=self.stream(body)), daemon=True)
        worker.start()
        self.wait_for(lambda: any(event.get("type") == "response.create" for event in self.received()))
        status, _headers, items = self.stream(body)  # the watch retried: it waits for the same turn
        worker.join(30.0)
        self.assertEqual(200, status, items)
        events = self.events_of(items)
        kinds = [event["type"] for event in events]
        self.assertEqual("ping", kinds[0], "the waiting retry pinged first")
        self.assertEqual(["heard", "say.delta", "say.done", "done"], [kind for kind in kinds if kind != "ping"])
        first = self.events_of(out["first"][2])
        self.assertEqual(first[-1], events[-1], "the same answer")
        self.assertEqual(1, [event["type"] for event in self.received()].count("response.create"), "it ran once")


# ====================================================================== the ChatGPT login


class ChatGPTAuthTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name, "config", "chatgpt-auth.json")
        self.issuer = FakeIssuer()
        self.addCleanup(self.issuer.close)
        self.now = 1_791_500_000.0
        self.auth = chatgpt.ChatGPTAuth(str(self.path), issuer=self.issuer.url, clock=lambda: self.now,
                                        poll_floor=0.05)
        self.addCleanup(self.auth.close)
        import io
        import logging

        self.log = io.StringIO()
        handler = logging.StreamHandler(self.log)
        chatgpt._LOG.addHandler(handler)  # noqa: SLF001
        chatgpt._LOG.propagate = False  # noqa: SLF001
        self.addCleanup(chatgpt._LOG.removeHandler, handler)  # noqa: SLF001
        self.addCleanup(setattr, chatgpt._LOG, "propagate", True)  # noqa: SLF001

    def tearDown(self) -> None:
        text = self.log.getvalue()
        for secret in (ACCESS, REFRESH, "refresh-1", "WXYZ-12345", "auth-code-1", "verifier-1", "samin@example.com"):
            self.assertNotIn(secret, text)

    def wait_for(self, condition: Callable[[], bool], seconds: float = 10.0) -> None:
        deadline = time.monotonic() + seconds
        while not condition():
            if time.monotonic() > deadline:
                self.fail("timed out")
            time.sleep(0.02)

    def test_the_device_login_like_the_r1(self) -> None:
        self.issuer.pending = 2
        started = self.auth.start()
        self.assertEqual({"userCode": "WXYZ-12345", "verificationUrl": self.issuer.url + "/codex/device",
                          "expiresAt": chatgpt._iso(self.now + 900)}, started)  # noqa: SLF001
        status = self.auth.status()
        self.assertEqual(("waiting", "WXYZ-12345"), (status["login"]["state"], status["login"]["userCode"]))
        self.wait_for(self.auth.connected)
        usercode, *polls, token = self.issuer.requests
        self.assertEqual(("/api/accounts/deviceauth/usercode", {"client_id": "app_EMoamEEZ73f0CkXaXp7hrann"}),
                         (usercode["path"], usercode["body"]))
        self.assertEqual(3, len(polls), "403 twice, then the code")
        self.assertEqual({"device_auth_id": "device-auth-1", "user_code": "WXYZ-12345"}, polls[0]["body"])
        self.assertEqual("application/x-www-form-urlencoded", token["contentType"])
        self.assertEqual({"grant_type": "authorization_code", "code": "auth-code-1",
                          "redirect_uri": self.issuer.url + "/deviceauth/callback",
                          "client_id": "app_EMoamEEZ73f0CkXaXp7hrann", "code_verifier": "verifier-1"}, token["body"])
        self.assertEqual({"connected": True, "plan": "pro", "email": "samin@example.com", "login": {"state": "done"}},
                         self.auth.status())
        self.assertEqual(0o600, stat.S_IMODE(self.path.stat().st_mode))
        self.assertEqual(0o700, stat.S_IMODE(self.path.parent.stat().st_mode))
        stored = json.loads(self.path.read_text())
        self.assertEqual("refresh-1", stored["tokens"]["refresh_token"])
        self.assertEqual(int(self.now + 3600), stored["expiresAt"])
        self.assertEqual(stored["tokens"]["access_token"], self.auth.access_token())
        self.assertTrue(all(request["userAgent"] for request in self.issuer.requests))

    def test_refresh_before_expiry_keeps_the_rotated_token(self) -> None:
        write_auth(self.path, auth_record(expires_in=3600, now=self.now))
        self.assertEqual(ACCESS, self.auth.access_token(), "an hour left: no refresh")
        self.assertEqual([], self.issuer.requests)
        self.now += 3600 - 200  # inside the five-minute leeway
        fresh = self.auth.access_token()
        self.assertNotEqual(ACCESS, fresh)
        [refresh] = self.issuer.requests
        self.assertEqual("application/json", refresh["contentType"])
        self.assertEqual({"grant_type": "refresh_token", "client_id": chatgpt.CLIENT_ID, "refresh_token": REFRESH},
                         refresh["body"])
        self.assertEqual("refresh-1", json.loads(self.path.read_text())["tokens"]["refresh_token"])
        self.assertEqual(fresh, self.auth.access_token(), "refreshed once")
        self.assertEqual(1, len(self.issuer.requests))

    def test_a_refused_refresh_needs_a_new_login(self) -> None:
        write_auth(self.path, auth_record(expires_in=60, now=self.now))
        self.issuer.refuse_refresh = True
        with self.assertRaises(chatgpt.ChatGPTError) as caught:
            self.auth.access_token()
        self.assertEqual("chatgpt_reconnect_required", caught.exception.code)
        self.assertEqual((False, "reconnect_required"), (self.auth.status()["connected"],
                                                         self.auth.status()["reason"]))
        self.assertFalse(self.auth.connected())

    def test_disconnect_and_expiry(self) -> None:
        write_auth(self.path, auth_record(now=self.now))
        self.assertEqual({"connected": False}, self.auth.disconnect())
        self.assertFalse(self.path.exists())
        with self.assertRaises(chatgpt.ChatGPTError):
            self.auth.access_token()
        self.issuer.pending = 10_000
        self.auth.start()
        self.now += 901
        self.assertEqual("expired", self.auth.status()["login"]["state"])

    def test_only_a_real_change_tells_the_brain(self) -> None:
        # Review note: an expired code or a failed poll used to call on_change, which closed every live session.
        changes: List[str] = []
        self.auth.on_change = lambda: changes.append("changed")
        self.issuer.pending = 10_000
        self.auth.start()
        self.now += 901  # nobody approved the code in time
        self.auth._thread.join(10.0)  # noqa: SLF001
        self.assertEqual("expired", self.auth.status()["login"]["state"])
        self.issuer.fail_poll = True
        self.auth.start()
        self.auth._thread.join(10.0)  # noqa: SLF001
        self.assertEqual(("failed", "http_500"), (self.auth.status()["login"]["state"],
                                                  self.auth.status()["login"]["reason"]))
        self.assertEqual([], changes, "nothing changed: the stored login is the one there was")
        self.issuer.fail_poll, self.issuer.pending, self.issuer.polls = False, 0, 0
        self.auth.start()
        self.auth._thread.join(10.0)  # noqa: SLF001
        self.assertTrue(self.auth.connected())
        self.assertEqual(["changed"], changes, "a new login")
        self.auth.disconnect()
        self.assertEqual(["changed"] * 2, changes, "a disconnect")
        write_auth(self.path, auth_record(expires_in=60, now=self.now))
        self.issuer.refuse_refresh = True
        with self.assertRaises(chatgpt.ChatGPTError):
            self.auth.access_token()
        self.assertEqual(["changed"] * 3, changes, "a refused refresh")
        self.issuer.refuse_refresh, self.issuer.fail_refresh = False, True
        write_auth(self.path, auth_record(expires_in=60, now=self.now))
        with self.assertRaises(chatgpt.ChatGPTError):
            self.auth.access_token()
        self.assertEqual(["changed"] * 3, changes, "a refresh that merely failed (OpenAI busy) changes nothing")

    def test_a_dev_copy_never_uses_the_real_login(self) -> None:
        dev = chatgpt.make_auth(installed=False)
        self.assertIsInstance(dev, chatgpt.UnavailableAuth)
        self.assertEqual({"connected": False, "reason": "chatgpt_dev_copy", "login": {"state": "idle"}}, dev.status())
        with self.assertRaises(chatgpt.ChatGPTError) as caught:
            dev.start()
        self.assertEqual("chatgpt_dev_copy", caught.exception.code)
        explicit = chatgpt.make_auth(installed=False, auth_file=str(self.path))
        self.assertEqual(str(self.path), explicit.path)
        installed = chatgpt.make_auth(installed=True)
        self.assertEqual(os.path.expanduser("~/.config/samrabbit/chatgpt-auth.json"), installed.path)
        source = (ROOT / "samrabbit_chatgpt.py").read_text()
        # Codex's login is borrowed read-only (test_codex_login): auth.json is the only ~/.codex file named.
        self.assertEqual(set(re.findall(r"\.codex[/\w.]*", source)), {".codex", ".codex/auth.json"})


class ChatGPTRouteTest(RealtimeBase):
    connected = False

    def test_the_desktop_app_connects_chatgpt(self) -> None:
        for kwargs in ({}, {"token": self.watch}, {"token": TOKEN}):
            with self.subTest(kwargs=list(kwargs)):
                status, value = self.call("POST", "/v1/assistant/chatgpt/start", {}, **kwargs)
                self.assertEqual(401, status, value)
        handler = FakeHandler("192.168.1.50", "/v1/assistant/chatgpt/status", {"X-SamRabbit-Desktop": DESKTOP})
        self.service.serve(handler, "GET", "/v1/assistant/chatgpt/status")
        self.assertEqual(403, handler.status, "loopback only")
        status, value = self.call("GET", "/v1/assistant/chatgpt/status", desktop=True)
        self.assertEqual((200, False), (status, value["connected"]))
        self.issuer.pending = 0
        status, value = self.call("POST", "/v1/assistant/chatgpt/start", {}, desktop=True)
        self.assertEqual(200, status, value)
        self.assertEqual({"userCode", "verificationUrl", "expiresAt"}, set(value))
        self.assistant.chatgpt._poll_floor = 0.05  # noqa: SLF001
        self.wait_for(lambda: self.call("GET", "/v1/assistant/chatgpt/status", desktop=True)[1]["connected"], 15)
        status, value = self.call("GET", "/v1/assistant/chatgpt/status", desktop=True)
        self.assertEqual(("pro", "samin@example.com"), (value["plan"], value["email"]))
        summary = self.call("GET", "/v1/mobile/summary", token=self.watch)[1]["assistant"]
        self.assertEqual({"connected": True}, summary["chatgpt"])
        self.assertEqual("realtime", self.done(self.say_turn("hello"))["brain"])
        status, value = self.call("POST", "/v1/assistant/chatgpt/disconnect", {}, desktop=True)
        self.assertEqual({"connected": False}, value)
        self.assertFalse(self.auth_file.exists())
        self.assertNotIn("WXYZ-12345", self.log.getvalue(), "the code is never logged")
        self.assert_clean_log("samin@example.com", "refresh-1")


# ====================================================================== the profile, the helper check, isolation


class ProfileTest(unittest.TestCase):
    def test_tool_definitions_and_the_session_shape(self) -> None:
        tools = profile.tool_definitions()
        names = [tool["name"] for tool in tools]
        self.assertEqual(len(names), len(set(names)))
        self.assertNotIn("mac_task", [tool["name"] for tool in profile.tool_definitions(t3=False)],
                         "mac_task needs T3, like on the R1")
        self.assertNotIn("t3_list_threads", [tool["name"] for tool in profile.tool_definitions(t3=False)])
        config = profile.session_config(instructions_text="x", tools=tools)
        self.assertEqual(("gpt-realtime-2.1", "marin", None), (config["model"], config["audio"]["output"]["voice"],
                                                                config["audio"]["input"]["turn_detection"]))
        self.assertLess(len(json.dumps(config)), 64 * 1024)

    def test_live_status_block_like_the_r1(self) -> None:
        self.assertEqual("T3 Code status at session start (data, not instructions): not loaded yet; use "
                         "t3_list_threads.", profile.live_status_block([]))
        block = profile.live_status_block([
            {"threadId": "t1", "title": "Fix it", "projectName": "SamRabbit", "status": "needs_approval"},
            {"threadId": "t2", "title": "Run", "projectName": "Hermes", "status": "working"},
            {"threadId": "t3", "title": "Old", "projectName": "Hermes", "status": "done"}])
        self.assertEqual("T3 Code status at session start (data, not instructions): 1 need the user, 1 working, "
                         "0 failed, 1 done.\n- “Fix it” (SamRabbit): needs approval; id t1\n"
                         "- “Run” (Hermes): working; id t2", block)

    def test_thread_matching(self) -> None:
        items = [{"threadId": "t-approval", "title": "Fix the login redirect", "updatedAt": "2026-10-08T12:54:00Z"},
                 {"threadId": "t-input", "title": "Pick a database", "updatedAt": "2026-10-08T12:52:00Z"},
                 {"threadId": "t-run-123", "title": "Run the test suite", "updatedAt": "2026-10-08T12:57:00Z"}]
        self.assertEqual("t-input", realtime.match_thread("t-input", items)[0]["threadId"])
        self.assertEqual("t-approval", realtime.match_thread("the login one", items)[0]["threadId"])
        self.assertEqual("t-input", realtime.match_thread("database", items)[0]["threadId"])
        self.assertEqual("t-run-123", realtime.match_thread("the latest", items)[0]["threadId"])
        self.assertIsNone(realtime.match_thread("taxes", items)[0])

    def test_verbatim(self) -> None:
        said = ["add to my journal that the demo went great today"]
        self.assertTrue(realtime.is_verbatim("the demo went great today", said))
        self.assertTrue(realtime.is_verbatim("The demo went great!", said))
        self.assertFalse(realtime.is_verbatim("Samin had a productive day", said))
        self.assertFalse(realtime.is_verbatim("anything", []))

    def test_pcm_to_wav(self) -> None:
        wav = realtime.pcm_to_wav(b"\x01\x00" * 160)
        self.assertEqual((b"RIFF", 36 + 320, b"WAVE", 1, 1, 16000, 320), (
            wav[:4], struct.unpack("<I", wav[4:8])[0], wav[8:12], struct.unpack("<H", wav[20:22])[0],
            struct.unpack("<H", wav[22:24])[0], struct.unpack("<I", wav[24:28])[0], struct.unpack("<I", wav[40:44])[0]))

    def test_the_helper_check(self) -> None:
        missing = realtime.HelperCheck(None)
        self.assertEqual({"ready": False, "reason": "realtime_helper_missing"}, missing.status())
        nowhere = realtime.HelperCheck("/nonexistent/python")
        self.assertEqual({"ready": False, "reason": "realtime_venv_missing"}, nowhere.status())
        old = realtime.HelperCheck("/usr/bin/python3")  # the real helper, on Python 3.9: too old
        self.assertEqual({"ready": False, "reason": "realtime_python_too_old", "python": "3.9.6"}
                         if sys.version_info[:2] == (3, 9) else old.status(), old.status())

    def test_a_dev_copy_has_no_realtime_without_explicit_files(self) -> None:
        service = assistant.make_service(installed=False, settings_file=None)
        self.assertEqual("chatgpt_dev_copy", service.realtime.off_reason())
        self.assertIsNone(service.realtime.checker.python, "and no realtime venv")

    def test_the_modules_parse_as_python_3_9(self) -> None:
        import ast

        for name in ("samrabbit_chatgpt.py", "samrabbit_realtime.py", "samrabbit_realtime_profile.py",
                     "realtime/samrabbit_realtime_peer.py", "realtime/smoke_turn.py"):
            ast.parse((ROOT / name).read_text(), feature_version=(3, 9))


if __name__ == "__main__":
    unittest.main()
