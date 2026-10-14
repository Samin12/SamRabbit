"""The SamRabbit window's twins of the phone's routes (CONTRACTS-WAVE7) end to end against the mobile API's fakes.

``GET /v1/desktop/summary`` (the phone's summary plus ``r1.online`` and the paired ``devices``), ``GET
/v1/desktop/calendar/agenda?days=``, ``POST /v1/desktop/calendar/block``, ``POST /v1/desktop/journal`` and
``GET|DELETE /v1/desktop/devices[/<id>]``: the phone's own handlers for the desktop token from this Mac only. Also how
the bridge learns the R1 was around (a request with its token from the network). A real bridge on a random loopback
port with a fake T3 server and CLI, a fake Composio, a fake Heptabase CLI and a fake cua-driver (``MobileBase``).
Nothing here reaches the real T3 Code, Google Calendar, the Heptabase journal, the R1 or the live bridge.

Run: cd companion/mac-bridge && /usr/bin/python3 -m unittest tests.test_desktop_window -q
"""

from __future__ import annotations

import json
from pathlib import Path
import sys
import unittest
from typing import Any, Dict, List, Tuple

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE))

import samrabbit_mobile as mobile  # noqa: E402
import test_mobile as phone_tests  # noqa: E402
from test_mobile import CONV, DESKTOP, NOTE, NOW, TOKEN, FakeHandler, MobileBase  # noqa: E402

R1_ADDRESS = "192.168.1.186"


class DesktopWindowBase(MobileBase):
    def desk(self, method: str, path: str, body: Any = None) -> Tuple[int, Dict[str, Any]]:
        return self.call(method, path, body, desktop=True)

    def creates(self) -> List[Dict[str, Any]]:
        return [call["args"] for call in self.composio_calls() if call["slug"] == "GOOGLECALENDAR_CREATE_EVENT"]


# ====================================================================== auth


class DesktopAuthTest(DesktopWindowBase):
    def test_only_the_desktop_app_on_this_mac_gets_in(self) -> None:
        phone = self.pair()["token"]
        routes = [("GET", "/v1/desktop/summary", None), ("GET", "/v1/desktop/calendar/agenda", None),
                  ("GET", "/v1/desktop/calendar/agenda?days=3", None),
                  ("POST", "/v1/desktop/calendar/block", {"minutes": 30}),
                  ("POST", "/v1/desktop/journal", {"text": NOTE}), ("GET", "/v1/desktop/devices", None),
                  ("DELETE", "/v1/desktop/devices/dev_0000000000000000", None),
                  ("GET", "/v1/desktop/calendar/nope", None), ("PUT", "/v1/desktop/summary", None)]
        for method, path, body in routes:
            for kwargs in ({}, {"token": TOKEN}, {"token": phone},
                           {"headers": {"X-SamRabbit-Desktop": "wrong-" + "x" * 30}}):
                with self.subTest(method=method, path=path, kwargs=sorted(kwargs)):
                    status, value = self.call(method, path, body, **kwargs)
                    self.assertEqual((401, "unauthorized"), (status, value["error"]["code"]))
        self.assertEqual([], self.composio_calls(), "nothing reached Composio")
        self.assertFalse((self.hepta_dir / "journal.json").exists(), "nothing reached Heptabase")
        status, value = self.call("GET", "/v1/desktop/summary", desktop=True, headers={"Origin": "http://evil.example"})
        self.assertEqual(403, status, "a web page can never read it")
        for path, method, body in (("/v1/desktop/summary", "GET", b""),
                                   ("/v1/desktop/journal", "POST", json.dumps({"text": NOTE}).encode())):
            with self.subTest(lan=path):
                handler = FakeHandler("192.168.1.20", path, {"X-SamRabbit-Desktop": DESKTOP}, body)
                self.service.serve(handler, method, path)
                self.assertEqual(403, handler.status, "another machine on the LAN is refused even with the token")
        self.assertFalse((self.hepta_dir / "journal.json").exists())
        self.assertEqual(404, self.desk("GET", "/v1/desktop/calendar/nope")[0])
        self.assertEqual(405, self.desk("PUT", "/v1/desktop/summary")[0])
        self.assertEqual(200, self.call("GET", "/v1/mobile/summary", token=phone)[0], "the phone's own still works")
        status, value = self.desk("GET", "/v1/desktop/inbox")
        self.assertEqual((200, True), (status, "revision" in value), "the dock's inbox is still the inbox's")
        log = self.log.getvalue()
        self.assertIn("GET /v1/desktop/summary 401", log)
        self.assertIn("GET /v1/desktop/(other) 404", log)


# ====================================================================== the summary and the R1


class DesktopSummaryTest(DesktopWindowBase):
    r1_conversation = phone_tests.SummaryTest.r1_conversation

    def test_the_phones_summary_plus_r1_online_and_the_devices(self) -> None:
        self.r1_conversation()
        phone = self.pair()
        status, watch = self.call("POST", "/v1/mobile/devices/child", {"name": "Sam's Watch"}, token=phone["token"])
        self.assertEqual(200, status, watch)
        status, mine = self.call("GET", "/v1/mobile/summary", token=phone["token"])
        self.assertEqual(200, status, mine)
        status, desk = self.desk("GET", "/v1/desktop/summary")
        self.assertEqual(200, status, desk)
        self.assertEqual(set(mine) | {"devices"}, set(desk))
        for key in mine:
            if key != "r1":
                self.assertEqual(mine[key], desk[key], key)
        self.assertEqual(dict(mine["r1"], online=True), desk["r1"], "a live R1 conversation: online")
        self.assertNotIn("online", mine["r1"], "the phone's summary keeps its shape")
        self.assertNotIn("battery", desk["r1"], "the R1 reports no battery to the bridge")
        self.assertEqual([phone["deviceId"], watch["deviceId"]], [item["deviceId"] for item in desk["devices"]])
        self.assertEqual({"deviceId", "name", "platform", "createdAt", "lastSeenAt"}, set(desk["devices"][0]))
        self.assertEqual(("watchos", phone["deviceId"]), (desk["devices"][1]["platform"],
                                                          desk["devices"][1]["parentId"]))
        self.assertNotIn("tokenHash", json.dumps(desk))
        self.assertEqual("Test Mac Studio", desk["mac"]["name"])
        self.assertTrue(desk["t3"]["available"] and desk["calendar"]["available"])

    def test_r1_online_is_when_it_last_talked_to_the_bridge(self) -> None:
        r1 = self.desk("GET", "/v1/desktop/summary")[1]["r1"]
        self.assertEqual({"lastSeenAt": None, "live": False, "liveConversationId": None, "liveTitle": None,
                          "online": False}, r1, "never seen")
        self.service.r1_heard("127.0.0.1")
        self.service.r1_heard("::1")
        self.service.r1_heard("8.8.8.8")
        self.clock.advance(3)  # past the summary's 2 s cache
        self.assertEqual((None, False), tuple(self.desk("GET", "/v1/desktop/summary")[1]["r1"][key]
                                              for key in ("lastSeenAt", "online")),
                         "this Mac's own checks and peers off the LAN are not the R1")
        self.service.r1_heard(R1_ADDRESS)
        heard = mobile.iso_utc(self.clock.now)
        self.clock.advance(3)
        r1 = self.desk("GET", "/v1/desktop/summary")[1]["r1"]
        self.assertEqual((heard, True), (r1["lastSeenAt"], r1["online"]))
        phone = self.pair()["token"]
        self.assertEqual(heard, self.call("GET", "/v1/mobile/summary", token=phone)[1]["r1"]["lastSeenAt"],
                         "the phone's \"R1 last seen\" knows it too")
        self.clock.advance(mobile.R1_ONLINE_SECONDS)
        r1 = self.desk("GET", "/v1/desktop/summary")[1]["r1"]
        self.assertEqual((heard, False), (r1["lastSeenAt"], r1["online"]), "quiet for 15 minutes: not online")
        last = self.r1_conversation()  # later than the contact (the sync store keeps real times)
        self.clock.advance(3)
        r1 = self.desk("GET", "/v1/desktop/summary")[1]["r1"]
        self.assertEqual((mobile.iso_utc(last / 1000), True, CONV), (r1["lastSeenAt"], r1["online"],
                                                                     r1["liveConversationId"]),
                         "the later of the two, and a live conversation is online")

    def test_the_bridge_notes_the_r1_on_its_own_token_only(self) -> None:
        heard: List[str] = []
        original = self.service.r1_heard
        self.service.r1_heard = lambda address: (heard.append(address), original(address))  # type: ignore
        phone = self.pair()["token"]
        self.assertEqual(200, self.call("GET", "/health", token=TOKEN)[0])
        self.assertEqual(["127.0.0.1"], heard, "a request with the R1's token")
        self.assertEqual(401, self.call("GET", "/health", token="wrong-token-" + "w" * 30)[0])
        self.assertEqual(401, self.call("GET", "/v1/mac/state", token=phone)[0])
        events = [{"id": "c_r1seen0001:1", "type": "message.user", "conversationId": "c_r1seen0001",
                   "text": "hello", "at": int(NOW * 1000)}]
        self.assertEqual(200, self.call("POST", "/v1/sync/events", {"device": "r1", "events": events}, token=TOKEN)[0])
        self.assertEqual(401, self.call("POST", "/v1/sync/events", {"device": "r1", "events": events},
                                        token=phone)[0])
        self.assertEqual(2, len(heard), "the conversation sync counts, refused requests do not")
        for path in ("/v1/sync/conversations", "/v1/desktop/summary"):
            self.assertEqual(200, self.desk("GET", path)[0])
        self.assertEqual(200, self.call("GET", "/v1/mobile/summary", token=phone)[0])
        self.assertEqual(2, len(heard), "the desktop app and the phone are not the R1")
        self.clock.advance(3)
        self.assertFalse(self.desk("GET", "/v1/desktop/summary")[1]["r1"]["online"],
                         "every request here came over loopback: not the R1")


# ====================================================================== calendar


class DesktopCalendarTest(DesktopWindowBase):
    def test_agenda_by_days_and_the_phones_hours(self) -> None:
        status, value = self.desk("GET", "/v1/desktop/calendar/agenda")
        self.assertEqual(200, status, value)
        self.assertEqual(("2026-10-08T14:37:45-04:00", "2026-10-09T14:37:45-04:00"), (value["from"], value["to"]),
                         "one day by default")
        self.assertEqual(["Mom's birthday", "Standup 6612", "Dentist"], [item["title"] for item in value["events"]])
        self.assertEqual({"eventId", "title", "startsAt", "endsAt", "allDay", "location", "meetingUrl"},
                         set(value["events"][0]))
        phone = self.pair()["token"]
        self.assertEqual(value["events"], self.call("GET", "/v1/mobile/calendar/agenda", token=phone)[1]["events"],
                         "the phone's agenda (its own 24 hours: the same cache)")
        status, week = self.desk("GET", "/v1/desktop/calendar/agenda?days=7")
        self.assertEqual(200, status, week)
        self.assertEqual("2026-10-15T14:37:45-04:00", week["to"])
        self.assertIn("Next week", [item["title"] for item in week["events"]])
        args = self.composio_calls()[-1]["args"]
        self.assertEqual(("2026-10-08T14:37:45-04:00", "2026-10-15T14:37:45-04:00", True, "startTime"),
                         (args["timeMin"], args["timeMax"], args["singleEvents"], args["orderBy"]))
        self.assertEqual("2026-10-15T14:37:45-04:00", self.desk("GET", "/v1/desktop/calendar/agenda?days=30")[1]["to"],
                         "at most a week")
        self.assertEqual("2026-10-08T20:37:45-04:00",
                         self.desk("GET", "/v1/desktop/calendar/agenda?hours=6")[1]["to"], "hours work too")
        self.assertEqual("2026-10-10T14:37:45-04:00",
                         self.call("GET", "/v1/mobile/calendar/agenda?days=2", token=phone)[1]["to"],
                         "and days on the phone's route")
        status, value = self.desk("GET", "/v1/desktop/calendar/agenda?days=two")
        self.assertEqual((400, "invalid_query"), (status, value["error"]["code"]))

    def test_block_time_from_the_window(self) -> None:
        status, value = self.desk("POST", "/v1/desktop/calendar/block", {"minutes": 45, "title": "Deep work"})
        self.assertEqual(200, status, value)
        self.assertEqual((True, 45), (value["ok"], value["minutes"]))
        args = self.creates()[-1]
        self.assertEqual(("Deep work", "2026-10-08T14:37:00-04:00", "2026-10-08T15:22:00-04:00", "America/New_York"),
                         (args["summary"], args["start_datetime"], args["end_datetime"], args["timezone"]))
        self.desk("POST", "/v1/desktop/calendar/block", {"minutes": 30})
        self.assertEqual("Focus", self.creates()[-1]["summary"])
        for bad in (0, 721, "30", None):
            with self.subTest(minutes=bad):
                status, value = self.desk("POST", "/v1/desktop/calendar/block", {"minutes": bad})
                self.assertEqual((400, "invalid_minutes"), (status, value["error"]["code"]))
        fresh = self.desk("GET", "/v1/desktop/calendar/agenda")[1]
        self.assertFalse(fresh["cached"], "a block clears the agenda's cache")
        self.assertIn("Deep work", [item["title"] for item in fresh["events"]])
        self.assert_log_clean("Deep work")


# ====================================================================== journal


class DesktopJournalTest(DesktopWindowBase):
    def test_a_note_from_the_window_is_the_phones_verbatim_note(self) -> None:
        status, value = self.desk("POST", "/v1/desktop/journal", {"text": "Call *mom*  about\nthe_trip " + NOTE})
        self.assertEqual((200, {"recorded": True, "date": "2026-10-08", "time": "14:37"}), (status, value))
        journal = json.loads((self.hepta_dir / "journal.json").read_text())
        self.assertEqual({"2026-10-08": ["**14:37** Call \\*mom\\* about the\\_trip " + NOTE]}, journal,
                         "the words as typed (escaped), nothing added")
        status, value = self.desk("POST", "/v1/desktop/journal", {"text": "my password is hunter2"})
        self.assertEqual((200, True), (status, value.get("redacted")))
        self.assertEqual("**14:37** my password is \\[redacted\\]",
                         json.loads((self.hepta_dir / "journal.json").read_text())["2026-10-08"][-1])
        for bad in ({"text": "   "}, {"text": 5}, {"text": "x" * 4001}, {}):
            with self.subTest(body=bad):
                status, value = self.desk("POST", "/v1/desktop/journal", bad)
                self.assertEqual(400, status, value)
        self.assertEqual(2, len(json.loads((self.hepta_dir / "journal.json").read_text())["2026-10-08"]),
                         "only the two explicit notes")
        self.assert_log_clean(NOTE, "mom", "hunter2")


# ====================================================================== devices


class DesktopDevicesTest(DesktopWindowBase):
    def test_list_and_unpair_from_the_window(self) -> None:
        phone = self.pair()
        status, watch = self.call("POST", "/v1/mobile/devices/child", {"name": "Sam's Watch"}, token=phone["token"])
        self.assertEqual(200, status, watch)
        status, listing = self.desk("GET", "/v1/desktop/devices")
        self.assertEqual(200, status, listing)
        self.assertEqual(self.desk("GET", "/v1/mobile/devices")[1], listing, "the same list as the phone pairing's")
        self.assertEqual([phone["deviceId"], watch["deviceId"]], [item["deviceId"] for item in listing["devices"]])
        self.assertNotIn("tokenHash", json.dumps(listing))
        self.assertEqual((404, "device_not_found"),
                         (lambda answer: (answer[0], answer[1]["error"]["code"]))(
                             self.desk("DELETE", "/v1/desktop/devices/dev_0000000000000000")))
        self.assertEqual(404, self.desk("DELETE", "/v1/desktop/devices/not-a-device")[0])
        status, value = self.desk("DELETE", f"/v1/desktop/devices/{phone['deviceId']}")
        self.assertEqual((200, {"ok": True, "revoked": 2}), (status, value), "the phone and the watch it set up")
        for token in (phone["token"], watch["token"]):
            self.assertEqual(401, self.call("GET", "/v1/mobile/summary", token=token)[0])
        self.assertEqual([], self.desk("GET", "/v1/desktop/devices")[1]["devices"])
        self.assertIn("DELETE /v1/desktop/devices/{id} 200", self.log.getvalue())
        self.assertNotIn(phone["deviceId"], self.log.getvalue(), "no device ids in the log")


if __name__ == "__main__":
    unittest.main()
