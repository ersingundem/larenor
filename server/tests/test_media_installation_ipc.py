"""Separate Unix protocol for closed installation worker operations."""

from contextlib import contextmanager
from dataclasses import replace
import os
from pathlib import Path
import tempfile
import threading
import time

import pytest
from fastapi.testclient import TestClient

from conftest import auth, ready
from larenor_server.app import create_app
from larenor_server.config import Settings
from larenor_server.plugins.installation_execution import build_execution
from larenor_server.plugins.installation_ipc import (
    InstallationIPCError, InstallationWorkerClient, InstallationWorkerServer,
)
from larenor_server.plugins.jellyfin_bootstrap_executor import (
    JellyfinBootstrapExecutionError, JellyfinBootstrapExecutionResult,
)
from larenor_server.plugins.jellyfin_media_rows_executor import (
    JellyfinMediaRowsExecutionError,
)
from larenor_server.plugins.jellyfin_authenticated_readback import (
    JellyfinAuthenticatedReadbackResult,
)
from larenor_server.plugins.media_service_bootstrap_models import (
    PrivateMediaServiceBootstrap,
)
from larenor_server.plugins.media_rows_models import (
    MediaRowsReadback, PrivateJellyfinMediaRowsAuthority,
)
from larenor_server.plugins.worker import StepReceipt
from test_media_host_preflight import stack


API_KEY = 'c' * 32


def verified_readback():
    return JellyfinAuthenticatedReadbackResult(
        'verified', '3' * 32, 'Larenor Jellyfin', '10.11.0', '1' * 32, API_KEY,
        (('Filmler', 'movies', '4' * 32, ('/media/movies',)),),
        ('authenticated', 'keys_observed', 'key_verified',
         'system_verified', 'libraries_verified', 'session_closed'),
    )


class Backend:
    def __init__(self):
        self.calls = []

    def apply(self, step, component):
        self.calls.append(('apply', step, component))
        code = 'container_created' if step.kind == 'create_container' else 'container_started'
        return StepReceipt(step.job_id, step.kind, 'succeeded', code, '1' * 64)

    def reconcile(self, step, component):
        self.calls.append(('reconcile', step, component))
        return StepReceipt(step.job_id, step.kind, 'succeeded', 'container_created', '1' * 64)

    def bootstrap(self, job, component, private, *, deadline):
        self.calls.append(('bootstrap', job, component, private, deadline))
        return JellyfinBootstrapExecutionResult(
            'wiring_partial',
            ('observed_unconfigured', 'configuration_updated', 'user_updated',
             'remote_access_updated', 'wizard_completed'),
            verified_readback(),
        )

    def read_media_rows(self, private, *, deadline, gate):
        self.calls.append(('media_rows', private, deadline, gate))
        assert deadline > time.monotonic() and gate() is True
        return MediaRowsReadback(revision=7, recent=[], resume=[])


@contextmanager
def running():
    with tempfile.TemporaryDirectory(prefix='liw-', dir='/private/tmp' if Path('/private/tmp').is_dir() else '/tmp') as root:
        path = Path(root) / 'worker.sock'
        backend = Backend()
        server = InstallationWorkerServer(path, backend, allowed_uid=os.getuid(), peer_uid=lambda _: os.getuid())
        server.start()
        try:
            yield backend, InstallationWorkerClient(path, owner_uid=os.getuid(), peer_uid=lambda _: os.getuid(), timeout=.5)
        finally:
            server.close()


def test_roundtrip_transports_only_closed_step_and_verified_stack_plan():
    execution = build_execution(stack(), job_id='a' * 32, deadline=1788609900)
    with running() as (backend, client):
        assert client.status() == {'capability': 'container_execution', 'installAvailable': False,
                                   'services': [
                                       'jellyfin', 'qbittorrent',
                                       'sonarr', 'radarr', 'seerr',
                                       'music_assistant']}
        receipt = client.apply(execution.steps[0], execution.plan)
        assert receipt == StepReceipt('a' * 32, 'create_container', 'succeeded',
                                      'container_created', '1' * 64)
        assert backend.calls == [('apply', execution.steps[0], execution.plan)]


def test_roundtrip_accepts_only_plan_derived_seerr_step():
    execution = build_execution(
        stack(), job_id='a' * 32, deadline=1788609900,
        service_id='seerr')
    with running() as (backend, client):
        receipt = client.apply(execution.steps[0], execution.plan)
    assert receipt.job_id == 'a' * 32
    assert receipt.step == 'create_container'
    assert backend.calls == [('apply', execution.steps[0], execution.plan)]


def test_roundtrip_accepts_only_plan_derived_music_assistant_step():
    execution = build_execution(
        stack(), job_id='a' * 32, deadline=1788609900,
        service_id='music_assistant')
    with running() as (backend, client):
        receipt = client.apply(execution.steps[0], execution.plan)
    assert receipt.job_id == 'a' * 32
    assert backend.calls == [('apply', execution.steps[0], execution.plan)]


def test_bootstrap_roundtrip_transports_only_exact_private_contract():
    selected = stack()
    private = PrivateMediaServiceBootstrap(
        credential='Synthetic-bootstrap-secret-0123456789',
    )
    with running() as (backend, client):
        result = client.execute(
            'a' * 32, selected, private,
            deadline=time.monotonic() + 1,
            gate=lambda: True,
        )
    assert result.state == 'wiring_partial'
    assert result.completed_steps[-1] == 'wizard_completed'
    assert result.readback.api_key == API_KEY
    call = backend.calls[0]
    assert call[:3] == ('bootstrap', 'a' * 32, selected)
    assert call[3] == private and call[4] > time.monotonic() - 1
    assert private.credential not in repr(result) and API_KEY not in repr(result)


def media_rows_authority():
    return PrivateJellyfinMediaRowsAuthority(
        requestId='d' * 32,
        installationId='a' * 32,
        installationRevision=4,
        bootstrapRevision=3,
        bindingRevision=2,
        plan=stack(),
        apiKey=API_KEY,
        userId='1' * 32,
    )


def test_media_rows_roundtrip_keeps_private_authority_inside_worker_channel():
    private = media_rows_authority()
    with running() as (backend, client):
        result = client.read_media_rows(
            private,
            deadline=time.monotonic() + .4,
            gate=lambda: True,
        )

    assert result == MediaRowsReadback(revision=7, recent=[], resume=[])
    assert backend.calls[0][0] == 'media_rows'
    assert backend.calls[0][1] == private
    assert API_KEY not in repr(result) + repr(private)


def test_media_rows_static_worker_failure_roundtrip():
    private = media_rows_authority()
    with running() as (backend, client):
        backend.read_media_rows = lambda *_args, **_kwargs: (
            _ for _ in ()
        ).throw(JellyfinMediaRowsExecutionError(
            'jellyfin_media_rows_endpoint_changed'))
        with pytest.raises(
            JellyfinMediaRowsExecutionError,
            match='^jellyfin_media_rows_endpoint_changed$',
        ) as raised:
            client.read_media_rows(
                private,
                deadline=time.monotonic() + .4,
                gate=lambda: True,
            )

    assert API_KEY not in repr(raised.value)


@pytest.mark.parametrize('change', ['authority', 'deadline', 'gate'])
def test_invalid_media_rows_ipc_input_never_reaches_worker(change):
    values = {
        'authority': media_rows_authority(),
        'deadline': time.monotonic() + .4,
        'gate': lambda: True,
    }
    values[change] = {
        'authority': 'private',
        'deadline': True,
        'gate': 'gate',
    }[change]
    with running() as (backend, client):
        with pytest.raises(InstallationIPCError, match='^invalid_request$'):
            client.read_media_rows(**values)
    assert backend.calls == []


def test_media_rows_authority_loss_before_ipc_opens_no_worker_request():
    with running() as (backend, client):
        with pytest.raises(
            JellyfinMediaRowsExecutionError,
            match='^jellyfin_media_rows_authority_changed$',
        ):
            client.read_media_rows(
                media_rows_authority(),
                deadline=time.monotonic() + .4,
                gate=lambda: False,
            )
    assert backend.calls == []


def test_media_rows_authority_loss_after_ipc_discards_worker_result():
    decisions = iter((True, False))
    with running() as (backend, client):
        with pytest.raises(
            JellyfinMediaRowsExecutionError,
            match='^jellyfin_media_rows_authority_changed$',
        ):
            client.read_media_rows(
                media_rows_authority(),
                deadline=time.monotonic() + .4,
                gate=lambda: next(decisions),
            )
    assert backend.calls[0][0] == 'media_rows'


def test_media_rows_caller_deadline_bounds_ipc_and_maps_transport_failure():
    private = media_rows_authority()
    with running() as (backend, client):
        original = backend.read_media_rows

        def delayed(*args, **kwargs):
            time.sleep(.08)
            return original(*args, **kwargs)

        backend.read_media_rows = delayed
        with pytest.raises(
            JellyfinMediaRowsExecutionError,
            match='^jellyfin_media_rows_resources_unavailable$',
        ):
            client.read_media_rows(
                private,
                deadline=time.monotonic() + .02,
                gate=lambda: True,
            )


def test_media_rows_malformed_transport_failure_uses_typed_static_error(
    monkeypatch,
):
    with running() as (_backend, client):
        monkeypatch.setattr(
            client,
            '_exchange',
            lambda *_args, **_kwargs: (_ for _ in ()).throw(
                InstallationIPCError('invalid_worker_result')
            ),
        )
        with pytest.raises(
            JellyfinMediaRowsExecutionError,
            match='^jellyfin_media_rows_resources_unavailable$',
        ):
            client.read_media_rows(
                media_rows_authority(),
                deadline=time.monotonic() + .4,
                gate=lambda: True,
            )


def test_bootstrap_failure_roundtrip_preserves_only_static_partial_outcome():
    class FailedBackend(Backend):
        def bootstrap(self, job, component, private, *, deadline):
            self.calls.append(('bootstrap', job, component, private, deadline))
            raise JellyfinBootstrapExecutionError(
                'bootstrap_startup_failed',
                completed_steps=('observed_unconfigured',),
                uncertain_effect=True,
            )

    private = PrivateMediaServiceBootstrap(
        credential='Synthetic-bootstrap-secret-0123456789',
    )
    with tempfile.TemporaryDirectory(
        prefix='liw-', dir='/private/tmp' if Path('/private/tmp').is_dir() else '/tmp',
    ) as root:
        path = Path(root) / 'worker.sock'
        backend = FailedBackend()
        server = InstallationWorkerServer(
            path, backend, allowed_uid=os.getuid(),
            peer_uid=lambda _: os.getuid(), timeout=.5,
        )
        server.start()
        try:
            client = InstallationWorkerClient(
                path, owner_uid=os.getuid(), peer_uid=lambda _: os.getuid(),
                timeout=.5,
            )
            with pytest.raises(
                JellyfinBootstrapExecutionError,
                match='^bootstrap_startup_failed$',
            ) as raised:
                client.execute(
                    'a' * 32, stack(), private,
                    deadline=time.monotonic() + 1,
                    gate=lambda: True,
                )
        finally:
            server.close()
    assert raised.value.completed_steps == ('observed_unconfigured',)
    assert raised.value.uncertain_effect
    assert private.credential not in repr(raised.value)


@pytest.mark.parametrize('change', ['job', 'private', 'deadline', 'gate'])
def test_invalid_bootstrap_ipc_input_never_reaches_worker(change):
    values = {
        'job': 'a' * 32,
        'private': PrivateMediaServiceBootstrap(
            credential='Synthetic-bootstrap-secret-0123456789',
        ),
        'deadline': time.monotonic() + 1,
        'gate': lambda: True,
    }
    values[change] = {
        'job': 'bad', 'private': 'private', 'deadline': True, 'gate': 'gate',
    }[change]
    with running() as (backend, client):
        with pytest.raises(JellyfinBootstrapExecutionError):
            client.execute(values.pop('job'), stack(), **values)
    assert backend.calls == []


@pytest.mark.parametrize('gate', [lambda: False, lambda: (_ for _ in ()).throw(
    RuntimeError('private-authority-detail'))])
def test_bootstrap_authority_gate_fails_before_ipc(gate):
    private = PrivateMediaServiceBootstrap(
        credential='Synthetic-bootstrap-secret-0123456789',
    )
    with running() as (backend, client):
        with pytest.raises(
            JellyfinBootstrapExecutionError,
            match='^bootstrap_authority_changed$',
        ) as raised:
            client.execute(
                'a' * 32, stack(), private,
                deadline=time.monotonic() + 1,
                gate=gate,
            )
    assert backend.calls == []
    assert private.credential not in repr(raised.value)


def test_backend_lifecycle_and_effects_share_the_server_native_thread():
    execution = build_execution(stack(), job_id='a' * 32, deadline=1788609900)
    events = []

    class LifecycleBackend(Backend):
        def open(self, deadline):
            assert time.monotonic() < deadline
            events.append(('open', threading.get_native_id()))

        def close(self):
            events.append(('close', threading.get_native_id()))

        def apply_with_deadline(self, step, plan, deadline):
            assert time.monotonic() < deadline
            events.append(('apply', threading.get_native_id()))
            return super().apply(step, plan)

    with tempfile.TemporaryDirectory(prefix='liw-', dir='/private/tmp' if Path('/private/tmp').is_dir() else '/tmp') as root:
        path = Path(root) / 'worker.sock'
        backend = LifecycleBackend()
        server = InstallationWorkerServer(path, backend, allowed_uid=os.getuid(),
                                          peer_uid=lambda _: os.getuid(), timeout=.5)
        server.start()
        try:
            client = InstallationWorkerClient(path, owner_uid=os.getuid(),
                                              peer_uid=lambda _: os.getuid(), timeout=.5)
            client.apply(execution.steps[0], execution.plan)
        finally:
            server.close()

    assert [event[0] for event in events] == ['open', 'apply', 'close']
    assert len({event[1] for event in events}) == 1


def test_backend_open_failure_prevents_server_start_and_removes_socket(tmp_path):
    class FailedBackend(Backend):
        def open(self, _deadline):
            raise RuntimeError('private-start-detail')

    path = tmp_path / 'worker.sock'
    server = InstallationWorkerServer(path, FailedBackend(), allowed_uid=os.getuid(),
                                      peer_uid=lambda _: os.getuid(), timeout=.2)
    with pytest.raises(Exception, match='^worker_unavailable$'):
        server.start()
    assert not path.exists()


def test_client_rejects_wrong_peer_and_forged_plan_before_effect():
    execution = build_execution(stack(), job_id='a' * 32, deadline=1788609900)
    with running() as (backend, client):
        client.peer_uid = lambda _: os.getuid() + 1
        with pytest.raises(InstallationIPCError, match='^worker_unavailable$'):
            client.apply(execution.steps[0], execution.plan)
        assert backend.calls == []


def test_settings_keep_readonly_and_mutating_worker_channels_separate(tmp_path, monkeypatch):
    preflight = tmp_path / 'preflight.sock'
    execution = tmp_path / 'execution.sock'
    monkeypatch.setenv('LARENOR_PLUGIN_WORKER_SOCKET', str(preflight))
    monkeypatch.setenv('LARENOR_INSTALLATION_WORKER_SOCKET', str(execution))
    monkeypatch.setenv('LARENOR_INSTALLATION_WORKER_UID', str(os.getuid()))
    settings = Settings.from_environment()
    assert settings.plugin_worker_socket == preflight
    assert settings.installation_worker_socket == execution
    assert settings.installation_worker_uid == os.getuid()
    with pytest.raises(ValueError, match='^invalid_worker_configuration$'):
        replace(settings, installation_worker_socket=preflight)


def test_core_enables_execution_only_from_the_separate_installation_channel(server):
    _app, client, settings, _clock = server
    pair = ready(server)
    assert client.get('/api/v1/admin/media/installations/capabilities',
                      headers=auth(pair)).json()['executionConfigured'] is False

    with running() as (_backend, worker):
        configured = replace(
            settings,
            installation_worker_socket=worker.path,
            installation_worker_uid=os.getuid(),
        )
        with TestClient(create_app(configured)) as reopened:
            assert reopened.get(
                '/api/v1/admin/media/installations/capabilities',
                headers=auth(pair),
            ).json() == {
                'executionConfigured': True,
                'installAvailable': False,
                    'services': ['jellyfin', 'seerr', 'music_assistant'],
            }


def test_durable_coordinator_reaches_supervised_worker_over_real_unix_ipc(
        server, monkeypatch):
    from test_media_service_bootstraps import BASE, installed, request

    _app, client, settings, _clock = server
    pair, installation = installed(server)
    queued = client.post(
        BASE, headers=auth(pair), json=request(installation),
    ).json()['bootstrap']
    monkeypatch.setattr(
        'larenor_server.plugins.preflight_ipc._peer_uid',
        lambda _connection: os.getuid(),
    )

    with running() as (backend, worker):
        configured = replace(
            settings,
            installation_worker_socket=worker.path,
            installation_worker_uid=os.getuid(),
        )
        with TestClient(create_app(configured)) as reopened:
            assert reopened.app.state.media_service_bootstrap_dispatcher is not None
            end = time.monotonic() + 5
            while True:
                terminal = reopened.get(
                    BASE + '/' + queued['id'], headers=auth(pair),
                ).json()['bootstrap']
                if terminal['state'] not in {'queued', 'running'}:
                    break
                assert time.monotonic() < end
                time.sleep(.025)

    assert terminal == queued | {
        'revision': 3, 'state': 'wiring_partial',
        'credentialsConfigured': True, 'wiringState': 'partial',
    }
    assert backend.calls[0][0] == 'bootstrap'
    assert backend.calls[0][1] == installation['id']
