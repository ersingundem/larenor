"""Durable user-confirmed provider-managed Zigbee OTA orchestration."""

from __future__ import annotations

from dataclasses import asdict, dataclass
import hashlib
import hmac
import json
import threading
from typing import Annotated, Callable, Literal

from pydantic import Field, model_validator

from ..errors import ApiError
from ..home_resources.models import FrozenModel, Identity, Revision, Snapshot
from .models import MeshAuthority, MeshTopology
from .managed_ota_transport import (
    ManagedOtaInstallEvidence,
    ManagedOtaOfferEvidence,
)

TimestampMs = Annotated[int, Field(ge=0, le=2**63 - 1)]
FileVersion = Annotated[int, Field(ge=0, le=2**32 - 1)]
OFFER_LIFETIME_MS = 5 * 60 * 1_000
PREVIEW_LIFETIME_MS = 2 * 60 * 1_000
MAX_COMMANDS = 2_048


class ManagedOtaOffer(FrozenModel):
    schemaVersion: Literal[1]
    offerId: Identity
    provider: Literal["zigbee2mqtt"]
    coreId: Identity
    homeId: Identity
    deviceId: Identity
    topologyRevision: Revision
    providerRevision: Revision
    deviceRevision: Revision
    installedFileVersion: FileVersion
    latestFileVersion: FileVersion
    providerSourceDigest: Snapshot
    checkedAtMs: TimestampMs
    expiresAtMs: TimestampMs
    releaseNotesAvailable: bool

    @model_validator(mode="after")
    def newer(self):
        if (
            self.latestFileVersion <= self.installedFileVersion
            or self.expiresAtMs <= self.checkedAtMs
        ):
            raise ValueError("invalid_managed_ota_offer")
        return self


class ManagedOtaPreview(FrozenModel):
    schemaVersion: Literal[1]
    requestId: Identity
    coreId: Identity
    homeId: Identity
    homeRevision: Revision
    accountId: Identity
    accountRevision: Revision
    memberRevision: Revision
    sessionFamilyId: Identity
    deviceId: Identity
    topologyRevision: Revision
    providerRevision: Revision
    deviceRevision: Revision
    offerId: Identity
    installedFileVersion: FileVersion
    latestFileVersion: FileVersion
    providerSourceDigest: Snapshot
    expiresAtMs: TimestampMs
    confirmationToken: Snapshot


class ManagedOtaResult(FrozenModel):
    schemaVersion: Literal[1]
    requestId: Identity
    status: Literal["confirmed", "uncertain"]
    reason: Literal["installed", "lost_ack", "readback_mismatch"]
    readbackVerified: bool
    previousProviderRevision: Revision | None
    providerRevision: Revision | None
    installedFileVersion: FileVersion | None
    completedAtMs: TimestampMs | None

    @model_validator(mode="after")
    def coherent(self):
        complete = self.status == "confirmed"
        if complete != self.readbackVerified or complete != (
            self.reason == "installed"
        ):
            raise ValueError("invalid_managed_ota_result")
        values = (
            self.previousProviderRevision,
            self.providerRevision,
            self.installedFileVersion,
            self.completedAtMs,
        )
        if complete != all(value is not None for value in values):
            raise ValueError("invalid_managed_ota_result")
        return self


class ManagedOtaCheckRequest(FrozenModel):
    schemaVersion: Literal[1]
    authority: MeshAuthority
    topology: MeshTopology
    deviceId: Identity


class ManagedOtaPreviewRequest(FrozenModel):
    schemaVersion: Literal[1]
    authority: MeshAuthority
    topology: MeshTopology
    offer: ManagedOtaOffer
    requestId: Identity


class ManagedOtaConfirmRequest(FrozenModel):
    schemaVersion: Literal[1]
    authority: MeshAuthority
    preview: ManagedOtaPreview
    confirmationToken: Snapshot


@dataclass
class _Command:
    preview: ManagedOtaPreview
    dispatchedAtMs: int | None = None
    result: ManagedOtaResult | None = None


def _canonical(value) -> bytes:
    return json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=True
    ).encode("ascii")


class ManagedOtaManager:
    def __init__(
        self,
        *,
        key: bytes,
        authorityResolver: Callable[[str], MeshAuthority | None],
        topologyResolver: Callable[[str], MeshTopology | None],
        checkWorker: Callable[[str, int], ManagedOtaOfferEvidence],
        installWorker: Callable[[ManagedOtaPreview], ManagedOtaInstallEvidence],
        clockMs: Callable[[], int],
        stateStore=None,
    ):
        if not isinstance(key, bytes) or len(key) < 32:
            raise ValueError("invalid_managed_ota_key")
        self._key = key
        self._resolve_authority = authorityResolver
        self._resolve_topology = topologyResolver
        self._check = checkWorker
        self._install = installWorker
        self._clock = clockMs
        self._store = stateStore
        self._commands: dict[str, _Command] = {}
        self._lock = threading.RLock()
        if self._store is not None:
            self._restore(self._store.load())

    def _restore(self, raw):
        try:
            if raw.get("schemaVersion") != 1 or not isinstance(raw.get("commands"), list):
                raise ValueError
            for item in raw["commands"]:
                state = _Command(
                    preview=ManagedOtaPreview.model_validate(item["preview"]),
                    dispatchedAtMs=item.get("dispatchedAtMs"),
                    result=(
                        None
                        if item.get("result") is None
                        else ManagedOtaResult.model_validate(item["result"])
                    ),
                )
                request_id = state.preview.requestId
                if request_id in self._commands:
                    raise ValueError
                if state.dispatchedAtMs is not None and (
                    type(state.dispatchedAtMs) is not int
                    or not 0 <= state.dispatchedAtMs <= 2**63 - 1
                ):
                    raise ValueError
                self._commands[request_id] = state
            if len(self._commands) > MAX_COMMANDS:
                raise ValueError
            changed = False
            for state in self._commands.values():
                if state.dispatchedAtMs is not None and state.result is None:
                    state.result = self._uncertain(state.preview, "lost_ack")
                    changed = True
            if changed:
                self._persist()
        except Exception:
            from ..errors import StartupError

            raise StartupError("mesh_managed_ota_storage_invalid") from None

    def _persist(self):
        if self._store is None:
            return
        self._store.save(
            {
                "schemaVersion": 1,
                "commands": [
                    {
                        "preview": state.preview.model_dump(mode="json"),
                        "dispatchedAtMs": state.dispatchedAtMs,
                        "result": (
                            None
                            if state.result is None
                            else state.result.model_dump(mode="json")
                        ),
                    }
                    for _, state in sorted(self._commands.items())
                ],
            }
        )

    def _authority(self, presented):
        try:
            shown = MeshAuthority.model_validate(presented)
            current = self._resolve_authority(shown.accountId)
            current = None if current is None else MeshAuthority.model_validate(current)
        except Exception:
            raise ApiError("server_unavailable", 503) from None
        if current is None or current != shown:
            raise ApiError("revision_conflict", 409)
        if (
            not shown.active
            or shown.role != "admin"
            or not shown.canObserveMesh
            or not shown.canUpdateMesh
        ):
            raise ApiError("forbidden", 403)
        return shown

    def _topology(self, authority, presented):
        try:
            shown = MeshTopology.model_validate(presented)
            current = self._resolve_topology(authority.homeId)
            current = None if current is None else MeshTopology.model_validate(current)
        except Exception:
            raise ApiError("server_unavailable", 503) from None
        if current is None or current != shown:
            raise ApiError("revision_conflict", 409)
        if (shown.coreId, shown.homeId, shown.homeRevision) != (
            authority.coreId,
            authority.homeId,
            authority.homeRevision,
        ):
            raise ApiError("revision_conflict", 409)
        return shown

    def _safe_device(self, topology, device_id):
        devices = [item for item in topology.devices if item.deviceId == device_id]
        if len(devices) != 1:
            raise ApiError("not_found", 404)
        device = devices[0]
        now = self._clock()
        if (
            device.protocol != "zigbee"
            or not topology.coordinator.online
            or not device.reachable
            or device.updating
            or device.lastSeenAtMs is None
            or device.lastSeenAtMs > now
            or now - device.lastSeenAtMs > 5 * 60 * 1_000
            or (
                device.powerSource == "battery"
                and (device.batteryPercent is None or device.batteryPercent < 70)
            )
        ):
            raise ApiError("firmware_update_safety_blocked", 409)
        return device

    def _offer_id(self, values):
        return hmac.new(
            self._key,
            b"larenor:managed-ota-offer:v1\0" + _canonical(values),
            hashlib.sha256,
        ).hexdigest()[:32]

    def _token(self, preview):
        value = preview.model_copy(update={"confirmationToken": "0" * 64})
        return hmac.new(
            self._key,
            b"larenor:managed-ota-confirm:v1\0"
            + _canonical(value.model_dump(mode="json")),
            hashlib.sha256,
        ).hexdigest()

    def check(self, presented_authority, raw_topology, device_id):
        authority = self._authority(presented_authority)
        topology = self._topology(authority, raw_topology)
        device = self._safe_device(topology, device_id)
        try:
            evidence = self._check(device.deviceId, topology.providerRevision)
        except ApiError:
            raise
        except Exception as error:
            code = getattr(error, "code", "server_unavailable")
            status = 409 if code in {
                "revision_conflict", "device_not_found", "device_unavailable",
                "battery_too_low", "no_update", "readback_mismatch"
            } else 503
            raise ApiError(code, status) from None
        if not isinstance(evidence, ManagedOtaOfferEvidence):
            raise ApiError("server_unavailable", 503)
        authority = self._authority(authority)
        current = self._resolve_topology(authority.homeId)
        if current is None:
            raise ApiError("revision_conflict", 409)
        current = MeshTopology.model_validate(current)
        current_device = self._safe_device(current, device.deviceId)
        if (
            evidence.deviceId != device.deviceId
            or current.providerRevision != evidence.providerRevision
            or current_device.providerRevision != evidence.providerRevision
            or evidence.latestFileVersion <= evidence.installedFileVersion
        ):
            raise ApiError("revision_conflict", 409)
        expires = min(evidence.checkedAtMs + OFFER_LIFETIME_MS, self._clock() + OFFER_LIFETIME_MS)
        values = {
            "coreId": authority.coreId,
            "homeId": authority.homeId,
            **asdict(evidence),
            "topologyRevision": current.revision,
            "deviceRevision": current_device.revision,
            "expiresAtMs": expires,
        }
        return ManagedOtaOffer(
            schemaVersion=1,
            offerId=self._offer_id(values),
            provider="zigbee2mqtt",
            coreId=authority.coreId,
            homeId=authority.homeId,
            deviceId=device.deviceId,
            topologyRevision=current.revision,
            providerRevision=evidence.providerRevision,
            deviceRevision=current_device.revision,
            installedFileVersion=evidence.installedFileVersion,
            latestFileVersion=evidence.latestFileVersion,
            providerSourceDigest=evidence.sourceDigest,
            checkedAtMs=evidence.checkedAtMs,
            expiresAtMs=expires,
            releaseNotesAvailable=evidence.releaseNotesAvailable,
        )

    def preview(self, presented_authority, raw_topology, raw_offer, request_id):
        authority = self._authority(presented_authority)
        topology = self._topology(authority, raw_topology)
        offer = ManagedOtaOffer.model_validate(raw_offer)
        device = self._safe_device(topology, offer.deviceId)
        now = self._clock()
        if (
            (offer.coreId, offer.homeId) != (authority.coreId, authority.homeId)
            or offer.providerRevision != topology.providerRevision
            or offer.topologyRevision != topology.revision
            or offer.deviceRevision != device.revision
            or now < offer.checkedAtMs
            or now >= offer.expiresAtMs
        ):
            raise ApiError("revision_conflict", 409)
        draft = ManagedOtaPreview(
            schemaVersion=1,
            requestId=request_id,
            coreId=authority.coreId,
            homeId=authority.homeId,
            homeRevision=authority.homeRevision,
            accountId=authority.accountId,
            accountRevision=authority.accountRevision,
            memberRevision=authority.memberRevision,
            sessionFamilyId=authority.sessionFamilyId,
            deviceId=device.deviceId,
            topologyRevision=topology.revision,
            providerRevision=topology.providerRevision,
            deviceRevision=device.revision,
            offerId=offer.offerId,
            installedFileVersion=offer.installedFileVersion,
            latestFileVersion=offer.latestFileVersion,
            providerSourceDigest=offer.providerSourceDigest,
            expiresAtMs=min(offer.expiresAtMs, now + PREVIEW_LIFETIME_MS),
            confirmationToken="0" * 64,
        )
        preview = draft.model_copy(update={"confirmationToken": self._token(draft)})
        with self._lock:
            prior = self._commands.get(request_id)
            if prior is not None:
                if prior.preview != preview:
                    raise ApiError("invalid_request")
                return prior.preview
            if len(self._commands) >= MAX_COMMANDS:
                raise ApiError("revision_conflict", 409)
            self._commands[request_id] = _Command(preview)
            try:
                self._persist()
            except Exception:
                del self._commands[request_id]
                raise
        return preview

    @staticmethod
    def _uncertain(preview, reason="lost_ack"):
        return ManagedOtaResult(
            schemaVersion=1,
            requestId=preview.requestId,
            status="uncertain",
            reason=reason,
            readbackVerified=False,
            previousProviderRevision=None,
            providerRevision=None,
            installedFileVersion=None,
            completedAtMs=None,
        )

    def confirm(self, presented_authority, raw_preview, confirmation_token):
        authority = self._authority(presented_authority)
        preview = ManagedOtaPreview.model_validate(raw_preview)
        if (
            preview.accountId != authority.accountId
            or preview.sessionFamilyId != authority.sessionFamilyId
            or preview.coreId != authority.coreId
            or preview.homeId != authority.homeId
            or not hmac.compare_digest(confirmation_token, preview.confirmationToken)
            or not hmac.compare_digest(self._token(preview), preview.confirmationToken)
        ):
            raise ApiError("revision_conflict", 409)
        with self._lock:
            existing = self._commands.get(preview.requestId)
            if existing is None or existing.preview != preview:
                raise ApiError("not_found", 404)
            if existing.result is not None:
                return existing.result
        topology = self._resolve_topology(authority.homeId)
        topology = None if topology is None else MeshTopology.model_validate(topology)
        if topology is None:
            raise ApiError("revision_conflict", 409)
        device = self._safe_device(topology, preview.deviceId)
        if (
            self._clock() >= preview.expiresAtMs
            or topology.revision != preview.topologyRevision
            or topology.providerRevision != preview.providerRevision
            or device.revision != preview.deviceRevision
        ):
            raise ApiError("revision_conflict", 409)
        with self._lock:
            state = self._commands.get(preview.requestId)
            if state is None or state.preview != preview:
                raise ApiError("not_found", 404)
            if state.result is not None:
                return state.result
            if state.dispatchedAtMs is not None:
                raise ApiError("revision_conflict", 409)
            if any(
                other.dispatchedAtMs is not None and other.result is None
                for other in self._commands.values()
            ):
                raise ApiError("mesh_update_in_progress", 409)
            state.dispatchedAtMs = self._clock()
            self._persist()
        try:
            evidence = self._install(preview)
            self._authority(authority)
            post_topology = self._resolve_topology(authority.homeId)
            post_topology = (
                None
                if post_topology is None
                else MeshTopology.model_validate(post_topology)
            )
            post_device = (
                None
                if post_topology is None
                else self._safe_device(post_topology, preview.deviceId)
            )
            if (
                not isinstance(evidence, ManagedOtaInstallEvidence)
                or evidence.deviceId != preview.deviceId
                or evidence.previousProviderRevision != preview.providerRevision
                or evidence.providerRevision <= preview.providerRevision
                or evidence.fromFileVersion != preview.installedFileVersion
                or evidence.toFileVersion != preview.latestFileVersion
                or evidence.installedFileVersion != preview.latestFileVersion
                or evidence.completedAtMs < state.dispatchedAtMs
                or post_topology is None
                or post_device is None
                or post_topology.providerRevision != evidence.providerRevision
                or post_device.providerRevision != evidence.providerRevision
                or post_device.updating
            ):
                raise ValueError("readback_mismatch")
            result = ManagedOtaResult(
                schemaVersion=1,
                requestId=preview.requestId,
                status="confirmed",
                reason="installed",
                readbackVerified=True,
                previousProviderRevision=evidence.previousProviderRevision,
                providerRevision=evidence.providerRevision,
                installedFileVersion=evidence.installedFileVersion,
                completedAtMs=evidence.completedAtMs,
            )
        except Exception as error:
            reason = "readback_mismatch" if str(error) == "readback_mismatch" else "lost_ack"
            result = self._uncertain(preview, reason)
        with self._lock:
            if state.result is None:
                state.result = result
                self._persist()
            return state.result

    def result(self, presented_authority, request_id):
        authority = self._authority(presented_authority)
        with self._lock:
            state = self._commands.get(request_id)
            if state is None or (
                state.preview.accountId,
                state.preview.sessionFamilyId,
                state.preview.coreId,
                state.preview.homeId,
            ) != (
                authority.accountId,
                authority.sessionFamilyId,
                authority.coreId,
                authority.homeId,
            ):
                raise ApiError("not_found", 404)
            if state.result is None:
                raise ApiError("mesh_update_in_progress", 409)
            return state.result
