"""Closed Jellyfin binding consumes only fresh typed resource proofs."""

from dataclasses import replace
import copy
import hashlib
import json
import time
from types import SimpleNamespace

import pytest

from larenor_server.context import ContextResponse
from larenor_server.plugins.catalog import load_catalog
from larenor_server.plugins.managed_container import (
    JellyfinBindingBuilder,
    JournaledManagedContainerOperations,
    ManagedContainerError,
    ManagedImageProof,
    ManagedWorkerJournal,
    ManagedNetworkProof,
    ManagedVolumeProof,
    VerifiedJellyfinResources,
    managed_container_matches,
)
from larenor_server.plugins.resource_models import WorkerPolicyBinding
from larenor_server.plugins.stack_plan import build_media_stack_plan
from larenor_server.plugins.worker import (
    DockerWorkerError, UnixDockerEngine, WorkerJournal, WorkerStep,
)


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


def build(provider=proof, container_journal_id='4' * 32):
    catalog, stack, policy = source()
    builder = JellyfinBindingBuilder(catalog, policy, container_journal_id, provider)
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


class Engine:
    def __init__(self, binding):
        self.binding = binding
        self.container = None
        self.calls = []
        self.lose_create = False

    def inspect_container(self, name):
        self.calls.append(('inspect', name))
        return copy.deepcopy(self.container)

    def inspect_image(self, reference):
        self.calls.append(('image', reference))
        return {'Id': self.binding.image_id, 'Os': 'linux', 'Architecture': 'amd64',
                'Config': json.loads(self.binding.image_configuration)}

    def create_managed_container(self, binding):
        self.calls.append(('create', binding.name))
        self.container = snapshot(binding)
        if self.lose_create:
            raise DockerWorkerError('engine_unavailable')
        return self.container['Id']

    def start_container(self, identity):
        self.calls.append(('start', identity))
        self.container['State'] = {'Status': 'running', 'Running': True}


def command(binding, kind='create_container', dispatch='6' * 32):
    return WorkerStep('7' * 32, binding.name.removeprefix('larenor-'), kind,
                      dispatch, time.time() + 30)


def test_separate_managed_journal_executes_exact_binding_and_recovers_lost_reply(tmp_path):
    with ManagedWorkerJournal(tmp_path / 'managed', initialize=True) as journal:
        _builder, _stack, binding = build(container_journal_id=journal.identity)
        engine = Engine(binding)
        worker = JournaledManagedContainerOperations(journal, engine)
        engine.lose_create = True
        created = worker.apply(command(binding), binding)
        assert created.state == 'uncertain'
        assert worker.reconcile('7' * 32, 'create_container', binding).code == 'container_created'
        assert len([call for call in engine.calls if call[0] == 'create']) == 1
        engine.lose_create = False
        started = worker.apply(command(binding, 'start_container', '8' * 32), binding)
        assert started.code == 'container_started'


def test_legacy_and_managed_journals_cannot_read_each_others_domain(tmp_path):
    legacy_path, managed_path = tmp_path / 'legacy', tmp_path / 'managed'
    with WorkerJournal(legacy_path, initialize=True), ManagedWorkerJournal(managed_path, initialize=True):
        pass
    with pytest.raises(DockerWorkerError, match='^journal_unavailable$'):
        ManagedWorkerJournal(legacy_path)
    with pytest.raises(DockerWorkerError, match='^journal_unavailable$'):
        WorkerJournal(managed_path)


def test_managed_start_requires_the_matching_completed_create(tmp_path):
    with ManagedWorkerJournal(tmp_path / 'managed', initialize=True) as journal:
        _builder, _stack, binding = build(container_journal_id=journal.identity)
        engine = Engine(binding)
        worker = JournaledManagedContainerOperations(journal, engine)
        with pytest.raises(DockerWorkerError, match='^step_order$'):
            worker.apply(command(binding, 'start_container'), binding)
        assert engine.calls == []


def test_managed_reconcile_rejects_a_rebuilt_resource_binding_change_before_engine(tmp_path):
    with ManagedWorkerJournal(tmp_path / 'managed', initialize=True) as journal:
        _builder, _stack, binding = build(container_journal_id=journal.identity)
        engine = Engine(binding)
        worker = JournaledManagedContainerOperations(journal, engine)
        engine.lose_create = True
        assert worker.apply(command(binding), binding).state == 'uncertain'
        calls = list(engine.calls)
        changed = replace(binding, network_id='9' * 64)
        with pytest.raises(DockerWorkerError, match='^idempotency_conflict$'):
            worker.reconcile('7' * 32, 'create_container', changed)
        assert engine.calls == calls


def test_managed_journal_tamper_is_static_and_never_recreates(tmp_path):
    with ManagedWorkerJournal(tmp_path / 'managed', initialize=True) as journal:
        _builder, _stack, binding = build(container_journal_id=journal.identity)
        engine = Engine(binding)
        worker = JournaledManagedContainerOperations(journal, engine)
        assert worker.apply(command(binding), binding).code == 'container_created'
        row = journal._database.execute('SELECT payload FROM operations').fetchone()
        payload = json.loads(row[0])
        payload['binding']['specification']['Labels']['org.larenor.worker-journal'] = '9' * 32
        raw = json.dumps(payload, sort_keys=True, separators=(',', ':')).encode()
        journal._database.execute('UPDATE operations SET payload=?,digest=?',
                                  (raw, hashlib.sha256(raw).hexdigest()))
        with pytest.raises(DockerWorkerError, match='^journal_unavailable$') as error:
            worker.observe('7' * 32, 'create_container')
        assert 'payload' not in repr(error.value)
        assert len([call for call in engine.calls if call[0] == 'create']) == 1


def test_unix_engine_sends_the_exact_managed_binding_to_the_fixed_create_route(tmp_path):
    _builder, _stack, binding = build()
    engine = UnixDockerEngine(tmp_path / 'unused')
    captured = []
    engine._exchange = lambda method, target, body=None: (
        captured.append((method, target, body)) or
        SimpleNamespace(status=201, body=json.dumps({'Id': '5' * 64, 'Warnings': []}).encode())
    )
    assert engine.create_managed_container(binding) == '5' * 64
    assert captured == [('POST', '/containers/create?name=' + binding.name
                         + '&platform=linux%2Famd64', binding.specification)]


@pytest.mark.parametrize('damage', ['image', 'label', 'memory', 'tmpfs', 'readonly'])
def test_managed_operations_reject_forged_binding_before_engine(tmp_path, damage):
    with ManagedWorkerJournal(tmp_path / 'managed', initialize=True) as journal:
        _builder, _stack, binding = build(container_journal_id=journal.identity)
        body = json.loads(binding.specification)
        if damage == 'image':
            body['Image'] = 'https://foreign.invalid/image@' + binding.image_id
        elif damage == 'label':
            body['Labels']['untrusted'] = 'true'
        elif damage == 'memory':
            body['HostConfig']['Memory'] = 'unbounded'
        elif damage == 'tmpfs':
            body['HostConfig']['Tmpfs']['/tmp'] = 'rw,exec,size=999999m'
        else:
            body['HostConfig']['ReadonlyRootfs'] = False
        forged = replace(binding, specification=json.dumps(
            body, sort_keys=True, separators=(',', ':')).encode())
        engine = Engine(binding)
        worker = JournaledManagedContainerOperations(journal, engine)
        with pytest.raises(DockerWorkerError, match='^invalid_command$'):
            worker.apply(command(binding), forged)
        assert engine.calls == []
