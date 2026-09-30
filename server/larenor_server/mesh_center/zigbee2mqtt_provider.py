"""Truthful projection of Zigbee2MQTT retained observations.

The MQTT boundary is intentionally separate: an isolated broker reader supplies
one bounded, revisioned observation. This adapter never triggers network-map or
OTA requests while serving the normal read path. Zigbee2MQTT documents network
map collection as a disruptive manual operation, and its retained inventory
does not prove a route, channel interference scan, or firmware image digest.
Those facts therefore remain explicitly unavailable instead of being guessed.
"""

from __future__ import annotations

from collections.abc import Callable, Mapping
from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import hmac
import json
import re
import threading

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

from ..errors import ApiError
from ..vault import validate_json_bounds
from .models import (
    CoordinatorNode,
    FirmwareCatalog,
    InterferenceSnapshot,
    MeshAuthority,
    MeshDevice,
    MeshTopology,
)
from .service import firmware_catalog_payload

MAX_RETAINED_BYTES = 2 * 1024 * 1024
MAX_DEVICE_STATE_BYTES = 64 * 1024
MAX_DEVICES = 1_024
CATALOG_LIFETIME_MS = 5 * 60 * 1_000
_IEEE = re.compile(r"0x[0-9a-fA-F]{8,16}\Z")
_VERSION = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+\Z")


@dataclass(frozen=True)
class Zigbee2MqttObservation:
    """One atomic read made by a trusted broker worker.

    ``revision`` must advance whenever any retained input changes. Message
    timestamps are worker receipt times; MQTT retained packets do not carry a
    trustworthy source timestamp.
    """

    revision: int
    capturedAtMs: int
    bridgeState: bytes
    bridgeInfo: bytes
    devices: bytes
    deviceStates: Mapping[str, bytes]
    availability: Mapping[str, bytes]


def _unique(pairs):
    value = {}
    for key, child in pairs:
        if key in value:
            raise ValueError("duplicate_json_key")
        value[key] = child
    return value


def _json(payload: bytes, maximum: int):
    if not isinstance(payload, bytes) or not 1 <= len(payload) <= maximum:
        raise ValueError("invalid_payload")
    value = json.loads(
        payload,
        object_pairs_hook=_unique,
        parse_constant=lambda _: (_ for _ in ()).throw(ValueError()),
    )
    validate_json_bounds(value)
    return value


def _identity(scope: str, value: str) -> str:
    return hashlib.sha256(
        b"larenor:zigbee2mqtt:v1\0"
        + scope.encode("ascii")
        + b"\0"
        + value.encode("utf-8")
    ).hexdigest()[:32]


def _text(value, fallback: str) -> str:
    if value is None:
        return fallback
    if not isinstance(value, str):
        raise ValueError("invalid_text")
    value = value.strip()
    if (
        not value
        or len(value) > 64
        or any(ord(char) < 32 or ord(char) == 127 for char in value)
    ):
        raise ValueError("invalid_text")
    return value


def _last_seen(value, captured_at: int) -> int | None:
    if value is None:
        return None
    if type(value) is int:
        result = value * 1_000 if value < 10_000_000_000 else value
    elif isinstance(value, str) and len(value) <= 64:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            raise ValueError("untrusted_local_time")
        result = int(parsed.astimezone(timezone.utc).timestamp() * 1_000)
    else:
        raise ValueError("invalid_last_seen")
    if not 0 <= result <= captured_at:
        raise ValueError("invalid_last_seen")
    return result


def _available(payload: bytes | None) -> bool:
    if payload is None:
        return False
    if payload == b"online":
        return True
    if payload == b"offline":
        return False
    value = _json(payload, 1_024)
    if not isinstance(value, dict) or set(value) != {"state"}:
        raise ValueError("invalid_availability")
    if value["state"] not in ("online", "offline"):
        raise ValueError("invalid_availability")
    return value["state"] == "online"


class Zigbee2MqttProvider:
    """MeshCenterProvider for the facts Zigbee2MQTT can prove passively."""

    def __init__(
        self,
        *,
        core_id: str,
        home_id: str,
        master_key: bytes,
        observe: Callable[[], Zigbee2MqttObservation],
        authority_for_actor: Callable[[object], MeshAuthority],
        authority_for_account: Callable[[str], MeshAuthority | None],
    ):
        if (
            not re.fullmatch(r"[0-9a-f]{32}", core_id)
            or not re.fullmatch(r"[0-9a-f]{32}", home_id)
            or not isinstance(master_key, bytes)
            or len(master_key) < 32
            or not callable(observe)
            or not callable(authority_for_actor)
            or not callable(authority_for_account)
        ):
            raise ValueError("invalid_zigbee2mqtt_provider")
        self._core_id = core_id
        self._home_id = home_id
        self._observe = observe
        self._authority_for_actor = authority_for_actor
        self._authority_for_account = authority_for_account
        seed = hmac.new(
            master_key, b"larenor:zigbee2mqtt:catalog-signing:v1", hashlib.sha256
        ).digest()
        self._signing_key = Ed25519PrivateKey.from_private_bytes(seed)
        self._public_key = self._signing_key.public_key().public_bytes(
            serialization.Encoding.Raw,
            serialization.PublicFormat.Raw,
        )
        self._catalog_id = _identity("catalog", core_id + home_id)
        self._key_id = _identity("signing-key", core_id + home_id)
        self._lock = threading.RLock()
        self._topology = None
        self._interference = None
        self._catalog = None

    def authority(self, account_id: str):
        return self._authority_for_account(account_id)

    def topology(self, home_id: str):
        with self._lock:
            return self._topology if home_id == self._home_id else None

    def interference(self, home_id: str):
        with self._lock:
            return self._interference if home_id == self._home_id else None

    def catalog(self, catalog_id: str):
        with self._lock:
            return self._catalog if catalog_id == self._catalog_id else None

    def signing_key(self, key_id: str):
        return self._public_key if key_id == self._key_id else None

    def install(self, _command):
        # No catalog entry is advertised without exact image bytes and digest.
        raise ApiError("firmware_update_unsupported", 409)

    def snapshot(self, actor):
        authority = MeshAuthority.model_validate(self._authority_for_actor(actor))
        if (
            authority.coreId != self._core_id
            or authority.homeId != self._home_id
            or authority.accountId != actor.id
            or authority.sessionFamilyId != actor.family_id
        ):
            raise ValueError("authority_scope_mismatch")
        observation = self._validate_observation(self._observe())
        topology = self._topology_from(observation, authority)
        interference = InterferenceSnapshot(
            schemaVersion=1,
            coreId=self._core_id,
            homeId=self._home_id,
            revision=observation.revision,
            providerRevision=observation.revision,
            capturedAtMs=observation.capturedAtMs,
            channels=[],
        )
        unsigned = FirmwareCatalog(
            schemaVersion=1,
            catalogId=self._catalog_id,
            revision=observation.revision,
            providerRevision=observation.revision,
            generatedAtMs=observation.capturedAtMs,
            expiresAtMs=observation.capturedAtMs + CATALOG_LIFETIME_MS,
            signingKeyId=self._key_id,
            entries=[],
            signature="0" * 128,
        )
        catalog = unsigned.model_copy(
            update={
                "signature": self._signing_key.sign(
                    firmware_catalog_payload(unsigned)
                ).hex()
            }
        )
        with self._lock:
            self._topology = topology
            self._interference = interference
            self._catalog = catalog
        return authority, topology, interference, catalog, None

    @staticmethod
    def _validate_observation(raw) -> Zigbee2MqttObservation:
        if not isinstance(raw, Zigbee2MqttObservation):
            raise ValueError("invalid_observation")
        if (
            type(raw.revision) is not int
            or not 1 <= raw.revision <= 2**63 - 1
            or type(raw.capturedAtMs) is not int
            or not 0 <= raw.capturedAtMs <= 2**63 - 1
            or not isinstance(raw.deviceStates, Mapping)
            or not isinstance(raw.availability, Mapping)
            or len(raw.deviceStates) > MAX_DEVICES
            or len(raw.availability) > MAX_DEVICES
        ):
            raise ValueError("invalid_observation")
        return raw

    def _topology_from(self, observation, authority):
        state = _json(observation.bridgeState, 1_024)
        info = _json(observation.bridgeInfo, MAX_RETAINED_BYTES)
        devices = _json(observation.devices, MAX_RETAINED_BYTES)
        if (
            not isinstance(state, dict)
            or set(state) != {"state"}
            or state["state"] not in ("online", "offline")
            or not isinstance(info, dict)
            or not isinstance(devices, list)
            or len(devices) > MAX_DEVICES + 1
        ):
            raise ValueError("invalid_bridge_snapshot")
        coordinator = info.get("coordinator")
        network = info.get("network")
        if not isinstance(coordinator, dict) or not isinstance(network, dict):
            raise ValueError("invalid_bridge_snapshot")
        ieee = coordinator.get("ieee_address")
        channel = network.get("channel")
        meta = coordinator.get("meta")
        if (
            not isinstance(ieee, str)
            or _IEEE.fullmatch(ieee) is None
            or type(channel) is not int
            or not 11 <= channel <= 26
            or not isinstance(meta, dict)
        ):
            raise ValueError("invalid_bridge_snapshot")
        version_parts = [meta.get(key) for key in ("majorrel", "minorrel", "maintrel")]
        if any(type(value) is not int or not 0 <= value <= 999_999 for value in version_parts):
            raise ValueError("invalid_coordinator_version")
        coordinator_id = _identity("device", ieee.lower())
        projected = []
        seen_ieee = set()
        for raw in devices:
            if not isinstance(raw, dict):
                raise ValueError("invalid_device")
            if raw.get("type") == "Coordinator":
                continue
            if (
                raw.get("supported") is not True
                or raw.get("disabled") is True
                or raw.get("interview_state") != "SUCCESSFUL"
            ):
                continue
            child_ieee = raw.get("ieee_address")
            friendly = raw.get("friendly_name")
            definition = raw.get("definition")
            power = raw.get("power_source")
            if (
                not isinstance(child_ieee, str)
                or _IEEE.fullmatch(child_ieee) is None
                or child_ieee.lower() in seen_ieee
                or not isinstance(friendly, str)
                or not 1 <= len(friendly) <= 256
                or not isinstance(definition, dict)
                or not isinstance(power, str)
            ):
                raise ValueError("invalid_device")
            seen_ieee.add(child_ieee.lower())
            state_payload = observation.deviceStates.get(friendly)
            raw_state = (
                {}
                if state_payload is None
                else _json(state_payload, MAX_DEVICE_STATE_BYTES)
            )
            if not isinstance(raw_state, dict):
                raise ValueError("invalid_device_state")
            battery = raw_state.get("battery")
            if battery is not None:
                if isinstance(battery, bool) or not isinstance(battery, (int, float)):
                    raise ValueError("invalid_battery")
                battery = round(battery)
                if not 0 <= battery <= 100:
                    raise ValueError("invalid_battery")
            normalized_power = power.strip().lower()
            if "battery" in normalized_power:
                power_source = "battery"
            elif any(value in normalized_power for value in ("mains", "dc source")):
                power_source = "mains"
            else:
                raise ValueError("unknown_power_source")
            if power_source == "mains":
                battery = None
            update = raw_state.get("update")
            if update is not None and not isinstance(update, dict):
                raise ValueError("invalid_update_state")
            software = raw.get("software_build_id")
            firmware = software if isinstance(software, str) and _VERSION.fullmatch(software) else None
            projected.append(
                MeshDevice(
                    schemaVersion=1,
                    deviceId=_identity("device", child_ieee.lower()),
                    revision=observation.revision,
                    providerRevision=observation.revision,
                    routeRevision=observation.revision,
                    protocol="zigbee",
                    manufacturer=_text(definition.get("vendor"), "Unknown"),
                    model=_text(definition.get("model") or raw.get("model_id"), "Unknown"),
                    hardwareRevision=_text(raw.get("date_code"), "Unknown"),
                    firmwareVersion=firmware,
                    powerSource=power_source,
                    batteryPercent=battery,
                    reachable=_available(observation.availability.get(friendly)),
                    updating=update is not None and update.get("state") == "updating",
                    routeKnown=False,
                    parentId=None,
                    routeDepth=None,
                    lastSeenAtMs=_last_seen(raw_state.get("last_seen"), observation.capturedAtMs),
                )
            )
        return MeshTopology(
            schemaVersion=1,
            coreId=self._core_id,
            homeId=self._home_id,
            homeRevision=authority.homeRevision,
            revision=observation.revision,
            providerRevision=observation.revision,
            capturedAtMs=observation.capturedAtMs,
            coordinator=CoordinatorNode(
                schemaVersion=1,
                nodeId=coordinator_id,
                revision=observation.revision,
                providerRevision=observation.revision,
                protocol="zigbee",
                channel=channel,
                firmwareVersion=".".join(str(value) for value in version_parts),
                online=state["state"] == "online",
            ),
            borderRouters=[],
            devices=projected,
        )
