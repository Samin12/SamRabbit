"""Device-only morning-briefing routes (bearer only; never answered for forwarded LAN browser requests).

* ``GET /v1/briefing`` → ``{configured, available, status, fetchedAt, stale, error, today, morning, openCount,
  briefing}`` from the R1's cache (never waits on the Mac).
* ``POST /v1/briefing/refresh`` → ``202 {status: "refreshing"}``; the worker asks the Mac and fetches the result.
* ``POST /v1/briefing/items/<id>/act {action}`` → ``{ok, itemId, action, state, say, open?}`` (a Gmail draft at
  most: nothing is ever sent).
"""

from __future__ import annotations

import re
from typing import TYPE_CHECKING

from ..domains.briefing import BriefingActionRejected, BriefingService
from ..security.pairing import PairingAuthority

if TYPE_CHECKING:
    from .routes import RouteRequest

_ACT = re.compile(r"^/v1/briefing/items/([A-Za-z0-9._:\-]{1,80})/act$")


class BriefingRoutes:
    def __init__(self, service: BriefingService) -> None:
        self._service = service

    def handle_get(self, request: "RouteRequest", pairing: PairingAuthority | None = None) -> bool:
        if request.path.split("?", 1)[0] != "/v1/briefing":
            return False
        if not _forwarded(request):
            request.respond_json(200, self._service.view())
        return True

    def handle_post(self, request: "RouteRequest", pairing: PairingAuthority | None = None) -> bool:
        path = request.path.split("?", 1)[0]
        match = _ACT.match(path)
        if match is None and path != "/v1/briefing/refresh":
            return False
        if _forwarded(request):
            return True
        payload = request.request_json(max_bytes=2048)
        if payload is None:
            return True
        if match is None:
            request.respond_json(202, self._service.request_refresh())
            return True
        try:
            result = self._service.act(match.group(1), payload.get("action"))
        except BriefingActionRejected as rejected:
            request.respond_json(rejected.status, {"error": {"code": rejected.code, "message": str(rejected)}})
            return True
        request.respond_json(200, result)
        return True


def _forwarded(request: "RouteRequest") -> bool:
    if request.headers.get("X-SAM-Forwarded-Origin"):
        request.respond_json(403, {"error": {"code": "device_only",
                                             "message": "The morning brief is only available on the device."}})
        return True
    return False
