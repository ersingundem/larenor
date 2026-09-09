"""One managed library volume has fixed media-service consumer mappings."""

import hashlib
import json
import os
import socket
import subprocess

import pytest

from larenor_server.context import ContextResponse
from larenor_server.plugins.catalog import load_catalog
from larenor_server.plugins.resource_models import WorkerPolicyBinding
from larenor_server.plugins.shared_library_consumers import (
    SharedLibraryConsumerPlanError,
    build_shared_library_consumer_plan,
    verify_shared_library_consumer_plan,
)
from larenor_server.plugins.stack_plan import build_media_stack_plan
from larenor_server.plugins.volume_plan import build_volume_plan


def source(platform='linux/amd64'):
    catalog = load_catalog()
    stack = build_media_stack_plan(
        catalog, {}, platform,
        ContextResponse(
            schemaVersion=1, coreId='a' * 32, homeId='b' * 32),
        'c' * 32,
    )
    policy = WorkerPolicyBinding(
        schemaVersion=1, workerPolicyVersion=3,
        workerPolicyDigest='d' * 64,
    )
    volumes = build_volume_plan(stack, catalog, policy)
    return volumes, stack, catalog, policy


@pytest.mark.parametrize('platform', ['linux/amd64', 'linux/arm64'])
def test_fixed_consumers_share_one_volume_with_service_specific_access(platform):
    values = source(platform)

    result = build_shared_library_consumer_plan(*values)

    owner = next(
        item for item in values[0].resources if item.kind == 'managed_library')
    assert result.schemaVersion == 1
    assert result.installAvailable is False
    assert result.bindingStatus == 'proposed'
    assert result.resourceId == owner.resourceId
    assert result.operationId == owner.operationId
    assert result.name == owner.name
    assert result.requestedRootId == owner.requestedRootId == 'library'
    assert [(item.serviceId, item.target, item.readOnly) for item in result.consumers] == [
        ('qbittorrent', '/data', False),
        ('sonarr', '/data', False),
        ('radarr', '/data', False),
        ('jellyfin', '/media', True),
    ]
    assert all(item.containerUser == '1000:1000' for item in result.consumers)
    assert len({item.installationId for item in result.consumers}) == 4
    assert verify_shared_library_consumer_plan(result, *values) == result
    payload = result.model_dump(mode='json', exclude={'planHash'})
    assert result.planHash == hashlib.sha256(json.dumps(
        payload, sort_keys=True, separators=(',', ':'),
        ensure_ascii=False, allow_nan=False).encode()).hexdigest()


def test_seerr_and_music_assistant_receive_no_media_library_mount():
    values = source()
    result = build_shared_library_consumer_plan(*values)
    assert {item.serviceId for item in result.consumers} == {
        'qbittorrent', 'sonarr', 'radarr', 'jellyfin'}
    assert not {'seerr', 'music_assistant'} & {
        item.serviceId for item in result.consumers}


@pytest.mark.parametrize('field,value', [
    ('installAvailable', True),
    ('bindingStatus', 'verified'),
    ('resourceId', '9' * 32),
    ('operationId', '9' * 32),
    ('name', 'larenor-library-v1-' + '9' * 32),
    ('requestedRootId', 'private'),
    ('planHash', '9' * 64),
    ('consumers', ()),
    ('hidden', 'private'),
])
def test_parent_plan_drift_is_rejected(field, value):
    values = source()
    plan = build_shared_library_consumer_plan(*values)
    changed = plan.model_copy(update={field: value})
    with pytest.raises(
        SharedLibraryConsumerPlanError,
        match='^shared_library_consumer_plan_untrusted$',
    ):
        verify_shared_library_consumer_plan(changed, *values)


@pytest.mark.parametrize('field,value', [
    ('serviceId', 'seerr'),
    ('installationId', '9' * 32),
    ('childPlanHash', '9' * 64),
    ('target', '/foreign'),
    ('readOnly', True),
    ('containerUser', '0:0'),
    ('hidden', 'private'),
])
def test_nested_consumer_drift_is_rejected(field, value):
    values = source()
    plan = build_shared_library_consumer_plan(*values)
    first = plan.consumers[0].model_copy(update={field: value})
    changed = plan.model_copy(update={
        'consumers': (first, *plan.consumers[1:]),
    })
    with pytest.raises(
        SharedLibraryConsumerPlanError,
        match='^shared_library_consumer_plan_untrusted$',
    ):
        verify_shared_library_consumer_plan(changed, *values)


def test_source_change_cannot_reuse_an_old_consumer_plan():
    values = source()
    plan = build_shared_library_consumer_plan(*values)
    volumes, stack, catalog, policy = values
    changed_stack = build_media_stack_plan(
        catalog, {'libraryRootId': 'other'}, stack.platform,
        ContextResponse(
            schemaVersion=1, coreId=stack.coreId, homeId=stack.homeId),
        stack.preparationId,
    )
    changed_volumes = build_volume_plan(changed_stack, catalog, policy)
    with pytest.raises(
        SharedLibraryConsumerPlanError,
        match='^shared_library_consumer_plan_untrusted$',
    ):
        verify_shared_library_consumer_plan(
            plan, changed_volumes, changed_stack, catalog, policy)


def test_planner_has_no_host_effect(monkeypatch):
    values = source()
    def forbidden(*_args, **_kwargs):
        pytest.fail('consumer planning attempted a host effect')
    for owner, name in [
        (os, 'open'), (socket, 'socket'), (subprocess, 'Popen'),
    ]:
        monkeypatch.setattr(owner, name, forbidden)
    assert build_shared_library_consumer_plan(*values).installAvailable is False
