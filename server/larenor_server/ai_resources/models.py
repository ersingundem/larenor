from typing import Annotated, Literal

from pydantic import Field, field_validator, model_validator

from ..home_resources.models import FrozenModel, Identity, Revision


Percent = Annotated[int, Field(ge=1, le=100)]
MemoryMb = Annotated[int, Field(ge=64, le=1_048_576)]


class Versioned(FrozenModel):
    schemaVersion: Literal[1]

    @field_validator("schemaVersion", mode="before")
    @classmethod
    def integer_version(cls, value):
        if type(value) is not int:
            raise ValueError("invalid_schema")
        return value


class UpdateAiResourcePolicy(Versioned):
    expectedRevision: Revision
    maxMemoryMb: MemoryMb
    maxCpuPercent: Percent
    maxConcurrentJobs: Annotated[int, Field(ge=1, le=16)]
    mediaCpuPercent: Percent

    @model_validator(mode="after")
    def media_limit(self):
        if self.mediaCpuPercent > self.maxCpuPercent:
            raise ValueError("invalid_media_cpu_limit")
        return self


class EnqueueAiJob(Versioned):
    expectedPolicyRevision: Revision
    requestKey: str = Field(min_length=16, max_length=128, pattern=r"^[A-Za-z0-9._:-]+$")
    kind: Literal["assistant", "vision", "embedding", "automation"]
    label: str = Field(min_length=1, max_length=80)
    priority: Annotated[int, Field(ge=0, le=100)]
    memoryMb: MemoryMb
    cpuPercent: Percent

    @field_validator("label")
    @classmethod
    def safe_label(cls, value):
        value = value.strip()
        if not value or any(ord(char) < 32 or ord(char) == 127 for char in value):
            raise ValueError("invalid_label")
        return value


class ChangeAiJob(Versioned):
    expectedRevision: Revision


class ReportMediaActivity(Versioned):
    active: bool
    leaseSeconds: Annotated[int, Field(ge=0, le=300)]

    @model_validator(mode="after")
    def lease_matches_state(self):
        if self.active != (self.leaseSeconds > 0):
            raise ValueError("invalid_media_lease")
        return self

