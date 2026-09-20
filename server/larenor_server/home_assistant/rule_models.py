from typing import Literal

from pydantic import Field, model_validator

from ..admin.models import ObjectId, Revision
from ..home_resources.models import ResourceRef
from ..models import StrictModel


class RuleCreateRequest(StrictModel):
    schemaVersion: Literal[1] = 1
    action: Literal['turn_on', 'turn_off']
    expectedResourceRevision: Revision
    expectedAclRevision: Revision
    expectedBindingRevision: Revision
    expectedServiceRevision: Revision


class RuleExecuteRequest(StrictModel):
    schemaVersion: Literal[1] = 1
    requestId: ObjectId
    expectedRuleRevision: Revision


class RuleRecord(StrictModel):
    schemaVersion: Literal[1] = 1
    id: ObjectId
    revision: Literal[1] = 1
    ref: ResourceRef
    action: Literal['turn_on', 'turn_off']
    creatorId: ObjectId
    resourceRevision: Revision
    aclRevision: Revision
    bindingId: ObjectId
    bindingRevision: Revision
    serviceId: ObjectId
    serviceRevision: Revision

    @model_validator(mode='after')
    def resource_only(self):
        if self.ref.kind != 'resource':
            raise ValueError('invalid_rule_target')
        return self


class RuleResponse(StrictModel):
    rule: RuleRecord
