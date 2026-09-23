import json
import os
from pathlib import Path
import tempfile
import time

from conftest import auth
from larenor_server.plugins.installation_ipc import (
    InstallationWorkerClient,
    InstallationWorkerServer,
)
from larenor_server.plugins.music_playback_models import (
    MusicLongformChapter,
    MusicLongformItem,
    MusicLongformWorkerResult,
    PrivateMusicLongformAction,
    ReadMusicLongformRequest,
)
from larenor_server.plugins.music_playback_runtime import MusicPlaybackRuntime
from test_music_manager_api import MANAGER, PRIVATE_TOKEN, ready_manager
from test_music_playback_runtime import Connection


def longform_body(setup, readiness, manager):
    return {
        'requestId': '8' * 32,
        'installationId': setup['installationId'],
        'expectedInstallationRevision': setup['installationRevision'],
        'expectedCoreRevision': readiness['revision'],
        'expectedManagerRevision': manager['revision'],
        'limit': 10,
    }


def result(provider='audiobookshelf--home'):
    return MusicLongformWorkerResult(items=[MusicLongformItem(
        uri='audiobookshelf://audiobook/book-one',
        name='Book One', mediaType='audiobook',
        providerInstanceId=provider,
        durationSeconds=3600, resumePositionSeconds=900,
        fullyPlayed=False,
        chapters=[
            MusicLongformChapter(
                position=0, name='Opening', startSeconds=0, endSeconds=600),
            MusicLongformChapter(
                position=1, name='Chapter one', startSeconds=600,
                endSeconds=1800),
        ],
    )])


def private_action():
    return PrivateMusicLongformAction(
        request=ReadMusicLongformRequest(
            requestId='8' * 32, installationId='b' * 32,
            expectedInstallationRevision=3, expectedCoreRevision=2,
            expectedManagerRevision=1, limit=10),
        allowedProviderInstanceIds=['audiobookshelf--home'],
        token='private-token')


def raw_item(*, uri='audiobookshelf://audiobook/book-one',
             provider='audiobookshelf--home'):
    return {
        'uri': uri, 'name': 'Book One', 'media_type': 'audiobook',
        'provider': provider, 'duration': 3600,
        'resume_position_ms': 900000, 'fully_played': False,
        'metadata': {'chapters': [
            {'position': 0, 'name': 'Opening', 'start': 0, 'end': 600},
            {'position': 1, 'name': 'Chapter one', 'start': 600, 'end': 1800},
        ]},
    }


def test_runtime_reads_fresh_details_for_each_bounded_in_progress_item():
    calls = []
    summary = raw_item()
    summary.pop('metadata')
    responses = [[summary], raw_item()]
    runtime = MusicPlaybackRuntime(lambda _timeout: Connection(responses, calls))

    observed = runtime.longform(private_action(), deadline=time.monotonic() + 2)

    assert observed == result()
    assert [call[2]['command'] for call in calls] == [
        'music/in_progress_items', 'music/item_by_uri']
    assert calls[0][2]['args'] == {'limit': 10}
    assert calls[1][2]['args'] == {
        'uri': 'audiobookshelf://audiobook/book-one'}
    assert all(call[3]['Authorization'] == 'Bearer private-token'
               for call in calls)


def test_runtime_rejects_detail_that_does_not_match_in_progress_identity():
    calls = []
    summary = raw_item()
    summary.pop('metadata')
    responses = [[summary], raw_item(uri='audiobookshelf://audiobook/other')]
    runtime = MusicPlaybackRuntime(lambda _timeout: Connection(responses, calls))

    try:
        runtime.longform(private_action(), deadline=time.monotonic() + 2)
    except Exception as error:
        assert str(error) == 'music_longform_readback_changed'
    else:
        raise AssertionError('mismatched detail was accepted')


def test_runtime_rejects_secret_bearing_longform_identity_before_publication():
    for private_uri in (
            'https://private.example/token=secret',
            'audiobookshelf://book-one?token=secret',
            'audiobookshelf://user:secret@book-one'):
        calls = []
        summary = raw_item(uri=private_uri)
        summary.pop('metadata')
        responses = [[summary], raw_item(uri=private_uri)]
        runtime = MusicPlaybackRuntime(
            lambda _timeout: Connection(responses, calls))

        try:
            runtime.longform(private_action(), deadline=time.monotonic() + 2)
        except Exception as error:
            assert str(error) == 'music_longform_readback_changed'
            assert private_uri not in str(error)
        else:
            raise AssertionError('secret-bearing media identity was accepted')


def test_runtime_rejects_detail_from_an_unbound_provider_instance():
    calls = []
    summary = raw_item()
    summary.pop('metadata')
    responses = [[summary], raw_item(provider='unbound-provider')]
    runtime = MusicPlaybackRuntime(lambda _timeout: Connection(responses, calls))

    try:
        runtime.longform(private_action(), deadline=time.monotonic() + 2)
    except Exception as error:
        assert str(error) == 'music_longform_readback_changed'
    else:
        raise AssertionError('unbound provider detail was accepted')


def test_runtime_rejects_falsey_malformed_longform_metadata():
    calls = []
    summary = raw_item()
    summary.pop('metadata')
    malformed = raw_item()
    malformed['metadata'] = []
    responses = [[summary], malformed]
    runtime = MusicPlaybackRuntime(lambda _timeout: Connection(responses, calls))

    try:
        runtime.longform(private_action(), deadline=time.monotonic() + 2)
    except Exception as error:
        assert str(error) == 'music_longform_readback_changed'
    else:
        raise AssertionError('falsey malformed metadata was accepted')


def test_runtime_rejects_overlapping_longform_chapters():
    calls = []
    summary = raw_item()
    summary.pop('metadata')
    overlapping = raw_item()
    overlapping['metadata']['chapters'][0]['end'] = 900
    overlapping['metadata']['chapters'][1]['start'] = 600
    responses = [[summary], overlapping]
    runtime = MusicPlaybackRuntime(lambda _timeout: Connection(responses, calls))

    try:
        runtime.longform(private_action(), deadline=time.monotonic() + 2)
    except Exception as error:
        assert str(error) == 'music_longform_readback_changed'
    else:
        raise AssertionError('overlapping chapter boundaries were accepted')


def test_private_worker_ipc_returns_longform_without_token():
    class Backend:
        def read_music_longform(self, action, *, deadline, gate):
            assert gate() is True
            assert action.request.limit == 10
            return result()

    base = '/private/tmp' if Path('/private/tmp').is_dir() else '/tmp'
    with tempfile.TemporaryDirectory(prefix='f28-', dir=base) as root:
        path = Path(root) / 'worker.sock'
        server = InstallationWorkerServer(
            path, Backend(), allowed_uid=os.getuid(),
            peer_uid=lambda _connection: os.getuid(), timeout=1)
        server.start()
        try:
            client = InstallationWorkerClient(
                path, owner_uid=os.getuid(),
                peer_uid=lambda _connection: os.getuid(), timeout=1)
            observed = client.read_music_longform(
                private_action(), deadline=time.monotonic() + 1,
                gate=lambda: True)
            assert observed == result()
            assert 'private-token' not in observed.model_dump_json()
        finally:
            server.close()


def test_in_progress_catalog_exposes_bounded_progress_and_chapters(server):
    pair, setup, readiness, worker, manager = ready_manager(server)
    reads = []
    provider = manager['providers'][0]['providerInstanceId']

    def read(action, *, deadline, gate):
        assert gate() is True
        reads.append(action)
        return result(provider)

    worker.read_music_longform = read
    response = server[1].post(
        MANAGER + '/catalog/in-progress', headers=auth(pair),
        json=longform_body(setup, readiness, manager))

    assert response.status_code == 200, response.text
    assert response.json()['longform']['items'][0] == {
        'uri': 'audiobookshelf://audiobook/book-one',
        'name': 'Book One', 'mediaType': 'audiobook',
        'providerInstanceId': provider,
        'durationSeconds': 3600.0, 'resumePositionSeconds': 900.0,
        'fullyPlayed': False,
        'chapters': [
            {'position': 0, 'name': 'Opening', 'startSeconds': 0.0,
             'endSeconds': 600.0},
            {'position': 1, 'name': 'Chapter one', 'startSeconds': 600.0,
             'endSeconds': 1800.0},
        ],
    }
    assert len(reads) == 1
    assert PRIVATE_TOKEN not in response.text + repr(reads[0])
    schema = server[1].get(
        '/api/v1/openapi.json', headers=auth(pair)).json()
    public = json.dumps([
        schema['components']['schemas']['ReadMusicLongformRequest'],
        schema['components']['schemas']['MusicLongformCatalogResponse'],
    ]).lower()
    assert 'token' not in public and 'password' not in public


def test_manager_revision_drift_discards_longform_result(server):
    app, client, _, _ = server
    pair, setup, readiness, worker, manager = ready_manager(server)
    provider = manager['providers'][0]['providerInstanceId']

    def drift(action, *, deadline, gate):
        assert gate() is True
        with app.state.core.db.transaction() as connection:
            row = connection.execute(
                'SELECT * FROM music_playback WHERE installation_id=?',
                (setup['installationId'],)).fetchone()
            stored = app.state.core.music_playback._decode(row)
            changed = dict(row)
            changed['revision'] += 1
            app.state.core.music_playback._save(connection, changed, stored)
        return result(provider)

    worker.read_music_longform = drift
    response = client.post(
        MANAGER + '/catalog/in-progress', headers=auth(pair),
        json=longform_body(setup, readiness, manager))

    assert response.status_code == 503
    assert response.json()['error']['code'] == 'music_longform_worker_unavailable'
    assert 'Book One' not in response.text


def test_invalid_longform_result_is_never_published(server):
    pair, setup, readiness, worker, manager = ready_manager(server)

    def wrong(action, *, deadline, gate):
        return {'items': [{'uri': 'https://private.example/token=secret'}]}

    worker.read_music_longform = wrong
    response = server[1].post(
        MANAGER + '/catalog/in-progress', headers=auth(pair),
        json=longform_body(setup, readiness, manager))

    assert response.status_code == 503
    assert response.json()['error']['code'] == 'music_longform_worker_unavailable'
    assert 'private.example' not in response.text
