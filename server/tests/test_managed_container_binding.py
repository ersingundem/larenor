"""Closed Jellyfin binding consumes only fresh typed resource proofs."""

from dataclasses import replace
import json

import pytest

from larenor_server.context import ContextResponse
from larenor_server.plugins.catalog import load_catalog
from larenor_server.plugins.managed_container import (
    JellyfinBindingBuilder,
    ManagedContainerError,
    ManagedImageProof,
    ManagedNetworkProof,
    ManagedVolumeProof,
    VerifiedJellyfinResources,
    managed_container_matches,
)
from larenor_server.plugins.resource_models import WorkerPolicyBinding
from larenor_server.plugins.stack_plan import build_media_stack_plan


def source():
    catalog = load_catalog()
    stack = build_media_stack_plan(catalog, {}, 'linux/amd64',
        ContextResponse(schemaVersion=1, coreId='a' * 32, homeId='b' * 32), 'c' * 32)
    policy = WorkerPolicyBinding(schemaVersion=1, workerPolicyVersion=3,
                                 workerPolicyDigest='d' * 64)
    return catalog, stack, policy


def proof(resource_plan, volume_plan, component):
    image = next(item for item in resource_plan.resources
                 if item.kind == 'ensure_image' and item.serviceId == 'jellyfin')
    network = resource_plan.resources[-1]
    volumes = tuple(item for item in volume_plan.resources if item.serviceId == 'jellyfin')
    return VerifiedJellyfinResources(
        stack_plan_hash=resource_plan.stackPlanHash,
        resource_plan_hash=resource_plan.planHash,
        volume_plan_hash=volume_plan.planHash,
        worker_policy_digest=resource_plan.workerPolicyDigest,
        image=ManagedImageProof(image.resourceId, 3, image.image.configDigest,
            json.dumps({'Env': ['PATH=/usr/bin'], 'Volumes': {'/config': {}, '/cache': {}}},
                       sort_keys=True, separators=(',', ':')).encode()),
        volumes=tuple(ManagedVolumeProof(
            item.resourceId, item.operationId, 4, 'e' * 32, 'f' * 32,
            item.name, item.target, True,
        ) for item in volumes),
        network=ManagedNetworkProof(
            network.resourceId, network.operationId, 3, '1' * 32, '2' * 32,
            network.name, '3' * 64,
        ),
    )


def build(provider=proof):
    catalog, stack, policy = source()
    builder = JellyfinBindingBuilder(catalog, policy, '4' * 32, provider)
    return builder, stack, builder(stack)


def test_builder_derives_ports_off_private_network_and_exact_nocopy_mounts():
    _builder, stack, binding = build()
    body = json.loads(binding.specification)
    jellyfin = next(item for item in stack.components if item.serviceId == 'jellyfin')
    assert binding.name == 'larenor-' + jellyfin.installationId
    assert body['Image'].endswith('@' + jellyfin.plan.image.digest)
    assert body['User'] == '1000:1000'
    assert body['HostConfig']['NetworkMode'].startswith('larenor-control-')
    assert 'PortBindings' not in body['HostConfig'] and 'ExposedPorts' not in body
    assert body['HostConfig']['Mounts'] == [
        {'Type': 'volume', 'Source': mount.name, 'Target': mount.target,
         'ReadOnly': False, 'VolumeOptions': {'NoCopy': True}}
        for mount in binding.mounts
    ]
    assert {mount.target for mount in binding.mounts} == {'/config', '/cache'}
    assert set(json.loads(binding.image_configuration)['Volumes']) == {'/config', '/cache'}
    assert 'ownership_nonce' not in repr(binding) and 'PATH=/usr/bin' not in repr(binding)


@pytest.mark.parametrize('damage', ['plan', 'image_revision', 'image_id', 'volume_name',
                                    'volume_revision', 'bootstrap', 'network_id', 'extra_volume'])
def test_stale_or_incomplete_resource_proof_never_builds_a_container(damage):
    def damaged(resources, volumes, component):
        value = proof(resources, volumes, component)
        if damage == 'plan':
            return replace(value, stack_plan_hash='9' * 64)
        if damage == 'image_revision':
            return replace(value, image=replace(value.image, revision=2))
        if damage == 'image_id':
            return replace(value, image=replace(value.image, image_id='sha256:' + '9' * 64))
        if damage == 'volume_name':
            return replace(value, volumes=(replace(value.volumes[0], name='foreign'), value.volumes[1]))
        if damage == 'volume_revision':
            return replace(value, volumes=(replace(value.volumes[0], revision=True), value.volumes[1]))
        if damage == 'bootstrap':
            return replace(value, volumes=(replace(value.volumes[0], bootstrap_verified=False), value.volumes[1]))
        if damage == 'network_id':
            return replace(value, network=replace(value.network, network_id='bad'))
        configuration = {'Env': [], 'Volumes': {'/config': {}, '/cache': {}, '/data': {}}}
        return replace(value, image=replace(value.image, image_configuration=json.dumps(
            configuration, sort_keys=True, separators=(',', ':')).encode()))

    catalog, stack, policy = source()
    builder = JellyfinBindingBuilder(catalog, policy, '4' * 32, damaged)
    with pytest.raises(ManagedContainerError, match='^resources_untrusted$'):
        builder(stack)


def test_provider_exception_and_forged_stack_are_static_and_leak_nothing():
    catalog, stack, policy = source()
    def fail(*_):
        raise RuntimeError('private socket and token')
    builder = JellyfinBindingBuilder(catalog, policy, '4' * 32, fail)
    with pytest.raises(ManagedContainerError, match='^resources_unavailable$') as caught:
        builder(stack)
    assert 'private' not in repr(caught.value)
    with pytest.raises(ManagedContainerError, match='^invalid_installation_plan$'):
        builder(stack.model_copy(update={'homeId': '9' * 32}))


def snapshot(binding):
    body = json.loads(binding.specification)
    inherited = json.loads(binding.image_configuration)
    config = {**inherited, **{key: value for key, value in body.items() if key != 'HostConfig'}}
    config['Env'] = list({
        **{value.partition('=')[0]: value for value in inherited.get('Env', [])},
        **{value.partition('=')[0]: value for value in body.get('Env', [])},
    }.values())
    config['Labels'] = {**inherited.get('Labels', {}), **body['Labels']}
    mounts = [
        {'Type': 'volume', 'Name': item.name, 'Source': '/discarded/' + item.name,
         'Destination': item.target, 'Driver': 'local', 'Mode': 'z', 'RW': True,
         'Propagation': ''}
        for item in binding.mounts
    ]
    host = dict(body['HostConfig'])
    host['RestartPolicy'] = {'Name': 'no', 'MaximumRetryCount': 0}
    return {
        'Id': '5' * 64, 'Name': '/' + binding.name, 'Image': binding.image_id,
        'Config': config, 'HostConfig': host, 'Mounts': mounts,
        'NetworkSettings': {'Networks': {
            body['HostConfig']['NetworkMode']: {'NetworkID': binding.network_id},
        }},
        'State': {'Status': 'created', 'Running': False},
    }


def test_fresh_inspect_matches_full_image_mount_network_and_security_state():
    _builder, _stack, binding = build()
    assert managed_container_matches(snapshot(binding), binding)


@pytest.mark.parametrize('damage', ['mount', 'extra_mount', 'network', 'image', 'capability', 'env'])
def test_inspect_drift_cannot_reconcile_as_the_managed_container(damage):
    _builder, _stack, binding = build()
    value = snapshot(binding)
    if damage == 'mount':
        value['Mounts'][0]['Name'] = 'foreign'
    elif damage == 'extra_mount':
        value['Mounts'].append(dict(value['Mounts'][0]))
    elif damage == 'network':
        next(iter(value['NetworkSettings']['Networks'].values()))['NetworkID'] = '9' * 64
    elif damage == 'image':
        value['Image'] = 'sha256:' + '9' * 64
    elif damage == 'capability':
        value['HostConfig']['CapAdd'] = ['SYS_ADMIN']
    else:
        value['Config']['Env'].append('TOKEN=private')
    assert managed_container_matches(value, binding) is False
