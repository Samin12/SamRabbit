from __future__ import annotations

import json
import unittest

from sam_runtime.agents import AgentKind
from sam_runtime.domains.mac import register_mac_tools
from sam_runtime.domains.t3.placement import (
    MENTIONED,
    NAMED,
    ORCHESTRATION,
    RECENT,
    OrchestrationSetting,
    ProjectPlacement,
    is_general_task,
)
from sam_runtime.domains.t3.service import T3InvalidRequest
from sam_runtime.domains.t3.tools import register_t3_tools
from sam_runtime.tools import ToolCatalog

from mac_fakes import FakeMacControlBridge, make_mac
from t3_fixtures import PAIRING_CODE, PROJECT_MAIN, PROJECT_SCRATCH, PROJECT_SIDE, FakeT3Server, make_service, project, thread

PROJECT_AGENT = "44444444-4444-4444-8444-444444444444"


class PlacementTest(unittest.TestCase):
    def setUp(self) -> None:
        self.fake = FakeT3Server().__enter__()
        self.fake.shell["projects"].append(project(PROJECT_AGENT, "Assistant", "/Users/test/.t3/assistant/workspace"))
        self.service, _, _, self.database, self.directory = make_service()
        self.setting = OrchestrationSetting(self.database)
        self.placement = ProjectPlacement(self.service, self.setting)
        self.mac_fake = FakeMacControlBridge()
        _, self.mac = make_mac(self.database, self.mac_fake)

    def tearDown(self) -> None:
        self.mac_fake.close()
        self.fake.__exit__()
        self.directory.cleanup()

    def connect(self) -> None:
        # Orbit Lab is the most recently active project, the scratch project is newer still.
        self.fake.set_threads([
            thread("w1", "Old work", project_id=PROJECT_MAIN, completed_at="2026-10-06T10:00:00.000Z"),
            thread("o1", "Orbit work", project_id=PROJECT_SIDE, completed_at="2026-10-07T11:00:00.000Z"),
            thread("s1", "Scratch chat", project_id=PROJECT_SCRATCH, completed_at="2026-10-07T11:30:00.000Z"),
        ])
        self.service.connect(self.fake.url, PAIRING_CODE)

    def test_selection_order(self) -> None:
        self.connect()
        cases = (
            ("Add retry logic to the uploader", {"project": "workbench"}, PROJECT_MAIN, NAMED),
            ("Fix the flaky test in orbit lab", {}, PROJECT_SIDE, MENTIONED),
            ("Book me a table for two and put it in my calendar", {}, PROJECT_AGENT, ORCHESTRATION),
            ("Fix the login bug in the parser", {}, PROJECT_SIDE, RECENT),
            ("Do the thing", {}, PROJECT_SIDE, RECENT),
            ("Reply with exactly OK", {"computer": True}, PROJECT_AGENT, ORCHESTRATION),
            ("Clean up the workbench notes", {"computer": True}, PROJECT_MAIN, MENTIONED),
        )
        for request, options, expected, reason in cases:
            with self.subTest(request=request):
                placed = self.placement.choose(request, **options)
                self.assertEqual((expected, reason), (placed.project_id, placed.reason))
        with self.assertRaises(T3InvalidRequest):
            self.placement.choose("anything", project="Nonexistent Galaxy")

    def test_orchestration_setting_default_override_and_view(self) -> None:
        self.connect()
        record, source = self.placement.orchestration()
        self.assertEqual((PROJECT_AGENT, "default"), (record["id"], source), "T3's agent workspace by default")
        view = self.placement.management_view()
        self.assertEqual(PROJECT_AGENT, view["projectId"])
        self.assertNotIn(PROJECT_SCRATCH, [item["id"] for item in view["projects"]])
        self.placement.set_orchestration(PROJECT_MAIN)
        self.assertEqual(PROJECT_MAIN, self.setting.get())
        self.assertEqual(PROJECT_MAIN, self.placement.choose("Order more coffee beans").project_id)
        self.assertEqual("setting", self.placement.management_view()["source"])
        with self.assertRaises(T3InvalidRequest):
            self.placement.set_orchestration(PROJECT_SCRATCH)
        with self.assertRaises(T3InvalidRequest):
            self.placement.set_orchestration("not-a-project")
        self.setting.set("gone-project")
        self.assertEqual(PROJECT_AGENT, self.placement.orchestration()[0]["id"], "a vanished setting falls back")
        self.placement.set_orchestration(None)
        self.assertIsNone(self.setting.get())

    def test_default_without_an_agent_workspace_is_the_most_recent_real_project(self) -> None:
        self.fake.shell["projects"] = [item for item in self.fake.shell["projects"] if item["id"] != PROJECT_AGENT]
        self.connect()
        self.assertEqual(PROJECT_SIDE, self.placement.orchestration()[0]["id"])

    def test_classifier(self) -> None:
        for text in ("open my email and draft a reply", "book a flight to Lisbon", "organize my downloads folder",
                     "what's on my calendar, then message Sam"):
            self.assertTrue(is_general_task(text), text)
        for text in ("fix the login bug", "write unit tests for the parser", "refactor the API client", "hello"):
            self.assertFalse(is_general_task(text), text)
        # Coding work about everyday things (the R1's own features) is still coding work.
        for text in ("fix the calendar sync so all-day events show", "add a Spotify widget to the board",
                     "the email card crashes when I open it", "fix the bug where the Heptabase journal doesn't save",
                     "make the mac bridge return the window title", "add a screenshot button to the management page",
                     "make the search for threads faster"):
            self.assertFalse(is_general_task(text), text)
        for text in ("summarize this web page", "set up the webinar tabs in Chrome", "make a deck for the meeting"):
            self.assertTrue(is_general_task(text), text)

    def test_t3_new_thread_uses_placement_when_no_project_is_named(self) -> None:
        self.connect()
        catalog = ToolCatalog()
        register_t3_tools(catalog, self.service, self.placement)
        result = catalog.invoke("t3_new_thread", {"prompt": "Research standing desks and summarize the best three"},
                                agent=AgentKind.VOICE)
        self.assertFalse(result.is_error, result.text)
        value = json.loads(result.text)
        self.assertEqual(("Assistant", "orchestration"), (value["project"], value["placement"]))
        self.assertEqual(PROJECT_AGENT, self.fake.launched[0]["projectId"])
        result = catalog.invoke("t3_new_thread", {"prompt": "Fix the crash in the uploader"}, agent=AgentKind.VOICE)
        self.assertEqual(PROJECT_SIDE, self.fake.launched[1]["projectId"])
        self.assertEqual("recent", json.loads(result.text)["placement"])
        result = catalog.invoke("t3_new_thread", {"prompt": "Fix it", "project": "Workbench"}, agent=AgentKind.VOICE)
        self.assertEqual(PROJECT_MAIN, self.fake.launched[2]["projectId"])
        self.assertNotIn("placement", json.loads(result.text))
        result = catalog.invoke("t3_new_thread", {"prompt": "Make the calendar widget show all-day events"},
                                agent=AgentKind.VOICE)
        self.assertEqual(PROJECT_SIDE, self.fake.launched[3]["projectId"], "coding work stays in the code project")
        self.assertEqual("recent", json.loads(result.text)["placement"])

    def test_mac_task_delegates_to_a_t3_thread_in_the_orchestration_project(self) -> None:
        catalog = ToolCatalog()
        register_mac_tools(catalog, self.mac, t3=self.service, placement=self.placement, owner_name=lambda: "Samin")
        self.assertNotIn("mac_task", {item["name"] for item in catalog.realtime_definitions()}, "needs T3 connected")
        self.connect()
        self.assertIn("mac_task", {item["name"] for item in catalog.realtime_definitions()})
        # No health check ran first (as in a voice session after a restart): mac_task asks the bridge itself
        # for its capabilities (driver path, screen vision), which inform the prompt.
        self.assertIsNone(self.mac.cached_capabilities())
        request = "Find my last three invoices in Downloads and put them in one folder"
        result = catalog.invoke("mac_task", {"request": request}, agent=AgentKind.VOICE)
        self.assertFalse(result.is_error, result.text)
        value = json.loads(result.text)
        self.assertEqual({"ok", "threadId", "title", "project", "status", "note"}, set(value))
        self.assertEqual(("Assistant", "started"), (value["project"], value["status"]))
        create = self.fake.launched[0]
        self.assertEqual(PROJECT_AGENT, create["projectId"])
        self.assertEqual(value["threadId"], create["threadId"])
        prompt = create["initialMessage"]["text"]
        self.assertTrue(prompt.startswith(request + "\n"), "the user's request comes first, verbatim")
        self.assertIn("You are acting for Samin via the R1 voice orchestrator on Test Mac Studio", prompt)
        self.assertIn("cua-driver CLI/skill", prompt)
        self.assertIn("Aside browser", prompt)
        self.assertIn("the terminal", prompt)
        self.assertIn("Keep Samin informed", prompt)
        self.assertIn("Reply with a short summary when done", prompt)
        self.assertIn("/Applications/CuaDriver.app/Contents/MacOS/cua-driver", prompt)
        self.assertIn("Screen Recording is not granted", prompt)
        self.assertIn("invoices", create["title"].lower())
        result = catalog.invoke("mac_task", {"request": "Tidy it", "project": "Orbit Lab", "title": "Tidy orbit"},
                                agent=AgentKind.VOICE)
        self.assertEqual(PROJECT_SIDE, self.fake.launched[1]["projectId"])
        self.assertEqual("Tidy orbit", self.fake.launched[1]["title"])
        self.assertTrue(catalog.invoke("mac_task", {"request": "  "}, agent=AgentKind.VOICE).is_error)

    def test_mac_task_goes_ahead_when_the_bridge_health_check_fails(self) -> None:
        catalog = ToolCatalog()
        register_mac_tools(catalog, self.mac, t3=self.service, placement=self.placement, owner_name=lambda: "Samin")
        self.connect()
        self.mac_fake.responses["/health"] = (503, {"error": {"code": "bridge_busy", "message": "Busy."}})
        result = catalog.invoke("mac_task", {"request": "Tidy my desktop"}, agent=AgentKind.VOICE)
        self.assertFalse(result.is_error, result.text)
        prompt = self.fake.launched[0]["initialMessage"]["text"]
        self.assertTrue(prompt.startswith("Tidy my desktop\n"))
        self.assertIn("on this Mac", prompt)
        self.assertNotIn("cua-driver: ", prompt)


if __name__ == "__main__":
    unittest.main()
