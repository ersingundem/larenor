from typing import Annotated, Literal

from pydantic import Field, field_validator, model_validator

from ..home_resources.models import FrozenModel, HomeScope, Identity, Revision
from .models import DetectionBatch, VisualSensorReading, VisualSensorRule, _safe_label


ExpectedRevision = Annotated[int, Field(ge=0, le=2**63 - 2)]


class ConfigureVisualSensorRule(FrozenModel):
    schemaVersion: Literal[1]
    expectedRevision: ExpectedRevision
    rule: VisualSensorRule


class VisualEngineCapability(FrozenModel):
    schemaVersion: Literal[1]
    architecture: Literal["amd64", "arm64", "other"]
    avx: Literal["supported", "unsupported", "unknown", "not_applicable"]
    avx2: Literal["supported", "unsupported", "unknown", "not_applicable"]
    arm64: bool
    detectorState: Literal["unavailable", "degraded", "ready"]
    trainingSupported: bool
    inferenceSupported: bool
    reason: Literal[
        "detector_worker_not_configured",
        "cpu_requirements_unmet",
        "arm64_unverified",
        "capability_unverified",
        "worker_stale",
        "ready",
    ]

    @model_validator(mode="after")
    def coherent(self):
        if self.architecture == "arm64":
            if (
                not self.arm64
                or self.avx != "not_applicable"
                or self.avx2 != "not_applicable"
            ):
                raise ValueError("invalid_capability")
        elif self.arm64 or self.avx == "not_applicable" or self.avx2 == "not_applicable":
            raise ValueError("invalid_capability")
        if self.detectorState == "ready":
            if not self.inferenceSupported or self.reason != "ready":
                raise ValueError("invalid_capability")
        elif self.detectorState == "degraded":
            if not self.inferenceSupported or self.reason != "worker_stale":
                raise ValueError("invalid_capability")
        elif self.reason in {"ready", "worker_stale"} or self.inferenceSupported:
            raise ValueError("invalid_capability")
        return self


class VisualSensorSummary(FrozenModel):
    schemaVersion: Literal[2]
    ruleId: Identity
    ruleRevision: Revision
    cameraId: Identity
    pipelineId: Identity
    pipelineRevision: Revision
    modelId: Identity
    modelRevision: Revision
    label: Annotated[str, Field(min_length=1, max_length=80)]
    state: Literal["on", "off", "unknown"]
    status: Literal["ready", "degraded", "unavailable"]
    reason: Literal[
        "trusted_frame", "provider_degraded", "missing_frame", "corrupt_frame",
        "wrong_camera_frame", "stale_frame", "no_trusted_frame",
    ]
    observedAtMs: int | None = Field(default=None, ge=0, le=2**63 - 1)
    staleAtMs: int | None = Field(default=None, ge=0, le=2**63 - 1)
    evidenceDigest: str | None = Field(
        default=None, min_length=64, max_length=64, pattern=r"^[0-9a-f]{64}$"
    )
    confidenceBps: int = Field(ge=0, le=10_000)
    count: int = Field(ge=0, le=1_000)
    automationEligible: bool
    accessControlEligible: Literal[False]

    _label = field_validator("label")(_safe_label)

    @model_validator(mode="after")
    def coherent(self):
        empty = self.observedAtMs is None
        if (
            empty != (self.evidenceDigest is None)
            or empty != (self.staleAtMs is None)
        ):
            raise ValueError("invalid_summary")
        if empty and (
            self.state != "unknown"
            or self.status != "unavailable"
            or self.reason != "no_trusted_frame"
            or self.confidenceBps != 0
            or self.count != 0
            or self.automationEligible
        ):
            raise ValueError("invalid_summary")
        if not empty and (
            self.staleAtMs <= self.observedAtMs
            or (self.status == "ready" and (
                self.state == "unknown" or self.reason != "trusted_frame"
            ))
            or (self.status == "degraded" and (
                self.state != "unknown"
                or self.reason not in {
                    "provider_degraded", "missing_frame", "corrupt_frame",
                    "wrong_camera_frame", "stale_frame",
                }
            ))
            or self.status == "unavailable"
        ):
            raise ValueError("invalid_summary")
        if self.reason != "trusted_frame" and self.automationEligible:
            raise ValueError("invalid_summary")
        return self


class VisualSensorRuleResponse(FrozenModel):
    schemaVersion: Literal[2]
    rule: VisualSensorSummary


class VisualSensorSummaryResponse(FrozenModel):
    schemaVersion: Literal[2]
    scope: HomeScope
    capability: VisualEngineCapability
    rules: list[VisualSensorSummary] = Field(max_length=64)


class SubmitVisualSensorObservation(FrozenModel):
    schemaVersion: Literal[1]
    expectedRuleRevision: Revision
    capability: VisualEngineCapability
    batch: DetectionBatch

    @model_validator(mode="after")
    def ready_worker(self):
        if self.capability.detectorState != "ready":
            raise ValueError("detector_not_ready")
        return self


class VisualSensorObservationResponse(FrozenModel):
    schemaVersion: Literal[1]
    reading: VisualSensorReading
