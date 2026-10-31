"""Builders for T3 orchestration protocol 2 writes (WebSocket RPC payloads).

Shapes follow ``OrchestrationV2Command`` / ``OrchestrationV2ThreadLaunchInput``
in T3's contracts (packages/contracts/src/orchestrationV2.ts) and the way T3's
own client sends them (packages/client-runtime/src/operations/commands.ts):

- new thread + first message: ``orchestration.launchThread`` with
  ``workspaceStrategy {type: root}`` and ``initialMessage`` (one call, no
  separate ``thread.create`` / turn start);
- follow-up message: ``message.dispatch``; on servers advertising
  ``serverResolvedCommandContext`` T3 picks steer/queue itself from
  ``deliveryIntent: auto`` with ``dispatchMode start_immediately``, otherwise a
  message for a live run is queued after it;
- approval / question answers: ``runtime-request.respond`` (``decision`` or
  ``answers``);
- stop: ``thread.stop`` (servers advertising ``threadStop``, also stops
  background work) or ``run.interrupt`` of the live run;
- archive: ``thread.archive``.

Every command gets a fresh UUIDv4 ``commandId`` (T3 dedupes retries by it).
Protocol 2 commands carry no ``createdAt``; T3 stamps its own time.
"""

from __future__ import annotations

from collections.abc import Callable
import uuid


DEFAULT_MODEL_SELECTION = {"instanceId": "claudeAgent", "model": "claude-opus-5-5"}
DEFAULT_RUNTIME_MODE = "full-access"
DEFAULT_INTERACTION_MODE = "default"
RUNTIME_MODES = frozenset({"approval-required", "auto-accept-edits", "auto", "full-access"})
APPROVAL_DECISIONS = frozenset({"accept", "acceptForSession", "acceptAlways", "decline", "cancel"})
MAX_PROMPT_CHARS = 120_000
CREATION_SOURCE = "mobile"


def _uuid() -> str:
    return str(uuid.uuid4())


class T3CommandBuilder:
    def __init__(self, *, new_id: Callable[[], str] = _uuid) -> None:
        self._new_id = new_id

    def new_id(self) -> str:
        return self._new_id()

    def launch_thread(
        self,
        *,
        thread_id: str,
        project_id: str,
        title: str,
        text: str,
        model_selection: dict[str, object],
        runtime_mode: str,
        interaction_mode: str = DEFAULT_INTERACTION_MODE,
        generate_title: bool = True,
    ) -> dict[str, object]:
        """``orchestration.launchThread`` payload: create the thread and send its first message."""
        return {
            "commandId": self._new_id(),
            "creationSource": CREATION_SOURCE,
            "threadId": thread_id,
            "projectId": project_id,
            "title": title,
            "generateTitle": generate_title,
            "modelSelection": dict(model_selection),
            "runtimeMode": runtime_mode,
            "interactionMode": interaction_mode,
            "workspaceStrategy": {"type": "root"},
            "initialMessage": {"messageId": self._new_id(), "text": text, "attachments": []},
        }

    def message(self, *, thread_id: str, text: str, server_resolved: bool = True, run_live: bool = False) -> dict[str, object]:
        """``message.dispatch`` for a follow-up message (see the module docstring for the mode)."""
        command: dict[str, object] = {
            "type": "message.dispatch",
            "commandId": self._new_id(),
            "createdBy": "user",
            "creationSource": CREATION_SOURCE,
            "threadId": thread_id,
            "messageId": self._new_id(),
            "text": text,
            "attachments": [],
        }
        if server_resolved:
            command["deliveryIntent"] = "auto"
            command["dispatchMode"] = {"type": "start_immediately"}
        else:
            command["dispatchMode"] = {"type": "queue_after_active" if run_live else "start_immediately"}
        return command

    def approval_respond(self, *, thread_id: str, request_id: str, decision: str) -> dict[str, object]:
        if decision not in APPROVAL_DECISIONS:
            raise ValueError("Approval decision is invalid.")
        return {
            "type": "runtime-request.respond",
            "commandId": self._new_id(),
            "threadId": thread_id,
            "requestId": request_id,
            "decision": decision,
        }

    def user_input_respond(self, *, thread_id: str, request_id: str, answers: dict[str, object]) -> dict[str, object]:
        return {
            "type": "runtime-request.respond",
            "commandId": self._new_id(),
            "threadId": thread_id,
            "requestId": request_id,
            "answers": dict(answers),
        }

    def stop(self, *, thread_id: str) -> dict[str, object]:
        return {"type": "thread.stop", "commandId": self._new_id(), "threadId": thread_id}

    def interrupt(self, *, thread_id: str, run_id: str) -> dict[str, object]:
        return {
            "type": "run.interrupt",
            "commandId": self._new_id(),
            "threadId": thread_id,
            "runId": run_id,
            "holdQueue": True,
        }

    def archive(self, *, thread_id: str) -> dict[str, object]:
        return {"type": "thread.archive", "commandId": self._new_id(), "threadId": thread_id}


def title_from_prompt(text: str, limit: int = 60) -> str:
    flat = " ".join(str(text).split())
    if len(flat) <= limit:
        return flat or "New thread"
    cut = flat[:limit]
    space = cut.rfind(" ")
    if space > limit * 0.5:
        cut = cut[:space]
    return cut.rstrip(" ,;:-.") + "…"
