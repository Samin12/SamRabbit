"""Detect announceable T3 thread transitions for threads observed during this runtime's life.

The first snapshot after start (or after pairing) is a silent baseline, so
history is never announced. A finish is announced only for a run that was
active when observed, or a new run (different ``latestRunId``) whose completion
time is later than the baseline. Each (thread, run/request, status) is announced
at most once. Protocol 2 has runs, not turns; ``turn_id`` keeps its name in the
announcement payload ("turnId") so the R1 app is unchanged.
"""

from __future__ import annotations

from collections import OrderedDict
from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime
import time

from .status import DONE, ERROR, NEEDS_APPROVAL, NEEDS_INPUT, NEEDS_YOU, WORKING, latest_run_id, parse_time, thread_status


FINISHED = "finished"
NEEDS_APPROVAL_EVENT = "needs_approval"
NEEDS_INPUT_EVENT = "needs_input"
ERROR_EVENT = "error"
_MAX_KEYS = 2000
_RECHECK_SECONDS = 10.0


@dataclass(frozen=True, slots=True)
class _Observed:
    status: str
    turn_id: str | None
    turn_state: str | None
    updated_at: str | None


@dataclass(frozen=True, slots=True)
class Transition:
    event: str
    thread_id: str
    turn_id: str | None
    thread: dict[str, object]


def _observe(thread: dict[str, object]) -> _Observed:
    run_id = latest_run_id(thread)
    return _Observed(
        status=thread_status(thread),
        turn_id=run_id,
        turn_state=str(thread.get("status")) if run_id and thread.get("status") else None,
        updated_at=str(thread.get("updatedAt")) if thread.get("updatedAt") else None,
    )


def _completed_after(thread: dict[str, object], baseline: datetime | None) -> bool:
    completed = parse_time(thread.get("latestRunCompletedAt"))
    if completed is None:
        return False
    return baseline is None or completed > baseline


class T3TransitionTracker:
    def __init__(self, *, clock: Callable[[], float] = time.monotonic) -> None:
        self._previous: dict[str, _Observed] | None = None
        self._baseline: datetime | None = None
        self._announced: OrderedDict[tuple[str, ...], None] = OrderedDict()
        self._clock = clock
        self._rechecked: dict[str, float] = {}

    @property
    def has_baseline(self) -> bool:
        return self._previous is not None

    def reset(self) -> None:
        """Forget observations (new pairing); the next snapshot becomes a silent baseline."""
        self._previous = None
        self._baseline = None
        self._announced.clear()
        self._rechecked.clear()

    def claim(self, key: tuple[str, ...]) -> bool:
        """Return True the first time ``key`` is claimed (dedupe for announcements)."""
        if key in self._announced:
            return False
        self._announced[key] = None
        while len(self._announced) > _MAX_KEYS:
            self._announced.popitem(last=False)
        return True

    def observe(self, threads: list[dict[str, object]]) -> list[Transition]:
        current = {str(thread.get("id")): _observe(thread) for thread in threads if thread.get("id")}
        by_id = {str(thread.get("id")): thread for thread in threads if thread.get("id")}
        if self._previous is None:
            self._previous = current
            self._baseline = _latest_time(threads)
            return []
        previous = self._previous
        self._previous = current
        events: list[Transition] = []
        for thread_id, now in current.items():
            before = previous.get(thread_id)
            thread = by_id[thread_id]
            if now.status == DONE:
                if now.turn_state != "completed" or not now.turn_id:
                    continue
                if before is not None:
                    was_active = before.status in {WORKING, NEEDS_APPROVAL, NEEDS_INPUT}
                    if before.turn_id != now.turn_id or was_active:
                        events.append(Transition(FINISHED, thread_id, now.turn_id, thread))
                elif _completed_after(thread, self._baseline):
                    events.append(Transition(FINISHED, thread_id, now.turn_id, thread))
            elif now.status in NEEDS_YOU:
                # A new status always triggers; a mere update while still waiting re-checks
                # for additional requests at most every _RECHECK_SECONDS.
                entered = before is None or before.status != now.status
                updated = before is not None and before.updated_at != now.updated_at
                moment = self._clock()
                if entered or (updated and moment - self._rechecked.get(thread_id, 0.0) >= _RECHECK_SECONDS):
                    self._rechecked[thread_id] = moment
                    event = NEEDS_APPROVAL_EVENT if now.status == NEEDS_APPROVAL else NEEDS_INPUT_EVENT
                    events.append(Transition(event, thread_id, now.turn_id, thread))
            elif now.status == ERROR:
                if before is None:
                    if _completed_after(thread, self._baseline) or now.turn_state != "failed":
                        events.append(Transition(ERROR_EVENT, thread_id, now.turn_id, thread))
                elif before.status != ERROR or before.turn_id != now.turn_id:
                    events.append(Transition(ERROR_EVENT, thread_id, now.turn_id, thread))
        return events


def _latest_time(threads: list[dict[str, object]]) -> datetime | None:
    latest: datetime | None = None
    for thread in threads:
        for value in (thread.get("latestRunCompletedAt"), thread.get("latestRunStartedAt"), thread.get("updatedAt")):
            parsed = parse_time(value)
            if parsed is not None and (latest is None or parsed > latest):
                latest = parsed
    return latest
