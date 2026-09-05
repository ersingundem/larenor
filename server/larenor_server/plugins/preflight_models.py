"""Public, bounded observations; no host paths or installation-success claim."""

from datetime import datetime
from typing import Annotated, Literal

from pydantic import Field, StringConstraints, field_validator, model_validator

from ..models import StrictModel
from .models import Digest, Platform


RootId = Annotated[str, StringConstraints(pattern=r"^[a-z][a-z0-9_-]{0,39}$")]
Mebibytes = Annotated[int, Field(ge=0, le=2**63 - 1)]


class PreflightCheck(StrictModel):
    code: Literal["platform", "storage_root", "storage_capacity", "docker_engine",
                  "port_availability", "receiver_network", "daemon_mount_context",
                  "daemon_network_context", "daemon_root_context"]
    status: Literal["passed", "failed", "unknown"]
    rootId: RootId | None = None
    availableMiB: Mebibytes | None = None
    requiredMiB: Mebibytes | None = None

    @model_validator(mode='after')
    def context_has_no_private_identifiers(self):
        if self.code.startswith('daemon_') and any(value is not None for value in (
                self.rootId, self.availableMiB, self.requiredMiB)):
            raise ValueError('invalid_context_check')
        return self


class PreflightResult(StrictModel):
    catalogDigest: Digest
    planHash: Digest
    platform: Platform
    checkedAt: Annotated[str, StringConstraints(
        pattern=r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$")]
    checks: list[PreflightCheck] = Field(min_length=1, max_length=32)

    @field_validator("checkedAt")
    @classmethod
    def valid_time(cls, value):
        datetime.fromisoformat(value.replace("Z", "+00:00"))
        return value
