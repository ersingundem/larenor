"""Pure fixed consumers for the single Larenor-managed media library volume.

This plan gives no mount or installation authority. It relates the existing
managed library proposal to the four catalog children that must consume the
same named volume. A later worker binding must still prove the volume and each
container under one retained daemon lease.
"""

import hashlib
from typing import Literal

from pydantic import Field, StrictBool, model_validator

from ..context import Identity
from .models import Digest, FrozenModel, RootId
from .resource_models import WorkerPolicyBinding
from .resource_plan import _wire
from .stack_plan import MediaStackPlan, _canonical, verify_media_stack_plan
from .volume_plan import (
    VolumeStoragePlan,
    verify_volume_plan,
)


_ORDER = ('qbittorrent', 'sonarr', 'radarr', 'jellyfin')


class SharedLibraryConsumer(FrozenModel):
    serviceId: Literal['qbittorrent', 'sonarr', 'radarr', 'jellyfin']
    installationId: Identity
    childPlanHash: Digest
    target: Literal['/data', '/media']
    readOnly: StrictBool
    containerUser: Literal['1000:1000']

    @model_validator(mode='after')
    def fixed_access(self):
        expected_target = '/media' if self.serviceId == 'jellyfin' else '/data'
        if (self.target != expected_target
                or self.readOnly is not (self.serviceId == 'jellyfin')):
            raise ValueError('invalid_shared_library_consumer')
        return self


class SharedLibraryConsumerPlan(FrozenModel):
    schemaVersion: int = Field(ge=1, le=1)
    coreId: Identity
    homeId: Identity
    preparationId: Identity
    stackPlanHash: Digest
    volumePlanHash: Digest
    resourceId: Identity
    operationId: Identity
    name: str = Field(
        max_length=51, pattern=r'^larenor-library-v1-[0-9a-f]{32}$')
    requestedRootId: RootId
    planHash: Digest
    installAvailable: StrictBool
    bindingStatus: Literal['proposed']
    consumers: tuple[SharedLibraryConsumer, ...] = Field(
        min_length=4, max_length=4)

    @model_validator(mode='after')
    def fixed_topology(self):
        if (
            self.installAvailable
            or tuple(item.serviceId for item in self.consumers) != _ORDER
            or len({item.installationId for item in self.consumers}) != 4
        ):
            raise ValueError('invalid_shared_library_consumer_plan')
        return self


class SharedLibraryConsumerPlanError(ValueError):
    """Static diagnostics; supplied roots and nested values are never echoed."""


def build_shared_library_consumer_plan(volumes, stack, catalog, policy):
    """Relate exact catalog mounts to one existing managed volume proposal."""
    try:
        if (
            type(volumes) is not VolumeStoragePlan
            or type(stack) is not MediaStackPlan
            or type(policy) is not WorkerPolicyBinding
        ):
            raise ValueError()
        selected_volumes = verify_volume_plan(
            volumes, stack, catalog, policy)
        selected_stack = verify_media_stack_plan(stack, catalog)
        owners = tuple(
            item for item in selected_volumes.resources
            if item.kind == 'managed_library'
        )
        if len(owners) != 1:
            raise ValueError()
        owner = owners[0]
        consumers = []
        for service_id in _ORDER:
            component = next(
                item for item in selected_stack.components
                if item.serviceId == service_id
            )
            target = '/media' if service_id == 'jellyfin' else '/data'
            mounts = tuple(
                item for item in component.plan.mounts
                if item.kind == 'approved_library' and item.target == target
            )
            if len(mounts) != 1:
                raise ValueError()
            mount = mounts[0]
            read_only = service_id == 'jellyfin'
            if (
                mount.rootId != owner.requestedRootId
                or mount.relativePath != ''
                or mount.readOnly is not read_only
                or component.plan.security.user != '1000:1000'
            ):
                raise ValueError()
            consumers.append(SharedLibraryConsumer(
                serviceId=service_id,
                installationId=component.installationId,
                childPlanHash=component.plan.planHash,
                target=target,
                readOnly=read_only,
                containerUser='1000:1000',
            ))
        result = SharedLibraryConsumerPlan(
            schemaVersion=1,
            coreId=selected_stack.coreId,
            homeId=selected_stack.homeId,
            preparationId=selected_stack.preparationId,
            stackPlanHash=selected_stack.planHash,
            volumePlanHash=selected_volumes.planHash,
            resourceId=owner.resourceId,
            operationId=owner.operationId,
            name=owner.name,
            requestedRootId=owner.requestedRootId,
            planHash='0' * 64,
            installAvailable=False,
            bindingStatus='proposed',
            consumers=tuple(consumers),
        )
        digest = hashlib.sha256(_canonical(
            result.model_dump(mode='json', exclude={'planHash'}))).hexdigest()
        return result.model_copy(update={'planHash': digest})
    except (
        ValueError, TypeError, AttributeError, KeyError, StopIteration,
        RecursionError,
    ):
        raise SharedLibraryConsumerPlanError(
            'shared_library_consumer_inputs_untrusted') from None


def verify_shared_library_consumer_plan(value, volumes, stack, catalog, policy):
    """Rebuild from current source models; a saved plan is never authority."""
    try:
        if type(value) is not SharedLibraryConsumerPlan:
            raise ValueError()
        validated = SharedLibraryConsumerPlan.model_validate_json(_wire(value))
        expected = build_shared_library_consumer_plan(
            volumes, stack, catalog, policy)
        if validated != expected:
            raise ValueError()
        return expected
    except (
        ValueError, TypeError, AttributeError, RecursionError,
        SharedLibraryConsumerPlanError,
    ):
        raise SharedLibraryConsumerPlanError(
            'shared_library_consumer_plan_untrusted') from None
