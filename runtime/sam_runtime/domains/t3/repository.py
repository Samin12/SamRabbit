"""Persistence for the single T3 Code connection and per-thread seen markers.

The bearer token is sealed by ``ConnectionCredentialEnvelopes`` (Keystore on
the device) and stored only as an envelope; plaintext never reaches SQLite.
The envelope also carries the T3 ``environmentId`` the token belongs to
(``{"token", "environmentId"}``), so the token and the only server it may be
sent to are kept together; records paired before that have no id until the
first successful contact backfills it (no schema change).
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime

from sam_runtime.storage.database import RuntimeDatabase


CONNECTION_KIND = "t3"
_HEALTH_TO_CONNECTION = {"ready": "ready", "failed": "failed", "reauth": "failed"}


@dataclass(frozen=True, slots=True)
class T3ConnectionRecord:
    connection_id: str
    server_url: str
    environment_label: str | None
    scopes: str
    expires_at: str | None
    health_state: str
    health_detail: str | None
    last_sync_at: str | None
    baseline_pending: bool
    created_at: str
    updated_at: str


def _now() -> str:
    return datetime.now(UTC).isoformat(timespec="milliseconds").replace("+00:00", "Z")


class T3Repository:
    def __init__(self, database: RuntimeDatabase) -> None:
        self._database = database

    def get(self) -> T3ConnectionRecord | None:
        with self._database.connect() as connection:
            row = connection.execute(
                "SELECT connection_id, server_url, environment_label, scopes, expires_at, health_state, "
                "health_detail, last_sync_at, baseline_pending, created_at, updated_at "
                "FROM t3_connections ORDER BY created_at DESC LIMIT 1"
            ).fetchone()
        if row is None:
            return None
        return T3ConnectionRecord(
            connection_id=str(row[0]),
            server_url=str(row[1]),
            environment_label=str(row[2]) if row[2] is not None else None,
            scopes=str(row[3] or ""),
            expires_at=str(row[4]) if row[4] is not None else None,
            health_state=str(row[5]),
            health_detail=str(row[6]) if row[6] is not None else None,
            last_sync_at=str(row[7]) if row[7] is not None else None,
            baseline_pending=bool(row[8]),
            created_at=str(row[9]),
            updated_at=str(row[10]),
        )

    def envelope(self, connection_id: str) -> str | None:
        with self._database.connect() as connection:
            row = connection.execute(
                "SELECT envelope FROM connection_credential_envelopes WHERE connection_id = ?",
                (connection_id,),
            ).fetchone()
        return str(row[0]) if row is not None else None

    def replace(
        self,
        *,
        connection_id: str,
        server_url: str,
        environment_label: str | None,
        scopes: str,
        expires_at: str | None,
        envelope: str,
    ) -> T3ConnectionRecord:
        """Atomically drop any previous T3 connection and store the new one."""
        now = _now()
        label = "T3 Code" + (f" · {environment_label}" if environment_label else "")
        with self._database.connect() as connection:
            previous = [str(row[0]) for row in connection.execute(
                "SELECT connection_id FROM connections WHERE kind = ?", (CONNECTION_KIND,)
            ).fetchall()]
            for old_id in previous:
                connection.execute("DELETE FROM connection_credential_envelopes WHERE connection_id = ?", (old_id,))
                connection.execute("DELETE FROM connections WHERE connection_id = ?", (old_id,))
            connection.execute("DELETE FROM t3_connections")
            connection.execute("DELETE FROM t3_thread_seen")
            connection.execute(
                "INSERT INTO connections(connection_id, kind, label, enabled, health_state, health_detail, "
                "source_owner, created_at, updated_at) VALUES (?, ?, ?, 1, 'ready', NULL, 't3', ?, ?)",
                (connection_id, CONNECTION_KIND, label[:120], now, now),
            )
            connection.execute(
                "INSERT INTO connection_credential_envelopes(connection_id, envelope, updated_at) VALUES (?, ?, ?)",
                (connection_id, envelope, now),
            )
            connection.execute(
                "INSERT INTO t3_connections(connection_id, server_url, environment_label, scopes, expires_at, "
                "health_state, health_detail, last_sync_at, baseline_pending, created_at, updated_at) "
                "VALUES (?, ?, ?, ?, ?, 'ready', NULL, NULL, 1, ?, ?)",
                (connection_id, server_url, environment_label, scopes, expires_at, now, now),
            )
            connection.commit()
        record = self.get()
        if record is None:
            raise RuntimeError("T3 connection was not persisted.")
        return record

    def remove(self) -> bool:
        with self._database.connect() as connection:
            ids = [str(row[0]) for row in connection.execute(
                "SELECT connection_id FROM connections WHERE kind = ?", (CONNECTION_KIND,)
            ).fetchall()]
            for connection_id in ids:
                connection.execute("DELETE FROM connection_credential_envelopes WHERE connection_id = ?", (connection_id,))
                connection.execute("DELETE FROM connections WHERE connection_id = ?", (connection_id,))
            connection.execute("DELETE FROM t3_connections")
            connection.execute("DELETE FROM t3_thread_seen")
            connection.commit()
        return bool(ids)

    def set_health(self, connection_id: str, state: str, detail: str | None) -> None:
        if state not in _HEALTH_TO_CONNECTION:
            raise ValueError("T3 health state is invalid.")
        now = _now()
        with self._database.connect() as connection:
            connection.execute(
                "UPDATE t3_connections SET health_state = ?, health_detail = ?, updated_at = ? WHERE connection_id = ?",
                (state, detail, now, connection_id),
            )
            connection.execute(
                "UPDATE connections SET health_state = ?, health_detail = ?, updated_at = ? WHERE connection_id = ?",
                (_HEALTH_TO_CONNECTION[state], detail, now, connection_id),
            )
            connection.commit()

    def set_envelope(self, connection_id: str, envelope: str) -> None:
        with self._database.connect() as connection:
            connection.execute(
                "UPDATE connection_credential_envelopes SET envelope = ?, updated_at = ? WHERE connection_id = ?",
                (envelope, _now(), connection_id),
            )
            connection.commit()

    def set_server_url(self, connection_id: str, server_url: str) -> T3ConnectionRecord | None:
        """Point the connection at the address T3 moved to (same environment, new port)."""
        with self._database.connect() as connection:
            connection.execute(
                "UPDATE t3_connections SET server_url = ?, updated_at = ? WHERE connection_id = ?",
                (server_url, _now(), connection_id),
            )
            connection.commit()
        return self.get()

    def mark_synced(self, connection_id: str, synced_at: str) -> None:
        with self._database.connect() as connection:
            connection.execute(
                "UPDATE t3_connections SET last_sync_at = ? WHERE connection_id = ?",
                (synced_at, connection_id),
            )
            connection.commit()

    # -- seen markers --------------------------------------------------------
    def seen_markers(self) -> dict[str, str]:
        with self._database.connect() as connection:
            rows = connection.execute("SELECT thread_id, seen_marker FROM t3_thread_seen").fetchall()
        return {str(row[0]): str(row[1]) for row in rows}

    def mark_seen(self, markers: dict[str, str]) -> None:
        if not markers:
            return
        now = _now()
        with self._database.connect() as connection:
            connection.executemany(
                "INSERT INTO t3_thread_seen(thread_id, seen_marker, seen_at) VALUES (?, ?, ?) "
                "ON CONFLICT(thread_id) DO UPDATE SET seen_marker = excluded.seen_marker, seen_at = excluded.seen_at",
                [(thread_id, marker, now) for thread_id, marker in markers.items()],
            )
            connection.commit()

    def finish_baseline(self, connection_id: str, markers: dict[str, str]) -> None:
        """Mark every thread known at pairing time as seen, once."""
        self.mark_seen(markers)
        with self._database.connect() as connection:
            connection.execute(
                "UPDATE t3_connections SET baseline_pending = 0 WHERE connection_id = ?",
                (connection_id,),
            )
            connection.commit()
