import math
from typing import Annotated, Literal

from pydantic import Field, field_validator, model_validator

from ..home_resources.models import FrozenModel, Revision


RequestKey = Annotated[str, Field(min_length=16, max_length=128, pattern=r"^[A-Za-z0-9._:-]+$")]
SupporterId = Annotated[str, Field(min_length=3, max_length=96, pattern=r"^[A-Za-z0-9][A-Za-z0-9._:-]+$")]
Permission = Literal[
    "core:health.read",
    "core:audit.verify",
    "home_registry:resource_count.read",
    "component_egress:summary.read",
    "session:activity.read",
]


class Versioned(FrozenModel):
    schemaVersion: Literal[1]

    @field_validator("schemaVersion", mode="before")
    @classmethod
    def integer_version(cls, value):
        if type(value) is not int:
            raise ValueError("invalid_schema")
        return value


class CreateSupportSession(Versioned):
    requestKey: RequestKey
    supporterId: SupporterId
    supporterName: Annotated[str, Field(min_length=1, max_length=80)]
    permissions: list[Permission] = Field(min_length=1, max_length=5)
    expiresAt: float

    @field_validator("supporterName")
    @classmethod
    def safe_name(cls, value):
        value = " ".join(value.split())
        if not value or any(ord(char) < 32 or ord(char) == 127 for char in value):
            raise ValueError("invalid_supporter_name")
        return value

    @model_validator(mode="after")
    def closed_authority(self):
        if self.permissions != sorted(set(self.permissions)) or not math.isfinite(self.expiresAt):
            raise ValueError("invalid_support_authority")
        return self


class RevokeSupportSession(Versioned):
    expectedRevision: Revision


class SupportAccess(Versioned):
    permission: Annotated[str, Field(min_length=1, max_length=96, pattern=r"^[a-z][a-z0-9_.:-]+$")]
