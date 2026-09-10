"""Public contract for the bounded container phase of one media preparation."""

from typing import Literal

from pydantic import Field, model_validator

from ..admin.models import ObjectId, Revision
from ..models import StrictModel
from .models import Digest
from .stack_plan import MediaStackPlan


class CreateMediaInstallationRequest(StrictModel):
    requestId: ObjectId
    preparationId: ObjectId
    inspectionId: ObjectId
    expectedPreparationRevision: Revision
    expectedInspectionRevision: Revision
    planHash: Digest
    serviceId: Literal['jellyfin', 'seerr', 'music_assistant'] = 'jellyfin'


class CancelMediaInstallationRequest(StrictModel):
    expectedRevision: Revision


class MediaInstallationStep(StrictModel):
    stepId: ObjectId
    kind: Literal['create_container', 'start_container']


class MediaInstallation(StrictModel):
    id: ObjectId
    requestId: ObjectId
    preparationId: ObjectId
    inspectionId: ObjectId
    serviceId: Literal['jellyfin', 'seerr', 'music_assistant']
    operationId: ObjectId
    revision: Revision
    state: Literal['queued', 'running', 'container_started', 'needs_attention', 'failed', 'cancelled']
    phase: Literal['queued', 'executing', 'complete']
    cancelRequested: bool
    installAvailable: Literal[False] = False
    steps: list[MediaInstallationStep] = Field(min_length=2, max_length=2)
    errorCode: Literal['authority_changed', 'context_changed', 'preparation_changed',
                       'inspection_changed', 'catalog_changed', 'worker_unavailable',
                       'invalid_worker_result', 'resource_conflict', 'dispatch_expired',
                       'container_not_running'] | None
    createdAt: str
    updatedAt: str

    @model_validator(mode='after')
    def coherent(self):
        if tuple(step.kind for step in self.steps) != ('create_container', 'start_container'):
            raise ValueError('invalid_installation_state')
        if self.state == 'queued' and (self.phase != 'queued' or self.revision != 1 or self.cancelRequested):
            raise ValueError('invalid_installation_state')
        if self.state == 'running' and (self.phase != 'executing' or self.revision < 2):
            raise ValueError('invalid_installation_state')
        if self.state not in ('queued', 'running') and (self.phase != 'complete' or self.revision < 2):
            raise ValueError('invalid_installation_state')
        if self.state in ('queued', 'running', 'container_started', 'cancelled') and self.errorCode is not None:
            raise ValueError('invalid_installation_state')
        if self.state == 'cancelled' and not self.cancelRequested:
            raise ValueError('invalid_installation_state')
        if self.state in ('needs_attention', 'failed') and self.errorCode is None:
            raise ValueError('invalid_installation_state')
        return self


class MediaInstallationResponse(StrictModel):
    installation: MediaInstallation


class MediaInstallationsResponse(StrictModel):
    installations: list[MediaInstallation] = Field(max_length=10)
    nextBefore: int | None


class MediaInstallationCapabilities(StrictModel):
    executionConfigured: bool
    installAvailable: Literal[False] = False
    services: list[Literal['jellyfin', 'seerr', 'music_assistant']] = Field(
        default_factory=lambda: ['jellyfin', 'seerr', 'music_assistant'],
        min_length=3, max_length=3)


class MediaInstallationPayload(StrictModel):
    request: CreateMediaInstallationRequest
    plan: MediaStackPlan
    deadline: int = Field(ge=1, le=253402300799)
