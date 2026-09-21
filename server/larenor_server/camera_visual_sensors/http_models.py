from typing import Annotated, Literal

from pydantic import Field, field_validator

from ..home_resources.models import FrozenModel, HomeScope, Identity, Revision
from .models import VisualSensorRule, _safe_label


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
        "ready",
    ]


class VisualSensorSummary(FrozenModel):
    schemaVersion: Literal[1]
    ruleId: Identity
    ruleRevision: Revision
    cameraId: Identity
    pipelineId: Identity
    pipelineRevision: Revision
    modelId: Identity
    modelRevision: Revision
    label: Annotated[str, Field(min_length=1, max_length=80)]
    state: Literal["unknown"]
    status: Literal["unavailable"]
    reason: Literal["no_trusted_frame"]
    confidenceBps: Literal[0]
    count: Literal[0]
    automationEligible: Literal[False]
    accessControlEligible: Literal[False]

    _label = field_validator("label")(_safe_label)


class VisualSensorRuleResponse(FrozenModel):
    schemaVersion: Literal[1]
    rule: VisualSensorSummary


class VisualSensorSummaryResponse(FrozenModel):
    schemaVersion: Literal[1]
    scope: HomeScope
    capability: VisualEngineCapability
    rules: list[VisualSensorSummary] = Field(max_length=64)
