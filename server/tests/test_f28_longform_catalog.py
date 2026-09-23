import json

from conftest import auth
from larenor_server.plugins.music_playback_models import (
    MusicLongformChapter,
    MusicLongformItem,
    MusicLongformWorkerResult,
)
from test_music_manager_api import MANAGER, PRIVATE_TOKEN, ready_manager


def longform_body(setup, readiness, manager):
    return {
        'requestId': '8' * 32,
        'installationId': setup['installationId'],
        'expectedInstallationRevision': setup['installationRevision'],
        'expectedCoreRevision': readiness['revision'],
        'expectedManagerRevision': manager['revision'],
        'limit': 10,
    }


def result():
    return MusicLongformWorkerResult(items=[MusicLongformItem(
        uri='audiobookshelf://audiobook/book-one',
        name='Book One', mediaType='audiobook',
        providerInstanceId='audiobookshelf--home',
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


def test_in_progress_catalog_exposes_bounded_progress_and_chapters(server):
    pair, setup, readiness, worker, manager = ready_manager(server)
    reads = []

    def read(action, *, deadline, gate):
        assert gate() is True
        reads.append(action)
        return result()

    worker.read_music_longform = read
    response = server[1].post(
        MANAGER + '/catalog/in-progress', headers=auth(pair),
        json=longform_body(setup, readiness, manager))

    assert response.status_code == 200, response.text
    assert response.json()['longform']['items'][0] == {
        'uri': 'audiobookshelf://audiobook/book-one',
        'name': 'Book One', 'mediaType': 'audiobook',
        'providerInstanceId': 'audiobookshelf--home',
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
    schema = server[1].get('/api/v1/openapi.json').json()
    public = json.dumps([
        schema['components']['schemas']['ReadMusicLongformRequest'],
        schema['components']['schemas']['MusicLongformCatalogResponse'],
    ]).lower()
    assert 'token' not in public and 'password' not in public


def test_manager_revision_drift_discards_longform_result(server):
    app, client, _, _ = server
    pair, setup, readiness, worker, manager = ready_manager(server)

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
        return result()

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
