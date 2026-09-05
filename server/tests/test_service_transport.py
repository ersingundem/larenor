"""Synthetic loopback-only tests for the private-service transport boundary."""

from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
import socket
import socketserver
import ssl
import threading
import time

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID
import pytest

from larenor_server.services.transport import (
    ProbeResponse, ProbeTransportError, ServiceTransport,
)


@contextmanager
def origin(response, *, tls=None):
    requests = []

    class Handler(socketserver.BaseRequestHandler):
        def handle(self):
            connection = self.request
            try:
                connection.settimeout(1)
                if tls is not None:
                    connection = tls.wrap_socket(connection, server_side=True)
                reader = connection.makefile("rb")
                first = reader.readline(8192)
                fields = []
                while line := reader.readline(8192):
                    if line == b"\r\n":
                        break
                    fields.append(line.decode("latin1").rstrip("\r\n"))
                length = next((int(line.split(":", 1)[1]) for line in fields
                               if line.lower().startswith("content-length:")), 0)
                payload = reader.read(length)
                requests.append((first, fields, payload))
                pieces = response if isinstance(response, list) else [(0, response)]
                for delay, data in pieces:
                    time.sleep(delay)
                    connection.sendall(data)
                reader.close()
            except (OSError, ValueError):
                pass
            finally:
                connection.close()

    class Server(socketserver.ThreadingTCPServer):
        allow_reuse_address = True
        daemon_threads = True

    with Server(("127.0.0.1", 0), Handler) as server:
        thread = threading.Thread(target=server.serve_forever,
                                  kwargs={"poll_interval": 0.01}, daemon=True)
        thread.start()
        try:
            yield server.server_address[1], requests
        finally:
            server.shutdown()
            thread.join(timeout=1)


def loopback(host, port):
    return [(socket.AF_INET, socket.SOCK_STREAM, socket.IPPROTO_TCP, "",
             ("127.0.0.1", port))]


def test_pinned_dns_original_host_prefix_and_no_proxy_or_redirect(monkeypatch):
    reply = (b"HTTP/1.1 302 Found\r\nLocation: http://100.100.100.200/secret\r\n"
             b"Set-Cookie: one=secret-one\r\nSet-Cookie: two=secret-two\r\n"
             b"Content-Length: 4\r\n\r\nbody")
    resolutions = []
    connections = []

    def resolve(host, port):
        resolutions.append(host)
        return loopback(host, port) if len(resolutions) == 1 else [
            (socket.AF_INET, socket.SOCK_STREAM, 6, "", ("100.100.100.200", port))]

    def connect(family, address, timeout):
        connections.append(address)
        connection = socket.socket(family, socket.SOCK_STREAM)
        connection.settimeout(timeout)
        connection.connect(address)
        return connection

    with origin(b"HTTP/1.1 500 Error\r\nContent-Length: 0\r\n\r\n") as (proxy, trapped):
        monkeypatch.setenv("HTTP_PROXY", f"http://127.0.0.1:{proxy}")
        monkeypatch.setenv("http_proxy", f"http://127.0.0.1:{proxy}")
        monkeypatch.setenv("ALL_PROXY", f"http://127.0.0.1:{proxy}")
        monkeypatch.setenv("NO_PROXY", "")
        with origin(reply) as (port, requests):
            with ServiceTransport(f"http://service.test:{port}/prefix", resolver=resolve,
                                  connector=connect) as transport:
                result = transport.request("POST", "/api/status",
                                           headers={"Authorization": "Bearer private-secret"},
                                           body=b"private-body")
                assert result.status == 302 and result.body == b"body"
                assert [value for key, value in result.headers if key == "set-cookie"] == [
                    "one=secret-one", "two=secret-two"]
                assert resolutions == ["service.test"]
                assert connections == [("127.0.0.1", port)]
                assert len(requests) == 1 and not trapped
                assert requests[0][0] == b"POST /prefix/api/status HTTP/1.1\r\n"
                assert f"Host: service.test:{port}" in requests[0][1]
                assert "Accept-Encoding: identity" in requests[0][1]
                assert requests[0][2] == b"private-body"
                assert "secret" not in repr(result)
                with pytest.raises(ProbeTransportError):
                    transport.request("GET", "/api/status")
                assert len(connections) == 1


@pytest.mark.parametrize("address", [
    "0.0.0.0", "224.0.0.1", "169.254.169.254", "100.100.100.200", "::",
    "ff02::1", "fe80::1", "::ffff:169.254.169.254", "::ffff:100.100.100.200",
])
def test_unsafe_addresses_never_reach_a_connector(address):
    family = socket.AF_INET6 if ":" in address else socket.AF_INET
    calls = []
    resolve = lambda host, port: [(family, socket.SOCK_STREAM, 6, "",
                                   (address, port, 0, 0) if family == socket.AF_INET6
                                   else (address, port))]
    with ServiceTransport("http://service.test", resolver=resolve,
                          connector=lambda *args: calls.append(args)) as transport:
        with pytest.raises(ProbeTransportError):
            transport.request("GET", "/")
    assert not calls


def test_mixed_safe_unsafe_and_excessive_dns_answers_fail_before_connect():
    for answers in (loopback("x", 80) + [(socket.AF_INET, socket.SOCK_STREAM, 6, "",
                                        ("169.254.169.254", 80))], loopback("x", 80) * 17):
        calls = []
        with ServiceTransport("http://service.test", resolver=lambda *args: answers,
                              connector=lambda *args: calls.append(args)) as transport:
            with pytest.raises(ProbeTransportError):
                transport.request("GET", "/")
        assert not calls


@pytest.mark.parametrize("base", [
    "ftp://host", "http://user:private-secret@host", "http://host/?token=x",
    "http://host/#x", "http://host/a/../b", "http://host/a%2fb", "http://host/%0d",
    "http://host\\evil", "http://host:99999", "http://host:0", " http://host", "http://[fe80::1%eth0]",
])
def test_invalid_base_is_rejected_without_exposing_it(base):
    with pytest.raises(ProbeTransportError) as error:
        ServiceTransport(base)
    assert "private-secret" not in str(error.value)


@pytest.mark.parametrize("path", [
    "http://other/x", "//other/x", "/a/../b", "/a/./b", "/a%2fb", "/x?token=secret",
    "/a\\b", "/a#b", "/a\r\nx: y", "relative", "/a//b",
])
def test_invalid_request_path_is_rejected_before_resolution(path):
    calls = []
    with ServiceTransport("http://service.test", resolver=lambda *args: calls.append(args)) as transport:
        with pytest.raises(ProbeTransportError):
            transport.request("GET", path)
    assert not calls


@pytest.mark.parametrize("headers", [
    {"Authorization": "x\r\nInjected: yes"}, {"Bad\nName": "x"}, {"Cookie": "x" * 4097},
    {"Host": "evil"}, {"Transfer-Encoding": "chunked"}, {"Content-Length": "9"},
    {"Proxy-Authorization": "secret"}, [("Authorization", "a"), ("authorization", "b")],
    [(f"X-Header-{i}", "x") for i in range(65)],
    [(f"X-Header-{i}", "x" * 2000) for i in range(9)],
])
def test_invalid_secret_headers_do_not_reach_the_network(headers):
    calls = []
    with ServiceTransport("http://service.test", resolver=lambda *args: calls.append(args)) as transport:
        with pytest.raises(ProbeTransportError):
            transport.request("GET", "/", headers=headers)
    assert not calls


@pytest.mark.parametrize("wire", [
    b"HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\n0123456789",
    b"HTTP/1.1 200 OK\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\nx",
    b"HTTP/1.1 200 OK\r\nContent-Length: +1\r\n\r\nx",
    b"HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nx",
    b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Length: 1\r\n\r\nx",
    b"HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 1\r\n\r\nx",
    b"HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip\r\n\r\nx",
    b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nabcde\r\n0\r\n\r\n",
    b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nz\r\n",
    b"HTTP/1.1 200 OK\r\nInvalid header\r\n\r\n",
    b"HTTP/1.1 200 OK\r\n Folded: x\r\n\r\n",
    b"HTTP/1.1 200 OK\r\nX-Huge: " + b"x" * 33000 + b"\r\n\r\n",
    b"HTTP/1.1 200 OK\r\n\r\nabcde",
    b"HTTP/1.0 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n",
    b"HTTP/1.1 200 OK\r\n" + b"X-Header: x\r\n" * 101 + b"\r\n",
    b"HTTP/1.1 200 OK\r\n" + (b"X-Header: " + b"x" * 8000 + b"\r\n") * 5 + b"\r\n",
])
def test_oversized_or_malformed_responses_are_bounded_failures(wire):
    with origin(wire) as (port, _):
        with ServiceTransport(f"http://127.0.0.1:{port}", max_bytes=4) as transport:
            with pytest.raises(ProbeTransportError):
                transport.request("GET", "/")


@pytest.mark.parametrize("wire,status,body", [
    (b"HTTP/1.1 401 Unauthorized\r\nContent-Length: 4\r\n\r\noops", 401, b"oops"),
    (b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nab\r\n2\r\ncd\r\n0\r\n\r\n", 200, b"abcd"),
    (b"HTTP/1.0 500 Error\r\n\r\noops", 500, b"oops"),
    (b"HTTP/1.1 204 No Content\r\n\r\n", 204, b""),
])
def test_bounded_success_chunked_and_http_error_bodies_are_returned(wire, status, body):
    with origin(wire) as (port, _):
        with ServiceTransport(f"http://127.0.0.1:{port}", max_bytes=4) as transport:
            assert transport.request("GET", "/") == ProbeResponse(status, (
                (("content-length", "4"),) if b"Content-Length" in wire else
                (("transfer-encoding", "chunked"),) if b"Transfer-Encoding" in wire else ()
            ), body)


@pytest.mark.parametrize("pieces", [
    [(0.025, bytes([byte])) for byte in b"HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\nx"],
    [(0, b"HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\na"), (0.5, b"bcd")],
])
def test_one_deadline_stops_slow_headers_and_body(pieces):
    with origin(pieces) as (port, _):
        started = time.monotonic()
        with ServiceTransport(f"http://127.0.0.1:{port}", timeout=0.12) as transport:
            with pytest.raises(ProbeTransportError):
                transport.request("GET", "/")
        assert time.monotonic() - started < 0.6


def test_hanging_resolvers_are_bounded_to_four_daemon_workers():
    release = threading.Event()
    calls = []

    def resolve(host, port):
        calls.append(threading.current_thread())
        release.wait(2)
        return loopback(host, port)

    try:
        started = time.monotonic()
        for _ in range(5):
            with ServiceTransport("http://service.test", timeout=0.03, resolver=resolve) as transport:
                with pytest.raises(ProbeTransportError):
                    transport.request("GET", "/")
        assert len(calls) == 4 and all(thread.daemon for thread in calls)
        assert time.monotonic() - started < 0.7
    finally:
        release.set()
        for thread in calls:
            thread.join(timeout=1)


def test_raw_resolver_errors_and_response_secrets_are_not_represented():
    def broken(*args):
        raise OSError("private-secret must not escape")

    with ServiceTransport("http://service.test", resolver=broken) as transport:
        with pytest.raises(ProbeTransportError) as error:
            transport.request("GET", "/")
    assert "private-secret" not in repr(error.value)
    assert error.value.__context__ is None
    assert "private-secret" not in repr(ProbeResponse(200, (("cookie", "private-secret"),), b"private-secret"))
    with pytest.raises(ProbeTransportError):
        transport.request("GET", "/")


def test_tls_uses_original_sni_validates_certificate_and_hostname(tmp_path, monkeypatch):
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "service.test")])
    now = datetime.now(timezone.utc)
    cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name)
            .public_key(key.public_key()).serial_number(x509.random_serial_number())
            .not_valid_before(now - timedelta(minutes=1)).not_valid_after(now + timedelta(days=1))
            .add_extension(x509.SubjectAlternativeName([x509.DNSName("service.test")]), critical=False)
            .sign(key, hashes.SHA256()))
    cert_path, key_path = tmp_path / "cert.pem", tmp_path / "key.pem"
    cert_path.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    key_path.write_bytes(key.private_bytes(serialization.Encoding.PEM,
                                          serialization.PrivateFormat.PKCS8,
                                          serialization.NoEncryption()))
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert_path, key_path)
    names = []
    context.set_servername_callback(lambda sock, name, ctx: names.append(name))
    with origin(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok", tls=context) as (port, _):
        with ServiceTransport(f"https://service.test:{port}", resolver=loopback) as transport:
            with pytest.raises(ProbeTransportError):
                transport.request("GET", "/")
        original = ssl.create_default_context
        monkeypatch.setattr(ssl, "create_default_context", lambda: original(cafile=str(cert_path)))
        with ServiceTransport(f"https://service.test:{port}", resolver=loopback) as transport:
            assert transport.request("GET", "/").body == b"ok"
        with ServiceTransport(f"https://wrong.test:{port}", resolver=loopback) as transport:
            with pytest.raises(ProbeTransportError):
                transport.request("GET", "/")
    assert names == ["service.test", "service.test", "wrong.test"]


@pytest.mark.parametrize("address", ["192.168.4.20", "10.1.2.3", "8.8.8.8", "::1", "::ffff:10.1.2.3"])
def test_lan_public_localhost_and_safe_mapped_addresses_are_allowed(address):
    # The seam verifies the chosen numeric address, then substitutes loopback.
    # No test connects to a LAN/public address.
    family = socket.AF_INET6 if ":" in address else socket.AF_INET
    with origin(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n") as (port, _):
        calls = []

        def connect(chosen_family, chosen, timeout):
            calls.append((chosen_family, chosen[0]))
            connection = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            connection.settimeout(timeout)
            connection.connect(("127.0.0.1", port))
            return connection

        resolved = (address, port, 0, 0) if family == socket.AF_INET6 else (address, port)
        with ServiceTransport(f"http://service.test:{port}", connector=connect,
                              resolver=lambda *args: [(family, socket.SOCK_STREAM, 6, "", resolved)]) as transport:
            assert transport.request("GET", "/").status == 200
        assert len(calls) == 1 and calls[0][0] == family


def test_failed_connection_is_not_retried_and_has_no_raw_exception_chain():
    attempts = []

    def connect(*args):
        attempts.append(args)
        raise OSError("private-connect-secret")

    with ServiceTransport("http://service.test", connector=connect,
                          resolver=lambda host, port: loopback(host, port) * 2) as transport:
        with pytest.raises(ProbeTransportError) as error:
            transport.request("GET", "/")
    assert len(attempts) == 1
    assert "private-connect-secret" not in repr(error.value)
    assert error.value.__context__ is None


@pytest.mark.parametrize("method,body", [("DELETE", None), ([], None), ("GET", b"secret"),
                                        ("POST", "secret"), ("POST", b"x" * (1024 * 1024 + 1))])
def test_invalid_method_and_body_fail_before_resolution(method, body):
    calls = []
    with ServiceTransport("http://service.test", resolver=lambda *args: calls.append(args)) as transport:
        with pytest.raises(ProbeTransportError):
            transport.request(method, "/", body=body)
    assert not calls


def test_close_aborts_an_inflight_socket_without_waiting_for_its_deadline():
    with origin([(0.5, b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")]) as (port, requests):
        transport = ServiceTransport(f"http://127.0.0.1:{port}", timeout=2)
        results = []

        def run():
            try:
                transport.request("GET", "/")
            except ProbeTransportError as error:
                results.append(error.code)

        thread = threading.Thread(target=run, daemon=True)
        thread.start()
        limit = time.monotonic() + 1
        while not requests and time.monotonic() < limit:
            time.sleep(0.005)
        assert requests
        transport.close()
        thread.join(timeout=0.3)
        assert not thread.is_alive()
        assert results == ["transport_closed"]


def test_watchdog_owns_the_socket_while_connect_is_in_progress(monkeypatch):
    import larenor_server.services.transport as module

    stopped = threading.Event()

    class PendingSocket:
        def settimeout(self, timeout):
            assert 0 < timeout <= 0.08

        def connect(self, address):
            assert address == ("127.0.0.1", 80)
            assert stopped.wait(0.5)
            raise OSError("synthetic connection stopped")

        def shutdown(self, how):
            stopped.set()

        def close(self):
            stopped.set()

    monkeypatch.setattr(module.socket, "socket", lambda *args: PendingSocket())
    started = time.monotonic()
    with ServiceTransport("http://service.test", timeout=0.08, resolver=loopback) as transport:
        with pytest.raises(ProbeTransportError, match="request_timeout"):
            transport.request("GET", "/")
    assert time.monotonic() - started < 0.4


@pytest.mark.parametrize("prefix,expected", [("/ö", "/%C3%B6"), ("/a//b", "/a//b"), ("//a", "//a")])
def test_saved_canonical_base_prefix_is_preserved_on_the_wire(prefix, expected):
    from larenor_server.services.models import CreateServiceRequest

    with origin(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n") as (port, requests):
        stored = CreateServiceRequest(name="Fixture", kind="home_assistant", credentials={},
                                      baseUrl=f"http://fixture.test:{port}" + prefix)
        with ServiceTransport(stored.baseUrl, resolver=loopback) as transport:
            assert transport.request("GET", "/api/config").status == 200
        assert requests[0][0] == f"GET {expected}/api/config HTTP/1.1\r\n".encode("ascii")


@pytest.mark.parametrize("literal", [False, True])
def test_aws_ipv6_metadata_is_blocked_before_connecting(literal):
    attempts = []
    target = "http://[fd00:ec2::254]" if literal else "http://fixture.test"
    def resolver(host, port):
        return [(socket.AF_INET6, socket.SOCK_STREAM, socket.IPPROTO_TCP, "", ("fd00:ec2::254", port, 0, 0))]
    with ServiceTransport(target, resolver=resolver, connector=lambda *args: attempts.append(args)) as transport:
        with pytest.raises(ProbeTransportError, match="address_blocked"):
            transport.request("GET", "/api/config")
    assert attempts == []
