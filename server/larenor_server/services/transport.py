"""Bounded HTTP/1.1 transport for explicitly configured private services.

Each request resolves once and connects to one validated numeric address. There
are no proxy, redirect, retry, cookie-jar or ambient authentication facilities.
Resolver and connector seams are trusted test hooks: resolver(host, port) returns
getaddrinfo entries; connector(family, sockaddr, timeout) returns a socket and
must honor its timeout. Production uses an owned socket before connecting.
"""

from collections.abc import Mapping
from dataclasses import dataclass, field
import ipaddress
import math
import queue
import re
import socket
import ssl
import threading
import time
from urllib.parse import urlsplit

from .models import canonical_base_url


_DNS_SLOTS = threading.BoundedSemaphore(4)
_MAX_ADDRESSES = 16
_MAX_HEADERS = 32768
_MAX_LINE = 8192
_MAX_BODY = 16 * 1024 * 1024
_TOKEN = re.compile(r"[!#$%&'*+.^_`|~0-9A-Za-z-]+\Z")
_PATH = re.compile(r"/[A-Za-z0-9._~!$&'()*+,;=:@/-]*\Z")
_FORBIDDEN_HEADERS = frozenset({
    "host", "connection", "content-length", "transfer-encoding", "trailer",
    "upgrade", "proxy-authorization", "proxy-connection", "expect", "te",
    "accept-encoding",
})
_CODES = frozenset({
    "invalid_url", "invalid_path", "invalid_request", "invalid_headers",
    "invalid_limits", "transport_closed", "request_timeout", "resolution_failed",
    "address_blocked", "invalid_resolution", "request_failed", "invalid_response",
    "response_too_large", "unsupported_encoding", "tls_failed",
})


class ProbeTransportError(Exception):
    """Only stable public codes; never include URLs, headers or raw exceptions."""

    def __init__(self, code="request_failed"):
        self.code = code if isinstance(code, str) and code in _CODES else "request_failed"
        super().__init__(self.code)


@dataclass(frozen=True)
class ProbeResponse:
    status: int
    headers: tuple[tuple[str, str], ...] = field(repr=False)
    body: bytes = field(repr=False)


def _path(value):
    if (not isinstance(value, str) or len(value) > 2048 or not _PATH.fullmatch(value)
            or "//" in value or any(part in {".", ".."} for part in value.split("/"))):
        raise ProbeTransportError("invalid_path")
    return value


def _base(value):
    invalid = False
    try:
        if (not isinstance(value, str) or len(value) > 2048 or not value
                or any(ord(c) <= 32 or ord(c) == 127 for c in value)
                or any(c in value for c in "\\?#")):
            raise ValueError
        parsed = urlsplit(value)
        if (parsed.scheme not in {"http", "https"} or not parsed.hostname
                or parsed.username is not None or parsed.password is not None
                or "%" in parsed.netloc or parsed.netloc.endswith(":")):
            raise ValueError
        host = parsed.hostname.encode("idna").decode("ascii")
        if ":" in host:
            ipaddress.IPv6Address(host)
        elif not all(re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?", part)
                     for part in host.rstrip(".").split(".")) or len(host) > 253:
            raise ValueError
        port = parsed.port if parsed.port is not None else (443 if parsed.scheme == "https" else 80)
        if not 1 <= port <= 65535:
            raise ValueError
        # Saved URLs use the same canonicalizer as CRUD. A Unicode or repeated
        # slash in the configured prefix is distinct from an adapter route;
        # the latter remains strictly ASCII and fixed by packaged code.
        canonical = urlsplit(canonical_base_url(value))
        prefix = canonical.path.rstrip("/")
        authority = f"[{host}]" if ":" in host else host
        if parsed.port is not None:
            authority += f":{port}"
    except (ValueError, UnicodeError, ProbeTransportError):
        invalid = True
    if invalid:
        raise ProbeTransportError("invalid_url")
    return parsed.scheme, host, port, authority, prefix


def _remaining(deadline):
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise ProbeTransportError("request_timeout")
    return remaining


def _resolve(resolver, host, port, deadline):
    if not _DNS_SLOTS.acquire(timeout=_remaining(deadline)):
        raise ProbeTransportError("request_timeout")
    result = queue.Queue(maxsize=1)

    def worker():
        try:
            try:
                answers = resolver(host, port)
            except Exception:
                result.put((False, None))
            else:
                result.put((True, answers))
        finally:
            _DNS_SLOTS.release()

    thread = threading.Thread(target=worker, name="service-dns", daemon=True)
    failed = False
    try:
        thread.start()
    except RuntimeError:
        _DNS_SLOTS.release()
        failed = True
    if failed:
        raise ProbeTransportError("resolution_failed")
    timed_out = False
    try:
        ok, answers = result.get(timeout=_remaining(deadline))
    except queue.Empty:
        timed_out = True
    if timed_out:
        raise ProbeTransportError("request_timeout")
    if not ok:
        raise ProbeTransportError("resolution_failed")
    _remaining(deadline)
    return _addresses(answers, port)


def _addresses(answers, port):
    valid = []
    invalid = False
    blocked = False
    try:
        if not isinstance(answers, (list, tuple)):
            raise ValueError
        for index, answer in enumerate(answers):
            if index >= _MAX_ADDRESSES or len(answer) != 5:
                raise ValueError
            family, kind, protocol, _, address = answer
            if (family not in {socket.AF_INET, socket.AF_INET6} or kind != socket.SOCK_STREAM
                    or protocol not in {0, socket.IPPROTO_TCP} or address[1] != port
                    or len(address) != (2 if family == socket.AF_INET else 4)):
                raise ValueError
            literal = ipaddress.ip_address(address[0])
            if (literal.version != (4 if family == socket.AF_INET else 6)
                    or "%" in address[0]
                    or (family == socket.AF_INET6 and address[2:] != (0, 0))):
                raise ValueError
            check = literal.ipv4_mapped if isinstance(literal, ipaddress.IPv6Address) else None
            check = check or literal
            if (check.is_unspecified or check.is_multicast or check.is_link_local
                    or str(check) in {"100.100.100.200", "255.255.255.255", "fd00:ec2::254"}
                    or (check.version == 4 and check in ipaddress.ip_network("0.0.0.0/8"))):
                blocked = True
            numeric = (str(literal), port) if family == socket.AF_INET else (str(literal), port, 0, 0)
            valid.append((family, numeric))
    except (TypeError, ValueError, IndexError):
        invalid = True
    if blocked:
        raise ProbeTransportError("address_blocked")
    if invalid or not valid:
        raise ProbeTransportError("invalid_resolution")
    # No alternate-address retry: failure of this connection is a failed probe.
    return valid[0]


def _resolve_system(host, port):
    return socket.getaddrinfo(host, port, type=socket.SOCK_STREAM, proto=socket.IPPROTO_TCP)


class _Deadline:
    def __init__(self, deadline):
        self.deadline = deadline
        self.socket = None
        self.lock = threading.Lock()
        self.expired = threading.Event()
        self.timer = threading.Timer(_remaining(deadline), self.abort)
        self.timer.daemon = True
        failed = False
        try:
            self.timer.start()
        except RuntimeError:
            failed = True
        if failed:
            raise ProbeTransportError("request_failed")

    def attach(self, connection):
        with self.lock:
            if self.expired.is_set():
                connection.close()
                raise ProbeTransportError("request_timeout")
            self.socket = connection

    def abort(self):
        self.expired.set()
        with self.lock:
            connection = self.socket
            if connection is not None:
                try:
                    connection.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
                # Wake pending I/O without releasing its descriptor underneath
                # another thread's recv/select. Closing here can leave that
                # thread blocked until its original timeout (observed on macOS).
                # The request owner closes in finish() after I/O has unwound.

    def finish(self):
        self.timer.cancel()
        with self.lock:
            if self.socket is not None:
                try:
                    self.socket.close()
                except OSError:
                    pass
                self.socket = None


class _Reader:
    def __init__(self, connection, deadline):
        self.connection, self.deadline = connection, deadline

    def receive(self, count):
        self.connection.settimeout(_remaining(self.deadline))
        return self.connection.recv(count)

    def line(self, limit):
        # Read framing without prefetching an unbounded body into a header buffer.
        value = bytearray()
        while len(value) < limit:
            piece = self.receive(1)
            if not piece:
                raise ProbeTransportError("invalid_response")
            value.extend(piece)
            if value.endswith(b"\r\n"):
                return bytes(value)
            if piece == b"\n":
                raise ProbeTransportError("invalid_response")
        raise ProbeTransportError("response_too_large")

    def exact(self, length):
        value = bytearray()
        while len(value) < length:
            piece = self.receive(min(65536, length - len(value)))
            if not piece:
                raise ProbeTransportError("invalid_response")
            value.extend(piece)
        return bytes(value)


def _response(reader, max_bytes):
    first = reader.line(_MAX_LINE)
    match = re.fullmatch(rb"HTTP/1\.[01] ([2-5][0-9]{2})(?: [\x20-\x7e]*)?\r\n", first)
    if not match:
        raise ProbeTransportError("invalid_response")
    status = int(match.group(1))
    headers = []
    total = len(first)
    while True:
        line = reader.line(min(_MAX_LINE, _MAX_HEADERS - total))
        total += len(line)
        if line == b"\r\n":
            break
        if len(headers) >= 100 or b":" not in line:
            raise ProbeTransportError("invalid_response")
        name, value = line[:-2].split(b":", 1)
        key = name.decode("latin1").lower()
        if not _TOKEN.fullmatch(key) or any(byte < 32 and byte != 9 or byte == 127 for byte in value):
            raise ProbeTransportError("invalid_response")
        headers.append((key, value.decode("latin1").strip(" \t")))
    framing = {}
    for key, value in headers:
        if key in {"content-length", "transfer-encoding", "content-encoding"}:
            if key in framing:
                raise ProbeTransportError("invalid_response")
            framing[key] = value
    length = framing.get("content-length")
    transfer = framing.get("transfer-encoding")
    encoding = framing.get("content-encoding", "identity")
    if encoding.lower() != "identity" or transfer is not None and transfer.lower() != "chunked":
        raise ProbeTransportError("unsupported_encoding")
    if transfer is not None and first.startswith(b"HTTP/1.0"):
        raise ProbeTransportError("invalid_response")
    if length is not None:
        if transfer is not None or not re.fullmatch(r"[0-9]{1,20}", length):
            raise ProbeTransportError("invalid_response")
        length = int(length)
    if status in {204, 304}:
        if transfer is not None or status == 204 and length not in {None, 0}:
            raise ProbeTransportError("invalid_response")
        return ProbeResponse(status, tuple(headers), b"")
    if length is not None:
        if length > max_bytes:
            raise ProbeTransportError("response_too_large")
        body = reader.exact(length)
    elif transfer is not None:
        body = bytearray()
        for _ in range(4096):
            size_line = reader.line(128)
            if not re.fullmatch(rb"[0-9a-fA-F]{1,16}\r\n", size_line):
                raise ProbeTransportError("invalid_response")
            size = int(size_line[:-2], 16)
            if size > max_bytes - len(body):
                raise ProbeTransportError("response_too_large")
            if size == 0:
                # Probe endpoints do not need trailer fields or chunk extensions.
                if reader.line(_MAX_LINE) != b"\r\n":
                    raise ProbeTransportError("invalid_response")
                break
            body.extend(reader.exact(size))
            if reader.exact(2) != b"\r\n":
                raise ProbeTransportError("invalid_response")
        else:
            raise ProbeTransportError("response_too_large")
        body = bytes(body)
    else:
        body = bytearray()
        while True:
            piece = reader.receive(min(65536, max_bytes - len(body) + 1))
            if not piece:
                break
            if len(piece) > max_bytes - len(body):
                raise ProbeTransportError("response_too_large")
            body.extend(piece)
        body = bytes(body)
    return ProbeResponse(status, tuple(headers), body)


def _request_bytes(method, path, authority, headers, body):
    if (not isinstance(method, str) or method not in {"GET", "POST"}
            or body is not None and not isinstance(body, bytes)):
        raise ProbeTransportError("invalid_request")
    if body is not None and (len(body) > 1024 * 1024 or method == "GET" and body):
        raise ProbeTransportError("invalid_request")
    pairs = []
    invalid = False
    try:
        source = headers.items() if isinstance(headers, Mapping) else headers or ()
        seen = set()
        for index, (name, value) in enumerate(source):
            if (index >= 64 or not isinstance(name, str) or not isinstance(value, str)
                    or len(name) > 256 or not _TOKEN.fullmatch(name) or len(value) > 4096
                    or any(ord(c) < 32 or ord(c) == 127 or ord(c) > 255 for c in value)):
                raise ValueError
            key = name.lower()
            if key in seen or key in _FORBIDDEN_HEADERS:
                raise ValueError
            seen.add(key)
            pairs.append(f"{name}: {value}\r\n")
    except (ValueError, TypeError):
        invalid = True
    if invalid:
        raise ProbeTransportError("invalid_headers")
    message = (f"{method} {path} HTTP/1.1\r\nHost: {authority}\r\n"
               "Connection: close\r\nAccept-Encoding: identity\r\n" + "".join(pairs))
    if body is not None or method == "POST":
        message += f"Content-Length: {len(body or b'')}\r\n"
    message += "\r\n"
    if len(message) > 16384:
        raise ProbeTransportError("invalid_headers")
    return message.encode("latin1") + (body or b"")


class ServiceTransport:
    def __init__(self, base_url, *, timeout=8.0, max_bytes=1024 * 1024,
                 resolver=None, connector=None):
        if (not isinstance(timeout, (float, int)) or isinstance(timeout, bool)
                or not math.isfinite(timeout) or not 0 < timeout <= 60
                or type(max_bytes) is not int or not 1 <= max_bytes <= _MAX_BODY):
            raise ProbeTransportError("invalid_limits")
        self._scheme, self._host, self._port, self._authority, self._prefix = _base(base_url)
        self._timeout, self._max_bytes = float(timeout), max_bytes
        self._resolver, self._connector = resolver or _resolve_system, connector
        self._lock = threading.Lock()
        self._closed = False
        self._active = set()

    def request(self, method, path, headers=None, body=None):
        deadline = time.monotonic() + self._timeout
        route = self._prefix + _path(path)
        if len(route) > 4096:
            raise ProbeTransportError("invalid_path")
        message = _request_bytes(method, route, self._authority, headers, body)
        with self._lock:
            if self._closed:
                raise ProbeTransportError("transport_closed")
        family, address = _resolve(self._resolver, self._host, self._port, deadline)
        scope = _Deadline(deadline)
        with self._lock:
            if self._closed:
                scope.finish()
                raise ProbeTransportError("transport_closed")
            self._active.add(scope)
        error = None
        result = None
        try:
            if self._connector is None:
                connection = socket.socket(family, socket.SOCK_STREAM)
                scope.attach(connection)
                connection.settimeout(_remaining(deadline))
                connection.connect(address)
            else:
                connection = self._connector(family, address, _remaining(deadline))
                scope.attach(connection)
            if self._scheme == "https":
                context = ssl.create_default_context()
                connection = context.wrap_socket(connection, server_hostname=self._host,
                                                 do_handshake_on_connect=False)
                scope.attach(connection)
                connection.settimeout(_remaining(deadline))
                connection.do_handshake()
            connection.settimeout(_remaining(deadline))
            connection.sendall(message)
            result = _response(_Reader(connection, deadline), self._max_bytes)
            _remaining(deadline)
        except ProbeTransportError as caught:
            error = caught
        except TimeoutError:
            error = ProbeTransportError("request_timeout")
        except ssl.SSLError:
            error = ProbeTransportError("tls_failed")
        except Exception:
            error = ProbeTransportError("request_failed")
        finally:
            expired = scope.expired.is_set()
            scope.finish()
            with self._lock:
                self._active.discard(scope)
                closed = self._closed
        # Raise outside handlers, preventing raw socket/SSL exception chains.
        if closed:
            raise ProbeTransportError("transport_closed")
        if expired or time.monotonic() >= deadline:
            raise ProbeTransportError("request_timeout")
        if error is not None:
            raise error
        return result

    def close(self):
        with self._lock:
            self._closed = True
            active = tuple(self._active)
        for scope in active:
            scope.abort()

    def __enter__(self):
        with self._lock:
            if self._closed:
                raise ProbeTransportError("transport_closed")
        return self

    def __exit__(self, exc_type, exc, traceback):
        self.close()
