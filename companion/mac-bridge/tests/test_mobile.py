"""The mobile API (``/v1/mobile/*``) end to end against fakes: a fake T3 server and CLI, a fake Composio CLI, a fake
Heptabase CLI, a fake cua-driver, a fake Claude Code and renderer, temp tokens and a random port. Nothing here
reaches the real T3 Code, Google Calendar, the Heptabase journal or the live bridge.

Run: cd companion/mac-bridge && /usr/bin/python3 -m unittest discover -s tests -q
"""

from __future__ import annotations

import hashlib
import http.client
import io
import json
import logging
import os
from datetime import datetime, timezone
from pathlib import Path
import stat
import sys
import tempfile
import threading
import time
import unittest
from typing import Any, Dict, List, Optional, Tuple
from urllib.error import HTTPError
from urllib.request import Request, urlopen

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE))

import samrabbit_bridge as bridge  # noqa: E402
import samrabbit_genui as genui  # noqa: E402
import samrabbit_mac as mac  # noqa: E402
import samrabbit_mobile as mobile  # noqa: E402
import samrabbit_t3 as t3  # noqa: E402
import samrabbit_transcribe as transcribe  # noqa: E402
from fake_t3 import FakeT3  # noqa: E402
from test_genui import FakeRenderer  # noqa: E402
from test_mac_control import UID, _console_user, _ioreg_root, base_state  # noqa: E402

TOKEN = "test-token-" + "b" * 32
DESKTOP = "desktop-token-" + "d" * 32
NOTE = "call mom about the secret 4417 trip"
PROMPT = "a chart of my secret 9931 meetings"
SECRET_ENV = "do-not-pass-me-1234"
CONV = "c_mobile0123456789abcd"
# 2026-10-08 14:37:45 in New York (EDT, UTC-4)
NOW = datetime(2026, 10, 8, 18, 37, 45, tzinfo=timezone.utc).timestamp()


class Clock:
    def __init__(self, epoch: float) -> None:
        self.now = epoch
        self.mono = 10_000.0
        self._real: Optional[float] = None

    def time(self) -> float:
        return self.now

    def monotonic(self) -> float:
        return self.mono + (time.monotonic() - self._real if self._real is not None else 0.0)

    def follow_real_time(self) -> None:
        """From now on the monotonic clock also moves with real time (tests with the background worker)."""
        self._real = time.monotonic()

    def dt(self) -> datetime:
        return datetime.fromtimestamp(self.now, timezone.utc)

    def advance(self, seconds: float) -> None:
        self.now += seconds
        self.mono += seconds


class FakeHandler:
    """Enough of BaseHTTPRequestHandler for MobileService.serve() with any peer address."""

    def __init__(self, address: str, path: str, headers: Optional[Dict[str, str]] = None, body: bytes = b"") -> None:
        self.client_address = (address, 50000)
        self.path = path
        self.headers = dict(headers or {})
        if body:
            self.headers.setdefault("Content-Length", str(len(body)))
        self.rfile = io.BytesIO(body)
        self.wfile = io.BytesIO()
        self.status: Optional[int] = None
        self.sent: Dict[str, str] = {}

    def send_response(self, status: int) -> None:
        self.status = status

    def send_header(self, name: str, value: str) -> None:
        self.sent[name] = value

    def end_headers(self) -> None:
        pass

    def json(self) -> Dict[str, Any]:
        return json.loads(self.wfile.getvalue() or b"{}")


def calendar_events() -> Dict[str, Any]:
    def timed(event_id: str, title: str, start: str, end: str, **extra: Any) -> Dict[str, Any]:
        return {"id": event_id, "status": "confirmed", "summary": title, "start": {"dateTime": start},
                "end": {"dateTime": end}, **extra}
    return {
        "ongoing": timed("ongoing", "Standup 6612", "2026-10-08T14:30:00-04:00", "2026-10-08T15:00:00-04:00",
                         hangoutLink="https://meet.google.com/abc-defg-hij"),
        "later": timed("later", "Dentist", "2026-10-08T17:00:00-04:00", "2026-10-08T18:00:00-04:00",
                       location="https://zoom.us/j/123456 room 4"),
        "allday": {"id": "allday", "status": "confirmed", "summary": "Mom's birthday", "start": {"date": "2026-10-08"},
                   "end": {"date": "2026-10-09"}},
        "declined": timed("declined", "Declined sync", "2026-10-08T16:00:00-04:00", "2026-10-08T16:30:00-04:00",
                          attendees=[{"self": True, "responseStatus": "declined"}]),
        "cancelled": timed("cancelled", "Cancelled", "2026-10-08T16:00:00-04:00", "2026-10-08T16:30:00-04:00",
                           status="cancelled"),
        "where": {"id": "where", "status": "confirmed", "eventType": "workingLocation", "summary": "Home",
                  "start": {"date": "2026-10-08"}, "end": {"date": "2026-10-09"}},
        "past": timed("past", "Breakfast", "2026-10-08T08:00:00-04:00", "2026-10-08T09:00:00-04:00"),
        "far": timed("far", "Next week", "2026-10-15T10:00:00-04:00", "2026-10-15T11:00:00-04:00"),
    }


class MobileBase(unittest.TestCase):
    """A real bridge on a random loopback port with every outside dependency faked."""

    with_t3 = True

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = self.root = Path(self.tmp.name)
        bin_dir = root / "bin"
        bin_dir.mkdir()
        config = root / "config"
        config.mkdir(mode=0o700)
        self.token_file = config / "bridge-token"
        self.token_file.write_text(TOKEN + "\n")
        self.token_file.chmod(0o600)
        self.desktop_file = config / "desktop-token"
        self.desktop_file.write_text(DESKTOP + "\n")
        self.desktop_file.chmod(0o600)
        self.devices_file = config / "mobile-devices.json"
        self.t3_token_file = config / "t3-token"
        self.old_env = {key: os.environ.get(key) for key in ("FAKE_HEPTABASE_DIR", "FAKE_CUA_DIR",
                                                             "SAMRABBIT_TEST_SECRET")}
        self.addCleanup(self._restore_env)
        os.environ["SAMRABBIT_TEST_SECRET"] = SECRET_ENV
        # fake Heptabase
        self.hepta_dir = root / "hepta"
        (self.hepta_dir / "docs").mkdir(parents=True)
        os.environ["FAKE_HEPTABASE_DIR"] = str(self.hepta_dir)
        self.heptabase = bin_dir / "heptabase"
        self.heptabase.write_text(f'#!/bin/sh\nexec "{sys.executable}" "{HERE / "fake_heptabase.py"}" "$@"\n')
        self.heptabase.chmod(0o755)
        # fake Composio
        self.composio_dir = root / "composio"
        self.composio_dir.mkdir()
        self.write_calendar({"events": calendar_events()})
        self.composio = bin_dir / "composio"
        self.composio.write_text(f'#!/bin/sh\nexec "{sys.executable}" "{HERE / "fake_composio.py"}" '
                                 f'"{self.composio_dir}" "$@"\n')
        self.composio.chmod(0o755)
        # fake cua-driver, open, lsappinfo, ioreg
        self.cua_dir = root / "cua"
        self.cua_dir.mkdir()
        state = base_state()
        state["permissions"]["screen_recording"] = True
        (self.cua_dir / "state.json").write_text(json.dumps(state))
        os.environ["FAKE_CUA_DIR"] = str(self.cua_dir)
        wrappers = {}
        for name, role in (("cua-driver", "driver"), ("open", "open"), ("lsappinfo", "lsappinfo"), ("ioreg", "ioreg")):
            path = bin_dir / name
            path.write_text(f'#!/bin/sh\nFAKE_CUA_ROLE={role} exec "{sys.executable}" "{HERE / "fake_cua_driver.py"}" '
                            '"$@"\n')
            path.chmod(0o755)
            wrappers[role] = path
        home = root / "home"
        (home / "Documents").mkdir(parents=True)
        self.control = mac.MacControl(mac.CuaDriver(str(wrappers["driver"]), timeout=5.0),
                                      open_command=str(wrappers["open"]), lsappinfo=str(wrappers["lsappinfo"]),
                                      ioreg=str(wrappers["ioreg"]), uid=UID, home=str(home),
                                      computer_name=lambda: "Test Mac Studio")
        # fake Claude Code + renderer for generated UIs
        self.claude_dir = root / "claude"
        self.claude_dir.mkdir()
        claude = bin_dir / "claude"
        claude.write_text(f'#!/bin/sh\nexec "{sys.executable}" "{HERE / "fake_claude.py"}" --state "{self.claude_dir}" "$@"\n')
        claude.chmod(0o755)
        self.genui = genui.GenUiService(genui.ArtifactStore(str(root / "artifacts")),
                                        cli=genui.ClaudeCli(str(claude), config_file=str(root / "genui.json")),
                                        renderer=FakeRenderer(),
                                        desktop_token=genui.DesktopToken(str(self.desktop_file)))
        # fake T3
        self.t3_dir = root / "t3"
        self.t3_dir.mkdir()
        self.fake_t3 = FakeT3(str(self.t3_dir))
        self.addCleanup(self.fake_t3.close)
        self.t3_cli = bin_dir / "t3"
        self.t3_cli.write_text(f'#!/bin/sh\nexec "{sys.executable}" "{HERE / "fake_t3_cli.py"}" --state "{self.t3_dir}" '
                               '"$@"\n')
        self.t3_cli.chmod(0o755)
        self.clock = Clock(NOW)
        hub: Any = None
        if self.with_t3:
            session = t3.T3Session(t3.T3Http(self.fake_t3.url), t3.TokenStore(str(self.t3_token_file)),
                                   t3.T3Cli(str(self.t3_cli)), clock=self.clock.dt, monotonic=self.clock.monotonic)
            hub = t3.T3Hub(session, monotonic=self.clock.monotonic, clock=self.clock.dt)
        self.hub = hub
        self.transcriber = self.make_transcriber(bin_dir)
        self.assistant = self.make_assistant(bin_dir)
        self.service = mobile.MobileService(devices_file=str(self.devices_file), t3_hub=hub,
                                            timezone_name="America/New_York", google_account="owner@example.com",
                                            hosts=["192.168.1.50"], bridge_version=bridge.VERSION,
                                            transcriber=self.transcriber, assistant=self.assistant,
                                            clock=self.clock.time, monotonic=self.clock.monotonic)
        self.log = io.StringIO()
        handler = logging.StreamHandler(self.log)
        bridge._LOG.addHandler(handler)  # noqa: SLF001
        bridge._LOG.setLevel(logging.INFO)  # noqa: SLF001
        self.addCleanup(bridge._LOG.removeHandler, handler)  # noqa: SLF001
        self.server = bridge.make_server("127.0.0.1", 0, token_file=str(self.token_file), cli=str(self.heptabase),
                                         cli_timeout=5.0, mac_control=self.control, sync_dir=str(root / "sync"),
                                         desktop_token_file=str(self.desktop_file), genui_service=self.genui,
                                         composio=str(self.composio), mobile_service=self.service)
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)
        self.thread.start()
        self.addCleanup(self._stop)
        self.port = self.server.server_address[1]
        self.base = f"http://127.0.0.1:{self.port}"

    def make_transcriber(self, bin_dir: Path) -> Any:
        """Speech to text: no helper here (deterministic, whatever is built in the checkout); test_transcribe.py
        gives its tests a fake one."""
        return transcribe.Transcriber(str(bin_dir / "samrabbit-transcribe-not-built"))

    def make_assistant(self, bin_dir: Path) -> Any:
        """The watch's voice assistant: none here; test_assistant.py gives its tests one with fakes."""
        return None

    def _stop(self) -> None:
        self.server.shutdown()
        self.server.server_close()

    def _restore_env(self) -> None:
        for key, value in self.old_env.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

    # ------------------------------------------------------------------ helpers
    def write_calendar(self, value: Dict[str, Any]) -> None:
        (self.composio_dir / "state.json").write_text(json.dumps(value))

    def composio_calls(self) -> List[Dict[str, Any]]:
        path = self.composio_dir / "calls.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def cua_calls(self, role: str) -> List[Dict[str, Any]]:
        path = self.cua_dir / "calls.jsonl"
        lines = path.read_text().splitlines() if path.exists() else []
        return [entry for entry in map(json.loads, lines) if entry["role"] == role]

    def t3_cli_calls(self) -> List[Dict[str, Any]]:
        path = self.t3_dir / "cli-calls.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def request(self, method: str, path: str, body: Any = None, *, token: Optional[str] = None,
                desktop: bool = False, headers: Optional[Dict[str, str]] = None,
                raw: Optional[bytes] = None) -> Tuple[int, Dict[str, str], bytes]:
        merged = {"Content-Type": "application/json"}
        if token is not None:
            merged["Authorization"] = "Bearer " + token
        if desktop:
            merged["X-SamRabbit-Desktop"] = DESKTOP
        merged.update(headers or {})
        data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
        try:
            with urlopen(Request(self.base + path, data=data, method=method, headers=merged), timeout=30) as response:
                return response.status, dict(response.headers), response.read()
        except HTTPError as error:
            return error.code, dict(error.headers), error.read()

    def call(self, method: str, path: str, body: Any = None, **kwargs: Any) -> Tuple[int, Dict[str, Any]]:
        status, _headers, raw = self.request(method, path, body, **kwargs)
        return status, json.loads(raw) if raw else {}

    def start_code(self) -> Dict[str, Any]:
        status, value = self.call("POST", "/v1/mobile/pairing/start", {}, desktop=True)
        self.assertEqual(200, status, value)
        return value

    def pair(self, platform: str = "ios", name: str = "Sam's iPhone") -> Dict[str, Any]:
        code = self.start_code()["code"]
        status, value = self.call("POST", "/v1/mobile/pair", {"code": code, "deviceName": name, "platform": platform})
        self.assertEqual(200, status, value)
        return value

    def assert_log_clean(self, *secrets_: str) -> None:
        text = self.log.getvalue()
        for secret in secrets_:
            self.assertNotIn(secret, text)


# ====================================================================== pairing, devices, auth


class PairingTest(MobileBase):
    def test_pairing_start_is_for_the_desktop_app_only(self) -> None:
        phone = self.pair()["token"]
        for kwargs in ({}, {"token": TOKEN}, {"token": phone}, {"headers": {"X-SamRabbit-Desktop": "wrong-" + "x" * 30}}):
            with self.subTest(kwargs=list(kwargs)):
                status, value = self.call("POST", "/v1/mobile/pairing/start", {}, **kwargs)
                self.assertEqual(401, status)
        status, value = self.call("POST", "/v1/mobile/pairing/start", {}, desktop=True,
                                  headers={"Origin": "http://evil.example"})
        self.assertEqual(403, status, "a foreign web page can never start pairing")
        # From another machine on the LAN the desktop routes are refused even with the desktop token.
        handler = FakeHandler("192.168.1.20", "/v1/mobile/pairing/start", {"X-SamRabbit-Desktop": DESKTOP}, b"{}")
        self.service.serve(handler, "POST", "/v1/mobile/pairing/start")
        self.assertEqual(403, handler.status)

    def test_pairing_start_answers_code_url_and_hosts(self) -> None:
        value = self.start_code()
        code = value["code"]
        self.assertEqual(8, len(code))
        self.assertTrue(set(code) <= set(mobile.CODE_ALPHABET))
        self.assertFalse(set(code) & set("IO01"))
        self.assertEqual(mobile.iso_utc(NOW + 600), value["expiresAt"])
        self.assertEqual([f"192.168.1.50:{self.port}"], value["hosts"])
        self.assertEqual(f"samrabbit://pair?h=192.168.1.50:{self.port}&c={code}&n=Test%20Mac%20Studio",
                         value["pairUrl"])
        self.assertEqual("Test Mac Studio", value["bridgeName"])
        self.assert_log_clean(code)

    def test_pair_single_use_code_hashed_token_file(self) -> None:
        code = self.start_code()["code"]
        status, value = self.call("POST", "/v1/mobile/pair", {"code": code.lower()[:4] + "-" + code[4:],
                                                              "deviceName": "Sam's iPhone", "platform": "ios"})
        self.assertEqual(200, status, value)
        token = value["token"]
        self.assertEqual({"token", "deviceId", "bridgeName", "bridgeVersion"}, set(value))
        self.assertEqual(("Test Mac Studio", bridge.VERSION), (value["bridgeName"], value["bridgeVersion"]))
        self.assertTrue(value["deviceId"].startswith("dev_"))
        self.assertGreaterEqual(len(token), 40)
        self.assertEqual(200, self.call("GET", "/v1/mobile/summary", token=token)[0])
        # The device file is private and holds only the hash.
        self.assertEqual(0o600, stat.S_IMODE(self.devices_file.stat().st_mode))
        text = self.devices_file.read_text()
        self.assertNotIn(token, text)
        record = json.loads(text)["devices"][0]
        self.assertEqual(hashlib.sha256(token.encode()).hexdigest(), record["tokenHash"])
        self.assertEqual({"deviceId", "name", "platform", "createdAt", "lastSeenAt", "tokenHash"}, set(record))
        self.assertEqual(("Sam's iPhone", "ios"), (record["name"], record["platform"]))
        # Single use.
        status, again = self.call("POST", "/v1/mobile/pair", {"code": code, "deviceName": "x", "platform": "ios"})
        self.assertEqual((401, "invalid_code"), (status, again["error"]["code"]))
        self.assert_log_clean(token, code)

    def test_codes_expire_and_a_new_code_replaces_the_old_one(self) -> None:
        first = self.start_code()["code"]
        second = self.start_code()["code"]
        status, _ = self.call("POST", "/v1/mobile/pair", {"code": first, "platform": "ios"})
        self.assertEqual(401, status, "only the newest code works")
        self.clock.advance(601)
        status, _ = self.call("POST", "/v1/mobile/pair", {"code": second, "platform": "ios"})
        self.assertEqual(401, status, "codes last 10 minutes")
        third = self.start_code()["code"]
        self.clock.advance(590)
        self.assertEqual(200, self.call("POST", "/v1/mobile/pair", {"code": third, "platform": "ios"})[0])

    def test_ten_bad_codes_lock_pairing_for_ten_minutes(self) -> None:
        code = self.start_code()["code"]
        for number in range(10):
            status, value = self.call("POST", "/v1/mobile/pair", {"code": f"ZZZZZZZ{number}", "platform": "ios"})
            self.assertEqual(401, status)
        status, value = self.call("POST", "/v1/mobile/pair", {"code": code, "platform": "ios"})
        self.assertEqual((429, "pairing_rate_limited", True), (status, value["error"]["code"],
                                                               value["error"]["retryable"]))
        self.clock.advance(601)
        code = self.start_code()["code"]
        self.assertEqual(200, self.call("POST", "/v1/mobile/pair", {"code": code, "platform": "ios"})[0])

    def test_pair_validates_platform_and_body(self) -> None:
        code = self.start_code()["code"]
        status, value = self.call("POST", "/v1/mobile/pair", {"code": "ÉÉÉÉ١٢٣٤", "platform": "ios"})
        self.assertEqual((401, "invalid_code"), (status, value["error"]["code"]), "odd input is a wrong code, not a 500")
        self.assertEqual(400, self.call("POST", "/v1/mobile/pair", {"code": code, "platform": "android"})[0])
        self.assertEqual(400, self.call("POST", "/v1/mobile/pair", raw=b"not json")[0])
        self.assertEqual(405, self.call("GET", "/v1/mobile/pair")[0])
        # A bad platform did not burn the code.
        self.assertEqual(200, self.call("POST", "/v1/mobile/pair", {"code": code, "platform": "watchos"})[0])

    def test_peer_check_accepts_lan_and_tailscale_only(self) -> None:
        token = self.pair()["token"]
        for address, expected in (("192.168.1.77", 200), ("10.0.0.4", 200), ("100.101.102.103", 200),
                                  ("fd7a:115c:a1e0::5", 200), ("::ffff:100.64.1.1", 200), ("8.8.8.8", 403),
                                  ("100.128.0.1", 403), ("2001:4860::8888", 403)):
            with self.subTest(address=address):
                handler = FakeHandler(address, "/v1/mobile/summary", {"Authorization": "Bearer " + token})
                self.service.serve(handler, "GET", "/v1/mobile/summary")
                self.assertEqual(expected, handler.status)
        handler = FakeHandler("8.8.8.8", "/v1/mobile/pair", {}, json.dumps({"code": "AAAAAAAA"}).encode())
        self.service.serve(handler, "POST", "/v1/mobile/pair")
        self.assertEqual((403, "forbidden"), (handler.status, handler.json()["error"]["code"]))

    def test_peer_rule_and_host_choice(self) -> None:
        for address in ("127.0.0.1", "192.168.1.186", "10.1.2.3", "172.20.0.9", "100.64.0.1", "100.127.255.254",
                        "::1", "fe80::1%en0", "fd7a:115c:a1e0:ab12::1", "::ffff:192.168.1.5"):
            self.assertTrue(mobile.mobile_peer_allowed(address), address)
        for address in ("8.8.8.8", "100.63.255.255", "100.128.0.0", "2001:4860::8888", "::ffff:8.8.8.8", "x", ""):
            self.assertFalse(mobile.mobile_peer_allowed(address), address)
        pairs = [("lo0", "127.0.0.1"), ("bridge100", "192.168.64.1"), ("en0", "192.168.1.183"),
                 ("en7", "169.254.10.2"), ("utun4", "100.101.102.103"), ("en1", "10.0.0.8")]
        self.assertEqual(["192.168.1.183", "100.101.102.103"], mobile.pick_hosts(pairs))
        self.assertEqual(["10.0.0.8"], mobile.pick_hosts([("en1", "10.0.0.8"), ("vmnet8", "172.16.5.1")]))

    def test_devices_list_and_revoke_from_the_desktop(self) -> None:
        phone = self.pair()
        status, listing = self.call("GET", "/v1/mobile/devices", desktop=True)
        self.assertEqual(200, status)
        self.assertEqual([phone["deviceId"]], [item["deviceId"] for item in listing["devices"]])
        self.assertNotIn("tokenHash", listing["devices"][0])
        self.assertEqual(401, self.call("GET", "/v1/mobile/devices", token=phone["token"])[0])
        self.assertEqual(401, self.call("DELETE", f"/v1/mobile/devices/{phone['deviceId']}", token=phone["token"])[0])
        self.assertEqual(404, self.call("DELETE", "/v1/mobile/devices/dev_0000000000000000", desktop=True)[0])
        status, value = self.call("DELETE", f"/v1/mobile/devices/{phone['deviceId']}", desktop=True)
        self.assertEqual((200, 1), (status, value["revoked"]))
        self.assertEqual(401, self.call("GET", "/v1/mobile/summary", token=phone["token"])[0])

    def test_watch_child_tokens(self) -> None:
        phone = self.pair()
        status, watch = self.call("POST", "/v1/mobile/devices/child", {"name": "Sam's Watch", "platform": "watchos"},
                                  token=phone["token"])
        self.assertEqual(200, status, watch)
        self.assertNotEqual(phone["token"], watch["token"])
        self.assertEqual(200, self.call("GET", "/v1/mobile/summary", token=watch["token"])[0])
        self.assertEqual(403, self.call("POST", "/v1/mobile/devices/child", {"name": "x"}, token=watch["token"])[0],
                         "a watch can't mint more tokens")
        self.assertEqual(400, self.call("POST", "/v1/mobile/devices/child", {"platform": "ios"},
                                        token=phone["token"])[0])
        # Provisioning the same watch again replaces its old token.
        status, again = self.call("POST", "/v1/mobile/devices/child", {"name": "Sam's Watch"}, token=phone["token"])
        self.assertEqual(200, status)
        self.assertEqual(401, self.call("GET", "/v1/mobile/summary", token=watch["token"])[0])
        devices = self.call("GET", "/v1/mobile/devices", desktop=True)[1]["devices"]
        child = next(item for item in devices if item["deviceId"] == again["deviceId"])
        self.assertEqual((phone["deviceId"], "watchos"), (child["parentId"], child["platform"]))
        # Revoking the phone revokes its watch too.
        self.call("DELETE", f"/v1/mobile/devices/{phone['deviceId']}", desktop=True)
        self.assertEqual(401, self.call("GET", "/v1/mobile/summary", token=again["token"])[0])
        self.assertEqual([], self.call("GET", "/v1/mobile/devices", desktop=True)[1]["devices"])

    def test_unpair_forgets_the_device(self) -> None:
        phone = self.pair()
        self.assertEqual(200, self.call("POST", "/v1/mobile/unpair", token=phone["token"])[0])
        self.assertEqual(401, self.call("GET", "/v1/mobile/summary", token=phone["token"])[0])

    def test_every_device_route_needs_a_mobile_token(self) -> None:
        phone = self.pair()["token"]
        routes = [("GET", "/v1/mobile/summary", None), ("GET", "/v1/mobile/conversations", None),
                  ("GET", f"/v1/mobile/conversations/{CONV}", None), ("GET", f"/v1/mobile/conversations/{CONV}/events", None),
                  ("GET", "/v1/mobile/stream", None), ("GET", "/v1/mobile/blobs/" + "a" * 64, None),
                  ("GET", "/v1/mobile/ui/artifacts/ui_" + "0" * 24, None),
                  ("GET", "/v1/mobile/ui/artifacts/ui_" + "0" * 24 + "/image", None),
                  ("GET", "/v1/mobile/ui/artifacts/ui_" + "0" * 24 + "/document", None),
                  ("POST", "/v1/mobile/ui/generate", {"prompt": PROMPT}),
                  ("GET", "/v1/mobile/t3/threads", None), ("GET", "/v1/mobile/t3/threads?filter=needs_you", None),
                  ("GET", "/v1/mobile/t3/threads/t-running", None), ("GET", "/v1/mobile/t3/projects", None),
                  ("POST", "/v1/mobile/t3/threads", {"text": "do a thing"}),
                  ("POST", "/v1/mobile/t3/threads/t-running/message", {"text": "hi"}),
                  ("POST", "/v1/mobile/t3/threads/t-approval/respond", {"decision": "approve"}),
                  ("POST", "/v1/mobile/t3/threads/t-running/stop", {}),
                  ("GET", "/v1/mobile/calendar/agenda", None), ("POST", "/v1/mobile/calendar/block", {"minutes": 30}),
                  ("POST", "/v1/mobile/calendar/events", {"title": "x", "startsAt": "2026-10-08T15:00:00-04:00",
                                                          "endsAt": "2026-10-08T16:00:00-04:00"}),
                  ("POST", "/v1/mobile/journal", {"text": NOTE}), ("GET", "/v1/mobile/mac/state", None),
                  ("POST", "/v1/mobile/mac/open", {"app": "Calculator"}), ("GET", "/v1/mobile/mac/screenshot", None),
                  ("POST", "/v1/mobile/devices/child", {"name": "w"}), ("POST", "/v1/mobile/unpair", {}),
                  ("POST", "/v1/mobile/transcribe", None),
                  ("GET", "/v1/mobile/nope", None), ("PUT", "/v1/mobile/summary", None)]
        before_t3 = len(self.fake_t3.requests)
        for method, path, body in routes:
            for token in (None, "wrong-token-" + "w" * 30, TOKEN, DESKTOP, phone[:-1]):
                with self.subTest(path=path, method=method, token=(token or "")[:6]):
                    status, value = self.call(method, path, body, token=token)
                    self.assertEqual(401, status)
                    self.assertEqual("unauthorized", value["error"]["code"])
        self.assertEqual(before_t3, len(self.fake_t3.requests), "nothing reached T3")
        self.assertEqual([], self.composio_calls(), "nothing reached Composio")
        self.assertFalse((self.hepta_dir / "journal.json").exists(), "nothing reached Heptabase")
        self.assertEqual([], self.cua_calls("open"))
        self.assertEqual(404, self.call("GET", "/v1/mobile/nope", token=phone)[0])
        self.assertEqual(405, self.call("PUT", "/v1/mobile/summary", token=phone)[0])

    def test_health_reports_the_mobile_section(self) -> None:
        status, health = self.call("GET", "/health", token=TOKEN)
        self.assertEqual(200, status)
        self.assertEqual({"available": True, "devices": 0, "t3": {"paired": False, "ok": False},
                          "transcribe": {"available": False, "reason": "helper_missing"}}, health["mobile"])
        phone = self.pair()["token"]
        self.call("GET", "/v1/mobile/t3/threads", token=phone)
        self.server._health = None  # noqa: SLF001
        health = self.call("GET", "/health", token=TOKEN)[1]
        self.assertEqual({"available": True, "devices": 1, "t3": {"paired": True, "ok": True},
                          "transcribe": {"available": False, "reason": "helper_missing"}}, health["mobile"])


# ====================================================================== summary


class SummaryTest(MobileBase):
    def r1_conversation(self) -> int:
        """A live R1 conversation (the sync store judges "live" by the real clock); returns its last event (ms)."""
        last = int(time.time() * 1000) - 40_000
        events = [{"id": f"{CONV}:1", "seq": 1, "type": "conversation.started", "conversationId": CONV,
                   "at": last - 20_000},
                  {"id": f"{CONV}:2", "seq": 2, "type": "message.user", "conversationId": CONV, "text": "What's next today",
                   "at": last - 10_000},
                  {"id": f"{CONV}:3", "seq": 3, "type": "message.assistant.done", "conversationId": CONV,
                   "messageId": "m1", "text": "Your standup is now.", "at": last}]
        status, value = self.call("POST", "/v1/sync/events", {"device": "r1", "events": events}, token=TOKEN)
        self.assertEqual((200, 3), (status, value["accepted"]))
        return last

    def test_summary_shape(self) -> None:
        last = self.r1_conversation()
        phone = self.pair()["token"]
        status, value = self.call("GET", "/v1/mobile/summary", token=phone)
        self.assertEqual(200, status, value)
        self.assertEqual({"generatedAt", "mac", "r1", "t3", "calendar", "latestConversation", "journal", "transcribe",
                          "assistant", "captures", "briefing"}, set(value))
        self.assertEqual({"available": True, "recent": [], "failed": 0, "pending": 0, "notes": 0}, value["captures"],
                         "voice notes (none yet; test_capture.py has them)")
        self.assertFalse(value["briefing"]["available"], "no brief on this test bridge (test_briefing.py has one)")
        self.assertEqual({"available": False, "reason": "assistant_missing"}, value["assistant"],
                         "no assistant on this test bridge (test_assistant.py has one)")
        self.assertEqual({"available": False, "reason": "helper_missing"}, value["transcribe"],
                         "the phone and the watch know whether the Mac transcribes (no helper here)")
        self.assertEqual(mobile.iso_utc(NOW), value["generatedAt"])
        self.assertEqual({"name": "Test Mac Studio", "online": True, "screenLocked": False}, value["mac"])
        self.assertEqual({"lastSeenAt", "live", "liveConversationId", "liveTitle"}, set(value["r1"]))
        self.assertEqual(mobile.iso_utc(last / 1000), value["r1"]["lastSeenAt"])
        self.assertTrue(value["r1"]["live"])
        self.assertEqual(CONV, value["r1"]["liveConversationId"])
        self.assertEqual("What's next today", value["r1"]["liveTitle"])
        latest = value["latestConversation"]
        self.assertEqual((CONV, "What's next today", "Your standup is now."),
                         (latest["conversationId"], latest["title"], latest["preview"]))
        part = value["t3"]
        self.assertEqual((True, 2, 3), (part["available"], part["needsYou"], part["working"]))
        self.assertEqual(["t-approval", "t-input", "t-starting", "t-running", "t-background"],
                         [item["threadId"] for item in part["threads"]])
        self.assertEqual({"threadId", "title", "project", "status", "updatedAt", "summary"}, set(part["threads"][0]))
        self.assertEqual(("needs_approval", "SamRabbit"), (part["threads"][0]["status"], part["threads"][0]["project"]))
        self.assertEqual("npm test -- --watch=false", part["threads"][0]["summary"], "the open request, fetched once")
        self.assertEqual("Step 2 of 4: Running unit tests", part["threads"][3]["summary"])
        calendar = value["calendar"]
        self.assertTrue(calendar["available"])
        self.assertEqual(["Standup 6612", "Dentist", "Mom's birthday"], [item["title"] for item in calendar["next"]])
        self.assertEqual({"title": "Standup 6612", "startsAt": "2026-10-08T14:30:00-04:00",
                          "endsAt": "2026-10-08T15:00:00-04:00", "allDay": False, "location": None,
                          "meetingUrl": "https://meet.google.com/abc-defg-hij"}, calendar["next"][0])
        self.assertEqual("https://zoom.us/j/123456", calendar["next"][1]["meetingUrl"])
        self.assertEqual((True, "2026-10-08T00:00:00-04:00"), (calendar["next"][2]["allDay"],
                                                               calendar["next"][2]["startsAt"]))
        self.assertEqual({"available": True}, value["journal"])

    def test_summary_is_served_from_cache_and_refreshed_after_its_ttl(self) -> None:
        phone = self.pair()["token"]
        self.call("GET", "/v1/mobile/summary", token=phone)
        shells, events_lists = self.fake_t3.count("GET /api/orchestration/shell"), len(self.composio_calls())
        self.assertEqual((1, 1), (shells, events_lists))
        started = time.monotonic()
        for _ in range(3):
            self.clock.advance(3)
            status, value = self.call("GET", "/v1/mobile/summary", token=phone)
            self.assertEqual(200, status)
        self.assertLess((time.monotonic() - started) / 3, 0.3, "under 300 ms from the cache")
        self.assertEqual(1, self.fake_t3.count("GET /api/orchestration/shell"), "T3 cached for 10 s")
        self.assertEqual(1, len(self.composio_calls()), "calendar cached for 120 s")
        self.clock.advance(2)  # 11 s after the first load
        self.fake_t3.get_thread("t-input")["hasPendingUserInput"] = False
        value = self.call("GET", "/v1/mobile/summary", token=phone)[1]
        self.assertEqual(2, self.fake_t3.count("GET /api/orchestration/shell"))
        self.assertEqual(1, value["t3"]["needsYou"])
        self.clock.advance(120)
        self.call("GET", "/v1/mobile/summary", token=phone)
        self.assertEqual(2, len(self.composio_calls()))

    def test_summary_with_the_background_worker(self) -> None:
        phone = self.pair()["token"]
        self.service.start()  # closed by server_close
        status, value = self.call("GET", "/v1/mobile/summary", token=phone)
        self.assertEqual(200, status)
        deadline = time.monotonic() + 10
        while not (value["t3"]["available"] and value["calendar"]["available"]) and time.monotonic() < deadline:
            time.sleep(0.2)
            self.clock.advance(3)
            value = self.call("GET", "/v1/mobile/summary", token=phone)[1]
        self.assertTrue(value["t3"]["available"] and value["calendar"]["available"], value)
        started = time.monotonic()
        self.call("GET", "/v1/mobile/summary", token=phone)
        self.assertLess(time.monotonic() - started, 0.3)

    def test_parts_still_loading_on_a_cold_start_say_so(self) -> None:
        phone = self.pair()["token"]
        self.fake_t3.delay["/api/orchestration/shell"] = 4.0
        (self.hepta_dir / "mode").write_text("slow")
        (self.hepta_dir / "slow").write_text("4")
        self.clock.follow_real_time()
        self.service.start()  # closed by server_close
        status, value = self.call("GET", "/v1/mobile/summary", token=phone)
        self.assertEqual(200, status)
        self.assertEqual({"available": False, "needsYou": 0, "working": 0, "threads": [], "reason": "loading"},
                         value["t3"])
        self.assertEqual({"available": False, "reason": "loading"}, value["journal"])

    def test_the_journal_part_keeps_its_reason_and_probes_through_the_read_slots(self) -> None:
        phone = self.pair()["token"]
        (self.hepta_dir / "mode").write_text("down")
        value = self.call("GET", "/v1/mobile/summary", token=phone)[1]
        self.assertEqual({"available": False, "reason": "heptabase_app_unavailable"}, value["journal"])
        (self.hepta_dir / "mode").write_text("ok")
        self.clock.advance(60)
        value = self.call("GET", "/v1/mobile/summary", token=phone)[1]
        self.assertFalse(value["journal"]["available"], "probed every 5 minutes, not on every summary")
        # A note from the phone that goes in is as good as a probe.
        self.assertEqual(200, self.call("POST", "/v1/mobile/journal", {"text": "back online"}, token=phone)[0])
        self.assertEqual({"available": True}, self.call("GET", "/v1/mobile/summary", token=phone)[1]["journal"])
        acquired = []
        original = self.server.read_slots.acquire

        def counting(*args: Any, **kwargs: Any) -> bool:
            acquired.append(1)
            return original(*args, **kwargs)

        self.server.read_slots.acquire = counting  # type: ignore[method-assign]
        self.clock.advance(301)
        self.assertTrue(self.call("GET", "/v1/mobile/summary", token=phone)[1]["journal"]["available"])
        self.assertEqual(1, len(acquired), "the probe goes through the bridge's read slots")

    def test_summary_when_t3_is_down_keeps_the_rest(self) -> None:
        phone = self.pair()["token"]
        self.fake_t3.close()
        status, value = self.call("GET", "/v1/mobile/summary", token=phone)
        self.assertEqual(200, status)
        self.assertEqual((False, "t3_unavailable"), (value["t3"]["available"], value["t3"]["reason"]))
        self.assertTrue(value["calendar"]["available"])


class DevCopyTest(unittest.TestCase):
    """A bridge run from a checkout without --t3-url / --composio never reaches T3 or Google Calendar."""

    def test_dev_copy_answers_t3_dev_copy_and_calendar_dev_copy(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "bridge-token").write_text(TOKEN + "\n")
            (root / "bridge-token").chmod(0o600)
            (root / "desktop-token").write_text(DESKTOP + "\n")
            (root / "desktop-token").chmod(0o600)
            server = bridge.make_server("127.0.0.1", 0, token_file=str(root / "bridge-token"),
                                        driver=str(root / "no-driver"), desktop_token_file=str(root / "desktop-token"),
                                        mobile_devices_file=str(root / "devices.json"), mobile_hosts=["10.0.0.2"])
            thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)
            thread.start()
            try:
                base = f"http://127.0.0.1:{server.server_address[1]}"

                def call(method: str, path: str, body: Any = None, headers: Optional[Dict[str, str]] = None) -> Tuple[int, Any]:
                    request = Request(base + path, data=json.dumps(body).encode() if body is not None else None,
                                      method=method, headers={"Content-Type": "application/json", **(headers or {})})
                    try:
                        with urlopen(request, timeout=15) as response:
                            return response.status, json.loads(response.read())
                    except HTTPError as error:
                        return error.code, json.loads(error.read() or b"{}")

                code = call("POST", "/v1/mobile/pairing/start", {}, {"X-SamRabbit-Desktop": DESKTOP})[1]["code"]
                token = call("POST", "/v1/mobile/pair", {"code": code, "platform": "ios"})[1]["token"]
                auth = {"Authorization": "Bearer " + token}
                status, value = call("GET", "/v1/mobile/t3/threads", headers=auth)
                self.assertEqual((503, "t3_dev_copy"), (status, value["error"]["code"]))
                status, value = call("POST", "/v1/mobile/calendar/block", {"minutes": 30}, headers=auth)
                self.assertEqual((503, "calendar_dev_copy"), (status, value["error"]["code"]))
                status, value = call("GET", "/v1/mobile/calendar/agenda", headers=auth)
                self.assertEqual((503, "calendar_dev_copy"), (status, value["error"]["code"]))
                summary = call("GET", "/v1/mobile/summary", headers=auth)[1]
                self.assertEqual("t3_dev_copy", summary["t3"]["reason"])
                self.assertEqual("calendar_dev_copy", summary["calendar"]["reason"])
                self.assertEqual({"available": True, "dryRun": True}, summary["journal"])
                status, value = call("POST", "/v1/mobile/journal", {"text": NOTE}, headers=auth)
                self.assertEqual((200, True), (status, value.get("dryRun")), "a checkout copy never writes the journal")
            finally:
                server.shutdown()
                server.server_close()


# ====================================================================== T3


class T3RoutesTest(MobileBase):
    def setUp(self) -> None:
        super().setUp()
        self.phone = self.pair()["token"]

    def threads(self, query: str = "") -> List[Dict[str, Any]]:
        status, value = self.call("GET", "/v1/mobile/t3/threads" + query, token=self.phone)
        self.assertEqual(200, status, value)
        return value["threads"]

    def test_status_mapping_for_every_state(self) -> None:
        by_id = {item["threadId"]: item for item in self.threads()}
        self.assertEqual({"t-approval": "needs_approval", "t-input": "needs_input", "t-running": "working",
                          "t-starting": "working", "t-background": "working", "t-error": "error",
                          "t-settled-error": "done", "t-done": "done", "t-new": "idle", "t-stopped": "done"},
                         {key: item["status"] for key, item in by_id.items()})
        self.assertNotIn("t-archived", by_id)
        self.assertEqual("Stopped", by_id["t-stopped"]["statusLabel"])
        self.assertEqual("Background work", by_id["t-background"]["statusLabel"])
        self.assertEqual("Starting", by_id["t-starting"]["statusLabel"])
        self.assertEqual("The provider stopped unexpectedly.", by_id["t-error"]["summary"])
        self.assertEqual(("SamRabbit", "p-rabbit"), (by_id["t-running"]["projectName"], by_id["t-running"]["projectId"]))
        self.assertEqual(0.25, by_id["t-running"]["progress"])
        self.assertEqual("2026-10-08T12:57:00Z", by_id["t-running"]["updatedAt"], "seconds, UTC, no fraction")
        for item in by_id.values():
            self.assertTrue({"threadId", "title", "projectId", "projectName", "status", "updatedAt", "summary"} <= set(item))
        self.assertEqual(["t-approval", "t-input"], [item["threadId"] for item in self.threads("?filter=needs_you")])
        self.assertEqual({"t-running", "t-starting", "t-background"},
                         {item["threadId"] for item in self.threads("?filter=working")})
        recent = self.threads("?filter=recent")
        self.assertEqual(["t-done", "t-error", "t-new", "t-stopped", "t-settled-error"],
                         [item["threadId"] for item in recent])
        self.assertEqual(400, self.call("GET", "/v1/mobile/t3/threads?filter=bogus", token=self.phone)[0])

    def test_pending_requests_in_lists_and_details(self) -> None:
        self.call("GET", "/v1/mobile/summary", token=self.phone)  # fetches the open requests once
        by_id = {item["threadId"]: item for item in self.threads("?filter=needs_you")}
        self.assertEqual({"kind": "approval", "requestId": "req-approve-1", "requestKind": "command",
                          "text": "npm test -- --watch=false",
                          "options": [dict(option) for option in t3.DEFAULT_APPROVAL_OPTIONS]},
                         by_id["t-approval"]["pending"])
        question = by_id["t-input"]["pending"]
        self.assertEqual(("question", "Which database should I use?", ["SQLite", "Postgres"], False),
                         (question["kind"], question["text"], question["options"], question["allowCustom"]))
        status, detail = self.call("GET", "/v1/mobile/t3/threads/t-approval", token=self.phone)
        self.assertEqual(200, status, detail)
        self.assertEqual({"thread", "messages", "pending", "activeTurnId"}, set(detail))
        self.assertEqual([("user", "Fix the login redirect please"), ("assistant", "I will run the tests first."),
                          ("tool", "2 steps: Command run, Read file")],
                         [(item["role"], item["text"]) for item in detail["messages"]])
        self.assertEqual("2026-10-08T12:50:00Z", detail["messages"][0]["at"])
        self.assertEqual("approval", detail["pending"]["kind"])
        self.assertEqual(404, self.call("GET", "/v1/mobile/t3/threads/t-missing", token=self.phone)[0])

    def test_dispatch_payloads(self) -> None:
        status, value = self.call("POST", "/v1/mobile/t3/threads/t-done/message", {"text": "Thanks, also check the 7781"},
                                  token=self.phone)
        self.assertEqual((200, False), (status, value["wasWorking"]))
        command = self.fake_t3.dispatched[-1]
        self.assertEqual(("thread.turn.start", "t-done", "Thanks, also check the 7781", [], "full-access", "default"),
                         (command["type"], command["threadId"], command["message"]["text"],
                          command["message"]["attachments"], command["runtimeMode"], command["interactionMode"]))
        self.assertEqual("user", command["message"]["role"])
        status, value = self.call("POST", "/v1/mobile/t3/threads/t-approval/respond", {"decision": "approve"},
                                  token=self.phone)
        self.assertEqual(200, status, value)
        self.assertEqual({"type": "thread.approval.respond", "threadId": "t-approval", "requestId": "req-approve-1",
                          "decision": "accept"},
                         {key: self.fake_t3.dispatched[-1][key] for key in ("type", "threadId", "requestId", "decision")})
        self.call("POST", "/v1/mobile/t3/threads/t-approval/respond", {"decision": "deny"}, token=self.phone)
        self.assertEqual("decline", self.fake_t3.dispatched[-1]["decision"])
        status, value = self.call("POST", "/v1/mobile/t3/threads/t-input/respond", {"answer": "postgres"},
                                  token=self.phone)
        self.assertEqual(200, status, value)
        self.assertEqual(("thread.user-input.respond", "req-input-1", {"q1": "Postgres"}),
                         (self.fake_t3.dispatched[-1]["type"], self.fake_t3.dispatched[-1]["requestId"],
                          self.fake_t3.dispatched[-1]["answers"]))
        self.call("POST", "/v1/mobile/t3/threads/t-input/respond", {"answer": "SQLite"}, token=self.phone)
        self.assertEqual({"q1": "sqlite"}, self.fake_t3.dispatched[-1]["answers"], "the option's value")
        status, value = self.call("POST", "/v1/mobile/t3/threads/t-input/respond", {"answer": "MongoDB"},
                                  token=self.phone)
        self.assertEqual(400, status, "no free text when the question does not allow it")
        status, value = self.call("POST", "/v1/mobile/t3/threads/t-done/respond", {"decision": "approve"},
                                  token=self.phone)
        self.assertEqual((409, "t3_request_not_pending"), (status, value["error"]["code"]))
        status, value = self.call("POST", "/v1/mobile/t3/threads/t-running/stop", token=self.phone)
        self.assertEqual((200, True), (status, value["wasWorking"]))
        self.assertEqual({"type": "thread.turn.interrupt", "threadId": "t-running", "turnId": "turn-active-1"},
                         {key: self.fake_t3.dispatched[-1].get(key) for key in ("type", "threadId", "turnId")})
        count = len(self.fake_t3.dispatched)
        status, value = self.call("POST", "/v1/mobile/t3/threads/t-done/stop", {}, token=self.phone)
        self.assertEqual((200, False, count), (status, value["wasWorking"], len(self.fake_t3.dispatched)))
        for command in self.fake_t3.dispatched:
            self.assertRegex(command["commandId"], r"^[0-9a-f-]{36}$")
            self.assertTrue(command["createdAt"].endswith("Z"))
        self.assert_log_clean("7781", "postgres", "Postgres", self.phone)

    def test_new_task_placement_and_payloads(self) -> None:
        cases = [("Fix the failing unit tests in the sync module", "p-rabbit", "coding"),
                 ("What's on my calendar and summarize my email", "p-agent", "orchestration"),
                 ("Tell me a joke", "p-agent", "orchestration"),
                 ("Update the Website footer copy", "p-site", "mentioned")]
        for text, project, reason in cases:
            with self.subTest(text=text):
                status, value = self.call("POST", "/v1/mobile/t3/threads", {"text": text}, token=self.phone)
                self.assertEqual(200, status, value)
                self.assertEqual((project, reason), (value["projectId"], value["placement"]))
                self.assertTrue({"threadId", "title", "projectName"} <= set(value))
                create, turn = self.fake_t3.dispatched[-2:]
                self.assertEqual(("thread.create", value["threadId"], project, value["title"], None, None),
                                 (create["type"], create["threadId"], create["projectId"], create["title"],
                                  create["branch"], create["worktreePath"]))
                self.assertEqual(("thread.turn.start", value["threadId"], text, value["title"]),
                                 (turn["type"], turn["threadId"], turn["message"]["text"], turn["titleSeed"]))
                self.assertEqual(create["modelSelection"], turn["modelSelection"])
        self.assertEqual({"instanceId": "claudeAgent", "model": "claude-opus-5-5"},
                         self.fake_t3.dispatched[-2]["modelSelection"], "the project's most recent thread's model")
        status, value = self.call("POST", "/v1/mobile/t3/threads", {"text": "Look at it", "projectId": "p-site"},
                                  token=self.phone)
        self.assertEqual(("p-site", "chosen", "Website"), (value["projectId"], value["placement"], value["projectName"]))
        self.assertEqual(400, self.call("POST", "/v1/mobile/t3/threads", {"text": "x", "projectId": "p-nope"},
                                        token=self.phone)[0])
        self.assertEqual(400, self.call("POST", "/v1/mobile/t3/threads", {"text": "  "}, token=self.phone)[0])
        # The new thread reads as working (Starting) until T3 reports its turn.
        created = value["threadId"]
        item = next(entry for entry in self.threads() if entry["threadId"] == created)
        self.assertEqual(("working", "Starting"), (item["status"], item["statusLabel"]))
        status, projects = self.call("GET", "/v1/mobile/t3/projects", token=self.phone)
        self.assertEqual(200, status)
        self.assertEqual("p-agent", projects["orchestrationProjectId"])
        self.assertNotIn("p-scratch", [item["projectId"] for item in projects["projects"]])
        self.assertEqual({"projectId", "name", "orchestration"}, set(projects["projects"][0]))

    def test_approve_and_deny_pick_the_offered_choices(self) -> None:
        activity = self.fake_t3.details["t-approval"]["activities"][-1]
        activity["payload"]["options"] = [{"decision": "acceptForSession", "label": "Allow for this session"},
                                          {"decision": "cancel", "label": "Cancel"}]
        self.call("POST", "/v1/mobile/t3/threads/t-approval/respond", {"decision": "approve"}, token=self.phone)
        self.assertEqual("acceptForSession", self.fake_t3.dispatched[-1]["decision"])
        self.call("POST", "/v1/mobile/t3/threads/t-approval/respond", {"decision": "deny"}, token=self.phone)
        self.assertEqual("cancel", self.fake_t3.dispatched[-1]["decision"])
        status, value = self.call("POST", "/v1/mobile/t3/threads/t-approval/respond", {"decision": "maybe"},
                                  token=self.phone)
        self.assertEqual(400, status)

    def test_dispatch_failure_is_reported(self) -> None:
        self.fake_t3.dispatch_status = 500
        status, value = self.call("POST", "/v1/mobile/t3/threads/t-done/message", {"text": "hi"}, token=self.phone)
        self.assertEqual((502, "t3_dispatch_failed"), (status, value["error"]["code"]))

    def test_auto_pairing_runs_the_cli_and_stores_the_token_privately(self) -> None:
        self.assertEqual([], self.t3_cli_calls(), "nothing paired before the first need")
        self.threads()
        calls = self.t3_cli_calls()
        self.assertEqual(1, len(calls))
        self.assertEqual(["auth", "pairing", "create", "--label", "SamRabbit bridge", "--ttl", "10m",
                          "--base-url", self.fake_t3.url, "--json"], calls[0]["argv"])
        self.assertEqual("1", calls[0]["env"]["ELECTRON_RUN_AS_NODE"])
        self.assertNotIn("SAMRABBIT_TEST_SECRET", calls[0]["envKeys"])
        exchange = self.fake_t3.exchanges[-1]
        self.assertEqual(("SamRabbit bridge", "bot", "macos", "orchestration:read orchestration:operate",
                          "urn:t3:params:oauth:token-type:environment-bootstrap"),
                         (exchange["client_label"], exchange["client_device_type"], exchange["client_os"],
                          exchange["scope"], exchange["subject_token_type"]))
        self.assertEqual(0o600, stat.S_IMODE(self.t3_token_file.stat().st_mode))
        stored = json.loads(self.t3_token_file.read_text())
        self.assertEqual(("2026-11-07T12:00:00Z", self.fake_t3.url, "sid-1", "SamRabbit bridge"),
                         (stored["expiresAt"], stored["serverUrl"], stored["sessionId"], stored["label"]))
        self.threads()
        self.assertEqual(1, len(self.t3_cli_calls()), "the token is reused")
        self.assert_log_clean(stored["token"], exchange["subject_token"])

    def test_a_401_pairs_again_once(self) -> None:
        self.threads()
        first = json.loads(self.t3_token_file.read_text())["token"]
        self.fake_t3.revoke_all()
        self.clock.advance(61)
        self.hub.invalidate()
        self.assertEqual(10, len(self.threads()))
        self.assertEqual(2, len(self.t3_cli_calls()))
        second = json.loads(self.t3_token_file.read_text())
        self.assertNotEqual(first, second["token"])
        self.assertEqual("sid-2", second["sessionId"])
        # T3 refusing the brand-new token too is not answered with a pairing loop.
        self.fake_t3.revoke_all()
        self.hub.invalidate()
        status, value = self.call("GET", "/v1/mobile/t3/threads", token=self.phone)
        self.assertEqual((502, "t3_unauthorized"), (status, value["error"]["code"]))
        self.assertEqual(2, len(self.t3_cli_calls()))
        self.assert_log_clean(first, second["token"])

    def test_an_expiring_token_is_replaced_before_use(self) -> None:
        old = self.fake_t3.issue_token()
        self.t3_token_file.write_text(json.dumps({"token": old, "expiresAt": "2026-10-09T02:00:00Z",
                                                  "serverUrl": self.fake_t3.url}))
        self.threads()
        self.assertEqual(1, len(self.t3_cli_calls()), "less than a day left: paired again")
        self.assertNotEqual(old, json.loads(self.t3_token_file.read_text())["token"])
        fresh = self.fake_t3.issue_token()
        self.t3_token_file.write_text(json.dumps({"token": fresh, "expiresAt": "2026-11-01T00:00:00Z",
                                                  "serverUrl": self.fake_t3.url}))
        self.hub.invalidate()
        self.threads()
        self.assertEqual(1, len(self.t3_cli_calls()), "a token written by install.sh is picked up as is")

    def test_a_failing_cli_backs_off(self) -> None:
        (self.t3_dir / "cli-mode").write_text("fail")
        status, value = self.call("GET", "/v1/mobile/t3/threads", token=self.phone)
        self.assertEqual((502, "t3_cli_failed"), (status, value["error"]["code"]))
        self.call("GET", "/v1/mobile/t3/threads", token=self.phone)
        self.assertEqual(1, len(self.t3_cli_calls()), "not run again within a minute")
        (self.t3_dir / "cli-mode").write_text("ok")
        self.clock.advance(61)
        self.assertEqual(200, self.call("GET", "/v1/mobile/t3/threads", token=self.phone)[0])
        status, health = self.call("GET", "/health", token=TOKEN)
        self.assertTrue(health["mobile"]["t3"]["paired"])

    def poll_threads(self, minutes: float, every: float = 20.0) -> List[Tuple[int, Optional[str]]]:
        """What the phone sees asking for its tasks every ``every`` seconds (the summary worker retries a failed
        T3 part about that often, and each Tasks-tab load asks too)."""
        answers = []
        for _ in range(int(minutes * 60 / every)):
            self.hub.invalidate()
            status, value = self.call("GET", "/v1/mobile/t3/threads", token=self.phone)
            answers.append((status, value.get("error", {}).get("code")))
            self.clock.advance(every)
        return answers

    def test_t3_refusing_every_token_never_pairs_in_a_loop(self) -> None:
        self.fake_t3.refuse_tokens = True
        answers = self.poll_threads(minutes=10)
        self.assertEqual({(502, "t3_unauthorized")}, set(answers))
        self.assertEqual(2, len(self.t3_cli_calls()), "paired at the start, then once more after 5 minutes")
        self.assertGreater(self.hub.status()["nextPairingInSeconds"], 0)
        self.poll_threads(minutes=50)
        self.assertEqual(4, len(self.t3_cli_calls()), "an hour: back-off of 5, 10, 20, then 40 minutes")
        self.assertEqual(4, len(self.fake_t3.exchanges), "one T3 session per pairing, no more")
        status, health = self.call("GET", "/health", token=TOKEN)
        self.assertEqual((False, False, "t3_unauthorized"), (health["mobile"]["t3"]["paired"],
                                                              health["mobile"]["t3"]["ok"],
                                                              health["mobile"]["t3"]["reason"]))
        # T3 takes the bridge's credentials again: after the back-off one pairing, and it works.
        self.fake_t3.refuse_tokens = False
        self.clock.advance(41 * 60)
        self.assertEqual(10, len(self.threads()))
        self.assertEqual(5, len(self.t3_cli_calls()))
        self.assertTrue(self.hub.status()["ok"])
        self.assert_log_clean(*[exchange["subject_token"] for exchange in self.fake_t3.exchanges])

    def test_a_token_that_worked_for_a_while_is_replaced_at_once_when_revoked(self) -> None:
        self.threads()
        self.clock.advance(3 * 86400)
        self.threads()
        self.fake_t3.revoke_all()
        self.hub.invalidate()
        self.assertEqual(10, len(self.threads()), "a revoked token is replaced without waiting")
        self.assertEqual(2, len(self.t3_cli_calls()))
        # The replacement keeps working for days, then is revoked too: replaced at once again.
        self.clock.advance(2 * 86400)
        self.hub.invalidate()
        self.threads()
        self.fake_t3.revoke_all()
        self.hub.invalidate()
        self.assertEqual(10, len(self.threads()))
        self.assertEqual(3, len(self.t3_cli_calls()))

    def test_a_cli_that_keeps_failing_pairs_at_most_six_times_an_hour(self) -> None:
        (self.t3_dir / "cli-mode").write_text("fail")
        answers = self.poll_threads(minutes=60, every=30)
        self.assertEqual({(502, "t3_cli_failed")}, set(answers))
        self.assertEqual(6, len(self.t3_cli_calls()), "1, 2, 4, 8, 10, 10 minutes apart, then the hourly cap")
        self.poll_threads(minutes=60, every=30)
        self.assertLessEqual(len(self.t3_cli_calls()), 12)

    def test_the_first_needs_you_list_already_has_the_open_requests(self) -> None:
        by_id = {item["threadId"]: item for item in self.threads("?filter=needs_you")}
        self.assertEqual(("approval", "npm test -- --watch=false"),
                         (by_id["t-approval"]["pending"]["kind"], by_id["t-approval"]["pending"]["text"]))
        self.assertEqual(["SQLite", "Postgres"], by_id["t-input"]["pending"]["options"])
        reads = self.fake_t3.count("GET /api/orchestration/threads/")
        self.threads("?filter=needs_you")
        self.threads()
        self.assertEqual(reads, self.fake_t3.count("GET /api/orchestration/threads/"), "read once, then cached")
        # A thread that starts needing you later is read on the next list.
        thread = self.fake_t3.get_thread("t-done")
        thread["hasPendingApprovals"] = True
        thread["updatedAt"] = "2026-10-08T13:00:00.000Z"
        self.fake_t3.details["t-done"] = {"messages": [], "activities": [
            {"id": "x", "kind": "approval.requested", "createdAt": "2026-10-08T13:00:00.000Z",
             "payload": {"requestId": "req-late", "requestKind": "file-change", "detail": "Edit README.md"}}]}
        self.clock.advance(4)
        item = next(entry for entry in self.threads() if entry["threadId"] == "t-done")
        self.assertEqual(("needs_approval", "req-late", "Edit README.md"),
                         (item["status"], item["pending"]["requestId"], item["pending"]["text"]))

    def test_dictated_answers_pick_options_by_position(self) -> None:
        question = self.fake_t3.details["t-input"]["activities"][0]["payload"]["questions"][0]
        question["allowCustomAnswer"] = True
        for said, expected in (("the first one", "sqlite"), ("Second option.", "Postgres"), ("2", "Postgres"),
                               ("the third one", "the third one")):
            with self.subTest(said=said):
                status, value = self.call("POST", "/v1/mobile/t3/threads/t-input/respond", {"answer": said},
                                          token=self.phone)
                self.assertEqual(200, status, value)
                self.assertEqual({"q1": expected}, self.fake_t3.dispatched[-1]["answers"])


# ====================================================================== calendar


class CalendarTest(MobileBase):
    def setUp(self) -> None:
        super().setUp()
        self.phone = self.pair()["token"]

    def creates(self) -> List[Dict[str, Any]]:
        return [call["args"] for call in self.composio_calls() if call["slug"] == "GOOGLECALENDAR_CREATE_EVENT"]

    def test_block_rounds_now_down_to_the_minute_in_new_york(self) -> None:
        status, value = self.call("POST", "/v1/mobile/calendar/block", {"minutes": 30}, token=self.phone)
        self.assertEqual(200, status, value)
        args = self.creates()[-1]
        self.assertEqual(("Focus", "2026-10-08T14:37:00-04:00", "2026-10-08T15:07:00-04:00", "America/New_York"),
                         (args["summary"], args["start_datetime"], args["end_datetime"], args["timezone"]))
        self.assertEqual((False, "none"), (args["create_meeting_room"], args["send_updates"]))
        self.assertEqual((True, 30), (value["ok"], value["minutes"]))
        self.call("POST", "/v1/mobile/calendar/block", {"minutes": 90, "title": "Deep work"}, token=self.phone)
        args = self.creates()[-1]
        self.assertEqual(("Deep work", "2026-10-08T16:07:00-04:00"), (args["summary"], args["end_datetime"]))
        for bad in (0, 4, 721, "30", True, 12.5, None):
            with self.subTest(minutes=bad):
                self.assertEqual(400, self.call("POST", "/v1/mobile/calendar/block", {"minutes": bad},
                                                token=self.phone)[0])

    def test_block_across_the_daylight_saving_change(self) -> None:
        # 2026-11-01 01:50:30 EDT; clocks fall back at 02:00 EDT to 01:00 EST.
        self.clock.now = datetime(2026, 11, 1, 5, 50, 30, tzinfo=timezone.utc).timestamp()
        self.call("POST", "/v1/mobile/calendar/block", {"minutes": 30}, token=self.phone)
        args = self.creates()[-1]
        self.assertEqual(("2026-11-01T01:50:00-04:00", "2026-11-01T01:20:00-05:00"),
                         (args["start_datetime"], args["end_datetime"]))
        zone = mobile.load_zone("America/New_York")
        start, end = mobile.block_window(datetime(2026, 3, 8, 1, 45, 59, 999, tzinfo=zone), 30)
        self.assertEqual(("2026-03-08T01:45:00-05:00", "2026-03-08T03:15:00-04:00"),
                         (start.isoformat(), end.isoformat()), "spring forward: still 30 real minutes")

    def test_agenda_parses_filters_and_caches(self) -> None:
        status, value = self.call("GET", "/v1/mobile/calendar/agenda?hours=24", token=self.phone)
        self.assertEqual(200, status, value)
        self.assertEqual(["Mom's birthday", "Standup 6612", "Dentist"], [item["title"] for item in value["events"]],
                         "no cancelled, declined, working-location, past or far events")
        self.assertEqual((False, "America/New_York", "2026-10-08T14:37:45-04:00", "2026-10-09T14:37:45-04:00"),
                         (value["cached"], value["timezone"], value["from"], value["to"]))
        args = self.composio_calls()[-1]["args"]
        self.assertEqual(({"calendarId": "primary", "singleEvents": True, "orderBy": "startTime"}),
                         {key: args[key] for key in ("calendarId", "singleEvents", "orderBy")})
        self.clock.advance(60)
        again = self.call("GET", "/v1/mobile/calendar/agenda?hours=24", token=self.phone)[1]
        self.assertTrue(again["cached"])
        self.assertEqual(1, len(self.composio_calls()))
        self.call("POST", "/v1/mobile/calendar/block", {"minutes": 15}, token=self.phone)
        fresh = self.call("GET", "/v1/mobile/calendar/agenda?hours=24", token=self.phone)[1]
        self.assertFalse(fresh["cached"], "a write clears the cache")
        self.assertIn("Focus", [item["title"] for item in fresh["events"]])
        self.assertEqual(400, self.call("GET", "/v1/mobile/calendar/agenda?hours=abc", token=self.phone)[0])

    def test_create_event(self) -> None:
        status, value = self.call("POST", "/v1/mobile/calendar/events",
                                  {"title": "Lunch with Ana", "startsAt": "2026-10-09T12:00:00-04:00",
                                   "endsAt": "2026-10-09T13:00:00-04:00"}, token=self.phone)
        self.assertEqual(200, status, value)
        args = self.creates()[-1]
        self.assertEqual(("Lunch with Ana", "2026-10-09T12:00:00-04:00", "2026-10-09T13:00:00-04:00",
                          "America/New_York"),
                         (args["summary"], args["start_datetime"], args["end_datetime"], args["timezone"]))
        status, value = self.call("POST", "/v1/mobile/calendar/events", {"title": "x", "startsAt": "tomorrow"},
                                  token=self.phone)
        self.assertEqual(400, status)

    def test_composio_failure_is_an_error_not_an_empty_day(self) -> None:
        self.write_calendar({"events": {}, "scripted": {"GOOGLECALENDAR_EVENTS_LIST": {
            "stdout": json.dumps({"successful": False, "error": "No active connection for googlecalendar"})}}})
        status, value = self.call("GET", "/v1/mobile/calendar/agenda", token=self.phone)
        self.assertEqual((503, "calendar_not_connected"), (status, value["error"]["code"]))
        summary = self.call("GET", "/v1/mobile/summary", token=self.phone)[1]
        self.assertEqual({"available": False, "next": [], "reason": "calendar_not_connected"}, summary["calendar"])


# ====================================================================== journal, conversations, generated UIs, Mac


class JournalTest(MobileBase):
    def test_note_is_appended_verbatim_with_the_time(self) -> None:
        phone = self.pair()["token"]
        status, value = self.call("POST", "/v1/mobile/journal", {"text": "Call *mom*  about\nthe_trip " + NOTE},
                                  token=phone)
        self.assertEqual(200, status, value)
        self.assertEqual({"recorded": True, "date": "2026-10-08", "time": "14:37"}, value)
        journal = json.loads((self.hepta_dir / "journal.json").read_text())
        self.assertEqual({"2026-10-08": ["**14:37** Call \\*mom\\* about the\\_trip " + NOTE]}, journal)
        for bad in ({"text": "   "}, {"text": 5}, {"text": "x" * 4001}, {}):
            with self.subTest(body=bad):
                self.assertEqual(400, self.call("POST", "/v1/mobile/journal", bad, token=phone)[0])
        self.assert_log_clean(NOTE, "mom")
        self.assertEqual("**09:05** a \\[link\\](x) \\<b\\>",
                         mobile.journal_note("a [link](x) <b>", datetime(2026, 1, 2, 9, 5)))

    def test_codes_passwords_and_keys_are_redacted_as_on_the_r1(self) -> None:
        phone = self.pair()["token"]
        status, value = self.call("POST", "/v1/mobile/journal",
                                  {"text": "The code is 123456 and my password is hunter2, see you"}, token=phone)
        self.assertEqual((200, True), (status, value.get("redacted")))
        journal = json.loads((self.hepta_dir / "journal.json").read_text())
        self.assertEqual("**14:37** The code is \\[redacted\\] and my password is \\[redacted\\], see you",
                         journal["2026-10-08"][-1])
        self.assertNotIn("redacted", self.call("POST", "/v1/mobile/journal", {"text": NOTE}, token=phone)[1],
                         "nothing to hide: the words go in as said")
        moment = datetime(2026, 1, 2, 9, 5)
        for said, written in (("key sk-ant-" + "a" * 24 + " ok", "key \\[redacted\\] ok"),
                              ("token ghp_" + "b" * 30, "token \\[redacted\\]"),
                              ("verification code: 4417 99", "verification code: \\[redacted\\]"),
                              ("call mom about the 4417 trip", "call mom about the 4417 trip")):
            with self.subTest(said=said):
                self.assertEqual("**09:05** " + written, mobile.journal_note(said, moment))
        self.assert_log_clean("123456", "hunter2")


class ConversationsTest(MobileBase):
    def test_conversation_routes_reuse_the_sync_handlers(self) -> None:
        phone = self.pair()["token"]
        events = [{"id": f"{CONV}:{n}", "seq": n, "type": "message.user", "conversationId": CONV,
                   "text": f"hello {n}", "at": 1_760_000_000_000 + n} for n in range(1, 4)]
        self.call("POST", "/v1/sync/events", {"device": "r1", "events": events}, token=TOKEN)
        data = b"\xff\xd8\xff\xe0" + b"jpeg-bytes" * 30 + b"\xff\xd9"
        digest = hashlib.sha256(data).hexdigest()
        status, _h, _raw = self.request("PUT", f"/v1/sync/blobs/{digest}", raw=data, token=TOKEN,
                                        headers={"Content-Type": "image/jpeg", "X-SAM-Conversation": CONV})
        self.assertEqual(200, status)
        for mobile_path, sync_path in (("/v1/mobile/conversations?limit=5", "/v1/sync/conversations?limit=5"),
                                       (f"/v1/mobile/conversations/{CONV}", f"/v1/sync/conversations/{CONV}"),
                                       (f"/v1/mobile/conversations/{CONV}/events?after=1",
                                        f"/v1/sync/conversations/{CONV}/events?after=1")):
            with self.subTest(path=mobile_path):
                status, _headers, mine = self.request("GET", mobile_path, token=phone)
                self.assertEqual(200, status)
                desktop_status, _headers, desktop = self.request("GET", sync_path, desktop=True)
                self.assertEqual((200, json.loads(desktop)), (desktop_status, json.loads(mine)))
        status, headers, raw = self.request("GET", f"/v1/mobile/blobs/{digest}", token=phone)
        self.assertEqual((200, data, "image/jpeg"), (status, raw, headers["Content-Type"]))
        self.assertEqual(404, self.call("GET", "/v1/mobile/conversations/c_nope1234567", token=phone)[0])
        self.assertEqual(404, self.call("GET", "/v1/mobile/blobs/" + "0" * 64, token=phone)[0])
        # The live stream, in the desktop format.
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        connection.request("GET", "/v1/mobile/stream?after=0", headers={"Authorization": "Bearer " + phone})
        response = connection.getresponse()
        self.assertEqual((200, "text/event-stream; charset=utf-8"), (response.status, response.getheader("Content-Type")))
        lines = []
        while len([line for line in lines if line.startswith("event: sync")]) < 3:
            lines.append(response.fp.readline().decode().strip())
        self.assertIn(f"\"conversationId\":\"{CONV}\"", "\n".join(lines))
        connection.close()


class StreamTest(MobileBase):
    def open_stream(self, token: str) -> Tuple[http.client.HTTPConnection, Any]:
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        self.addCleanup(connection.close)
        connection.request("GET", "/v1/mobile/stream?after=0", headers={"Authorization": "Bearer " + token})
        response = connection.getresponse()
        return connection, response

    def assert_open(self, response: Any) -> None:
        self.assertEqual(200, response.status)
        self.assertTrue(response.fp.readline().startswith(b"retry:"))

    def assert_closed_soon(self, response: Any) -> None:
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            line = response.fp.readline()
            if line == b"":
                return
        self.fail("the stream is still open")

    def test_phones_share_a_few_streams_and_a_revoked_device_is_cut_off(self) -> None:
        first, second, third = (self.pair(name=name) for name in ("Phone A", "Phone B", "Phone C"))
        _c1, a1 = self.open_stream(first["token"])
        self.assert_open(a1)
        _c2, a2 = self.open_stream(first["token"])
        self.assert_open(a2)
        _c3, a3 = self.open_stream(first["token"])  # a reconnect: the oldest of this phone's streams goes
        self.assert_open(a3)
        self.assert_closed_soon(a1)
        _c4, b1 = self.open_stream(second["token"])
        self.assert_open(b1)
        _c5, b2 = self.open_stream(second["token"])
        self.assert_open(b2)
        _c6, c1 = self.open_stream(third["token"])
        self.assertEqual(503, c1.status, "four phone streams at most: the desktop app keeps the other slots")
        self.assertEqual("too_many_streams", json.loads(c1.read())["error"]["code"])
        desktop = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        self.addCleanup(desktop.close)
        desktop.request("GET", "/v1/sync/stream?after=0", headers={"X-SamRabbit-Desktop": DESKTOP})
        self.assertEqual(200, desktop.getresponse().status, "the desktop app still gets a stream")
        status, value = self.call("DELETE", f"/v1/mobile/devices/{first['deviceId']}", desktop=True)
        self.assertEqual((200, 1), (status, value["revoked"]))
        self.assert_closed_soon(a2)
        self.assert_closed_soon(a3)
        _c7, c2 = self.open_stream(third["token"])
        self.assert_open(c2)
        self.assertEqual(401, self.open_stream(first["token"])[1].status)


class GeneratedUiTest(MobileBase):
    def test_generate_records_into_the_phone_conversation(self) -> None:
        phone = self.pair()["token"]
        status, value = self.call("POST", "/v1/mobile/ui/generate", {"prompt": PROMPT, "data": {"rows": [1, 2]}},
                                  token=phone)
        self.assertEqual(202, status, value)
        artifact, conversation = value["artifactId"], value["conversationId"]
        self.assertEqual(("generating", "phone-20261008"), (value["status"], conversation))
        self.genui.start()
        self.assertTrue(self.genui.wait_idle(30))
        status, meta = self.call("GET", f"/v1/mobile/ui/artifacts/{artifact}", token=phone)
        self.assertEqual((200, "ready", "Meetings this week"), (status, meta["status"], meta["title"]))
        status, headers, image = self.request("GET", f"/v1/mobile/ui/artifacts/{artifact}/image", token=phone)
        self.assertEqual((200, "image/jpeg", b"\xff\xd8"), (status, headers["Content-Type"], image[:2]))
        status, headers, document = self.request("GET", f"/v1/mobile/ui/artifacts/{artifact}/document", token=phone)
        self.assertEqual(200, status)
        self.assertIn("sandbox allow-scripts", headers["Content-Security-Policy"])
        self.assertIn(b"Meetings this week", document)
        # In the sync store: a "Phone" conversation, never live, with the request and the result.
        status, listing = self.call("GET", "/v1/sync/conversations", desktop=True)
        phone_conversation = next(item for item in listing["conversations"] if item["conversationId"] == conversation)
        self.assertEqual(("Phone", False, "mac"), (phone_conversation["title"], phone_conversation["live"],
                                                   phone_conversation["device"]))
        events = self.call("GET", f"/v1/sync/conversations/{conversation}/events", desktop=True)[1]["events"]
        self.assertEqual(["message.user", "ui.generating", "ui.generated"], [item["type"] for item in events])
        self.assertEqual((PROMPT, "phone"), (events[0]["text"], events[0]["origin"]))
        self.assertEqual(artifact, events[2]["artifactId"])
        summary = self.call("GET", "/v1/mobile/summary", token=phone)[1]
        self.assertIsNone(summary["latestConversation"], "the phone's own conversation is not an R1 one")
        self.assertFalse(summary["r1"]["live"])
        self.assertEqual(400, self.call("POST", "/v1/mobile/ui/generate", {"prompt": ""}, token=phone)[0])
        self.assert_log_clean(PROMPT, "9931")

    def phone_events(self) -> List[Dict[str, Any]]:
        status, value = self.call("GET", "/v1/sync/conversations/phone-20261008/events", desktop=True)
        return value.get("events", []) if status == 200 else []

    def test_a_refused_request_leaves_no_user_line(self) -> None:
        phone = self.pair()["token"]
        status, value = self.call("POST", "/v1/mobile/ui/generate", {"prompt": PROMPT, "data": "x" * 24001},
                                  token=phone)
        self.assertEqual((400, "invalid_data"), (status, value["error"]["code"]))
        status, value = self.call("POST", "/v1/mobile/ui/generate", {"prompt": PROMPT, "requestId": "bad id!"},
                                  token=phone)
        self.assertEqual((400, "invalid_request_id"), (status, value["error"]["code"]))
        for number in range(genui.MAX_QUEUE):  # the generator is not running: these fill its queue
            self.genui.submit({"requestId": f"r1:{number}", "prompt": "a card"})
        status, value = self.call("POST", "/v1/mobile/ui/generate", {"prompt": PROMPT}, token=phone)
        self.assertEqual((503, "genui_busy", True), (status, value["error"]["code"], value["error"]["retryable"]))
        self.assertEqual([], self.phone_events())

    def test_a_retry_with_the_same_request_id_makes_one_visual(self) -> None:
        phone = self.pair()["token"]
        body = {"prompt": PROMPT, "requestId": "4C1F7A3E-2B9D-4E51-8A60-0D2C9B7E1F11"}
        first = self.call("POST", "/v1/mobile/ui/generate", body, token=phone)
        again = self.call("POST", "/v1/mobile/ui/generate", body, token=phone)
        self.assertEqual((202, 202), (first[0], again[0]))
        self.assertEqual(first[1], again[1])
        self.assertEqual(["message.user", "ui.generating"], [item["type"] for item in self.phone_events()])
        self.genui.start()
        self.assertTrue(self.genui.wait_idle(30))
        status, value = self.call("POST", "/v1/mobile/ui/generate", body, token=phone)
        self.assertEqual((200, "ready", first[1]["artifactId"]), (status, value["status"], value["artifactId"]))
        self.assertEqual(["message.user", "ui.generating", "ui.generated"],
                         [item["type"] for item in self.phone_events()])
        other = self.call("POST", "/v1/mobile/ui/generate", {"prompt": PROMPT}, token=phone)[1]
        self.assertNotEqual(first[1]["artifactId"], other["artifactId"], "without a requestId: a new visual")


class MacTest(MobileBase):
    def setUp(self) -> None:
        super().setUp()
        self.phone = self.pair()["token"]

    def update_cua(self, **changes: Any) -> None:
        path = self.cua_dir / "state.json"
        value = json.loads(path.read_text())
        value.update(changes)
        path.write_text(json.dumps(value))

    def test_open_applies_the_google_account_rule(self) -> None:
        status, value = self.call("POST", "/v1/mobile/mac/open", {"url": "https://calendar.google.com/calendar/u/1/r"},
                                  token=self.phone)
        self.assertEqual(200, status, value)
        self.assertEqual(["-a", "Google Chrome", "https://calendar.google.com/calendar/r?authuser=owner@example.com"],
                         self.cua_calls("open")[-1]["argv"])
        self.call("POST", "/v1/mobile/mac/open", {"url": "https://example.com/a?b=1"}, token=self.phone)
        self.assertEqual("https://example.com/a?b=1", self.cua_calls("open")[-1]["argv"][-1])
        status, value = self.call("POST", "/v1/mobile/mac/open", {"app": "Calculator"}, token=self.phone)
        self.assertEqual(200, status, value)
        for bad in ({"path": "~/Documents"}, {"app": "Calculator", "url": "https://x.com"}, {}, {"app": 5}):
            with self.subTest(body=bad):
                self.assertEqual(400, self.call("POST", "/v1/mobile/mac/open", bad, token=self.phone)[0])

    def test_the_google_account_is_learned_from_the_calendar_after_a_restart(self) -> None:
        self.service._google_account = None  # noqa: SLF001 - as installed: no SAMRABBIT_GOOGLE_ACCOUNT
        events = calendar_events()
        events["later"]["creator"] = {"email": "Owner2@Example.com", "self": True}
        self.write_calendar({"events": events})
        # Nothing known yet (no event was created since the bridge started): a Google link loads the agenda first.
        self.call("POST", "/v1/mobile/mac/open", {"url": "https://mail.google.com/mail/u/0/#inbox"}, token=self.phone)
        self.assertEqual("https://mail.google.com/mail/?authuser=owner2@example.com#inbox",
                         self.cua_calls("open")[-1]["argv"][-1])
        self.assertEqual(1, len(self.composio_calls()))
        self.call("POST", "/v1/mobile/mac/open", {"url": "https://example.com/"}, token=self.phone)
        self.call("POST", "/v1/mobile/mac/open", {"url": "https://drive.google.com/"}, token=self.phone)
        self.assertEqual("https://drive.google.com/drive/?authuser=owner2@example.com",
                         self.cua_calls("open")[-1]["argv"][-1])
        self.assertEqual(1, len(self.composio_calls()), "learned once, then known")

    def test_account_from_events(self) -> None:
        mine = {"email": "me@example.com", "self": True}
        group = {"email": "family123@group.calendar.google.com", "self": True}
        cases = [({"items": [{"creator": {"email": "other@example.com"}}, {"creator": mine}]}, "primary", "me@example.com"),
                 ({"response_data": {"items": [{"organizer": mine}]}}, "primary", "me@example.com"),
                 ({"items": [{"organizer": group}]}, "primary", None),
                 ({"items": [], "summary": "Me@Example.com"}, "primary", "me@example.com"),
                 ({"items": [], "summary": "Family"}, "family123@group.calendar.google.com", None),
                 ({"items": [{"organizer": mine}]}, "team@example.com", "team@example.com"),
                 ({"items": []}, "primary", None)]
        for data, calendar_id, expected in cases:
            with self.subTest(data=data, calendar=calendar_id):
                self.assertEqual(expected, mobile.account_from_events(data, calendar_id))

    def test_screenshot_is_a_jpeg_or_a_clear_error(self) -> None:
        status, headers, raw = self.request("GET", "/v1/mobile/mac/screenshot", token=self.phone)
        self.assertEqual((200, "image/jpeg", b"\xff\xd8"), (status, headers["Content-Type"], raw[:2]))
        self.assertGreater(int(headers["X-Image-Width"]), 0)
        self.update_cua(ioreg=_ioreg_root(_console_user(locked=True), console_locked=True))
        status, value = self.call("GET", "/v1/mobile/mac/screenshot", token=self.phone)
        self.assertEqual((409, "screen_locked"), (status, value["error"]["code"]))
        self.update_cua(ioreg=_ioreg_root(_console_user()), permissions={"accessibility": True,
                                                                          "screen_recording": False})
        status, value = self.call("GET", "/v1/mobile/mac/screenshot", token=self.phone)
        self.assertEqual((409, "screen_recording_required"), (status, value["error"]["code"]))

    def test_state(self) -> None:
        status, value = self.call("GET", "/v1/mobile/mac/state", token=self.phone)
        self.assertEqual(200, status, value)
        self.assertEqual((True, "Test Mac Studio", "Google Chrome"), (value["available"], value["computer"],
                                                                       value["front"]["app"]))
        self.update_cua(permissions={"accessibility": False, "screen_recording": False})
        self.control._permissions = None  # noqa: SLF001 - skip the 10 s permission cache
        status, value = self.call("GET", "/v1/mobile/mac/state", token=self.phone)
        self.assertEqual((200, False, "Test Mac Studio"), (status, value["available"], value["computer"]))
        self.assertIn("code", value["error"])


class LogHygieneTest(MobileBase):
    def test_the_log_has_routes_and_codes_only(self) -> None:
        phone = self.pair()
        self.call("GET", "/v1/mobile/summary", token=phone["token"])
        self.call("GET", "/v1/mobile/t3/threads/t-approval", token=phone["token"])
        self.call("POST", "/v1/mobile/journal", {"text": NOTE}, token=phone["token"])
        text = self.log.getvalue()
        self.assertIn("GET /v1/mobile/t3/threads/{id} 200", text)
        self.assertIn("POST /v1/mobile/journal 200", text)
        for secret in (phone["token"], phone["deviceId"], NOTE, "Fix the login redirect", "npm test",
                       json.loads(self.t3_token_file.read_text())["token"]):
            self.assertNotIn(secret, text)


if __name__ == "__main__":
    unittest.main()
