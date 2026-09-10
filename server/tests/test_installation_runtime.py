"""Packaged mutation worker policy and process lifecycle."""

import json
import os
from pathlib import Path
import signal
import socket
import threading
import time
from types import SimpleNamespace

import pytest

from larenor_server.plugins import installation_runtime as runtime
from larenor_server.plugins.managed_container import ManagedWorkerJournal
from larenor_server.plugins.resource_journal import ResourceJournal
from larenor_server.plugins.volume_create_journal import VolumeCreateJournal
from larenor_server.context import ContextResponse
from larenor_server.plugins.catalog import load_catalog
from larenor_server.plugins.installation_execution import build_execution
from larenor_server.plugins.qbittorrent_config_effect import (
    QbittorrentConfigInstallReceipt,
)
from larenor_server.plugins.qbittorrent_bootstrap_executor import (
    QbittorrentBootstrapExecutionError, QbittorrentBootstrapExecutionResult,
)
from larenor_server.plugins.qbittorrent_authenticated_readback import (
    QbittorrentAuthenticatedReadbackResult,
)
from larenor_server.plugins.qbittorrent_managed_categories import (
    QbittorrentManagedCategoriesResult,
)
from larenor_server.plugins.qbittorrent_readback import QbittorrentReadback
from larenor_server.plugins.stack_plan import build_media_stack_plan
from larenor_server.plugins.worker import StepReceipt


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
        assert built.backend.bootstrap_executor.operations is built.backend.operations
        assert built.backend.bootstrap_executor.binding_builder is built.backend.binding_builder
        assert (built.backend.qbittorrent_installation.binding_builder
                is built.backend.binding_builder)
        assert (built.backend.qbittorrent_installation.operations
                is built.backend.operations)
        assert built.backend.qbittorrent_config._endpoint is policy.endpoint
        assert built.backend.qbittorrent_config._journal is built.backend.binding_builder._volume_journal
        assert built.backend.arr_config._endpoint is policy.endpoint
        assert (built.backend.arr_config._journal
                is built.backend.binding_builder._volume_journal)
    finally:
        built.close()
    assert built.closed is True


def test_runtime_configures_qbittorrent_before_create_and_start(monkeypatch):
    events = []
    receipt = QbittorrentConfigInstallReceipt(
        '1' * 32, '2' * 32, '3' * 32, 3,
        'larenor-appdata-v1-' + '1' * 32, '4' * 64,
        'qbittorrent_config_installed')

    class Configuration:
        def install(self, stack, credential, **kwargs):
            events.append(('configure', stack, credential, kwargs))
            return receipt

    class Operations:
        def apply(self, step, binding):
            events.append(
                ('apply', step.kind, binding, step.start_deadline))
            code = ('container_created' if step.kind == 'create_container'
                    else 'container_started')
            return StepReceipt(
                step.job_id, step.kind, 'succeeded', code, '5' * 64)

        def reconcile(self, job, kind, binding):
            raise AssertionError('successful effects are not reconciled')

    def binding(stack, service_id='jellyfin'):
        events.append(('binding', service_id))
        return 'binding-' + service_id

    verified = QbittorrentBootstrapExecutionResult(
        'verified',
        QbittorrentManagedCategoriesResult(
            'verified',
            (('movies', '/data/downloads/movies'),
             ('tv', '/data/downloads/tv')),
            ('categories_observed', 'categories_verified')),
        QbittorrentAuthenticatedReadbackResult(
            'verified', 'v5.2.3',
            QbittorrentReadback(
                'verified', 'larenor-system', 8080, 6881,
                '/data/downloads', '/data/incomplete',
                (('movies', '/data/downloads/movies'),
                 ('tv', '/data/downloads/tv'))),
            ('version_verified', 'preferences_verified',
             'categories_verified')))

    class QbittorrentBootstrap:
        def execute(self, *args, **kwargs):
            events.append(('bootstrap', args, kwargs))
            return verified

    stack = build_media_stack_plan(
        load_catalog(), {}, 'linux/amd64',
        ContextResponse(
            schemaVersion=1, coreId='a' * 32, homeId='b' * 32),
        'c' * 32)
    monkeypatch.setattr(
        runtime, 'JellyfinBootstrapExecutor', lambda *_args: object())
    monkeypatch.setattr(
        runtime, 'QbittorrentBootstrapExecutor',
        lambda *_args: QbittorrentBootstrap())
    monkeypatch.setattr(
        runtime, 'ArrBootstrapExecutor', lambda *_args: object())
    monkeypatch.setattr(
        runtime, 'SeerrBootstrapExecutor', lambda *_args: object())
    monkeypatch.setattr(runtime.time, 'monotonic', lambda: 1000.0)
    monkeypatch.setattr(runtime.time, 'time', lambda: 2000.0)
    backend = runtime._RuntimeBackend(
        Operations(), binding, Configuration(), object())
    result = backend.install_configured_qbittorrent(
        'd' * 32, stack, 'c' * 48,
        api_key='qbt_' + 'a' * 28, salt=b'1' * 16,
        cancelled=threading.Event(), deadline=1030.0,
        gate=lambda: True)
    assert result.configuration == receipt
    assert result.state == 'qbittorrent_container_started'
    assert result.container_id == '5' * 64
    assert result.service_state == 'qbittorrent_service_verified'
    assert [event[0] for event in events] == [
        'configure', 'binding', 'apply', 'binding', 'apply', 'bootstrap']
    assert [event[1] for event in events if event[0] == 'binding'] == [
        'qbittorrent', 'qbittorrent']
    assert [event[3] for event in events if event[0] == 'apply'] == [
        2030.0, 2030.0]


def test_runtime_routes_plan_derived_seerr_steps_to_seerr_backend():
    stack = build_media_stack_plan(
        load_catalog(), {}, 'linux/amd64',
        ContextResponse(
            schemaVersion=1, coreId='a' * 32, homeId='b' * 32),
        'c' * 32)
    execution = build_execution(
        stack, job_id='d' * 32, deadline=1788609900,
        service_id='seerr')
    calls = []

    class Selected:
        def apply(self, step, plan):
            calls.append(('apply', step, plan))
            return 'applied'

        def reconcile(self, step, plan):
            calls.append(('reconcile', step, plan))
            return 'reconciled'

    class Rejected:
        def apply(self, *_args):
            raise AssertionError('Jellyfin backend must not receive Seerr')

        def reconcile(self, *_args):
            raise AssertionError('Jellyfin backend must not receive Seerr')

    backend = object.__new__(runtime._RuntimeBackend)
    backend.installation = Rejected()
    backend.seerr_installation = Selected()

    assert backend.apply(execution.steps[0], execution.plan) == 'applied'
    assert backend.reconcile(
        execution.steps[0], execution.plan) == 'reconciled'
    assert [item[0] for item in calls] == ['apply', 'reconcile']


def test_runtime_routes_plan_derived_music_assistant_steps_to_its_backend():
    stack = build_media_stack_plan(
        load_catalog(), {}, 'linux/amd64',
        ContextResponse(schemaVersion=1, coreId='a' * 32, homeId='b' * 32),
        'c' * 32)
    execution = build_execution(
        stack, job_id='d' * 32, deadline=1788609900,
        service_id='music_assistant')
    calls = []

    class Selected:
        def apply(self, step, plan):
            calls.append(('apply', step, plan))
            return 'applied'

        def reconcile(self, step, plan):
            calls.append(('reconcile', step, plan))
            return 'reconciled'

    backend = object.__new__(runtime._RuntimeBackend)
    backend.installation = SimpleNamespace(
        apply=lambda *_: pytest.fail('wrong backend'),
        reconcile=lambda *_: pytest.fail('wrong backend'))
    backend.seerr_installation = backend.installation
    backend.music_assistant_installation = Selected()

    assert backend.apply(execution.steps[0], execution.plan) == 'applied'
    assert backend.reconcile(execution.steps[0], execution.plan) == 'reconciled'
    assert [item[0] for item in calls] == ['apply', 'reconcile']


def test_runtime_owns_music_assistant_first_run_inside_authority_gates():
    from larenor_server.plugins.music_assistant_core_models import (
        AuthenticatedMusicAssistantReadback,
    )

    calls = []
    expected = AuthenticatedMusicAssistantReadback(
        token='private-long-token', serverId='mass-fixture',
        serverVersion='2.10.2', schemaVersion=65)

    class Bootstrap:
        def create(self, **kwargs):
            calls.append(('create', kwargs))
            return expected

    backend = object.__new__(runtime._RuntimeBackend)
    backend.music_assistant_bootstrap = Bootstrap()

    def gate():
        calls.append(('gate',))
        return True

    result = backend.bootstrap_music_assistant(
        'a' * 32, 'larenor-core', 'S' * 48,
        deadline=time.monotonic() + 2, gate=gate)

    assert result == expected
    assert [call[0] for call in calls] == ['gate', 'create', 'gate']
    assert calls[1][1]['installation_id'] == 'a' * 32
    assert calls[1][1]['username'] == 'larenor-core'
    assert calls[1][1]['credential'] == 'S' * 48


@pytest.mark.parametrize('bootstrap_code,public_code', [
    ('qbittorrent_bootstrap_authority_changed',
     'qbittorrent_config_authority_changed'),
    ('qbittorrent_bootstrap_endpoint_unavailable',
     'qbittorrent_service_unavailable'),
    ('qbittorrent_bootstrap_endpoint_changed',
     'qbittorrent_service_changed'),
    ('qbittorrent_bootstrap_timeout', 'qbittorrent_config_timeout'),
    ('qbittorrent_bootstrap_readback_failed',
     'qbittorrent_service_verification_failed'),
])
def test_runtime_projects_bootstrap_failure_as_static_uncertain_result(
        monkeypatch, bootstrap_code, public_code):
    receipt = QbittorrentConfigInstallReceipt(
        '1' * 32, '2' * 32, '3' * 32, 3,
        'larenor-appdata-v1-' + '1' * 32, '4' * 64,
        'qbittorrent_config_installed')

    def failed(*_args, **_kwargs):
        raise QbittorrentBootstrapExecutionError(
            bootstrap_code,
            cause_code=('qbittorrent_readback_protocol'
                        if bootstrap_code
                        == 'qbittorrent_bootstrap_readback_failed'
                        else None))

    backend = object.__new__(runtime._RuntimeBackend)
    backend.qbittorrent_config = SimpleNamespace(
        install=lambda *_args, **_kwargs: receipt)
    backend.qbittorrent_installation = object()
    backend.qbittorrent_bootstrap = SimpleNamespace(execute=failed)
    monkeypatch.setattr(
        runtime, 'build_execution',
        lambda *_args, **_kwargs: SimpleNamespace(
            run=lambda *_run_args: runtime.ExecutionResult(
                'succeeded', 'container_started', '5' * 64)))
    with pytest.raises(
        runtime.QbittorrentConfigurationExecutionError,
        match='^' + public_code + '$',
    ) as raised:
        backend.install_configured_qbittorrent(
            'd' * 32, object(), 'c' * 48,
            api_key='qbt_' + 'a' * 28, salt=b'1' * 16,
            cancelled=threading.Event(), deadline=time.monotonic() + 30,
            gate=lambda: True)
    assert raised.value.uncertain_effect
    assert raised.value.cause_code == (
        'qbittorrent_readback_protocol'
        if bootstrap_code == 'qbittorrent_bootstrap_readback_failed'
        else None)


def test_runtime_projects_unexpected_bootstrap_failure_with_static_boundary(
        monkeypatch):
    receipt = QbittorrentConfigInstallReceipt(
        '1' * 32, '2' * 32, '3' * 32, 3,
        'larenor-appdata-v1-' + '1' * 32, '4' * 64,
        'qbittorrent_config_installed')

    def failed(*_args, **_kwargs):
        raise QbittorrentBootstrapExecutionError(
            'qbittorrent_bootstrap_resources_unavailable',
            boundary='after_categories',
            cause_code='qbittorrent_bootstrap_unexpected')

    backend = object.__new__(runtime._RuntimeBackend)
    backend.qbittorrent_config = SimpleNamespace(
        install=lambda *_args, **_kwargs: receipt)
    backend.qbittorrent_installation = object()
    backend.qbittorrent_bootstrap = SimpleNamespace(execute=failed)
    monkeypatch.setattr(
        runtime, 'build_execution',
        lambda *_args, **_kwargs: SimpleNamespace(
            run=lambda *_run_args: runtime.ExecutionResult(
                'succeeded', 'container_started', '5' * 64)))

    with pytest.raises(
        runtime.QbittorrentConfigurationExecutionError,
        match='^qbittorrent_service_verification_failed$',
    ) as raised:
        backend.install_configured_qbittorrent(
            'd' * 32, object(), 'c' * 48,
            api_key='qbt_' + 'a' * 28, salt=b'1' * 16,
            cancelled=threading.Event(), deadline=time.monotonic() + 30,
            gate=lambda: True)

    assert raised.value.uncertain_effect
    assert raised.value.cause_code == (
        'qbittorrent_bootstrap_after_categories_failed')


@pytest.mark.parametrize('state,code,cause', [
    ('pending', 'worker_unavailable',
     'qbittorrent_execution_worker_unavailable'),
    ('failed', 'invalid_worker_result',
     'qbittorrent_execution_invalid_worker_result'),
    ('needs_attention', 'resource_conflict',
     'qbittorrent_execution_resource_conflict'),
    ('needs_attention', 'container_not_running',
     'qbittorrent_execution_container_not_running'),
    ('needs_attention', 'dispatch_expired',
     'qbittorrent_execution_dispatch_expired'),
])
def test_runtime_projects_invalid_execution_result_as_static_cause(
        monkeypatch, state, code, cause):
    receipt = QbittorrentConfigInstallReceipt(
        '1' * 32, '2' * 32, '3' * 32, 3,
        'larenor-appdata-v1-' + '1' * 32, '4' * 64,
        'qbittorrent_config_installed')
    backend = object.__new__(runtime._RuntimeBackend)
    backend.qbittorrent_config = SimpleNamespace(
        install=lambda *_args, **_kwargs: receipt)
    backend.qbittorrent_installation = object()
    monkeypatch.setattr(
        runtime, 'build_execution',
        lambda *_args, **_kwargs: SimpleNamespace(
            run=lambda *_run_args: runtime.ExecutionResult(state, code)))

    with pytest.raises(
        runtime.QbittorrentConfigurationExecutionError,
        match='^qbittorrent_config_result_invalid$',
    ) as raised:
        backend.install_configured_qbittorrent(
            'd' * 32, object(), 'c' * 48,
            api_key='qbt_' + 'a' * 28, salt=b'1' * 16,
            cancelled=threading.Event(), deadline=time.monotonic() + 30,
            gate=lambda: True)

    assert raised.value.uncertain_effect
    assert raised.value.cause_code == cause


def test_runtime_closes_unexpected_qbittorrent_configure_failure():
    backend = object.__new__(runtime._RuntimeBackend)
    backend.qbittorrent_config = SimpleNamespace(
        install=lambda *_args, **_kwargs: (_ for _ in ()).throw(
            RuntimeError('private failure')))

    with pytest.raises(
        runtime.QbittorrentConfigurationExecutionError,
        match='^qbittorrent_config_resources_unavailable$',
    ) as raised:
        backend.install_configured_qbittorrent(
            'd' * 32, object(), 'c' * 48,
            api_key='qbt_' + 'a' * 28, salt=b'1' * 16,
            cancelled=threading.Event(), deadline=time.monotonic() + 30,
            gate=lambda: True)

    assert raised.value.cause_code == 'qbittorrent_configure_stage_failed'
    assert 'private failure' not in repr(raised.value)


def test_runtime_routes_every_engine_connection_through_one_peer_verifier(configuration):
    policy = runtime.load_policy(configuration)
    verifier = lambda _connection: policy.endpoint.owner_uid
    built = runtime._build_runtime(policy, peer_uid=verifier)
    try:
        readers = built.backend.binding_builder._readers
        assert readers._images._peer_uid is verifier
        assert readers._volumes._http._peer_uid is verifier
        assert readers._networks._http._peer_uid is verifier
        assert readers._bootstrap._engine._transport.peer_uid is verifier
        assert built.backend.operations.engine.peer_uid is verifier
        qbit = built.backend.qbittorrent_config._installer._engine
        assert qbit._transport.peer_uid is verifier
        assert qbit._stdin._peer_uid is verifier
        arr = built.backend.arr_config._installer._engine
        assert arr._transport.peer_uid is verifier
        assert arr._stdin._peer_uid is verifier
    finally:
        built.close()


def test_runtime_backend_routes_only_valid_jobs_to_arr_config():
    calls = []
    backend = object.__new__(runtime._RuntimeBackend)
    backend.arr_config = SimpleNamespace(
        install=lambda *args, **kwargs: calls.append((args, kwargs)) or 'done')
    cancelled = threading.Event()
    gate = lambda: True

    assert backend.configure_arr(
        'd' * 32, 'stack', 'radarr', api_key='a' * 32,
        cancelled=cancelled, deadline=1000.0, gate=gate) == 'done'
    assert calls == [(('stack', 'radarr'), {
        'api_key': 'a' * 32,
        'cancelled': cancelled,
        'before_dispatch': gate,
    })]

    with pytest.raises(ValueError, match='^invalid_worker_result$'):
        backend.configure_arr(
            'foreign', 'stack', 'sonarr', api_key='a' * 32,
            cancelled=cancelled, deadline=1000.0, gate=gate)
    assert len(calls) == 1


def test_core_uses_the_same_private_worker_channel_for_bootstrap(server, monkeypatch):
    from dataclasses import replace
    from fastapi.testclient import TestClient
    from conftest import auth, ready
    from larenor_server.app import create_app

    _app, _client, settings, _clock = server
    pair = ready(server)
    path = settings.data_dir / 'synthetic-installation.sock'

    class Client:
        def __init__(self, selected, **kwargs):
            assert selected == path and kwargs['owner_uid'] == 0

        def execute(self, *_args, **_kwargs):
            raise AssertionError('startup must not dispatch queued work')

    monkeypatch.setattr('larenor_server.core.InstallationWorkerClient', Client)
    with TestClient(create_app(replace(settings, installation_worker_socket=path))) as reopened:
        manager = reopened.app.state.core.media_service_bootstraps
        assert type(manager.backend) is Client
        assert reopened.get('/api/v1/admin/media/bootstraps', headers=auth(pair)).status_code == 200


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
    monkeypatch.setattr(runtime, '_build_runtime', lambda policy, **_kwargs: Built())
    monkeypatch.setattr(runtime, 'SupervisedInstallationBackend',
                        lambda _endpoint, backend, **kwargs:
                        backend if kwargs['platform'] == 'linux/amd64' else None)

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


def test_runtime_configures_arr_before_create_start_and_readback(monkeypatch):
    from larenor_server.plugins.arr_config_effect import ArrConfigInstallReceipt
    from larenor_server.plugins.arr_bootstrap_executor import ArrBootstrapExecutionResult
    from larenor_server.plugins.arr_authenticated_readback import ArrAuthenticatedReadbackResult
    from larenor_server.plugins.arr_managed_root_folders import ArrManagedRootFoldersResult
    events=[]
    configured=ArrConfigInstallReceipt('sonarr','1'*32,'2'*32,'3'*32,3,'larenor-appdata-v1-'+'1'*32,'4'*64,'sonarr_config_installed')
    class Configuration:
        def install(self, stack, service, **kwargs): events.append(('configure',service)); return configured
    class Operations:
        def apply(self,step,binding): events.append(('apply',step.kind,binding)); return StepReceipt(step.job_id,step.kind,'succeeded','container_created' if step.kind=='create_container' else 'container_started','5'*64)
        def reconcile(self,*args): raise AssertionError()
    class Bootstrap:
        def execute(self,*args,**kwargs): events.append(('readback',args[2].serviceId,args[2].qbittorrentApiKey)); return ArrBootstrapExecutionResult('verified','sonarr',ArrManagedRootFoldersResult('verified','sonarr','/data/shows',('root_folders_observed','root_folder_verified')),ArrAuthenticatedReadbackResult('verified','sonarr','Sonarr','4.0.19.2979'))
    monkeypatch.setattr(runtime,'JellyfinBootstrapExecutor',lambda *_:object())
    monkeypatch.setattr(runtime,'QbittorrentBootstrapExecutor',lambda *_:object())
    monkeypatch.setattr(runtime,'ArrBootstrapExecutor',lambda *_:Bootstrap())
    monkeypatch.setattr(runtime,'SeerrBootstrapExecutor',lambda *_:object())
    monkeypatch.setattr(runtime.time,'monotonic',lambda:1000.0); monkeypatch.setattr(runtime.time,'time',lambda:2000.0)
    stack=build_media_stack_plan(load_catalog(),{},'linux/amd64',ContextResponse(schemaVersion=1,coreId='a'*32,homeId='b'*32),'c'*32)
    backend=runtime._RuntimeBackend(Operations(),lambda _s,service:'binding-'+service,object(),Configuration())
    value=backend.install_configured_arr('d'*32,stack,'sonarr',api_key='a'*32,qbittorrent_api_key='qbt_'+'A'*28,cancelled=threading.Event(),deadline=1030.0,gate=lambda:True)
    assert value.configuration==configured and value.container_id=='5'*64
    assert value.state=='sonarr_container_started' and value.service_state=='sonarr_service_verified'
    assert events==[('configure','sonarr'),('apply','create_container','binding-sonarr'),('apply','start_container','binding-sonarr'),('readback','sonarr','qbt_'+'A'*28)]


def _arr_runtime_backend(monkeypatch, execution_result, bootstrap):
    from larenor_server.plugins.arr_config_effect import ArrConfigInstallReceipt

    configured = ArrConfigInstallReceipt(
        'sonarr', '1' * 32, '2' * 32, '3' * 32, 3,
        'larenor-appdata-v1-' + '1' * 32, '4' * 64,
        'sonarr_config_installed',
    )
    backend = object.__new__(runtime._RuntimeBackend)
    backend.arr_config = SimpleNamespace(
        install=lambda *_args, **_kwargs: configured)
    backend.operations = object()
    backend.binding_builder = lambda *_args: object()
    backend.arr_bootstrap = SimpleNamespace(execute=bootstrap)
    monkeypatch.setattr(
        runtime,
        'build_execution',
        lambda *_args, **_kwargs: SimpleNamespace(
            run=lambda *_run_args: execution_result),
    )
    monkeypatch.setattr(
        runtime, 'ArrWorkerBackend', lambda *_args, **_kwargs: object())
    return backend


@pytest.mark.parametrize(('state', 'cause', 'public_code', 'diagnostic'), [
    ('needs_attention', 'authority_changed', 'arr_config_authority_changed',
     'arr_execution_authority_changed'),
    ('cancelled', 'cancelled', 'arr_config_authority_changed',
     'arr_execution_cancelled'),
    ('pending', 'worker_unavailable', 'arr_config_resources_unavailable',
     'arr_execution_worker_unavailable'),
    ('needs_attention', 'resource_conflict',
     'arr_config_resources_unavailable', 'arr_execution_resource_conflict'),
    ('failed', 'invalid_worker_result', 'arr_config_result_invalid',
     'arr_execution_invalid_worker_result'),
])
def test_arr_runtime_projects_execution_failures_to_closed_uncertain_codes(
        monkeypatch, state, cause, public_code, diagnostic):
    def forbidden(*_args, **_kwargs):
        pytest.fail('failed container execution must not start readback')

    backend = _arr_runtime_backend(
        monkeypatch, runtime.ExecutionResult(state, cause), forbidden)

    with pytest.raises(
            runtime.ArrConfigurationExecutionError,
            match='^' + public_code + '$') as raised:
        backend.install_configured_arr(
            'd' * 32, object(), 'sonarr', api_key='a' * 32,
            cancelled=threading.Event(), deadline=time.monotonic() + 30,
            gate=lambda: True,
        )

    assert raised.value.uncertain_effect
    assert raised.value.cause_code == diagnostic


@pytest.mark.parametrize(('bootstrap_code', 'public_code'), [
    ('arr_bootstrap_authority_changed', 'arr_config_authority_changed'),
    ('arr_bootstrap_timeout', 'arr_config_timeout'),
    ('arr_bootstrap_resources_unavailable',
     'arr_config_resources_unavailable'),
    ('arr_bootstrap_endpoint_unavailable',
     'arr_config_resources_unavailable'),
    ('arr_bootstrap_endpoint_changed', 'arr_config_result_invalid'),
    ('arr_bootstrap_wiring_failed', 'arr_config_result_invalid'),
    ('arr_bootstrap_readback_failed', 'arr_config_result_invalid'),
])
def test_arr_runtime_projects_bootstrap_failures_to_closed_uncertain_codes(
        monkeypatch, bootstrap_code, public_code):
    def failed(*_args, **_kwargs):
        raise runtime.ArrBootstrapExecutionError(bootstrap_code)

    backend = _arr_runtime_backend(
        monkeypatch,
        runtime.ExecutionResult('succeeded', 'container_started', '5' * 64),
        failed,
    )

    with pytest.raises(
            runtime.ArrConfigurationExecutionError,
            match='^' + public_code + '$') as raised:
        backend.install_configured_arr(
            'd' * 32, object(), 'sonarr', api_key='a' * 32,
            cancelled=threading.Event(), deadline=time.monotonic() + 30,
            gate=lambda: True,
        )

    assert raised.value.uncertain_effect
    assert raised.value.cause_code == bootstrap_code
