import math
from typing import Annotated, Literal

from pydantic import Field, field_validator, model_validator

from ..home_resources.models import FrozenModel, Identity

MAX_SAFE_INTEGER = 2**53 - 1
SafeRevision = Annotated[int, Field(ge=1, le=MAX_SAFE_INTEGER)]
RequestKey = Annotated[
    str, Field(min_length=16, max_length=128, pattern=r"^[A-Za-z0-9._:-]+$")]
Digest = Annotated[str, Field(pattern=r"^[0-9a-f]{64}$")]
EngineRevision = Annotated[
    str, Field(min_length=1, max_length=128, pattern=r"^[A-Za-z0-9._-]+$")]


class Versioned(FrozenModel):
    schemaVersion: Literal[2]

    @field_validator("schemaVersion", mode="before")
    @classmethod
    def integer_schema(cls, value):
        if type(value) is not int:
            raise ValueError("invalid_schema")
        return value


class PairingIntentRequest(Versioned):
    requestKey: RequestKey
    accountRevision: SafeRevision
    expiresAt: float

    @field_validator("expiresAt", mode="before")
    @classmethod
    def finite_expiry(cls, value):
        if type(value) is not float or not math.isfinite(value):
            raise ValueError("invalid_expiry")
        return value


class NativeAppObservation(FrozenModel):
    observationId: Identity
    revision: SafeRevision
    name: str = Field(min_length=1, max_length=160)

    @field_validator("name")
    @classmethod
    def safe_name(cls, value):
        value = value.strip()
        if not value or any(ord(char) < 32 or ord(char) == 127 for char in value):
            raise ValueError("invalid_name")
        return value


class NativePairingObservation(FrozenModel):
    schemaVersion: Literal[1]
    receiptId: Identity
    nativeBindingId: Identity
    bindingRevision: SafeRevision
    engineRevision: EngineRevision
    provider: Literal["moonlight-nvhttp"]
    state: Literal["paired"]
    hostObservationId: Identity
    name: str = Field(min_length=1, max_length=80)
    codecs: list[Literal["h264", "hevc", "av1"]] = Field(
        min_length=1, max_length=3)
    maxWidth: int = Field(ge=320, le=8192)
    maxHeight: int = Field(ge=320, le=8192)
    maxFps: int = Field(ge=30, le=240)
    catalogRevision: SafeRevision
    catalogDigest: Digest
    apps: list[NativeAppObservation] = Field(max_length=256)

    @field_validator("schemaVersion", mode="before")
    @classmethod
    def integer_native_schema(cls, value):
        if type(value) is not int:
            raise ValueError("invalid_schema")
        return value

    @field_validator("name")
    @classmethod
    def safe_name(cls, value):
        value = value.strip()
        if not value or any(ord(char) < 32 or ord(char) == 127 for char in value):
            raise ValueError("invalid_name")
        return value

    @model_validator(mode="after")
    def unique_values(self):
        if (len(self.codecs) != len(set(self.codecs))
                or len({item.observationId for item in self.apps})
                != len(self.apps)):
            raise ValueError("duplicate_observation")
        return self


class CompletePairingIntent(Versioned):
    expectedPairingRevision: SafeRevision
    pairingGrant: Identity
    observation: NativePairingObservation


class CatalogObservationIntentRequest(Versioned):
    requestKey: RequestKey
    expectedHostRevision: SafeRevision
    expectedPairingRevision: SafeRevision
    expectedCatalogRevision: SafeRevision
    accountRevision: SafeRevision
    expiresAt: float

    @field_validator("expiresAt", mode="before")
    @classmethod
    def finite_expiry(cls, value):
        if type(value) is not float or not math.isfinite(value):
            raise ValueError("invalid_expiry")
        return value


class NativeCatalogObservation(FrozenModel):
    schemaVersion: Literal[1]
    receiptId: Identity
    nativeBindingId: Identity
    bindingRevision: SafeRevision
    catalogRevision: SafeRevision
    catalogDigest: Digest
    apps: list[NativeAppObservation] = Field(max_length=256)

    @field_validator("schemaVersion", mode="before")
    @classmethod
    def integer_native_schema(cls, value):
        if type(value) is not int:
            raise ValueError("invalid_schema")
        return value

    @model_validator(mode="after")
    def unique_apps(self):
        if len({item.observationId for item in self.apps}) != len(self.apps):
            raise ValueError("duplicate_observation")
        return self


class CompleteCatalogObservationIntent(Versioned):
    expectedObservationRevision: SafeRevision
    catalogGrant: Identity
    observation: NativeCatalogObservation


class ClientGameStreamAuthority(FrozenModel):
    routeRevision: SafeRevision
    lifecycleRevision: SafeRevision
    displayRevision: SafeRevision
    networkRevision: SafeRevision
    policyRevision: SafeRevision


class SelectedGameStreamQuality(FrozenModel):
    codec: Literal["h264", "hevc", "av1"]
    codecId: Identity
    codecRevision: SafeRevision
    displayId: int = Field(ge=0, le=63)
    displayRevision: SafeRevision
    networkId: Identity
    networkRevision: SafeRevision
    policyId: Identity
    policyRevision: SafeRevision
    widthPixels: int = Field(ge=320, le=8192)
    heightPixels: int = Field(ge=320, le=8192)
    framesPerSecond: int = Field(ge=24, le=240)
    bitrateKbps: int = Field(ge=2000, le=100000)
    frameQueueDepth: int = Field(ge=1, le=3)
    inputQueueDepth: int = Field(ge=1, le=32)
    secureSurface: Literal[True]


class OpenGameStreamSession(Versioned):
    requestKey: RequestKey
    expectedHostRevision: SafeRevision
    expectedPairingRevision: SafeRevision
    expectedCatalogRevision: SafeRevision
    expectedAppRevision: SafeRevision
    accountRevision: SafeRevision
    clientAuthority: ClientGameStreamAuthority
    selectedQuality: SelectedGameStreamQuality
    expiresAt: float

    @model_validator(mode="after")
    def quality_matches_client_authority(self):
        quality = self.selectedQuality
        authority = self.clientAuthority
        if (quality.displayRevision, quality.networkRevision, quality.policyRevision) != (
                authority.displayRevision, authority.networkRevision,
                authority.policyRevision):
            raise ValueError("quality_authority_mismatch")
        return self

    @field_validator("expiresAt", mode="before")
    @classmethod
    def finite_expiry(cls, value):
        if type(value) is not float or not math.isfinite(value):
            raise ValueError("invalid_expiry")
        return value


class RetireGameStreamSession(Versioned):
    requestKey: RequestKey
    expectedSessionRevision: SafeRevision


class AuthorizeGameStreamIntent(Versioned):
    requestKey: RequestKey
    expectedSessionRevision: SafeRevision
    intent: Literal["wake", "launch", "stream", "stop"]


class CompleteGameStreamIntent(Versioned):
    expectedSessionRevision: SafeRevision
    dispatchGrant: Identity
    state: Literal["native_observed", "unknown", "rejected"]
    result: Literal[
        "hostAwake", "appRunning", "streaming", "stopped", "rejected",
        "unknown"]
    observationKind: Literal[
        "serverInfoOnline", "currentGameMatched", "connectionStarted",
        "connectionTerminated", "nativeRejected", "unknown"]
    readbackRevision: SafeRevision | None = None
    nativeReceiptDigest: Digest | None = None


class RevokeGameStreamHost(Versioned):
    requestKey: RequestKey
    expectedHostRevision: SafeRevision
    expectedPairingRevision: SafeRevision
    expectedCatalogRevision: SafeRevision


class CompleteGameStreamRevocation(Versioned):
    state: Literal["local_cleared", "unknown"]
