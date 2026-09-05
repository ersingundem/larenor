"""Operator opt-in and sanitized Docker observations; no real Engine access."""

import json
import os
import time
from dataclasses import replace
from types import SimpleNamespace

import pytest

from larenor_server.plugins import host_preflight as host
from larenor_server.plugins import preflight_runtime as runtime
from larenor_server.plugins.catalog import load_catalog, plan


@pytest.fixture
def policy_file(tmp_path):
    roots = tmp_path / 'appdata'
    roots.mkdir(mode=0o700)
    file = tmp_path / 'policy.json'
    file.write_text(json.dumps({
        'version': 2,
        'roots': [{'id': 'appdata', 'path': str(roots), 'purpose': 'data'}],
        'docker': {'socketPath': '/run/larenor-test-only.sock', 'ownerUid': os.getuid()},
    }))
    file.chmod(0o600)
    return file


def write_change(file, change):
    contents = json.loads(file.read_text())
    change(contents)
    file.write_text(json.dumps(contents))


def selected(platform='linux/amd64'):
    entry = next(e for e in load_catalog().entries if e.manifest.serviceId == 'jellyfin')
    return plan(entry, {}, platform)


def arguments(file):
    return ['--policy', str(file), '--socket', str(file.parent / 'worker.sock'),
            '--api-uid', str(os.getuid()), '--check-config']


def inspect(policy, *, platform='linux/amd64'):
    return host.HostInspector(
        policy, platform_provider=lambda: platform, clock=lambda: 1788609600.125,
        statvfs_provider=lambda _: SimpleNamespace(f_bavail=16384, f_frsize=1048576, f_flag=0),
    ).inspect(selected())


def statuses(result):
    return {check.code: check.status for check in result.checks}


def test_private_version_two_policy_only_optins_named_endpoint_without_inspecting_it(policy_file, monkeypatch):
    def forbidden(*args, **kwargs):
        pytest.fail('configuration validation must not inspect or connect to Docker')
    monkeypatch.setattr(runtime, 'HostInspector', forbidden)
    monkeypatch.setattr(runtime, '_host_platform', lambda: 'linux/amd64')
    import socket
    monkeypatch.setattr(socket, 'socket', forbidden)
    assert runtime.main(arguments(policy_file)) == 0
    policy = runtime.load_policy(policy_file)
    assert policy.docker.path == '/run/larenor-test-only.sock'
    assert policy.docker.owner_uid == os.getuid()
    assert 'larenor-test-only' not in repr(policy)
    assert 'larenor-test-only' not in repr(policy.docker)


@pytest.mark.parametrize('version', [1, 2])
def test_legacy_and_explicit_disabled_policy_never_discovers_default_engine(policy_file, monkeypatch, version):
    def change(value):
        value['version'] = version
        if version == 1:
            value.pop('docker')
        else:
            value['docker'] = None
    write_change(policy_file, change)
    monkeypatch.setenv('DOCKER_HOST', 'tcp://127.0.0.1:2375')
    monkeypatch.setattr(host, 'DockerProbe', lambda *_: pytest.fail('Docker opt-in is required'), raising=False)
    policy = runtime.load_policy(policy_file)
    assert policy.docker is None
    assert statuses(inspect(policy))['docker_engine'] == 'unknown'


@pytest.mark.parametrize('change', [
    lambda x: x.update(version=1),
    lambda x: x.update(version=3),
    lambda x: x.pop('docker'),
    lambda x: x.update(docker=True),
    lambda x: x.update(docker={}),
    lambda x: x['docker'].pop('ownerUid'),
    lambda x: x['docker'].update(extra='private-sentinel'),
    lambda x: x['docker'].update(ownerUid=True),
    lambda x: x['docker'].update(ownerUid=-1),
    lambda x: x['docker'].update(ownerUid=2**31),
    lambda x: x['docker'].update(socketPath='tcp://127.0.0.1:2375'),
    lambda x: x['docker'].update(socketPath='/run/../private-sentinel'),
    lambda x: x['docker'].update(socketPath='/run/private-sentinel\n'),
])
def test_invalid_optin_policy_does_not_start_worker_or_disclose_values(policy_file, monkeypatch, capsys, change):
    write_change(policy_file, change)
    monkeypatch.setattr(runtime, '_host_platform', lambda: 'linux/amd64')
    monkeypatch.setattr(runtime, 'HostInspector', lambda *_: pytest.fail('invalid policy reached inspector'))
    assert runtime.main(arguments(policy_file)) == 1
    assert capsys.readouterr().err == 'worker_configuration_invalid\n'


@pytest.mark.parametrize('observed', ['passed', 'failed', 'unknown'])
def test_worker_publishes_only_observed_engine_status_without_install_or_receiver_claim(policy_file, monkeypatch, observed):
    calls = []
    class Probe:
        def __init__(self, endpoint):
            calls.append(endpoint.path)
        def observe(self, expected_platform, *, during, deadline):
            from larenor_server.plugins.docker_probe import DockerObservation
            calls.append(expected_platform)
            assert deadline > time.monotonic()
            return DockerObservation(observed, None, during())
    monkeypatch.setattr(host, 'DockerProbe', Probe, raising=False)
    result = inspect(runtime.load_policy(policy_file))
    state = statuses(result)
    assert state['docker_engine'] == observed
    assert state['port_availability'] == state['receiver_network'] == 'unknown'
    assert state['storage_root'] == state['storage_capacity'] == 'passed'
    assert calls == ['/run/larenor-test-only.sock', 'linux/amd64']
    assert result.planHash == selected().planHash
    assert not selected().installable
    assert '/run/' not in result.model_dump_json()


@pytest.mark.parametrize('value', [True, None, '', 'private-sentinel', {'status': 'passed'}])
def test_malformed_probe_observation_is_unknown_without_disclosing_it(policy_file, monkeypatch, value):
    class Probe:
        def __init__(self, _endpoint): pass
        def observe(self, _platform, *, during, deadline):
            from larenor_server.plugins.docker_probe import DockerObservation
            return DockerObservation(value, None, during())
    monkeypatch.setattr(host, 'DockerProbe', Probe, raising=False)
    result = inspect(runtime.load_policy(policy_file))
    assert statuses(result)['docker_engine'] == 'unknown'
    assert 'private-sentinel' not in result.model_dump_json()


@pytest.mark.parametrize('stage', ['construct', 'observe'])
def test_probe_error_preserves_other_checks_and_has_no_raw_exception_result(policy_file, monkeypatch, stage):
    class Probe:
        def __init__(self, _endpoint):
            if stage == 'construct': raise OSError('private-sentinel')
        def observe(self, _platform, *, during, deadline): raise OSError('private-sentinel')
    monkeypatch.setattr(host, 'DockerProbe', Probe, raising=False)
    result = inspect(runtime.load_policy(policy_file))
    assert statuses(result)['docker_engine'] == 'unknown'
    assert statuses(result)['storage_capacity'] == 'passed'
    assert 'private-sentinel' not in result.model_dump_json()


@pytest.mark.parametrize('actual', [None, 'darwin/arm64', 'linux/arm64'])
def test_unsupported_or_plan_mismatched_host_never_contacts_engine(policy_file, monkeypatch, actual):
    monkeypatch.setattr(host, 'DockerProbe', lambda *_: pytest.fail('platform gate must precede Docker'), raising=False)
    result = inspect(runtime.load_policy(policy_file), platform=actual)
    assert statuses(result)['platform'] == 'failed'
    assert statuses(result)['docker_engine'] == 'unknown'


def test_untrusted_plan_never_reaches_docker(policy_file, monkeypatch):
    monkeypatch.setattr(host, 'DockerProbe', lambda *_: pytest.fail('plan verification must precede Docker'), raising=False)
    inspector = host.HostInspector(runtime.load_policy(policy_file))
    with pytest.raises(host.HostPreflightError, match='plan_untrusted'):
        inspector.inspect(selected().model_copy(update={'planHash': 'a' * 64}))


def test_policy_rejects_arbitrary_probe_or_endpoint_objects(policy_file):
    policy = runtime.load_policy(policy_file)
    for value in (True, 'private-sentinel', object(), {'socketPath': '/run/fake.sock'}):
        with pytest.raises(host.HostPreflightError, match='^invalid_policy$'):
            replace(policy, docker=value)
