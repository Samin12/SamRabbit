"""A stand-in for the Composio CLI (``composio execute <slug> -d - --account <connection>``) used by the calendar,
capture and morning-brief tests.

It never talks to the network. State lives in ``<state dir>/state.json`` (the wrapper script passes the folder
as the first argument, because the bridge runs the CLI with a small environment):

* ``events``: ``{eventId: google event}`` (the fake Google calendar), ``next_id``: a counter for new ids;
* ``gmail``: ``{connection: {"profile": {...}, "messages": [message]}}``: fake mailboxes. A message is
  ``{messageId, threadId, labelIds, messageTimestamp, sender, to, subject, preview: {subject, body}, body?,
  replyTo?}``; ``GMAIL_FETCH_EMAILS`` understands ``after:<epoch>``, ``in:inbox`` / ``in:sent``, ``max_results``,
  ``page_token`` (an offset), ``ids_only`` and ``verbose``. Drafts made are appended to ``drafts``; a send tool
  (which the bridge must never run) is appended to ``sent``;
* ``scripted``: ``{slug: {"stdout": str, "rc": int, "sleep": seconds}}`` answers printed instead;
* ``slow``: ``{slug: seconds}``;
* ``dump``: true makes every call leave ``$TMPDIR/composio/adhoc_<n>/<SLUG>_OUTPUT_<n>.json`` behind, as the real
  CLI does for answers over about 40 KB.

Every call is appended to ``calls.jsonl``: ``{argv, slug, account, args, env, tmpdir, cwd, start}``.
"""

from __future__ import annotations

import json
import os
import sys
import time

STATE_DIR = sys.argv[1]
ARGV = sys.argv[2:]


def _state() -> dict:
    with open(os.path.join(STATE_DIR, "state.json"), encoding="utf-8") as handle:
        return json.load(handle)


def _save(state: dict) -> None:
    path = os.path.join(STATE_DIR, "state.json")
    temporary = f"{path}.{os.getpid()}.tmp"  # two calls may run at once (one per mailbox)
    with open(temporary, "w", encoding="utf-8") as handle:
        json.dump(state, handle)
    os.replace(temporary, path)


def _record(entry: dict) -> None:
    with open(os.path.join(STATE_DIR, "calls.jsonl"), "a", encoding="utf-8") as handle:
        handle.write(json.dumps(entry) + "\n")


def _ok(data: dict) -> dict:
    return {"successful": True, "data": data, "error": None, "logId": "log_fake"}


def _not_found() -> dict:
    return {"successful": False, "data": {"message": "Not Found", "status_code": 404}, "error": "Not Found",
            "logId": "log_fake"}


def _part(value: object) -> str:
    if isinstance(value, dict):
        return str(value.get("dateTime") or (value.get("date", "") + "T00:00:00-04:00" if value.get("date") else ""))
    return ""


def _instant(value: str):
    from datetime import datetime, timezone

    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)


def _when(value: str, zone: str | None) -> dict:
    part = {"dateTime": value}
    if zone:
        part["timeZone"] = zone
    return part


def _tool(slug: str, args: dict, state: dict, account: str = "") -> dict:
    events = state.setdefault("events", {})
    if slug == "GOOGLECALENDAR_CREATE_EVENT":
        number = int(state.get("next_id", 1))
        state["next_id"] = number + 1
        event_id = f"fakeevent{number:04d}abc"
        event = {"id": event_id, "iCalUID": event_id + "@google.com", "status": "confirmed",
                 "summary": args.get("summary"), "description": args.get("description"),
                 "location": args.get("location"), "calendarId": args.get("calendar_id"),
                 "start": _when(args["start_datetime"], args.get("timezone")),
                 "end": _when(args["end_datetime"], args.get("timezone")),
                 "creator": {"email": "samin@aianswer.us"}, "organizer": {"email": "samin@aianswer.us", "self": True},
                 "htmlLink": "https://www.google.com/calendar/event?eid=fake"}
        events[event_id] = event
        return _ok({"response_data": event})
    if slug == "GOOGLECALENDAR_PATCH_EVENT":
        event_id = args.get("event_id", "")
        base = event_id.split("_", 1)[0]
        if event_id not in events and base not in events:
            return _not_found()
        event = dict(events.get(event_id) or {**events[base], "id": event_id, "recurringEventId": base})
        if "summary" in args:
            event["summary"] = args["summary"]
        if "start_time" in args:
            event["start"] = _when(args["start_time"], args.get("timezone"))
        if "end_time" in args:
            event["end"] = _when(args["end_time"], args.get("timezone"))
        for key in ("description", "location"):
            if key in args:
                event[key] = args[key]
        events[event_id] = event
        return _ok({"response_data": event})
    if slug == "GOOGLECALENDAR_DELETE_EVENT":
        event_id = args.get("event_id", "")
        base = event_id.split("_", 1)[0]
        if event_id in events:
            events.pop(event_id)
        elif base in events and "_" in event_id:
            state.setdefault("cancelled_instances", []).append(event_id)
        else:
            return _not_found()
        return _ok({})
    if slug == "GOOGLECALENDAR_EVENTS_LIST" and args.get("iCalUID") is None and args.get("timeMin"):
        # An agenda window (the mobile API): whole events overlapping [timeMin, timeMax), by start time.
        low, high = _instant(args["timeMin"]), _instant(args.get("timeMax") or "9999-12-31T00:00:00Z")
        found = []
        for event in events.values():
            start, end = _instant(_part(event.get("start"))), _instant(_part(event.get("end")))
            if start is not None and end is not None and end > low and start < high:
                found.append(event)
        found.sort(key=lambda item: _instant(_part(item.get("start"))))
        return _ok({"items": found[:int(args.get("maxResults") or 250)], "timeZone": args.get("timeZone")})
    if slug == "GOOGLECALENDAR_EVENTS_LIST":
        uid = args.get("iCalUID")
        items = [{"id": event["id"], "status": event.get("status", "confirmed"),
                  **({"recurringEventId": event["recurringEventId"]} if event.get("recurringEventId") else {})}
                 for event in events.values() if uid is None or event.get("iCalUID") == uid]
        return _ok({"items": items})
    if slug.startswith("GMAIL_"):
        return _gmail(slug, args, state, account)
    return {"successful": False, "error": f"Tool {slug} not found", "slug": "ToolRouterV2_ToolNotFound"}


def _epoch(value: str) -> float:
    parsed = _instant(value or "")
    return parsed.timestamp() if parsed is not None else 0.0


def _headers(message: dict) -> list:
    headers = [{"name": "From", "value": message.get("sender", "")}, {"name": "To", "value": message.get("to", "")},
               {"name": "Subject", "value": message.get("subject", "")},
               {"name": "Message-ID", "value": "<" + message["messageId"] + "@mail.example>"}]
    if message.get("replyTo"):
        headers.append({"name": "Reply-To", "value": message["replyTo"]})
    return headers


def _gmail(slug: str, args: dict, state: dict, account: str) -> dict:
    box = (state.get("gmail") or {}).get(account)
    if box is None:
        return {"successful": False, "error": "No active connection found for toolkit gmail. Run composio link gmail",
                "data": {}}
    messages = list(box.get("messages") or [])
    if slug == "GMAIL_GET_PROFILE":
        return _ok(dict(box.get("profile") or {}, messagesTotal=len(messages)))
    if slug == "GMAIL_FETCH_EMAILS":
        query = str(args.get("query") or "")
        after = 0.0
        folder = "INBOX"
        for word in query.split():
            if word.startswith("after:") and word[6:].isdigit():
                after = float(word[6:])
            elif word == "in:sent":
                folder = "SENT"
        found = [item for item in messages if folder in (item.get("labelIds") or []) and
                 _epoch(item.get("messageTimestamp", "")) > after and
                 not ({"CATEGORY_PROMOTIONS", "CATEGORY_SOCIAL", "CATEGORY_FORUMS"} & set(item.get("labelIds") or [])
                      and "-category:promotions" in query)]
        found.sort(key=lambda item: _epoch(item.get("messageTimestamp", "")), reverse=True)
        size = int(args.get("max_results") or 1)
        offset = int(args.get("page_token") or 0)
        page = found[offset:offset + size]
        if args.get("ids_only"):
            shown = [{"messageId": item["messageId"], "threadId": item["threadId"]} for item in page]
        else:
            shown = [{key: item.get(key) for key in ("messageId", "threadId", "labelIds", "messageTimestamp",
                                                     "sender", "to", "subject", "preview")} for item in page]
            for item in shown:
                item.update({"messageText": "", "attachmentList": [],
                             "display_url": "https://mail.google.com/mail/u/0/#inbox/" + item["messageId"]})
        value = {"messages": shown, "resultSizeEstimate": len(found)}
        if offset + size < len(found):
            value["nextPageToken"] = str(offset + size)
        return _ok(value)
    if slug == "GMAIL_FETCH_MESSAGE_BY_THREAD_ID":
        thread = [dict(item, messageText=item.get("body") or (item.get("preview") or {}).get("body", ""),
                       payload={"headers": _headers(item)})
                  for item in messages if item["threadId"] == args.get("thread_id")]
        thread.sort(key=lambda item: _epoch(item.get("messageTimestamp", "")))
        return _ok({"messages": thread})
    if slug == "GMAIL_FETCH_MESSAGE_BY_MESSAGE_ID":
        item = next((entry for entry in messages if entry["messageId"] == args.get("message_id")), None)
        if item is None:
            return _not_found()
        value = {"messageId": item["messageId"], "threadId": item["threadId"], "labelIds": item.get("labelIds"),
                 "payload": {"headers": _headers(item)}}
        if args.get("format") != "metadata":
            value["messageText"] = item.get("body") or ""
        return _ok(value)
    if slug == "GMAIL_CREATE_EMAIL_DRAFT":
        drafts = state.setdefault("drafts", [])
        number = len(drafts) + 1
        drafts.append({"account": account, "args": args})
        return _ok({"id": f"r-fake{number:03d}", "message": {"id": f"draftmsg{number:04d}",
                                                              "threadId": args.get("thread_id"),
                                                              "labelIds": ["DRAFT"]}})
    if slug in ("GMAIL_SEND_EMAIL", "GMAIL_SEND_DRAFT", "GMAIL_REPLY_TO_THREAD", "GMAIL_FORWARD_MESSAGE"):
        state.setdefault("sent", []).append({"slug": slug, "account": account, "args": args})
        return _ok({"id": "sent"})
    return {"successful": False, "error": f"Tool {slug} not found", "slug": "ToolRouterV2_ToolNotFound"}


def _parse(argv: list):
    """``execute <slug> -d - [--account <connection>]`` (the flags in any order) -> (slug, account) or None."""
    if len(argv) < 4 or argv[0] != "execute":
        return None
    slug, rest, account = argv[1], argv[2:], None
    seen_data = False
    while rest:
        if rest[:2] == ["-d", "-"]:
            seen_data, rest = True, rest[2:]
        elif rest[0] == "--account" and len(rest) >= 2:
            account, rest = rest[1], rest[2:]
        else:
            return None
    return (slug, account) if seen_data else None


def main() -> int:
    if ARGV[:1] == ["--version"]:
        print("0.4.2")
        return 0
    parsed = _parse(ARGV)
    if parsed is None:
        print("usage: composio execute <slug> -d - [--account <connection>]", file=sys.stderr)
        return 2
    slug, account = parsed
    raw = sys.stdin.read()
    args = json.loads(raw or "{}")
    state = _state()
    started = time.time()
    scripted = (state.get("scripted") or {}).get(slug)
    time.sleep(float((state.get("slow") or {}).get(slug, 0)))
    _record({"argv": ARGV, "slug": slug, "account": account, "args": args, "env": sorted(os.environ),
             "tmpdir": os.environ.get("TMPDIR"), "cwd": os.getcwd(), "start": started})
    if state.get("dump") and os.environ.get("TMPDIR"):
        folder = os.path.join(os.environ["TMPDIR"], "composio", "adhoc_fake1")
        os.makedirs(folder, exist_ok=True)
        with open(os.path.join(folder, slug + "_OUTPUT_fake1.json"), "w", encoding="utf-8") as handle:
            json.dump({"args": args}, handle)
    if scripted is not None:
        time.sleep(float(scripted.get("sleep", 0)))
        sys.stdout.write(scripted.get("stdout", ""))
        return int(scripted.get("rc", 0))
    result = _tool(slug, args, state, account or "")
    _save(state)
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
