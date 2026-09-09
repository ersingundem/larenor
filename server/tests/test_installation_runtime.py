"""Packaged mutation worker policy and process lifecycle."""

import json
import os
from pathlib import Path
import signal
import socket

import pytest

from larenor_server.plugins import installation_runtime as runtime
from larenor_server.plugins.managed_container import ManagedWorkerJournal
from larenor_server.plugins.resource_journal import ResourceJournal
from larenor_server.plugins.volume_create_journal import VolumeCreateJournal


def contents(root, *, platform='linux/amd64'):
    return {
        'version': 1,
        'platform': platform,
        'docker': {
            'socketPath': '/var/run/docker.sock',
            'ownerUid': 0,
            'daemonExecutable': '/usr/bin/dockerd',
        },
        'workerPolicy': {
            'schemaVersion': 1,
            'workerPolicyVersion': 3,
            'workerPolicyDigest': 'd' * 64,
        },
        'bootstrap': {'imageId': 'sha256:' + '9' * 64},
        'journals': {
            'resources': str(root / 'resources'),
            'volumes': str(root / 'volumes'),
            'containers': str(root / 'containers'),
        },
    }


@pytest.fixture
def configuration(tmp_path, monkeypatch):
    for name, cls in (
        ('resources', ResourceJournal),
        ('volumes', VolumeCreateJournal),
        ('containers', ManagedWorkerJournal),
    ):
        value = cls(tmp_path / name, initialize=True)
        value.close()
    policy = tmp_path / 'installation-policy.json'
    policy.write_text(json.dumps(contents(tmp_path)))
    policy.chmod(0o600)
    monkeypatch.setattr(runtime, '_host_platform', lambda: 'linux/amd64')
    return policy


def arguments(policy, *extra):
    return [
        '--policy', str(policy),
        '--socket', str(policy.parent / 'installation.sock'),
        '--api-uid', str(os.getuid()),
        *extra,
    ]


def test_check_config_validates_only_policy_without_journal_engine_or_socket_access(
        configuration, monkeypatch):
    def forbidden(*args, **kwargs):
        pytest.fail('check-only must not construct runtime dependencies')
    for name in ('_build_runtime', 'InstallationWorkerServer'):
        monkeypatch.setattr(runtime, name, forbidden)
    monkeypatch.setattr(socket, 'socket', forbidden)

    assert runtime.main(arguments(configuration, '--check-config')) == 0
    assert sorted(p.name for p in configuration.parent.iterdir()) == [
        'containers', 'installation-policy.json', 'resources', 'volumes',
    ]


@pytest.mark.parametrize('change', [
    lambda x: x.update(version=2),
    lambda x: x.update(version=True),
    lambda x: x.update(extra='private-secret'),
    lambda x: x.update(platform='linux/386'),
    lambda x: x['docker'].pop('daemonExecutable'),
    lambda x: x['docker'].update(tcp='private-secret'),
    lambda x: x['docker'].update(socketPath='tcp://private-secret'),
    lambda x: x['workerPolicy'].update(workerPolicyDigest='z' * 64),
    lambda x: x['bootstrap'].update(imageId='latest'),
    lambda x: x['journals'].update(resources='relative/private-secret'),
    lambda x: x['journals'].update(extra='/private-secret'),
    lambda x: x['journals'].update(volumes=x['journals']['resources'] + '/nested'),
])
def test_invalid_policy_is_static_and_never_builds_runtime(
        configuration, monkeypatch, capsys, change):
    value = contents(configuration.parent)
    change(value)
    configuration.write_text(json.dumps(value))
    monkeypatch.setattr(
        runtime,
        '_build_runtime',
        lambda *args: pytest.fail('invalid configuration must not open journals'),
    )
    assert runtime.main(arguments(configuration, '--check-config')) == 1
    assert 'private-secret' not in capsys.readouterr().err


@pytest.mark.parametrize('raw', [
    b'{"version":1,"version":1}', b'null', b'[]', b'\xff', b'{}', b' ' * 32769,
])
def test_duplicate_malformed_or_oversized_policy_is_rejected(configuration, raw):
    configuration.write_bytes(raw)
    assert runtime.main(arguments(configuration, '--check-config')) == 1


@pytest.mark.parametrize('mode', [0o644, 0o660, 0o400, 0o777])
def test_nonprivate_policy_is_rejected(configuration, mode):
    configuration.chmod(mode)
    assert runtime.main(arguments(configuration, '--check-config')) == 1


def test_runtime_builds_one_endpoint_and_closes_all_journals(configuration):
    policy = runtime.load_policy(configuration)
    built = runtime._build_runtime(policy)
    try:
        assert built.backend.binding_builder._endpoint is policy.endpoint
        assert built.backend.binding_builder._readers._endpoint is policy.endpoint
        assert built.backend.binding_builder._readers._bootstrap._endpoint is policy.endpoint
        assert built.backend.operations.engine.path == Path(policy.endpoint.path)
        assert built.backend.operations.journal.identity == built.backend.binding_builder._container_journal.identity
    finally:
        built.close()
    assert built.closed is True


def install_lifecycle(monkeypatch, *, start_error=None, close_error=None):
    events, handlers = [], {}

    class Event:
        def set(self):
            events.append('signal')

        def wait(self):
            handlers[signal.SIGTERM](signal.SIGTERM, None)

    class Built:
        backend = object()

        def close(self):
            events.append('runtime-close')

    class Worker:
        def start(self):
            events.append('start')
            if start_error:
                raise start_error

        def close(self):
            events.append('worker-close')
            if close_error:
                raise close_error

    monkeypatch.setattr(runtime.threading, 'Event', Event)
    monkeypatch.setattr(runtime.signal, 'getsignal', lambda value: f'original-{value}')

    def signal_handler(value, handler):
        events.append(('handler', value))
        handlers[value] = handler

    monkeypatch.setattr(runtime.signal, 'signal', signal_handler)
    monkeypatch.setattr(runtime, '_build_runtime', lambda policy: Built())

    def server(path, backend, **kwargs):
        assert kwargs['allowed_uid'] == os.getuid()
        events.append('construct')
        return Worker()

    monkeypatch.setattr(runtime, 'InstallationWorkerServer', server)
    return events, handlers


def test_runtime_serves_until_signal_then_closes_socket_before_journals(
        configuration, monkeypatch):
    events, handlers = install_lifecycle(monkeypatch)
    assert runtime.main(arguments(configuration)) == 0
    assert events.index('start') < events.index('signal')
    assert events.index('signal') < events.index('worker-close') < events.index('runtime-close')
    for value in (signal.SIGINT, signal.SIGTERM):
        assert handlers[value] == f'original-{value}'


@pytest.mark.parametrize('stage', ['start', 'close'])
def test_lifecycle_errors_are_static_and_all_resources_close(
        configuration, monkeypatch, capsys, stage):
    kwargs = {stage + '_error': RuntimeError('private-runtime-detail')}
    events, _handlers = install_lifecycle(monkeypatch, **kwargs)
    assert runtime.main(arguments(configuration)) == 1
    assert events.count('worker-close') == 1
    assert events.count('runtime-close') == 1
    assert 'private-runtime-detail' not in capsys.readouterr().err


def test_distinct_api_uid_requires_socket_group(configuration):
    values = arguments(configuration, '--check-config')
    values[values.index('--api-uid') + 1] = str(os.getuid() + 1)
    assert runtime.main(values) == 2
    assert runtime.main([*values, '--socket-gid', str(os.getgid())]) == 0


@pytest.mark.parametrize('target', ['docker', 'journal'])
def test_ipc_socket_cannot_alias_engine_or_live_inside_a_journal(
        configuration, target):
    value = json.loads(configuration.read_text())
    socket_path = (value['docker']['socketPath'] if target == 'docker'
                   else value['journals']['resources'] + '/worker.sock')
    values = arguments(configuration, '--check-config')
    values[values.index('--socket') + 1] = socket_path
    assert runtime.main(values) == 2


def test_help_and_module_entrypoint_do_not_observe_runtime(monkeypatch, capsys):
    monkeypatch.setattr(runtime, '_host_platform', lambda: pytest.fail('help must not inspect'))
    assert runtime.main(['--help']) == 0
    assert 'larenor-installation-worker' in capsys.readouterr().out

    import runpy
    monkeypatch.setattr('sys.argv', ['larenor-installation-worker', '--help'])
    with pytest.warns(RuntimeWarning, match='found in sys.modules'):
        with pytest.raises(SystemExit) as result:
            runpy.run_module('larenor_server.plugins.installation_runtime', run_name='__main__')
    assert result.value.code == 0
