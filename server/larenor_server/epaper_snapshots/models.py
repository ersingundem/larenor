"""Closed, low-color and shared-content contracts for e-paper displays."""

import re
from typing import Annotated, Literal

from pydantic import Field, field_validator, model_validator

from ..home_resources.models import FrozenModel, Identity, Revision, Snapshot


TimestampMs = Annotated[int, Field(ge=0, le=2**63 - 1)]
Color = Literal["black", "white", "red", "yellow"]
CardKind = Literal["weather", "energy", "temperature", "clock", "battery"]
Connectivity = Literal["online", "offline", "unknown"]
_PRIVATE = re.compile(
    r"(?:bearer\s+|password|secret|token|api[ _-]?key|-----begin|eyJ[a-zA-Z0-9_-]{12})",
    re.IGNORECASE,
)


def _shared_text(value: str, *, maximum: int) -> str:
    if not isinstance(value, str) or not 1 <= len(value) <= maximum:
        raise ValueError("invalid_shared_text")
    if value != value.strip() or any(
        ord(character) < 32
        or ord(character) == 127
        or 0xD800 <= ord(character) <= 0xDFFF
        for character in value
    ):
        raise ValueError("invalid_shared_text")
    if "://" in value or _PRIVATE.search(value):
        raise ValueError("private_content_rejected")
    return value


class EpaperAuthority(FrozenModel):
    schemaVersion: Literal[1]
    coreId: Identity
    homeId: Identity
    homeRevision: Revision
    accountId: Identity
    accountRevision: Revision
    memberRevision: Revision
    sessionFamilyId: Identity
    active: bool
    canPublishEpaper: bool


class EpaperDevice(FrozenModel):
    schemaVersion: Literal[1]
    coreId: Identity
    homeId: Identity
    deviceId: Identity
    revision: Revision
    bridgeRevision: Revision
    width: int = Field(ge=64, le=2_048)
    height: int = Field(ge=32, le=2_048)
    supportedColors: list[Color] = Field(min_length=2, max_length=4)
    active: bool
    connectivity: Connectivity
    batteryPercent: int = Field(ge=0, le=100)
    lastSeenAtMs: TimestampMs

    @field_validator("supportedColors")
    @classmethod
    def unique_colors(cls, value):
        if "black" not in value or "white" not in value or len(value) != len(set(value)):
            raise ValueError("invalid_epaper_colors")
        return value


class EpaperCardSlot(FrozenModel):
    schemaVersion: Literal[1]
    slotId: Identity
    kind: CardKind
    column: int = Field(ge=0, le=7)
    row: int = Field(ge=0, le=7)
    columnSpan: int = Field(ge=1, le=8)
    rowSpan: int = Field(ge=1, le=8)

    @model_validator(mode="after")
    def bounded_grid(self):
        if self.column + self.columnSpan > 8 or self.row + self.rowSpan > 8:
            raise ValueError("invalid_slot_bounds")
        return self


class EpaperLayout(FrozenModel):
    schemaVersion: Literal[1]
    coreId: Identity
    homeId: Identity
    layoutId: Identity
    revision: Revision
    width: int = Field(ge=64, le=2_048)
    height: int = Field(ge=32, le=2_048)
    colors: list[Color] = Field(min_length=2, max_length=4)
    slots: list[EpaperCardSlot] = Field(min_length=1, max_length=8)

    @model_validator(mode="after")
    def unique_layout(self):
        slot_ids = [slot.slotId for slot in self.slots]
        cells = set()
        for slot in self.slots:
            occupied = {
                (column, row)
                for column in range(slot.column, slot.column + slot.columnSpan)
                for row in range(slot.row, slot.row + slot.rowSpan)
            }
            if cells & occupied:
                raise ValueError("overlapping_slots")
            cells.update(occupied)
        if (
            len(slot_ids) != len(set(slot_ids))
            or len(self.colors) != len(set(self.colors))
            or "black" not in self.colors
            or "white" not in self.colors
        ):
            raise ValueError("invalid_layout")
        return self


class EpaperPolicy(FrozenModel):
    schemaVersion: Literal[1]
    coreId: Identity
    homeId: Identity
    policyId: Identity
    revision: Revision
    allowedKinds: list[CardKind] = Field(min_length=1, max_length=5)
    allowedColors: list[Color] = Field(min_length=2, max_length=4)
    maxCards: int = Field(ge=1, le=8)
    maxTtlSeconds: int = Field(ge=60, le=86_400)
    sharedContentOnly: Literal[True]

    @model_validator(mode="after")
    def unique_policy(self):
        if (
            len(self.allowedKinds) != len(set(self.allowedKinds))
            or len(self.allowedColors) != len(set(self.allowedColors))
            or "black" not in self.allowedColors
            or "white" not in self.allowedColors
        ):
            raise ValueError("invalid_epaper_policy")
        return self


class EpaperCardData(FrozenModel):
    schemaVersion: Literal[1]
    slotId: Identity
    kind: CardKind
    label: str
    value: str
    unit: str | None
    status: Literal["normal", "attention", "offline"]
    accent: Color

    @field_validator("label")
    @classmethod
    def public_label(cls, value):
        return _shared_text(value, maximum=32)

    @field_validator("value")
    @classmethod
    def public_value(cls, value):
        return _shared_text(value, maximum=48)

    @field_validator("unit")
    @classmethod
    def public_unit(cls, value):
        return None if value is None else _shared_text(value, maximum=8)


class EpaperDataSnapshot(FrozenModel):
    schemaVersion: Literal[1]
    coreId: Identity
    homeId: Identity
    dataId: Identity
    revision: Revision
    providerRevision: Revision
    capturedAtMs: TimestampMs
    classification: Literal["shared"]
    cards: list[EpaperCardData] = Field(min_length=1, max_length=8)

    @field_validator("cards")
    @classmethod
    def unique_card_slots(cls, value):
        slots = [card.slotId for card in value]
        if len(slots) != len(set(slots)):
            raise ValueError("duplicate_card_data")
        return value


class EpaperRenderSnapshot(FrozenModel):
    schemaVersion: Literal[1]
    snapshotId: Identity
    coreId: Identity
    homeId: Identity
    homeRevision: Revision
    deviceId: Identity
    deviceRevision: Revision
    bridgeRevision: Revision
    layoutId: Identity
    layoutRevision: Revision
    dataId: Identity
    dataRevision: Revision
    dataProviderRevision: Revision
    policyId: Identity
    policyRevision: Revision
    width: int = Field(ge=64, le=2_048)
    height: int = Field(ge=32, le=2_048)
    colors: list[Color] = Field(min_length=2, max_length=4)
    cards: list[EpaperCardData] = Field(min_length=1, max_length=8)
    createdAtMs: TimestampMs
    expiresAtMs: TimestampMs
    renderDigest: Snapshot


class EpaperPullEnvelope(FrozenModel):
    schemaVersion: Literal[1]
    requestId: Identity
    deviceId: Identity
    deviceRevision: Revision
    deviceConnectivity: Connectivity
    snapshot: EpaperRenderSnapshot
    byteLength: int = Field(ge=1, le=256 * 1024)
    frameCount: int = Field(ge=1, le=64)


class EpaperDeliveryAck(FrozenModel):
    schemaVersion: Literal[1]
    requestId: Identity
    coreId: Identity
    homeId: Identity
    deviceId: Identity
    deviceRevision: Revision
    layoutRevision: Revision
    dataRevision: Revision
    policyRevision: Revision
    renderDigest: Snapshot
    byteLength: int = Field(ge=1, le=256 * 1024)
    frameCount: int = Field(ge=1, le=64)
    receivedFrames: int = Field(ge=0, le=64)
    status: Literal["complete", "partial"]


class EpaperAckResult(FrozenModel):
    schemaVersion: Literal[1]
    requestId: Identity
    status: Literal["verified", "partial"]
    verified: bool
    snapshotDigest: Snapshot

    @model_validator(mode="after")
    def coherent_result(self):
        if (self.status == "verified") != self.verified:
            raise ValueError("invalid_ack_result")
        return self


class EpaperDeliveryStatus(FrozenModel):
    schemaVersion: Literal[1]
    deviceId: Identity
    snapshotDigest: Snapshot | None
    status: Literal["empty", "pending", "partial", "verified", "stale"]
    verifiedDigest: Snapshot | None

    @model_validator(mode="after")
    def coherent_status(self):
        if (self.status == "verified") != (self.verifiedDigest is not None):
            raise ValueError("invalid_delivery_status")
        return self
