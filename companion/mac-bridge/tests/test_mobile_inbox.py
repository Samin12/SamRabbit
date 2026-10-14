"""The iPhone's inbox (``/v1/mobile/inbox*``, CONTRACTS-WAVE7) end to end against the Agent Dock's fakes.

The dock's list, revisions, long poll, items and actions (``test_inbox.py``) for a paired phone's own token from the
LAN or the tailnet: the same answers, except that ``open`` is the Mac's alone (never in the phone's ``can``; ``/open``
answers 409 and opens nothing), a Claude or Codex reply that starts a Terminal window on the Mac says so, and what the
phone marks seen is seen in the dock too. The same fakes as the dock's tests: a fake T3 server, a temp HOME with
synthetic Claude Code and Codex sessions, a fake process table and a launcher that only records (nothing is ever
launched). Nothing here reaches the real T3 Code, Claude Code, Codex, the user's HOME or the live bridge.

Run: cd companion/mac-bridge && /usr/bin/python3 -m unittest tests.test_mobile_inbox -q
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import sys
import threading
import time
import unittest
from typing import Any, Dict, List, Optional, Tuple

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE))

import samrabbit_inbox as inbox  # noqa: E402
import test_inbox as dock_tests  # noqa: E402
from test_inbox import IDS, REPLY, SECRET_ANSWER, SECRET_PROMPT, InboxBase, claude_text, claude_user  # noqa: E402
from test_mobile import DESKTOP, NOW, TOKEN, FakeHandler  # noqa: E402

INTERNAL = "internal-assistant-token-" + "i" * 30


class _AssistantTools:
    """Stands in for the voice assistant's ``internal_device``: its tools' own token, from loopback."""

    def internal_device(self, presented: str, _address: str) -> Optional[Dict[str, Any]]:
        return {"deviceId": "assistant", "platform": "internal", "internal": True} if presented == INTERNAL else None


class PhoneInboxBase(InboxBase):
    """``InboxBase`` with a paired iPhone."""

    def setUp(self) -> None:
        super().setUp()
        self.phone = self.pair()["token"]

    def phone_inbox(self, query: str = "") -> Dict[str, Any]:
        status, value = self.call("GET", "/v1/mobile/inbox" + query, token=self.phone)
        self.assertEqual(200, status, value)
        return value

    def phone_act(self, item_id: str, action: str, body: Any = None) -> Tuple[int, Dict[str, Any]]:
        return self.call("POST", f"/v1/mobile/inbox/items/{item_id}/{action}", body if body is not None else {},
                         token=self.phone)

    def dispatched(self, kind: str) -> List[Dict[str, Any]]:
        return [command for command in self.fake_t3.dispatched if command["type"] == kind]


# ====================================================================== auth


class PhoneAuthTest(PhoneInboxBase):
    def test_every_phone_inbox_route_needs_a_paired_device(self) -> None:
        routes = [("GET", "/v1/mobile/inbox", None), ("GET", "/v1/mobile/inbox?after=1&wait=1", None),
                  ("GET", "/v1/mobile/inbox/targets", None), ("GET", "/v1/mobile/inbox/items/t3:t-done", None),
                  ("POST", "/v1/mobile/inbox/new", {"text": SECRET_PROMPT}),
                  ("POST", "/v1/mobile/inbox/items/t3:t-approval/approve",
                   {"requestId": "req-approve-1", "decision": "accept"}),
                  ("POST", "/v1/mobile/inbox/items/t3:t-input/answer",
                   {"requestId": "req-input-1", "answers": {"q1": "SQLite"}}),
                  ("POST", "/v1/mobile/inbox/items/t3:t-done/reply", {"text": REPLY}),
                  ("POST", "/v1/mobile/inbox/items/t3:t-running/stop", {}),
                  ("POST", "/v1/mobile/inbox/items/t3:t-done/seen", {}),
                  ("POST", "/v1/mobile/inbox/items/t3:t-done/open", {}),
                  ("GET", "/v1/mobile/inbox/nope", None), ("DELETE", "/v1/mobile/inbox", None)]
        for method, path, body in routes:
            for kwargs in ({}, {"token": TOKEN}, {"token": DESKTOP}, {"desktop": True}, {"token": self.phone[:-1]}):
                with self.subTest(method=method, path=path, kwargs=sorted(kwargs)):
                    status, value = self.call(method, path, body, **kwargs)
                    self.assertEqual((401, "unauthorized"), (status, value["error"]["code"]))
        self.assertEqual([], self.fake_t3.dispatched, "a refused request dispatched nothing")
        self.assertEqual([], self.recorder.calls, "nor opened anything")
        status, headers, _raw = self.request("GET", "/v1/mobile/inbox")
        self.assertEqual((401, 'Bearer realm="samrabbit-mobile"'), (status, headers.get("WWW-Authenticate")),
                         "answered like the rest of the mobile API")
        # From the LAN or the tailnet with the phone's token: in; from anywhere else: refused even with it.
        for address, expected in (("192.168.1.20", 200), ("100.101.102.103", 200), ("8.8.8.8", 403)):
            with self.subTest(address=address):
                handler = FakeHandler(address, "/v1/mobile/inbox", {"Authorization": "Bearer " + self.phone})
                self.inbox.serve(handler, "GET", "/v1/mobile/inbox")
                self.assertEqual(expected, handler.status, handler.json())
        # The phone's token opens none of the dock's routes, and the dock's none of the phone's (above).
        status, value = self.call("GET", "/v1/desktop/inbox", token=self.phone)
        self.assertEqual(401, status, value)
        self.assertEqual(404, self.call("GET", "/v1/mobile/inbox/nope", token=self.phone)[0])
        self.assertEqual(405, self.call("DELETE", "/v1/mobile/inbox", token=self.phone)[0])

    def test_the_assistants_own_tools_cannot_read_the_inbox(self) -> None:
        self.service.assistant = _AssistantTools()
        try:
            status, value = self.call("GET", "/v1/mobile/inbox", token=INTERNAL)
            self.assertEqual((403, "forbidden"), (status, value["error"]["code"]))
            status, value = self.call("POST", "/v1/mobile/inbox/items/t3:t-done/reply", {"text": REPLY},
                                      token=INTERNAL)
            self.assertEqual((403, "forbidden"), (status, value["error"]["code"]))
        finally:
            self.service.assistant = None
        self.assertEqual([], self.fake_t3.dispatched)


# ====================================================================== the list


class PhoneListTest(PhoneInboxBase):
    def test_the_phone_gets_the_docks_list_without_open(self) -> None:
        self.build_world()
        self.inbox.refresh(force=True)
        dock = self.get_inbox()
        phone = self.phone_inbox()
        self.assertEqual({"revision", "updatedAt", "counts", "sources", "items"}, set(phone))
        self.assertEqual((dock["revision"], dock["updatedAt"], dock["counts"], dock["sources"]),
                         (phone["revision"], phone["updatedAt"], phone["counts"], phone["sources"]),
                         "one list, one revision for the dock and the phone")
        self.assertEqual([item["id"] for item in dock["items"]], [item["id"] for item in phone["items"]])
        for mine, theirs in zip(phone["items"], dock["items"]):
            with self.subTest(item=mine["id"]):
                self.assertEqual([action for action in theirs["can"] if action != "open"], mine["can"])
                self.assertEqual(dict(theirs, can=mine["can"]), mine, "everything else is the dock's")
        self.assertTrue({"t3", "claude", "codex"} <= {item["source"] for item in phone["items"]},
                        "Claude Code and Codex sessions on the phone too")
        items = self.by_id(phone)
        self.assertEqual(["approve", "reply", "stop"], items["t3:t-approval"]["can"])
        self.assertEqual(["answer", "reply", "stop"], items["t3:t-input"]["can"])
        self.assertEqual(["reply"], items["claude:" + IDS["done"]]["can"], "nobody runs it: a reply resumes it")
        self.assertEqual([], items["claude:" + IDS["waiting"]]["can"], "a prompt in a terminal: only the Mac answers")
        self.assertEqual([], items["codex:" + IDS["desk"]]["can"], "Codex Desktop owns its threads")
        self.assertIn("open", self.by_id(self.get_inbox())["t3:t-approval"]["can"],
                      "the dock's own list is untouched: the phone's view is a copy")
        self.assert_log_clean(SECRET_PROMPT, SECRET_ANSWER, "5521")
        self.assertIn("GET /v1/mobile/inbox 200", self.log.getvalue())

    def test_the_phone_long_polls_the_same_revisions(self) -> None:
        self.build_world()
        start = self.phone_inbox()
        answers: List[Tuple[float, Dict[str, Any]]] = []

        def poll() -> None:
            began = time.monotonic()
            value = self.phone_inbox(f"?after={start['revision']}&wait=20")
            answers.append((time.monotonic() - began, value))

        waiter = threading.Thread(target=poll)
        waiter.start()
        time.sleep(0.6)
        self.assertTrue(waiter.is_alive(), "it waits while nothing changes")
        path = self.project_dir / (IDS["done"] + ".jsonl")
        with open(path, "a") as handle:
            handle.write(json.dumps(claude_user(NOW, "one more thing", session=IDS["done"])) + "\n")
        os.utime(path, (NOW - 1, NOW - 1))
        waiter.join(timeout=15)
        self.assertFalse(waiter.is_alive())
        took, value = answers[0]
        self.assertLess(took, 10.0)
        self.assertEqual(start["revision"] + 1, value["revision"])
        self.assertEqual(value["revision"], self.get_inbox()["revision"], "the dock sees the same revision")
        began = time.monotonic()
        again = self.phone_inbox(f"?after={value['revision']}&wait=1")
        self.assertGreaterEqual(time.monotonic() - began, 0.9, "nothing new: it answers after its wait")
        self.assertEqual(value["revision"], again["revision"])

    def test_an_item_with_its_last_messages(self) -> None:
        self.build_world()
        self.phone_inbox()
        status, value = self.call("GET", "/v1/mobile/inbox/items/t3:t-approval", token=self.phone)
        self.assertEqual(200, status, value)
        status, dock = self.call("GET", "/v1/desktop/inbox/items/t3:t-approval", desktop=True)
        self.assertEqual(({"item", "messages"}, dock["messages"]), (set(value), value["messages"]))
        self.assertEqual(["approve", "reply", "stop"], value["item"]["can"])
        self.assertEqual(["req-approve-1"], [entry["requestId"] for entry in value["item"]["pending"]["approvals"]])
        status, value = self.call("GET", "/v1/mobile/inbox/items/claude:" + IDS["done"], token=self.phone)
        self.assertEqual(200, status, value)
        self.assertEqual([("user", SECRET_PROMPT), ("assistant", "Looking at it.\n\n" + SECRET_ANSWER)],
                         [(entry["role"], entry["text"]) for entry in value["messages"]])
        self.assertEqual(["reply"], value["item"]["can"])
        status, value = self.call("GET", "/v1/mobile/inbox/items/claude:" + IDS["sdk"], token=self.phone)
        self.assertEqual((404, "item_not_found"), (status, value["error"]["code"]))


# ====================================================================== seen


class PhoneSeenTest(PhoneInboxBase):
    def test_what_the_phone_marks_seen_is_seen_in_the_dock(self) -> None:
        self.build_world()
        self.get_inbox()  # the first look: everything there is seen
        with self.fake_t3.lock:
            thread = self.fake_t3.get_thread("t-done")
            thread["latestTurn"]["completedAt"] = thread["updatedAt"] = "2026-10-08T18:30:00.000Z"
        self.hub.invalidate()
        path = self.project_dir / (IDS["done"] + ".jsonl")
        with open(path, "a") as handle:
            handle.write(json.dumps(claude_user(NOW - 100, "and the docs?", session=IDS["done"])) + "\n")
            handle.write(json.dumps(claude_text(NOW - 90, "Docs updated.", session=IDS["done"],
                                                message_id="msg_2")) + "\n")
        os.utime(path, (NOW - 90, NOW - 90))
        self.inbox.refresh(force=True)
        items = self.by_id(self.phone_inbox())
        for item_id in ("t3:t-done", "claude:" + IDS["done"]):
            with self.subTest(item=item_id):
                self.assertTrue(items[item_id]["unread"])
                self.assertIn("seen", items[item_id]["can"])
                status, answer = self.phone_act(item_id, "seen")
                self.assertEqual((200, {"ok": True}), (status, answer))
        self.inbox.refresh(force=True)
        for name, listing in (("dock", self.get_inbox()), ("phone", self.phone_inbox())):
            items = self.by_id(listing)
            for item_id in ("t3:t-done", "claude:" + IDS["done"]):
                with self.subTest(view=name, item=item_id):
                    self.assertFalse(items[item_id]["unread"])
                    self.assertNotIn("seen", items[item_id]["can"])
        self.assertEqual([], self.fake_t3.dispatched, "seen dispatches nothing to T3")


# ====================================================================== T3 from the phone


class PhoneT3ActionTest(PhoneInboxBase):
    def test_approve_answer_reply_stop_and_new_dispatch_what_t3_expects(self) -> None:
        self.phone_inbox()
        status, value = self.phone_act("t3:t-approval", "approve", {"requestId": "req-approve-1", "decision": "accept"})
        self.assertEqual((200, {"ok": True, "threadId": "t-approval", "requestId": "req-approve-1",
                                "decision": "accept"}), (status, value))
        [command] = self.dispatched("thread.approval.respond")
        self.assertEqual(("t-approval", "req-approve-1", "accept"),
                         (command["threadId"], command["requestId"], command["decision"]))
        status, value = self.phone_act("t3:t-input", "answer",
                                       {"requestId": "req-input-1", "answers": {"q1": "SQLite"}})
        self.assertEqual(200, status, value)
        [command] = self.dispatched("thread.user-input.respond")
        self.assertEqual(("t-input", {"q1": "sqlite"}), (command["threadId"], command["answers"]))
        status, value = self.phone_act("t3:t-done", "reply", {"text": REPLY})
        self.assertEqual((202, {"ok": True, "how": "t3", "threadId": "t-done"}), (status, value))
        [command] = self.dispatched("thread.turn.start")
        self.assertEqual(("t-done", REPLY), (command["threadId"], command["message"]["text"]))
        status, value = self.phone_act("t3:t-running", "stop")
        self.assertEqual(200, status, value)
        [command] = self.dispatched("thread.turn.interrupt")
        self.assertEqual(("t-running", "turn-active-1"), (command["threadId"], command["turnId"]))
        status, value = self.phone_act("t3:t-approval", "approve", {"requestId": "req-approve-1"})
        self.assertEqual((400, "invalid_decision"), (status, value["error"]["code"]))
        # Where a new task can go, and a new one.
        status, targets = self.call("GET", "/v1/mobile/inbox/targets", token=self.phone)
        self.assertEqual(200, status, targets)
        self.assertEqual(self.call("GET", "/v1/desktop/inbox/targets", desktop=True)[1], targets)
        status, value = self.call("POST", "/v1/mobile/inbox/new", {"text": SECRET_PROMPT, "projectId": "p-site",
                                                                   "agent": "codex", "model": "gpt-6.1"},
                                  token=self.phone)
        self.assertEqual(202, status, value)
        self.assertEqual(("t3:" + value["threadId"], "p-site", "codex", "gpt-6.1"),
                         (value["itemId"], value["projectId"], value["agent"], value["model"]))
        create, turn = self.fake_t3.dispatched[-2:]
        self.assertEqual(("thread.create", {"instanceId": "codex_cli", "model": "gpt-6.1"}),
                         (create["type"], create["modelSelection"]))
        self.assertEqual(("thread.turn.start", SECRET_PROMPT), (turn["type"], turn["message"]["text"]))
        self.assertEqual("working", self.by_id(self.phone_inbox())[value["itemId"]]["status"],
                         "the new task shows under Working at once")
        # Opening is the Mac's: nothing comes up there because of the phone.
        status, value = self.phone_act("t3:t-done", "open")
        self.assertEqual((409, "unsupported_action"), (status, value["error"]["code"]))
        self.assertEqual([], self.recorder.calls)
        self.assert_log_clean(REPLY, SECRET_PROMPT, "5521")
        log = self.log.getvalue()
        for label in ("POST /v1/mobile/inbox/items/{id}/approve 200", "POST /v1/mobile/inbox/items/{id}/reply 202",
                      "POST /v1/mobile/inbox/new 202", "POST /v1/mobile/inbox/items/{id}/open 409"):
            self.assertIn(label, log)
        self.assertNotIn("t-approval", log, "route templates only: no item ids")


# ====================================================================== Claude Code and Codex from the phone


class PhoneSessionTest(PhoneInboxBase):
    script_argv = dock_tests.SessionActionTest.script_argv  # what the Terminal window's script would run

    def setUp(self) -> None:
        super().setUp()
        self.build_world()
        self.phone_inbox()

    def test_a_live_session_opens_nothing_on_the_mac(self) -> None:
        for name in ("waiting", "busy"):
            with self.subTest(session=name):
                status, value = self.phone_act("claude:" + IDS[name], "reply", {"text": REPLY})
                self.assertEqual((409, "session_live"), (status, value["error"]["code"]))
                self.assertIn("on the Mac", value["error"]["message"])
        for item_id in ("claude:" + IDS["waiting"], "claude:" + IDS["done"], "codex:" + IDS["desk"],
                        "codex:" + IDS["cli_done"]):
            with self.subTest(open=item_id):
                status, value = self.phone_act(item_id, "open")
                self.assertEqual((409, "unsupported_action"), (status, value["error"]["code"]))
        status, value = self.phone_act("codex:" + IDS["desk"], "reply", {"text": REPLY})
        self.assertEqual((409, "unsupported_action"), (status, value["error"]["code"]), "Codex Desktop owns it")
        self.assertIn("ChatGPT app", value["error"]["message"])
        status, value = self.phone_act("claude:" + IDS["done"], "approve", {"decision": "accept"})
        self.assertEqual((409, "unsupported_action"), (status, value["error"]["code"]))
        self.assertEqual([], self.recorder.calls, "nothing came up on the Mac's screen")

    def test_a_reply_to_a_session_nobody_runs_continues_in_terminal_on_the_mac(self) -> None:
        item_id = "claude:" + IDS["done"]
        status, value = self.phone_act(item_id, "reply", {"text": REPLY})
        self.assertEqual((202, {"ok": True, "how": "terminal",
                                "message": "It continues in a new Terminal window on the Mac."}), (status, value))
        [call] = self.recorder.calls
        self.assertEqual(["/usr/bin/open", "-a", "Terminal"], call[:3])
        folder, argv = self.script_argv()
        self.assertEqual((str(self.cwd), ["/opt/test/bin/claude", "--resume", IDS["done"], "--", REPLY]),
                         (folder, argv), "as from the dock: the reply is the prompt, the CLI's own prompts stay")
        item = self.by_id(self.phone_inbox())[item_id]
        self.assertEqual((True, []), (item["live"], item["can"]), "its Terminal window is starting: live")
        for answer in (self.phone_act(item_id, "reply", {"text": REPLY}), self.act(item_id, "reply", {"text": REPLY})):
            self.assertEqual((409, "session_live"), (answer[0], answer[1]["error"]["code"]),
                             "pressed again on the phone or in the dock: never a second CLI")
        self.assertEqual(1, len(self.recorder.scripts))
        status, value = self.phone_act("codex:" + IDS["cli_done"], "reply", {"text": REPLY})
        self.assertEqual(202, status, value)
        self.assertEqual(["/opt/test/bin/codex", "resume", IDS["cli_done"], "--", REPLY], self.script_argv()[1])
        self.assert_log_clean(REPLY, "5521", str(self.cwd))
        self.assertIn("inbox continued a claude session in Terminal (from the phone)", self.log.getvalue())

    def test_when_the_mac_cannot_tell_what_runs_the_phone_starts_nothing(self) -> None:
        # ps failed: the "busy" session's plain `claude` may still be running it.
        self.processes.broken = True
        with self.inbox._lock:  # noqa: SLF001
            self.inbox._live = (-1e12, {})  # noqa: SLF001
        self.inbox.refresh(force=True)
        items = self.by_id(self.phone_inbox())
        for item_id in ("claude:" + IDS["busy"], "claude:" + IDS["done"]):
            with self.subTest(item=item_id):
                self.assertNotIn("reply", items[item_id]["can"])
                status, value = self.phone_act(item_id, "reply", {"text": REPLY})
                self.assertEqual((503, "session_check_failed"), (status, value["error"]["code"]))
                self.assertIn("on the Mac", value["error"]["message"])
        self.assertEqual([], self.recorder.calls, "nothing came up on the Mac's screen")

    def test_a_copy_that_is_not_the_installed_one_says_nothing_was_opened(self) -> None:
        dry = inbox.make_service(installed=False)
        self.addCleanup(dry.close)
        dry.home = str(self.home)
        dry.claude = inbox.ClaudeSessions(str(self.claude_root))
        dry.codex = inbox.CodexSessions(str(self.codex_root / "sessions"))
        dry.processes = self.processes
        dry._clock = self.clock.time  # noqa: SLF001
        dry.attach(self.server)
        self.server.inbox = dry
        dry.refresh(force=True)
        status, value = self.phone_act("claude:" + IDS["done"], "reply", {"text": REPLY})
        self.assertEqual((202, {"ok": True, "how": "terminal", "dryRun": True,
                                "message": "A test copy of the Mac bridge: no Terminal window was opened."}),
                         (status, value))
        self.assertEqual([], self.recorder.calls)


if __name__ == "__main__":
    unittest.main()
