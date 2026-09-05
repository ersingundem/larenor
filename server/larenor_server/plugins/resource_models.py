"""Strict immutable resource proposals, separate from MediaStackPlan v1.

No field is a host path, credential, arbitrary Docker option or observed grant.
Policy digests identify caller-supplied policy; validation does not approve it.
"""

from typing import Annotated, Literal

from pydantic import Field, StrictBool, model_validator

from ..context import Identity
from .models import Digest, FrozenModel, ImageDigest, Platform, RootId, ServiceId, TargetPath


_ORDER = ('qbittorrent', 'sonarr', 'radarr', 'jellyfin', 'seerr', 'music_assistant')
Repository = Annotated[str, Field(max_length=160, pattern=r'^ghcr\.io/[a-z0-9-]+/[a-z0-9-]+$')]
OwnedPath = Annotated[str, Field(max_length=192, pattern=r'^larenor-managed-v1/(?:[0-9a-f]{32}/){3}[0-9a-f]{32}$')]
OwnedMountPath = Annotated[str, Field(max_length=200, pattern=r'^larenor-managed-v1/(?:[0-9a-f]{32}/){4}(?:config|cache|data)$')]


class WorkerPolicyBinding(FrozenModel):
    """Opaque identity supplied by trusted worker policy loading, not a grant."""

    schemaVersion: int = Field(ge=1, le=1)
    workerPolicyVersion: int = Field(ge=1, le=2**31 - 1)
    workerPolicyDigest: Digest


class ResourceImage(FrozenModel):
    repository: Repository
    platform: Platform
    digest: ImageDigest
    configDigest: ImageDigest
    indexDigest: ImageDigest
    reference: Annotated[str, Field(max_length=240, pattern=r'^ghcr\.io/[a-z0-9-]+/[a-z0-9-]+@sha256:[0-9a-f]{64}$')]

    @model_validator(mode='after')
    def digest_only_reference(self):
        if self.reference != self.repository + '@' + self.digest:
            raise ValueError('invalid_resource_image')
        return self


class _ChildResource(FrozenModel):
    resourceId: Identity
    operationId: Identity
    serviceId: ServiceId
    installationId: Identity
    childPlanHash: Digest


class EnsureImageResource(_ChildResource):
    kind: Literal['ensure_image']
    manifestDigest: Digest
    image: ResourceImage
    ownership: Literal['shared_cache']


class AppdataMountProposal(FrozenModel):
    requestedRelativePath: Annotated[str, Field(max_length=48, pattern=r'^[a-z][a-z0-9-]{0,39}/(?:config|cache|data)$')]
    proposedRelativePath: OwnedMountPath
    target: TargetPath
    readOnly: StrictBool

    @model_validator(mode='after')
    def writable_proposal(self):
        if self.readOnly:
            raise ValueError('invalid_appdata_proposal')
        return self


class PrepareAppdataResource(_ChildResource):
    kind: Literal['prepare_appdata']
    rootId: RootId
    mapping: Literal['proposed_owned_appdata_v1']
    relativePath: OwnedPath
    mounts: tuple[AppdataMountProposal, ...] = Field(min_length=1, max_length=3)
    ownership: Literal['requires_verified_id_mapping']

    @model_validator(mode='after')
    def explicit_mount_mapping(self):
        for mount in self.mounts:
            leaf = mount.requestedRelativePath.rsplit('/', 1)[1]
            if mount.proposedRelativePath != self.relativePath + '/' + leaf:
                raise ValueError('invalid_appdata_proposal')
        for values in ((m.target for m in self.mounts), (m.proposedRelativePath for m in self.mounts)):
            items = tuple(values)
            if len(set(items)) != len(items):
                raise ValueError('duplicate_appdata_proposal')
        return self


class PrepareControlNetworkResource(FrozenModel):
    kind: Literal['prepare_control_network']
    resourceId: Identity
    operationId: Identity
    name: Annotated[str, Field(max_length=48, pattern=r'^larenor-control-[0-9a-f]{32}$')]
    driver: Literal['bridge']
    scope: Literal['local']
    internal: StrictBool
    attachable: StrictBool
    ingress: StrictBool
    configOnly: StrictBool

    @model_validator(mode='after')
    def fixed_unattached_network(self):
        if (self.name != 'larenor-control-' + self.resourceId
                or (self.internal, self.attachable, self.ingress, self.configOnly) != (True, False, False, False)):
            raise ValueError('invalid_control_network_proposal')
        return self


ResourceProposal = Annotated[
    EnsureImageResource | PrepareAppdataResource | PrepareControlNetworkResource,
    Field(discriminator='kind'),
]


class ResourcePreparationPlan(FrozenModel):
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
    resources: tuple[ResourceProposal, ...] = Field(min_length=13, max_length=13)

    @model_validator(mode='after')
    def bounded_disabled_resources(self):
        if self.installAvailable:
            raise ValueError('resource_execution_unavailable')
        identities = [resource.resourceId for resource in self.resources]
        for index, service in enumerate(_ORDER):
            image, appdata = self.resources[index * 2:index * 2 + 2]
            if not isinstance(image, EnsureImageResource) or not isinstance(appdata, PrepareAppdataResource):
                raise ValueError('invalid_resource_order')
            if (image.serviceId != service or appdata.serviceId != service
                    or image.installationId != appdata.installationId
                    or image.operationId != appdata.operationId or image.childPlanHash != appdata.childPlanHash
                    or image.image.platform != self.platform):
                raise ValueError('invalid_resource_binding')
            expected = '/'.join(('larenor-managed-v1', self.coreId, self.homeId,
                                 appdata.installationId, appdata.resourceId))
            if appdata.relativePath != expected:
                raise ValueError('invalid_appdata_proposal')
            identities.extend((image.installationId, image.operationId))
        network = self.resources[-1]
        if not isinstance(network, PrepareControlNetworkResource):
            raise ValueError('invalid_resource_order')
        identities.append(network.operationId)
        if len(identities) != len(set(identities)):
            raise ValueError('duplicate_resource_identity')
        return self
