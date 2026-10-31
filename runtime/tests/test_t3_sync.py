from __future__ import annotations

import socket
import unittest

from sam_runtime.domains.t3.client import T3Unavailable
from sam_runtime.domains.t3.sync import T3SyncWorker
from sam_runtime.domains.t3.transitions import T3TransitionTracker

from t3_fixtures import (
    PAIRING_CODE,
    FakeT3Server,
    approval_requested,
    detail,
    input_requested,
    make_service,
    message,
    thread,
)


def _working(thread_id: str = "t-1", title: str = "Fix login redirect", **extra) -> dict[str, object]:
    return thread(thread_id, title, **{"status": "running", "run_id": "run-2", "completed_at": None,
                                       "updated_at": "2026-10-07T12:05:00.000Z", **extra})


def _done(thread_id: str = "t-1", title: str = "Fix login redirect", **extra) -> dict[str, object]:
    return thread(thread_id, title, run_id="run-2", completed_at="2026-10-07T12:06:00.000Z", **extra)


class T3TransitionTrackerTest(unittest.TestCase):
    def test_startup_snapshot_is_silent_baseline(self) -> None:
        tracker = T3TransitionTracker()
        events = tracker.observe([
            thread("a", "A", request="command"), thread("b", "B", request="user_input"),
            thread("c", "C", status="failed"), _done("d", "D"),
        ])
        self.assertEqual([], events)
        self.assertEqual([], tracker.observe([
            thread("a", "A", request="command"), thread("b", "B", request="user_input"),
            thread("c", "C", status="failed"), _done("d", "D"),
        ]))

    def test_finish_detected_for_working_run_and_fast_new_run(self) -> None:
        tracker = T3TransitionTracker()
        tracker.observe([_working("a"), thread("b", "B", run_id="run-1")])
        events = tracker.observe([_done("a"), thread("b", "B", run_id="run-9", completed_at="2026-10-07T12:30:00.000Z")])
        self.assertEqual([("finished", "a", "run-2"), ("finished", "b", "run-9")],
                         [(item.event, item.thread_id, item.turn_id) for item in events])

    def test_reappearing_history_and_interrupts_are_not_announced(self) -> None:
        tracker = T3TransitionTracker()
        tracker.observe([thread("x", "X", completed_at="2026-10-07T12:00:00.000Z")])
        events = tracker.observe([
            thread("x", "X", completed_at="2026-10-07T12:00:00.000Z"),
            thread("old", "Unarchived", completed_at="2026-10-01T09:00:00.000Z"),
        ])
        self.assertEqual([], events)
        tracker.observe([_working("i")])
        self.assertEqual([], tracker.observe([thread("i", "I", status="interrupted", run_id="run-2")]))
        # A "waiting" run (provider turn over, effects draining) is not finished yet.
        tracker.observe([_working("w")])
        self.assertEqual([], tracker.observe([thread("w", "W", status="waiting", run_id="run-2")]))

    def test_needs_you_and_error_transitions(self) -> None:
        tracker = T3TransitionTracker()
        tracker.observe([_working("a"), _working("b"), _working("c")])
        events = tracker.observe([
            thread("a", "A", request="command", status="running", run_id="run-2"),
            thread("b", "B", request="user_input", status="running", run_id="run-2"),
            thread("c", "C", status="failed", run_id="run-2"),
        ])
        self.assertEqual({("needs_approval", "a"), ("needs_input", "b"), ("error", "c")},
                         {(item.event, item.thread_id) for item in events})


class T3AnnouncementFlowTest(unittest.TestCase):
    def setUp(self) -> None:
        self.fake = FakeT3Server().__enter__()
        self.service, self.announcements, _, _, self.directory = make_service()

    def tearDown(self) -> None:
        self.fake.__exit__()
        self.directory.cleanup()

    def _items(self) -> list[object]:
        items, _ = self.announcements.next(0, wait_seconds=0)
        return list(items)

    def test_finished_announcement_has_speakable_text_and_last_message(self) -> None:
        self.fake.set_threads([_working(), thread("h", "History", completed_at="2026-10-07T07:00:00.000Z")])
        self.service.connect(self.fake.url, PAIRING_CODE)
        self.assertEqual([], self._items())
        finished = _done()
        self.fake.set_threads([finished, thread("h", "History", completed_at="2026-10-07T07:00:00.000Z")])
        long_reply = "All tests pass now. " + "The redirect keeps the original path. " * 30
        self.fake.set_detail("t-1", detail(finished, messages=[
            message("u1", "user", "Fix the login redirect"),
            message("assistant:1", "assistant", long_reply),
        ]))
        self.service.sync_once()
        self.service.sync_once()
        items = self._items()
        self.assertEqual(1, len(items))
        item = items[0]
        self.assertEqual("t3.thread.finished", item.kind)
        self.assertEqual("“Fix login redirect” in Workbench finished.", item.text)
        self.assertEqual("Fix login redirect", item.title)
        self.assertEqual("t-1", item.payload["threadId"])
        self.assertEqual("Workbench", item.payload["projectTitle"])
        self.assertEqual("done", item.payload["status"])
        self.assertTrue(item.payload["lastMessage"].startswith("All tests pass now."))
        self.assertLessEqual(len(item.payload["lastMessage"]), 400)

    def test_approvals_are_announced_once_per_request(self) -> None:
        moment = [100.0]
        self.service._tracker._clock = lambda: moment[0]
        self.fake.set_threads([_working()])
        self.service.connect(self.fake.url, PAIRING_CODE)
        waiting = thread("t-1", "Fix login redirect", request="command", status="running", run_id="run-2",
                         completed_at=None, updated_at="2026-10-07T12:07:00.000Z")
        self.fake.set_threads([waiting])
        self.fake.set_detail("t-1", detail(waiting, requests=[approval_requested("req-1", detail_text="npm test")]))
        self.service.sync_once()
        self.service.sync_once()
        more = dict(waiting, updatedAt="2026-10-07T12:08:00.000Z")
        self.fake.set_threads([more])
        self.fake.set_detail("t-1", detail(more, requests=[approval_requested("req-1"), approval_requested("req-2", at="2026-10-07T12:07:30.000Z")]))
        requests_before = len(self.fake.requests)
        self.service.sync_once()
        self.assertEqual(1, len(self.fake.requests) - requests_before, "updates while waiting are re-checked at most every 10 s")
        moment[0] += 11
        self.fake.set_threads([dict(more, updatedAt="2026-10-07T12:09:00.000Z")])
        self.service.sync_once()
        items = self._items()
        self.assertEqual(["req-1", "req-2"], [item.payload["requestId"] for item in items])
        self.assertEqual("t3.thread.needs_approval", items[0].kind)
        self.assertEqual("“Fix login redirect” in Workbench wants approval to run a command.", items[0].text)
        self.assertEqual("npm test", items[0].payload["detail"])

    def test_question_and_error_announcements(self) -> None:
        self.fake.set_threads([_working("q", "Pick storage"), _working("e", "Deploy preview")])
        self.service.connect(self.fake.url, PAIRING_CODE)
        asking = thread("q", "Pick storage", request="user_input", status="running", run_id="run-2",
                        completed_at=None, updated_at="2026-10-07T12:07:00.000Z")
        failing = thread("e", "Deploy preview", status="failed", run_id="run-2", completed_at="2026-10-07T12:07:00.000Z",
                         preview="I could not reach the preview host.")
        self.fake.set_threads([asking, failing])
        self.fake.set_detail("q", detail(asking, requests=[input_requested("q-1")]))
        self.service.sync_once()
        by_kind = {item.kind: item for item in self._items()}
        self.assertEqual("“Pick storage” in Workbench asks: Which database should I use?", by_kind["t3.thread.needs_input"].text)
        self.assertEqual("q-1", by_kind["t3.thread.needs_input"].payload["requestId"])
        self.assertEqual("“Deploy preview” in Workbench hit an error.", by_kind["t3.thread.error"].text)
        self.assertEqual("Provider crashed", by_kind["t3.thread.error"].payload["error"])
        # The shell's latest visible agent message is used without fetching the thread.
        self.assertEqual("I could not reach the preview host.", by_kind["t3.thread.error"].payload["lastMessage"])
        self.assertFalse([item for item in self.fake.requests if item["path"].startswith("/api/orchestration/threads/e")])


class T3SyncWorkerTest(unittest.TestCase):
    def setUp(self) -> None:
        self.fake = FakeT3Server().__enter__()
        self.service, _, _, _, self.directory = make_service()
        self.worker = T3SyncWorker(self.service)

    def tearDown(self) -> None:
        self.worker.stop()
        self.fake.__exit__()
        self.directory.cleanup()

    def test_cadence_backoff_and_reauth(self) -> None:
        self.assertEqual(30.0, self.worker.step())
        self.fake.set_threads([_working()])
        self.service.connect(self.fake.url, PAIRING_CODE)
        self.assertEqual(2.0, self.worker.step())
        self.fake.set_threads([_done()])
        self.assertEqual(15.0, self.worker.step())  # nothing working or pending: quiet cadence
        self.fake.revoke_all()
        self.assertEqual(30.0, self.worker.step())
        status = self.service.status_view()
        self.assertEqual("reauth", status["healthState"])
        self.assertFalse(status["connected"])
        self.assertFalse(self.service.connected())
        self.assertEqual(30.0, self.worker.step())

    def test_unreachable_server_backs_off_and_reports_failed(self) -> None:
        self.fake.set_threads([_done()])
        self.service.connect(self.fake.url, PAIRING_CODE)
        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        dead_port = listener.getsockname()[1]
        listener.close()
        with self.service._lock:
            record = self.service._record
            self.service._record = type(record)(**{**{field: getattr(record, field) for field in record.__dataclass_fields__},
                                                   "server_url": f"http://127.0.0.1:{dead_port}"})
        delays = [self.worker.step() for _ in range(3)]
        self.assertEqual([5.0, 10.0, 20.0], delays)
        status = self.service.status_view()
        self.assertEqual("failed", status["healthState"])
        self.assertTrue(status["connected"])
        self.assertIn("Cannot reach T3 Code", status["detail"])
        with self.assertRaisesRegex(T3Unavailable, "moments ago"):
            self.service.thread_detail("t-1")
        # A probe skips the fail-fast window and really tries (and finds the port closed).
        with self.assertRaises(T3Unavailable) as caught:
            self.service._client(probe=True)
        self.assertEqual("refused", caught.exception.reason)


if __name__ == "__main__":
    unittest.main()
