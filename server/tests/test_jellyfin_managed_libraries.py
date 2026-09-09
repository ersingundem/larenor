"""Idempotent managed Jellyfin library configuration on one proved stream."""

import inspect
import json

import pytest

from larenor_server.plugins.jellyfin_authenticated_readback import (
    JellyfinAuthenticatedReadbackResult,
)
from larenor_server.plugins.jellyfin_managed_libraries import (
    JellyfinManagedLibraries,
    JellyfinManagedLibrariesError,
)
from test_jellyfin_startup import Connection, response


KEY = 'c' * 32
DEVICE = 'a' * 32


def readback(libraries=()):
    return JellyfinAuthenticatedReadbackResult(
        'verified', '3' * 32, 'Larenor Jellyfin', '10.11.11', KEY,
        tuple(libraries),
        ('authenticated', 'keys_observed', 'key_verified', 'system_verified',
         'libraries_verified', 'session_closed'),
    )


def folder(name, collection, identifier, path):
    return {
        'Name': name,
        'Locations': [path],
        'CollectionType': collection,
        'ItemId': identifier,
        'PrimaryImageItemId': None,
        'RefreshProgress': None,
        'RefreshStatus': 'Idle',
        'LibraryOptions': {'EnableRealtimeMonitor': True},
    }


def json_response(value, status=200):
    return response(
        status, json.dumps(value, separators=(',', ':')).encode(),
        content_type=b'application/json',
    )


def request_line(raw):
    return raw.split(b'\r\n', 1)[0]


def test_creates_fixed_movies_and_shows_then_verifies_exact_readback():
    connection = Connection([
        json_response([]), response(), response(),
        json_response([
            folder('Larenor Movies', 'movies', '4' * 32, '/media/movies'),
            folder('Larenor Shows', 'tvshows', '5' * 32, '/media/shows'),
        ]),
    ])

    result = JellyfinManagedLibraries().ensure(
        connection, readback(), device_id=DEVICE,
    )

    assert result.state == 'verified'
    assert result.created == ('movies', 'shows')
    assert result.libraries == (
        ('Larenor Movies', 'movies', '4' * 32, ('/media/movies',)),
        ('Larenor Shows', 'tvshows', '5' * 32, ('/media/shows',)),
    )
    assert [request_line(raw) for raw in connection.requests] == [
        b'GET /Library/VirtualFolders HTTP/1.1',
        b'POST /Library/VirtualFolders?name=Larenor%20Movies&collectionType=movies&paths=%2Fmedia%2Fmovies&refreshLibrary=false HTTP/1.1',
        b'POST /Library/VirtualFolders?name=Larenor%20Shows&collectionType=tvshows&paths=%2Fmedia%2Fshows&refreshLibrary=false HTTP/1.1',
        b'GET /Library/VirtualFolders HTTP/1.1',
    ]
    assert all(b'Token=' + KEY.encode() in raw for raw in connection.requests)
    assert connection.closed and KEY not in repr(result)


def test_exact_existing_libraries_are_verified_without_mutation():
    listed = [
        folder('Larenor Movies', 'movies', '4' * 32, '/media/movies'),
        folder('Larenor Shows', 'tvshows', '5' * 32, '/media/shows'),
    ]
    connection = Connection([json_response(listed), json_response(listed)])

    result = JellyfinManagedLibraries().ensure(
        connection, readback(), device_id=DEVICE,
    )

    assert result.created == ()
    assert all(not raw.startswith(b'POST ') for raw in connection.requests)
    assert len(connection.requests) == 2 and connection.closed


@pytest.mark.parametrize('listed', [
    [folder('Larenor Movies', 'tvshows', '4' * 32, '/media/movies')],
    [folder('Other', 'movies', '4' * 32, '/media/movies')],
    [folder('Larenor Movies', 'movies', '4' * 32, '/media/other')],
])
def test_name_path_or_type_conflicts_fail_before_mutation(listed):
    connection = Connection([json_response(listed)])
    with pytest.raises(
        JellyfinManagedLibrariesError, match='^jellyfin_library_conflict$',
    ) as raised:
        JellyfinManagedLibraries().ensure(
            connection, readback(), device_id=DEVICE,
        )
    assert raised.value.completed_steps == ('observed',)
    assert not raised.value.uncertain_effect
    assert len(connection.requests) == 1 and connection.closed


def test_partial_creation_failure_is_uncertain_and_never_retried():
    connection = Connection([json_response([]), response(), response(status=500)])
    with pytest.raises(
        JellyfinManagedLibrariesError, match='^jellyfin_library_protocol$',
    ) as raised:
        JellyfinManagedLibraries().ensure(
            connection, readback(), device_id=DEVICE,
        )
    assert raised.value.completed_steps == ('observed', 'movies_created')
    assert raised.value.uncertain_effect
    assert len(connection.requests) == 3 and connection.closed


def test_closed_inputs_have_no_address_proxy_retry_or_user_library_controls():
    connection = Connection([])
    with pytest.raises(
        JellyfinManagedLibrariesError, match='^invalid_jellyfin_libraries$',
    ):
        JellyfinManagedLibraries().ensure(
            connection, 'private', device_id=DEVICE,
        )
    assert connection.requests == []
    parameters = inspect.signature(JellyfinManagedLibraries.ensure).parameters
    assert not {
        'url', 'host', 'port', 'resolver', 'proxy', 'headers', 'token',
        'names', 'paths', 'libraries', 'retry',
    } & set(parameters)
