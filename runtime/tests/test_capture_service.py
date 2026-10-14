from __future__ import annotations

import logging
from pathlib import Path
import socket
import tempfile
import unittest
import uuid

from sam_runtime.domains.capture import CaptureBridgeClient, CaptureRejected, CaptureService
from sam_runtime.domains.capture import outcome as lines
from sam_runtime.storage.announcements import AnnouncementRepository
from sam_runtime.storage.database import RuntimeDatabase

from capture_briefing_fakes import FakeCaptureBriefingBridge
from mac_fakes import make_mac

WORDS = "put it in the journal ship the build tonight"


def free_url() -> str:
    """A loopback port nothing listens on (the Mac is away)."""
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return f"http://127.0.0.1:{probe.getsockname()[1]}"


class Clock:
    def __init__(self) -> None:
        self.now = 1_800_000_000.0

    def __call__(self) -> float:
        return self.now


class CaptureServiceTest(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.database = RuntimeDatabase(Path(self.directory.name) / "runtime.sqlite3")
        self.database.migrate()
        self.fake = FakeCaptureBriefingBridge()
        self.store, _mac = make_mac(self.database)
        self.store.save(self.fake.url, self.fake.token)
        self.announcements = AnnouncementRepository(self.database)
        self.clock = Clock()
        self.service = self.make_service()

    def tearDown(self) -> None:
        self.service.stop()
        self.fake.close()
        self.directory.cleanup()

    def make_service(self) -> CaptureService:
        return CaptureService(CaptureBridgeClient(self.store), self.database, self.announcements, clock=self.clock)

    def note(self, capture_id: str | None = None, text: str = WORDS) -> dict[str, object]:
        return {"captureId": capture_id or str(uuid.uuid4()), "text": text,
                "capturedAt": "2026-10-14T09:41:07-04:00", "durationMs": 4200, "trigger": "triple_press"}

    def test_outcome_arrives_inline_and_is_not_announced(self) -> None:
        payload = self.note()
        view = self.service.submit(payload)
        self.assertEqual("done", view["state"])
        self.assertEqual("Added to your journal", view["say"])
        self.assertEqual("journal", view["kind"])
        posted = self.fake.last("/v1/capture")
        self.assertEqual({"text": WORDS, "capturedAt": "2026-10-14T09:41:07-04:00",
                          "captureId": payload["captureId"]}, posted["body"])
        self.assertEqual(payload["captureId"], posted["headers"]["X-SamRabbit-Capture"])
        self.assertEqual("2026-10-14T09:41:07-04:00", posted["headers"]["X-SamRabbit-Captured-At"])
        self.assertEqual("r1", posted["headers"]["X-SamRabbit-Source"])
        self.assertEqual((), tuple(self.announcements.after(0)), "the app already shows an inline outcome")
        self.assertEqual(0, self.service.pending_count())

    def test_same_capture_id_is_sent_once(self) -> None:
        payload = self.note()
        first = self.service.submit(payload)
        second = self.service.submit(payload)
        self.assertEqual(first, second)
        self.assertEqual(1, self.fake.posts_per_capture[payload["captureId"]])

    def test_mac_away_queues_then_sends_and_announces(self) -> None:
        self.store.save(free_url(), self.fake.token)
        payload = self.note()
        view = self.service.submit(payload)
        self.assertEqual(("queued", lines.QUEUED_LINE), (view["state"], view["say"]))
        self.assertEqual(1, self.service.pending_count())
        reloaded = self.make_service()
        self.assertEqual(1, reloaded.pending_count(), "the outbox survives a runtime restart")
        self.store.save(self.fake.url, self.fake.token)
        self.clock.now += 3
        self.assertEqual(1, reloaded.run_due())
        (item,) = self.announcements.after(0)
        self.assertEqual("capture.routed", item.kind)
        self.assertEqual("Added to your journal", item.text)
        self.assertEqual({"captureId": payload["captureId"], "state": "done", "kind": "journal"},
                         {key: item.payload[key] for key in ("captureId", "state", "kind")})
        self.assertNotIn(WORDS, item.text + str(item.payload), "the transcript never goes into announcements")
        self.assertEqual(0, reloaded.pending_count())
        self.assertEqual("done", reloaded.view(payload["captureId"])["state"])

    def test_note_still_routing_is_followed_and_announced(self) -> None:
        self.fake.capture_result = None
        payload = self.note()
        view = self.service.submit(payload)
        self.assertEqual(("sent", lines.SENT_LINE), (view["state"], view["say"]))
        self.assertEqual(0, self.service.run_due(), "not due yet")
        self.fake.finish(payload["captureId"], {"state": "done", "outcome": {"kind": "t3_task", "title": "Fix login",
                                                                             "threadId": "t-1"}})
        self.clock.now += 5
        self.assertEqual(1, self.service.run_due())
        (item,) = self.announcements.after(0)
        self.assertEqual("Started a T3 task: Fix login", item.text)
        self.assertEqual("t-1", item.payload["outcome"]["threadId"])

    def test_refused_note_fails_and_outdated_bridge_keeps_it(self) -> None:
        self.fake.responses["POST /v1/capture"] = (400, {"error": {"code": "invalid_request", "message": "no"}})
        self.assertEqual("failed", self.service.submit(self.note())["state"])
        self.fake.responses["POST /v1/capture"] = (404, {"error": {"code": "not_found", "message": "Not found."}})
        view = self.service.submit(self.note())
        self.assertEqual(("queued", lines.QUEUED_OUTDATED_LINE), (view["state"], view["say"]))
        self.assertEqual(1, self.service.pending_count())
        self.clock.now += 30
        self.service.wake()
        self.assertEqual(0, self.service.run_due(), "an outdated bridge is retried slowly, not on every wake")
        self.fake.responses.clear()
        self.clock.now += 60
        self.assertEqual(1, self.service.run_due())

    def test_unpaired_r1_keeps_the_note(self) -> None:
        self.store.clear()
        view = self.service.submit(self.note())
        self.assertEqual(("queued", lines.QUEUED_UNPAIRED_LINE), (view["state"], view["say"]))
        self.assertEqual([], self.fake.paths())

    def test_invalid_notes_are_rejected_before_anything_is_stored(self) -> None:
        for payload in (self.note(capture_id="not-a-uuid"), self.note(text="   "),
                        {**self.note(), "capturedAt": "2026-10-14T09:41:07"}, self.note(text="x" * 8001)):
            with self.assertRaises(CaptureRejected):
                self.service.submit(payload)
        self.assertEqual(0, self.service.pending_count())
        self.assertEqual([], self.fake.paths())

    def test_transcript_is_never_logged(self) -> None:
        self.store.save(free_url(), self.fake.token)
        with self.assertLogs("sam-runtime", level=logging.INFO) as captured:
            self.service.submit(self.note())
        self.assertIn("capture.received", [record.getMessage() for record in captured.records])
        dump = " ".join(str(record.__dict__) for record in captured.records)
        self.assertNotIn("ship the build", dump)


class CaptureLinesTest(unittest.TestCase):
    def test_lines_for_each_outcome(self) -> None:
        self.assertEqual("Added to your journal", lines.line({"state": "done", "outcome": {"kind": "journal"}}))
        self.assertEqual("On your calendar: Dentist", lines.line({"state": "done", "outcome": {
            "kind": "calendar_event", "title": "Dentist"}}))
        self.assertEqual("Saved as a note · Start as a T3 task?", lines.line({
            "state": "done", "outcome": {"kind": "note"}, "suggestion": {"label": "Start as a T3 task?"}}))
        self.assertEqual("The bridge's own words", lines.line({"state": "done", "say": "The bridge's own words"}))
        self.assertEqual("I didn't catch anything.", lines.line({"state": "no_speech"}))
        self.assertEqual(lines.SENT_LINE, lines.line({"state": "transcribed"}))
        self.assertFalse(lines.finished({"state": "transcribed"}))
        self.assertTrue(lines.finished({"state": "failed"}))
