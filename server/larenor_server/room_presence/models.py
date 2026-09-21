"""Private-input and public-output contracts for room presence fusion."""

from typing import Annotated, Literal

from pydantic import Field, model_validator

from ..home_resources.models import FrozenModel, Identity, Revision


TimestampMs = Annotated[int, Field(ge=0, le=2**63 - 1)]
Confidence = Annotated[int, Field(ge=0, le=1000)]


class PresenceAuthority(FrozenModel):
    schemaVersion: Literal[1]
    coreId: Identity
    homeId: Identity
    homeRevision: Revision
    accountId: Identity
    accountRevision: Revision
    sessionFamilyId: Identity
    active: bool
    canReadPresence: bool
    canManagePresence: bool


class PresenceRoom(FrozenModel):
    schemaVersion: Literal[1]
    coreId: Identity
    homeId: Identity
    roomId: Identity
    roomRevision: Revision


class PresenceDevice(FrozenModel):
    schemaVersion: Literal[1]
    coreId: Identity
    homeId: Identity
    deviceId: Identity
    deviceRevision: Revision
    modelId: Identity
    modelRevision: Revision
    consentId: Identity
    consentRevision: Revision
    consentActive: bool
    allowAutomationHandoff: bool


class PresenceSource(FrozenModel):
    schemaVersion: Literal[1]
    sourceId: Identity
    sourceKind: Literal["ha_person", "ha_device_tracker", "ble", "uwb"]
    sourceRevision: Revision


class PresencePolicy(FrozenModel):
    schemaVersion: Literal[1]
    coreId: Identity
    homeId: Identity
    homeRevision: Revision
    policyId: Identity
    policyRevision: Revision
    device: PresenceDevice
    sources: list[PresenceSource] = Field(min_length=1, max_length=16)
    rooms: list[PresenceRoom] = Field(min_length=1, max_length=32)
    enterConfidencePermille: Confidence
    exitConfidencePermille: Confidence
    enterObservations: int = Field(ge=1, le=10)
    exitObservations: int = Field(ge=1, le=10)
    maxSignalAgeMs: int = Field(ge=1000, le=15 * 60 * 1000)
    active: bool

    @model_validator(mode="after")
    def exact_scope_and_hysteresis(self):
        if self.enterConfidencePermille <= self.exitConfidencePermille:
            raise ValueError("invalid_hysteresis")
        if (self.device.coreId, self.device.homeId) != (self.coreId, self.homeId):
            raise ValueError("device_scope_mismatch")
        room_ids = [room.roomId for room in self.rooms]
        source_ids = [source.sourceId for source in self.sources]
        if len(room_ids) != len(set(room_ids)):
            raise ValueError("duplicate_room")
        if len(source_ids) != len(set(source_ids)):
            raise ValueError("duplicate_source")
        if any((room.coreId, room.homeId) != (self.coreId, self.homeId) for room in self.rooms):
            raise ValueError("room_scope_mismatch")
        return self


class PrivatePresenceSignal(FrozenModel):
    """Validated only inside Core; never returned or persisted by this slice."""

    schemaVersion: Literal[1]
    coreId: Identity
    homeId: Identity
    homeRevision: Revision
    roomId: Identity
    roomRevision: Revision
    deviceId: Identity
    deviceRevision: Revision
    modelId: Identity
    modelRevision: Revision
    policyId: Identity
    policyRevision: Revision
    consentId: Identity
    consentRevision: Revision
    sourceId: Identity
    sourceKind: Literal["ha_person", "ha_device_tracker", "ble", "uwb"]
    sourceRevision: Revision
    observationRevision: Revision
    rawIdentifier: str = Field(min_length=1, max_length=160)
    confidencePermille: Confidence
    observedAtMs: TimestampMs

    @model_validator(mode="after")
    def safe_raw_identity(self):
        if any(ord(char) < 32 or ord(char) == 127 for char in self.rawIdentifier):
            raise ValueError("invalid_raw_identifier")
        return self


class PresenceEstimate(FrozenModel):
    """Secret-free projection. It never conveys authentication or access."""

    schemaVersion: Literal[1]
    estimateId: Identity
    coreId: Identity
    homeId: Identity
    homeRevision: Revision
    deviceId: Identity
    deviceRevision: Revision
    modelId: Identity
    modelRevision: Revision
    policyId: Identity
    policyRevision: Revision
    consentId: Identity
    consentRevision: Revision
    status: Literal["unknown", "candidate", "uncertain", "present"]
    roomId: Identity | None
    roomRevision: Revision | None
    confidencePermille: Confidence
    observedAtMs: TimestampMs
    sampleCount: int = Field(ge=0, le=64)
    transitionRevision: Annotated[int, Field(ge=0, le=2**63 - 1)]
    advisoryOnly: Literal[True] = True
    grantsAccess: Literal[False] = False

    @model_validator(mode="after")
    def room_matches_status(self):
        if self.status in ("present", "uncertain"):
            if self.roomId is None or self.roomRevision is None:
                raise ValueError("room_required")
        elif self.roomId is not None or self.roomRevision is not None:
            raise ValueError("room_forbidden")
        if self.status == "unknown" and (self.confidencePermille != 0 or self.sampleCount != 0):
            raise ValueError("unknown_has_signal")
        return self


class PresenceAutomationCommand(FrozenModel):
    schemaVersion: Literal[1]
    commandId: Identity
    requestId: Identity
    automationId: Identity
    automationRevision: Revision
    estimateId: Identity
    transitionRevision: Revision
    deviceId: Identity
    deviceRevision: Revision
    modelRevision: Revision
    policyRevision: Revision
    consentRevision: Revision
    roomId: Identity
    roomRevision: Revision
    advisoryOnly: Literal[True] = True
    grantsAccess: Literal[False] = False


class WorkerPresenceReceipt(FrozenModel):
    schemaVersion: Literal[1]
    commandId: Identity
    requestId: Identity
    automationId: Identity
    automationRevision: Revision
    estimateId: Identity
    transitionRevision: Revision
    deviceId: Identity
    roomId: Identity
    accepted: bool
    observedState: Literal["present", "rejected", "unknown"]
    readbackRevision: Revision


class PresenceHandoffReceipt(FrozenModel):
    schemaVersion: Literal[1]
    requestId: Identity
    commandId: Identity
    automationId: Identity
    automationRevision: Revision
    estimateId: Identity
    transitionRevision: Revision
    status: Literal["verified", "rejected", "unknown"]
    verified: bool
    readbackRevision: Revision | None

    @model_validator(mode="after")
    def verified_only_for_exact_success(self):
        if self.verified != (self.status == "verified"):
            raise ValueError("invalid_verification")
        if (self.status == "unknown") != (self.readbackRevision is None):
            raise ValueError("invalid_readback")
        return self
