from typing import Literal

from pydantic import Field, field_validator, model_validator

from ..home_resources.models import FrozenModel, Identity, Revision, Snapshot


class PresenceRouteBinding(FrozenModel):
    schemaVersion: Literal[1]
    routeId: Identity
    routeRevision: Revision
    clientSessionRevision: Revision


class PresenceClientAuthority(FrozenModel):
    schemaVersion: Literal[1]
    coreId: Identity
    homeId: Identity
    accountId: Identity
    sessionFamilyId: Identity
    routeId: Identity
    homeRevision: Revision
    accountRevision: Revision
    clientSessionRevision: Revision
    routeRevision: Revision
    bindingTag: Snapshot


class PresenceAuthorityRequest(FrozenModel):
    schemaVersion: Literal[1]
    authority: PresenceClientAuthority


class PresenceDeviceView(FrozenModel):
    schemaVersion: Literal[1]
    authority: PresenceClientAuthority
    deviceId: Identity
    deviceName: str = Field(min_length=1, max_length=80)
    deviceRevision: Revision
    modelRevision: Revision
    policyRevision: Revision
    consentRevision: Revision
    consentActive: bool
    configuredRoomId: Identity
    configuredRoomName: str = Field(min_length=1, max_length=80)
    configuredRoomRevision: Revision
    detectedRoomId: Identity | None
    detectedRoomRevision: Revision | None
    estimateRevision: Identity
    transitionRevision: int = Field(ge=0, le=2**63 - 1)
    calibrationRevision: Revision
    state: Literal["unknown", "candidate", "uncertain", "present"]
    confidencePermille: int = Field(ge=0, le=1000)
    sampleCount: int = Field(ge=0, le=64)
    observedAtMs: int = Field(ge=0, le=2**63 - 1)
    stored: Literal[True] = True
    providerReachable: bool
    advisoryOnly: Literal[True] = True
    grantsAccess: Literal[False] = False

    @field_validator("deviceName", "configuredRoomName")
    @classmethod
    def safe_label(cls, value):
        value = value.strip()
        if not value or any(ord(char) < 32 or ord(char) == 127 for char in value):
            raise ValueError("invalid_label")
        return value

    @model_validator(mode="after")
    def coherent_room(self):
        detected = (
            self.detectedRoomId is not None and self.detectedRoomRevision is not None
        )
        if (self.detectedRoomId is None) != (self.detectedRoomRevision is None):
            raise ValueError("invalid_detected_room")
        if self.state in ("present", "uncertain") and not detected:
            raise ValueError("detected_room_required")
        if self.state in ("unknown", "candidate") and detected:
            raise ValueError("detected_room_forbidden")
        if self.state == "unknown" and (
            self.confidencePermille != 0 or self.sampleCount != 0
        ):
            raise ValueError("invalid_unknown_state")
        return self


class PresenceDevicePage(FrozenModel):
    schemaVersion: Literal[1]
    authority: PresenceClientAuthority
    devices: list[PresenceDeviceView] = Field(max_length=100)


class CalibrationPreviewCommand(FrozenModel):
    schemaVersion: Literal[1]
    authority: PresenceClientAuthority
    deviceId: Identity
    expectedDeviceRevision: Revision
    expectedModelRevision: Revision
    roomId: Identity
    expectedRoomRevision: Revision
    expectedPolicyRevision: Revision
    expectedConsentRevision: Revision
    expectedCalibrationRevision: Revision


class CalibrationPreview(FrozenModel):
    schemaVersion: Literal[1]
    authority: PresenceClientAuthority
    requestId: Identity
    deviceId: Identity
    deviceRevision: Revision
    modelRevision: Revision
    roomId: Identity
    roomRevision: Revision
    policyRevision: Revision
    consentRevision: Revision
    previousCalibrationRevision: Revision
    nextCalibrationRevision: Revision
    expiresAtMs: int = Field(ge=0, le=2**63 - 1)


class CalibrationReceipt(FrozenModel):
    schemaVersion: Literal[1]
    authority: PresenceClientAuthority
    requestId: Identity
    deviceId: Identity
    deviceRevision: Revision
    modelRevision: Revision
    roomId: Identity
    roomRevision: Revision
    policyRevision: Revision
    consentRevision: Revision
    previousCalibrationRevision: Revision
    observedCalibrationRevision: Revision | None
    status: Literal["applied", "rejected", "uncertain"]


__all__ = [
    "CalibrationPreview",
    "CalibrationPreviewCommand",
    "CalibrationReceipt",
    "PresenceAuthorityRequest",
    "PresenceClientAuthority",
    "PresenceDevicePage",
    "PresenceDeviceView",
    "PresenceRouteBinding",
]
