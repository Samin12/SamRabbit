"""T3 Code domain service: pairing, cached shell snapshot, views, and commands.

One T3 server per R1. The runtime keeps an in-memory snapshot of the T3
shell (refreshed by ``T3SyncWorker``) so device routes and voice tools answer
instantly; thread details are fetched on demand with a short cache. T3 speaks
orchestration protocol 2 (see ``client.py``); the views this service returns to
the R1 app and the voice tools keep their protocol-1 shapes.

Which server gets the token. Pairing stores T3's ``environmentId`` (from the
unauthenticated ``/.well-known/t3/environment``) sealed with the token. Before
the token goes to an address, its descriptor must be T3 Code (protocol 2) with
that same ``environmentId``; the check is redone after any connection failure
and at least every ``VERIFY_TTL`` seconds. A record paired before ids were kept
("legacy") accepts a T3-looking descriptor at its own saved address and stores
that id after the first call the token works for.

T3 moving ports. T3 picks another port when its own is taken (another app on
3773 put it on 3774) and may move again on restart. When the saved address
refuses connections, or something other than our T3 answers there, the service
probes the same host's nearby ports (``nearby_ports``: 3773-3779 and the saved
port +-3, at most 10, nearest first; 1.5 s each, no token) for a descriptor with
the stored ``environmentId`` and switches the saved address to it. A timeout
(Mac asleep or off the network) never probes. Probes run at most every 30 s,
backing off to 5 min while nothing is found. A legacy record switches only when
exactly one protocol-2 T3 descriptor answers in that range, its label equals
the label seen at pairing (when one was stored), and ``/api/auth/session``
there says the token is authenticated; the id is then stored.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import replace
from datetime import UTC, datetime, timedelta
import json
import sqlite3
import threading
import time
from uuid import uuid4

from sam_runtime.core.logging import runtime_logger
from sam_runtime.security.credentials import ConnectionCredentialEnvelopes
from sam_runtime.storage.announcements import AnnouncementRepository

from .client import (
    MISMATCH,
    NOT_T3,
    REFUSED,
    T3Endpoint,
    T3Error,
    T3HttpClient,
    T3RequestError,
    T3Unauthorized,
    T3Unavailable,
    looks_like_t3,
    normalize_pairing_code,
    parse_server_url,
)
from .commands import (
    DEFAULT_INTERACTION_MODE,
    DEFAULT_MODEL_SELECTION,
    DEFAULT_RUNTIME_MODE,
    MAX_PROMPT_CHARS,
    RUNTIME_MODES,
    T3CommandBuilder,
    title_from_prompt,
)
from .matching import match_item
from .repository import T3ConnectionRecord, T3Repository
from .status import (
    ACTIVITY_ACTIVE,
    DONE,
    ERROR,
    NEEDS_APPROVAL,
    NEEDS_INPUT,
    NEEDS_YOU,
    WORKING,
    PendingInput,
    PendingQuestion,
    PendingRequests,
    activity_level,
    activity_time,
    condense,
    counts,
    holds_completion,
    last_assistant_text,
    latest_assistant_preview,
    latest_run_id,
    listed,
    missing_request_items,
    order_key,
    parse_time,
    pending_requests,
    plan_phase,
    projection_of,
    project_titles,
    run_items,
    run_live,
    seen_marker,
    shell_from_projection,
    summarize,
)
from .transitions import ERROR_EVENT, FINISHED, NEEDS_APPROVAL_EVENT, NEEDS_INPUT_EVENT, T3TransitionTracker, Transition


DEFAULT_SERVER_URL = "http://192.168.1.183:3774"
REAUTH_DETAIL = "T3 Code no longer accepts this R1. Pair again from Management > Connections."
EXPIRED_DETAIL = "T3 access expired. Pair again from Management > Connections."
MAX_MESSAGE_CHARS = 6000
MAX_MESSAGES = 40
LAST_MESSAGE_CHARS = 400
_DETAIL_TTL = 1.5
_PERSIST_SYNC_EVERY = 60.0
_FAIL_FAST_SECONDS = 5.0
_TURN_START_GRACE = 45.0
VERIFY_TTL = 60.0
PROBE_TIMEOUT = 1.5
PROBE_MIN_INTERVAL = 30.0
PROBE_MAX_INTERVAL = 300.0
_PROBE_BASE_PORTS = range(3773, 3780)
_PROBE_SPREAD = 3
_PROBE_MAX = 10
_APPROVAL_PHRASES = {
    "command": "wants approval to run a command",
    "file-change": "wants approval to edit files",
    "file-read": "wants approval to read files",
    "permission": "is asking for a permission",
    "mcp-elicitation": "wants approval for a tool request",
}

ClientFactory = Callable[[T3Endpoint, "str | None"], T3HttpClient]
PortsFor = Callable[[int], "list[int]"]


def nearby_ports(port: int) -> list[int]:
    """Ports T3 may have moved to from ``port``, nearest first (the saved port itself excluded)."""
    candidates = set(_PROBE_BASE_PORTS) | set(range(port - _PROBE_SPREAD, port + _PROBE_SPREAD + 1))
    ordered = sorted((item for item in candidates if 0 < item < 65536 and item != port), key=lambda item: (abs(item - port), item))
    return ordered[:_PROBE_MAX]


class T3NotConnected(T3Error):
    code = "t3_not_connected"


class T3ReauthRequired(T3Error):
    code = "t3_reauth_required"


class T3ThreadNotFound(T3Error):
    code = "t3_thread_not_found"


class T3InvalidRequest(T3Error, ValueError):
    code = "invalid_request"


class T3RequestNotPending(T3Error):
    code = "t3_request_not_pending"


class T3DispatchFailed(T3Error):
    code = "t3_dispatch_failed"

    def __init__(self, message: str, thread_id: str | None = None) -> None:
        super().__init__(message)
        self.thread_id = thread_id


def _utcnow() -> datetime:
    return datetime.now(UTC)


def _iso(value: datetime) -> str:
    return value.astimezone(UTC).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def _quoted(title: str) -> str:
    return "“" + " ".join(title.split())[:80] + "”"


def _is_scratch(project: dict[str, object]) -> bool:
    root = str(project.get("workspaceRoot") or "").rstrip("/")
    return root.endswith("/.t3/scratch") or str(project.get("title") or "").strip().lower() == "no project"


class T3Service:
    def __init__(
        self,
        repository: T3Repository,
        envelopes: ConnectionCredentialEnvelopes,
        *,
        announcements: AnnouncementRepository | None = None,
        client_factory: ClientFactory | None = None,
        resolver: Callable[[str], tuple[str, ...]] | None = None,
        commands: T3CommandBuilder | None = None,
        clock: Callable[[], datetime] = _utcnow,
        probe_ports: PortsFor = nearby_ports,
    ) -> None:
        self._repository = repository
        self._envelopes = envelopes
        self._announcements = announcements
        self._client_factory: ClientFactory = client_factory or (lambda endpoint, token: T3HttpClient(endpoint, token))
        self._resolver = resolver
        self._commands = commands or T3CommandBuilder()
        self._clock = clock
        self._probe_ports = probe_ports
        self._log = runtime_logger()
        self._lock = threading.RLock()
        self._sync_lock = threading.Lock()
        self._probe_lock = threading.Lock()
        self._wake: Callable[[], None] = lambda: None
        self._loaded = False
        self._record: T3ConnectionRecord | None = None
        self._token: str | None = None
        self._threads: dict[str, dict[str, object]] = {}
        self._projects: list[dict[str, object]] = []
        self._snapshot_sequence = -1
        self._seen: dict[str, str] = {}
        self._summaries: list[dict[str, object]] = []
        self._project_views: list[dict[str, object]] = []
        self._has_snapshot = False
        self._revision = 0
        self._fingerprint: str | None = None
        self._revision_at = _iso(clock())
        self._last_sync_at: str | None = None
        self._last_sync_persisted = 0.0
        self._tracker = T3TransitionTracker()
        self._detail_cache: dict[tuple[str, bool], tuple[float, dict[str, object]]] = {}
        self._down_until = 0.0
        # thread id -> (monotonic time, latest run id before) for runs this R1 just
        # requested; T3 still reports the previous run until the new one is queued.
        self._turn_requests: dict[str, tuple[float, str | None]] = {}
        self._reset_identity()

    def _reset_identity(self) -> None:
        # The environment the token belongs to (None: legacy record, not backfilled yet).
        self._environment_id: str | None = None
        # (server url, monotonic time) of the last descriptor check that allowed the token there.
        self._verified: tuple[str, float] | None = None
        self._capabilities: dict[str, object] = {}
        # A legacy record's environment id, stored after the token first works there.
        self._backfill: str | None = None
        self._probe_after = 0.0
        self._probe_interval = PROBE_MIN_INTERVAL

    # ------------------------------------------------------------------ state
    def set_wake(self, wake: Callable[[], None]) -> None:
        self._wake = wake

    def _load(self) -> None:
        if self._loaded:
            return
        record = self._repository.get()
        seen = self._repository.seen_markers() if record is not None else {}
        self._record = record
        self._token = None
        self._seen = seen
        self._loaded = True
        if record is not None:
            self._last_sync_at = record.last_sync_at

    def _effective_health(self, record: T3ConnectionRecord) -> tuple[str, str | None]:
        expires = parse_time(record.expires_at)
        if expires is not None and expires <= self._clock():
            return "reauth", EXPIRED_DETAIL
        return record.health_state, record.health_detail

    def _current(self) -> T3ConnectionRecord | None:
        """The stored connection, or None if storage is not ready (never raises)."""
        with self._lock:
            try:
                self._load()
            except sqlite3.Error:
                return None
            return self._record

    def has_credential(self) -> bool:
        return self._current() is not None

    def connected(self) -> bool:
        """Paired and not waiting for re-pairing (the server may still be briefly unreachable)."""
        record = self._current()
        return record is not None and self._effective_health(record)[0] != "reauth"

    def needs_reauth(self) -> bool:
        record = self._current()
        return record is not None and self._effective_health(record)[0] == "reauth"

    def has_active(self) -> bool:
        with self._lock:
            return any(item["status"] in NEEDS_YOU or item["status"] == WORKING for item in self._summaries)

    def activity_level(self) -> str:
        """Poll cadence tier from the last shell (see ``status.activity_level``).

        A run this R1 just requested counts as active until it shows up (or its grace ends),
        so a new thread or message from the R1 is followed at the fast cadence even before T3
        reports the run as queued.
        """
        with self._lock:
            threads = dict(self._threads)
            requested = list(self._turn_requests)
        for thread_id in requested:
            if self._awaiting_turn_start(thread_id, threads.get(thread_id, {})):
                return ACTIVITY_ACTIVE
        return activity_level(list(threads.values()))

    def status_view(self) -> dict[str, object]:
        record = self._current()
        with self._lock:
            if record is None:
                return {
                    "connected": False, "serverUrl": None, "label": None, "healthState": "unconfigured",
                    "detail": None, "expiresAt": None, "lastSyncAt": None,
                }
            health, detail = self._effective_health(record)
            if health == "ready":
                detail = self._expiry_hint(record) or detail
            return {
                "connected": health != "reauth",
                "serverUrl": record.server_url,
                "label": record.environment_label,
                "healthState": health,
                "detail": detail,
                "expiresAt": record.expires_at,
                "lastSyncAt": self._last_sync_at,
            }

    def management_view(self) -> dict[str, object]:
        view = self.status_view()
        with self._lock:
            record = self._record
            view.update({
                "credentialPresent": record is not None,
                "defaultServerUrl": DEFAULT_SERVER_URL,
                "scopes": record.scopes.split() if record is not None and record.scopes else [],
                "counts": counts(self._summaries) if record is not None and self._has_snapshot else None,
                "threadCount": len(self._summaries) if record is not None and self._has_snapshot else None,
            })
        return view

    def _expiry_hint(self, record: T3ConnectionRecord) -> str | None:
        expires = parse_time(record.expires_at)
        if expires is None:
            return None
        remaining = expires - self._clock()
        if remaining <= timedelta(days=3):
            days = max(0, remaining.days)
            when = "today" if days == 0 else ("in 1 day" if days == 1 else f"in {days} days")
            return f"Access expires {when}. Pair again soon."
        return None

    # ---------------------------------------------------------------- pairing
    def connect(self, server_url: object, pairing_code: object) -> dict[str, object]:
        code, link_url = normalize_pairing_code(pairing_code)
        raw_url = str(server_url or "").strip() or link_url or DEFAULT_SERVER_URL
        endpoint = parse_server_url(raw_url, **({"resolver": self._resolver} if self._resolver else {}))
        anonymous = self._client_factory(endpoint, None)
        descriptor = anonymous.descriptor()
        if not looks_like_t3(descriptor):
            raise T3Unavailable("That T3 Code is too old for this R1. Update T3 Code on the Mac.", NOT_T3)
        environment_id = str(descriptor["environmentId"]).strip()
        label = descriptor.get("label")
        environment_label = str(label).strip()[:80] if isinstance(label, str) and label.strip() else None
        exchanged = anonymous.exchange_pairing_code(code)
        token = str(exchanged["access_token"])
        authed = self._client_factory(endpoint, token)
        expires_at: str | None = None
        scopes = str(exchanged.get("scope") or "")
        try:
            session = authed.session_state()
            if isinstance(session.get("expiresAt"), str):
                expires_at = str(session["expiresAt"])
            if isinstance(session.get("scopes"), list):
                scopes = " ".join(str(item) for item in session["scopes"])
        except T3Unavailable:
            pass
        if expires_at is None and isinstance(exchanged.get("expires_in"), (int, float)):
            expires_at = _iso(self._clock() + timedelta(seconds=float(exchanged["expires_in"])))
        shell = authed.shell()
        connection_id = str(uuid4())
        envelope = self._envelopes.seal(connection_id, _sealed(token, environment_id))
        with self._sync_lock:
            record = self._repository.replace(
                connection_id=connection_id,
                server_url=endpoint.url,
                environment_label=environment_label,
                scopes=scopes,
                expires_at=expires_at,
                envelope=envelope,
            )
            with self._lock:
                self._loaded = True
                self._reset_state()
                self._record = record
                self._token = token
                self._environment_id = environment_id
                self._verified = (endpoint.url, time.monotonic())
                self._capabilities = _capabilities(descriptor)
            transitions = self._apply_shell(shell)
        del transitions
        self._log.info("t3.connected", extra={"server": endpoint.url})
        self._wake()
        return self.management_view()

    def disconnect(self) -> dict[str, object]:
        with self._sync_lock:
            self._repository.remove()
            with self._lock:
                self._loaded = True
                self._reset_state()
        self._log.info("t3.disconnected")
        self._wake()
        view = self.management_view()
        view["revokeHint"] = "To also revoke this R1 on the Mac, open T3 Code > Settings > Connections."
        return view

    def _reset_state(self) -> None:
        self._record = None
        self._token = None
        self._threads = {}
        self._projects = []
        self._snapshot_sequence = -1
        self._seen = {}
        self._summaries = []
        self._project_views = []
        self._has_snapshot = False
        self._last_sync_at = None
        self._tracker.reset()
        self._detail_cache.clear()
        self._turn_requests.clear()
        self._reset_identity()
        self._recompute()

    # ------------------------------------------------------------- transport
    def _client(self, *, probe: bool = False) -> tuple[T3ConnectionRecord, T3HttpClient]:
        """Client for the paired server, after the identity check (module docstring). Fails fast
        for a few seconds after a network failure (unless ``probe``), so screens polling an
        asleep Mac never pile up. A closed port or the wrong server tries rediscovery first."""
        with self._lock:
            self._load()
            record = self._record
            if record is None:
                raise T3NotConnected("T3 Code is not connected.")
            health, _ = self._effective_health(record)
            if health == "reauth":
                raise T3ReauthRequired(EXPIRED_DETAIL if record.health_state != "reauth" else REAUTH_DETAIL)
            if not probe and time.monotonic() < self._down_until:
                raise T3Unavailable("T3 Code was unreachable moments ago.")
            if self._token is None:
                envelope = self._repository.envelope(record.connection_id)
                try:
                    opened = json.loads(self._envelopes.open(record.connection_id, envelope or ""))
                    self._token = str(opened["token"])
                    stored = opened.get("environmentId")
                    self._environment_id = str(stored) if isinstance(stored, str) and stored else None
                except Exception:
                    raise T3NotConnected("The T3 Code credential is unavailable. Pair again.") from None
            token = self._token
        client = self._client_factory(parse_server_url(record.server_url, verify_host=False), token)
        try:
            self._verify(record, client.endpoint)
        except T3Unavailable as error:
            moved = self._rediscover(record, error)
            if moved is None:
                with self._lock:
                    self._down_until = time.monotonic() + _FAIL_FAST_SECONDS
                raise
            return moved
        return record, client

    def _verify(self, record: T3ConnectionRecord, endpoint: T3Endpoint) -> None:
        """Allow the token at ``record.server_url`` only if our T3 environment answers there."""
        with self._lock:
            verified = self._verified
            expected = self._environment_id
        if verified is not None and verified[0] == record.server_url and time.monotonic() - verified[1] < VERIFY_TTL:
            return
        descriptor = self._client_factory(endpoint, None).descriptor()
        if not looks_like_t3(descriptor):
            raise T3Unavailable("Something other than T3 Code answers at the saved address.", NOT_T3)
        found = str(descriptor["environmentId"]).strip()
        if expected is not None and found != expected:
            self._log.warning("t3.server.mismatch", extra={"server": record.server_url})
            raise T3Unavailable("A different T3 Code answers at the saved address.", MISMATCH)
        with self._lock:
            self._verified = (record.server_url, time.monotonic())
            self._capabilities = _capabilities(descriptor)
            if expected is None:
                self._backfill = found

    def _rediscover(self, record: T3ConnectionRecord, error: T3Unavailable) -> tuple[T3ConnectionRecord, T3HttpClient] | None:
        """Find the same T3 environment on a nearby port of the saved host (module docstring)."""
        if error.reason not in {REFUSED, NOT_T3, MISMATCH}:
            return None
        if not self._probe_lock.acquire(blocking=False):
            return None
        try:
            with self._lock:
                if time.monotonic() < self._probe_after:
                    return None
                expected = self._environment_id
                token = self._token
            saved = parse_server_url(record.server_url, verify_host=False)
            found: list[tuple[T3Endpoint, dict[str, object]]] = []
            for port in self._probe_ports(saved.port):
                candidate = T3Endpoint(saved.scheme, saved.host, port)
                try:
                    descriptor = self._client_factory(candidate, None).descriptor(timeout=PROBE_TIMEOUT)
                except T3Error:
                    continue
                if not looks_like_t3(descriptor):
                    continue
                found.append((candidate, descriptor))
                if expected is not None and str(descriptor["environmentId"]).strip() == expected:
                    break
            chosen = self._choose_moved(record, found, expected, token)
            if chosen is None:
                with self._lock:
                    self._probe_after = time.monotonic() + self._probe_interval
                    self._probe_interval = min(PROBE_MAX_INTERVAL, self._probe_interval * 2)
                self._log.info("t3.rediscover.none", extra={"candidates": len(found)})
                return None
            endpoint, descriptor = chosen
            environment_id = str(descriptor["environmentId"]).strip()
            moved = self._repository.set_server_url(record.connection_id, endpoint.url) or replace(record, server_url=endpoint.url)
            with self._lock:
                if self._record is None or self._record.connection_id != record.connection_id:
                    return None
                self._record = replace(self._record, server_url=moved.server_url)
                self._verified = (endpoint.url, time.monotonic())
                self._capabilities = _capabilities(descriptor)
                self._down_until = 0.0
                self._probe_after = 0.0
                self._probe_interval = PROBE_MIN_INTERVAL
                current = self._record
            if expected is None:
                self._store_identity(current, environment_id)
            self._log.info("t3.server.moved", extra={"fromPort": saved.port, "toPort": endpoint.port})
            return current, self._client_factory(endpoint, token)
        finally:
            self._probe_lock.release()

    def _choose_moved(
        self,
        record: T3ConnectionRecord,
        found: list[tuple[T3Endpoint, dict[str, object]]],
        expected: str | None,
        token: str | None,
    ) -> tuple[T3Endpoint, dict[str, object]] | None:
        if expected is not None:
            return next((item for item in found if str(item[1]["environmentId"]).strip() == expected), None)
        # Legacy record: no id to match, so only an unambiguous candidate that knows our token.
        if record.environment_label:
            found = [item for item in found if str(item[1].get("label") or "").strip()[:80] == record.environment_label]
        if len(found) != 1 or not token:
            return None
        try:
            session = self._client_factory(found[0][0], token).session_state()
        except T3Error:
            return None
        return found[0] if session.get("authenticated") is True else None

    def _store_identity(self, record: T3ConnectionRecord, environment_id: str) -> None:
        """Seal the environment id next to the token (backfill for records paired before ids)."""
        with self._lock:
            token = self._token
            if token is None or self._environment_id is not None:
                return
            self._environment_id = environment_id
            self._backfill = None
        try:
            envelope = self._envelopes.seal(record.connection_id, _sealed(token, environment_id))
            self._repository.set_envelope(record.connection_id, envelope)
            self._log.info("t3.identity.stored")
        except Exception:
            self._log.warning("t3.identity.persist_failed")

    def _guard(self, record: T3ConnectionRecord, call: Callable[[], object]) -> object:
        try:
            value = call()
        except T3Unauthorized:
            self._set_health(record, "reauth", REAUTH_DETAIL)
            raise T3ReauthRequired(REAUTH_DETAIL) from None
        except T3Unavailable:
            with self._lock:
                self._down_until = time.monotonic() + _FAIL_FAST_SECONDS
                self._verified = None
            raise
        with self._lock:
            self._down_until = 0.0
            backfill = self._backfill
        if backfill is not None:
            self._store_identity(record, backfill)
        return value

    def _set_health(self, record: T3ConnectionRecord, state: str, detail: str | None) -> None:
        with self._lock:
            current = self._record
            if current is None or current.connection_id != record.connection_id:
                return
            if current.health_state == state and current.health_detail == detail:
                return
            self._record = replace(current, health_state=state, health_detail=detail)
        try:
            self._repository.set_health(record.connection_id, state, detail)
        except Exception:
            self._log.warning("t3.health.persist_failed")

    def _capability(self, name: str) -> bool:
        with self._lock:
            return self._capabilities.get(name) is True

    # ------------------------------------------------------------------ sync
    def sync_once(self, *, probe: bool = True) -> bool:
        """Fetch the shell once, update the snapshot, announce transitions. Returns has_active."""
        with self._sync_lock:
            try:
                record, client = self._client(probe=probe)
            except T3Unavailable:
                record = self._current()
                if record is not None:
                    self._set_health(record, "failed", f"Cannot reach T3 Code at {record.server_url}.")
                raise
            try:
                try:
                    shell = self._guard(record, client.shell)
                except T3Unavailable as error:
                    moved = self._rediscover(record, error)
                    if moved is None:
                        raise
                    record, client = moved
                    shell = self._guard(record, client.shell)
            except T3ReauthRequired:
                raise
            except T3Error:
                self._set_health(record, "failed", f"Cannot reach T3 Code at {record.server_url}.")
                raise
            transitions = self._apply_shell(shell)
            self._set_health(record, "ready", None)
            self._announce(record, client, transitions)
        return self.has_active()

    def ensure_snapshot(self, *, required: bool = False) -> None:
        """Load the first snapshot on demand (route/tool called before the poller ran).

        ``required`` re-raises the failure when there is still no snapshot, so callers
        that would otherwise report "no projects" or "no threads" say the Mac is
        unreachable instead.
        """
        with self._lock:
            ready = self._has_snapshot
        if not ready:
            try:
                self.sync_once(probe=False)
            except T3Error:
                if required:
                    raise

    def _apply_shell(self, shell: dict[str, object]) -> list[Transition]:
        sequence = shell.get("snapshotSequence")
        threads = [thread for thread in shell.get("threads", []) or [] if listed(thread)]
        projects = [project for project in shell.get("projects", []) or [] if isinstance(project, dict) and project.get("id")]
        with self._lock:
            record = self._record
            if record is None:
                return []
            if isinstance(sequence, int):
                self._snapshot_sequence = sequence
            self._threads = {str(thread["id"]): thread for thread in threads}
            self._projects = projects
            self._has_snapshot = True
            if record.baseline_pending:
                markers = {str(thread["id"]): seen_marker(thread) for thread in threads}
                markers = {key: value for key, value in markers.items() if value}
                self._repository.finish_baseline(record.connection_id, markers)
                self._seen.update(markers)
                self._record = replace(record, baseline_pending=False)
            transitions = self._tracker.observe(threads)
            now = self._clock()
            self._last_sync_at = _iso(now)
            persist = time.monotonic() - self._last_sync_persisted >= _PERSIST_SYNC_EVERY
            if persist:
                self._last_sync_persisted = time.monotonic()
            self._recompute()
        if persist:
            try:
                self._repository.mark_synced(record.connection_id, self._last_sync_at or _iso(now))
            except Exception:
                self._log.warning("t3.sync.persist_failed")
        return transitions

    def _recompute(self) -> None:
        now = self._clock()
        titles = project_titles({"projects": self._projects})
        pairs = []
        for thread_id, thread in self._threads.items():
            summary = summarize(thread, titles, seen=self._seen.get(thread_id))
            pairs.append((order_key(thread, summary, now), summary))
        pairs.sort(key=lambda pair: pair[0])
        self._summaries = [summary for _, summary in pairs]
        recency: dict[str, datetime] = {}
        for thread in self._threads.values():
            stamp = parse_time(activity_time(thread))
            project_id = str(thread.get("projectId") or "")
            if stamp is not None and (project_id not in recency or stamp > recency[project_id]):
                recency[project_id] = stamp
        floor = datetime.min.replace(tzinfo=UTC)
        ordered = sorted(self._projects, key=lambda project: recency.get(str(project["id"]), floor), reverse=True)
        self._project_views = [{"id": str(project["id"]), "title": str(project.get("title") or "Project")} for project in ordered]
        fingerprint = json.dumps(
            [self._record is not None, self._summaries, self._project_views],
            sort_keys=True,
            separators=(",", ":"),
        )
        if fingerprint != self._fingerprint:
            self._fingerprint = fingerprint
            # Never below wall-clock seconds, so a restarted runtime cannot repeat a
            # revision the app already holds (it skips re-rendering on an equal one).
            self._revision = max(self._revision + 1, int(time.time()))
            self._revision_at = _iso(now)

    # --------------------------------------------------------- announcements
    def _announce(self, record: T3ConnectionRecord, client: T3HttpClient, transitions: list[Transition]) -> None:
        if self._announcements is None or not transitions:
            return
        titles = project_titles({"projects": self._projects})
        for transition in transitions:
            try:
                self._announce_one(record, client, transition, titles)
            except T3ReauthRequired:
                return
            except Exception:
                self._log.warning("t3.announce.failed", extra={"event": transition.event})

    def _announce_one(
        self,
        record: T3ConnectionRecord,
        client: T3HttpClient,
        transition: Transition,
        titles: dict[str, str],
    ) -> None:
        thread = transition.thread
        thread_id = transition.thread_id
        title = str(thread.get("title") or "Untitled thread")
        project_id = str(thread.get("projectId") or "")
        project_title = titles.get(project_id, "T3 Code")
        where = f"{_quoted(title)} in {project_title}"
        base = {
            "threadId": thread_id,
            "title": title,
            "projectId": project_id,
            "projectTitle": project_title,
            "turnId": transition.turn_id,
        }
        assert self._announcements is not None
        if transition.event == FINISHED:
            if not self._tracker.claim((thread_id, transition.turn_id or "", DONE)):
                return
            text = latest_assistant_preview(thread)
            if text is None:
                detail = self._detail_quiet(record, client, thread_id)
                text = last_assistant_text(detail) if detail else None
            self._announcements.publish(
                "t3.thread.finished", title, f"{where} finished.",
                {**base, "status": DONE, "lastMessage": condense(text, LAST_MESSAGE_CHARS)},
            )
            return
        if transition.event == ERROR_EVENT:
            if not self._tracker.claim((thread_id, transition.turn_id or "", ERROR)):
                return
            text = latest_assistant_preview(thread)
            if text is None:
                detail = self._detail_quiet(record, client, thread_id)
                text = last_assistant_text(detail) if detail else None
            error_text = condense(str(thread.get("lastError") or ""), 200)
            self._announcements.publish(
                "t3.thread.error", title, f"{where} hit an error.",
                {**base, "status": ERROR, "error": error_text or None, "lastMessage": condense(text, LAST_MESSAGE_CHARS)},
            )
            return
        detail = self._detail_quiet(record, client, thread_id)
        if detail and missing_request_items(detail):
            detail = self._detail_quiet(record, client, thread_id, full=True) or detail
        pending = pending_requests(detail) if detail else PendingRequests()
        last = condense(latest_assistant_preview(thread) or (last_assistant_text(detail) if detail else None), LAST_MESSAGE_CHARS)
        if transition.event == NEEDS_APPROVAL_EVENT:
            approvals = pending.approvals or ()
            if not approvals:
                if self._tracker.claim((thread_id, transition.turn_id or "", NEEDS_APPROVAL)):
                    self._announcements.publish(
                        "t3.thread.needs_approval", title, f"{where} needs your approval.",
                        {**base, "status": NEEDS_APPROVAL, "requestId": None, "lastMessage": last},
                    )
                return
            for approval in approvals:
                if not self._tracker.claim((thread_id, approval.request_id, NEEDS_APPROVAL)):
                    continue
                phrase = _APPROVAL_PHRASES.get(approval.kind, "needs your approval")
                self._announcements.publish(
                    "t3.thread.needs_approval", title, f"{where} {phrase}.",
                    {
                        **base, "status": NEEDS_APPROVAL, "requestId": approval.request_id,
                        "requestKind": approval.kind, "detail": condense(approval.detail, 200) or None,
                        "lastMessage": last,
                    },
                )
            return
        if transition.event == NEEDS_INPUT_EVENT:
            inputs = pending.inputs or ()
            if not inputs:
                if self._tracker.claim((thread_id, transition.turn_id or "", NEEDS_INPUT)):
                    self._announcements.publish(
                        "t3.thread.needs_input", title, f"{where} has a question for you.",
                        {**base, "status": NEEDS_INPUT, "requestId": None, "lastMessage": last},
                    )
                return
            for request in inputs:
                if not self._tracker.claim((thread_id, request.request_id, NEEDS_INPUT)):
                    continue
                question = request.questions[0].question if request.questions else ""
                short = condense(question, 120)
                text = f"{where} asks: {short}" if short and len(question) <= 120 else f"{where} has a question for you."
                if text and text[-1] not in ".?!":
                    text += "?" if short else "."
                self._announcements.publish(
                    "t3.thread.needs_input", title, text,
                    {
                        **base, "status": NEEDS_INPUT, "requestId": request.request_id,
                        "question": condense(question, 300) or None, "lastMessage": last,
                    },
                )

    def _detail_quiet(self, record: T3ConnectionRecord, client: T3HttpClient, thread_id: str, *, full: bool = False) -> dict[str, object] | None:
        try:
            value = self._guard(record, lambda: client.thread(thread_id, full=full))
        except T3ReauthRequired:
            raise
        except T3Error:
            return None
        return value if isinstance(value, dict) else None

    # ------------------------------------------------------------------ views
    def threads_view(self, limit: int = 40) -> dict[str, object]:
        limit = max(1, min(100, int(limit)))
        if self.connected():
            self.ensure_snapshot()
        with self._lock:
            connected = self._record is not None and self._effective_health(self._record)[0] != "reauth"
            return {
                "connected": connected,
                "revision": self._revision,
                "updatedAt": self._revision_at,
                "counts": counts(self._summaries) if connected else {"needsYou": 0, "working": 0, "done": 0, "error": 0},
                "projects": [dict(item) for item in self._project_views] if connected else [],
                "threads": [dict(item) for item in self._summaries[:limit]] if connected else [],
            }

    def summaries(self) -> list[dict[str, object]]:
        with self._lock:
            return [dict(item) for item in self._summaries]

    def projects(self) -> list[dict[str, object]]:
        with self._lock:
            return [dict(item) for item in self._project_views]

    def project_records(self) -> list[dict[str, object]]:
        """Projects most recently active first, with the fields placement needs (no secrets).

        ``scratch`` marks T3's "No project" scratch space."""
        with self._lock:
            by_id = {str(item["id"]): item for item in self._projects}
            order = [str(item["id"]) for item in self._project_views]
        records = []
        for project_id in order:
            item = by_id.get(project_id)
            if item is None:
                continue
            identity = item.get("repositoryIdentity")
            records.append({
                "id": project_id,
                "title": str(item.get("title") or "Project"),
                "workspaceRoot": str(item.get("workspaceRoot") or ""),
                "repository": identity if isinstance(identity, dict) else None,
                "scratch": _is_scratch(item),
            })
        return records

    def summary(self, thread_id: str) -> dict[str, object] | None:
        with self._lock:
            for item in self._summaries:
                if item["id"] == thread_id:
                    return dict(item)
        return None

    def thread_detail(self, thread_id: str, *, fresh: bool = False, full: bool = False) -> dict[str, object]:
        """The thread snapshot ``{snapshotSequence, projection}``: T3's bounded recent window, or
        the whole projection with ``full``. Cached for ``_DETAIL_TTL`` seconds."""
        record, client = self._client()
        key = (thread_id, full)
        if not fresh:
            with self._lock:
                cached = self._detail_cache.get(key)
            if cached is not None and time.monotonic() - cached[0] < _DETAIL_TTL:
                return cached[1]
        try:
            detail = self._guard(record, lambda: client.thread(thread_id, full=full))
        except T3RequestError as error:
            if error.status == 404:
                raise T3ThreadNotFound("That T3 thread was not found.") from None
            raise
        assert isinstance(detail, dict)
        with self._lock:
            if len(self._detail_cache) > 24:
                self._detail_cache.clear()
            self._detail_cache[key] = (time.monotonic(), detail)
        return detail

    def _invalidate(self, thread_id: str) -> None:
        with self._lock:
            for key in [key for key in self._detail_cache if key[0] == thread_id]:
                self._detail_cache.pop(key, None)

    def _note_turn_requested(self, thread_id: str, previous_run_id: object) -> None:
        with self._lock:
            self._turn_requests[thread_id] = (time.monotonic(), str(previous_run_id) if previous_run_id else None)
            if len(self._turn_requests) > 32:
                oldest = min(self._turn_requests, key=lambda key: self._turn_requests[key][0])
                self._turn_requests.pop(oldest, None)

    def _awaiting_turn_start(self, thread_id: str, thread: dict[str, object]) -> bool:
        """True while a run this R1 requested has not shown up in ``thread`` (shell-like) yet."""
        with self._lock:
            requested = self._turn_requests.get(thread_id)
            if requested is None:
                return False
            at, previous_run = requested
            started = run_live(thread) or latest_run_id(thread) != previous_run
            if started or time.monotonic() - at > _TURN_START_GRACE:
                self._turn_requests.pop(thread_id, None)
                return False
            return True

    def _summary_from_shell(self, thread: dict[str, object]) -> dict[str, object]:
        with self._lock:
            titles = project_titles({"projects": self._projects})
            seen = self._seen.get(str(thread.get("id")))
        return summarize(thread, titles, seen=seen)

    def thread_view(self, thread_id: str, *, turns: int = 3) -> dict[str, object]:
        detail = self.thread_detail(thread_id)
        if missing_request_items(detail):
            detail = self.thread_detail(thread_id, full=True)
        projection = projection_of(detail)
        current = shell_from_projection(detail)
        pending = pending_requests(detail)
        summary = self.summary(thread_id) or self._summary_from_shell(current)
        messages = []
        for message in projection.get("messages", []) or []:
            if not isinstance(message, dict) or message.get("role") not in {"user", "assistant"}:
                continue
            if message.get("notification") is not None:
                continue
            text = str(message.get("text") or "")
            if len(text) > MAX_MESSAGE_CHARS:
                text = text[: MAX_MESSAGE_CHARS - 1] + "…"
            if not text.strip() and not message.get("streaming"):
                continue
            messages.append({
                "id": str(message.get("id") or ""),
                "role": str(message["role"]),
                "text": text,
                "createdAt": str(message.get("createdAt") or ""),
                "streaming": message.get("streaming") is True,
            })
        # ``turns``: keep the last that many user turns (T3's window is already bounded).
        users = [index for index, item in enumerate(messages) if item["role"] == "user"]
        if len(users) > max(1, int(turns)):
            messages = messages[users[-max(1, int(turns))]:]
        active = current.get("activeRunId") if run_live(current) else None
        return {
            "thread": summary,
            "messages": messages[-MAX_MESSAGES:],
            "pending": pending.view(),
            "activeTurnId": str(active) if active else None,
        }

    def pending(self, thread_id: str) -> PendingRequests:
        detail = self.thread_detail(thread_id, fresh=True)
        pending = pending_requests(detail)
        if missing_request_items(detail):
            pending = pending_requests(self.thread_detail(thread_id, fresh=True, full=True))
        return pending

    def live_view(self, thread_id: str) -> dict[str, object]:
        detail = self.thread_detail(thread_id)
        current = shell_from_projection(detail)
        pending = pending_requests(detail)
        summary = self.summary(thread_id) or self._summary_from_shell(current)
        status = str(summary["status"])
        status_label = str(summary["statusLabel"])
        if status in {DONE, ERROR} and self._awaiting_turn_start(thread_id, current):
            # Still showing the previous run: a terminal snapshot now would make the
            # live card stop polling before the requested run even starts.
            status, status_label = WORKING, "Starting"
        live_status = {WORKING: "active", NEEDS_APPROVAL: "warn", NEEDS_INPUT: "warn", ERROR: "error"}.get(status, "ok")
        run_id = latest_run_id(current)
        if status == DONE and not run_id:
            live_status = "idle"
        # Terminal only for a finished run (genui contract: ok/error); a thread with
        # no run yet ("idle") may still start.
        terminal = live_status in {"ok", "error"}
        items = run_items(detail, run_id) if run_id else []
        todo = next((item for item in reversed(items) if item.get("type") == "todo_list"), None)
        step, progress = plan_phase(todo.get("steps")) if todo else (None, None)
        parts = [str(summary.get("projectTitle") or "")]
        if summary.get("model"):
            parts.append(str(summary["model"]))
        parts.append(status_label)
        started = parse_time(current.get("latestRunStartedAt") or current.get("latestRunRequestedAt"))
        if status == WORKING and run_live(current) and started is not None:
            minutes = int(max(0.0, (self._clock() - started).total_seconds()) // 60)
            parts.append(f"{minutes}m" if minutes else "<1m")
        if status == NEEDS_APPROVAL and pending.approvals:
            phase = condense(pending.approvals[0].detail or "Approval needed", 60)
        elif status == NEEDS_INPUT and pending.inputs and pending.inputs[0].questions:
            phase = condense(pending.inputs[0].questions[0].question, 60)
        elif status == WORKING and step:
            phase = step
        else:
            phase = summary.get("phase") or status_label
        return {
            "status": live_status,
            "terminal": terminal,
            "subtitle": " · ".join(part for part in parts if part),
            "phase": phase,
            "progress": progress if status == WORKING else summary.get("progress"),
            "items": _activity_items(items),
            "text": condense(last_assistant_text(detail), 280),
            "updatedAt": str(current.get("updatedAt") or summary.get("updatedAt") or ""),
            "nextPollMs": 3000 if live_status == "active" else (5000 if live_status == "warn" else 20000),
        }

    # --------------------------------------------------------------- commands
    def _known_thread(self, thread_id: str) -> dict[str, object]:
        """The cached shell thread, or one built from its projection when the shell lacks it."""
        thread_id = str(thread_id or "").strip()
        if not thread_id:
            raise T3InvalidRequest("A thread id is required.")
        self.ensure_snapshot()
        with self._lock:
            thread = self._threads.get(thread_id)
        if thread is not None:
            return thread
        detail = self.thread_detail(thread_id)
        thread = shell_from_projection(detail)
        if not thread.get("id"):
            raise T3ThreadNotFound("That T3 thread was not found.")
        return thread

    def _write(self, record: T3ConnectionRecord, call: Callable[[], object]) -> dict[str, object]:
        """One WebSocket RPC write, sent again once on a network failure (T3 dedupes by commandId),
        after the address is checked again: the failure cleared the identity check."""
        try:
            value = self._guard(record, call)
        except T3Unavailable:
            self._verify(record, parse_server_url(record.server_url, verify_host=False))
            value = self._guard(record, call)
        return value if isinstance(value, dict) else {}

    def resolve_project(self, project_id: str | None = None, project: str | None = None) -> dict[str, object]:
        self.ensure_snapshot(required=True)
        with self._lock:
            projects = list(self._projects)
            order = [item["id"] for item in self._project_views]
        if not projects:
            raise T3InvalidRequest("T3 Code has no projects yet. Add one on the Mac first.")
        by_id = {str(item["id"]): item for item in projects}
        ordered = [by_id[str(item)] for item in order if str(item) in by_id]
        if project_id:
            found = by_id.get(str(project_id).strip())
            if found is None:
                raise T3InvalidRequest("That project was not found in T3 Code.")
            return found
        if project and str(project).strip():
            result = match_item(str(project), ordered)
            if result.item is not None:
                return result.item
            names = ", ".join(str(item.get("title")) for item in (result.candidates or ordered[:4]))
            raise T3InvalidRequest(f"No single project matches “{project}”. Projects: {names}.")
        for item in ordered:
            if not _is_scratch(item):
                return item
        return ordered[0]

    def create_thread(
        self,
        text: str,
        *,
        title: str | None = None,
        project_id: str | None = None,
        project: str | None = None,
        runtime_mode: str | None = None,
    ) -> dict[str, object]:
        prompt = str(text or "").strip()
        if not prompt:
            raise T3InvalidRequest("Say what the new thread should do.")
        if len(prompt) > MAX_PROMPT_CHARS:
            raise T3InvalidRequest("That prompt is too long.")
        if runtime_mode is not None and runtime_mode not in RUNTIME_MODES:
            raise T3InvalidRequest("runtimeMode is invalid.")
        record, client = self._client()
        chosen = self.resolve_project(project_id, project)
        chosen_id = str(chosen["id"])
        with self._lock:
            siblings = [thread for thread in self._threads.values() if str(thread.get("projectId")) == chosen_id]
        floor = datetime.min.replace(tzinfo=UTC)
        siblings.sort(key=lambda thread: parse_time(activity_time(thread)) or floor, reverse=True)
        recent = siblings[0] if siblings else None
        selection = None
        if recent is not None and isinstance(recent.get("modelSelection"), dict) and recent["modelSelection"].get("model"):
            selection = dict(recent["modelSelection"])
        elif isinstance(chosen.get("defaultModelSelection"), dict) and chosen["defaultModelSelection"].get("model"):
            selection = dict(chosen["defaultModelSelection"])
        selection = selection or dict(DEFAULT_MODEL_SELECTION)
        mode = runtime_mode or (str(recent.get("runtimeMode")) if recent is not None and recent.get("runtimeMode") in RUNTIME_MODES else DEFAULT_RUNTIME_MODE)
        name = " ".join(str(title or "").split())[:80]
        generate_title = not name
        name = name or title_from_prompt(prompt)
        thread_id = self._commands.new_id()
        launch = self._commands.launch_thread(
            thread_id=thread_id,
            project_id=chosen_id,
            title=name,
            text=prompt,
            model_selection=selection,
            runtime_mode=mode,
            interaction_mode=DEFAULT_INTERACTION_MODE,
            generate_title=generate_title,
        )
        try:
            self._write(record, lambda: client.launch_thread(launch))
        except T3ReauthRequired:
            raise
        except T3Error as error:
            raise T3DispatchFailed(f"T3 Code could not create the thread ({type(error).__name__}).") from None
        self._note_turn_requested(thread_id, None)
        self._log.info("t3.thread.created", extra={"project": chosen_id})
        self._wake()
        return {
            "threadId": thread_id,
            "title": name,
            "projectId": chosen_id,
            "projectTitle": str(chosen.get("title") or "Project"),
            "runtimeMode": mode,
            "model": selection.get("model"),
        }

    def send_message(self, thread_id: str, text: str) -> dict[str, object]:
        body = str(text or "").strip()
        if not body:
            raise T3InvalidRequest("The message is empty.")
        if len(body) > MAX_PROMPT_CHARS:
            raise T3InvalidRequest("That message is too long.")
        record, client = self._client()
        thread = self._known_thread(thread_id)
        was_working = run_live(thread)
        command = self._commands.message(
            thread_id=str(thread["id"]), text=body,
            server_resolved=self._capability("serverResolvedCommandContext"), run_live=was_working,
        )
        self._dispatch_or_fail(record, client, command)
        if not was_working:
            self._note_turn_requested(str(thread["id"]), latest_run_id(thread))
        self._invalidate(str(thread["id"]))
        self._wake()
        return {"ok": True, "threadId": str(thread["id"]), "title": str(thread.get("title") or ""), "wasWorking": was_working}

    def respond_approval(self, thread_id: str, request_id: str, decision: str) -> dict[str, object]:
        decision = str(decision or "").strip()
        if decision not in {"accept", "acceptForSession", "acceptAlways", "decline", "cancel"}:
            raise T3InvalidRequest("decision must be accept, acceptForSession, decline, or cancel.")
        record, client = self._client()
        pending = self.pending(thread_id)
        approval = next((item for item in pending.approvals if item.request_id == request_id), None)
        if approval is None:
            raise T3RequestNotPending("That approval is no longer pending.")
        allowed = {option["decision"] for option in approval.options}
        if decision not in allowed:
            raise T3InvalidRequest("That decision is not offered for this approval.")
        command = self._commands.approval_respond(thread_id=thread_id, request_id=request_id, decision=decision)
        self._dispatch_or_fail(record, client, command)
        self._invalidate(thread_id)
        self._wake()
        return {"ok": True, "threadId": thread_id, "requestId": request_id, "decision": decision}

    def respond_input(self, thread_id: str, request_id: str, answers: object) -> dict[str, object]:
        if not isinstance(answers, dict) or not answers:
            raise T3InvalidRequest("answers must map each question id to an answer.")
        record, client = self._client()
        pending = self.pending(thread_id)
        request = next((item for item in pending.inputs if item.request_id == request_id), None)
        if request is None:
            raise T3RequestNotPending("That question is no longer pending.")
        resolved = resolve_answers(request, answers)
        command = self._commands.user_input_respond(thread_id=thread_id, request_id=request_id, answers=resolved)
        self._dispatch_or_fail(record, client, command)
        if request.dismissible:
            # T3 sends an async ("message") answer to the agent as a new run.
            with self._lock:
                cached = self._threads.get(thread_id) or {}
            if not run_live(cached):
                self._note_turn_requested(thread_id, latest_run_id(cached))
        self._invalidate(thread_id)
        self._wake()
        return {"ok": True, "threadId": thread_id, "requestId": request_id, "answers": resolved}

    def interrupt(self, thread_id: str) -> dict[str, object]:
        record, client = self._client()
        thread = self._known_thread(thread_id)
        running = run_live(thread)
        background = holds_completion(thread) or bool(thread.get("pendingBackgroundTasks"))
        if not running and not background:
            return {"ok": True, "threadId": str(thread["id"]), "wasWorking": False}
        if self._capability("threadStop"):
            command = self._commands.stop(thread_id=str(thread["id"]))
        else:
            run_id = thread.get("activeRunId") or latest_run_id(thread)
            if not run_id:
                return {"ok": True, "threadId": str(thread["id"]), "wasWorking": False}
            command = self._commands.interrupt(thread_id=str(thread["id"]), run_id=str(run_id))
        self._dispatch_or_fail(record, client, command)
        self._invalidate(str(thread["id"]))
        self._wake()
        return {"ok": True, "threadId": str(thread["id"]), "wasWorking": True}

    def archive(self, thread_id: str) -> dict[str, object]:
        """Archive one thread (used for cleanup of test threads; not exposed to voice)."""
        record, client = self._client()
        self._dispatch_or_fail(record, client, self._commands.archive(thread_id=thread_id))
        self._wake()
        return {"ok": True, "threadId": thread_id}

    def _dispatch_or_fail(self, record: T3ConnectionRecord, client: T3HttpClient, command: dict[str, object]) -> None:
        try:
            self._write(record, lambda: client.dispatch(command))
        except T3ReauthRequired:
            raise
        except T3Error as error:
            raise T3DispatchFailed(f"T3 Code did not accept the command ({type(error).__name__}).") from None

    def mark_seen(self, thread_id: str) -> dict[str, object]:
        with self._lock:
            self._load()
            if self._record is None:
                raise T3NotConnected("T3 Code is not connected.")
            thread = self._threads.get(thread_id)
        marker = seen_marker(thread) if thread is not None else ""
        marker = marker or _iso(self._clock())
        self._repository.mark_seen({thread_id: marker})
        with self._lock:
            self._seen[thread_id] = marker
            self._recompute()
        return {"ok": True}


def resolve_answers(request: PendingInput, answers: dict[str, object]) -> dict[str, object]:
    """Map spoken/tapped answers onto option labels; free text only when allowed."""
    resolved: dict[str, object] = {}
    message_mode = request.dismissible
    for question in request.questions:
        raw = answers.get(question.question_id)
        if raw is None and len(request.questions) == 1 and len(answers) == 1:
            raw = next(iter(answers.values()))
        if raw is None:
            raise T3InvalidRequest(f"Answer the question “{condense(question.question, 80)}”.")
        values = raw if isinstance(raw, list) else [raw]
        picked = [_pick_option(question, str(value)) for value in values if str(value).strip()]
        if not picked:
            raise T3InvalidRequest(f"Answer the question “{condense(question.question, 80)}”.")
        if question.multi_select and not message_mode:
            resolved[question.question_id] = picked
        else:
            resolved[question.question_id] = ", ".join(picked) if len(picked) > 1 else picked[0]
    return resolved


def _pick_option(question: PendingQuestion, value: str) -> str:
    """The value T3 expects for one answer: ``option.value ?? option.label``, or free text."""
    text = " ".join(value.split())
    options = list(question.options)
    lowered = text.lower().strip(" .!")
    for index, option in enumerate(options):
        if option.lower() == lowered or question.answer_value(index).lower() == lowered:
            return question.answer_value(index)
    # "2" means the second option, unless the options are themselves numbers.
    numeric_labels = any(option.strip().isdigit() for option in options)
    if lowered.isdigit() and not numeric_labels and 1 <= int(lowered) <= len(options):
        return question.answer_value(int(lowered) - 1)
    ordinals = {"first": 0, "second": 1, "third": 2, "fourth": 3, "fifth": 4}
    for word, index in ordinals.items():
        if lowered in {word, f"the {word}", f"{word} one", f"the {word} one", f"{word} option", f"the {word} option"} and index < len(options):
            return question.answer_value(index)
    # A shortened label ("sqlite" for "Use SQLite") picks that option.
    shortened = [index for index, option in enumerate(options) if lowered and lowered in option.lower()]
    if len(shortened) == 1:
        return question.answer_value(shortened[0])
    # An answer that merely contains a label ("yes, but skip the tests") is the
    # user's own words: send it whole when free text is allowed.
    if question.allow_custom:
        return text
    containing = [index for index, option in enumerate(options) if option.lower() in lowered]
    if len(containing) == 1:
        return question.answer_value(containing[0])
    choices = "; ".join(options)
    raise T3InvalidRequest(f"Choose one of: {choices}.")


_STEP_TYPES = {
    "command_execution": "Ran a command",
    "file_change": "Edited a file",
    "file_search": "Searched files",
    "web_search": "Searched the web",
    "dynamic_tool": "Used a tool",
    "subagent": "Subagent",
}


def _activity_items(items: list[dict[str, object]]) -> list[dict[str, object]]:
    """The four most recent tool steps of the run (v2 turn items) as live-card rows."""
    rows = []
    for item in items:
        kind = str(item.get("type") or "")
        if kind not in _STEP_TYPES:
            continue
        raw_status = str(item.get("status") or "")
        if raw_status == "completed":
            status = "ok"
        elif raw_status in {"failed", "cancelled", "interrupted"}:
            status = "error"
        else:
            status = "active"
        if status == "ok" and kind == "command_execution" and (
            item.get("exitCode") not in {None, 0} or item.get("outputIndicatesFailure") is True
        ):
            status = "error"
        detail = {
            "command_execution": item.get("input"),
            "file_change": item.get("fileName"),
            "file_search": item.get("pattern"),
            "dynamic_tool": item.get("toolName"),
            "subagent": item.get("progress"),
        }.get(kind)
        if kind == "web_search" and isinstance(item.get("patterns"), list) and item["patterns"]:
            detail = item["patterns"][0]
        title = condense(str(item.get("title") or _STEP_TYPES[kind]), 48)
        detail_text = str(detail) if isinstance(detail, str) else ""
        if detail_text.lower() == title.lower():
            detail_text = ""
        rows.append({"title": title, "detail": condense(detail_text, 64) or None, "status": status, "trailing": None})
    return rows[-4:]


def _sealed(token: str, environment_id: str | None) -> str:
    return json.dumps({"token": token, "environmentId": environment_id}, separators=(",", ":"))


def _capabilities(descriptor: dict[str, object]) -> dict[str, object]:
    value = descriptor.get("capabilities")
    return dict(value) if isinstance(value, dict) else {}
