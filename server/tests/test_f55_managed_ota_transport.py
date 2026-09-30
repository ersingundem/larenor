import json
import socket
import struct
import threading

import pytest

from larenor_server.mesh_center.managed_ota_transport import (
    ManagedOtaTransportError,
    Zigbee2MqttManagedOtaTransport,
)
from larenor_server.mesh_center.mqtt_transport import (
    MqttBrokerConfig,
    MqttRetainedObserver,
)
from larenor_server.mesh_center.zigbee2mqtt_provider import _identity

BASE = "home/zigbee"
IEEE = "0x90fd9ffffe6494fc"
FRIENDLY = "living/room/bulb"
DEVICE = _identity("device", IEEE)


def _remaining(value):
    result = bytearray()
    while True:
        digit = value % 128
        value //= 128
        result.append(digit | (0x80 if value else 0))
        if not value:
            return bytes(result)


def _packet(kind, body):
    return bytes([kind]) + _remaining(len(body)) + body


def _field(value):
    return struct.pack("!H", len(value)) + value


def _publish(topic, value, *, retained=False):
    payload = value if isinstance(value, bytes) else json.dumps(value).encode()
    return _packet(0x31 if retained else 0x30, _field(topic.encode()) + payload)


def _decode_publish(value):
    offset = 1
    multiplier = 1
    while True:
        digit = value[offset]
        offset += 1
        if not digit & 0x80:
            break
        multiplier *= 128
    size = struct.unpack("!H", value[offset : offset + 2])[0]
    offset += 2
    topic = value[offset : offset + size].decode()
    return topic, json.loads(value[offset + size :])


def _inventory():
    return [
        {
            "ieee_address": IEEE,
            "type": "EndDevice",
            "supported": True,
            "disabled": False,
            "friendly_name": FRIENDLY,
            "definition": {"model": "REMOTE", "vendor": "IKEA"},
            "power_source": "Battery",
            "interview_state": "SUCCESSFUL",
        }
    ]


class Session:
    def __init__(self, mode, state, *, retained_response=False, wrong_transaction=False):
        self.mode = mode
        self.state = state
        self.retained_response = retained_response
        self.wrong_transaction = wrong_transaction
        self.buffer = bytearray(_packet(0x20, b"\x00\x00"))
        self.requests = []
        self.closed = False

    def getpeername(self):
        return ("192.168.1.10", 1883)

    def settimeout(self, _value):
        return None

    def sendall(self, value):
        kind = value[0] >> 4
        if kind == 1:
            return
        if kind == 8:
            if self.mode == "observe":
                self.buffer.extend(_packet(0x90, b"\x00\x01\x00"))
                info = {
                    "coordinator": {
                        "ieee_address": "0x00124b00120144ae",
                        "meta": {"majorrel": 2, "minorrel": 7, "maintrel": 2},
                    },
                    "network": {"channel": 15},
                }
                for topic, payload in (
                    (BASE + "/bridge/state", {"state": "online"}),
                    (BASE + "/bridge/info", info),
                    (BASE + "/bridge/devices", _inventory()),
                    (BASE + "/" + FRIENDLY, self.state),
                    (BASE + "/" + FRIENDLY + "/availability", b"online"),
                ):
                    self.buffer.extend(_publish(topic, payload, retained=True))
            else:
                self.buffer.extend(_packet(0x90, b"\x00\x01\x00\x00"))
            return
        if kind == 3:
            topic, body = _decode_publish(value)
            self.requests.append((topic, body))
            transaction = (
                "f" * 32 if self.wrong_transaction else body["transaction"]
            )
            if topic.endswith("/health_check"):
                response = {
                    "data": {"healthy": True},
                    "status": "ok",
                    "transaction": transaction,
                }
                self.buffer.extend(
                    _publish(BASE + "/bridge/response/health_check", response)
                )
            elif topic.endswith("/check"):
                response = {
                    "data": {
                        "id": IEEE,
                        "update_available": True,
                        "source": {"provider": "IKEA", "channel": "stable"},
                        "release_notes": "Reliability fixes",
                    },
                    "status": "ok",
                    "transaction": transaction,
                }
                self.buffer.extend(
                    _publish(
                        BASE + "/bridge/response/device/ota_update/check",
                        response,
                        retained=self.retained_response,
                    )
                )
            elif topic.endswith("/update"):
                self.buffer.extend(
                    _publish(
                        BASE + "/" + FRIENDLY,
                        {"update": {"state": "updating", "progress": 61.5}},
                    )
                )
                response = {
                    "data": {
                        "id": IEEE,
                        "from": {"file_version": 5},
                        "to": {"file_version": 10},
                    },
                    "status": "ok",
                    "transaction": transaction,
                }
                self.buffer.extend(
                    _publish(
                        BASE + "/bridge/response/device/ota_update/update", response
                    )
                )
            return
        if kind == 12:
            self.buffer.extend(b"\xd0\x00")
            return
        raise AssertionError(kind)

    def recv(self, count):
        if not self.buffer:
            raise socket.timeout
        result = bytes(self.buffer[:count])
        del self.buffer[:count]
        return result

    def close(self):
        self.closed = True


def _config():
    return MqttBrokerConfig.parse(
        "mqtt://broker.internal:1883",
        base_topic=BASE,
        allowed_addresses=("192.168.1.10",),
        username="worker",
        password="private",
    )


def _state(installed, latest, state):
    return {
        "battery": 84,
        "last_seen": 2_000,
        "update": {
            "state": state,
            "installed_version": installed,
            "latest_version": latest,
        },
    }


def _revision(state):
    broker = Session("observe", state)
    return MqttRetainedObserver(
        _config(), clock=lambda: 2_000, connector=lambda *_: broker
    ).observe(timeout=1).revision


class Connectors:
    def __init__(self, sessions):
        self.sessions = list(sessions)

    def __call__(self, *_args):
        return self.sessions.pop(0)


def _read_wire_packet(stream):
    first = stream.recv(1)
    if not first:
        return None
    encoded = bytearray(first)
    while True:
        byte = stream.recv(1)
        if not byte:
            raise AssertionError("truncated MQTT length")
        encoded.extend(byte)
        if not byte[0] & 0x80:
            break
    multiplier = 1
    size = 0
    for byte in encoded[1:]:
        size += (byte & 0x7f) * multiplier
        multiplier *= 128
    body = bytearray()
    while len(body) < size:
        part = stream.recv(size - len(body))
        if not part:
            raise AssertionError("truncated MQTT body")
        body.extend(part)
    return bytes(encoded + body)


class LoopbackBroker:
    def __init__(self, sessions):
        self.sessions = sessions
        self.server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.server.bind(("127.0.0.1", 0))
        self.server.listen(len(sessions))
        self.port = self.server.getsockname()[1]
        self.errors = []
        self.thread = threading.Thread(target=self._serve, daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_args):
        self.server.close()
        self.thread.join(timeout=2)
        assert not self.thread.is_alive()
        assert self.errors == []

    def _serve(self):
        try:
            for session in self.sessions:
                connection, _ = self.server.accept()
                with connection:
                    connection.settimeout(2)
                    while True:
                        packet = _read_wire_packet(connection)
                        if packet is None:
                            break
                        session.sendall(packet)
                        if session.buffer:
                            connection.sendall(session.buffer)
                            session.buffer.clear()
        except Exception as error:
            self.errors.append(error)


def test_check_and_update_use_fixed_topics_exact_ieee_and_causal_readback():
    before = _state(5, 5, "idle")
    available = _state(5, 10, "available")
    complete = _state(10, 10, "idle")
    check_wire = Session("check", available)
    check = Zigbee2MqttManagedOtaTransport(
        _config(),
        clock=lambda: 2_000,
        connector=Connectors(
            [Session("observe", before), check_wire, Session("observe", available)]
        ),
    )

    offer = check.check(DEVICE, _revision(before), timeout=1)

    assert offer.installedFileVersion == 5
    assert offer.latestFileVersion == 10
    assert offer.providerRevision == _revision(available)
    assert len(offer.sourceDigest) == 64
    assert check_wire.requests == [
        (
            BASE + "/bridge/request/device/ota_update/check",
            {"id": IEEE, "transaction": check_wire.requests[0][1]["transaction"]},
        )
    ]
    assert set(check_wire.requests[0][1]) == {"id", "transaction"}

    update_wire = Session("update", available)
    update = Zigbee2MqttManagedOtaTransport(
        _config(),
        clock=lambda: 2_100,
        connector=Connectors(
            [
                Session("observe", available),
                update_wire,
                Session("observe", complete),
            ]
        ),
    )
    installed = update.install(
        DEVICE, offer.providerRevision, 5, 10, timeout=1
    )

    assert installed.fromFileVersion == 5
    assert installed.toFileVersion == installed.installedFileVersion == 10
    assert installed.providerRevision == _revision(complete)
    assert installed.progressPercent == 100
    assert set(update_wire.requests[0][1]) == {"id", "transaction"}
    assert "url" not in update_wire.requests[0][1]
    assert "image" not in update_wire.requests[0][1]


def test_real_loopback_mqtt_wire_acceptance_is_separate_from_physical_gate():
    before = _state(5, 5, "idle")
    available = _state(5, 10, "available")
    sessions = [
        Session("observe", before),
        Session("check", available),
        Session("observe", available),
    ]
    with LoopbackBroker(sessions) as broker:
        # Production parsing rejects loopback broker addresses. Constructing the
        # frozen config directly is an explicit test-only gate for real TCP wire
        # acceptance; no physical Zigbee device or broker is contacted.
        config = MqttBrokerConfig(
            host="127.0.0.1",
            port=broker.port,
            tls=False,
            base_topic=BASE,
            allowed_addresses=("127.0.0.1",),
            username=None,
            password=None,
        )
        result = Zigbee2MqttManagedOtaTransport(
            config, clock=lambda: 2_000
        ).check(DEVICE, _revision(before), timeout=2)

    assert result.latestFileVersion == 10
    assert set(sessions[1].requests[0][1]) == {"id", "transaction"}


@pytest.mark.parametrize(
    "wire",
    [
        Session("check", _state(5, 10, "available"), retained_response=True),
        Session("check", _state(5, 10, "available"), wrong_transaction=True),
    ],
)
def test_check_rejects_retained_or_mismatched_transaction_response(wire):
    before = _state(5, 5, "idle")
    adapter = Zigbee2MqttManagedOtaTransport(
        _config(),
        connector=Connectors([Session("observe", before), wire]),
    )

    with pytest.raises(ManagedOtaTransportError):
        adapter.check(DEVICE, _revision(before), timeout=0.1)


def test_worker_re_resolves_device_and_enforces_battery_before_publish():
    low = _state(5, 5, "idle")
    low["battery"] = 69
    connector = Connectors([Session("observe", low)])
    adapter = Zigbee2MqttManagedOtaTransport(_config(), connector=connector)

    with pytest.raises(ManagedOtaTransportError, match="battery_too_low"):
        adapter.check(DEVICE, _revision(low), timeout=1)

    assert connector.sessions == []
