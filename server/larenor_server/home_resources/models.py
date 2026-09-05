"""Closed, immutable metadata contracts. User subjects are login accounts, not people profiles."""
from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator


Identity = Annotated[str, Field(min_length=32, max_length=32, pattern=r'^[0-9a-f]{32}$')]
Snapshot = Annotated[str, Field(min_length=64, max_length=64, pattern=r'^[0-9a-f]{64}$')]
Revision = Annotated[int, Field(ge=1, le=2**63 - 1)]
Kind = Literal['room', 'resource']
Action = Literal['read', 'write']


class FrozenModel(BaseModel):
    model_config = ConfigDict(strict=True, extra='forbid', frozen=True, revalidate_instances='always')


class HomeScope(FrozenModel):
    schemaVersion: Literal[1]
    coreId: Identity
    homeId: Identity

    @field_validator('schemaVersion', mode='before')
    @classmethod
    def integer_version(cls, value):
        if type(value) is not int:
            raise ValueError('invalid_schema')
        return value


class ResourceRef(HomeScope):
    kind: Kind
    id: Identity


class SubjectRef(FrozenModel):
    """A users.id grant subject; never an upstream person or household profile."""
    userId: Identity


class Permissions(FrozenModel):
    read: bool
    write: bool

    @model_validator(mode='after')
    def write_needs_read(self):
        if self.write and not self.read:
            raise ValueError('write_requires_read')
        return self


class LabelFields(FrozenModel):
    label: str = Field(min_length=1, max_length=80)
    order: int = Field(ge=0, le=10000)

    @field_validator('label')
    @classmethod
    def safe_label(cls, value):
        if any(ord(c) < 32 or ord(c) == 127 or 0xD800 <= ord(c) <= 0xDFFF for c in value):
            raise ValueError('invalid_label')
        value = value.strip()
        if not value:
            raise ValueError('invalid_label')
        return value


class RegistryRecord(LabelFields):
    ref: ResourceRef
    revision: Revision
    aclRevision: Revision
    permissions: Permissions


class GrantSnapshot(FrozenModel):
    subjectId: Identity
    target: ResourceRef
    aclRevision: Revision
    permissions: Permissions


class ActorFacts(FrozenModel):
    """Private facts read by packaged DB code, not an HTTP credential or permit."""
    userId: Identity
    revision: Revision
    role: Literal['admin', 'member']
    disabled: bool
    mustChangePassword: bool
    sessionCurrent: bool


class TargetFacts(FrozenModel):
    ref: ResourceRef
    revision: Revision
    aclRevision: Revision
    active: bool


class AccessDecision(FrozenModel):
    allowed: bool
    code: Literal['allowed', 'cancelled', 'scope_mismatch', 'actor_invalid',
                  'target_unavailable', 'revision_conflict', 'forbidden']
