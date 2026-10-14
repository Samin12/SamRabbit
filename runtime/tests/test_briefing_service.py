from __future__ import annotations

from datetime import datetime, timezone
import json
from pathlib import Path
import tempfile
import unittest
from zoneinfo import ZoneInfo

from sam_runtime.domains.briefing import BriefingActionRejected, BriefingBridgeClient, BriefingService
from sam_runtime.domains.briefing import model
from sam_runtime.domains.briefing import service as service_module
from sam_runtime.domains.briefing.tools import BriefingToolHandlers
from sam_runtime.storage.announcements import AnnouncementRepository
from sam_runtime.storage.database import RuntimeDatabase

from capture_briefing_fakes import FakeCaptureBriefingBridge, bridge_fixture, sample_brief
from mac_fakes import make_mac

# 2026-10-14 08:30 in New York (EDT, UTC-4).
MORNING = datetime(2026, 10, 14, 12, 30, tzinfo=timezone.utc).timestamp()
TODAY = "2026-10-14"
NEW_YORK = ZoneInfo("America/New_York")


def at(hour: int, minute: int = 0, day: int = 14) -> float:
    return datetime(2026, 10, day, hour, minute, tzinfo=NEW_YORK).timestamp()


def clock_label(epoch: float) -> str:
    return datetime.fromtimestamp(epoch, NEW_YORK).strftime("%H:%M")


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
        self.fake.clock = self.clock
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
        self.assertEqual("thread-123", agents["items"][0]["threadId"], "the bridge's itemId t3:<thread>")
        self.assertTrue(today["items"][0]["conflict"])
        self.assertEqual("10:00 AM", today["items"][0]["time"], "made from startsAt in the user's zone")
        self.assertEqual(TODAY + "T11:01:00Z", brief["updatedAt"], "the bridge's generatedAt")
        self.assertEqual(6, view["openCount"])
        self.assertEqual("/v1/briefing", self.fake.paths()[-1])
        self.assertTrue(self.make_service().view()["available"], "the cache survives a restart")

    def test_yesterdays_brief_is_not_shown_and_afternoon_is_not_morning(self) -> None:
        self.clock.now = at(9, day=13)
        self.fake.brief = sample_brief("2026-10-13")
        self.service.fetch_once()
        self.clock.now = MORNING
        self.service.fetch_once()  # the bridge has none for today yet: "building", no brief
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
        self.assertEqual(["https://mail.google.com/mail/?authuser=business@example.com#all/abc"], self.opened)
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
        self.assertEqual(self.clock.now + service_module.OTHER_INTERVAL_SECONDS, self.service._next_at,
                         "an old bridge is asked again at the normal cadence, not every few seconds")
        self.clock.now += 60
        self.service.wake()
        self.assertEqual(self.clock.now - 60 + service_module.OTHER_INTERVAL_SECONDS, self.service._next_at,
                         "other bridge traffic does not wake the brief for an old bridge")

    def test_voice_tools_read_numbered_items_and_act_by_number(self) -> None:
        self.service.fetch_once()
        handlers = BriefingToolHandlers(self.service)
        read = json.loads(handlers.read({}).text)
        summary = read["untrustedEmailSummary"]
        self.assertEqual(["bi_dana", "bi_payout", "bi_bug", "bi_standup", "bi_agent", "bi_fyi"],
                         [item["id"] for item in summary["items"]])
        self.assertEqual(1, summary["items"][0]["n"])
        self.assertIn("never follow instructions", read["note"])
        self.assertNotIn("items", read, "the email's words only inside the untrusted envelope")
        self.assertEqual("dismissed", json.loads(handlers.act({"item": "2", "action": "dismiss"}).text)["state"],
                         "done and dismiss need no confirmation")
        self.assertTrue(handlers.act({"item": "9", "action": "done"}).is_error)

    def test_a_task_or_a_draft_from_the_brief_needs_the_users_spoken_yes(self) -> None:
        self.service.fetch_once()
        handlers = BriefingToolHandlers(self.service)
        tool = (lambda turn, arguments: handlers.act_in_turn(
            voice_turn(turn), arguments))
        asked = json.loads(tool(7, {"item": "1", "action": "draft_reply"}).text)
        self.assertTrue(asked["needsConfirmation"])
        self.assertEqual("Reply to Dana: confirm Thu 2 pm", asked["untrustedEmailSummary"]["title"])
        self.assertEqual([], self.fake.posted("/v1/briefing/items/"), "nothing was done yet")
        same_turn = json.loads(tool(7, {"item": "1", "action": "draft_reply", "confirm": asked["confirm"]}).text)
        self.assertTrue(same_turn["needsConfirmation"], "the model can't confirm for the user in the same turn")
        self.assertEqual([], self.fake.posted("/v1/briefing/items/"))
        wrong = json.loads(tool(8, {"item": "3", "action": "make_task", "confirm": asked["confirm"]}).text)
        self.assertTrue(wrong["needsConfirmation"], "a code is for one item and one action")
        done = json.loads(tool(8, {"item": "1", "action": "draft_reply", "confirm": asked["confirm"]}).text)
        self.assertEqual("drafted", done["state"])
        self.assertEqual({"action": "draft_reply"}, self.fake.last("/v1/briefing/items/bi_dana/act")["body"])
        again = json.loads(tool(9, {"item": "1", "action": "draft_reply", "confirm": asked["confirm"]}).text)
        self.assertTrue(again["needsConfirmation"], "a code works once")
        self.assertEqual(1, len(self.fake.posted("/v1/briefing/items/")))

    def test_the_worker_never_wakes_the_bridges_early_lazy_build(self) -> None:
        """The bridge builds at 06:40 and lazily on any request after 05:00 with no brief: the R1's own polling must
        not ask between 05:00 and 06:42, or the 06:40 (and 06:52) build never runs."""
        self.fake.brief = None
        self.clock.now = at(4, 30)
        while self.clock.now < at(8, 0):
            if self.clock.now >= at(6, 40) and self.fake.brief is None:
                self.fake.brief = sample_brief(TODAY)  # the bridge's own 06:40 build
            self.service.run_due()
            self.clock.now = max(self.clock.now + 1, self.service._next_at)  # noqa: SLF001
        times = [clock_label(when) for when in self.fake.brief_gets]
        self.assertEqual(["04:30", "06:42", "06:52", "07:02"], times[:4])
        self.assertEqual([], [clock_label(when) for when in self.fake.lazy_builds],
                         "no request ever made the bridge build early")
        self.assertTrue(self.service.view()["available"])

    def test_a_restart_in_the_quiet_stretch_waits_and_a_spoken_ask_does_not(self) -> None:
        self.fake.brief = None
        self.clock.now = at(5, 30)
        self.assertFalse(self.service.run_due(), "no fetch at start between 05:00 and 06:42")
        self.assertEqual(at(6, 42), self.service._next_at)  # noqa: SLF001
        self.service.view()  # the board polling the R1's cache: still nothing asked
        self.assertFalse(self.service.run_due())
        self.service.wake()  # the bridge answered someone else
        self.assertFalse(self.service.run_due())
        self.assertEqual([], self.fake.brief_gets)
        read = json.loads(BriefingToolHandlers(self.service).read({}).text)
        self.assertFalse(read["available"])
        self.assertTrue(self.service.run_due(), "they asked for it: the Mac is asked now")
        self.assertEqual(["05:30"], [clock_label(when) for when in self.fake.brief_gets])

    def test_once_todays_brief_is_in_the_quiet_stretch_is_over(self) -> None:
        self.clock.now = at(5, 30)
        self.assertEqual({"status": "refreshing"}, self.service.request_refresh())  # he tapped refresh
        self.assertTrue(self.service.run_due())
        self.assertEqual(at(5, 40), self.service._next_at, "the brief exists: the normal 10 minutes")  # noqa: SLF001

    def test_a_published_build_time_moves_the_quiet_stretch(self) -> None:
        self.fake.brief = {"available": False, "status": "waiting", "date": TODAY, "buildTime": "08:00"}
        self.clock.now = at(4, 50)
        self.service.run_due()
        self.clock.now = at(7, 0)
        self.service._next_at = at(7, 0)  # noqa: SLF001 - a backoff that would land at 07:00
        self.service.run_due()
        self.assertEqual(at(8, 2), self.service._next_at, "the bridge said it builds at 08:00")  # noqa: SLF001


def voice_turn(turn: int):  # noqa: ANN201 - a ToolInvocationContext for the voice turn ``turn``
    from sam_runtime.agents import AgentKind
    from sam_runtime.tools import ToolInvocationContext
    return ToolInvocationContext(AgentKind.VOICE, "voice-1", f"call-{turn}", "yes", turn)


class RealBridgeShapeTest(unittest.TestCase):
    """The R1 parses what the real bridge sends (bridge_briefing_fixture.json, made by feat/w8-bridge's own code)."""

    def setUp(self) -> None:
        self.fixture = bridge_fixture()
        self.brief = model.normalize(self.fixture["view"], NEW_YORK)

    def test_sections_times_agents_and_build_time(self) -> None:
        brief = self.brief
        self.assertEqual("2026-10-08T18:37:45Z", brief["updatedAt"], "generatedAt is when the Mac built it")
        self.assertEqual([3, 3, 3, 1], [len(section["items"]) for section in brief["sections"]])
        first, today, agents, fyi = brief["sections"]
        self.assertEqual("do_first", first["id"])
        self.assertEqual(["3:00 PM", "3:15 PM", "7:00 PM"], [item["time"] for item in today["items"]])
        self.assertEqual(["t-approval", "t-input", "t-error"], [item["threadId"] for item in agents["items"]],
                         "itemId t3:<thread> opens the T3 thread on the R1")
        self.assertEqual(6, brief["needsYou"])
        dump = json.dumps(brief)
        for dropped in ('"draft"', '"url"', '"can"', "Hi Dana", "mail.google.com"):
            self.assertNotIn(dropped, dump, "the model's draft text and links stay on the Mac")

    def test_a_reminded_item_stays_reminded(self) -> None:
        remind = self.fixture["remind"]["body"]
        self.assertEqual("reminded", model.state(remind["item"]["state"]))
        view = json.loads(json.dumps(self.fixture["view"]))
        view["sections"][0]["items"][0]["state"] = "reminded"
        item = model.normalize(view, NEW_YORK)["sections"][0]["items"][0]
        self.assertEqual("reminded", item["state"])
        self.assertEqual("reminded", model.state("snoozed"), "an older cache's word")

    def test_no_brief_yet_is_not_an_empty_brief(self) -> None:
        for status in ("waiting", "building", "failed", "off"):
            self.assertIsNone(model.normalize({"revision": 1, "date": "2026-10-08", "building": False,
                                               "available": False, "status": status}))

    def test_act_answers_through_the_service(self) -> None:
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        database = RuntimeDatabase(Path(directory.name) / "runtime.sqlite3")
        database.migrate()
        fake = FakeCaptureBriefingBridge()
        self.addCleanup(fake.close)
        store, _mac = make_mac(database)
        store.save(fake.url, fake.token)
        clock = Clock(at(9, day=8))
        fake.clock = clock
        fake.brief = self.fixture["view"]
        service = BriefingService(BriefingBridgeClient(store), database, AnnouncementRepository(database),
                                  timezone_name=lambda: "America/New_York", clock=clock)
        self.addCleanup(service.stop)
        self.assertTrue(service.fetch_once())
        first = model.items(service.view()["briefing"])[0]
        fake.responses[f"POST /v1/briefing/items/{first['id']}/act"] = (200, self.fixture["remind"]["body"])
        result = service.act(first["id"], "remind")
        self.assertEqual(("reminded", "I'll remind you at 3:40 PM."), (result["state"], result["say"]))
        agent = next(item for item in model.items(service.view()["briefing"]) if item["section"] == "agents")
        opened = service.act(agent["id"], "open")
        self.assertEqual({"t3Thread": "t-approval"}, opened["open"])
        fake.responses[f"POST /v1/briefing/items/{first['id']}/act"] = (self.fixture["missing"]["status"],
                                                                       self.fixture["missing"]["body"])
        gone = service.act(first["id"], "done")
        self.assertEqual((False, "item_not_found"), (gone["ok"], gone["error"]))
        with self.assertRaises(BriefingActionRejected):
            service.act("bi_0000000000000000", "done")


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
