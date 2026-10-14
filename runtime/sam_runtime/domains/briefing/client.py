"""HTTP client for the morning-briefing routes of the SamRabbit Mac bridge (CONTRACTS-WAVE8 A3, bridge token).

``GET /v1/briefing?wait=0`` (no long-poll: the R1 never holds a connection open), ``POST /v1/briefing/refresh``
(202 while it rebuilds) and ``POST /v1/briefing/items/<id>/act {action}``. Drafts are made by the bridge as Gmail
DRAFTS only; nothing here can send mail, and the R1's own mail domain is never used for the brief.
"""

from __future__ import annotations

from urllib.parse import quote

from sam_runtime.domains.bridge_calls import BridgeCaller
from sam_runtime.domains.heptabase_journal.bridge import BridgeStore
from sam_runtime.domains.heptabase_journal.client import HttpTransport

FETCH_TIMEOUT_SECONDS = 15.0
REFRESH_TIMEOUT_SECONDS = 10.0
# A draft reply is written by Claude on the Mac before Gmail stores it.
ACT_TIMEOUT_SECONDS = 45.0


class BriefingBridgeClient:
    def __init__(self, store: BridgeStore, transport: HttpTransport | None = None) -> None:
        self._calls = BridgeCaller(store, transport, timeout=FETCH_TIMEOUT_SECONDS)

    @property
    def store(self) -> BridgeStore:
        return self._calls.store

    def configured(self) -> bool:
        return self._calls.configured()

    def fetch(self) -> dict[str, object]:
        _status, value = self._calls.json("GET", "/v1/briefing?wait=0", timeout=FETCH_TIMEOUT_SECONDS)
        return value

    def refresh(self) -> dict[str, object]:
        _status, value = self._calls.json("POST", "/v1/briefing/refresh", body={}, timeout=REFRESH_TIMEOUT_SECONDS)
        return value

    def act(self, item_id: str, action: str) -> dict[str, object]:
        _status, value = self._calls.json("POST", f"/v1/briefing/items/{quote(item_id, safe='')}/act",
                                          body={"action": action}, timeout=ACT_TIMEOUT_SECONDS)
        return value
