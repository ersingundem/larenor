import json

import pytest
from conftest import auth
from larenor_server.plugins.media_archive_health_models import (
    JellyfinArchiveItem,
)
from larenor_server.plugins.media_installations import BINDING
from test_admin import activate
from test_admin import create as create_user
from test_media_archive_core_read import configured

BASE = '/api/v1/admin/media/archive-health/catalog/search'
MEMBER_TARGET = '/api/v1/media/catalog/target'
MEMBER_SEARCH = '/api/v1/media/catalog/search'
MEMBER_BROWSE = '/api/v1/media/catalog/browse'
MEMBER_RESOLVE = '/api/v1/media/catalog/resolve'


def _items(worker):
    current = worker.result.jellyfin.items[0]
    worker.result = worker.result.model_copy(update={
        'jellyfin': worker.result.jellyfin.model_copy(update={'items': [
            current,
            JellyfinArchiveItem(
                itemId='c' * 32,
                mediaKey='movie:tmdb:604',
                title='Matrix Reloaded',
                mediaKind='movie',
                sizeBytes=9_000,
                integrity='playable',
                runtimeSeconds=8_280,
            ),
            JellyfinArchiveItem(
                itemId='d' * 32,
                mediaKey='episode:tvdb:101:1:3',
                title='Matrix episode',
                mediaKind='episode',
                sizeBytes=1_000,
                integrity='playable',
            ),
            JellyfinArchiveItem(
                itemId='e' * 32,
                mediaKey='movie:tmdb:605',
                title='Matrix damaged',
                mediaKind='movie',
                sizeBytes=500,
                integrity='corrupt',
            ),
        ]}),
    })


def test_search_is_bounded_revision_bound_and_secret_free(server):
    pair, installation, _current, reader, worker, body = configured(server)
    _items(worker)
    request = {
        **body,
        'query': 'matrix',
        'mediaKind': 'movie',
        'offset': 0,
        'limit': 1,
    }

    first = server[1].post(BASE, headers=auth(pair), json=request)
    assert first.status_code == 200, first.text
    assert first.json() == {
        'requestId': 'e' * 32,
        'catalog': {
            'schemaVersion': 1,
            'installationId': installation['id'],
            'installationRevision': installation['revision'],
            'snapshotRevision': 4,
            'jellyfinServiceRevision': 8,
            'offset': 0,
            'nextOffset': 1,
            'total': 2,
            'items': [{
                'itemId': 'c' * 32,
                'mediaKey': 'movie:tmdb:604',
                'title': 'Matrix Reloaded',
                'mediaKind': 'movie',
                'runtimeSeconds': 8_280,
            }],
        },
    }
    assert reader.calls == 2 and len(worker.calls) == 1
    wire = json.dumps(first.json()).lower()
    assert all(secret not in wire for secret in (
        'token', 'password', 'cookie', 'endpoint', '/media/', '/data/'))

    second = server[1].post(BASE, headers=auth(pair), json={
        **request, 'offset': 1,
    })
    assert second.status_code == 200, second.text
    catalog = second.json()['catalog']
    assert catalog['nextOffset'] is None
    assert [item['title'] for item in catalog['items']] == ['The Matrix']


@pytest.mark.parametrize('change', [
    {'query': ' x'},
    {'query': 'x\n'},
    {'query': 'x\u202e'},
    {'query': 'x' * 81},
    {'mediaKind': 'audio'},
    {'offset': True},
    {'offset': 4097},
    {'limit': 0},
    {'limit': 51},
    {'accessToken': 'must-not-cross-boundary'},
])
def test_invalid_search_never_reaches_private_worker(server, change):
    pair, _installation, _current, _reader, worker, body = configured(server)
    response = server[1].post(BASE, headers=auth(pair), json={
        **body,
        'query': 'matrix',
        'mediaKind': None,
        'offset': 0,
        'limit': 24,
        **change,
    })
    assert response.status_code == 400
    assert worker.calls == []
    assert 'must-not-cross-boundary' not in response.text


def test_cross_kind_worker_item_fails_before_publication(server):
    pair, _installation, _current, _reader, worker, body = configured(server)
    forged = worker.result.jellyfin.items[0].model_copy(update={
        'mediaKind': 'episode',
    })
    worker.result = worker.result.model_copy(update={
        'jellyfin': worker.result.jellyfin.model_copy(update={
            'items': [forged],
        }),
    })
    response = server[1].post(BASE, headers=auth(pair), json={
        **body,
        'query': 'matrix',
        'mediaKind': None,
        'offset': 0,
        'limit': 24,
    })
    assert response.status_code == 503
    assert response.json()['error']['code'] == 'media_archive_worker_unavailable'


def test_search_rechecks_binding_session_and_admin_policy(server):
    pair, _installation, current, reader, worker, body = configured(server)
    request = {
        **body,
        'query': 'matrix',
        'mediaKind': None,
        'offset': 0,
        'limit': 24,
    }
    changed = current.model_copy(update={
        'snapshotRevision': 5,
        'sources': [item.model_copy(update={'snapshotRevision': 5})
                    for item in current.sources],
    })
    reader.values = [current, changed]
    response = server[1].post(BASE, headers=auth(pair), json=request)
    assert response.status_code == 409
    assert response.json()['error']['code'] == 'media_archive_authority_changed'
    assert len(worker.calls) == 1

    worker.calls.clear()
    create_user(server[1], pair)
    member = activate(server[1], 'member')
    response = server[1].post(BASE, headers=auth(member), json=request)
    assert response.status_code == 403
    assert worker.calls == []

    reader.values = [current]
    worker.calls.clear()
    worker.change = lambda: server[1].post(
        '/api/v1/auth/logout', headers=auth(pair))
    response = server[1].post(BASE, headers=auth(pair), json=request)
    assert response.status_code == 401
    assert len(worker.calls) == 1


def test_member_discovers_and_searches_catalog_without_admin_surface(server):
    pair, installation, _current, reader, worker, body = configured(server)
    _items(worker)
    create_user(server[1], pair)
    member = activate(server[1], 'member')

    target = server[1].get(MEMBER_TARGET, headers=auth(member))
    assert target.status_code == 200, target.text
    assert target.json() == {
        'schemaVersion': 1,
        'installationId': installation['id'],
        'installationRevision': installation['revision'],
        'snapshotRevision': 4,
        'jellyfinServiceRevision': 8,
    }
    response = server[1].post(MEMBER_SEARCH, headers=auth(member), json={
        **body,
        'query': 'matrix',
        'mediaKind': 'movie',
        'offset': 0,
        'limit': 1,
    })
    assert response.status_code == 200, response.text
    assert response.json()['catalog']['items'][0]['title'] == 'Matrix Reloaded'
    assert reader.calls == 3 and len(worker.calls) == 1
    wire = json.dumps(target.json() | response.json()).lower()
    assert all(secret not in wire for secret in (
        'token', 'password', 'cookie', 'endpoint', '/media/', '/data/'))


def test_member_search_rechecks_session_after_private_worker(server):
    pair, _installation, _current, _reader, worker, body = configured(server)
    create_user(server[1], pair)
    member = activate(server[1], 'member')
    worker.change = lambda: server[1].post(
        '/api/v1/auth/logout', headers=auth(member))

    response = server[1].post(MEMBER_SEARCH, headers=auth(member), json={
        **body,
        'query': 'matrix',
        'mediaKind': None,
        'offset': 0,
        'limit': 24,
    })
    assert response.status_code == 401
    assert len(worker.calls) == 1


def test_member_search_rejects_a_non_unique_ready_target(server):
    app, client, _settings, _clock = server
    pair, installation, _current, _reader, worker, body = configured(server)
    create_user(client, pair)
    member = activate(client, 'member')
    manager = app.state.core.media_installations
    with app.state.core.db.transaction() as connection:
        source = dict(connection.execute(
            'SELECT * FROM media_installations WHERE id=?',
            (installation['id'],),
        ).fetchone())
        payload = manager._decode(source)
        clone = source | {
            'id': 'f' * 32,
            'sequence': source['sequence'] + 1,
            'request_id': 'f' * 32,
        }
        cloned_payload = payload.model_copy(update={
            'request': payload.request.model_copy(update={
                'requestId': clone['request_id'],
            }),
        })
        connection.execute(
            'INSERT INTO media_installations('
            + ','.join(BINDING)
            + ',nonce,ciphertext) VALUES('
            + ','.join('?' for _ in range(len(BINDING) + 2))
            + ')',
            (*[clone[key] for key in BINDING], source['nonce'],
             source['ciphertext']),
        )
        manager._save(connection, clone, cloned_payload)

    target = client.get(MEMBER_TARGET, headers=auth(member))
    assert target.status_code == 409
    response = client.post(MEMBER_SEARCH, headers=auth(member), json={
        **body,
        'query': 'matrix',
        'mediaKind': None,
        'offset': 0,
        'limit': 24,
    })
    assert response.status_code == 409
    assert response.json()['error']['code'] == target.json()['error']['code']
    assert worker.calls == []


def test_member_browse_is_bounded_sorted_and_revision_bound(server):
    pair, installation, _current, reader, worker, body = configured(server)
    _items(worker)
    create_user(server[1], pair)
    member = activate(server[1], 'member')

    first = server[1].post(MEMBER_BROWSE, headers=auth(member), json={
        **body,
        'mediaKind': None,
        'offset': 0,
        'limit': 2,
    })
    assert first.status_code == 200, first.text
    assert first.json() == {
        'requestId': 'e' * 32,
        'catalog': {
            'schemaVersion': 1,
            'installationId': installation['id'],
            'installationRevision': installation['revision'],
            'snapshotRevision': 4,
            'jellyfinServiceRevision': 8,
            'offset': 0,
            'nextOffset': 2,
            'total': 3,
            'items': [
                {
                    'itemId': 'd' * 32,
                    'mediaKey': 'episode:tvdb:101:1:3',
                    'title': 'Matrix episode',
                    'mediaKind': 'episode',
                    'runtimeSeconds': None,
                },
                {
                    'itemId': 'c' * 32,
                    'mediaKey': 'movie:tmdb:604',
                    'title': 'Matrix Reloaded',
                    'mediaKind': 'movie',
                    'runtimeSeconds': 8_280,
                },
            ],
        },
    }
    second = server[1].post(MEMBER_BROWSE, headers=auth(member), json={
        **body,
        'mediaKind': None,
        'offset': 2,
        'limit': 2,
    })
    assert second.status_code == 200, second.text
    assert second.json()['catalog']['nextOffset'] is None
    assert [item['title'] for item in second.json()['catalog']['items']] == [
        'The Matrix',
    ]
    assert reader.calls == 4 and len(worker.calls) == 2


@pytest.mark.parametrize('change', [
    {'query': 'matrix'},
    {'sort': 'added'},
    {'offset': True},
    {'offset': 4097},
    {'limit': 0},
    {'limit': 51},
    {'accessToken': 'must-not-cross-boundary'},
])
def test_invalid_member_browse_never_reaches_private_worker(server, change):
    pair, _installation, _current, _reader, worker, body = configured(server)
    create_user(server[1], pair)
    member = activate(server[1], 'member')
    response = server[1].post(MEMBER_BROWSE, headers=auth(member), json={
        **body,
        'mediaKind': None,
        'offset': 0,
        'limit': 24,
        **change,
    })
    assert response.status_code == 400
    assert worker.calls == []
    assert 'must-not-cross-boundary' not in response.text


def test_member_browse_rechecks_session_after_private_worker(server):
    pair, _installation, _current, _reader, worker, body = configured(server)
    create_user(server[1], pair)
    member = activate(server[1], 'member')
    worker.change = lambda: server[1].post(
        '/api/v1/auth/logout', headers=auth(member))

    response = server[1].post(MEMBER_BROWSE, headers=auth(member), json={
        **body,
        'mediaKind': None,
        'offset': 0,
        'limit': 24,
    })
    assert response.status_code == 401
    assert len(worker.calls) == 1


def test_member_resolves_one_opaque_row_item_through_current_catalog(server):
    pair, installation, _current, reader, worker, body = configured(server)
    _items(worker)
    create_user(server[1], pair)
    member = activate(server[1], 'member')

    response = server[1].post(MEMBER_RESOLVE, headers=auth(member), json={
        **body,
        'itemId': 'd' * 32,
    })

    assert response.status_code == 200, response.text
    assert response.json() == {
        'requestId': 'e' * 32,
        'catalog': {
            'schemaVersion': 1,
            'installationId': installation['id'],
            'installationRevision': installation['revision'],
            'snapshotRevision': 4,
            'jellyfinServiceRevision': 8,
            'offset': 0,
            'nextOffset': None,
            'total': 1,
            'items': [{
                'itemId': 'd' * 32,
                'mediaKey': 'episode:tvdb:101:1:3',
                'title': 'Matrix episode',
                'mediaKind': 'episode',
                'runtimeSeconds': None,
            }],
        },
    }
    assert reader.calls == 2 and len(worker.calls) == 1


def test_member_resolve_rejects_missing_or_unplayable_items(server):
    pair, _installation, _current, _reader, worker, body = configured(server)
    _items(worker)
    create_user(server[1], pair)
    member = activate(server[1], 'member')

    for item_id in ('e' * 32, 'f' * 32):
        response = server[1].post(MEMBER_RESOLVE, headers=auth(member), json={
            **body,
            'itemId': item_id,
        })
        assert response.status_code == 404
        assert response.json()['error']['code'] == \
            'media_catalog_item_unavailable'


def test_invalid_member_resolve_never_reaches_private_worker(server):
    pair, _installation, _current, _reader, worker, body = configured(server)
    create_user(server[1], pair)
    member = activate(server[1], 'member')

    response = server[1].post(MEMBER_RESOLVE, headers=auth(member), json={
        **body,
        'itemId': 'not-an-id',
    })
    assert response.status_code == 400
    assert worker.calls == []
