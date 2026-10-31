"""Pure T3 shell/thread interpretation (orchestration protocol 2): status, labels, ordering, pending requests.

Status mirrors T3's own sidebar (``resolveSidebarThreadStatus`` in apps/web over
``presentThreadShell`` in packages/client-runtime): a pending runtime request
first (approval before question), then a live run, then background work the
agent waits on, then a failed run. Settled threads are demoted: a failure the
user already settled reads as done.

Shell fields used (``OrchestrationV2ThreadShell``): ``status`` (latest run status,
``idle`` with no run), ``activityRunStatus`` (the run that owns activity, wins over
``status``), ``latestRunId`` / ``latestRun{Requested,Started,Completed}At``,
``activeRunId``, ``pendingRuntimeRequest`` ``{id, kind, createdAt, blocking?}``,
``pendingBackgroundTasks``, ``blockedOnThreadWait``, ``lastError``, ``settledAt``,
``snoozedUntil``, ``modelSelection``, ``projectId``, ``title``, ``updatedAt``.
"""

from __future__ import annotations

from collections.abc import Iterable
from dataclasses import dataclass
from datetime import UTC, datetime


NEEDS_APPROVAL = "needs-approval"
NEEDS_INPUT = "needs-input"
WORKING = "working"
ERROR = "error"
DONE = "done"
STATUS_ORDER = {NEEDS_APPROVAL: 0, NEEDS_INPUT: 1, WORKING: 2, ERROR: 3, DONE: 4}
NEEDS_YOU = frozenset({NEEDS_APPROVAL, NEEDS_INPUT})
DEFAULT_APPROVAL_OPTIONS = (
    {"decision": "accept", "label": "Approve"},
    {"decision": "acceptForSession", "label": "Always allow this session"},
    {"decision": "decline", "label": "Decline"},
    {"decision": "cancel", "label": "Cancel"},
)
_REQUEST_KINDS = frozenset({"command", "file-read", "file-change", "mcp-elicitation", "permission"})
# Run statuses (OrchestrationV2RunStatus). "waiting" runs ended their provider turn and only drain effects.
LIVE_RUN = frozenset({"preparing", "queued", "starting", "running", "waiting"})
_PROVIDER_WORKING = frozenset({"preparing", "starting", "running"})
TERMINAL_RUN = frozenset({"completed", "interrupted", "failed", "cancelled", "rolled_back"})
PARKED = "idle"  # runtime status while background work the agent waits on holds the thread


def _dict(value: object) -> dict[str, object]:
    return value if isinstance(value, dict) else {}


def _text(value: object) -> str | None:
    return value.strip() if isinstance(value, str) and value.strip() else None


def parse_time(value: object) -> datetime | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=UTC)


def is_settled(thread: dict[str, object]) -> bool:
    return thread.get("settledAt") is not None


def is_snoozed(thread: dict[str, object], now: datetime) -> bool:
    until = parse_time(thread.get("snoozedUntil"))
    return until is not None and until > now


def is_subagent(thread: dict[str, object]) -> bool:
    return _dict(thread.get("lineage")).get("relationshipToParent") == "subagent"


def holds_completion(thread: dict[str, object]) -> bool:
    """Background work the agent waits on (``backgroundWorkHoldsCompletion``): a subagent or
    background task, or a command/monitor the agent marked ``awaited``. A dev server it merely
    left running does not hold the thread."""
    for task in thread.get("pendingBackgroundTasks") or []:
        if isinstance(task, dict) and (task.get("awaited") is True or task.get("kind") in {"subagent", "background_task"}):
            return True
    return False


def runtime_status(thread: dict[str, object]) -> str | None:
    """The status T3's sidebar reads (``shellRuntime``): ``None`` for a thread that never ran,
    ``idle`` while held by awaited background work, else the activity run's or latest run's status."""
    parked = holds_completion(thread) and thread.get("status") != "failed"
    if thread.get("latestRunId") is None and thread.get("activeProviderThreadId") is None and not parked:
        return None
    if parked:
        return PARKED
    return str(thread.get("activityRunStatus") or thread.get("status") or "") or None


def latest_run_id(thread: dict[str, object]) -> str | None:
    value = thread.get("latestRunId")
    return str(value) if value else None


def run_live(thread: dict[str, object]) -> bool:
    """A run is queued, starting, running or draining (what "stop" would interrupt)."""
    return runtime_status(thread) in LIVE_RUN


def _pending_kind(thread: dict[str, object]) -> str | None:
    request = thread.get("pendingRuntimeRequest")
    if not isinstance(request, dict):
        return None
    kind = request.get("kind")
    if kind == "auth_refresh":
        return None
    if kind == "user_input":
        # An async question (blocking: false) counts only once the run stops working past it.
        if request.get("blocking") is False and runtime_status(thread) in _PROVIDER_WORKING:
            return None
        return NEEDS_INPUT
    return NEEDS_APPROVAL


def raw_status(thread: dict[str, object]) -> str:
    """Status before settlement demotion (T3 sidebar order)."""
    pending = _pending_kind(thread)
    if pending is not None:
        return pending
    runtime = runtime_status(thread)
    if runtime in LIVE_RUN or runtime == PARKED:
        return WORKING
    if runtime == "failed":
        return ERROR
    return DONE


ACTIVITY_ACTIVE = "active"
ACTIVITY_BACKGROUND = "background"
ACTIVITY_IDLE = "idle"


def foreground_active(thread: dict[str, object]) -> bool:
    """A run is live (and not just waiting on another thread), or a request waits on the user."""
    if _pending_kind(thread) is not None:
        return True
    return runtime_status(thread) in LIVE_RUN and thread.get("blockedOnThreadWait") is not True


def activity_level(threads: Iterable[object]) -> str:
    """How busy T3 is, for the shell poll cadence (not for display).

    ``active``: some thread runs or waits on the user. ``background``: threads are only held by
    background work (a subagent or awaited task with no live run of their own, or a run blocked
    on another thread), which shows as "Background work" / "Waiting" but has no turn to announce
    yet. ``idle``: nothing working or pending.
    """
    level = ACTIVITY_IDLE
    for thread in threads:
        if not isinstance(thread, dict):
            continue
        if foreground_active(thread):
            return ACTIVITY_ACTIVE
        if runtime_status(thread) in LIVE_RUN or runtime_status(thread) == PARKED:
            level = ACTIVITY_BACKGROUND
    return level


def thread_status(thread: dict[str, object]) -> str:
    status = raw_status(thread)
    if status == ERROR and is_settled(thread):
        return DONE
    return status


def status_label(thread: dict[str, object], status: str) -> str:
    runtime = runtime_status(thread)
    if status == NEEDS_APPROVAL:
        return "Needs approval"
    if status == NEEDS_INPUT:
        return "Has a question"
    if status == WORKING:
        if runtime == PARKED:
            return "Background work"
        if runtime in {"preparing", "starting"}:
            return "Starting"
        if runtime == "queued":
            return "Queued"
        if thread.get("blockedOnThreadWait") is True:
            return "Waiting"
        return "Working"
    if status == ERROR:
        return "Failed"
    if latest_run_id(thread) is None:
        return "New"
    if thread.get("status") in {"interrupted", "cancelled"}:
        return "Stopped"
    return "Done"


def plan_phase(steps: object) -> tuple[str | None, float | None]:
    """(current step, fraction done) from a v2 ``todo_list`` item's ``steps``."""
    if not isinstance(steps, list) or not steps:
        return None, None
    rows = [step for step in steps if isinstance(step, dict)]
    if not rows:
        return None, None
    done = sum(1 for step in rows if step.get("status") == "completed")
    current = next((step for step in rows if step.get("status") == "running"), None)
    current = current or next((step for step in rows if step.get("status") == "pending"), None)
    text = _text(current.get("text")) if current else None
    return (text[:80] if text else None), round(max(0.0, min(1.0, done / len(rows))), 3)


def activity_time(thread: dict[str, object]) -> str:
    """When something last happened in the thread (not settle/rename bookkeeping)."""
    candidates = [
        thread.get("latestRunCompletedAt"),
        thread.get("latestRunStartedAt"),
        thread.get("latestRunRequestedAt"),
        thread.get("latestUserMessageAt"),
        thread.get("createdAt"),
    ]
    best: tuple[datetime, str] | None = None
    for value in candidates:
        parsed = parse_time(value)
        if parsed is not None and (best is None or parsed > best[0]):
            best = (parsed, str(value))
    if best is not None:
        return best[1]
    return str(thread.get("updatedAt") or "")


def summary_time(thread: dict[str, object], status: str) -> str:
    if status in NEEDS_YOU:
        return str(thread.get("updatedAt") or activity_time(thread))
    return activity_time(thread)


def completed_at(thread: dict[str, object]) -> str | None:
    """When the latest run ended (``None`` while it runs or before any run). Older servers omit
    ``latestRunCompletedAt``; T3's own client then uses ``updatedAt``."""
    if latest_run_id(thread) is None or thread.get("status") not in TERMINAL_RUN:
        return None
    if "latestRunCompletedAt" not in thread:
        value = thread.get("updatedAt")
    else:
        value = thread.get("latestRunCompletedAt")
    return str(value) if value else None


def unread_marker(thread: dict[str, object], status: str) -> str | None:
    """Value compared against the stored seen marker; ``None`` means never unread."""
    if status == WORKING:
        return None
    if status in NEEDS_YOU:
        return str(thread.get("updatedAt") or "") or None
    return completed_at(thread)


def seen_marker(thread: dict[str, object]) -> str:
    """Marker stored when the user views a thread (covers both done and needs-you)."""
    values = [value for value in (completed_at(thread), thread.get("updatedAt")) if value]
    parsed = [(parse_time(value), str(value)) for value in values]
    parsed = [item for item in parsed if item[0] is not None]
    if not parsed:
        return ""
    return max(parsed, key=lambda item: item[0])[1]


def is_unread(marker: str | None, seen: str | None) -> bool:
    if not marker:
        return False
    if not seen:
        return True
    marker_time, seen_time = parse_time(marker), parse_time(seen)
    if marker_time is None or seen_time is None:
        return marker != seen
    return marker_time > seen_time


def project_titles(shell: dict[str, object]) -> dict[str, str]:
    return {
        str(project.get("id")): str(project.get("title") or "Project")
        for project in shell.get("projects", []) or []
        if isinstance(project, dict) and project.get("id")
    }


def listed(thread: object) -> bool:
    """Whether a shell thread appears on the R1: not archived or deleted, and not a subagent
    child unless the child itself waits on the user (an app-owned child asks on its own thread)."""
    if not isinstance(thread, dict) or not thread.get("id"):
        return False
    if thread.get("archivedAt") is not None or thread.get("deletedAt") is not None:
        return False
    return not is_subagent(thread) or _pending_kind(thread) is not None


def summarize(thread: dict[str, object], projects: dict[str, str], *, seen: str | None) -> dict[str, object]:
    status = thread_status(thread)
    model = _dict(thread.get("modelSelection")).get("model")
    project_id = str(thread.get("projectId") or "")
    return {
        "id": str(thread.get("id") or ""),
        "projectId": project_id,
        "projectTitle": projects.get(project_id, "Project"),
        "title": str(thread.get("title") or "Untitled thread"),
        "status": status,
        "statusLabel": status_label(thread, status),
        "updatedAt": summary_time(thread, status),
        "completedAt": completed_at(thread),
        "unread": is_unread(unread_marker(thread, status), seen),
        "model": str(model) if isinstance(model, str) and model else None,
        # The v2 shell carries no plan progress; the live card reads it from the thread's todo list.
        "phase": None,
        "progress": None,
    }


def order_key(thread: dict[str, object], summary: dict[str, object], now: datetime) -> tuple[object, ...]:
    """Actionable first, then unsettled done, then settled/snoozed; most recent first."""
    status = str(summary["status"])
    shelved = 1 if status in {DONE, ERROR} and (is_settled(thread) or is_snoozed(thread, now)) else 0
    stamp = parse_time(summary.get("updatedAt"))
    epoch = -(stamp.timestamp() if stamp else 0.0)
    return (shelved, STATUS_ORDER.get(status, 9), epoch, str(summary["id"]))


def counts(summaries: list[dict[str, object]]) -> dict[str, int]:
    result = {"needsYou": 0, "working": 0, "done": 0, "error": 0}
    for item in summaries:
        status = item.get("status")
        if status in NEEDS_YOU:
            result["needsYou"] += 1
        elif status == WORKING:
            result["working"] += 1
        elif status == ERROR:
            result["error"] += 1
        else:
            result["done"] += 1
    return result


@dataclass(frozen=True, slots=True)
class PendingApproval:
    request_id: str
    kind: str
    detail: str | None
    options: tuple[dict[str, str], ...]
    created_at: str

    def view(self) -> dict[str, object]:
        return {
            "requestId": self.request_id,
            "kind": self.kind,
            "detail": self.detail,
            "options": [dict(option) for option in self.options],
        }


@dataclass(frozen=True, slots=True)
class PendingQuestion:
    question_id: str
    header: str
    question: str
    options: tuple[str, ...]
    allow_custom: bool
    multi_select: bool
    # What T3 expects back for each option: ``option.value ?? option.label``
    # (apps/web pendingUserInput.ts). Parallel to ``options``; labels are for display.
    values: tuple[str, ...] = ()

    def answer_value(self, index: int) -> str:
        return self.values[index] if index < len(self.values) else self.options[index]

    def view(self) -> dict[str, object]:
        return {
            "id": self.question_id,
            "header": self.header,
            "question": self.question,
            "options": list(self.options),
            "allowCustom": self.allow_custom,
            "multiSelect": self.multi_select,
        }


@dataclass(frozen=True, slots=True)
class PendingInput:
    request_id: str
    questions: tuple[PendingQuestion, ...]
    dismissible: bool
    created_at: str

    def view(self) -> dict[str, object]:
        return {"requestId": self.request_id, "questions": [item.view() for item in self.questions]}


@dataclass(frozen=True, slots=True)
class PendingRequests:
    approvals: tuple[PendingApproval, ...] = ()
    inputs: tuple[PendingInput, ...] = ()

    def view(self) -> dict[str, object]:
        return {
            "approvals": [item.view() for item in self.approvals],
            "inputs": [item.view() for item in self.inputs],
        }

    @property
    def count(self) -> int:
        return len(self.approvals) + len(self.inputs)


def _questions(value: object) -> tuple[PendingQuestion, ...]:
    if not isinstance(value, list):
        return ()
    result = []
    for raw in value:
        if not isinstance(raw, dict) or not isinstance(raw.get("options"), list):
            continue
        kept = [
            option for option in raw["options"]
            if isinstance(option, dict) and isinstance(option.get("label"), str)
        ]
        options = tuple(str(option["label"]) for option in kept)
        values = tuple(
            str(option["value"]) if isinstance(option.get("value"), str) else str(option["label"])
            for option in kept
        )
        allow_custom = raw.get("allowCustomAnswer") is not False
        if not options and not allow_custom:
            continue
        if not all(isinstance(raw.get(key), str) for key in ("id", "header", "question")):
            continue
        result.append(PendingQuestion(
            question_id=str(raw["id"]),
            header=str(raw["header"]),
            question=str(raw["question"]),
            options=options,
            allow_custom=allow_custom,
            multi_select=raw.get("multiSelect") is True,
            values=values,
        ))
    return tuple(result)


def projection_of(detail: object) -> dict[str, object]:
    """The ``OrchestrationV2ThreadProjection`` inside a thread snapshot (or the projection itself)."""
    value = _dict(detail)
    return _dict(value.get("projection")) if "projection" in value else value


def pending_requests(projection: object) -> PendingRequests:
    """Mirror of T3 ``derivePendingThreadRequests`` (packages/client-runtime/src/state/threadRequests.ts).

    Every ``runtimeRequests`` row still ``pending``: ``user_input`` rows become questions from
    their ``user_input_request`` turn item (skipped while that item is not in the window);
    ``auth_refresh`` and ``dynamic_tool_call`` are T3's own business; the rest are approvals,
    with the ``approval_request`` item's prompt as the detail and its options when given.
    """
    value = projection_of(projection)
    items = [item for item in value.get("turnItems") or [] if isinstance(item, dict)]
    by_request: dict[tuple[str, str], dict[str, object]] = {}
    for item in items:
        request_id = item.get("requestId")
        if isinstance(request_id, str) and item.get("type") in {"user_input_request", "approval_request"}:
            by_request[(str(item["type"]), request_id)] = item
    approvals: list[PendingApproval] = []
    inputs: list[PendingInput] = []
    for request in value.get("runtimeRequests") or []:
        if not isinstance(request, dict) or request.get("status") != "pending":
            continue
        request_id = request.get("id")
        if not isinstance(request_id, str) or not request_id:
            continue
        kind = request.get("kind")
        created = str(request.get("createdAt") or "")
        capability = _dict(request.get("responseCapability")).get("type")
        if kind == "user_input":
            item = by_request.get(("user_input_request", request_id))
            if item is None:
                continue
            questions = _questions(item.get("questions"))
            if not questions:
                continue
            inputs.append(PendingInput(
                request_id=request_id,
                questions=questions,
                dismissible=item.get("responseMode") == "message" or capability == "message",
                created_at=created,
            ))
            continue
        if kind in {"auth_refresh", "dynamic_tool_call"}:
            continue
        item = by_request.get(("approval_request", request_id)) or {}
        options = tuple(
            {"decision": str(option["decision"]), "label": str(option["label"])}
            for option in item.get("options", []) or []
            if isinstance(option, dict) and isinstance(option.get("decision"), str) and isinstance(option.get("label"), str)
        )
        approvals.append(PendingApproval(
            request_id=request_id,
            kind=str(kind) if kind in _REQUEST_KINDS else "command",
            detail=_text(item.get("prompt")) or _text(item.get("reason")),
            options=options or DEFAULT_APPROVAL_OPTIONS,
            created_at=created,
        ))
    return PendingRequests(
        approvals=tuple(sorted(approvals, key=lambda item: item.created_at)),
        inputs=tuple(sorted(inputs, key=lambda item: item.created_at)),
    )


def missing_request_items(projection: object) -> bool:
    """A pending question whose turn item is outside the bounded window (fetch the whole thread)."""
    value = projection_of(projection)
    have = {
        str(item.get("requestId")) for item in value.get("turnItems") or []
        if isinstance(item, dict) and item.get("type") == "user_input_request"
    }
    return any(
        isinstance(request, dict) and request.get("status") == "pending" and request.get("kind") == "user_input"
        and str(request.get("id")) not in have
        for request in value.get("runtimeRequests") or []
    )


def _ordinal(value: object) -> int:
    ordinal = _dict(value).get("ordinal")
    return ordinal if isinstance(ordinal, int) else -1


def shell_from_projection(detail: object) -> dict[str, object]:
    """A shell-like thread (the fields this module reads) built from a thread projection, for a
    thread the cached shell does not hold yet and for the freshest run state of one thread."""
    projection = projection_of(detail)
    thread = dict(_dict(projection.get("thread")))
    runs = sorted((run for run in projection.get("runs") or [] if isinstance(run, dict)), key=_ordinal)
    latest = runs[-1] if runs else None
    active = next((run for run in reversed(runs) if run.get("status") in LIVE_RUN), None)
    thread["latestRunId"] = latest.get("id") if latest else None
    thread["status"] = str(latest.get("status")) if latest else "idle"
    thread["latestRunRequestedAt"] = latest.get("requestedAt") if latest else None
    thread["latestRunStartedAt"] = latest.get("startedAt") if latest else None
    thread["latestRunCompletedAt"] = latest.get("completedAt") if latest else None
    thread["activeRunId"] = active.get("id") if active else None
    pending = next((
        request for request in projection.get("runtimeRequests") or []
        if isinstance(request, dict) and request.get("status") == "pending" and request.get("kind") != "auth_refresh"
    ), None)
    thread["pendingRuntimeRequest"] = (
        {"id": pending.get("id"), "kind": pending.get("kind"), "createdAt": pending.get("createdAt")} if pending else None
    )
    thread.setdefault("pendingBackgroundTasks", [])
    return thread


def run_items(detail: object, run_id: str | None) -> list[dict[str, object]]:
    """Turn items of one run (all items when ``run_id`` is None), oldest first."""
    items = [item for item in projection_of(detail).get("turnItems") or [] if isinstance(item, dict)]
    if run_id is not None:
        items = [item for item in items if item.get("runId") == run_id]
    return sorted(items, key=_ordinal)


def last_assistant_text(thread_detail: object) -> str | None:
    messages = projection_of(thread_detail).get("messages")
    for message in reversed(messages if isinstance(messages, list) else []):
        if isinstance(message, dict) and message.get("role") == "assistant":
            text = _text(message.get("text"))
            if text:
                return text
    return None


def latest_assistant_preview(thread: dict[str, object]) -> str | None:
    """The shell's ``latestVisibleMessage`` when it is the agent's (no detail fetch needed)."""
    latest = _dict(thread.get("latestVisibleMessage"))
    return _text(latest.get("text")) if latest.get("role") == "assistant" else None


def condense(text: str | None, limit: int) -> str:
    """Collapse whitespace and trim to ``limit`` characters at a word boundary."""
    if not text:
        return ""
    flat = " ".join(str(text).replace("```", " ").split())
    if len(flat) <= limit:
        return flat
    cut = flat[: max(1, limit - 1)]
    space = cut.rfind(" ")
    if space > limit * 0.6:
        cut = cut[:space]
    return cut.rstrip(" ,;:-") + "…"
