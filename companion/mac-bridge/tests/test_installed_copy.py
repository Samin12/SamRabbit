"""Only the installed copy of the bridge reaches the real T3 Code, Google Calendar and Heptabase journal.

The decision (``samrabbit_installed``) uses the account's own home from the password database, never ``$HOME``, plus
the ``.samrabbit-installed`` marker install.sh writes. These tests point HOME at a temp folder (and install a copy
there with install.sh, then run that copy) and check that every such copy is a dev copy: a dry-run Heptabase CLI,
``t3_dev_copy`` and ``calendar_dev_copy``.

Nothing here can reach a real service even if the decision were wrong: PATH holds only recording fakes (``heptabase``,
``composio``) and system folders without them, the Heptabase and Composio fallbacks point at missing files, and the
T3 Code app CLI and the default T3 address are replaced by a recording fake CLI and a fake T3 server (in a bridge run
as a separate process too, through a small launcher). Every test checks that none of the fakes ran.

Run: cd companion/mac-bridge && /usr/bin/python3 -m unittest tests.test_installed_copy -q
"""

from __future__ import annotations

import io
import json
import os
from pathlib import Path
import pwd
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from contextlib import redirect_stdout
from typing import Any, Dict, List, Optional, Tuple
from urllib.error import HTTPError
from urllib.request import Request, urlopen

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(HERE))

import samrabbit_bridge as bridge  # noqa: E402
import samrabbit_calendar as gcal  # noqa: E402
import samrabbit_installed as installed  # noqa: E402
import samrabbit_t3 as t3  # noqa: E402
from fake_t3 import FakeT3  # noqa: E402

TOKEN = "test-token-" + "i" * 32
DESKTOP = "desktop-token-" + "j" * 32
NOTE = "a note that must stay in the dry run"
ISOLATED = ("SAMRABBIT_T3_URL", "SAMRABBIT_T3_CLI", "SAMRABBIT_HEPTABASE_CLI", "SAMRABBIT_T3_TOKEN_FILE",
            "SAMRABBIT_MOBILE_DEVICES_FILE", "SAMRABBIT_DESKTOP_TOKEN_FILE", "SAMRABBIT_SYNC_DIR",
            "SAMRABBIT_BRIDGE_TOKEN_FILE", "SAMRABBIT_TRANSCRIBE_HELPER", "SAMRABBIT_GOOGLE_ACCOUNT",
            "SAMRABBIT_CLAUDE", "SAMRABBIT_ASSISTANT_DIR", "SAMRABBIT_ASSISTANT_MODEL", "SAMRABBIT_ASSISTANT_VOICE",
            "SAMRABBIT_ELEVENLABS_KEY_FILE", "SAMRABBIT_ELEVENLABS_URL", "T3CODE_HOME")

# Runs a copy of the bridge (or its T3 command line) from <folder> as its own process, with the T3 app CLI, the
# default T3 address and the Heptabase / Composio fallbacks replaced by fakes before anything starts.
LAUNCHER = r"""
import sys
folder, t3_url, t3_cli, missing, command = sys.argv[1:6]
sys.path.insert(0, folder)
import samrabbit_t3, samrabbit_calendar, samrabbit_bridge, samrabbit_installed
for module in (samrabbit_t3, samrabbit_calendar, samrabbit_bridge, samrabbit_installed):
    assert module.__file__.startswith(folder), module.__file__
samrabbit_t3.DEFAULT_SERVER_URL = t3_url
samrabbit_t3.T3_EXECUTABLE = samrabbit_t3.T3_ASAR = t3_cli
samrabbit_bridge.FALLBACK_CLI = missing
samrabbit_calendar.FALLBACK_COMPOSIO = (missing,)
main = samrabbit_bridge.main if command == "bridge" else samrabbit_t3.main
sys.exit(main(sys.argv[6:]))
"""


def write_marker(folder: Path, named: Optional[str] = None) -> Path:
    marker = folder / installed.MARKER_NAME
    marker.write_text((str(folder) if named is None else named) + "\n")
    return marker


# --------------------------------------------------------------------------- the decision itself


class DecisionTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name, "account").resolve()
        self.folder = Path(installed.installed_dir(str(self.home)))
        self.folder.mkdir(parents=True)
        self.env = {"HOME": str(self.home)}

    def reason(self, folder: Optional[Path] = None, **kwargs: Any) -> Optional[str]:
        options = {"home": str(self.home), "environ": self.env, **kwargs}
        return installed.dev_reason(str(folder or self.folder), **options)

    def test_the_account_home_comes_from_the_password_database(self) -> None:
        self.assertEqual(pwd.getpwuid(os.getuid()).pw_dir, installed.account_home())
        self.assertEqual(os.path.join(pwd.getpwuid(os.getuid()).pw_dir, "Library", "Application Support",
                                      "SamRabbit", "bridge"), installed.installed_dir())

    def test_the_marked_install_folder_of_the_account_home_is_the_installed_copy(self) -> None:
        self.assertEqual(installed.REASON_NO_MARKER, self.reason(), "the folder alone is not enough")
        write_marker(self.folder)
        self.assertIsNone(self.reason())
        self.assertTrue(installed.is_installed_copy(str(self.folder), home=str(self.home), environ=self.env))
        self.assertIsNone(self.reason(environ={}), "a LaunchAgent without HOME is fine")
        self.assertEqual(bridge.CLI_AUTO, bridge.default_cli_choice(str(self.folder), home=str(self.home),
                                                                    environ=self.env))

    def test_everything_else_is_a_dev_copy(self) -> None:
        marker = write_marker(self.folder)
        other = Path(self.tmp.name, "somewhere-else")
        shutil.copytree(self.folder, other)  # a copy of the installed folder, marker and all
        self.assertTrue((other / installed.MARKER_NAME).exists())
        self.assertEqual(installed.REASON_ELSEWHERE, self.reason(other))
        self.assertEqual(installed.REASON_ELSEWHERE, self.reason(ROOT), "a checkout")
        self.assertEqual(installed.REASON_HOME, self.reason(environ={"HOME": self.tmp.name}), "a temp HOME")
        self.assertEqual(installed.REASON_NO_ACCOUNT, installed.dev_reason(str(self.folder), home=""))
        for content in (str(other), "", "relative/path", "\x00\xff"):
            with self.subTest(marker=content):
                marker.write_text(content + "\n")
                self.assertIn(self.reason(), (installed.REASON_MISMATCH, installed.REASON_NO_MARKER))
                self.assertFalse(installed.is_installed_copy(str(self.folder), home=str(self.home),
                                                             environ=self.env))
        marker.unlink()
        real = write_marker(Path(self.tmp.name))  # a good-looking marker elsewhere, linked in
        real.rename(Path(self.tmp.name, "marker-target"))
        Path(self.tmp.name, "marker-target").write_text(str(self.folder) + "\n")
        marker.symlink_to(Path(self.tmp.name, "marker-target"))
        self.assertEqual(installed.REASON_NO_MARKER, self.reason(), "a marker that is a link is never followed")
        marker.unlink()
        marker.mkdir()
        self.assertEqual(installed.REASON_NO_MARKER, self.reason(), "a folder is not a marker")
        marker.rmdir()
        marker.write_text(str(self.folder) + "\n" + "x" * installed.MAX_MARKER_BYTES)
        self.assertEqual(installed.REASON_NO_MARKER, self.reason(), "an oversized marker")

    def test_a_temp_home_never_makes_an_installed_copy(self) -> None:
        """What install.sh does with HOME (or SAMRABBIT_HOME) pointing at a temp folder: still a dev copy."""
        old = os.environ.get("HOME")
        os.environ["HOME"] = str(self.home)
        self.addCleanup(_restore, "HOME", old)
        write_marker(self.folder)
        # The old $HOME-based check would have taken this folder for the installed copy:
        self.assertEqual(os.path.realpath(os.path.expanduser("~/Library/Application Support/SamRabbit/bridge")),
                         os.path.realpath(self.folder))
        self.assertFalse(installed.is_installed_copy(str(self.folder)))
        self.assertEqual(installed.REASON_ELSEWHERE, installed.dev_reason(str(self.folder)))
        self.assertEqual(bridge.CLI_DRY_RUN, bridge.default_cli_choice(str(self.folder)))
        self.assertIsInstance(bridge.cli_for(None, here=str(self.folder)), bridge.DryRunHeptabaseCli)
        self.assertFalse(bridge.is_installed_copy(), "the checkout")
        self.assertEqual("dev (not_the_install_folder)", installed.describe(str(self.folder)))


def _restore(key: str, value: Optional[str]) -> None:
    if value is None:
        os.environ.pop(key, None)
    else:
        os.environ[key] = value


# --------------------------------------------------------------------------- bridges with a temp HOME


class FakesMixin:
    """Recording fakes for every real service, a hermetic PATH and HOME pointing at a temp folder."""

    tmp: tempfile.TemporaryDirectory
    root: Path

    def setup_fakes(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)  # type: ignore[attr-defined]
        self.root = Path(self.tmp.name).resolve()
        self.home = self.root / "home"
        self.home.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.calls = self.root / "calls.jsonl"  # every fake heptabase / composio run lands here
        for name in ("heptabase", "composio"):
            path = self.bin / name
            path.write_text(f'#!/bin/sh\necho "{name} $*" >> "{self.calls}"\necho "{{}}"\n')
            path.chmod(0o755)
        self.t3_dir = self.root / "t3"
        self.t3_dir.mkdir()
        self.fake_t3 = FakeT3(str(self.t3_dir))
        self.addCleanup(self.fake_t3.close)  # type: ignore[attr-defined]
        # The T3 app's CLI as the bridge runs it ("auto": <app executable> <server bundle> auth pairing create ...).
        self.t3_cli = self.bin / "t3-app"
        self.t3_cli.write_text(f'#!/bin/sh\nshift\nexec "{sys.executable}" "{HERE / "fake_t3_cli.py"}" '
                               f'--state "{self.t3_dir}" "$@"\n')
        self.t3_cli.chmod(0o755)
        self.t3_cli_path = self.bin / "t3"  # the same, given by path (--cli <path>: the arguments come first)
        self.t3_cli_path.write_text(f'#!/bin/sh\nexec "{sys.executable}" "{HERE / "fake_t3_cli.py"}" '
                                    f'--state "{self.t3_dir}" "$@"\n')
        self.t3_cli_path.chmod(0o755)
        self.missing = str(self.root / "missing")
        self.config = self.home / ".config" / "samrabbit"
        self.config.mkdir(parents=True)
        for name, value in (("bridge-token", TOKEN), ("desktop-token", DESKTOP)):
            (self.config / name).write_text(value + "\n")
            (self.config / name).chmod(0o600)
        self.env = {key: value for key, value in os.environ.items() if key not in ISOLATED}
        self.env.update({"HOME": str(self.home), "PATH": os.pathsep.join([str(self.bin), "/usr/bin", "/bin",
                                                                          "/usr/sbin", "/sbin"]),
                         # what install.sh records for the LaunchAgent: a dev copy must not use it
                         "SAMRABBIT_COMPOSIO": str(self.bin / "composio"),
                         "TMPDIR": str(self.root) + "/"})

    def fake_runs(self) -> Dict[str, Any]:
        cli_calls = self.t3_dir / "cli-calls.jsonl"
        return {"heptabase/composio": self.calls.read_text().splitlines() if self.calls.exists() else [],
                "t3 cli": cli_calls.read_text().splitlines() if cli_calls.exists() else [],
                "t3 server": list(self.fake_t3.requests)}

    def assert_nothing_ran(self) -> None:
        self.assertEqual({"heptabase/composio": [], "t3 cli": [], "t3 server": []}, self.fake_runs())  # type: ignore

    def check_dev_copy(self, base: str) -> None:
        """The bridge at ``base`` is a dev copy: dry-run journal, t3_dev_copy, calendar_dev_copy."""
        status, health = _call(base, "GET", "/health", token=TOKEN)
        self.assertEqual(200, status, health)  # type: ignore[attr-defined]
        self.assertEqual(("dev", True, "dryRun"), (health["copy"], health["dryRun"], health["cli"]["mode"]))  # type: ignore
        self.assertEqual({"reachable": False, "detail": "bridge_dry_run"}, health["app"])  # type: ignore
        self.assertEqual((False, "calendar_dev_copy"), (health["calendarWrite"]["available"],  # type: ignore
                                                        health["calendarWrite"]["lastError"]))
        self.assertEqual({"paired": False, "ok": False, "reason": "t3_dev_copy"}, health["mobile"]["t3"])  # type: ignore
        # The watch assistant: no agent without an explicit claude (here a missing one), never the ElevenLabs key.
        self.assertFalse(health["assistant"]["available"])  # type: ignore
        self.assertEqual(("dev", "voice_dev_copy"), (health["assistant"]["copy"],  # type: ignore
                                                     health["assistant"]["voice"]["reason"]))
        # The R1's own routes: the journal stays in the dry run, the calendar is refused.
        status, written = _call(base, "POST", "/v1/heptabase/journal/append", {"date": "2026-10-08", "content": NOTE},
                                token=TOKEN)
        self.assertEqual((200, True), (status, written.get("dryRun")), written)  # type: ignore
        status, value = _call(base, "POST", "/v1/calendar/events", {"title": "Focus",
                                                                    "start": "2026-10-08T15:00:00-04:00",
                                                                    "end": "2026-10-08T15:30:00-04:00"}, token=TOKEN)
        self.assertEqual(503, status, value)  # type: ignore
        # A paired phone: T3 and the calendar answer *_dev_copy, the journal is a dry run.
        status, code = _call(base, "POST", "/v1/mobile/pairing/start", {}, headers={"X-SamRabbit-Desktop": DESKTOP})
        self.assertEqual(200, status, code)  # type: ignore
        status, paired = _call(base, "POST", "/v1/mobile/pair", {"code": code["code"], "platform": "ios"})
        self.assertEqual(200, status, paired)  # type: ignore
        phone = paired["token"]
        for method, path, body, expected in (
                ("GET", "/v1/mobile/t3/threads", None, "t3_dev_copy"),
                ("POST", "/v1/mobile/t3/threads", {"text": "make a thing"}, "t3_dev_copy"),
                ("GET", "/v1/mobile/calendar/agenda", None, "calendar_dev_copy"),
                ("POST", "/v1/mobile/calendar/block", {"minutes": 30}, "calendar_dev_copy")):
            with self.subTest(path=path, method=method):  # type: ignore[attr-defined]
                status, value = _call(base, method, path, body, token=phone)
                self.assertEqual((503, expected), (status, value["error"]["code"]), value)  # type: ignore
        status, value = _call(base, "POST", "/v1/mobile/journal", {"text": NOTE}, token=phone)
        self.assertEqual((200, True), (status, value.get("dryRun")), value)  # type: ignore
        status, summary = _call(base, "GET", "/v1/mobile/summary", token=phone)
        self.assertEqual(200, status, summary)  # type: ignore
        self.assertEqual(("t3_dev_copy", False), (summary["t3"]["reason"], summary["t3"]["available"]))  # type: ignore
        self.assertEqual({"available": True, "dryRun": True}, summary["journal"])  # type: ignore
        self.assertFalse(summary["calendar"]["available"])  # type: ignore
        self.assertEqual({"available": False, "reason": "helper_missing"}, summary["transcribe"])  # type: ignore
        self.assertFalse((self.config / "t3-token").exists(), "no T3 token was minted")  # type: ignore


def _call(base: str, method: str, path: str, body: Any = None, *, token: Optional[str] = None,
          headers: Optional[Dict[str, str]] = None) -> Tuple[int, Dict[str, Any]]:
    merged = {"Content-Type": "application/json", **(headers or {})}
    if token:
        merged["Authorization"] = "Bearer " + token
    data = json.dumps(body).encode() if body is not None else None
    try:
        with urlopen(Request(base + path, data=data, method=method, headers=merged), timeout=30) as response:
            return response.status, json.loads(response.read() or b"{}")
    except HTTPError as error:
        return error.code, json.loads(error.read() or b"{}")


class TempHomeInProcessTest(FakesMixin, unittest.TestCase):
    """The checkout's bridge and T3 command line, in this process, with HOME pointing at a temp folder."""

    def setUp(self) -> None:
        self.setup_fakes()
        saved = {key: os.environ.get(key) for key in set(self.env) | set(ISOLATED)}
        for key in ISOLATED:
            os.environ.pop(key, None)
        os.environ.update(self.env)
        for key, value in saved.items():
            self.addCleanup(_restore, key, value)
        for module, name, value in ((t3, "DEFAULT_SERVER_URL", self.fake_t3.url), (t3, "T3_EXECUTABLE", str(self.t3_cli)),
                                    (t3, "T3_ASAR", str(self.t3_cli)), (bridge, "FALLBACK_CLI", self.missing),
                                    (gcal, "FALLBACK_COMPOSIO", (self.missing,))):
            self.addCleanup(setattr, module, name, getattr(module, name))
            setattr(module, name, value)
        self.assertEqual(str(self.bin / "heptabase"), shutil.which("heptabase"), "only the fake is on PATH")

    def test_a_bridge_from_the_checkout_with_a_temp_home_is_a_dev_copy(self) -> None:
        server = bridge.make_server("127.0.0.1", 0, token_file=str(self.config / "bridge-token"),
                                    desktop_token_file=str(self.config / "desktop-token"),
                                    mobile_devices_file=str(self.config / "mobile-devices.json"),
                                    t3_token_file=str(self.config / "t3-token"), driver=self.missing,
                                    claude=self.missing, agent_browser=self.missing,
                                    artifacts_dir=str(self.root / "artifacts"),
                                    transcribe_helper=self.missing, mobile_hosts=["10.0.0.2"])
        thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        self.assertFalse(server.installed_copy)
        self.assertIsInstance(server.cli, bridge.DryRunHeptabaseCli)
        self.assertEqual("calendar_dev_copy", server.calendar.code)
        self.assertEqual("t3_dev_copy", server.mobile.t3.code)
        self.check_dev_copy(f"http://127.0.0.1:{server.server_address[1]}")
        self.assert_nothing_ran()

    def test_the_t3_command_line_never_pairs_a_dev_copy_with_the_default_server(self) -> None:
        token_file = self.config / "t3-token"
        for args in ([], ["--cli", str(self.t3_cli_path)], ["--cli", "auto"]):
            with self.subTest(args=args):
                out = io.StringIO()
                with redirect_stdout(out):
                    code = t3.main(["ensure-paired", "--token-file", str(token_file), *args])
                self.assertEqual(3, code)
                self.assertIn("T3 not paired: t3_dev_copy", out.getvalue())
        self.assert_nothing_ran()
        self.assertFalse(token_file.exists())
        # An explicit server is a deliberate choice, as with the bridge's --t3-url (here: the fakes).
        out = io.StringIO()
        with redirect_stdout(out):
            code = t3.main(["ensure-paired", "--token-file", str(token_file), "--url", self.fake_t3.url,
                            "--cli", str(self.t3_cli_path)])
        self.assertEqual((0, "T3 paired (expires 2026-11-07)"), (code, out.getvalue().strip()))
        self.assertEqual(1, len(self.fake_t3.exchanges))


class InstalledIntoTempHomeTest(FakesMixin, unittest.TestCase):
    """install.sh into a temp HOME, then that installed copy run as its own process with HOME=<temp>: a dev copy."""

    def setUp(self) -> None:
        if sys.platform != "darwin":
            self.skipTest("the installer targets macOS")
        self.setup_fakes()
        done = subprocess.run([str(ROOT / "install.sh")], capture_output=True, text=True, timeout=300,
                              env={**self.env, "SAMRABBIT_HOME": str(self.home), "SAMRABBIT_SKIP_LAUNCHCTL": "1",
                                   "SAMRABBIT_SKIP_T3_PAIR": "1", "SAMRABBIT_SKIP_TRANSCRIBE_BUILD": "1"})
        self.assertEqual(0, done.returncode, done.stdout + done.stderr)
        self.install_output = done.stdout + done.stderr
        self.app = self.home / "Library" / "Application Support" / "SamRabbit" / "bridge"

    def launch(self, command: str, *args: str) -> subprocess.Popen:
        return subprocess.Popen([sys.executable, "-I", "-c", LAUNCHER, str(self.app), self.fake_t3.url,
                                 str(self.t3_cli), self.missing, command, *args],
                                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                env=self.env, cwd=str(self.root), start_new_session=True)

    def test_the_marker_names_the_temp_folder_and_the_copy_is_still_a_dev_copy(self) -> None:
        self.assertEqual(str(self.app) + "\n", (self.app / installed.MARKER_NAME).read_text())
        self.assertIn("bridge copy: dev (not_the_install_folder)", self.install_output)
        self.assertTrue(installed.is_installed_copy(str(self.app), home=str(self.home), environ=self.env),
                        "it is exactly what the installed copy in the account's own home would have")
        self.assertFalse(installed.is_installed_copy(str(self.app)))

    def test_the_installed_copy_run_with_a_temp_home_is_a_dev_copy(self) -> None:
        process = self.launch("bridge", "--host", "127.0.0.1", "--port", "0",
                              "--token-file", str(self.config / "bridge-token"),
                              "--sync-dir", str(self.home / "Library/Application Support/SamRabbit/sync"),
                              "--desktop-token-file", str(self.config / "desktop-token"),
                              "--mobile-devices-file", str(self.config / "mobile-devices.json"),
                              "--t3-token-file", str(self.config / "t3-token"),
                              "--cua-driver", self.missing, "--claude", self.missing, "--agent-browser", self.missing,
                              "--artifacts-dir", str(self.root / "artifacts"))
        lines: List[str] = []
        reader = threading.Thread(target=lambda: lines.extend(iter(process.stderr.readline, b"")), daemon=True)
        reader.start()

        def stop() -> None:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
            process.stdout.close()
            reader.join(timeout=5)
            process.stderr.close()

        self.addCleanup(stop)
        deadline = time.monotonic() + 60
        match = None
        while match is None and time.monotonic() < deadline and process.poll() is None:
            text = b"".join(lines).decode("utf-8", "replace")
            match = re.search(r"listening on 127\.0\.0\.1:(\d+) \((\w+) copy", text)
            time.sleep(0.05)
        self.assertIsNotNone(match, b"".join(lines).decode("utf-8", "replace"))
        self.assertEqual("dev", match.group(2))
        self.check_dev_copy(f"http://127.0.0.1:{match.group(1)}")
        log = b"".join(lines).decode("utf-8", "replace")
        self.assertIn("heptabase CLI: dry-run", log)
        self.assertNotIn(NOTE, log)
        self.assert_nothing_ran()

    def test_the_installed_copys_t3_command_line_never_pairs_with_a_temp_home(self) -> None:
        for args in ([], ["--cli", str(self.t3_cli_path)]):
            with self.subTest(args=args):
                process = self.launch("t3", "ensure-paired", "--token-file", str(self.config / "t3-token"), *args)
                out, _err = process.communicate(timeout=60)
                self.assertEqual(3, process.returncode)
                self.assertIn("T3 not paired: t3_dev_copy", out.decode())
        self.assert_nothing_ran()
        self.assertFalse((self.config / "t3-token").exists())


if __name__ == "__main__":
    unittest.main()
