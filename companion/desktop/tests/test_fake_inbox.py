"""The Agent Dock's fixture inbox in dev/fake_sync_server.py (/v1/desktop/inbox*), on a throwaway port and token.

Run: python3 -m unittest discover -s companion/desktop/tests
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from typing import Any, Dict, Optional, Tuple

HERE = Path(__file__).resolve().parent
SERVER = HERE.parent / "dev" / "fake_sync_server.py"


def free_port() -> int:
    import socket
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class FakeInboxTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.tmp = tempfile.TemporaryDirectory()
        cls.token = secrets.token_hex(24)
        token_file = Path(cls.tmp.name, "desktop-token")
        token_file.write_text(cls.token + "\n")
        os.chmod(token_file, 0o600)
        cls.port = free_port()
        cls.proc = subprocess.Popen(
            [sys.executable, "-I", str(SERVER), "--port", str(cls.port), "--token-file", str(token_file),
             "--live-delay", "-1", "--inbox-tick", "0"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        deadline = time.time() + 20
        while time.time() < deadline:
            try:
                cls.call("GET", "/v1/desktop/inbox")
                return
            except OSError:
                time.sleep(0.2)
        raise RuntimeError("the fake server did not start")

    @classmethod
    def tearDownClass(cls) -> None:
        cls.proc.terminate()
        cls.proc.wait(timeout=10)
        if cls.proc.stdout:
            cls.proc.stdout.close()
        cls.tmp.cleanup()

    def setUp(self) -> None:
        self.call("POST", "/dev/inbox/reset", {})

    @classmethod
    def call(cls, method: str, path: str, body: Optional[Dict[str, Any]] = None, token: Optional[str] = "default",
             timeout: float = 10) -> Tuple[int, Dict[str, Any]]:
        request = urllib.request.Request("http://127.0.0.1:%d%s" % (cls.port, path), method=method,
                                         data=None if body is None else json.dumps(body).encode())
        if token == "default":
            token = cls.token
        if token:
            request.add_header("X-SamRabbit-Desktop", token)
        if body is not None:
            request.add_header("Content-Type", "application/json")
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        try:
            with opener.open(request, timeout=timeout) as response:
                return response.status, json.loads(response.read() or b"{}")
        except urllib.error.HTTPError as error:
            with error:
                return error.code, json.loads(error.read() or b"{}")

    def inbox(self) -> Dict[str, Any]:
        status, body = self.call("GET", "/v1/desktop/inbox")
        self.assertEqual(status, 200)
        return body

    def item(self, item_id: str) -> Dict[str, Any]:
        return next(i for i in self.inbox()["items"] if i["id"] == item_id)

    def test_needs_the_desktop_token(self) -> None:
        self.assertEqual(self.call("GET", "/v1/desktop/inbox", token=None)[0], 401)
        self.assertEqual(self.call("GET", "/v1/desktop/inbox", token="nope-" + "x" * 20)[0], 401)
        self.assertEqual(self.call("GET", "/dev/inbox/fake", token=None)[0], 401)

    def test_says_it_is_the_fake(self) -> None:
        # The dock's smoke driver (it approves and creates tasks) runs only against a server that answers this; the
        # window's tests count the inbox reads with it (a hidden window must not poll).
        status, body = self.call("GET", "/dev/inbox/fake")
        self.assertEqual((status, body["fake"]), (200, True))
        self.call("GET", "/v1/desktop/inbox")
        self.call("GET", "/v1/desktop/inbox?after=0&wait=0")
        self.assertEqual(self.call("GET", "/dev/inbox/fake")[1]["polls"], body["polls"] + 2)

    def test_inbox_has_every_source_and_status_in_order(self) -> None:
        body = self.inbox()
        items = body["items"]
        self.assertEqual({i["source"] for i in items}, {"t3", "claude", "codex", "samrabbit"})
        self.assertEqual({i["status"] for i in items}, {"needs-approval", "needs-input", "error", "done", "working", "idle"})
        # Counted like the bridge: "working" includes the SamRabbit chat that is streaming a reply.
        self.assertEqual(body["counts"], {"needsYou": 6, "working": 5, "total": 15, "dismissed": 0})
        self.assertTrue(all("dismiss" in i["can"] for i in items), "every item can be dismissed, as from the bridge")
        self.assertTrue(any(i["source"] == "samrabbit" and i["status"] == "working" for i in items))
        self.assertTrue(any(len(i["title"]) > 100 for i in items), "a long title")
        approval = next(i for i in items if i["pending"]["approvals"])
        self.assertEqual(len(approval["pending"]["approvals"][0]["options"]), 3)
        self.assertTrue(any(i["pending"]["inputs"] for i in items), "a question")
        rank = {"needs-approval": 0, "needs-input": 1, "error": 2, "working": 4}
        ranks = [3 if i["status"] == "done" and i["unread"] else rank.get(i["status"], 5) for i in items]
        self.assertEqual(ranks, sorted(ranks))
        self.assertFalse(any(key.startswith("_") for i in items for key in i))
        # Times were moved to now: the newest item is seconds old, not days.
        self.assertTrue(all(i["updatedAt"].endswith("Z") for i in items))

    def test_long_poll_waits_and_wakes_on_a_change(self) -> None:
        revision = self.inbox()["revision"]
        started = time.time()
        status, same = self.call("GET", "/v1/desktop/inbox?after=%d&wait=1" % revision)
        self.assertEqual((status, same["revision"]), (200, revision))
        self.assertGreaterEqual(time.time() - started, 0.9, "it waited for news")
        answers: Dict[str, Any] = {}

        def poll() -> None:
            answers["body"] = self.call("GET", "/v1/desktop/inbox?after=%d&wait=20" % revision, timeout=30)[1]

        waiter = threading.Thread(target=poll)
        waiter.start()
        time.sleep(0.5)
        self.call("POST", "/v1/desktop/inbox/items/t3:th_release_notes/seen", {})
        waiter.join(timeout=10)
        self.assertGreater(answers["body"]["revision"], revision)

    def test_actions_change_the_items(self) -> None:
        status, body = self.call("POST", "/v1/desktop/inbox/items/t3:th_pairing_redirect/approve",
                                 {"requestId": "req_run_tests", "decision": "accept"})
        self.assertEqual((status, body), (200, {"ok": True}))
        self.assertEqual(self.item("t3:th_pairing_redirect")["status"], "working")
        status, body = self.call("POST", "/v1/desktop/inbox/items/t3:th_pairing_redirect/approve",
                                 {"requestId": "req_run_tests", "decision": "accept"})
        self.assertEqual((status, body["error"]["code"]), (409, "not_supported"))
        status, _ = self.call("POST", "/v1/desktop/inbox/items/t3:th_waitlist_db/answer",
                              {"requestId": "req_db_choice", "answers": {"db": "Supabase"}})
        self.assertEqual(status, 200)
        self.assertEqual(self.item("t3:th_waitlist_db")["pending"]["inputs"], [])
        status, body = self.call("POST", "/v1/desktop/inbox/items/t3:th_release_notes/reply", {"text": "Ship it"})
        self.assertEqual((status, body["how"]), (202, "t3"))
        status, detail = self.call("GET", "/v1/desktop/inbox/items/t3:th_release_notes")
        self.assertEqual(detail["messages"][-1], {"role": "user", "text": "Ship it", "at": detail["messages"][-1]["at"]})
        status, _ = self.call("POST", "/v1/desktop/inbox/items/t3:th_snapshot_cache/stop", {})
        self.assertEqual((status, self.item("t3:th_snapshot_cache")["status"]), (200, "idle"))
        # As the real bridge: a T3 failure he has seen is settled (out of Needs you), its label kept.
        self.assertEqual(self.item("t3:th_watch_previews")["status"], "error")
        status, _ = self.call("POST", "/v1/desktop/inbox/items/t3:th_watch_previews/seen", {})
        seen = self.item("t3:th_watch_previews")
        self.assertEqual((status, seen["status"], seen["unread"], seen["statusLabel"]),
                         (200, "idle", False, "Failed · xcodebuild exited 65"))

    def test_dismiss_hides_until_it_changes_and_undo_brings_it_back(self) -> None:
        before = self.inbox()
        status, body = self.call("POST", "/v1/desktop/inbox/items/t3:th_watch_previews/dismiss", {})
        self.assertEqual((status, body["ok"], body["dismissed"]), (200, True, True))
        self.assertGreater(body["revision"], before["revision"])
        after = self.inbox()
        self.assertNotIn("t3:th_watch_previews", [i["id"] for i in after["items"]])
        self.assertEqual((after["counts"]["needsYou"], after["counts"]["total"], after["counts"]["dismissed"]),
                         (before["counts"]["needsYou"] - 1, before["counts"]["total"] - 1, 1))
        status, everything = self.call("GET", "/v1/desktop/inbox?include=dismissed")
        hidden = [i for i in everything["items"] if i.get("dismissed")]
        self.assertEqual([i["id"] for i in hidden], ["t3:th_watch_previews"])
        self.assertIn("undismiss", hidden[0]["can"])
        self.assertNotIn("dismiss", hidden[0]["can"])
        self.assertFalse(hidden[0]["unread"], "dismissing marks it seen")
        # The undo: back, as unread as it was.
        status, body = self.call("POST", "/v1/desktop/inbox/items/t3:th_watch_previews/undismiss", {})
        self.assertEqual((status, body["dismissed"]), (200, False))
        self.assertTrue(self.item("t3:th_watch_previews")["unread"])
        # It comes back by itself when it changes (a reply makes it work).
        self.call("POST", "/v1/desktop/inbox/items/t3:th_release_notes/dismiss", {})
        self.assertNotIn("t3:th_release_notes", [i["id"] for i in self.inbox()["items"]])
        self.call("POST", "/v1/desktop/inbox/items/t3:th_release_notes/reply", {"text": "One more thing"})
        self.assertEqual(self.item("t3:th_release_notes")["status"], "working")
        self.assertEqual(self.inbox()["counts"]["dismissed"], 0)
        # A refused action (dev): 503, nothing changes.
        self.call("POST", "/dev/inbox/refuse", {"actions": ["dismiss"]})
        status, body = self.call("POST", "/v1/desktop/inbox/items/t3:th_watch_previews/dismiss", {})
        self.assertEqual((status, body["error"]["code"]), (503, "dev_refused"))
        self.assertIn("t3:th_watch_previews", [i["id"] for i in self.inbox()["items"]])
        self.call("POST", "/dev/inbox/refuse", {"actions": []})
        self.assertEqual(self.call("POST", "/v1/desktop/inbox/items/t3:nope/dismiss", {})[0], 404)

    def test_live_sessions_and_open(self) -> None:
        status, body = self.call("POST", "/v1/desktop/inbox/items/codex:019a7788-99aa-4bbc-8cde-f00112233445/reply",
                                 {"text": "keep going"})
        self.assertEqual((status, body["error"]["code"]), (409, "session_live"))
        self.assertEqual(self.call("POST", "/v1/desktop/inbox/items/chat:c_sleep_chart/open", {})[1],
                         {"opened": True, "how": "desktop", "conversationId": "c_sleep_chart"})
        self.assertEqual(self.call("POST", "/v1/desktop/inbox/items/codex:019a2b3c-4d5e-6f70-8192-a3b4c5d6e7f8/open", {})[1]["how"],
                         "app")
        self.assertEqual(self.call("POST", "/v1/desktop/inbox/items/t3:nope/open", {})[0], 404)

    def test_targets_and_new(self) -> None:
        status, targets = self.call("GET", "/v1/desktop/inbox/targets")
        self.assertEqual(status, 200)
        self.assertEqual(targets["default"]["agent"], "claude")
        status, body = self.call("POST", "/v1/desktop/inbox/new",
                                 {"text": "Add a dark mode toggle", "projectId": "proj_website", "agent": "codex",
                                  "model": "gpt-5.5"})
        self.assertEqual(status, 202)
        created = self.item(body["itemId"])
        self.assertEqual((created["status"], created["project"], created["agent"]), ("working", "Website", "codex"))
        self.assertEqual(self.call("POST", "/v1/desktop/inbox/new", {"text": " "})[0], 400)
        self.assertEqual(self.call("POST", "/v1/desktop/inbox/new", {"text": "x", "projectId": "nope"})[0], 404)


if __name__ == "__main__":
    unittest.main()
