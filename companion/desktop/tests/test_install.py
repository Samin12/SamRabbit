"""install.sh / uninstall.sh against a throwaway home and apps folder (launchctl, open and pkill skipped).

Run: python3 -m unittest discover -s companion/desktop/tests
"""

from __future__ import annotations

import os
from pathlib import Path
import plistlib
import stat
import subprocess
import sys
import tempfile
import unittest
from typing import Dict, Optional

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent


@unittest.skipUnless(sys.platform == "darwin", "the installer targets macOS")
class DesktopInstallTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name, "home")
        self.apps = Path(self.tmp.name, "Applications")
        self.home.mkdir()

    def run_script(self, name: str, *args: str, env: Optional[Dict[str, str]] = None) -> str:
        env = {**os.environ, "SAMRABBIT_HOME": str(self.home), "SAMRABBIT_SKIP_LAUNCHCTL": "1", **(env or {})}
        done = subprocess.run([str(ROOT / name), *args, "--apps-dir", str(self.apps)], env=env, capture_output=True,
                              text=True, timeout=240, check=True)
        return done.stdout + done.stderr

    def test_install_is_idempotent_private_and_never_prints_the_token(self) -> None:
        output = self.run_script("install.sh", "--no-open")
        token_file = self.home / ".config/samrabbit/desktop-token"
        token = token_file.read_text().strip()
        self.assertGreaterEqual(len(token), 40)
        self.assertEqual(0o600, stat.S_IMODE(token_file.stat().st_mode))
        self.assertEqual(0o700, stat.S_IMODE(token_file.parent.stat().st_mode))
        self.assertNotIn(token, output)

        app = self.apps / "SamRabbit.app"
        with (app / "Contents/Info.plist").open("rb") as handle:
            info = plistlib.load(handle)
        self.assertEqual("com.samrabbit.desktop", info["CFBundleIdentifier"])
        self.assertFalse(info["LSUIElement"], "SamRabbit has a Dock icon")
        self.assertTrue(os.access(app / "Contents/MacOS/SamRabbit", os.X_OK))
        self.assertTrue((app / "Contents/Resources/AppIcon.icns").stat().st_size > 10_000)
        web = app / "Contents/Resources/web"
        for name in ("index.html", "app.js", "styles.css", "orb.svg"):
            self.assertTrue((web / name).is_file(), name)
        self.assertFalse(any(path.name.startswith(".") for path in web.rglob("*")), "no dotfiles in the web folder")
        signed = subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], capture_output=True)
        self.assertEqual(0, signed.returncode, signed.stderr)

        plist_path = self.home / "Library/LaunchAgents/com.samrabbit.desktop.login.plist"
        with plist_path.open("rb") as handle:
            plist = plistlib.load(handle)
        self.assertEqual("com.samrabbit.desktop.login", plist["Label"])
        self.assertEqual(["/usr/bin/open", "-g", "-a", str(app), "--args", "--login"], plist["ProgramArguments"])
        self.assertTrue(plist["RunAtLoad"])
        self.assertFalse(plist["KeepAlive"])

        output = self.run_script("install.sh", "--no-open")
        self.assertIn("keeping the existing desktop token", output)
        self.assertEqual(token, token_file.read_text().strip())
        self.assertTrue(app.is_dir())

        self.run_script("install.sh", "--no-open", "--no-login-item")
        self.assertFalse(plist_path.exists())

        self.run_script("uninstall.sh")
        self.assertFalse(app.exists())
        self.assertTrue(token_file.exists(), "token kept without --purge")
        self.run_script("uninstall.sh", "--purge")
        self.assertFalse(token_file.exists())

    def test_the_bridge_check_never_sends_the_token_off_this_mac(self) -> None:
        # A listener on this Mac that records what reaches it (stands in for a LAN host).
        import http.server
        import threading

        seen = []

        class Recorder(http.server.BaseHTTPRequestHandler):
            def do_GET(self) -> None:  # noqa: N802
                seen.append({name.lower() for name in self.headers.keys()})  # names only, never values
                self.send_response(404)
                self.send_header("Content-Length", "0")
                self.end_headers()

            def log_message(self, *args: object) -> None:
                return

        server = http.server.HTTPServer(("127.0.0.1", 0), Recorder)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        port = server.server_address[1]

        # 1. A loopback override is used (and gets the token header).
        output = self.run_script("install.sh", "--no-open", "--no-login-item",
                                 env={"SAMRABBIT_APP_URL": f"http://127.0.0.1:{port}/app/"})
        self.assertIn("does not serve the desktop page yet", output)
        self.assertEqual(1, len(seen))
        self.assertIn("x-samrabbit-desktop", seen[0])
        # 2. A non-loopback override is ignored: nothing is sent there.
        output = self.run_script("install.sh", "--no-open", "--no-login-item",
                                 env={"SAMRABBIT_APP_URL": "http://192.0.2.10:3780/app/"})
        self.assertIn("ignoring the BaseURL override", output)
        token = (self.home / ".config/samrabbit/desktop-token").read_text().strip()
        self.assertNotIn(token, output)


@unittest.skipUnless(sys.platform == "darwin", "the build targets macOS")
class DesktopBuildTest(unittest.TestCase):
    """build.sh and its SamRabbitKit cache, into a throwaway folder (never the app's own build folder)."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.out = Path(self.tmp.name, "out")

    def test_an_identity_that_cannot_sign_falls_back_to_ad_hoc(self) -> None:
        # The keychain lists an Apple Development identity codesign can't use (a locked keychain, a denied key
        # prompt): stand in for `security` with one that lists an identity that doesn't exist.
        shims = Path(self.tmp.name, "bin")
        shims.mkdir()
        security = shims / "security"
        security.write_text('#!/bin/sh\necho \'  1) 0123456789ABCDEF0123456789ABCDEF01234567 '
                            '"Apple Development: Nobody (NOTEAM0000)"\'\necho "     1 valid identities found"\n')
        security.chmod(0o755)
        env = {**os.environ, "PATH": f"{shims}:{os.environ['PATH']}"}
        done = subprocess.run([str(ROOT / "build.sh"), "--out", str(self.out)], env=env, capture_output=True,
                              text=True, timeout=600)
        self.assertEqual(0, done.returncode, done.stdout + done.stderr)
        self.assertIn("the Apple Development identity couldn't sign", done.stderr)
        self.assertIn("signed ad-hoc", done.stdout)
        app = self.out / "SamRabbit.app"
        details = subprocess.run(["codesign", "-dv", str(app)], capture_output=True, text=True)
        self.assertIn("Signature=adhoc", details.stderr)
        with (app / "Contents/Info.plist").open("rb") as handle:
            info = plistlib.load(handle)
        self.assertIn("NSMicrophoneUsageDescription", info)
        self.assertEqual("26.0", info["LSMinimumSystemVersion"])

    def test_the_samrabbitkit_cache_follows_the_compiler_and_the_files(self) -> None:
        kit = self.out / "SamRabbitKit"
        target = "x86_64-apple-macos26.0" if os.uname().machine == "x86_64" else "arm64-apple-macos26.0"

        def build() -> str:
            done = subprocess.run([str(ROOT / "tools/build_samrabbitkit.sh"), str(kit), target], capture_output=True,
                                  text=True, timeout=600, check=True)
            return done.stdout + done.stderr

        self.assertIn("compiling SamRabbitKit", build())
        stamp = (kit / "stamp").read_text().splitlines()
        self.assertEqual(target, stamp[0])
        self.assertIn("Swift version", stamp[1])
        self.assertIn("Assistant/ConversationMachine.swift", stamp)
        self.assertEqual("", build(), "cached")
        # Another compiler (an Xcode update): its module can't be imported, so it is built again.
        (kit / "stamp").write_text("\n".join([stamp[0], "Apple Swift version 0.1", *stamp[2:]]) + "\n")
        self.assertIn("compiling SamRabbitKit", build())
        self.assertEqual("", build(), "cached again")
        # A source that is gone (the stamp lists one more file than there is now).
        (kit / "stamp").write_text("\n".join([*stamp, "Assistant/Removed.swift"]) + "\n")
        self.assertIn("compiling SamRabbitKit", build())


if __name__ == "__main__":
    unittest.main()
