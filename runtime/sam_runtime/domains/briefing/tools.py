"""Voice tools for the morning briefing (tool set ``briefing``): ``briefing_read`` and ``briefing_act``.

Visible only while the Mac bridge is configured. Both read the R1's cached brief (no wait on the Mac for reading).
The model speaks the brief only when the user asks for it; ``briefing_act`` takes an item number from
``briefing_read`` (1 = the first item) or its id. Drafts are Gmail drafts only: nothing can be sent from here.
"""

from __future__ import annotations

import json

from sam_runtime.agents import AudienceResource, AudienceResourceKind
from sam_runtime.tools import ToolCatalog, ToolDefinition, ToolInvocationResult

from . import model
from .service import BriefingActionRejected, BriefingService

BRIEFING_TOOL_SET = AudienceResource(AudienceResourceKind.DOMAIN_TOOL_SET, "briefing")

BRIEFING_READ_SPEC: tuple[str, str, dict[str, object]] = (
    "briefing_read",
    "Read today's morning brief (built from the user's email, calendar and agents on their Mac): a headline, a "
    "short spoken version, and numbered items (Do first, Today, Agents, FYI) with the actions each one offers. "
    "Use it only when the user asks for their brief or what needs them this morning; then say the 'spoken' text "
    "in your own short words, not every item.",
    {"type": "object", "properties": {}, "additionalProperties": False},
)

BRIEFING_ACT_SPEC: tuple[str, str, dict[str, object]] = (
    "briefing_act",
    "Do one action on a morning-brief item when the user asks: draft_reply (saves a Gmail DRAFT for them to review "
    "and send themselves; nothing is ever sent), make_task (starts a T3 task), block_time, remind, done, dismiss, "
    "or open (opens the email on their Mac). item: its number from briefing_read (1 = first) or its id. Only an "
    "action that item lists, plus done and dismiss.",
    {
        "type": "object",
        "properties": {
            "item": {"type": "string", "description": "The item's number from briefing_read (\"1\") or its id."},
            "action": {"type": "string", "enum": ["draft_reply", "make_task", "block_time", "remind", "done",
                                                  "dismiss", "open"]},
        },
        "required": ["item", "action"],
        "additionalProperties": False,
    },
)


def register_briefing_tools(catalog: ToolCatalog, service: BriefingService) -> "BriefingToolHandlers":
    handlers = BriefingToolHandlers(service)
    for spec, handler, effect, tool_id in (
            (BRIEFING_READ_SPEC, handlers.read, "read", "builtin.briefing.read.v1"),
            (BRIEFING_ACT_SPEC, handlers.act, "external_write", "builtin.briefing.act.v1")):
        name, description, schema = spec
        catalog.register(ToolDefinition(
            tool_id=tool_id,
            name=name,
            description=description,
            input_schema=schema,
            handler=handler,
            effect_class=effect,
            audience_resource=BRIEFING_TOOL_SET,
            available_to=lambda _agent: service.configured(),
        ))
    return handlers


class BriefingToolHandlers:
    def __init__(self, service: BriefingService) -> None:
        self._service = service

    def read(self, arguments: dict[str, object]) -> ToolInvocationResult:
        view = self._service.view()
        brief = view.get("briefing")
        if not isinstance(brief, dict):
            say = "Today's brief isn't ready yet." if view.get("configured") else "The Mac isn't connected to the R1."
            return _result({"available": False, "status": view.get("status"), "say": say})
        numbered = []
        for index, item in enumerate(model.items(brief), start=1):
            entry: dict[str, object] = {"n": index, "id": item["id"], "section": item["section"],
                                        "title": item["title"], "state": item["state"],
                                        "actions": [action["type"] for action in item.get("actions") or []]}
            for key in ("why", "time"):
                if item.get(key):
                    entry[key] = item[key]
            numbered.append(entry)
        return _result({"available": True, "date": brief.get("date"), "headline": brief.get("headline"),
                        "spoken": brief.get("spoken"), "needsYou": brief.get("needsYou"), "items": numbered})

    def act(self, arguments: dict[str, object]) -> ToolInvocationResult:
        view = self._service.view()
        brief = view.get("briefing") if isinstance(view.get("briefing"), dict) else None
        wanted = str(arguments.get("item") or "").strip()
        listed = model.items(brief)
        item_id = wanted
        if wanted.isdigit():
            index = int(wanted) - 1
            if not 0 <= index < len(listed):
                return _error("item_not_found", "There is no such item in today's brief.")
            item_id = str(listed[index]["id"])
        try:
            result = self._service.act(item_id, arguments.get("action"))
        except BriefingActionRejected as rejected:
            return _error(rejected.code, str(rejected))
        return ToolInvocationResult(json.dumps(result, separators=(",", ":"), ensure_ascii=False),
                                    is_error=result.get("ok") is False)


def _result(payload: dict[str, object]) -> ToolInvocationResult:
    return ToolInvocationResult(json.dumps(payload, separators=(",", ":"), ensure_ascii=False))


def _error(code: str, message: str) -> ToolInvocationResult:
    return ToolInvocationResult(json.dumps({"isError": True, "code": code, "message": message},
                                           separators=(",", ":"), ensure_ascii=False), is_error=True)
