import json
import socket
import struct

import pytest

from larenor_server.mesh_center.mqtt_transport import (
    MqttBrokerConfig,
    MqttObservationError,
    MqttRetainedObserver,
)


def remaining(value):
    result = bytearray()
    while True:
        digit = value % 128
        value //= 128
        result.append(digit | (0x80 if value else 0))
        if not value:
            return bytes(result)


def packet(kind, body):
    return bytes([kind]) + remaining(len(body)) + body


def field(value):
    return struct.pack("!H", len(value)) + value


def publish(topic, payload, *, retained=True):
    return packet(0x31 if retained else 0x30, field(topic.encode()) + payload)


class Broker:
    def __init__(self, *, retain_bridge=True, retain_health=False):
        self.buffer = bytearray(packet(0x20, b"\x00\x00"))
        self.timeout = None
        self.closed = False
        self.retain_bridge = retain_bridge
        self.retain_health = retain_health
        self.health_requests = []

    def getpeername(self):
        return ("192.168.1.10", 1883)

    def settimeout(self, value):
        self.timeout = value

    def sendall(self, value):
        kind = value[0] >> 4
        if kind == 1:
            return
        if kind == 8:
            self.buffer.extend(packet(0x90, b"\x00\x01\x00"))
            base = "home/zigbee"
            info = {
                "coordinator": {
                    "ieee_address": "0x00124b00120144ae",
                    "meta": {"majorrel": 2, "minorrel": 7, "maintrel": 2},
                },
                "network": {"channel": 15},
            }
            devices = [
                {
                    "ieee_address": "0x90fd9ffffe6494fc",
                    "type": "Router",
                    "supported": True,
                    "disabled": False,
                    "friendly_name": "living/room/bulb",
                    "definition": {"model": "LED", "vendor": "IKEA"},
                    "power_source": "Mains",
                    "interview_state": "SUCCESSFUL",
                }
            ]
            for topic, payload in (
                (base + "/bridge/state", b'{"state":"online"}'),
                (base + "/bridge/info", json.dumps(info).encode()),
                (base + "/bridge/devices", json.dumps(devices).encode()),
                (base + "/living/room/bulb", b'{"last_seen":1999}'),
                (base + "/living/room/bulb/availability", b"online"),
                (base + "/unrelated", b"ignored"),
            ):
                self.buffer.extend(
                    publish(
                        topic,
                        payload,
                        retained=self.retain_bridge or "/bridge/" not in topic,
                    )
                )
            return
        if kind == 3:
            multiplier = 1
            offset = 1
            length = 0
            while True:
                digit = value[offset]
                offset += 1
                length += (digit & 127) * multiplier
                if digit & 128 == 0:
                    break
                multiplier *= 128
            topic_length = struct.unpack("!H", value[offset : offset + 2])[0]
            start = offset + 2
            topic = value[start : start + topic_length].decode()
            body = json.loads(value[start + topic_length :])
            self.health_requests.append((topic, body))
            response = {
                "data": {"healthy": True},
                "status": "ok",
                "transaction": body["transaction"],
            }
            self.buffer.extend(
                publish(
                    "home/zigbee/bridge/response/health_check",
                    json.dumps(response, separators=(",", ":")).encode(),
                    retained=self.retain_health,
                )
            )
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


def config(**changes):
    values = dict(
        url="mqtt://broker.internal:1883",
        base_topic="home/zigbee",
        allowed_addresses=("192.168.1.10",),
        username="reader",
        password="secret",
    )
    values.update(changes)
    return MqttBrokerConfig.parse(**values)


def test_bounded_reader_pins_address_correlates_health_and_filters_retained_topics():
    broker = Broker()
    adapter = MqttRetainedObserver(
        config(),
        clock=lambda: 2_000,
        connector=lambda family, target, timeout: broker,
    )

    result = adapter.observe(timeout=1)

    assert result.capturedAtMs == 2_000_000
    assert result.revision > 0
    assert set(result.deviceStates) == {"living/room/bulb"}
    assert set(result.availability) == {"living/room/bulb"}
    assert result.bridgeState == b'{"state":"online"}'
    assert broker.health_requests[0][0] == "home/zigbee/bridge/request/health_check"
    assert len(broker.health_requests[0][1]["transaction"]) == 32
    assert broker.closed is True


def test_bridge_evidence_must_be_retained_even_when_health_reply_is_live():
    broker = Broker(retain_bridge=False)
    adapter = MqttRetainedObserver(
        config(), connector=lambda family, target, timeout: broker
    )

    with pytest.raises(MqttObservationError):
        adapter.observe(timeout=0.1)


def test_retained_health_reply_is_not_accepted_as_live_broker_proof():
    adapter = MqttRetainedObserver(
        config(), connector=lambda family, target, timeout: Broker(retain_health=True)
    )

    with pytest.raises(MqttObservationError, match="unhealthy"):
        adapter.observe(timeout=0.1)


@pytest.mark.parametrize(
    "changes",
    [
        {"url": "http://broker.internal"},
        {"url": "mqtt://user:secret@broker.internal"},
        {"base_topic": "home/+"},
        {"allowed_addresses": ("127.0.0.1",)},
        {"username": "reader", "password": None},
    ],
)
def test_ambiguous_or_unsafe_broker_configuration_is_rejected(changes):
    with pytest.raises(MqttObservationError, match="invalid_configuration"):
        config(**changes)
