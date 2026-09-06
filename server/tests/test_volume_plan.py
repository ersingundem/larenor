"""Alternative storage proposals neither change old plans nor grant effects."""
import json
import os
import socket
import subprocess

import pytest

from larenor_server.context import ContextResponse
from larenor_server.plugins.catalog import load_catalog
from larenor_server.plugins.resource_models import WorkerPolicyBinding
from larenor_server.plugins.resource_plan import build_resource_plan
from larenor_server.plugins.stack_plan import build_media_stack_plan
from larenor_server.plugins.volume_plan import (
    VolumePlanError, build_volume_plan, verify_volume_plan,
)


@pytest.fixture
def source():
    catalog = load_catalog()
    policy = WorkerPolicyBinding(schemaVersion=1, workerPolicyVersion=3,
                                 workerPolicyDigest='d' * 64)
    stack = build_media_stack_plan(catalog, {}, 'linux/amd64',
        ContextResponse(schemaVersion=1, coreId='a' * 32, homeId='b' * 32), 'c' * 32)
    return stack, catalog, policy


@pytest.mark.parametrize('platform', ['linux/amd64', 'linux/arm64'])
def test_seven_targets_have_separate_managed_names_without_claiming_write_access(source, platform):
    original, catalog, policy = source
    stack = build_media_stack_plan(catalog, {}, platform,
        ContextResponse(schemaVersion=1, coreId=original.coreId, homeId=original.homeId),
        original.preparationId)
    plan = build_volume_plan(stack, catalog, policy)
    assert plan.schemaVersion == 1 and plan.platform == platform
    assert plan.installAvailable is False
    assert plan.bindingStatus == 'proposed'
    assert plan.planHash != build_resource_plan(stack, catalog, policy).planHash
    assert len(plan.resources) == len({r.name for r in plan.resources}) == 7
    assert len({r.resourceId for r in plan.resources}) == 7
    actual = {(r.serviceId, r.target, r.containerUser) for r in plan.resources}
    expected = {(c.serviceId, m.target, c.plan.security.user)
                for c in stack.components for m in c.plan.mounts if m.kind == 'managed_appdata'}
    assert actual == expected
    for resource in plan.resources:
        assert resource.name.startswith('larenor-appdata-v1-')
        assert '/' not in resource.name
        assert resource.driver == resource.scope == 'local'
        assert resource.readOnly is False and resource.noCopy is True
        assert resource.readiness == 'requires_bootstrap_validation'
        assert not {'DriverOpts', 'hostPath', 'Mountpoint', 'permissions', 'lease'} & set(resource.model_dump())
    assert verify_volume_plan(plan, stack, catalog, policy) == plan


def test_no_host_effect_no_native_plan_change_and_no_library_conversion(source, monkeypatch):
    stack, catalog, policy = source
    before = stack.model_dump_json()
    native = build_resource_plan(*source).model_dump_json()
    def forbidden(*args, **kwargs):
        pytest.fail('proposal touched host or transport')
    for owner, name in [(socket, 'socket'), (subprocess, 'Popen'), (os, 'open'), (os, 'mkdir'), (os, 'chown')]:
        monkeypatch.setattr(owner, name, forbidden)
    plan = build_volume_plan(*source)
    assert verify_volume_plan(plan, *source) == plan
    assert stack.model_dump_json() == before
    assert build_resource_plan(*source).model_dump_json() == native
    assert stack.components[-1].plan.network.mode == 'host'
    assert all(r.requestedRootId == 'appdata' for r in plan.resources)
    assert not any(r.target in {'/media', '/music', '/downloads'} for r in plan.resources)


@pytest.mark.parametrize('field', ['core', 'home', 'preparation'])
def test_context_change_never_reuses_volume_names(source, field):
    stack, catalog, policy = source
    context = ContextResponse(schemaVersion=1,
        coreId='e' * 32 if field == 'core' else stack.coreId,
        homeId='e' * 32 if field == 'home' else stack.homeId)
    changed = build_media_stack_plan(catalog, {}, stack.platform, context,
        'e' * 32 if field == 'preparation' else stack.preparationId)
    first, second = build_volume_plan(*source), build_volume_plan(changed, catalog, policy)
    assert {r.name for r in first.resources}.isdisjoint(r.name for r in second.resources)
    with pytest.raises(VolumePlanError):
        verify_volume_plan(first, changed, catalog, policy)


def test_changed_policy_rebinds_plan_without_silently_renaming_existing_proposals(source):
    stack, catalog, policy = source
    first = build_volume_plan(*source)
    changed = policy.model_copy(update={'workerPolicyDigest': 'e' * 64})
    second = build_volume_plan(stack, catalog, changed)
    assert [r.name for r in first.resources] == [r.name for r in second.resources]
    assert first.planHash != second.planHash
    with pytest.raises(VolumePlanError):
        verify_volume_plan(first, stack, catalog, changed)


@pytest.mark.parametrize('field,value', [
    ('installAvailable', True), ('schemaVersion', True), ('planHash', 'e' * 64),
    ('workerPolicyVersion', True), ('resources', ()), ('hidden', 'synthetic-private'),
])
def test_forged_plan_never_becomes_an_accepted_volume_proposal(source, field, value):
    plan = build_volume_plan(*source)
    changed = plan.model_copy(update={field: value})
    with pytest.raises(VolumePlanError, match='^volume_plan_untrusted$'):
        verify_volume_plan(changed, *source)


@pytest.mark.parametrize('field,value', [
    ('driver', 'nfs'), ('scope', 'global'), ('noCopy', False), ('readOnly', True),
    ('name', '/private/host'), ('target', '/'), ('containerUser', '0:0'),
    ('DriverOpts', {'type': 'none', 'o': 'bind', 'device': '/'}),
])
def test_forged_nested_storage_options_are_rejected_even_if_parent_is_valid(source, field, value):
    plan = build_volume_plan(*source)
    first = plan.resources[0].model_copy(update={field: value})
    changed = plan.model_copy(update={'resources': (first, *plan.resources[1:])})
    with pytest.raises(VolumePlanError, match='^volume_plan_untrusted$'):
        verify_volume_plan(changed, *source)


@pytest.mark.parametrize('index,field,value', [
    (0, 'coreId', 'e' * 32), (0, 'planHash', 'e' * 64),
    (1, 'digest', 'e' * 64), (2, 'workerPolicyVersion', True),
    (2, 'workerPolicyDigest', 'synthetic-private'),
])
def test_source_corruption_is_redacted_and_cannot_be_reinterpreted(source, index, field, value):
    changed = list(source)
    changed[index] = changed[index].model_copy(update={field: value})
    with pytest.raises(VolumePlanError) as caught:
        build_volume_plan(*changed)
    assert str(caught.value) == 'volume_inputs_untrusted'
    assert 'synthetic-private' not in str(caught.value)


def test_names_and_policy_identity_are_not_an_execution_receipt(source):
    plan = build_volume_plan(*source)
    raw = json.loads(plan.model_dump_json())
    assert not {'ownershipNonce', 'journalId', 'ready', 'grants', 'created'} & raw.keys()
    assert raw['installAvailable'] is False
    assert all(r['readiness'] == 'requires_bootstrap_validation' for r in raw['resources'])


def test_changed_requested_storage_does_not_silently_adopt_old_plan(source):
    stack, catalog, policy = source
    original = build_volume_plan(*source)
    changed = build_media_stack_plan(catalog,
        {'instanceName': 'changed', 'dataRootId': 'private_appdata'}, stack.platform,
        ContextResponse(schemaVersion=1, coreId=stack.coreId, homeId=stack.homeId), stack.preparationId)
    alternate = build_volume_plan(changed, catalog, policy)
    assert [r.name for r in original.resources] == [r.name for r in alternate.resources]
    assert original.stackPlanHash != alternate.stackPlanHash
    assert original.planHash != alternate.planHash
    for before, after in zip(original.resources, alternate.resources):
        assert after.requestedRootId == 'private_appdata'
        assert before.requestedRelativePath != after.requestedRelativePath
        assert before.childPlanHash != after.childPlanHash
    with pytest.raises(VolumePlanError, match='^volume_plan_untrusted$'):
        verify_volume_plan(original, changed, catalog, policy)


@pytest.mark.parametrize('index', [0, 1, 2])
def test_untyped_source_is_not_a_valid_input(source, index):
    changed = list(source)
    changed[index] = changed[index].model_dump()
    with pytest.raises(VolumePlanError, match='^volume_inputs_untrusted$'):
        build_volume_plan(*changed)


def test_native_plan_and_plain_wire_are_not_volume_models(source):
    for candidate in [build_resource_plan(*source), build_volume_plan(*source).model_dump(), None]:
        with pytest.raises(VolumePlanError, match='^volume_plan_untrusted$'):
            verify_volume_plan(candidate, *source)
