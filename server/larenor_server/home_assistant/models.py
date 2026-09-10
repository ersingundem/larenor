from typing import Annotated, Literal
import re
import unicodedata

from pydantic import Field, field_validator, model_validator

from ..home_resources.models import FrozenModel, Identity, Revision, ResourceRef


EntityId = Annotated[str, Field(min_length=3, max_length=128)]
_ENTITY = re.compile(r'[a-z0-9_]{1,64}\.[a-z0-9_]{1,121}\Z')


class PreviewRequest(FrozenModel):
    serviceId: Identity
    expectedServiceRevision: Revision
    expectedRevision: Revision
    expectedAclRevision: Revision
    entityId: EntityId
    expectedBindingId: Identity | None

    @field_validator('entityId')
    @classmethod
    def safe_entity(cls, value):
        if _ENTITY.fullmatch(value) is None:
            raise ValueError('invalid_entity')
        return value

    @classmethod
    def switch_entity(cls, value):
        if not re.fullmatch(r'switch\.[a-z0-9_]{1,121}', value):
            raise ValueError('invalid_entity')
        return value


class ConfirmRequest(FrozenModel):
    previewId: Identity


class Projection(FrozenModel):
    kind: Annotated[str, Field(min_length=1, max_length=64, pattern=r'^[a-z0-9_]+$')] = 'switch'
    state: Annotated[str, Field(min_length=1, max_length=255)]
    commandAvailable: bool = False

    @field_validator('commandAvailable', mode='before')
    @classmethod
    def literal_boolean(cls, value):
        if type(value) is not bool:
            raise ValueError('invalid_capability')
        return value

    @model_validator(mode='after')
    def closed_capability(self):
        if any(unicodedata.category(char).startswith('C') for char in self.state):
            raise ValueError('invalid_state')
        if self.kind == 'switch':
            if self.state not in {'on', 'off', 'unavailable'}:
                raise ValueError('invalid_state')
        elif self.commandAvailable:
            raise ValueError('invalid_capability')
        return self


class Binding(FrozenModel):
    schemaVersion: Literal[1] = 1
    id: Identity
    revision: Revision
    ref: ResourceRef
    serviceId: Identity
    serviceRevision: Revision
    entityId: EntityId

    _entity = field_validator('entityId')(PreviewRequest.safe_entity.__func__)


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


class CommandRequest(FrozenModel):
    schemaVersion: Literal[1] = 1
    requestId: Identity
    action: Literal['turn_on', 'turn_off']
    expectedBindingRevision: Revision
    expectedResourceRevision: Revision
    expectedAclRevision: Revision

    @field_validator('schemaVersion', mode='before')
    @classmethod
    def integer_version(cls, value):
        if type(value) is not int:
            raise ValueError('invalid_schema')
        return value


class CommandReceipt(FrozenModel):
    schemaVersion: Literal[1] = 1
    requestId: Identity
    ref: ResourceRef
    bindingId: Identity
    bindingRevision: Revision
    actorId: Identity
    action: Literal['turn_on', 'turn_off']
    dispatchState: Literal['pending', 'accepted', 'rejected', 'unknown']
    providerAccepted: bool | None
    observedProjection: Projection | None
    observationMatchesTarget: bool | None
    causalityVerified: Literal[False] = False
    createdAt: str = Field(max_length=40)
    completedAt: str | None = Field(default=None, max_length=40)

    @field_validator('causalityVerified', mode='before')
    @classmethod
    def literal_false(cls, value):
        if type(value) is not bool or value is not False:
            raise ValueError('invalid_capability')
        return value


class LegacyStoredCommand(FrozenModel):
    request: CommandRequest
    receipt: CommandReceipt


class CommandAttribution(FrozenModel):
    schemaVersion: Literal[1] = 1
    correlationId: Identity
    source: Literal['core_api', 'unknown']
    reason: Literal['explicit_command_request', 'unknown']
    serviceId: Identity | None
    serviceRevision: Revision | None

    _integer_version = field_validator('schemaVersion', mode='before')(CommandRequest.integer_version.__func__)

    @model_validator(mode='after')
    def known_source(self):
        if self.source == 'unknown':
            if self.reason != 'unknown' or self.serviceId is not None or self.serviceRevision is not None:
                raise ValueError('invalid_attribution')
        elif self.reason != 'explicit_command_request' or self.serviceId is None or self.serviceRevision is None:
            raise ValueError('invalid_attribution')
        return self


class StoredCommand(LegacyStoredCommand):
    attribution: CommandAttribution

    @model_validator(mode='after')
    def same_correlation(self):
        if self.attribution.correlationId != self.request.requestId:
            raise ValueError('invalid_attribution')
        return self


class CommandHistoryEntry(FrozenModel):
    attribution: CommandAttribution
    receipt: CommandReceipt


class CommandHistoryResponse(FrozenModel):
    schemaVersion: Literal[1] = 1
    ref: ResourceRef
    entries: list[CommandHistoryEntry] = Field(max_length=50)
    nextBefore: Identity | None


class CommandResponse(FrozenModel):
    receipt: CommandReceipt
