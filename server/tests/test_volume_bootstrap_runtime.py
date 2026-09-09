"""Production-shaped root verification through one fixed helper container."""

import json
from pathlib import Path
from types import SimpleNamespace
import threading

import pytest

from larenor_server.plugins.docker_probe import DockerEndpoint
from larenor_server.plugins.volume_bootstrap import (
    UnixVolumeBootstrapEngine,
    VolumeBootstrapError,
    VolumeBootstrapVerifier,
)
from larenor_server.services.transport import ProbeResponse
from test_managed_resource_proof import populate, source
from larenor_server.plugins.resource_journal import ResourceJournal
from larenor_server.plugins.volume_create_journal import VolumeCreateJournal


HELPER = 'sha256:' + '9' * 64


def volume_intent(tmp_path):
    data = source()
    resources = ResourceJournal(tmp_path / 'resources', initialize=True)
    volumes = VolumeCreateJournal(tmp_path / 'volumes', initialize=True)
    populate(resources, volumes, data)
    plan, stack, catalog, policy = data[4], data[1], data[0], data[2]
    selected = next(item for item in plan.resources if item.serviceId == 'jellyfin')
    with volumes.locked():
        receipt = volumes.get(selected.resourceId)
        intent = volumes.bind(
            selected.resourceId,
            receipt.revision,
            plan=plan,
            stack=stack,
            catalog=catalog,
            policy=policy,
        )
    resources.close()
    volumes.close()
    return intent


class VerifiedRootEngine:
    def __init__(self, endpoint, result=True):
        self._endpoint = endpoint
        self.result = result
        self.calls = []

    def verify_root(self, intent, helper_image_id, platform, *, cancelled):
        self.calls.append((intent, helper_image_id, platform, cancelled))
        if isinstance(self.result, Exception):
            raise self.result
        return self.result


def test_verifier_rederives_intent_and_returns_revision_bound_observation(tmp_path):
    intent = volume_intent(tmp_path)
    endpoint = DockerEndpoint('/private/docker.sock', owner_uid=0)
    engine = VerifiedRootEngine(endpoint)
    verifier = VolumeBootstrapVerifier(
        endpoint,
        HELPER,
        'linux/amd64',
        engine_factory=lambda value: engine,
    )
    cancelled = threading.Event()

    result = verifier.verify(intent, cancelled=cancelled)

    binding, receipt = intent.binding, intent.receipt
    assert result.resource_id == binding.resource_id
    assert result.operation_id == binding.resource.operationId
    assert result.journal_id == binding.journal_id
    assert result.ownership_nonce == binding.ownership_nonce
    assert result.revision == receipt.revision
    assert result.name == binding.resource.name
    assert result.target == binding.resource.target
    assert result.state == 'root_verified'
    assert engine.calls == [(intent, HELPER, 'linux/amd64', cancelled)]
    assert verifier._endpoint is endpoint


@pytest.mark.parametrize('result', [False, RuntimeError('private-engine-detail')])
def test_verifier_fails_closed_without_echoing_engine_detail(tmp_path, result):
    intent = volume_intent(tmp_path)
    endpoint = DockerEndpoint('/private/docker.sock', owner_uid=0)
    verifier = VolumeBootstrapVerifier(
        endpoint,
        HELPER,
        'linux/amd64',
        engine_factory=lambda value: VerifiedRootEngine(value, result),
    )
    with pytest.raises(VolumeBootstrapError, match='^bootstrap_unavailable$') as raised:
        verifier.verify(intent, cancelled=threading.Event())
    assert 'private-engine-detail' not in str(raised.value)


def test_verifier_rejects_cancelled_or_forged_inputs_before_engine(tmp_path):
    intent = volume_intent(tmp_path)
    endpoint = DockerEndpoint('/private/docker.sock', owner_uid=0)
    engine = VerifiedRootEngine(endpoint)
    verifier = VolumeBootstrapVerifier(
        endpoint,
        HELPER,
        'linux/amd64',
        engine_factory=lambda value: engine,
    )
    cancelled = threading.Event()
    cancelled.set()
    with pytest.raises(VolumeBootstrapError, match='^bootstrap_unavailable$'):
        verifier.verify(intent, cancelled=cancelled)
    with pytest.raises(VolumeBootstrapError, match='^bootstrap_unavailable$'):
        verifier.verify(SimpleNamespace(binding=intent.binding, receipt=intent.receipt),
                        cancelled=threading.Event())
    assert engine.calls == []


@pytest.mark.parametrize('image,platform', [
    ('latest', 'linux/amd64'),
    ('sha256:' + '9' * 63, 'linux/amd64'),
    (HELPER, 'linux/386'),
])
def test_verifier_configuration_is_exact(image, platform):
    endpoint = DockerEndpoint('/private/docker.sock', owner_uid=0)
    with pytest.raises(VolumeBootstrapError, match='^bootstrap_configuration_invalid$'):
        VolumeBootstrapVerifier(endpoint, image, platform)


def test_verifier_rejects_engine_bound_to_another_endpoint():
    endpoint = DockerEndpoint('/private/docker.sock', owner_uid=0)
    foreign = DockerEndpoint('/private/other.sock', owner_uid=0)
    with pytest.raises(VolumeBootstrapError, match='^bootstrap_configuration_invalid$'):
        VolumeBootstrapVerifier(
            endpoint,
            HELPER,
            'linux/amd64',
            engine_factory=lambda value: VerifiedRootEngine(foreign),
        )


def test_default_engine_keeps_all_helper_operations_strictly_bounded():
    endpoint = DockerEndpoint('/private/docker.sock', owner_uid=0)

    engine = UnixVolumeBootstrapEngine(endpoint)

    assert engine._transport.path == Path(endpoint.path)
    assert engine._transport.socket_uid == 0
    assert engine._transport.timeout == 1.0
    assert engine._cleanup_transport is engine._transport


class ExchangeTransport:
    def __init__(self, replies):
        self.replies = list(replies)
        self.calls = []

    def _exchange(self, method, target, body=None):
        self.calls.append((method, target, body))
        reply = self.replies.pop(0)
        if isinstance(reply, Exception):
            raise reply
        return reply


def response(status, value=None):
    body = b'' if value is None else json.dumps(
        value, sort_keys=True, separators=(',', ':'),
    ).encode()
    return ProbeResponse(status, (), body)


def test_unix_engine_uses_fixed_ephemeral_helper_and_removes_it(tmp_path):
    intent = volume_intent(tmp_path)
    container_id = '7' * 64
    transport = ExchangeTransport([
        response(201, {'Id': container_id, 'Warnings': None}),
        response(204),
        response(200, {'StatusCode': 0, 'Error': None}),
        response(204),
    ])
    endpoint = DockerEndpoint('/private/docker.sock', owner_uid=0)
    engine = UnixVolumeBootstrapEngine(
        endpoint,
        transport_factory=lambda value: transport,
        name_factory=lambda: '8' * 32,
    )

    assert engine.verify_root(
        intent,
        HELPER,
        'linux/amd64',
        cancelled=threading.Event(),
    ) is True

    create = transport.calls[0]
    assert create[:2] == (
        'POST',
        '/containers/create?name=larenor-bootstrap-' + '8' * 32 + '&platform=linux%2Famd64',
    )
    body = json.loads(create[2])
    assert body['Image'] == HELPER
    assert body['User'] == '1000:1000'
    assert body['Entrypoint'] == [
        '/usr/local/bin/python', '-I', '/opt/larenor/volume_bootstrap_helper.py',
    ]
    assert body['Cmd'] == ['verify_root']
    assert body['HostConfig']['NetworkMode'] == 'none'
    assert body['HostConfig']['ReadonlyRootfs'] is True
    assert body['HostConfig']['CapDrop'] == ['ALL']
    assert body['HostConfig']['CapAdd'] == []
    assert body['HostConfig']['Mounts'] == [{
        'Type': 'volume',
        'Source': intent.binding.resource.name,
        'Target': '/volume',
        'ReadOnly': True,
        'VolumeOptions': {'NoCopy': True},
    }]
    assert transport.calls[1][:2] == ('POST', f'/containers/{container_id}/start')
    assert transport.calls[2][:2] == (
        'POST', f'/containers/{container_id}/wait?condition=not-running',
    )
    assert transport.calls[3][:2] == (
        'DELETE', f'/containers/{container_id}',
    )


@pytest.mark.parametrize('wait', [
    {'StatusCode': 1, 'Error': None},
    {'StatusCode': 0, 'Error': {'Message': 'private'}},
    {'StatusCode': True, 'Error': None},
])
def test_helper_failure_is_static_and_still_removes_known_container(tmp_path, wait):
    intent = volume_intent(tmp_path)
    container_id = '7' * 64
    transport = ExchangeTransport([
        response(201, {'Id': container_id, 'Warnings': []}),
        response(204), response(200, wait), response(204),
    ])
    endpoint = DockerEndpoint('/private/docker.sock', owner_uid=0)
    engine = UnixVolumeBootstrapEngine(
        endpoint,
        transport_factory=lambda value: transport,
        name_factory=lambda: '8' * 32,
    )
    with pytest.raises(VolumeBootstrapError, match='^bootstrap_result_failed$'):
        engine.verify_root(intent, HELPER, 'linux/amd64', cancelled=threading.Event())
    assert transport.calls[-1][:2] == (
        'DELETE', f'/containers/{container_id}',
    )


def test_cleanup_http_rejection_reports_only_static_status_stage(tmp_path):
    intent = volume_intent(tmp_path)
    container_id = '7' * 64
    transport = ExchangeTransport([
        response(201, {'Id': container_id, 'Warnings': None}),
        response(204),
        response(200, {'StatusCode': 0, 'Error': None}),
        response(409, {'message': 'private-engine-detail'}),
    ])
    engine = UnixVolumeBootstrapEngine(
        DockerEndpoint('/private/docker.sock', owner_uid=0),
        transport_factory=lambda value: transport,
        name_factory=lambda: '8' * 32,
    )

    with pytest.raises(
        VolumeBootstrapError,
        match='^bootstrap_cleanup_status_failed$',
    ) as raised:
        engine.verify_root(intent, HELPER, 'linux/amd64', cancelled=threading.Event())

    assert 'private-engine-detail' not in str(raised.value)
    assert transport.calls[-1][:2] == ('DELETE', f'/containers/{container_id}')


def test_cleanup_transport_rejection_reports_only_static_transport_stage(tmp_path):
    intent = volume_intent(tmp_path)
    container_id = '7' * 64
    transport = ExchangeTransport([
        response(201, {'Id': container_id, 'Warnings': None}),
        response(204),
        response(200, {'StatusCode': 0, 'Error': None}),
        RuntimeError('private-transport-detail'),
    ])
    engine = UnixVolumeBootstrapEngine(
        DockerEndpoint('/private/docker.sock', owner_uid=0),
        transport_factory=lambda value: transport,
        name_factory=lambda: '8' * 32,
    )

    with pytest.raises(
        VolumeBootstrapError,
        match='^bootstrap_cleanup_transport_failed$',
    ) as raised:
        engine.verify_root(intent, HELPER, 'linux/amd64', cancelled=threading.Event())

    assert 'private-transport-detail' not in str(raised.value)
    assert transport.calls[-1][:2] == ('DELETE', f'/containers/{container_id}')


def test_create_rejection_reports_only_static_stage_and_has_no_cleanup_target(tmp_path):
    intent = volume_intent(tmp_path)
    transport = ExchangeTransport([response(500, {'message': 'private-engine-detail'})])
    endpoint = DockerEndpoint('/private/docker.sock', owner_uid=0)
    engine = UnixVolumeBootstrapEngine(
        endpoint,
        transport_factory=lambda value: transport,
        name_factory=lambda: '8' * 32,
    )
    with pytest.raises(VolumeBootstrapError, match='^bootstrap_create_failed$') as raised:
        engine.verify_root(intent, HELPER, 'linux/amd64', cancelled=threading.Event())
    assert 'private-engine-detail' not in str(raised.value)
    assert len(transport.calls) == 1
