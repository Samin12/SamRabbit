"""One authenticated call to the SamRabbit Mac bridge, for the clients added in wave 8 (voice notes, the
morning briefing).

Same pairing as every other bridge user (``BridgeStore``: the URL in ``provider_settings``, the token sealed with
``ConnectionCredentialEnvelopes`` and bound to that URL). Only private-LAN addresses are ever contacted; the
host is re-checked before every request. Failures become a ``BridgeCallFailure`` with a stable code; callers add
their own wording. Nothing here logs bodies.
"""

from __future__ import annotations

import json
import sqlite3
from urllib.parse import urlsplit

from sam_runtime.domains.heptabase_journal.bridge import BridgeStore, is_private_host
from sam_runtime.domains.heptabase_journal.client import HttpResponse, HttpTransport
from sam_runtime.domains.heptabase_journal.errors import HeptabaseError, TransportError


class BridgeCallFailure(Exception):
    """``code``: mac_not_configured | mac_token_unavailable | mac_not_local | mac_url_invalid | mac_unreachable
    (never sent) | mac_no_answer (sent, no answer) | mac_response_too_large, or a bridge error code."""

    def __init__(self, code: str, *, status: int | None = None, message: str = "", retryable: bool = False,
                 sent: bool = False) -> None:
        super().__init__(code)
        self.code = code
        self.status = status
        self.message = message
        self.retryable = retryable
        self.sent = sent


class BridgeCaller:
    def __init__(self, store: BridgeStore, transport: HttpTransport | None = None, *, timeout: float = 15.0) -> None:
        self._store = store
        self._transport = transport or HttpTransport(timeout=timeout, allow_http=is_private_host)

    @property
    def store(self) -> BridgeStore:
        return self._store

    def configured(self) -> bool:
        try:
            return self._store.config() is not None
        except sqlite3.Error:
            return False

    def request(self, method: str, path: str, *, body: dict[str, object] | None = None,
                headers: dict[str, str] | None = None, timeout: float) -> HttpResponse:
        """The bridge's answer whatever its status; raises only when there is no answer to read."""
        try:
            config = self._store.config()
        except sqlite3.Error:
            config = None
        if config is None:
            raise BridgeCallFailure("mac_not_configured", retryable=True)
        token = self._store.token(config.url)
        if token is None:
            raise BridgeCallFailure("mac_token_unavailable", retryable=True)
        if not is_private_host(urlsplit(config.url).hostname or ""):
            raise BridgeCallFailure("mac_not_local")
        merged = {"Authorization": f"Bearer {token}", "Accept": "application/json", **(headers or {})}
        raw = None
        if body is not None:
            raw = json.dumps(body, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
            merged["Content-Type"] = "application/json"
        try:
            response = self._transport.request(method, config.url + path, body=raw, headers=merged, timeout=timeout)
        except TransportError as error:
            raise BridgeCallFailure("mac_no_answer" if error.sent else "mac_unreachable", retryable=True,
                                    sent=bool(error.sent)) from None
        except HeptabaseError:
            raise BridgeCallFailure("mac_response_too_large", sent=True) from None
        except ValueError:
            raise BridgeCallFailure("mac_url_invalid") from None
        if 200 <= response.status < 300:
            note = getattr(self._store, "note_reachable", None)
            if callable(note):
                note()
        return response

    def json(self, method: str, path: str, *, body: dict[str, object] | None = None,
             headers: dict[str, str] | None = None, timeout: float) -> tuple[int, dict[str, object]]:
        """``(status, value)`` for a 2xx answer; any other answer raises with the bridge's error code."""
        response = self.request(method, path, body=body, headers=headers, timeout=timeout)
        if 200 <= response.status < 300:
            return response.status, response.json()
        raise failure_for(response)


def failure_for(response: HttpResponse) -> BridgeCallFailure:
    """401/403 → mac_unauthorized; 404/405 without a route → bridge_outdated; else the bridge's own code."""
    value = response.json()
    error = value.get("error") if isinstance(value.get("error"), dict) else {}
    code = str(error.get("code") or f"http_{response.status}")[:64]
    message = str(error.get("message") or "")[:300]
    if response.status in (401, 403):
        return BridgeCallFailure("mac_unauthorized", status=response.status, message=message, retryable=True,
                                 sent=True)
    if response.status == 405 or (response.status == 404 and code in ("not_found", "http_404")):
        return BridgeCallFailure("bridge_outdated", status=response.status, message=message, retryable=True,
                                 sent=True)
    retryable = bool(error.get("retryable")) or response.status == 429 or response.status >= 500
    return BridgeCallFailure(code, status=response.status, message=message, retryable=retryable, sent=True)
