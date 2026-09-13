"""Public and encrypted-private contracts for durable Seerr bootstrap jobs."""

from typing import Literal

from pydantic import ConfigDict, Field, field_validator, model_validator

from ..admin.models import ObjectId, Revision
from ..models import StrictModel
from .seerr_bootstrap_models import PrivateSeerrBootstrap


class CreateSeerrBootstrapRequest(StrictModel):
    requestId: ObjectId
    installationId: ObjectId
    expectedInstallationRevision: Revision
    sourceBootstrapId: ObjectId
    expectedSourceBootstrapRevision: Revision


class SeerrBootstrapJob(StrictModel):
    id: ObjectId
    requestId: ObjectId
    installationId: ObjectId
    sourceBootstrapId: ObjectId
    sourceBootstrapRevision: Revision
    serviceId: Literal["seerr"] = "seerr"
    revision: Revision
    state: Literal[
        "queued", "running", "succeeded", "needs_attention", "failed", "cancelled"
    ]
    phase: Literal["queued", "bootstrapping", "complete"]
    errorCode: Literal[
        "seerr_bootstrap_authority_changed",
        "seerr_bootstrap_resources_unavailable",
        "seerr_bootstrap_endpoint_unavailable",
        "seerr_bootstrap_endpoint_changed",
        "seerr_bootstrap_peer_changed",
        "seerr_bootstrap_initial_admin_failed",
        "seerr_bootstrap_arr_wiring_failed",
        "seerr_bootstrap_initialization_failed",
        "seerr_bootstrap_timeout",
        "seerr_bootstrap_interrupted",
        "seerr_bootstrap_worker_unavailable",
        "invalid_seerr_bootstrap_result",
    ] | None
    installAvailable: Literal[False] = False
    convergencePhase: Literal[
        "queued", "bootstrap", "arr_wiring", "initialize", "verified"
    ]
    arrWired: bool = False
    initialized: bool = False
    createdAt: str
    updatedAt: str

    @model_validator(mode="after")
    def coherent(self):
        if self.state == "queued" and (
            self.phase != "queued" or self.revision != 1 or self.errorCode is not None
        ):
            raise ValueError("invalid_seerr_bootstrap_job")
        if self.state == "running" and (
            self.phase != "bootstrapping" or self.revision < 2 or self.errorCode is not None
        ):
            raise ValueError("invalid_seerr_bootstrap_job")
        if self.state not in {"queued", "running"} and (
            self.phase != "complete" or self.revision < 2
        ):
            raise ValueError("invalid_seerr_bootstrap_job")
        if self.state in {"succeeded", "cancelled"} and self.errorCode is not None:
            raise ValueError("invalid_seerr_bootstrap_job")
        if self.state in {"needs_attention", "failed"} and self.errorCode is None:
            raise ValueError("invalid_seerr_bootstrap_job")
        return self


class SeerrBootstrapJobResponse(StrictModel):
    bootstrap: SeerrBootstrapJob


class SeerrBootstrapJobsResponse(StrictModel):
    bootstraps: list[SeerrBootstrapJob] = Field(max_length=10)
    nextBefore: int | None


class PrivateSeerrBootstrapPayload(StrictModel):
    model_config = ConfigDict(extra="forbid", strict=True, frozen=True)

    private: PrivateSeerrBootstrap = Field(repr=False)
    apiKey: str | None = Field(
        default=None,
        min_length=64,
        max_length=72,
        pattern=r"^[A-Za-z0-9+/]+={0,2}$",
        repr=False,
    )
    convergencePhase: Literal[
        "queued", "bootstrap", "arr_wiring", "initialize", "verified"
    ] = "queued"
    arrInstanceIds: tuple[int, int] | None = None
    initialized: bool = False
    initializationChanged: bool | None = None

    @field_validator("arrInstanceIds", mode="before")
    @classmethod
    def json_arr_instance_ids(cls, value):
        return tuple(value) if isinstance(value, list) else value

    @model_validator(mode="before")
    @classmethod
    def upgrade_legacy_payload(cls, value):
        if isinstance(value, dict) and "convergencePhase" not in value:
            value = dict(value)
            value["convergencePhase"] = (
                "bootstrap" if value.get("apiKey") is not None else "queued"
            )
        return value

    @model_validator(mode="after")
    def convergence_coherent(self):
        rank = {
            "queued": 0,
            "bootstrap": 1,
            "arr_wiring": 2,
            "initialize": 3,
            "verified": 4,
        }[self.convergencePhase]
        if rank == 0 and self.apiKey is not None or rank >= 2 and self.apiKey is None:
            raise ValueError("invalid_seerr_convergence")
        if (self.arrInstanceIds is not None) != (rank >= 3):
            raise ValueError("invalid_seerr_convergence")
        if self.arrInstanceIds is not None and any(
            type(value) is not int or not 0 <= value <= 2**31 - 1
            for value in self.arrInstanceIds
        ):
            raise ValueError("invalid_seerr_convergence")
        if self.initialized != (rank == 4):
            raise ValueError("invalid_seerr_convergence")
        if (self.initializationChanged is not None) != self.initialized:
            raise ValueError("invalid_seerr_convergence")
        return self
