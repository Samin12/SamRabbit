from __future__ import annotations

import json
import unittest

from sam_runtime.agents import AgentKind
from sam_runtime.domains.t3.service import T3Service
from sam_runtime.domains.t3.tools import MAX_OUTPUT_BYTES, register_t3_tools
from sam_runtime.security.credentials import ConnectionCredentialEnvelopes
from sam_runtime.tools import ToolCatalog

from t3_fixtures import (
    PAIRING_CODE,
    FakeT3Server,
    StubBridge,
    approval_requested,
    detail,
    input_requested,
    make_service,
    message,
    thread,
)


TOOL_NAMES = {"t3_list_threads", "t3_read_thread", "t3_new_thread", "t3_send_message", "t3_respond", "t3_stop"}


class T3VoiceToolsTest(unittest.TestCase):
    def setUp(self) -> None:
        self.fake = FakeT3Server().__enter__()
        self.service, _, self.repository, _, self.directory = make_service()
        self.catalog = ToolCatalog()
        register_t3_tools(self.catalog, self.service)

    def tearDown(self) -> None:
        self.fake.__exit__()
        self.directory.cleanup()

    def _call(self, name: str, arguments: dict[str, object]) -> tuple[bool, object]:
        result = self.catalog.invoke(name, arguments, agent=AgentKind.VOICE)
        self.assertLessEqual(len(result.text.encode()), MAX_OUTPUT_BYTES + 200, result.text[:200])
        if result.is_error:
            return False, result.text
        return True, json.loads(result.text)

    def _connect(self, threads: list[dict[str, object]]) -> None:
        self.fake.set_threads(threads)
        self.service.connect(self.fake.url, PAIRING_CODE)

    def test_tools_are_hidden_until_connected_and_schemas_are_simple(self) -> None:
        self.assertFalse(TOOL_NAMES & {item["name"] for item in self.catalog.realtime_definitions()})
        self._connect([thread("a", "A")])
        definitions = {item["name"]: item for item in self.catalog.realtime_definitions()}
        self.assertEqual(TOOL_NAMES, TOOL_NAMES & set(definitions))
        text = json.dumps([definitions[name] for name in TOOL_NAMES])
        for keyword in ("anyOf", "oneOf", "allOf", "$ref", '"additionalProperties": {'):
            self.assertNotIn(keyword, text)
        self.assertIn("never invent ids", definitions["t3_respond"]["description"].lower())
        self.assertIn("restate", definitions["t3_respond"]["description"])

    def test_list_filters_counts_and_size_cap(self) -> None:
        threads = [thread(f"done-{index}", f"Long finished thread title number {index} " + "x" * 120,
                          completed_at=f"2026-10-07T0{index % 9}:00:00.000Z") for index in range(30)]
        threads.append(thread("ask", "Approve the deploy", request="command"))
        threads.append(thread("busy", "Refactor the parser", status="running"))
        self._connect(threads)
        ok, value = self._call("t3_list_threads", {})
        self.assertTrue(ok)
        self.assertEqual({"needsYou": 1, "working": 1, "done": 30, "error": 0}, value["counts"])
        self.assertEqual(["ask", "busy"], [item["id"] for item in value["threads"][:2]])
        self.assertEqual(6, len(value["threads"]))
        self.assertEqual(26, value["more"])
        self.assertEqual({"id", "title", "project", "status", "label", "when"}, set(value["threads"][0]))
        ok, value = self._call("t3_list_threads", {"filter": "needs-you"})
        self.assertEqual(["ask"], [item["id"] for item in value["threads"]])
        ok, value = self._call("t3_list_threads", {"filter": "working", "limit": 12})
        self.assertEqual(["busy"], [item["id"] for item in value["threads"]])
        ok, value = self._call("t3_list_threads", {"filter": "all", "limit": 12})
        self.assertTrue(ok)

    def test_read_condenses_and_lists_pending_requests(self) -> None:
        asking = thread("ask", "Fix login redirect bug", request="command")
        self._connect([asking, thread("other", "Write the changelog")])
        self.fake.set_detail("ask", detail(asking, messages=[
            message("u", "user", "please fix it"),
            message("assistant:1", "assistant", "I found the bug in the redirect handler. " * 300),
        ], requests=[approval_requested("req-1", detail_text="git push origin fix-login")]))
        ok, value = self._call("t3_read_thread", {"thread": "login redirect"})
        self.assertTrue(ok, value)
        self.assertEqual("ask", value["thread"]["id"])
        self.assertLessEqual(len(value["lastAssistant"]), 1500)
        self.assertEqual([{"requestId": "req-1", "kind": "command", "detail": "git push origin fix-login",
                           "decisions": ["accept", "acceptForSession", "decline", "cancel"]}], value["approvals"])

    def test_fuzzy_matching_ids_and_ambiguity(self) -> None:
        self._connect([
            thread("8ce4b73c-8eb3-425e-b36a-e8cc6b94c5d6", "Rabbit device access"),
            thread("11aa22bb-0000-4000-8000-000000000001", "Deploy preview build"),
            thread("11aa22bb-0000-4000-8000-000000000002", "Deploy preview docs"),
        ])
        ok, value = self._call("t3_read_thread", {"thread": "8ce4b73c"})
        self.assertEqual("Rabbit device access", value["thread"]["title"])
        ok, value = self._call("t3_read_thread", {"thread": "the rabbit device one"})
        self.assertEqual("Rabbit device access", value["thread"]["title"])
        ok, value = self._call("t3_read_thread", {"thread": "deploy preview"})
        self.assertFalse(ok)
        self.assertIn("Several threads could match", value)
        ok, value = self._call("t3_read_thread", {"thread": "quantum toaster"})
        self.assertFalse(ok)

    def test_unreachable_mac_before_the_first_sync_is_reported_as_unreachable(self) -> None:
        # Runtime restarted while the Mac sleeps: paired, but no snapshot yet. Voice must
        # not hear "no projects yet" or "no threads".
        self._connect([thread("a", "Fix the login bug")])
        restarted = T3Service(self.repository, ConnectionCredentialEnvelopes(StubBridge()))
        catalog = ToolCatalog()
        register_t3_tools(catalog, restarted)
        self.fake.unavailable = True
        count = len(self.fake.dispatched) + len(self.fake.launched)
        for name, arguments in (
            ("t3_new_thread", {"prompt": "Add dark mode"}),
            ("t3_list_threads", {}),
            ("t3_read_thread", {"thread": "login bug"}),
        ):
            result = catalog.invoke(name, arguments, agent=AgentKind.VOICE)
            self.assertTrue(result.is_error, result.text)
            self.assertIn("unreachable", result.text, name)
        self.assertEqual(count, len(self.fake.dispatched) + len(self.fake.launched))

    def test_latest_means_most_recently_active_not_highest_priority(self) -> None:
        self._connect([
            thread("waiting", "Approve the old deploy", request="command", completed_at="2026-10-05T09:00:00.000Z"),
            thread("fresh", "Polish the settings page", completed_at="2026-10-07T12:30:00.000Z"),
            thread("older", "Write the changelog", completed_at="2026-10-07T08:00:00.000Z"),
        ])
        self.assertEqual("waiting", self.service.summaries()[0]["id"])
        for spoken in ("latest", "the last one", "most recent thread", "Newest."):
            ok, value = self._call("t3_read_thread", {"thread": spoken})
            self.assertTrue(ok, value)
            self.assertEqual("fresh", value["thread"]["id"], spoken)

    def test_new_send_respond_and_stop(self) -> None:
        asking = thread("ask", "Pick storage", request="user_input")
        self._connect([asking, thread("busy", "Refactor the parser", status="running", run_id="run-x")])
        ok, value = self._call("t3_new_thread", {"prompt": "Add retry logic to the uploader", "project": "Orbit Lab"})
        self.assertTrue(ok, value)
        self.assertEqual("Orbit Lab", value["project"])
        self.assertEqual([value["threadId"]], [item["threadId"] for item in self.fake.launched])
        self.assertEqual("Add retry logic to the uploader", self.fake.launched[0]["initialMessage"]["text"])

        ok, value = self._call("t3_send_message", {"thread": "parser", "text": "Keep the public API"})
        self.assertTrue(ok)
        self.assertIn("queued", value["note"])

        self.fake.set_detail("ask", detail(asking, requests=[input_requested("q-1")]))
        ok, value = self._call("t3_respond", {"thread": "pick storage", "answer": "the first one"})
        self.assertTrue(ok, value)
        self.assertEqual({"type": "runtime-request.respond", "requestId": "q-1", "answers": {"0": "Use SQLite"}},
                         {key: self.fake.dispatched[-1][key] for key in ("type", "requestId", "answers")})

        self.fake.set_detail("ask", detail(asking, requests=[input_requested("q-2", options=("Red", "Green", "Blue"), multi=True)]))
        ok, value = self._call("t3_respond", {"thread": "pick storage", "requestId": "q-2", "answers": ["red | blue"]})
        self.assertTrue(ok, value)
        self.assertEqual({"0": ["Red", "Blue"]}, self.fake.dispatched[-1]["answers"])
        ok, value = self._call("t3_respond", {"thread": "pick storage", "answers": ["Red", "Green"]})
        self.assertFalse(ok)
        self.assertIn("one answer per question", value)

        self.fake.set_detail("ask", detail(asking, requests=[approval_requested("req-7")]))
        ok, value = self._call("t3_respond", {"thread": "pick storage", "decision": "decline"})
        self.assertTrue(ok, value)
        self.assertEqual(("runtime-request.respond", "req-7", "decline"),
                         tuple(self.fake.dispatched[-1][key] for key in ("type", "requestId", "decision")))

        self.fake.set_detail("ask", detail(asking, requests=[]))
        ok, value = self._call("t3_respond", {"thread": "pick storage", "decision": "accept"})
        self.assertFalse(ok)
        self.assertIn("Nothing is waiting", value)

        ok, value = self._call("t3_stop", {"thread": "refactor parser"})
        self.assertTrue(ok)
        self.assertTrue(value["wasWorking"])
        self.assertEqual(("thread.stop", "busy"), (self.fake.dispatched[-1]["type"], self.fake.dispatched[-1]["threadId"]))

    def test_disconnected_tools_fail_softly(self) -> None:
        handlers_result = self.catalog.invoke("t3_list_threads", {}, agent=AgentKind.VOICE)
        self.assertTrue(handlers_result.is_error)
        self.assertEqual("Tool is not granted.", handlers_result.text)


if __name__ == "__main__":
    unittest.main()
