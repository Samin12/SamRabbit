"""The morning briefing on the R1: fetched from the Mac bridge, cached, shown on the Cards board and acted on."""

from .client import BriefingBridgeClient
from .service import KIND_READY, BriefingActionRejected, BriefingService
from .tools import BRIEFING_TOOL_SET, BriefingToolHandlers, register_briefing_tools
from .voice import BRIEFING_VOICE_INSTRUCTION, BriefingVoiceContext

__all__ = [
    "BRIEFING_TOOL_SET",
    "BRIEFING_VOICE_INSTRUCTION",
    "BriefingActionRejected",
    "BriefingBridgeClient",
    "BriefingService",
    "BriefingToolHandlers",
    "BriefingVoiceContext",
    "KIND_READY",
    "register_briefing_tools",
]
