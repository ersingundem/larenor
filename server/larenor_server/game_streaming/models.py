import math
from typing import Literal

from pydantic import Field, field_validator

from ..home_resources.models import FrozenModel, HomeScope, Identity, Revision


class Versioned(FrozenModel):
    schemaVersion: Literal[1]

    @field_validator("schemaVersion", mode="before")
    @classmethod
    def integer_schema(cls, value):
        if type(value) is not int:
            raise ValueError("invalid_schema")
        return value


class RegisterGameStreamHost(Versioned):
    registrationId: Identity
    name: str = Field(min_length=1, max_length=80)
    pairingRevision: Revision
    credentialHandle: Identity
    codecs: list[Literal["h264", "hevc", "av1"]] = Field(min_length=1, max_length=3)
    maxWidth: int = Field(ge=320, le=8192)
    maxHeight: int = Field(ge=320, le=8192)
    maxFps: int = Field(ge=30, le=240)

    @field_validator("name")
    @classmethod
    def safe_name(cls, value):
        value = value.strip()
        if not value or any(ord(char) < 32 or ord(char) == 127 for char in value):
            raise ValueError("invalid_name")
        return value

    @field_validator("codecs")
    @classmethod
    def unique_codecs(cls, value):
        if len(value) != len(set(value)):
            raise ValueError("duplicate_codec")
        return value


class OpenGameStreamSession(Versioned):
    requestKey: str = Field(min_length=16, max_length=128, pattern=r"^[A-Za-z0-9._:-]+$")
    expectedHostRevision: Revision
    expectedPairingRevision: Revision
    accountRevision: Revision
    routeRevision: Revision
    lifecycleRevision: Revision
    displayRevision: Revision
    networkRevision: Revision
    policyRevision: Revision
    expiresAt: float

    @field_validator("expiresAt", mode="before")
    @classmethod
    def finite_expiry(cls, value):
        if type(value) is not float or not math.isfinite(value):
            raise ValueError("invalid_expiry")
        return value


class AuthorizeGameStreamIntent(Versioned):
    requestKey: str = Field(min_length=16, max_length=128, pattern=r"^[A-Za-z0-9._:-]+$")
    expectedSessionRevision: Revision
    intent: Literal["wake", "launch", "stream", "stop"]


class CompleteGameStreamIntent(Versioned):
    expectedSessionRevision: Revision
    state: Literal["verified", "unknown", "rejected"]
    result: Literal["hostAwake", "appRunning", "streaming", "stopped", "rejected", "unknown"]
    readbackRevision: Revision | None = None


class HostRef(HomeScope):
    kind: Literal["game_stream_host"]
    id: Identity
