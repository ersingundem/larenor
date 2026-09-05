"""HTTP -> encrypted job -> Unix worker -> synthetic Docker version response."""

from contextlib import contextmanager
from dataclasses import replace
import json
import os
from pathlib import Path
import socket
import socketserver
import tempfile
import threading
import time
from types import SimpleNamespace

from fastapi.testclient import TestClient
import pytest

from conftest import auth, ready
from test_plugin_api import preview
from test_plugin_preflight_ipc import running
from larenor_server.app import create_app
from larenor_server.plugins import host_preflight as host
from larenor_server.plugins.docker_probe import DockerEndpoint, DockerProbe


BASE = '/api/v1/admin/plugins/jobs'


@contextmanager
def engine_response(status, payload):
    requests = []
    body = json.dumps(payload).encode()
    wire = (f'HTTP/1.1 {status} Test\r\nContent-Type: application/json\r\n'
            f'Content-Length: {len(body)}\r\nConnection: close\r\n\r\n').encode() + body

    class Handler(socketserver.BaseRequestHandler):
        def handle(self):
            self.request.settimeout(1)
            data = bytearray()
            while b'\r\n\r\n' not in data and len(data) < 8192:
                chunk = self.request.recv(8192 - len(data))
                if not chunk:
                    return
                data.extend(chunk)
            requests.append(bytes(data))
            self.request.sendall(wire)

    with tempfile.TemporaryDirectory(prefix='ln-dj-', dir='/tmp') as directory:
        path = Path(directory).resolve() / 'engine.sock'
        with socketserver.UnixStreamServer(str(path), Handler) as server:
            path.chmod(0o600)
            thread = threading.Thread(target=server.serve_forever, kwargs={'poll_interval': .01}, daemon=True)
            thread.start()
            try:
                yield path, requests
            finally:
                server.shutdown()
                thread.join(timeout=2)
                assert not thread.is_alive()


@pytest.mark.parametrize('status,payload,expected', [
    (200, {'Os': 'linux', 'Arch': 'amd64', 'ApiVersion': '1.53', 'MinAPIVersion': '1.44'}, 'passed'),
    (200, {'Os': 'linux', 'Arch': 'amd64', 'ApiVersion': '1.40', 'MinAPIVersion': '1.24'}, 'failed'),
    (503, {'message': 'private-engine-error-sentinel'}, 'unknown'),
])
def test_admin_observes_docker_result_with_unknown_ports_and_restart_safe_history(
        server, tmp_path, monkeypatch, status, payload, expected):
    pair = ready(server)
    settings = server[2]
    root = tmp_path / 'component-data'
    root.mkdir(mode=0o700)
    if not hasattr(socket, 'SO_PEERCRED'):
        monkeypatch.setattr('larenor_server.plugins.preflight_ipc._peer_uid', lambda _: os.getuid())
        monkeypatch.setattr(host, 'DockerProbe', lambda endpoint: DockerProbe(endpoint, peer_uid=lambda _: os.getuid()))

    with engine_response(status, payload) as (path, requests):
        policy = host.HostPolicy({'appdata': host.HostRoot(str(root), 'data')},
                                 docker=DockerEndpoint(str(path), owner_uid=os.getuid()))
        inspector = host.HostInspector(policy, platform_provider=lambda: 'linux/amd64',
            statvfs_provider=lambda _: SimpleNamespace(f_bavail=16384, f_frsize=1048576, f_flag=0))
        with running(inspector) as (worker, _):
            configured = replace(settings, plugin_worker_socket=worker.path, plugin_worker_uid=os.getuid())
            with TestClient(create_app(configured)) as client:
                record = preview(client, pair)
                body = {'operation': 'preflight', 'previewId': record['id'], 'expectedRevision': 1,
                        'planHash': record['plan']['planHash'], 'requestId': 'a' * 32}
                accepted = client.post(BASE, headers=auth(pair), json=body)
                assert accepted.status_code == 202
                identifier = accepted.json()['job']['id']
                deadline = time.monotonic() + 4
                while True:
                    response = client.get(BASE + '/' + identifier, headers=auth(pair))
                    assert response.status_code == 200
                    job = response.json()['job']
                    if job['state'] not in ('queued', 'running'):
                        break
                    assert time.monotonic() < deadline
                    time.sleep(.025)
                # A completed inspection can include failed/unknown checks.
                assert job['state'] == 'succeeded'
                checks = {item['code']: item['status'] for item in job['result']['checks']}
                assert checks['docker_engine'] == expected
                assert checks['port_availability'] == checks['receiver_network'] == 'unknown'
                assert client.get(BASE + '/capabilities', headers=auth(pair)).json()['installAvailable'] is False
                assert client.post(BASE, headers=auth(pair), json=body).json()['job']['id'] == identifier
                assert str(path) not in response.text
                assert 'private-engine-error-sentinel' not in response.text
            assert len(requests) == 1
            assert requests[0].startswith(b'GET /version HTTP/1.1\r\n')
            assert requests[0].split(b'\r\n\r\n', 1)[1] == b''
    with TestClient(create_app(settings)) as restarted:
        assert restarted.get(BASE + '/' + identifier, headers=auth(pair)).json()['job'] == job
