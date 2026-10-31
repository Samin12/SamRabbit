from __future__ import annotations

import json
from pathlib import Path
import re
import unittest
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from sam_runtime.api.announcement_routes import AnnouncementRoutes
from sam_runtime.api.events import RuntimeEventStream
from sam_runtime.api.http_server import RuntimeHttpServer
from sam_runtime.api.t3_routes import T3Routes
from sam_runtime.security.pairing import PairingAuthority
from sam_runtime.storage.lifecycle_repository import LifecycleRepository

from t3_fixtures import (
    PAIRING_CODE,
    FakeT3Server,
    approval_requested,
    command_item,
    detail,
    input_requested,
    make_service,
    message,
    thread,
)


LOCAL_TOKEN = "l" * 43
ORIGIN = "https://r1.local:8443"


class T3RouteTest(unittest.TestCase):
    def setUp(self) -> None:
        self.fake = FakeT3Server().__enter__()
        self.service, self.outbox, _, database, self.directory = make_service()
        self.pairing = PairingAuthority()
        lifecycle = LifecycleRepository(database)
        lifecycle.record_start()
        self.server = RuntimeHttpServer(
            host="127.0.0.1", port=0, token=LOCAL_TOKEN,
            health=lambda: {"status": "ready"}, lifecycle=lifecycle, events=RuntimeEventStream(),
            pairing=self.pairing, t3=T3Routes(self.service), announcements=AnnouncementRoutes(self.outbox),
        )
        self.server.start()
        self.base = f"http://127.0.0.1:{self.server.port}"
        self.bodies: list[str] = []

    def tearDown(self) -> None:
        self.server.stop()
        self.fake.__exit__()
        self.directory.cleanup()

    def _call(self, method: str, path: str, body: object | None = None, *, bearer: bool = True, browser: object | None = None,
              csrf: bool = True) -> tuple[int, dict[str, object]]:
        headers = {"Content-Type": "application/json"}
        if bearer:
            headers["Authorization"] = f"Bearer {LOCAL_TOKEN}"
        if browser is not None:
            headers.update({"Cookie": f"sam_session={browser.token}", "X-SAM-Forwarded-Origin": ORIGIN, "Origin": ORIGIN})
            if csrf:
                headers["X-CSRF-Token"] = browser.csrf_token
        data = json.dumps(body).encode() if body is not None else (b"" if method == "POST" else None)
        request = Request(self.base + path, data=data, headers=headers, method=method)
        try:
            with urlopen(request, timeout=10) as response:
                raw = response.read().decode()
                status = response.status
        except HTTPError as error:
            raw = error.read().decode()
            status = error.code
        self.bodies.append(raw)
        return status, json.loads(raw) if raw else {}

    def _browser(self) -> object:
        code = self.pairing.current_code()
        return self.pairing.pair(code.value, ORIGIN, ORIGIN)

    def test_management_routes_need_a_paired_session_and_csrf(self) -> None:
        self.assertEqual(401, self._call("GET", "/v1/management/t3", bearer=False)[0])
        status, body = self._call("GET", "/v1/management/t3")
        self.assertEqual((403, "browser_session_denied"), (status, body["error"]["code"]))
        browser = self._browser()
        status, body = self._call("GET", "/v1/management/t3", browser=browser)
        self.assertEqual(200, status)
        self.assertEqual("http://192.168.1.183:3774", body["defaultServerUrl"])
        self.assertFalse(body["connected"])
        connect = {"serverUrl": self.fake.url, "pairingCode": PAIRING_CODE}
        self.assertEqual(403, self._call("POST", "/v1/management/t3/connect", connect, browser=browser, csrf=False)[0])
        self.assertEqual(403, self._call("POST", "/v1/management/t3/connect", connect)[0])
        status, body = self._call("POST", "/v1/management/t3/connect", connect, browser=browser)
        self.assertEqual(200, status, body)
        self.assertTrue(body["connected"])
        self.assertEqual("Test Mac", body["label"])
        self.assertEqual("2026-11-06T17:25:15.183Z", body["expiresAt"])
        self.assertEqual(["orchestration:read", "orchestration:operate"], body["scopes"])
        status, body = self._call("POST", "/v1/management/t3/connect", connect, browser=browser)
        self.assertEqual((400, "t3_pairing_rejected"), (status, body["error"]["code"]))
        status, body = self._call("POST", "/v1/management/t3/disconnect", {}, browser=browser)
        self.assertEqual(200, status)
        self.assertFalse(body["connected"])
        self._assert_no_token_leaked()

    def test_device_routes_are_bearer_only_and_follow_the_contract(self) -> None:
        status, body = self._call("GET", "/v1/t3/status")
        self.assertEqual((200, "unconfigured"), (status, body["healthState"]))
        self.assertEqual(401, self._call("GET", "/v1/t3/status", bearer=False)[0])
        status, body = self._call("POST", "/v1/t3/threads", {"text": "hello"})
        self.assertEqual((409, "t3_not_connected"), (status, body["error"]["code"]))
        status, body = self._call("GET", "/v1/live/t3-thread/abc")
        self.assertEqual(409, status)

        asking = thread("ask", "Approval thread", request="command", status="running", completed_at=None, run_id="run-ask")
        self.fake.set_threads([asking, thread("done", "Finished thread")])
        self.fake.set_detail("ask", detail(asking, messages=[
            message("u0", "user", "An older request"),
            message("a0", "assistant", "An older answer"),
            message("u1", "user", "Please run the tests"),
            message("r1", "system", "private reasoning"),
            message("assistant:1", "assistant", "I need to run the test suite.", streaming=True),
        ], requests=[
            approval_requested("req-1"),
            input_requested("q-1"),
        ], items=[
            command_item("c0", "git status", status="completed"),
            command_item("c1", "npm test"),
        ]))
        self.service.connect(self.fake.url, PAIRING_CODE)

        status, body = self._call("GET", "/v1/t3/status")
        self.assertEqual(
            {"connected": True, "serverUrl": self.fake.url, "label": "Test Mac", "healthState": "ready", "detail": None,
             "expiresAt": "2026-11-06T17:25:15.183Z"},
            {key: value for key, value in body.items() if key != "lastSyncAt"},
        )
        status, body = self._call("GET", "/v1/t3/threads?limit=1")
        self.assertEqual(200, status)
        self.assertEqual({"connected", "revision", "updatedAt", "counts", "projects", "threads"}, set(body))
        self.assertEqual(["ask"], [item["id"] for item in body["threads"]])

        status, body = self._call("GET", "/v1/t3/threads/ask?turns=1")
        self.assertEqual(200, status)
        self.assertEqual(["user", "assistant"], [item["role"] for item in body["messages"]])
        self.assertTrue(body["messages"][1]["streaming"])
        self.assertEqual("needs-approval", body["thread"]["status"])
        self.assertEqual("run-ask", body["activeTurnId"])
        self.assertEqual("req-1", body["pending"]["approvals"][0]["requestId"])
        self.assertEqual({"requestId", "kind", "detail", "options"}, set(body["pending"]["approvals"][0]))
        self.assertEqual("q-1", body["pending"]["inputs"][0]["requestId"])
        self.assertEqual("/api/orchestration/threads/ask/bounded", self.fake.requests[-1]["path"])
        status, body = self._call("GET", "/v1/t3/threads/ask?turns=3")
        self.assertEqual(["user", "assistant", "user", "assistant"], [item["role"] for item in body["messages"]])

        status, body = self._call("GET", "/v1/live/t3-thread/ask")
        self.assertEqual(200, status)
        self.assertEqual("warn", body["status"])
        self.assertFalse(body["terminal"])
        self.assertEqual("Run the unit tests", body["phase"])
        self.assertEqual([
            {"title": "Command run", "detail": "git status", "status": "ok", "trailing": None},
            {"title": "Command run", "detail": "npm test", "status": "active", "trailing": None},
        ], body["items"])
        self.assertEqual({"status", "terminal", "subtitle", "phase", "progress", "items", "text", "updatedAt", "nextPollMs"}, set(body))

        status, body = self._call("GET", "/v1/t3/threads/missing")
        self.assertEqual((404, "t3_thread_not_found"), (status, body["error"]["code"]))

        status, body = self._call("POST", "/v1/t3/threads", {"text": "Add a changelog", "project": "orbit"})
        self.assertEqual(202, status)
        self.assertEqual("Orbit Lab", body["projectTitle"])
        self.assertEqual(body["threadId"], self.fake.launched[-1]["threadId"])
        status, body = self._call("POST", "/v1/t3/threads/ask/messages", {"text": "Use the fast suite"})
        self.assertEqual((202, True), (status, body["ok"]))
        status, body = self._call("POST", "/v1/t3/threads/ask/approvals/req-1", {"decision": "accept"})
        self.assertEqual((200, True), (status, body["ok"]))
        status, body = self._call("POST", "/v1/t3/threads/ask/approvals/req-1", {"decision": "maybe"})
        self.assertEqual(400, status)
        status, body = self._call("POST", "/v1/t3/threads/ask/inputs/q-1", {"answers": {"0": "Use SQLite"}})
        self.assertEqual((200, True), (status, body["ok"]))
        status, body = self._call("POST", "/v1/t3/threads/ask/interrupt")
        self.assertEqual((200, True), (status, body["ok"]))
        self.assertEqual({"type": "thread.stop", "threadId": "ask"},
                         {key: self.fake.dispatched[-1][key] for key in ("type", "threadId")})
        status, body = self._call("POST", "/v1/t3/threads/done/seen")
        self.assertEqual((200, {"ok": True}), (status, body))
        self.assertEqual(400, self._call("POST", "/v1/t3/threads/ask/messages", {"text": "  "})[0])
        self._assert_no_token_leaked()

    def test_announcement_routes(self) -> None:
        item = self.outbox.publish("t3.thread.finished", "A", "A finished.", {"threadId": "a"})
        status, body = self._call("GET", "/v1/host/announcements/next?after=0&wait=0")
        self.assertEqual(200, status)
        self.assertEqual(item.announcement_id, body["cursor"])
        self.assertEqual([item.view()], body["announcements"])
        status, body = self._call("GET", f"/v1/host/announcements/next?after={item.announcement_id}&wait=0")
        self.assertEqual((200, [], item.announcement_id), (status, body["announcements"], body["cursor"]))
        status, body = self._call("POST", f"/v1/host/announcements/{item.announcement_id}/ack", {"channel": "voice"})
        self.assertEqual((200, True), (status, body["ok"]))
        self.assertEqual(400, self._call("POST", f"/v1/host/announcements/{item.announcement_id}/ack", {"channel": "x"})[0])
        self.assertEqual(404, self._call("POST", "/v1/host/announcements/424242/ack", {"channel": "voice"})[0])
        self.assertEqual(401, self._call("GET", "/v1/host/announcements/next?wait=0", bearer=False)[0])

    def _assert_no_token_leaked(self) -> None:
        for token in self.fake.tokens | {"tok-1-", "tok-2-"}:
            for body in self.bodies:
                self.assertNotIn(token, body)


class ManagementProxyAllowlistTest(unittest.TestCase):
    def test_management_routes_are_proxied_and_device_routes_are_not(self) -> None:
        root = Path(__file__).resolve().parents[2]
        proxy = root / "android/runtime-host/src/main/java/com/resonolabs/runtime/host/ManagementRuntimeProxy.java"
        if not proxy.exists():
            self.skipTest("Android sources are not available")
        source = proxy.read_text()
        for route in ("/v1/management/t3", "/v1/management/t3/connect", "/v1/management/t3/disconnect"):
            self.assertIn(f'"{route}"', source)
        quoted = re.findall(r'"(/v1/[^"]*)"', source)
        self.assertFalse([item for item in quoted if item.startswith(("/v1/t3", "/v1/live", "/v1/host/announcements"))])
        self.assertRegex(source, r'path\.equals\("/v1/management/t3/connect"\)\) return \d+_000;')


if __name__ == "__main__":
    unittest.main()
