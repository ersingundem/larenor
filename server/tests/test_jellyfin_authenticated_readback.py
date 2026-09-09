"""Authenticated Jellyfin key, identity and library readback on one proved stream."""

import inspect
import json
import socket

import pytest

from larenor_server.plugins.jellyfin_authenticated_readback import (
    JellyfinAuthenticatedReadback,
    JellyfinAuthenticatedReadbackError,
    JellyfinAuthenticatedReadbackLimits,
)
from larenor_server.plugins.media_service_bootstrap_models import PrivateMediaServiceBootstrap
from test_jellyfin_startup import Connection, SECRET, response


DEVICE = 'a' * 32
SESSION = 'b' * 32
API_KEY = 'c' * 32


def private():
    return PrivateMediaServiceBootstrap(credential=SECRET)


def json_response(value, status=200):
    return response(
        status,
        json.dumps(value, separators=(',', ':')).encode(),
        content_type=b'application/json',
    )


def authentication():
    return {
        'User': {'Id': '1' * 32, 'Name': 'larenor-system'},
        'SessionInfo': {'Id': '2' * 32},
        'AccessToken': SESSION,
        'ServerId': '3' * 32,
    }


def keys(*items):
    return {'Items': list(items), 'TotalRecordCount': len(items), 'StartIndex': 0}


def key(token=API_KEY, *, app='Larenor Core', active=False, revoked=None):
    return {
        'Id': 0,
        'AccessToken': token,
        'DeviceId': '',
        'AppName': app,
        'AppVersion': '',
        'DeviceName': '',
        'UserId': '0' * 32,
        'IsActive': active,
        'DateCreated': '2026-09-09T00:00:00.0000000Z',
        'DateRevoked': revoked,
        'DateLastActivity': '0001-01-01T00:00:00.0000000Z',
        'UserName': None,
    }


def serialized_key(token=API_KEY):
    """Match Jellyfin's WhenWritingNull response serialization."""
    return {name: value for name, value in key(token).items() if value is not None}


def system():
    return {
        'ServerName': 'Larenor Jellyfin',
        'Version': '10.11.0',
        'ProductName': 'Jellyfin Server',
        'Id': '3' * 32,
        'StartupWizardCompleted': True,
        'LocalAddress': 'http://172.28.0.2:8096',
        'ProgramDataPath': '/config',
    }


def folders():
    return [{
        'Name': 'Filmler',
        'Locations': ['/media/movies'],
        'CollectionType': 'movies',
        'ItemId': '4' * 32,
        'PrimaryImageItemId': None,
        'RefreshProgress': None,
        'RefreshStatus': 'Idle',
        'LibraryOptions': {'EnableRealtimeMonitor': True},
    }]


def request_parts(raw):
    head, body = raw.split(b'\r\n\r\n', 1)
    return head.split(b'\r\n'), body


def test_creates_one_dedicated_key_then_reads_closed_identity_and_libraries():
    connection = Connection([
        json_response(authentication()),
        json_response(keys()),
        response(),
        json_response(keys(key())),
        json_response(system()),
        json_response(folders()),
        response(),
    ])

    result = JellyfinAuthenticatedReadback().read(
        connection, private(), device_id=DEVICE,
    )

    assert result.state == 'verified'
    assert result.api_key == API_KEY
    assert result.server_id == '3' * 32
    assert result.server_name == 'Larenor Jellyfin'
    assert result.version == '10.11.0'
    assert result.libraries == (('Filmler', 'movies', '4' * 32, ('/media/movies',)),)
    assert result.completed_steps == (
        'authenticated', 'keys_observed', 'key_created', 'key_verified',
        'system_verified', 'libraries_verified', 'session_closed',
    )
    assert len(connection.requests) == 7 and connection.closed
    lines = [request_parts(raw)[0][0] for raw in connection.requests]
    assert lines == [
        b'POST /Users/AuthenticateByName HTTP/1.1',
        b'GET /Auth/Keys HTTP/1.1',
        b'POST /Auth/Keys?app=Larenor%20Core HTTP/1.1',
        b'GET /Auth/Keys HTTP/1.1',
        b'GET /System/Info HTTP/1.1',
        b'GET /Library/VirtualFolders HTTP/1.1',
        b'POST /Sessions/Logout HTTP/1.1',
    ]
    first_head, first_body = request_parts(connection.requests[0])
    assert json.loads(first_body) == {'Username': 'larenor-system', 'Pw': SECRET}
    assert b'Authorization: MediaBrowser Client="Larenor%20Core", Device="Larenor%20Core", DeviceId="' + DEVICE.encode() + b'", Version="0.1.0"' in first_head
    token_headers = [b'\n'.join(request_parts(raw)[0]) for raw in connection.requests]
    assert all(b'Token=' + SESSION.encode() in token_headers[index]
               for index in (1, 2, 3, 6))
    assert all(b'Token=' + API_KEY.encode() in token_headers[index]
               for index in (4, 5))
    private_text = repr(result)
    assert API_KEY not in private_text and SESSION not in private_text
    assert '/media/movies' not in private_text and SECRET not in private_text


def test_existing_single_projected_larenor_key_is_reused_without_mutation():
    connection = Connection([
        json_response(authentication()),
        json_response(keys(key())),
        json_response(system()),
        json_response([]),
        response(),
    ])

    result = JellyfinAuthenticatedReadback().read(
        connection, private(), device_id=DEVICE,
    )

    assert result.api_key == API_KEY
    assert result.completed_steps == (
        'authenticated', 'keys_observed', 'key_verified',
        'system_verified', 'libraries_verified', 'session_closed',
    )
    assert all(not raw.startswith(b'POST /Auth/Keys') for raw in connection.requests)


def test_created_key_accepts_the_exact_null_omitting_jellyfin_wire_shape():
    connection = Connection([
        json_response(authentication()),
        json_response(keys()),
        response(),
        json_response(keys(serialized_key())),
        json_response(system()),
        json_response([]),
        response(),
    ])

    result = JellyfinAuthenticatedReadback().read(
        connection, private(), device_id=DEVICE,
    )

    assert result.api_key == API_KEY
    assert result.completed_steps[-1] == 'session_closed'


@pytest.mark.parametrize('listed', [
    keys({name: value for name, value in serialized_key().items() if name != 'UserId'}),
    keys(serialized_key() | {'Unexpected': 'private'}),
])
def test_created_key_still_requires_all_nonnullable_fields_and_no_extras(listed):
    connection = Connection([json_response(authentication()), json_response(listed)])
    with pytest.raises(
        JellyfinAuthenticatedReadbackError,
        match='^jellyfin_authenticated_readback_protocol$',
    ):
        JellyfinAuthenticatedReadback().read(connection, private(), device_id=DEVICE)


def test_unicode_display_names_are_preserved_without_relaxing_private_paths():
    named_system = system() | {'ServerName': 'Ersin’in Evi'}
    named_folders = folders()
    named_folders[0] = named_folders[0] | {'Name': 'Çocuk Filmleri'}
    connection = Connection([
        json_response(authentication()),
        json_response(keys(key())),
        json_response(named_system),
        json_response(named_folders),
        response(),
    ])

    result = JellyfinAuthenticatedReadback().read(
        connection, private(), device_id=DEVICE,
    )

    assert result.server_name == 'Ersin’in Evi'
    assert result.libraries[0][0] == 'Çocuk Filmleri'


def test_session_cleanup_is_required_after_successful_readback():
    connection = Connection([
        json_response(authentication()),
        json_response(keys(key())),
        json_response(system()),
        json_response(folders()),
        json_response({'error': 'private'}, status=500),
    ])

    with pytest.raises(
        JellyfinAuthenticatedReadbackError,
        match='^jellyfin_session_cleanup_failed$',
    ) as raised:
        JellyfinAuthenticatedReadback().read(
            connection, private(), device_id=DEVICE,
        )

    assert raised.value.completed_steps[-1] == 'libraries_verified'
    assert raised.value.uncertain_effect
    assert len(connection.requests) == 5 and connection.closed


@pytest.mark.parametrize('listed', [
    keys(key(), key('d' * 32)),
    keys(key(active=True)),
    keys(key(revoked='2026-09-09T00:00:00.0000000Z')),
    {'Items': [key()], 'TotalRecordCount': 2, 'StartIndex': 0},
])
def test_ambiguous_or_incoherent_key_readback_is_closed(listed):
    connection = Connection([json_response(authentication()), json_response(listed)])
    with pytest.raises(
        JellyfinAuthenticatedReadbackError,
        match='^jellyfin_authenticated_readback_protocol$',
    ) as raised:
        JellyfinAuthenticatedReadback().read(connection, private(), device_id=DEVICE)
    assert raised.value.completed_steps == ('authenticated',)
    assert not raised.value.uncertain_effect and len(connection.requests) == 2


def test_authentication_failure_is_static_secret_free_and_never_retried():
    connection = Connection([json_response({'error': 'private'}, status=401)])
    with pytest.raises(
        JellyfinAuthenticatedReadbackError,
        match='^jellyfin_authentication_failed$',
    ) as raised:
        JellyfinAuthenticatedReadback().read(connection, private(), device_id=DEVICE)
    assert raised.value.completed_steps == () and not raised.value.uncertain_effect
    assert len(connection.requests) == 1
    assert SECRET not in str(raised.value) + repr(raised.value)


def test_connection_loss_after_key_create_is_uncertain_and_not_retried():
    connection = Connection([
        json_response(authentication()),
        json_response(keys()),
        response(),
    ])
    with pytest.raises(
        JellyfinAuthenticatedReadbackError,
        match='^jellyfin_authenticated_readback_unavailable$',
    ) as raised:
        JellyfinAuthenticatedReadback().read(connection, private(), device_id=DEVICE)
    assert raised.value.completed_steps == ('authenticated', 'keys_observed', 'key_created')
    assert raised.value.uncertain_effect and len(connection.requests) == 4


@pytest.mark.parametrize('payload,device,limits', [
    ('private', DEVICE, JellyfinAuthenticatedReadbackLimits()),
    (private(), 'bad', JellyfinAuthenticatedReadbackLimits()),
    (private(), DEVICE, 'limits'),
])
def test_closed_input_has_no_target_retry_proxy_or_ambient_token(payload, device, limits):
    connection = Connection([])
    with pytest.raises(
        JellyfinAuthenticatedReadbackError,
        match='^invalid_jellyfin_authenticated_readback$',
    ):
        JellyfinAuthenticatedReadback().read(
            connection, payload, device_id=device, limits=limits,
        )
    assert connection.requests == []
    parameters = inspect.signature(JellyfinAuthenticatedReadback.read).parameters
    assert not {'url', 'host', 'port', 'resolver', 'proxy', 'headers', 'token'} & set(parameters)


def test_timeout_closes_the_preverified_stream_without_retry():
    class Stalled(Connection):
        def recv(self, _count):
            raise socket.timeout()

    connection = Stalled([])
    with pytest.raises(
        JellyfinAuthenticatedReadbackError,
        match='^jellyfin_authenticated_readback_timeout$',
    ) as raised:
        JellyfinAuthenticatedReadback().read(
            connection,
            private(),
            device_id=DEVICE,
            limits=JellyfinAuthenticatedReadbackLimits(
                total_seconds=0.01,
                max_response_bytes=262144,
            ),
        )
    assert raised.value.completed_steps == () and not raised.value.uncertain_effect
    assert connection.closed and len(connection.requests) == 1
