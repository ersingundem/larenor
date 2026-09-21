"""Deterministic shared e-paper snapshots with offline pull acknowledgements."""

import hashlib
import json
import threading
from collections.abc import Callable

from ..errors import ApiError
from .models import (
    EpaperAckResult,
    EpaperAuthority,
    EpaperDataSnapshot,
    EpaperDeliveryAck,
    EpaperDeliveryStatus,
    EpaperDevice,
    EpaperLayout,
    EpaperPolicy,
    EpaperPullEnvelope,
    EpaperRenderSnapshot,
)

MAX_DATA_AGE_MS = 300_000
FRAME_BYTES = 4_096


def _canonical(value) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")


class EpaperSnapshotService:
    def __init__(
        self,
        *,
        authorityResolver: Callable[[str], EpaperAuthority | None],
        deviceResolver: Callable[[str], EpaperDevice | None],
        layoutResolver: Callable[[str], EpaperLayout | None],
        dataResolver: Callable[[str], EpaperDataSnapshot | None],
        policyResolver: Callable[[str], EpaperPolicy | None],
        clockMs: Callable[[], int],
    ):
        self._resolve_authority = authorityResolver
        self._resolve_device = deviceResolver
        self._resolve_layout = layoutResolver
        self._resolve_data = dataResolver
        self._resolve_policy = policyResolver
        self._clock = clockMs
        self._latest: dict[str, EpaperRenderSnapshot] = {}
        self._sources: dict[
            str,
            tuple[EpaperDevice, EpaperLayout, EpaperDataSnapshot, EpaperPolicy],
        ] = {}
        self._pulls: dict[str, EpaperPullEnvelope] = {}
        self._acks: dict[str, tuple[EpaperDeliveryAck, EpaperAckResult]] = {}
        self._status: dict[str, EpaperAckResult] = {}
        self._lock = threading.RLock()

    def _authority(self, presented):
        try:
            authority = EpaperAuthority.model_validate(presented)
            current = self._resolve_authority(authority.accountId)
            current = None if current is None else EpaperAuthority.model_validate(current)
        except Exception:  # noqa: BLE001 - fail closed across injected resolvers
            raise ApiError("forbidden", 403) from None
        if current is None:
            raise ApiError("forbidden", 403)
        if current != authority:
            raise ApiError("revision_conflict", 409)
        if not authority.active or not authority.canPublishEpaper:
            raise ApiError("forbidden", 403)
        return authority

    @staticmethod
    def _validated(raw, model, resolver, identity, authority):
        try:
            presented = model.model_validate(raw)
            current = resolver(identity)
            current = None if current is None else model.model_validate(current)
        except Exception:  # noqa: BLE001 - fail closed across injected resolvers
            raise ApiError("epaper_content_rejected", 400) from None
        if current != presented:
            raise ApiError("revision_conflict", 409)
        if (presented.coreId, presented.homeId) != (
            authority.coreId,
            authority.homeId,
        ):
            raise ApiError("revision_conflict", 409)
        return presented

    def _device(self, authority, raw):
        try:
            presented = EpaperDevice.model_validate(raw)
            current = self._resolve_device(presented.deviceId)
            current = None if current is None else EpaperDevice.model_validate(current)
        except Exception:  # noqa: BLE001 - fail closed across injected resolvers
            raise ApiError("epaper_content_rejected", 400) from None
        if current != presented or (presented.coreId, presented.homeId) != (
            authority.coreId,
            authority.homeId,
        ):
            raise ApiError("revision_conflict", 409)
        if not presented.active:
            raise ApiError("epaper_device_unavailable", 409)
        return presented

    def _current_device_id(self, authority, device_id):
        try:
            current = self._resolve_device(device_id)
            current = None if current is None else EpaperDevice.model_validate(current)
        except Exception:  # noqa: BLE001 - fail closed across injected resolvers
            raise ApiError("revision_conflict", 409) from None
        if current is None or (current.coreId, current.homeId) != (
            authority.coreId,
            authority.homeId,
        ):
            raise ApiError("revision_conflict", 409)
        if not current.active:
            raise ApiError("epaper_device_unavailable", 409)
        return current

    def compose(
        self,
        presentedAuthority,
        rawDevice,
        rawLayout,
        rawData,
        rawPolicy,
        *,
        ttlSeconds,
    ):
        authority = self._authority(presentedAuthority)
        device = self._device(authority, rawDevice)
        try:
            layout_identity = rawLayout.layoutId
        except AttributeError:
            layout_identity = rawLayout.get("layoutId") if isinstance(rawLayout, dict) else None
        try:
            data_identity = rawData.dataId
        except AttributeError:
            data_identity = rawData.get("dataId") if isinstance(rawData, dict) else None
        try:
            policy_identity = rawPolicy.policyId
        except AttributeError:
            policy_identity = rawPolicy.get("policyId") if isinstance(rawPolicy, dict) else None
        layout = self._validated(
            rawLayout, EpaperLayout, self._resolve_layout, layout_identity, authority
        )
        data = self._validated(
            rawData, EpaperDataSnapshot, self._resolve_data, data_identity, authority
        )
        policy = self._validated(
            rawPolicy, EpaperPolicy, self._resolve_policy, policy_identity, authority
        )
        now = self._clock()
        if (
            type(ttlSeconds) is not int
            or not 60 <= ttlSeconds <= policy.maxTtlSeconds
            or data.capturedAtMs > now
            or now - data.capturedAtMs > MAX_DATA_AGE_MS
        ):
            raise ApiError("epaper_content_rejected", 400)
        slot_map = {slot.slotId: slot for slot in layout.slots}
        card_map = {card.slotId: card for card in data.cards}
        ordered_cards = [card_map[slot.slotId] for slot in layout.slots]
        if (
            layout.width != device.width
            or layout.height != device.height
            or not set(layout.colors) <= set(device.supportedColors)
            or not set(layout.colors) <= set(policy.allowedColors)
            or len(layout.slots) > policy.maxCards
            or set(slot_map) != set(card_map)
            or any(slot.kind not in policy.allowedKinds for slot in layout.slots)
            or any(
                card.kind != slot_map[card.slotId].kind
                or card.accent not in layout.colors
                or card.kind not in policy.allowedKinds
                for card in data.cards
            )
        ):
            raise ApiError("epaper_content_rejected", 400)
        base = {
            "schemaVersion": 1,
            "coreId": authority.coreId,
            "homeId": authority.homeId,
            "homeRevision": authority.homeRevision,
            "deviceId": device.deviceId,
            "deviceRevision": device.revision,
            "bridgeRevision": device.bridgeRevision,
            "layoutId": layout.layoutId,
            "layoutRevision": layout.revision,
            "dataId": data.dataId,
            "dataRevision": data.revision,
            "dataProviderRevision": data.providerRevision,
            "policyId": policy.policyId,
            "policyRevision": policy.revision,
            "width": layout.width,
            "height": layout.height,
            "colors": layout.colors,
            "cards": [card.model_dump(mode="json") for card in ordered_cards],
            "createdAtMs": now,
            "expiresAtMs": now + ttlSeconds * 1_000,
        }
        digest = hashlib.sha256(
            b"larenor:epaper-render:v1\0" + _canonical(base)
        ).hexdigest()
        snapshot = EpaperRenderSnapshot(
            snapshotId=digest[:32],
            renderDigest=digest,
            **base,
        )
        with self._lock:
            previous = self._latest.get(device.deviceId)
            self._latest[device.deviceId] = snapshot
            self._sources[device.deviceId] = (device, layout, data, policy)
            if previous is None or previous.renderDigest != snapshot.renderDigest:
                self._status.pop(device.deviceId, None)
            return snapshot

    def _exact_latest(self, authority, device):
        snapshot = self._latest.get(device.deviceId)
        sources = self._sources.get(device.deviceId)
        if snapshot is None or sources is None:
            raise ApiError("not_found", 404)
        source_device, layout, data, policy = sources
        try:
            current_layout = EpaperLayout.model_validate(
                self._resolve_layout(layout.layoutId)
            )
            current_data = EpaperDataSnapshot.model_validate(
                self._resolve_data(data.dataId)
            )
            current_policy = EpaperPolicy.model_validate(
                self._resolve_policy(policy.policyId)
            )
        except Exception:  # noqa: BLE001 - fail closed across injected resolvers
            raise ApiError("revision_conflict", 409) from None
        if (
            snapshot.deviceRevision != device.revision
            or source_device != device
            or current_layout != layout
            or current_data != data
            or current_policy != policy
            or any(
                (item.coreId, item.homeId) != (authority.coreId, authority.homeId)
                for item in (current_layout, current_data, current_policy)
            )
        ):
            raise ApiError("revision_conflict", 409)
        return snapshot

    def _fresh_latest(self, authority, device):
        snapshot = self._exact_latest(authority, device)
        if self._clock() >= snapshot.expiresAtMs:
            raise ApiError("epaper_snapshot_stale", 409)
        return snapshot

    @staticmethod
    def _transfer_shape(snapshot):
        byte_length = len(_canonical(snapshot.model_dump(mode="json")))
        frame_count = (byte_length + FRAME_BYTES - 1) // FRAME_BYTES
        return byte_length, frame_count

    def pull(self, presentedAuthority, *, deviceId, requestId):
        authority = self._authority(presentedAuthority)
        device = self._current_device_id(authority, deviceId)
        with self._lock:
            snapshot = self._fresh_latest(authority, device)
            byte_length, frame_count = self._transfer_shape(snapshot)
            try:
                envelope = EpaperPullEnvelope(
                    schemaVersion=1,
                    requestId=requestId,
                    deviceId=device.deviceId,
                    deviceRevision=device.revision,
                    deviceConnectivity=device.connectivity,
                    snapshot=snapshot,
                    byteLength=byte_length,
                    frameCount=frame_count,
                )
            except Exception:  # noqa: BLE001 - pydantic closes malformed envelopes
                raise ApiError("invalid_request") from None
            prior = self._pulls.get(envelope.requestId)
            if prior is not None:
                if prior != envelope:
                    raise ApiError("revision_conflict", 409)
                return prior
            self._pulls[envelope.requestId] = envelope
            return envelope

    def acknowledge(self, presentedAuthority, rawAck):
        authority = self._authority(presentedAuthority)
        try:
            ack = EpaperDeliveryAck.model_validate(rawAck)
        except Exception:  # noqa: BLE001 - pydantic closes malformed acknowledgements
            raise ApiError("invalid_request") from None
        if (ack.coreId, ack.homeId) != (authority.coreId, authority.homeId):
            raise ApiError("revision_conflict", 409)
        device = self._current_device_id(authority, ack.deviceId)
        with self._lock:
            snapshot = self._fresh_latest(authority, device)
            pull = self._pulls.get(ack.requestId)
            if pull is None or pull.snapshot.renderDigest != snapshot.renderDigest:
                raise ApiError("revision_conflict", 409)
            expected = (
                device.revision,
                snapshot.layoutRevision,
                snapshot.dataRevision,
                snapshot.policyRevision,
                snapshot.renderDigest,
                pull.byteLength,
                pull.frameCount,
            )
            actual = (
                ack.deviceRevision,
                ack.layoutRevision,
                ack.dataRevision,
                ack.policyRevision,
                ack.renderDigest,
                ack.byteLength,
                ack.frameCount,
            )
            if actual != expected:
                raise ApiError("revision_conflict", 409)
            if (
                ack.status == "complete" and ack.receivedFrames != ack.frameCount
            ) or (
                ack.status == "partial" and ack.receivedFrames >= ack.frameCount
            ):
                raise ApiError("invalid_request")
            result = EpaperAckResult(
                schemaVersion=1,
                requestId=ack.requestId,
                status="verified" if ack.status == "complete" else "partial",
                verified=ack.status == "complete",
                snapshotDigest=snapshot.renderDigest,
            )
            prior = self._acks.get(ack.requestId)
            if prior is not None:
                if prior != (ack, result):
                    raise ApiError("revision_conflict", 409)
                return prior[1]
            self._acks[ack.requestId] = (ack, result)
            self._status[device.deviceId] = result
            return result

    def delivery_status(self, presentedAuthority, *, deviceId):
        authority = self._authority(presentedAuthority)
        device = self._current_device_id(authority, deviceId)
        with self._lock:
            snapshot = self._latest.get(device.deviceId)
            if snapshot is None:
                return EpaperDeliveryStatus(
                    schemaVersion=1,
                    deviceId=device.deviceId,
                    snapshotDigest=None,
                    status="empty",
                    verifiedDigest=None,
                )
            self._exact_latest(authority, device)
            if self._clock() >= snapshot.expiresAtMs:
                status = "stale"
                result = None
            else:
                result = self._status.get(device.deviceId)
                status = "pending" if result is None else result.status
            return EpaperDeliveryStatus(
                schemaVersion=1,
                deviceId=device.deviceId,
                snapshotDigest=snapshot.renderDigest,
                status=status,
                verifiedDigest=(
                    snapshot.renderDigest
                    if result is not None and result.verified
                    else None
                ),
            )
