"""Separate, closed wire contracts for local household profiles.

These models carry metadata and current access observations, never executable
authority. Creating a profile cannot create an account or bind an HA person.
The existing home-resources endpoint retains its room/resource-only contract.
"""
from typing import Literal

from pydantic import Field, field_validator

from ..home_resources.models import (
    FrozenModel, HomeScope, Identity, LabelFields, Permissions, Revision, Snapshot,
)


class PersonRef(HomeScope):
    kind: Literal['person']
    id: Identity


class PersonRecord(LabelFields):
    ref: PersonRef
    revision: Revision
    aclRevision: Revision
    permissions: Permissions


class CreatePersonRequest(LabelFields):
    """The server creates the identity; callers supply only display metadata."""


class UpdatePersonRequest(LabelFields):
    expectedRevision: Revision
    expectedAclRevision: Revision


class SetPersonGrantRequest(FrozenModel):
    expectedAclRevision: Revision
    permissions: Permissions


class PersonGrant(FrozenModel):
    """subjectId is a users.id, not the household profile's own identity."""
    subjectId: Identity
    target: PersonRef
    aclRevision: Revision
    permissions: Permissions


class StoredPerson(LabelFields):
    """Private persistence payload; no implicit upstream/account association."""
    grants: dict[Identity, Permissions] = Field(max_length=128, repr=False)

    @field_validator('grants')
    @classmethod
    def retain_only_visible_grants(cls, value):
        if any(not permission.read for permission in value.values()):
            raise ValueError('invalid_grants')
        return value


class PersonResponse(FrozenModel):
    person: PersonRecord


class PeopleResponse(FrozenModel):
    scope: HomeScope
    entries: list[PersonRecord] = Field(max_length=100)
    snapshot: Snapshot
    nextAfter: Identity | None


class PersonGrantResponse(FrozenModel):
    grant: PersonGrant


class PersonGrantsResponse(FrozenModel):
    aclRevision: Revision
    grants: list[PersonGrant] = Field(max_length=128)
