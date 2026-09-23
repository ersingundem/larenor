from typing import Literal

from pydantic import Field, field_validator, model_validator

from ..home_resources.models import FrozenModel, HomeScope, Identity, Revision, Snapshot


class Target(FrozenModel):
    oem: str = Field(
        min_length=1, max_length=48, pattern=r"^[A-Za-z0-9][A-Za-z0-9 ._+()-]*$"
    )
    model: str = Field(
        min_length=1, max_length=80, pattern=r"^[A-Za-z0-9][A-Za-z0-9 ._+()-]*$"
    )
    androidApi: int = Field(ge=26, le=100)
    webViewPackage: str = Field(
        min_length=3, max_length=120, pattern=r"^[a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)+$"
    )
    webViewVersion: str = Field(
        min_length=1, max_length=64, pattern=r"^[0-9A-Za-z][0-9A-Za-z._+-]*$"
    )
    dexProfile: Literal["none", "window", "external_display", "managed_kiosk"]
    permissions: list[str] = Field(max_length=32)

    @model_validator(mode="after")
    def distinct_permissions(self):
        if self.permissions != sorted(set(self.permissions)):
            raise ValueError("invalid_permissions")
        return self

    @field_validator("permissions")
    @classmethod
    def safe_permissions(cls, value):
        import re

        if any(
            not re.fullmatch(r"android\.permission\.[A-Z][A-Z0-9_]{1,79}", item)
            for item in value
        ):
            raise ValueError("invalid_permissions")
        return value


class PutEvidence(FrozenModel):
    schemaVersion: Literal[1]
    expectedRevision: int = Field(ge=0, le=2**63 - 2)
    requestKey: str = Field(
        min_length=16, max_length=128, pattern=r"^[A-Za-z0-9._:-]+$"
    )
    evidenceId: Identity
    capabilityId: str = Field(
        min_length=3, max_length=80, pattern=r"^[a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)+$"
    )
    target: Target
    outcome: Literal["tested", "failed", "untested", "manual_required"]
    artifactName: str = Field(
        min_length=1, max_length=100, pattern=r"^[a-zA-Z0-9][a-zA-Z0-9._-]*$"
    )
    artifactSha256: Snapshot
    sourceCommit: str = Field(pattern=r"^[0-9a-f]{40}$")
    testCase: str = Field(
        min_length=3,
        max_length=100,
        pattern=r"^[a-zA-Z][a-zA-Z0-9_-]*(?:\.[a-zA-Z][a-zA-Z0-9_-]*)+$",
    )

    @field_validator("schemaVersion", mode="before")
    @classmethod
    def exact_version(cls, value):
        if type(value) is not int:
            raise ValueError("invalid_schema")
        return value


class EvidenceRecord(FrozenModel):
    schemaVersion: Literal[1]
    id: Identity
    revision: Revision
    capabilityId: str
    target: Target
    outcome: Literal["tested", "failed", "untested", "manual_required"]
    artifactName: str
    artifactSha256: Snapshot
    sourceCommit: str
    testCase: str
    updatedAt: float


class EvidenceResponse(FrozenModel):
    record: EvidenceRecord


class EvidenceList(FrozenModel):
    schemaVersion: Literal[1]
    scope: HomeScope
    records: list[EvidenceRecord] = Field(max_length=50)
    nextAfter: Identity | None
