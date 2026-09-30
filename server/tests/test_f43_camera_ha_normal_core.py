"""Normal Core and real loopback TCP HA read/write/readback acceptance."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import threading
import base64
import hashlib
import struct

import pytest

from conftest import auth, ready
from larenor_server.app import create_app
from larenor_server.errors import StartupError


@pytest.fixture
def cameras():
    class Fixture:
        calls = []
        states = {'switch.recordings': 'on', 'switch.detection': 'on', 'person.owner': 'home'}
        generation = 1
        reject_detection = False
        unknown_ack = False
        during = None
        registry_platform = 'frigate'
        registry_device = 'c' * 32
    fixture = Fixture()

    class Handler(BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'
        def log_message(self, *_):
            pass

        def reply(self, value, status=200):
            raw = json.dumps(value).encode()
            self.send_response(status)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

        def do_GET(self):
            fixture.calls.append(('GET', self.path))
            if self.path == '/api/websocket':
                key = self.headers['Sec-WebSocket-Key']
                accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
                self.send_response(101, 'Switching Protocols')
                self.send_header('Upgrade', 'websocket')
                self.send_header('Connection', 'Upgrade')
                self.send_header('Sec-WebSocket-Accept', accept)
                self.end_headers()
                def write(value):
                    raw = json.dumps(value).encode()
                    header = bytes([0x81, len(raw)]) if len(raw) < 126 else b'\x81\x7e' + struct.pack('!H', len(raw))
                    self.wfile.write(header + raw); self.wfile.flush()
                def read():
                    first, second = self.rfile.read(2)
                    assert first == 0x81 and second & 0x80
                    length = second & 0x7f
                    if length == 126: length = struct.unpack('!H', self.rfile.read(2))[0]
                    mask = self.rfile.read(4); raw = self.rfile.read(length)
                    return json.loads(bytes(value ^ mask[index % 4] for index, value in enumerate(raw)))
                write({'type': 'auth_required'})
                assert read() == {'type': 'auth', 'access_token': 'camera-loopback-only'}
                write({'type': 'auth_ok'})
                assert read() == {'id': 1, 'type': 'config/entity_registry/list'}
                write({'id': 1, 'type': 'result', 'success': True, 'result': [
                    {'entity_id': entity, 'platform': fixture.registry_platform,
                     'config_entry_id': 'b' * 32, 'device_id': fixture.registry_device,
                     'unique_id': 'b' * 32 + ':switch:entry_' + suffix,
                     'disabled_by': None}
                    for entity, suffix in [('switch.recordings', 'recordings'), ('switch.detection', 'detect')]]})
                self.close_connection = True
                return
            assert self.headers['Authorization'] == 'Bearer camera-loopback-only'
            entity = self.path.removeprefix('/api/states/')
            assert entity in fixture.states
            self.reply({'entity_id': entity, 'state': fixture.states[entity],
                'attributes': {'friendly_name': entity, 'secret': 'PRIVATE-ONLY'},
                'last_updated': f'2026-09-30T12:00:{fixture.generation:02d}+00:00',
                'context': {'id': str(fixture.generation), 'parent_id': None, 'user_id': None}})

        def do_POST(self):
            fixture.calls.append(('POST', self.path))
            assert self.path in {'/api/services/switch/turn_off', '/api/services/switch/turn_on'}
            assert self.headers['Authorization'] == 'Bearer camera-loopback-only'
            raw = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            assert set(raw) == {'entity_id'}
            if fixture.during:
                fixture.during()
            entity = raw['entity_id']
            if fixture.unknown_ack or fixture.reject_detection and entity == 'switch.detection':
                self.reply({}, 503)
                return
            fixture.states[entity] = 'on' if self.path.endswith('/turn_on') else 'off'
            fixture.generation += 1
            self.reply([])

    http = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=http.serve_forever, daemon=True)
    thread.start()
    fixture.url = f'http://127.0.0.1:{http.server_port}'
    yield fixture
    http.shutdown()
    http.server_close()
    thread.join(timeout=2)


def provision(server, cameras):
    app, client, _settings, _clock = server
    admin = ready(server)
    scope = app.state.core.context
    registry = f'/api/v1/admin/home-resources/{scope.coreId}/{scope.homeId}'
    service = client.post('/api/v1/admin/services', headers=auth(admin), json={
        'kind': 'home_assistant', 'name': 'Cameras HA', 'baseUrl': cameras.url,
        'credentials': {'token': 'camera-loopback-only'}}).json()['service']
    area = client.post(registry, headers=auth(admin), json={
        'kind': 'room', 'label': 'Entry', 'order': 0}).json()['record']['ref']['id']
    resources = []
    for entity, name in [('person.owner', 'Presence'), ('switch.recordings', 'Recordings'),
                         ('switch.detection', 'Detection')]:
        resource = client.post(registry, headers=auth(admin), json={
            'kind': 'resource', 'label': name, 'order': 0}).json()['record']['ref']['id']
        root = f'/api/v1/admin/home-assistant/{scope.coreId}/{scope.homeId}/resources/{resource}'
        response = client.post(root + '/binding-preview', headers=auth(admin), json={
            'serviceId': service['id'], 'expectedServiceRevision': 1, 'expectedRevision': 1,
            'expectedAclRevision': 1, 'entityId': entity, 'expectedBindingId': None})
        assert response.status_code == 201, response.text
        response = client.post(root + '/binding-confirm', headers=auth(admin),
            json={'previewId': response.json()['preview']['id']})
        assert response.status_code == 201, response.text
        resources.append(resource)
    root = f'/api/v1/admin/camera-profiles/{scope.coreId}/{scope.homeId}'
    settings = {'schemaVersion': 1, 'expectedRevision': 0,
        'presenceResourceId': resources[0], 'cameras': [{'recordingResourceId': resources[1],
        'detectionResourceId': resources[2], 'areaId': area}],
        'enterDelayMs': 0, 'exitDelayMs': 0, 'hysteresisMs': 0,
        'presenceMaxAgeMs': 30000, 'atHomeMode': {'recording': 'paused', 'detection': 'disabled'},
        'awayMode': {'recording': 'enabled', 'detection': 'enabled'},
        'failSafeMode': {'recording': 'enabled', 'detection': 'enabled'}}
    response = client.put(root + '/sources', headers=auth(admin), json=settings)
    assert response.status_code == 200, response.text
    return app, client, admin, root, settings


def apply(client, admin, root, snapshot, key='a' * 32):
    return client.post(root + '/apply', headers=auth(admin), json={
        'schemaVersion': 1, 'requestId': key,
        **{field: snapshot[field] for field in ['authority', 'policy', 'signal',
                                              'decision', 'readbacks', 'support']}})


def test_normal_core_actual_read_apply_readback_and_encrypted_restart(server, cameras):
    app, client, admin, root, _settings = provision(server, cameras)
    response = client.get(root, headers=auth(admin))
    assert response.status_code == 200, response.text
    snapshot = response.json()['snapshot']
    server[3].now += 2  # Refresh observation timestamps without fabricating a state change.
    response = apply(client, admin, root, snapshot)
    assert response.status_code == 200, response.text
    receipt = response.json()['receipt']
    assert receipt['status'] == 'applied'
    assert cameras.states['switch.recordings'] == 'off'
    assert cameras.states['switch.detection'] == 'off'
    assert sum(method == 'POST' for method, _ in cameras.calls) == 2
    assert all(not flag for flag in snapshot['privacyBoundary'].values())
    assert 'PRIVATE-ONLY' not in response.text and 'camera-loopback-only' not in response.text
    with app.state.core.db.connection() as connection:
        stored = connection.execute('SELECT * FROM camera_provider_records').fetchall()
        assert stored and all('switch.recordings' not in str(dict(row)) for row in stored)
    restarted = create_app(server[2])
    provider = restarted.state.core.camera_profile_sources
    provider.store.validate_storage()
    assert provider.store.get('configuration')['revision'] == 1


def test_stale_source_settings_never_send_device_commands(server, cameras):
    _app, client, admin, root, settings = provision(server, cameras)
    before = len(cameras.calls)
    response = client.put(root + '/sources', headers=auth(admin), json=settings)
    assert response.status_code == 409
    assert not any(method == 'POST' for method, _ in cameras.calls[before:])


def test_partial_pair_is_visible_and_unresolved_intent_cannot_replay(server, cameras):
    app, client, admin, root, _settings = provision(server, cameras)
    snapshot = client.get(root, headers=auth(admin)).json()['snapshot']
    cameras.reject_detection = True
    result = apply(client, admin, root, snapshot).json()['receipt']
    assert result['status'] == 'unknown'
    assert cameras.states['switch.recordings'] == 'off'
    assert cameras.states['switch.detection'] == 'on'
    before = len(cameras.calls)
    fresh = client.get(root, headers=auth(admin)).json()['snapshot']
    result = apply(client, admin, root, fresh, key='b' * 32).json()['receipt']
    assert result['status'] == 'unknown'
    assert not any(method == 'POST' for method, _ in cameras.calls[before:])
    provider = app.state.core.camera_profile_sources
    with app.state.core.db.connection() as connection:
        rows = connection.execute("SELECT * FROM camera_provider_records WHERE id LIKE 'command:%'").fetchall()
        assert any(provider.store._decode(row)['result'] is None for row in rows)


def test_live_manual_state_change_rejects_old_profile_preview(server, cameras):
    _app, client, admin, root, _settings = provision(server, cameras)
    snapshot = client.get(root, headers=auth(admin)).json()['snapshot']
    cameras.states['switch.recordings'] = 'off'
    cameras.generation += 1
    response = apply(client, admin, root, snapshot)
    assert response.status_code == 409
    assert not any(method == 'POST' for method, _ in cameras.calls)


def test_corrupted_provider_storage_fails_startup(server, cameras):
    app, _client, _admin, _root, _settings = provision(server, cameras)
    with app.state.core.db.transaction() as connection:
        connection.execute('UPDATE camera_provider_records SET ciphertext=?', (b'x' * 32,))
    with pytest.raises(StartupError, match='camera_profile_storage_invalid'):
        create_app(server[2])


def test_read_only_reconciliation_after_restart_clears_only_current_state_interlock(server, cameras):
    _app, client, admin, root, _settings = provision(server, cameras)
    snapshot = client.get(root, headers=auth(admin)).json()['snapshot']
    cameras.reject_detection = True
    receipt = apply(client, admin, root, snapshot).json()['receipt']
    assert receipt['status'] == 'unknown'
    before = sum(method == 'POST' for method, _ in cameras.calls)
    restarted = create_app(server[2])
    from fastapi.testclient import TestClient
    with TestClient(restarted) as current:
        recovery = current.get(root + '/sources/recovery', headers=auth(admin))
        assert recovery.status_code == 200, recovery.text
        pending = recovery.json()['recoveries'][0]
        pending.pop('label')
        invalid = {**pending, 'expectedStateRevision': pending['expectedStateRevision'] + 1}
        assert current.post(root + '/sources/reconcile', headers=auth(admin), json=invalid).status_code == 409
        response = current.post(root + '/sources/reconcile', headers=auth(admin), json=pending)
        assert response.status_code == 200, response.text
        assert response.json()['reconciliation']['status'] == 'current_state_confirmed'
        assert current.get(root + '/sources/recovery', headers=auth(admin)).json()['recoveries'] == []
        assert sum(method == 'POST' for method, _ in cameras.calls) == before
        cameras.reject_detection = False
        fresh = current.get(root, headers=auth(admin)).json()['snapshot']
        response = apply(current, admin, root, fresh, key='d' * 32)
        assert response.status_code == 200, response.text
        assert response.json()['receipt']['status'] == 'applied'
        assert sum(method == 'POST' for method, _ in cameras.calls) == before + 1


def test_registry_provider_change_after_preview_never_sends_camera_commands(server, cameras):
    _app, client, admin, root, _settings = provision(server, cameras)
    preview = client.get(root, headers=auth(admin)).json()['snapshot']
    cameras.registry_platform = 'template'
    response = apply(client, admin, root, preview)
    assert response.status_code == 409
    assert not any(method == 'POST' for method, _ in cameras.calls)


def test_inventory_deletion_cannot_erase_an_unresolved_command(server, cameras):
    app, client, admin, root, _settings = provision(server, cameras)
    preview = client.get(root, headers=auth(admin)).json()['snapshot']
    cameras.unknown_ack = True
    assert apply(client, admin, root, preview).json()['receipt']['status'] == 'unknown'
    with app.state.core.db.transaction() as connection:
        connection.execute("DELETE FROM camera_provider_records WHERE id LIKE 'command:%'")
    with pytest.raises(StartupError, match='camera_profile_storage_invalid'):
        create_app(server[2])
