"""Fresh managed-container proofs must stay bound to journals and one Engine."""

import json
from types import SimpleNamespace

import pytest

from larenor_server.context import ContextResponse
from larenor_server.plugins.catalog import load_catalog
from larenor_server.plugins.image_resources import ImageObservation
from larenor_server.plugins.managed_container import (
    JellyfinEngineReaders, JellyfinResourceProofBroker, ManagedContainerError,
    VolumeBootstrapObservation,
)
from larenor_server.plugins.docker_probe import DockerEndpoint
from larenor_server.plugins.network_resources import NetworkListObservation
from larenor_server.plugins.resource_journal import (
    ImageIdentity, NetworkIdentity, ResourceJournal, ResourceObservation, _digest,
)
from larenor_server.plugins.resource_models import WorkerPolicyBinding
from larenor_server.plugins.resource_plan import build_resource_plan
from larenor_server.plugins.stack_plan import build_media_stack_plan
from larenor_server.plugins.volume_create_journal import VolumeCreateJournal
from larenor_server.plugins.volume_plan import build_volume_plan
from larenor_server.plugins.volume_resources import VolumeObservation, volume_expected_labels


def source(service_id='jellyfin'):
    catalog = load_catalog()
    stack = build_media_stack_plan(catalog, {}, 'linux/amd64',
        ContextResponse(schemaVersion=1, coreId='a' * 32, homeId='b' * 32), 'c' * 32)
    policy = WorkerPolicyBinding(schemaVersion=1, workerPolicyVersion=3,
                                 workerPolicyDigest='d' * 64)
    resources = build_resource_plan(stack, catalog, policy)
    volumes = build_volume_plan(stack, catalog, policy)
    component = next(item for item in stack.components
                     if item.serviceId == service_id)
    return catalog, stack, policy, resources, volumes, component


def resource_observation(intent):
    identity = (ImageIdentity(intent.resource.image.configDigest)
                if intent.resource.kind == 'ensure_image' else NetworkIdentity('3' * 64))
    return ResourceObservation(
        'matched', intent.resource.resourceId, intent.journal_id,
        intent.ownership_nonce, intent.specification_digest, identity,
    )


def volume_observation(intent):
    binding = intent.binding
    return VolumeObservation(
        binding.resource_id, binding.resource.name, binding.source[0].planHash,
        _digest(volume_expected_labels(binding)),
    )


def populate(resource_journal, volume_journal, data, service_id='jellyfin'):
    catalog, stack, policy, resources, volumes, _component = data
    source = dict(stack=stack, catalog=catalog, policy=policy)
    with resource_journal.locked():
        for resource in resources.resources:
            if resource.kind not in {'ensure_image', 'prepare_control_network'} or (
                    resource.kind == 'ensure_image' and resource.serviceId != service_id):
                continue
            receipt = resource_journal.prepare(
                plan=resources, resource_id=resource.resourceId, **source)
            intent = resource_journal.begin(
                resource.resourceId, receipt.revision, plan=resources, **source)
            result = resource_journal.reconcile(
                resource.resourceId, intent.receipt.revision, resource_observation,
                plan=resources, **source)
            assert result.state == 'ready'
    with volume_journal.locked():
        for resource in volumes.resources:
            if (resource.serviceId != service_id
                    and not (service_id == 'qbittorrent'
                             and resource.kind == 'managed_library')):
                continue
            receipt = volume_journal.prepare(
                plan=volumes, resource_id=resource.resourceId, **source)
            intent = volume_journal.begin_create(
                resource.resourceId, receipt.revision, plan=volumes, **source)
            result = volume_journal.reconcile(
                resource.resourceId, intent.receipt.revision, volume_observation,
                plan=volumes, **source)
            assert result.state == 'observed_requires_bootstrap'


class Readers:
    def __init__(self, data, endpoint=None):
        self.data = data
        self._endpoint = endpoint if endpoint is not None else object()
        self.calls = []
        self.bootstrap_revision_delta = 0

    def inspect_image(self, binding, *, cancelled):
        self.calls.append(('image', binding.resource_id))
        service_id = self.data[5].serviceId
        volumes = ({'/app/config': {}} if service_id == 'seerr'
                   else {'/config': {}, **(
                       {'/cache': {}} if service_id == 'jellyfin' else {})})
        configuration = {'Env': ['PATH=/usr/bin'], 'Volumes': volumes}
        return ImageObservation(binding.config_digest, json.dumps(
            configuration, sort_keys=True, separators=(',', ':')).encode())

    def inspect_volume(self, intent, *, cancelled):
        self.calls.append(('volume', intent.binding.resource_id))
        return volume_observation(intent)

    def verify_bootstrap(self, intent, *, cancelled):
        self.calls.append(('bootstrap', intent.binding.resource_id))
        binding, receipt = intent.binding, intent.receipt
        return VolumeBootstrapObservation(
            binding.resource_id, binding.resource.operationId, binding.journal_id,
            binding.ownership_nonce, receipt.revision + self.bootstrap_revision_delta,
            binding.resource.name, binding.resource.target, 'root_verified',
        )

    def prepare_media_directories(self, intent, *, cancelled):
        self.calls.append(('prepare-library', intent.binding.resource_id))
        binding, receipt = intent.binding, intent.receipt
        return VolumeBootstrapObservation(
            binding.resource_id, binding.resource.operationId, binding.journal_id,
            binding.ownership_nonce, receipt.revision,
            binding.resource.name, binding.resource.target,
            'media_directories_prepared',
        )

    def list_network(self, binding, intent, *, cancelled):
        self.calls.append(('network-list', binding.resource.resourceId))
        return NetworkListObservation('candidate', '3' * 64)

    def inspect_network(self, binding, intent, network_id, *, cancelled):
        self.calls.append(('network-inspect', binding.resource.resourceId))
        return NetworkIdentity(network_id)


class BootstrapVerifier:
    def __init__(self, endpoint):
        self._endpoint = endpoint
        self.calls = []

    def verify(self, intent, *, cancelled):
        self.calls.append((intent, cancelled))
        return 'bootstrap-observation'

    def prepare_media_directories(self, intent, *, cancelled):
        self.calls.append((intent, cancelled, 'prepare'))
        return 'directory-observation'


def test_engine_readers_construct_fixed_adapters_on_one_exact_endpoint():
    endpoint = DockerEndpoint('/tmp/larenor-engine-readers.sock')
    bootstrap = BootstrapVerifier(endpoint)
    readers = JellyfinEngineReaders(endpoint, bootstrap, peer_uid=lambda _connection: 0)
    calls = []
    readers._images.inspect = lambda binding, *, cancelled: calls.append(
        ('image', binding, cancelled)) or 'image-observation'
    readers._volumes.inspect = lambda binding, *, cancelled: calls.append(
        ('volume', binding, cancelled)) or 'volume-observation'
    readers._networks.list = lambda binding, intent, *, cancelled: calls.append(
        ('network-list', binding, intent, cancelled)) or 'network-list-observation'
    readers._networks.inspect = lambda binding, intent, network_id, *, cancelled: calls.append(
        ('network-inspect', binding, intent, network_id, cancelled)) or 'network-observation'
    cancelled = object()
    volume_intent = SimpleNamespace(binding='volume-binding')

    assert readers.inspect_image('image-binding', cancelled=cancelled) == 'image-observation'
    assert readers.inspect_volume(volume_intent, cancelled=cancelled) == 'volume-observation'
    assert readers.verify_bootstrap(volume_intent, cancelled=cancelled) == 'bootstrap-observation'
    assert readers.prepare_media_directories(
        volume_intent, cancelled=cancelled) == 'directory-observation'
    assert readers.list_network('network-binding', 'network-intent', cancelled=cancelled) == \
        'network-list-observation'
    assert readers.inspect_network(
        'network-binding', 'network-intent', 'network-id', cancelled=cancelled,
    ) == 'network-observation'
    assert readers._endpoint is endpoint and bootstrap.calls == [
        (volume_intent, cancelled), (volume_intent, cancelled, 'prepare')]
    assert [item[0] for item in calls] == [
        'image', 'volume', 'network-list', 'network-inspect',
    ]


def test_engine_readers_reject_bootstrap_on_a_different_endpoint():
    endpoint = DockerEndpoint('/tmp/larenor-engine-readers.sock')
    foreign = DockerEndpoint('/tmp/larenor-foreign-engine.sock')
    with pytest.raises(ManagedContainerError, match='^resources_untrusted$'):
        JellyfinEngineReaders(endpoint, BootstrapVerifier(foreign))


def test_broker_rebinds_and_freshly_observes_every_jellyfin_resource(tmp_path):
    data = source()
    endpoint = object()
    readers = Readers(data, endpoint)
    with ResourceJournal(tmp_path / 'resources', initialize=True) as resource_journal, \
            VolumeCreateJournal(tmp_path / 'volumes', initialize=True) as volume_journal:
        populate(resource_journal, volume_journal, data)
        broker = JellyfinResourceProofBroker(
            data[1], data[0], data[2], resource_journal, volume_journal,
            readers, engine_identity=endpoint,
        )
        proof = broker(data[3], data[4], data[5])
    jellyfin_image = next(item for item in data[3].resources
                           if item.kind == 'ensure_image' and item.serviceId == 'jellyfin')
    assert proof.image.image_id == jellyfin_image.image.configDigest
    assert len(proof.volumes) == 3 and all(item.bootstrap_verified for item in proof.volumes)
    assert proof.network.network_id == '3' * 64
    assert [call[0] for call in readers.calls] == [
        'image', 'volume', 'bootstrap', 'volume', 'bootstrap', 'volume',
        'prepare-library', 'bootstrap',
        'network-list', 'network-inspect',
    ]


def test_broker_rebinds_qbittorrent_config_and_shared_library(tmp_path):
    data = source('qbittorrent')
    endpoint = object()
    readers = Readers(data, endpoint)
    with ResourceJournal(tmp_path / 'resources', initialize=True) as resource_journal, \
            VolumeCreateJournal(tmp_path / 'volumes', initialize=True) as volume_journal:
        populate(resource_journal, volume_journal, data, 'qbittorrent')
        broker = JellyfinResourceProofBroker(
            data[1], data[0], data[2], resource_journal, volume_journal,
            readers, engine_identity=endpoint, service_id='qbittorrent')
        proof = broker(data[3], data[4], data[5])
    image = next(item for item in data[3].resources
                 if item.kind == 'ensure_image'
                 and item.serviceId == 'qbittorrent')
    assert proof.image.image_id == image.image.configDigest
    assert len(proof.volumes) == 2
    assert {item.target for item in proof.volumes} == {'/config', '/media'}
    assert [call[0] for call in readers.calls] == [
        'image', 'volume', 'bootstrap', 'volume', 'prepare-library', 'bootstrap',
        'network-list', 'network-inspect']


def test_broker_rebinds_only_seerr_owned_appdata(tmp_path):
    data = source('seerr')
    endpoint = object()
    readers = Readers(data, endpoint)
    with ResourceJournal(tmp_path / 'resources', initialize=True) as resource_journal, \
            VolumeCreateJournal(tmp_path / 'volumes', initialize=True) as volume_journal:
        populate(resource_journal, volume_journal, data, 'seerr')
        broker = JellyfinResourceProofBroker(
            data[1], data[0], data[2], resource_journal, volume_journal,
            readers, engine_identity=endpoint, service_id='seerr')
        proof = broker(data[3], data[4], data[5])
    assert len(proof.volumes) == 1
    assert proof.volumes[0].target == '/app/config'
    assert [call[0] for call in readers.calls] == [
        'image', 'volume', 'bootstrap', 'network-list', 'network-inspect']


def test_stale_bootstrap_or_different_engine_never_produces_a_proof(tmp_path):
    data = source()
    readers = Readers(data)
    with ResourceJournal(tmp_path / 'resources', initialize=True) as resource_journal, \
            VolumeCreateJournal(tmp_path / 'volumes', initialize=True) as volume_journal:
        populate(resource_journal, volume_journal, data)
        with pytest.raises(ManagedContainerError, match='^resources_untrusted$'):
            JellyfinResourceProofBroker(
                data[1], data[0], data[2], resource_journal, volume_journal,
                readers, engine_identity=object(),
            )
        broker = JellyfinResourceProofBroker(
            data[1], data[0], data[2], resource_journal, volume_journal,
            readers, engine_identity=readers._endpoint,
        )
        readers.bootstrap_revision_delta = -1
        with pytest.raises(ManagedContainerError, match='^resources_unavailable$') as error:
            broker(data[3], data[4], data[5])
        assert 'revision' not in repr(error.value)


def test_broker_reports_only_the_failed_proof_stage(tmp_path):
    data = source('qbittorrent')
    endpoint = object()
    readers = Readers(data, endpoint)
    readers.verify_bootstrap = lambda *_args, **_kwargs: (_ for _ in ()).throw(
        RuntimeError('private helper failure'))
    with ResourceJournal(tmp_path / 'resources', initialize=True) as resource_journal, \
            VolumeCreateJournal(tmp_path / 'volumes', initialize=True) as volume_journal:
        populate(resource_journal, volume_journal, data, 'qbittorrent')
        broker = JellyfinResourceProofBroker(
            data[1], data[0], data[2], resource_journal, volume_journal,
            readers, engine_identity=endpoint, service_id='qbittorrent')
        with pytest.raises(
                ManagedContainerError,
                match='^resources_unavailable$') as error:
            broker(data[3], data[4], data[5])

    assert error.value.cause_code == 'resource_proof_volume_bootstrap_failed'
    assert 'private' not in repr(error.value)
