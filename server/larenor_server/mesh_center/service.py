"""Read-only mesh health and explicit, verified Zigbee firmware updates."""

import hashlib
import hmac
import json
import secrets
import threading
from collections.abc import Callable
from dataclasses import dataclass

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

from ..errors import ApiError
from .models import (
    ChannelAdvisory,
    FirmwareCatalog,
    FirmwareCatalogEntry,
    FirmwareUpdateCommand,
    FirmwareUpdatePreview,
    FirmwareUpdateReadback,
    FirmwareUpdateResult,
    InterferenceSnapshot,
    MeshAuthority,
    MeshHealthReport,
    MeshTopology,
)

MAX_COMMANDS = 1_000
MAX_AUDIT = 10_000
MAX_SNAPSHOT_AGE_MS = 300_000
MAX_CATALOG_LIFETIME_MS = 30 * 24 * 60 * 60 * 1_000
PREVIEW_LIFETIME_MS = 300_000
ZERO_HASH = "0" * 64


def _canonical(value) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")


def firmware_catalog_payload(catalog: FirmwareCatalog) -> bytes:
    """Canonical signed bytes; the signature itself is never recursive."""
    parsed = FirmwareCatalog.model_validate(catalog)
    return _canonical(parsed.model_dump(mode="json", exclude={"signature"}))


def _version(value: str) -> tuple[int, int, int]:
    return tuple(int(part) for part in value.split("."))


def _authority(resolver, presented, *, control: bool) -> MeshAuthority:
    try:
        authority = MeshAuthority.model_validate(presented)
        current = resolver(authority.accountId)
        current = None if current is None else MeshAuthority.model_validate(current)
    except Exception:
        raise ApiError("forbidden", 403) from None
    if current is None:
        raise ApiError("forbidden", 403)
    if current != authority:
        raise ApiError("revision_conflict", 409)
    if not authority.active or not authority.canObserveMesh:
        raise ApiError("forbidden", 403)
    if control and (authority.role != "admin" or not authority.canUpdateMesh):
        raise ApiError("forbidden", 403)
    return authority


class MeshHealthService:
    def __init__(
        self,
        *,
        authorityResolver: Callable[[str], MeshAuthority | None],
        topologyResolver: Callable[[str], MeshTopology | None],
        interferenceResolver: Callable[[str], InterferenceSnapshot | None],
        clockMs: Callable[[], int],
    ):
        self._resolve_authority = authorityResolver
        self._resolve_topology = topologyResolver
        self._resolve_interference = interferenceResolver
        self._clock = clockMs

    def _topology(self, authority, raw):
        try:
            topology = MeshTopology.model_validate(raw)
        except Exception:
            raise ApiError("invalid_request") from None
        try:
            current = self._resolve_topology(authority.homeId)
            current = None if current is None else MeshTopology.model_validate(current)
        except Exception:
            raise ApiError("server_unavailable", 503) from None
        if current is None:
            raise ApiError("not_found", 404)
        if current != topology or (
            topology.coreId,
            topology.homeId,
            topology.homeRevision,
        ) != (authority.coreId, authority.homeId, authority.homeRevision):
            raise ApiError("revision_conflict", 409)
        self._fresh(topology.capturedAtMs)
        return topology

    def _interference(self, authority, raw):
        try:
            snapshot = InterferenceSnapshot.model_validate(raw)
        except Exception:
            raise ApiError("invalid_request") from None
        try:
            current = self._resolve_interference(authority.homeId)
            current = (
                None
                if current is None
                else InterferenceSnapshot.model_validate(current)
            )
        except Exception:
            raise ApiError("server_unavailable", 503) from None
        if current is None:
            raise ApiError("not_found", 404)
        if current != snapshot or (snapshot.coreId, snapshot.homeId) != (
            authority.coreId,
            authority.homeId,
        ):
            raise ApiError("revision_conflict", 409)
        self._fresh(snapshot.capturedAtMs)
        return snapshot

    def _fresh(self, captured_at):
        now = self._clock()
        if captured_at > now or now - captured_at > MAX_SNAPSHOT_AGE_MS:
            raise ApiError("mesh_snapshot_stale", 409)

    def observe(self, presentedAuthority, rawTopology, rawInterference):
        authority = _authority(
            self._resolve_authority, presentedAuthority, control=False
        )
        topology = self._topology(authority, rawTopology)
        interference = self._interference(authority, rawInterference)
        channels = {item.channel: item for item in interference.channels}
        current = channels.get(topology.coordinator.channel)
        candidates = [
            channels[channel] for channel in (11, 15, 20, 25) if channel in channels
        ]
        if current is None or not candidates:
            raise ApiError("mesh_interference_incomplete", 409)
        recommended = min(
            candidates,
            key=lambda item: (item.utilizationPercent, item.energyDbm, item.channel),
        )
        offline_devices = sorted(
            device.deviceId for device in topology.devices if not device.reachable
        )
        low_battery = sorted(
            device.deviceId
            for device in topology.devices
            if device.powerSource == "battery" and device.batteryPercent < 20
        )
        offline_routers = sorted(
            router.nodeId for router in topology.borderRouters if not router.online
        )
        if not topology.coordinator.online:
            status = "unavailable"
        elif (
            offline_devices
            or low_battery
            or offline_routers
            or current.utilizationPercent >= 80
        ):
            status = "degraded"
        else:
            status = "healthy"
        return MeshHealthReport(
            schemaVersion=1,
            coreId=topology.coreId,
            homeId=topology.homeId,
            topologyRevision=topology.revision,
            interferenceRevision=interference.revision,
            readOnly=True,
            status=status,
            offlineDeviceIds=offline_devices,
            lowBatteryDeviceIds=low_battery,
            threadBorderRouterCount=len(topology.borderRouters),
            offlineBorderRouterIds=offline_routers,
            channelAdvisory=ChannelAdvisory(
                advisory=True,
                currentChannel=current.channel,
                recommendedChannel=recommended.channel,
                currentUtilizationPercent=current.utilizationPercent,
                recommendedUtilizationPercent=recommended.utilizationPercent,
                reason=(
                    "current_channel_best"
                    if current.channel == recommended.channel
                    else "lower_interference"
                ),
                applied=False,
            ),
        )


@dataclass(frozen=True)
class MeshUpdateAuditEntry:
    sequence: int
    action: str
    requestId: str
    coreId: str
    homeId: str
    accountId: str
    sessionFamilyId: str
    deviceId: str
    topologyRevision: int
    catalogRevision: int
    firmwareSha256: str
    createdAtMs: int
    previousHash: str
    entryHash: str


@dataclass
class _UpdateState:
    preview: FirmwareUpdatePreview
    topology: MeshTopology
    catalog: FirmwareCatalog
    entry: FirmwareCatalogEntry
    result: FirmwareUpdateResult | None = None


class FirmwareUpdateManager:
    def __init__(
        self,
        *,
        auditKey: bytes,
        authorityResolver: Callable[[str], MeshAuthority | None],
        topologyResolver: Callable[[str], MeshTopology | None],
        catalogResolver: Callable[[str], FirmwareCatalog | None],
        signingKeyResolver: Callable[[str], bytes | None],
        worker: Callable[[FirmwareUpdateCommand], FirmwareUpdateReadback],
        clockMs: Callable[[], int],
    ):
        if not isinstance(auditKey, bytes) or len(auditKey) < 32:
            raise ValueError("invalid_audit_key")
        self._key = auditKey
        self._resolve_authority = authorityResolver
        self._resolve_topology = topologyResolver
        self._resolve_catalog = catalogResolver
        self._resolve_signing_key = signingKeyResolver
        self._worker = worker
        self._clock = clockMs
        self._commands: dict[str, _UpdateState] = {}
        self._audit: list[MeshUpdateAuditEntry] = []
        self._lock = threading.RLock()

    @property
    def audit(self):
        with self._lock:
            self._validate_audit()
            return tuple(self._audit)

    def _authority(self, presented):
        return _authority(self._resolve_authority, presented, control=True)

    def _entry_hash(self, values):
        return hmac.new(
            self._key,
            b"larenor:mesh-update-audit:v1\0" + _canonical(values),
            hashlib.sha256,
        ).hexdigest()

    def _validate_audit(self):
        if len(self._audit) > MAX_AUDIT:
            raise ApiError("mesh_update_integrity_failed", 503)
        previous = ZERO_HASH
        for sequence, entry in enumerate(self._audit, 1):
            values = [
                sequence,
                entry.action,
                entry.requestId,
                entry.coreId,
                entry.homeId,
                entry.accountId,
                entry.sessionFamilyId,
                entry.deviceId,
                entry.topologyRevision,
                entry.catalogRevision,
                entry.firmwareSha256,
                entry.createdAtMs,
                previous,
            ]
            if (
                entry.sequence != sequence
                or entry.action not in {"previewed", "confirmed", "uncertain"}
                or entry.previousHash != previous
                or not secrets.compare_digest(entry.entryHash, self._entry_hash(values))
            ):
                raise ApiError("mesh_update_integrity_failed", 503)
            previous = entry.entryHash

    def _append_audit(self, action, preview):
        self._validate_audit()
        if len(self._audit) >= MAX_AUDIT:
            raise ApiError("mesh_update_integrity_failed", 503)
        sequence = len(self._audit) + 1
        previous = self._audit[-1].entryHash if self._audit else ZERO_HASH
        created = self._clock()
        values = [
            sequence,
            action,
            preview.requestId,
            preview.coreId,
            preview.homeId,
            preview.accountId,
            preview.sessionFamilyId,
            preview.deviceId,
            preview.topologyRevision,
            preview.catalogRevision,
            preview.firmwareSha256,
            created,
            previous,
        ]
        self._audit.append(
            MeshUpdateAuditEntry(
                sequence=sequence,
                action=action,
                requestId=preview.requestId,
                coreId=preview.coreId,
                homeId=preview.homeId,
                accountId=preview.accountId,
                sessionFamilyId=preview.sessionFamilyId,
                deviceId=preview.deviceId,
                topologyRevision=preview.topologyRevision,
                catalogRevision=preview.catalogRevision,
                firmwareSha256=preview.firmwareSha256,
                createdAtMs=created,
                previousHash=previous,
                entryHash=self._entry_hash(values),
            )
        )

    @staticmethod
    def _preview_values(preview):
        return preview.model_dump(mode="json", exclude={"confirmationToken"})

    def _token(self, preview):
        return hmac.new(
            self._key,
            b"larenor:mesh-update-confirmation:v1\0"
            + _canonical(self._preview_values(preview)),
            hashlib.sha256,
        ).hexdigest()

    def _current_topology(self, authority, presented):
        try:
            topology = MeshTopology.model_validate(presented)
            current = self._resolve_topology(authority.homeId)
            current = None if current is None else MeshTopology.model_validate(current)
        except Exception:
            raise ApiError("revision_conflict", 409) from None
        if current != topology or (
            topology.coreId,
            topology.homeId,
            topology.homeRevision,
        ) != (authority.coreId, authority.homeId, authority.homeRevision):
            raise ApiError("revision_conflict", 409)
        now = self._clock()
        if (
            topology.capturedAtMs > now
            or now - topology.capturedAtMs > MAX_SNAPSHOT_AGE_MS
        ):
            raise ApiError("mesh_snapshot_stale", 409)
        return topology

    def _current_catalog(self, presented):
        try:
            catalog = FirmwareCatalog.model_validate(presented)
            current = self._resolve_catalog(catalog.catalogId)
            current = (
                None if current is None else FirmwareCatalog.model_validate(current)
            )
        except Exception:
            raise ApiError("revision_conflict", 409) from None
        if current != catalog:
            raise ApiError("revision_conflict", 409)
        now = self._clock()
        if (
            catalog.generatedAtMs > now
            or now >= catalog.expiresAtMs
            or catalog.expiresAtMs - catalog.generatedAtMs > MAX_CATALOG_LIFETIME_MS
        ):
            raise ApiError("firmware_catalog_stale", 409)
        try:
            public_bytes = self._resolve_signing_key(catalog.signingKeyId)
            if not isinstance(public_bytes, bytes) or len(public_bytes) != 32:
                raise ValueError
            Ed25519PublicKey.from_public_bytes(public_bytes).verify(
                bytes.fromhex(catalog.signature), firmware_catalog_payload(catalog)
            )
        except Exception:
            raise ApiError("firmware_signature_invalid", 409) from None
        return catalog

    def _safe_entry(self, topology, catalog, device_id, firmware_id):
        devices = {device.deviceId: device for device in topology.devices}
        device = devices.get(device_id)
        entry = next(
            (item for item in catalog.entries if item.firmwareId == firmware_id),
            None,
        )
        if device is None or entry is None:
            raise ApiError("not_found", 404)
        if device.protocol != "zigbee" or entry.protocol != "zigbee":
            raise ApiError("firmware_update_unsupported", 409)
        if (
            device.manufacturer != entry.manufacturer
            or device.model != entry.model
            or device.hardwareRevision not in entry.compatibleHardwareRevisions
            or device.firmwareVersion not in entry.sourceVersions
            or _version(entry.version) <= _version(device.firmwareVersion)
        ):
            raise ApiError("firmware_incompatible", 409)
        parents = {topology.coordinator.nodeId: topology.coordinator.online}
        parents.update(
            {router.nodeId: router.online for router in topology.borderRouters}
        )
        parents.update({item.deviceId: item.reachable for item in topology.devices})
        now = self._clock()
        battery_safe = (
            device.powerSource == "mains"
            or device.batteryPercent >= entry.minimumBatteryPercent
        )
        if (
            not topology.coordinator.online
            or not device.reachable
            or device.updating
            or not parents.get(device.parentId, False)
            or device.routeDepth > 16
            or device.lastSeenAtMs > now
            or now - device.lastSeenAtMs > MAX_SNAPSHOT_AGE_MS
            or not battery_safe
            or (entry.requiresMains and device.powerSource != "mains")
        ):
            raise ApiError("firmware_update_safety_blocked", 409)
        return device, entry

    def preview(
        self,
        presentedAuthority,
        rawTopology,
        rawCatalog,
        *,
        deviceId,
        firmwareId,
        requestId,
    ):
        authority = self._authority(presentedAuthority)
        topology = self._current_topology(authority, rawTopology)
        catalog = self._current_catalog(rawCatalog)
        device, entry = self._safe_entry(topology, catalog, deviceId, firmwareId)
        expires = min(self._clock() + PREVIEW_LIFETIME_MS, catalog.expiresAtMs)
        try:
            draft = FirmwareUpdatePreview(
                schemaVersion=1,
                requestId=requestId,
                coreId=authority.coreId,
                homeId=authority.homeId,
                homeRevision=authority.homeRevision,
                accountId=authority.accountId,
                accountRevision=authority.accountRevision,
                memberRevision=authority.memberRevision,
                sessionFamilyId=authority.sessionFamilyId,
                topologyRevision=topology.revision,
                topologyProviderRevision=topology.providerRevision,
                coordinatorRevision=topology.coordinator.revision,
                deviceId=device.deviceId,
                expectedDeviceRevision=device.revision,
                expectedResultRevision=device.revision + 1,
                expectedProviderRevision=device.providerRevision,
                expectedRouteRevision=device.routeRevision,
                catalogId=catalog.catalogId,
                catalogRevision=catalog.revision,
                catalogProviderRevision=catalog.providerRevision,
                firmwareId=entry.firmwareId,
                firmwareSha256=entry.sha256,
                targetVersion=entry.version,
                expiresAtMs=expires,
                confirmationToken=ZERO_HASH,
            )
            preview = draft.model_copy(update={"confirmationToken": self._token(draft)})
        except Exception:
            raise ApiError("invalid_request") from None
        with self._lock:
            self._validate_audit()
            prior = self._commands.get(preview.requestId)
            if prior is not None:
                if prior.preview != preview:
                    raise ApiError("invalid_request")
                return prior.preview
            if len(self._commands) >= MAX_COMMANDS:
                raise ApiError("revision_conflict", 409)
            self._commands[preview.requestId] = _UpdateState(
                preview, topology, catalog, entry
            )
            self._append_audit("previewed", preview)
            return preview

    def confirm(self, presentedAuthority, rawPreview, confirmationToken):
        authority = self._authority(presentedAuthority)
        try:
            preview = FirmwareUpdatePreview.model_validate(rawPreview)
        except Exception:
            raise ApiError("invalid_request") from None
        with self._lock:
            self._validate_audit()
            state = self._commands.get(preview.requestId)
            if (
                state is None
                or state.preview != preview
                or not isinstance(confirmationToken, str)
                or not secrets.compare_digest(confirmationToken, self._token(preview))
                or (
                    preview.coreId,
                    preview.homeId,
                    preview.accountId,
                    preview.accountRevision,
                    preview.memberRevision,
                    preview.sessionFamilyId,
                )
                != (
                    authority.coreId,
                    authority.homeId,
                    authority.accountId,
                    authority.accountRevision,
                    authority.memberRevision,
                    authority.sessionFamilyId,
                )
            ):
                raise ApiError("invalid_request")
            if state.result is not None:
                return state.result
            if self._clock() >= preview.expiresAtMs:
                raise ApiError("invalid_request")
            topology = self._current_topology(authority, state.topology)
            catalog = self._current_catalog(state.catalog)
            device, entry = self._safe_entry(
                topology, catalog, preview.deviceId, preview.firmwareId
            )
            if (
                device.revision + 1 != preview.expectedResultRevision
                or entry != state.entry
            ):
                raise ApiError("revision_conflict", 409)
            command = FirmwareUpdateCommand(
                schemaVersion=1,
                requestId=preview.requestId,
                coreId=preview.coreId,
                homeId=preview.homeId,
                homeRevision=preview.homeRevision,
                accountId=preview.accountId,
                accountRevision=preview.accountRevision,
                memberRevision=preview.memberRevision,
                sessionFamilyId=preview.sessionFamilyId,
                topologyRevision=preview.topologyRevision,
                topologyProviderRevision=preview.topologyProviderRevision,
                coordinatorRevision=preview.coordinatorRevision,
                deviceId=preview.deviceId,
                expectedDeviceRevision=preview.expectedDeviceRevision,
                expectedResultRevision=preview.expectedResultRevision,
                expectedProviderRevision=preview.expectedProviderRevision,
                expectedRouteRevision=preview.expectedRouteRevision,
                catalogRevision=preview.catalogRevision,
                catalogProviderRevision=preview.catalogProviderRevision,
                firmwareId=preview.firmwareId,
                firmwareSha256=preview.firmwareSha256,
                firmwareSizeBytes=entry.sizeBytes,
                targetVersion=preview.targetVersion,
            )
            try:
                readback = FirmwareUpdateReadback.model_validate(self._worker(command))
            except Exception:
                readback = None
            expected = FirmwareUpdateReadback(
                schemaVersion=1,
                requestId=command.requestId,
                coreId=command.coreId,
                homeId=command.homeId,
                deviceId=command.deviceId,
                previousDeviceRevision=command.expectedDeviceRevision,
                deviceRevision=command.expectedResultRevision,
                providerRevision=command.expectedProviderRevision,
                routeRevision=command.expectedRouteRevision,
                installedVersion=command.targetVersion,
                installedSha256=command.firmwareSha256,
                status="installed",
            )
            if readback == expected:
                result = FirmwareUpdateResult(
                    schemaVersion=1,
                    requestId=command.requestId,
                    status="confirmed",
                    reason=None,
                    readbackVerified=True,
                    readback=readback,
                )
                action = "confirmed"
            else:
                result = FirmwareUpdateResult(
                    schemaVersion=1,
                    requestId=command.requestId,
                    status="uncertain",
                    reason="lost_ack" if readback is None else "readback_mismatch",
                    readbackVerified=False,
                    readback=None,
                )
                action = "uncertain"
            state.result = result
            self._append_audit(action, preview)
            return result

    def result(self, presentedAuthority, requestId):
        """Read one existing result without dispatching or replaying its command."""
        authority = self._authority(presentedAuthority)
        if not isinstance(requestId, str):
            raise ApiError("invalid_request")
        with self._lock:
            self._validate_audit()
            state = self._commands.get(requestId)
            if state is None:
                raise ApiError("not_found", 404)
            preview = state.preview
            if (
                preview.coreId,
                preview.homeId,
                preview.accountId,
                preview.accountRevision,
                preview.memberRevision,
                preview.sessionFamilyId,
            ) != (
                authority.coreId,
                authority.homeId,
                authority.accountId,
                authority.accountRevision,
                authority.memberRevision,
                authority.sessionFamilyId,
            ):
                raise ApiError("forbidden", 403)
            if state.result is None:
                raise ApiError("not_found", 404)
            return state.result
