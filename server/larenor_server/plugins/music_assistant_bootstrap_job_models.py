"""Public and encrypted-private contracts for Music Assistant bootstrap jobs."""

from typing import Literal

from pydantic import ConfigDict, Field, model_validator

from ..admin.models import ObjectId, Revision
from ..models import StrictModel
from .music_assistant_bootstrap_models import PrivateMusicAssistantBootstrap


class CreateMusicAssistantBootstrapRequest(StrictModel):
    requestId: ObjectId
    installationId: ObjectId
    expectedInstallationRevision: Revision


class MusicAssistantBootstrapJob(StrictModel):
    id: ObjectId
    requestId: ObjectId
    installationId: ObjectId
    serviceId: Literal["music_assistant"] = "music_assistant"
    revision: Revision
    state: Literal[
        "queued", "running", "succeeded", "needs_attention", "failed"
    ]
    phase: Literal["queued", "bootstrapping", "complete"]
    errorCode: Literal[
        "music_assistant_bootstrap_authority_changed",
        "music_assistant_bootstrap_interrupted",
        "music_assistant_bootstrap_worker_unavailable",
        "music_assistant_bootstrap_state_conflict",
        "music_assistant_bootstrap_cancelled",
        "music_assistant_bootstrap_readback_changed",
        "music_assistant_bootstrap_readback_rejected",
        "music_assistant_bootstrap_uncertain",
        "invalid_music_assistant_bootstrap_result",
    ] | None
    installAvailable: Literal[False] = False
    createdAt: str
    updatedAt: str

    @model_validator(mode="after")
    def coherent(self):
        if self.state == "queued" and (
            self.phase != "queued" or self.revision != 1 or self.errorCode is not None
        ):
            raise ValueError("invalid_music_assistant_bootstrap_job")
        if self.state == "running" and (
            self.phase != "bootstrapping" or self.revision < 2
            or self.errorCode is not None
        ):
            raise ValueError("invalid_music_assistant_bootstrap_job")
        if self.state == "succeeded" and (
            self.phase != "complete" or self.errorCode is not None
        ):
            raise ValueError("invalid_music_assistant_bootstrap_job")
        if self.state in {"needs_attention", "failed"} and (
            self.phase != "complete" or self.errorCode is None
        ):
            raise ValueError("invalid_music_assistant_bootstrap_job")
        return self


class MusicAssistantBootstrapJobResponse(StrictModel):
    bootstrap: MusicAssistantBootstrapJob


class MusicAssistantBootstrapJobsResponse(StrictModel):
    bootstraps: list[MusicAssistantBootstrapJob] = Field(max_length=10)
    nextBefore: int | None


class PrivateMusicAssistantBootstrapPayload(StrictModel):
    model_config = ConfigDict(extra="forbid", strict=True, frozen=True)
    private: PrivateMusicAssistantBootstrap = Field(repr=False)
