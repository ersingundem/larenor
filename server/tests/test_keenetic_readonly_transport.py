"""Synthetic NDM fixtures for the Core Keenetic read-only transport."""

import json
import socket

import pytest

from larenor_server.errors import ApiError
from larenor_server.keenetic_resources.transport import (
    KeeneticReadOnlyTransport,
    _PinnedLanResolver,
    firmware_capabilities,
)
from larenor_server.services.service import ServiceConnection
from larenor_server.services.transport import ProbeResponse, ProbeTransportError


SECRET = "fixture-router-password"
CONNECTION = ServiceConnection(
    id="1" * 32,
    revision=7,
    name="Fixture router",
    kind="keenetic",
    base_url="http://router.test/prefix",
    credentials={"username": "admin", "password": SECRET},
)


def response(value=b"", status=200, headers=()):
    body = value if isinstance(value, bytes) else json.dumps(value, separators=(",", ":")).encode()
    return ProbeResponse(status, tuple(headers), body)


def challenge():
    return response(b"", 401, (
        ("X-NDM-Realm", "Keenetic"),
        ("X-NDM-Challenge", "SYNTHETICCHALLENGE"),
        ("WWW-Authenticate", 'x-ndw2-interactive realm="Keenetic" challenge="SYNTHETICCHALLENGE" '
         'session_id="preauth123" session_cookie="SESSION"'),
        ("Set-Cookie", "SESSION=preauth123; Path=/prefix; HttpOnly"),
    ))


def batch(*, release="5.0.4", online="yes", duplicate_interface=False):
    interfaces = {
        "GigabitEthernet0": {
            "description": "Internet",
            "type": "GigabitEthernet",
            "state": "up",
            "link": "up",
            "connected": "yes",
            "address": "93.184.216.34",
        },
        "Bridge0": {
            "description": "Home network",
            "type": "Bridge",
            "state": "up",
            "link": "up",
            "connected": "yes",
            "address": "192.168.1.1",
        },
        "WifiMaster0/AccessPoint1": {
            "description": "Guest Wi-Fi",
            "type": "AccessPoint",
            "state": "down",
            "link": "down",
            "connected": "no",
            "guest": "yes",
            "ssid": "Larenor Guest",
            "band": "5",
            "channel": 44,
            "signal": -61,
            "password": SECRET,
        },
    }
    if duplicate_interface:
        interfaces = [{"id": "Bridge0", **interfaces["Bridge0"]},
                      {"id": "Bridge0", **interfaces["Bridge0"]}]
    return response([
        {"version": {"title": release, "model": "Giga", "hw_id": "KN-1011"}},
        {"system": {"cpuload": 8, "memory": "100/400", "uptime": "90061"}},
        {"interface": interfaces},
        {"internet": {"status": {"internet": online, "gateway": {
            "interface": "GigabitEthernet0", "address": "192.0.2.1"}}}},
        {"ip": {"hotspot": {"host": [{
            "mac": "02:00:00:00:00:01", "name": "Tablet", "ip": "192.168.1.20",
            "via": "Bridge0", "active": True, "registered": True,
            "access": "permit",
            "band": "5",
            "signal": -58,
        }]}}},
    ])


def stats(rx=1200, tx=500, timestamp=100):
    return response({"interface": [
        {"name": "GigabitEthernet0", "stat": {"rxbytes": rx, "txbytes": tx, "timestamp": timestamp}},
        {"name": "Bridge0", "stat": {"rxbytes": 800, "txbytes": 300, "timestamp": timestamp}},
        {"name": "WifiMaster0/AccessPoint1", "stat": {
            "rxbytes": 0, "txbytes": 0, "timestamp": timestamp,
        }},
    ]})


class ScriptedFactory:
    def __init__(self, *replies):
        self.replies = list(replies)
        self.calls = []
        self.instances = []

    def __call__(self, base_url, **options):
        owner = self

        class Transport:
            closed = False

            def request(self, method, path, headers=None, body=None, **kwargs):
                owner.calls.append((base_url, method, path, dict(headers or {}), body, options, kwargs))
                callback = kwargs.get("before_send")
                if callback is not None:
                    callback()
                item = owner.replies.pop(0)
                if isinstance(item, Exception):
                    raise item
                return item

            def close(self):
                self.closed = True

        result = Transport()
        self.instances.append(result)
        return result


def exchange(*, release="5.0.4", stat=stats(), batch_response=None):
    return [challenge(), response(b"", headers=(("Set-Cookie", "SESSION=ready456; Path=/prefix"),)),
            batch(release=release) if batch_response is None else batch_response, stat]


def error_code(call):
    with pytest.raises(ApiError) as caught:
        call()
    return caught.value.code


def test_authenticated_fixed_show_contract_maps_full_typed_snapshot_and_rates():
    clock = [10.0]
    fake = ScriptedFactory(*exchange(), *exchange(stat=stats(1700, 700, 105)))
    guards = []
    reader = KeeneticReadOnlyTransport(factory=fake, clock=lambda: clock[0])

    first = reader.read(CONNECTION, lambda: guards.append("checked"))
    clock[0] = 15.0
    second = reader.read(CONNECTION, lambda: guards.append("checked"))

    assert first.status.model_dump(mode="json") == {
        "online": True, "publicIp": "93.184.216.34", "uptimeSeconds": 90061,
        "firmware": "5.0.4", "cpuPercent": 8.0, "memoryPercent": 25.0,
        "firmwareRevision": first.status.firmwareRevision,
        "statusRevision": first.status.statusRevision,
    }
    assert first.status.firmwareRevision > 0 and first.status.statusRevision > 0
    assert first.status.statusRevision == second.status.statusRevision
    assert [item.id for item in first.interfaces] == [
        "GigabitEthernet0", "Bridge0", "WifiMaster0/AccessPoint1",
    ]
    assert first.interfaces[0].kind == "wan" and first.interfaces[1].kind == "lan"
    assert first.interfaces[2].guest is True and first.interfaces[2].online is False
    assert first.interfaces[2].ssid == "Larenor Guest"
    assert (first.interfaces[2].band, first.interfaces[2].channel,
            first.interfaces[2].signalDbm) == ("5", 44, -61)
    assert first.traffic.model_dump() == {
        "rxBytes": 1200, "txBytes": 500, "downloadBps": None, "uploadBps": None,
    }
    assert second.traffic.downloadBps == 100 and second.traffic.uploadBps == 40
    assert second.hosts[0].model_dump(mode="json") == {
        "id": "02:00:00:00:00:01", "name": "Tablet", "ipAddress": "192.168.1.20",
        "macAddress": "02:00:00:00:00:01", "interfaceId": "Bridge0",
        "online": True, "registered": True, "internetAccess": "allowed",
        "band": "5", "signalDbm": -58,
    }
    assert [(method, path) for _, method, path, *_ in fake.calls] == [
        ("GET", "/auth"), ("POST", "/auth"), ("POST", "/rci/show"),
        ("POST", "/rci/show"),
    ] * 2
    assert json.loads(fake.calls[2][4]) == [
        {"version": {}}, {"system": {}}, {"interface": {}},
        {"internet": {"status": {}}}, {"ip": {"hotspot": {}}},
    ]
    assert json.loads(fake.calls[3][4]) == {"interface": [
        {"name": "GigabitEthernet0", "stat": {}}, {"name": "Bridge0", "stat": {}},
        {"name": "WifiMaster0/AccessPoint1", "stat": {}},
    ]}
    assert all(item.closed for item in fake.instances) and len(guards) >= len(fake.calls) * 2
    assert all(
        0 < call[5]["timeout"] <= 4
        and call[5]["max_bytes"] == 256 * 1024
        and callable(call[5]["address_guard"])
        for call in fake.calls
    )
    assert SECRET not in repr(first) + repr(second) + repr(fake.calls)
    assert SECRET not in first.model_dump_json()


def test_offline_is_typed_and_command_state_change_has_a_new_revision():
    live = KeeneticReadOnlyTransport(factory=ScriptedFactory(*exchange())).read(
        CONNECTION, lambda: None
    )
    offline = KeeneticReadOnlyTransport(factory=ScriptedFactory(
        *exchange(batch_response=batch(online="no"))
    )).read(CONNECTION, lambda: None)
    assert live.status.online is True and offline.status.online is False
    assert live.status.statusRevision != offline.status.statusRevision


def test_guard_cancellation_after_auth_stops_before_rci_and_redacts_secret():
    fake = ScriptedFactory(*exchange())
    calls = 0

    def guard():
        nonlocal calls
        calls += 1
        if calls >= 4:
            raise ApiError("request_timeout", 408)

    with pytest.raises(ApiError, match="request_timeout") as caught:
        KeeneticReadOnlyTransport(factory=fake).read(CONNECTION, guard)
    assert len(fake.calls) == 2
    assert SECRET not in repr(caught.value) + repr(fake.calls)


def test_expired_authority_never_resolves_or_opens_a_transport():
    fake = ScriptedFactory(*exchange())
    with pytest.raises(ApiError, match="forbidden"):
        KeeneticReadOnlyTransport(factory=fake).read(
            CONNECTION,
            lambda: (_ for _ in ()).throw(ApiError("forbidden", 403)),
        )
    assert fake.calls == []


def test_closed_reader_never_resolves_or_opens_a_transport():
    fake = ScriptedFactory(*exchange())
    reader = KeeneticReadOnlyTransport(factory=fake)
    reader.close()
    assert error_code(lambda: reader.read(CONNECTION, lambda: None)) == (
        "keenetic_upstream_unavailable"
    )
    assert fake.calls == []


@pytest.mark.parametrize("release,family", [
    ("2.12.A.1.0-1", "ndms-2"), ("3.9.6", "keeneticos-3"),
    ("4.3.6", "keeneticos-4"), ("5.0.4", "keeneticos-5"),
])
def test_firmware_capability_matrix_is_explicit(release, family):
    capabilities = firmware_capabilities(release)
    assert capabilities.family == family
    assert capabilities.commands == ("version", "system", "interface", "internet.status", "ip.hotspot", "interface.stat")


@pytest.mark.parametrize("release", [
    "2.12.A.1.0-1", "3.9.6", "4.3.6", "5.0.4",
])
def test_each_supported_firmware_family_produces_provider_metadata(release):
    value = KeeneticReadOnlyTransport(
        factory=ScriptedFactory(*exchange(release=release))
    ).read(CONNECTION, lambda: None)
    assert value.status.firmware == release
    assert value.status.firmwareRevision > 0
    assert value.status.statusRevision > 0
    assert value.interfaces[2].guest is True
    assert value.hosts[0].internetAccess == "allowed"


@pytest.mark.parametrize("release", ["1.11", "6.0.0", "dev", "5", "5.0\nsecret"])
def test_unknown_firmware_fails_closed(release):
    assert error_code(lambda: KeeneticReadOnlyTransport(
        factory=ScriptedFactory(*exchange(release=release))).read(CONNECTION, lambda: None)
    ) == "keenetic_upstream_unsupported"


@pytest.mark.parametrize("reply_value,expected", [
    (response(b"", 302, (("Location", "http://other.test"),)), "keenetic_upstream_unsupported"),
    (response(b"", 403), "keenetic_upstream_denied"),
    (ProbeTransportError("request_timeout"), "request_timeout"),
    (ProbeTransportError("address_blocked"), "keenetic_upstream_denied"),
    (ProbeTransportError("response_too_large"), "keenetic_upstream_unsupported"),
])
def test_redirect_auth_denial_timeout_oversize_and_peer_failure_are_static(reply_value, expected):
    fake = ScriptedFactory(reply_value)
    assert error_code(lambda: KeeneticReadOnlyTransport(factory=fake).read(CONNECTION, lambda: None)) == expected
    assert len(fake.calls) == 1


@pytest.mark.parametrize("body", [
    b'{"duplicate":1,"duplicate":2}', b'{"number":NaN}', b'[]', b'{' + b'"x":1,' * 20000 + b'"z":1}',
])
def test_duplicate_nan_wrong_shape_and_injected_oversize_bodies_fail_closed(body):
    fake = ScriptedFactory(challenge(), response(b"", headers=(("Set-Cookie", "SESSION=ready456; Path=/prefix"),)), response(body))
    assert error_code(lambda: KeeneticReadOnlyTransport(factory=fake).read(CONNECTION, lambda: None)) == "keenetic_upstream_unsupported"
    assert len(fake.calls) == 3


def test_duplicate_interface_and_stale_router_sample_fail_closed():
    duplicate = ScriptedFactory(*exchange(batch_response=batch(duplicate_interface=True)))
    assert error_code(lambda: KeeneticReadOnlyTransport(factory=duplicate).read(CONNECTION, lambda: None)) == "keenetic_upstream_unsupported"

    clock = [1.0]
    stale = ScriptedFactory(*exchange(), *exchange(stat=stats(1300, 600, 100)))
    reader = KeeneticReadOnlyTransport(factory=stale, clock=lambda: clock[0])
    reader.read(CONNECTION, lambda: None)
    clock[0] = 2.0
    assert error_code(lambda: reader.read(CONNECTION, lambda: None)) == "keenetic_upstream_unsupported"


def test_dns_rebinding_duplicate_answers_and_non_lan_targets_are_denied():
    answers = [[(socket.AF_INET, socket.SOCK_STREAM, socket.IPPROTO_TCP, "", ("192.168.1.1", 80))],
               [(socket.AF_INET, socket.SOCK_STREAM, socket.IPPROTO_TCP, "", ("192.168.1.2", 80))]]
    resolver = _PinnedLanResolver(lambda _host, _port: answers.pop(0))
    assert resolver("router.test", 80)[0][4][0] == "192.168.1.1"
    with pytest.raises(ProbeTransportError, match="address_blocked"):
        resolver("router.test", 80)

    duplicate = _PinnedLanResolver(lambda _h, _p: [
        (socket.AF_INET, socket.SOCK_STREAM, socket.IPPROTO_TCP, "", ("192.168.1.1", 80)),
        (socket.AF_INET, socket.SOCK_STREAM, socket.IPPROTO_TCP, "", ("192.168.1.1", 80)),
    ])
    with pytest.raises(ProbeTransportError, match="invalid_resolution"):
        duplicate("router.test", 80)
    public = _PinnedLanResolver(lambda _h, _p: [
        (socket.AF_INET, socket.SOCK_STREAM, socket.IPPROTO_TCP, "", ("93.184.216.34", 80)),
    ])
    with pytest.raises(ProbeTransportError, match="address_blocked"):
        public("router.test", 80)
