"""Fresh managed-container proofs must stay bound to journals and one Engine."""

from dataclasses import replace
import hashlib
import json

import pytest

from larenor_server.context import ContextResponse
from larenor_server.plugins.catalog import load_catalog
from larenor_server.plugins.image_resources import ImageObservation
from larenor_server.plugins.managed_container import (
    JellyfinResourceProofBroker, ManagedContainerError,
    VolumeBootstrapObservation,
)
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


def source():
    catalog = load_catalog()
    stack = build_media_stack_plan(catalog, {}, 'linux/amd64',
        ContextResponse(schemaVersion=1, coreId='a' * 32, homeId='b' * 32), 'c' * 32)
    policy = WorkerPolicyBinding(schemaVersion=1, workerPolicyVersion=3,
                                 workerPolicyDigest='d' * 64)
    resources = build_resource_plan(stack, catalog, policy)
    volumes = build_volume_plan(stack, catalog, policy)
    component = next(item for item in stack.components if item.serviceId == 'jellyfin')
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


def populate(resource_journal, volume_journal, data):
    catalog, stack, policy, resources, volumes, _component = data
    source = dict(stack=stack, catalog=catalog, policy=policy)
    with resource_journal.locked():
        for resource in resources.resources:
            if resource.kind not in {'ensure_image', 'prepare_control_network'} or (
                    resource.kind == 'ensure_image' and resource.serviceId != 'jellyfin'):
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
            if resource.serviceId != 'jellyfin':
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
        configuration = {'Env': ['PATH=/usr/bin'], 'Volumes': {'/config': {}, '/cache': {}}}
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

    def list_network(self, binding, intent, *, cancelled):
        self.calls.append(('network-list', binding.resource.resourceId))
        return NetworkListObservation('candidate', '3' * 64)

    def inspect_network(self, binding, intent, network_id, *, cancelled):
        self.calls.append(('network-inspect', binding.resource.resourceId))
        return NetworkIdentity(network_id)


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
    assert proof.image.image_id == data[3].resources[0].image.configDigest
    assert len(proof.volumes) == 2 and all(item.bootstrap_verified for item in proof.volumes)
    assert proof.network.network_id == '3' * 64
    assert [call[0] for call in readers.calls] == [
        'image', 'volume', 'bootstrap', 'volume', 'bootstrap',
        'network-list', 'network-inspect',
    ]


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
