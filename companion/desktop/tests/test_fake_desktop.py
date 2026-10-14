"""The SamRabbit window's desktop routes in dev/fake_sync_server.py (dev/fake_desktop.py: summary, agenda, block,
journal, devices, ChatGPT status), on a throwaway port and token. The shapes are the bridge's (CONTRACTS-WAVE7 §A).

Run: python3 -m unittest discover -s companion/desktop/tests
"""

from __future__ import annotations

from datetime import datetime, timedelta
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
import tempfile
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


def parse(text: str) -> datetime:
    return datetime.fromisoformat(text.replace("Z", "+00:00"))


class FakeDesktopTest(unittest.TestCase):
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
                cls.call("GET", "/v1/desktop/summary")
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
        self.call("POST", "/dev/desktop/reset", {})

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

    def test_needs_the_desktop_token(self) -> None:
        for path in ("/v1/desktop/summary", "/v1/desktop/calendar/agenda", "/v1/desktop/devices",
                     "/v1/assistant/chatgpt/status", "/dev/desktop"):
            self.assertEqual(self.call("GET", path, token=None)[0], 401, path)

    def test_summary_is_the_phones_plus_r1_online_and_devices(self) -> None:
        status, body = self.call("GET", "/v1/desktop/summary")
        self.assertEqual(status, 200)
        for key in ("generatedAt", "mac", "r1", "t3", "calendar", "latestConversation", "journal", "transcribe",
                    "assistant", "devices"):
            self.assertIn(key, body)
        self.assertIsInstance(body["r1"]["online"], bool)
        self.assertTrue(body["r1"]["lastSeenAt"].endswith("Z"), "from the sample conversations")
        self.assertLessEqual(len(body["calendar"]["next"]), 3)
        self.assertEqual([d["platform"] for d in body["devices"]], ["ios", "watchos"])
        self.assertEqual(body["devices"][1]["parentId"], body["devices"][0]["deviceId"])
        self.assertEqual(body["assistant"]["brain"], "realtime")

    def test_agenda_by_days_from_now(self) -> None:
        status, body = self.call("GET", "/v1/desktop/calendar/agenda?days=7")
        self.assertEqual(status, 200)
        now = datetime.now().astimezone()
        events = body["events"]
        self.assertGreaterEqual(len(events), 8)
        for event in events:
            self.assertEqual(set(event), {"eventId", "title", "startsAt", "endsAt", "allDay", "location", "meetingUrl"})
            self.assertGreater(parse(event["endsAt"]), now, "nothing that has ended")
            self.assertLess(parse(event["startsAt"]), now + timedelta(days=7))
        starts = [parse(e["startsAt"]) for e in events]
        self.assertEqual(starts, sorted(starts))
        self.assertTrue(any(e["allDay"] for e in events))
        self.assertTrue(any(e["meetingUrl"] for e in events))
        short = self.call("GET", "/v1/desktop/calendar/agenda?days=1")[1]["events"]
        self.assertLessEqual(len(short), len(events))
        self.assertEqual(self.call("GET", "/v1/desktop/calendar/agenda?days=9")[0], 400)

    def test_block_joins_the_agenda(self) -> None:
        status, body = self.call("POST", "/v1/desktop/calendar/block", {"minutes": 45, "title": "  Deep   work "})
        self.assertEqual(status, 200)
        self.assertEqual(body["minutes"], 45)
        self.assertEqual(body["event"]["title"], "Deep work")
        span = parse(body["event"]["endsAt"]) - parse(body["event"]["startsAt"])
        self.assertEqual(span, timedelta(minutes=45))
        agenda = self.call("GET", "/v1/desktop/calendar/agenda?days=1")[1]
        self.assertIn(body["event"]["eventId"], [e["eventId"] for e in agenda["events"]])
        self.assertEqual(self.call("POST", "/v1/desktop/calendar/block", {"minutes": 2})[0], 400)
        self.assertEqual(self.call("POST", "/v1/desktop/calendar/block", {"minutes": True})[0], 400)

    def test_journal_is_kept_in_memory_only(self) -> None:
        status, body = self.call("POST", "/v1/desktop/journal", {"text": "Finished the Mac window."})
        self.assertEqual(status, 200)
        self.assertTrue(body["recorded"])
        self.assertRegex(body["time"], r"^\d\d:\d\d$")
        self.assertEqual(self.call("GET", "/dev/desktop")[1]["notes"], 1)
        self.assertEqual(self.call("POST", "/v1/desktop/journal", {"text": "   "})[0], 400)

    def test_unpairing_a_phone_unpairs_its_watch(self) -> None:
        devices = self.call("GET", "/v1/desktop/devices")[1]["devices"]
        phone = next(d for d in devices if d["platform"] == "ios")
        self.assertEqual(self.call("DELETE", "/v1/desktop/devices/" + phone["deviceId"]), (200, {"ok": True, "revoked": 2}))
        self.assertEqual(self.call("GET", "/v1/desktop/devices")[1]["devices"], [])
        self.assertEqual(self.call("DELETE", "/v1/desktop/devices/" + phone["deviceId"])[0], 404)
        self.assertEqual(self.call("DELETE", "/v1/desktop/devices/..%2Fetc")[0], 404)

    def test_chatgpt_through_the_codex_login_and_the_dev_states(self) -> None:
        body = self.call("GET", "/v1/assistant/chatgpt/status")[1]
        self.assertTrue(body["connected"])
        self.assertEqual(body["source"], "codex")
        self.call("POST", "/dev/desktop", {"chatgpt": "off", "calendar": False})
        self.assertFalse(self.call("GET", "/v1/assistant/chatgpt/status")[1]["connected"])
        status, error = self.call("GET", "/v1/desktop/calendar/agenda?days=7")
        self.assertEqual(status, 503)
        self.assertEqual(error["error"]["code"], "calendar_unavailable")
        summary = self.call("GET", "/v1/desktop/summary")[1]
        self.assertFalse(summary["calendar"]["available"])
        self.assertEqual(summary["assistant"]["brain"], "claude")


if __name__ == "__main__":
    unittest.main()
