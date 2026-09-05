"""Resource proposals are pure, context-bound and cannot authorize effects."""

import builtins
import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess

import pytest
from pydantic import ValidationError

from larenor_server.context import ContextResponse
from larenor_server.plugins.catalog import load_catalog
from larenor_server.plugins.resource_models import WorkerPolicyBinding, ResourcePreparationPlan
from larenor_server.plugins.resource_plan import ResourcePlanError, build_resource_plan, verify_resource_plan
from larenor_server.plugins.stack_plan import build_media_stack_plan


CONTEXT = ContextResponse(schemaVersion=1, coreId='a' * 32, homeId='b' * 32)
PREPARATION = 'c' * 32


@pytest.fixture
def catalog():
    return load_catalog()


@pytest.fixture
def policy():
    return WorkerPolicyBinding(schemaVersion=1, workerPolicyVersion=3, workerPolicyDigest='d' * 64)


def stack(catalog, *, settings=None, platform='linux/amd64', context=CONTEXT, preparation=PREPARATION):
    return build_media_stack_plan(catalog, settings or {}, platform, context, preparation)


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':'),
                                     ensure_ascii=False, allow_nan=False).encode()).hexdigest()


def ids(value):
    return tuple(resource.resourceId for resource in value.resources)


@pytest.mark.parametrize('platform', ['linux/amd64', 'linux/arm64'])
def test_exact_thirteen_resources_rederive_from_catalog_stack_and_policy(catalog, policy, platform):
    selected = stack(catalog, platform=platform)
    value = build_resource_plan(selected, catalog, policy)
    assert (value.schemaVersion, value.coreId, value.homeId, value.preparationId) == (1, CONTEXT.coreId, CONTEXT.homeId, PREPARATION)
    assert (value.catalogDigest, value.stackPlanHash, value.platform) == (catalog.digest, selected.planHash, platform)
    assert (value.workerPolicyVersion, value.workerPolicyDigest) == (3, 'd' * 64)
    assert value.bindingStatus == 'proposed' and value.installAvailable is False
    assert len(value.resources) == len(set(ids(value))) == 13
    for index, component in enumerate(selected.components):
        image, appdata = value.resources[index * 2:index * 2 + 2]
        assert image.kind == 'ensure_image' and appdata.kind == 'prepare_appdata'
        for resource in (image, appdata):
            assert (resource.serviceId, resource.installationId, resource.operationId, resource.childPlanHash) == (
                component.serviceId, component.installationId, component.operationId, component.plan.planHash)
        entry = next(entry for entry in catalog.entries if entry.manifest.serviceId == component.serviceId)
        pinned = next(image for image in entry.manifest.images if image.platform == platform)
        assert image.manifestDigest == entry.manifestDigest
        assert (image.image.digest, image.image.configDigest, image.image.indexDigest) == (
            pinned.digest, pinned.configDigest, entry.manifest.indexDigest)
        assert image.image.reference == image.image.repository + '@' + pinned.digest
        assert image.image.platform == platform and image.ownership == 'shared_cache'
    assert verify_resource_plan(value, selected, catalog, policy) == value
    assert ResourcePreparationPlan.model_validate_json(value.model_dump_json()) == value
    assert value.planHash == digest(value.model_dump(mode='json', exclude={'planHash'}))


def test_appdata_explicitly_pairs_old_request_with_owned_proposal_without_mutating_stack(catalog, policy):
    selected = stack(catalog, settings={'instanceName': 'family', 'dataRootId': 'private_data',
                                        'libraryRootId': 'movies', 'musicRootId': 'songs'})
    before = selected.model_dump_json()
    value = build_resource_plan(selected, catalog, policy)
    for index, component in enumerate(selected.components):
        appdata = value.resources[index * 2 + 1]
        expected_mounts = [mount for mount in component.plan.mounts if mount.kind == 'managed_appdata']
        assert appdata.mapping == 'proposed_owned_appdata_v1'
        assert appdata.ownership == 'requires_verified_id_mapping' and appdata.rootId == 'private_data'
        assert appdata.relativePath == '/'.join(('larenor-managed-v1', CONTEXT.coreId, CONTEXT.homeId,
                                               component.installationId, appdata.resourceId))
        assert len(appdata.mounts) == len(expected_mounts)
        for proposed, original in zip(appdata.mounts, expected_mounts):
            assert (proposed.requestedRelativePath, proposed.target, proposed.readOnly) == (
                original.relativePath, original.target, False)
            assert proposed.proposedRelativePath == appdata.relativePath + '/' + original.relativePath.rsplit('/', 1)[1]
            assert proposed.proposedRelativePath != original.relativePath
        assert not appdata.relativePath.startswith('/') and 'family' not in appdata.relativePath
    assert not any(getattr(resource, 'rootId', '') in ('movies', 'songs') for resource in value.resources)
    assert selected.model_dump_json() == before
    assert selected.components[-1].plan.network.mode == 'host'
    assert all(port.hostIp == '0.0.0.0' for c in selected.components for port in c.plan.ports)
    assert value.installAvailable is False


def test_stack_control_network_is_fixed_private_unattached_proposal(catalog, policy):
    value = build_resource_plan(stack(catalog), catalog, policy)
    network = value.resources[-1]
    assert network.model_dump() == {
        'kind': 'prepare_control_network', 'resourceId': network.resourceId,
        'operationId': network.operationId, 'name': 'larenor-control-' + network.resourceId,
        'driver': 'bridge', 'scope': 'local', 'internal': True,
        'attachable': False, 'ingress': False, 'configOnly': False}
    assert network.operationId not in {r.operationId for r in value.resources[:-1]}
    assert not {'containers', 'ports', 'Options', 'IPAM', 'ConfigFrom', 'labels', 'hostPath'} & set(network.model_dump())


def test_hash_is_order_canonical_and_ids_are_independent_of_display_and_policy(catalog, policy):
    selected = stack(catalog)
    value = build_resource_plan(selected, catalog, policy)
    assert build_resource_plan(selected, catalog.model_copy(update={'entries': tuple(reversed(catalog.entries))}), policy) == value
    assert ids(build_resource_plan(stack(catalog, settings={'instanceName': 'different'}, platform='linux/arm64'), catalog, policy)) == ids(value)
    changed = policy.model_copy(update={'workerPolicyDigest': 'e' * 64})
    other = build_resource_plan(selected, catalog, changed)
    assert ids(other) == ids(value) and other.planHash != value.planHash
    with pytest.raises(ResourcePlanError, match='^resource_plan_untrusted$'):
        verify_resource_plan(value, selected, catalog, changed)
    assert build_resource_plan(selected, catalog, policy.model_copy(update={'workerPolicyVersion': 4})).planHash != value.planHash
    previous_ids = {identity for component in selected.components for identity in (
        component.installationId, component.operationId, *(step.stepId for step in component.steps))}
    assert not previous_ids & set(ids(value))
    assert value.resources[-1].operationId not in previous_ids | set(ids(value))


@pytest.mark.parametrize('field', ['coreId', 'homeId', 'preparationId'])
def test_current_context_or_preparation_change_rejects_old_plan(catalog, policy, field):
    selected = stack(catalog)
    old = build_resource_plan(selected, catalog, policy)
    context = CONTEXT.model_copy(update={field: 'e' * 32}) if field != 'preparationId' else CONTEXT
    other = stack(catalog, context=context, preparation='e' * 32 if field == 'preparationId' else PREPARATION)
    assert not set(ids(old)) & set(ids(build_resource_plan(other, catalog, policy)))
    with pytest.raises(ResourcePlanError, match='^resource_plan_untrusted$'):
        verify_resource_plan(old, other, catalog, policy)


@pytest.mark.parametrize('field,value', [('schemaVersion', True), ('schemaVersion', 1.0),
                                       ('workerPolicyVersion', True), ('workerPolicyVersion', '3'),
                                       ('workerPolicyVersion', 0), ('workerPolicyVersion', 2**31),
                                       ('workerPolicyDigest', '/private/root'),
                                       ('workerPolicyDigest', 'x' * 64),
                                       ('socketPath', '/run/docker.sock'), ('secret', 'token'),
                                       ('Options', {}), ('roots', {'appdata': '/private/root'})])
def test_policy_binding_is_strict_opaque_and_not_a_host_configuration(field, value):
    wire = dict(schemaVersion=1, workerPolicyVersion=3, workerPolicyDigest='d' * 64)
    wire[field] = value
    with pytest.raises(ValidationError):
        WorkerPolicyBinding.model_validate(wire)


@pytest.mark.parametrize('field,value', [('schemaVersion', True), ('installAvailable', True),
                                       ('installAvailable', 0), ('bindingStatus', 'ready'),
                                       ('workerPolicyVersion', '3'), ('workerPolicyVersion', True),
                                       ('hostPath', '/private/root'), ('token', 'sensitive'),
                                       ('dockerOptions', {'Privileged': True})])
def test_resource_plan_schema_rejects_noncanonical_values_and_extra_options(catalog, policy, field, value):
    wire = build_resource_plan(stack(catalog), catalog, policy).model_dump(mode='json')
    wire[field] = value
    with pytest.raises(ValidationError):
        ResourcePreparationPlan.model_validate_json(json.dumps(wire))


@pytest.mark.parametrize('resource_index,field,value', [(0, 'repository', 'evil.invalid/thing'),
                                                       (1, 'relativePath', '/private/root'),
                                                       (1, 'relativePath', '../escape'),
                                                       (1, 'uid', 0), (1, 'mountOptions', ['rw']),
                                                       (12, 'internal', False), (12, 'internal', 1),
                                                       (12, 'attachable', True), (12, 'driver', 'overlay'),
                                                       (12, 'Options', {}), (12, 'IPAM', {})])
def test_nested_resource_options_cannot_escape_static_effect_schema(catalog, policy, resource_index, field, value):
    wire = build_resource_plan(stack(catalog), catalog, policy).model_dump(mode='json')
    wire['resources'][resource_index][field] = value
    with pytest.raises(ValidationError):
        ResourcePreparationPlan.model_validate_json(json.dumps(wire))


@pytest.mark.parametrize('kind', ['plan_hash', 'stack_hash', 'policy_digest', 'resource_id',
                                 'child_operation', 'config_digest', 'image_digest', 'mount_target',
                                 'catalog_digest', 'extra_hidden', 'nested_hidden', 'wrong_bool'])
def test_copy_construct_and_rehashed_forgery_never_verify(catalog, policy, kind):
    selected = stack(catalog)
    value = build_resource_plan(selected, catalog, policy)
    resources = list(value.resources)
    if kind == 'resource_id':
        resources[0] = resources[0].model_copy(update={'resourceId': 'f' * 32})
        changed = value.model_copy(update={'resources': tuple(resources)})
    elif kind == 'child_operation':
        resources[0] = resources[0].model_copy(update={'operationId': 'f' * 32})
        changed = value.model_copy(update={'resources': tuple(resources)})
    elif kind in ('config_digest', 'image_digest'):
        image = resources[0].image.model_copy(update={
            'configDigest' if kind == 'config_digest' else 'digest': 'sha256:' + 'f' * 64})
        resources[0] = resources[0].model_copy(update={'image': image})
        changed = value.model_copy(update={'resources': tuple(resources)})
    elif kind == 'mount_target':
        mounts = tuple(m.model_copy(update={'target': '/host'}) for m in resources[1].mounts)
        resources[1] = resources[1].model_copy(update={'mounts': mounts})
        changed = value.model_copy(update={'resources': tuple(resources)})
    elif kind == 'nested_hidden':
        resources[0] = resources[0].model_copy(update={'token': 'never_echo'})
        changed = value.model_copy(update={'resources': tuple(resources)})
    else:
        field, replacement = {'plan_hash': ('planHash', 'f'*64), 'stack_hash': ('stackPlanHash', 'f'*64),
            'policy_digest': ('workerPolicyDigest', 'f'*64), 'catalog_digest': ('catalogDigest', 'f'*64),
            'extra_hidden': ('secret', 'never_echo'), 'wrong_bool': ('installAvailable', 0)}[kind]
        changed = value.model_copy(update={field: replacement})
    # Even a caller recomputing its self-consistent hash cannot authorize drift.
    if kind not in ('plan_hash', 'extra_hidden', 'nested_hidden'):
        changed = changed.model_copy(update={'planHash': digest(changed.model_dump(mode='json', exclude={'planHash'}, warnings=False))})
    with pytest.raises(ResourcePlanError, match='^resource_plan_untrusted$'):
        verify_resource_plan(changed, selected, catalog, policy)


def test_forged_catalog_stack_and_policy_are_revalidated_before_build(catalog, policy):
    selected = stack(catalog)
    cases = [(selected, catalog.model_copy(update={'digest': 'e' * 64}), policy),
             (selected.model_copy(update={'installAvailable': True}), catalog, policy),
             (selected.model_copy(update={'secret': 'never_echo'}), catalog, policy),
             (selected, catalog, policy.model_copy(update={'workerPolicyVersion': True})),
             (selected, catalog, policy.model_copy(update={'hostPath': '/private/root'})),
             (selected.model_dump(), catalog, policy), (selected, catalog, policy.model_dump())]
    for current_stack, current_catalog, current_policy in cases:
        with pytest.raises(ResourcePlanError, match='^resource_inputs_untrusted$'):
            build_resource_plan(current_stack, current_catalog, current_policy)


def test_models_are_immutable_and_returned_wire_is_detached(catalog, policy):
    value = build_resource_plan(stack(catalog), catalog, policy)
    for model, field, replacement in [(value, 'planHash', 'e'*64), (policy, 'workerPolicyVersion', 4),
                                      (value.resources[0].image, 'configDigest', 'sha256:'+'e'*64),
                                      (value.resources[1].mounts[0], 'target', '/other')]:
        with pytest.raises(ValidationError):
            setattr(model, field, replacement)
    wire = value.model_dump(mode='json')
    wire['resources'].clear()
    assert len(value.resources) == 13


@pytest.mark.parametrize('case', ['readonly_appdata', 'mount_mapping', 'duplicate_mount', 'owned_root',
                                'resource_order', 'missing_resource', 'duplicate_identity', 'wrong_final_kind'])
def test_resource_structure_cannot_claim_ambiguous_or_unbound_effects(catalog, policy, case):
    wire = build_resource_plan(stack(catalog), catalog, policy).model_dump(mode='json')
    if case == 'readonly_appdata':
        wire['resources'][1]['mounts'][0]['readOnly'] = True
    elif case == 'mount_mapping':
        wire['resources'][1]['mounts'][0]['proposedRelativePath'] += 'x'
    elif case == 'duplicate_mount':
        wire['resources'][1]['mounts'] *= 2
    elif case == 'owned_root':
        wire['resources'][1]['relativePath'] = wire['resources'][1]['relativePath'].replace('a'*32, 'e'*32)
        wire['resources'][1]['mounts'][0]['proposedRelativePath'] = wire['resources'][1]['relativePath'] + '/config'
    elif case == 'resource_order':
        wire['resources'][0], wire['resources'][1] = wire['resources'][1], wire['resources'][0]
    elif case == 'missing_resource':
        wire['resources'].pop()
    elif case == 'duplicate_identity':
        wire['resources'][0]['resourceId'] = wire['resources'][2]['resourceId']
    else:
        wire['resources'][-1] = wire['resources'][0]
    with pytest.raises(ValidationError):
        ResourcePreparationPlan.model_validate_json(json.dumps(wire))


def test_forged_catalog_image_configuration_pin_cannot_supply_an_image_id(catalog, policy):
    entry = catalog.entries[0]
    manifest = entry.manifest.model_copy(update={'images': tuple(
        image.model_copy(update={'configDigest': 'sha256:' + 'f'*64}) for image in entry.manifest.images)})
    forged = catalog.model_copy(update={'entries': (entry.model_copy(update={'manifest': manifest}), *catalog.entries[1:])})
    with pytest.raises(ResourcePlanError, match='^resource_inputs_untrusted$'):
        build_resource_plan(stack(catalog), forged, policy)


@pytest.mark.parametrize('case', ['wrong_plan_type', 'missing_constructed_field', 'unknown_scalar'])
def test_constructed_objects_are_not_a_trust_boundary(catalog, policy, case):
    selected = stack(catalog)
    value = build_resource_plan(selected, catalog, policy)
    if case == 'wrong_plan_type':
        changed = value.model_dump()
    elif case == 'missing_constructed_field':
        changed = ResourcePreparationPlan.model_construct(**{
            name: field for name, field in value.__dict__.items() if name != 'planHash'})
    else:
        changed = value.model_copy(update={'workerPolicyDigest': object()})
    with pytest.raises(ResourcePlanError, match='^resource_plan_untrusted$'):
        verify_resource_plan(changed, selected, catalog, policy)


def test_pure_build_and_verify_do_not_read_write_network_spawn_or_load_catalog(catalog, policy, monkeypatch):
    selected = stack(catalog)
    def forbidden(*args, **kwargs):
        raise AssertionError('resource planning must have zero IO')
    for owner, name in ((builtins, 'open'), (Path, 'open'), (os, 'open'), (os, 'stat'),
                        (socket, 'socket'), (subprocess, 'run'), (subprocess, 'Popen')):
        monkeypatch.setattr(owner, name, forbidden)
    value = build_resource_plan(selected, catalog, policy)
    assert verify_resource_plan(value, selected, catalog, policy) == value
