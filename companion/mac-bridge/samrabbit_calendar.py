"""Google Calendar changes for the SamRabbit bridge, made with the Composio CLI on this Mac.

The R1 reads the user's Google Calendar from its secret iCal address, which is read-only. To add, move or
cancel an event it asks this bridge, which runs the signed-in Composio CLI (managed Google auth):

    composio execute GOOGLECALENDAR_CREATE_EVENT | GOOGLECALENDAR_PATCH_EVENT | GOOGLECALENDAR_DELETE_EVENT -d -
        --account <connection>

through the bridge's shared Composio runner (``samrabbit_composio``: an allow-list of tool slugs, the JSON arguments
on stdin, never on argv, a private working folder and ``TMPDIR`` per call, wiped after it), one call at a time, 30 s
each, no shell, a small child environment, and the process group killed on timeout. ``GOOGLECALENDAR_EVENTS_LIST``
(read-only) turns an iCal UID that is not ``<eventId>@google.com`` into the event id. ``--account`` is always the
connection that is samin@aianswer.us (``DEFAULT_CONNECTION``; ``SAMRABBIT_CALENDAR_CONNECTION`` to change it), never
Composio's own pick among several Google Calendar connections.

Routes (bearer token and a loopback/private-LAN peer, like ``/v1/mac/*``):

* ``GET  /v1/calendar/status``
* ``POST /v1/calendar/events``         ``{title, startsAt, endsAt, timezone?, description?, location?, calendarId?}``
* ``POST /v1/calendar/events/update``  ``{iCalUID | eventId, recurrenceId?, title?, startsAt?, endsAt?, timezone?,
  description?, location?, calendarId?}``
* ``POST /v1/calendar/events/delete``  ``{iCalUID | eventId, recurrenceId?, calendarId?}``

Times are RFC 3339 with an offset. Errors are ``{"error": {code, message, retryable, written}}``; ``written`` is
``"unknown"`` when a change may have reached Google Calendar (for example after a timeout). Event titles,
descriptions and Composio's own messages are never logged. Stdlib only (macOS system Python 3.9+).
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
import json
import logging
import os
import re
import sys
import tempfile
import threading
from typing import Any, Dict, Optional, Tuple

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.append(_HERE)

import samrabbit_composio as composio  # noqa: E402

_LOG = logging.getLogger("samrabbit-bridge.calendar")

ROUTE_PREFIX = "/v1/calendar/"
STATUS_ROUTE = "/v1/calendar/status"
CREATE_ROUTE = "/v1/calendar/events"
UPDATE_ROUTE = "/v1/calendar/events/update"
DELETE_ROUTE = "/v1/calendar/events/delete"
ROUTES = (STATUS_ROUTE, CREATE_ROUTE, UPDATE_ROUTE, DELETE_ROUTE)
CLI_TIMEOUT_SECONDS = composio.CLI_TIMEOUT_SECONDS
LOCK_WAIT_SECONDS = 15.0
DEFAULT_CALENDAR_ID = "primary"
FALLBACK_COMPOSIO = composio.FALLBACK_COMPOSIO
# The Composio connection the bridge reads and writes Google Calendar with. Two connections are ACTIVE, both
# samin@aianswer.us (checked 2026-10-14 with a read-only GOOGLECALENDAR_EVENTS_LIST: the primary calendar's name is
# the account's email); neither has an alias and the CLI cannot add one without linking again, so the word id is used.
DEFAULT_CONNECTION = "googlecalendar_awest-hug"
MAX_TITLE_CHARS = 300
MAX_DESCRIPTION_CHARS = 8000
MAX_LOCATION_CHARS = 500
MAX_UID_CHARS = 1024
MAX_SPAN = timedelta(days=31)
GOOGLE_UID_SUFFIX = "@google.com"
CREATE_SLUG = "GOOGLECALENDAR_CREATE_EVENT"
PATCH_SLUG = "GOOGLECALENDAR_PATCH_EVENT"
DELETE_SLUG = "GOOGLECALENDAR_DELETE_EVENT"
LIST_SLUG = "GOOGLECALENDAR_EVENTS_LIST"
LINK_FIX = "Run on the Mac: composio link googlecalendar"

_GOOGLE_ID = re.compile(r"^[a-v0-9]{5,1024}$")  # ids Google generates (base32hex)
_EVENT_ID = re.compile(r"^[A-Za-z0-9_\-]{1,1100}$")
_RECURRENCE_ID = re.compile(r"^\d{8}(?:T\d{6}Z)?$")  # the occurrence's original start, as in instance ids
_CALENDAR_ID = re.compile(r"^[A-Za-z0-9._%+\-#@]{1,254}$")
_TIMEZONE = re.compile(r"^[A-Za-z][A-Za-z0-9_+\-]*(?:/[A-Za-z0-9_+\-]+){0,2}$")
_DATETIME = re.compile(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2})?)(?:\.\d+)?(Z|[+-]\d{2}:\d{2})$")
_EMAIL = re.compile(r"^[^@\s]{1,128}@[^@\s]{1,128}$")
_CONTROL = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")
# In Composio's message: any rate-limit wording. Anywhere in its data: only Google's own reasons
# (rateLimitExceeded, userRateLimitExceeded), so an unrelated key never turns a refusal into "try again".
_RATE_LIMIT_WORDS = ("ratelimit", "rate limit")
_RATE_LIMIT_REASONS = ("ratelimitexceeded",)  # also matches userratelimitexceeded
_HTTP_STATUS = re.compile(r"\b([45]\d\d) (?:Client|Server) Error|status(?:_code| code)?[\"':= ]+([45]\d\d)\b",
                          re.IGNORECASE)


class CalendarError(composio.ComposioError):
    """An answer of ``{"error": {"code", "message", "retryable", "written"[, "fix"]}}``."""


def _bad(code: str, message: str) -> CalendarError:
    return CalendarError(400, code, message)


# --------------------------------------------------------------------------- the CLI


class ComposioCli(composio.ComposioCli):
    """The shared runner (``samrabbit_composio``) with Google Calendar's words, slugs and connection
    (``--account``): ``account`` when given, else ``SAMRABBIT_CALENDAR_CONNECTION``, else ``DEFAULT_CONNECTION``."""

    def __init__(self, executable: Optional[str] = None, *, timeout: float = CLI_TIMEOUT_SECONDS,
                 account: Optional[str] = None) -> None:
        super().__init__(executable, toolkit=CALENDAR, timeout=timeout,
                         workdir=tempfile.mkdtemp(prefix="samrabbit-calendar-"))  # 0700; the calls' folders go inside
        self.account = account or os.environ.get("SAMRABBIT_CALENDAR_CONNECTION") or DEFAULT_CONNECTION

    def _fallbacks(self) -> Tuple[str, ...]:
        return FALLBACK_COMPOSIO  # this module's, read now (a test may point it at a missing file)

    def execute(self, slug: str, arguments: Dict[str, Any], *, writing: bool,
                account: Optional[str] = None) -> Dict[str, Any]:
        """The tool's ``data`` on success; a ``CalendarError`` otherwise."""
        return super().execute(slug, arguments, writing=writing, account=account or self.account)


def _failure(value: Dict[str, Any], writing: bool) -> CalendarError:
    """Composio's ``{"successful": false, ...}`` as a bridge error. Google applies a change completely or
    not at all, so a refusal means nothing was written; only server errors leave that open."""
    data = value.get("data") if isinstance(value.get("data"), dict) else {}
    message = str(value.get("error") or data.get("message") or "")
    low = (message + " " + str(value.get("slug") or "")).lower()
    try:  # Google's own reason (e.g. "rateLimitExceeded") may sit anywhere in data
        details = json.dumps(data, ensure_ascii=True, default=str)[:20000].lower()
    except (TypeError, ValueError):
        details = ""
    status = data.get("status_code") if isinstance(data.get("status_code"), int) else None
    if status is None:
        match = _HTTP_STATUS.search(message)
        status = int(match.group(1) or match.group(2)) if match else None
    if "noactiveconnection" in low or "no active connection" in low or "composio link" in low \
            or "no connected account" in low:
        return CalendarError(409, "calendar_not_connected", "Google Calendar is not linked in Composio on the Mac.",
                             written=False, fix=LINK_FIX)
    if "input validation failed" in low:
        return CalendarError(400, "calendar_invalid_request", "Google Calendar did not accept those details.",
                             written=False)
    if "toolnotfound" in low:
        return CalendarError(502, "composio_tool_missing", "The Composio CLI on the Mac is missing that Google "
                             "Calendar action. Update it with: composio upgrade", written=False)
    if status == 401 or "invalid_grant" in low or "unauthenticated" in low or "invalid credentials" in low:
        return CalendarError(409, "calendar_not_connected", "Google Calendar needs to be linked again in Composio "
                             "on the Mac.", written=False, fix=LINK_FIX)
    # Google answers 403 rateLimitExceeded / userRateLimitExceeded (and 429) when it wants a slower client: a
    # retry later works, so this is not "forbidden".
    if status == 429 or any(word in low for word in _RATE_LIMIT_WORDS) or \
            any(reason in details for reason in _RATE_LIMIT_REASONS):
        return CalendarError(503, "calendar_rate_limited", "Google Calendar is busy. Try again in a minute.",
                             retryable=True, written=False)
    if status == 403:
        return CalendarError(403, "calendar_forbidden", "Google Calendar didn't allow that change (you may not be "
                             "the organizer, or that calendar is read-only).", written=False)
    if status in (404, 410):
        if "calendar not found" in low:
            return CalendarError(404, "calendar_not_found", "That Google calendar is not in the linked account.",
                                 written=False)
        return CalendarError(404, "calendar_event_not_found", "That event is not in Google Calendar (it may "
                             "have been deleted already).", written=False)
    if status is not None and status >= 500:
        return CalendarError(502, "calendar_google_error", "Google Calendar failed while handling that.",
                             retryable=True, written="unknown" if writing else False)
    if status == 400 or "timerangeempty" in low:
        return CalendarError(422, "calendar_rejected", "Google Calendar refused those details (an event must "
                             "end after it starts).", written=False)
    return CalendarError(502, "calendar_rejected", "Google Calendar did not accept that change.", written=False)


CALENDAR = composio.Toolkit(
    label="Google Calendar", code_prefix="calendar", slugs=composio.CALENDAR_SLUGS, error=CalendarError,
    missing="The Composio CLI is not installed on the Mac, so Google Calendar can't be changed from the R1.",
    signed_out="The Composio CLI on the Mac gave no answer. Check that it is signed in (composio login) and that "
               "Google Calendar is linked.",
    signed_out_fix="Run on the Mac: composio login, then composio link googlecalendar",
    failure=lambda value, writing: _failure(value, writing))


# --------------------------------------------------------------------------- requests


def _text(body: Dict[str, Any], key: str, limit: int, *, required: bool = False) -> Optional[str]:
    value = body.get(key)
    if value is None or (isinstance(value, str) and not value.strip() and not required):
        if required:
            raise _bad("invalid_event", f"{key} is required.")
        return None
    if not isinstance(value, str) or not value.strip():
        raise _bad("invalid_event", f"{key} must be non-empty text.")
    value = value.strip()
    if len(value) > limit or "\x00" in value:
        raise _bad("invalid_event", f"{key} is too long or contains NUL characters.")
    return value


def _instant(body: Dict[str, Any], key: str) -> Optional[Tuple[str, datetime]]:
    value = body.get(key)
    if value is None:
        return None
    match = _DATETIME.match(value) if isinstance(value, str) else None
    if not match:
        raise _bad("invalid_time", f"{key} must be an RFC 3339 time with an offset, e.g. 2026-10-08T10:30:00-04:00.")
    base = match.group(1) if len(match.group(1)) > 16 else match.group(1) + ":00"
    offset = "+00:00" if match.group(2) == "Z" else match.group(2)
    try:
        parsed = datetime.fromisoformat(base + offset)
    except ValueError:
        raise _bad("invalid_time", f"{key} is not a real time.") from None
    return base + offset, parsed


def _zone(body: Dict[str, Any]) -> Optional[str]:
    value = body.get("timezone")
    if value is None:
        return None
    if not isinstance(value, str) or len(value) > 64 or not _TIMEZONE.match(value):
        raise _bad("invalid_timezone", "timezone must be an IANA name such as America/New_York.")
    try:
        from zoneinfo import ZoneInfo

        ZoneInfo(value)
    except Exception:  # noqa: BLE001 - ZoneInfoNotFoundError, ValueError, a missing tz database
        raise _bad("invalid_timezone", "timezone is not a known time zone.") from None
    return value


def _span(start: datetime, end: datetime) -> None:
    if end <= start:
        raise _bad("invalid_time", "The event must end after it starts.")
    if end - start > MAX_SPAN:
        raise _bad("invalid_time", "The event is longer than 31 days.")


def _find_event(value: Any, depth: int = 0) -> Dict[str, Any]:
    """The Google event inside Composio's answer (``data.response_data`` today; tolerant of other wrappers)."""
    if not isinstance(value, dict) or depth > 3:
        return {}
    if isinstance(value.get("id"), str) and ("start" in value or "summary" in value or "iCalUID" in value):
        return value
    for key in ("response_data", "event", "data", "result"):
        found = _find_event(value.get(key), depth + 1)
        if found:
            return found
    return {}


def _time_of(part: Any) -> Optional[str]:
    if isinstance(part, dict):
        for key in ("dateTime", "date"):
            if isinstance(part.get(key), str) and part[key].strip():
                return part[key].strip()
    return None


def _guests(event: Dict[str, Any]) -> Optional[int]:
    """Guests on Google's event (attendees other than the user and rooms); ``None`` when Google sent no event."""
    if not event:
        return None
    attendees = event.get("attendees")
    if not isinstance(attendees, list):
        return 0  # Google leaves "attendees" out when there are none
    return sum(1 for item in attendees if isinstance(item, dict) and not item.get("self")
               and not item.get("resource"))


def _email(value: Any) -> Optional[str]:
    email = value.get("email") if isinstance(value, dict) else None
    return email.strip()[:256] if isinstance(email, str) and _EMAIL.match(email.strip()) else None


# --------------------------------------------------------------------------- the service


class CalendarWriter:
    """Create, update and delete events on one Google calendar (default ``primary``). One CLI call at a time."""

    def __init__(self, cli: ComposioCli, *, calendar_id: Optional[str] = None,
                 account: Optional[str] = None) -> None:
        self.cli = cli
        configured = calendar_id or os.environ.get("SAMRABBIT_CALENDAR_ID") or DEFAULT_CALENDAR_ID
        if not _CALENDAR_ID.match(configured):
            raise ValueError("the Google calendar id is malformed")
        self.calendar_id = configured
        self._account = account if account and _EMAIL.match(account) else None
        self._lock = threading.Lock()
        self._state_lock = threading.Lock()
        self._last_error: Optional[str] = None
        self._last_ok_at: Optional[str] = None

    def close(self) -> None:
        self.cli.close()

    # ------------------------------------------------------------------ status
    def capabilities(self) -> Dict[str, Any]:
        """For ``/health`` and ``/v1/calendar/status``: cheap (no network, no CLI run)."""
        executable = self.cli.executable()
        with self._state_lock:
            account, last_error, last_ok = self._account, self._last_error, self._last_ok_at
        return {"available": executable is not None, "composio": executable is not None, "path": executable,
                "calendarId": self.calendar_id, "account": account, "connection": getattr(self.cli, "account", None),
                "lastError": last_error, "lastOkAt": last_ok}

    # ------------------------------------------------------------------ operations
    def create(self, body: Dict[str, Any]) -> Dict[str, Any]:
        calendar_id = self._calendar(body)
        title = _text(body, "title", MAX_TITLE_CHARS, required=True)
        start, end = _instant(body, "startsAt"), _instant(body, "endsAt")
        if start is None or end is None:
            raise _bad("invalid_time", "startsAt and endsAt are required.")
        _span(start[1], end[1])
        zone = _zone(body)
        arguments: Dict[str, Any] = {
            "calendar_id": calendar_id, "summary": title, "start_datetime": start[0], "end_datetime": end[0],
            # A plain event on the user's own calendar: no Meet link, no attendee list, no emails.
            "create_meeting_room": False, "exclude_organizer": True, "send_updates": "none",
        }
        if zone:
            arguments["timezone"] = zone
        for key, limit in (("description", MAX_DESCRIPTION_CHARS), ("location", MAX_LOCATION_CHARS)):
            value = _text(body, key, limit)
            if value:
                arguments[key] = value
        data = self._call(CREATE_SLUG, arguments, writing=True)
        event = _find_event(data)
        if not isinstance(event.get("id"), str) or not _EVENT_ID.match(event["id"]):
            self._note_error("calendar_bad_answer")
            raise CalendarError(502, "calendar_bad_answer", "Google Calendar answered without the new event's id, "
                                "so it was probably added. Check the calendar before trying again.",
                                written="unknown")
        return {"ok": True, "calendarId": calendar_id, "account": self._learn(event),
                "event": self._view(event, calendar_id, title=title, starts=start[0], ends=end[0], zone=zone)}

    def update(self, body: Dict[str, Any]) -> Dict[str, Any]:
        calendar_id = self._calendar(body)
        start, end = _instant(body, "startsAt"), _instant(body, "endsAt")
        if start is not None and end is not None:
            _span(start[1], end[1])
        changes: Dict[str, Any] = {}
        title = _text(body, "title", MAX_TITLE_CHARS)
        if title:
            changes["summary"] = title
        if start is not None:
            changes["start_time"] = start[0]
        if end is not None:
            changes["end_time"] = end[0]
        for key, limit in (("description", MAX_DESCRIPTION_CHARS), ("location", MAX_LOCATION_CHARS)):
            value = _text(body, key, limit)
            if value:
                changes[key] = value
        if not changes:
            raise _bad("nothing_to_change", "Give a new title, time, description or location.")
        zone = _zone(body)
        if zone and (start is not None or end is not None):
            changes["timezone"] = zone
        with self._serialized():
            event_id = self._resolve(body, calendar_id)
            data = self._run(PATCH_SLUG, {"calendar_id": calendar_id, "event_id": event_id, "send_updates": "none",
                                          **changes}, writing=True)
        event = _find_event(data)
        return {"ok": True, "calendarId": calendar_id, "account": self._learn(event),
                "event": self._view(event, calendar_id, event_id=event_id, title=title,
                                    starts=start[0] if start else None, ends=end[0] if end else None, zone=zone)}

    def delete(self, body: Dict[str, Any]) -> Dict[str, Any]:
        calendar_id = self._calendar(body)
        with self._serialized():
            event_id = self._resolve(body, calendar_id)
            self._run(DELETE_SLUG, {"calendar_id": calendar_id, "event_id": event_id, "send_updates": "none"},
                      writing=True)
        return {"ok": True, "deleted": True, "calendarId": calendar_id, "eventId": event_id}

    # ------------------------------------------------------------------ HTTP
    def route(self, handler: Any, method: str, route: str) -> Tuple[int, Dict[str, Any]]:
        try:
            if route == STATUS_ROUTE:
                _method(method, "GET")
                return 200, self.capabilities()
            operations = {CREATE_ROUTE: self.create, UPDATE_ROUTE: self.update, DELETE_ROUTE: self.delete}
            operation = operations.get(route)
            if operation is None:
                raise CalendarError(404, "not_found", "Not found.")
            _method(method, "POST")
            return 200, operation(handler._json_body())  # noqa: SLF001 - the bridge's bounded JSON reader
        except CalendarError as error:
            return error.status, error.payload()

    # ------------------------------------------------------------------ plumbing
    def _calendar(self, body: Dict[str, Any]) -> str:
        value = body.get("calendarId")
        if value is None or value == "":
            return self.calendar_id
        if not isinstance(value, str) or not _CALENDAR_ID.match(value):
            raise _bad("invalid_calendar", "calendarId is malformed.")
        return value

    def _resolve(self, body: Dict[str, Any], calendar_id: str) -> str:
        """The Google event id: ``eventId`` as given, else from the iCal UID; one occurrence of a repeating
        event is ``<series id>_<recurrenceId>`` (its original start), never the whole series."""
        recurrence = body.get("recurrenceId") or ""
        if not isinstance(recurrence, str) or (recurrence and not _RECURRENCE_ID.match(recurrence)):
            raise _bad("invalid_event", "recurrenceId must be YYYYMMDD or YYYYMMDDTHHMMSSZ.")
        event_id = body.get("eventId")
        if event_id is not None:
            if not isinstance(event_id, str) or not _EVENT_ID.match(event_id) or recurrence:
                raise _bad("invalid_event", "eventId is malformed (give recurrenceId only with iCalUID).")
            return event_id
        uid = body.get("iCalUID")
        if not isinstance(uid, str) or not uid.strip() or len(uid) > MAX_UID_CHARS or _CONTROL.search(uid):
            raise _bad("invalid_event", "iCalUID or eventId is required.")
        uid = uid.strip()
        base = uid[:-len(GOOGLE_UID_SUFFIX)] if uid.lower().endswith(GOOGLE_UID_SUFFIX) else ""
        if not _GOOGLE_ID.match(base):
            base = self._lookup(uid, calendar_id, bool(recurrence))
        return f"{base}_{recurrence}" if recurrence else base

    def _lookup(self, uid: str, calendar_id: str, series: bool) -> str:
        data = self._run(LIST_SLUG, {"calendarId": calendar_id, "iCalUID": uid, "maxResults": 10,
                                     "fields": "items(id,recurringEventId,status)"}, writing=False)
        items = data.get("items")
        if not isinstance(items, list):
            nested = data.get("response_data") if isinstance(data.get("response_data"), dict) else {}
            items = nested.get("items") if isinstance(nested.get("items"), list) else []
        found = [item for item in items if isinstance(item, dict) and isinstance(item.get("id"), str)
                 and _EVENT_ID.match(item["id"]) and item.get("status") != "cancelled"]
        best = next((item for item in found if not item.get("recurringEventId")), found[0] if found else None)
        if best is None:
            raise CalendarError(404, "calendar_event_not_found", "That event is not in Google Calendar (it may have "
                                "been deleted already).", written=False)
        parent = best.get("recurringEventId")
        return parent if series and isinstance(parent, str) and _EVENT_ID.match(parent) else best["id"]

    def _serialized(self) -> "_Slot":
        return _Slot(self._lock)

    def _call(self, slug: str, arguments: Dict[str, Any], *, writing: bool) -> Dict[str, Any]:
        with self._serialized():
            return self._run(slug, arguments, writing=writing)

    def _run(self, slug: str, arguments: Dict[str, Any], *, writing: bool) -> Dict[str, Any]:
        try:
            data = self.cli.execute(slug, arguments, writing=writing)
        except CalendarError as error:
            self._note_error(error.code)
            raise
        with self._state_lock:
            self._last_error = None
            self._last_ok_at = datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
        return data

    def _note_error(self, code: str) -> None:
        with self._state_lock:
            self._last_error = code

    def _learn(self, event: Dict[str, Any]) -> Optional[str]:
        """The Google account behind the linked connection (the event's creator), kept for ``/health``."""
        email = _email(event.get("creator")) or _email(event.get("organizer"))
        with self._state_lock:
            if email:
                self._account = email
            return self._account

    @staticmethod
    def _view(event: Dict[str, Any], calendar_id: str, *, event_id: Optional[str] = None,
              title: Optional[str] = None, starts: Optional[str] = None, ends: Optional[str] = None,
              zone: Optional[str] = None) -> Dict[str, Any]:
        """The event as Google answered, falling back to what was asked for."""
        identifier = event.get("id") if isinstance(event.get("id"), str) else event_id
        uid = event.get("iCalUID") if isinstance(event.get("iCalUID"), str) else None
        start_part = event.get("start") if isinstance(event.get("start"), dict) else {}
        value: Dict[str, Any] = {
            "eventId": identifier,
            "iCalUID": uid or (identifier.split("_", 1)[0] + GOOGLE_UID_SUFFIX if identifier else None),
            "calendarId": calendar_id,
            "title": event.get("summary") if isinstance(event.get("summary"), str) else title,
            "startsAt": _time_of(event.get("start")) or starts,
            "endsAt": _time_of(event.get("end")) or ends,
            "timezone": start_part.get("timeZone") if isinstance(start_part.get("timeZone"), str) else zone,
            "allDay": isinstance(start_part.get("date"), str) and not start_part.get("dateTime"),
            "status": event.get("status") if isinstance(event.get("status"), str) else "confirmed",
        }
        if isinstance(event.get("recurringEventId"), str):
            value["recurringEventId"] = event["recurringEventId"]
        guests = _guests(event)
        if guests is not None:
            value["guests"] = guests  # changes never email them (send_updates "none"); the R1 says so
        return value


class _Slot:
    """One Composio call at a time; a caller waits at most ``LOCK_WAIT_SECONDS``."""

    def __init__(self, lock: threading.Lock) -> None:
        self._lock = lock

    def __enter__(self) -> None:
        if not self._lock.acquire(timeout=LOCK_WAIT_SECONDS):
            raise CalendarError(503, "calendar_busy", "Another calendar change is still running on the Mac.",
                                retryable=True, written=False)

    def __exit__(self, *_exc: Any) -> None:
        self._lock.release()


def _method(method: str, expected: str) -> None:
    if method != expected:
        raise CalendarError(405, "method_not_allowed", f"Use {expected}.")


class _NoCli:
    """The CLI of an ``UnavailableWriter``: never found, never run."""

    def executable(self) -> Optional[str]:
        return None

    def close(self) -> None:
        return None


class UnavailableWriter:
    """Stands in for ``CalendarWriter`` when it could not be set up (a malformed ``SAMRABBIT_CALENDAR_ID``, no
    usable temp folder): ``/health`` says ``calendarWrite.available: false`` with the reason code, every change
    is refused with 503 ``calendar_unavailable``, and the rest of the bridge keeps working."""

    def __init__(self, code: str, message: str) -> None:
        self.cli = _NoCli()
        self.calendar_id: Optional[str] = None
        self.code = code
        self.message = message

    def close(self) -> None:
        return None

    def capabilities(self) -> Dict[str, Any]:
        return {"available": False, "composio": False, "path": None, "calendarId": None, "account": None,
                "connection": None, "lastError": self.code, "lastOkAt": None}

    def route(self, handler: Any, method: str, route: str) -> Tuple[int, Dict[str, Any]]:
        if route == STATUS_ROUTE and method == "GET":
            return 200, self.capabilities()
        if route not in ROUTES:
            return 404, CalendarError(404, "not_found", "Not found.").payload()
        return 503, CalendarError(503, "calendar_unavailable", self.message, written=False).payload()


def make_writer(executable: Optional[str] = None, *, calendar_id: Optional[str] = None,
                account: Optional[str] = None) -> CalendarWriter:
    cli = ComposioCli(executable)
    try:
        return CalendarWriter(cli, calendar_id=calendar_id,
                              account=account or os.environ.get("SAMRABBIT_CALENDAR_ACCOUNT") or None)
    except BaseException:
        cli.close()  # no stray temp folder
        raise


def make_writer_or_unavailable(executable: Optional[str] = None, *, calendar_id: Optional[str] = None,
                               account: Optional[str] = None) -> Any:
    """``make_writer``, or an ``UnavailableWriter`` (logged by code only) when the setup fails."""
    try:
        return make_writer(executable, calendar_id=calendar_id, account=account)
    except ValueError:
        _LOG.warning("calendar changes off: the Google calendar id (--calendar-id / SAMRABBIT_CALENDAR_ID) is "
                     "malformed")
        return UnavailableWriter("calendar_id_invalid", "The Google calendar id configured on the Mac "
                                 "(--calendar-id / SAMRABBIT_CALENDAR_ID) is malformed, so Google Calendar can't be "
                                 "changed from the R1. Fix it and restart the bridge.")
    except OSError as error:
        _LOG.warning("calendar changes off: no private working folder (%s)", type(error).__name__)
        return UnavailableWriter("calendar_setup_failed", "The Mac bridge could not create its private working "
                                 "folder, so Google Calendar can't be changed from the R1. Restart the bridge.")
