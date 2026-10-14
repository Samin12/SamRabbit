"""Voice notes from the R1: the transcript goes to the Mac bridge, which routes it (journal, T3 task, calendar or a
saved note). The R1 keeps an outbox while the Mac is away."""

from .client import CaptureBridgeClient
from .service import KIND_ROUTED, CaptureRejected, CaptureService

__all__ = ["CaptureBridgeClient", "CaptureRejected", "CaptureService", "KIND_ROUTED"]
