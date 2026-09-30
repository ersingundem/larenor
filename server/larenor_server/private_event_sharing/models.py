from typing import Literal

from pydantic import Field, FiniteFloat, field_validator

from ..home_resources.models import FrozenModel, Identity, Revision

Mask = Literal["face", "license_plate"]
Metadata = Literal["device_serial", "gps", "camera_name", "network_address"]


class ExactEventScope(FrozenModel):
    schemaVersion: Literal[1]
    coreRevision: Revision
    homeRevision: Revision
    accountRevision: Revision
    membersRevision: Revision
    cameraRevision: Revision
    eventRevision: Revision
    sessionRevision: Revision
    expectedShareRevision: Revision


class PreviewRequest(ExactEventScope):
    masks: list[Mask] = Field(min_length=1, max_length=2)
    removedMetadata: list[Metadata] = Field(min_length=1, max_length=4)


class Transformation(FrozenModel):
    sourceDigest: str = Field(pattern=r"^[0-9a-f]{64}$")
    outputDigest: str = Field(pattern=r"^[0-9a-f]{64}$")
    outputArtifactId: Identity
    pipelineId: Identity
    pipelineRevision: Revision
    masks: list[Mask] = Field(min_length=1, max_length=2)
    removedMetadata: list[Metadata] = Field(min_length=1, max_length=4)
    proof: str = Field(pattern=r"^[0-9a-f]{64}$")


class CreateShareRequest(ExactEventScope):
    commandId: Identity
    consentId: Identity
    consentRevision: Revision
    recipientId: Identity
    purpose: str = Field(min_length=1, max_length=200)
    expiresAt: FiniteFloat = Field(gt=0)
    accessMode: Literal["one_time", "time_bound"]
    transformation: Transformation

    @field_validator("purpose")
    @classmethod
    def safe_purpose(cls, value: str) -> str:
        if value != value.strip() or any(
            ord(character) < 32
            or ord(character) == 127
            or 0xD800 <= ord(character) <= 0xDFFF
            for character in value
        ):
            raise ValueError("invalid_purpose")
        return value


class RevokeShareRequest(ExactEventScope):
    commandId: Identity
    shareId: Identity


class RedeemShareRequest(FrozenModel):
    schemaVersion: Literal[1]
    accessId: Identity
    accessToken: str = Field(min_length=32, max_length=128)


class PrivateEventPolicyRequest(FrozenModel):
    schemaVersion: Literal[1]
    expectedRevision: int = Field(ge=0, lt=2**63 - 1)
    active: bool
    grantorIds: list[Identity] = Field(min_length=1, max_length=128)
    recipientIds: list[Identity] = Field(min_length=1, max_length=128)
    purposes: list[str] = Field(min_length=1, max_length=16)
    accessModes: list[Literal["one_time", "time_bound"]] = Field(
        min_length=1, max_length=2
    )
    maxTtlSeconds: int = Field(ge=60, le=604800)
    requiredMasks: list[Mask] = Field(min_length=1, max_length=2)
    requiredMetadata: list[Metadata] = Field(min_length=1, max_length=4)
    redactionMode: Literal["full_frame_blur"]

    @field_validator(
        "grantorIds", "recipientIds", "purposes", "accessModes",
        "requiredMasks", "requiredMetadata"
    )
    @classmethod
    def unique_values(cls, value):
        if len(set(value)) != len(value):
            raise ValueError("duplicate_value")
        return value

    @field_validator("purposes")
    @classmethod
    def safe_purposes(cls, values):
        if any(
            value != value.strip()
            or not 1 <= len(value) <= 200
            or any(ord(character) < 32 or ord(character) == 127 for character in value)
            for value in values
        ):
            raise ValueError("invalid_purpose")
        return values


class AcceptEventConsentRequest(ExactEventScope):
    expectedPolicyRevision: Revision
    recipientId: Identity
    purpose: str = Field(min_length=1, max_length=200)
    expiresAt: FiniteFloat = Field(gt=0)
    accessMode: Literal["one_time", "time_bound"]
    masks: list[Mask] = Field(min_length=1, max_length=2)
    removedMetadata: list[Metadata] = Field(min_length=1, max_length=4)

    @field_validator("purpose")
    @classmethod
    def safe_consent_purpose(cls, value):
        return CreateShareRequest.safe_purpose(value)

    @field_validator("masks", "removedMetadata")
    @classmethod
    def unique_consent_values(cls, value):
        if len(set(value)) != len(value):
            raise ValueError("duplicate_value")
        return value
