"""The bridge's morning briefing routes (CONTRACTS-WAVE8 §A3), from ``samples/briefing.json``, for
``fake_sync_server.py`` (behind the desktop token and the loopback check the server already does). It reads no mail,
makes no Gmail draft, starts no T3 task and puts nothing on a calendar: each action only answers as the bridge
(``companion/mac-bridge/samrabbit_briefing.py``) would.

* ``GET /v1/desktop/briefing?after=<revision>&wait=0..25`` -> the brief, as the bridge's ``view()``: ``{revision,
  date, building, available, status: ready | building | waiting | failed | off, generatedAt, headline, spoken,
  needsYou, sections: [{id: doFirst | today | agents | fyi, title, items: [{id, section, kind, title, why,
  actions: [{type, label}], can, state, updatedAt, account?, url?, suggestion?, draft?, startsAt?, endsAt?,
  conflict?, itemId?, source?, result?}]}], accounts, counts, composed}`` (``reason`` instead when there is none).
  The sample is moved to today (its clock times stay); with ``after`` equal to the current revision it waits up to
  ``wait`` seconds for a newer one.
* ``POST /v1/desktop/briefing/refresh`` -> 202 ``{status: "building", revision}``; about a second later the revision
  goes up. At most once in 5 minutes, as on the bridge: sooner it answers 429 ``refresh_too_soon`` with
  ``retryAfter``.
* ``POST /v1/desktop/briefing/items/<id>/act {action, …}`` -> ``{ok, item, result, revision}``, only for an action in
  the item's ``can`` (else 409 ``unsupported_action``): ``draft_reply`` -> ``{draftId, url, account, say}`` (a Gmail
  drafts link in the item's account), ``make_task`` (``text?``: the task's words, kept in the dev log's ``acts``) ->
  ``{threadId, itemId, title, say}``, ``block_time`` ->
  ``{eventId, startsAt, endsAt, say}``, ``remind`` (``in: 1h | 2pm | tonight | tomorrow`` or ``at``) -> ``{eventId,
  until, say}``, ``done`` / ``dismiss`` -> ``{}``, ``open`` -> ``{url, itemId}`` (no change). A second tap of a done
  action answers what the first did.
* Dev controls: ``POST /dev/briefing {status?: ready|building|waiting|failed|off, fail?: <action>}`` (a brief that
  isn't there, an action that fails with 502 ``gmail_failed``), ``GET /dev/briefing`` (the actions that arrived and how
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
from urllib.parse import parse_qs, unquote, urlsplit

HERE = os.path.dirname(os.path.abspath(__file__))
SAMPLE = os.path.join(HERE, "samples", "briefing.json")
ACTIONS = ("draft_reply", "make_task", "block_time", "remind", "done", "dismiss", "open")
STATES = {"draft_reply": "drafted", "make_task": "tasked", "block_time": "blocked", "remind": "reminded",
          "done": "done", "dismiss": "dismissed"}
STATUSES = ("ready", "building", "waiting", "failed", "off")
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
            self.refreshes = 0

    @staticmethod
    def handles(path: str) -> bool:
        return path.startswith("/v1/desktop/briefing") or path in ("/dev/briefing", "/dev/briefing/reset")

    # ------------------------------------------------------------------ dispatch

    def handle(self, handler: Any, method: str, path: str, query: str) -> None:
        try:
            if path == "/dev/briefing/reset":
                self.only(method, "POST")
                self.json_body(handler)  # read, so a kept-alive connection's next request starts clean
                self.reset()
                return handler.json(200, {"ok": True})
            if path == "/dev/briefing":
                if method == "POST":
                    return handler.json(200, self.dev(self.json_body(handler)))
                self.only(method, "GET")
                with self.lock:
                    return handler.json(200, {"fake": True, "status": self.status, "reads": self.reads,
                                              "revision": self.brief["revision"], "acts": list(self.acts),
                                              "refreshes": self.refreshes})
            if path == "/v1/desktop/briefing":
                self.only(method, "GET")
                params = parse_qs(query)
                return handler.json(200, self.read(params))
            if path == "/v1/desktop/briefing/refresh":
                self.only(method, "POST")
                self.json_body(handler)  # as the bridge (an optional body): the page's next request on the connection
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
        """The answer (called with the lock held), as the bridge's ``view()``."""
        base = {"revision": self.brief["revision"], "date": self.brief["date"], "building": self.status == "building"}
        if self.status in ("off", "failed", "waiting"):
            value = dict(base, available=False, status=self.status)
            if self.status != "waiting":
                value["reason"] = {"off": "briefing_turned_off", "failed": "compose_failed"}[self.status]
            return value
        brief = copy.deepcopy(self.brief)
        brief.update(base)
        brief["status"] = self.status
        brief["needsYou"] = sum(1 for section in brief["sections"] if section["id"] in ("doFirst", "agents")
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
        self.changed.notify_all()

    def refresh(self) -> Any:
        with self.lock:
            if self.status == "building":
                return 202, {"status": "building", "revision": self.brief["revision"]}
            now = time.time()
            left = REFRESH_EVERY - (now - self.refreshed_at)
            if left > 0:
                return 429, {"error": {"code": "refresh_too_soon", "retryable": True, "retryAfter": int(left) + 1,
                                       "message": "The brief was made a moment ago. Try again in a few minutes."}}
            self.refreshed_at = now
            self.refreshes += 1
            self.status = "building"
            self.changed.notify_all()

        def done() -> None:
            time.sleep(1.0)
            with self.lock:
                self.status = "ready"
                self.brief["generatedAt"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
                self.bump()

        threading.Thread(target=done, daemon=True).start()
        return 202, {"status": "building", "revision": self.brief["revision"]}

    def find(self, item_id: str) -> Dict[str, Any]:
        for section in self.brief["sections"]:
            for item in section["items"]:
                if item["id"] == item_id:
                    return item
        raise Refusal(404, "item_not_found", "That item is not in today's brief.")

    @staticmethod
    def account_of(item: Dict[str, Any]) -> Optional[str]:
        """The mailbox an email item is in: the ``authuser`` the bridge put on its Gmail link."""
        query = urlsplit(str(item.get("url") or "")).query
        values = parse_qs(query).get("authuser") or []
        return values[0] if values and "@" in values[0] else None

    @staticmethod
    def remind_at(body: Dict[str, Any]) -> Optional[datetime]:
        """The bridge's choices (``in``: 1h, 2pm, tonight, tomorrow; else ``at``, ISO with an offset)."""
        now = datetime.now().astimezone().replace(second=0, microsecond=0)
        if isinstance(body.get("at"), str):
            at = parse_iso(body["at"])
            return at if at is not None and at.tzinfo is not None else None
        choice = str(body.get("in") or "1h")
        if choice == "2pm":
            at = now.replace(hour=14, minute=0)
        elif choice == "tonight":
            at = now.replace(hour=18, minute=0)
        elif choice == "tomorrow":
            at = (now + timedelta(days=1)).replace(hour=9, minute=0)
        elif choice == "1h":
            return now + timedelta(hours=1)
        else:
            return None
        return at if at > now else at + timedelta(days=1)

    def act(self, item_id: str, body: Dict[str, Any]) -> Dict[str, Any]:
        action = body.get("action") or body.get("type")
        if action not in ACTIONS:
            raise Refusal(400, "invalid_action", "action must be one of %s." % ", ".join(ACTIONS))
        with self.lock:
            item = self.find(item_id)
            if action not in item.get("can", []):
                raise Refusal(409, "unsupported_action", "That item can't do that.")
            self.acts.append({"id": item_id, "action": action, "at": body.get("at"), "in": body.get("in"),
                              "text": body.get("text") if isinstance(body.get("text"), str) else None})
            if self.fail == action:
                raise Refusal(502, "gmail_failed", "Gmail didn't answer. Nothing was changed.", True)
            if action == "open":
                return {"ok": True, "item": dict(item), "result": {"url": item.get("url"), "itemId": item.get("itemId")},
                        "revision": self.brief["revision"]}
            if item.get("state") == STATES[action] and item.get("result"):
                return {"ok": True, "item": dict(item), "result": item["result"], "revision": self.brief["revision"]}
            self.made += 1
            result: Dict[str, Any] = {}
            if action == "draft_reply":
                draft = "r-%d%04d" % (int(time.time()) % 100000, self.made)
                account = self.account_of(item)
                result = {"draftId": draft, "account": item.get("account"),
                          "url": "https://mail.google.com/mail/%s#drafts?compose=%s"
                                 % ("?authuser=%s" % account if account else "", draft),
                          "say": "Saved as a draft in Gmail. Open it to send."}
            elif action == "make_task":
                thread = "th_brief_%d" % self.made
                result = {"threadId": thread, "itemId": "t3:" + thread, "title": item.get("title"),
                          "say": "Started it as a T3 task."}
            elif action == "block_time":
                start = datetime.now().astimezone().replace(second=0, microsecond=0) + timedelta(minutes=30)
                end = start + timedelta(minutes=45)
                result = {"eventId": "blk_brief_%d" % self.made, "startsAt": start.isoformat(),
                          "endsAt": end.isoformat(), "say": "Blocked 45 min at %s." % start.strftime("%I:%M %p").lstrip("0")}
            elif action == "remind":
                at = self.remind_at(body)
                if at is None or at <= datetime.now().astimezone():
                    raise Refusal(400, "invalid_time", "in must be 1h, 2pm, tonight or tomorrow (or give at).")
                result = {"eventId": "rem_brief_%d" % self.made, "until": at.isoformat(timespec="seconds"),
                          "say": "I'll remind you at %s." % at.strftime("%I:%M %p").lstrip("0")}
            item["state"] = STATES[action]
            item["updatedAt"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            if result:
                item["result"] = result
            self.bump()
            return {"ok": True, "item": dict(item), "result": result, "revision": self.brief["revision"]}

    def summary(self) -> Dict[str, Any]:
        """``summary.briefing``, as the bridge's ``summary_part()``."""
        with self.lock:
            brief = self.current()
        return {"available": bool(brief.get("available")), "date": brief.get("date"), "status": brief.get("status"),
                "revision": brief.get("revision"), "headline": brief.get("headline") if brief.get("available") else None,
                "needsYou": int(brief.get("needsYou") or 0)}

    # ------------------------------------------------------------------ dev controls

    def dev(self, body: Dict[str, Any]) -> Dict[str, Any]:
        with self.lock:
            if body.get("status") in STATUSES:
                self.status = body["status"]
                self.changed.notify_all()
            if "fail" in body:
                self.fail = body["fail"] if body["fail"] in ACTIONS else None
            return {"ok": True, "status": self.status, "fail": self.fail}
