"""The desktop app's voice (``/v1/desktop/assistant/*``) end to end against the watch assistant's fakes.

The same routes, bodies and streaming protocol as ``/v1/mobile/assistant/*`` (``test_assistant.py``,
``test_realtime.py``), but for the desktop token from this Mac only, as the one device "mac": its conversations are
"Mac" ones in the sync store, its Claude turns get the Mac's prompt and ``device: mac``, its realtime sessions the Mac
addendum. Nothing here reaches the real Claude, OpenAI, ElevenLabs, T3 Code or the live bridge.

Run: cd companion/mac-bridge && /usr/bin/python3 -m unittest tests.test_desktop_assistant -q
"""

from __future__ import annotations

import http.client
import json
from pathlib import Path
import struct
import sys
import unittest
import uuid
from typing import Any, Dict, List, Optional, Tuple

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE))

import samrabbit_assistant as assistant  # noqa: E402
import samrabbit_inbox as inbox  # noqa: E402
import samrabbit_realtime_profile as profile  # noqa: E402
from test_assistant import REPLY, UTTERANCE, AssistantBase  # noqa: E402
from test_inbox import FakeProcesses  # noqa: E402
from test_mobile import DESKTOP, FakeHandler  # noqa: E402
from test_realtime import ANSWER, STREAM, RealtimeBase  # noqa: E402

MAC_NOW = "[Now: Thursday, October 8, 2026, 2:37 PM America/New_York · device: mac]"


class DesktopVoiceMixin:
    def use_temp_inbox(self) -> None:
        """The dock's list reads a temp HOME (never the real ~/.claude or ~/.codex) and no real ``ps``."""
        dock = inbox.InboxService(home=str(self.root / "home-dock"), processes=FakeProcesses(),  # type: ignore
                                  clock=self.clock.time)  # type: ignore[attr-defined]
        self.addCleanup(dock.close)  # type: ignore[attr-defined]
        self.server.inbox.close()  # type: ignore[attr-defined]
        dock.attach(self.server)  # type: ignore[attr-defined]
        self.server.inbox = dock  # type: ignore[attr-defined]

    def desk(self, text: str, *, conversation: Optional[str] = None, turn: Optional[str] = None,
             **kwargs: Any) -> Tuple[int, Dict[str, Any]]:
        body: Dict[str, Any] = {"text": text, "turnId": turn or str(uuid.uuid4())}
        if conversation:
            body["conversationId"] = conversation
        kwargs.setdefault("desktop", True)
        return self.call("POST", "/v1/desktop/assistant/turn", body, **kwargs)  # type: ignore[attr-defined]

    def mac_events(self, conversation: str) -> List[Dict[str, Any]]:
        store = self.server.sync.store  # type: ignore[attr-defined]
        return [json.loads(payload) for _cursor, payload in store.events_after(0, 500, "mac-" + conversation)]


class DesktopTurnTest(DesktopVoiceMixin, AssistantBase):
    def test_a_turn_from_the_desktop_app_is_a_mac_conversation(self) -> None:
        self.use_temp_inbox()
        self.script({"tools": [{"name": "get_status", "arguments": {}}], "reply": REPLY})
        status, value = self.desk(UTTERANCE)
        self.assertEqual(200, status, value)
        self.assertEqual(("claude", UTTERANCE, REPLY), (value["brain"], value["heard"], value["say"]))
        [call] = self.claude_calls()
        self.assertEqual(f"{MAC_NOW}\n{UTTERANCE}", call["stdin"], "the Mac's time line: device mac")
        self.assertEqual(assistant.MAC_SYSTEM_PROMPT, call["systemPrompt"], "the Mac's own prompt")
        self.assertEqual(str(self.workdir / "system-prompt-mac.md"),
                         call["args"][call["args"].index("--system-prompt-file") + 1])
        self.assertIn("One to three short sentences.", assistant.MAC_SYSTEM_PROMPT)
        self.assertIn("Agent Dock", assistant.MAC_SYSTEM_PROMPT)
        conversation = value["conversationId"]
        events = self.mac_events(conversation)
        self.assertEqual(["conversation.started", "message.user", "tool.completed", "message.assistant.done"],
                         [event["type"] for event in events])
        self.assertTrue(all(event["origin"] == "mac" for event in events))
        self.assertEqual(f"mac:{value['turnId']}:user", events[1]["id"])
        self.assertEqual([], self.events(conversation), "nothing in a Watch conversation")
        status, listing = self.call("GET", "/v1/sync/conversations", desktop=True)
        found = next(item for item in listing["conversations"] if item["conversationId"] == "mac-" + conversation)
        self.assertEqual(("Mac: " + UTTERANCE, REPLY), (found["title"], found["preview"]))
        # The phone's Chats show it too, and the dock lists it as a Mac chat.
        status, mine = self.call("GET", "/v1/mobile/conversations", token=self.phone)
        self.assertIn("mac-" + conversation, [item["conversationId"] for item in mine["conversations"]])
        status, dock = self.call("GET", "/v1/desktop/inbox", desktop=True)
        chat = next(item for item in dock["items"] if item["id"] == "chat:mac-" + conversation)
        self.assertEqual(("samrabbit", "Mac", "idle"), (chat["source"], chat["project"], chat["status"]))
        # The next turn resumes the same session, still the Mac's.
        status, again = self.desk("and the calendar?", conversation=conversation)
        self.assertEqual(200, status, again)
        second = self.claude_calls()[-1]
        self.assertEqual(call["session"]["new"], second["session"]["resume"])
        self.assertEqual(assistant.MAC_SYSTEM_PROMPT, second["systemPrompt"])
        # A watch turn meanwhile keeps the watch's prompt.
        status, watch = self.say(UTTERANCE)
        self.assertEqual(assistant.SYSTEM_PROMPT, self.claude_calls()[-1]["systemPrompt"])
        self.assertTrue(self.claude_calls()[-1]["stdin"].endswith("device: watch]\n" + UTTERANCE))
        self.assert_clean_log()

    def test_only_the_desktop_app_on_this_mac_may_talk(self) -> None:
        for kwargs in ({"desktop": False}, {"desktop": False, "token": self.watch},
                       {"desktop": False, "headers": {"X-SamRabbit-Desktop": "wrong-" + "x" * 30}}):
            with self.subTest(kwargs=list(kwargs)):
                status, value = self.desk(UTTERANCE, **kwargs)
                self.assertEqual((401, "unauthorized"), (status, value["error"]["code"]))
        status, value = self.desk(UTTERANCE, headers={"Origin": "http://evil.example"})
        self.assertEqual(403, status)
        body = json.dumps({"text": UTTERANCE, "turnId": str(uuid.uuid4())}).encode()
        handler = FakeHandler("192.168.1.20", "/v1/desktop/assistant/turn",
                              {"X-SamRabbit-Desktop": DESKTOP, "Content-Type": "application/json"}, body)
        self.service.serve(handler, "POST", "/v1/desktop/assistant/turn")
        self.assertEqual(403, handler.status, "another machine on the LAN is refused even with the desktop token")
        self.assertEqual([], self.claude_calls(), "no refused request reached the agent")
        status, value = self.call("GET", "/v1/desktop/assistant/nope", desktop=False)
        self.assertEqual(401, status, "an unknown desktop route asks for the desktop token, not a device token")
        status, value = self.call("GET", "/v1/desktop/assistant/nope", desktop=True)
        self.assertEqual(404, status)

    def test_session_announcements_cancel_and_end_with_the_desktop_token(self) -> None:
        status, warm = self.call("POST", "/v1/desktop/assistant/session", {}, desktop=True)
        self.assertEqual(200, status, warm)
        self.assertEqual(("claude", True), (warm["brain"], warm["ready"]))
        conversation = warm["conversationId"]
        self.script({"reply": REPLY})
        status, turn = self.desk(UTTERANCE, conversation=conversation)
        self.assertEqual((200, conversation), (status, turn["conversationId"]))
        status, value = self.call("GET", f"/v1/desktop/assistant/announcements?conversationId={conversation}",
                                  desktop=True)
        self.assertEqual(200, status, value)
        self.assertEqual({"items", "cursor"}, set(value))
        status, value = self.call("POST", "/v1/desktop/assistant/cancel", {"conversationId": conversation},
                                  desktop=True)
        self.assertEqual((200, {"ok": True, "cancelled": False}), (status, value), "nothing was being said")
        status, value = self.call("POST", "/v1/desktop/assistant/cancel",
                                  {"conversationId": conversation, "turnId": turn["turnId"]}, desktop=True)
        self.assertEqual((200, {"ok": True, "cancelled": False}), (status, value), "a cancel may name its turn")
        status, value = self.call("POST", "/v1/desktop/assistant/cancel",
                                  {"conversationId": conversation, "turnId": ["x"]}, desktop=True)
        self.assertEqual((400, "invalid_turn"), (status, value["error"]["code"]))
        status, value = self.call("POST", "/v1/desktop/assistant/end", {"conversationId": conversation}, desktop=True)
        self.assertEqual((200, {"ok": True, "ended": True}), (status, value))
        self.assertEqual("conversation.ended", self.mac_events(conversation)[-1]["type"])
        # The same warm-up from a reopened dock reuses nothing that ended.
        status, again = self.call("POST", "/v1/desktop/assistant/session", {}, desktop=True)
        self.assertNotEqual(conversation, again["conversationId"])

    def test_the_mac_and_the_watch_never_share_a_conversation(self) -> None:
        self.script({"reply": REPLY})
        status, mac = self.desk(UTTERANCE)
        self.assertEqual(200, status, mac)
        status, value = self.say("hello", conversation=mac["conversationId"])
        self.assertEqual((404, "conversation_not_found"), (status, value["error"]["code"]))
        status, watch = self.say(UTTERANCE)
        status, value = self.desk("hello", conversation=watch["conversationId"])
        self.assertEqual((404, "conversation_not_found"), (status, value["error"]["code"]))
        status, value = self.call("POST", "/v1/desktop/assistant/end", {"conversationId": watch["conversationId"]},
                                  desktop=True)
        self.assertEqual((200, {"ok": True, "ended": False}), (status, value), "the Mac cannot end the watch's")


class DesktopRealtimeTest(DesktopVoiceMixin, RealtimeBase):
    def stream_desk(self, body: Dict[str, Any]) -> Tuple[int, Any]:
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=30)
        connection.request("POST", "/v1/desktop/assistant/turn", body=json.dumps(body).encode(), headers={
            "X-SamRabbit-Desktop": DESKTOP, "Accept": STREAM, "Content-Type": "application/json"})
        response = connection.getresponse()
        if response.status != 200:
            value = json.loads(response.read() or b"{}")
            connection.close()
            return response.status, value
        out: List[Tuple[str, bytes]] = []
        while True:
            head = response.read(5)
            if len(head) < 5:
                break
            kind, length = chr(head[0]), struct.unpack(">I", head[1:5])[0]
            out.append((kind, response.read(length)))
        connection.close()
        return 200, out

    def test_a_streamed_desktop_turn_is_the_realtime_session_with_the_mac_addendum(self) -> None:
        self.rt_script({"say": ANSWER, "ms": 300})
        status, frames = self.stream_desk({"text": UTTERANCE, "turnId": str(uuid.uuid4())})
        self.assertEqual(200, status, frames)
        events = self.events_of(frames)
        self.assertEqual({"type": "heard", "text": UTTERANCE}, events[0])
        done = events[-1]
        self.assertEqual(("done", "realtime"), (done["type"], done["brain"]))
        self.assertEqual(300 * 32, len(self.audio_of(frames)), "PCM16 16 kHz mono, as for the watch")
        [call] = self.signaling.requests
        instructions = call["session"]["instructions"]
        self.assertTrue(instructions.startswith(profile.PRIMARY_VOICE_INSTRUCTION))
        self.assertTrue(instructions.endswith(profile.MAC_INSTRUCTION))
        self.assertNotIn(profile.WATCH_INSTRUCTION, instructions)
        self.assertEqual(f"{MAC_NOW}\n{UTTERANCE}", self.received()[0]["item"]["content"][0]["text"])
        names = [tool["name"] for tool in call["session"]["tools"]]
        for name in ("t3_list_threads", "t3_respond", "mac_open", "calendar_list_upcoming", "journal_add"):
            self.assertIn(name, names, "the same tools as the watch")
        conversation = done["conversationId"]
        self.assertEqual(["message.user", "message.assistant.done"],
                         [event["type"] for event in self.mac_events(conversation)
                          if event["type"].startswith("message.")])
        self.assert_clean_log(ANSWER)


if __name__ == "__main__":
    unittest.main()
