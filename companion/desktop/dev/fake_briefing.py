"""The bridge's morning briefing routes (CONTRACTS-WAVE8 §A3), from ``samples/briefing.json``, for
``fake_sync_server.py`` (behind the desktop token and the loopback check the server already does). It reads no mail,
makes no Gmail draft, starts no T3 task and puts nothing on a calendar: each action only answers as the bridge would.

* ``GET /v1/desktop/briefing?after=<revision>&wait=0..25`` -> the brief (``{available, status, date, revision,
  updatedAt, headline, spoken, needsYou, sections: [{kind, title, items: [{id, kind, account?, accountEmail?, title,
  why, suggestion?, actions: [{type, label}], state, url?, startsAt?, endsAt?, conflict?, inboxItemId?}]}]}``). The
  sample is moved to today (its clock times stay); with ``after`` equal to the current revision it waits up to
  ``wait`` seconds for a newer one.
* ``POST /v1/desktop/briefing/refresh`` -> 202 ``{status: "building"}``; about a second later the revision goes up
  (at most once in 5 minutes, as on the bridge; sooner it answers 200 ``{status, revision, throttled: true}``).
* ``POST /v1/desktop/briefing/items/<id>/act {action, at?}`` -> ``{ok, state, result}``: ``draft_reply`` ->
  ``{draftId, url}`` (a Gmail drafts link in the item's account), ``make_task`` -> ``{itemId}``, ``block_time`` ->
  ``{eventId, startsAt, endsAt}``, ``remind`` -> ``{until}``, ``done`` / ``dismiss`` -> ``{}``, ``open`` -> ``{url}``.
* Dev controls: ``POST /dev/briefing {status?: ready|building|failed|off, fail?: <action>}`` (a brief that isn't
  there, an action that fails with 502 ``gmail_failed``), ``GET /dev/briefing`` (the actions that arrived and how
  often the brief was read), ``POST /dev/briefing/reset``.

Stdlib only.
"""

from __future__ import annotations

import copy
import json
import os
import threading
import time
from datetime import date, datetime, timedelta, timezone
from typing import Any, Dict, List, Optional
from urllib.parse import parse_qs, quote, unquote

HERE = os.path.dirname(os.path.abspath(__file__))
SAMPLE = os.path.join(HERE, "samples", "briefing.json")
ACTIONS = ("draft_reply", "make_task", "block_time", "remind", "done", "dismiss", "open")
STATES = {"draft_reply": "drafted", "make_task": "tasked", "block_time": "blocked", "remind": "snoozed",
          "done": "done", "dismiss": "dismissed"}
REFRESH_EVERY = 300


class Refusal(Exception):
    def __init__(self, status: int, code: str, message: str, retryable: bool = False) -> None:
        super().__init__(message)
        self.status, self.code, self.message, self.retryable = status, code, message, retryable


def parse_iso(text: str) -> Optional[datetime]:
    try:
        return datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        return None


def moved(value: Any, days: int) -> Any:
    """Every ISO time in ``value`` moved by whole days (so the clock times stay: standup is still at 9:30)."""
    if isinstance(value, dict):
        return {key: moved(item, days) for key, item in value.items()}
    if isinstance(value, list):
        return [moved(item, days) for item in value]
    if isinstance(value, str) and len(value) >= 20 and "T" in value:
        parsed = parse_iso(value)
        if parsed is not None and parsed.tzinfo is not None:
            return (parsed + timedelta(days=days)).isoformat(timespec="seconds")
    return value


def today_brief(path: str = SAMPLE, today: Optional[date] = None) -> Dict[str, Any]:
    with open(path, encoding="utf-8") as handle:
        sample = json.load(handle)
    brief = sample["briefing"]
    base = parse_iso(sample["base"])
    today = today or datetime.now().astimezone().date()
    days = (today - base.date()).days if base else 0
    brief = moved(brief, days)
    brief["date"] = today.isoformat()
    return brief


class FakeBriefing:
    def __init__(self, path: str = SAMPLE) -> None:
        self.path = path
        self.lock = threading.Lock()
        self.changed = threading.Condition(self.lock)
        self.reset()

    def reset(self) -> None:
        with self.lock:
            self.brief = today_brief(self.path)
            self.status = "ready"
            self.fail: Optional[str] = None
            self.refreshed_at = 0.0
            self.acts: List[Dict[str, Any]] = []
            self.reads = 0
            self.made = 0

    @staticmethod
    def handles(path: str) -> bool:
        return path.startswith("/v1/desktop/briefing") or path in ("/dev/briefing", "/dev/briefing/reset")

    # ------------------------------------------------------------------ dispatch

    def handle(self, handler: Any, method: str, path: str, query: str) -> None:
        try:
            if path == "/dev/briefing/reset":
                self.only(method, "POST")
                self.reset()
                return handler.json(200, {"ok": True})
            if path == "/dev/briefing":
                if method == "POST":
                    return handler.json(200, self.dev(self.json_body(handler)))
                self.only(method, "GET")
                with self.lock:
                    return handler.json(200, {"fake": True, "status": self.status, "reads": self.reads,
                                              "revision": self.brief["revision"], "acts": list(self.acts)})
            if path == "/v1/desktop/briefing":
                self.only(method, "GET")
                params = parse_qs(query)
                return handler.json(200, self.read(params))
            if path == "/v1/desktop/briefing/refresh":
                self.only(method, "POST")
                status, payload = self.refresh()
                return handler.json(status, payload)
            prefix = "/v1/desktop/briefing/items/"
            if path.startswith(prefix) and path.endswith("/act"):
                self.only(method, "POST")
                item_id = unquote(path[len(prefix):-len("/act")])
                return handler.json(200, self.act(item_id, self.json_body(handler)))
            raise Refusal(404, "not_found", "Not found.")
        except Refusal as refusal:
            handler.json(refusal.status, {"error": {"code": refusal.code, "message": refusal.message,
                                                    "retryable": refusal.retryable}})

    @staticmethod
    def only(method: str, allowed: str) -> None:
        if method != allowed:
            raise Refusal(405, "method_not_allowed", "Method not allowed.")

    @staticmethod
    def json_body(handler: Any) -> Dict[str, Any]:
        try:
            length = int(handler.headers.get("Content-Length") or 0)
        except ValueError:
            length = 0
        raw = handler.rfile.read(min(length, 65536)) if length > 0 else b""
        if not raw:
            return {}
        try:
            value = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            raise Refusal(400, "invalid_json", "Send a JSON object.")
        if not isinstance(value, dict):
            raise Refusal(400, "invalid_json", "Send a JSON object.")
        return value

    # ------------------------------------------------------------------ the brief

    def current(self) -> Dict[str, Any]:
        """The answer (called with the lock held)."""
        if self.status in ("off", "failed") or (self.status == "building" and not self.brief.get("sections")):
            reason = {"off": "gmail_not_connected", "failed": "compose_failed"}.get(self.status, "building")
            return {"available": False, "status": self.status, "date": self.brief["date"],
                    "revision": self.brief["revision"], "reason": reason}
        brief = copy.deepcopy(self.brief)
        brief["status"] = self.status
        brief["needsYou"] = sum(1 for section in brief["sections"] if section["kind"] in ("doFirst", "agents")
                                for item in section["items"] if item.get("state", "open") == "open")
        return brief

    def read(self, params: Dict[str, List[str]]) -> Dict[str, Any]:
        after = (params.get("after") or [""])[0]
        try:
            wait = max(0.0, min(25.0, float((params.get("wait") or ["0"])[0])))
        except ValueError:
            wait = 0.0
        deadline = time.time() + wait
        with self.lock:
            self.reads += 1
            while after.isdigit() and int(after) == self.brief["revision"] and time.time() < deadline:
                self.changed.wait(timeout=max(0.01, deadline - time.time()))
            return self.current()

    def bump(self) -> None:
        self.brief["revision"] += 1
        self.brief["updatedAt"] = datetime.now().astimezone().isoformat(timespec="seconds")
        self.changed.notify_all()

    def refresh(self) -> Any:
        with self.lock:
            now = time.time()
            if now - self.refreshed_at < REFRESH_EVERY:
                return 200, {"status": self.status, "revision": self.brief["revision"], "throttled": True}
            self.refreshed_at = now
            self.status = "building"
            self.changed.notify_all()

        def done() -> None:
            time.sleep(1.0)
            with self.lock:
                self.status = "ready"
                self.bump()

        threading.Thread(target=done, daemon=True).start()
        return 202, {"status": "building"}

    def find(self, item_id: str) -> Dict[str, Any]:
        for section in self.brief["sections"]:
            for item in section["items"]:
                if item["id"] == item_id:
                    return item
        raise Refusal(404, "item_not_found", "That item is not in today's brief.")

    def act(self, item_id: str, body: Dict[str, Any]) -> Dict[str, Any]:
        action = body.get("action") or body.get("type")
        if action not in ACTIONS:
            raise Refusal(400, "invalid_action", "action must be one of %s." % ", ".join(ACTIONS))
        with self.lock:
            item = self.find(item_id)
            self.acts.append({"id": item_id, "action": action, "at": body.get("at")})
            if self.fail == action:
                raise Refusal(502, "gmail_failed", "Gmail didn't answer. Nothing was changed.", True)
            self.made += 1
            result: Dict[str, Any] = {}
            if action == "draft_reply":
                draft = "r-%d%04d" % (int(time.time()) % 100000, self.made)
                account = item.get("accountEmail")
                user = "?authuser=%s" % quote(account, safe="") if account else ""
                result = {"draftId": draft, "url": "https://mail.google.com/mail/u/0/%s#drafts/%s" % (user, draft)}
            elif action == "make_task":
                result = {"itemId": "t3:th_brief_%d" % self.made}
            elif action == "block_time":
                start = datetime.now().astimezone().replace(second=0, microsecond=0) + timedelta(minutes=30)
                result = {"eventId": "blk_brief_%d" % self.made, "startsAt": start.isoformat(),
                          "endsAt": (start + timedelta(minutes=45)).isoformat()}
            elif action == "remind":
                until = body.get("at") if isinstance(body.get("at"), str) else \
                    (datetime.now(timezone.utc) + timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
                result = {"until": until}
            elif action == "open":
                result = {"url": item.get("url")} if item.get("url") else {}
            if action in STATES:
                item["state"] = STATES[action]
                self.bump()
            return {"ok": True, "state": item.get("state", "open"), "result": result}

    def summary(self) -> Dict[str, Any]:
        with self.lock:
            brief = self.current()
        return {"available": bool(brief.get("available", True)), "date": brief.get("date"), "status": brief.get("status"),
                "revision": brief.get("revision"), "headline": brief.get("headline"), "needsYou": brief.get("needsYou", 0),
                "updatedAt": brief.get("updatedAt")}

    # ------------------------------------------------------------------ dev controls

    def dev(self, body: Dict[str, Any]) -> Dict[str, Any]:
        with self.lock:
            if body.get("status") in ("ready", "building", "failed", "off"):
                self.status = body["status"]
                self.changed.notify_all()
            if "fail" in body:
                self.fail = body["fail"] if body["fail"] in ACTIONS else None
            return {"ok": True, "status": self.status, "fail": self.fail}
