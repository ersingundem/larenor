"""Bounded durable inspection contracts; these never authorize installation."""

from datetime import datetime
from typing import Annotated, Literal

from pydantic import Field, StringConstraints, field_validator, model_validator

from ..admin.models import ObjectId, Revision
from ..models import StrictModel
from .models import Digest, InstallPlan, Platform, ServiceId
from .preflight_models import PreflightResult


Sequence = Annotated[int, Field(ge=1, le=2**63 - 1)]
Timestamp = Annotated[str, StringConstraints(pattern=r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$")]
State = Literal["queued", "running", "succeeded", "failed", "cancelled", "needs_attention"]
Phase = Literal["queued", "checking_requirements", "complete"]
Failure = Literal["worker_unavailable", "invalid_worker_result", "authority_changed", "catalog_changed", "storage_unavailable"]
EventCode = Literal["job_queued", "job_started", "job_resumed", "job_completed", "job_failed",
                    "job_cancel_requested", "job_cancelled", "job_needs_attention"]


class CreateJobRequest(StrictModel):
    operation: Literal["preflight"]
    previewId: ObjectId
    expectedRevision: Revision
    planHash: Digest
    requestId: ObjectId


class CancelJobRequest(StrictModel):
    expectedRevision: Revision


class JobPayload(StrictModel):
    request: CreateJobRequest
    plan: InstallPlan
    result: PreflightResult | None = None


class PluginJob(StrictModel):
    id: ObjectId
    revision: Revision
    operation: Literal["preflight"]
    previewId: ObjectId
    requestId: ObjectId
    serviceId: ServiceId
    distributionId: Literal["upstream", "linuxserver"]
    planHash: Digest
    platform: Platform
    state: State
    phase: Phase
    cancelRequested: bool
    createdAt: Timestamp
    updatedAt: Timestamp
    result: PreflightResult | None
    errorCode: Failure | None

    @field_validator("createdAt", "updatedAt")
    @classmethod
    def valid_time(cls, value):
        datetime.fromisoformat(value.replace("Z", "+00:00"))
        return value

    @model_validator(mode="after")
    def coherent_state(self):
        if self.updatedAt < self.createdAt:
            raise ValueError("invalid_job_state")
        if self.state in ("queued", "running"):
            if self.phase != ("queued" if self.state == "queued" else "checking_requirements") or self.result is not None or self.errorCode is not None:
                raise ValueError("invalid_job_state")
            if self.state == "queued" and self.cancelRequested:
                raise ValueError("invalid_job_state")
        elif self.phase != "complete":
            raise ValueError("invalid_job_state")
        if self.state == "succeeded":
            if self.result is None or self.errorCode is not None or self.cancelRequested:
                raise ValueError("invalid_job_state")
            if self.result.planHash != self.planHash or self.result.platform != self.platform:
                raise ValueError("invalid_job_result")
        elif self.result is not None:
            raise ValueError("invalid_job_state")
        if self.state == "failed" and (self.errorCode not in ("worker_unavailable", "invalid_worker_result") or self.cancelRequested):
            raise ValueError("invalid_job_state")
        if self.state == "needs_attention" and (self.errorCode not in ("authority_changed", "catalog_changed", "storage_unavailable") or self.cancelRequested):
            raise ValueError("invalid_job_state")
        if self.state == "cancelled" and (not self.cancelRequested or self.errorCode is not None):
            raise ValueError("invalid_job_state")
        return self


class JobResponse(StrictModel):
    job: PluginJob


class JobsResponse(StrictModel):
    jobs: list[PluginJob] = Field(max_length=100)
    nextBefore: Sequence | None


class JobEvent(StrictModel):
    sequence: Sequence
    code: EventCode
    createdAt: Timestamp
    jobRevision: Revision

    @field_validator("createdAt")
    @classmethod
    def valid_time(cls, value):
        datetime.fromisoformat(value.replace("Z", "+00:00"))
        return value


class JobEventsResponse(StrictModel):
    events: list[JobEvent] = Field(max_length=100)
    nextAfter: Sequence | None


class JobCapabilities(StrictModel):
    preflightConfigured: bool
    installAvailable: Literal[False] = False
