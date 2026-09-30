"""Persisted, account-scoped Frigate sound-event source contracts."""

from typing import Literal

from pydantic import Field, field_validator, model_validator

from ..home_resources.models import FrozenModel, Identity, Revision


class SoundLabelMap(FrozenModel):
    bark: list[str] = Field(default_factory=lambda: ["bark"], max_length=8)
    noise: list[str] = Field(default_factory=list, max_length=16)

    @field_validator("bark", "noise")
    @classmethod
    def labels(cls, values):
        if len(values) != len(set(values)) or any(
            not value
            or len(value) > 64
            or not value.replace("_", "").isalnum()
            or value.lower() != value
            for value in values
        ):
            raise ValueError("invalid_audio_label")
        return values

    @model_validator(mode="after")
    def disjoint(self):
        if not self.bark and not self.noise:
            raise ValueError("empty_audio_labels")
        if set(self.bark) & set(self.noise):
            raise ValueError("ambiguous_audio_label")
        return self


class FrigateSoundSourceInput(FrozenModel):
    schemaVersion: Literal[1]
    expectedRevision: Revision | None
    cameraResourceId: Identity
    expectedCameraRevision: Revision
    roomId: Identity
    expectedRoomRevision: Revision
    labels: SoundLabelMap
    consentGranted: bool
    retentionSeconds: int = Field(ge=60, le=7 * 24 * 60 * 60)


class FrigateSoundSource(FrozenModel):
    schemaVersion: Literal[1]
    revision: Revision
    ownerId: Identity
    cameraResourceId: Identity
    cameraRevision: Revision
    roomId: Identity
    roomRevision: Revision
    frigateCamera: str = Field(min_length=1, max_length=80)
    providerRevision: Revision
    labels: SoundLabelMap
    consentGranted: bool
    consentRevision: Revision
    retentionSeconds: int
    configuredAtMs: int = Field(ge=0, le=2**63 - 1)


class SoundSourceChoice(FrozenModel):
    id: Identity
    revision: Revision
    label: str = Field(min_length=1, max_length=80)
    audioLabels: list[str] = Field(default_factory=list, max_length=256)


class SoundSourceSetup(FrozenModel):
    schemaVersion: Literal[1]
    revision: int = Field(ge=0, le=2**63 - 1)
    configuration: FrigateSoundSource | None
    cameras: list[SoundSourceChoice] = Field(max_length=16)
    rooms: list[SoundSourceChoice] = Field(max_length=128)


class SoundSourceRefresh(FrozenModel):
    schemaVersion: Literal[1]
    configurationRevision: Revision
    importedEvents: int = Field(ge=0, le=256)
    reviewedRecords: int = Field(ge=0, le=256)
