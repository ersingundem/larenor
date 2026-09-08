"""One explicit credential tuple and unbound switch; no general import schema."""
from typing import Literal

from pydantic import Field, field_validator, model_validator

from ..home_resources.models import FrozenModel, Identity, Revision, ResourceRef
from ..services.models import PublicService, canonical_base_url, safe_text
from .models import Binding, EntityId, PreviewRequest, Projection


class MigrationInput(FrozenModel):
    requestId: Identity
    name: str = Field(min_length=1, max_length=80)
    baseUrl: str = Field(min_length=1, max_length=2048)
    token: str = Field(min_length=1, max_length=2048, repr=False, json_schema_extra={'writeOnly': True})
    entityId: EntityId
    expectedRevision: Revision
    expectedAclRevision: Revision

    @field_validator('name')
    @classmethod
    def name_text(cls, value):
        value = safe_text(value).strip()
        if not value:
            raise ValueError('invalid_name')
        return value

    @field_validator('token')
    @classmethod
    def token_bytes(cls, value):
        if any(not 33 <= ord(char) <= 126 for char in value):
            raise ValueError('invalid_token')
        return value

    _url = field_validator('baseUrl')(canonical_base_url)
    _entity = field_validator('entityId')(PreviewRequest.switch_entity.__func__)


class MigrationConfirm(MigrationInput):
    previewId: Identity


class MigrationReceipt(FrozenModel):
    schemaVersion: Literal[1] = 1
    requestId: Identity
    status: Literal['committed'] = 'committed'
    ref: ResourceRef
    resourceRevision: Revision
    aclRevision: Revision
    service: PublicService
    binding: Binding

    @model_validator(mode='after')
    def paired(self):
        if (self.ref.kind != 'resource' or self.binding.ref != self.ref or
                self.service.kind != 'home_assistant' or self.service.revision != 1 or
                self.service.credentialKeys != ['token'] or self.service.verification.state != 'never' or
                self.binding.serviceId != self.service.id or self.binding.serviceRevision != 1 or
                self.binding.revision != 1):
            raise ValueError('invalid_pair')
        return self


class MigrationPreview(FrozenModel):
    id: Identity
    requestId: Identity
    expiresInMs: int = Field(ge=1, le=60000)
    ref: ResourceRef
    resourceRevision: Revision
    aclRevision: Revision
    service: PublicService
    binding: Binding
    projection: Projection


class StoredMigration(FrozenModel):
    actorId: Identity
    previewId: Identity
    digest: str = Field(min_length=64, max_length=64, pattern=r'^[0-9a-f]{64}$', repr=False)
    receipt: MigrationReceipt


class MigrationPreviewResponse(FrozenModel):
    preview: MigrationPreview


class MigrationReceiptResponse(FrozenModel):
    receipt: MigrationReceipt
