"""The shared Composio runner (``samrabbit_composio``) against the fake CLI: the slug allow-list (nothing that sends,
forwards, deletes or relabels mail ever starts a process), ``--account`` on every call, and the private ``TMPDIR``
wiped after every call. Nothing here reaches a real Composio, Gmail or Google Calendar.

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
import unittest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import samrabbit_briefing as briefing  # noqa: E402
import samrabbit_calendar as gcal  # noqa: E402
import samrabbit_composio as composio  # noqa: E402

# Everything Composio's Gmail toolkit can do that the bridge must never do (sending, forwarding, deleting, labels,
# filters, settings), plus a few from other toolkits and lookalikes.
FORBIDDEN = ("GMAIL_SEND_EMAIL", "GMAIL_REPLY_TO_THREAD", "GMAIL_SEND_DRAFT", "GMAIL_FORWARD_MESSAGE",
             "GMAIL_DELETE_MESSAGE", "GMAIL_DELETE_DRAFT", "GMAIL_BATCH_DELETE_MESSAGES", "GMAIL_MOVE_TO_TRASH",
             "GMAIL_MODIFY_THREAD_LABELS", "GMAIL_ADD_LABEL_TO_EMAIL", "GMAIL_BATCH_MODIFY_MESSAGES",
             "GMAIL_CREATE_FILTER", "GMAIL_UPDATE_DRAFT", "GMAIL_PATCH_LABEL", "GMAIL_IMPORT_MESSAGE",
             "GMAIL_INSERT_MESSAGE", "GMAIL_LIST_DRAFTS", "GMAIL_LIST_THREADS", "SLACK_SEND_MESSAGE",
             "GITHUB_CREATE_ISSUE", "gmail_create_email_draft", "GMAIL_CREATE_EMAIL_DRAFT ", "GMAIL_FETCH_EMAILS\n",
             "", "GOOGLECALENDAR_QUICK_ADD")


class RunnerTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.state_dir = root / "state"
        self.state_dir.mkdir()
        self.write_state({"events": {}, "gmail": {"samin-gmail": {"profile": {"emailAddress": "samin@aianswer.us"},
                                                                  "messages": []}}})
        self.composio = root / "bin" / "composio"
        self.composio.parent.mkdir()
        self.composio.write_text(f'#!/bin/sh\nexec "{sys.executable}" "{HERE / "fake_composio.py"}" '
                                 f'"{self.state_dir}" "$@"\n')
        self.composio.chmod(0o755)
        self.log = io.StringIO()
        handler = logging.StreamHandler(self.log)
        composio._LOG.addHandler(handler)  # noqa: SLF001
        self.addCleanup(composio._LOG.removeHandler, handler)  # noqa: SLF001

    def write_state(self, value: dict) -> None:
        (self.state_dir / "state.json").write_text(json.dumps(value))

    def state(self) -> dict:
        return json.loads((self.state_dir / "state.json").read_text())

    def calls(self) -> list:
        path = self.state_dir / "calls.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def runner(self, **kwargs: object) -> composio.ComposioCli:
        cli = composio.ComposioCli(str(self.composio), toolkit=briefing.GMAIL, **kwargs)  # type: ignore[arg-type]
        self.addCleanup(cli.close)
        return cli

    def test_the_allow_list_is_exactly_the_reads_the_draft_and_the_calendar(self) -> None:
        self.assertEqual({"GMAIL_FETCH_EMAILS", "GMAIL_FETCH_MESSAGE_BY_THREAD_ID", "GMAIL_FETCH_MESSAGE_BY_MESSAGE_ID",
                          "GMAIL_GET_PROFILE", "GMAIL_LIST_LABELS", "GMAIL_LIST_HISTORY", "GMAIL_CREATE_EMAIL_DRAFT",
                          "GOOGLECALENDAR_CREATE_EVENT", "GOOGLECALENDAR_PATCH_EVENT", "GOOGLECALENDAR_DELETE_EVENT",
                          "GOOGLECALENDAR_EVENTS_LIST"}, set(composio.ALLOWED_SLUGS))
        self.assertFalse(any("SEND" in slug or "FORWARD" in slug or "REPLY" in slug or "TRASH" in slug
                             for slug in composio.ALLOWED_SLUGS), "nothing on the list sends or deletes mail")

    def test_anything_else_is_refused_before_a_process_starts(self) -> None:
        cli = self.runner()
        for slug in FORBIDDEN:
            for writing in (False, True):
                with self.subTest(slug=slug, writing=writing):
                    with self.assertRaises(composio.ComposioError) as caught:
                        cli.execute(slug, {"recipient_email": "someone@example.com", "body": "hi"}, writing=writing,
                                    account="samin-gmail")
                    self.assertEqual((403, "composio_tool_refused", False),
                                     (caught.exception.status, caught.exception.code, caught.exception.written))
        self.assertEqual([], self.calls(), "the CLI never ran")
        self.assertNotIn("sent", self.state(), "and nothing was sent")
        self.assertIn("composio tool refused (not on the allow-list)", self.log.getvalue())
        self.assertNotIn("someone@example.com", self.log.getvalue())

    def test_a_toolkit_never_runs_another_toolkits_tools(self) -> None:
        gmail = self.runner()
        with self.assertRaises(composio.ComposioError):
            gmail.execute("GOOGLECALENDAR_DELETE_EVENT", {"event_id": "x"}, writing=True, account="samin-gmail")
        calendar = gcal.ComposioCli(str(self.composio))
        self.addCleanup(calendar.close)
        with self.assertRaises(gcal.CalendarError) as caught:
            calendar.execute("GMAIL_CREATE_EMAIL_DRAFT", {}, writing=True)
        self.assertEqual("composio_tool_refused", caught.exception.code)
        self.assertEqual([], self.calls())

    def test_a_narrowed_runner_runs_only_its_own_tools(self) -> None:
        drafter = self.runner(allowed={composio.GMAIL_DRAFT_SLUG, "GMAIL_FETCH_MESSAGE_BY_MESSAGE_ID"})
        self.assertEqual({composio.GMAIL_DRAFT_SLUG, "GMAIL_FETCH_MESSAGE_BY_MESSAGE_ID"}, set(drafter.allowed))
        for slug in ("GMAIL_FETCH_EMAILS", "GMAIL_GET_PROFILE", "GMAIL_SEND_EMAIL"):
            with self.assertRaises(composio.ComposioError):
                drafter.execute(slug, {}, writing=False, account="samin-gmail")
        reader = self.runner(allowed=composio.GMAIL_READ_SLUGS)
        with self.assertRaises(composio.ComposioError):
            reader.execute(composio.GMAIL_DRAFT_SLUG, {}, writing=True, account="samin-gmail")
        widened = self.runner(allowed={"GMAIL_SEND_EMAIL", "GMAIL_FETCH_EMAILS"})
        self.assertEqual({"GMAIL_FETCH_EMAILS"}, set(widened.allowed), "a runner can never widen the bridge's list")
        self.assertEqual([], self.calls())

    def test_the_account_is_always_passed_and_checked(self) -> None:
        cli = self.runner()
        for account in (None, "", "two words", "-flag", "x" * 200):
            with self.subTest(account=account):
                with self.assertRaises(composio.ComposioError) as caught:
                    cli.execute("GMAIL_GET_PROFILE", {}, writing=False, account=account)  # type: ignore[arg-type]
                self.assertEqual("composio_account_missing", caught.exception.code)
        self.assertEqual([], self.calls())
        data = cli.execute("GMAIL_GET_PROFILE", {"user_id": "me"}, writing=False, account="samin-gmail")
        self.assertEqual("samin@aianswer.us", data["emailAddress"])
        [call] = self.calls()
        self.assertEqual(["execute", "GMAIL_GET_PROFILE", "-d", "-", "--account", "samin-gmail"], call["argv"])
        self.assertEqual({"user_id": "me"}, call["args"], "the arguments travel on stdin")

    def test_every_call_gets_a_private_tmpdir_that_is_wiped_after_it(self) -> None:
        self.write_state(dict(self.state(), dump=True))
        cli = self.runner()
        outer = os.environ.get("TMPDIR")
        for _ in range(2):
            cli.execute("GMAIL_GET_PROFILE", {}, writing=False, account="samin-gmail")
        first, second = self.calls()
        for call in (first, second):
            self.assertEqual(os.path.realpath(call["cwd"]), os.path.realpath(call["tmpdir"]))
            self.assertNotEqual(outer, call["tmpdir"], "never the user's own TMPDIR")
            self.assertFalse(os.path.exists(call["cwd"]), "the folder and the CLI's adhoc dump in it are gone")
            self.assertNotIn("SAMRABBIT_TEST_SECRET", call["env"])
        self.assertNotEqual(first["cwd"], second["cwd"], "a fresh folder per call")
        parent = Path(first["cwd"]).parent
        self.assertEqual(0o700, parent.stat().st_mode & 0o777)
        self.assertEqual([], list(parent.iterdir()), "nothing is left in the runner's own folder")
        cli.close()
        self.assertFalse(parent.exists())

    def test_the_calendar_names_its_samin_connection(self) -> None:
        cli = gcal.ComposioCli(str(self.composio))
        self.addCleanup(cli.close)
        self.assertEqual("googlecalendar_awest-hug", cli.account)
        old = os.environ.get("SAMRABBIT_CALENDAR_CONNECTION")
        os.environ["SAMRABBIT_CALENDAR_CONNECTION"] = "googlecalendar_gell-tunder"
        try:
            other = gcal.ComposioCli(str(self.composio))
            self.addCleanup(other.close)
            self.assertEqual("googlecalendar_gell-tunder", other.account)
        finally:
            if old is None:
                os.environ.pop("SAMRABBIT_CALENDAR_CONNECTION", None)
            else:
                os.environ["SAMRABBIT_CALENDAR_CONNECTION"] = old
        cli.execute("GOOGLECALENDAR_EVENTS_LIST", {"calendarId": "primary", "iCalUID": "x@google.com"}, writing=False)
        self.assertEqual("googlecalendar_awest-hug", self.calls()[-1]["account"])

    def test_gmail_failures_in_the_bridges_words(self) -> None:
        cli = self.runner()
        with self.assertRaises(composio.ComposioError) as caught:
            cli.execute("GMAIL_GET_PROFILE", {}, writing=False, account="samin-personal-gmail")  # no such mailbox
        self.assertEqual((409, "gmail_not_connected"), (caught.exception.status, caught.exception.code))
        self.assertIn("composio link gmail", caught.exception.fix or "")
        self.write_state(dict(self.state(), scripted={"GMAIL_FETCH_EMAILS": {"stdout": json.dumps(
            {"successful": False, "error": "Rate limit exceeded", "data": {"status_code": 429}})}}))
        with self.assertRaises(composio.ComposioError) as caught:
            cli.execute("GMAIL_FETCH_EMAILS", {}, writing=False, account="samin-gmail")
        self.assertEqual(("gmail_rate_limited", True), (caught.exception.code, caught.exception.retryable))
        self.write_state(dict(self.state(), scripted={"GMAIL_FETCH_EMAILS": {"stdout": "", "rc": 0}}))
        with self.assertRaises(composio.ComposioError) as caught:
            cli.execute("GMAIL_FETCH_EMAILS", {}, writing=False, account="samin-gmail")
        self.assertEqual("composio_signed_out", caught.exception.code)

    def test_an_explicit_only_runner_never_looks_for_a_cli(self) -> None:
        cli = composio.ComposioCli(None, toolkit=briefing.GMAIL, explicit_only=True)
        self.addCleanup(cli.close)
        old = os.environ.get("SAMRABBIT_COMPOSIO")
        os.environ["SAMRABBIT_COMPOSIO"] = str(self.composio)
        try:
            self.assertIsNone(cli.executable())
            with self.assertRaises(composio.ComposioError) as caught:
                cli.execute("GMAIL_GET_PROFILE", {}, writing=False, account="samin-gmail")
            self.assertEqual("composio_missing", caught.exception.code)
        finally:
            if old is None:
                os.environ.pop("SAMRABBIT_COMPOSIO", None)
            else:
                os.environ["SAMRABBIT_COMPOSIO"] = old
        self.assertEqual([], self.calls())


if __name__ == "__main__":
    unittest.main()
