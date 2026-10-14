"""Device-only voice-note routes (bearer only; never answered for forwarded LAN browser requests).

* ``POST /v1/capture`` ``{captureId, text, capturedAt, durationMs?, trigger?}`` → ``200 {captureId, state, say,
  kind?, outcome?, suggestion?}`` with ``state`` done | sent | queued | failed. The note is stored before the Mac
  is tried, so an answer of ``queued`` means it is safe on the R1.
* ``GET /v1/capture/<captureId>`` → the same view (404 when unknown), plus ``text`` for a note the R1 could not hand
  over for good (outbox full, refused by the bridge): those words exist nowhere else.
* ``GET /v1/captures`` → ``{queued, sending, failed, recent: [...]}`` (states and lines only, no transcripts).
"""

from __future__ import annotations

import re
from typing import TYPE_CHECKING

from ..domains.capture import CaptureRejected, CaptureService
from ..security.pairing import PairingAuthority

if TYPE_CHECKING:
    from .routes import RouteRequest

_ONE = re.compile(r"^/v1/capture/([0-9a-fA-F-]{36})$")
MAX_BODY_BYTES = 48 * 1024


class CaptureRoutes:
    def __init__(self, service: CaptureService) -> None:
        self._service = service

    def handle_get(self, request: "RouteRequest", pairing: PairingAuthority | None = None) -> bool:
        path = request.path.split("?", 1)[0]
        match = _ONE.match(path)
        if match is None and path != "/v1/captures":
            return False
        if _forwarded(request):
            return True
        if match is None:
            request.respond_json(200, self._service.summary())
            return True
        view = self._service.view(match.group(1))
        if view is None:
            request.respond_json(404, {"error": {"code": "capture_not_found", "message": "No such voice note."}})
            return True
        kept = self._service.kept_text(match.group(1))
        if kept:
            view = dict(view, text=kept)
        request.respond_json(200, view)
        return True

    def handle_post(self, request: "RouteRequest", pairing: PairingAuthority | None = None) -> bool:
        if request.path.split("?", 1)[0] != "/v1/capture":
            return False
        if _forwarded(request):
            return True
        payload = request.request_json(max_bytes=MAX_BODY_BYTES)
        if payload is None:
            return True
        try:
            view = self._service.submit(payload)
        except CaptureRejected as error:
            request.respond_json(400, {"error": {"code": "invalid_request", "message": str(error)}})
            return True
        request.respond_json(200, view)
        return True


def _forwarded(request: "RouteRequest") -> bool:
    if request.headers.get("X-SAM-Forwarded-Origin"):
        request.respond_json(403, {"error": {"code": "device_only",
                                             "message": "Voice notes are only available on the device."}})
        return True
    return False
