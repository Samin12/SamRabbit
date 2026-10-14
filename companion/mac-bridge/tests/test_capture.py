"""Quick voice notes (``/v1/capture``, ``/v1/mobile/capture``, ``/v1/desktop/capture``; ``samrabbit_capture.py``) end to
end on a real bridge on a random loopback port, against fakes only: the fake T3 server and CLI, the fake Heptabase CLI
(its journal is a file in a temp folder), the fake Composio (a fake Google calendar), a fake transcription helper and a
fake Claude Code for the router. Temp tokens, a temp HOME for the inbox, a fake clock. Nothing here reaches the live
bridge, the real journal, Google Calendar, T3 Code or a microphone, and nothing plays.

Run: python3 -m unittest discover -s companion/mac-bridge/tests
"""

from __future__ import annotations

from datetime import datetime, timedelta
import io
import json
import logging
import os
from pathlib import Path
import stat
import sys
import time
import unittest
import uuid
from typing import Any, Dict, List, Optional, Tuple
from zoneinfo import ZoneInfo

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE))

import samrabbit_capture as capture  # noqa: E402
import samrabbit_claude as claude  # noqa: E402
import samrabbit_inbox as inbox  # noqa: E402
import samrabbit_t3 as t3  # noqa: E402
import samrabbit_transcribe as transcribe  # noqa: E402
from test_mobile import DESKTOP, NOW, TOKEN, FakeHandler, MobileBase  # noqa: E402
from test_transcribe import wav  # noqa: E402

ZONE = ZoneInfo("America/New_York")
CAPTURED = datetime.fromtimestamp(NOW - 60, ZONE)  # 14:36:45, a minute before the bridge's "now"
SECRET_WORDS = "the private 6142 plan"


class CaptureBase(MobileBase):
    """The mobile test bridge, with its own capture service (fake router Claude, temp folder, the fake clock) and an
    inbox that reads a temp HOME."""

    def make_transcriber(self, bin_dir: Path) -> Any:
        self.voice_dir = self.root / "voice"
        self.voice_dir.mkdir()
        helper = bin_dir / "samrabbit-transcribe"
        helper.write_text(f'#!/bin/sh\nexec "{sys.executable}" "{HERE / "fake_transcribe.py"}" '
                          f'--state "{self.voice_dir}" "$@"\n')
        helper.chmod(0o755)
        return transcribe.Transcriber(str(helper), timeout=10.0, check_timeout=5.0)

    def setUp(self) -> None:
        super().setUp()
        self.router_dir = self.root / "router"
        self.router_dir.mkdir()
        self.answers([{"mode": "garbage"}])
        router_cli = self.root / "bin" / "router-claude"
        router_cli.write_text(f'#!/bin/sh\nexec "{sys.executable}" "{HERE / "fake_structured_claude.py"}" '
                              f'--state "{self.router_dir}" "$@"\n')
        router_cli.chmod(0o755)
        self.classifier = claude.ClaudeJson(str(router_cli), model="claude-haiku-5-5", timeout=10.0,
                                            explicit_only=True)
        self.server.capture.close()
        self.folder = self.root / "capture"
        self.capture = capture.CaptureService(str(self.folder), router=capture.CaptureRouter(self.classifier),
                                              timezone_name="America/New_York", clock=self.clock.time,
                                              monotonic=self.clock.monotonic)
        self.capture.attach(self.server)
        self.server.capture = self.capture
        self.addCleanup(self.capture.close)
        home = self.root / "inbox-home"
        home.mkdir()
        self.server.inbox = inbox.InboxService(home=str(home), clock=self.clock.time, monotonic=self.clock.monotonic)
        self.server.inbox.attach(self.server)
        self.addCleanup(self.server.inbox.close)
        self.capture_log = io.StringIO()
        handler = logging.StreamHandler(self.capture_log)
        capture._LOG.addHandler(handler)  # noqa: SLF001
        capture._LOG.setLevel(logging.INFO)  # noqa: SLF001
        self.addCleanup(capture._LOG.removeHandler, handler)  # noqa: SLF001
        self.phone = self.pair()["token"]

    # ------------------------------------------------------------------ helpers
    def answers(self, values: List[Dict[str, Any]]) -> None:
        (self.router_dir / "answers.json").write_text(json.dumps(values))

    def router_calls(self) -> List[Dict[str, Any]]:
        path = self.router_dir / "calls.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def submit(self, text: Optional[str] = None, *, audio: Optional[bytes] = None, path: str = "/v1/capture",
               capture_id: Optional[str] = None, captured: Optional[datetime] = CAPTURED, token: Optional[str] = TOKEN,
               desktop: bool = False, source: Optional[str] = None, extra: Optional[Dict[str, str]] = None,
               query: str = "") -> Tuple[int, Dict[str, Any]]:
        capture_id = capture_id or str(uuid.uuid4())
        headers = {"X-SamRabbit-Capture": capture_id}
        if captured is not None:
            headers["X-SamRabbit-Captured-At"] = captured.isoformat(timespec="seconds")
        if source:
            headers["X-SamRabbit-Source"] = source
        if audio is not None:
            headers["Content-Type"] = "audio/wav"
        headers.update(extra or {})
        status, _headers, raw = self.request("POST", path + query, {"text": text} if audio is None else None,
                                             token=token, desktop=desktop, headers=headers, raw=audio)
        return status, json.loads(raw) if raw else {}

    def note(self, text: str, **kwargs: Any) -> Dict[str, Any]:
        """Submit a note from the R1 and run the worker's steps for it (no background worker here)."""
        status, value = self.submit(text, **kwargs)
        self.assertEqual(202, status, value)
        self.capture.process(value["captureId"])
        return self.capture.view(self.capture.store.get(value["captureId"]))

    def journal(self) -> Dict[str, List[str]]:
        path = self.hepta_dir / "journal.json"
        return json.loads(path.read_text()) if path.exists() else {}

    def timeline(self, day: str = "20261008") -> List[Dict[str, Any]]:
        store = self.server.sync.store
        return [json.loads(payload) for _cursor, payload in store.events_after(0, 200, "notes-" + day)]

    def composio_state(self) -> Dict[str, Any]:
        return json.loads((self.composio_dir / "state.json").read_text())

    def created_events(self) -> List[Dict[str, Any]]:
        return [call for call in self.composio_calls() if call["slug"] == "GOOGLECALENDAR_CREATE_EVENT"]

    def assert_clean(self, *words: str) -> None:
        text = self.log.getvalue() + self.capture_log.getvalue()
        for word in words:
            self.assertNotIn(word, text)


# ====================================================================== accepting a note


class SubmitTest(CaptureBase):
    def test_a_note_is_on_disk_before_the_quick_202(self) -> None:
        capture_id = str(uuid.uuid4())
        started = time.monotonic()
        status, value = self.submit("Buy milk and " + SECRET_WORDS, capture_id=capture_id.upper())
        took = time.monotonic() - started
        self.assertEqual(202, status, value)
        self.assertLess(took, 1.0, "the client says Sent at once")
        self.assertEqual({"captureId": capture_id, "state": "received", "source": "r1", "kind": "text",
                          "capturedAt": "2026-10-08T14:36:45-04:00", "say": "Sent."},
                         {key: value[key] for key in ("captureId", "state", "source", "kind", "capturedAt", "say")})
        record = self.folder / (capture_id + ".json")
        self.assertTrue(record.exists())
        self.assertEqual(0o600, stat.S_IMODE(record.stat().st_mode))
        self.assertEqual(0o700, stat.S_IMODE(self.folder.stat().st_mode))
        self.assertEqual("Buy milk and " + SECRET_WORDS, json.loads(record.read_text())["text"])
        self.assertIn("POST /v1/capture 202", self.log.getvalue())
        self.assert_clean(SECRET_WORDS, "Buy milk", capture_id)

    def test_the_same_id_is_the_same_note_and_other_words_conflict(self) -> None:
        capture_id = str(uuid.uuid4())
        first = self.submit("Call the plumber", capture_id=capture_id)
        again = self.submit("Call the plumber", capture_id=capture_id)
        self.assertEqual((202, 202), (first[0], again[0]))
        self.assertEqual(first[1]["receivedAt"], again[1]["receivedAt"], "a retry after a lost answer is the same note")
        status, value = self.submit("Call the electrician", capture_id=capture_id)
        self.assertEqual((409, "capture_conflict"), (status, value["error"]["code"]))
        self.capture.process(capture_id)
        status, value = self.submit("Call the plumber", capture_id=capture_id)
        self.assertEqual((200, "done"), (status, value["state"]), "once it is done a retry gets the outcome")
        self.assertEqual(1, len([name for name in os.listdir(self.folder) if name.endswith(".json")]))

    def test_headers_and_bodies_are_checked_before_anything_is_kept(self) -> None:
        cases = [({"capture_id": "not-a-uuid"}, 400, "invalid_capture_id"),
                 ({"captured": None, "extra": {"X-SamRabbit-Captured-At": "yesterday"}}, 400, "invalid_captured_at"),
                 ({"captured": None, "extra": {"X-SamRabbit-Captured-At": "2026-10-08T14:00:00"}}, 400,
                  "invalid_captured_at"),
                 ({"captured": CAPTURED - timedelta(days=9)}, 400, "invalid_captured_at"),
                 ({"source": "toaster"}, 400, "invalid_source")]
        for kwargs, code, error in cases:
            with self.subTest(kwargs=kwargs):
                status, value = self.submit("hello", **kwargs)
                self.assertEqual((code, error), (status, value["error"]["code"]))
        status, _headers, raw = self.request("POST", "/v1/capture", {"text": "hello"}, token=TOKEN)
        self.assertEqual((400, "invalid_capture_id"), (status, json.loads(raw)["error"]["code"]), "the id is required")
        self.assertEqual(400, self.submit("   ")[0])
        self.assertEqual(413, self.submit("x" * (capture.MAX_TEXT_CHARS + 1))[0])
        status, value = self.submit(None, audio=b"not audio at all, just words")
        self.assertEqual((415, "unsupported_audio"), (status, value["error"]["code"]))
        status, value = self.submit(None, audio=wav(capture.MAX_SECONDS + 5), path="/v1/desktop/capture", token=None,
                                    desktop=True)
        self.assertEqual((413, "audio_too_long"), (status, value["error"]["code"]))
        self.assertEqual([], [name for name in os.listdir(self.folder) if not name.startswith(".")],
                         "nothing refused was kept")

    def test_each_prefix_has_its_own_auth(self) -> None:
        cases = [("/v1/capture", {"token": None}, 401), ("/v1/capture", {"token": self.phone}, 401),
                 ("/v1/capture", {"token": "wrong-" + "t" * 40}, 401),
                 ("/v1/mobile/capture", {"token": TOKEN}, 401), ("/v1/mobile/capture", {"token": None}, 401),
                 ("/v1/desktop/capture", {"token": TOKEN}, 401), ("/v1/desktop/capture", {"token": self.phone}, 401)]
        for path, kwargs, code in cases:
            with self.subTest(path=path, kwargs=list(kwargs.values())[0] and "token"):
                self.assertEqual(code, self.submit("hello", path=path, **kwargs)[0])
        status, value = self.submit("from the phone", path="/v1/mobile/capture", token=self.phone)
        self.assertEqual((202, "iphone"), (status, value["source"]))
        status, value = self.submit("from the Mac", path="/v1/desktop/capture", token=None, desktop=True)
        self.assertEqual((202, "mac"), (status, value["source"]))
        status, value = self.submit("from the watch", path="/v1/mobile/capture", token=self.phone, source="watch")
        self.assertEqual((202, "watch"), (status, value["source"]))
        # From another machine on the LAN the desktop route is refused even with the desktop token, and the R1's route
        # from outside the private networks.
        body = json.dumps({"text": "x"}).encode()
        handler = FakeHandler("192.168.1.20", "/v1/desktop/capture", {"X-SamRabbit-Desktop": DESKTOP,
                                                                      "Content-Type": "application/json",
                                                                      "X-SamRabbit-Capture": str(uuid.uuid4())}, body)
        self.capture.serve(handler, "POST", "/v1/desktop/capture")
        self.assertEqual(403, handler.status)
        handler = FakeHandler("8.8.8.8", "/v1/capture", {"Authorization": "Bearer " + TOKEN,
                                                         "Content-Type": "application/json"}, body)
        self.capture.serve(handler, "POST", "/v1/capture")
        self.assertEqual(403, handler.status)
        self.assertEqual((405, 404), (self.call("GET", "/v1/capture", token=TOKEN)[0],
                                      self.call("GET", "/v1/capture/" + str(uuid.uuid4()), token=TOKEN)[0]))

    def test_audio_size_limits_per_surface(self) -> None:
        big = wav(290)  # about 9.3 MB: over the phone's 8 MiB, under the Mac's 16 MiB
        self.assertGreater(len(big), capture.MAX_AUDIO_BYTES["mobile"])
        for path, auth in (("/v1/mobile/capture", {"Authorization": "Bearer " + self.phone}),
                           ("/v1/capture", {"Authorization": "Bearer " + TOKEN})):
            with self.subTest(path=path):
                # Refused from the declared length, before the body is read.
                handler = FakeHandler("127.0.0.1", path, dict(auth, **{
                    "Content-Type": "audio/wav", "Content-Length": str(len(big)),
                    "X-SamRabbit-Capture": str(uuid.uuid4())}), b"RIFF")
                self.capture.serve(handler, "POST", path)
                self.assertEqual((413, "body_too_large"), (handler.status, handler.json()["error"]["code"]))
        status, value = self.submit(None, audio=big, path="/v1/desktop/capture", token=None, desktop=True)
        self.assertEqual((202, "audio"), (status, value["kind"]))
        record = self.capture.store.get(value["captureId"])
        audio = self.folder / (value["captureId"] + ".audio.wav")
        self.assertEqual((0o600, len(big)), (stat.S_IMODE(audio.stat().st_mode), audio.stat().st_size))
        self.assertEqual(290.0, record["seconds"])


# ====================================================================== where a note goes


class RouteTest(CaptureBase):
    def test_put_this_in_my_journal_writes_the_words_after_the_cue_at_the_capture_time(self) -> None:
        view = self.note("Put this in my journal: I finished the deck with Dana and " + SECRET_WORDS + ".")
        self.assertEqual(("done", "journal", "Added to your journal.", "2026-10-08"),
                         (view["state"], view["outcome"]["kind"], view["say"], view["outcome"]["journalDate"]))
        self.assertEqual({"2026-10-08": ["**14:36** I finished the deck with Dana and the private 6142 plan."]},
                         self.journal(), "his words, verbatim, at the time he spoke (not when the Mac got it)")
        self.assertEqual([], self.router_calls(), "an explicit cue needs no model")
        events = self.timeline()
        self.assertEqual(["message.user", "host.note"], [event["type"] for event in events])
        self.assertEqual("[Voice note] Added to your journal.", events[1]["text"])
        self.assertEqual("r1", events[0]["origin"])
        [conversation] = [item for item in self.server.sync.store.conversations(limit=10, before=None, query="")
                          if item["conversationId"] == "notes-20261008"]
        self.assertEqual(("Voice notes", False), (conversation["title"], conversation["live"]))
        self.assert_clean(SECRET_WORDS, "finished the deck")

    def test_a_trailing_journal_cue_and_the_tag_form(self) -> None:
        self.note("Talked to Dana about pricing. Put it in the journal.")
        self.note("Journal: slept badly, long run at noon", captured=CAPTURED + timedelta(seconds=30))
        self.assertEqual(["**14:36** Talked to Dana about pricing", "**14:37** slept badly, long run at noon"],
                         self.journal()["2026-10-08"])

    def test_the_journal_is_never_written_without_his_explicit_cue(self) -> None:
        self.answers([{"mode": "ok", "output": {"kind": "journal", "confidence": 0.99, "title": "Log the run",
                                                 "suggestion": "journal"}}])
        view = self.note("Long run this morning, felt great")
        self.assertEqual(("note", "journal"), (view["outcome"]["kind"], view["suggestion"]["action"]))
        self.assertEqual({}, self.journal(), "the classifier can only suggest the journal")
        self.assertEqual("Add it to your journal?", view["suggestion"]["label"])
        self.answers([{"mode": "ok", "output": {"kind": "journal", "confidence": 1, "title": "x", "suggestion": "none"}}])
        view = self.note("put this in my journal")
        self.assertEqual(("note", "journal"), (view["outcome"]["kind"], view["suggestion"]["action"]),
                         "a cue with nothing after it writes nothing")
        self.assertEqual({}, self.journal())

    def test_a_negated_or_asked_journal_cue_never_writes_the_journal(self) -> None:
        # The classifier is asked for the rest; it says "journal" each time and is held to the rules.
        self.answers([{"mode": "ok", "output": {"kind": "journal", "confidence": 0.99, "title": "Keep it",
                                                 "suggestion": "journal"}}])
        refused = ["Don't put this in my journal", "Buy milk on the way home, but don't put this in the journal.",
                   "I'm not sure I want to add this to my journal",
                   "I was going to say we should never put that in the journal",
                   "Please do not put that in the journal.",
                   "Put this in my journal: the offsite. Actually no, don't put it in the journal."]
        for heard in refused:
            with self.subTest(heard=heard):
                view = self.note(heard)
                self.assertEqual(("done", "note", None), (view["state"], view["outcome"]["kind"], view["suggestion"]),
                                 "he said not to: no journal, not even the offer")
        asked = ["Why did you put it in the journal", "He told me to put it in the journal",
                 "Did you put that in my journal?", "Why would you put it in the journal",
                 "I ran 5k this morning. Put it in my journal?"]
        for heard in asked:
            with self.subTest(heard=heard):
                view = self.note(heard)
                self.assertEqual(("note", "journal"), (view["outcome"]["kind"], view["suggestion"]["action"]),
                                 "maybe a request, maybe not: kept, the journal offered for his tap")
        self.assertEqual({}, self.journal(), "nothing reached the journal")
        written = {"I ran 5k this morning. Can you put that in my journal?": "I ran 5k this morning",
                   "Talked to Dana about pricing, and please put it in the journal.": "Talked to Dana about pricing",
                   "Talked to Ana please put it in the journal": "Talked to Ana",
                   "No meetings on Friday. Put it in the journal": "No meetings on Friday"}
        for heard, words in written.items():
            with self.subTest(heard=heard):
                view = self.note(heard)
                self.assertEqual("journal", view["outcome"]["kind"])
        self.assertEqual(["**14:36** " + words for words in written.values()], self.journal()["2026-10-08"],
                         "his own request after a pause (or with please / can you): his words, verbatim")
        self.assert_clean("milk", "Dana", "5k")

    def test_a_message_to_someone_is_never_started_by_the_classifier(self) -> None:
        self.answers([{"mode": "ok", "output": {"kind": "task", "confidence": 0.97, "title": "Tell Dana the SOW slips",
                                                 "suggestion": "task"}}])
        before = len(self.fake_t3.dispatched)
        view = self.note("I need to tell Dana the SOW slips to Monday")
        self.assertEqual(("note", "task"), (view["outcome"]["kind"], view["suggestion"]["action"]))
        self.assertEqual(before, len(self.fake_t3.dispatched), "no agent was started")
        # His tap starts it, and the agent asks him before it acts (it could send the email).
        status, value = self.call("POST", f"/v1/captures/{view['captureId']}/act", {"action": "task"}, token=TOKEN)
        self.assertEqual((200, "task", "approval-required"),
                         (status, value["outcome"]["kind"], value["outcome"]["runtimeMode"]))
        create, turn = self.fake_t3.dispatched[-2:]
        self.assertEqual(("approval-required", "approval-required"), (create["runtimeMode"], turn["runtimeMode"]))
        self.assertEqual("I need to tell Dana the SOW slips to Monday", turn["message"]["text"])
        self.assertIn("it asks you before it acts", value["say"])
        # A task the classifier starts (no message to anyone) also asks first; an explicit cue is the phone's new task.
        self.answers([{"mode": "ok", "output": {"kind": "task", "confidence": 0.92, "title": "Look into the sync",
                                                 "suggestion": "none"}}])
        self.note("the sync service drops events after a restart, look into it")
        self.assertEqual("approval-required", self.fake_t3.dispatched[-2]["runtimeMode"])
        self.note("Make a new task to rename the widgets module")
        self.assertEqual("full-access", self.fake_t3.dispatched[-2]["runtimeMode"], "inherited, as from the phone")
        self.note("Make a new task to email Dana the release notes")
        self.assertEqual("approval-required", self.fake_t3.dispatched[-2]["runtimeMode"],
                         "an explicit task that writes to someone asks first")
        self.assertIn("never a task", capture.ROUTER_PROMPT)
        self.assertNotIn("an email to write is a task", capture.ROUTER_PROMPT)

    def test_a_task_whose_first_message_failed_is_finished_not_reported_started(self) -> None:
        hub = self.server.mobile.t3
        real = hub._dispatch  # noqa: SLF001

        def first_message_fails(command: Dict[str, Any]) -> None:
            if command.get("type") == "thread.turn.start":
                raise t3.T3Error(503, "t3_unavailable", "T3 Code is busy.", retryable=True)
            real(command)

        hub._dispatch = first_message_fails  # noqa: SLF001
        status, value = self.submit("Make a new task to fix the flaky sync test")
        capture_id = value["captureId"]
        self.capture.process(capture_id)
        record = self.capture.store.get(capture_id)
        thread_id = record["steps"]["task"]["threadId"]
        self.assertEqual(("transcribed", "creating"), (record["state"], record["steps"]["task"]["state"]),
                         "the thread is there, its first message is not: not done")
        self.assertEqual(["thread.create"], [command["type"] for command in self.fake_t3.dispatched
                                             if command.get("threadId") == thread_id])
        hub._dispatch = real  # noqa: SLF001
        self.capture.process(capture_id)
        view = self.capture.view(self.capture.store.get(capture_id))
        self.assertEqual(("done", "task", thread_id), (view["state"], view["outcome"]["kind"],
                                                       view["outcome"]["threadId"]))
        mine = [command for command in self.fake_t3.dispatched if command.get("threadId") == thread_id]
        self.assertEqual(["thread.create", "thread.turn.start"], [command["type"] for command in mine],
                         "the same thread, its first message sent once")
        self.assertEqual("Make a new task to fix the flaky sync test", mine[-1]["message"]["text"])
        self.capture.process(capture_id)
        self.assertEqual(2, len([command for command in self.fake_t3.dispatched
                                 if command.get("threadId") == thread_id]), "done: nothing more")

    def test_make_a_new_task_starts_t3_with_the_verbatim_transcript(self) -> None:
        heard = "Make a new task to fix the failing unit tests in the sync module"
        view = self.note(heard)
        self.assertEqual(("done", "task"), (view["state"], view["outcome"]["kind"]))
        create, turn = self.fake_t3.dispatched[-2:]
        self.assertEqual(("thread.create", "thread.turn.start"), (create["type"], turn["type"]))
        self.assertEqual(heard, turn["message"]["text"], "the prompt is what he said, word for word")
        self.assertEqual("Fix the failing unit tests in the sync module", create["title"])
        record = self.capture.store.get(view["captureId"])
        self.assertEqual(create["threadId"], record["steps"]["task"]["threadId"], "the id was saved before dispatch")
        self.assertEqual(create["threadId"], view["outcome"]["threadId"])
        self.assertEqual("p-rabbit", create["projectId"], "placed as a phone's new task (a coding task)")
        self.assertEqual("Started “Fix the failing unit tests in the sync module” in SamRabbit.", view["say"])

    def test_a_task_that_reached_t3_before_a_crash_is_not_made_twice(self) -> None:
        status, value = self.submit("Make a task to update the README")
        record = self.capture.store.get(value["captureId"])
        thread_id = str(uuid.uuid4())
        self.capture.process(value["captureId"])  # done once, normally
        count = len(self.fake_t3.dispatched)
        # A second note as if the bridge stopped right after dispatching: the thread exists, the step says "creating".
        status, value = self.submit("Make a task to update the changelog")
        record = self.capture.store.get(value["captureId"])
        hub = self.server.mobile.t3
        hub.create(record["text"], thread_id=thread_id)
        record.update(state="transcribed", heard=record["text"],
                      plan={"kind": "task", "by": "rule", "confidence": 1.0, "title": "Update the changelog"},
                      steps={"task": {"state": "creating", "threadId": thread_id}})
        self.capture.store.save(record)
        dispatched = len(self.fake_t3.dispatched)
        self.capture.process(value["captureId"])
        self.assertEqual(dispatched, len(self.fake_t3.dispatched), "it looked for the thread instead")
        self.assertEqual(("task", thread_id), (self.capture.view(self.capture.store.get(value["captureId"]))[
            "outcome"]["kind"], self.capture.store.get(value["captureId"])["outcome"]["threadId"]))
        self.assertGreater(dispatched, count)

    def test_a_journal_line_written_before_a_crash_is_not_written_twice(self) -> None:
        status, value = self.submit("Journal: the quiet morning")
        record = self.capture.store.get(value["captureId"])
        line = "**14:36** the quiet morning"
        self.server.append("2026-10-08", line)  # it got there, then the bridge stopped
        record.update(state="transcribed", heard=record["text"],
                      plan={"kind": "journal", "by": "rule", "confidence": 1.0, "title": "x",
                            "text": "the quiet morning"},
                      steps={"journal": {"state": "writing", "date": "2026-10-08", "line": line}})
        self.capture.store.save(record)
        self.capture.process(value["captureId"])
        self.assertEqual([line], self.journal()["2026-10-08"], "read before writing again")
        self.assertEqual("journal", self.capture.store.get(value["captureId"])["outcome"]["kind"])

    def test_remind_me_at_a_time_adds_a_calendar_event_with_the_capture_id(self) -> None:
        view = self.note("Remind me to call mom at 3 pm")
        self.assertEqual(("done", "event"), (view["state"], view["outcome"]["kind"]))
        [call] = self.created_events()
        self.assertEqual(("Reminder: Call mom", "2026-10-08T15:00:00-04:00", "2026-10-08T15:15:00-04:00"),
                         (call["args"]["summary"], call["args"]["start_datetime"], call["args"]["end_datetime"]))
        self.assertIn("SamRabbit voice note " + view["captureId"], call["args"]["description"])
        self.assertEqual("none", call["args"]["send_updates"])
        self.assertEqual("googlecalendar_awest-hug", call["account"])
        self.assertEqual("Added “Reminder: Call mom” for 3:00 PM.", view["say"])
        self.assertIsNotNone(view["outcome"]["eventId"])

    def test_block_minutes_starts_now(self) -> None:
        view = self.note("Block 45 minutes for deep work", captured=datetime.fromtimestamp(NOW, ZONE))
        [call] = self.created_events()
        self.assertEqual(("Deep work", "2026-10-08T14:37:00-04:00", "2026-10-08T15:22:00-04:00"),
                         (call["args"]["summary"], call["args"]["start_datetime"], call["args"]["end_datetime"]))
        self.assertEqual("event", view["outcome"]["kind"])

    def test_the_classifier_decides_and_the_bridge_holds_it_to_the_rules(self) -> None:
        self.answers([
            {"mode": "ok", "output": {"kind": "task", "confidence": 0.92, "title": "Draft the Q4 investor update",
                                      "suggestion": "none"}},
            {"mode": "ok", "output": {"kind": "event", "confidence": 0.6, "title": "Lunch with Priya",
                                      "start": "2026-10-09T12:30:00-04:00", "end": "2026-10-09T13:30:00-04:00",
                                      "suggestion": "event"}},
            {"mode": "ok", "output": {"kind": "event", "confidence": 0.95, "title": "Dentist",
                                      "start": "2026-10-07T09:00:00-04:00", "suggestion": "none"}},
            {"mode": "ok", "output": {"kind": "event", "confidence": 0.9, "title": "Lunch with Sam",
                                      "start": "2026-10-09T12:00:00-04:00", "suggestion": "none"}},
            {"mode": "ok", "output": {"kind": "task", "confidence": 0.4, "title": "Think about pricing",
                                      "suggestion": "task"}},
        ])
        task = self.note("I need to get the Q4 investor update drafted for Friday")
        self.assertEqual("task", task["outcome"]["kind"])
        self.assertEqual("I need to get the Q4 investor update drafted for Friday",
                         self.fake_t3.dispatched[-1]["message"]["text"])
        low = self.note("lunch with Priya tomorrow around 12:30 probably")
        self.assertEqual(("note", "event", "2026-10-09T12:30:00-04:00"),
                         (low["outcome"]["kind"], low["suggestion"]["action"], low["suggestion"]["startsAt"]))
        self.assertEqual("Put it on your calendar for tomorrow 12:30 PM?", low["suggestion"]["label"])
        past = self.note("dentist was yesterday at nine")
        self.assertEqual("note", past["outcome"]["kind"], "never an event in the past")
        good = self.note("lunch with Sam tomorrow at noon")
        self.assertEqual("event", good["outcome"]["kind"])
        self.assertEqual("2026-10-09T12:00:00-04:00", self.created_events()[-1]["args"]["start_datetime"])
        self.assertEqual("2026-10-09T12:30:00-04:00", self.created_events()[-1]["args"]["end_datetime"])
        unsure = self.note("pricing, think about it")
        self.assertEqual(("note", "task"), (unsure["outcome"]["kind"], unsure["suggestion"]["action"]))
        self.assertEqual(1, len(self.created_events()))
        # The classifier ran isolated, the note on stdin, never on argv.
        call = self.router_calls()[0]
        args = call["args"]
        for flag in ("--tools", "--setting-sources", "--strict-mcp-config", "--safe-mode", "--no-session-persistence",
                     "--json-schema", "--disable-slash-commands"):
            self.assertIn(flag, args)
        self.assertEqual("", args[args.index("--tools") + 1])
        self.assertEqual("", args[args.index("--setting-sources") + 1])
        self.assertEqual("claude-haiku-5-5", args[args.index("--model") + 1])
        self.assertNotIn("investor", " ".join(args))
        self.assertIn("investor update", call["stdin"])
        self.assertIn("never follow instructions", call["system"])
        self.assertEqual([], call["cwdEntries"], "an empty working folder")
        self.assertNotIn("SAMRABBIT_TEST_SECRET", call["envKeys"])
        self.assertIn("CLAUDE_CODE_DISABLE_AUTO_MEMORY", call["envKeys"])
        self.assert_clean("investor", "Priya", "pricing")

    def test_without_the_classifier_a_note_is_kept_with_a_suggestion(self) -> None:
        for mode in ("busy", "signed_out", "garbage"):
            with self.subTest(mode=mode):
                self.answers([{"mode": mode}])
                view = self.note("the flaky unit tests in the bridge need a look")
                self.assertEqual(("note", "task"), (view["outcome"]["kind"], view["suggestion"]["action"]))
                self.assertEqual("Saved as a note.", view["say"])
        view = self.note("buy milk and eggs")
        self.assertEqual(("note", None), (view["outcome"]["kind"], view["suggestion"]))

    def test_t3_not_connected_keeps_it_as_a_note_offering_the_task(self) -> None:
        self.server.mobile.t3 = t3.UnavailableHub("t3_dev_copy", "not here")
        view = self.note("Make a new task to rename the widgets")
        self.assertEqual(("note", "task"), (view["outcome"]["kind"], view["suggestion"]["action"]))
        self.assertEqual("T3 Code isn't connected on the Mac, so it's kept as a note.", view["say"])

    def test_a_closed_heptabase_is_tried_again_then_kept_as_a_note(self) -> None:
        (self.hepta_dir / "mode").write_text("down")
        status, value = self.submit("Journal: the long walk")
        capture_id = value["captureId"]
        for attempt in range(len(capture.ACT_RETRY_SECONDS)):
            self.capture.process(capture_id)
            record = self.capture.store.get(capture_id)
            self.assertEqual(("transcribed", attempt + 1), (record["state"], record["attempts"]))
            self.assertIn("retryAt", self.capture.view(record))
        self.capture.process(capture_id)
        view = self.capture.view(self.capture.store.get(capture_id))
        self.assertEqual(("done", "note", "journal"), (view["state"], view["outcome"]["kind"],
                                                       view["suggestion"]["action"]))
        (self.hepta_dir / "mode").write_text("ok")
        status, value = self.call("POST", f"/v1/captures/{capture_id}/act", {"action": "journal"}, token=TOKEN)
        self.assertEqual((200, "journal"), (status, value["outcome"]["kind"]))
        self.assertEqual(["**14:36** the long walk"], self.journal()["2026-10-08"])


# ====================================================================== audio


class AudioTest(CaptureBase):
    def test_a_recording_is_heard_then_routed_and_its_audio_deleted(self) -> None:
        (self.voice_dir / "text").write_text("Put it in my journal. Coffee with Ana went long.")
        status, value = self.submit(None, audio=wav(42), path="/v1/mobile/capture", token=self.phone,
                                    source="watch")
        capture_id = value["captureId"]
        audio = self.folder / (capture_id + ".audio.wav")
        self.assertTrue(audio.exists())
        self.capture.process(capture_id)
        view = self.capture.view(self.capture.store.get(capture_id))
        self.assertEqual(("done", "journal", "Put it in my journal. Coffee with Ana went long."),
                         (view["state"], view["outcome"]["kind"], view["heard"]))
        self.assertEqual(["**14:36** Coffee with Ana went long."], self.journal()["2026-10-08"])
        self.assertFalse(audio.exists(), "the audio is gone once the words are in")
        [call] = [entry for entry in map(json.loads, (self.voice_dir / "calls.jsonl").read_text().splitlines())
                  if "--file" in entry["args"]]
        args = call["args"]
        self.assertEqual("300", args[args.index("--max-seconds") + 1], "the voice note's own limit")
        self.assertGreater(float(args[args.index("--deadline") + 1]), 40.0, "its timeout scales with the length")
        self.assertEqual("watch", self.timeline()[0]["origin"])
        self.assert_clean("Coffee with Ana")

    def test_no_speech_is_done_with_nothing(self) -> None:
        (self.voice_dir / "mode").write_text("no_speech")
        status, value = self.submit(None, audio=wav(3))
        self.capture.process(value["captureId"])
        view = self.capture.view(self.capture.store.get(value["captureId"]))
        self.assertEqual(("done", "nothing", "I didn't catch anything."),
                         (view["state"], view["outcome"]["kind"], view["say"]))
        self.assertEqual([], [name for name in os.listdir(self.folder) if ".audio" in name])

    def test_speech_recognition_down_waits_with_the_audio_kept(self) -> None:
        (self.voice_dir / "mode").write_text("unavailable")
        status, value = self.submit(None, audio=wav(5))
        self.capture.process(value["captureId"])
        record = self.capture.store.get(value["captureId"])
        self.assertEqual(("received", 1, "transcribe_unavailable"),
                         (record["state"], record["attempts"], record["error"]["code"]))
        self.assertTrue((self.folder / (value["captureId"] + ".audio.wav")).exists())
        (self.voice_dir / "mode").write_text("ok")
        self.capture.process(value["captureId"])
        self.assertEqual("done", self.capture.store.get(value["captureId"])["state"])

    def test_unreadable_audio_fails_and_can_be_retried(self) -> None:
        (self.voice_dir / "mode").write_text("audio")
        status, value = self.submit(None, audio=wav(5))
        self.capture.process(value["captureId"])
        view = self.capture.view(self.capture.store.get(value["captureId"]))
        self.assertEqual(("failed", "unsupported_audio"), (view["state"], view["error"]["code"]))
        items = self.capture.inbox_items()
        self.assertEqual(["error"], [item["status"] for item in items])
        (self.voice_dir / "mode").write_text("ok")
        status, value = self.call("POST", f"/v1/captures/{view['captureId']}/act", {"action": "retry"}, token=TOKEN)
        self.assertEqual((202, "received"), (status, value["state"]))
        self.capture.process(view["captureId"])
        self.assertEqual("done", self.capture.store.get(view["captureId"])["state"])


# ====================================================================== taps, the inbox, the summary, the worker


class ActTest(CaptureBase):
    def test_redo_as_a_task_or_the_journal_and_undo_an_event(self) -> None:
        view = self.note("Remind me to send the invoice at 4 pm")
        capture_id = view["captureId"]
        status, value = self.call("POST", f"/v1/mobile/captures/{capture_id}/act", {"action": "task"}, token=self.phone)
        self.assertEqual((200, "task", "event"), (status, value["outcome"]["kind"], value["outcome"]["undone"]))
        self.assertEqual("GOOGLECALENDAR_DELETE_EVENT", self.composio_calls()[-1]["slug"],
                         "the event it made is removed first")
        self.assertEqual("Remind me to send the invoice at 4 pm", self.fake_t3.dispatched[-1]["message"]["text"])
        dispatched = len(self.fake_t3.dispatched)
        again = self.call("POST", f"/v1/mobile/captures/{capture_id}/act", {"action": "task"}, token=self.phone)
        self.assertEqual(200, again[0])
        self.assertEqual(dispatched, len(self.fake_t3.dispatched), "a second tap starts nothing new")
        status, value = self.call("POST", f"/v1/captures/{capture_id}/act", {"action": "undo"}, token=TOKEN)
        self.assertEqual((409, "cannot_undo"), (status, value["error"]["code"]))
        status, value = self.call("POST", f"/v1/captures/{capture_id}/act", {"action": "journal"}, token=TOKEN)
        self.assertEqual((200, "journal"), (status, value["outcome"]["kind"]))
        self.assertEqual(["**14:36** Remind me to send the invoice at 4 pm"], self.journal()["2026-10-08"],
                         "on his tap the journal gets everything he said, verbatim")
        status, value = self.call("POST", f"/v1/captures/{capture_id}/act", {"action": "teleport"}, token=TOKEN)
        self.assertEqual((400, "invalid_action"), (status, value["error"]["code"]))

    def test_redo_keeps_the_event_until_the_new_action_worked(self) -> None:
        view = self.note("Remind me to send the invoice at 4 pm")
        capture_id = view["captureId"]
        event_id = view["outcome"]["eventId"]
        hub = self.server.mobile.t3
        self.server.mobile.t3 = t3.UnavailableHub("t3_dev_copy", "not here")
        status, value = self.call("POST", f"/v1/captures/{capture_id}/act", {"action": "task"}, token=TOKEN)
        self.assertEqual((409, "t3_dev_copy"), (status, value["error"]["code"]))
        (self.hepta_dir / "mode").write_text("down")
        status, value = self.call("POST", f"/v1/captures/{capture_id}/act", {"action": "journal"}, token=TOKEN)
        self.assertEqual(503, status, value)
        self.assertNotIn("GOOGLECALENDAR_DELETE_EVENT", [call["slug"] for call in self.composio_calls()],
                         "neither worked: the reminder is still on his calendar")
        record = self.capture.store.get(capture_id)
        self.assertEqual(("event", event_id, "done"), (record["outcome"]["kind"], record["outcome"]["eventId"],
                                                       record["steps"]["event"]["state"]))
        (self.hepta_dir / "mode").write_text("ok")
        self.server.mobile.t3 = hub
        status, value = self.call("POST", f"/v1/captures/{capture_id}/act", {"action": "task"}, token=TOKEN)
        self.assertEqual((200, "task", "event"), (status, value["outcome"]["kind"], value["outcome"]["undone"]))
        self.assertEqual("GOOGLECALENDAR_DELETE_EVENT", self.composio_calls()[-1]["slug"], "removed once it worked")
        self.assertEqual("removed", self.capture.store.get(capture_id)["steps"]["event"]["state"])
        # The new action worked but the event can't be removed: done, and it says the event is still there.
        view = self.note("Remind me to call the bank at 5 pm")
        state = self.composio_state()
        state["scripted"] = {"GOOGLECALENDAR_DELETE_EVENT": {"stdout": json.dumps(
            {"successful": False, "error": "Backend Error", "data": {"status_code": 500}})}}
        self.write_calendar(state)
        status, value = self.call("POST", f"/v1/captures/{view['captureId']}/act", {"action": "journal"},
                                  token=TOKEN)
        self.assertEqual((200, "journal", view["outcome"]["eventId"]),
                         (status, value["outcome"]["kind"], value["outcome"]["eventKept"]))
        self.assertTrue(value["say"].endswith("The calendar event is still there."))
        self.assertEqual(["**14:36** Remind me to call the bank at 5 pm"], self.journal()["2026-10-08"])

    def test_undo_an_event_keeps_the_note_and_offers_it_again(self) -> None:
        view = self.note("Remind me to stretch in 20 minutes")
        status, value = self.call("POST", f"/v1/captures/{view['captureId']}/act", {"action": "undo"}, token=TOKEN)
        self.assertEqual((200, "note", "event"), (status, value["outcome"]["kind"], value["suggestion"]["action"]))
        self.assertEqual("Removed from your calendar; kept as a note.", value["say"])
        status, value = self.call("POST", f"/v1/captures/{view['captureId']}/act", {"action": "event"}, token=TOKEN)
        self.assertEqual((200, "event"), (status, value["outcome"]["kind"]))
        self.assertEqual(2, len(self.created_events()))

    def test_notes_are_inbox_items_that_act_dismiss_and_get_seen(self) -> None:
        self.answers([{"mode": "busy"}])
        view = self.note("the sync store migration needs a test")
        item_id = "note:" + view["captureId"]
        status, value = self.call("GET", "/v1/desktop/inbox", desktop=True)
        [item] = [entry for entry in value["items"] if entry["id"] == item_id]
        self.assertEqual(("note", "needs-input", ["act", "dismiss", "seen"], "Start it as a T3 task?"),
                         (item["source"], item["status"], item["can"], item["statusLabel"]))
        self.assertEqual("the sync store migration needs a test", item["summary"])
        self.assertGreaterEqual(value["counts"]["needsYou"], 1)
        status, phone = self.call("GET", "/v1/mobile/inbox", token=self.phone)
        self.assertIn(item_id, [entry["id"] for entry in phone["items"]])
        status, detail = self.call("GET", f"/v1/desktop/inbox/items/{item_id}", desktop=True)
        self.assertEqual("the sync store migration needs a test", detail["messages"][0]["text"])
        status, value = self.call("POST", f"/v1/mobile/inbox/items/{item_id}/act", {}, token=self.phone)
        self.assertEqual((200, "task"), (status, value["capture"]["outcome"]["kind"]))
        self.assertEqual("the sync store migration needs a test", self.fake_t3.dispatched[-1]["message"]["text"])
        status, value = self.call("GET", "/v1/desktop/inbox", desktop=True)
        self.assertNotIn(item_id, [entry["id"] for entry in value["items"]], "done: it left the inbox")
        other = self.note("call the landlord")
        other_id = "note:" + other["captureId"]
        self.assertEqual(200, self.call("POST", f"/v1/desktop/inbox/items/{other_id}/seen", {}, desktop=True)[0])
        status, value = self.call("GET", "/v1/desktop/inbox", desktop=True)
        self.assertEqual("idle", next(entry for entry in value["items"] if entry["id"] == other_id)["status"])
        self.assertEqual(200, self.call("POST", f"/v1/desktop/inbox/items/{other_id}/dismiss", {}, desktop=True)[0])
        status, value = self.call("GET", "/v1/desktop/inbox", desktop=True)
        self.assertNotIn(other_id, [entry["id"] for entry in value["items"]])
        status, value = self.call("POST", f"/v1/desktop/inbox/items/{other_id}/approve", {"decision": "accept"},
                                  desktop=True)
        self.assertEqual(409, status, "a note is never approved")

    def test_the_summary_lists_recent_notes_and_failures(self) -> None:
        self.note("Journal: a good start")
        (self.voice_dir / "mode").write_text("audio")
        status, value = self.submit(None, audio=wav(2), capture_id=str(uuid.uuid4()))
        self.capture.process(value["captureId"])
        status, pending = self.submit("Make a task to tidy the docs")
        status, summary = self.call("GET", "/v1/mobile/summary", token=self.phone)
        part = summary["captures"]
        self.assertEqual((True, 1, 1, 0), (part["available"], part["failed"], part["pending"], part["notes"]))
        self.assertEqual(3, len(part["recent"]))
        self.assertEqual({"captureId", "state", "kind", "title", "say", "at"}, set(part["recent"][0]))
        status, desktop = self.call("GET", "/v1/desktop/summary", desktop=True)
        self.assertEqual(part["failed"], desktop["captures"]["failed"])
        status, value = self.call("GET", "/v1/desktop/captures?limit=2", desktop=True)
        self.assertEqual((200, 2, 1), (status, len(value["captures"]), value["pending"]))

    def test_a_failed_note_counts_the_same_everywhere_and_settles_once_seen(self) -> None:
        (self.voice_dir / "mode").write_text("audio")
        status, value = self.submit(None, audio=wav(2))
        self.capture.process(value["captureId"])
        item_id = "note:" + value["captureId"]

        def counts() -> Tuple[int, int, int, Optional[str], int]:
            summary = self.call("GET", "/v1/mobile/summary", token=self.phone)[1]["captures"]
            inbox_now = self.call("GET", "/v1/desktop/inbox", desktop=True)[1]
            item = next((entry for entry in inbox_now["items"] if entry["id"] == item_id), None)
            return (summary["failed"], self.capture.health()["failed"], inbox_now["counts"]["needsYou"],
                    item["status"] if item else None, len([entry for entry in inbox_now["items"]
                                                           if entry["source"] == "note"]))

        failed, health, needs, status, listed = counts()
        self.assertEqual((1, 1, "error", 1), (failed, health, status, listed))
        self.assertEqual(200, self.call("POST", f"/v1/desktop/inbox/items/{item_id}/seen", {}, desktop=True)[0])
        failed, health, needs_after, status, listed = counts()
        self.assertEqual((0, 0, "idle", 1, needs - 1), (failed, health, status, listed, needs_after),
                         "seen: it stays listed, idle, and no longer needs him (as a failed session)")
        # One that failed four days ago: out of the inbox, and so out of every count.
        (self.voice_dir / "mode").write_text("audio")
        status, value = self.submit(None, audio=wav(2))
        self.capture.process(value["captureId"])
        record = self.capture.store.get(value["captureId"])
        record["receivedEpoch"] -= 4 * 86400
        self.capture.store.save(record)
        self.server.inbox.refresh_soon()
        failed, health, _needs, _status, listed = counts()
        self.assertEqual((0, 0, 1), (failed, health, listed))
        # A retry that fails again needs him again.
        self.call("POST", f"/v1/captures/{item_id[5:]}/act", {"action": "retry"}, token=TOKEN)
        self.capture.process(item_id[5:])
        self.assertEqual((1, 1, "error"), counts()[:2] + (counts()[3],))

    def test_the_worker_answers_within_wait_and_finishes_what_a_stopped_bridge_left(self) -> None:
        self.clock.follow_real_time()
        # A note a stopped bridge accepted but never routed:
        status, value = self.submit("Journal: before the restart")
        left = value["captureId"]
        self.capture.start()
        status, value = self.call("GET", f"/v1/capture/{left}?wait=8", token=TOKEN)
        self.assertEqual(("done", "journal"), (value["state"], value["outcome"]["kind"]))
        started = time.monotonic()
        status, value = self.submit("Journal: with the worker", query="?wait=8", captured=CAPTURED)
        self.assertEqual((200, "done", "journal"), (status, value["state"], value["outcome"]["kind"]))
        self.assertLess(time.monotonic() - started, 8.0)
        self.assertEqual(["**14:36** before the restart", "**14:36** with the worker"], self.journal()["2026-10-08"])

    def test_a_new_service_picks_up_notes_left_half_done(self) -> None:
        status, value = self.submit("Journal: picked up later")
        self.capture.close()
        again = capture.CaptureService(str(self.folder), timezone_name="America/New_York", clock=self.clock.time,
                                       monotonic=self.clock.monotonic)
        again.attach(self.server)
        self.server.capture = again
        self.addCleanup(again.close)
        self.clock.follow_real_time()
        again.start()
        deadline = time.monotonic() + 10
        while again.store.get(value["captureId"])["state"] != "done" and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertEqual(["**14:36** picked up later"], self.journal()["2026-10-08"])


class ParseWhenTest(unittest.TestCase):
    NOW = datetime(2026, 10, 14, 9, 41, tzinfo=ZONE)  # a Wednesday

    def when(self, text: str) -> Optional[str]:
        found = capture.parse_when(text, self.NOW)
        return found[0].isoformat(timespec="minutes") if found else None

    def test_times_that_read_one_way_only(self) -> None:
        cases = {"at 3 pm": "2026-10-14T15:00-04:00", "at 3:30pm": "2026-10-14T15:30-04:00",
                 "at 15:45": "2026-10-14T15:45-04:00", "tomorrow at 9 am": "2026-10-15T09:00-04:00",
                 "on Friday at noon": "2026-10-16T12:00-04:00", "next wednesday at 8 a.m.": "2026-10-21T08:00-04:00",
                 "wednesday at 8 am": "2026-10-21T08:00-04:00", "in 20 minutes": "2026-10-14T10:01-04:00",
                 "in half an hour": "2026-10-14T10:11-04:00", "in an hour": "2026-10-14T10:41-04:00",
                 "at 3": None, "at 3:30": None, "sometime soon": None, "at 25 pm": None}
        for text, expected in cases.items():
            with self.subTest(text=text):
                self.assertEqual(expected, self.when(text))

    def test_router_rules(self) -> None:
        router = capture.CaptureRouter(None)

        def route(text: str) -> Dict[str, Any]:
            return router.route(text, captured=self.NOW, now=self.NOW, zone_name="America/New_York")

        self.assertEqual("Reminder: Call the bank", route("remind me on Friday to call the bank at 9 am")["title"])
        self.assertEqual(("journal", "today was good"), (route("Journal, today was good")["kind"],
                                                         route("Journal, today was good")["text"]))
        self.assertEqual("note", route("journal is a thing I should start")["kind"])
        self.assertEqual(("block", 120), (route("block off two hours to prep")["kind"],
                                          route("block off two hours to prep")["minutes"]))
        cases = {"Don't put this in my journal": ("refused", ""),
                 "Buy milk, but don't put it in the journal.": ("refused", ""),
                 "I'm not sure I want to add this to my journal": ("refused", ""),
                 "Why did you put it in the journal": ("ask", ""), "Did you put that in my journal?": ("ask", ""),
                 "He told me to put it in the journal": ("ask", ""),
                 "Coffee with Ana. Put it in my journal.": ("journal", "Coffee with Ana"),
                 "Coffee with Ana, put it in my journal please": ("journal", "Coffee with Ana"),
                 "Coffee with Ana. Could you put it in my journal?": ("journal", "Coffee with Ana"),
                 "journal is a thing I should start": None}
        for text, expected in cases.items():
            with self.subTest(text=text):
                self.assertEqual(expected, capture.journal_tail(text))
                if expected and expected[0] != "journal":
                    self.assertNotEqual("journal", route(text)["kind"])
        self.assertTrue(capture.in_order_slice("finished the deck", "I finished the deck today"))
        self.assertFalse(capture.in_order_slice("finished deck", "I finished the deck today"))


if __name__ == "__main__":
    unittest.main()
