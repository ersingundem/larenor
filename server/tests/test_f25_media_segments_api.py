import json

from conftest import auth
from larenor_server.plugins.media_playback_models import (
    MediaSegment,
    MediaSegmentsReadback,
)
from test_media_archive_core_read import configured


BASE = '/api/v1/media/playback/segments'


class SegmentWorker:
    def __init__(self, result=None, change=None):
        self.result = result or MediaSegmentsReadback(
            supported=True,
            reason='available',
            segments=[
                MediaSegment(kind='intro', startSeconds=10, endSeconds=75),
                MediaSegment(kind='outro', startSeconds=7000,
                             endSeconds=7100),
            ],
        )
        self.change = change
        self.calls = []

    def read_media_segments(self, authority, *, request_id, deadline, gate):
        assert request_id == 'a' * 32
        assert deadline > 0 and gate() is True
        self.calls.append(authority)
        if self.change is not None:
            self.change()
        return self.result


def request(installation, current, **changes):
    jellyfin = next(
        source for source in current.sources if source.serviceId == 'jellyfin')
    value = {
        'schemaVersion': 1,
        'requestId': 'a' * 32,
        'installationId': installation['id'],
        'expectedInstallationRevision': installation['revision'],
        'expectedSnapshotRevision': current.snapshotRevision,
        'expectedJellyfinServiceRevision': jellyfin.serviceRevision,
        'itemId': 'b' * 32,
        'mediaKey': 'movie:tmdb:603',
    }
    return value | changes


def test_http_core_dispatches_exact_catalog_authority_to_isolated_worker(server):
    app, client, _, _ = server
    pair, installation, current, _reader, _archive, _body = configured(server)
    worker = SegmentWorker()
    app.state.core.media_playback.backend = worker

    response = client.post(
        BASE, headers=auth(pair), json=request(installation, current))

    assert response.status_code == 200, response.text
    value = response.json()
    assert value['schemaVersion'] == 1
    assert value['requestId'] == 'a' * 32
    assert value['supported'] is True and value['reason'] == 'available'
    assert value['segments'] == [
        {'schemaVersion': 1, 'kind': 'intro',
         'startSeconds': 10, 'endSeconds': 75},
        {'schemaVersion': 1, 'kind': 'outro',
         'startSeconds': 7000, 'endSeconds': 7100},
    ]
    assert len(worker.calls) == 1
    authority = worker.calls[0]
    assert authority.model_dump() == {
        'installationId': installation['id'],
        'installationRevision': installation['revision'],
        'snapshotRevision': current.snapshotRevision,
        'jellyfinServiceRevision': next(
            source.serviceRevision for source in current.sources
            if source.serviceId == 'jellyfin'),
        'itemId': 'b' * 32,
        'mediaKey': 'movie:tmdb:603',
    }
    assert all(secret not in json.dumps(value).lower()
               for secret in ('token', 'password', 'endpoint', 'api_key'))


def test_unsupported_endpoint_is_explicit_and_secret_free(server):
    app, client, _, _ = server
    pair, installation, current, _reader, _archive, _body = configured(server)
    worker = SegmentWorker(MediaSegmentsReadback(
        supported=False, reason='endpoint_unsupported', segments=[]))
    app.state.core.media_playback.backend = worker

    response = client.post(
        BASE, headers=auth(pair), json=request(installation, current))

    assert response.status_code == 200, response.text
    assert response.json()['supported'] is False
    assert response.json()['reason'] == 'endpoint_unsupported'
    assert response.json()['segments'] == []
    assert len(worker.calls) == 1


def test_unauthorized_stale_and_late_requests_fail_closed(server):
    app, client, _, _ = server
    pair, installation, current, _reader, _archive, _body = configured(server)
    worker = SegmentWorker()
    app.state.core.media_playback.backend = worker
    body = request(installation, current)

    assert client.post(BASE, json=body).status_code == 401
    stale = client.post(
        BASE,
        headers=auth(pair),
        json={**body, 'expectedSnapshotRevision':
              current.snapshotRevision + 1},
    )
    assert stale.status_code == 409
    assert stale.json()['error']['code'] == 'media_archive_authority_changed'
    assert worker.calls == []

    def change_actor_revision():
        with app.state.core.db.transaction() as connection:
            connection.execute(
                'UPDATE users SET revision=revision+1 WHERE id=?',
                (pair['user']['id'],),
            )

    worker.change = change_actor_revision
    late = client.post(BASE, headers=auth(pair), json=body)
    assert late.status_code == 503
    assert late.json()['error']['code'] == 'media_playback_worker_unavailable'
    assert len(worker.calls) == 1


def test_malformed_or_over_limit_worker_result_never_crosses_http(server):
    app, client, _, _ = server
    pair, installation, current, _reader, _archive, _body = configured(server)
    segments = [
        MediaSegment(kind='intro', startSeconds=index * 2,
                     endSeconds=index * 2 + 1)
        for index in range(9)
    ]
    worker = SegmentWorker(MediaSegmentsReadback.model_construct(
        schemaVersion=1,
        supported=True,
        reason='available',
        segments=segments,
    ))
    app.state.core.media_playback.backend = worker

    response = client.post(
        BASE, headers=auth(pair), json=request(installation, current))

    assert response.status_code == 503
    assert response.json()['error']['code'] == 'media_playback_worker_unavailable'
    assert len(worker.calls) == 1
    assert 'segments' not in response.text
