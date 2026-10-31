"""Pure parts of ``samrabbit_t3`` (status, pending requests, placement, the CLI's output, the token file) and the
module's command line, plus a Python 3.9 / ``python3 -I`` import check of the new bridge modules.

Run: cd companion/mac-bridge && /usr/bin/python3 -m unittest discover -s tests -q
"""

from __future__ import annotations

import ast
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import threading
from typing import Dict, List
import unittest

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(HERE))

import samrabbit_t3 as t3  # noqa: E402
from fake_t3 import FakeT3  # noqa: E402


def record(project_id: str, title: str, root: str = "", **extra: object) -> dict:
    value = {"id": project_id, "title": title, "workspaceRoot": root, "repository": None, "scratch": False}
    value.update(extra)
    return value


def shell(**fields: object) -> dict:
    """A v2 thread shell (``OrchestrationV2ThreadShell``) with a completed run unless told otherwise."""
    value = {"id": "t", "projectId": "p", "title": "T", "status": "completed", "latestRunId": "run-1",
             "latestRunRequestedAt": "2026-10-08T10:00:00Z", "latestRunStartedAt": "2026-10-08T10:00:01Z",
             "latestRunCompletedAt": "2026-10-08T10:05:00Z", "activeRunId": None, "activityRunStatus": None,
             "activeProviderThreadId": "pt-1", "pendingRuntimeRequest": None, "pendingBackgroundTasks": [],
             "lineage": {"parentThreadId": None, "relationshipToParent": None, "rootThreadId": "t"},
             "settledOverride": None, "settledAt": None, "updatedAt": "2026-10-08T10:05:00Z",
             "createdAt": "2026-10-08T09:00:00Z", "latestUserMessageAt": "2026-10-08T10:00:00Z", "itemCount": 4}
    value.update(fields)
    return value


def running(**fields: object) -> dict:
    return shell(**{"status": "running", "activeRunId": "run-1", "activityRunStatus": "running",
                    "latestRunCompletedAt": None, **fields})


def asks(kind: str, **fields: object) -> dict:
    return {"id": "req-1", "kind": kind, "createdAt": "2026-10-08T10:02:00Z", **fields}


class StatusTest(unittest.TestCase):
    def test_mobile_status_names_from_v2_shells(self) -> None:
        never = shell(status="idle", latestRunId=None, latestRunRequestedAt=None, latestRunStartedAt=None,
                      latestRunCompletedAt=None, activeProviderThreadId=None, itemCount=0)
        cases = [(running(pendingRuntimeRequest=asks("command")), "needs_approval", "Needs approval"),
                 (shell(pendingRuntimeRequest=asks("file-change")), "needs_approval", "Needs approval"),
                 (shell(pendingRuntimeRequest=asks("user_input")), "needs_input", "Has a question"),
                 (running(pendingRuntimeRequest=asks("user_input", blocking=False)), "working", "Working"),
                 (shell(pendingRuntimeRequest=asks("user_input", blocking=False)), "needs_input", "Has a question"),
                 (shell(pendingRuntimeRequest=asks("auth_refresh")), "done", "Done"),
                 (shell(pendingRuntimeRequest=asks("dynamic_tool_call")), "done", "Done"),
                 (running(), "working", "Working"),
                 (running(status="waiting", activityRunStatus="waiting"), "working", "Working"),
                 (shell(status="starting", activeRunId="run-1", activityRunStatus="starting",
                        latestRunCompletedAt=None), "working", "Starting"),
                 (shell(status="preparing", activeRunId="run-1", activityRunStatus="preparing",
                        latestRunCompletedAt=None), "working", "Starting"),
                 (shell(activityRunStatus="running", activeRunId="run-2"), "working", "Working"),
                 (shell(pendingBackgroundTasks=[{"taskId": "a", "kind": "subagent"}]), "working", "Background work"),
                 (shell(pendingBackgroundTasks=[{"taskId": "a", "kind": "monitor", "awaited": True}]), "working",
                  "Monitoring"),
                 (shell(pendingBackgroundTasks=[{"taskId": "a", "kind": "command"}]), "done", "Done"),
                 (shell(status="failed", lastError="boom"), "error", "Failed"),
                 (shell(status="failed", pendingBackgroundTasks=[{"taskId": "a", "kind": "subagent"}]), "error",
                  "Failed"),
                 (shell(status="failed", settledOverride="settled", settledAt="2026-10-08T11:00:00Z"), "done",
                  "Done"),
                 (shell(status="interrupted"), "done", "Stopped"), (shell(status="cancelled"), "done", "Stopped"),
                 (shell(), "done", "Done"), (never, "idle", "New"),
                 (dict(never, historyOrigin="v1_import", itemCount=12), "done", "Done")]
        for value, expected, label in cases:
            with self.subTest(expected=expected, value=value):
                thread = t3.bridge_thread(value)
                self.assertEqual(expected, t3.mobile_status(thread))
                self.assertEqual(label, t3.status_label(thread, t3.thread_status(thread)))

    def test_the_shell_reads_as_the_rest_of_the_bridge_expects(self) -> None:
        thread = t3.bridge_thread(running(lastError="old"))
        self.assertEqual({"threadId": "t", "status": "running", "activeTurnId": "run-1", "lastError": None,
                          "providerName": None, "updatedAt": None}, thread["session"])
        self.assertEqual({"turnId": "run-1", "state": "running", "requestedAt": "2026-10-08T10:00:00Z",
                          "startedAt": "2026-10-08T10:00:01Z", "completedAt": None}, thread["latestTurn"])
        failed = t3.bridge_thread(shell(status="failed", lastError="The provider stopped."))
        self.assertEqual(("error", "The provider stopped.", "2026-10-08T10:05:00Z"),
                         (failed["session"]["status"], failed["session"]["lastError"], failed["session"]["updatedAt"]))
        self.assertEqual(("error", "2026-10-08T10:05:00Z"),
                         (failed["latestTurn"]["state"], failed["latestTurn"]["completedAt"]))
        self.assertEqual("2026-10-08T10:05:00Z", t3.activity_time(t3.bridge_thread(shell())))
        self.assertFalse(t3.is_settled(t3.bridge_thread(shell(settledOverride="active",
                                                             settledAt="2026-10-08T11:00:00Z"))))

    def test_subagent_requests_show_on_their_parents(self) -> None:
        def child(thread_id: str, parent: str, kind: str, **fields: object) -> dict:
            return running(**{"id": thread_id, "pendingRuntimeRequest": asks(kind), "creationSource": "server",
                              "lineage": {"parentThreadId": parent, "relationshipToParent": "subagent",
                                          "rootThreadId": "root"}, **fields})
        root = shell(id="root")
        middle = running(id="mid", lineage={"parentThreadId": "root", "relationshipToParent": "subagent",
                                            "rootThreadId": "root"}, creationSource="server")
        shells = [root, middle, child("c-input", "mid", "user_input"), child("c-approve", "root", "command"),
                  child("c-native", "root", "command", creationSource="provider"),
                  child("c-ended", "root", "command", activityRunStatus=None)]
        found = t3.subagent_requests(shells)
        self.assertEqual(("approval", ["c-input", "c-approve"]), found["root"], "approval wins; native and ended skip")
        self.assertEqual(("user_input", ["c-input"]), found["mid"])
        parent = t3.bridge_thread(root, found["root"])
        self.assertEqual(("needs_approval", ["c-input", "c-approve"]),
                         (t3.mobile_status(parent), parent["pendingChildThreadIds"]))
        self.assertTrue(t3.is_subagent(middle))

    def test_times_are_normalized_for_swift(self) -> None:
        self.assertEqual("2026-10-07T17:18:33Z", t3.normal_time("2026-10-07T17:18:33.806Z"))
        self.assertEqual("2026-10-07T21:18:33Z", t3.normal_time("2026-10-07T17:18:33.8-04:00"))
        self.assertEqual("2026-10-07T17:18:33Z", t3.normal_time("2026-10-07T17:18:33.806123456Z"))
        self.assertIsNone(t3.normal_time("yesterday"))
        self.assertIsNone(t3.normal_time(None))

    def test_pending_requests_follow_t3(self) -> None:
        def request(request_id: str, kind: str, at: str, status: str = "pending", capability: str = "live") -> dict:
            return {"id": request_id, "kind": kind, "status": status, "createdAt": at,
                    "responseCapability": {"type": capability}}

        def item(kind: str, request_id: str, **fields: object) -> dict:
            return {"id": "i-" + request_id, "type": kind, "requestId": request_id, **fields}
        thread = {
            "runtimeRequests": [request("a", "file-change", "1", status="resolved"), request("b", "command", "2"),
                                request("c", "auth_refresh", "3"), request("d", "dynamic_tool_call", "4"),
                                request("q", "user_input", "5", capability="message"), request("old", "user_input", "0"),
                                request("e", "permission", "6")],
            "turnItems": [item("approval_request", "a", requestKind="file-change"),
                          item("approval_request", "b", requestKind="command", prompt="first prompt"),
                          item("approval_request", "b", requestKind="command", prompt="npm test",
                               options=[{"decision": "accept", "label": "Yes"}, {"decision": "bogus", "label": "?"}]),
                          item("user_input_request", "q", questions=[{"id": "0", "header": "H", "question": "Which?",
                                                                      "options": [{"label": "A", "description": "a"}]}])]}
        pending = t3.pending_requests(thread)
        self.assertEqual(["b", "e"], [entry.request_id for entry in pending.approvals])
        self.assertEqual(({"decision": "accept", "label": "Yes"},), pending.approvals[0].options, "the last item wins")
        self.assertEqual(("npm test", t3.DEFAULT_APPROVAL_OPTIONS, "permission"),
                         (pending.approvals[0].detail, pending.approvals[1].options, pending.approvals[1].kind))
        self.assertEqual((["q"], True), ([entry.request_id for entry in pending.inputs], pending.inputs[0].dismissible))
        self.assertEqual(1, pending.unmatched, "a question older than the window")
        view = t3.pending_view(pending)
        self.assertEqual(("approval", "npm test"), (view["kind"], view["text"]))
        self.assertEqual("Wants to edit files",
                         t3.pending_view(t3.pending_requests({"runtimeRequests": [request("x", "file-change", "1")]}))
                         ["text"], "no item: the kind says it")
        self.assertIsNone(t3.pending_view(t3.PendingRequests()))
        self.assertEqual(("t-child", "t-child"), tuple(entry.thread_id for entry in
                                                       pending.asked_by("t-child").approvals))

    def test_answers_map_to_option_values(self) -> None:
        question = t3.PendingQuestion("q1", "H", "Which?", ("Use SQLite", "Postgres"), True, False, ("sqlite", "Postgres"))
        request = t3.PendingInput("r", (question,), False, "")
        self.assertEqual({"q1": "sqlite"}, t3.resolve_answers(request, {"q1": "use sqlite"}))
        self.assertEqual({"q1": "Postgres"}, t3.resolve_answers(request, {"q1": "2"}))
        self.assertEqual({"q1": "sqlite"}, t3.resolve_answers(request, {"q1": "SQLite"}))
        self.assertEqual({"q1": "something else entirely"}, t3.resolve_answers(request, {"x": "something else entirely"}))
        strict = t3.PendingInput("r", (t3.PendingQuestion("q1", "H", "Which?", ("A", "B"), False, False, ("A", "B")),),
                                 False, "")
        with self.assertRaises(t3.T3Error):
            t3.resolve_answers(strict, {"q1": "C"})

    def test_ordinal_answers_pick_by_position_as_on_the_r1(self) -> None:
        question = t3.PendingQuestion("q1", "H", "Which?", ("Use SQLite", "Postgres", "None"), True, False,
                                      ("sqlite", "Postgres", "none"))
        request = t3.PendingInput("r", (question,), False, "")
        for said, expected in (("first", "sqlite"), ("the first one", "sqlite"), ("The second option.", "Postgres"),
                               ("third one", "none"), ("the fourth one", "the fourth one"),
                               ("first, but skip tests", "first, but skip tests")):
            with self.subTest(said=said):
                self.assertEqual({"q1": expected}, t3.resolve_answers(request, {"q1": said}))
        strict = t3.PendingInput("r", (t3.PendingQuestion("q1", "H", "Which?", ("A", "B"), False, False, ("a", "b")),),
                                 False, "")
        self.assertEqual({"q1": "b"}, t3.resolve_answers(strict, {"q1": "the second one"}))
        with self.assertRaises(t3.T3Error):
            t3.resolve_answers(strict, {"q1": "the third one"})

    def test_timeline_folds_tool_steps(self) -> None:
        def tool(number: int, kind: str = "command_execution", **fields: object) -> dict:
            return {"id": f"c{number}", "type": kind, "startedAt": f"2026-10-08T10:0{number}:00Z",
                    "updatedAt": f"2026-10-08T10:0{number}:30Z", "title": f"Step {number}", **fields}
        thread = {"messages": [
            {"id": "1", "role": "user", "text": "go", "createdAt": "2026-10-08T10:00:00Z"},
            {"id": "2", "role": "system", "text": "thinking", "createdAt": "2026-10-08T10:00:01Z"},
            {"id": "w", "role": "user", "text": "a subagent finished", "createdAt": "2026-10-08T10:04:40Z",
             "notification": {"source": {"kind": "subagent"}, "outcome": "completed", "summary": "done"}},
            {"id": "3", "role": "assistant", "text": "done", "createdAt": "2026-10-08T10:05:00Z"}],
            "turnItems": [tool(1), tool(2, "file_change"), tool(3, "web_search"), tool(4, "dynamic_tool", title=None,
                                                                                  toolName="Step 4"),
                          {"id": "r", "type": "reasoning", "startedAt": "2026-10-08T10:04:10Z", "text": "hm"},
                          {"id": "x", "type": "command_execution", "startedAt": "2026-10-08T10:06:00Z", "title": ""}]}
        self.assertEqual([("user", "go"), ("tool", "4 steps: Step 1, Step 2, Step 3 (+1 more)"), ("assistant", "done"),
                          ("tool", "1 step: Command run")],
                         [(item["role"], item["text"]) for item in t3.timeline(thread)])

    def test_plan_progress_from_the_active_task_list(self) -> None:
        steps = [{"text": "A", "status": "completed"}, {"text": "B", "status": "running"},
                 {"text": "C", "status": "pending"}]
        plans = [{"kind": "todo_list", "status": "superseded", "steps": steps[:1]},
                 {"kind": "proposed_plan", "status": "active", "markdown": "x"},
                 {"kind": "todo_list", "status": "active", "steps": steps}]
        self.assertEqual({"step": "B", "completedSteps": 1, "totalSteps": 3}, t3.plan_progress(plans))
        self.assertIsNone(t3.plan_progress([plans[0]]))
        self.assertIsNone(t3.plan_progress(None))
        thread = dict(t3.bridge_thread(running()), planProgress=t3.plan_progress(plans))
        self.assertEqual("Step 2 of 3", t3.status_label(thread, t3.thread_status(thread)))

    def test_commands_are_orchestration_v2_shapes(self) -> None:
        ids = iter(f"id-{number}" for number in range(100))
        commands = t3.CommandBuilder(new_id=lambda: next(ids))
        self.assertEqual({"commandId": "id-0", "creationSource": "mobile", "threadId": "t", "projectId": "p",
                          "title": "Do it", "generateTitle": True, "modelSelection": {"instanceId": "c", "model": "m"},
                          "runtimeMode": "full-access", "interactionMode": "default", "workspaceStrategy": {"type": "root"},
                          "initialMessage": {"messageId": "id-1", "text": "do it", "attachments": []}},
                         commands.launch(thread_id="t", project_id="p", title="Do it", text="do it",
                                         model_selection={"instanceId": "c", "model": "m"}, runtime_mode="full-access"))
        self.assertEqual({"type": "message.dispatch", "commandId": "id-2", "createdBy": "user", "creationSource": "mobile",
                          "threadId": "t", "messageId": "id-3", "text": "hi", "attachments": [],
                          "deliveryIntent": "auto", "dispatchMode": {"type": "start_immediately"}},
                         commands.message(thread_id="t", text="hi"))
        self.assertEqual({"type": "runtime-request.respond", "commandId": "id-4", "threadId": "t", "requestId": "r",
                          "decision": "acceptForSession"},
                         commands.approval_respond(thread_id="t", request_id="r", decision="acceptForSession"))
        self.assertEqual({"type": "runtime-request.respond", "commandId": "id-5", "threadId": "t", "requestId": "r",
                          "answers": {"q1": ["a", "b"]}},
                         commands.user_input_respond(thread_id="t", request_id="r", answers={"q1": ["a", "b"]}))
        self.assertEqual({"type": "thread.stop", "commandId": "id-6", "threadId": "t"}, commands.stop(thread_id="t"))
        with self.assertRaises(ValueError):
            commands.approval_respond(thread_id="t", request_id="r", decision="maybe")


class PlacementTest(unittest.TestCase):
    def test_coding_or_not(self) -> None:
        for text in ("Fix the failing tests", "Refactor the sync module", "Add a widget to the R1",
                     "Why does the build crash in Xcode"):
            self.assertTrue(t3.is_coding_task(text), text)
        for text in ("Summarize my inbox", "What's on my calendar today", "Tell me a joke", "Book a flight to Lisbon",
                     "Open YouTube in Chrome"):
            self.assertFalse(t3.is_coding_task(text), text)

    def test_orchestration_project_fallbacks(self) -> None:
        agent = record("agent", "Assistant", "/Users/x/.t3/hermes/workspace")
        named = record("named", "Hermes", "/Users/x/agents")
        repo = record("repo", "SamRabbit", "/Users/x/jackrabbit-src")
        scratch = record("scratch", "No project", "/Users/x/.t3/scratch", scratch=True)
        self.assertEqual("named", t3.orchestration_project([repo, agent, named, scratch])["id"], "the configured title")
        self.assertEqual("repo", t3.orchestration_project([repo, agent, named], project_id="repo")["id"])
        self.assertEqual("agent", t3.orchestration_project([repo, agent, scratch])["id"], "T3's agent workspace")
        self.assertEqual("repo", t3.orchestration_project([scratch, repo])["id"], "else the most recent project")
        self.assertEqual("scratch", t3.orchestration_project([scratch])["id"])
        self.assertIsNone(t3.orchestration_project([]))

    def test_place(self) -> None:
        agent = record("agent", "Hermes", "/Users/x/.t3/hermes/workspace")
        repo = record("repo", "SamRabbit", "/Users/x/jackrabbit-src", repository={"remote": "git@github.com:x/SamRabbit.git"})
        site = record("site", "Website", "/Users/x/code/site")
        records = [agent, repo, site]

        def where(text: str, choices: list = records) -> tuple:
            chosen, reason = t3.place(text, choices)
            return chosen["id"], reason
        self.assertEqual(("repo", t3.CODING), where("Fix the failing tests"))
        self.assertEqual(("agent", t3.ORCHESTRATION), where("Summarize my inbox"))
        self.assertEqual(("site", t3.MENTIONED), where("Change the website hero"))
        self.assertEqual(("repo", t3.MENTIONED), where("Merge the samrabbit branch"))
        self.assertEqual(("agent", t3.ORCHESTRATION), where("Fix the tests", [agent]),
                         "nothing else: the orchestration project after all")
        with self.assertRaises(t3.T3Error):
            t3.place("anything", [])


class CliAndTokenTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def test_cli_output_parsing(self) -> None:
        self.assertEqual({"credential": "X"}, t3._json_object('warning: old db\n{\n  "credential": "X"\n}\n'))  # noqa: SLF001
        self.assertIsNone(t3._json_object("no json here"))  # noqa: SLF001

    def test_token_store_is_private_and_rereads_changes(self) -> None:
        store = t3.TokenStore(str(self.root / "cfg" / "t3-token"))
        self.assertIsNone(store.load())
        store.save({"token": "a" * 40, "expiresAt": "2026-11-01T00:00:00Z"})
        path = self.root / "cfg" / "t3-token"
        self.assertEqual(0o600, stat.S_IMODE(path.stat().st_mode))
        self.assertEqual(0o700, stat.S_IMODE(path.parent.stat().st_mode))
        path.write_text(json.dumps({"token": "b" * 40}))
        path.chmod(0o644)
        self.assertEqual("b" * 40, store.load()["token"])
        self.assertEqual(0o600, stat.S_IMODE(path.stat().st_mode), "tightened")
        path.write_text("{not json")
        self.assertIsNone(store.load())

    def test_session_ids_come_from_the_claims(self) -> None:
        fake = FakeT3(str(self.root))
        self.addCleanup(fake.close)
        self.assertEqual("sid-1", t3.session_id_of(fake.issue_token()))
        self.assertIsNone(t3.session_id_of("garbage.token"))

    def test_http_refuses_plain_http_to_the_internet(self) -> None:
        for url in ("http://8.8.8.8:3773", "ftp://127.0.0.1", "http://user:pw@127.0.0.1:3773", ""):
            with self.assertRaises(ValueError, msg=url):
                t3.T3Http(url)
        for url in ("http://127.0.0.1:3773", "http://192.168.1.183:3773", "http://100.100.1.2:3773",
                    "https://t3.example.com"):
            self.assertTrue(t3.T3Http(url).base_url)

    def test_command_line_pairs_once_and_never_prints_the_token(self) -> None:
        fake = FakeT3(str(self.root))
        self.addCleanup(fake.close)
        cli = self.root / "t3"
        cli.write_text(f'#!/bin/sh\nexec "{sys.executable}" "{HERE / "fake_t3_cli.py"}" --state "{self.root}" "$@"\n')
        cli.chmod(0o755)
        token_file = self.root / "cfg" / "t3-token"
        args = ["--token-file", str(token_file), "--url", fake.url, "--cli", str(cli)]

        def run(*command: str) -> subprocess.CompletedProcess:
            return subprocess.run(["/usr/bin/python3", "-I", str(ROOT / "samrabbit_t3.py"), *command, *args],
                                  capture_output=True, text=True, timeout=60)
        done = run("status")
        self.assertEqual((0, "T3 not paired"), (done.returncode, done.stdout.strip()))
        done = run("ensure-paired")
        self.assertEqual((0, "T3 paired (expires 2026-11-07)"), (done.returncode, done.stdout.strip()), done.stderr)
        token = json.loads(token_file.read_text())["token"]
        self.assertNotIn(token, done.stdout + done.stderr)
        done = run("ensure-paired")
        self.assertEqual(0, done.returncode)
        self.assertEqual(1, len((self.root / "cli-calls.jsonl").read_text().splitlines()), "kept, not paired again")
        (self.root / "cli-mode").write_text("fail")
        token_file.unlink()
        done = run("ensure-paired")
        self.assertEqual(3, done.returncode)
        self.assertIn("t3_cli_failed", done.stdout)


class ServerDiscoveryTest(unittest.TestCase):
    """Where T3 runs (its server-runtime.json), that it is T3 before a token goes out, and the app that pairs."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.state = self.root / "t3home" / "userdata"
        self.state.mkdir(parents=True)

    def runtime(self, port: int, *, pid: int = os.getpid(), host: str = "0.0.0.0") -> None:
        temp = self.state / "server-runtime.json.tmp"
        temp.write_text(json.dumps({"version": 1, "pid": pid, "host": host, "port": port,
                                    "origin": f"http://127.0.0.1:{port}", "serverVersion": "0.1.4-test"}))
        os.replace(temp, self.state / "server-runtime.json")

    def environment(self, value: str) -> None:
        temp = self.state / "environment-id.tmp"
        temp.write_text(value + "\n")
        os.replace(temp, self.state / "environment-id")

    @staticmethod
    def dead_pid() -> int:
        child = subprocess.Popen(["/usr/bin/true"])
        child.wait()
        return child.pid

    def test_the_locator_follows_the_runtime_file_while_its_server_lives(self) -> None:
        locator = t3.ServerLocator(str(self.state))
        self.assertEqual((t3.DEFAULT_SERVER_URL, None), (locator.url(), locator.pid()), "no file: the usual port")
        self.runtime(3774)
        self.assertEqual(("http://127.0.0.1:3774", os.getpid()), (locator.url(), locator.pid()))
        self.runtime(3790, host="127.0.0.1")
        self.assertEqual("http://127.0.0.1:3790", locator.url(), "a restart on another port is followed")
        self.runtime(3791, pid=self.dead_pid())
        self.assertEqual(t3.DEFAULT_SERVER_URL, locator.url(), "a server that is gone does not count")
        (self.state / "server-runtime.json").write_text("{not json")
        self.assertEqual(t3.DEFAULT_SERVER_URL, locator.url())
        self.assertIsNone(locator.environment_id())
        self.environment("11111111-2222-4333-8444-555555555555")
        self.assertEqual("11111111-2222-4333-8444-555555555555", locator.environment_id())
        self.assertEqual("/somewhere/userdata", t3.t3_state_dir({"T3CODE_HOME": "/somewhere"}))
        self.assertEqual(os.path.expanduser("~/.t3/userdata"), t3.t3_state_dir({}))

    def test_a_discovered_server_must_be_t3_before_the_token_goes_out(self) -> None:
        fake = FakeT3(str(self.root))
        self.addCleanup(fake.close)
        token = fake.issue_token()
        self.runtime(int(fake.url.rsplit(":", 1)[1]))
        self.environment(fake.environment_id)
        http = t3.T3Http(None, locator=t3.ServerLocator(str(self.state)))
        self.assertEqual((True, fake.url), (http.auto, http.current()))
        for _ in range(2):
            self.assertIn("threads", http.request("GET", "/api/orchestration/shell", token=token))
        self.assertEqual((1, fake.environment_id), (fake.count("GET /.well-known/t3/environment"), http.environment_id),
                         "checked once, then remembered")
        self.environment("another-environment-id")  # T3 was reset, or another T3-like app took the port
        other = t3.T3Http(None, locator=t3.ServerLocator(str(self.state)))
        with self.assertRaises(t3._Unavailable):  # noqa: SLF001
            other.request("GET", "/api/orchestration/shell", token=token)
        with self.assertRaises(t3._Unavailable):  # noqa: SLF001
            other.rpc("server.getConfig", {}, token=token)
        self.assertEqual(2, fake.count("GET /api/orchestration/shell"), "the token never went to it")
        self.assertEqual(0, fake.count("GET /ws"))

    def test_another_app_on_the_port_never_sees_the_token(self) -> None:
        seen: List[Dict[str, str]] = []  # each request's path and headers

        class Voyager(BaseHTTPRequestHandler):  # a T3-derived app with its own auth: its web page on every path
            def log_message(self, *_args: object) -> None:
                return

            def do_GET(self) -> None:  # noqa: N802
                seen.append(dict(self.headers, path=self.path))
                body = b"<!doctype html><title>Voyager</title>"
                self.send_response(200)
                self.send_header("Content-Type", "text/html")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            do_POST = do_GET  # noqa: N815
        server = ThreadingHTTPServer(("127.0.0.1", 0), Voyager)
        threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        # No runtime file (T3 is not running): the usual port, which the other app holds.
        session = t3.T3Session(t3.T3Http(None, locator=t3.ServerLocator(str(self.state))),
                               t3.TokenStore(str(self.root / "t3-token")), t3.T3Cli(str(self.root / "no-cli")))
        session.store.save({"token": "a" * 40, "expiresAt": "2099-01-01T00:00:00Z"})
        saved = t3.DEFAULT_SERVER_URL
        self.addCleanup(setattr, t3, "DEFAULT_SERVER_URL", saved)
        t3.DEFAULT_SERVER_URL = f"http://127.0.0.1:{server.server_address[1]}"
        with self.assertRaises(t3.T3Error) as caught:
            session.call(lambda token: session.http.request("GET", "/api/orchestration/shell", token=token))
        self.assertEqual("t3_unavailable", caught.exception.code)
        self.assertEqual(["/.well-known/t3/environment"], [headers["path"] for headers in seen])
        self.assertFalse(any("Authorization" in headers for headers in seen), "no token, no pairing credential")

    def test_a_port_change_alone_keeps_the_token(self) -> None:
        record = {"token": "b" * 40, "expiresAt": "2099-01-01T00:00:00Z", "serverUrl": "http://127.0.0.1:3773"}
        store = t3.TokenStore(str(self.root / "t3-token"))
        store.save(record)
        self.runtime(3774)
        auto = t3.T3Session(t3.T3Http(None, locator=t3.ServerLocator(str(self.state))), store, t3.T3Cli(t3.CLI_NONE))
        self.assertEqual("http://127.0.0.1:3774", auto.http.current())
        self.assertEqual("b" * 40, auto.token(), "the same T3, on another port: no new pairing")
        fixed = t3.T3Session(t3.T3Http("http://127.0.0.1:3774"), store, t3.T3Cli(t3.CLI_NONE))
        with self.assertRaises(t3.T3Error) as caught:
            fixed.token()
        self.assertEqual("t3_dev_copy", caught.exception.code, "a fixed address still pairs with its own server")

    def test_the_app_that_pairs_is_the_one_running_the_server(self) -> None:
        def bundle(name: str) -> str:
            app = self.root / "Applications" / f"{name}.app"
            (app / "Contents" / "MacOS").mkdir(parents=True)
            (app / "Contents" / "Resources").mkdir(parents=True)
            executable = app / "Contents" / "MacOS" / name
            executable.write_text("#!/bin/sh\n")
            executable.chmod(0o755)
            (app / "Contents" / "Resources" / "app.asar").write_text("asar")
            return str(app)
        nightly, beta = bundle("T3 Code (Nightly)"), bundle("T3 Code (Beta)")
        missing = str(self.root / "Applications" / "T3 Code (Alpha).app")
        for name, value in (("T3_APPS", (missing, nightly, beta)), ("T3_EXECUTABLE", None), ("T3_ASAR", None)):
            self.addCleanup(setattr, t3, name, getattr(t3, name))
            setattr(t3, name, value)
        self.assertEqual((nightly + "/Contents/MacOS/T3 Code (Nightly)", nightly + "/Contents/Resources/app.asar"),
                         t3.find_app(None), "the first that is installed")
        saved = t3._app_of_pid  # noqa: SLF001
        self.addCleanup(setattr, t3, "_app_of_pid", saved)
        t3._app_of_pid = lambda pid: beta if pid == 4242 else None  # noqa: SLF001
        self.assertEqual(t3.app_parts(beta), t3.find_app(4242), "the live server's own app first")
        self.runtime(3774)
        locator = t3.ServerLocator(str(self.state))
        t3._app_of_pid = lambda pid: beta if pid == os.getpid() else None  # noqa: SLF001
        self.assertEqual([t3.app_parts(beta)[0], t3.app_parts(beta)[1] + "/apps/server/dist/bin.mjs"],
                         t3.T3Cli(t3.CLI_AUTO, locator=locator).command())
        self.assertIsNone(saved(os.getpid()), "this test's own process is no T3 Code app")
        self.assertIsNone(saved(None))


class Python39Test(unittest.TestCase):
    def test_new_modules_parse_as_python_3_9_and_import_isolated(self) -> None:
        for name in ("samrabbit_mobile.py", "samrabbit_t3.py", "samrabbit_bridge.py", "samrabbit_installed.py"):
            ast.parse((ROOT / name).read_text(), filename=name, feature_version=(3, 9))
        # As the LaunchAgent runs it: the macOS system Python, isolated mode, from another folder.
        code = ("import sys; sys.path.append(sys.argv[1]); import samrabbit_mobile, samrabbit_t3, samrabbit_bridge; "
                "print(sys.version_info[:2] >= (3, 9), samrabbit_bridge.mobile is not None, "
                "samrabbit_bridge.installation is not None, samrabbit_bridge.is_installed_copy())")
        done = subprocess.run(["/usr/bin/python3", "-I", "-c", code, str(ROOT)], capture_output=True, text=True,
                              timeout=60, cwd=tempfile.gettempdir())
        self.assertEqual("True True True False", done.stdout.strip(), done.stderr)
        # samrabbit_t3.py run as a script (install.sh) finds samrabbit_installed next to it, isolated too.
        done = subprocess.run(["/usr/bin/python3", "-I", "-c", "import sys; sys.argv = [sys.argv[1]]; "
                               "import runpy; ns = runpy.run_path(sys.argv[0]); "
                               "print(ns['_installed_copy'](), 'samrabbit_installed' in sys.modules)",
                               str(ROOT / "samrabbit_t3.py")], capture_output=True, text=True, timeout=60,
                              cwd=tempfile.gettempdir())
        self.assertEqual("False True", done.stdout.strip(), done.stderr)


if __name__ == "__main__":
    unittest.main()
