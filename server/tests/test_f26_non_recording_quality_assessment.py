from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import socket
import threading

from conftest import auth, ready
from larenor_server.plugins.jellyfin_playback_runtime import (
    JellyfinPlaybackProtocol,
)
from test_f26_playback_quality_api import (
    CorePlaybackInfoWorker,
    PlaybackInfoProvider,
    observation_request,
    observe_scope,
)
from test_f27_offline_media_api import setup
from test_f27_online_playback_lease import BASE, create_body
from test_jellyfin_playback_runtime import (
    TOKEN,
    USER,
    playback_info_body,
    playback_info_source,
)


class _OwnedJellyfin:
    def __init__(self):
        self.calls = []

    def handler(self):
        owner = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.1'

            def log_message(self, *_args):
                pass

            def do_POST(self):
                try:
                    size = int(self.headers.get('Content-Length', '-1'))
                    raw = self.rfile.read(size) if 0 <= size <= 256_000 else b''
                    body = json.loads(raw)
                except (ValueError, UnicodeDecodeError, json.JSONDecodeError):
                    self.send_error(400)
                    return
                owner.calls.append((
                    self.path,
                    self.headers.get('Authorization'),
                    body,
                ))
                authorization = self.headers.get('Authorization', '')
                if (self.path != f"/Items/{'b' * 32}/PlaybackInfo"
                        or f'Token={TOKEN}' not in authorization
                        or body.get('UserId') != USER
                        or not isinstance(body.get('DeviceProfile'), dict)):
                    self.send_error(400)
                    return
                encoded = playback_info_body(
                    playback_info_source(Size=8))
                self.send_response_only(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(encoded)))
                self.send_header('Connection', 'close')
                self.end_headers()
                self.wfile.write(encoded)

        return Handler


@contextmanager
def _owned_jellyfin():
    owned = _OwnedJellyfin()
    server = ThreadingHTTPServer(('127.0.0.1', 0), owned.handler())
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    try:
        yield server.server_port, owned.calls
    finally:
        server.shutdown()
        server.server_close()
        worker.join(timeout=5)


class _LoopbackPlaybackInfoWorker:
    def __init__(self, port, chunk_worker=None):
        self.port = port
        self.chunk_worker = chunk_worker
        self.calls = []
        self.protocol = JellyfinPlaybackProtocol()

    def read_offline_media_chunk(self, *args, **kwargs):
        assert self.chunk_worker is not None
        return self.chunk_worker.read_offline_media_chunk(*args, **kwargs)

    def read_playback_info(
            self, authority, *, request_id, profile,
            expected_content_length, deadline, gate):
        assert gate() is True
        self.calls.append((authority, request_id, profile))
        connection = socket.create_connection(
            ('127.0.0.1', self.port), timeout=2)
        try:
            result = self.protocol.read_playback_info(
                connection,
                api_key=TOKEN,
                user_id=USER,
                installation_id=authority.installationId,
                item_id=authority.itemId,
                profile=profile,
                expected_content_length=expected_content_length,
                deadline=deadline,
            )
        finally:
            connection.close()
        assert gate() is True
        return result


def assess_scope(server, pair):
    context = server[1].get('/api/v1/context', headers=auth(pair)).json()
    return (
        f"/api/v1/media/playback-quality/{context['coreId']}/"
        f"{context['homeId']}/assess-item"
    )


def test_assessment_has_no_consumable_observation_or_private_provider_fields(
        server):
    pair = ready(server)
    app, client, _settings, _clock = server
    with app.state.core.db.connection() as connection:
        revision = connection.execute(
            'SELECT revision FROM users WHERE id=?',
            (pair['user']['id'],)).fetchone()['revision']
    provider = PlaybackInfoProvider(revision)
    app.state.core.playback_quality.media_playback = lambda: provider

    response = client.post(
        assess_scope(server, pair), headers=auth(pair),
        json=observation_request())

    assert response.status_code == 200, response.text
    value = response.json()
    assert set(value) == {
        'schemaVersion', 'requestId', 'authority', 'observation'}
    assert 'observationId' not in value
    assert value['observation']['originalByteOutcome'] == (
        'direct_play_supported')
    assert all(private not in response.text for private in (
        'private-media-source', 'PlaySessionId', 'MediaSourceId',
        'apiKey', 'http://', 'https://'))
    assert len(provider.calls) == 1


def test_thirty_three_real_assessments_leave_observe_and_lease_capacity(
        server):
    app, client, _settings, _clock = server
    pair, installation, current, chunk_worker = setup(server)
    jellyfin = next(
        value for value in current.sources if value.serviceId == 'jellyfin')
    body = observation_request() | {
        'installationId': installation['id'],
        'expectedInstallationRevision': installation['revision'],
        'expectedSnapshotRevision': current.snapshotRevision,
        'expectedJellyfinServiceRevision': jellyfin.serviceRevision,
        'itemId': 'b' * 32,
    }
    with _owned_jellyfin() as (port, jellyfin_calls):
        worker = _LoopbackPlaybackInfoWorker(port, chunk_worker)
        app.state.core.media_playback.backend = worker
        for index in range(33):
            assessed = client.post(
                assess_scope(server, pair), headers=auth(pair),
                json={**body, 'requestId': f'{index + 1:032x}'})
            assert assessed.status_code == 200, assessed.text
            assert set(assessed.json()) == {
                'schemaVersion', 'requestId', 'authority', 'observation'}
        assert app.state.core.media_playback._playback_info_observations == {}
        assert app.state.core.offline_media._playback_leases == {}

        observed = client.post(
            observe_scope(server, pair), headers=auth(pair),
            json={**body, 'requestId': 'e' * 32})
        assert observed.status_code == 200, observed.text
        observation_id = observed.json()['observationId']
        assert set(app.state.core.media_playback._playback_info_observations) == {
            observation_id}

        base = create_body(
            installation, current, request_id='a' * 32)
        lease_body = {
            key: base[key]
            for key in (
                'schemaVersion', 'requestId', 'installationId',
                'expectedInstallationRevision', 'expectedSnapshotRevision',
                'expectedJellyfinServiceRevision', 'itemId', 'mediaKey',
            )
        } | {'playbackObservationId': observation_id}
        created = client.post(BASE, headers=auth(pair), json=lease_body)
        assert created.status_code == 201, created.text
        assert app.state.core.media_playback._playback_info_observations == {}
        assert len(worker.calls) == 34
        assert len(jellyfin_calls) == 34


def test_assessment_rejects_extra_stale_retired_and_late_authority(
        server):
    app, client, _settings, clock = server
    pair, installation, current, _unused = setup(server)
    jellyfin = next(
        value for value in current.sources if value.serviceId == 'jellyfin')
    body = observation_request() | {
        'installationId': installation['id'],
        'expectedInstallationRevision': installation['revision'],
        'expectedSnapshotRevision': current.snapshotRevision,
        'expectedJellyfinServiceRevision': jellyfin.serviceRevision,
        'itemId': 'b' * 32,
    }
    extra = client.post(
        assess_scope(server, pair), headers=auth(pair),
        json={**body, 'privateUrl': 'https://private.invalid'})
    assert extra.status_code == 400

    path = assess_scope(server, pair)
    clock.now += 901
    expired = client.post(path, headers=auth(pair), json=body)
    assert expired.status_code == 401
    clock.now -= 901

    worker = CorePlaybackInfoWorker()
    app.state.core.media_playback.backend = worker
    stale = client.post(
        assess_scope(server, pair), headers=auth(pair), json={
            **body,
            'expectedSnapshotRevision': current.snapshotRevision + 1,
        })
    assert stale.status_code == 409
    assert worker.calls == []

    def drift():
        with app.state.core.db.transaction() as connection:
            connection.execute(
                'UPDATE users SET revision=revision+1 WHERE id=?',
                (pair['user']['id'],))

    worker.change = drift
    changed = client.post(
        path, headers=auth(pair), json=body)
    assert changed.status_code == 409
    assert 'observation' not in changed.text
    assert app.state.core.media_playback._playback_info_observations == {}

    client.post('/api/v1/auth/logout', headers=auth(pair))
    retired = client.post(
        path, headers=auth(pair), json=body)
    assert retired.status_code == 401
    assert len(worker.calls) == 1
