"""A JSON value kept under one ``provider_settings`` key (state that needs no migration of its own).

Used for small durable lists and caches (the voice-note outbox, the cached morning briefing), the same way
``genui.pending`` is stored. Reads and writes never raise on a database error: they report it instead.
"""

from __future__ import annotations

from datetime import UTC, datetime
import json
import sqlite3

from .database import RuntimeDatabase


class JsonSetting:
    def __init__(self, database: RuntimeDatabase, key: str) -> None:
        self._database = database
        self.key = key

    def load(self) -> object | None:
        """The stored value, or None when it is missing, unreadable or the database failed."""
        try:
            with self._database.connect() as connection:
                row = connection.execute("SELECT setting_value FROM provider_settings WHERE setting_key = ?",
                                         (self.key,)).fetchone()
        except sqlite3.Error:
            return None
        if not row or not row[0]:
            return None
        try:
            return json.loads(row[0])
        except (TypeError, ValueError):
            return None

    def save(self, value: object) -> bool:
        stamp = datetime.now(UTC).isoformat(timespec="seconds").replace("+00:00", "Z")
        text = json.dumps(value, separators=(",", ":"), ensure_ascii=False)
        try:
            with self._database.connect() as connection:
                connection.execute(
                    "INSERT INTO provider_settings(setting_key, setting_value, updated_at) VALUES (?, ?, ?) "
                    "ON CONFLICT(setting_key) DO UPDATE SET setting_value = excluded.setting_value, "
                    "updated_at = excluded.updated_at",
                    (self.key, text, stamp),
                )
                connection.commit()
        except sqlite3.Error:
            return False
        return True
