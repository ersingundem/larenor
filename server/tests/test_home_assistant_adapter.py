"""Real Core HTTP/SQLite + owned loopback HA; no real home or external service."""
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Thread

import pytest

from conftest import auth, ready
from test_admin import activate, create as create_user


@pytest.fixture
def ha():
    class Fixture:
        calls = 0
        command_calls = 0
        state = 'off'
        status = 200
        command_status = 200
        body = None
        during = None
    fixture = Fixture()
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass
        def do_GET(self):
            fixture.calls += 1
            assert self.path == '/api/states/switch.synthetic'
            assert self.headers.get('Authorization') == 'Bearer synthetic-ha-only'
            if fixture.during:
                fixture.during()
            value = {'entity_id': 'switch.synthetic', 'state': fixture.state,
                'attributes': {'token': 'NEVER-PUBLISH-ATTRIBUTES'}, 'last_updated': '2026-09-06T12:00:00Z'}
            body = fixture.body if fixture.body is not None else json.dumps(value).encode()
            self.send_response(fixture.status)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        def do_POST(self):
            fixture.command_calls += 1
            assert self.path in ('/api/services/switch/turn_on', '/api/services/switch/turn_off')
            assert self.headers.get('Authorization') == 'Bearer synthetic-ha-only'
            assert self.headers.get('Content-Type') == 'application/json'
            length = int(self.headers.get('Content-Length', '0'))
            assert json.loads(self.rfile.read(length)) == {'entity_id': 'switch.synthetic'}
            if fixture.during:
                fixture.during()
            if fixture.command_status == 200:
                fixture.state = 'on' if self.path.endswith('/turn_on') else 'off'
            body = b'[]'
            self.send_response(fixture.command_status)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
    http = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    thread = Thread(target=http.serve_forever, daemon=True); thread.start()
    fixture.url = f'http://127.0.0.1:{http.server_port}'
    try:
        yield fixture
    finally:
        http.shutdown(); http.server_close(); thread.join(timeout=2)


def setup(server, ha):
    app, client, _, _ = server; admin = ready(server)
    scope = app.state.core.context
    resource = client.post(f'/api/v1/admin/home-resources/{scope.coreId}/{scope.homeId}',
        headers=auth(admin), json={'kind': 'resource', 'label': 'Synthetic switch', 'order': 0}).json()['record']
    service = client.post('/api/v1/admin/services', headers=auth(admin), json={
        'kind': 'home_assistant', 'name': 'Synthetic HA', 'baseUrl': ha.url,
        'credentials': {'token': 'synthetic-ha-only'}}).json()['service']
    suffix = f'/home-assistant/{scope.coreId}/{scope.homeId}/resources/{resource["ref"]["id"]}'
    base, public = '/api/v1/admin' + suffix, '/api/v1' + suffix
    body = {'serviceId': service['id'], 'expectedServiceRevision': 1, 'expectedRevision': 1,
        'expectedAclRevision': 1, 'entityId': 'switch.synthetic', 'expectedBindingId': None}
    return app, client, admin, resource, service, base, public, body


def bind(client, admin, base, body):
    preview = client.post(base + '/binding-preview', headers=auth(admin), json=body)
    assert preview.status_code == 201, preview.text
    assert preview.json()['preview']['projection'] == {'kind': 'switch', 'state': 'off', 'commandAvailable': False}
    confirm = client.post(base + '/binding-confirm', headers=auth(admin),
        json={'previewId': preview.json()['preview']['id']})
    assert confirm.status_code == 201, confirm.text
    return preview.json()['preview'], confirm.json()['binding']


def test_actual_preview_confirm_snapshot_and_cache(server, ha):
    app, client, admin, record, service, base, public, body = setup(server, ha)
    preview, binding = bind(client, admin, base, body)
    assert binding == preview['binding'] and binding['revision'] == 1
    assert client.post(base + '/binding-confirm', headers=auth(admin),
        json={'previewId': preview['id']}).status_code == 409
    response = client.get(public + '/snapshot', headers=auth(admin))
    assert response.status_code == 200, response.text
    snapshot = response.json()['snapshot']
    assert snapshot['bindingId'] == binding['id'] and snapshot['ref'] == record['ref']
    assert snapshot['projection'] == preview['projection']
    assert 0 < snapshot['remainingTtlMs'] <= 5000
    assert ha.calls == 2
    assert client.get(public + '/snapshot', headers=auth(admin)).status_code == 200
    assert ha.calls == 2
    assert 'NEVER-PUBLISH' not in response.text and 'synthetic-ha-only' not in response.text
    with app.state.core.db.connection() as c:
        rows = c.execute('SELECT * FROM home_assistant_bindings').fetchall()
        assert len(rows) == 1 and 'switch.synthetic' not in str(dict(rows[0]))


def test_members_require_resource_acl_and_never_receive_service_admin_api(server, ha):
    app, client, admin, record, service, base, public, body = setup(server, ha)
    create_user(client, admin); member = activate(client, 'member')
    bind(client, admin, base, body)
    before = ha.calls
    hidden = client.get(public + '/snapshot', headers=auth(member))
    assert hidden.status_code == 404
    assert client.get('/api/v1/admin/services', headers=auth(member)).status_code == 403
    assert client.post(base + '/binding-preview', headers=auth(member), json=body).status_code == 403
    assert ha.calls == before
    ref = record['ref']
    grant = f'/api/v1/admin/home-resources/{ref["coreId"]}/{ref["homeId"]}/{ref["id"]}/grants/{member["user"]["id"]}'
    assert client.put(grant, headers=auth(admin), json={'expectedAclRevision': 1,
        'permissions': {'read': True, 'write': False}}).status_code == 200
    assert client.get(public + '/snapshot', headers=auth(member)).status_code == 200
