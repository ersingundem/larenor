"""Preview-confirm orchestration for opaque, bounded IR/RF commands."""

from dataclasses import dataclass
import hashlib
import hmac
import json
import secrets
import threading
from typing import Callable

from ..errors import ApiError
from .models import (
    RemoteAuthority,
    RemoteCommandPreview,
    RemoteCommandProfile,
    RemoteCommandResult,
    RemoteDeliveryReceipt,
    RemoteDevice,
    RemoteWorkerCommand,
)


MAX_COMMANDS = 1_000
MAX_AUDIT = 10_000
PREVIEW_LIFETIME_MS = 30_000
ZERO_HASH = "0" * 64


def _canonical(value) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")


@dataclass(frozen=True)
class RemoteAuditEntry:
    sequence: int
    action: str
    requestId: str
    coreId: str
    homeId: str
    accountId: str
    sessionFamilyId: str
    deviceId: str
    deviceRevision: int
    providerRevision: int
    profileRevision: int
    codeSetRevision: int
    bindingId: str
    createdAtMs: int
    previousHash: str
    entryHash: str


@dataclass
class _CommandState:
    preview: RemoteCommandPreview
    device: RemoteDevice
    profile: RemoteCommandProfile
    result: RemoteCommandResult | None = None


class LegacyRemoteManager:
    def __init__(
        self,
        *,
        auditKey: bytes,
        authorityResolver: Callable[[str], RemoteAuthority | None],
        deviceResolver: Callable[[str], RemoteDevice | None],
        profileResolver: Callable[[str], RemoteCommandProfile | None],
        worker: Callable[[RemoteWorkerCommand], RemoteDeliveryReceipt],
        clockMs: Callable[[], int],
    ):
        if not isinstance(auditKey, bytes) or len(auditKey) < 32:
            raise ValueError("invalid_audit_key")
        self._key = auditKey
        self._resolve_authority = authorityResolver
        self._resolve_device = deviceResolver
        self._resolve_profile = profileResolver
        self._worker = worker
        self._clock = clockMs
        self._commands: dict[str, _CommandState] = {}
        self._audit: list[RemoteAuditEntry] = []
        self._lock = threading.RLock()

    @property
    def audit(self):
        with self._lock:
            self._validate_audit()
            return tuple(self._audit)

    def _authority(self, presented):
        try:
            authority = RemoteAuthority.model_validate(presented)
            current = self._resolve_authority(authority.accountId)
            current = None if current is None else RemoteAuthority.model_validate(current)
        except Exception:
            raise ApiError("forbidden", 403) from None
        if current is None:
            raise ApiError("forbidden", 403)
        if current != authority:
            raise ApiError("revision_conflict", 409)
        if not authority.active or not authority.canControlLegacyRemote:
            raise ApiError("forbidden", 403)
        return authority

    def authorize(self, presented):
        """Validate a catalog read against the same live authority as effects."""
        return self._authority(presented)

    def _entry_hash(self, values):
        return hmac.new(
            self._key,
            b"larenor:legacy-remote-audit:v1\0" + _canonical(values),
            hashlib.sha256,
        ).hexdigest()

    def _validate_audit(self):
        if len(self._audit) > MAX_AUDIT:
            raise ApiError("remote_command_integrity_failed", 503)
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
                entry.deviceRevision,
                entry.providerRevision,
                entry.profileRevision,
                entry.codeSetRevision,
                entry.bindingId,
                entry.createdAtMs,
                previous,
            ]
            if (
                entry.sequence != sequence
                or entry.action not in {"previewed", "dispatched", "uncertain"}
                or entry.previousHash != previous
                or not secrets.compare_digest(entry.entryHash, self._entry_hash(values))
            ):
                raise ApiError("remote_command_integrity_failed", 503)
            previous = entry.entryHash

    def _append_audit(self, action, preview):
        self._validate_audit()
        if len(self._audit) >= MAX_AUDIT:
            raise ApiError("remote_command_integrity_failed", 503)
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
            preview.deviceRevision,
            preview.providerRevision,
            preview.profileRevision,
            preview.codeSetRevision,
            preview.bindingId,
            created,
            previous,
        ]
        self._audit.append(
            RemoteAuditEntry(
                sequence=sequence,
                action=action,
                requestId=preview.requestId,
                coreId=preview.coreId,
                homeId=preview.homeId,
                accountId=preview.accountId,
                sessionFamilyId=preview.sessionFamilyId,
                deviceId=preview.deviceId,
                deviceRevision=preview.deviceRevision,
                providerRevision=preview.providerRevision,
                profileRevision=preview.profileRevision,
                codeSetRevision=preview.codeSetRevision,
                bindingId=preview.bindingId,
                createdAtMs=created,
                previousHash=previous,
                entryHash=self._entry_hash(values),
            )
        )

    def _token(self, preview):
        values = preview.model_dump(mode="json", exclude={"confirmationToken"})
        return hmac.new(
            self._key,
            b"larenor:legacy-remote-confirmation:v1\0" + _canonical(values),
            hashlib.sha256,
        ).hexdigest()

    def _current_device(self, authority, presented):
        try:
            device = RemoteDevice.model_validate(presented)
            current = self._resolve_device(device.deviceId)
            current = None if current is None else RemoteDevice.model_validate(current)
        except Exception:
            raise ApiError("revision_conflict", 409) from None
        if current != device or (device.coreId, device.homeId) != (
            authority.coreId,
            authority.homeId,
        ):
            raise ApiError("revision_conflict", 409)
        if not device.stored or not device.reachable or not device.providerVerified:
            raise ApiError("remote_provider_unverified", 409)
        return device

    def _current_profile(self, authority, device, presented):
        try:
            profile = RemoteCommandProfile.model_validate(presented)
            current = self._resolve_profile(profile.profileId)
            current = (
                None
                if current is None
                else RemoteCommandProfile.model_validate(current)
            )
        except Exception:
            raise ApiError("revision_conflict", 409) from None
        if current != profile or (
            profile.coreId,
            profile.homeId,
            profile.deviceId,
            profile.expectedDeviceRevision,
            profile.providerId,
            profile.expectedProviderRevision,
            profile.protocol,
        ) != (
            authority.coreId,
            authority.homeId,
            device.deviceId,
            device.revision,
            device.providerId,
            device.providerRevision,
            device.protocol,
        ):
            raise ApiError("revision_conflict", 409)
        return profile

    @staticmethod
    def _definition(profile, key, repeats, hold_ms):
        definition = next(
            (command for command in profile.commands if command.key == key),
            None,
        )
        if (
            definition is None
            or type(repeats) is not int
            or not 1 <= repeats <= definition.maxRepeats
            or type(hold_ms) is not int
            or not 0 <= hold_ms <= definition.maxHoldMs
        ):
            raise ApiError("remote_command_forbidden", 403)
        return definition

    def preview(
        self,
        presentedAuthority,
        rawDevice,
        rawProfile,
        *,
        commandKey,
        repeats,
        holdMs,
        requestId,
    ):
        authority = self._authority(presentedAuthority)
        device = self._current_device(authority, rawDevice)
        profile = self._current_profile(authority, device, rawProfile)
        definition = self._definition(profile, commandKey, repeats, holdMs)
        try:
            draft = RemoteCommandPreview(
                schemaVersion=1,
                requestId=requestId,
                coreId=authority.coreId,
                homeId=authority.homeId,
                homeRevision=authority.homeRevision,
                accountId=authority.accountId,
                accountRevision=authority.accountRevision,
                memberRevision=authority.memberRevision,
                sessionFamilyId=authority.sessionFamilyId,
                deviceId=device.deviceId,
                deviceRevision=device.revision,
                providerType=device.providerType,
                providerId=device.providerId,
                providerRevision=device.providerRevision,
                bridgeId=device.bridgeId,
                bridgeRevision=device.bridgeRevision,
                profileId=profile.profileId,
                profileRevision=profile.revision,
                codeSetId=profile.codeSetId,
                codeSetRevision=profile.codeSetRevision,
                bindingId=definition.bindingId,
                key=definition.key,
                repeats=repeats,
                holdMs=holdMs,
                expiresAtMs=self._clock() + PREVIEW_LIFETIME_MS,
                confirmationToken=ZERO_HASH,
            )
            preview = draft.model_copy(
                update={"confirmationToken": self._token(draft)}
            )
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
            self._commands[preview.requestId] = _CommandState(
                preview, device, profile
            )
            self._append_audit("previewed", preview)
            return preview

    def confirm(self, presentedAuthority, rawPreview, confirmationToken):
        authority = self._authority(presentedAuthority)
        try:
            preview = RemoteCommandPreview.model_validate(rawPreview)
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
                    preview.homeRevision,
                    preview.accountId,
                    preview.accountRevision,
                    preview.memberRevision,
                    preview.sessionFamilyId,
                )
                != (
                    authority.coreId,
                    authority.homeId,
                    authority.homeRevision,
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
                raise ApiError("remote_preview_expired", 409)
            device = self._current_device(authority, state.device)
            profile = self._current_profile(authority, device, state.profile)
            definition = self._definition(
                profile, preview.key, preview.repeats, preview.holdMs
            )
            if definition.bindingId != preview.bindingId:
                raise ApiError("revision_conflict", 409)
            command = RemoteWorkerCommand(
                schemaVersion=1,
                requestId=preview.requestId,
                coreId=preview.coreId,
                homeId=preview.homeId,
                homeRevision=preview.homeRevision,
                accountId=preview.accountId,
                accountRevision=preview.accountRevision,
                memberRevision=preview.memberRevision,
                sessionFamilyId=preview.sessionFamilyId,
                deviceId=preview.deviceId,
                deviceRevision=preview.deviceRevision,
                providerType=preview.providerType,
                providerId=preview.providerId,
                providerRevision=preview.providerRevision,
                bridgeId=preview.bridgeId,
                bridgeRevision=preview.bridgeRevision,
                profileId=preview.profileId,
                profileRevision=preview.profileRevision,
                codeSetId=preview.codeSetId,
                codeSetRevision=preview.codeSetRevision,
                bindingId=preview.bindingId,
                key=preview.key,
                repeats=preview.repeats,
                holdMs=preview.holdMs,
            )
            try:
                receipt = RemoteDeliveryReceipt.model_validate(self._worker(command))
            except Exception:
                receipt = None
            expected = RemoteDeliveryReceipt(
                schemaVersion=1,
                requestId=command.requestId,
                coreId=command.coreId,
                homeId=command.homeId,
                providerId=command.providerId,
                providerRevision=command.providerRevision,
                bridgeId=command.bridgeId,
                bridgeRevision=command.bridgeRevision,
                deviceId=command.deviceId,
                deviceRevision=command.deviceRevision,
                profileId=command.profileId,
                profileRevision=command.profileRevision,
                codeSetId=command.codeSetId,
                codeSetRevision=command.codeSetRevision,
                bindingId=command.bindingId,
                key=command.key,
                repeats=command.repeats,
                holdMs=command.holdMs,
                status="emitted",
            )
            if receipt == expected:
                result = RemoteCommandResult(
                    schemaVersion=1,
                    requestId=command.requestId,
                    status="dispatched",
                    reason=None,
                    deliveryVerified=True,
                    deviceStateVerified=False,
                    receipt=receipt,
                )
                action = "dispatched"
            else:
                result = RemoteCommandResult(
                    schemaVersion=1,
                    requestId=command.requestId,
                    status="uncertain",
                    reason="lost_ack" if receipt is None else "readback_mismatch",
                    deliveryVerified=False,
                    deviceStateVerified=False,
                    receipt=None,
                )
                action = "uncertain"
            state.result = result
            self._append_audit(action, preview)
            return result

    def result(self, presentedAuthority, requestId):
        """Read one completed result without retrying or redispatching it."""
        authority = self._authority(presentedAuthority)
        with self._lock:
            self._validate_audit()
            state = self._commands.get(requestId)
            if state is None or state.result is None:
                raise ApiError("not_found", 404)
            preview = state.preview
            if (
                preview.coreId,
                preview.homeId,
                preview.homeRevision,
                preview.accountId,
                preview.accountRevision,
                preview.memberRevision,
                preview.sessionFamilyId,
            ) != (
                authority.coreId,
                authority.homeId,
                authority.homeRevision,
                authority.accountId,
                authority.accountRevision,
                authority.memberRevision,
                authority.sessionFamilyId,
            ):
                raise ApiError("not_found", 404)
            return state.result
