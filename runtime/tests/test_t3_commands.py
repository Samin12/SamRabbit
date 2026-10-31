from __future__ import annotations

import unittest
from unittest import mock

from sam_runtime.domains.t3.commands import T3CommandBuilder
from sam_runtime.domains.t3.service import T3DispatchFailed, T3InvalidRequest, T3RequestNotPending

from t3_fixtures import (
    PAIRING_CODE,
    PROJECT_MAIN,
    PROJECT_SCRATCH,
    PROJECT_SIDE,
    FakeT3Server,
    FixedIds,
    approval_requested,
    detail,
    input_requested,
    make_service,
    thread,
)


def _builder() -> T3CommandBuilder:
    return T3CommandBuilder(new_id=FixedIds())


def _id(n: int) -> str:
    return f"00000000-0000-4000-8000-{n:012d}"


def _without_ids(value: dict[str, object]) -> dict[str, object]:
    return {key: item for key, item in value.items() if key not in {"commandId", "messageId"}}


class T3CommandShapeTest(unittest.TestCase):
    def test_launch_thread_shape(self) -> None:
        payload = _builder().launch_thread(
            thread_id="thread-1", project_id="project-1", title="Check the build", text="Check the build",
            model_selection={"instanceId": "claudeAgent", "model": "claude-opus-5-5"},
            runtime_mode="full-access",
        )
        self.assertEqual(
            {"commandId": _id(1), "creationSource": "mobile", "threadId": "thread-1", "projectId": "project-1",
             "title": "Check the build", "generateTitle": True,
             "modelSelection": {"instanceId": "claudeAgent", "model": "claude-opus-5-5"},
             "runtimeMode": "full-access", "interactionMode": "default", "workspaceStrategy": {"type": "root"},
             "initialMessage": {"messageId": _id(2), "text": "Check the build", "attachments": []}},
            payload,
        )

    def test_message_dispatch_shape(self) -> None:
        resolved = _builder().message(thread_id="thread-1", text="Run the tests")
        self.assertEqual(
            {"type": "message.dispatch", "commandId": _id(1), "createdBy": "user", "creationSource": "mobile",
             "threadId": "thread-1", "messageId": _id(2), "text": "Run the tests", "attachments": [],
             "deliveryIntent": "auto", "dispatchMode": {"type": "start_immediately"}},
            resolved,
        )
        older = _builder().message(thread_id="thread-1", text="More", server_resolved=False, run_live=True)
        self.assertNotIn("deliveryIntent", older)
        self.assertEqual({"type": "queue_after_active"}, older["dispatchMode"])
        idle = _builder().message(thread_id="thread-1", text="More", server_resolved=False, run_live=False)
        self.assertEqual({"type": "start_immediately"}, idle["dispatchMode"])

    def test_respond_stop_interrupt_and_archive_shapes(self) -> None:
        builder = _builder()
        self.assertEqual(
            {"type": "runtime-request.respond", "commandId": _id(1), "threadId": "t", "requestId": "r", "decision": "accept"},
            builder.approval_respond(thread_id="t", request_id="r", decision="accept"),
        )
        self.assertEqual(
            {"type": "runtime-request.respond", "commandId": _id(2), "threadId": "t", "requestId": "q",
             "answers": {"0": "Use SQLite"}},
            builder.user_input_respond(thread_id="t", request_id="q", answers={"0": "Use SQLite"}),
        )
        self.assertEqual({"type": "thread.stop", "commandId": _id(3), "threadId": "t"}, builder.stop(thread_id="t"))
        self.assertEqual(
            {"type": "run.interrupt", "commandId": _id(4), "threadId": "t", "runId": "run-9", "holdQueue": True},
            builder.interrupt(thread_id="t", run_id="run-9"),
        )
        self.assertEqual({"type": "thread.archive", "commandId": _id(5), "threadId": "t"}, builder.archive(thread_id="t"))
        with self.assertRaises(ValueError):
            builder.approval_respond(thread_id="t", request_id="r", decision="maybe")


class T3ServiceCommandTest(unittest.TestCase):
    def setUp(self) -> None:
        self.fake = FakeT3Server().__enter__()
        self.service, _, _, _, self.directory = make_service()

    def tearDown(self) -> None:
        self.fake.__exit__()
        self.directory.cleanup()

    def _connect(self, threads: list[dict[str, object]]) -> None:
        self.fake.set_threads(threads)
        self.service.connect(self.fake.url, PAIRING_CODE)

    def test_create_uses_most_recent_project_and_its_latest_thread_settings(self) -> None:
        self._connect([
            thread("old", "Old", project_id=PROJECT_MAIN, completed_at="2026-10-07T08:00:00.000Z", model="gpt-old", runtime_mode="auto"),
            thread("recent", "Recent", project_id=PROJECT_SIDE, completed_at="2026-10-07T11:00:00.000Z", model="claude-sonnet-5", runtime_mode="approval-required"),
            thread("scratch", "Scratch", project_id=PROJECT_SCRATCH, completed_at="2026-10-07T11:50:00.000Z"),
        ])
        created = self.service.create_thread("Add a dark mode toggle to settings")
        self.assertEqual([], self.fake.dispatched, "one launchThread call, no separate create + turn")
        (launch,) = self.fake.launched
        thread_id = created["threadId"]
        self.assertEqual("Orbit Lab", created["projectTitle"])
        self.assertEqual(
            {"creationSource": "mobile", "threadId": thread_id, "projectId": PROJECT_SIDE,
             "title": "Add a dark mode toggle to settings", "generateTitle": True,
             "modelSelection": {"instanceId": "claudeAgent", "model": "claude-sonnet-5", "options": [{"id": "effort", "value": "high"}]},
             "runtimeMode": "approval-required", "interactionMode": "default", "workspaceStrategy": {"type": "root"},
             "initialMessage": {"text": "Add a dark mode toggle to settings", "attachments": []}},
            {**_without_ids(launch), "initialMessage": _without_ids(launch["initialMessage"])},
        )

    def test_create_falls_back_to_default_model_and_named_project(self) -> None:
        self._connect([thread("recent", "Recent", project_id=PROJECT_SIDE)])
        created = self.service.create_thread("Write release notes", title="Release notes", project="workbench", runtime_mode="approval-required")
        create = self.fake.launched[0]
        self.assertEqual(PROJECT_MAIN, created["projectId"])
        self.assertEqual({"instanceId": "claudeAgent", "model": "claude-opus-5-5"}, create["modelSelection"])
        self.assertEqual("approval-required", create["runtimeMode"])
        self.assertEqual("Release notes", create["title"])
        self.assertFalse(create["generateTitle"], "a title the user gave is kept")
        with self.assertRaises(T3InvalidRequest):
            self.service.create_thread("x", project="nonexistent galaxy")
        with self.assertRaises(T3InvalidRequest):
            self.service.create_thread("   ")

    def test_failed_launch_is_reported(self) -> None:
        self._connect([thread("recent", "Recent")])
        self.fake.fail_dispatch_types.add("launchThread")
        with self.assertRaises(T3DispatchFailed):
            self.service.create_thread("Do it")

    def test_send_message_lets_t3_choose_steer_or_queue(self) -> None:
        self._connect([thread("t-1", "Recent", runtime_mode="auto-accept-edits"), thread("busy", "Busy", status="running")])
        self.assertFalse(self.service.send_message("t-1", "Also update the docs")["wasWorking"])
        self.assertEqual(
            {"type": "message.dispatch", "createdBy": "user", "creationSource": "mobile", "threadId": "t-1",
             "text": "Also update the docs", "attachments": [], "deliveryIntent": "auto",
             "dispatchMode": {"type": "start_immediately"}},
            _without_ids(self.fake.dispatched[-1]),
        )
        self.assertTrue(self.service.send_message("busy", "Steer it")["wasWorking"])
        # A server without serverResolvedCommandContext gets an explicit queue for a live run.
        self.service._capabilities = {}
        self.service.send_message("busy", "Queue it")
        self.assertEqual({"type": "queue_after_active"}, self.fake.dispatched[-1]["dispatchMode"])
        self.assertNotIn("deliveryIntent", self.fake.dispatched[-1])

    def test_interrupt_stops_live_threads_and_skips_idle_ones(self) -> None:
        self._connect([
            thread("busy", "Busy", status="running", run_id="run-active"),
            thread("held", "Held", background=[{"taskId": "s", "kind": "subagent"}]),
            thread("idle", "Idle"),
        ])
        self.assertTrue(self.service.interrupt("busy")["wasWorking"])
        self.assertEqual({"type": "thread.stop", "threadId": "busy"}, _without_ids(self.fake.dispatched[-1]))
        self.assertTrue(self.service.interrupt("held")["wasWorking"])
        count = len(self.fake.dispatched)
        self.assertFalse(self.service.interrupt("idle")["wasWorking"])
        self.assertEqual(count, len(self.fake.dispatched))
        # Without the threadStop capability the live run is interrupted.
        self.service._capabilities = {}
        self.service.interrupt("busy")
        self.assertEqual({"type": "run.interrupt", "threadId": "busy", "runId": "run-active", "holdQueue": True},
                         _without_ids(self.fake.dispatched[-1]))

    def test_approval_and_input_responses_are_validated_against_pending(self) -> None:
        shell_thread = thread("ask", "Ask", request="command")
        self._connect([shell_thread])
        self.fake.set_detail("ask", detail(shell_thread, requests=[approval_requested("req-1"), input_requested("q-1")]))
        self.service.respond_approval("ask", "req-1", "accept")
        self.assertEqual(
            {"type": "runtime-request.respond", "threadId": "ask", "requestId": "req-1", "decision": "accept"},
            _without_ids(self.fake.dispatched[-1]),
        )
        with self.assertRaises(T3RequestNotPending):
            self.service.respond_approval("ask", "req-gone", "accept")
        self.service.respond_input("ask", "q-1", {"0": "sqlite"})
        self.assertEqual({"0": "Use SQLite"}, self.fake.dispatched[-1]["answers"])
        self.service.respond_input("ask", "q-1", {"0": "second"})
        self.assertEqual({"0": "Use DuckDB"}, self.fake.dispatched[-1]["answers"])
        self.service.respond_input("ask", "q-1", {"0": "Something custom"})
        self.assertEqual({"0": "Something custom"}, self.fake.dispatched[-1]["answers"])

    def test_multi_select_and_closed_questions(self) -> None:
        shell_thread = thread("ask", "Ask", request="user_input")
        self._connect([shell_thread])
        self.fake.set_detail("ask", detail(shell_thread, requests=[
            input_requested("multi", options=("Red", "Green", "Blue"), multi=True, allow_custom=False),
        ]))
        self.service.respond_input("ask", "multi", {"0": ["red", "Blue"]})
        self.assertEqual({"0": ["Red", "Blue"]}, self.fake.dispatched[-1]["answers"])
        with self.assertRaises(T3InvalidRequest):
            self.service.respond_input("ask", "multi", {"0": "Purple"})

    def test_live_snapshot_is_not_terminal_before_a_requested_turn_starts(self) -> None:
        # genui stops polling a live card once a snapshot says terminal.
        self._connect([thread("done", "Finished", run_id="run-1"), thread("blank", "Blank", status="idle")])
        self.assertEqual(("ok", True), tuple(self.service.live_view("done")[key] for key in ("status", "terminal")))
        self.assertEqual(("idle", False), tuple(self.service.live_view("blank")[key] for key in ("status", "terminal")))

        self.service.send_message("done", "One more thing")
        live = self.service.live_view("done")
        self.assertEqual(("active", False, "Starting"), (live["status"], live["terminal"], live["phase"]))
        with mock.patch("sam_runtime.domains.t3.service._TURN_START_GRACE", -1.0):
            self.service._invalidate("done")
            self.assertTrue(self.service.live_view("done")["terminal"])
        self.service.send_message("done", "And another")
        self.fake.set_threads([thread("done", "Finished", run_id="run-2", completed_at="2026-10-07T12:05:00.000Z")])
        self.service.sync_once()
        self.service._invalidate("done")
        self.assertEqual(("ok", True), tuple(self.service.live_view("done")[key] for key in ("status", "terminal")))

        created = self.service.create_thread("Write the release notes")["threadId"]
        self.fake.set_detail(created, detail(thread(created, "Write the release notes", status="idle")))
        live = self.service.live_view(created)
        self.assertEqual(("active", False), (live["status"], live["terminal"]))

    def test_live_snapshot_stays_live_after_an_async_answer_starts_a_turn(self) -> None:
        asking = thread("ask", "Ask", request="user_input", run_id="run-a")
        self._connect([asking])
        self.fake.set_detail("ask", detail(asking, requests=[input_requested("q-async", message_mode=True)]))
        self.service.respond_input("ask", "q-async", {"0": "Use SQLite"})
        answered = thread("ask", "Ask", run_id="run-a")
        self.fake.set_threads([answered])
        self.fake.set_detail("ask", detail(answered))
        self.service.sync_once()
        self.service._invalidate("ask")
        live = self.service.live_view("ask")
        self.assertEqual(("active", False), (live["status"], live["terminal"]))

    def test_answers_send_option_values_and_keep_the_users_own_words(self) -> None:
        shell_thread = thread("ask", "Ask", request="user_input")
        self._connect([shell_thread])
        valued = input_requested("pick", options=("Allow once", "Always allow"), allow_custom=False)
        valued["item"]["questions"][0]["options"] = [
            {"label": "Allow once", "description": "Once", "value": "opt-once"},
            {"label": "Always allow", "description": "Always", "value": "opt-always"},
        ]
        self.fake.set_detail("ask", detail(shell_thread, requests=[
            valued,
            input_requested("count", options=("1", "3", "5")),
            input_requested("confirm", options=("Yes", "No")),
        ]))
        pending = self.service.thread_view("ask")["pending"]["inputs"][0]["questions"][0]
        self.assertEqual(["Allow once", "Always allow"], pending["options"])

        def answer(request_id: str, value: str) -> object:
            self.service.respond_input("ask", request_id, {"0": value})
            return self.fake.dispatched[-1]["answers"]["0"]

        # T3 expects option.value ?? option.label, like its own web client.
        self.assertEqual("opt-always", answer("pick", "always allow"))
        self.assertEqual("opt-once", answer("pick", "the first one"))
        self.assertEqual("opt-once", answer("pick", "opt-once"))
        # With numeric labels a number is the label, never an index.
        self.assertEqual("3", answer("count", "3"))
        self.assertEqual("2", answer("count", "2"))
        # Extra words are the user's answer, not just the label they contain.
        self.assertEqual("Yes, but skip the slow tests", answer("confirm", "Yes, but skip the slow tests"))
        self.assertEqual("No", answer("confirm", "no."))


if __name__ == "__main__":
    unittest.main()
