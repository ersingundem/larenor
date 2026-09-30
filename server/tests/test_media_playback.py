import json
import sqlite3

import pytest
from conftest import auth, login
from larenor_server.errors import StartupError
from larenor_server.plugins.jellyfin_playback_executor import (
    JellyfinPlaybackExecutionError,
)
from larenor_server.plugins.media_playback_models import (
    MediaPlaybackReadback,
    MediaPlaybackTarget,
    MediaPlaybackWorkerResult,
)
from larenor_server.plugins.media_playback_schema import migrate_media_playback
from test_admin import activate
from test_admin import create as create_user
from test_media_archive_core_read import configured

BASE = '/api/v1/media/playback'


def test_v1_migration_invalidates_unbound_intents_and_receipts():
    connection = sqlite3.connect(':memory:')
    connection.row_factory = sqlite3.Row
    connection.execute('PRAGMA foreign_keys=ON')
    connection.execute('CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT)')
    connection.execute(
        "INSERT INTO metadata VALUES('media_playback_schema','1')")
    connection.execute('''CREATE TABLE media_playback_intents (
        id TEXT PRIMARY KEY NOT NULL, actor_id TEXT NOT NULL,
        installation_id TEXT NOT NULL, installation_revision INTEGER NOT NULL,
        snapshot_revision INTEGER NOT NULL,
        jellyfin_service_revision INTEGER NOT NULL, item_id TEXT NOT NULL,
        media_key TEXT NOT NULL, playback_revision INTEGER NOT NULL,
        targets_json TEXT NOT NULL, expires_at INTEGER NOT NULL,
        consumed_by TEXT UNIQUE)''')
    connection.execute('''CREATE TABLE media_playback_receipts (
        request_id TEXT PRIMARY KEY NOT NULL,
        intent_id TEXT UNIQUE NOT NULL REFERENCES media_playback_intents(id),
        actor_id TEXT NOT NULL, request_json TEXT NOT NULL,
        state TEXT NOT NULL, receipt_json TEXT, created_at INTEGER NOT NULL)''')
    connection.execute(
        'INSERT INTO media_playback_intents VALUES(?,?,?,?,?,?,?,?,?,?,?,?)',
        ('a' * 32, 'b' * 32, 'c' * 32, 1, 1, 1, 'd' * 32,
         'movie:tmdb:603', 1, '[]', 100, 'e' * 32))
    connection.execute(
        'INSERT INTO media_playback_receipts VALUES(?,?,?,?,?,?,?)',
        ('e' * 32, 'a' * 32, 'b' * 32, '{}', 'pending', None, 1))

    migrate_media_playback(connection)

    assert connection.execute(
        "SELECT value FROM metadata WHERE key='media_playback_schema'"
    ).fetchone()['value'] == '2'
    assert connection.execute(
        'SELECT COUNT(*) FROM media_playback_intents').fetchone()[0] == 0
    assert connection.execute(
        'SELECT COUNT(*) FROM media_playback_receipts').fetchone()[0] == 0
    assert {row['name'] for row in connection.execute(
        "PRAGMA table_info('media_playback_intents')")} >= {
            'actor_revision', 'family_id'}
    connection.close()


class PlaybackWorker:
    def __init__(self):
        self.calls = []
        self.reads = 0
        self.read_change = None
        self.change = None
        self.execute_error = None

    def read_media_playback(self, _authority, *, deadline, gate):
        assert deadline > 0 and gate() is True
        self.reads += 1
        if self.read_change is not None:
            self.read_change(self.reads)
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
        if self.execute_error is not None:
            raise self.execute_error
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
        'itemId': 'b' * 32,
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
            'qualityObservation': None,
        }],
    }
    assert worker.reads == 1
    assert all(value not in json.dumps(admin.json()).lower()
               for value in ('token', 'password', 'endpoint', 'url'))
    with app.state.core.db.connection() as connection:
        stored = connection.execute(
            'SELECT actor_revision,family_id FROM media_playback_intents '
            'WHERE id=?', (body['requestId'],)).fetchone()
        current_revision = connection.execute(
            'SELECT revision FROM users WHERE id=?',
            (pair['user']['id'],)).fetchone()['revision']
    assert stored['actor_revision'] == current_revision
    assert stored['family_id'] == pair['sessionFamilyId']

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
    assert first.json()['receipt']['itemId'] == 'b' * 32
    replay = client.post(BASE + '/commands', headers=auth(pair), json=command)
    assert replay.status_code == 201 and replay.json() == first.json()
    conflict = client.post(
        BASE + '/commands', headers=auth(pair),
        json={**command, 'requestId': 'd' * 32},
    )
    assert conflict.status_code == 409
    assert worker.calls.__len__() == 1


def test_intent_cannot_be_consumed_from_another_session_family(server):
    app, client, _, _ = server
    pair, installation, current, _reader, _archive, _body = configured(server)
    worker = PlaybackWorker()
    app.state.core.media_playback.backend = worker
    intent = client.post(
        BASE + '/intents', headers=auth(pair),
        json=_request(installation, current),
    ).json()['intent']
    other_family = login(
        client, 'admin', 'Synthetic new password 2026',
        device='Other playback tablet').json()

    response = client.post(BASE + '/commands', headers=auth(other_family), json={
        'requestId': 'c' * 32,
        'intentId': intent['requestId'],
        'expectedPlaybackRevision': intent['playbackRevision'],
        'targetId': 'living-room',
        'expectedTargetRevision': 3,
        'startSeconds': 12,
    })

    assert response.status_code == 409
    assert response.json()['error']['code'] == 'media_playback_intent_unavailable'
    assert worker.reads == 1
    assert worker.calls == []


def test_intent_cannot_be_consumed_after_actor_revision_changes(server):
    app, client, _, _ = server
    pair, installation, current, _reader, _archive, _body = configured(server)
    worker = PlaybackWorker()
    app.state.core.media_playback.backend = worker
    intent = client.post(
        BASE + '/intents', headers=auth(pair),
        json=_request(installation, current),
    ).json()['intent']
    with app.state.core.db.transaction() as connection:
        connection.execute(
            'UPDATE users SET revision=revision+1 WHERE id=?',
            (pair['user']['id'],))

    response = client.post(BASE + '/commands', headers=auth(pair), json={
        'requestId': 'c' * 32,
        'intentId': intent['requestId'],
        'expectedPlaybackRevision': intent['playbackRevision'],
        'targetId': 'living-room',
        'expectedTargetRevision': 3,
        'startSeconds': 12,
    })

    assert response.status_code == 409
    assert response.json()['error']['code'] == 'media_playback_intent_unavailable'
    assert worker.reads == 1
    assert worker.calls == []


def test_intent_expiring_during_readback_is_not_claimed(server):
    app, client, _, clock = server
    pair, installation, current, _reader, _archive, _body = configured(server)
    worker = PlaybackWorker()
    app.state.core.media_playback.backend = worker
    intent = client.post(
        BASE + '/intents', headers=auth(pair),
        json=_request(installation, current),
    ).json()['intent']
    worker.read_change = lambda reads: setattr(
        clock, 'now', clock.now + 31) if reads == 2 else None

    response = client.post(BASE + '/commands', headers=auth(pair), json={
        'requestId': 'c' * 32,
        'intentId': intent['requestId'],
        'expectedPlaybackRevision': intent['playbackRevision'],
        'targetId': 'living-room',
        'expectedTargetRevision': 3,
        'startSeconds': 12,
    })

    assert response.status_code == 409
    assert response.json()['error']['code'] == 'media_playback_intent_conflict'
    with app.state.core.db.connection() as connection:
        row = connection.execute(
            'SELECT consumed_by FROM media_playback_intents WHERE id=?',
            (intent['requestId'],)).fetchone()
    assert row['consumed_by'] is None
    assert worker.calls == []


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


def test_actor_revision_change_after_dispatch_never_publishes_success(server):
    app, client, _, _ = server
    pair, installation, current, _reader, _archive, _body = configured(server)
    worker = PlaybackWorker()
    app.state.core.media_playback.backend = worker
    intent = client.post(
        BASE + '/intents', headers=auth(pair),
        json=_request(installation, current),
    ).json()['intent']

    def change_revision():
        with app.state.core.db.transaction() as connection:
            connection.execute(
                'UPDATE users SET revision=revision+1 WHERE id=?',
                (pair['user']['id'],))

    worker.change = change_revision
    command = {
        'requestId': '9' * 32,
        'intentId': intent['requestId'],
        'expectedPlaybackRevision': 7,
        'targetId': 'living-room',
        'expectedTargetRevision': 3,
        'startSeconds': 0,
    }

    response = client.post(BASE + '/commands', headers=auth(pair), json=command)

    assert response.status_code == 503
    assert response.json()['error']['code'] == 'media_playback_worker_unavailable'
    assert 'authenticated_readback' not in response.text
    assert len(worker.calls) == 1
    with app.state.core.db.connection() as connection:
        receipt = connection.execute(
            'SELECT state,receipt_json FROM media_playback_receipts '
            'WHERE request_id=?', (command['requestId'],)).fetchone()
    assert receipt['state'] == 'pending'
    assert receipt['receipt_json'] is None


def test_definite_pre_effect_denial_retires_attempt_without_uncertain_replay(
        server):
    app, client, _, _ = server
    pair, installation, current, _reader, _archive, _body = configured(server)
    worker = PlaybackWorker()
    app.state.core.media_playback.backend = worker
    intent = client.post(
        BASE + '/intents', headers=auth(pair),
        json=_request(installation, current),
    ).json()['intent']
    command = {
        'requestId': 'f' * 32,
        'intentId': intent['requestId'],
        'expectedPlaybackRevision': intent['playbackRevision'],
        'targetId': 'living-room',
        'expectedTargetRevision': 3,
        'startSeconds': 0,
    }
    worker.execute_error = JellyfinPlaybackExecutionError(
        'jellyfin_playback_authority_changed', uncertain_effect=False)

    first = client.post(BASE + '/commands', headers=auth(pair), json=command)
    replay = client.post(BASE + '/commands', headers=auth(pair), json=command)

    assert first.status_code == 409
    assert first.json()['error']['code'] == 'media_playback_authority_changed'
    assert replay.status_code == 409
    assert replay.json()['error']['code'] == 'media_playback_intent_unavailable'
    assert len(worker.calls) == 1
    with app.state.core.db.connection() as connection:
        assert connection.execute(
            'SELECT 1 FROM media_playback_receipts WHERE request_id=?',
            (command['requestId'],)).fetchone() is None
        assert connection.execute(
            'SELECT 1 FROM media_playback_intents WHERE id=?',
            (command['intentId'],)).fetchone() is None


def test_definite_pre_effect_resource_failure_retires_attempt_without_replay(
        server):
    app, client, _, _ = server
    pair, installation, current, _reader, _archive, _body = configured(server)
    worker = PlaybackWorker()
    app.state.core.media_playback.backend = worker
    intent = client.post(
        BASE + '/intents', headers=auth(pair),
        json=_request(installation, current),
    ).json()['intent']
    command = {
        'requestId': 'f' * 32,
        'intentId': intent['requestId'],
        'expectedPlaybackRevision': intent['playbackRevision'],
        'targetId': 'living-room',
        'expectedTargetRevision': 3,
        'startSeconds': 0,
    }
    worker.execute_error = JellyfinPlaybackExecutionError(
        'jellyfin_playback_resources_unavailable', uncertain_effect=False)

    first = client.post(BASE + '/commands', headers=auth(pair), json=command)
    replay = client.post(BASE + '/commands', headers=auth(pair), json=command)

    assert first.status_code == 503
    assert first.json()['error']['code'] == 'media_playback_worker_unavailable'
    assert replay.status_code == 409
    assert replay.json()['error']['code'] == 'media_playback_intent_unavailable'
    assert len(worker.calls) == 1
    with app.state.core.db.connection() as connection:
        assert connection.execute(
            'SELECT 1 FROM media_playback_receipts WHERE request_id=?',
            (command['requestId'],)).fetchone() is None
        assert connection.execute(
            'SELECT 1 FROM media_playback_intents WHERE id=?',
            (command['intentId'],)).fetchone() is None


def test_uncertain_post_effect_preserves_attempt_without_worker_replay(server):
    app, client, _, _ = server
    pair, installation, current, _reader, _archive, _body = configured(server)
    worker = PlaybackWorker()
    app.state.core.media_playback.backend = worker
    intent = client.post(
        BASE + '/intents', headers=auth(pair),
        json=_request(installation, current),
    ).json()['intent']
    command = {
        'requestId': 'f' * 32,
        'intentId': intent['requestId'],
        'expectedPlaybackRevision': intent['playbackRevision'],
        'targetId': 'living-room',
        'expectedTargetRevision': 3,
        'startSeconds': 0,
    }
    worker.execute_error = JellyfinPlaybackExecutionError(
        'jellyfin_playback_effect_unknown', uncertain_effect=True)

    first = client.post(BASE + '/commands', headers=auth(pair), json=command)
    replay = client.post(BASE + '/commands', headers=auth(pair), json=command)

    assert first.status_code == 503
    assert first.json()['error']['code'] == 'media_playback_worker_unavailable'
    assert replay.status_code == 201
    assert replay.json()['receipt']['state'] == 'needs_attention'
    assert replay.json()['receipt']['code'] == 'effect_unknown'
    assert len(worker.calls) == 1
    with app.state.core.db.connection() as connection:
        assert connection.execute(
            'SELECT 1 FROM media_playback_receipts WHERE request_id=?',
            (command['requestId'],)).fetchone() is not None
        assert connection.execute(
            'SELECT 1 FROM media_playback_intents WHERE id=?',
            (command['intentId'],)).fetchone() is not None


def test_intent_capacity_rejects_257th_prepare_without_growing_storage(server):
    app, client, _, _ = server
    pair, installation, current, _reader, _archive, _body = configured(server)
    app.state.core.media_playback.backend = PlaybackWorker()
    create_user(client, pair)
    member = activate(client, 'member')
    for index in range(256):
        response = client.post(
            BASE + '/intents', headers=auth(member),
            json=_request(installation, current, request_id=f'{index:032x}'))
        assert response.status_code == 200, response.text

    overflow = client.post(
        BASE + '/intents', headers=auth(member),
        json=_request(installation, current, request_id=f'{256:032x}'))

    assert overflow.status_code == 503
    assert overflow.json()['error']['code'] == 'media_playback_storage_unavailable'
    with app.state.core.db.connection() as connection:
        count = connection.execute(
            'SELECT COUNT(*) AS count FROM media_playback_intents'
        ).fetchone()['count']
    assert count == 256


def _fill_receipts(connection, *, actor_id, family_id, body, count=256,
                   state='pending'):
    actor_revision = connection.execute(
        'SELECT revision FROM users WHERE id=?', (actor_id,)).fetchone()[0]
    targets = json.dumps([{
        'targetId': 'living-room', 'targetRevision': 3,
        'name': 'Living room', 'available': True,
        'currentItemId': None, 'positionSeconds': 0,
    }], separators=(',', ':'), sort_keys=True)
    for index in range(count):
        intent_id = f'{index:032x}'
        request_id = f'{index + 1024:032x}'
        command = {
            'requestId': request_id,
            'intentId': intent_id,
            'expectedPlaybackRevision': 7,
            'targetId': 'living-room',
            'expectedTargetRevision': 3,
            'startSeconds': 0,
        }
        receipt = {
            'requestId': request_id,
            'intentId': intent_id,
            'installationId': body['installationId'],
            'itemId': body['itemId'],
            'targetId': 'living-room',
            'playbackRevision': 8,
            'state': 'succeeded',
            'code': 'authenticated_readback',
            'installAvailable': False,
        }
        connection.execute(
            'INSERT INTO media_playback_intents('
            'id,actor_id,actor_revision,family_id,installation_id,'
            'installation_revision,snapshot_revision,'
            'jellyfin_service_revision,item_id,media_key,playback_revision,'
            'targets_json,expires_at,consumed_by) '
            'VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
            (intent_id, actor_id, actor_revision, family_id,
             body['installationId'],
             body['expectedInstallationRevision'],
             body['expectedSnapshotRevision'],
             body['expectedJellyfinServiceRevision'], body['itemId'],
             body['mediaKey'], 7, targets, 1788613200, request_id))
        connection.execute(
            'INSERT INTO media_playback_receipts VALUES(?,?,?,?,?,?,?)',
            (request_id, intent_id, actor_id,
             json.dumps(command, separators=(',', ':'), sort_keys=True), state,
             (json.dumps(receipt, separators=(',', ':'), sort_keys=True)
              if state == 'succeeded' else None), 1788609600 + index))


def test_expired_intents_are_pruned_before_capacity_is_enforced(server):
    app, client, _, clock = server
    pair, installation, current, _reader, _archive, _body = configured(server)
    app.state.core.media_playback.backend = PlaybackWorker()
    for index in range(256):
        response = client.post(
            BASE + '/intents', headers=auth(pair),
            json=_request(installation, current, request_id=f'{index:032x}'))
        assert response.status_code == 200, response.text
    clock.now += 31

    response = client.post(
        BASE + '/intents', headers=auth(pair),
        json=_request(installation, current, request_id='f' * 32))

    assert response.status_code == 200, response.text
    with app.state.core.db.connection() as connection:
        count = connection.execute(
            'SELECT COUNT(*) AS count FROM media_playback_intents'
        ).fetchone()['count']
    assert count == 1


def test_pending_receipt_capacity_never_consumes_another_intent(server):
    app, client, _, _ = server
    pair, installation, current, _reader, _archive, _body = configured(server)
    body = _request(installation, current)
    worker = PlaybackWorker()
    app.state.core.media_playback.backend = worker
    candidate_id = 'f' * 32
    targets = json.dumps([{
        'targetId': 'living-room', 'targetRevision': 3,
        'name': 'Living room', 'available': True,
        'currentItemId': None, 'positionSeconds': 0,
    }], separators=(',', ':'), sort_keys=True)
    with app.state.core.db.transaction() as connection:
        _fill_receipts(
            connection, actor_id=pair['user']['id'],
            family_id=pair['sessionFamilyId'], body=body)
        actor_revision = connection.execute(
            'SELECT revision FROM users WHERE id=?',
            (pair['user']['id'],)).fetchone()[0]
        connection.execute(
            'INSERT INTO media_playback_intents('
            'id,actor_id,actor_revision,family_id,installation_id,'
            'installation_revision,snapshot_revision,'
            'jellyfin_service_revision,item_id,media_key,playback_revision,'
            'targets_json,expires_at,consumed_by) '
            'VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,NULL)',
            (candidate_id, pair['user']['id'], actor_revision,
             pair['sessionFamilyId'], body['installationId'],
             body['expectedInstallationRevision'],
             body['expectedSnapshotRevision'],
             body['expectedJellyfinServiceRevision'], body['itemId'],
             body['mediaKey'], 7, targets, 1788613200))

    response = client.post(BASE + '/commands', headers=auth(pair), json={
        'requestId': 'e' * 32, 'intentId': candidate_id,
        'expectedPlaybackRevision': 7, 'targetId': 'living-room',
        'expectedTargetRevision': 3, 'startSeconds': 0,
    })

    assert response.status_code == 503
    assert response.json()['error']['code'] == 'media_playback_storage_unavailable'
    with app.state.core.db.connection() as connection:
        receipt_count = connection.execute(
            'SELECT COUNT(*) AS count FROM media_playback_receipts'
        ).fetchone()['count']
        consumed_by = connection.execute(
            'SELECT consumed_by FROM media_playback_intents WHERE id=?',
            (candidate_id,)).fetchone()['consumed_by']
    assert receipt_count == 256
    assert consumed_by is None
    assert worker.calls == []


def test_oldest_succeeded_receipt_is_pruned_without_losing_pending_evidence(
        server):
    app, client, _, _ = server
    pair, installation, current, _reader, _archive, _body = configured(server)
    body = _request(installation, current)
    worker = PlaybackWorker()
    app.state.core.media_playback.backend = worker
    candidate_id = 'f' * 32
    targets = json.dumps([{
        'targetId': 'living-room', 'targetRevision': 3,
        'name': 'Living room', 'available': True,
        'currentItemId': None, 'positionSeconds': 0,
    }], separators=(',', ':'), sort_keys=True)
    with app.state.core.db.transaction() as connection:
        _fill_receipts(
            connection, actor_id=pair['user']['id'],
            family_id=pair['sessionFamilyId'], body=body, state='succeeded')
        actor_revision = connection.execute(
            'SELECT revision FROM users WHERE id=?',
            (pair['user']['id'],)).fetchone()[0]
        connection.execute(
            'INSERT INTO media_playback_intents('
            'id,actor_id,actor_revision,family_id,installation_id,'
            'installation_revision,snapshot_revision,'
            'jellyfin_service_revision,item_id,media_key,playback_revision,'
            'targets_json,expires_at,consumed_by) '
            'VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,NULL)',
            (candidate_id, pair['user']['id'], actor_revision,
             pair['sessionFamilyId'], body['installationId'],
             body['expectedInstallationRevision'],
             body['expectedSnapshotRevision'],
             body['expectedJellyfinServiceRevision'], body['itemId'],
             body['mediaKey'], 7, targets, 1788613200))

    response = client.post(BASE + '/commands', headers=auth(pair), json={
        'requestId': 'e' * 32, 'intentId': candidate_id,
        'expectedPlaybackRevision': 7, 'targetId': 'living-room',
        'expectedTargetRevision': 3, 'startSeconds': 0,
    })

    assert response.status_code == 201, response.text
    with app.state.core.db.connection() as connection:
        receipt_count = connection.execute(
            'SELECT COUNT(*) AS count FROM media_playback_receipts'
        ).fetchone()['count']
        oldest = connection.execute(
            'SELECT 1 FROM media_playback_receipts WHERE request_id=?',
            (f'{1024:032x}',)).fetchone()
    assert receipt_count == 256
    assert oldest is None
    assert len(worker.calls) == 1


def test_startup_validation_rejects_more_than_256_receipts(server):
    app, _, _, _ = server
    pair, installation, current, _reader, _archive, _body = configured(server)
    with app.state.core.db.transaction() as connection:
        _fill_receipts(
            connection, actor_id=pair['user']['id'],
            family_id=pair['sessionFamilyId'],
            body=_request(installation, current), count=257)

    with pytest.raises(StartupError, match='invalid_media_playback_storage'):
        app.state.core.media_playback.validate_storage()


def _insert_cross_bound_pending_receipt(server):
    app, client, _, _ = server
    pair, installation, current, _reader, _archive, _body = configured(server)
    app.state.core.media_playback.backend = PlaybackWorker()
    first = client.post(
        BASE + '/intents', headers=auth(pair),
        json=_request(installation, current, request_id='a' * 32),
    ).json()['intent']
    second = client.post(
        BASE + '/intents', headers=auth(pair),
        json=_request(installation, current, request_id='b' * 32),
    ).json()['intent']
    command = {
        'requestId': 'c' * 32,
        'intentId': second['requestId'],
        'expectedPlaybackRevision': second['playbackRevision'],
        'targetId': 'living-room',
        'expectedTargetRevision': 3,
        'startSeconds': 0,
    }
    encoded = json.dumps(command, separators=(',', ':'), sort_keys=True)
    with app.state.core.db.transaction() as connection:
        connection.execute(
            'UPDATE media_playback_intents SET consumed_by=? WHERE id=?',
            (command['requestId'], first['requestId']))
        connection.execute(
            'INSERT INTO media_playback_receipts VALUES(?,?,?,?,?,?,?)',
            (command['requestId'], first['requestId'], pair['user']['id'],
             encoded, 'pending', None, 1788609600))
    return app, client, pair, command


def test_startup_rejects_cross_bound_pending_receipt(server):
    app, _client, _pair, _command = _insert_cross_bound_pending_receipt(server)

    with pytest.raises(StartupError, match='invalid_media_playback_storage'):
        app.state.core.media_playback.validate_storage()


def test_runtime_replay_rejects_cross_bound_pending_receipt(server):
    _app, client, pair, command = _insert_cross_bound_pending_receipt(server)

    response = client.post(BASE + '/commands', headers=auth(pair), json=command)

    assert response.status_code == 503
    assert response.json()['error']['code'] == 'media_playback_storage_unavailable'


def test_succeeded_receipt_payload_must_match_bound_intent(server):
    app, client, _, _ = server
    pair, installation, current, _reader, _archive, _body = configured(server)
    app.state.core.media_playback.backend = PlaybackWorker()
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
        'startSeconds': 0,
    }
    first = client.post(BASE + '/commands', headers=auth(pair), json=command)
    assert first.status_code == 201, first.text
    corrupt = {**first.json()['receipt'], 'itemId': 'd' * 32}
    with app.state.core.db.transaction() as connection:
        connection.execute(
            'UPDATE media_playback_receipts SET receipt_json=? '
            'WHERE request_id=?',
            (json.dumps(corrupt, separators=(',', ':'), sort_keys=True),
             command['requestId']))

    with pytest.raises(StartupError, match='invalid_media_playback_storage'):
        app.state.core.media_playback.validate_storage()
    replay = client.post(BASE + '/commands', headers=auth(pair), json=command)
    assert replay.status_code == 503
    assert replay.json()['error']['code'] == 'media_playback_storage_unavailable'


def test_receipt_binding_drift_after_effect_never_publishes_success(server):
    app, client, _, _ = server
    pair, installation, current, _reader, _archive, _body = configured(server)
    worker = PlaybackWorker()
    app.state.core.media_playback.backend = worker
    first = client.post(
        BASE + '/intents', headers=auth(pair),
        json=_request(installation, current, request_id='a' * 32),
    ).json()['intent']
    second = client.post(
        BASE + '/intents', headers=auth(pair),
        json=_request(installation, current, request_id='b' * 32),
    ).json()['intent']
    command = {
        'requestId': 'c' * 32,
        'intentId': first['requestId'],
        'expectedPlaybackRevision': first['playbackRevision'],
        'targetId': 'living-room',
        'expectedTargetRevision': 3,
        'startSeconds': 0,
    }

    def drift_receipt():
        with app.state.core.db.transaction() as connection:
            connection.execute(
                'UPDATE media_playback_receipts SET intent_id=? '
                'WHERE request_id=?',
                (second['requestId'], command['requestId']))

    worker.change = drift_receipt
    response = client.post(BASE + '/commands', headers=auth(pair), json=command)

    assert response.status_code == 503
    assert response.json()['error']['code'] == 'media_playback_worker_unavailable'
    assert len(worker.calls) == 1
    assert 'authenticated_readback' not in response.text


def test_capacity_pruning_never_launders_a_corrupt_succeeded_receipt(server):
    app, client, _, _ = server
    pair, installation, current, _reader, _archive, _body = configured(server)
    body = _request(installation, current)
    worker = PlaybackWorker()
    app.state.core.media_playback.backend = worker
    candidate_id = 'f' * 32
    targets = json.dumps([{
        'targetId': 'living-room', 'targetRevision': 3,
        'name': 'Living room', 'available': True,
        'currentItemId': None, 'positionSeconds': 0,
    }], separators=(',', ':'), sort_keys=True)
    with app.state.core.db.transaction() as connection:
        _fill_receipts(
            connection, actor_id=pair['user']['id'],
            family_id=pair['sessionFamilyId'], body=body, state='succeeded')
        oldest_id = f'{1024:032x}'
        receipt = json.loads(connection.execute(
            'SELECT receipt_json FROM media_playback_receipts '
            'WHERE request_id=?', (oldest_id,)).fetchone()['receipt_json'])
        receipt['itemId'] = 'd' * 32
        connection.execute(
            'UPDATE media_playback_receipts SET receipt_json=? '
            'WHERE request_id=?',
            (json.dumps(receipt, separators=(',', ':'), sort_keys=True),
             oldest_id))
        connection.execute(
            'INSERT INTO media_playback_intents('
            'id,actor_id,actor_revision,family_id,installation_id,'
            'installation_revision,snapshot_revision,'
            'jellyfin_service_revision,item_id,media_key,playback_revision,'
            'targets_json,expires_at,consumed_by) '
            'VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,NULL)',
            (candidate_id, pair['user']['id'], connection.execute(
                'SELECT revision FROM users WHERE id=?',
                (pair['user']['id'],)).fetchone()[0],
             pair['sessionFamilyId'], body['installationId'],
             body['expectedInstallationRevision'],
             body['expectedSnapshotRevision'],
             body['expectedJellyfinServiceRevision'], body['itemId'],
             body['mediaKey'], 7, targets, 1788613200))

    response = client.post(BASE + '/commands', headers=auth(pair), json={
        'requestId': 'e' * 32, 'intentId': candidate_id,
        'expectedPlaybackRevision': 7, 'targetId': 'living-room',
        'expectedTargetRevision': 3, 'startSeconds': 0,
    })

    assert response.status_code == 503
    assert response.json()['error']['code'] == 'media_playback_storage_unavailable'
    with app.state.core.db.connection() as connection:
        candidate = connection.execute(
            'SELECT consumed_by FROM media_playback_intents WHERE id=?',
            (candidate_id,)).fetchone()
        oldest = connection.execute(
            'SELECT 1 FROM media_playback_receipts WHERE request_id=?',
            (oldest_id,)).fetchone()
    assert candidate['consumed_by'] is None
    assert oldest is not None
    assert worker.calls == []
