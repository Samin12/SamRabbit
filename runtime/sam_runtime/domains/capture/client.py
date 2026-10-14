"""HTTP client for the voice-note route of the SamRabbit Mac bridge (CONTRACTS-WAVE8 A2, bridge token).

``POST /v1/capture`` takes the R1's own transcript as JSON ``{text, capturedAt, captureId}`` with the headers
``X-SamRabbit-Capture`` (the idempotency key, a UUID made when recording started), ``X-SamRabbit-Captured-At``
and ``X-SamRabbit-Source: r1``, and answers ``202 {captureId, state: "received"}`` once the note is safely
stored. ``GET /v1/capture/<id>?wait=0..10`` long-polls the outcome: ``{state: received|transcribed|done|failed,
heard, outcome: {kind, title, detail, threadId?, eventId?, noteId?}, suggestion?}``.

The same id may be sent any number of times: the bridge keeps one note per id, so every failure is retryable.
"""

from __future__ import annotations

from urllib.parse import quote

from sam_runtime.domains.bridge_calls import BridgeCaller, BridgeCallFailure
from sam_runtime.domains.heptabase_journal.bridge import BridgeStore
from sam_runtime.domains.heptabase_journal.client import HttpTransport

SUBMIT_TIMEOUT_SECONDS = 8.0
MAX_WAIT_SECONDS = 10
SOURCE = "r1"
# Bridge answers that will never be accepted however often the note is sent again.
PERMANENT_CODES = frozenset({"invalid_request", "invalid_json", "invalid_capture_id", "capture_conflict",
                             "body_too_large", "text_too_long", "unsupported_media_type", "mac_not_local",
                             "mac_url_invalid"})


class CaptureBridgeClient:
    def __init__(self, store: BridgeStore, transport: HttpTransport | None = None) -> None:
        self._calls = BridgeCaller(store, transport, timeout=SUBMIT_TIMEOUT_SECONDS)

    @property
    def store(self) -> BridgeStore:
        return self._calls.store

    def configured(self) -> bool:
        return self._calls.configured()

    def submit(self, capture_id: str, text: str, captured_at: str) -> dict[str, object]:
        """Hands one note to the bridge; its answer (``state`` at least ``received``)."""
        headers = {"X-SamRabbit-Capture": capture_id, "X-SamRabbit-Captured-At": captured_at,
                   "X-SamRabbit-Source": SOURCE}
        _status, value = self._calls.json("POST", "/v1/capture",
                                          body={"text": text, "capturedAt": captured_at, "captureId": capture_id},
                                          headers=headers, timeout=SUBMIT_TIMEOUT_SECONDS)
        return value

    def status(self, capture_id: str, *, wait: int = 0) -> dict[str, object]:
        seconds = max(0, min(MAX_WAIT_SECONDS, int(wait)))
        _status, value = self._calls.json("GET", f"/v1/capture/{quote(capture_id, safe='')}?wait={seconds}",
                                          timeout=seconds + 6.0)
        return value


def permanent(failure: BridgeCallFailure) -> bool:
    """True when sending the same note again cannot succeed (it is then reported as failed)."""
    if failure.code in PERMANENT_CODES:
        return True
    return failure.status is not None and 400 <= failure.status < 500 and failure.status not in (401, 403, 404, 405,
                                                                                                 408, 409, 429)
