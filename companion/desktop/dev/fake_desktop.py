"""The SamRabbit window's desktop twins of the mobile routes (CONTRACTS-WAVE7 §A), with realistic fixtures, for
``fake_sync_server.py`` (behind the desktop token and the loopback check the server already does):

* ``GET /v1/desktop/summary`` -> the phone's summary (``/v1/mobile/summary``: ``mac``, ``r1``, ``t3``, ``calendar``
  (the next three), ``latestConversation``, ``journal``, ``transcribe``, ``assistant``) plus ``r1.online`` and the
  paired ``devices``; the R1 part comes from the fake sync store's conversations, like the bridge's.
* ``GET /v1/desktop/calendar/agenda?days=1..7`` (or ``?hours=``) -> ``{available, timezone, from, to, events:
  [{eventId, title, startsAt, endsAt, allDay, location, meetingUrl}], updatedAt}``: a week of meetings around now
  (from now on, as the bridge reads Google Calendar); 503 ``calendar_unavailable`` while the calendar is off.
* ``POST /v1/desktop/calendar/block {minutes, title?}`` -> ``{ok, calendarId, event, minutes}`` (the block joins the
  agenda); ``POST /v1/desktop/journal {text}`` -> ``{recorded, date, time}`` (kept in memory only: this never
  writes to any journal).
* ``GET /v1/desktop/devices``, ``DELETE /v1/desktop/devices/<id>`` (a phone's watch goes with it).
* ``GET /v1/assistant/chatgpt/status`` -> connected through the Codex login on this Mac.
* Dev controls: ``POST /dev/desktop {calendar?, chatgpt?: "codex"|"own"|"off", r1Online?, journal?}`` switches the
  states the window shows (a calendar that can't be read, ChatGPT not connected, …), ``GET /dev/desktop`` says what
  arrived (blocks, notes: counts and titles only) and how often the window read each route (``reads``),
  ``POST /dev/desktop/reset``.

Stdlib only.
"""

from __future__ import annotations

import json
import re
import threading
import time
from datetime import datetime, timedelta, timezone
from typing import Any, Callable, Dict, List, Optional, Tuple
from urllib.parse import parse_qs, unquote

MINUTE = 60
HOUR = 60 * MINUTE
MAX_NOTE_CHARS = 4000
_DEVICE_ID = re.compile(r"^[A-Za-z0-9_]{1,40}$")


class Refusal(Exception):
    def __init__(self, status: int, code: str, message: str, retryable: bool = False) -> None:
        super().__init__(message)
        self.status, self.code, self.message, self.retryable = status, code, message, retryable


def local_now() -> datetime:
    return datetime.now().astimezone()


def iso_utc(moment: datetime) -> str:
    return moment.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def iso_local(moment: datetime) -> str:
    return moment.isoformat(timespec="seconds")


def quarter(moment: datetime) -> datetime:
    """Down to the quarter hour (meetings start on the quarter)."""
    return moment.replace(minute=moment.minute - moment.minute % 15, second=0, microsecond=0)


def at(day: datetime, clock: str) -> datetime:
    hour, minute = (int(part) for part in clock.split(":"))
    return day.replace(hour=hour, minute=minute, second=0, microsecond=0)


class FakeDesktop:
    def __init__(self, conversations: Optional[Callable[[], List[Dict[str, Any]]]] = None) -> None:
        self.conversations = conversations or (lambda: [])
        self.lock = threading.Lock()
        self.reset()

    def reset(self) -> None:
        with self.lock:
            self.started = local_now()
            self.calendar_on = True
            self.journal_on = True
            self.chatgpt = "codex"
            self.r1_online: Optional[bool] = None  # None: from the conversations, like the bridge
            self.blocks: List[Dict[str, Any]] = []
            self.notes: List[Dict[str, Any]] = []
            self.created = 0
            # What the window read (each summary read makes the real bridge look at the calendar and the journal).
            self.reads = {"summary": 0, "agenda": 0, "devices": 0, "chatgpt": 0}
            now = self.started
            self.devices = [
                {"deviceId": "dev_iphone_9f3a", "name": "Samin’s iPhone", "platform": "ios",
                 "createdAt": iso_utc(now - timedelta(days=12, hours=3)), "lastSeenAt": iso_utc(now - timedelta(minutes=3))},
                {"deviceId": "dev_watch_51c2", "name": "Samin’s Apple Watch", "platform": "watchos",
                 "parentId": "dev_iphone_9f3a", "createdAt": iso_utc(now - timedelta(days=11, hours=20)),
                 "lastSeenAt": iso_utc(now - timedelta(minutes=26))},
            ]
            self.events = self.week(now)

    @staticmethod
    def handles(path: str) -> bool:
        return (path.startswith("/v1/desktop/") and not path.startswith(("/v1/desktop/inbox", "/v1/desktop/assistant/"))) \
            or path == "/v1/assistant/chatgpt/status" or path == "/dev/desktop" or path.startswith("/dev/desktop/")

    # ------------------------------------------------------------------ fixtures

    @staticmethod
    def week(now: datetime) -> List[Dict[str, Any]]:
        """A believable week on the clock (the agenda, like Google Calendar through the bridge, starts at now)."""
        def event(eid: str, title: str, start: datetime, minutes: int, location: Optional[str] = None,
                  meeting: Optional[str] = None) -> Dict[str, Any]:
            return {"eventId": eid, "title": title, "startsAt": iso_local(start),
                    "endsAt": iso_local(start + timedelta(minutes=minutes)), "allDay": False, "location": location,
                    "meetingUrl": meeting}

        def all_day(eid: str, title: str, day: datetime, days: int = 1) -> Dict[str, Any]:
            start = day.replace(hour=0, minute=0, second=0, microsecond=0)
            # As the bridge sends them: local midnight to midnight, with the offset.
            return {"eventId": eid, "title": title, "startsAt": iso_local(start),
                    "endsAt": iso_local(start + timedelta(days=days)), "allDay": True, "location": None,
                    "meetingUrl": None}

        today = now.replace(hour=0, minute=0, second=0, microsecond=0)
        day = [today + timedelta(days=offset) for offset in range(8)]
        events = [
            event("ev_standup_0", "Standup", at(day[0], "09:30"), 15, meeting="https://meet.google.com/xyz-abcd-efg"),
            event("ev_review", "Design review: Agent Dock and the Mac window", at(day[0], "11:00"), 45,
                  meeting="https://meet.google.com/abc-defg-hij"),
            event("ev_one_on_one", "1:1 with Priya", at(day[0], "14:00"), 30,
                  location="https://us02web.zoom.us/j/81234567890", meeting="https://us02web.zoom.us/j/81234567890"),
            event("ev_gym", "Gym", at(day[0], "18:30"), 60, location="Equinox Hudson Yards"),
            event("ev_standup_1", "Standup", at(day[1], "09:30"), 15, meeting="https://meet.google.com/xyz-abcd-efg"),
            event("ev_club", "Claude Club live: building agents that run your day — Q&A and teardown of member builds",
                  at(day[1], "12:00"), 90, meeting="https://meet.google.com/club-live-now"),
            event("ev_dentist", "Dentist", at(day[1], "16:00"), 45, location="Smile Studio, 210 5th Ave"),
            all_day("ev_birthday", "Mom’s birthday", day[2]),
            event("ev_investors", "Investor update call", at(day[2], "10:00"), 30,
                  meeting="https://meet.google.com/inv-upda-tec"),
            event("ev_sync", "Sam / Jordan product sync", at(day[2], "15:30"), 45),
            all_day("ev_travel", "Travel to San Francisco", day[3], 2),
            event("ev_flight", "Flight UA 1532 JFK → SFO", at(day[3], "08:05"), 385, location="JFK Terminal 7"),
            event("ev_dinner", "Dinner with the Bookedin team", at(day[4], "19:30"), 120, location="Nopa, 560 Divisadero St"),
            event("ev_lunch", "Lunch with Alex", at(day[6], "12:30"), 60, location="Café Altro Paradiso"),
        ]
        # During the working day one block is on right now (the "now" line and "until …" show).
        if 8 <= now.hour < 20:
            events.append(event("ev_focus", "Focus · SamRabbit window", quarter(now) - timedelta(minutes=30), 75))
        return events

    # ------------------------------------------------------------------ dispatch

    def handle(self, handler: Any, method: str, path: str, query: str) -> None:
        body = self.read_body(handler, method)
        try:
            if path == "/dev/desktop":
                if method == "GET":
                    return handler.json(200, self.arrived())
                self.only(method, "POST")
                return handler.json(200, self.dev(body))
            if path == "/dev/desktop/reset":
                self.only(method, "POST")
                self.reset()
                return handler.json(200, {"ok": True})
            if path == "/v1/assistant/chatgpt/status":
                self.only(method, "GET")
                self.count("chatgpt")
                return handler.json(200, self.chatgpt_status())
            if path == "/v1/desktop/summary":
                self.only(method, "GET")
                self.count("summary")
                return handler.json(200, self.summary())
            if path == "/v1/desktop/calendar/agenda":
                self.only(method, "GET")
                self.count("agenda")
                return handler.json(200, self.agenda(parse_qs(query)))
            if path == "/v1/desktop/calendar/block":
                self.only(method, "POST")
                return handler.json(200, self.block(body))
            if path == "/v1/desktop/journal":
                self.only(method, "POST")
                return handler.json(200, self.journal(body))
            if path == "/v1/desktop/devices":
                self.only(method, "GET")
                self.count("devices")
                with self.lock:
                    return handler.json(200, {"devices": [dict(d) for d in self.devices]})
            if path.startswith("/v1/desktop/devices/"):
                self.only(method, "DELETE")
                return handler.json(200, self.unpair(unquote(path[len("/v1/desktop/devices/"):])))
            raise Refusal(404, "not_found", "Not found.")
        except Refusal as refusal:
            handler.json(refusal.status, {"error": {"code": refusal.code, "message": refusal.message,
                                                    "retryable": refusal.retryable}})

    def count(self, what: str) -> None:
        with self.lock:
            self.reads[what] += 1

    @staticmethod
    def only(method: str, allowed: str) -> None:
        if method != allowed:
            raise Refusal(405, "method_not_allowed", "Method not allowed.")

    @staticmethod
    def read_body(handler: Any, method: str) -> Dict[str, Any]:
        if method not in ("POST", "DELETE"):
            return {}
        length = int(handler.headers.get("Content-Length") or 0)
        raw = handler.rfile.read(min(length, 65536)) if length else b""
        try:
            value = json.loads(raw or b"{}")
        except ValueError:
            return {"_bad": True}
        return value if isinstance(value, dict) else {"_bad": True}

    # ------------------------------------------------------------------ routes

    def r1_part(self) -> Tuple[Dict[str, Any], Optional[Dict[str, Any]]]:
        mine = [c for c in self.conversations() if (c.get("device") or "r1") != "mac"]
        r1: Dict[str, Any] = {"lastSeenAt": None, "live": False, "liveConversationId": None, "liveTitle": None}
        if mine:
            last = max(int(c.get("lastAt") or 0) for c in mine)
            r1["lastSeenAt"] = iso_utc(datetime.fromtimestamp(last / 1000, timezone.utc))
        live = next((c for c in mine if c.get("live")), None)
        if live:
            r1.update(live=True, liveConversationId=live["conversationId"], liveTitle=live.get("title") or "Live conversation")
        seen = (time.time() * 1000 - max(int(c.get("lastAt") or 0) for c in mine)) if mine else None
        r1["online"] = self.r1_online if self.r1_online is not None else bool(live) or (seen is not None and seen < 10 * 60_000)
        latest = mine[0] if mine else None
        return r1, ({"conversationId": latest["conversationId"], "title": latest.get("title") or "Conversation",
                     "lastAt": iso_utc(datetime.fromtimestamp(int(latest["lastAt"]) / 1000, timezone.utc)),
                     "preview": latest.get("preview"), "live": bool(latest.get("live"))} if latest else None)

    def upcoming(self, hours: int) -> List[Dict[str, Any]]:
        now = local_now()
        until = now + timedelta(hours=hours)
        with self.lock:
            events = [dict(e) for e in self.events + self.blocks]
        out = []
        for event in events:
            start, end = self.bounds(event)
            if end > now and start < until:
                out.append(event)
        return sorted(out, key=lambda e: (self.bounds(e)[0], e["title"]))

    @staticmethod
    def bounds(event: Dict[str, Any]) -> Tuple[datetime, datetime]:
        return (datetime.fromisoformat(event["startsAt"].replace("Z", "+00:00")),
                datetime.fromisoformat(event["endsAt"].replace("Z", "+00:00")))

    def summary(self) -> Dict[str, Any]:
        now = local_now()
        r1, latest = self.r1_part()
        events = self.upcoming(24) if self.calendar_on else []
        timed = [e for e in events if not e["allDay"]]
        nxt = (timed + [e for e in events if e["allDay"]])[:3]
        connected = self.chatgpt != "off"
        with self.lock:
            devices = [dict(d) for d in self.devices]
        return {
            "generatedAt": iso_utc(now),
            "mac": {"name": "Samin’s Mac Studio", "online": True, "screenLocked": False},
            "r1": r1,
            "t3": {"available": True, "connected": True, "counts": {"needsYou": 3, "working": 2, "done": 7, "error": 1}},
            "calendar": {"available": self.calendar_on,
                         "next": [{k: e.get(k) for k in ("title", "startsAt", "endsAt", "allDay", "location", "meetingUrl")}
                                  for e in nxt], **({} if self.calendar_on else {"reason": "calendar_unavailable"})},
            "latestConversation": latest,
            "journal": {"available": self.journal_on, **({} if self.journal_on else {"reason": "heptabase_closed"})},
            "transcribe": {"available": True},
            "assistant": {"available": True, "brain": "realtime" if connected else "claude",
                          "model": "gpt-realtime-2.1" if connected else "claude-haiku-5-5",
                          "chatgpt": {"connected": connected}},
            "devices": devices,
        }

    def agenda(self, query: Dict[str, List[str]]) -> Dict[str, Any]:
        if not self.calendar_on:
            raise Refusal(503, "calendar_unavailable", "Google Calendar can't be read from the Mac right now.", True)
        raw_days = (query.get("days") or [""])[0]
        raw_hours = (query.get("hours") or [""])[0]
        if raw_days:
            if not raw_days.isdigit() or not 1 <= int(raw_days) <= 7:
                raise Refusal(400, "invalid_days", "days must be a whole number from 1 to 7.")
            hours = int(raw_days) * 24
        elif raw_hours:
            if not raw_hours.isdigit() or not 1 <= int(raw_hours) <= 168:
                raise Refusal(400, "invalid_hours", "hours must be a whole number from 1 to 168.")
            hours = int(raw_hours)
        else:
            hours = 24
        now = local_now()
        return {"available": True, "timezone": "America/New_York", "from": iso_local(now),
                "to": iso_local(now + timedelta(hours=hours)), "calendarId": "primary",
                "events": self.upcoming(hours), "updatedAt": iso_utc(now), "cached": False}

    def block(self, body: Dict[str, Any]) -> Dict[str, Any]:
        minutes = body.get("minutes")
        if isinstance(minutes, float) and minutes.is_integer():
            minutes = int(minutes)
        if isinstance(minutes, bool) or not isinstance(minutes, int) or not 5 <= minutes <= 480:
            raise Refusal(400, "invalid_minutes", "minutes must be a whole number from 5 to 480.")
        if not self.calendar_on:
            raise Refusal(503, "calendar_unavailable", "Google Calendar can't be reached from the Mac right now.", True)
        title = body.get("title")
        title = " ".join(title.split())[:120] if isinstance(title, str) and title.strip() else "Focus"
        start = local_now().replace(second=0, microsecond=0)
        end = start + timedelta(minutes=minutes)
        with self.lock:
            self.created += 1
            event = {"eventId": "blk_%d" % self.created, "title": title, "startsAt": iso_local(start),
                     "endsAt": iso_local(end), "allDay": False, "location": None, "meetingUrl": None}
            self.blocks.append(event)
        return {"ok": True, "calendarId": "primary", "event": dict(event, status="confirmed"), "minutes": minutes}

    def journal(self, body: Dict[str, Any]) -> Dict[str, Any]:
        text = body.get("text")
        if not isinstance(text, str) or not text.strip():
            raise Refusal(400, "invalid_text", "text must be the note to add.")
        if len(text) > MAX_NOTE_CHARS or "\x00" in text:
            raise Refusal(400, "invalid_text", f"The note must be at most {MAX_NOTE_CHARS} characters.")
        if not self.journal_on:
            raise Refusal(503, "heptabase_closed", "Heptabase isn't open on the Mac.", True)
        now = local_now()
        with self.lock:
            self.notes.append({"text": " ".join(text.split()), "at": iso_utc(now)})
        return {"recorded": True, "date": now.date().isoformat(), "time": now.strftime("%H:%M")}

    def unpair(self, device_id: str) -> Dict[str, Any]:
        if not _DEVICE_ID.match(device_id):
            raise Refusal(404, "device_not_found", "No such device.")
        with self.lock:
            gone = [d for d in self.devices if d["deviceId"] == device_id or d.get("parentId") == device_id]
            if not any(d["deviceId"] == device_id for d in gone):
                raise Refusal(404, "device_not_found", "No such device.")
            self.devices = [d for d in self.devices if d not in gone]
        return {"ok": True, "revoked": len(gone)}

    def chatgpt_status(self) -> Dict[str, Any]:
        if self.chatgpt == "off":
            return {"connected": False, "login": {"state": "idle"}}
        value = {"connected": True, "plan": "pro", "email": "sam@example.com", "login": {"state": "idle"}}
        if self.chatgpt == "codex":
            value["source"] = "codex"
        return value

    # ------------------------------------------------------------------ dev controls

    def dev(self, body: Dict[str, Any]) -> Dict[str, Any]:
        with self.lock:
            if isinstance(body.get("calendar"), bool):
                self.calendar_on = body["calendar"]
            if isinstance(body.get("journal"), bool):
                self.journal_on = body["journal"]
            if body.get("chatgpt") in ("codex", "own", "off"):
                self.chatgpt = body["chatgpt"]
            if "r1Online" in body and (body["r1Online"] is None or isinstance(body["r1Online"], bool)):
                self.r1_online = body["r1Online"]
        return {"ok": True, "calendar": self.calendar_on, "journal": self.journal_on, "chatgpt": self.chatgpt,
                "r1Online": self.r1_online}

    def arrived(self) -> Dict[str, Any]:
        with self.lock:
            return {"blocks": [{"title": b["title"], "startsAt": b["startsAt"], "endsAt": b["endsAt"]} for b in self.blocks],
                    "notes": len(self.notes), "devices": [d["deviceId"] for d in self.devices], "reads": dict(self.reads)}
