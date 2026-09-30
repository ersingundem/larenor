"""Bounded MQTT 3.1.1 retained reader for one configured Zigbee2MQTT prefix."""

from __future__ import annotations

from dataclasses import dataclass, field
import hashlib
import ipaddress
import json
import math
import secrets
import socket
import ssl
import struct
import time
from urllib.parse import urlsplit

from .zigbee2mqtt_provider import (
    MAX_DEVICE_STATE_BYTES,
    MAX_DEVICES,
    MAX_RETAINED_BYTES,
    Zigbee2MqttObservation,
    _json,
)

MAX_PACKET_BYTES = 2 * 1024 * 1024
MAX_TOTAL_BYTES = 8 * 1024 * 1024
MAX_MESSAGES = 2_048


class MqttObservationError(Exception):
    pass


@dataclass(frozen=True)
class MqttBrokerConfig:
    host: str
    port: int
    tls: bool
    base_topic: str
    allowed_addresses: tuple[str, ...]
    username: str | None = None
    password: str | None = field(default=None, repr=False)

    @classmethod
    def parse(
        cls,
        url: str,
        *,
        base_topic: str,
        allowed_addresses: tuple[str, ...],
        username: str | None = None,
        password: str | None = None,
    ):
        try:
            parsed = urlsplit(url)
            if (
                parsed.scheme not in {"mqtt", "mqtts"}
                or not parsed.hostname
                or parsed.username is not None
                or parsed.password is not None
                or parsed.path not in {"", "/"}
                or parsed.query
                or parsed.fragment
                or not 1 <= (parsed.port or (8883 if parsed.scheme == "mqtts" else 1883)) <= 65535
                or not isinstance(base_topic, str)
                or not 1 <= len(base_topic) <= 128
                or base_topic.startswith("/")
                or base_topic.endswith("/")
                or any(part in {"", ".", ".."} for part in base_topic.split("/"))
                or any(char in base_topic for char in "+#\0")
                or not 1 <= len(allowed_addresses) <= 8
                or len(set(allowed_addresses)) != len(allowed_addresses)
                or (username is None) != (password is None)
            ):
                raise ValueError
            addresses = []
            for raw in allowed_addresses:
                address = ipaddress.ip_address(raw)
                if (
                    str(address) != raw
                    or address.is_loopback
                    or address.is_link_local
                    or address.is_multicast
                    or address.is_unspecified
                    or address.is_reserved
                ):
                    raise ValueError
                addresses.append(raw)
            for secret in (username, password):
                if secret is not None and (
                    not 1 <= len(secret.encode("utf-8")) <= 2_048
                    or any(ord(char) < 32 or ord(char) == 127 for char in secret)
                ):
                    raise ValueError
            host = parsed.hostname.rstrip(".")
            if "%" in host or len(host.encode("idna")) > 253:
                raise ValueError
            return cls(
                host=host,
                port=parsed.port or (8883 if parsed.scheme == "mqtts" else 1883),
                tls=parsed.scheme == "mqtts",
                base_topic=base_topic,
                allowed_addresses=tuple(addresses),
                username=username,
                password=password,
            )
        except (ValueError, TypeError, UnicodeError):
            raise MqttObservationError("invalid_configuration") from None


def _remaining(deadline):
    value = deadline - time.monotonic()
    if not math.isfinite(deadline) or value <= 0:
        raise MqttObservationError("timeout")
    return value


def _field(value: bytes) -> bytes:
    if len(value) > 65_535:
        raise MqttObservationError("invalid_packet")
    return struct.pack("!H", len(value)) + value


def _remaining_length(value: int) -> bytes:
    if not 0 <= value <= 268_435_455:
        raise MqttObservationError("invalid_packet")
    encoded = bytearray()
    while True:
        digit = value % 128
        value //= 128
        if value:
            digit |= 0x80
        encoded.append(digit)
        if not value:
            return bytes(encoded)


def _packet(kind: int, body: bytes) -> bytes:
    return bytes([kind]) + _remaining_length(len(body)) + body


def _read_exact(stream, count: int, deadline: float) -> bytes:
    result = bytearray()
    while len(result) < count:
        stream.settimeout(_remaining(deadline))
        try:
            part = stream.recv(count - len(result))
        except (TimeoutError, socket.timeout):
            raise MqttObservationError("timeout") from None
        if not part:
            raise MqttObservationError("connection_closed")
        result.extend(part)
    return bytes(result)


def _read_packet(stream, deadline: float):
    first = _read_exact(stream, 1, deadline)[0]
    multiplier = 1
    remaining = 0
    for index in range(4):
        digit = _read_exact(stream, 1, deadline)[0]
        remaining += (digit & 127) * multiplier
        if digit & 128 == 0:
            break
        multiplier *= 128
    else:
        raise MqttObservationError("invalid_packet")
    if remaining > MAX_PACKET_BYTES:
        raise MqttObservationError("packet_too_large")
    return first, _read_exact(stream, remaining, deadline)


def _publish(packet_type: int, body: bytes):
    if len(body) < 2:
        raise MqttObservationError("invalid_packet")
    topic_length = struct.unpack("!H", body[:2])[0]
    if not 1 <= topic_length <= len(body) - 2:
        raise MqttObservationError("invalid_packet")
    try:
        topic = body[2 : 2 + topic_length].decode("utf-8")
    except UnicodeError:
        raise MqttObservationError("invalid_packet") from None
    qos = (packet_type >> 1) & 3
    if qos != 0 or "\0" in topic or len(topic) > 512:
        raise MqttObservationError("invalid_packet")
    return topic, body[2 + topic_length :], bool(packet_type & 1)


class MqttRetainedObserver:
    def __init__(self, config: MqttBrokerConfig, *, clock=time.time, connector=None):
        self.config = config
        self._clock = clock
        self._connector = connector

    def _connect(self, deadline):
        last = None
        for raw in self.config.allowed_addresses:
            address = ipaddress.ip_address(raw)
            family = socket.AF_INET6 if address.version == 6 else socket.AF_INET
            target = (
                (raw, self.config.port, 0, 0)
                if address.version == 6
                else (raw, self.config.port)
            )
            candidate = None
            try:
                if self._connector is None:
                    candidate = socket.socket(family, socket.SOCK_STREAM)
                    candidate.settimeout(_remaining(deadline))
                    candidate.connect(target)
                else:
                    candidate = self._connector(family, target, _remaining(deadline))
                if candidate.getpeername()[0] != raw:
                    raise MqttObservationError("address_changed")
                if self.config.tls:
                    candidate = ssl.create_default_context().wrap_socket(
                        candidate,
                        server_hostname=self.config.host,
                    )
                return candidate
            except Exception as error:
                last = error
                if candidate is not None:
                    try:
                        candidate.close()
                    except Exception:
                        pass
        raise MqttObservationError("unavailable") from None

    def observe(self, *, timeout: float = 8.0) -> Zigbee2MqttObservation:
        if (
            not isinstance(timeout, (int, float))
            or isinstance(timeout, bool)
            or not 0 < timeout <= 15
        ):
            raise MqttObservationError("invalid_timeout")
        deadline = time.monotonic() + timeout
        stream = self._connect(deadline)
        try:
            client_id = ("larenor-" + secrets.token_hex(8)).encode("ascii")
            flags = 0x02
            payload = _field(client_id)
            if self.config.username is not None:
                flags |= 0xC0
                payload += _field(self.config.username.encode("utf-8"))
                payload += _field(self.config.password.encode("utf-8"))
            connect = _field(b"MQTT") + b"\x04" + bytes([flags]) + b"\x00\x0f" + payload
            stream.sendall(_packet(0x10, connect))
            packet_type, body = _read_packet(stream, deadline)
            if packet_type != 0x20 or body != b"\x00\x00":
                raise MqttObservationError("unauthorized")

            topic = (self.config.base_topic + "/#").encode("utf-8")
            stream.sendall(_packet(0x82, b"\x00\x01" + _field(topic) + b"\x00"))
            subscribed = False
            retained = {}
            total = 0
            transaction = secrets.token_hex(16)
            health_response = self.config.base_topic + "/bridge/response/health_check"
            health_ok = False
            requested = False
            completed_at = None
            while True:
                try:
                    packet_type, body = _read_packet(
                        stream,
                        min(deadline, completed_at + 0.2) if completed_at else deadline,
                    )
                except MqttObservationError as error:
                    if completed_at is not None and error.args == ("timeout",):
                        break
                    raise
                kind = packet_type >> 4
                if kind == 9:
                    if body != b"\x00\x01\x00" or subscribed:
                        raise MqttObservationError("subscription_failed")
                    subscribed = True
                    request_topic = self.config.base_topic + "/bridge/request/health_check"
                    request = json.dumps(
                        {"transaction": transaction}, separators=(",", ":")
                    ).encode("ascii")
                    stream.sendall(
                        _packet(0x30, _field(request_topic.encode("utf-8")) + request)
                    )
                    requested = True
                    continue
                if kind != 3 or not subscribed or not requested:
                    raise MqttObservationError("unexpected_packet")
                message_topic, message, is_retained = _publish(packet_type, body)
                total += len(message)
                if total > MAX_TOTAL_BYTES:
                    raise MqttObservationError("snapshot_too_large")
                if message_topic == health_response:
                    value = _json(message, 16_384)
                    if (
                        is_retained
                        or not isinstance(value, dict)
                        or value.get("transaction") != transaction
                        or value.get("status") != "ok"
                        or not isinstance(value.get("data"), dict)
                        or value["data"].get("healthy") is not True
                    ):
                        raise MqttObservationError("unhealthy")
                    health_ok = True
                elif is_retained:
                    if len(retained) >= MAX_MESSAGES and message_topic not in retained:
                        raise MqttObservationError("snapshot_too_large")
                    retained[message_topic] = message
                required = tuple(
                    self.config.base_topic + suffix
                    for suffix in ("/bridge/state", "/bridge/info", "/bridge/devices")
                )
                if health_ok and all(item in retained for item in required):
                    completed_at = completed_at or time.monotonic()

            prefix = self.config.base_topic + "/"
            bridge_state = retained[prefix + "bridge/state"]
            bridge_info = retained[prefix + "bridge/info"]
            devices = retained[prefix + "bridge/devices"]
            inventory = _json(devices, MAX_RETAINED_BYTES)
            if not isinstance(inventory, list) or len(inventory) > MAX_DEVICES + 1:
                raise MqttObservationError("invalid_inventory")
            names = set()
            for item in inventory:
                if not isinstance(item, dict):
                    raise MqttObservationError("invalid_inventory")
                name = item.get("friendly_name")
                if (
                    isinstance(name, str)
                    and 1 <= len(name) <= 256
                    and not any(char in name for char in "\0+#")
                    and not name.startswith("bridge/")
                ):
                    names.add(name)
            states = {}
            availability = {}
            for name in names:
                state_topic = prefix + name
                availability_topic = state_topic + "/availability"
                if state_topic in retained:
                    if len(retained[state_topic]) > MAX_DEVICE_STATE_BYTES:
                        raise MqttObservationError("snapshot_too_large")
                    states[name] = retained[state_topic]
                if availability_topic in retained:
                    availability[name] = retained[availability_topic]
            digest = hashlib.sha256()
            for key, value in sorted(
                {
                    "bridge/state": bridge_state,
                    "bridge/info": bridge_info,
                    "bridge/devices": devices,
                    **{f"state/{key}": value for key, value in states.items()},
                    **{f"availability/{key}": value for key, value in availability.items()},
                }.items()
            ):
                digest.update(key.encode("utf-8") + b"\0" + value + b"\0")
            revision = int.from_bytes(digest.digest()[:8], "big") & (2**63 - 1)
            return Zigbee2MqttObservation(
                revision=revision or 1,
                capturedAtMs=int(self._clock() * 1_000),
                bridgeState=bridge_state,
                bridgeInfo=bridge_info,
                devices=devices,
                deviceStates=states,
                availability=availability,
            )
        except MqttObservationError:
            raise
        except (OSError, ValueError, TypeError, UnicodeError, OverflowError, json.JSONDecodeError):
            raise MqttObservationError("unavailable") from None
        finally:
            try:
                stream.close()
            except Exception:
                pass
