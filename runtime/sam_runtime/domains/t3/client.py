"""Stdlib client for one user-configured T3 Code server (orchestration protocol 2).

The T3 server normally lives on the user's Mac on the LAN, so this client does
not use ``security.outbound`` (which rejects private hosts). Instead the
endpoint itself is validated: plain http only for private, loopback, link-local
or Tailscale (CGNAT) addresses, https for anything else. The bearer token is
never logged and never included in exception messages.

Reads are HTTP with ``x-t3-orchestration-protocol: 2`` (T3 answers a bare 400
without it): ``GET /api/orchestration/shell?omitIdleSubagents=1`` and
``GET /api/orchestration/threads/<id>/bounded`` (a byte-bounded recent window,
~1 MB at most) or ``/threads/<id>`` (the whole projection). Writes have no HTTP
route in protocol 2: they are one Effect RPC call each over ``GET
/ws?orchestrationProtocol=2`` with the same bearer token on the upgrade
(``orchestration.dispatchCommand``, ``orchestration.launchThread``): one
``Request``, then the matching ``Exit``; server ``Ping`` is answered with
``Pong`` and stream ``Chunk`` frames are acked. A connection failure says why in
``T3Unavailable.reason`` so the service can tell a closed port (T3 moved) from
an asleep Mac.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
import base64
import hashlib
from http.client import HTTPConnection, HTTPException, HTTPSConnection
import ipaddress
import json
import os
import socket
import ssl
import struct
import time
from urllib.parse import quote, urlencode, urlsplit
import zlib


GRANT_TYPE = "urn:ietf:params:oauth:grant-type:token-exchange"
SUBJECT_TOKEN_TYPE = "urn:t3:params:oauth:token-type:environment-bootstrap"
ACCESS_TOKEN_TYPE = "urn:ietf:params:oauth:token-type:access_token"
REQUESTED_SCOPES = "orchestration:read orchestration:operate"
CLIENT_LABEL = "Rabbit R1"
DEFAULT_T3_PORT = 3773
MAX_RESPONSE_BYTES = 8 * 1024 * 1024
MAX_WS_MESSAGE_BYTES = 8 * 1024 * 1024
ORCHESTRATION_PROTOCOL = "2"
ORCHESTRATION_PROTOCOL_HEADER = "x-t3-orchestration-protocol"
WS_PATH = "/ws?orchestrationProtocol=" + ORCHESTRATION_PROTOCOL
WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
RPC_DISPATCH = "orchestration.dispatchCommand"
RPC_LAUNCH = "orchestration.launchThread"
# Why a server could not be used (``T3Unavailable.reason``): ``refused`` (host up, port closed),
# ``timeout`` (host asleep or gone), ``not_t3`` (something else answers), ``mismatch`` (a
# different T3 environment answers), ``unreachable`` / ``invalid`` (anything else).
REFUSED = "refused"
TIMEOUT = "timeout"
NOT_T3 = "not_t3"
MISMATCH = "mismatch"
PAIRING_ALPHABET = frozenset("23456789ABCDEFGHJKLMNPQRSTUVWXYZ")
_CGNAT = ipaddress.ip_network("100.64.0.0/10")


class T3Error(RuntimeError):
    code = "t3_error"


class T3EndpointError(T3Error, ValueError):
    code = "invalid_server_url"


class T3Unavailable(T3Error):
    """Network failure, timeout, oversized or undecodable response, or the wrong server."""

    code = "t3_unavailable"

    def __init__(self, message: str, reason: str = "unreachable") -> None:
        super().__init__(message)
        self.reason = reason


class T3Unauthorized(T3Error):
    """HTTP 401 from T3: the bearer token (or pairing code) was rejected."""

    code = "t3_unauthorized"

    def __init__(self, message: str, reason: str | None = None) -> None:
        super().__init__(message)
        self.reason = reason


class T3RequestError(T3Error):
    code = "t3_request_failed"

    def __init__(self, status: int, error_code: str | None, reason: str | None) -> None:
        super().__init__(f"T3 Code returned HTTP {status}" + (f" ({reason})" if reason else ""))
        self.status = status
        self.error_code = error_code
        self.reason = reason


@dataclass(frozen=True, slots=True)
class T3Endpoint:
    scheme: str
    host: str
    port: int

    @property
    def url(self) -> str:
        host = f"[{self.host}]" if ":" in self.host else self.host
        default = 443 if self.scheme == "https" else 80
        return f"{self.scheme}://{host}" + ("" if self.port == default else f":{self.port}")


Resolver = Callable[[str], tuple[str, ...]]


def _resolve(host: str) -> tuple[str, ...]:
    infos = socket.getaddrinfo(host, None, type=socket.SOCK_STREAM)
    return tuple(sorted({str(info[4][0]) for info in infos}))


def _private_address(value: str) -> bool:
    try:
        address = ipaddress.ip_address(value.split("%", 1)[0])
    except ValueError:
        return False
    if address.is_multicast or address.is_unspecified or address.is_reserved:
        return False
    if address.is_loopback or address.is_link_local or address.is_private:
        return True
    return address.version == 4 and address in _CGNAT


def parse_server_url(value: object, *, resolver: Resolver = _resolve, verify_host: bool = True) -> T3Endpoint:
    """Validate the user's T3 server address. http is allowed only on private hosts.

    ``verify_host=False`` re-parses an address that was already validated when
    it was saved, without resolving its host name again.
    """
    text = str(value or "").strip()
    if not text:
        raise T3EndpointError("Enter the T3 Code server address, for example http://192.168.1.183:3774.")
    if len(text) > 300:
        raise T3EndpointError("The server address is too long.")
    if "://" not in text:
        text = "http://" + text
    parts = urlsplit(text)
    scheme = parts.scheme.lower()
    if scheme not in {"http", "https"}:
        raise T3EndpointError("The server address must start with http:// or https://.")
    if parts.username or parts.password:
        raise T3EndpointError("The server address must not contain a user name or password.")
    if parts.path not in {"", "/"} or parts.query or parts.fragment:
        raise T3EndpointError("Use only the server address, for example http://192.168.1.183:3774.")
    host = (parts.hostname or "").strip().lower()
    if not host or any(ch.isspace() for ch in host):
        raise T3EndpointError("The server address needs a host name or IP address.")
    try:
        port = parts.port
    except ValueError as error:
        raise T3EndpointError("The server port is invalid.") from error
    if port is None:
        port = DEFAULT_T3_PORT if scheme == "http" else 443
    if scheme == "http" and verify_host:
        if host == "localhost":
            pass
        elif _is_ip_literal(host):
            if not _private_address(host):
                raise T3EndpointError("Plain http is allowed only for a private LAN address. Use https for other hosts.")
        else:
            try:
                addresses = resolver(host)
            except (OSError, UnicodeError) as error:
                raise T3EndpointError("That host name could not be resolved. Use the Mac's IP address instead.") from error
            if not addresses or not all(_private_address(item) for item in addresses):
                raise T3EndpointError("Plain http is allowed only for a private LAN host. Use https for other hosts.")
    return T3Endpoint(scheme, host, int(port))


def normalize_pairing_code(value: object) -> tuple[str, str | None]:
    """Return (code, server_url_from_link). Accepts a bare code or a full pair link."""
    text = str(value or "").strip()
    server_url: str | None = None
    if "token=" in text:
        parts = urlsplit(text)
        if parts.scheme in {"http", "https"} and parts.netloc:
            server_url = f"{parts.scheme}://{parts.netloc}"
        fragment = parts.fragment or parts.query
        for item in fragment.split("&"):
            name, _, found = item.partition("=")
            if name == "token":
                text = found
                break
    code = "".join(ch for ch in text if ch.isalnum()).upper()
    if len(code) != 12 or any(ch not in PAIRING_ALPHABET for ch in code):
        raise T3EndpointError("The pairing code is the 12-character code from T3 Code > Settings > Connections.")
    return code, server_url


def _is_ip_literal(host: str) -> bool:
    try:
        ipaddress.ip_address(host.split("%", 1)[0])
    except ValueError:
        return False
    return True


def looks_like_t3(descriptor: object) -> bool:
    """True for a T3 Code environment descriptor that speaks orchestration protocol 2."""
    if not isinstance(descriptor, dict):
        return False
    return (
        isinstance(descriptor.get("environmentId"), str) and bool(descriptor["environmentId"].strip())
        and isinstance(descriptor.get("label"), str)
        and isinstance(descriptor.get("serverVersion"), str)
        and isinstance(descriptor.get("capabilities"), dict)
        and str(descriptor.get("orchestrationProtocolVersion")) == ORCHESTRATION_PROTOCOL
    )


class T3HttpClient:
    def __init__(
        self,
        endpoint: T3Endpoint,
        token: str | None = None,
        *,
        timeout: float = 6.0,
    ) -> None:
        self._endpoint = endpoint
        self._token = token
        self._timeout = timeout

    @property
    def endpoint(self) -> T3Endpoint:
        return self._endpoint

    def with_token(self, token: str) -> "T3HttpClient":
        return T3HttpClient(self._endpoint, token, timeout=self._timeout)

    # -- auth -------------------------------------------------------------
    def descriptor(self, *, timeout: float = 4.0) -> dict[str, object]:
        """``/.well-known/t3/environment`` (no token). Anything that is not a T3 descriptor
        (another app's HTML page, a 404, garbage) raises ``T3Unavailable(reason=not_t3)``."""
        try:
            value = self._request("GET", "/.well-known/t3/environment", auth=False, timeout=timeout)
        except T3Unavailable as error:
            if error.reason in {REFUSED, TIMEOUT, "unreachable"}:
                raise
            raise T3Unavailable("Something other than T3 Code answers there.", NOT_T3) from None
        except T3RequestError:
            raise T3Unavailable("Something other than T3 Code answers there.", NOT_T3) from None
        if not isinstance(value, dict) or not isinstance(value.get("environmentId"), str):
            raise T3Unavailable("Something other than T3 Code answers there.", NOT_T3)
        return value

    def exchange_pairing_code(self, code: str, *, label: str = CLIENT_LABEL) -> dict[str, object]:
        form = {
            "grant_type": GRANT_TYPE,
            "subject_token": code,
            "subject_token_type": SUBJECT_TOKEN_TYPE,
            "requested_token_type": ACCESS_TOKEN_TYPE,
            "scope": REQUESTED_SCOPES,
            "client_label": label,
            "client_device_type": "mobile",
            "client_os": "android",
        }
        value = self._request(
            "POST",
            "/oauth/token",
            body=urlencode(form).encode(),
            content_type="application/x-www-form-urlencoded",
            auth=False,
        )
        if not isinstance(value, dict) or not isinstance(value.get("access_token"), str) or not value["access_token"]:
            raise T3Unavailable("T3 Code returned an unexpected pairing response.", "invalid")
        return value

    def session_state(self) -> dict[str, object]:
        value = self._request("GET", "/api/auth/session", timeout=4.0)
        return value if isinstance(value, dict) else {}

    # -- orchestration reads (HTTP) ------------------------------------------
    def shell(self) -> dict[str, object]:
        """The v2 shell: ``{schemaVersion, snapshotSequence, threads, archivedThreads, projects}``.
        Idle subagent children are left out by T3 (the R1 never lists them)."""
        value = self._request("GET", "/api/orchestration/shell?omitIdleSubagents=1")
        if not isinstance(value, dict) or not isinstance(value.get("threads"), list):
            raise T3Unavailable("T3 Code returned an unexpected thread list.", "invalid")
        return value

    def thread(self, thread_id: str, *, full: bool = False) -> dict[str, object]:
        """``{snapshotSequence, projection, ...}``: the bounded recent window by default, the
        whole projection with ``full`` (only when a pending request's item fell outside it)."""
        path = f"/api/orchestration/threads/{quote(thread_id, safe='')}" + ("" if full else "/bounded")
        value = self._request("GET", path, timeout=max(self._timeout, 8.0))
        projection = value.get("projection") if isinstance(value, dict) else None
        if not isinstance(projection, dict) or not isinstance(projection.get("thread"), dict):
            raise T3Unavailable("T3 Code returned an unexpected thread.", "invalid")
        return value

    # -- orchestration writes (WebSocket RPC) ---------------------------------
    def dispatch(self, command: dict[str, object]) -> dict[str, object]:
        value = self.rpc(RPC_DISPATCH, command)
        return value if isinstance(value, dict) else {}

    def launch_thread(self, payload: dict[str, object]) -> dict[str, object]:
        value = self.rpc(RPC_LAUNCH, payload, timeout=max(self._timeout, 15.0))
        return value if isinstance(value, dict) else {}

    def rpc(self, tag: str, payload: dict[str, object], *, timeout: float | None = None) -> object:
        """One Effect RPC call over ``/ws``: ``Request`` out, the matching ``Exit`` value back.

        401 on the upgrade raises ``T3Unauthorized``; a ``Failure`` exit raises
        ``T3RequestError(422, <error _tag>)`` (``EnvironmentAuthorizationError``: 403)."""
        if not self._token:
            raise T3Unauthorized("T3 Code is not paired.", "missing_token")
        endpoint = self._endpoint
        wait = timeout if timeout is not None else self._timeout
        deadline = time.monotonic() + wait
        try:
            raw = socket.create_connection((endpoint.host, endpoint.port), timeout=wait)
        except OSError as error:
            raise T3Unavailable(f"T3 Code is unreachable ({type(error).__name__}).", _reason(error)) from None
        connection: socket.socket = raw
        try:
            if endpoint.scheme == "https":
                connection = ssl.create_default_context().wrap_socket(raw, server_hostname=endpoint.host)
            channel = _WebSocket(connection, deadline)
            channel.handshake(endpoint, self._token)
            channel.send_json({"_tag": "Request", "id": "1", "tag": tag, "payload": payload, "headers": []})
            while True:
                for message in channel.messages():
                    kind = message.get("_tag")
                    if kind == "Ping":
                        channel.send_json({"_tag": "Pong"})
                    elif kind == "Chunk" and message.get("requestId") is not None:
                        channel.send_json({"_tag": "Ack", "requestId": message["requestId"]})
                    elif kind == "Exit" and str(message.get("requestId")) == "1":
                        exit_value = message.get("exit") if isinstance(message.get("exit"), dict) else {}
                        if exit_value.get("_tag") == "Success":
                            return exit_value.get("value")
                        error_tag = _error_tag(exit_value.get("cause"))
                        status = 403 if error_tag == "EnvironmentAuthorizationError" else 422
                        raise T3RequestError(status, error_tag or "rpc_failed", None)
                    elif kind == "Defect":
                        raise T3RequestError(500, "rpc_defect", None)
        except (OSError, ValueError, ssl.SSLError) as error:
            raise T3Unavailable(f"T3 Code is unreachable ({type(error).__name__}).", _reason(error)) from None
        finally:
            try:
                connection.close()
            except OSError:
                pass

    # -- transport ----------------------------------------------------------
    def _request(
        self,
        method: str,
        path: str,
        *,
        body: bytes | None = None,
        content_type: str | None = None,
        auth: bool = True,
        timeout: float | None = None,
    ) -> object:
        headers = {
            "Accept": "application/json",
            "Accept-Encoding": "gzip",
            "User-Agent": "SamRabbit-R1/1",
        }
        if auth:
            if not self._token:
                raise T3Unauthorized("T3 Code is not paired.", "missing_token")
            headers["Authorization"] = f"Bearer {self._token}"
        if path.startswith("/api/orchestration/"):
            headers[ORCHESTRATION_PROTOCOL_HEADER] = ORCHESTRATION_PROTOCOL
        if content_type:
            headers["Content-Type"] = content_type
        endpoint = self._endpoint
        wait = timeout if timeout is not None else self._timeout
        if endpoint.scheme == "https":
            connection = HTTPSConnection(endpoint.host, endpoint.port, timeout=wait, context=ssl.create_default_context())
        else:
            connection = HTTPConnection(endpoint.host, endpoint.port, timeout=wait)
        try:
            connection.request(method, path, body=body, headers=headers)
            response = connection.getresponse()
            raw = response.read(MAX_RESPONSE_BYTES + 1)
            status = int(response.status)
            encoding = (response.getheader("Content-Encoding") or "").lower()
        except (OSError, HTTPException, ValueError) as error:
            raise T3Unavailable(f"T3 Code is unreachable ({type(error).__name__}).", _reason(error)) from None
        finally:
            connection.close()
        if len(raw) > MAX_RESPONSE_BYTES:
            raise T3Unavailable("T3 Code response is too large.", "invalid")
        if "gzip" in encoding and raw:
            raw = _gunzip(raw)
        value: object = None
        if raw:
            try:
                value = json.loads(raw)
            except (UnicodeDecodeError, ValueError):
                if status < 400:
                    raise T3Unavailable("T3 Code returned an unreadable response.", "invalid") from None
                value = None
        if status == 401:
            reason = value.get("reason") if isinstance(value, dict) else None
            raise T3Unauthorized("T3 Code rejected the credential.", str(reason) if reason else None)
        if status >= 400:
            code = value.get("code") if isinstance(value, dict) else None
            reason = value.get("reason") if isinstance(value, dict) else None
            raise T3RequestError(status, str(code) if code else None, str(reason) if reason else None)
        return value


def _reason(error: BaseException) -> str:
    if isinstance(error, ConnectionRefusedError):
        return REFUSED
    if isinstance(error, (socket.timeout, TimeoutError)):
        return TIMEOUT
    return "unreachable"


def _error_tag(cause: object, depth: int = 0) -> str | None:
    """The ``_tag`` of the first typed error inside an Effect ``Cause`` (any nesting)."""
    if depth > 6:
        return None
    if isinstance(cause, dict):
        tag = cause.get("_tag")
        if isinstance(tag, str) and tag.endswith("Error"):
            return tag
        for key in ("error", "failures", "cause", "left", "right", "reasons"):
            found = _error_tag(cause.get(key), depth + 1)
            if found:
                return found
    elif isinstance(cause, list):
        for item in cause[:8]:
            found = _error_tag(item, depth + 1)
            if found:
                return found
    return None


class _WebSocket:
    """Just enough of RFC 6455 for one RPC: a client handshake, masked text frames out, (fragmented) frames in."""

    def __init__(self, connection: socket.socket, deadline: float) -> None:
        self._connection = connection
        self._deadline = deadline
        self._buffer = b""

    def _remaining(self) -> float:
        left = self._deadline - time.monotonic()
        if left <= 0:
            raise TimeoutError("T3 Code did not answer in time.")
        return left

    def _recv(self) -> bytes:
        self._connection.settimeout(self._remaining())
        chunk = self._connection.recv(65536)
        if not chunk:
            raise ConnectionResetError("T3 Code closed the connection.")
        return chunk

    def _fill(self, size: int) -> bytes:
        while len(self._buffer) < size:
            self._buffer += self._recv()
        out, self._buffer = self._buffer[:size], self._buffer[size:]
        return out

    def handshake(self, endpoint: T3Endpoint, token: str) -> None:
        key = base64.b64encode(os.urandom(16)).decode("ascii")
        host = f"[{endpoint.host}]" if ":" in endpoint.host else endpoint.host
        request = (
            f"GET {WS_PATH} HTTP/1.1\r\nHost: {host}:{endpoint.port}\r\nUpgrade: websocket\r\n"
            f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n"
            f"Authorization: Bearer {token}\r\nUser-Agent: SamRabbit-R1/1\r\n\r\n"
        )
        self._connection.settimeout(self._remaining())
        self._connection.sendall(request.encode("ascii"))
        while b"\r\n\r\n" not in self._buffer:
            if len(self._buffer) > 16 * 1024:
                raise ValueError("T3 Code sent an oversized handshake.")
            self._buffer += self._recv()
        head, self._buffer = self._buffer.split(b"\r\n\r\n", 1)
        lines = head.decode("latin-1").split("\r\n")
        parts = lines[0].split(" ")
        status = int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else 0
        if status == 401:
            raise T3Unauthorized("T3 Code rejected the credential.", None)
        if status == 426:
            raise T3RequestError(426, "orchestration_protocol_incompatible", None)
        if status != 101:
            raise T3RequestError(status or 502, "websocket_refused", None)
        headers = {name.strip().lower(): value.strip() for name, _, value in (line.partition(":") for line in lines[1:])}
        expected = base64.b64encode(hashlib.sha1((key + WS_GUID).encode("ascii")).digest()).decode("ascii")
        if headers.get("sec-websocket-accept") != expected:
            raise ValueError("T3 Code sent a bad WebSocket handshake.")

    def _send(self, opcode: int, data: bytes) -> None:
        head = bytearray([0x80 | opcode])
        if len(data) < 126:
            head.append(0x80 | len(data))
        elif len(data) < 65536:
            head += bytes([0x80 | 126]) + struct.pack(">H", len(data))
        else:
            head += bytes([0x80 | 127]) + struct.pack(">Q", len(data))
        mask = os.urandom(4)
        masked = bytes(byte ^ mask[index % 4] for index, byte in enumerate(data))
        self._connection.settimeout(self._remaining())
        self._connection.sendall(bytes(head) + mask + masked)

    def send_json(self, value: dict[str, object]) -> None:
        self._send(0x1, json.dumps(value, separators=(",", ":"), ensure_ascii=False).encode("utf-8"))

    def messages(self) -> list[dict[str, object]]:
        """The next complete text message as JSON objects (Effect RPC may batch several in one array)."""
        message = b""
        while True:
            first, second = self._fill(2)
            opcode, size = first & 0x0F, second & 0x7F
            if size == 126:
                size = struct.unpack(">H", self._fill(2))[0]
            elif size == 127:
                size = struct.unpack(">Q", self._fill(8))[0]
            if size + len(message) > MAX_WS_MESSAGE_BYTES:
                raise ValueError("T3 Code sent an oversized message.")
            mask = self._fill(4) if second & 0x80 else b""  # a server never masks; tolerated anyway
            data = self._fill(size)
            if mask:
                data = bytes(byte ^ mask[index % 4] for index, byte in enumerate(data))
            if opcode == 0x8:
                raise ConnectionResetError("T3 Code closed the connection.")
            if opcode == 0x9:
                self._send(0xA, data[:125])
                continue
            if opcode == 0xA:
                continue
            message += data
            if first & 0x80:
                break
        value = json.loads(message.decode("utf-8"))
        items = value if isinstance(value, list) else [value]
        return [item for item in items if isinstance(item, dict)]


def _gunzip(raw: bytes) -> bytes:
    decoder = zlib.decompressobj(16 + zlib.MAX_WBITS)
    try:
        out = decoder.decompress(raw, MAX_RESPONSE_BYTES)
    except zlib.error:
        raise T3Unavailable("T3 Code returned a corrupt compressed response.", "invalid") from None
    if decoder.unconsumed_tail:
        raise T3Unavailable("T3 Code response is too large.", "invalid")
    return out
