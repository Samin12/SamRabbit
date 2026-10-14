from __future__ import annotations

from datetime import datetime, timezone
import json
from pathlib import Path
import tempfile
import unittest

from sam_runtime.domains.briefing import BriefingActionRejected, BriefingBridgeClient, BriefingService
from sam_runtime.domains.briefing import model
from sam_runtime.domains.briefing import service as service_module
from sam_runtime.domains.briefing.tools import BriefingToolHandlers
from sam_runtime.storage.announcements import AnnouncementRepository
from sam_runtime.storage.database import RuntimeDatabase

from capture_briefing_fakes import FakeCaptureBriefingBridge, sample_brief
from mac_fakes import make_mac

# 2026-10-14 08:30 in New York (EDT, UTC-4).
MORNING = datetime(2026, 10, 14, 12, 30, tzinfo=timezone.utc).timestamp()
TODAY = "2026-10-14"


class Clock:
    def __init__(self, now: float = MORNING) -> None:
        self.now = now

    def __call__(self) -> float:
        return self.now


class BriefingServiceTest(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.database = RuntimeDatabase(Path(self.directory.name) / "runtime.sqlite3")
        self.database.migrate()
        self.fake = FakeCaptureBriefingBridge()
        self.fake.brief = sample_brief(TODAY)
        self.store, _mac = make_mac(self.database)
        self.store.save(self.fake.url, self.fake.token)
        self.announcements = AnnouncementRepository(self.database)
        self.clock = Clock()
        self.opened: list[str] = []
        self.service = self.make_service()

    def tearDown(self) -> None:
        self.service.stop()
        self.fake.close()
        self.directory.cleanup()

    def make_service(self) -> BriefingService:
        return BriefingService(BriefingBridgeClient(self.store), self.database, self.announcements,
                               timezone_name=lambda: "America/New_York", open_on_mac=self.opened.append,
                               clock=self.clock)

    def test_fetch_caches_a_bounded_brief_without_unsafe_actions(self) -> None:
        self.assertTrue(self.service.fetch_once())
        view = self.service.view()
        self.assertEqual((True, True, "ready", TODAY, True), (view["configured"], view["available"], view["status"],
                                                              view["today"], view["morning"]))
        brief = view["briefing"]
        first, today, agents, fyi = brief["sections"]
        self.assertEqual(["bi_dana", "bi_payout", "bi_bug"], [item["id"] for item in first["items"]],
                         "Do first keeps three")
        self.assertEqual([{"type": "draft_reply", "label": "Draft reply"}, {"type": "remind", "label": "Remind 4 pm"}],
                         first["items"][0]["actions"], "send is never offered on the R1")
        self.assertEqual([{"type": "open", "label": "Open"}], agents["items"][0]["actions"], "no approve from the brief")
        self.assertEqual("thread-123", agents["items"][0]["threadId"])
        self.assertTrue(today["items"][0]["conflict"])
        self.assertEqual(6, view["openCount"])
        self.assertEqual("/v1/briefing", self.fake.paths()[-1])
        self.assertTrue(self.make_service().view()["available"], "the cache survives a restart")

    def test_yesterdays_brief_is_not_shown_and_afternoon_is_not_morning(self) -> None:
        self.fake.brief = sample_brief("2026-10-13")
        self.service.fetch_once()
        view = self.service.view()
        self.assertEqual((False, "stale", None), (view["available"], view["status"], view["briefing"]))
        self.clock.now += 5 * 3600
        self.assertFalse(self.service.view()["morning"])

    def test_ready_is_announced_once_a_day_and_only_with_work(self) -> None:
        self.fake.brief = sample_brief(TODAY, needs_you=0)
        self.service.fetch_once()
        self.assertEqual((), tuple(self.announcements.after(0)))
        self.fake.brief = sample_brief(TODAY, revision=4, needs_you=2)
        self.service.fetch_once()
        self.fake.brief = sample_brief(TODAY, revision=5, needs_you=3)
        self.service.fetch_once()
        (item,) = self.announcements.after(0)
        self.assertEqual("briefing.ready", item.kind)
        self.assertEqual({"date": TODAY, "revision": 4, "needsYou": 2}, item.payload)

    def test_draft_reply_goes_to_the_bridge_and_only_offered_actions_run(self) -> None:
        self.service.fetch_once()
        result = self.service.act("bi_dana", "draft_reply")
        self.assertEqual((True, "drafted"), (result["ok"], result["state"]))
        self.assertIn("draft", result["say"].lower())
        self.assertEqual({"action": "draft_reply"}, self.fake.last("/v1/briefing/items/bi_dana/act")["body"])
        self.assertEqual("drafted", model.find(self.service.view()["briefing"], "bi_dana")["state"])
        with self.assertRaises(BriefingActionRejected):
            self.service.act("bi_payout", "draft_reply")
        with self.assertRaises(BriefingActionRejected):
            self.service.act("bi_dana", "send")
        with self.assertRaises(BriefingActionRejected) as missing:
            self.service.act("bi_nope", "done")
        self.assertEqual(404, missing.exception.status)
        self.assertEqual("dismissed", self.service.act("bi_payout", "dismiss")["state"], "done/dismiss always")
        acted = [item["body"]["action"] for item in self.fake.posted("/v1/briefing/items/")]
        self.assertEqual(["draft_reply", "dismiss"], acted)

    def test_open_uses_the_mac_for_mail_and_t3_for_agents(self) -> None:
        self.service.fetch_once()
        result = self.service.act("bi_payout", "open")
        self.assertEqual("Opened it on your Mac.", result["say"])
        self.assertEqual(["https://mail.google.com/mail/u/0/#inbox/abc?authuser=samin%40aianswer.us"], self.opened)
        before = len(self.fake.requests)
        agent = self.service.act("bi_agent", "open")
        self.assertEqual({"t3Thread": "thread-123"}, agent["open"])
        self.assertEqual(before, len(self.fake.requests), "an agent item opens in T3 without the bridge")

    def test_worker_cadence_backoff_refresh_and_outdated_bridge(self) -> None:
        self.assertTrue(self.service.run_due())
        self.assertEqual(MORNING + service_module.MORNING_INTERVAL_SECONDS, self.service._next_at)
        self.clock.now = MORNING + 5 * 3600
        self.assertTrue(self.service.run_due())
        self.assertEqual(self.clock.now + service_module.OTHER_INTERVAL_SECONDS, self.service._next_at)
        self.assertEqual({"status": "refreshing"}, self.service.request_refresh())
        self.assertTrue(self.service.run_due())
        self.assertEqual(1, self.fake.refreshes)
        self.clock.now += 5
        self.assertTrue(self.service.run_due(), "fetched again while the Mac rebuilds")
        self.fake.responses["GET /v1/briefing"] = (500, {"error": {"code": "internal", "message": "x"}})
        self.clock.now += 3600
        self.assertFalse(self.service.run_due())
        self.assertEqual(self.clock.now + 2, self.service._next_at)
        self.assertTrue(self.service.view()["stale"])
        self.fake.responses["GET /v1/briefing"] = (404, {"error": {"code": "not_found", "message": "Not found."}})
        self.clock.now += 3
        self.service.run_due()
        view = self.service.view()
        self.assertEqual(("off", False), (view["status"], view["available"]))

    def test_voice_tools_read_numbered_items_and_act_by_number(self) -> None:
        self.service.fetch_once()
        handlers = BriefingToolHandlers(self.service)
        read = json.loads(handlers.read({}).text)
        self.assertEqual(["bi_dana", "bi_payout", "bi_bug", "bi_standup", "bi_agent", "bi_fyi"],
                         [item["id"] for item in read["items"]])
        self.assertEqual(1, read["items"][0]["n"])
        acted = handlers.act({"item": "1", "action": "draft_reply"})
        self.assertFalse(acted.is_error)
        self.assertEqual({"action": "draft_reply"}, self.fake.last("/v1/briefing/items/bi_dana/act")["body"])
        self.assertTrue(handlers.act({"item": "9", "action": "done"}).is_error)


class BriefingModelTest(unittest.TestCase):
    def test_flat_item_lists_and_section_maps_are_accepted(self) -> None:
        flat = model.normalize({"date": TODAY, "items": [
            {"id": "a", "kind": "email", "section": "doFirst", "title": "Reply to Sam", "actions": ["draft"]},
            {"id": "b", "kind": "event", "title": "Standup"}]})
        self.assertEqual([["a"], ["b"], [], []], [[item["id"] for item in section["items"]]
                                                  for section in flat["sections"]])
        mapped = model.normalize({"briefing": {"date": TODAY, "sections": {"fyi": [{"id": "c", "title": "Payout"}]}}})
        self.assertEqual(["c"], [item["id"] for item in mapped["sections"][3]["items"]])
        self.assertIsNone(model.normalize({"date": "today"}))
        many = model.normalize({"date": TODAY, "sections": [
            {"id": key, "items": [{"id": f"{key}{index}", "title": "x"} for index in range(9)]}
            for key in ("do_first", "today", "agents", "fyi")]})
        self.assertEqual([3, 5, 3, 1], [len(section["items"]) for section in many["sections"]], "≤ 12 items")
