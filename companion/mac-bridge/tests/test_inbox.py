"""The Agent Dock's inbox (``/v1/desktop/inbox*``) end to end against fakes.

A real bridge on a random loopback port (``MobileBase``: fake T3 server and CLI, fake Composio, Heptabase and
cua-driver, temp tokens), a temp HOME with synthetic Claude Code (``~/.claude/projects``, ``~/.claude/sessions``) and
Codex (``~/.codex/sessions``) trees plus a decoy ``~/.codex/auth.json`` and ``config.toml`` that must never be touched,
a fake process table instead of ``ps`` / ``lsof``, and a launcher that records what it would open (nothing is ever
launched). Nothing here reaches the real T3 Code, Claude Code, Codex, the user's HOME or the live bridge.

Run: cd companion/mac-bridge && /usr/bin/python3 -m unittest tests.test_inbox -q
"""

from __future__ import annotations

import builtins
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import shlex
import stat
import sys
import threading
import time
import unittest
import uuid
from typing import Any, Dict, List, Optional, Tuple

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE))

import samrabbit_inbox as inbox  # noqa: E402
import samrabbit_t3 as t3  # noqa: E402
from fake_t3 import _thread  # noqa: E402
from test_mobile import DESKTOP, NOW, TOKEN, FakeHandler, MobileBase  # noqa: E402

CWD = "/Users/test/code/app"  # replaced by a real folder under the temp HOME in setUp
SECRET_TITLE = "Refactor the secret 5521 billing module"
SECRET_PROMPT = "please fix the secret 5521 login bug"
SECRET_ANSWER = "Fixed the secret 5521 bug in login.py."
REPLY = "and the secret 5521 tests too, please"
IDS = {name: str(uuid.UUID(int=index + 1)) for index, name in enumerate((
    "done", "waiting", "registry_wait", "busy", "sdk", "sdkcli", "old", "asks", "failed", "sub",
    "desk", "cli_wait", "t3codex", "exec", "subagent", "cli_open", "cli_error", "cli_done", "guardian"))}
STARTED = "Wed Oct 8 18:30:00 2026"


def iso(epoch: float) -> str:
    return t3.iso_utc(datetime.fromtimestamp(epoch, timezone.utc))


class FakeProcesses:
    """Stands in for ``inbox.Processes`` (``ps`` and ``lsof``): ``procs`` pid -> Process, ``cwds``, ``apps``."""

    def __init__(self) -> None:
        self.procs: Dict[int, inbox.Process] = {}
        self.cwds: Dict[int, str] = {}
        self.apps: Dict[int, str] = {}
        self.broken = False
        self.lookups = 0
        self.checks = 0

    def add(self, pid: int, args: str, *, cwd: Optional[str] = None, app: Optional[str] = None,
            started: str = STARTED) -> None:
        self.procs[pid] = inbox.Process(pid, 1, started, args)
        if cwd:
            self.cwds[pid] = cwd
        if app:
            self.apps[pid] = app

    def table(self, *, fresh: bool = False) -> Optional[Dict[int, inbox.Process]]:
        self.lookups += 1
        return None if self.broken else dict(self.procs)

    def started(self, pids: List[int]) -> Optional[Dict[int, str]]:
        self.checks += 1
        return None if self.broken else {pid: self.procs[pid].started for pid in pids if pid in self.procs}

    def cwd(self, process: inbox.Process) -> Optional[str]:
        return self.cwds.get(process.pid)

    def app_of(self, pid: int, table: Optional[Dict[int, inbox.Process]] = None) -> Optional[str]:
        return self.apps.get(pid)


class Recorder:
    """The launcher's ``run``: what would be opened (a Terminal script's text is read at once)."""

    def __init__(self) -> None:
        self.calls: List[List[str]] = []
        self.scripts: List[str] = []

    def __call__(self, argv: List[str]) -> None:
        self.calls.append(list(argv))
        if argv[-1].endswith(".command"):
            path = Path(argv[-1])
            self.scripts.append(path.read_text())
            mode = stat.S_IMODE(path.stat().st_mode)
            assert mode == 0o700, oct(mode)


# ---------------------------------------------------------------------- synthetic session files


def claude_record(kind: str, at: float, *, session: str, entrypoint: str = "cli", cwd: Optional[str] = None,
                  **extra: Any) -> Dict[str, Any]:
    return {"type": kind, "sessionId": session, "entrypoint": entrypoint, "cwd": cwd or CWD, "isSidechain": False,
            "uuid": str(uuid.uuid4()), "timestamp": iso(at), "userType": "external", "version": "2.1.295", **extra}


def claude_user(at: float, text: str, **kw: Any) -> Dict[str, Any]:
    return claude_record("user", at, message={"role": "user", "content": text}, **kw)


def claude_text(at: float, text: str, *, stop: Optional[str] = "end_turn", message_id: str = "msg_1",
                **kw: Any) -> Dict[str, Any]:
    return claude_record("assistant", at, message={"id": message_id, "role": "assistant", "model": "claude-opus-5-5",
                                                   "content": [{"type": "text", "text": text}],
                                                   "stop_reason": stop}, **kw)


def claude_tool(at: float, name: str, tool_input: Dict[str, Any], *, tool_id: str = "toolu_1",
                **kw: Any) -> Dict[str, Any]:
    return claude_record("assistant", at, message={"id": "msg_t", "role": "assistant", "model": "claude-opus-5-5",
                                                   "content": [{"type": "tool_use", "id": tool_id, "name": name,
                                                                "input": tool_input}], "stop_reason": "tool_use"},
                         **kw)


def claude_result(at: float, tool_id: str = "toolu_1", **kw: Any) -> Dict[str, Any]:
    return claude_record("user", at, message={"role": "user", "content": [
        {"type": "tool_result", "tool_use_id": tool_id, "content": "ok"}]}, toolUseResult={"stdout": "ok"}, **kw)


def codex_line(kind: str, at: float, payload: Dict[str, Any]) -> Dict[str, Any]:
    return {"timestamp": iso(at), "type": kind, "payload": payload}


def codex_meta(at: float, thread_id: str, *, originator: str, source: Any = "cli", cwd: Optional[str] = None,
               **extra: Any) -> Dict[str, Any]:
    return codex_line("session_meta", at, {"id": thread_id, "timestamp": iso(at), "cwd": cwd or CWD,
                                           "originator": originator, "cli_version": "0.162.0", "source": source,
                                           **extra})


def codex_event(at: float, kind: str, **payload: Any) -> Dict[str, Any]:
    return codex_line("event_msg", at, {"type": kind, **payload})


def desktop_head(at: float, thread_id: str, *, policy: str = "never") -> List[Dict[str, Any]]:
    """How Codex Desktop (ChatGPT 26.1007) starts a rollout today: about 100 KB (its instructions in the meta, a
    developer message, the world state, the turn context, AGENTS.md and the environment) before anything typed."""
    return [
        codex_meta(at, thread_id, originator="Codex Desktop", source="vscode",
                   base_instructions={"text": "You are Codex. " + "i" * 22_000}),
        codex_line("response_item", at, {"type": "message", "role": "developer", "content": [
            {"type": "input_text",
             "text": "<permissions instructions>" + "p" * 60_000 + "</permissions instructions>"}]}),
        {"timestamp": iso(at), "type": "world_state", "payload": {"apps": "w" * 24_000}},
        codex_line("turn_context", at, {"cwd": CWD, "approval_policy": policy, "model": "gpt-6",
                                        "sandbox_policy": {"type": "danger-full-access"}}),
        codex_line("response_item", at, {"type": "message", "role": "user", "content": [
            {"type": "input_text", "text": "# AGENTS.md instructions for " + CWD + "\n\n<INSTRUCTIONS>be brief"
                                           "</INSTRUCTIONS>"},
            {"type": "input_text",
             "text": "<environment_context>\n  <cwd>" + CWD + "</cwd>\n</environment_context>"}]})]


def desktop_turn(at: float, text: Optional[str], answer: Optional[str] = None, *,
                 error: Optional[str] = None) -> List[Dict[str, Any]]:
    """One turn as Codex Desktop writes it now: ``item_completed`` events next to the response items, and a failure
    inside ``task_complete`` (no ``error`` event, no last answer)."""
    records = [codex_event(at, "task_started", turn_id="turn-" + str(int(at)))]
    if text is not None:
        records += [codex_line("response_item", at, {"type": "message", "role": "user", "content": [
                        {"type": "input_text", "text": text}]}),
                    codex_event(at, "item_completed", item={"type": "UserMessage", "id": "u-" + str(int(at)),
                                                            "content": [{"type": "text", "text": text}]})]
    records.append(codex_event(at, "thread_settings_applied", settings={"model": "gpt-6"}))
    if answer is not None:
        records += [codex_event(at + 5, "item_completed", item={"type": "AgentMessage", "id": "a-" + str(int(at)),
                                                                "phase": "final_answer",
                                                                "content": [{"type": "Text", "text": answer}]}),
                    codex_line("response_item", at + 5, {"type": "message", "role": "assistant", "content": [
                        {"type": "output_text", "text": answer}]})]
    end: Dict[str, Any] = {"turn_id": "turn-" + str(int(at)), "last_agent_message": answer}
    if error is not None:
        end["error"] = {"message": error, "codex_error_info": "response_stream_disconnected"}
    records.append(codex_event(at + 6, "task_complete", **end))
    return records


class InboxBase(MobileBase):
    """``MobileBase`` with the desktop inbox reading a synthetic HOME (the bridge's own inbox is replaced)."""

    def setUp(self) -> None:
        super().setUp()
        self.clock.follow_real_time()
        self.home = self.root / "home-inbox"
        self.claude_root = self.home / ".claude"
        self.codex_root = self.home / ".codex"
        (self.claude_root / "projects").mkdir(parents=True)
        (self.claude_root / "sessions").mkdir(parents=True)
        (self.codex_root / "sessions").mkdir(parents=True)
        self.cwd = self.home / "code" / "app"
        self.cwd.mkdir(parents=True)
        global CWD
        CWD = str(self.cwd)
        self.project_dir = self.claude_root / "projects" / CWD.replace("/", "-")
        self.project_dir.mkdir()
        # The decoys: nothing may ever open, stat or list them.
        for name in ("auth.json", "config.toml", "session_index.jsonl"):
            decoy = self.codex_root / name
            decoy.write_text('{"tokens": "do-not-read-me"}\n')
            decoy.chmod(0o000)
            self.addCleanup(decoy.chmod, 0o600)
        self.processes = FakeProcesses()
        self.recorder = Recorder()
        self.scratch = self.root / "inbox-scripts"
        self.inbox_dir = self.root / "inbox-state"
        self.inbox = self.make_inbox()
        old = self.server.inbox
        if old is not None:
            old.close()
        self.server.inbox = self.inbox
        self.inbox.attach(self.server)
        self.addCleanup(self.inbox.close)

    def make_inbox(self, **kwargs: Any) -> inbox.InboxService:
        return inbox.InboxService(state_dir=str(self.inbox_dir), home=str(self.home),
                                  launcher=inbox.Launcher(run=self.recorder, scratch=str(self.scratch)),
                                  processes=self.processes, claude_cli="/opt/test/bin/claude",
                                  codex_cli="/opt/test/bin/codex", clock=self.clock.time,
                                  monotonic=self.clock.monotonic, **kwargs)

    # ------------------------------------------------------------------ fixtures
    def claude_session(self, name: str, records: List[Dict[str, Any]], *, age: float = 60.0,
                       folder: Optional[Path] = None) -> Path:
        path = (folder or self.project_dir) / (IDS[name] + ".jsonl")
        path.write_text("".join(json.dumps(record) + "\n" for record in records))
        os.utime(path, (NOW - age, NOW - age))
        return path

    def codex_session(self, name: str, records: List[Dict[str, Any]], *, age: float = 60.0,
                      day: str = "2026/10/08") -> Path:
        folder = self.codex_root / "sessions" / day
        folder.mkdir(parents=True, exist_ok=True)
        path = folder / f"rollout-2026-10-08T14-00-00-{IDS[name]}.jsonl"
        path.write_text("".join(json.dumps(record) + "\n" for record in records))
        os.utime(path, (NOW - age, NOW - age))
        return path

    def append(self, path: Path, records: List[Dict[str, Any]], *, age: float) -> None:
        with open(path, "a") as handle:
            handle.write("".join(json.dumps(record) + "\n" for record in records))
        os.utime(path, (NOW - age, NOW - age))

    def register(self, pid: int, name: str, status: str, waiting_for: Optional[str] = None) -> None:
        entry = {"pid": pid, "sessionId": IDS[name], "cwd": CWD, "startedAt": int(NOW * 1000), "kind": "interactive",
                 "procStart": "Wed Oct  8 18:30:00 2026", "entrypoint": "cli", "status": status,
                 "version": "2.1.295"}
        if waiting_for:
            entry["waitingFor"] = waiting_for
        (self.claude_root / "sessions" / f"{pid}.json").write_text(json.dumps(entry))
        # Claude Code keeps a key file next to each entry: never read.
        key = self.claude_root / "sessions" / f"{pid}.abcdef.key"
        key.write_text("not-for-us")
        key.chmod(0o000)
        self.addCleanup(key.chmod, 0o600)

    def build_world(self) -> None:
        """Every kind of session the inbox must show, and every kind it must leave out."""
        t = NOW
        self.claude_session("done", [
            {"type": "file-history-snapshot", "messageId": "x", "snapshot": {}},
            claude_user(t - 600, SECRET_PROMPT, session=IDS["done"]),
            claude_text(t - 590, "Looking at it.", stop=None, session=IDS["done"]),
            claude_text(t - 590, SECRET_ANSWER, session=IDS["done"]),
            {"type": "ai-title", "sessionId": IDS["done"], "aiTitle": SECRET_TITLE},
            {"type": "last-prompt", "sessionId": IDS["done"], "lastPrompt": SECRET_PROMPT}], age=580)
        self.claude_session("waiting", [
            claude_user(t - 30, "<command-name>/clear</command-name>", session=IDS["waiting"]),
            claude_user(t - 30, "# Run the build\nthen deploy", session=IDS["waiting"]),
            claude_tool(t - 20, "Bash", {"command": "npm run build -- --prod"}, session=IDS["waiting"])], age=20)
        self.processes.add(4100, "claude", cwd=CWD,
                           app="/Applications/iTerm.app")
        self.claude_session("registry_wait", [
            claude_user(t - 50, "clean the build folder", session=IDS["registry_wait"]),
            claude_tool(t - 49, "Bash", {"command": "rm -rf build"}, tool_id="toolu_r", session=IDS["registry_wait"])],
            age=2)
        self.processes.add(4200, "/Users/test/.local/bin/claude --resume " + IDS["registry_wait"])
        self.register(4200, "registry_wait", "waiting", "approve Bash: rm -rf build")
        self.claude_session("busy", [
            claude_user(t - 300, "write the migration", session=IDS["busy"]),
            claude_tool(t - 200, "Task", {"description": "research"}, session=IDS["busy"])], age=200)
        self.processes.add(4300, "claude")
        self.register(4300, "busy", "busy")
        self.claude_session("sdk", [claude_user(t - 100, "a T3 thread", session=IDS["sdk"], entrypoint="sdk-ts"),
                                    claude_text(t - 99, "done", session=IDS["sdk"], entrypoint="sdk-ts")])
        self.claude_session("sdkcli", [claude_user(t - 100, "the assistant", session=IDS["sdkcli"],
                                                   entrypoint="sdk-cli")])
        self.claude_session("old", [claude_user(t - 5 * 86400, "last week", session=IDS["old"]),
                                    claude_text(t - 5 * 86400, "ok", session=IDS["old"])], age=5 * 86400)
        self.claude_session("asks", [
            claude_user(t - 40, "set up the database", session=IDS["asks"]),
            claude_tool(t - 30, "AskUserQuestion", {"questions": [
                {"question": "Which database should I use?", "header": "Database", "multiSelect": False,
                 "options": [{"label": "SQLite", "description": ""}, {"label": "Postgres", "description": ""}]}]},
                tool_id="toolu_q", session=IDS["asks"])], age=30)
        self.processes.add(4400, "claude --resume " + IDS["asks"])
        self.claude_session("failed", [
            claude_user(t - 900, "summarize the logs", session=IDS["failed"]),
            claude_record("assistant", t - 899, session=IDS["failed"], isApiErrorMessage=True, error="rate_limit",
                          message={"id": "e", "role": "assistant", "model": "<synthetic>",
                                   "content": [{"type": "text", "text": "API Error: rate limited"}],
                                   "stop_reason": "stop_sequence"})], age=899)
        sub_folder = self.project_dir / IDS["done"] / "subagents"
        sub_folder.mkdir(parents=True)
        self.claude_session("sub", [claude_user(t - 20, "a subagent", session=IDS["sub"])], folder=sub_folder)
        # Codex
        self.codex_session("desk", [
            codex_meta(t - 700, IDS["desk"], originator="Codex Desktop", source="vscode"),
            codex_line("response_item", t - 699, {"type": "message", "role": "user", "content": [
                {"type": "input_text", "text": "<environment_context>\n  <cwd>/x</cwd>\n</environment_context>"},
                {"type": "input_text", "text": "Draft the release notes"}]}),
            codex_event(t - 699, "task_started"),
            codex_event(t - 650, "agent_message", message="Here are the release notes."),
            codex_event(t - 640, "task_complete", last_agent_message="Here are the release notes.")], age=640)
        self.codex_session("cli_wait", [
            codex_meta(t - 100, IDS["cli_wait"], originator="codex_cli_rs"),
            codex_event(t - 99, "user_message", message="migrate the schema"),
            codex_event(t - 98, "task_started"),
            codex_event(t - 50, "exec_approval_request", call_id="call_9", command=["psql", "-f", "migrate.sql"],
                        cwd=CWD)], age=50)
        self.codex_session("t3codex", [codex_meta(t - 100, IDS["t3codex"], originator="T3 Code", source="vscode"),
                                       codex_event(t - 99, "user_message", message="a T3 thread")])
        self.codex_session("exec", [codex_meta(t - 100, IDS["exec"], originator="codex_exec", source="exec"),
                                    codex_event(t - 99, "user_message", message="exec run")])
        self.codex_session("subagent", [codex_meta(t - 100, IDS["subagent"], originator="codex_cli_rs",
                                                   source={"subagent": "review"}),
                                        codex_event(t - 99, "user_message", message="review")])
        self.codex_session("guardian", [codex_meta(t - 100, IDS["guardian"], originator="codex_cli_rs",
                                                   thread_source="guardian_review"),
                                        codex_event(t - 99, "user_message", message="guard")])
        self.codex_session("cli_open", [
            codex_meta(t - 30, IDS["cli_open"], originator="codex-tui"),
            codex_event(t - 29, "user_message", message="write the docs"),
            codex_event(t - 28, "task_started"),
            codex_event(t - 5, "agent_message", message="Writing the docs now.")], age=5)
        self.codex_session("cli_error", [
            codex_meta(t - 400, IDS["cli_error"], originator="codex_cli_rs"),
            codex_event(t - 399, "user_message", message="deploy it"),
            codex_event(t - 398, "task_started"),
            codex_event(t - 390, "error", message="stream disconnected")], age=390)
        self.codex_session("cli_done", [
            codex_meta(t - 2000, IDS["cli_done"], originator="codex_cli_rs"),
            codex_event(t - 1999, "user_message", message="bump the version"),
            codex_event(t - 1998, "task_started"),
            codex_event(t - 1990, "task_complete", last_agent_message="Bumped to 1.4.0.")], age=1990, day="2026/10/07")

    # ------------------------------------------------------------------ helpers
    def get_inbox(self, query: str = "") -> Dict[str, Any]:
        status, value = self.call("GET", "/v1/desktop/inbox" + query, desktop=True)
        self.assertEqual(200, status, value)
        return value

    def fresh(self) -> Dict[str, Any]:
        self.inbox.refresh(force=True)
        return self.get_inbox()

    def by_id(self, value: Dict[str, Any]) -> Dict[str, Dict[str, Any]]:
        return {item["id"]: item for item in value["items"]}

    def act(self, item_id: str, action: str, body: Any = None) -> Tuple[int, Dict[str, Any]]:
        return self.call("POST", f"/v1/desktop/inbox/items/{item_id}/{action}", body if body is not None else {},
                         desktop=True)


# ====================================================================== auth


class AuthTest(InboxBase):
    def test_only_the_desktop_app_on_this_mac_gets_in(self) -> None:
        phone = self.pair()["token"]
        for path in ("/v1/desktop/inbox", "/v1/desktop/inbox/targets", "/v1/desktop/inbox/items/t3:t-done"):
            for kwargs in ({}, {"token": TOKEN}, {"token": phone},
                           {"headers": {"X-SamRabbit-Desktop": "wrong-" + "x" * 30}}):
                with self.subTest(path=path, kwargs=list(kwargs)):
                    status, value = self.call("GET", path, **kwargs)
                    self.assertEqual(401, status, value)
                    self.assertEqual("unauthorized", value["error"]["code"])
        status, value = self.call("GET", "/v1/desktop/inbox", desktop=True, headers={"Origin": "http://evil.example"})
        self.assertEqual(403, status, "a web page can never read the inbox")
        handler = FakeHandler("192.168.1.20", "/v1/desktop/inbox", {"X-SamRabbit-Desktop": DESKTOP})
        self.inbox.serve(handler, "GET", "/v1/desktop/inbox")
        self.assertEqual(403, handler.status, "another machine on the LAN is refused even with the desktop token")
        self.assertEqual("forbidden", handler.json()["error"]["code"])
        status, value = self.act("t3:t-done", "seen", None)
        self.assertEqual(200, status, value)
        status, value = self.call("POST", "/v1/desktop/inbox/items/t3:t-done/stop", {})
        self.assertEqual(401, status)
        self.assertEqual([], [item for item in self.fake_t3.dispatched], "a refused request dispatched nothing")
        status, value = self.call("DELETE", "/v1/desktop/inbox", desktop=True)
        self.assertEqual(405, status)
        status, value = self.call("GET", "/v1/desktop/inbox/nope", desktop=True)
        self.assertEqual(404, status)


# ====================================================================== the list


class ListTest(InboxBase):
    def test_every_source_with_its_statuses_in_the_contract_order(self) -> None:
        self.build_world()
        value = self.get_inbox()
        self.assertEqual({"revision", "updatedAt", "counts", "sources", "items"}, set(value))
        self.assertEqual({"t3": {"connected": True}, "claude": {"available": True}, "codex": {"available": True},
                          "samrabbit": {"available": True}}, value["sources"])
        items = self.by_id(value)
        claude = {key: items.get("claude:" + IDS[key]) for key in IDS}
        codex = {key: items.get("codex:" + IDS[key]) for key in IDS}
        for name in ("sdk", "sdkcli", "old", "sub"):
            self.assertIsNone(claude[name], f"claude {name} is left out")
        for name in ("t3codex", "exec", "subagent", "guardian"):
            self.assertIsNone(codex[name], f"codex {name} is left out")
        for item in value["items"]:
            self.assertEqual({"id", "source", "agent", "title", "project", "cwd", "status", "statusLabel", "summary",
                              "updatedAt", "unread", "pending", "can", "live", "progress", "phase"}, set(item))
            self.assertLessEqual(len(item["summary"]), 240)
            self.assertRegex(item["updatedAt"], r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")
        # Claude Code
        done = claude["done"]
        self.assertEqual(("done", "Finished", SECRET_TITLE, SECRET_ANSWER, "app", CWD, "claude", False),
                         (done["status"], done["statusLabel"], done["title"], done["summary"], done["project"],
                          done["cwd"], done["agent"], done["live"]))
        self.assertEqual(["reply", "open"], done["can"], "nobody owns it: reply resumes it in Terminal")
        waiting = claude["waiting"]
        self.assertEqual(("needs-approval", "Waiting for you in the terminal", "Run the build", True),
                         (waiting["status"], waiting["statusLabel"], waiting["title"], waiting["live"]),
                         "a tool call with no result, the file quiet for 4 s and a claude process in its folder")
        self.assertEqual(["open"], waiting["can"], "only the terminal can answer its prompt")
        self.assertEqual([{"requestId": "toolu_1", "kind": "command",
                           "detail": "Wants to run: npm run build -- --prod", "options": []}],
                         waiting["pending"]["approvals"])
        registered = claude["registry_wait"]
        self.assertEqual(("needs-approval", True), (registered["status"], registered["live"]),
                         "Claude Code's registry says it waits (even though the file was written 2 s ago)")
        self.assertEqual("Wants to run: rm -rf build", registered["summary"])
        busy = claude["busy"]
        self.assertEqual(("working", True, ["open"]), (busy["status"], busy["live"], busy["can"]))
        asks = claude["asks"]
        self.assertEqual(("needs-input", "Which database should I use?"), (asks["status"], asks["summary"]))
        self.assertEqual([{"requestId": "toolu_q", "questions": [
            {"id": "0", "header": "Database", "question": "Which database should I use?",
             "options": ["SQLite", "Postgres"], "allowCustom": True, "multiSelect": False}]}],
            asks["pending"]["inputs"])
        self.assertEqual(("idle", "Hit an error", "API Error: rate limited"),
                         (claude["failed"]["status"], claude["failed"]["statusLabel"], claude["failed"]["summary"]),
                         "an error from before the first look is seen like the rest: the dock starts quiet")
        # Codex
        desk = codex["desk"]
        self.assertEqual(("done", "Draft the release notes", "Here are the release notes.", "codex", ["open"], False),
                         (desk["status"], desk["title"], desk["summary"], desk["agent"], desk["can"], desk["live"]),
                         "Codex Desktop: the injected environment block is not the title; the app owns it")
        wait = codex["cli_wait"]
        self.assertEqual(("needs-approval", "Waiting for you in the terminal", ["open"]),
                         (wait["status"], wait["statusLabel"], wait["can"]))
        self.assertEqual([{"requestId": "call_9", "kind": "command", "detail": "Wants to run: psql -f migrate.sql",
                           "options": []}], wait["pending"]["approvals"])
        self.assertEqual("working", codex["cli_open"]["status"])
        self.assertEqual(("idle", "Hit an error", "stream disconnected"),
                         (codex["cli_error"]["status"], codex["cli_error"]["statusLabel"],
                          codex["cli_error"]["summary"]))
        self.assertEqual(("done", "bump the version", ["reply", "open"]),
                         (codex["cli_done"]["status"], codex["cli_done"]["title"], codex["cli_done"]["can"]),
                         "a session filed under an older day is still read")
        # T3: settled and archived threads are not there; agents from the model's provider
        self.assertNotIn("t3:t-settled-error", items)
        self.assertNotIn("t3:t-archived", items)
        approval = items["t3:t-approval"]
        self.assertEqual(("needs-approval", "Wants to run a command", "npm test -- --watch=false", "SamRabbit",
                          "claude", ["approve", "reply", "stop", "open"]),
                         (approval["status"], approval["statusLabel"], approval["summary"], approval["project"],
                          approval["agent"], approval["can"]))
        self.assertEqual([{"requestId": "req-approve-1", "kind": "command", "detail": "npm test -- --watch=false",
                           "options": [dict(option) for option in t3.DEFAULT_APPROVAL_OPTIONS]}],
                         approval["pending"]["approvals"])
        question = items["t3:t-input"]
        self.assertEqual(("needs-input", "Has a question", ["answer", "reply", "stop", "open"]),
                         (question["status"], question["statusLabel"], question["can"]))
        self.assertEqual([{"requestId": "req-input-1", "questions": [
            {"id": "q1", "header": "Database", "question": "Which database should I use?",
             "options": ["SQLite", "Postgres"], "allowCustom": False, "multiSelect": False}]}],
            question["pending"]["inputs"])
        running = items["t3:t-running"]
        self.assertEqual(("working", "Working · step 2/4", 0.25, "Running unit tests", ["reply", "stop", "open"]),
                         (running["status"], running["statusLabel"], running["progress"], running["phase"],
                          running["can"]))
        self.assertEqual(("idle", "Failed", "The provider stopped unexpectedly."),
                         (items["t3:t-error"]["status"], items["t3:t-error"]["statusLabel"],
                          items["t3:t-error"]["summary"]),
                         "a failure from before the first look is seen like the rest: settled, not Needs you")
        self.assertEqual(("idle", "New"), (items["t3:t-new"]["status"], items["t3:t-new"]["statusLabel"]))
        self.assertEqual(("done", "Stopped"), (items["t3:t-stopped"]["status"], items["t3:t-stopped"]["statusLabel"]))
        self.assertEqual("/Users/test/jackrabbit-src", approval["cwd"], "a T3 thread runs in its project's folder")
        # The order: needs-approval, needs-input, error, done and unread, working, then the rest (newest first).
        groups = {"needs-approval": 0, "needs-input": 1, "error": 2}
        ranks = [(groups.get(item["status"], 3 if item["status"] == "done" and item["unread"] else
                             4 if item["status"] == "working" else 5), -t3.parse_time(item["updatedAt"]).timestamp())
                 for item in value["items"]]
        self.assertEqual(sorted(ranks), ranks)
        self.assertEqual("needs-approval", value["items"][0]["status"])
        needs = [item for item in value["items"] if item["status"] in ("needs-approval", "needs-input", "error")]
        self.assertEqual(len(needs), value["counts"]["needsYou"], "nothing is unread yet: the first look baselined")
        self.assertEqual(sum(1 for item in value["items"] if item["status"] == "working"), value["counts"]["working"])
        self.assertEqual(len(value["items"]), value["counts"]["total"])
        self.assertFalse(any(item["unread"] for item in value["items"]))
        # Nothing about any item reaches the log: no titles, prompts, answers, commands or folders.
        self.assert_log_clean(SECRET_TITLE, SECRET_PROMPT, SECRET_ANSWER, "5521", "rm -rf", "psql", CWD,
                              "release notes")

    def test_a_t3_thread_on_codex_is_a_codex_item_and_the_cap_is_sixty(self) -> None:
        with self.fake_t3.lock:
            for number in range(70):
                thread = _thread(f"t-bulk-{number:02d}", "p-site", f"Bulk {number}", minutes_ago=50)
                thread["modelSelection"] = {"instanceId": "codex_cli", "model": "gpt-6"}
                self.fake_t3.shell["threads"].append(thread)
        value = self.get_inbox()
        self.assertEqual(60, len(value["items"]), "at most 60 items")
        self.assertGreater(value["counts"]["total"], 60, "the counts are over everything")
        bulk = [item for item in value["items"] if item["id"].startswith("t3:t-bulk-")]
        self.assertTrue(bulk and all(item["agent"] == "codex" for item in bulk))
        self.assertEqual("needs-approval", value["items"][0]["status"], "the cap keeps what needs him")

    def test_an_unreadable_source_never_empties_the_others(self) -> None:
        self.build_world()
        self.fake_t3.refuse_tokens = True
        self.hub.invalidate()
        value = self.fresh()
        self.assertFalse(value["sources"]["t3"]["connected"])
        self.assertTrue(any(item["source"] == "claude" for item in value["items"]))
        self.assertFalse(any(item["source"] == "t3" for item in value["items"]))
        self.processes.broken = True  # ps failed: nobody can tell what is live, nothing breaks
        with self.inbox._lock:  # noqa: SLF001
            self.inbox._live = (-1e12, {})  # noqa: SLF001
        value = self.fresh()
        self.assertTrue(any(item["source"] == "codex" for item in value["items"]))

    def test_no_claude_or_codex_on_this_mac(self) -> None:
        import shutil
        shutil.rmtree(self.claude_root)
        for child in (self.codex_root / "sessions",):
            shutil.rmtree(child)
        value = self.fresh()
        self.assertEqual({"available": False, "reason": "not_installed"}, value["sources"]["claude"])
        self.assertEqual({"available": False, "reason": "not_installed"}, value["sources"]["codex"])

    def test_samrabbit_chats_are_the_six_newest_conversations(self) -> None:
        store = self.server.sync.store
        for number in range(8):
            conversation = f"c_chat{number:02d}abcdef"
            store.insert_events([{"id": f"e{number}", "type": "message.user", "conversationId": conversation,
                                  "at": int((NOW - 1000 + number) * 1000), "text": f"chat number {number}"}], "r1")
        store.record_local("mac-" + "a" * 32, {"type": "message.user", "text": "Mac: hello",
                                               "at": int((NOW - 10) * 1000)})
        store.insert_events([{"id": "draft", "type": "message.assistant.delta", "messageId": "m7",
                              "conversationId": "c_chat07abcdef", "at": int(NOW * 1000) - 2000,
                              "text": "partial"}], "r1")
        value = self.get_inbox()
        chats = [item for item in value["items"] if item["source"] == "samrabbit"]
        self.assertEqual(6, len(chats))
        by = {item["id"]: item for item in chats}
        mac = by["chat:mac-" + "a" * 32]
        self.assertEqual(("Mac", "idle", ["open"], None), (mac["project"], mac["status"], mac["can"], mac["agent"]))
        self.assertEqual("working", by["chat:c_chat07abcdef"]["status"], "an R1 reply still being written")
        self.assertEqual("R1", by["chat:c_chat07abcdef"]["project"])
        self.assertNotIn("chat:c_chat00abcdef", by)


# ====================================================================== the Codex folder is off limits


class CodexIsolationTest(InboxBase):
    def test_nothing_under_codex_but_the_rollouts_is_ever_opened_listed_or_stat_read(self) -> None:
        self.build_world()
        codex = str(self.codex_root)
        allowed = os.path.join(codex, "sessions")
        touched: List[str] = []

        def guard(name: str, real: Any) -> Any:
            def wrapper(path: Any, *args: Any, **kwargs: Any) -> Any:
                text = os.fspath(path) if isinstance(path, (str, bytes, os.PathLike)) else ""
                text = text.decode() if isinstance(text, bytes) else text
                if text and os.path.abspath(text).startswith(codex) and not \
                        os.path.abspath(text).startswith(allowed):
                    touched.append(f"{name} {text}")
                    raise PermissionError(text)
                return real(path, *args, **kwargs)
            return wrapper

        patches = {(builtins, "open"): builtins.open, (os, "open"): os.open, (os, "stat"): os.stat,
                   (os, "lstat"): os.lstat, (os, "listdir"): os.listdir, (os, "scandir"): os.scandir}
        for (module, name), real in patches.items():
            setattr(module, name, guard(name, real))
        try:
            value = self.fresh()
            for item in value["items"]:
                if item["source"] in ("codex", "claude"):
                    status, detail = self.call("GET", "/v1/desktop/inbox/items/" + item["id"], desktop=True)
                    self.assertEqual(200, status, detail)
        finally:
            for (module, name), real in patches.items():
                setattr(module, name, real)
        self.assertEqual([], touched)
        self.assertTrue(any(item["source"] == "codex" for item in value["items"]), "the rollouts were read")
        for name in ("auth.json", "config.toml", "session_index.jsonl"):
            self.assertEqual(0, stat.S_IMODE(os.lstat(self.codex_root / name).st_mode), "still chmod 000: unread")

    def test_a_symlink_is_never_followed_out_of_sessions(self) -> None:
        outside = self.root / "elsewhere"
        outside.mkdir()

        def rollout(folder: Path, name: str) -> Path:
            path = folder / f"rollout-2026-10-08T14-00-00-{IDS[name]}.jsonl"
            path.write_text("".join(json.dumps(record) + "\n" for record in (
                codex_meta(NOW - 100, IDS[name], originator="codex_cli_rs"),
                codex_event(NOW - 99, "user_message", message="from outside"),
                codex_event(NOW - 98, "task_complete", last_agent_message="ok"))))
            return path

        day = self.codex_root / "sessions" / "2026" / "10" / "08"
        day.mkdir(parents=True)
        link = day / f"rollout-2026-10-08T15-00-00-{IDS['cli_open']}.jsonl"
        link.symlink_to(rollout(outside, "cli_open"))  # a "rollout" that is really another file
        rollout(outside, "cli_wait")
        (self.codex_root / "sessions" / "2026" / "10" / "09").symlink_to(outside, target_is_directory=True)
        self.codex_session("cli_done", [codex_meta(NOW - 100, IDS["cli_done"], originator="codex_cli_rs"),
                                        codex_event(NOW - 99, "user_message", message="bump the version")])
        items = self.by_id(self.fresh())
        self.assertIn("codex:" + IDS["cli_done"], items, "a real rollout is read")
        self.assertNotIn("codex:" + IDS["cli_open"], items, "a symlinked rollout is not")
        self.assertNotIn("codex:" + IDS["cli_wait"], items, "nor a symlinked day folder")
        with self.assertRaises(OSError):
            inbox._read_head(str(link))  # noqa: SLF001 - opened without following, even when asked for


# ====================================================================== revisions and the long poll


class RevisionTest(InboxBase):
    def test_the_revision_moves_only_when_what_it_shows_changes(self) -> None:
        self.build_world()
        first = self.fresh()
        again = self.fresh()
        self.assertEqual(first["revision"], again["revision"], "nothing changed: the same revision")
        self.assertEqual(first["items"], again["items"])
        with self.fake_t3.lock:
            self.fake_t3.get_thread("t-running")["planProgress"]["completedSteps"] = 2
        self.hub.invalidate()
        moved = self.fresh()
        self.assertEqual(first["revision"] + 1, moved["revision"])
        self.assertEqual("Working · step 3/4", self.by_id(moved)["t3:t-running"]["statusLabel"])

    def test_a_bridge_started_again_is_past_every_revision_it_gave_out(self) -> None:
        self.build_world()
        first = self.fresh()
        self.assertGreater(first["revision"], int(NOW * 1000), "it starts from the time in ms")
        for number in range(3):
            self.claude_session("done", [claude_user(NOW - 10 + number, f"step {number}", session=IDS["done"])],
                                age=10 - number)
            self.fresh()
        before = self.get_inbox()["revision"]
        self.assertEqual(first["revision"] + 3, before)
        self.clock.advance(2)
        again = self.make_inbox()
        self.addCleanup(again.close)
        again.attach(self.server)
        self.server.inbox = again
        began = time.monotonic()
        value = self.get_inbox(f"?after={before}&wait=20")
        self.assertLess(time.monotonic() - began, 2.0, "a dock still waiting on the old bridge's revision gets the "
                                                       "new list at once, never a stale wait")
        self.assertGreater(value["revision"], before)

    def test_a_long_poll_wakes_up_when_something_changes(self) -> None:
        self.build_world()
        start = self.get_inbox()
        answers: List[Tuple[float, Dict[str, Any]]] = []

        def poll() -> None:
            began = time.monotonic()
            value = self.get_inbox(f"?after={start['revision']}&wait=20")
            answers.append((time.monotonic() - began, value))

        waiter = threading.Thread(target=poll)
        waiter.start()
        time.sleep(0.6)
        self.assertTrue(waiter.is_alive(), "it waits while nothing changes")
        path = self.project_dir / (IDS["done"] + ".jsonl")
        with open(path, "a") as handle:
            handle.write(json.dumps(claude_user(NOW, "one more thing", session=IDS["done"])) + "\n")
        os.utime(path, (NOW - 1, NOW - 1))
        waiter.join(timeout=15)
        self.assertFalse(waiter.is_alive())
        took, value = answers[0]
        self.assertLess(took, 10.0)
        self.assertEqual(start["revision"] + 1, value["revision"])
        self.assertEqual("working", self.by_id(value)["claude:" + IDS["done"]]["status"])

    def test_a_long_poll_with_nothing_new_answers_after_its_wait(self) -> None:
        start = self.get_inbox()
        began = time.monotonic()
        value = self.get_inbox(f"?after={start['revision']}&wait=1")
        self.assertGreaterEqual(time.monotonic() - began, 0.9)
        self.assertEqual(start["revision"], value["revision"])
        status, error = self.call("GET", "/v1/desktop/inbox?after=x", desktop=True)
        self.assertEqual((400, "invalid_query"), (status, error["error"]["code"]))
        began = time.monotonic()
        self.get_inbox("?after=0&wait=20")
        self.assertLess(time.monotonic() - began, 2.0, "an older revision answers at once")

    def test_the_background_refresher_wakes_a_long_poll(self) -> None:
        self.inbox.start()
        start = self.get_inbox()
        answers: List[Dict[str, Any]] = []
        waiter = threading.Thread(target=lambda: answers.append(
            self.get_inbox(f"?after={start['revision']}&wait=20")))
        waiter.start()
        time.sleep(0.3)
        self.claude_session("done", [claude_user(NOW - 3, "hello there", session=IDS["done"])], age=3)
        waiter.join(timeout=15)
        self.assertFalse(waiter.is_alive())
        self.assertIn("claude:" + IDS["done"], self.by_id(answers[0]))
        self.assertTrue(self.inbox._worker_alive(), "the refresher did it, not the waiting request")  # noqa: SLF001


# ====================================================================== seen and unread


class SeenTest(InboxBase):
    def test_finished_after_the_first_look_is_unread_until_seen_and_that_is_kept(self) -> None:
        self.build_world()
        first = self.get_inbox()
        self.assertFalse(any(item["unread"] for item in first["items"]), "the first look marks everything seen")
        # T3: a thread finishes later
        with self.fake_t3.lock:
            thread = self.fake_t3.get_thread("t-done")
            thread["latestTurn"]["completedAt"] = thread["updatedAt"] = "2026-10-08T18:30:00.000Z"
        self.hub.invalidate()
        # Claude: a session answers later
        path = self.project_dir / (IDS["done"] + ".jsonl")
        with open(path, "a") as handle:
            handle.write(json.dumps(claude_user(NOW - 100, "and the docs?", session=IDS["done"])) + "\n")
            handle.write(json.dumps(claude_text(NOW - 90, "Docs updated.", session=IDS["done"],
                                                message_id="msg_2")) + "\n")
        os.utime(path, (NOW - 90, NOW - 90))
        value = self.fresh()
        items = self.by_id(value)
        for item_id in ("t3:t-done", "claude:" + IDS["done"]):
            with self.subTest(item=item_id):
                self.assertTrue(items[item_id]["unread"])
                self.assertIn("seen", items[item_id]["can"])
        needs = [item["id"] for item in value["items"] if item["status"] == "done" and item["unread"]]
        self.assertEqual({"t3:t-done", "claude:" + IDS["done"]}, set(needs))
        self.assertEqual(len([item for item in value["items"] if inbox._needs_you(item)]),  # noqa: SLF001
                         value["counts"]["needsYou"])
        for item_id in ("t3:t-done", "claude:" + IDS["done"]):
            status, answer = self.act(item_id, "seen")
            self.assertEqual((200, {"ok": True}), (status, answer))
        items = self.by_id(self.fresh())
        self.assertFalse(items["t3:t-done"]["unread"])
        self.assertFalse(items["claude:" + IDS["done"]]["unread"])
        self.assertNotIn("seen", items["t3:t-done"]["can"])
        state = self.inbox_dir / inbox.STATE_FILE
        self.assertEqual(0o600, stat.S_IMODE(state.stat().st_mode))
        self.assertEqual(0o700, stat.S_IMODE(self.inbox_dir.stat().st_mode))
        saved = json.loads(state.read_text())
        self.assertEqual({"t3": True, "claude": True, "codex": True}, saved["baselines"])
        self.assertEqual("2026-10-08T18:30:00.000Z", saved["seen"]["t3:t-done"]["marker"])
        self.assertEqual([], [command for command in self.fake_t3.dispatched], "seen dispatches nothing to T3")
        # A bridge started again remembers.
        again = self.make_inbox()
        self.addCleanup(again.close)
        again.attach(self.server)
        self.server.inbox = again
        items = self.by_id(self.get_inbox())
        self.assertFalse(items["t3:t-done"]["unread"])


    def test_a_t3_failure_is_news_until_seen_then_settled_until_it_fails_again(self) -> None:
        # Samin: "if I say 'Mark as seen,' it should settle it, and I shouldn't be seeing it in 'Needs You.'"
        self.build_world()
        self.get_inbox()
        def fail_at(stamp: str) -> None:
            with self.fake_t3.lock:
                thread = self.fake_t3.get_thread("t-error")
                thread["latestTurn"]["completedAt"] = thread["updatedAt"] = stamp
            self.hub.invalidate()
        fail_at("2026-10-08T18:30:00.000Z")
        failed = self.by_id(self.fresh())["t3:t-error"]
        self.assertEqual(("error", True), (failed["status"], failed["unread"]))
        self.assertIn("seen", failed["can"])
        self.assertTrue(inbox._needs_you(failed))  # noqa: SLF001
        self.assertEqual((200, {"ok": True}), self.act("t3:t-error", "seen"))
        settled = self.by_id(self.fresh())["t3:t-error"]
        self.assertEqual(("idle", "Failed", False), (settled["status"], settled["statusLabel"], settled["unread"]))
        self.assertNotIn("seen", settled["can"])
        self.assertFalse(inbox._needs_you(settled))  # noqa: SLF001
        fail_at("2026-10-08T19:10:00.000Z")  # it ran and failed again: news again
        again = self.by_id(self.fresh())["t3:t-error"]
        self.assertEqual(("error", True), (again["status"], again["unread"]))


# ====================================================================== actions on T3 threads


class T3ActionTest(InboxBase):
    def dispatched(self, kind: str) -> List[Dict[str, Any]]:
        return [command for command in self.fake_t3.dispatched if command["type"] == kind]

    def test_approve_answer_reply_stop_dispatch_what_t3_expects(self) -> None:
        self.get_inbox()
        status, value = self.act("t3:t-approval", "approve", {"requestId": "req-approve-1", "decision": "accept"})
        self.assertEqual(200, status, value)
        self.assertEqual({"ok": True, "threadId": "t-approval", "requestId": "req-approve-1", "decision": "accept"},
                         value)
        [command] = self.dispatched("thread.approval.respond")
        self.assertEqual(("t-approval", "req-approve-1", "accept"),
                         (command["threadId"], command["requestId"], command["decision"]))
        self.assertRegex(command["commandId"], r"^[0-9a-f-]{36}$")
        status, value = self.act("t3:t-approval", "approve", {"requestId": "req-approve-1", "decision": "deny"})
        self.assertEqual("decline", self.dispatched("thread.approval.respond")[-1]["decision"])
        status, value = self.act("t3:t-approval", "approve", {"requestId": "req-approve-1",
                                                              "decision": "acceptForSession"})
        self.assertEqual("acceptForSession", self.dispatched("thread.approval.respond")[-1]["decision"])
        status, value = self.act("t3:t-approval", "approve", {"requestId": "req-gone", "decision": "accept"})
        self.assertEqual((409, "t3_request_not_pending"), (status, value["error"]["code"]))
        status, value = self.act("t3:t-approval", "approve", {"requestId": "req-approve-1"})
        self.assertEqual((400, "invalid_decision"), (status, value["error"]["code"]))
        # answer: the option's value, as T3 expects
        status, value = self.act("t3:t-input", "answer", {"requestId": "req-input-1", "answers": {"q1": "SQLite"}})
        self.assertEqual(200, status, value)
        [command] = self.dispatched("thread.user-input.respond")
        self.assertEqual(("t-input", "req-input-1", {"q1": "sqlite"}),
                         (command["threadId"], command["requestId"], command["answers"]))
        status, value = self.act("t3:t-input", "answer", {"requestId": "req-input-1", "answers": {}})
        self.assertEqual((400, "invalid_answers"), (status, value["error"]["code"]))
        # reply: a turn on the thread (202)
        status, value = self.act("t3:t-done", "reply", {"text": REPLY})
        self.assertEqual((202, {"ok": True, "how": "t3", "threadId": "t-done"}), (status, value))
        [command] = self.dispatched("thread.turn.start")
        self.assertEqual(("t-done", REPLY, "full-access"),
                         (command["threadId"], command["message"]["text"], command["runtimeMode"]))
        status, value = self.act("t3:t-done", "reply", {"text": "  "})
        self.assertEqual((400, "invalid_text"), (status, value["error"]["code"]))
        # stop: interrupt the active turn
        status, value = self.act("t3:t-running", "stop")
        self.assertEqual(200, status, value)
        [command] = self.dispatched("thread.turn.interrupt")
        self.assertEqual(("t-running", "turn-active-1"), (command["threadId"], command["turnId"]))
        # nothing to stop: no dispatch
        status, value = self.act("t3:t-done", "stop")
        self.assertEqual((200, False), (status, value["wasWorking"]))
        self.assertEqual(1, len(self.dispatched("thread.turn.interrupt")))
        status, value = self.act("t3:no-such-thread", "reply", {"text": "hi"})
        self.assertEqual(404, status, value)
        self.assert_log_clean(REPLY, "5521")

    def test_open_activates_t3_code(self) -> None:
        status, value = self.act("t3:t-done", "open")
        self.assertEqual((200, {"opened": True, "how": "app"}), (status, value))
        self.assertEqual([["/usr/bin/open", "-b", "com.t3tools.t3code"]], self.recorder.calls)

    def test_an_item_with_its_requests_and_last_messages(self) -> None:
        status, value = self.call("GET", "/v1/desktop/inbox/items/t3:t-approval", desktop=True)
        self.assertEqual(200, status, value)
        self.assertEqual({"item", "messages"}, set(value))
        self.assertEqual("t3:t-approval", value["item"]["id"])
        self.assertEqual(["req-approve-1"], [entry["requestId"] for entry in value["item"]["pending"]["approvals"]])
        self.assertEqual([("user", "Fix the login redirect please"), ("assistant", "I will run the tests first.")],
                         [(entry["role"], entry["text"]) for entry in value["messages"]],
                         "only user and assistant messages (no reasoning, no tool steps)")
        self.assertEqual("2026-10-08T12:50:00Z", value["messages"][0]["at"])
        # Encoded ids work too.
        status, again = self.call("GET", "/v1/desktop/inbox/items/t3%3At-approval", desktop=True)
        self.assertEqual((200, "t3:t-approval"), (status, again["item"]["id"]))
        status, value = self.call("GET", "/v1/desktop/inbox/items/bogus:1", desktop=True)
        self.assertEqual((404, "item_not_found"), (status, value["error"]["code"]))


# ====================================================================== Claude Code and Codex actions


class SessionActionTest(InboxBase):
    def setUp(self) -> None:
        super().setUp()
        self.build_world()
        self.get_inbox()

    def script_argv(self, index: int = -1) -> Tuple[str, List[str]]:
        text = self.recorder.scripts[index]
        lines = text.splitlines()
        self.assertEqual(["#!/bin/sh", 'rm -f "$0"'], lines[:2], "the script deletes itself first")
        self.assertTrue(lines[2].startswith("cd ") and lines[2].endswith(" || exit 1"))
        folder = shlex.split(lines[2][3:-len(" || exit 1")])[0]
        self.assertTrue(lines[3].startswith("exec "))
        return folder, shlex.split(lines[3][5:])

    def test_a_live_session_cannot_be_continued_from_here(self) -> None:
        for name in ("waiting", "busy"):
            status, value = self.act("claude:" + IDS[name], "reply", {"text": REPLY})
            self.assertEqual((409, "session_live"), (status, value["error"]["code"]), name)
        self.assertEqual([], self.recorder.calls)

    def test_reply_to_a_session_nobody_owns_resumes_it_in_terminal(self) -> None:
        status, value = self.act("claude:" + IDS["done"], "reply", {"text": REPLY})
        self.assertEqual((202, {"ok": True, "how": "terminal"}), (status, value))
        [call] = self.recorder.calls
        self.assertEqual(["/usr/bin/open", "-a", "Terminal"], call[:3])
        self.assertTrue(call[3].endswith(".command"))
        folder, argv = self.script_argv()
        self.assertEqual((CWD, ["/opt/test/bin/claude", "--resume", IDS["done"], "--", REPLY]), (folder, argv),
                         "-- ends the options: the reply is always the prompt")
        status, value = self.act("codex:" + IDS["cli_done"], "reply", {"text": REPLY})
        self.assertEqual(202, status, value)
        folder, argv = self.script_argv()
        self.assertEqual((CWD, ["/opt/test/bin/codex", "resume", IDS["cli_done"], "--", REPLY]), (folder, argv))
        status, value = self.act("codex:" + IDS["desk"], "reply", {"text": REPLY})
        self.assertEqual((409, "unsupported_action"), (status, value["error"]["code"]), "Codex Desktop owns it")
        status, value = self.act("claude:" + IDS["done"], "approve", {"decision": "accept"})
        self.assertEqual((409, "unsupported_action"), (status, value["error"]["code"]))
        self.assert_log_clean(REPLY, "5521", CWD)

    def test_a_reply_that_looks_like_an_option_is_still_the_prompt(self) -> None:
        for text in ("-p --dangerously-skip-permissions", "- also add a test"):
            with self.subTest(text=text):
                status, value = self.act("claude:" + IDS["failed"], "reply", {"text": text})
                self.assertEqual(202, status, value)
                _folder, argv = self.script_argv()
                self.assertEqual(["/opt/test/bin/claude", "--resume", IDS["failed"], "--", text], argv)
                self.clock.advance(inbox.LAUNCH_GRACE_SECONDS + 1)
        status, value = self.act("codex:" + IDS["cli_done"], "reply", {"text": "-m gpt-0 do it"})
        self.assertEqual(202, status, value)
        self.assertEqual(["/opt/test/bin/codex", "resume", IDS["cli_done"], "--", "-m gpt-0 do it"],
                         self.script_argv()[1])

    def test_a_session_just_resumed_is_never_started_twice(self) -> None:
        item_id = "claude:" + IDS["done"]
        status, value = self.act(item_id, "reply", {"text": REPLY})
        self.assertEqual(202, status, value)
        item = self.by_id(self.get_inbox())[item_id]
        self.assertEqual((True, ["open"]), (item["live"], item["can"]),
                         "its Terminal window is starting: live before ps can see the CLI")
        status, value = self.act(item_id, "reply", {"text": REPLY})
        self.assertEqual((409, "session_live"), (status, value["error"]["code"]), "a second press")
        status, value = self.act(item_id, "open")
        self.assertEqual((200, {"opened": True, "how": "terminal"}), (status, value))
        self.assertEqual(["/usr/bin/open", "-b", "com.apple.Terminal"], self.recorder.calls[-1],
                         "Open brings that window's Terminal forward instead of resuming it again")
        self.assertEqual(1, len(self.recorder.scripts), "one CLI on the session file")
        self.clock.advance(inbox.LAUNCH_GRACE_SECONDS + 1)
        status, value = self.act(item_id, "open")
        self.assertEqual(2, len(self.recorder.scripts), "later (nobody owns it in ps): resumed again")

    def test_when_ps_fails_no_second_cli_is_ever_started(self) -> None:
        # "busy" runs in a plain `claude` that only `ps` shows: with ps down, nobody can tell it is live.
        self.processes.broken = True
        with self.inbox._lock:  # noqa: SLF001
            self.inbox._live = (-1e12, {})  # noqa: SLF001
        items = self.by_id(self.fresh())
        for item_id in ("claude:" + IDS["busy"], "claude:" + IDS["done"], "codex:" + IDS["cli_done"]):
            with self.subTest(item=item_id):
                self.assertNotIn("reply", items[item_id]["can"], "no reply that would resume it in a new CLI")
                status, value = self.act(item_id, "reply", {"text": REPLY})
                self.assertEqual((503, "session_check_failed", True),
                                 (status, value["error"]["code"], value["error"]["retryable"]))
        self.assertEqual([], self.recorder.calls, "nothing was started")
        status, value = self.act("claude:" + IDS["busy"], "open")
        self.assertEqual((200, {"opened": True, "how": "terminal"}), (status, value))
        self.assertEqual([["/usr/bin/open", "-b", "com.apple.Terminal"]], self.recorder.calls,
                         "Open brings Terminal forward instead of resuming the session again")
        self.assertEqual([], self.recorder.scripts)
        self.processes.broken = False  # ps works again: a session nobody owns resumes as before
        self.assertIn("reply", self.by_id(self.fresh())["claude:" + IDS["done"]]["can"])
        self.assertEqual(202, self.act("claude:" + IDS["done"], "reply", {"text": REPLY})[0])
        self.assertEqual(1, len(self.recorder.scripts))

    def test_a_live_codex_cli_is_answered_where_it_runs(self) -> None:
        self.processes.add(5100, "codex resume " + IDS["cli_done"], app="/Applications/Ghostty.app")
        self.processes.add(5200, "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/"
                                 "codex resume " + IDS["cli_error"], app="/Applications/ChatGPT.app")
        items = self.by_id(self.fresh())
        live = items["codex:" + IDS["cli_done"]]
        self.assertEqual((True, ["open"]), (live["live"], live["can"]))
        self.assertFalse(items["codex:" + IDS["cli_error"]]["live"], "the ChatGPT app's own codex is not a terminal")
        status, value = self.act("codex:" + IDS["cli_done"], "reply", {"text": REPLY})
        self.assertEqual((409, "session_live"), (status, value["error"]["code"]))
        status, value = self.act("codex:" + IDS["cli_done"], "open")
        self.assertEqual((200, {"opened": True, "how": "terminal"}), (status, value))
        self.assertEqual([["/usr/bin/open", "-a", "/Applications/Ghostty.app"]], self.recorder.calls,
                         "the app its terminal runs in")
        status, value = self.act("codex:" + IDS["cli_error"], "reply", {"text": REPLY})
        self.assertEqual(202, status, value)

    def test_a_folder_that_is_gone_is_said_so(self) -> None:
        import shutil
        shutil.rmtree(self.cwd)
        status, value = self.act("claude:" + IDS["done"], "reply", {"text": REPLY})
        self.assertEqual((409, "folder_missing"), (status, value["error"]["code"]))
        self.assertEqual([], self.recorder.calls)

    def test_open_goes_where_each_session_lives(self) -> None:
        cases = [
            ("claude:" + IDS["waiting"], {"opened": True, "how": "terminal"}, ["/usr/bin/open", "-a",
                                                                               "/Applications/iTerm.app"]),
            ("claude:" + IDS["busy"], {"opened": True, "how": "terminal"}, ["/usr/bin/open", "-b",
                                                                            "com.apple.Terminal"]),
            ("codex:" + IDS["desk"], {"opened": True, "how": "deeplink"},
             ["/usr/bin/open", "codex://threads/" + IDS["desk"]]),
        ]
        for item_id, answer, command in cases:
            with self.subTest(item=item_id):
                self.recorder.calls.clear()
                status, value = self.act(item_id, "open")
                self.assertEqual((200, answer), (status, value))
                self.assertEqual([command], self.recorder.calls)
        self.recorder.calls.clear()
        status, value = self.act("claude:" + IDS["done"], "open")
        self.assertEqual((200, {"opened": True, "how": "terminal"}), (status, value))
        self.assertEqual((CWD, ["/opt/test/bin/claude", "--resume", IDS["done"]]), self.script_argv())
        status, value = self.act("codex:" + IDS["cli_done"], "open")
        self.assertEqual((CWD, ["/opt/test/bin/codex", "resume", IDS["cli_done"]]), self.script_argv())
        self.recorder.calls.clear()
        store = self.server.sync.store
        store.insert_events([{"id": "c1", "type": "message.user", "conversationId": "c_open0123456789",
                              "at": int(NOW * 1000), "text": "hi"}], "r1")
        self.inbox.refresh(force=True)
        status, value = self.act("chat:c_open0123456789", "open")
        self.assertEqual((200, {"opened": True, "how": "desktop", "conversationId": "c_open0123456789"}),
                         (status, value))
        self.assertEqual([], self.recorder.calls, "a chat opens in the desktop app itself")
        status, value = self.act("chat:c_open0123456789", "reply", {"text": "hi"})
        self.assertEqual((409, "unsupported_action"), (status, value["error"]["code"]))

    def test_the_scripts_are_private_and_removed(self) -> None:
        self.act("claude:" + IDS["done"], "open")
        [script] = [Path(call[-1]) for call in self.recorder.calls]
        self.assertTrue(script.exists())
        self.assertEqual(0o700, stat.S_IMODE(script.parent.stat().st_mode))
        self.inbox.launcher.close()
        self.assertFalse(script.exists(), "a script Terminal never ran is removed")

    def test_item_messages_for_claude_and_codex(self) -> None:
        status, value = self.call("GET", "/v1/desktop/inbox/items/claude:" + IDS["done"], desktop=True)
        self.assertEqual(200, status, value)
        self.assertEqual([("user", SECRET_PROMPT), ("assistant", "Looking at it.\n\n" + SECRET_ANSWER)],
                         [(entry["role"], entry["text"]) for entry in value["messages"]],
                         "one answer's blocks are one message")
        status, value = self.call("GET", "/v1/desktop/inbox/items/codex:" + IDS["desk"], desktop=True)
        self.assertEqual([("user", "Draft the release notes"), ("assistant", "Here are the release notes.")],
                         [(entry["role"], entry["text"]) for entry in value["messages"]],
                         "the words Samin typed, without what Codex injected")
        status, value = self.call("GET", "/v1/desktop/inbox/items/codex:" + IDS["cli_done"], desktop=True)
        self.assertEqual([("user", "bump the version")], [(entry["role"], entry["text"])
                                                           for entry in value["messages"]])
        status, value = self.call("GET", "/v1/desktop/inbox/items/claude:" + IDS["sdk"], desktop=True)
        self.assertEqual((404, "item_not_found"), (status, value["error"]["code"]), "a T3 session is not an item")

    def test_a_copy_that_is_not_the_installed_one_opens_nothing(self) -> None:
        dry = inbox.make_service(installed=False)
        self.addCleanup(dry.close)
        self.assertTrue(dry.launcher.dry_run)
        self.assertIsNone(dry.state_dir, "what it saw stays in memory")
        dry.home = str(self.home)
        dry.claude = inbox.ClaudeSessions(str(self.claude_root))
        dry.codex = inbox.CodexSessions(str(self.codex_root / "sessions"))
        dry.processes = self.processes
        dry._clock = self.clock.time  # noqa: SLF001
        dry.attach(self.server)
        self.server.inbox = dry
        dry.refresh(force=True)
        status, value = self.act("claude:" + IDS["done"], "open")
        self.assertEqual((200, {"opened": True, "how": "terminal", "dryRun": True}), (status, value))
        status, value = self.act("t3:t-done", "open")
        self.assertEqual((200, {"opened": True, "how": "app", "dryRun": True}), (status, value))
        self.assertEqual([], self.recorder.calls)
        launching = inbox.make_service(installed=False, launch=True)
        self.addCleanup(launching.close)
        self.assertFalse(launching.launcher.dry_run, "--inbox-launch lets a dev copy open things")


# ====================================================================== new tasks


class NewTaskTest(InboxBase):
    def test_targets_are_t3s_projects_and_the_providers_it_offers(self) -> None:
        status, value = self.call("GET", "/v1/desktop/inbox/targets", desktop=True)
        self.assertEqual(200, status, value)
        self.assertEqual({"projects", "agents", "default"}, set(value))
        self.assertNotIn("p-scratch", [project["id"] for project in value["projects"]], "no scratch project")
        self.assertEqual("p-agent", value["projects"][0]["id"], "most recently active first")
        self.assertRegex(value["projects"][0]["lastActiveAt"], r"Z$")
        agents = {agent["id"]: agent for agent in value["agents"]}
        self.assertEqual({"claude", "codex"}, set(agents))
        self.assertEqual("Claude", agents["claude"]["label"])
        self.assertEqual([{"id": "claude-opus-5-5", "label": "Claude Opus 5.5"},
                          {"id": "claude-sonnet-5-5", "label": "Claude Sonnet 5.5"},
                          {"id": "claude-fable-5-1", "label": "Claude Fable 5.1"}], agents["claude"]["models"],
                         "legacy models are left out")
        self.assertEqual(["gpt-6.1", "gpt-6"], [model["id"] for model in agents["codex"]["models"]],
                         "the Codex instance that is installed, not the one that is not")
        self.assertEqual({"projectId": "p-agent", "agent": "claude", "model": "claude-opus-5-5"}, value["default"])
        self.assertEqual(["server.getConfig", "Pong"], self.fake_t3.ws_requests)
        self.call("GET", "/v1/desktop/inbox/targets", desktop=True)
        self.assertEqual(2, len(self.fake_t3.ws_requests), "the provider list is cached")

    def test_without_the_provider_list_the_threads_show_what_runs(self) -> None:
        self.fake_t3.ws_status = 404
        with self.fake_t3.lock:
            thread = _thread("t-codex", "p-site", "On Codex", minutes_ago=0)
            thread["modelSelection"] = {"instanceId": "codex_cli", "model": "gpt-6.1"}
            self.fake_t3.shell["threads"].append(thread)
        status, value = self.call("GET", "/v1/desktop/inbox/targets", desktop=True)
        self.assertEqual(200, status, value)
        agents = {agent["id"]: agent for agent in value["agents"]}
        self.assertEqual(["gpt-6.1"], [model["id"] for model in agents["codex"]["models"]])
        self.assertEqual("claude-opus-5-5", agents["claude"]["models"][0]["id"])
        self.assertEqual({"projectId": "p-site", "agent": "codex", "model": "gpt-6.1"}, value["default"])
        self.assertEqual({"paired": True, "ok": True}, {key: self.hub.status()[key] for key in ("paired", "ok")},
                         "a T3 without the WebSocket RPC does not count as failing")

    def test_new_with_project_agent_and_model(self) -> None:
        status, value = self.call("POST", "/v1/desktop/inbox/new",
                                  {"text": SECRET_PROMPT, "projectId": "p-site", "agent": "codex", "model": "gpt-6.1",
                                   "title": "Release prep"}, desktop=True)
        self.assertEqual(202, status, value)
        self.assertEqual("t3:" + value["threadId"], value["itemId"])
        self.assertEqual(("p-site", "Website", "chosen", "codex", "gpt-6.1"),
                         (value["projectId"], value["projectName"], value["placement"], value["agent"],
                          value["model"]))
        create, turn = self.fake_t3.dispatched[-2:]
        self.assertEqual(("thread.create", "p-site", "Release prep", {"instanceId": "codex_cli", "model": "gpt-6.1"}),
                         (create["type"], create["projectId"], create["title"], create["modelSelection"]))
        self.assertEqual(("thread.turn.start", SECRET_PROMPT, {"instanceId": "codex_cli", "model": "gpt-6.1"}),
                         (turn["type"], turn["message"]["text"], turn["modelSelection"]))
        items = self.by_id(self.fresh())
        self.assertEqual(("working", "codex"), (items[value["itemId"]]["status"], items[value["itemId"]]["agent"]),
                         "the new task shows under Working at once")
        # An agent alone: its default model on the instance it runs on.
        status, value = self.call("POST", "/v1/desktop/inbox/new", {"text": "check the build", "agent": "claude"},
                                  desktop=True)
        self.assertEqual(202, status, value)
        self.assertEqual({"instanceId": "claudeAgent", "model": "claude-opus-5-5"},
                         self.fake_t3.dispatched[-2]["modelSelection"])
        # Neither: the phone's own path (placement, the project's last model).
        status, value = self.call("POST", "/v1/desktop/inbox/new", {"text": "Tell me a joke"}, desktop=True)
        self.assertEqual(202, status, value)
        self.assertEqual(("p-agent", "orchestration"), (value["projectId"], value["placement"]))
        self.assertEqual({"instanceId": "claudeAgent", "model": "claude-opus-5-5"},
                         self.fake_t3.dispatched[-2]["modelSelection"])
        for body, code in (({"text": "x", "agent": "gemini"}, "invalid_agent"),
                           ({"text": "x", "agent": "codex", "model": "claude-opus-5-5"}, "invalid_model"),
                           ({"text": "x", "model": "bad model!"}, "invalid_model"),
                           ({"text": "x", "projectId": "nope"}, "invalid_project"),
                           ({"text": " "}, "invalid_request")):
            with self.subTest(body=body):
                status, value = self.call("POST", "/v1/desktop/inbox/new", body, desktop=True)
                self.assertEqual((400, code), (status, value["error"]["code"]))
        self.assert_log_clean(SECRET_PROMPT, "5521", "Release prep")


# ====================================================================== the pieces on their own


class ProcessesTest(unittest.TestCase):
    PS = "\n".join([
        "    1     0 Wed Oct  1 09:00:00 2026 /sbin/launchd",
        "  500     1 Wed Oct  8 18:00:00 2026 /System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal",
        "  510   500 Wed Oct  8 18:00:01 2026 login -pf test",
        "  511   510 Wed Oct  8 18:00:01 2026 -zsh",
        "  520   511 Wed Oct  8 18:30:00 2026 claude",
        "  600     1 Wed Oct  8 17:00:00 2026 /Applications/T3 Code (Alpha).app/Contents/MacOS/T3 Code (Alpha)",
        "  610   600 Wed Oct  8 17:00:01 2026 /bin/zsh -il",
        "  620   610 Wed Oct  8 17:10:00 2026 /Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/"
        "Contents/MacOS/codex resume 11111111-2222-3333-4444-555555555555",
        "  700     1 Wed Oct  8 16:00:00 2026 /opt/homebrew/bin/tmux new -s work",
        "  710   700 Wed Oct  8 16:00:01 2026 claude --resume 00000000-0000-0000-0000-000000000002",
        "  800     1 Wed Oct  8 16:00:00 2026 /Users/test/.local/bin/claude -p --model x",
        "  900     1 Wed Oct  8 16:00:00 2026 /Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/"
        "Contents/MacOS/codex app-server --listen stdio",
        "  950     1 Wed Oct  8 16:00:00 2026 /Users/test/Library/Application Support/iTerm2/iTermServer-3.5.0 x",
        "  951   950 Wed Oct  8 16:00:01 2026 -zsh",
        "  952   951 Wed Oct  8 16:00:02 2026 node /usr/local/lib/node_modules/@openai/codex/bin/codex.js",
        "  953   951 Wed Oct  8 16:00:03 2026 node /usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js",
        "  960   1 Wed Oct  8 16:00:00 2026 /Applications/ChatGPT.app/Contents/MacOS/ChatGPT",
        "  961   960 Wed Oct  8 16:00:01 2026 /Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/"
        "Contents/MacOS/codex -c features.x=true -c y=\"z\" app-server",
        "  962   951 Wed Oct  8 16:00:04 2026 codex -m gpt-6 --full-auto fix the tests"]) + "\n"

    def make(self) -> inbox.Processes:
        table = self

        class Canned(inbox.Processes):
            calls: List[List[str]] = []

            @staticmethod
            def _output(argv: List[str]) -> Optional[str]:
                Canned.calls.append(argv)
                if argv[0].endswith("ps") and "-p" in argv:
                    return "  520 Wed Oct  8 18:30:00 2026\n"
                if argv[0].endswith("ps"):
                    return table.PS
                return "p520\nfcwd\nn/Users/test/code/app\n"
        return Canned(monotonic=time.monotonic)

    def test_ps_lsof_and_the_hosting_app(self) -> None:
        processes = self.make()
        table = processes.table()
        self.assertEqual("/Applications/T3 Code (Alpha).app/Contents/MacOS/T3 Code (Alpha)", table[600].args)
        self.assertEqual("Wed Oct 8 18:30:00 2026", table[520].started, "lstart with its double space normalized")
        self.assertEqual("claude --resume 00000000-0000-0000-0000-000000000002", table[710].args)
        self.assertEqual("/System/Applications/Utilities/Terminal.app", processes.app_of(520))
        self.assertEqual("/Applications/T3 Code (Alpha).app", processes.app_of(620),
                         "the codex binary sits inside an app itself: its parents decide")
        self.assertEqual("/Applications/iTerm.app", processes.app_of(952), "iTerm's shells hang off iTermServer")
        self.assertIsNone(processes.app_of(710), "tmux has no app")
        self.assertEqual("/Users/test/code/app", processes.cwd(table[520]))
        processes.cwd(table[520])
        self.assertEqual(1, sum(1 for argv in type(processes).calls if "lsof" in argv[0]), "a cwd is read once")
        self.assertEqual({520: "Wed Oct 8 18:30:00 2026"}, processes.started([520, 4242]))
        before = sum(1 for argv in type(processes).calls if "-axww" in argv)
        processes.table()
        self.assertEqual(before, sum(1 for argv in type(processes).calls if "-axww" in argv),
                         "the whole table at most every 30 s")
        self.assertEqual({520, 710, 953}, {pid for pid, item in table.items()
                                           if inbox._is_claude_cli(item)},  # noqa: SLF001
                         "claude -p is not an interactive session")
        self.assertEqual({620, 952, 962}, {pid for pid, item in table.items()
                                           if inbox._is_codex_cli(item)},  # noqa: SLF001
                         "the app-server is Codex Desktop's (or T3's), not a CLI, wherever its options put it")
        self.assertEqual("/Applications/ChatGPT.app", processes.app_of(961, table))

    def test_which_codex_sessions_are_kept(self) -> None:
        kept = inbox._codex_kept  # noqa: SLF001
        self.assertIs(True, kept({"originator": "Codex Desktop", "source": "vscode"}))
        self.assertIs(False, kept({"originator": "codex_cli_rs", "source": "cli"}))
        self.assertIs(False, kept({"originator": "codex-tui", "source": "cli"}))
        for meta in ({"originator": "T3 Code", "source": "vscode"}, {"originator": "codex_exec", "source": "exec"},
                     {"originator": "codex_cli_rs", "source": {"subagent": {"thread_spawn": {}}}},
                     {"originator": "codex_cli_rs", "source": "subAgentReview"},
                     {"originator": "codex_cli_rs", "source": "cli", "thread_source": "guardian_review"},
                     {"originator": "codex_vscode", "source": "vscode"}, {"originator": "agentbox"}):
            with self.subTest(meta=meta):
                self.assertIsNone(kept(meta))


class ParsingTest(InboxBase):
    def test_sidechains_a_huge_first_message_and_bypass_mode(self) -> None:
        t = NOW
        self.claude_session("done", [
            claude_user(t - 100, "write the parser", session=IDS["done"]),
            claude_text(t - 90, "Done with the parser.", session=IDS["done"]),
            claude_tool(t - 80, "Bash", {"command": "ls"}, session=IDS["done"], isSidechain=True)], age=80)
        huge = claude_user(t - 50, "look at this " + "A" * 200_000, session=IDS["waiting"])
        self.claude_session("waiting", [huge, claude_text(t - 40, "I see it.", session=IDS["waiting"])], age=40)
        self.claude_session("busy", [
            {"type": "permission-mode", "sessionId": IDS["busy"], "permissionMode": "bypassPermissions"},
            claude_user(t - 30, "run everything", session=IDS["busy"]),
            claude_tool(t - 20, "Bash", {"command": "make all"}, session=IDS["busy"])], age=20)
        self.processes.add(4500, "claude --resume " + IDS["busy"])
        items = self.by_id(self.get_inbox())
        self.assertEqual(("done", "Done with the parser."), (items["claude:" + IDS["done"]]["status"],
                                                             items["claude:" + IDS["done"]]["summary"]),
                         "a subagent's tool call (a sidechain) is not the session's")
        big = items["claude:" + IDS["waiting"]]
        self.assertEqual("done", big["status"], "a first message bigger than the head: the tail says cli")
        self.assertTrue(big["title"].startswith("look at this AAA"))
        self.assertLessEqual(len(big["title"]), inbox.MAX_TITLE_CHARS)
        self.assertEqual(("working", True), (items["claude:" + IDS["busy"]]["status"],
                                             items["claude:" + IDS["busy"]]["live"]),
                         "with permissions bypassed an unanswered call is a command still running")

    def test_an_unchanged_file_is_not_read_again(self) -> None:
        self.build_world()
        reads: List[str] = []
        real = inbox._read_tail  # noqa: SLF001

        def counting(path: str, size: int, limit: int) -> Any:
            reads.append(path)
            return real(path, size, limit)

        inbox._read_tail = counting  # noqa: SLF001
        try:
            self.fresh()
            first = len(reads)
            self.fresh()
            self.assertEqual(first, len(reads), "nothing changed: nothing read")
            path = self.project_dir / (IDS["done"] + ".jsonl")
            with open(path, "a") as handle:
                handle.write(json.dumps(claude_user(NOW, "more", session=IDS["done"])) + "\n")
            self.fresh()
            self.assertEqual([str(path)], reads[first:], "only the file that changed")
        finally:
            inbox._read_tail = real  # noqa: SLF001
        self.assertEqual(0, sum(1 for path in reads if IDS["sdk"] in path), "a T3 session is never read past its head")


class CodexFormatTest(InboxBase):
    """Rollouts as the Codex installed on this Mac writes them today (no ``user_message`` / ``agent_message`` /
    ``error`` / approval events at all)."""

    def test_the_title_lies_past_a_hundred_kb_of_instructions(self) -> None:
        t = NOW
        path = self.codex_session("desk", desktop_head(t - 700, IDS["desk"]) +
                                  desktop_turn(t - 690, "Draft the release notes", "Here are the release notes."),
                                  age=600)
        self.assertGreater(path.read_bytes().find(b"Draft the release notes"), inbox.HEAD_BYTES,
                           "like the real thing: what he typed starts past the old head")
        # A thread being written: only the instructions are there yet; what he typed comes next.
        fresh = self.codex_session("cli_open", desktop_head(t - 20, IDS["cli_open"]), age=19)
        # A first message bigger than a record is read (a pasted image after the words) ...
        self.codex_session("cli_wait", desktop_head(t - 300, IDS["cli_wait"]) + [
            codex_event(t - 290, "task_started"),
            codex_line("response_item", t - 290, {"type": "message", "role": "user", "content": [
                {"type": "input_text", "text": "Make the logo bigger"},
                {"type": "input_image", "image_url": "data:image/png;base64," + "Q" * 400_000}]}),
            codex_event(t - 280, "task_complete", last_agent_message="Done.")], age=280)
        # ... and one whose words come after the image: the item_completed event has them (the image as a path).
        self.codex_session("cli_done", desktop_head(t - 400, IDS["cli_done"]) + [
            codex_event(t - 390, "task_started"),
            codex_line("response_item", t - 390, {"type": "message", "role": "user", "content": [
                {"type": "input_image", "image_url": "data:image/png;base64," + "Q" * 400_000},
                {"type": "input_text", "text": "Crop this screenshot"}]}),
            codex_event(t - 390, "item_completed", item={"type": "UserMessage", "id": "u", "content": [
                {"type": "local_image", "path": "/tmp/shot.png"}, {"type": "text", "text": "Crop this screenshot"}]}),
            codex_event(t - 380, "task_complete", last_agent_message="Cropped.")], age=380)
        items = self.by_id(self.get_inbox())
        desk = items["codex:" + IDS["desk"]]
        self.assertEqual(("Draft the release notes", "done", "Finished", "Here are the release notes.", ["open"]),
                         (desk["title"], desk["status"], desk["statusLabel"], desk["summary"], desk["can"]))
        self.assertEqual("Codex thread", items["codex:" + IDS["cli_open"]]["title"], "nothing typed yet")
        self.assertEqual("Make the logo bigger", items["codex:" + IDS["cli_wait"]]["title"])
        self.assertEqual("Crop this screenshot", items["codex:" + IDS["cli_done"]]["title"])
        self.append(fresh, desktop_turn(t - 10, "Rename the config flag"), age=9)
        items = self.by_id(self.fresh())
        self.assertEqual("Rename the config flag", items["codex:" + IDS["cli_open"]]["title"],
                         "the search goes on where it stopped once the thread has more")
        reads: List[int] = []
        real = inbox._open_file  # noqa: SLF001

        def counting(path: str) -> Any:
            reads.append(1)
            return real(path)

        inbox._open_file = counting  # noqa: SLF001
        try:
            self.fresh()
        finally:
            inbox._open_file = real  # noqa: SLF001
        self.assertEqual([], reads, "found once, never looked for again")

    def test_a_failed_turn_needs_him_until_he_saw_it(self) -> None:
        t = NOW
        path = self.codex_session("desk", desktop_head(t - 900, IDS["desk"]) +
                                  desktop_turn(t - 890, "Draft the release notes", "Here they are."), age=880)
        cli = self.codex_session("cli_error", [
            codex_meta(t - 900, IDS["cli_error"], originator="codex_cli_rs"),
            codex_event(t - 899, "user_message", message="deploy it"),
            codex_event(t - 898, "task_complete", last_agent_message="Deployed.")], age=898)
        self.get_inbox()  # the first look
        self.append(path, desktop_turn(t - 100, "And the changelog", error="stream disconnected before completion"),
                    age=94)
        self.append(cli, [codex_event(t - 60, "user_message", message="and roll it back"),
                          codex_event(t - 59, "task_started"),
                          codex_event(t - 50, "error", message="sandbox denied"),
                          codex_event(t - 40, "turn_aborted", reason="interrupted")], age=40)
        value = self.fresh()
        desk = self.by_id(value)["codex:" + IDS["desk"]]
        self.assertEqual(("error", "Hit an error", "stream disconnected before completion", True),
                         (desk["status"], desk["statusLabel"], desk["summary"], desk["unread"]),
                         "a task_complete with an error is a failure, not Finished")
        self.assertEqual(["open", "seen"], desk["can"])
        self.assertTrue(inbox._needs_you(desk))  # noqa: SLF001
        stopped = self.by_id(value)["codex:" + IDS["cli_error"]]
        self.assertEqual(("idle", "Stopped"), (stopped["status"], stopped["statusLabel"]),
                         "Esc after an error: the turn is over, nothing is left to fix")
        needs = value["counts"]["needsYou"]
        status, answer = self.act("codex:" + IDS["desk"], "seen")
        self.assertEqual((200, {"ok": True}), (status, answer))
        value = self.fresh()
        desk = self.by_id(value)["codex:" + IDS["desk"]]
        self.assertEqual(("idle", "Hit an error", False, ["open"]),
                         (desk["status"], desk["statusLabel"], desk["unread"], desk["can"]),
                         "seen: it no longer needs him, and still says what happened")
        self.assertEqual(needs - 1, value["counts"]["needsYou"])
        # Claude Code too: an API error stops needing him once seen; a new one needs him again.
        claude = self.claude_session("failed", [claude_user(t - 900, "summarize the logs", session=IDS["failed"]),
                                                claude_text(t - 890, "Summary.", session=IDS["failed"])], age=890)
        self.fresh()
        self.append(claude, [claude_user(t - 80, "and the errors?", session=IDS["failed"]),
                             claude_record("assistant", t - 79, session=IDS["failed"], isApiErrorMessage=True,
                                           message={"id": "e", "role": "assistant", "model": "<synthetic>",
                                                    "content": [{"type": "text", "text": "API Error: overloaded"}],
                                                    "stop_reason": "stop_sequence"})], age=79)
        item = self.by_id(self.fresh())["claude:" + IDS["failed"]]
        self.assertEqual(("error", True), (item["status"], item["unread"]))
        self.assertIn("seen", item["can"])
        self.act(item["id"], "seen")
        item = self.by_id(self.fresh())["claude:" + IDS["failed"]]
        self.assertEqual(("idle", "Hit an error", "API Error: overloaded"),
                         (item["status"], item["statusLabel"], item["summary"]))

    def test_a_quiet_tool_call_may_be_a_prompt_only_when_approvals_are_on(self) -> None:
        t = NOW

        def calling(name: str, at: float, **call: Any) -> List[Dict[str, Any]]:
            return desktop_turn(at, "Run the migration")[:-1] + [codex_line("response_item", at + 1, {
                "type": call.pop("kind", "custom_tool_call"), "name": name, "call_id": "call_" + name, **call})]

        self.codex_session("desk", desktop_head(t - 100, IDS["desk"], policy="on-request") +
                           calling("exec", t - 90, input="psql -f migrate.sql", status="in_progress"), age=60)
        self.codex_session("cli_done", desktop_head(t - 100, IDS["cli_done"], policy="never") +
                           calling("exec", t - 90, input="make all", status="in_progress"), age=60)
        self.codex_session("cli_open", desktop_head(t - 100, IDS["cli_open"], policy="on-request") +
                           calling("wait_agent", t - 90, kind="function_call", arguments='{"timeout_ms": 60000}'),
                           age=60)
        self.codex_session("cli_error", desktop_head(t - 100, IDS["cli_error"], policy="on-request") +
                           calling("exec", t - 90, input="ls", status="in_progress"), age=10)
        self.codex_session("cli_wait", [
            codex_meta(t - 100, IDS["cli_wait"], originator="codex_cli_rs"),
            codex_line("turn_context", t - 99, {"cwd": CWD, "approval_policy": "on-request"}),
            codex_event(t - 99, "user_message", message="migrate it"),
            codex_event(t - 98, "task_started"),
            codex_line("response_item", t - 97, {"type": "function_call", "name": "shell", "call_id": "call_s",
                                                 "arguments": json.dumps({"command": ["psql", "-f", "x.sql"]})})],
            age=60)
        self.processes.add(5100, "codex resume " + IDS["cli_wait"], app="/Applications/Ghostty.app")
        items = self.by_id(self.get_inbox())
        desk = items["codex:" + IDS["desk"]]
        self.assertEqual(("needs-approval", "May be waiting for you in Codex", "Wants to run a command"),
                         (desk["status"], desk["statusLabel"], desk["summary"]),
                         "Codex writes no approval request: a quiet open call, approvals on")
        self.assertEqual([{"requestId": "call_exec", "kind": "command", "detail": "Wants to run a command",
                           "options": []}], desk["pending"]["approvals"])
        self.assertEqual("working", items["codex:" + IDS["cli_done"]]["status"], "approvals off: it runs")
        self.assertEqual("working", items["codex:" + IDS["cli_open"]]["status"], "Codex's own wait never asks")
        self.assertEqual("working", items["codex:" + IDS["cli_error"]]["status"], "not quiet long enough yet")
        cli = items["codex:" + IDS["cli_wait"]]
        self.assertEqual(("needs-approval", "May be waiting for you in the terminal", "Wants to run: psql -f x.sql",
                          True, ["open"]),
                         (cli["status"], cli["statusLabel"], cli["summary"], cli["live"], cli["can"]))
        self.assertNotIn("psql", json.dumps(desk), "the code a tool runs is never shown")

    def test_a_tail_of_settings_events_looks_further_back(self) -> None:
        t = NOW
        self.codex_session("desk", desktop_head(t - 900, IDS["desk"]) +
                           desktop_turn(t - 890, "Draft the release notes", "Here are the release notes.") +
                           [codex_event(t - 800 + index, "thread_settings_applied", settings={"pad": "s" * 2000})
                            for index in range(60)], age=740)
        desk = self.by_id(self.get_inbox())["codex:" + IDS["desk"]]
        self.assertEqual(("done", "Here are the release notes."), (desk["status"], desk["summary"]),
                         "Codex Desktop writes a settings event each time a thread is looked at")


if __name__ == "__main__":
    unittest.main()
