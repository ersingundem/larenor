import math
from typing import Literal

from pydantic import Field, field_validator, model_validator

from ..home_resources.models import FrozenModel, Identity, Revision
from ..tablet_fleet.models import safe_text


Scope = Literal["read", "control", "admin"]


class CreatePairing(FrozenModel):
    schemaVersion: Literal[1]
    requestId: Identity
    deviceId: Identity
    expectedDeviceRevision: Revision
    name: str = Field(min_length=1, max_length=80)
    scopes: list[Scope] = Field(min_length=1, max_length=3)
    expiresAt: float

    _name = field_validator("name")(safe_text)

    @field_validator("expiresAt", mode="before")
    @classmethod
    def finite_expiry(cls, value):
        if type(value) is not float or not math.isfinite(value):
            raise ValueError("invalid_expiry")
        return value

    @model_validator(mode="after")
    def unique_scopes(self):
        if len(self.scopes) != len(set(self.scopes)):
            raise ValueError("invalid_scopes")
        return self


class MqttCommand(FrozenModel):
    schemaVersion: Literal[1]
    requestId: Identity
    sequence: int = Field(ge=1, le=2**63 - 1)
    kind: Literal["refreshDashboard", "syncProfile", "lockKiosk"]
    retained: bool
    expiresAt: float

    @field_validator("expiresAt", mode="before")
    @classmethod
    def finite_expiry(cls, value):
        if type(value) is not float or not math.isfinite(value):
            raise ValueError("invalid_expiry")
        return value


class MqttAck(FrozenModel):
    schemaVersion: Literal[1]
    sequence: int = Field(ge=1, le=2**63 - 1)
    result: Literal["succeeded", "denied", "failed", "unsupported"]
