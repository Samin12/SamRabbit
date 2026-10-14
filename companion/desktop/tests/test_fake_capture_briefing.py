"""Voice notes and the morning brief in dev/fake_sync_server.py (dev/fake_capture.py, dev/fake_briefing.py), on a
throwaway port and token: the bridge's own shapes (companion/mac-bridge samrabbit_capture.py / samrabbit_briefing.py,
CONTRACTS-WAVE8 §A2, §A3), idempotent captures, the brief moved to today, its actions (only those an item `can`, a
draft link in the item's own Google account, no send), and that nothing leaves the fake.

Run: python3 -m unittest discover -s companion/desktop/tests
"""

from __future__ import annotations

import io
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.error
import urllib.request
import uuid
import wave
from datetime import datetime, timedelta
from typing import Any, Dict, Optional, Tuple

HERE = Path(__file__).resolve().parent
SERVER = HERE.parent / "dev" / "fake_sync_server.py"


def free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def wav(seconds: float, rate: int = 16000) -> bytes:
    out = io.BytesIO()
    with wave.open(out, "wb") as clip:
        clip.setnchannels(1)
        clip.setsampwidth(2)
        clip.setframerate(rate)
        clip.writeframes(b"\x00\x00" * int(seconds * rate))
    return out.getvalue()


class FakeCaptureBriefingTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.tmp = tempfile.TemporaryDirectory()
        cls.token = secrets.token_hex(24)
        token_file = Path(cls.tmp.name, "desktop-token")
        token_file.write_text(cls.token + "\n")
        os.chmod(token_file, 0o600)
        cls.port = free_port()
        env = dict(os.environ, SAMRABBIT_FAKE_CAPTURE_SAVE=str(Path(cls.tmp.name, "saved")))
        cls.proc = subprocess.Popen(
            [sys.executable, "-I", str(SERVER), "--port", str(cls.port), "--token-file", str(token_file),
             "--live-delay", "-1", "--inbox-tick", "0", "--empty"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, env=env)
        deadline = time.time() + 20
        while time.time() < deadline:
            try:
                cls.call("GET", "/dev/capture")
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
        self.call("POST", "/dev/capture/reset", {})
        self.call("POST", "/dev/capture", {"delay": 0.3})
        self.call("POST", "/dev/briefing/reset", {})

    @classmethod
    def call(cls, method: str, path: str, body: Any = None, token: Optional[str] = "default", headers: Optional[Dict[str, str]] = None,
             timeout: float = 15) -> Tuple[int, Dict[str, Any]]:
        data = body if isinstance(body, bytes) else (None if body is None else json.dumps(body).encode())
        request = urllib.request.Request("http://127.0.0.1:%d%s" % (cls.port, path), method=method, data=data)
        if token == "default":
            token = cls.token
        if token:
            request.add_header("X-SamRabbit-Desktop", token)
        if body is not None and not isinstance(body, bytes):
            request.add_header("Content-Type", "application/json")
        for key, value in (headers or {}).items():
            request.add_header(key, value)
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        try:
            with opener.open(request, timeout=timeout) as response:
                return response.status, json.loads(response.read() or b"{}")
        except urllib.error.HTTPError as error:
            with error:
                return error.code, json.loads(error.read() or b"{}")

    def capture(self, audio: bytes, capture_id: Optional[str] = None, content_type: str = "audio/wav") -> Tuple[int, Dict[str, Any]]:
        return self.call("POST", "/v1/desktop/capture", audio, headers={
            "Content-Type": content_type, "X-SamRabbit-Capture": capture_id or str(uuid.uuid4()),
            "X-SamRabbit-Captured-At": "2026-10-14T09:41:07-04:00", "X-SamRabbit-Source": "mac"})

    # ------------------------------------------------------------------ voice notes

    def test_needs_the_desktop_token(self) -> None:
        for path in ("/v1/desktop/captures", "/v1/desktop/briefing", "/dev/capture", "/dev/briefing"):
            self.assertEqual(self.call("GET", path, token=None)[0], 401, path)

    def test_a_note_is_received_then_routed(self) -> None:
        capture_id = str(uuid.uuid4())
        started = time.time()
        status, body = self.capture(wav(2.5), capture_id)
        self.assertEqual(status, 202)
        self.assertEqual((body["captureId"], body["state"], body["source"], body["kind"], body["say"]),
                         (capture_id, "received", "mac", "audio", "Sent."))
        self.assertEqual(set(body) - {"error", "retryAt"}, {"captureId", "state", "source", "kind", "capturedAt",
                                                           "receivedAt", "updatedAt", "heard", "outcome", "suggestion",
                                                           "say", "seen", "dismissed"}, "the bridge's view()")
        self.assertLess(time.time() - started, 1.0, "202 at once")
        status, body = self.call("GET", "/v1/desktop/capture/%s?wait=0" % capture_id)
        self.assertEqual((status, body["state"]), (200, "received"))
        status, body = self.call("GET", "/v1/desktop/capture/%s?wait=5" % capture_id)
        self.assertEqual(body["state"], "done", "a wait blocks until it is routed")
        self.assertEqual((body["outcome"]["kind"], body["outcome"]["title"], body["outcome"]["detail"]),
                         ("journal", "Journal", "Added to your journal."))
        self.assertTrue(body["heard"].startswith("Put this in my journal"))
        arrived = self.call("GET", "/dev/capture")[1]
        self.assertEqual(arrived["captures"][0]["seconds"], 2.5)
        self.assertEqual(arrived["captures"][0]["source"], "mac")
        self.assertEqual(arrived["captures"][0]["capturedAt"], "2026-10-14T09:41:07-04:00")
        self.assertLess(len(json.dumps(arrived)), 1000, "never the audio itself")
        self.assertTrue(Path(self.tmp.name, "saved", "capture-1.wav").exists(), "kept for the voice tests")

    def test_the_script_in_turn_and_a_suggestion(self) -> None:
        kinds = []
        for _ in range(4):
            capture_id = str(uuid.uuid4())
            self.capture(wav(1), capture_id)
            body = self.call("GET", "/v1/desktop/capture/%s?wait=5" % capture_id)[1]
            kinds.append(body["outcome"]["kind"])
            self.assertEqual(body["state"], "done", "the bridge's states: received, transcribed, done, failed")
            if body["outcome"]["kind"] == "note":
                self.assertEqual(body["suggestion"], {"action": "task", "label": "Start it as a T3 task?"})
                self.assertEqual(body["outcome"]["noteId"], "note:" + capture_id)
                acted = self.call("POST", "/v1/desktop/captures/%s/act" % capture_id, {"action": "task"})[1]
                self.assertEqual(acted["outcome"]["kind"], "task", "the suggestion done on a tap")
                self.assertEqual(acted["suggestion"], None)
                self.assertEqual(self.call("POST", "/v1/desktop/captures/%s/act" % capture_id, {"action": "undo"})[1]
                                 ["error"]["code"], "cannot_undo", "a task that started stays")
            if body["outcome"]["kind"] == "event":
                undone = self.call("POST", "/v1/desktop/captures/%s/act" % capture_id, {"action": "undo"})[1]
                self.assertEqual(undone["outcome"]["kind"], "note", "an event undone is kept as a note")
        self.assertEqual(kinds, ["journal", "task", "note", "event"])
        self.assertEqual(self.call("POST", "/v1/desktop/captures/%s/act" % uuid.uuid4(), {"action": "task"})[0], 404)
        self.assertEqual(self.call("POST", "/v1/desktop/captures/%s/act" % capture_id, {"action": "block"})[1]["error"]["code"],
                         "invalid_action", "a block suggestion has no act of its own")
        recent = self.call("GET", "/v1/desktop/captures?limit=2")[1]
        self.assertEqual((len(recent["captures"]), recent["pending"]), (2, 0))
        summary = self.call("GET", "/v1/desktop/summary")[1]["captures"]
        self.assertEqual((summary["available"], len(summary["recent"]), summary["failed"], summary["pending"]),
                         (True, 3, 0, 0))

    def test_the_same_id_is_the_same_note(self) -> None:
        capture_id = str(uuid.uuid4())
        audio = wav(1.2)
        self.assertEqual(self.capture(audio, capture_id)[0], 202)
        status, body = self.capture(audio, capture_id)
        self.assertEqual((status, body["captureId"]), (202, capture_id), "a retry is answered, not a second note")
        self.assertEqual(self.capture(wav(1.3), capture_id)[1]["error"]["code"], "capture_conflict")
        arrived = self.call("GET", "/dev/capture")[1]
        self.assertEqual((len(arrived["captures"]), arrived["repeats"]), (1, 1))

    def test_refuses_what_the_bridge_refuses(self) -> None:
        self.assertEqual(self.capture(wav(1), "not-a-uuid")[1]["error"]["code"], "invalid_capture_id")
        self.assertEqual(self.capture(b"RIFFnope")[1]["error"]["code"], "unsupported_audio")
        self.assertEqual(self.capture(b"x", content_type="text/plain")[1]["error"]["code"], "unsupported_audio")
        bad = self.call("POST", "/v1/desktop/capture", wav(1), headers={
            "Content-Type": "audio/wav", "X-SamRabbit-Capture": str(uuid.uuid4()), "X-SamRabbit-Source": "dock"})
        self.assertEqual(bad[1]["error"]["code"], "invalid_source")
        self.assertEqual(self.capture(wav(301, rate=8000))[1]["error"]["code"], "audio_too_long")
        status, body = self.call("POST", "/v1/desktop/capture", {"text": "Journal: a typed note"},
                                 headers={"X-SamRabbit-Capture": str(uuid.uuid4()), "X-SamRabbit-Source": "mac"})
        self.assertEqual(status, 202, "text works too (the R1 sends what it transcribed)")

    def test_modes(self) -> None:
        self.call("POST", "/dev/capture", {"mode": "outdated"})
        self.assertEqual(self.capture(wav(1))[0], 404, "a bridge without voice notes")
        self.call("POST", "/dev/capture", {"mode": "busy"})
        self.assertEqual(self.capture(wav(1))[0], 503)
        self.call("POST", "/dev/capture", {"mode": "no_speech"})
        capture_id = str(uuid.uuid4())
        self.capture(wav(1), capture_id)
        body = self.call("GET", "/v1/desktop/capture/%s?wait=5" % capture_id)[1]
        self.assertEqual((body["state"], body["outcome"]["kind"]), ("done", "nothing"), "nothing heard is done")
        self.call("POST", "/dev/capture", {"mode": "fail"})
        capture_id = str(uuid.uuid4())
        self.capture(wav(1), capture_id)
        body = self.call("GET", "/v1/desktop/capture/%s?wait=5" % capture_id)[1]
        self.assertEqual((body["state"], body["outcome"]["kind"], body["error"]["code"]), ("failed", "failed", "t3_not_connected"))
        self.assertEqual(self.call("GET", "/v1/desktop/capture/%s" % uuid.uuid4())[0], 404)

    def test_a_slow_bridge_and_its_outcome_reads(self) -> None:
        self.call("POST", "/dev/capture", {"hold": 0.6})
        started = time.monotonic()
        status, _ = self.capture(wav(1))
        self.assertEqual(status, 202)
        self.assertGreaterEqual(time.monotonic() - started, 0.55, "hold: the upload's answer comes late")
        self.call("POST", "/dev/capture", {"hold": 0})
        capture_id = str(uuid.uuid4())
        self.capture(wav(1), capture_id)
        before = self.call("GET", "/dev/capture")[1]["polls"]
        self.call("GET", "/v1/desktop/capture/%s?wait=5" % capture_id)
        self.assertEqual(self.call("GET", "/dev/capture")[1]["polls"], before + 1, "each outcome read is counted")

    def test_voice_notes_in_the_inbox(self) -> None:
        self.call("POST", "/dev/inbox/reset", {})
        before = self.call("GET", "/v1/desktop/inbox")[1]
        self.assertFalse(any(i["id"].startswith("note:") for i in before["items"]), "only on request")
        self.call("POST", "/dev/inbox/notes", {})
        inbox = self.call("GET", "/v1/desktop/inbox")[1]
        self.assertGreater(inbox["revision"], before["revision"])
        notes = {i["id"]: i for i in inbox["items"] if i["source"] == "note"}
        kept = notes["note:3f2b8c1e-7d4a-4e9b-8f21-6a5c0d9e1b47"]
        failed = notes["note:9c4e2a7b-1f3d-4b8e-a6c5-2d7f0e8b3a91"]
        # The bridge's own shape (samrabbit_capture inbox_items).
        self.assertEqual((kept["status"], kept["suggestion"]["action"], kept["can"]), ("needs-input", "task", ["act", "dismiss", "seen"]))
        self.assertEqual((failed["status"], failed["suggestion"]), ("error", None))
        self.assertEqual(kept["captureId"], kept["id"][5:])
        self.assertFalse(any(key.startswith("_") for key in kept))
        detail = self.call("GET", "/v1/desktop/inbox/items/%s" % kept["id"])[1]
        self.assertEqual([m["role"] for m in detail["messages"]], ["user", "assistant"])
        # Seen: a kept note no longer asks; a failed one stays an error (only out of the dock's count once seen).
        self.call("POST", "/v1/desktop/inbox/items/%s/seen" % failed["id"], {})
        failed_now = next(i for i in self.call("GET", "/v1/desktop/inbox")[1]["items"] if i["id"] == failed["id"])
        self.assertEqual((failed_now["status"], failed_now["unread"]), ("error", False))
        # Act: the suggestion (it leaves the inbox: it is a task now), a retry for the failed one, nothing for a block.
        status, body = self.call("POST", "/v1/desktop/inbox/items/%s/act" % kept["id"], {"action": "task"})
        self.assertEqual((status, body["capture"]["outcome"]["kind"]), (200, "task"))
        status, body = self.call("POST", "/v1/desktop/inbox/items/%s/act" % failed["id"], {})
        self.assertEqual((status, body["capture"]["state"]), (202, "received"), "a failed note is tried again")
        ids = [i["id"] for i in self.call("GET", "/v1/desktop/inbox")[1]["items"]]
        self.assertFalse(any(i.startswith("note:") for i in ids), "both left the inbox")
        self.call("POST", "/dev/inbox/notes", {})
        status, body = self.call("POST", "/v1/desktop/inbox/items/%s/act" % kept["id"], {"action": "block"})
        self.assertEqual((status, body["error"]["code"]), (400, "invalid_action"))
        status, body = self.call("POST", "/v1/desktop/inbox/items/%s/act" % kept["id"], {"action": "retry"})
        self.assertEqual((status, body["error"]["code"]), (409, "not_failed"))
        self.call("POST", "/dev/inbox/reset", {})

    # ------------------------------------------------------------------ the brief

    def test_the_brief_is_todays(self) -> None:
        status, brief = self.call("GET", "/v1/desktop/briefing")
        self.assertEqual(status, 200)
        today = datetime.now().astimezone().date().isoformat()
        self.assertEqual(brief["date"], today)
        self.assertTrue(brief["available"])
        self.assertEqual([s["id"] for s in brief["sections"]], ["doFirst", "today", "agents", "fyi"])
        self.assertEqual((brief["status"], brief["building"], brief["composed"]), ("ready", False, "claude"))
        self.assertTrue(brief["generatedAt"].startswith(today + "T11:01:00"), "moved by whole days too")
        self.assertEqual(brief["counts"]["emails"], 105)
        standup = brief["sections"][1]["items"][0]
        self.assertTrue(standup["startsAt"].startswith(today + "T09:30:00"), "clock times stay")
        self.assertEqual(brief["needsYou"], 4)
        for section in brief["sections"]:
            for item in section["items"]:
                self.assertEqual(item["section"], section["id"])
                self.assertLessEqual(len(item["title"]), 60, "verb-first titles, 60 characters at most")
                self.assertLessEqual(len(item["why"]), 100)
                self.assertTrue(1 <= len(item["actions"]) <= 2)
                self.assertTrue({"done", "dismiss"} <= set(item["can"]))
                self.assertTrue({a["type"] for a in item["actions"]} <= set(item["can"]))
                if "mail.google.com" in item.get("url", ""):
                    self.assertIn("authuser=", item["url"], "the bridge names the account on every Gmail link")
        self.assertEqual(brief["sections"][2]["items"][0]["itemId"], "t3:th_pairing_redirect")
        summary = self.call("GET", "/v1/desktop/summary")[1]["briefing"]
        self.assertEqual(summary, {"available": True, "date": today, "status": "ready", "revision": brief["revision"],
                                   "headline": brief["headline"], "needsYou": 4})

    def test_actions(self) -> None:
        brief = self.call("GET", "/v1/desktop/briefing")[1]
        first, second, conflict = brief["sections"][0]["items"]
        status, drafted = self.call("POST", "/v1/desktop/briefing/items/%s/act" % first["id"], {"action": "draft_reply"})
        self.assertEqual((status, drafted["ok"], drafted["item"]["state"]), (200, True, "drafted"))
        self.assertTrue(drafted["result"]["url"].startswith("https://mail.google.com/mail/?authuser=sam@example.com#drafts?compose="))
        self.assertEqual(drafted["revision"], brief["revision"] + 1)
        again = self.call("POST", "/v1/desktop/briefing/items/%s/act" % first["id"], {"action": "draft_reply"})[1]
        self.assertEqual(again["result"], drafted["result"], "a second tap answers what the first did")
        words = "Fix the failed Stripe payout. Stripe: the bank declined Monday’s $1,240 payout"
        tasked = self.call("POST", "/v1/desktop/briefing/items/%s/act" % second["id"], {"action": "make_task", "text": words})[1]
        self.assertTrue(tasked["result"]["itemId"].startswith("t3:"))
        self.assertEqual(self.call("POST", "/v1/desktop/briefing/items/%s/act" % second["id"], {"action": "remind"})[1]
                         ["error"]["code"], "unsupported_action", "only what the item can")
        later = datetime.now().astimezone().replace(microsecond=0) + timedelta(hours=2)
        reminded = self.call("POST", "/v1/desktop/briefing/items/%s/act" % conflict["id"],
                             {"action": "remind", "at": later.isoformat()})[1]
        self.assertEqual((reminded["item"]["state"], reminded["result"]["until"]), ("reminded", later.isoformat()))
        after = self.call("GET", "/v1/desktop/briefing")[1]
        self.assertEqual([i["state"] for i in after["sections"][0]["items"]], ["drafted", "tasked", "reminded"])
        self.assertEqual(after["sections"][0]["items"][0]["result"]["url"], drafted["result"]["url"], "kept on the item")
        self.assertEqual(after["revision"], brief["revision"] + 3)
        self.assertEqual(after["needsYou"], 1, "the agent")
        self.assertEqual(self.call("POST", "/v1/desktop/briefing/items/nope/act", {"action": "done"})[0], 404)
        self.assertEqual(self.call("POST", "/v1/desktop/briefing/items/%s/act" % first["id"], {"action": "send"})[1]["error"]["code"],
                         "invalid_action", "there is no send")
        acts = self.call("GET", "/dev/briefing")[1]["acts"]
        self.assertEqual([a["action"] for a in acts], ["draft_reply", "draft_reply", "make_task", "remind"],
                         "refusals change nothing")
        self.assertEqual(acts[2]["text"], words, "the task's words are kept for the tests")

    def test_long_poll_and_refresh(self) -> None:
        brief = self.call("GET", "/v1/desktop/briefing")[1]
        started = time.time()
        status, payload = self.call("POST", "/v1/desktop/briefing/refresh", {})
        self.assertEqual((status, payload["status"]), (202, "building"))
        newer = self.call("GET", "/v1/desktop/briefing?after=%d&wait=10" % brief["revision"])[1]
        self.assertEqual(newer["revision"], brief["revision"] + 1)
        self.assertLess(time.time() - started, 5)
        status, payload = self.call("POST", "/v1/desktop/briefing/refresh", {})
        self.assertEqual((status, payload["error"]["code"]), (429, "refresh_too_soon"), "once in 5 minutes")
        self.assertGreater(payload["error"]["retryAfter"], 0)

    def test_posts_leave_a_kept_alive_connection_clean(self) -> None:
        # The window's Refresh then reads the brief on the same connection: the POST's body must have been read (an
        # unread "{}" made the next request "{}GET …", 501).
        import http.client
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=15)
        headers = {"X-SamRabbit-Desktop": self.token, "Content-Type": "application/json"}
        try:
            for path in ("/dev/capture/reset", "/dev/briefing/reset", "/v1/desktop/briefing/refresh"):
                connection.request("POST", path, body=b"{}", headers=headers)
                response = connection.getresponse()
                response.read()
                self.assertIn(response.status, (200, 202), path)
                connection.request("GET", "/v1/desktop/briefing?wait=0", headers=headers)
                response = connection.getresponse()
                response.read()
                self.assertEqual(response.status, 200, "the request after %s" % path)
        finally:
            connection.close()

    def test_states_and_failures(self) -> None:
        self.call("POST", "/dev/briefing", {"status": "off"})
        brief = self.call("GET", "/v1/desktop/briefing")[1]
        self.assertEqual((brief["available"], brief["reason"]), (False, "briefing_turned_off"))
        self.call("POST", "/dev/briefing", {"status": "waiting"})
        brief = self.call("GET", "/v1/desktop/briefing")[1]
        self.assertEqual((brief["available"], brief["status"], "sections" in brief), (False, "waiting", False))
        self.assertEqual(self.call("GET", "/v1/desktop/summary")[1]["briefing"]["headline"], None)
        self.call("POST", "/dev/briefing", {"status": "ready", "fail": "draft_reply"})
        item = self.call("GET", "/v1/desktop/briefing")[1]["sections"][0]["items"][0]
        status, body = self.call("POST", "/v1/desktop/briefing/items/%s/act" % item["id"], {"action": "draft_reply"})
        self.assertEqual((status, body["error"]["code"]), (502, "gmail_failed"))
        self.assertEqual(self.call("GET", "/v1/desktop/briefing")[1]["sections"][0]["items"][0]["state"], "open")


if __name__ == "__main__":
    unittest.main()
