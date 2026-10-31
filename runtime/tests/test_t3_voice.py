from __future__ import annotations

from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import patch

from sam_runtime.api.events import RuntimeEventStream
from sam_runtime.domains.t3.voice import T3_VOICE_INSTRUCTION, T3VoiceContext
from sam_runtime.providers.controller import ProviderController
from sam_runtime.providers.openai import ProviderModels
from sam_runtime.realtime.modes import PRIMARY_VOICE_INSTRUCTION, VoiceModeService
from sam_runtime.security.credentials import ProviderCredentials
from sam_runtime.storage.database import RuntimeDatabase
from sam_runtime.storage.migrations import LATEST_VERSION, MIGRATIONS
from sam_runtime.storage.provider_settings import ProviderSettingsRepository
from sam_runtime.storage.sessions import SessionTranscriptRepository

from t3_fixtures import PAIRING_CODE, FakeT3Server, make_service, thread


class _Bridge:
    def __init__(self) -> None:
        self.value: str | None = None

    def hasOpenAiPlatformKey(self) -> bool: return self.value is not None
    def getOpenAiPlatformKey(self) -> str | None: return self.value
    def putOpenAiPlatformKey(self, value: str) -> None: self.value = value
    def deleteOpenAiPlatformKey(self) -> None: self.value = None
    def hasOpenAiSubscriptionTokens(self) -> bool: return False
    def getOpenAiSubscriptionTokens(self) -> str | None: return None
    def putOpenAiSubscriptionTokens(self, value: str) -> None: return None
    def deleteOpenAiSubscriptionTokens(self) -> None: return None


class _OpenAI:
    instructions_extra = ""

    def __init__(self, key: str, *, safety_source: str) -> None:
        self.key = key

    def list_models(self) -> ProviderModels:
        return ProviderModels(("gpt-5.4",), ("gpt-realtime-2.1",))

    def create_realtime_call(self, *, offer_sdp: str, model: str, instructions_extra: str = "", **_: object) -> str:
        _OpenAI.instructions_extra = instructions_extra
        return "v=0\r\nanswer"


class T3VoiceInstructionTest(unittest.TestCase):
    def test_primary_instruction_lists_t3_as_a_direct_domain(self) -> None:
        self.assertIn("Web Search, T3 Code, or installed Agent Skill requests", PRIMARY_VOICE_INSTRUCTION)
        self.assertIn("[T3 update]", T3_VOICE_INSTRUCTION)
        self.assertIn("never invent ids", T3_VOICE_INSTRUCTION)

    def test_live_context_lists_threads_that_need_the_user_with_ids(self) -> None:
        with FakeT3Server() as fake:
            service, _, _, _, directory = make_service()
            try:
                context = T3VoiceContext(service)
                self.assertEqual("", context.render())
                threads = [thread(f"busy-{index}", f"Busy {index}", status="running") for index in range(7)]
                threads += [thread("ask", "Approve deploy", request="command"), thread("done", "Finished one")]
                fake.set_threads(threads)
                service.connect(fake.url, PAIRING_CODE)
                text = context.render()
                self.assertTrue(text.startswith(T3_VOICE_INSTRUCTION))
                self.assertIn("1 need the user, 7 working, 0 failed, 1 done.", text)
                self.assertIn("“Approve deploy” (Workbench): needs approval; id ask", text)
                self.assertIn("- and 2 more", text)
                self.assertNotIn("Finished one", text)
            finally:
                directory.cleanup()

    @patch("sam_runtime.providers.controller.OpenAIPlatform", _OpenAI)
    def test_controller_appends_context_and_it_survives_mode_switch(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            database = RuntimeDatabase(Path(directory) / "runtime.sqlite3")
            database.migrate()
            modes = VoiceModeService()
            controller = ProviderController(
                credentials=ProviderCredentials(_Bridge()),
                settings=ProviderSettingsRepository(database),
                events=RuntimeEventStream(),
                safety_source="local-install",
                voice_tools=lambda: (),
                goal_intake_tools=lambda: (),
                voice_modes=modes,
                sessions=SessionTranscriptRepository(database),
                t3_voice_context=lambda: "T3 CONTEXT MARKER",
            )
            controller.connect_platform("sk-test-value-long-enough")
            call = controller.create_realtime_call("v=0\r\noffer")
            self.assertIn("T3 CONTEXT MARKER", _OpenAI.instructions_extra)
            modes.switch(call.session_id, "goal_intake")
            restored = modes.switch(call.session_id, "primary")
            self.assertIn("T3 CONTEXT MARKER", restored.provider_session_update["session"]["instructions"])

            broken = ProviderController(
                credentials=ProviderCredentials(_Bridge()),
                settings=ProviderSettingsRepository(database),
                events=RuntimeEventStream(),
                safety_source="local-install",
                t3_voice_context=lambda: (_ for _ in ()).throw(RuntimeError("boom")),
            )
            broken.connect_platform("sk-test-value-long-enough")
            self.assertEqual("v=0\r\nanswer", broken.create_realtime_call("v=0\r\noffer").sdp)


class T3MigrationTest(unittest.TestCase):
    def test_migration_43_widens_kinds_and_keeps_existing_rows(self) -> None:
        self.assertGreaterEqual(LATEST_VERSION, 43)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "runtime.sqlite3"
            connection = sqlite3.connect(path)
            connection.row_factory = sqlite3.Row
            connection.execute("PRAGMA foreign_keys = ON")
            connection.execute("CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL)")
            for migration in [m for m in MIGRATIONS if m.version < 43]:
                migration.apply(connection)
                connection.execute("INSERT INTO schema_migrations VALUES (?, 'x')", (migration.version,))
            connection.commit()
            connection.execute(
                "INSERT INTO connections VALUES ('11111111-1111-4111-8111-111111111111', 'calendar', 'Cal', 1, 'ready', NULL, NULL, 'a', 'a')"
            )
            connection.commit()
            with self.assertRaises(sqlite3.IntegrityError):
                connection.execute("INSERT INTO connections VALUES ('x', 't3', 'T3', 1, 'ready', NULL, NULL, 'a', 'a')")
            connection.rollback()
            connection.close()

            database = RuntimeDatabase(path)
            database.migrate()
            self.assertEqual({"status": "ready", "migrationVersion": LATEST_VERSION}, database.health())
            with database.connect() as db:
                db.execute("INSERT INTO connections VALUES ('t3-row', 't3', 'T3', 1, 'ready', NULL, NULL, 'a', 'a')")
                db.execute("INSERT INTO connections VALUES ('hb-row', 'heptabase', 'HB', 1, 'ready', NULL, NULL, 'a', 'a')")
                kinds = [row[0] for row in db.execute("SELECT kind FROM connections ORDER BY kind")]
                tables = {row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
                indexes = {row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type='index'")}
                self.assertEqual([], db.execute("PRAGMA foreign_key_check").fetchall())
            self.assertEqual(["calendar", "heptabase", "t3"], kinds)
            self.assertTrue({"t3_connections", "t3_thread_seen", "announcements"} <= tables)
            self.assertIn("connections_kind_idx", indexes)


if __name__ == "__main__":
    unittest.main()
