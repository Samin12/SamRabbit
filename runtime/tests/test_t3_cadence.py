"""T3 shell poll cadence: 2 s for live runs or requests, 5 s for background-only work, 15 s otherwise."""

from __future__ import annotations

import unittest

from sam_runtime.domains.t3.status import (
    ACTIVITY_ACTIVE,
    ACTIVITY_BACKGROUND,
    ACTIVITY_IDLE,
    activity_level,
    foreground_active,
    thread_status,
)
from sam_runtime.domains.t3.sync import T3SyncWorker

from t3_fixtures import PAIRING_CODE, FakeT3Server, make_service, thread


def _background(thread_id: str = "bg", kind: str = "subagent") -> dict[str, object]:
    # A parent whose run ended while work it waits on (a subagent, an awaited monitor) goes on.
    task = {"taskId": f"task-{thread_id}", "kind": kind, **({"awaited": True} if kind in {"command", "monitor"} else {})}
    return thread(thread_id, "Rabbit R1 device access", background=[task])


class ActivityLevelTest(unittest.TestCase):
    def test_background_only_threads_are_not_active(self) -> None:
        background = _background()
        self.assertEqual("working", thread_status(background))  # still shown as "Background work"
        self.assertFalse(foreground_active(background))
        self.assertEqual(ACTIVITY_BACKGROUND, activity_level([background, thread("d", "Done")]))
        self.assertEqual(ACTIVITY_BACKGROUND, activity_level([_background("m", "monitor")]))
        # A run that only waits on another thread is background too.
        self.assertEqual(ACTIVITY_BACKGROUND, activity_level([thread("w", "Waits", status="running", blocked=True)]))

    def test_running_starting_or_pending_threads_are_active(self) -> None:
        for item in (
            thread("r", "Running", status="running", completed_at=None),
            thread("s", "Starting", status="starting"),
            thread("q", "Queued", status="queued"),
            thread("a", "Approval", request="command"),
            thread("i", "Question", request="user_input"),
            # Held by background work but also waiting on the user: the request wins.
            thread("b", "Both", background=[{"taskId": "s", "kind": "subagent"}], request="command"),
        ):
            with self.subTest(item["id"]):
                self.assertEqual(ACTIVITY_ACTIVE, activity_level([_background(), item]))

    def test_nothing_working_or_pending_is_idle(self) -> None:
        self.assertEqual(ACTIVITY_IDLE, activity_level([]))
        self.assertEqual(ACTIVITY_IDLE, activity_level([
            thread("d", "Done"), thread("e", "Errored", status="failed"),
            thread("n", "Never started", status="idle"),
            thread("x", "Dev server left running", background=[{"taskId": "c", "kind": "command"}]), "not a thread",
        ]))


class T3CadenceTest(unittest.TestCase):
    def setUp(self) -> None:
        self.fake = FakeT3Server().__enter__()
        self.service, _, _, _, self.directory = make_service()
        self.worker = T3SyncWorker(self.service)

    def tearDown(self) -> None:
        self.worker.stop()
        self.fake.__exit__()
        self.directory.cleanup()

    def test_worker_picks_the_cadence_tier_from_the_shell(self) -> None:
        self.fake.set_threads([_background(), thread("d", "Done")])
        self.service.connect(self.fake.url, PAIRING_CODE)
        self.assertEqual(5.0, self.worker.step())
        self.fake.set_threads([_background(), thread("r", "Running", status="running", completed_at=None)])
        self.assertEqual(2.0, self.worker.step())
        self.fake.set_threads([_background(), thread("a", "Approval", request="command")])
        self.assertEqual(2.0, self.worker.step())
        self.fake.set_threads([thread("d", "Done")])
        self.assertEqual(15.0, self.worker.step())

    def test_a_turn_requested_on_the_r1_polls_fast_until_it_starts(self) -> None:
        self.fake.set_threads([thread("t-1", "Fix login redirect", run_id="run-1")])
        self.service.connect(self.fake.url, PAIRING_CODE)
        self.assertEqual(15.0, self.worker.step())
        self.service.send_message("t-1", "Also check Safari")
        # T3 still reports the old, completed run: the requested one has not been queued yet.
        self.assertEqual(2.0, self.worker.step())
        self.fake.set_threads([thread("t-1", "Fix login redirect", run_id="run-2",
                                      completed_at="2026-10-07T12:10:00.000Z")])
        self.assertEqual(15.0, self.worker.step())

    def test_intervals_are_configurable(self) -> None:
        worker = T3SyncWorker(self.service, active_interval=1.0, idle_interval=3.0, quiet_interval=9.0)
        self.assertEqual(
            [1.0, 3.0, 9.0, 9.0],
            [worker.interval_for(level) for level in (ACTIVITY_ACTIVE, ACTIVITY_BACKGROUND, ACTIVITY_IDLE, "?")],
        )


if __name__ == "__main__":
    unittest.main()
