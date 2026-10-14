#!/usr/bin/env python3
"""SamRabbit's tools for the voice assistant: a stdio MCP server that the headless Claude Code CLI starts.

The Mac bridge (``samrabbit_assistant``) runs ``claude -p --strict-mcp-config --mcp-config <0600 file>`` for every
watch turn; that file starts this script with two environment variables:

* ``SAMRABBIT_ASSISTANT_URL``: the bridge on loopback (``http://127.0.0.1:<port>``);
* ``SAMRABBIT_ASSISTANT_TOKEN_FILE``: a 0600 file with the bridge's internal assistant token (made when the bridge
  starts; never on the command line, never logged).

Every tool is one call to the bridge's own mobile API (``/v1/mobile/*``) with that token (never through a system
proxy), so a copy of the bridge run from a checkout only ever reaches its own dev-safe answers (``t3_dev_copy``,
``calendar_dev_copy``, a dry-run journal). The CLI's session id (``CLAUDE_CODE_SESSION_ID``, which Claude Code gives
its MCP servers) travels as ``X-SamRabbit-Assistant-Session``, so the bridge can tell which watch conversation a tool
call belongs to.

Protocol (what Claude Code sends, newline-delimited JSON-RPC 2.0): ``server/discover`` (answered at once with
method-not-found), ``initialize``, ``notifications/initialized``, ``tools/list``, ``tools/call`` (and ``ping``).
Notifications are never answered. Stdout carries only protocol messages; nothing is logged (Claude Code kills this
process when it exits, so there is no shutdown code). Stdlib only, Python 3.9.
"""

from __future__ import annotations

import base64
from datetime import datetime, timedelta
import json
import math
import os
import sys
from typing import Any, Dict, List, Optional, Tuple
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlencode, urlsplit
from urllib.request import ProxyHandler, Request, build_opener

SERVER_NAME = "samrabbit"
SERVER_VERSION = "1.0.0"
DEFAULT_PROTOCOL = "2025-11-25"
URL_ENV = "SAMRABBIT_ASSISTANT_URL"
TOKEN_ENV = "SAMRABBIT_ASSISTANT_TOKEN_FILE"
SESSION_HEADER = "X-SamRabbit-Assistant-Session"
# Loopback only, so never through a system proxy (a proxy set in System Settings would otherwise get these requests,
# with the internal token in them).
_OPENER = build_opener(ProxyHandler({}))
HTTP_TIMEOUT = 12.0
SLOW_TIMEOUT = 18.0  # creating a T3 task, a screenshot
SCREENSHOT_SIDE = 1280
MAX_LINE_BYTES = 1024 * 1024
MAX_TEXT = 600

TOOLS: List[Dict[str, Any]] = [
    {"name": "get_status",
     "description": "What needs Samin right now and what is going on: T3 Code tasks waiting for him (approvals, "
                    "questions), tasks that are working, his next calendar events, whether the R1 is in a "
                    "conversation, and the Mac (screen locked or not). Use for 'what needs me', 'what's going on', "
                    "'anything new'.",
     "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False}},
    {"name": "list_tasks",
     "description": "List T3 Code tasks, most urgent first. filter: needs_you (waiting for an approval or an answer), "
                    "working, or recent (finished, failed or never started). No filter: all of them.",
     "inputSchema": {"type": "object", "properties": {
         "filter": {"type": "string", "enum": ["needs_you", "working", "recent"]}}, "additionalProperties": False}},
    {"name": "read_task",
     "description": "Read one T3 Code task: its status, its last messages, and what it is waiting for (the approval "
                    "or question, with its requestId and options).",
     "inputSchema": {"type": "object", "properties": {"id": {"type": "string", "description": "the task's id"}},
                     "required": ["id"], "additionalProperties": False}},
    {"name": "start_task",
     "description": "Start a new T3 Code task with Samin's request. Without a project it is placed automatically "
                    "(coding work goes to the matching repository, everything else to his orchestration project). "
                    "The result names the project it went to: tell him.",
     "inputSchema": {"type": "object", "properties": {
         "text": {"type": "string", "description": "what the task should do, in Samin's words"},
         "project": {"type": "string", "description": "a project name, only when he named one"}},
         "required": ["text"], "additionalProperties": False}},
    {"name": "reply_task",
     "description": "Send a follow-up message to an existing T3 Code task.",
     "inputSchema": {"type": "object", "properties": {"id": {"type": "string"}, "text": {"type": "string"}},
                     "required": ["id", "text"], "additionalProperties": False}},
    {"name": "respond_task",
     "description": "Answer what a T3 Code task is waiting for: decision approve or deny for an approval, or answer "
                    "(text) for a question. Only after Samin clearly said yes to exactly this.",
     "inputSchema": {"type": "object", "properties": {
         "id": {"type": "string"}, "requestId": {"type": "string"},
         "decision": {"type": "string", "enum": ["approve", "deny"]}, "answer": {"type": "string"}},
         "required": ["id"], "additionalProperties": False}},
    {"name": "stop_task",
     "description": "Stop a running T3 Code task. Only after Samin clearly confirmed.",
     "inputSchema": {"type": "object", "properties": {"id": {"type": "string"}}, "required": ["id"],
                     "additionalProperties": False}},
    {"name": "mark_seen",
     "description": "Mark what Samin saw in his agent inbox (the dock's Needs you: T3 Code tasks, Claude Code and "
                    "Codex sessions) as seen, when he says 'mark it as seen', 'I saw that', 'clear it': a finished "
                    "one stops being new and a failed one settles, out of Needs you until it fails again. item: its "
                    "title as he said it (or an id); all: true for everything finished or failed he hasn't seen. "
                    "Approvals and questions keep needing him: seeing them doesn't answer them.",
     "inputSchema": {"type": "object", "properties": {
         "item": {"type": "string", "description": "the title as he said it, or an id"},
         "all": {"type": "boolean", "description": "everything finished or failed that he hasn't seen"}},
         "additionalProperties": False}},
    {"name": "calendar_agenda",
     "description": "Samin's Google Calendar. withinMinutes for 'the next N minutes' (events happening now or "
                    "starting in that window); hours for a longer window (default 12).",
     "inputSchema": {"type": "object", "properties": {
         "withinMinutes": {"type": "integer", "minimum": 1, "maximum": 1440},
         "hours": {"type": "integer", "minimum": 1, "maximum": 168}}, "additionalProperties": False}},
    {"name": "calendar_block",
     "description": "Block time on his calendar starting now, for minutes (5 to 720), with an optional title "
                    "(default Focus).",
     "inputSchema": {"type": "object", "properties": {
         "minutes": {"type": "integer", "minimum": 5, "maximum": 720}, "title": {"type": "string"}},
         "required": ["minutes"], "additionalProperties": False}},
    {"name": "calendar_create",
     "description": "Add an event to his calendar. start and end are ISO 8601 times with the America/New_York "
                    "offset (work the date out from the [Now: ...] line).",
     "inputSchema": {"type": "object", "properties": {
         "title": {"type": "string"}, "start": {"type": "string"}, "end": {"type": "string"}},
         "required": ["title", "start", "end"], "additionalProperties": False}},
    {"name": "journal_add",
     "description": "Add a note to today's Heptabase journal. ONLY when Samin explicitly asks to add something to "
                    "his journal. text is his own words, verbatim, never a summary or your wording.",
     "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"],
                     "additionalProperties": False}},
    {"name": "mac_open",
     "description": "Open an app (by its name) or a URL on Samin's Mac. Give exactly one of app or url.",
     "inputSchema": {"type": "object", "properties": {"app": {"type": "string"}, "url": {"type": "string"}},
                     "additionalProperties": False}},
    {"name": "mac_look",
     "description": "Look at the Mac's screen (a screenshot you can see). Use when he asks what is on the screen or "
                    "to check something visible on the Mac.",
     "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False}},
    {"name": "generate_ui",
     "description": "Make a chart, graph, table or other visual on the Mac. It appears on his iPhone and his Mac, "
                    "not on the watch: say so.",
     "inputSchema": {"type": "object", "properties": {"prompt": {"type": "string"}}, "required": ["prompt"],
                     "additionalProperties": False}},
    {"name": "recent_conversations",
     "description": "His recent conversations with SamRabbit (the R1, the phone and the watch): titles, when, and a "
                    "short preview.",
     "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False}},
]
TOOL_NAMES = frozenset(tool["name"] for tool in TOOLS)


class ToolFailure(Exception):
    """A tool that did not work: answered as ``isError`` with a short reason the model can say."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


# --------------------------------------------------------------------------- the bridge


class Bridge:
    """The bridge's mobile API over loopback with the internal assistant token."""

    def __init__(self, base_url: str, token_file: str, session: Optional[str]) -> None:
        self.base_url = base_url.rstrip("/")
        self.token_file = token_file
        self.session = session if session and len(session) <= 80 and session.isprintable() else None
        self._token: Optional[str] = None

    def token(self) -> str:
        if self._token is None:
            try:
                with open(self.token_file, "r", encoding="utf-8") as handle:
                    value = handle.read().strip()
            except OSError:
                value = ""
            if not value:
                raise ToolFailure("assistant_token_missing", "The bridge did not give the assistant its key.")
            self._token = value
        return self._token

    def call(self, method: str, path: str, body: Optional[Dict[str, Any]] = None, *,
             timeout: float = HTTP_TIMEOUT, raw: bool = False) -> Any:
        parts = urlsplit(self.base_url)
        if parts.scheme != "http" or parts.hostname not in ("127.0.0.1", "localhost", "::1") and \
                not str(parts.hostname or "").startswith(("10.", "192.168.", "172.")):
            raise ToolFailure("assistant_bridge_url", "The bridge address is not a local one.")
        headers = {"Authorization": "Bearer " + self.token(), "Accept": "application/json"}
        if self.session:
            headers[SESSION_HEADER] = self.session
        data = None
        if body is not None:
            data = json.dumps(body, ensure_ascii=False).encode("utf-8")
            headers["Content-Type"] = "application/json"
        request = Request(self.base_url + path, data=data, method=method, headers=headers)
        try:
            with _OPENER.open(request, timeout=timeout) as response:  # noqa: S310 - loopback only (checked above)
                payload = response.read(16 * 1024 * 1024)
                kind = response.headers.get("Content-Type", "")
        except HTTPError as error:
            try:
                value = json.loads(error.read(256 * 1024).decode("utf-8"))
            except (OSError, ValueError, UnicodeDecodeError):
                value = None
            detail = value.get("error") if isinstance(value, dict) and isinstance(value.get("error"), dict) else {}
            raise ToolFailure(str(detail.get("code") or f"http_{error.code}"),
                              str(detail.get("message") or f"The Mac answered HTTP {error.code}.")) from None
        except (URLError, OSError, ValueError):
            raise ToolFailure("bridge_unreachable", "The Mac bridge did not answer.") from None
        if raw:
            return payload, kind
        try:
            return json.loads(payload.decode("utf-8")) if payload else {}
        except (UnicodeDecodeError, ValueError):
            raise ToolFailure("bad_answer", "The Mac answered with something unreadable.") from None


# --------------------------------------------------------------------------- tools


def _short(value: Any, limit: int = MAX_TEXT) -> Optional[str]:
    if not isinstance(value, str):
        return None
    text = " ".join(value.split())
    return text if len(text) <= limit else text[:limit - 1].rstrip() + "…"


def _task(item: Dict[str, Any]) -> Dict[str, Any]:
    value = {"id": item.get("threadId"), "title": _short(item.get("title"), 120),
             "project": item.get("projectName") or item.get("project"), "status": item.get("status"),
             "summary": _short(item.get("summary"), 200), "updatedAt": item.get("updatedAt")}
    pending = item.get("pending")
    if isinstance(pending, dict):
        value["waitingFor"] = _pending(pending)
    return {key: item_value for key, item_value in value.items() if item_value not in (None, "")}


def _pending(pending: Dict[str, Any]) -> Dict[str, Any]:
    value: Dict[str, Any] = {"kind": pending.get("kind"), "requestId": pending.get("requestId"),
                             "text": _short(pending.get("text"), 400)}
    options = pending.get("options")
    if isinstance(options, list) and options:
        value["options"] = [option.get("label") if isinstance(option, dict) else option for option in options][:6]
    return {key: item for key, item in value.items() if item not in (None, "", [])}


def _event(item: Dict[str, Any]) -> Dict[str, Any]:
    value = {"title": _short(item.get("title"), 120), "startsAt": item.get("startsAt"), "endsAt": item.get("endsAt"),
             "allDay": bool(item.get("allDay")) or None, "location": _short(item.get("location"), 120),
             "hasMeetingLink": bool(item.get("meetingUrl")) or None}
    return {key: item_value for key, item_value in value.items() if item_value not in (None, "")}


def _text_arg(arguments: Dict[str, Any], key: str, *, required: bool = True, limit: int = 4000) -> Optional[str]:
    value = arguments.get(key)
    if value is None or (isinstance(value, str) and not value.strip()):
        if required:
            raise ToolFailure("invalid_arguments", f"{key} is required.")
        return None
    if not isinstance(value, str) or len(value) > limit:
        raise ToolFailure("invalid_arguments", f"{key} must be text of at most {limit} characters.")
    return value.strip()


def _int_arg(arguments: Dict[str, Any], key: str, low: int, high: int) -> Optional[int]:
    value = arguments.get(key)
    if value is None:
        return None
    if isinstance(value, float) and value.is_integer():
        value = int(value)
    if isinstance(value, str) and value.strip().isdigit():
        value = int(value.strip())
    if isinstance(value, bool) or not isinstance(value, int) or not low <= value <= high:
        raise ToolFailure("invalid_arguments", f"{key} must be a whole number from {low} to {high}.")
    return value


def _task_id(arguments: Dict[str, Any]) -> str:
    value = _text_arg(arguments, "id", limit=190)
    return quote(str(value), safe="")


def get_status(bridge: Bridge, _arguments: Dict[str, Any]) -> Dict[str, Any]:
    summary = bridge.call("GET", "/v1/mobile/summary")
    t3 = summary.get("t3") or {}
    threads = [item for item in t3.get("threads") or [] if isinstance(item, dict)]
    value: Dict[str, Any] = {
        "tasks": {"available": bool(t3.get("available")), "needsYouCount": int(t3.get("needsYou") or 0),
                  "workingCount": int(t3.get("working") or 0),
                  "needsYou": [_task(item) for item in threads if item.get("status") in ("needs_approval",
                                                                                        "needs_input")],
                  "working": [_task(item) for item in threads if item.get("status") == "working"]},
        "calendar": {"available": bool((summary.get("calendar") or {}).get("available")),
                     "next": [_event(item) for item in (summary.get("calendar") or {}).get("next") or []]},
        "r1": {"inConversation": bool((summary.get("r1") or {}).get("live")),
               "lastSeenAt": (summary.get("r1") or {}).get("lastSeenAt")},
        "mac": {"screenLocked": (summary.get("mac") or {}).get("screenLocked")},
    }
    if not t3.get("available") and t3.get("reason"):
        value["tasks"]["problem"] = t3["reason"]
    calendar = summary.get("calendar") or {}
    if not calendar.get("available") and calendar.get("reason"):
        value["calendar"]["problem"] = calendar["reason"]
    return value


def list_tasks(bridge: Bridge, arguments: Dict[str, Any]) -> Dict[str, Any]:
    name = arguments.get("filter")
    if name not in (None, "", "needs_you", "working", "recent"):
        raise ToolFailure("invalid_arguments", "filter must be needs_you, working or recent.")
    query = "?" + urlencode({"filter": name, "limit": 12}) if name else "?limit=12"
    value = bridge.call("GET", "/v1/mobile/t3/threads" + query)
    tasks = [_task(item) for item in value.get("threads") or [] if isinstance(item, dict)]
    return {"filter": name or "all", "count": len(tasks), "tasks": tasks}


def read_task(bridge: Bridge, arguments: Dict[str, Any]) -> Dict[str, Any]:
    value = bridge.call("GET", "/v1/mobile/t3/threads/" + _task_id(arguments))
    messages = [{"role": item.get("role"), "text": _short(item.get("text"), 500)}
                for item in (value.get("messages") or [])[-6:] if isinstance(item, dict)]
    result: Dict[str, Any] = {"task": _task(value.get("thread") or {}), "lastMessages": messages}
    if isinstance(value.get("pending"), dict):
        result["waitingFor"] = _pending(value["pending"])
    return result


def _project_id(bridge: Bridge, name: str) -> Tuple[str, str]:
    projects = [item for item in bridge.call("GET", "/v1/mobile/t3/projects").get("projects") or []
                if isinstance(item, dict) and item.get("projectId")]
    wanted = " ".join(name.lower().split())
    for test in (lambda title: title == wanted, lambda title: title.startswith(wanted),
                 lambda title: wanted in title):
        found = [item for item in projects if test(" ".join(str(item.get("name") or "").lower().split()))]
        if len(found) == 1:
            return str(found[0]["projectId"]), str(found[0].get("name") or "")
    names = ", ".join(str(item.get("name")) for item in projects[:12])
    raise ToolFailure("project_not_found", f"No T3 project called {name!r}. Projects: {names}.")


def start_task(bridge: Bridge, arguments: Dict[str, Any]) -> Dict[str, Any]:
    text = _text_arg(arguments, "text", limit=8000)
    body: Dict[str, Any] = {"text": text}
    project = _text_arg(arguments, "project", required=False, limit=120)
    if project:
        body["projectId"], _name = _project_id(bridge, project)
    value = bridge.call("POST", "/v1/mobile/t3/threads", body, timeout=SLOW_TIMEOUT)
    return {"started": True, "id": value.get("threadId"), "title": value.get("title"),
            "project": value.get("projectName"), "placement": value.get("placement")}


def reply_task(bridge: Bridge, arguments: Dict[str, Any]) -> Dict[str, Any]:
    text = _text_arg(arguments, "text", limit=8000)
    value = bridge.call("POST", f"/v1/mobile/t3/threads/{_task_id(arguments)}/message", {"text": text},
                        timeout=SLOW_TIMEOUT)
    return {"sent": True, "id": value.get("threadId"), "taskWasWorking": value.get("wasWorking")}


def respond_task(bridge: Bridge, arguments: Dict[str, Any]) -> Dict[str, Any]:
    decision = arguments.get("decision")
    answer = _text_arg(arguments, "answer", required=False)
    if decision not in (None, "approve", "deny") or (decision is None) == (answer is None):
        raise ToolFailure("invalid_arguments", "Give either decision (approve or deny) or answer.")
    body: Dict[str, Any] = {"decision": decision} if decision else {"answer": answer}
    request_id = _text_arg(arguments, "requestId", required=False, limit=200)
    if request_id:
        body["requestId"] = request_id
    value = bridge.call("POST", f"/v1/mobile/t3/threads/{_task_id(arguments)}/respond", body, timeout=SLOW_TIMEOUT)
    result = {"done": True, "id": value.get("threadId"), "requestId": value.get("requestId")}
    if value.get("decision"):
        result["decision"] = value["decision"]
    return result


def stop_task(bridge: Bridge, arguments: Dict[str, Any]) -> Dict[str, Any]:
    value = bridge.call("POST", f"/v1/mobile/t3/threads/{_task_id(arguments)}/stop", {}, timeout=SLOW_TIMEOUT)
    return {"stopped": bool(value.get("wasWorking")), "id": value.get("threadId"),
            "note": None if value.get("wasWorking") else "It was not running."}


SEEN_SOURCES = ("t3", "claude", "codex")


def inbox_items(bridge: Bridge) -> List[Dict[str, Any]]:
    """The inbox as the phone sees it (T3 Code, Claude Code, Codex, chats and voice notes), dismissed ones left out."""
    value = bridge.call("GET", "/v1/mobile/inbox")
    return [item for item in value.get("items") or [] if isinstance(item, dict) and item.get("id")]


def unseen_finished(items: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """``mark_seen {all}``: every finished or failed agent he hasn't seen (approvals and questions still need him)."""
    return [item for item in items if item.get("source") in SEEN_SOURCES and item.get("status") in ("done", "error")
            and "seen" in (item.get("can") or [])]


def mark_items_seen(bridge: Bridge, items: List[Dict[str, Any]]) -> Dict[str, Any]:
    """``POST /v1/mobile/inbox/items/<id>/seen`` for each (what the dock's Mark seen does); one already seen is left."""
    marked = [item for item in items if "seen" in (item.get("can") or [])]
    for item in marked:
        bridge.call("POST", f"/v1/mobile/inbox/items/{quote(str(item['id']), safe=':')}/seen", {})
    settled = sum(1 for item in marked if item.get("status") == "error")
    return {"marked": len(marked), "titles": [_short(item.get("title"), 80) for item in marked[:5]],
            "settled": settled or None,
            "note": None if marked else "Nothing to mark: it was already seen, or it is waiting for his answer."}


def _match_item(text: str, items: List[Dict[str, Any]]) -> Dict[str, Any]:
    lowered = text.lower()
    for item in items:
        if str(item.get("id")).lower() == lowered or str(item.get("id")).lower().endswith(":" + lowered):
            return item
    exact = [item for item in items if " ".join(str(item.get("title") or "").split()).lower() == lowered]
    if exact:
        return exact[0]
    near = [item for item in items if lowered in str(item.get("title") or "").lower()
            or str(item.get("title") or "").lower() in lowered and str(item.get("title") or "").strip()]
    if len(near) == 1:
        return near[0]
    if near:
        raise ToolFailure("ambiguous", "More than one matches: " + "; ".join(
            f"“{_short(item.get('title'), 60)}”" for item in near[:3]) + ". Ask him which one.")
    raise ToolFailure("not_found", f"Nothing in the inbox matches “{_short(text, 60)}”.")


def mark_seen(bridge: Bridge, arguments: Dict[str, Any]) -> Dict[str, Any]:
    everything = arguments.get("all") is True
    text = " ".join(str(arguments.get("item") or "").split())
    if not everything and not text:
        raise ToolFailure("invalid_arguments", "Say which one, or all.")
    items = inbox_items(bridge)
    return mark_items_seen(bridge, unseen_finished(items) if everything else [_match_item(text, items)])


def calendar_agenda(bridge: Bridge, arguments: Dict[str, Any]) -> Dict[str, Any]:
    within = _int_arg(arguments, "withinMinutes", 1, 1440)
    hours = _int_arg(arguments, "hours", 1, 168)
    span = max(1, math.ceil(within / 60)) if within else (hours or 12)
    value = bridge.call("GET", "/v1/mobile/calendar/agenda?" + urlencode({"hours": span}))
    now = _moment(value.get("from"))
    events = [item for item in value.get("events") or [] if isinstance(item, dict) and
              (now is None or item.get("allDay") or (_moment(item.get("endsAt")) or now) > now)]  # not over yet
    if within:
        # The agenda starts now: keep what is happening now or starts within the window (the route reads whole
        # hours, so cut it to the minutes asked for).
        limit = _iso_plus(value.get("from"), within)
        if limit is not None:
            events = [item for item in events
                      if item.get("allDay") or (_moment(item.get("startsAt")) or limit) < limit]
    result: Dict[str, Any] = {"window": f"next {within} minutes" if within else f"next {span} hours",
                              "now": value.get("from"), "count": len(events),
                              "events": [_event(item) for item in events[:12]]}
    if value.get("stale"):
        result["note"] = "From a cached copy; Google Calendar did not answer just now."
    return result


def _moment(value: Any) -> Optional[datetime]:
    if not isinstance(value, str):
        return None
    try:
        moment = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return moment if moment.tzinfo is not None else None


def _iso_plus(start: Any, minutes: int) -> Optional[datetime]:
    moment = _moment(start)
    return moment + timedelta(minutes=minutes) if moment is not None else None


def calendar_block(bridge: Bridge, arguments: Dict[str, Any]) -> Dict[str, Any]:
    minutes = _int_arg(arguments, "minutes", 5, 720)
    if minutes is None:
        raise ToolFailure("invalid_arguments", "minutes is required.")
    body: Dict[str, Any] = {"minutes": minutes}
    title = _text_arg(arguments, "title", required=False, limit=300)
    if title:
        body["title"] = title
    value = bridge.call("POST", "/v1/mobile/calendar/block", body, timeout=SLOW_TIMEOUT)
    return {"added": True, **_event(value.get("event") or {}), "eventId": (value.get("event") or {}).get("eventId")}


def calendar_create(bridge: Bridge, arguments: Dict[str, Any]) -> Dict[str, Any]:
    body = {"title": _text_arg(arguments, "title", limit=300), "startsAt": _text_arg(arguments, "start", limit=64),
            "endsAt": _text_arg(arguments, "end", limit=64)}
    value = bridge.call("POST", "/v1/mobile/calendar/events", body, timeout=SLOW_TIMEOUT)
    return {"added": True, **_event(value.get("event") or {}), "eventId": (value.get("event") or {}).get("eventId")}


def journal_add(bridge: Bridge, arguments: Dict[str, Any]) -> Dict[str, Any]:
    value = bridge.call("POST", "/v1/mobile/journal", {"text": _text_arg(arguments, "text")})
    result: Dict[str, Any] = {"added": bool(value.get("recorded")), "date": value.get("date"),
                              "time": value.get("time")}
    if value.get("redacted"):
        result["note"] = "A code, password or key in it was written as [redacted]."
    if value.get("dryRun"):
        result["note"] = "Test copy of the Mac bridge: kept in a dry run, not written to Heptabase."
    return result


def mac_open(bridge: Bridge, arguments: Dict[str, Any]) -> Dict[str, Any]:
    app = _text_arg(arguments, "app", required=False, limit=200)
    url = _text_arg(arguments, "url", required=False, limit=2000)
    if (app is None) == (url is None):
        raise ToolFailure("invalid_arguments", "Give exactly one of app or url.")
    value = bridge.call("POST", "/v1/mobile/mac/open", {"app": app} if app else {"url": url}, timeout=SLOW_TIMEOUT)
    return {"opened": True, "app": value.get("app") or app, "url": url if url else None}


def mac_look(bridge: Bridge, _arguments: Dict[str, Any]) -> List[Dict[str, Any]]:
    """An MCP image content block (the model sees the screen), or text when the screen is locked."""
    try:
        data, kind = bridge.call("GET", f"/v1/mobile/mac/screenshot?max={SCREENSHOT_SIDE}", timeout=SLOW_TIMEOUT,
                                 raw=True)
    except ToolFailure as failure:
        if failure.code == "screen_locked":
            return [{"type": "text", "text": "The Mac's screen is locked, so there is nothing to see. Say so."}]
        raise
    mime = str(kind).split(";", 1)[0].strip() or "image/jpeg"
    if not data or not mime.startswith("image/"):
        raise ToolFailure("capture_failed", "The Mac could not take a screenshot.")
    return [{"type": "image", "data": base64.b64encode(data).decode("ascii"), "mimeType": mime},
            {"type": "text", "text": "This is the Mac's screen right now."}]


def generate_ui(bridge: Bridge, arguments: Dict[str, Any]) -> Dict[str, Any]:
    value = bridge.call("POST", "/v1/mobile/ui/generate", {"prompt": _text_arg(arguments, "prompt")})
    return {"started": True, "artifactId": value.get("artifactId"), "status": value.get("status"),
            "note": "It appears on his iPhone and his Mac in a moment, not on the watch."}


def recent_conversations(bridge: Bridge, _arguments: Dict[str, Any]) -> Dict[str, Any]:
    value = bridge.call("GET", "/v1/mobile/conversations?limit=6")
    items = []
    for item in value.get("conversations") or []:
        if isinstance(item, dict):
            items.append({key: item_value for key, item_value in {
                "title": _short(item.get("title"), 100), "preview": _short(item.get("preview"), 160),
                "lastAt": item.get("lastAt"), "live": bool(item.get("live")) or None}.items()
                if item_value not in (None, "")})
    return {"conversations": items}


HANDLERS = {"get_status": get_status, "list_tasks": list_tasks, "read_task": read_task, "start_task": start_task,
            "reply_task": reply_task, "respond_task": respond_task, "stop_task": stop_task, "mark_seen": mark_seen,
            "calendar_agenda": calendar_agenda, "calendar_block": calendar_block, "calendar_create": calendar_create,
            "journal_add": journal_add, "mac_open": mac_open, "mac_look": mac_look, "generate_ui": generate_ui,
            "recent_conversations": recent_conversations}


def call_tool(bridge: Bridge, name: Any, arguments: Any) -> Dict[str, Any]:
    """``tools/call`` result: ``{content: [...], isError}``."""
    if not isinstance(name, str) or name not in HANDLERS:
        return {"content": [{"type": "text", "text": json.dumps({"error": "unknown_tool"})}], "isError": True}
    try:
        value = HANDLERS[name](bridge, arguments if isinstance(arguments, dict) else {})
    except ToolFailure as failure:
        text = json.dumps({"error": failure.code, "message": failure.message}, ensure_ascii=False)
        return {"content": [{"type": "text", "text": text}], "isError": True}
    except Exception:  # noqa: BLE001 - a broken tool never takes the server down
        return {"content": [{"type": "text", "text": json.dumps({"error": "tool_failed"})}], "isError": True}
    if isinstance(value, list):
        return {"content": value, "isError": False}
    clean = {key: item for key, item in value.items() if item is not None}
    return {"content": [{"type": "text", "text": json.dumps(clean, ensure_ascii=False, separators=(",", ":"))}],
            "isError": False}


# --------------------------------------------------------------------------- JSON-RPC over stdio


def answer(request: Dict[str, Any], bridge_factory: Any) -> Optional[Dict[str, Any]]:
    """The reply to one message, or None for notifications (never answered)."""
    if "id" not in request:
        return None
    method = request.get("method")
    params = request.get("params") if isinstance(request.get("params"), dict) else {}
    if method == "initialize":
        version = params.get("protocolVersion")
        result: Dict[str, Any] = {"protocolVersion": version if isinstance(version, str) and version else
                                  DEFAULT_PROTOCOL,
                                  "capabilities": {"tools": {"listChanged": False}},
                                  "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION}}
    elif method == "ping":
        result = {}
    elif method == "tools/list":
        result = {"tools": TOOLS}
    elif method == "tools/call":
        result = call_tool(bridge_factory(), params.get("name"), params.get("arguments"))
    else:  # includes server/discover, which must be answered at once
        return {"jsonrpc": "2.0", "id": request.get("id"), "error": {"code": -32601, "message": "method not found"}}
    return {"jsonrpc": "2.0", "id": request.get("id"), "result": result}


def serve(stdin: Any = None, stdout: Any = None, environ: Optional[Dict[str, str]] = None) -> int:
    source = stdin if stdin is not None else sys.stdin.buffer
    sink = stdout if stdout is not None else sys.stdout
    env = os.environ if environ is None else environ
    bridges: List[Bridge] = []

    def bridge() -> Bridge:
        if not bridges:
            bridges.append(Bridge(env.get(URL_ENV, ""), env.get(TOKEN_ENV, ""), env.get("CLAUDE_CODE_SESSION_ID")))
        return bridges[0]

    while True:
        line = source.readline(MAX_LINE_BYTES + 1)
        if not line:
            return 0
        if isinstance(line, bytes):
            try:
                line = line.decode("utf-8")
            except UnicodeDecodeError:
                continue
        if not line.strip():
            continue
        try:
            request = json.loads(line)
        except ValueError:
            reply: Optional[Dict[str, Any]] = {"jsonrpc": "2.0", "id": None,
                                               "error": {"code": -32700, "message": "parse error"}}
        else:
            if not isinstance(request, dict):
                reply = {"jsonrpc": "2.0", "id": None, "error": {"code": -32600, "message": "invalid request"}}
            else:
                reply = answer(request, bridge)
        if reply is not None:
            sink.write(json.dumps(reply, ensure_ascii=False, separators=(",", ":")) + "\n")
            sink.flush()


if __name__ == "__main__":
    sys.exit(serve())
