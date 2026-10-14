"""The morning briefing as the R1 keeps it (pure): the bridge's brief normalized, trimmed and bounded.

Shape kept in the cache and served to the app::

    {date, revision, status, headline, spoken, updatedAt, needsYou, footer,
     sections: [{id: do_first|today|agents|fyi, title, items: [Item]}]}
    Item = {id, kind, section, title, why, suggestion?, account?, time?, conflict?, threadId?, state,
            actions: [{type, label}]}

Limits (CONTRACTS-WAVE8 A3): Do first ≤ 3, Today ≤ 5, Agents ≤ 3, FYI ≤ 3, ≤ 12 items. The R1 offers only these
actions: Draft reply (a Gmail DRAFT, never sent), Make task, Block time, Remind me, Done, Dismiss, Open. Anything
else the bridge lists (approve, send, …) is dropped here, so no R1 surface can ever offer it.
"""

from __future__ import annotations

import re

SECTIONS = (("do_first", "Do first", 3), ("today", "Today", 5), ("agents", "Agents", 3), ("fyi", "FYI", 3))
MAX_ITEMS = 12
ACTION_LABELS = {"draft_reply": "Draft reply", "make_task": "Make task", "block_time": "Block time",
                 "remind": "Remind me", "done": "Done", "dismiss": "Dismiss", "open": "Open"}
_ACTION_ALIASES = {"draft_reply": "draft_reply", "draft": "draft_reply", "make_task": "make_task",
                   "task": "make_task", "make_t3_task": "make_task", "t3_task": "make_task",
                   "block_time": "block_time", "block": "block_time", "remind": "remind", "remind_me": "remind",
                   "snooze": "remind", "done": "done", "dismiss": "dismiss", "open": "open"}
_SECTION_ALIASES = {"do_first": "do_first", "dofirst": "do_first", "first": "do_first", "today": "today",
                    "events": "today", "calendar": "today", "agents": "agents", "agent": "agents", "fyi": "fyi"}
CLOSED_STATES = frozenset({"done", "dismissed"})
STATES = frozenset({"open", "drafted", "tasked", "blocked", "snoozed", "done", "dismissed"})
_ID = re.compile(r"^[A-Za-z0-9._:\-]{1,80}$")


def flat(value: object, limit: int) -> str:
    text = " ".join(str(value or "").split()) if isinstance(value, (str, int, float)) else ""
    return text if len(text) <= limit else text[:limit - 1].rstrip() + "…"


def action_type(value: object) -> str | None:
    key = re.sub(r"[^a-z_]", "", str(value or "").strip().lower().replace("-", "_").replace(" ", "_"))
    return _ACTION_ALIASES.get(key)


def section_id(value: object) -> str | None:
    key = re.sub(r"[^a-z]", "", str(value or "").strip().lower())
    return _SECTION_ALIASES.get(key) or _SECTION_ALIASES.get(re.sub(r"[^a-z_]", "", str(value or "").lower()))


def normalize(raw: object) -> dict[str, object] | None:
    """The bridge's brief (wrapped in ``briefing`` or not; sections as a list, a map or a flat item list)."""
    if not isinstance(raw, dict):
        return None
    brief = raw.get("briefing") if isinstance(raw.get("briefing"), dict) else raw
    date = flat(brief.get("date"), 10)
    if not re.match(r"^\d{4}-\d{2}-\d{2}$", date):
        return None
    grouped: dict[str, list[dict[str, object]]] = {key: [] for key, _title, _limit in SECTIONS}
    for section, items in _raw_sections(brief):
        for item in items:
            normalized = _item(item, section)
            if normalized is not None:
                grouped[str(normalized["section"])].append(normalized)
    sections = []
    total = 0
    for key, title, limit in SECTIONS:
        kept = []
        for item in grouped[key][:limit]:
            if total >= MAX_ITEMS:
                break
            kept.append(item)
            total += 1
        sections.append({"id": key, "title": title, "items": kept})
    revision = brief.get("revision")
    needs = brief.get("needsYou")
    open_first = sum(1 for item in sections[0]["items"] if item["state"] == "open")
    return {
        "date": date,
        "revision": int(revision) if isinstance(revision, (int, float)) and not isinstance(revision, bool) else 0,
        "status": flat(brief.get("status"), 16) or "ready",
        "headline": flat(brief.get("headline"), 90),
        "spoken": flat(brief.get("spoken"), 400),
        "updatedAt": flat(brief.get("updatedAt") or brief.get("builtAt"), 40) or None,
        "needsYou": int(needs) if isinstance(needs, int) and not isinstance(needs, bool) and needs >= 0 else open_first,
        "footer": flat(brief.get("footer"), 120),
        "sections": sections,
    }


def items(brief: dict[str, object] | None) -> list[dict[str, object]]:
    """Every item in display order (Do first, Today, Agents, FYI)."""
    if not isinstance(brief, dict):
        return []
    out: list[dict[str, object]] = []
    for section in brief.get("sections") or []:
        if isinstance(section, dict):
            out.extend(item for item in section.get("items") or [] if isinstance(item, dict))
    return out


def find(brief: dict[str, object] | None, item_id: str) -> dict[str, object] | None:
    for item in items(brief):
        if item.get("id") == item_id:
            return item
    return None


def open_count(brief: dict[str, object] | None) -> int:
    return sum(1 for item in items(brief) if item.get("state") not in CLOSED_STATES)


def allowed(item: dict[str, object], action: str) -> bool:
    """Done and Dismiss always; otherwise only an action the item itself offers."""
    if action in ("done", "dismiss"):
        return True
    return any(isinstance(entry, dict) and entry.get("type") == action for entry in item.get("actions") or [])


def with_state(brief: dict[str, object], item_id: str, state: str) -> dict[str, object]:
    """A copy of ``brief`` with one item's state changed (the R1's view until the next fetch)."""
    copy = dict(brief)
    sections = []
    for section in brief.get("sections") or []:
        updated = dict(section)
        updated["items"] = [dict(item, state=state) if item.get("id") == item_id else item
                            for item in section.get("items") or []]
        sections.append(updated)
    copy["sections"] = sections
    return copy


def _raw_sections(brief: dict[str, object]) -> list[tuple[str | None, list[object]]]:
    found: list[tuple[str | None, list[object]]] = []
    sections = brief.get("sections")
    if isinstance(sections, list):
        for section in sections:
            if isinstance(section, dict) and isinstance(section.get("items"), list):
                found.append((section_id(section.get("id") or section.get("key") or section.get("kind")
                                         or section.get("title")), section["items"]))
    elif isinstance(sections, dict):
        for key, value in sections.items():
            if isinstance(value, list):
                found.append((section_id(key), value))
            elif isinstance(value, dict) and isinstance(value.get("items"), list):
                found.append((section_id(key), value["items"]))
    if found:
        return found
    for key in ("doFirst", "do_first", "today", "agents", "fyi"):
        if isinstance(brief.get(key), list):
            found.append((section_id(key), brief[key]))
    if not found and isinstance(brief.get("items"), list):
        found.append((None, brief["items"]))
    return found


def _item(raw: object, section: str | None) -> dict[str, object] | None:
    if not isinstance(raw, dict):
        return None
    item_id = flat(raw.get("id"), 80)
    title = flat(raw.get("title"), 90)
    if not _ID.match(item_id) or not title:
        return None
    where = section or section_id(raw.get("section")) or _section_for_kind(raw.get("kind"))
    if where is None:
        return None
    actions: list[dict[str, str]] = []
    for entry in raw.get("actions") or []:
        kind = action_type(entry.get("type") if isinstance(entry, dict) else entry)
        if kind is None or kind in (action["type"] for action in actions):
            continue
        label = flat(entry.get("label"), 24) if isinstance(entry, dict) else ""
        actions.append({"type": kind, "label": label or ACTION_LABELS[kind]})
        if len(actions) == 2:
            break
    state = flat(raw.get("state"), 16).lower() or "open"
    item: dict[str, object] = {
        "id": item_id, "kind": flat(raw.get("kind"), 16) or "email", "section": where, "title": title,
        "why": flat(raw.get("why"), 140), "state": state if state in STATES else "open", "actions": actions,
    }
    for key, limit in (("suggestion", 120), ("account", 16), ("time", 24)):
        value = flat(raw.get(key), limit)
        if value:
            item[key] = value
    starts = flat(raw.get("startsAt") or raw.get("start"), 40)
    if starts:
        item["startsAt"] = starts
    if raw.get("conflict") is True:
        item["conflict"] = True
    source = raw.get("source") if isinstance(raw.get("source"), dict) else {}
    thread = raw.get("threadId") or source.get("threadId")
    if isinstance(thread, str) and _ID.match(thread) and item["kind"] == "agent":
        item["threadId"] = thread
    return item


def _section_for_kind(kind: object) -> str | None:
    return {"event": "today", "agent": "agents", "fyi": "fyi", "conflict": "do_first",
            "email": "do_first"}.get(str(kind or "").strip().lower())
