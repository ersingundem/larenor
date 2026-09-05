"""Actual HTTP -> encrypted history -> Unix worker -> host observations."""
import json
import os
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
from uuid import UUID

from fastapi.testclient import TestClient

from conftest import Clock, auth, ready
from larenor_server.app import create_app
from larenor_server.config import Settings
from larenor_server.plugins.host_preflight import HostInspector, HostPolicy, HostRoot
from larenor_server.plugins.preflight_ipc import PreflightWorkerClient, PreflightWorkerServer
from test_media_preparations_api import create_preparation
from test_plugin_preflight_ipc import root as worker_root


BASE = '/api/v1/admin/media/inspections'
FIXTURE = Path(__file__).resolve().parents[2] / 'contracts/media-inspections.v1.json'


def actual_contract(root):
    identities = iter(('a'*32, 'b'*32))
    clock = Clock()
    settings = Settings(root/'state', root/'secrets/vault.key', clock=clock)
    paths = {}
    for name, purpose in [('appdata', 'data'), ('library', 'library')]:
        path = root/name
        path.mkdir(parents=True, mode=0o700)
        paths[name] = HostRoot(str(path), purpose)
    inspector = HostInspector(HostPolicy(paths), platform_provider=lambda: 'linux/amd64',
        clock=clock, statvfs_provider=lambda _: SimpleNamespace(f_bavail=16384, f_frsize=1048576, f_flag=0))
    with worker_root() as directory:
        worker = PreflightWorkerServer(directory/'worker.sock', inspector, platform='linux/amd64',
            allowed_uid=os.getuid(), peer_uid=lambda _: os.getuid())
        worker.start()
        try:
            backend = PreflightWorkerClient(worker.path, owner_uid=os.getuid(), peer_uid=lambda _: os.getuid())
            with patch('larenor_server.context.secrets', SimpleNamespace(token_hex=lambda _: next(identities))):
                app = create_app(settings)
                with TestClient(app) as client:
                    pair = ready((app, client, settings, clock))
                    with patch('larenor_server.plugins.media_preparations.uuid', SimpleNamespace(uuid4=lambda: UUID(hex='c'*32))):
                        _, prep = create_preparation(client, pair)
                    app.state.core.media_inspections.backend = backend
                    capabilities = client.get(BASE+'/capabilities', headers=auth(pair)).json()
                    request = {'requestId': 'd'*32, 'preparationId': prep['id'], 'expectedRevision': 1, 'planHash': prep['plan']['planHash']}
                    with patch('larenor_server.plugins.media_inspections.uuid', SimpleNamespace(uuid4=lambda: UUID(hex='1'*32))):
                        response = client.post(BASE, headers=auth(pair), json=request)
                    assert response.status_code == 201
                    queued = response.json()['inspection']
                # Resume a persisted queued inspection after a complete Core restart.
                restarted = create_app(settings)
                with TestClient(restarted) as client:
                    restarted.state.core.media_inspections.backend = backend
                    assert client.get(BASE+'/'+queued['id'], headers=auth(pair)).json()['inspection'] == queued
                    restarted.state.core.media_inspections.tick()
                    succeeded = client.get(BASE+'/'+queued['id'], headers=auth(pair)).json()['inspection']
                    assert succeeded['state'] == 'succeeded'
                    assert next(c for c in succeeded['result']['checks'] if c['code'] == 'storage_capacity')['requiredMiB'] == 49152
                    assert next(c for c in succeeded['result']['checks'] if c['code'] == 'storage_capacity')['status'] == 'failed'
                    second_request = request | {'requestId': 'e'*32}
                    with patch('larenor_server.plugins.media_inspections.uuid', SimpleNamespace(uuid4=lambda: UUID(hex='2'*32))):
                        second = client.post(BASE, headers=auth(pair), json=second_request)
                    assert second.status_code == 201
                    queued_cancel = second.json()['inspection']
                    response = client.post(BASE+'/'+queued_cancel['id']+'/cancel', headers=auth(pair), json={'expectedRevision': 1})
                    assert response.status_code == 200
                    cancelled = response.json()['inspection']
                    history = client.get(BASE, headers=auth(pair)).json()
                    assert client.get('/api/v1/admin/media/preparations/'+prep['id'], headers=auth(pair)).json()['preparation'] == prep
            with TestClient(create_app(settings)) as client:
                assert client.get(BASE, headers=auth(pair)).json() == history
                assert client.post(BASE, headers=auth(pair), json=request).json()['inspection'] == succeeded
            assert all(not list(Path(p.path).iterdir()) for p in paths.values())
            return {'capabilities': capabilities, 'createRequest': request, 'queued': queued,
                'succeeded': succeeded, 'cancelCreateRequest': second_request, 'queuedForCancel': queued_cancel,
                'cancelled': cancelled, 'history': history}
        finally:
            worker.close()


def test_http_unix_restart_contract_matches_shared_client_fixture(tmp_path):
    assert actual_contract(tmp_path.resolve()) == json.loads(FIXTURE.read_text())
