from __future__ import annotations

import time
import unittest
from unittest import mock

from sam_runtime.domains.t3.service import T3Service
from sam_runtime.domains.t3.status import (
    DEFAULT_APPROVAL_OPTIONS,
    listed,
    missing_request_items,
    pending_requests,
    status_label,
    thread_status,
)
from sam_runtime.security.credentials import ConnectionCredentialEnvelopes

from t3_fixtures import (
    PAIRING_CODE,
    PROJECT_SIDE,
    FakeT3Server,
    StubBridge,
    approval_requested,
    detail,
    input_requested,
    make_service,
    thread,
)


class T3StatusDerivationTest(unittest.TestCase):
    def test_status_follows_t3_sidebar_order(self) -> None:
        cases = {
            "needs-approval": thread("a", "A", request="command", status="running"),
            "needs-input": thread("b", "B", request="user_input", status="running"),
            "working": thread("c", "C", status="running"),
            "error": thread("d", "D", status="failed"),
            "done": thread("e", "E"),
        }
        for expected, item in cases.items():
            with self.subTest(expected=expected):
                self.assertEqual(expected, thread_status(item))
        self.assertEqual("working", thread_status(thread("f", "F", status="starting")))
        self.assertEqual("working", thread_status(thread("q", "Q", status="queued")))
        self.assertEqual("working", thread_status(thread("w", "W", status="waiting")))
        # The activity run wins over the latest run (a follow-up queued behind a live run).
        self.assertEqual("working", thread_status(thread("v", "V", activity="running")))
        # Background work the agent waits on holds the thread; a dev server it left running does not.
        self.assertEqual("working", thread_status(thread("g", "G", background=[{"taskId": "s", "kind": "subagent"}])))
        self.assertEqual("working", thread_status(thread("m", "M", background=[{"taskId": "m", "kind": "monitor", "awaited": True}])))
        self.assertEqual("done", thread_status(thread("h", "H", background=[{"taskId": "c", "kind": "command"}])))
        self.assertEqual("done", thread_status(thread("i", "I", status="failed", settled=True)))
        self.assertEqual("done", thread_status(thread("j", "J", status="idle")))
        # An async question the run keeps working past is not "needs input" until the run stops.
        self.assertEqual("working", thread_status(thread("k", "K", request="user_input", blocking=False, status="running")))
        self.assertEqual("needs-input", thread_status(thread("l", "L", request="user_input", blocking=False)))
        self.assertEqual("done", thread_status(thread("n", "N", request="auth_refresh")))

    def test_labels_are_short_and_specific(self) -> None:
        self.assertEqual("Starting", status_label(thread("a", "A", status="starting"), "working"))
        self.assertEqual("Background work", status_label(thread("b", "B", background=[{"taskId": "s", "kind": "subagent"}]), "working"))
        self.assertEqual("Waiting", status_label(thread("w", "W", status="running", blocked=True), "working"))
        self.assertEqual("Queued", status_label(thread("q", "Q", status="queued"), "working"))
        self.assertEqual("Stopped", status_label(thread("d", "D", status="interrupted"), "done"))
        self.assertEqual("New", status_label(thread("e", "E", status="idle"), "done"))

    def test_subagent_children_are_listed_only_while_they_wait_on_the_user(self) -> None:
        self.assertTrue(listed(thread("p", "Parent")))
        self.assertFalse(listed(thread("c", "Child", subagent=True, status="running")))
        self.assertTrue(listed(thread("c", "Child", subagent=True, status="running", request="command")))
        self.assertFalse(listed({**thread("x", "Archived"), "archivedAt": "2026-10-07T12:00:00.000Z"}))
        self.assertFalse(listed({**thread("y", "Deleted"), "deletedAt": "2026-10-07T12:00:00.000Z"}))


class T3PendingRequestsTest(unittest.TestCase):
    def test_requests_follow_runtime_request_rows_like_t3(self) -> None:
        shell = thread("t", "T", request="file-change")
        snapshot = detail(shell, requests=[
            approval_requested("r-1", at="2026-10-07T11:00:00.000Z", status="resolved"),
            approval_requested("r-2", at="2026-10-07T11:01:00.000Z", kind="file-change", detail_text="Changed files"),
            input_requested("q-1"),
            input_requested("q-2", status="expired"),
        ])
        projection = snapshot["projection"]
        projection["runtimeRequests"] += [
            {**approval_requested("auth")["request"], "kind": "auth_refresh"},
            {**approval_requested("tool")["request"], "kind": "dynamic_tool_call"},
            # A pending question whose item is outside the bounded window is skipped (and flagged).
            input_requested("q-old")["request"],
        ]
        pending = pending_requests(snapshot)
        self.assertEqual(["r-2"], [item.request_id for item in pending.approvals])
        self.assertEqual("file-change", pending.approvals[0].kind)
        self.assertEqual("Changed files", pending.approvals[0].detail)
        self.assertEqual(list(DEFAULT_APPROVAL_OPTIONS), pending.view()["approvals"][0]["options"])
        self.assertEqual(
            {"requestId": "q-1", "questions": [{
                "id": "0", "header": "Storage", "question": "Which database should I use?",
                "options": ["Use SQLite", "Use DuckDB"], "allowCustom": True, "multiSelect": False,
            }]},
            pending.view()["inputs"][0],
        )
        self.assertTrue(missing_request_items(snapshot))
        projection["runtimeRequests"].pop()
        self.assertFalse(missing_request_items(snapshot))

    def test_provider_options_are_kept(self) -> None:
        pair = approval_requested("r-9", options=[{"decision": "accept", "label": "Allow"}, {"decision": "decline", "label": "Deny"}])
        pending = pending_requests(detail(thread("t", "T", request="command"), requests=[pair]))
        self.assertEqual([{"decision": "accept", "label": "Allow"}, {"decision": "decline", "label": "Deny"}],
                         pending.view()["approvals"][0]["options"])


class T3SummariesTest(unittest.TestCase):
    def setUp(self) -> None:
        self.fake = FakeT3Server().__enter__()
        self.service, self.announcements, self.repository, _, self.directory = make_service()

    def tearDown(self) -> None:
        self.fake.__exit__()
        self.directory.cleanup()

    def _threads(self) -> list[dict[str, object]]:
        return [
            thread("done-old", "Old done", completed_at="2026-10-07T08:00:00.000Z"),
            thread("done-new", "New done", completed_at="2026-10-07T10:00:00.000Z"),
            thread("settled", "Settled one", completed_at="2026-10-07T11:30:00.000Z", settled=True),
            thread("working", "Busy thread", status="running", project_id=PROJECT_SIDE),
            thread("error", "Broken thread", status="failed"),
            thread("input", "Question thread", request="user_input"),
            thread("approve", "Approval thread", request="command"),
            # An idle subagent child is never listed.
            thread("child", "Subagent child", subagent=True),
        ]

    def test_order_counts_projects_and_revision(self) -> None:
        self.fake.set_threads(self._threads())
        self.service.connect(self.fake.url, PAIRING_CODE)
        view = self.service.threads_view(limit=40)
        self.assertTrue(view["connected"])
        self.assertEqual(
            ["approve", "input", "working", "error", "done-new", "done-old", "settled"],
            [item["id"] for item in view["threads"]],
        )
        self.assertEqual({"needsYou": 2, "working": 1, "done": 3, "error": 1}, view["counts"])
        working = view["threads"][2]
        self.assertEqual(
            {"id": "working", "projectId": PROJECT_SIDE, "projectTitle": "Orbit Lab", "title": "Busy thread",
             "status": "working", "statusLabel": "Working", "unread": False, "model": "claude-opus-5-5",
             "phase": None, "progress": None, "completedAt": None},
            {key: value for key, value in working.items() if key != "updatedAt"},
        )
        self.assertEqual("Workbench", view["projects"][0]["title"])
        self.assertEqual(set(view["threads"][0]), {
            "id", "projectId", "projectTitle", "title", "status", "statusLabel", "updatedAt", "completedAt",
            "unread", "model", "phase", "progress",
        })
        revision = view["revision"]
        self.service.sync_once()
        self.assertEqual(revision, self.service.threads_view()["revision"])
        changed = self._threads()
        changed[3] = thread("working", "Busy thread", project_id=PROJECT_SIDE, completed_at="2026-10-07T12:10:00.000Z")
        self.fake.set_threads(changed)
        self.service.sync_once()
        self.assertEqual(revision + 1, self.service.threads_view()["revision"])
        self.assertEqual(2, len(self.service.threads_view(limit=2)["threads"]))

    def test_unread_tracks_seen_and_history_starts_read(self) -> None:
        self.fake.set_threads(self._threads())
        self.service.connect(self.fake.url, PAIRING_CODE)
        self.assertFalse(any(item["unread"] for item in self.service.threads_view()["threads"]))
        threads = self._threads()
        threads[1] = thread("done-new", "New done", completed_at="2026-10-07T12:20:00.000Z", run_id="run-2")
        self.fake.set_threads(threads)
        self.service.sync_once()
        before = self.service.threads_view()
        unread = {item["id"] for item in before["threads"] if item["unread"]}
        self.assertEqual({"done-new"}, unread)
        self.service.mark_seen("done-new")
        after = self.service.threads_view()
        self.assertFalse(any(item["unread"] for item in after["threads"]))
        self.assertGreater(after["revision"], before["revision"])

    def test_revision_never_repeats_after_a_runtime_restart(self) -> None:
        # The app skips re-rendering when the revision equals the one it holds.
        self.fake.set_threads(self._threads())
        self.service.connect(self.fake.url, PAIRING_CODE)
        held = self.service.threads_view()["revision"]
        later = time.time() + 30
        with mock.patch("sam_runtime.domains.t3.service.time.time", return_value=later):
            restarted = T3Service(self.repository, ConnectionCredentialEnvelopes(StubBridge()))
            restarted.sync_once()
            self.assertGreater(restarted.threads_view()["revision"], held)

    def test_not_connected_view_and_status(self) -> None:
        view = self.service.threads_view()
        self.assertEqual(
            {"connected": False, "counts": {"needsYou": 0, "working": 0, "done": 0, "error": 0}, "projects": [], "threads": []},
            {key: view[key] for key in ("connected", "counts", "projects", "threads")},
        )
        self.assertEqual(
            {"connected": False, "serverUrl": None, "label": None, "healthState": "unconfigured",
             "detail": None, "expiresAt": None, "lastSyncAt": None},
            self.service.status_view(),
        )


if __name__ == "__main__":
    unittest.main()
