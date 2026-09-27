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
