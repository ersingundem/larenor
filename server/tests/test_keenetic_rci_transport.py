import base64
import json
import socket
import socketserver
import threading
import time
from contextlib import contextmanager

import pytest

from larenor_server.keenetic_commands.rci_adapter import (
    PackagedRciCommandAdapter,
    RciCommand,
)
from larenor_server.keenetic_commands.rci_transport import (
    KeeneticRciTransport,
    keenetic_lan_address,
)
from larenor_server.keenetic_commands.service import KeeneticEffectError
from larenor_server.keenetic_commands.worker_models import KeeneticWorkerCommand
from larenor_server.services.service import ServiceConnection
from larenor_server.services.transport import ProbeResponse, ProbeTransportError

from conftest import auth, ready
from test_keenetic_command_authority import Actor, request, state


SECRET = "Synthetic-router-secret-not-for-production"


def command(action="guest_wifi_enable", *, target=None):
    return RciCommand(
        operation={
            "guest_wifi_enable": "guest_wifi_enable",
            "guest_wifi_disable": "guest_wifi_disable",
            "client_internet_pause": "client_access_pause",
            "client_internet_resume": "client_access_resume",
            "wan_reconnect": "wan_reconnect",
        }[action],
        expectedState=target or state(target="WifiMaster0/AccessPoint1"),
    )


def successful_body(current, value):
    if current.targetKind == "client":
        observed = {"ip": {"hotspot": {"host": [{
            "mac": current.targetId,
            "access": "deny" if value == "paused" else "permit",
            "revision": current.stateRevision + 1,
        }]}}}
    else:
        observed = {"interface": {current.targetId: {
            "id": current.targetId,
            "up": "yes" if value in {"enabled", "online"} else "no",
            "connected": "yes" if value == "online" else None,
            "revision": current.stateRevision + 1,
        }}}
    return json.dumps([
        {"status": "ok"},
        {"status": "ok"},
        {"version": {
            "release": current.firmwareVersion,
            "revision": current.firmwareRevision,
        }},
        observed,
    ], separators=(",", ":")).encode()


class Services:
    def __init__(self, connection):
        self.connection_value = connection
        self.calls = []

    def connection(self, actor, service_id, expected_revision):
        self.calls.append((actor.id, service_id, expected_revision))
        return self.connection_value


class ScriptTransport:
    def __init__(self, responses, calls, base_url, options):
        self.responses = responses
        self.calls = calls
        self.calls.append(("open", base_url, options))

    def request(self, method, path, headers=None, body=None, **options):
        self.calls.append((method, path, dict(headers or {}), body))
        before_send = options.get("before_send")
        if before_send is not None:
            before_send()
        item = self.responses.pop(0)
        if isinstance(item, Exception):
            raise item
        return item

    def close(self):
        self.calls.append(("close",))


class ScriptFactory:
    def __init__(self, responses):
        self.responses = list(responses)
        self.calls = []

    def __call__(self, base_url, **options):
        return ScriptTransport(self.responses, self.calls, base_url, options)


def binding(*, base_url="http://router.test:79", revision=6, credentials=None):
    return ServiceConnection(
        id="5" * 32,
        name="Home router",
        kind="keenetic",
        base_url=base_url,
        revision=revision,
        credentials=credentials or {"username": "fixture-admin", "password": SECRET},
    )


def challenge(scheme="Basic"):
    value = (
        'Basic realm="Keenetic"'
        if scheme == "Basic"
        else 'Digest realm="Keenetic", nonce="fixture-nonce", algorithm=SHA-256, qop="auth"'
    )
    return ProbeResponse(401, (("www-authenticate", value),), b"")


def ok(current, value):
    return ProbeResponse(200, (("content-type", "application/json"),), successful_body(current, value))


def run(services, factory, rci, **options):
    transport = KeeneticRciTransport(
        services,
        Actor(),
        transport_factory=factory,
        **options,
    )
    return transport(rci, deadline=time.monotonic() + 1, cancelled=lambda: False)


def test_binding_is_loaded_at_dispatch_and_basic_secret_never_crosses_models():
    current = state(target="WifiMaster0/AccessPoint1")
    services = Services(binding())
    factory = ScriptFactory([challenge(), ok(current, "enabled")])
    rci = command(target=current)

    observed = run(services, factory, rci)

    assert services.calls == [(Actor().id, current.serviceId, current.serviceRevision)]
    assert observed == current.model_copy(update={"value": "enabled", "stateRevision": 12})
    post = [entry for entry in factory.calls if entry[0] == "POST"]
    assert len(post) == 1
    expected = "Basic " + base64.b64encode(f"fixture-admin:{SECRET}".encode()).decode()
    assert post[0][2]["Authorization"] == expected
    public = repr(rci) + repr(observed) + repr(KeeneticRciTransport(services, Actor()))
    assert SECRET not in public and "router.test" not in public


def test_real_service_store_decrypts_binding_only_at_dispatch_and_public_api_is_redacted(server):
    app, client, _, _ = server
    pair = ready(server)
    saved = client.post("/api/v1/admin/services", headers=auth(pair), json={
        "name": "Home router",
        "kind": "keenetic",
        "baseUrl": "http://192.168.1.1:79",
        "credentials": {"username": "fixture-admin", "password": SECRET},
    })
    assert saved.status_code == 201
    public = saved.json()["service"]
    assert public["credentialKeys"] == ["password", "username"]
    assert SECRET not in json.dumps(public)
    with app.state.core.db.connection() as connection:
        assert SECRET not in "\n".join(connection.iterdump())
    actor = app.state.core.auth.authenticate(pair["accessToken"])
    current = state(target="WifiMaster0/AccessPoint1").model_copy(update={
        "serviceId": public["id"],
        "serviceRevision": public["revision"],
    })
    factory = ScriptFactory([challenge(), ok(current, "enabled")])
    observed = KeeneticRciTransport(
        app.state.core.services,
        actor,
        transport_factory=factory,
    )(command(target=current), deadline=time.monotonic() + 1, cancelled=lambda: False)
    assert observed.value == "enabled"
    assert SECRET not in repr(observed) + repr(factory.responses)


def test_digest_is_one_mutation_request_without_retry_and_token_is_redacted():
    current = state(target="WifiMaster0/AccessPoint1")
    services = Services(binding())
    factory = ScriptFactory([challenge("Digest"), ok(current, "enabled")])
    observed = run(
        services,
        factory,
        command(target=current),
        cnonce_factory=lambda: "0123456789abcdef",
    )
    assert observed.value == "enabled"
    posts = [entry for entry in factory.calls if entry[0] == "POST"]
    assert len(posts) == 1
    authorization = posts[0][2]["Authorization"]
    assert authorization.startswith("Digest ")
    assert 'uri="/rci/"' in authorization and "response=" in authorization
    assert SECRET not in authorization
    assert SECRET not in repr(factory.responses)


@pytest.mark.parametrize(
    ("action", "kind", "value", "target_id", "expected_fragments"),
    [
        ("guest_wifi_enable", "guest_wifi", "disabled", "WifiMaster0/AccessPoint1",
         ["interface WifiMaster0/AccessPoint1 up", "system configuration save"]),
        ("guest_wifi_disable", "guest_wifi", "enabled", "WifiMaster0/AccessPoint1",
         ["interface WifiMaster0/AccessPoint1 down", "system configuration save"]),
        ("client_internet_pause", "client", "allowed", "AA:BB:CC:DD:EE:FF",
         ["ip hotspot host AA:BB:CC:DD:EE:FF deny", "system configuration save"]),
        ("client_internet_resume", "client", "paused", "AA:BB:CC:DD:EE:FF",
         ["ip hotspot host AA:BB:CC:DD:EE:FF permit", "system configuration save"]),
        ("wan_reconnect", "wan", "online", "ISP",
         ["interface ISP no connect", "interface ISP connect"]),
    ],
)
def test_only_fixed_target_typed_rci_batches_can_be_dispatched(
    action, kind, value, target_id, expected_fragments
):
    current = state(kind=kind, value=value, target=target_id)
    result_value = {
        "guest_wifi_enable": "enabled",
        "guest_wifi_disable": "disabled",
        "client_internet_pause": "paused",
        "client_internet_resume": "allowed",
        "wan_reconnect": "online",
    }[action]
    factory = ScriptFactory([challenge(), ok(current, result_value)])
    run(Services(binding()), factory, command(action, target=current))
    body = json.loads(next(entry[3] for entry in factory.calls if entry[0] == "POST"))
    assert [item["parse"] for item in body[:2]] == expected_fragments
    assert body[2] == {"show": {"version": {}}}
    assert "show" in body[3]
    wire = command(action, target=current).model_dump(mode="json")
    assert set(wire) == {"operation", "expectedState"}
    assert all(key not in json.dumps(wire).lower() for key in ("endpoint", "password", "command"))


@pytest.mark.parametrize(
    "bad_target",
    ["WifiMaster0/AccessPoint1 show running-config", "AA:BB:CC:DD:EE:FF; system reboot", "ISP && reboot"],
)
def test_target_injection_is_rejected_before_service_or_network(bad_target):
    current = state(target=bad_target)
    services = Services(binding())
    factory = ScriptFactory([])
    with pytest.raises(KeeneticEffectError, match="^keenetic_effect_rejected$"):
        run(services, factory, command(target=current))
    assert services.calls == [] and factory.calls == []


@pytest.mark.parametrize(
    ("address", "allowed"),
    [
        ("192.168.1.1", True),
        ("10.0.0.1", True),
        ("172.31.255.254", True),
        ("fd12:3456::1", True),
        ("127.0.0.1", False),
        ("169.254.1.1", False),
        ("100.64.0.1", False),
        ("8.8.8.8", False),
        ("::1", False),
        ("fe80::1", False),
    ],
)
def test_endpoint_resolution_is_lan_only_and_loopback_needs_fixture_flag(address, allowed):
    if allowed:
        assert keenetic_lan_address(address) is None
    else:
        with pytest.raises(ProbeTransportError, match="^address_blocked$"):
            keenetic_lan_address(address)
    if address == "127.0.0.1":
        assert keenetic_lan_address(address, allow_loopback_fixture=True) is None


@pytest.mark.parametrize(
    "connection",
    [
        binding(revision=7),
        ServiceConnection("5" * 32, "Wrong", "proxmox", "http://router.test", 6,
                          {"username": "u", "password": SECRET}),
        binding(credentials={"token": SECRET}),
    ],
)
def test_stale_or_invalid_encrypted_binding_fails_before_transport(connection):
    services = Services(connection)
    factory = ScriptFactory([])
    with pytest.raises(KeeneticEffectError, match="^keenetic_effect_unavailable$") as caught:
        run(services, factory, command())
    assert caught.value.uncertain is False and factory.calls == []
    assert SECRET not in str(caught.value)


@pytest.mark.parametrize("base_url", [
    "ftp://192.168.1.1", "http://user:secret@192.168.1.1",
    "http://192.168.1.1/rci", "https://192.168.1.1/?next=x",
])
def test_non_root_http_https_service_endpoint_never_reaches_transport(base_url):
    services = Services(binding(base_url=base_url))
    factory = ScriptFactory([])
    with pytest.raises(KeeneticEffectError, match="^keenetic_effect_unavailable$"):
        run(services, factory, command())
    assert factory.calls == []


@pytest.mark.parametrize(
    "response",
    [
        ProbeResponse(302, (("location", "http://192.168.1.2/rci/"),), b""),
        ProbeResponse(401, (("www-authenticate", 'Basic realm="other"'),), b""),
        ProbeResponse(200, (), b"x" * (128 * 1024 + 1)),
        ProbeTransportError("request_timeout"),
    ],
)
def test_redirect_bad_auth_oversize_and_timeout_are_fail_closed_without_retry(response):
    services = Services(binding())
    factory = ScriptFactory([response])
    with pytest.raises(KeeneticEffectError):
        run(services, factory, command())
    requests = [entry for entry in factory.calls if entry[0] in {"GET", "POST"}]
    assert len(requests) == 1


def test_firmware_or_state_revision_drift_after_dispatch_is_unknown_and_redacted():
    current = state(target="WifiMaster0/AccessPoint1")
    for body in (
        successful_body(current.model_copy(update={"firmwareVersion": "5.0.5"}), "enabled"),
        successful_body(current.model_copy(update={"stateRevision": 12}), "enabled"),
    ):
        factory = ScriptFactory([challenge(), ProbeResponse(200, (), body)])
        with pytest.raises(KeeneticEffectError, match="^keenetic_result_unknown$") as caught:
            run(Services(binding()), factory, command(target=current))
        assert caught.value.uncertain is True
        assert SECRET not in str(caught.value)


@contextmanager
def loopback_origin(responses):
    requests = []

    class Handler(socketserver.BaseRequestHandler):
        def handle(self):
            reader = self.request.makefile("rb")
            first = reader.readline(8192)
            headers = []
            while (line := reader.readline(8192)) != b"\r\n":
                headers.append(line.decode("latin1").rstrip())
            length = next((int(line.split(":", 1)[1]) for line in headers
                           if line.lower().startswith("content-length:")), 0)
            requests.append((first, headers, reader.read(length)))
            self.request.sendall(responses.pop(0))

    class Server(socketserver.ThreadingTCPServer):
        allow_reuse_address = True
        daemon_threads = True

    with Server(("127.0.0.1", 0), Handler) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            yield server.server_address[1], requests
        finally:
            server.shutdown()
            thread.join(1)


def test_owned_loopback_fixture_uses_pinned_dns_once_and_real_bounded_http_socket():
    current = state(target="WifiMaster0/AccessPoint1")
    challenge_wire = (
        b'HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm="Keenetic"\r\n'
        b"Content-Length: 0\r\n\r\n"
    )
    body = successful_body(current, "enabled")
    ok_wire = (b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: "
               + str(len(body)).encode() + b"\r\n\r\n" + body)
    with loopback_origin([challenge_wire, ok_wire]) as (port, requests):
        resolutions = []

        def resolve(host, resolved_port):
            resolutions.append((host, resolved_port))
            return [(socket.AF_INET, socket.SOCK_STREAM, socket.IPPROTO_TCP, "",
                     ("127.0.0.1", resolved_port))]

        service = binding(base_url=f"http://router.test:{port}")
        observed = run(
            Services(service),
            __import__("larenor_server.services.transport", fromlist=["ServiceTransport"]).ServiceTransport,
            command(target=current),
            resolver=resolve,
            allow_loopback_fixture=True,
        )
        assert observed.value == "enabled"
        assert len(resolutions) == 1
        assert len(requests) == 2 and requests[1][0] == b"POST /rci/ HTTP/1.1\r\n"


@pytest.mark.parametrize(
    ("action", "operation"),
    [
        ("guest_wifi_enable", "guest_wifi_enable"),
        ("guest_wifi_disable", "guest_wifi_disable"),
        ("client_internet_pause", "client_access_pause"),
        ("client_internet_resume", "client_access_resume"),
        ("wan_reconnect", "wan_reconnect"),
    ],
)
def test_executor_maps_only_packaged_operations(action, operation):
    current = state(
        kind={
            "guest_wifi_enable": "guest_wifi",
            "guest_wifi_disable": "guest_wifi",
            "client_internet_pause": "client",
            "client_internet_resume": "client",
            "wan_reconnect": "wan",
        }[action],
        value={
            "guest_wifi_enable": "disabled",
            "guest_wifi_disable": "enabled",
            "client_internet_pause": "allowed",
            "client_internet_resume": "paused",
            "wan_reconnect": "online",
        }[action],
        target={
            "guest_wifi_enable": "WifiMaster0/AccessPoint1",
            "guest_wifi_disable": "WifiMaster0/AccessPoint1",
            "client_internet_pause": "AA:BB:CC:DD:EE:FF",
            "client_internet_resume": "AA:BB:CC:DD:EE:FF",
            "wan_reconnect": "ISP",
        }[action],
    )
    worker = KeeneticWorkerCommand.from_request(
        request(action, current=current),
        timeout_ms=500,
    )
    calls = []

    def transport(rci, *, deadline, cancelled):
        calls.append(rci)
        result = {
            "guest_wifi_enable": "enabled",
            "guest_wifi_disable": "disabled",
            "client_internet_pause": "paused",
            "client_internet_resume": "allowed",
            "wan_reconnect": "online",
        }[action]
        return current.model_copy(
            update={"value": result, "stateRevision": current.stateRevision + 1}
        )

    result = PackagedRciCommandAdapter(transport).execute(
        worker, deadline=time.monotonic() + 1, cancelled=lambda: False
    )
    assert calls == [RciCommand(operation=operation, expectedState=current)]
    assert result.status == "succeeded"


def test_default_executor_is_unavailable_without_dns_or_socket(monkeypatch):
    monkeypatch.setattr(socket, "socket", lambda *_args, **_kwargs: pytest.fail("socket opened"))
    monkeypatch.setattr(socket, "getaddrinfo", lambda *_args, **_kwargs: pytest.fail("DNS used"))
    worker = KeeneticWorkerCommand.from_request(
        request(), timeout_ms=500
    )
    with pytest.raises(KeeneticEffectError, match="^keenetic_effect_unavailable$") as caught:
        PackagedRciCommandAdapter().execute(
            worker, deadline=time.monotonic() + 1, cancelled=lambda: False
        )
    assert caught.value.uncertain is False


def test_post_timeout_is_uncertain_and_never_retried():
    current = state(target="WifiMaster0/AccessPoint1")
    factory = ScriptFactory([challenge(), ProbeTransportError("request_timeout")])
    with pytest.raises(KeeneticEffectError, match="^keenetic_effect_timeout$") as caught:
        run(Services(binding()), factory, command(target=current))
    requests = [entry for entry in factory.calls if entry[0] in {"GET", "POST"}]
    assert caught.value.uncertain is True
    assert [entry[0] for entry in requests] == ["GET", "POST"]


def test_oversized_post_response_is_unknown_without_retry():
    current = state(target="WifiMaster0/AccessPoint1")
    factory = ScriptFactory([
        challenge(),
        ProbeResponse(200, (), b"x" * (128 * 1024 + 1)),
    ])
    with pytest.raises(KeeneticEffectError, match="^keenetic_result_unknown$") as caught:
        run(Services(binding()), factory, command(target=current))
    assert caught.value.uncertain is True
    assert [entry[0] for entry in factory.calls if entry[0] in {"GET", "POST"}] == [
        "GET", "POST"
    ]


def test_tls_and_auth_failures_never_disclose_service_secret():
    for response in (
        ProbeTransportError("tls_verification_failed"),
        ProbeResponse(401, (("www-authenticate", 'Basic realm="wrong"'),), b""),
    ):
        factory = ScriptFactory([response])
        with pytest.raises(KeeneticEffectError) as caught:
            run(
                Services(binding(base_url="https://router.test")),
                factory,
                command(),
            )
        public = str(caught.value) + repr(caught.value) + repr(factory.responses)
        assert SECRET not in public
        assert len([entry for entry in factory.calls if entry[0] in {"GET", "POST"}]) == 1
