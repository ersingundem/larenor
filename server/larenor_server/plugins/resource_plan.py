"""Pure proposals bound to current stack/catalog/policy inputs, never grants.

IDs use a new domain without rewriting MediaStackPlan v1 IDs or requested paths.
The explicit requested/proposed appdata pairing describes a future mapping; it
does not migrate directories, resolve host paths, verify UID mapping or enable
container effects. Current actor, preparation state and actual policy approval
must be checked by a separate authorized dispatcher before any future effect.
"""

import hashlib

from pydantic import BaseModel

from .models import Catalog
from .resource_models import (
    AppdataMountProposal, EnsureImageResource, PrepareAppdataResource,
    PrepareControlNetworkResource, ResourceImage, ResourcePreparationPlan,
    WorkerPolicyBinding,
)
from .stack_plan import MediaStackPlan, _canonical, verify_media_stack_plan


class ResourcePlanError(ValueError):
    """Static codes only, with no supplied paths/options in public diagnostics."""


def _wire(value):
    # Pydantic's serializer can normalize invalid model_copy values (an int
    # field containing True becomes 1). Validate raw field values first, while
    # also rejecting hidden extras that model_dump would silently discard.
    def raw(item, depth=0):
        if depth > 16:
            raise ValueError()
        if isinstance(item, BaseModel):
            if set(item.__dict__) != set(type(item).model_fields) or item.__pydantic_extra__:
                raise ValueError()
            return {key: raw(field, depth + 1) for key, field in item.__dict__.items()}
        if type(item) is dict:
            if any(type(key) is not str for key in item):
                raise ValueError()
            return {key: raw(field, depth + 1) for key, field in item.items()}
        if type(item) in (tuple, list):
            return [raw(field, depth + 1) for field in item]
        if item is None or type(item) in (str, int, bool, float):
            return item
        raise ValueError()
    return _canonical(raw(value))


def _identity(kind, stack, service=''):
    fields = ('larenor-resource-preparation-v1', kind, stack.coreId, stack.homeId,
              stack.preparationId, service)
    return hashlib.sha256('\0'.join(fields).encode('ascii')).hexdigest()[:32]


def build_resource_plan(stack, catalog, policybinding) -> ResourcePreparationPlan:
    """Revalidate supplied immutable inputs and calculate exactly 13 proposals.

    No catalog file, host, credential, daemon or random source is consulted.
    Policy version/digest equality identifies a policy; it never approves one.
    """
    try:
        if (type(stack) is not MediaStackPlan or type(catalog) is not Catalog
                or type(policybinding) is not WorkerPolicyBinding):
            raise ValueError()
        trusted = Catalog.model_validate_json(_wire(catalog))
        policy = WorkerPolicyBinding.model_validate_json(_wire(policybinding))
        original = MediaStackPlan.model_validate_json(_wire(stack))
        selected = verify_media_stack_plan(original, trusted)
        entries = {entry.manifest.serviceId: entry for entry in trusted.entries}
        resources = []
        for component in selected.components:
            child = component.plan
            entry = entries[component.serviceId]
            pinned = next(image for image in entry.manifest.images if image.platform == selected.platform)
            common = dict(operationId=component.operationId, serviceId=component.serviceId,
                          installationId=component.installationId, childPlanHash=child.planHash)
            resources.append(EnsureImageResource(kind='ensure_image',
                resourceId=_identity('ensure_image', selected, component.serviceId), **common,
                manifestDigest=entry.manifestDigest, ownership='shared_cache',
                image=ResourceImage(repository=child.image.repository, platform=selected.platform,
                    digest=pinned.digest, configDigest=pinned.configDigest, indexDigest=child.image.indexDigest,
                    reference=child.image.repository + '@' + pinned.digest)))
            identity = _identity('prepare_appdata', selected, component.serviceId)
            relative = '/'.join(('larenor-managed-v1', selected.coreId, selected.homeId,
                                 component.installationId, identity))
            mounts = [mount for mount in child.mounts if mount.kind == 'managed_appdata']
            if not mounts or len({mount.rootId for mount in mounts}) != 1:
                raise ValueError()
            resources.append(PrepareAppdataResource(kind='prepare_appdata', resourceId=identity,
                **common, rootId=mounts[0].rootId, mapping='proposed_owned_appdata_v1',
                relativePath=relative, ownership='requires_verified_id_mapping',
                mounts=tuple(AppdataMountProposal(requestedRelativePath=mount.relativePath,
                    proposedRelativePath=relative + '/' + mount.relativePath.rsplit('/', 1)[1],
                    target=mount.target, readOnly=False) for mount in mounts)))
        network_id = _identity('prepare_control_network', selected)
        resources.append(PrepareControlNetworkResource(kind='prepare_control_network', resourceId=network_id,
            operationId=_identity('operation', selected, 'control_network'),
            name='larenor-control-' + network_id, driver='bridge', scope='local', internal=True,
            attachable=False, ingress=False, configOnly=False))
        result = ResourcePreparationPlan(schemaVersion=1, coreId=selected.coreId, homeId=selected.homeId,
            preparationId=selected.preparationId, platform=selected.platform, catalogDigest=trusted.digest,
            stackPlanHash=selected.planHash, workerPolicyVersion=policy.workerPolicyVersion,
            workerPolicyDigest=policy.workerPolicyDigest, planHash='0' * 64,
            installAvailable=False, bindingStatus='proposed', resources=tuple(resources))
        return result.model_copy(update={'planHash': hashlib.sha256(
            _canonical(result.model_dump(mode='json', exclude={'planHash'}))).hexdigest()})
    except (ValueError, TypeError, AttributeError, KeyError, RecursionError, StopIteration):
        raise ResourcePlanError('resource_inputs_untrusted') from None


def verify_resource_plan(value, stack, catalog, policybinding) -> ResourcePreparationPlan:
    """Re-derive against current supplied context and policy, not saved authority."""
    try:
        if type(value) is not ResourcePreparationPlan:
            raise ValueError()
        validated = ResourcePreparationPlan.model_validate_json(_wire(value))
        expected = build_resource_plan(stack, catalog, policybinding)
        if expected != validated:
            raise ValueError()
        return expected
    except (ValueError, TypeError, AttributeError, RecursionError):
        raise ResourcePlanError('resource_plan_untrusted') from None
