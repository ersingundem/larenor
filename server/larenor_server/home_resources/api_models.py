"""Registry management metadata only. A write permission exposes no device command."""
from pydantic import Field

from .models import (FrozenModel, GrantSnapshot, HomeScope, Identity, Kind, LabelFields,
                     Permissions, RegistryRecord, Revision, Snapshot)


class CreateRecordRequest(LabelFields):
    kind: Kind


class UpdateRecordRequest(LabelFields):
    expectedRevision: Revision
    expectedAclRevision: Revision


class SetGrantRequest(FrozenModel):
    expectedAclRevision: Revision
    permissions: Permissions


class StoredRecord(LabelFields):
    grants: dict[Identity, Permissions] = Field(max_length=128, repr=False)


class RecordResponse(FrozenModel):
    record: RegistryRecord


class ListResponse(FrozenModel):
    scope: HomeScope
    entries: list[RegistryRecord] = Field(max_length=100)
    snapshot: Snapshot
    nextAfter: Identity | None


class GrantResponse(FrozenModel):
    grant: GrantSnapshot


class GrantsResponse(FrozenModel):
    grants: list[GrantSnapshot] = Field(max_length=128)
    aclRevision: Revision
