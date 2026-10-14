"""The Mac borrows Codex's ChatGPT login read-only when it has none of its own (samrabbit_chatgpt.CodexLoginAuth).

Everything here runs on files in a temp folder: never the real ~/.codex.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import stat
import sys
import tempfile
import unittest
from typing import Any, Dict, Optional
from unittest import mock

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(HERE))

import samrabbit_chatgpt as chatgpt  # noqa: E402
from fake_openai import jwt  # noqa: E402

NOW = 1_791_500_000.0


def codex_token(*, exp: float = NOW + 7 * 86400, client: str = chatgpt.CLIENT_ID,
                aud: Any = ("https://api.openai.com/v1",), account: str = "acct-1", tag: str = "a") -> str:
    return jwt({"exp": int(exp), "client_id": client, "aud": list(aud) if isinstance(aud, tuple) else aud,
                "tag": tag, "https://api.openai.com/auth": {"chatgpt_plan_type": "promax",
                                                            "chatgpt_account_id": account}})


class CodexLoginTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name, "codex", "auth.json")
        self.path.parent.mkdir()
        self.now = NOW
        self.auth = chatgpt.CodexLoginAuth(str(self.path), clock=lambda: self.now)

    def write(self, access: str, *, mode: Optional[str] = "chatgpt", extra: Optional[Dict[str, Any]] = None) -> None:
        value: Dict[str, Any] = {"auth_mode": mode, "OPENAI_API_KEY": None, "last_refresh": "2026-10-10T17:53:53Z",
                                 "tokens": {"access_token": access, "refresh_token": "codex-refresh-secret",
                                            "id_token": access, "account_id": "acct-1"}}
        value.update(extra or {})
        self.path.write_text(json.dumps(value))
        stamp = self.path.stat().st_mtime_ns
        os.utime(self.path, ns=(stamp + 1_000_000, stamp + 1_000_000))  # a new mtime even within one clock tick
        os.chmod(self.path, 0o600)

    def test_a_valid_codex_login_is_used_as_it_is(self) -> None:
        token = codex_token()
        self.write(token)
        self.assertTrue(self.auth.connected())
        self.assertEqual(self.auth.access_token(), token)
        self.assertEqual(self.auth.status(), {"connected": True, "source": "codex", "plan": "promax"})
        self.assertEqual(self.auth.safety_id(), "acct-1")
        self.assertAlmostEqual(self.auth.expires_in() or 0, 7 * 86400, delta=1)

    def test_the_file_is_only_ever_read(self) -> None:
        self.write(codex_token())
        before = self.path.read_bytes(), stat.S_IMODE(self.path.stat().st_mode), self.path.stat().st_mtime_ns
        modes = []
        real_open = open

        def spy(file: Any, mode: str = "r", *args: Any, **kwargs: Any) -> Any:
            if str(file) == str(self.path):
                modes.append(mode)
            return real_open(file, mode, *args, **kwargs)

        with mock.patch("builtins.open", spy), mock.patch.object(chatgpt, "_write_private") as write, \
                mock.patch.object(chatgpt.os, "chmod") as chmod:
            self.auth.access_token()
            self.auth.status()
        self.assertTrue(modes and all(mode == "r" for mode in modes), modes)
        write.assert_not_called()
        chmod.assert_not_called()
        self.assertEqual((self.path.read_bytes(), stat.S_IMODE(self.path.stat().st_mode),
                          self.path.stat().st_mtime_ns), before)

    def test_logins_that_cannot_be_used(self) -> None:
        cases = {
            "expired": codex_token(exp=NOW - 10),
            "about to expire": codex_token(exp=NOW + 60),
            "another client": codex_token(client="app_someone_else"),
            "another audience": codex_token(aud=("https://example.com",)),
            "not a token": "not-a-jwt",
        }
        for name, token in cases.items():
            with self.subTest(name):
                self.write(token)
                self.assertFalse(self.auth.connected())
                with self.assertRaises(chatgpt.ChatGPTError) as caught:
                    self.auth.access_token()
                self.assertEqual(caught.exception.code, "chatgpt_not_connected")
        with self.subTest("an API key login"):
            self.write(codex_token(), mode="apikey")
            self.assertFalse(self.auth.connected())
        with self.subTest("no file"):
            self.path.unlink()
            self.assertFalse(self.auth.connected())
            self.assertEqual(self.auth.status(), {"connected": False, "source": "codex"})
        with self.subTest("a huge file"):
            self.path.write_text(" " * (chatgpt.MAX_FILE_BYTES + 1))
            self.assertFalse(self.auth.connected())

    def test_a_refusal_never_refreshes_and_uses_what_codex_renewed(self) -> None:
        old = codex_token(tag="old")
        self.write(old)
        self.assertEqual(self.auth.access_token(), old)
        with mock.patch.object(chatgpt, "default_transport") as transport:
            self.assertEqual(self.auth.access_token(force_refresh=True), old)  # nothing renewed: the same token again
            renewed = codex_token(tag="new")
            self.write(renewed)  # Codex renewed between handing the token out and OpenAI's answer
            self.assertEqual(self.auth.access_token(force_refresh=True), renewed)
        transport.assert_not_called()
        self.assertTrue(self.auth.connected())

    def test_a_renewed_token_is_picked_up_at_once(self) -> None:
        self.write(codex_token(tag="one"))
        self.auth.access_token()
        renewed = codex_token(tag="two")
        self.write(renewed)
        self.assertEqual(self.auth.access_token(), renewed)


class PreferredAuthTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.codex = Path(self.tmp.name, "codex-auth.json")
        self.own_file = Path(self.tmp.name, "config", "chatgpt-auth.json")
        self.codex_token = codex_token()
        self.codex.write_text(json.dumps({"auth_mode": "chatgpt", "tokens": {"access_token": self.codex_token}}))
        self.auth = chatgpt.make_auth(installed=False, auth_file=str(self.own_file), codex_file=str(self.codex))
        self.addCleanup(self.auth.close)

    def store_own(self) -> str:
        own = jwt({"exp": 4_000_000_000, "https://api.openai.com/auth": {"chatgpt_plan_type": "pro",
                                                                         "chatgpt_account_id": "own"}})
        self.auth.own._store({"access_token": own, "refresh_token": "own-refresh", "expires_in": 3600})
        return own

    def test_codex_is_borrowed_until_the_mac_has_its_own_login(self) -> None:
        self.assertIsInstance(self.auth, chatgpt.PreferredAuth)
        self.assertTrue(self.auth.connected())
        status = self.auth.status()
        self.assertEqual((status["connected"], status["source"], status["plan"]), (True, "codex", "promax"))
        self.assertEqual(status["login"], {"state": "idle"})
        self.assertEqual(self.auth.access_token(), self.codex_token)
        own = self.store_own()
        self.assertEqual(self.auth.access_token(), own)
        self.assertEqual(self.auth.status()["source"], "samrabbit")
        self.assertEqual(self.auth.safety_id(), "own")

    def test_disconnect_drops_only_the_macs_own_login(self) -> None:
        changes = []
        self.auth.on_change = lambda: changes.append(1)
        self.assertEqual(self.auth.disconnect(), {"connected": True, "source": "codex"})
        self.assertEqual(changes, [])  # no login of its own: nothing changed, no session is retired
        self.store_own()
        self.assertEqual(self.auth.disconnect(), {"connected": True, "source": "codex"})  # Codex's is still there
        self.assertEqual(changes, [1])
        self.assertTrue(self.codex.exists())
        self.assertEqual(self.auth.access_token(), self.codex_token)

    def test_a_refusal_goes_back_to_the_login_that_gave_the_token(self) -> None:
        self.assertEqual(self.auth.access_token(), self.codex_token)
        own = self.store_own()  # the Mac's own login arrives while the borrowed token is in flight
        with mock.patch.object(self.auth.own, "access_token", wraps=self.auth.own.access_token) as own_token:
            self.assertEqual(self.auth.access_token(force_refresh=True), self.codex_token)
        own_token.assert_not_called()  # the own login is not refreshed for Codex's refused token
        self.assertEqual(self.auth.access_token(), own)

    def test_the_status_never_mixes_two_accounts(self) -> None:
        stale = jwt({"exp": 4_000_000_000, "email": "old-own@example.com",
                     "https://api.openai.com/auth": {"chatgpt_plan_type": "plus"}})
        record = self.auth.own._store({"access_token": stale, "refresh_token": "r", "expires_in": 3600})
        self.auth.own._mark_refused(record)  # the Mac's own login needs a reconnect
        status = self.auth.status()
        self.assertEqual(status, {"connected": True, "source": "codex", "login": {"state": "idle"}, "plan": "promax"})

    def test_the_borrowed_login_is_never_refreshed(self) -> None:
        with mock.patch.object(self.auth.own, "refresh_if_needed") as own_refresh, \
                mock.patch.object(chatgpt, "default_transport") as transport:
            self.auth.refresh_if_needed()
        own_refresh.assert_called_once()
        transport.assert_not_called()

    def test_on_change_is_the_macs_own(self) -> None:
        called = []
        self.auth.on_change = lambda: called.append(1)
        self.assertIs(self.auth.own.on_change, self.auth.on_change)

    def test_which_copies_borrow(self) -> None:
        with mock.patch.dict(os.environ, {"CODEX_HOME": self.tmp.name, "SAMRABBIT_CODEX_LOGIN": "1"}):
            installed = chatgpt.make_auth(installed=True)
            self.assertIsInstance(installed, chatgpt.PreferredAuth)
            self.assertEqual(installed.borrowed.path, os.path.join(self.tmp.name, "auth.json"))
            self.assertIsInstance(chatgpt.make_auth(installed=False), chatgpt.UnavailableAuth)  # a checkout: never
            self.assertIsInstance(chatgpt.make_auth(installed=False, auth_file=str(self.own_file)),
                                  chatgpt.ChatGPTAuth)  # tests: only with an explicit codex_file
        for off in ("0", "OFF", "False", " no "):
            with mock.patch.dict(os.environ, {"CODEX_HOME": self.tmp.name, "SAMRABBIT_CODEX_LOGIN": off}):
                self.assertIsInstance(chatgpt.make_auth(installed=True), chatgpt.ChatGPTAuth)

    def test_tokens_never_reach_the_log(self) -> None:
        import io
        import logging

        log = io.StringIO()
        handler = logging.StreamHandler(log)
        chatgpt._LOG.addHandler(handler)  # noqa: SLF001
        self.addCleanup(chatgpt._LOG.removeHandler, handler)  # noqa: SLF001
        self.auth.access_token()
        self.auth.status()
        with self.assertRaises(chatgpt.ChatGPTError):
            chatgpt.CodexLoginAuth(str(self.codex), clock=lambda: 4_100_000_000).access_token()
        self.assertNotIn(self.codex_token, log.getvalue())


class BorrowedRefusalTest(unittest.TestCase):
    """OpenAI refusing the borrowed token: one retry with whatever the file holds, then the realtime brain's usual
    pause with the refusal recorded (never a refresh, never 'not connected' for days)."""

    def test_a_refused_borrowed_token_pauses_the_brain_like_the_macs_own(self) -> None:
        import samrabbit_realtime as realtime

        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        codex = Path(tmp.name, "auth.json")
        token = codex_token()
        codex.write_text(json.dumps({"auth_mode": "chatgpt", "tokens": {"access_token": token}}))
        auth = chatgpt.make_auth(installed=False, auth_file=str(Path(tmp.name, "own.json")), codex_file=str(codex))
        brain = realtime.RealtimeBrain(auth, python=None, api_root="http://127.0.0.1:9")
        calls = []

        def refuse(api_root: str, sent: str, safety: str, offer: str, config: Dict[str, Any]) -> Any:
            calls.append(sent)
            return 403, "", {"code": "unsupported_country"}

        with mock.patch.object(realtime, "create_call", refuse), \
                mock.patch.object(chatgpt, "default_transport") as transport:
            with self.assertRaises(realtime.RealtimeError) as caught:
                brain.signal("v=0 offer", {})
        transport.assert_not_called()
        self.assertEqual(calls, [token, token])
        self.assertEqual((caught.exception.code, caught.exception.pause),
                         ("chatgpt_rejected", realtime.PAUSE_REJECTED_SECONDS))
        self.assertEqual(brain.last_error, "http_403_unsupported_country")
        self.assertTrue(auth.connected(), "the login itself is still there; only the brain pauses")


if __name__ == "__main__":
    unittest.main()
