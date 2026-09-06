"""Pure appdata volume proposals; no transport, host access or ownership grant.

This is a separate domain from ResourcePreparationPlan v1 and its inode-based
journal. Names never prove creation, exclusive ownership, safe container mount
or UID write access. A later typed volume journal and verified bootstrap are
required. Existing library paths and Music Assistant host networking remain
unchanged. Engine API 1.47 supports named local volumes but driver options may
perform other mount types; this proposal deliberately has no options field.

References: https://raw.githubusercontent.com/moby/moby/v27.5.1/api/swagger.yaml
and https://docs.docker.com/engine/storage/volumes/ . NoCopy is the proposed
container-mount behavior, not an option of the volume-create API.
"""

import hashlib
from typing import Annotated, Literal

from pydantic import Field, StrictBool, model_validator

from ..context import Identity
from .models import Catalog, Digest, FrozenModel, Platform, RootId, ServiceId, TargetPath
from .resource_models import WorkerPolicyBinding
from .resource_plan import _wire, build_resource_plan
from .stack_plan import MediaStackPlan, _canonical


class ManagedVolumeProposal(FrozenModel):
    resourceId: Identity
    operationId: Identity
    serviceId: ServiceId
    installationId: Identity
    childPlanHash: Digest
    requestedRootId: RootId
    requestedRelativePath: Annotated[str, Field(max_length=48,
        pattern=r'^[a-z][a-z0-9-]{0,39}/(?:config|cache|data)$')]
    target: TargetPath
    name: Annotated[str, Field(max_length=51, pattern=r'^larenor-appdata-v1-[0-9a-f]{32}$')]
    driver: Literal['local']
    scope: Literal['local']
    containerUser: Literal['1000:1000', '0:0']
    readOnly: StrictBool
    noCopy: StrictBool
    readiness: Literal['requires_bootstrap_validation']

    @model_validator(mode='after')
    def fixed_mapping(self):
        if self.name != 'larenor-appdata-v1-' + self.resourceId or self.readOnly or not self.noCopy:
            raise ValueError('invalid_volume_proposal')
        return self


class VolumeStoragePlan(FrozenModel):
    schemaVersion: int = Field(ge=1, le=1)
    coreId: Identity
    homeId: Identity
    preparationId: Identity
    platform: Platform
    catalogDigest: Digest
    stackPlanHash: Digest
    workerPolicyVersion: int = Field(ge=1, le=2**31 - 1)
    workerPolicyDigest: Digest
    planHash: Digest
    installAvailable: StrictBool
    bindingStatus: Literal['proposed']
    resources: tuple[ManagedVolumeProposal, ...] = Field(min_length=7, max_length=7)

    @model_validator(mode='after')
    def no_execution_grant(self):
        ids = [value for resource in self.resources
               for value in (resource.resourceId, resource.operationId)]
        targets = [(r.serviceId, r.target) for r in self.resources]
        if self.installAvailable or len(set(ids)) != len(ids) or len(set(targets)) != len(targets):
            raise ValueError('invalid_volume_plan')
        return self


class VolumePlanError(ValueError):
    """Static diagnostics; never echoes a supplied path, option or policy."""


def _id(kind, selected, child, target):
    parts = ('larenor-volume-plan-v1', kind, selected.coreId, selected.homeId,
             selected.preparationId, child.installationId, target)
    return hashlib.sha256('\0'.join(parts).encode('ascii')).hexdigest()[:32]


def build_volume_plan(stack, catalog, policy):
    """Re-derive from complete current inputs; never load policy or a catalog."""
    try:
        if type(stack) is not MediaStackPlan or type(catalog) is not Catalog or type(policy) is not WorkerPolicyBinding:
            raise ValueError()
        selected = MediaStackPlan.model_validate_json(_wire(stack))
        trusted = Catalog.model_validate_json(_wire(catalog))
        current_policy = WorkerPolicyBinding.model_validate_json(_wire(policy))
        # Reuse the existing complete stack/catalog validation, without changing
        # its 13 native resources or making a host directory mapping usable.
        native = build_resource_plan(selected, trusted, current_policy)
        resources = []
        for component in selected.components:
            child = component.plan
            for mount in child.mounts:
                if mount.kind != 'managed_appdata':
                    continue
                identity = _id('resource', selected, component, mount.target)
                resources.append(ManagedVolumeProposal(
                    resourceId=identity,
                    operationId=_id('operation', selected, component, mount.target),
                    serviceId=component.serviceId, installationId=component.installationId,
                    childPlanHash=child.planHash, requestedRootId=mount.rootId,
                    requestedRelativePath=mount.relativePath, target=mount.target,
                    name='larenor-appdata-v1-' + identity, driver='local', scope='local',
                    containerUser=child.security.user, readOnly=False, noCopy=True,
                    readiness='requires_bootstrap_validation'))
        result = VolumeStoragePlan(schemaVersion=1, coreId=selected.coreId,
            homeId=selected.homeId, preparationId=selected.preparationId, platform=selected.platform,
            catalogDigest=native.catalogDigest, stackPlanHash=native.stackPlanHash,
            workerPolicyVersion=current_policy.workerPolicyVersion,
            workerPolicyDigest=current_policy.workerPolicyDigest, planHash='0' * 64,
            installAvailable=False, bindingStatus='proposed', resources=tuple(resources))
        return result.model_copy(update={'planHash': hashlib.sha256(
            _canonical(result.model_dump(mode='json', exclude={'planHash'}))).hexdigest()})
    except (ValueError, TypeError, AttributeError, KeyError, RecursionError):
        raise VolumePlanError('volume_inputs_untrusted') from None


def verify_volume_plan(plan, stack, catalog, policy):
    """Validate bytes and rederive; a saved hash or name is never authority."""
    try:
        if type(plan) is not VolumeStoragePlan:
            raise ValueError()
        validated = VolumeStoragePlan.model_validate_json(_wire(plan))
        expected = build_volume_plan(stack, catalog, policy)
        if validated != expected:
            raise ValueError()
        return expected
    except (ValueError, TypeError, AttributeError, RecursionError):
        raise VolumePlanError('volume_plan_untrusted') from None
