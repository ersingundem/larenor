"""Provider-managed Zigbee2MQTT OTA over a fixed MQTT command surface.

The Core supplies only its opaque device identity and an exact observation
revision.  This worker re-resolves the trusted Zigbee descriptor before every
broker request.  It never accepts a URL, file name, image, downgrade, or
schedule option from the caller.
"""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
import math
import secrets
import socket
import struct
import time

from .mqtt_transport import (
    MqttBrokerConfig,
    MqttObservationError,
    MqttRetainedObserver,
    _field,
    _packet,
    _publish,
    _read_packet,
    _remaining,
)
from .zigbee2mqtt_provider import (
    MAX_DEVICE_STATE_BYTES,
    _IEEE,
    _available,
    _identity,
    _json,
)

MAX_CHECK_SECONDS = 30.0
MAX_UPDATE_SECONDS = 7_200.0
MAX_LIVE_MESSAGES = 8_192
MAX_LIVE_BYTES = 8 * 1024 * 1024


class ManagedOtaTransportError(RuntimeError):
    def __init__(self, code: str, *, ambiguous: bool = False):
        self.code = code if code in {
            "unavailable",
            "revision_conflict",
            "device_not_found",
            "device_unavailable",
            "battery_too_low",
            "no_update",
            "provider_rejected",
            "readback_mismatch",
            "timeout",
        } else "unavailable"
        self.ambiguous = ambiguous
        super().__init__(self.code)


@dataclass(frozen=True)
class ManagedOtaOfferEvidence:
    deviceId: str
    providerRevision: int
    installedFileVersion: int
    latestFileVersion: int
    sourceDigest: str
    checkedAtMs: int
    releaseNotesAvailable: bool


@dataclass(frozen=True)
class ManagedOtaInstallEvidence:
    deviceId: str
    previousProviderRevision: int
    providerRevision: int
    fromFileVersion: int
    toFileVersion: int
    installedFileVersion: int
    progressPercent: int
    completedAtMs: int


def _safe_version(value):
    if type(value) is not int or not 0 <= value <= 2**32 - 1:
        raise ManagedOtaTransportError("readback_mismatch")
    return value


def _descriptor(observation, device_id: str):
    try:
        inventory = _json(observation.devices, 2 * 1024 * 1024)
        if not isinstance(inventory, list):
            raise ValueError
        matches = []
        for item in inventory:
            if not isinstance(item, dict):
                raise ValueError
            ieee = item.get("ieee_address")
            friendly = item.get("friendly_name")
            if (
                not isinstance(ieee, str)
                or _IEEE.fullmatch(ieee) is None
                or not isinstance(friendly, str)
            ):
                continue
            if _identity("device", ieee.lower()) == device_id:
                matches.append((ieee.lower(), friendly, item))
        if len(matches) != 1:
            raise ManagedOtaTransportError("device_not_found")
        ieee, friendly, item = matches[0]
        if (
            len(friendly.encode("utf-8")) > 256
            or any(char in friendly for char in "\0+#")
            or friendly.startswith("bridge/")
            or item.get("supported") is not True
            or item.get("disabled") is True
            or item.get("interview_state") != "SUCCESSFUL"
        ):
            raise ManagedOtaTransportError("device_unavailable")
        if not _available(observation.availability.get(friendly)):
            raise ManagedOtaTransportError("device_unavailable")
        state = _json(
            observation.deviceStates.get(friendly, b"{}"), MAX_DEVICE_STATE_BYTES
        )
        if not isinstance(state, dict):
            raise ValueError
        battery = state.get("battery")
        power = item.get("power_source")
        if power in ("Battery", "battery"):
            if (
                type(battery) not in (int, float)
                or isinstance(battery, bool)
                or not math.isfinite(battery)
                or not 70 <= battery <= 100
            ):
                raise ManagedOtaTransportError("battery_too_low")
        return ieee, friendly, state
    except ManagedOtaTransportError:
        raise
    except (ValueError, TypeError, UnicodeError, json.JSONDecodeError):
        raise ManagedOtaTransportError("unavailable") from None


def _update_versions(state):
    update = state.get("update")
    if not isinstance(update, dict):
        raise ManagedOtaTransportError("readback_mismatch")
    installed = _safe_version(update.get("installed_version"))
    latest = _safe_version(update.get("latest_version"))
    status = update.get("state")
    if status not in {"idle", "available", "scheduled", "updating"}:
        raise ManagedOtaTransportError("readback_mismatch")
    return installed, latest, status


class Zigbee2MqttManagedOtaTransport:
    def __init__(self, config: MqttBrokerConfig, *, clock=time.time, connector=None):
        self.config = config
        self._clock = clock
        self._connector = connector
        self._observer = MqttRetainedObserver(
            config, clock=clock, connector=connector
        )

    def _fresh_target(self, device_id, expected_revision, timeout):
        try:
            observation = self._observer.observe(timeout=min(timeout, 15.0))
        except MqttObservationError as error:
            raise ManagedOtaTransportError("unavailable") from error
        if observation.revision != expected_revision:
            raise ManagedOtaTransportError("revision_conflict")
        ieee, friendly, state = _descriptor(observation, device_id)
        return observation, ieee, friendly, state

    @staticmethod
    def _phase_timeout(deadline, maximum):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise ManagedOtaTransportError("timeout")
        return min(remaining, maximum)

    def _connect(self, deadline):
        try:
            return self._observer._connect(deadline)
        except MqttObservationError as error:
            raise ManagedOtaTransportError("unavailable") from error

    def _request(self, operation, ieee, friendly, *, timeout):
        deadline = time.monotonic() + timeout
        stream = self._connect(deadline)
        published = False
        try:
            client_id = ("larenor-ota-" + secrets.token_hex(8)).encode("ascii")
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
                raise ManagedOtaTransportError("unavailable")

            response_topic = (
                f"{self.config.base_topic}/bridge/response/device/ota_update/{operation}"
            )
            device_topic = f"{self.config.base_topic}/{friendly}"
            subscriptions = (
                _field(response_topic.encode("utf-8")) + b"\x00"
                + _field(device_topic.encode("utf-8")) + b"\x00"
            )
            stream.sendall(_packet(0x82, b"\x00\x01" + subscriptions))
            packet_type, body = _read_packet(stream, deadline)
            if packet_type != 0x90 or body != b"\x00\x01\x00\x00":
                raise ManagedOtaTransportError("unavailable")

            transaction = secrets.token_hex(16)
            request_topic = (
                f"{self.config.base_topic}/bridge/request/device/ota_update/{operation}"
            )
            request = json.dumps(
                {"id": ieee, "transaction": transaction}, separators=(",", ":")
            ).encode("ascii")
            stream.sendall(_packet(0x30, _field(request_topic.encode("utf-8")) + request))
            published = True

            live_states = []
            total = 0
            while True:
                try:
                    packet_type, body = _read_packet(
                        stream, min(deadline, time.monotonic() + 10.0)
                    )
                except MqttObservationError as error:
                    if error.args == ("timeout",) and time.monotonic() < deadline:
                        stream.sendall(b"\xc0\x00")
                        continue
                    raise ManagedOtaTransportError(
                        "timeout" if error.args == ("timeout",) else "unavailable",
                        ambiguous=published,
                    ) from error
                kind = packet_type >> 4
                if kind == 13:
                    if body:
                        raise ManagedOtaTransportError("unavailable", ambiguous=published)
                    continue
                if kind != 3:
                    raise ManagedOtaTransportError("unavailable", ambiguous=published)
                topic, message, retained = _publish(packet_type, body)
                total += len(message)
                if total > MAX_LIVE_BYTES or len(live_states) >= MAX_LIVE_MESSAGES:
                    raise ManagedOtaTransportError("unavailable", ambiguous=published)
                if topic == device_topic:
                    if not retained:
                        value = _json(message, MAX_DEVICE_STATE_BYTES)
                        if isinstance(value, dict):
                            live_states.append(value)
                    continue
                if topic != response_topic:
                    raise ManagedOtaTransportError("unavailable", ambiguous=published)
                value = _json(message, 64 * 1024)
                if (
                    retained
                    or not isinstance(value, dict)
                    or value.get("transaction") != transaction
                    or value.get("status") not in {"ok", "error"}
                    or not isinstance(value.get("data"), dict)
                ):
                    raise ManagedOtaTransportError("unavailable", ambiguous=published)
                if value["status"] != "ok":
                    raise ManagedOtaTransportError("provider_rejected", ambiguous=published)
                return value["data"], tuple(live_states)
        except ManagedOtaTransportError:
            raise
        except (OSError, ValueError, TypeError, UnicodeError, json.JSONDecodeError) as error:
            raise ManagedOtaTransportError("unavailable", ambiguous=published) from error
        finally:
            try:
                stream.close()
            except Exception:
                pass

    def check(self, device_id: str, expected_provider_revision: int, *, timeout=30.0):
        if not 0 < timeout <= MAX_CHECK_SECONDS:
            raise ManagedOtaTransportError("unavailable")
        deadline = time.monotonic() + timeout
        _, ieee, friendly, _ = self._fresh_target(
            device_id,
            expected_provider_revision,
            self._phase_timeout(deadline, 15.0),
        )
        data, _ = self._request(
            "check", ieee, friendly,
            timeout=self._phase_timeout(deadline, MAX_CHECK_SECONDS),
        )
        if data.get("id") not in {ieee, friendly}:
            raise ManagedOtaTransportError("readback_mismatch")
        if data.get("update_available") is not True:
            raise ManagedOtaTransportError("no_update")
        source = data.get("source")
        if not isinstance(source, (str, dict, list)):
            raise ManagedOtaTransportError("readback_mismatch")
        source_payload = json.dumps(
            source, sort_keys=True, separators=(",", ":"), ensure_ascii=True
        ).encode("ascii")
        post = self._observer.observe(
            timeout=self._phase_timeout(deadline, 15.0)
        )
        _, _, state = _descriptor(post, device_id)
        installed, latest, status = _update_versions(state)
        if status != "available" or latest <= installed:
            raise ManagedOtaTransportError("readback_mismatch")
        return ManagedOtaOfferEvidence(
            deviceId=device_id,
            providerRevision=post.revision,
            installedFileVersion=installed,
            latestFileVersion=latest,
            sourceDigest=hashlib.sha256(source_payload).hexdigest(),
            checkedAtMs=int(self._clock() * 1_000),
            releaseNotesAvailable=bool(data.get("release_notes")),
        )

    def install(
        self,
        device_id: str,
        expected_provider_revision: int,
        installed_file_version: int,
        latest_file_version: int,
        *,
        timeout=7_200.0,
    ):
        if not 0 < timeout <= MAX_UPDATE_SECONDS:
            raise ManagedOtaTransportError("unavailable")
        deadline = time.monotonic() + timeout
        _, ieee, friendly, state = self._fresh_target(
            device_id,
            expected_provider_revision,
            self._phase_timeout(deadline, 15.0),
        )
        installed, latest, status = _update_versions(state)
        if (
            installed != installed_file_version
            or latest != latest_file_version
            or status != "available"
        ):
            raise ManagedOtaTransportError("revision_conflict")
        data, states = self._request(
            "update", ieee, friendly,
            timeout=self._phase_timeout(deadline, MAX_UPDATE_SECONDS),
        )
        if data.get("id") not in {ieee, friendly}:
            raise ManagedOtaTransportError("readback_mismatch", ambiguous=True)
        before = data.get("from")
        after = data.get("to")
        if not isinstance(before, dict) or not isinstance(after, dict):
            raise ManagedOtaTransportError("readback_mismatch", ambiguous=True)
        from_version = _safe_version(before.get("file_version"))
        to_version = _safe_version(after.get("file_version"))
        if from_version != installed or to_version != latest:
            raise ManagedOtaTransportError("readback_mismatch", ambiguous=True)
        progress = 0
        for raw in states:
            update = raw.get("update")
            if isinstance(update, dict) and update.get("state") == "updating":
                value = update.get("progress")
                if type(value) in (int, float) and not isinstance(value, bool):
                    progress = max(progress, max(0, min(100, int(value))))
        post = self._observer.observe(
            timeout=self._phase_timeout(deadline, 15.0)
        )
        _, _, post_state = _descriptor(post, device_id)
        final_installed, final_latest, final_status = _update_versions(post_state)
        if (
            final_status != "idle"
            or final_installed != latest
            or final_latest != latest
        ):
            raise ManagedOtaTransportError("readback_mismatch", ambiguous=True)
        return ManagedOtaInstallEvidence(
            deviceId=device_id,
            previousProviderRevision=expected_provider_revision,
            providerRevision=post.revision,
            fromFileVersion=from_version,
            toFileVersion=to_version,
            installedFileVersion=final_installed,
            progressPercent=max(progress, 100),
            completedAtMs=int(self._clock() * 1_000),
        )
