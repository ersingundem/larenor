import json

from conftest import auth
from larenor_server.plugins.media_playback_models import (
    MediaPlaybackReadback,
    MediaPlaybackTarget,
    MediaPlaybackWorkerResult,
)
from test_admin import activate, create as create_user
from test_media_archive_core_read import configured


BASE = '/api/v1/media/playback'


class PlaybackWorker:
    def __init__(self):
        self.calls = []
        self.reads = 0
        self.change = None

    def read_media_playback(self, _authority, *, deadline, gate):
        assert deadline > 0 and gate() is True
        self.reads += 1
        return MediaPlaybackReadback(
            playbackRevision=7,
            targets=[MediaPlaybackTarget(
                targetId='living-room', targetRevision=3,
                name='Living room', available=True,
                currentItemId=None, positionSeconds=0,
            )],
        )

    def execute_media_playback(self, action, *, deadline, gate):
        assert deadline > 0 and gate() is True
        self.calls.append(action)
        if self.change is not None:
            self.change()
        return MediaPlaybackWorkerResult(
            state='succeeded', playbackRevision=8,
            target=MediaPlaybackTarget(
                targetId='living-room', targetRevision=4,
                name='Living room', available=True,
                currentItemId=action.itemId,
                positionSeconds=action.startSeconds,
            ),
        )


def _request(installation, current, *, request_id='a' * 32):
    jellyfin = next(
        item for item in current.sources if item.serviceId == 'jellyfin')
    return {
        'requestId': request_id,
        'installationId': installation['id'],
        'expectedInstallationRevision': installation['revision'],
        'expectedSnapshotRevision': current.snapshotRevision,
        'expectedJellyfinServiceRevision': jellyfin.serviceRevision,
        'itemId': 'a' * 32,
        'mediaKey': 'movie:tmdb:603',
    }


def test_member_and_admin_prepare_revision_pinned_secret_free_intents(server):
    app, client, _, _ = server
    pair, installation, current, _reader, _archive, _body = configured(server)
    worker = PlaybackWorker()
    app.state.core.media_playback.backend = worker
    body = _request(installation, current)

    admin = client.post(BASE + '/intents', headers=auth(pair), json=body)
    assert admin.status_code == 200, admin.text
    intent = admin.json()['intent']
    assert intent == {
        **body,
        'playbackRevision': 7,
        'expiresAt': 1788609640,
        'targets': [{
            'targetId': 'living-room', 'targetRevision': 3,
            'name': 'Living room', 'available': True,
            'currentItemId': None, 'positionSeconds': 0,
        }],
    }
    assert worker.reads == 1
    assert all(value not in json.dumps(admin.json()).lower()
               for value in ('token', 'password', 'endpoint', 'url'))

    create_user(client, pair)
    member = activate(client, 'member')
    member_body = {**body, 'requestId': 'b' * 32}
    response = client.post(
        BASE + '/intents', headers=auth(member), json=member_body)
    assert response.status_code == 200, response.text
    assert response.json()['intent']['requestId'] == 'b' * 32


def test_stale_catalog_authority_never_reaches_playback_worker(server):
    app, client, _, _ = server
    pair, installation, current, _reader, _archive, _body = configured(server)
    worker = PlaybackWorker()
    app.state.core.media_playback.backend = worker
    body = _request(installation, current)
    body['expectedJellyfinServiceRevision'] += 1
    response = client.post(BASE + '/intents', headers=auth(pair), json=body)
    assert response.status_code == 409
    assert response.json()['error']['code'] == 'media_playback_authority_changed'
    assert worker.reads == 0 and worker.calls == []


def test_intent_is_one_use_and_same_command_replays_only_its_receipt(server):
    app, client, _, _ = server
    pair, installation, current, _reader, _archive, _body = configured(server)
    worker = PlaybackWorker()
    app.state.core.media_playback.backend = worker
    intent = client.post(
        BASE + '/intents', headers=auth(pair),
        json=_request(installation, current),
    ).json()['intent']
    command = {
        'requestId': 'c' * 32,
        'intentId': intent['requestId'],
        'expectedPlaybackRevision': intent['playbackRevision'],
        'targetId': 'living-room',
        'expectedTargetRevision': 3,
        'startSeconds': 12,
    }
    first = client.post(BASE + '/commands', headers=auth(pair), json=command)
    assert first.status_code == 201, first.text
    assert first.json()['receipt']['code'] == 'authenticated_readback'
    assert first.json()['receipt']['itemId'] == 'a' * 32
    replay = client.post(BASE + '/commands', headers=auth(pair), json=command)
    assert replay.status_code == 201 and replay.json() == first.json()
    conflict = client.post(
        BASE + '/commands', headers=auth(pair),
        json={**command, 'requestId': 'd' * 32},
    )
    assert conflict.status_code == 409
    assert worker.calls.__len__() == 1


def test_authority_loss_after_dispatch_never_publishes_success_or_replays(server):
    app, client, _, _ = server
    pair, installation, current, _reader, _archive, _body = configured(server)
    worker = PlaybackWorker()
    app.state.core.media_playback.backend = worker
    intent = client.post(
        BASE + '/intents', headers=auth(pair),
        json=_request(installation, current),
    ).json()['intent']
    worker.change = lambda: client.post('/api/v1/auth/logout', headers=auth(pair))
    command = {
        'requestId': 'e' * 32,
        'intentId': intent['requestId'],
        'expectedPlaybackRevision': 7,
        'targetId': 'living-room',
        'expectedTargetRevision': 3,
        'startSeconds': 0,
    }
    first = client.post(BASE + '/commands', headers=auth(pair), json=command)
    assert first.status_code == 401
    assert 'authenticated_readback' not in first.text
    assert len(worker.calls) == 1
