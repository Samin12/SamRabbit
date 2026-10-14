"""Google Calendar routes (``/v1/calendar/*``) against a fake Composio CLI. Nothing here reaches a real
calendar: the bridge only ever runs the fake executable it is given.

Run: python3 -m unittest discover -s companion/mac-bridge/tests
"""

from __future__ import annotations

import io
import json
import logging
import os
from pathlib import Path
import sys
import tempfile
import threading
import types
import unittest
from urllib.error import HTTPError
from urllib.request import Request, urlopen

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import samrabbit_bridge as bridge  # noqa: E402
import samrabbit_calendar as gcal  # noqa: E402

TOKEN = "test-token-" + "c" * 32
TITLE = "Research the AI influencer video 7731"
DESCRIPTION = "private notes 5512"


class CalendarRoutesTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.state_dir = root / "state"
        self.state_dir.mkdir()
        self.write_state({"events": {}})
        self.composio = root / "bin" / "composio"
        self.composio.parent.mkdir()
        self.composio.write_text(f'#!/bin/sh\nexec "{sys.executable}" "{HERE / "fake_composio.py"}" '
                                 f'"{self.state_dir}" "$@"\n')
        self.composio.chmod(0o755)
        token_file = root / "bridge-token"
        token_file.write_text(TOKEN + "\n")
        token_file.chmod(0o600)
        self.log = io.StringIO()
        handler = logging.StreamHandler(self.log)
        bridge._LOG.addHandler(handler)  # noqa: SLF001
        bridge._LOG.setLevel(logging.INFO)  # noqa: SLF001
        self.addCleanup(bridge._LOG.removeHandler, handler)  # noqa: SLF001
        self.calendar_log = io.StringIO()
        calendar_handler = logging.StreamHandler(self.calendar_log)
        gcal._LOG.addHandler(calendar_handler)  # noqa: SLF001
        self.addCleanup(gcal._LOG.removeHandler, calendar_handler)  # noqa: SLF001
        self.old_secret = os.environ.get("SAMRABBIT_TEST_SECRET")
        os.environ["SAMRABBIT_TEST_SECRET"] = "do-not-pass-me"
        self.addCleanup(self._restore_env)
        self.writer = gcal.make_writer(str(self.composio))
        self.server = bridge.make_server("127.0.0.1", 0, token_file=str(token_file), cli_timeout=2.0,
                                         cli=str(root / "bin" / "no-heptabase"), driver=str(root / "bin" / "no-driver"),
                                         calendar_writer=self.writer)
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)
        self.thread.start()
        self.addCleanup(self._stop)
        self.base = f"http://127.0.0.1:{self.server.server_address[1]}"

    def _restore_env(self) -> None:
        if self.old_secret is None:
            os.environ.pop("SAMRABBIT_TEST_SECRET", None)
        else:
            os.environ["SAMRABBIT_TEST_SECRET"] = self.old_secret

    def _stop(self) -> None:
        self.server.shutdown()
        self.server.server_close()

    def write_state(self, value: dict) -> None:
        (self.state_dir / "state.json").write_text(json.dumps(value))

    def state(self) -> dict:
        return json.loads((self.state_dir / "state.json").read_text())

    def update_state(self, **changes: object) -> None:
        value = self.state()
        value.update(changes)
        self.write_state(value)

    def calls(self) -> list:
        path = self.state_dir / "calls.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def call(self, method: str, path: str, body: object = None, *, token: str | None = TOKEN) -> tuple:
        headers = {"Content-Type": "application/json"}
        if token is not None:
            headers["Authorization"] = "Bearer " + token
        data = json.dumps(body).encode() if body is not None else None
        request = Request(self.base + path, data=data, method=method, headers=headers)
        try:
            with urlopen(request, timeout=30) as response:
                return response.status, json.loads(response.read())
        except HTTPError as error:
            return error.code, json.loads(error.read() or b"{}")

    def create(self, **extra: object) -> tuple:
        body = {"title": TITLE, "startsAt": "2026-10-08T10:33:00-04:00", "endsAt": "2026-10-08T11:03:00-04:00",
                "timezone": "America/New_York", "description": DESCRIPTION, **extra}
        return self.call("POST", "/v1/calendar/events", body)

    def add_event(self, event_id: str, *, uid: str | None = None, attendees: list | None = None) -> None:
        events = self.state()["events"]
        events[event_id] = {"id": event_id, "iCalUID": uid or event_id + "@google.com", "status": "confirmed",
                            "summary": "Standup", "start": {"dateTime": "2026-10-09T10:00:00-04:00"},
                            "end": {"dateTime": "2026-10-09T10:15:00-04:00"}}
        if attendees is not None:
            events[event_id]["attendees"] = attendees
        self.update_state(events=events)

    # ------------------------------------------------------------------ auth, health, availability

    def test_every_calendar_route_requires_the_token_and_a_local_peer(self) -> None:
        routes = (("GET", "/v1/calendar/status", None), ("POST", "/v1/calendar/events", {"title": "x"}),
                  ("POST", "/v1/calendar/events/update", {"iCalUID": "a@google.com"}),
                  ("POST", "/v1/calendar/events/delete", {"iCalUID": "a@google.com"}), ("GET", "/v1/calendar/x", None))
        for method, path, body in routes:
            for token in (None, "wrong-" + "t" * 40):
                with self.subTest(path=path, token=token):
                    status, value = self.call(method, path, body, token=token)
                    self.assertEqual(401, status)
                    self.assertEqual("unauthorized", value["error"]["code"])
        self.server.allow_any_client = True
        original = bridge.client_allowed
        bridge.client_allowed = lambda _address: False
        try:
            self.assertEqual(403, self.create()[0], "calendar changes never leave the local network")
            self.assertEqual(403, self.call("GET", "/v1/calendar/status")[0])
        finally:
            bridge.client_allowed = original
        self.assertEqual([], self.calls(), "nothing reached Composio")

    def test_health_and_status_report_calendar_write_without_running_the_cli(self) -> None:
        status, health = self.call("GET", "/health")
        self.assertEqual(200, status)
        calendar = health["calendarWrite"]
        self.assertTrue(calendar["available"])
        self.assertEqual(str(self.composio), calendar["path"])
        self.assertEqual("primary", calendar["calendarId"])
        self.assertIsNone(calendar["account"])
        self.assertEqual(200, self.call("GET", "/v1/calendar/status")[0])
        self.assertEqual([], self.calls(), "availability is cheap: no CLI run, no network")
        self.assertEqual(405, self.call("POST", "/v1/calendar/status", {})[0])
        self.assertEqual(405, self.call("GET", "/v1/calendar/events")[0])

    def test_a_checkout_copy_never_changes_the_real_calendar_without_an_explicit_cli(self) -> None:
        self.assertEqual(bridge.CLI_DRY_RUN, bridge.default_cli_choice(), "tests run from a checkout")
        token_file = Path(self.tmp.name) / "bridge-token"
        server = bridge.make_server("127.0.0.1", 0, token_file=str(token_file), cli="dry-run",
                                    driver=str(Path(self.tmp.name) / "no-cua-driver"), sync_dir=None,
                                    artifacts_dir=str(Path(self.tmp.name) / "artifacts"))
        self.addCleanup(server.server_close)
        self.assertIsInstance(server.calendar, gcal.UnavailableWriter)
        self.assertEqual("calendar_dev_copy", server.calendar.code)
        self.assertFalse(server.calendar.capabilities()["available"])

    def test_missing_cli_is_reported_and_refused_honestly(self) -> None:
        self.server.calendar = gcal.make_writer(str(self.composio) + "-absent")
        self.addCleanup(self.server.calendar.close)
        status, value = self.call("GET", "/v1/calendar/status")
        self.assertEqual(200, status)
        self.assertFalse(value["available"])
        status, value = self.create()
        self.assertEqual(503, status)
        self.assertEqual("composio_missing", value["error"]["code"])
        self.assertFalse(value["error"]["written"])

    def test_the_executable_is_found_from_the_recorded_path_then_the_usual_folders(self) -> None:
        cli = gcal.ComposioCli()
        self.addCleanup(cli.close)
        old = os.environ.get("SAMRABBIT_COMPOSIO")
        os.environ["SAMRABBIT_COMPOSIO"] = str(self.composio)
        try:
            self.assertEqual(str(self.composio), cli.executable())
        finally:
            if old is None:
                os.environ.pop("SAMRABBIT_COMPOSIO", None)
            else:
                os.environ["SAMRABBIT_COMPOSIO"] = old
        self.assertEqual(("~/.local/bin/composio", "/opt/homebrew/bin/composio", "/usr/local/bin/composio"),
                         gcal.FALLBACK_COMPOSIO)
        explicit = gcal.ComposioCli(str(self.composio) + "-absent")
        self.addCleanup(explicit.close)
        self.assertIsNone(explicit.executable(), "an explicit path never falls back to a real CLI")

    # ------------------------------------------------------------------ create

    def test_create_runs_composio_with_json_on_stdin_and_answers_the_event(self) -> None:
        status, value = self.create(location="Home office")
        self.assertEqual(200, status, value)
        event = value["event"]
        self.assertEqual("fakeevent0001abc", event["eventId"])
        self.assertEqual("fakeevent0001abc@google.com", event["iCalUID"])
        self.assertEqual(TITLE, event["title"])
        self.assertEqual("2026-10-08T10:33:00-04:00", event["startsAt"])
        self.assertEqual("2026-10-08T11:03:00-04:00", event["endsAt"])
        self.assertEqual("America/New_York", event["timezone"])
        self.assertEqual("primary", value["calendarId"])
        self.assertEqual("samin@aianswer.us", value["account"])
        [call] = self.calls()
        self.assertEqual(["execute", "GOOGLECALENDAR_CREATE_EVENT", "-d", "-", "--account", gcal.DEFAULT_CONNECTION],
                         call["argv"], "the event never travels on argv; the connection is always named")
        self.assertEqual("googlecalendar_awest-hug", call["account"], "the samin@aianswer.us connection")
        self.assertEqual(os.path.realpath(call["cwd"]), os.path.realpath(call["tmpdir"]),
                         "the call's own private folder is its TMPDIR")
        self.assertNotEqual(os.environ.get("TMPDIR"), call["tmpdir"])
        self.assertFalse(os.path.exists(call["cwd"]), "and it is gone after the call")
        self.assertEqual({"calendar_id": "primary", "summary": TITLE, "start_datetime": "2026-10-08T10:33:00-04:00",
                          "end_datetime": "2026-10-08T11:03:00-04:00", "timezone": "America/New_York",
                          "description": DESCRIPTION, "location": "Home office", "create_meeting_room": False,
                          "exclude_organizer": True, "send_updates": "none"}, call["args"])
        self.assertNotIn("SAMRABBIT_TEST_SECRET", call["env"], "the CLI gets a small environment")
        self.assertNotEqual(os.getcwd(), call["cwd"])
        self.assertEqual("samin@aianswer.us", self.call("GET", "/health")[1]["calendarWrite"]["account"])
        logged = self.log.getvalue()
        self.assertIn("/v1/calendar/events", logged)
        self.assertNotIn(TITLE, logged)
        self.assertNotIn(DESCRIPTION, logged)

    def test_create_accepts_utc_and_a_calendar_id_and_validates_before_running(self) -> None:
        status, value = self.call("POST", "/v1/calendar/events", {
            "title": "Call", "startsAt": "2026-10-08T14:33:00Z", "endsAt": "2026-10-08T15:03:00.000Z",
            "calendarId": "samin@aianswer.us"})
        self.assertEqual(200, status, value)
        self.assertEqual({"calendar_id": "samin@aianswer.us", "summary": "Call",
                          "start_datetime": "2026-10-08T14:33:00+00:00", "end_datetime": "2026-10-08T15:03:00+00:00",
                          "create_meeting_room": False, "exclude_organizer": True, "send_updates": "none"},
                         self.calls()[-1]["args"])
        before = len(self.calls())
        bad = (
            {"startsAt": "2026-10-08T10:33:00-04:00", "endsAt": "2026-10-08T11:03:00-04:00"},
            {"title": "x", "startsAt": "2026-10-08T10:33:00", "endsAt": "2026-10-08T11:03:00-04:00"},
            {"title": "x", "startsAt": "2026-10-08T11:33:00-04:00", "endsAt": "2026-10-08T11:03:00-04:00"},
            {"title": "x", "startsAt": "2026-10-08T10:33:00-04:00"},
            {"title": "x", "startsAt": "2026-10-08T10:33:00-04:00", "endsAt": "2026-12-08T11:03:00-04:00"},
            {"title": "x", "startsAt": "2026-10-08T10:33:00-04:00", "endsAt": "2026-10-08T11:03:00-04:00",
             "timezone": "Eastern Time"},
            {"title": "x", "startsAt": "2026-10-08T10:33:00-04:00", "endsAt": "2026-10-08T11:03:00-04:00",
             "calendarId": "bad id; rm"},
            {"title": "x" * 400, "startsAt": "2026-10-08T10:33:00-04:00", "endsAt": "2026-10-08T11:03:00-04:00"},
        )
        for body in bad:
            with self.subTest(body=body):
                status, value = self.call("POST", "/v1/calendar/events", body)
                self.assertEqual(400, status, value)
                self.assertFalse(value["error"]["written"])
        self.assertEqual(before, len(self.calls()), "invalid requests never reach Composio")

    # ------------------------------------------------------------------ update and delete

    def test_update_by_google_uid_patches_the_event_and_keeps_occurrences_single(self) -> None:
        self.add_event("abcdefghij0123")
        status, value = self.call("POST", "/v1/calendar/events/update", {
            "iCalUID": "abcdefghij0123@google.com", "startsAt": "2026-10-09T11:00:00-04:00",
            "endsAt": "2026-10-09T11:15:00-04:00", "timezone": "America/New_York"})
        self.assertEqual(200, status, value)
        self.assertEqual("2026-10-09T11:00:00-04:00", value["event"]["startsAt"])
        [call] = self.calls()
        self.assertEqual("GOOGLECALENDAR_PATCH_EVENT", call["slug"])
        self.assertEqual({"calendar_id": "primary", "event_id": "abcdefghij0123", "send_updates": "none",
                          "start_time": "2026-10-09T11:00:00-04:00", "end_time": "2026-10-09T11:15:00-04:00",
                          "timezone": "America/New_York"}, call["args"])
        # One occurrence of a repeating event: the instance id, never the series id.
        status, value = self.call("POST", "/v1/calendar/events/update", {
            "iCalUID": "abcdefghij0123@google.com", "recurrenceId": "20261010T140000Z", "title": "Moved standup"})
        self.assertEqual(200, status, value)
        self.assertEqual("abcdefghij0123_20261010T140000Z", self.calls()[-1]["args"]["event_id"])
        self.assertEqual({"summary": "Moved standup"},
                         {k: v for k, v in self.calls()[-1]["args"].items()
                          if k not in ("calendar_id", "event_id", "send_updates")})
        self.assertEqual(400, self.call("POST", "/v1/calendar/events/update",
                                        {"iCalUID": "abcdefghij0123@google.com"})[0], "nothing to change")
        self.assertEqual(400, self.call("POST", "/v1/calendar/events/update",
                                        {"iCalUID": "abcdefghij0123@google.com", "recurrenceId": "tomorrow",
                                         "title": "x"})[0])

    def test_updates_report_the_guests_google_has_and_never_email_them(self) -> None:
        self.add_event("guestevent0001", attendees=[
            {"email": "samin@aianswer.us", "self": True, "organizer": True},
            {"email": "partner@example.com"}, {"email": "cofounder@example.com"},
            {"email": "room-12@resource.calendar.google.com", "resource": True}])
        self.add_event("soloevent00001")
        status, value = self.call("POST", "/v1/calendar/events/update",
                                  {"iCalUID": "guestevent0001@google.com", "title": "Moved standup"})
        self.assertEqual(200, status, value)
        self.assertEqual(2, value["event"]["guests"], "attendees other than the user and rooms")
        self.assertEqual("none", self.calls()[-1]["args"]["send_updates"], "nobody is emailed")
        status, value = self.call("POST", "/v1/calendar/events/update",
                                  {"iCalUID": "soloevent00001@google.com", "title": "Solo"})
        self.assertEqual((200, 0), (status, value["event"]["guests"]))

    def test_a_foreign_uid_is_looked_up_read_only_first(self) -> None:
        self.add_event("outlookcopy01", uid="040000008200E00074C5B7101A82E008@outlook.com")
        status, value = self.call("POST", "/v1/calendar/events/delete",
                                  {"iCalUID": "040000008200E00074C5B7101A82E008@outlook.com"})
        self.assertEqual(200, status, value)
        self.assertEqual(["GOOGLECALENDAR_EVENTS_LIST", "GOOGLECALENDAR_DELETE_EVENT"],
                         [call["slug"] for call in self.calls()])
        self.assertEqual("040000008200E00074C5B7101A82E008@outlook.com", self.calls()[0]["args"]["iCalUID"])
        self.assertEqual({"calendar_id": "primary", "event_id": "outlookcopy01", "send_updates": "none"},
                         self.calls()[1]["args"])
        self.assertEqual({}, self.state()["events"])
        status, value = self.call("POST", "/v1/calendar/events/delete", {"iCalUID": "missing@outlook.com"})
        self.assertEqual(404, status)
        self.assertEqual("calendar_event_not_found", value["error"]["code"])
        self.assertEqual("GOOGLECALENDAR_EVENTS_LIST", self.calls()[-1]["slug"], "nothing was deleted")

    def test_delete_of_a_missing_event_is_an_error_not_a_success(self) -> None:
        status, value = self.call("POST", "/v1/calendar/events/delete", {"iCalUID": "zzzzzzzz0000@google.com"})
        self.assertEqual(404, status)
        self.assertEqual("calendar_event_not_found", value["error"]["code"])
        self.assertFalse(value["error"]["written"])

    # ------------------------------------------------------------------ Composio failures

    def test_composio_failures_map_to_structured_errors(self) -> None:
        cases = (
            ({"stdout": json.dumps({"successful": False, "slug": "ToolRouterV2_NoActiveConnection",
                                    "error": "No active connection found for toolkit \"googlecalendar\". Run "
                                             "`composio link googlecalendar`, then retry."})},
             409, "calendar_not_connected", False),
            ({"stdout": json.dumps({"successful": False, "data": {"message": "Forbidden", "status_code": 403},
                                    "error": "Forbidden"})}, 403, "calendar_forbidden", False),
            ({"stdout": json.dumps({"successful": False, "data": {"message": "Backend Error", "status_code": 503},
                                    "error": "Backend Error"})}, 502, "calendar_google_error", "unknown"),
            ({"stdout": json.dumps({"successful": False, "error": "Input validation failed for X"})},
             400, "calendar_invalid_request", False),
            ({"stdout": ""}, 503, "composio_signed_out", False),
            ({"stdout": "not json at all"}, 502, "calendar_bad_answer", "unknown"),
            ({"stdout": "", "rc": 3}, 502, "composio_failed", "unknown"),
        )
        for scripted, status_code, code, written in cases:
            with self.subTest(code=code):
                self.update_state(scripted={"GOOGLECALENDAR_CREATE_EVENT": scripted})
                status, value = self.create()
                self.assertEqual(status_code, status, value)
                self.assertEqual(code, value["error"]["code"])
                self.assertEqual(written, value["error"]["written"])
                self.assertNotIn("composio link googlecalendar`, then", value["error"]["message"],
                                 "Composio's own text is not passed through")
        self.assertEqual("composio_failed", self.call("GET", "/v1/calendar/status")[1]["lastError"])

    def test_google_rate_limits_are_retryable_not_forbidden(self) -> None:
        google = lambda reason: json.dumps({"error": {"code": 403, "message": "Rate Limit Exceeded",  # noqa: E731
                                                      "errors": [{"domain": "usageLimits", "reason": reason}]}})
        cases = (
            {"successful": False, "data": {"message": "Rate Limit Exceeded", "status_code": 403,
                                           "errors": [{"reason": "rateLimitExceeded"}]}, "error": "Forbidden"},
            {"successful": False, "data": {"message": google("userRateLimitExceeded"), "status_code": 403},
             "error": "403 Client Error: Forbidden"},
            {"successful": False, "error": "403 Client Error: Forbidden " + google("rateLimitExceeded")},
            {"successful": False, "data": {"message": "Too Many Requests", "status_code": 429}, "error": "429"},
        )
        for answer in cases:
            with self.subTest(answer=answer):
                self.update_state(scripted={"GOOGLECALENDAR_PATCH_EVENT": {"stdout": json.dumps(answer)}})
                status, value = self.call("POST", "/v1/calendar/events/update",
                                          {"eventId": "abcdefghij0123", "title": "x"})
                self.assertEqual(503, status, value)
                self.assertEqual(("calendar_rate_limited", True, False),
                                 (value["error"]["code"], value["error"]["retryable"], value["error"]["written"]))
        self.update_state(scripted={"GOOGLECALENDAR_PATCH_EVENT": {"stdout": json.dumps({
            "successful": False, "data": {"message": "Forbidden", "status_code": 403,
                                          "errors": [{"reason": "forbiddenForNonOrganizer"}],
                                          "headers": {"x-ratelimit-remaining": "99"}}, "error": "Forbidden"})}})
        status, value = self.call("POST", "/v1/calendar/events/update", {"eventId": "abcdefghij0123", "title": "x"})
        self.assertEqual((403, "calendar_forbidden", False),
                         (status, value["error"]["code"], value["error"]["retryable"]), "a real refusal stays one")

    def test_a_bad_calendar_id_or_temp_folder_turns_calendar_changes_off_not_the_bridge(self) -> None:
        # Only samrabbit_calendar's view of tempfile is replaced (Mac control and generated UIs keep theirs).
        created: list = []
        failing = {"on": False}

        def calendar_mkdtemp(*args: object, **kwargs: object) -> str:
            if failing["on"]:
                raise PermissionError("no temp folder")
            path = tempfile.mkdtemp(*args, **kwargs)
            created.append(path)
            return path

        real_tempfile = gcal.tempfile
        gcal.tempfile = types.SimpleNamespace(mkdtemp=calendar_mkdtemp)  # type: ignore[assignment]
        self.addCleanup(setattr, gcal, "tempfile", real_tempfile)
        old_id = os.environ.get("SAMRABBIT_CALENDAR_ID")
        os.environ["SAMRABBIT_CALENDAR_ID"] = "not a calendar id!"
        self.addCleanup(lambda: os.environ.pop("SAMRABBIT_CALENDAR_ID", None) if old_id is None
                        else os.environ.__setitem__("SAMRABBIT_CALENDAR_ID", old_id))
        root = Path(self.tmp.name)
        for code, no_temp_folder in (("calendar_id_invalid", False), ("calendar_setup_failed", True)):
            with self.subTest(code=code):
                failing["on"] = no_temp_folder
                server = bridge.make_server("127.0.0.1", 0, token_file=str(root / "bridge-token"), cli_timeout=2.0,
                                            cli=str(root / "bin" / "no-heptabase"),
                                            driver=str(root / "bin" / "no-driver"), composio=str(self.composio))
                thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)
                thread.start()
                self.addCleanup(server.server_close)
                self.addCleanup(server.shutdown)
                self.base = f"http://127.0.0.1:{server.server_address[1]}"
                status, health = self.call("GET", "/health")
                self.assertEqual(200, status, "the bridge is up")
                self.assertEqual({"available": False, "lastError": code},
                                 {key: health["calendarWrite"][key] for key in ("available", "lastError")})
                self.assertEqual((200, False), (lambda answer: (answer[0], answer[1]["available"]))(
                    self.call("GET", "/v1/calendar/status")))
                status, value = self.create()
                self.assertEqual((503, "calendar_unavailable", False),
                                 (status, value["error"]["code"], value["error"]["written"]))
                self.assertEqual(503, self.call("POST", "/v1/heptabase/journal/append",
                                                {"date": "2026-10-08", "content": "x"})[0],
                                 "the journal routes still answer (here: no CLI)")
        self.assertEqual([], self.calls(), "nothing reached Composio")
        self.assertTrue(created, "the bad id case did create the private folder first")
        self.assertFalse(any(os.path.exists(path) for path in created), "and removed it again")
        self.assertIn("calendar changes off", self.log.getvalue() + _calendar_log(self))
        self.assertNotIn("not a calendar id!", self.log.getvalue() + _calendar_log(self))

    def test_a_slow_cli_is_killed_and_the_write_is_reported_as_unknown(self) -> None:
        self.server.calendar = gcal.CalendarWriter(gcal.ComposioCli(str(self.composio), timeout=1.0))
        self.addCleanup(self.server.calendar.close)
        self.update_state(slow={"GOOGLECALENDAR_CREATE_EVENT": 5})
        status, value = self.create()
        self.assertEqual(504, status)
        self.assertEqual("calendar_timeout", value["error"]["code"])
        self.assertEqual("unknown", value["error"]["written"], "the event may have been added")

    def test_answers_without_an_event_id_say_it_was_probably_added(self) -> None:
        self.update_state(scripted={"GOOGLECALENDAR_CREATE_EVENT": {
            "stdout": json.dumps({"successful": True, "data": {"response_data": {}}})}})
        status, value = self.create()
        self.assertEqual(502, status)
        self.assertEqual("unknown", value["error"]["written"])


def _calendar_log(test: CalendarRoutesTest) -> str:
    return test.calendar_log.getvalue()


if __name__ == "__main__":
    unittest.main()
