from typing import Annotated, Literal

from pydantic import Field, field_validator

from ..home_resources.models import FrozenModel, HomeScope, Identity, ResourceRef, Revision


class WorkflowTargetRequest(FrozenModel):
    kind: Literal["home_assistant_switch"]
    resourceId: Identity
    action: Literal["turn_on", "turn_off"]
    expectedBindingRevision: Revision
    expectedResourceRevision: Revision
    expectedAclRevision: Revision


class CreateWorkflowRequest(FrozenModel):
    schemaVersion: Literal[1]
    requestId: Identity
    title: Annotated[str, Field(min_length=1, max_length=80)]
    deadlineSeconds: Annotated[int, Field(ge=1, le=86400)]
    target: WorkflowTargetRequest

    @field_validator("schemaVersion", mode="before")
    @classmethod
    def integer_version(cls, value):
        if type(value) is not int:
            raise ValueError("invalid_schema")
        return value

    @field_validator("deadlineSeconds", mode="before")
    @classmethod
    def integer_deadline(cls, value):
        if type(value) is not int:
            raise ValueError("invalid_deadline")
        return value

    @field_validator("title")
    @classmethod
    def safe_title(cls, value):
        value = value.strip()
        if not value or any(ord(char) < 32 or ord(char) == 127 for char in value):
            raise ValueError("invalid_title")
        return value


class WorkflowDecisionRequest(FrozenModel):
    schemaVersion: Literal[1]
    decisionId: Identity
    expectedRevision: Revision
    decision: Literal["approve", "cancel", "effect_applied", "effect_not_applied"]

    _integer_version = field_validator("schemaVersion", mode="before") (
        CreateWorkflowRequest.integer_version.__func__
    )


class WorkflowResumeRequest(FrozenModel):
    schemaVersion: Literal[1]
    resumeId: Identity
    expectedRevision: Revision

    _integer_version = field_validator("schemaVersion", mode="before") (
        CreateWorkflowRequest.integer_version.__func__
    )


class WorkflowTarget(FrozenModel):
    kind: Literal["home_assistant_switch"]
    resource: ResourceRef
    action: Literal["turn_on", "turn_off"]
    bindingRevision: Revision
    resourceRevision: Revision
    aclRevision: Revision


class HomeWorkflow(FrozenModel):
    schemaVersion: Literal[1] = 1
    id: Identity
    revision: Revision
    requestId: Identity
    scope: HomeScope
    creatorId: Identity
    title: Annotated[str, Field(min_length=1, max_length=80)]
    target: WorkflowTarget
    state: Literal[
        "waiting_decision", "running", "reconciliation_required", "completed",
        "failed", "cancelled", "timed_out",
    ]
    decisionRequired: Literal["approve_effect", "reconcile_effect"] | None
    attempt: Annotated[int, Field(ge=1, le=3)]
    stepRequestId: Identity | None
    effectState: Literal["not_started", "accepted", "rejected", "unknown"]
    reconciliationResult: Literal["none", "effect_applied", "effect_not_applied"]
    cancelRequested: bool
    deadlineAt: Annotated[str, Field(max_length=40)]
    createdAt: Annotated[str, Field(max_length=40)]
    updatedAt: Annotated[str, Field(max_length=40)]


class WorkflowResponse(FrozenModel):
    schemaVersion: Literal[1] = 1
    workflow: HomeWorkflow


class WorkflowListResponse(FrozenModel):
    schemaVersion: Literal[1] = 1
    workflows: list[HomeWorkflow] = Field(max_length=50)
    nextBefore: Identity | None


class OperationRecord(FrozenModel):
    id: Identity
    kind: Literal["decision", "resume"]
    expectedRevision: Revision
    decision: Literal["approve", "cancel", "effect_applied", "effect_not_applied"] | None
    responseRevision: Revision


class WorkflowPayload(FrozenModel):
    request: CreateWorkflowRequest
    operations: list[OperationRecord] = Field(default_factory=list, max_length=16)
