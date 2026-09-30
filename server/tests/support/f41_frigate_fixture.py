"""A real TCP/WS provider fixture; normal Core retains all production adapters."""
import base64
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import struct
import threading
from urllib.parse import urlsplit, parse_qs


class FrigateFixture:
    def __init__(self):
        self.calls = []
        self.errors = []
        self.semantic = True
        self.events = [self.event('1788609600.123-front', 'front'),
                       self.event('1788609601.124-back', 'back', start=1788609601)]
        self.registry_platform = 'frigate'
        self.device = 'c' * 32
        self.during = None
        self.invalid_events = None
        self.allowed = ['front', 'back']
        self.token = 'f41-synthetic-only-token'
        self.frigate_credentials = None
        self.jwt = 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJmaXh0dXJlIn0.fixture_signature'
        owner = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.1'
            def log_message(self, *_):
                pass
            def reply(self, body, content_type='application/json', status=200, headers=()):
                raw = body if type(body) is bytes else json.dumps(body).encode()
                self.send_response(status)
                self.send_header('Content-Type', content_type)
                self.send_header('Content-Length', str(len(raw)))
                for name, value in headers:
                    self.send_header(name, value)
                self.end_headers()
                self.wfile.write(raw)
            def do_GET(self):
                try:
                    owner.calls.append(('GET', self.path))
                    path = urlsplit(self.path).path
                    if path == '/api/version':
                        self.reply(b'0.17.0-f41-v1', 'text/plain'); return
                    if path == '/api/websocket':
                        self.websocket(); return
                    expected_token = owner.token if path.startswith('/api/states/') or path == '/api/' else (
                        owner.jwt if owner.frigate_credentials else owner.token)
                    assert self.headers['Authorization'] == 'Bearer ' + expected_token
                    if path == '/api/':
                        self.reply({'message': 'API running.'}); return
                    if path.startswith('/api/states/'):
                        entity = path.removeprefix('/api/states/')
                        assert entity in ['camera.front', 'camera.back']
                        self.reply({'entity_id': entity, 'state': 'streaming',
                            'attributes': {'friendly_name': entity},
                            'last_updated': '2026-09-05T12:00:00+00:00',
                            'context': {'id': 'fixture', 'user_id': None, 'parent_id': None}}); return
                    if path == '/api/profile':
                        self.reply({'username': 'fixture', 'role': 'admin', 'allowed_cameras': owner.allowed}); return
                    if path == '/api/config':
                        self.reply({'cameras': {'front': {}, 'back': {}},
                            'semantic_search': {'enabled': owner.semantic}, 'secret': 'PRIVATE-ONLY'}); return
                    if owner.during is not None:
                        callback, owner.during = owner.during, None
                        callback()
                    if path in ['/api/events', '/api/events/search']:
                        query = parse_qs(urlsplit(self.path).query)
                        assert set(query['cameras'][0].split(',')) <= {'front', 'back'}
                        selected = [event for event in owner.events
                            if event['camera'] in query['cameras'][0].split(',')
                            and float(query['after'][0]) < event['start_time'] < float(query['before'][0])]
                        if path.endswith('/search'):
                            assert owner.semantic and query['search_type'] == ['thumbnail,description']
                        self.reply(selected if owner.invalid_events is None else owner.invalid_events); return
                    if path.startswith('/api/events/'):
                        item = next((event for event in owner.events if event['id'] == path.removeprefix('/api/events/')), None)
                        self.reply(item or {}, status=200 if item else 404); return
                    raise AssertionError('unexpected_path')
                except Exception as error:
                    owner.errors.append(type(error).__name__)
                    self.reply({}, status=503)
            def do_POST(self):
                owner.calls.append(('POST', self.path))
                if self.path == '/api/login' and owner.frigate_credentials:
                    body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                    assert body == {'user': owner.frigate_credentials['username'],
                                    'password': owner.frigate_credentials['password']}
                    self.reply(b'', 'text/plain', headers=[('Set-Cookie',
                        'frigate_token=' + owner.jwt + '; HttpOnly; Path=/')])
                    return
                self.reply({}, status=405)
            def websocket(self):
                accept = base64.b64encode(hashlib.sha1((self.headers['Sec-WebSocket-Key']
                    + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
                self.send_response(101, 'Switching Protocols')
                self.send_header('Upgrade', 'websocket'); self.send_header('Connection', 'Upgrade')
                self.send_header('Sec-WebSocket-Accept', accept); self.end_headers()
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
                assert read() == {'type': 'auth', 'access_token': owner.token}
                write({'type': 'auth_ok'})
                assert read() == {'id': 1, 'type': 'config/entity_registry/list'}
                write({'id': 1, 'type': 'result', 'success': True, 'result': [
                    {'entity_id': 'camera.' + name, 'platform': owner.registry_platform,
                     'config_entry_id': 'b' * 32, 'device_id': owner.device,
                     'unique_id': 'b' * 32 + ':camera:' + name, 'disabled_by': None}
                    for name in ['front', 'back']]})
                self.close_connection = True

        self.server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.url = f'http://127.0.0.1:{self.server.server_port}'

    @staticmethod
    def event(identity, camera, start=1788609600):
        return {'id': identity, 'camera': camera, 'start_time': start, 'end_time': start + 12,
            'has_clip': True, 'label': 'person', 'data': {'description': 'Red parcel at the door'}}

    def close(self):
        self.server.shutdown(); self.server.server_close(); self.thread.join(timeout=2)


def provision(client, core, actor, upstream):
    """Use normal authenticated management routes and real service checks."""
    from conftest import auth
    scope = core.context
    headers = auth(actor)
    services = {}
    for kind in ['home_assistant', 'frigate']:
        created = client.post('/api/v1/admin/services', headers=headers, json={
            'kind': kind, 'name': kind, 'baseUrl': upstream.url, 'credentials': (
                upstream.frigate_credentials if kind == 'frigate' and upstream.frigate_credentials
                else {'token': upstream.token})})
        assert created.status_code == 201, created.text
        service = created.json()['service']; services[kind] = service
        if kind == 'home_assistant':
            continue  # Binding preview and WS verify HA; its egress probe excludes loopback.
        checked = client.post('/api/v1/admin/services/' + service['id'] + '/check', headers=headers,
            json={'expectedRevision': 1})
        assert checked.status_code == 200, checked.text
        assert checked.json()['service']['verification']['state'] in ['authenticated', 'reachable'], checked.text
    cameras = []
    for name in ['front', 'back']:
        resource = client.post(f'/api/v1/admin/home-resources/{scope.coreId}/{scope.homeId}',
            headers=headers, json={'kind': 'resource', 'label': name.title() + ' door', 'order': 0})
        assert resource.status_code == 201, resource.text
        rid = resource.json()['record']['ref']['id']; cameras.append(rid)
        path = f'/api/v1/admin/home-assistant/{scope.coreId}/{scope.homeId}/resources/{rid}'
        preview = client.post(path + '/binding-preview', headers=headers, json={
            'serviceId': services['home_assistant']['id'], 'expectedServiceRevision': 1,
            'expectedRevision': 1, 'expectedAclRevision': 1, 'entityId': 'camera.' + name, 'expectedBindingId': None})
        assert preview.status_code == 201, preview.text
        confirmed = client.post(path + '/binding-confirm', headers=headers,
            json={'previewId': preview.json()['preview']['id']})
        assert confirmed.status_code == 201, confirmed.text
    root = f'/api/v1/camera-search/{scope.coreId}/{scope.homeId}'
    setup = f'/api/v1/admin/camera-search/{scope.coreId}/{scope.homeId}/sources'
    body = {'schemaVersion': 1, 'expectedRevision': 0, 'serviceId': services['frigate']['id'],
        'expectedServiceRevision': 1, 'cameraResourceIds': cameras}
    configured = client.put(setup, headers=headers, json=body)
    assert configured.status_code == 200, configured.text
    return root, setup, body, cameras, services
