"""Aggregate observations for one media preparation; no installation authority."""

from datetime import datetime
from typing import Literal

from pydantic import Field, field_validator, model_validator

from ..admin.models import ObjectId, Revision
from ..models import StrictModel
from .job_models import Phase, Sequence, State, Timestamp
from .models import Digest, Platform
from .preflight_models import PreflightResult
from .stack_plan import MediaStackPlan


Failure = Literal['worker_unavailable', 'invalid_worker_result', 'authority_changed',
                  'catalog_changed', 'preparation_changed', 'context_changed']


class CreateMediaInspectionRequest(StrictModel):
    requestId: ObjectId
    preparationId: ObjectId
    expectedRevision: Revision
    planHash: Digest


class CancelMediaInspectionRequest(StrictModel):
    expectedRevision: Revision


class MediaInspectionPayload(StrictModel):
    request: CreateMediaInspectionRequest
    plan: MediaStackPlan
    result: PreflightResult | None = None


class MediaInspection(StrictModel):
    id: ObjectId
    requestId: ObjectId
    preparationId: ObjectId
    preparationRevision: int = Field(ge=1, le=1)
    coreId: ObjectId
    homeId: ObjectId
    catalogDigest: Digest
    planHash: Digest
    platform: Platform
    revision: Revision
    state: State
    phase: Phase
    cancelRequested: bool
    createdAt: Timestamp
    updatedAt: Timestamp
    result: PreflightResult | None
    errorCode: Failure | None

    @field_validator('createdAt', 'updatedAt')
    @classmethod
    def valid_time(cls, value):
        datetime.fromisoformat(value.replace('Z', '+00:00'))
        return value

    @model_validator(mode='after')
    def coherent_state(self):
        if self.updatedAt < self.createdAt:
            raise ValueError('invalid_inspection_state')
        if self.state in ('queued', 'running'):
            phase = 'queued' if self.state == 'queued' else 'checking_requirements'
            if self.phase != phase or self.result is not None or self.errorCode is not None:
                raise ValueError('invalid_inspection_state')
            if self.state == 'queued' and (self.cancelRequested or self.revision != 1):
                raise ValueError('invalid_inspection_state')
            if self.state == 'running' and self.revision < 2:
                raise ValueError('invalid_inspection_state')
        elif self.phase != 'complete' or self.revision < 2:
            raise ValueError('invalid_inspection_state')
        if self.state == 'succeeded':
            if self.result is None or self.errorCode is not None or self.cancelRequested:
                raise ValueError('invalid_inspection_state')
            if (self.result.catalogDigest != self.catalogDigest or self.result.planHash != self.planHash
                    or self.result.platform != self.platform):
                raise ValueError('invalid_inspection_result')
        elif self.result is not None:
            raise ValueError('invalid_inspection_state')
        if self.state == 'failed' and (self.errorCode not in ('worker_unavailable', 'invalid_worker_result') or self.cancelRequested):
            raise ValueError('invalid_inspection_state')
        if self.state == 'needs_attention' and (self.errorCode not in (
                'authority_changed', 'catalog_changed', 'preparation_changed', 'context_changed') or self.cancelRequested):
            raise ValueError('invalid_inspection_state')
        if self.state == 'cancelled' and (not self.cancelRequested or self.errorCode is not None):
            raise ValueError('invalid_inspection_state')
        return self


class MediaInspectionResponse(StrictModel):
    inspection: MediaInspection


class MediaInspectionsResponse(StrictModel):
    inspections: list[MediaInspection] = Field(max_length=10)
    nextBefore: Sequence | None


class MediaInspectionCapabilities(StrictModel):
    inspectionConfigured: bool
    installAvailable: Literal[False] = False
