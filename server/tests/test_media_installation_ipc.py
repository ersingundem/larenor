"""Separate Unix protocol for closed installation worker operations."""

from contextlib import contextmanager
from dataclasses import replace
import os
from pathlib import Path
import tempfile

import pytest
from fastapi.testclient import TestClient

from conftest import auth, ready
from larenor_server.app import create_app
from larenor_server.config import Settings
from larenor_server.plugins.installation_execution import build_execution
from larenor_server.plugins.installation_ipc import (
    InstallationIPCError, InstallationWorkerClient, InstallationWorkerServer,
)
from larenor_server.plugins.worker import StepReceipt
from test_media_host_preflight import stack


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


def test_roundtrip_transports_only_closed_step_and_verified_component():
    execution = build_execution(stack(), job_id='a' * 32, deadline=1788609900)
    with running() as (backend, client):
        assert client.status() == {'capability': 'container_execution', 'installAvailable': False,
                                   'services': ['jellyfin']}
        receipt = client.apply(execution.steps[0], execution.component)
        assert receipt == StepReceipt('a' * 32, 'create_container', 'succeeded',
                                      'container_created', '1' * 64)
        assert backend.calls == [('apply', execution.steps[0], execution.component)]


def test_client_rejects_wrong_peer_and_forged_component_before_effect():
    execution = build_execution(stack(), job_id='a' * 32, deadline=1788609900)
    with running() as (backend, client):
        client.peer_uid = lambda _: os.getuid() + 1
        with pytest.raises(InstallationIPCError, match='^worker_unavailable$'):
            client.apply(execution.steps[0], execution.component)
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
                'services': ['jellyfin'],
            }
