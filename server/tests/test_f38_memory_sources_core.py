"""Normal Core routes against bounded real loopback Immich HTTP."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import threading
import uuid
from urllib.parse import parse_qs, urlsplit

import pytest
from fastapi.testclient import TestClient

from conftest import auth, ready
from larenor_server.app import create_app
from larenor_server.errors import StartupError
from test_admin import create, activate
from test_f38_family_memories import (
    ALBUM, OTHER_ALBUM, ASSET, OTHER_ASSET, asset,
)


ROOT = '/api/v1/family-memories'
KEY = 'synthetic-immich-album-read-key'


def body(**values):
    return {'schemaVersion': 1, 'requestId': uuid.uuid4().hex, **values}


@pytest.fixture
def immich_http():
    state = {
        'contains': True,
        'calls': [],
        'during_search': lambda: None,
        'version': '3.2.4',
        'albums': {ALBUM: 'Aile tatili'},
        'search_items': {ALBUM: [asset()]},
    }

    class Handler(BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'

        def log_message(self, *_args):
            pass

        def send(self, value):
            raw = json.dumps(value).encode()
            self.send_response(200 if self.headers.get('x-api-key') == KEY else 401)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(raw)))
            self.send_header('Connection', 'close')
            self.end_headers()
            self.wfile.write(raw)

        def do_GET(self):
            state['calls'].append(('GET', self.path))
            path = urlsplit(self.path)
            if path.path == '/api/server/about':
                self.send({'version': state['version'], 'licensed': False,
                           'versionUrl': 'https://github.com/immich-app/immich/releases/tag/v3.2.4'})
            elif path.path == '/api/albums':
                query = parse_qs(path.query)
                assert not query or query == {'assetId': [ASSET]}
                self.send([
                    {'id': album_id, 'albumName': title}
                    for album_id, title in state['albums'].items()
                ] if not query else [
                    {'id': album_id, 'albumName': title}
                    for album_id, title in state['albums'].items()
                    if state['contains'] and album_id == ALBUM
                ])
            elif path.path == '/api/assets/' + ASSET:
                self.send(asset())
            else:
                raise AssertionError('unexpected Immich route')

        def do_POST(self):
            assert self.path == '/api/search/smart'
            incoming = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            albums = incoming['filter'].pop('albumIds')
            assert incoming['filter'] == {'type': {'eq': 'IMAGE'}}
            assert isinstance(albums, dict) and list(albums) == ['any']
            assert isinstance(albums['any'], list) and len(albums['any']) == 1
            album_id = albums['any'][0]
            assert album_id in state['albums']
            state['calls'].append(('POST', self.path, album_id))
            state['during_search']()
            self.send({'assets': {'items': state['search_items'][album_id]}})

    httpd = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    try:
        yield httpd.server_port, state
    finally:
        httpd.shutdown()
        httpd.server_close()
        thread.join(timeout=2)


def configured(server, immich_http):
    app, client, _settings, _clock = server
    admin = ready(server)
    service = client.post('/api/v1/admin/services', headers=auth(admin), json={
        'name': 'Aile fotoğrafları', 'kind': 'immich',
        'baseUrl': f'http://127.0.0.1:{immich_http[0]}',
        'credentials': {'apiKey': KEY}}).json()['service']
    actor = app.state.core.auth.authenticate(admin['accessToken'])
    app.state.core.services.record_verification(actor, service['id'], service['revision'],
                                               state='authenticated', version='3.2.4')
    return admin, service


def sources(client, pair, **values):
    response = client.post(ROOT + '/sources', headers=auth(pair), json=body(**values))
    assert response.status_code == 200, response.text
    return response.json()['source']


def grant(client, admin, service, source, *, albums=None):
    return client.put(ROOT + '/sources', headers=auth(admin), json=body(
        accountId=source['accountId'], expectedAccountRevision=source['accountRevision'],
        expectedRevision=source['revision'], serviceId=service['id'],
        expectedServiceRevision=service['revision'], allowedAlbumIds=albums or [ALBUM]))


def test_normal_core_catalog_grant_search_membership_reconcile_and_restart(server, immich_http):
    app, client, settings, _clock = server
    admin, service = configured(server, immich_http)
    initial = sources(client, admin)
    assert initial['binding'] is None and initial['canManage']
    response = grant(client, admin, service, initial)
    assert response.status_code == 200, response.text
    source = response.json()['source']
    assert source['revision'] == 1
    assert source['binding']['faceSearchEnabled'] is False
    assert KEY not in response.text and 'originalPath' not in response.text
    snapshot = client.post(ROOT + '/snapshot', headers=auth(admin), json=body()).json()['snapshot']
    facts = dict(expectedMembersRevision=snapshot['authority']['membersRevision'],
                 serviceId=service['id'], expectedServiceRevision=service['revision'])
    searched = client.post(ROOT + '/search', headers=auth(admin),
                           json=body(**facts, query='Aile tatili', albumIds=[ALBUM]))
    assert searched.status_code == 200, searched.text
    assert searched.json()['assets'][0]['assetId'] == ASSET
    assert KEY not in searched.text and 'originalPath' not in searched.text
    created = client.post(ROOT + '/albums', headers=auth(admin), json=body(
        **facts, title='Yaz anıları', visibility='personal', memberIds=[source['accountId']]))
    assert created.status_code == 201, created.text
    album = created.json()['album']
    selected = {key: searched.json()['assets'][0][key]
                for key in ('assetId', 'sourceAlbumId', 'sourceEtag')}
    replaced = client.put(ROOT + f"/albums/{album['albumId']}/assets", headers=auth(admin),
        json=body(**facts, expectedRevision=album['revision'], assets=[selected]))
    assert replaced.status_code == 200, replaced.text
    assert ('GET', f'/api/albums?assetId={ASSET}') in immich_http[1]['calls']
    immich_http[1]['contains'] = False
    forged = client.put(ROOT + f"/albums/{album['albumId']}/assets", headers=auth(admin),
        json=body(**facts, expectedRevision=replaced.json()['album']['revision'], assets=[selected]))
    assert forged.status_code == 409 and forged.json()['error']['code'] == 'memory_asset_changed'
    reconciled = client.post(ROOT + f"/albums/{album['albumId']}/reconcile", headers=auth(admin),
        json=body(**facts, expectedRevision=replaced.json()['album']['revision']))
    assert reconciled.status_code == 200 and reconciled.json()['album']['assets'] == []
    with TestClient(create_app(settings)) as restarted:
        assert sources(restarted, admin)['binding']['allowedAlbumIds'] == [ALBUM]
        assert restarted.post(ROOT + '/snapshot', headers=auth(admin), json=body()).status_code == 200
    with app.state.core.db.connection() as db:
        row = db.execute('SELECT ciphertext FROM memory_source_bindings').fetchone()
        assert KEY.encode() not in row['ciphertext'] and ALBUM.encode() not in row['ciphertext']


def test_normal_core_searches_each_granted_album_and_returns_exact_provenance(
        server, immich_http):
    _app, client, _settings, _clock = server
    immich_http[1]['albums'][OTHER_ALBUM] = 'Aile arşivi'
    immich_http[1]['search_items'] = {
        ALBUM: [asset(), asset(id=OTHER_ASSET, originalFileName='Ortak.jpg')],
        OTHER_ALBUM: [
            asset(id=OTHER_ASSET, originalFileName='Ortak.jpg'),
            asset(id='66666666-6666-4666-8666-666666666666',
                  originalFileName='İkinci-albüm.jpg'),
        ],
    }
    admin, service = configured(server, immich_http)
    source = sources(client, admin)
    granted = grant(
        client, admin, service, source, albums=[ALBUM, OTHER_ALBUM])
    assert granted.status_code == 200, granted.text
    snapshot = client.post(
        ROOT + '/snapshot', headers=auth(admin), json=body()).json()['snapshot']
    searched = client.post(ROOT + '/search', headers=auth(admin), json=body(
        expectedMembersRevision=snapshot['authority']['membersRevision'],
        serviceId=service['id'], expectedServiceRevision=service['revision'],
        query='Aile', albumIds=[ALBUM, OTHER_ALBUM], limit=3))
    assert searched.status_code == 200, searched.text
    assert [(value['assetId'], value['sourceAlbumId'])
            for value in searched.json()['assets']] == [
        (ASSET, ALBUM),
        (OTHER_ASSET, OTHER_ALBUM),
        ('66666666-6666-4666-8666-666666666666', OTHER_ALBUM),
    ]
    assert [call for call in immich_http[1]['calls'] if call[0] == 'POST'] == [
        ('POST', '/api/search/smart', ALBUM),
        ('POST', '/api/search/smart', OTHER_ALBUM),
    ]


def test_grants_are_admin_only_face_consent_is_self_only_and_revocation_is_immediate(server, immich_http):
    app, client, _settings, _clock = server
    admin, service = configured(server, immich_http)
    created = create(client, admin)
    member = activate(client, 'member')
    target = sources(client, admin, accountId=created['id'])
    assert grant(client, member, service, target).status_code == 403
    assert grant(client, admin, service, target, albums=[OTHER_ALBUM]).status_code == 409
    granted = grant(client, admin, service, target)
    assert granted.status_code == 200
    mine = sources(client, member)
    assert mine['services'] == mine['members'] == [] and not mine['canManage']
    assert client.post(ROOT + '/sources/albums', headers=auth(member), json=body(
        serviceId=service['id'], expectedServiceRevision=service['revision'])).status_code == 403
    assert client.put(ROOT + '/sources/face-consent', headers=auth(admin), json=body(
        accountId=created['id'], expectedRevision=1, enabled=True)).status_code == 400
    consent = client.put(ROOT + '/sources/face-consent', headers=auth(member),
        json=body(expectedRevision=1, enabled=True))
    assert consent.status_code == 200 and consent.json()['source']['binding']['faceSearchEnabled']
    assert grant(client, admin, service, target).status_code == 409
    revoked = client.request('DELETE', ROOT + '/sources', headers=auth(member), json=body(
        accountId=created['id'], expectedAccountRevision=mine['accountRevision'], expectedRevision=2))
    assert revoked.status_code == 200 and revoked.json()['source']['binding'] is None
    assert client.post(ROOT + '/snapshot', headers=auth(member), json=body()).status_code == 503
    actor = app.state.core.auth.authenticate(member['accessToken'])
    with pytest.raises(Exception, match='policy_unavailable'):
        app.state.core.family_memory_sources.resolve(actor)


def test_late_search_after_source_revocation_is_not_returned(server, immich_http):
    app, client, _settings, _clock = server
    admin, service = configured(server, immich_http)
    source = sources(client, admin)
    assert grant(client, admin, service, source).status_code == 200
    snapshot = client.post(ROOT + '/snapshot', headers=auth(admin), json=body()).json()['snapshot']
    immich_http[1]['during_search'] = lambda: client.request('DELETE', ROOT + '/sources',
        headers=auth(admin), json=body(accountId=source['accountId'],
            expectedAccountRevision=source['accountRevision'], expectedRevision=1))
    response = client.post(ROOT + '/search', headers=auth(admin), json=body(
        expectedMembersRevision=snapshot['authority']['membersRevision'], serviceId=service['id'],
        expectedServiceRevision=service['revision'], query='Aile', albumIds=[ALBUM]))
    assert response.status_code in {409, 503} and 'assets' not in response.json()


def test_encrypted_source_tamper_refuses_startup(server, immich_http):
    app, client, settings, _clock = server
    admin, service = configured(server, immich_http)
    assert grant(client, admin, service, sources(client, admin)).status_code == 200
    with app.state.core.db.transaction() as db:
        db.execute("UPDATE memory_source_bindings SET ciphertext=?", (b'x' * 32,))
    with pytest.raises(StartupError, match='memory_source_storage_invalid'):
        create_app(settings)


def test_revoke_then_identical_regrant_cannot_resurrect_inflight_search(server, immich_http):
    _app, client, _settings, _clock = server
    admin, service = configured(server, immich_http)
    source = sources(client, admin)
    assert grant(client, admin, service, source).status_code == 200
    snapshot = client.post(ROOT + '/snapshot', headers=auth(admin), json=body()).json()['snapshot']

    def replace_grant():
        revoked = client.request('DELETE', ROOT + '/sources', headers=auth(admin), json=body(
            accountId=source['accountId'], expectedAccountRevision=source['accountRevision'], expectedRevision=1))
        assert revoked.status_code == 200
        assert grant(client, admin, service, revoked.json()['source']).status_code == 200

    immich_http[1]['during_search'] = replace_grant
    response = client.post(ROOT + '/search', headers=auth(admin), json=body(
        expectedMembersRevision=snapshot['authority']['membersRevision'], serviceId=service['id'],
        expectedServiceRevision=service['revision'], query='Aile', albumIds=[ALBUM]))
    assert response.status_code == 409 and response.json()['error']['code'] == 'memory_binding_changed'
    assert 'assets' not in response.json()


def test_actual_upstream_downgrade_blocks_catalog_and_existing_search(server, immich_http):
    _app, client, _settings, _clock = server
    admin, service = configured(server, immich_http)
    assert grant(client, admin, service, sources(client, admin)).status_code == 200
    snapshot = client.post(ROOT + '/snapshot', headers=auth(admin), json=body()).json()['snapshot']
    immich_http[1]['version'] = '3.1.9'
    immich_http[1]['calls'].clear()
    response = client.post(ROOT + '/sources/albums', headers=auth(admin), json=body(
        serviceId=service['id'], expectedServiceRevision=service['revision']))
    assert response.status_code == 503 and response.json()['error']['code'] == 'memory_unsupported_version'
    response = client.post(ROOT + '/search', headers=auth(admin), json=body(
        expectedMembersRevision=snapshot['authority']['membersRevision'], serviceId=service['id'],
        expectedServiceRevision=service['revision'], query='Aile', albumIds=[ALBUM]))
    assert response.status_code == 503 and response.json()['error']['code'] == 'memory_unsupported_version'
    assert immich_http[1]['calls'] == [('GET', '/api/server/about')] * 2
