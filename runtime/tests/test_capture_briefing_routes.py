from __future__ import annotations

from datetime import datetime, timezone
import json
from pathlib import Path
import tempfile
import unittest
from urllib.error import HTTPError
from urllib.request import Request, urlopen
import uuid

from sam_runtime.api.briefing_routes import BriefingRoutes
from sam_runtime.api.capture_routes import CaptureRoutes
from sam_runtime.api.events import RuntimeEventStream
from sam_runtime.api.http_server import RuntimeHttpServer
from sam_runtime.domains.briefing import BriefingBridgeClient, BriefingService
from sam_runtime.domains.capture import CaptureBridgeClient, CaptureService
from sam_runtime.security.pairing import PairingAuthority
from sam_runtime.storage.announcements import AnnouncementRepository
from sam_runtime.storage.database import RuntimeDatabase
from sam_runtime.storage.lifecycle_repository import LifecycleRepository

from capture_briefing_fakes import FakeCaptureBriefingBridge, sample_brief
from mac_fakes import make_mac

LOCAL_TOKEN = "l" * 43
FORWARDED = {"X-SAM-Forwarded-Origin": "https://r1.local:8443"}


class CaptureBriefingRoutesTest(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        database = RuntimeDatabase(Path(self.directory.name) / "runtime.sqlite3")
        database.migrate()
        self.fake = FakeCaptureBriefingBridge()
        self.fake.brief = sample_brief(datetime.now(timezone.utc).date().isoformat())
        self.store, _mac = make_mac(database)
        self.store.save(self.fake.url, self.fake.token)
        announcements = AnnouncementRepository(database)
        self.capture = CaptureService(CaptureBridgeClient(self.store), database, announcements)
        self.briefing = BriefingService(BriefingBridgeClient(self.store), database, announcements,
                                        timezone_name=lambda: "UTC")
        lifecycle = LifecycleRepository(database)
        lifecycle.record_start()
        self.server = RuntimeHttpServer(
            host="127.0.0.1", port=0, token=LOCAL_TOKEN, health=lambda: {"status": "ready"}, lifecycle=lifecycle,
            events=RuntimeEventStream(), pairing=PairingAuthority(), capture=CaptureRoutes(self.capture),
            briefing=BriefingRoutes(self.briefing),
        )
        self.server.start()
        self.base = f"http://127.0.0.1:{self.server.port}"

    def tearDown(self) -> None:
        self.server.stop()
        self.capture.stop()
        self.briefing.stop()
        self.fake.close()
        self.directory.cleanup()

    def call(self, method: str, path: str, body: dict[str, object] | None = None, *,
             headers: dict[str, str] | None = None, bearer: bool = True) -> tuple[int, dict[str, object]]:
        merged = {"Authorization": f"Bearer {LOCAL_TOKEN}"} if bearer else {}
        merged.update(headers or {})
        data = None
        if body is not None:
            data = json.dumps(body).encode()
            merged["Content-Type"] = "application/json"
        try:
            with urlopen(Request(self.base + path, data=data, headers=merged, method=method), timeout=30) as response:
                return response.status, json.loads(response.read() or b"{}")
        except HTTPError as error:
            return error.code, json.loads(error.read() or b"{}")

    def test_capture_round_trip(self) -> None:
        capture_id = str(uuid.uuid4())
        note = {"captureId": capture_id, "text": "make a new task to fix the login redirect",
                "capturedAt": "2026-10-14T09:41:07-04:00", "durationMs": 3100, "trigger": "hold"}
        status, view = self.call("POST", "/v1/capture", note)
        self.assertEqual((200, "done", "Added to your journal"), (status, view["state"], view["say"]))
        self.assertEqual((200, "done"), (lambda result: (result[0], result[1]["state"]))(
            self.call("GET", f"/v1/capture/{capture_id}")))
        status, summary = self.call("GET", "/v1/captures")
        self.assertEqual((200, 0), (status, summary["queued"]))
        self.assertEqual([capture_id], [item["captureId"] for item in summary["recent"]])
        self.assertNotIn("login redirect", json.dumps(summary))
        status, error = self.call("POST", "/v1/capture", {**note, "captureId": "x"})
        self.assertEqual((400, "invalid_request"), (status, error["error"]["code"]))
        self.assertEqual(404, self.call("GET", f"/v1/capture/{uuid.uuid4()}")[0])

    def test_briefing_round_trip(self) -> None:
        self.briefing.fetch_once()
        status, view = self.call("GET", "/v1/briefing")
        self.assertEqual((200, True), (status, view["available"]))
        self.assertEqual("bi_dana", view["briefing"]["sections"][0]["items"][0]["id"])
        status, result = self.call("POST", "/v1/briefing/items/bi_dana/act", {"action": "draft_reply"})
        self.assertEqual((200, "drafted"), (status, result["state"]))
        status, error = self.call("POST", "/v1/briefing/items/bi_dana/act", {"action": "send"})
        self.assertEqual((400, "action_not_offered"), (status, error["error"]["code"]))
        self.assertEqual(404, self.call("POST", "/v1/briefing/items/bi_none/act", {"action": "done"})[0])
        status, refreshing = self.call("POST", "/v1/briefing/refresh", {})
        self.assertEqual((202, "refreshing"), (status, refreshing["status"]))

    def test_routes_are_device_only_and_need_the_bearer(self) -> None:
        for method, path, body in (("GET", "/v1/briefing", None), ("POST", "/v1/briefing/refresh", {}),
                                   ("POST", "/v1/briefing/items/bi_dana/act", {"action": "done"}),
                                   ("POST", "/v1/capture", {"captureId": str(uuid.uuid4())}),
                                   ("GET", "/v1/captures", None), ("GET", f"/v1/capture/{uuid.uuid4()}", None)):
            status, error = self.call(method, path, body, headers=FORWARDED)
            self.assertEqual((403, "device_only"), (status, error["error"]["code"]), path)
            self.assertEqual(401, self.call(method, path, body, bearer=False)[0], path)
        self.assertEqual([], self.fake.posted("/v1/"), "nothing reached the Mac")
