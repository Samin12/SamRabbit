"""Which server gets the R1's T3 token, and following T3 when it moves ports (service module docstring)."""

from __future__ import annotations

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import socket
import threading
import unittest

from sam_runtime.domains.t3.client import T3Unavailable
from sam_runtime.domains.t3.service import T3Service, nearby_ports
from sam_runtime.security.credentials import ConnectionCredentialEnvelopes

from t3_fixtures import PAIRING_CODE, FakeT3Server, StubBridge, make_service, thread


def _closed_port() -> int:
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    port = listener.getsockname()[1]
    listener.close()
    return port


class _Html:
    """Another app's web page on a port (what Voyager answers on 127.0.0.1:3773)."""

    def __init__(self, port: int = 0) -> None:
        self.requests: list[dict[str, str]] = []
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_: object) -> None:
                return

            def do_GET(self) -> None:
                owner.requests.append(dict(self.headers))
                body = b"<!doctype html><html><head></head></html>"
                self.send_response(200)
                self.send_header("Content-Type", "text/html")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        self._server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
        self._thread = threading.Thread(target=self._server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._server.shutdown()
        self._server.server_close()


class T3IdentityTest(unittest.TestCase):
    def setUp(self) -> None:
        self.fake = FakeT3Server().__enter__()
        self.others: list[object] = []
        self.ports: list[int] = []
        self.service, _, self.repository, _, self.directory = make_service(probe_ports=lambda port: list(self.ports))
        self.envelopes = ConnectionCredentialEnvelopes(StubBridge())
        self.fake.set_threads([thread("t-1", "Fix login redirect")])

    def tearDown(self) -> None:
        for other in self.others:
            other.stop()
        self.fake.stop()
        self.directory.cleanup()

    def _sealed(self) -> dict[str, object]:
        record = self.repository.get()
        return json.loads(self.envelopes.open(record.connection_id, self.repository.envelope(record.connection_id)))

    def _make_legacy(self) -> T3Service:
        """Rewrite the stored envelope as an R1 paired before ids were kept, and restart the service."""
        record = self.repository.get()
        token = self._sealed()["token"]
        self.repository.set_envelope(record.connection_id, self.envelopes.seal(record.connection_id, json.dumps({"token": token})))
        return T3Service(self.repository, self.envelopes, probe_ports=lambda port: list(self.ports))

    def _requests_since(self, index: int) -> list[dict[str, object]]:
        return self.fake.requests[index:]

    def test_pairing_seals_the_environment_id_with_the_token(self) -> None:
        self.service.connect(self.fake.url, PAIRING_CODE)
        sealed = self._sealed()
        self.assertEqual("env-1", sealed["environmentId"])
        self.assertTrue(sealed["token"].startswith("tok-"))

    def test_t3_on_a_new_port_is_followed_and_saved(self) -> None:
        self.service.connect(self.fake.url, PAIRING_CODE)
        before = len(self.fake.requests)
        old_port = self.fake.move()
        self.ports = [_closed_port(), self.fake.port]
        self.service.sync_once()
        self.assertEqual(self.fake.url, self.service.status_view()["serverUrl"])
        self.assertEqual("ready", self.service.status_view()["healthState"])
        self.assertEqual(self.fake.url, self.repository.get().server_url)
        moved = self._requests_since(before)
        # The new port's descriptor is read (no token) before the token goes there.
        self.assertEqual("/.well-known/t3/environment", moved[0]["path"])
        self.assertNotIn("Authorization", moved[0]["headers"])
        self.assertEqual("/api/orchestration/shell?omitIdleSubagents=1", moved[1]["path"])
        # Writes follow the new address too.
        self.service.send_message("t-1", "Keep going")
        self.assertEqual("message.dispatch", self.fake.dispatched[-1]["type"])

    def test_a_different_t3_never_gets_the_token(self) -> None:
        self.service.connect(self.fake.url, PAIRING_CODE)
        old_port = self.fake.port
        self.fake.stop()
        with self.assertRaises(T3Unavailable):
            self.service.sync_once()  # the port is closed: nothing found nearby yet
        imposter = FakeT3Server(environment_id="env-other", label="Test Mac", port=old_port).__enter__()
        self.others.append(imposter)
        elsewhere = FakeT3Server(environment_id="env-third").__enter__()
        self.others.append(elsewhere)
        self.ports = [elsewhere.port]
        self.service._probe_after = 0.0
        self.service._down_until = 0.0
        with self.assertRaises(T3Unavailable) as caught:
            self.service.sync_once()
        self.assertEqual("mismatch", caught.exception.reason)
        self.assertEqual([], imposter.authorized_requests())
        self.assertEqual([], elsewhere.authorized_requests())
        self.assertEqual("failed", self.service.status_view()["healthState"])
        self.assertTrue(self.service.connected(), "a wrong server is not a reason to re-pair")
        self.assertEqual(f"http://127.0.0.1:{old_port}", self.repository.get().server_url)

    def test_another_app_on_the_saved_port_sends_us_looking(self) -> None:
        self.service.connect(self.fake.url, PAIRING_CODE)
        old_port = self.fake.move()
        page = _Html(old_port)
        self.others.append(page)
        self.ports = [self.fake.port]
        self.service._verified = None  # as after the failed poll while T3 restarted
        self.service.sync_once()
        self.assertEqual(self.fake.url, self.repository.get().server_url)
        self.assertFalse([headers for headers in page.requests if "Authorization" in headers])

    def test_a_legacy_record_backfills_its_environment_id_on_first_contact(self) -> None:
        self.service.connect(self.fake.url, PAIRING_CODE)
        restarted = self._make_legacy()
        self.assertNotIn("environmentId", self._sealed())
        restarted.sync_once()
        self.assertEqual("env-1", self._sealed()["environmentId"])

    def test_a_legacy_record_follows_only_an_unambiguous_t3_that_knows_its_token(self) -> None:
        self.service.connect(self.fake.url, PAIRING_CODE)
        old_port = self.fake.move()
        other = FakeT3Server(environment_id="env-other", label="Test Mac").__enter__()
        self.others.append(other)
        # Two T3 Code servers with the paired label nearby: ambiguous, so neither gets the token.
        self.ports = [self.fake.port, other.port]
        restarted = self._make_legacy()
        before = len(self.fake.requests)
        with self.assertRaises(T3Unavailable):
            restarted.sync_once()
        self.assertEqual([], other.authorized_requests())
        self.assertFalse([item for item in self._requests_since(before) if "Authorization" in item["headers"]])
        self.assertEqual(f"http://127.0.0.1:{old_port}", self.repository.get().server_url)
        # A T3 with another label is not ours either.
        other.descriptor = {**other.descriptor, "label": "Someone else's Mac"}
        restarted._probe_after = 0.0
        restarted._down_until = 0.0
        restarted.sync_once()
        self.assertEqual(self.fake.url, self.repository.get().server_url)
        self.assertEqual([], other.authorized_requests())
        self.assertEqual("env-1", self._sealed()["environmentId"], "the id is stored once the token worked there")

    def test_probes_are_rate_limited_and_never_run_for_an_asleep_mac(self) -> None:
        self.service.connect(self.fake.url, PAIRING_CODE)
        self.fake.stop()
        spare = FakeT3Server(environment_id="env-other").__enter__()
        self.others.append(spare)
        self.ports = [spare.port]
        with self.assertRaises(T3Unavailable):
            self.service.sync_once()
        probes = len(spare.requests)
        self.assertEqual(1, probes)
        self.service._down_until = 0.0
        with self.assertRaises(T3Unavailable):
            self.service.sync_once()
        self.assertEqual(probes, len(spare.requests), "no second probe within the back-off")
        record = self.repository.get()
        self.service._probe_after = 0.0
        self.assertIsNone(self.service._rediscover(record, T3Unavailable("asleep", "timeout")))
        self.assertEqual(probes, len(spare.requests))

    def test_nearby_ports_are_ordered_nearest_first(self) -> None:
        self.assertEqual([3772, 3774, 3771, 3775, 3770, 3776, 3777, 3778, 3779], nearby_ports(3773))
        self.assertEqual([3773, 3775, 3772, 3776, 3771, 3777, 3778, 3779], nearby_ports(3774))
        self.assertNotIn(8080, nearby_ports(8080))
        self.assertLessEqual(len(nearby_ports(8080)), 10)


if __name__ == "__main__":
    unittest.main()
