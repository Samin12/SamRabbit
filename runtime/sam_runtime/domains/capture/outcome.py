"""What the R1 shows for a voice note (pure): the bridge's capture state turned into one short line.

App-facing states: ``done`` (the bridge acted: journal, T3 task, calendar or a saved note), ``sent`` (the Mac has
it and is still working), ``queued`` (kept on the R1 until the Mac answers), ``failed`` (refused for good).
Lines are short and factual; they are shown, never spoken.
"""

from __future__ import annotations

TERMINAL_BRIDGE_STATES = frozenset({"done", "failed", "needs_you", "no_speech"})
KINDS = {"journal": "journal", "t3_task": "task", "task": "task", "t3": "task", "calendar": "calendar",
         "calendar_event": "calendar", "calendar_block": "calendar", "reminder": "calendar", "note": "note"}
MAX_LINE = 120

QUEUED_LINE = "Saved. It goes to your Mac when it's back."
QUEUED_OUTDATED_LINE = "Saved on the R1. Update the Mac bridge to send notes."
QUEUED_UNAUTHORIZED_LINE = "Saved on the R1. Connect the Mac bridge again."
QUEUED_UNPAIRED_LINE = "Saved on the R1. Connect your Mac to send it."
SENT_LINE = "Sent to your Mac."
FAILED_LINE = "Couldn't save that note."


def flat(value: object, limit: int = MAX_LINE) -> str:
    text = " ".join(str(value or "").split())
    return text if len(text) <= limit else text[:limit - 1].rstrip() + "…"


def bridge_state(result: dict[str, object]) -> str:
    return str(result.get("state") or "received").strip().lower()


def finished(result: dict[str, object]) -> bool:
    return bridge_state(result) in TERMINAL_BRIDGE_STATES


def kind(result: dict[str, object]) -> str:
    outcome = result.get("outcome") if isinstance(result.get("outcome"), dict) else {}
    return KINDS.get(str(outcome.get("kind") or "").strip().lower(), "note" if outcome else "")


def line(result: dict[str, object]) -> str:
    """The outcome in a few words ("Added to your journal", "Started a T3 task: Fix login")."""
    state = bridge_state(result)
    say = flat(result.get("say"))
    if state == "no_speech":
        return say or "I didn't catch anything."
    if state == "failed":
        outcome = result.get("outcome") if isinstance(result.get("outcome"), dict) else {}
        return say or flat(outcome.get("detail")) or FAILED_LINE
    if say:
        return say
    outcome = result.get("outcome") if isinstance(result.get("outcome"), dict) else {}
    title = flat(outcome.get("title"), 70)
    detail = flat(outcome.get("detail"))
    which = kind(result)
    if which == "journal":
        return "Added to your journal"
    if which == "task":
        return f"Started a T3 task: {title}" if title else "Started a T3 task"
    if which == "calendar":
        return f"On your calendar: {title}" if title else "Added to your calendar"
    if which == "note":
        suggestion = result.get("suggestion")
        label = flat(suggestion.get("label"), 60) if isinstance(suggestion, dict) else flat(suggestion, 60)
        return f"Saved as a note · {label}" if label else "Saved as a note"
    if state in TERMINAL_BRIDGE_STATES:
        return detail or title or "Done"
    return SENT_LINE


def queued_line(code: str) -> str:
    return {"bridge_outdated": QUEUED_OUTDATED_LINE, "mac_unauthorized": QUEUED_UNAUTHORIZED_LINE,
            "mac_token_unavailable": QUEUED_UNAUTHORIZED_LINE,
            "mac_not_configured": QUEUED_UNPAIRED_LINE}.get(code, QUEUED_LINE)


def app_outcome(result: dict[str, object]) -> dict[str, object] | None:
    """The bridge outcome trimmed to ids and labels (never the transcript) for the app."""
    outcome = result.get("outcome")
    if not isinstance(outcome, dict):
        return None
    view: dict[str, object] = {"kind": kind(result) or "note", "title": flat(outcome.get("title"), 80),
                               "detail": flat(outcome.get("detail"), 160)}
    for key in ("threadId", "eventId", "noteId"):
        value = outcome.get(key)
        if isinstance(value, str) and value and len(value) <= 128:
            view[key] = value
    return view
