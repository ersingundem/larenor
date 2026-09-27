"""Closed v1 contracts for rule and manual device-write arbitration."""

import math
from typing import Annotated, Literal

from pydantic import Field, field_validator, model_validator

from ..home_resources.models import FrozenModel, Identity, Revision, Snapshot


RequestKey = Annotated[
    str, Field(min_length=16, max_length=128, pattern=r"^[A-Za-z0-9._:-]+$")
]
Priority = Annotated[int, Field(ge=0, le=100)]
LeaseSeconds = Annotated[int, Field(ge=1, le=86_400)]
DeviceAction = Annotated[str, Field(min_length=1, max_length=128)]


def _safe_action_value(value):
    value = value.strip()
    if (
        not value
        or any(
            ord(char) < 32 or ord(char) == 127 or 0xD800 <= ord(char) <= 0xDFFF
            for char in value
        )
        or len(value.encode("utf-8")) > 256
    ):
        raise ValueError("invalid_action")
    return value


class Versioned(FrozenModel):
    schemaVersion: Literal[1]

    @field_validator("schemaVersion", mode="before")
    @classmethod
    def integer_version(cls, value):
        if type(value) is not int:
            raise ValueError("invalid_schema")
        return value


class _ActionRequest(Versioned):
    requestKey: RequestKey
    deviceId: Identity
    expectedDeviceRevision: Revision
    action: DeviceAction

    @field_validator("action")
    @classmethod
    def safe_action(cls, value):
        return _safe_action_value(value)


class SubmitRuleIntent(_ActionRequest):
    ruleId: Identity
    expectedRuleRevision: Revision
    priority: Priority
    leaseSeconds: LeaseSeconds


class SubmitManualIntent(_ActionRequest):
    holdSeconds: LeaseSeconds


class CompleteArbitratedIntent(Versioned):
    effectToken: Snapshot
    outcome: Literal["applied", "rejected", "unknown"]
    readbackDeviceRevision: Revision | None = None

    @model_validator(mode="after")
    def coherent_result(self):
        if (self.outcome == "applied") != (self.readbackDeviceRevision is not None):
            raise ValueError("invalid_arbitration_result")
        return self


class ObserveExternalWrite(Versioned):
    observationId: Identity
    deviceId: Identity
    providerRevision: Revision
    action: DeviceAction
    observedAt: float
    origin: Literal["home_assistant"]

    _safe_action = field_validator("action")(_safe_action_value)

    @field_validator("observedAt", mode="before")
    @classmethod
    def finite_timestamp(cls, value):
        if type(value) is not float or not math.isfinite(value) or value < 0:
            raise ValueError("invalid_observed_at")
        return value
