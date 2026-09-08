from typing import Annotated, Literal
import re

from pydantic import Field, field_validator

from ..home_resources.models import FrozenModel, Identity, Revision, ResourceRef


EntityId = Annotated[str, Field(min_length=8, max_length=128)]


class PreviewRequest(FrozenModel):
    serviceId: Identity
    expectedServiceRevision: Revision
    expectedRevision: Revision
    expectedAclRevision: Revision
    entityId: EntityId
    expectedBindingId: Identity | None

    @field_validator('entityId')
    @classmethod
    def switch_entity(cls, value):
        if not re.fullmatch(r'switch\.[a-z0-9_]+', value):
            raise ValueError('invalid_entity')
        return value


class ConfirmRequest(FrozenModel):
    previewId: Identity


class Projection(FrozenModel):
    kind: Literal['switch'] = 'switch'
    state: Literal['on', 'off', 'unavailable']
    commandAvailable: Literal[False] = False

    @field_validator('commandAvailable', mode='before')
    @classmethod
    def literal_false(cls, value):
        if type(value) is not bool or value is not False:
            raise ValueError('invalid_capability')
        return value


class Binding(FrozenModel):
    schemaVersion: Literal[1] = 1
    id: Identity
    revision: Revision
    ref: ResourceRef
    serviceId: Identity
    serviceRevision: Revision
    entityId: EntityId

    _entity = field_validator('entityId')(PreviewRequest.switch_entity.__func__)


class BindingResponse(FrozenModel):
    binding: Binding


class Preview(FrozenModel):
    id: Identity
    expiresInMs: int = Field(ge=1, le=60000)
    binding: Binding
    projection: Projection


class PreviewResponse(FrozenModel):
    preview: Preview


class Snapshot(FrozenModel):
    schemaVersion: Literal[1] = 1
    ref: ResourceRef
    bindingId: Identity
    bindingRevision: Revision
    resourceRevision: Revision
    aclRevision: Revision
    serviceRevision: Revision
    observedAt: str = Field(max_length=40)
    remainingTtlMs: int = Field(ge=0, le=5000)
    projection: Projection


class SnapshotResponse(FrozenModel):
    snapshot: Snapshot
