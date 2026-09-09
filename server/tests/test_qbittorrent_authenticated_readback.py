"""Authenticated qBittorrent API readback over one preverified stream."""

import inspect
import json
import socket

import pytest

from larenor_server.plugins.qbittorrent_authenticated_readback import (
    QbittorrentAuthenticatedReadback,
    QbittorrentAuthenticatedReadbackError,
    QbittorrentAuthenticatedReadbackLimits,
)
from test_jellyfin_startup import Connection, response
from test_qbittorrent_owned_config import PRIVATE_BEARER
from test_qbittorrent_readback import categories, preferences


def json_response(value, status=200, *, connection=b'keep-alive'):
    return response(
        status, json.dumps(value, separators=(',', ':')).encode(),
        content_type=b'application/json',
        extra=b'Connection: ' + connection + b'\r\n')


def version_response(value=b'v5.2.3', status=200, *, connection=b'keep-alive'):
    return response(
        status, value, content_type=b'text/plain',
        extra=b'Connection: ' + connection + b'\r\n')


def parts(raw):
    head, body = raw.split(b'\r\n\r\n', 1)
    return head.split(b'\r\n'), body


def private_preferences(**changes):
    return preferences() | {'web_ui_api_key': PRIVATE_BEARER} | changes


def test_reads_preferences_and_categories_with_private_bearer_key():
    connection = Connection([
        version_response(),
        json_response(private_preferences()),
        json_response(categories(), connection=b'close'),
    ])

    result = QbittorrentAuthenticatedReadback().read(
        connection, api_key=PRIVATE_BEARER)

    assert result.state == 'verified'
    assert result.version == 'v5.2.3'
    assert result.completed_steps == (
        'version_verified', 'preferences_verified', 'categories_verified')
    assert result.settings.categories == (
        ('movies', '/data/downloads/movies'),
        ('tv', '/data/downloads/tv'),
    )
    assert len(connection.requests) == 3 and connection.closed
    assert [parts(raw)[0][0] for raw in connection.requests] == [
        b'GET /api/v2/app/version HTTP/1.1',
        b'GET /api/v2/app/preferences HTTP/1.1',
        b'GET /api/v2/torrents/categories HTTP/1.1',
    ]
    for raw in connection.requests:
        head, body = parts(raw)
        assert b'Host: qbittorrent' in head
        assert b'Authorization: Bearer ' + PRIVATE_BEARER.encode() in head
        assert body == b''
    assert b'Connection: keep-alive' in parts(connection.requests[0])[0]
    assert b'Connection: keep-alive' in parts(connection.requests[1])[0]
    assert b'Connection: close' in parts(connection.requests[2])[0]
    assert PRIVATE_BEARER not in repr(result)


@pytest.mark.parametrize('status', [401, 403])
def test_authentication_failure_is_static_and_never_retried(status):
    connection = Connection([version_response(status=status)])
    with pytest.raises(QbittorrentAuthenticatedReadbackError,
                       match='^qbittorrent_authentication_failed$') as raised:
        QbittorrentAuthenticatedReadback().read(connection, api_key=PRIVATE_BEARER)
    assert raised.value.completed_steps == ()
    assert len(connection.requests) == 1 and connection.closed
    assert PRIVATE_BEARER not in str(raised.value) + repr(raised.value)


def test_owned_setting_drift_is_reported_without_returning_payload():
    connection = Connection([
        version_response(),
        json_response(private_preferences(upnp=True)),
        json_response(categories(), connection=b'close'),
    ])
    with pytest.raises(QbittorrentAuthenticatedReadbackError,
                       match='^qbittorrent_readback_mismatch$') as raised:
        QbittorrentAuthenticatedReadback().read(connection, api_key=PRIVATE_BEARER)
    assert raised.value.completed_steps == ('version_verified',) and connection.closed
    assert 'upnp' not in str(raised.value) + repr(raised.value)


@pytest.mark.parametrize('value', ['other-private-key-' + 'x' * 32, None, True])
def test_authenticated_preferences_must_confirm_the_owned_api_key(value):
    connection = Connection([
        version_response(),
        json_response(private_preferences(web_ui_api_key=value)),
    ])
    expected = ('qbittorrent_readback_protocol' if type(value) is not str
                else 'qbittorrent_readback_mismatch')
    with pytest.raises(QbittorrentAuthenticatedReadbackError,
                       match='^' + expected + '$') as raised:
        QbittorrentAuthenticatedReadback().read(connection, api_key=PRIVATE_BEARER)
    assert PRIVATE_BEARER not in str(raised.value) + repr(raised.value)


@pytest.mark.parametrize('payload', [b'not-json', b'{"x":1,"x":2}', b'[]'])
def test_malformed_preferences_are_closed_protocol_failures(payload):
    connection = Connection([
        version_response(),
        response(200, payload, content_type=b'application/json'),
    ])
    with pytest.raises(QbittorrentAuthenticatedReadbackError,
                       match='^qbittorrent_readback_protocol$'):
        QbittorrentAuthenticatedReadback().read(connection, api_key=PRIVATE_BEARER)
    assert len(connection.requests) == 2 and connection.closed


@pytest.mark.parametrize('version', [b'v5.2.2', b'5.2.3', b'v5.2.3\n', b'', b'not-qbittorrent'])
def test_exact_pinned_version_is_required_before_preferences(version):
    connection = Connection([version_response(version)])
    with pytest.raises(QbittorrentAuthenticatedReadbackError,
                       match='^qbittorrent_readback_mismatch$') as raised:
        QbittorrentAuthenticatedReadback().read(
            connection, api_key=PRIVATE_BEARER)
    assert raised.value.completed_steps == ()
    assert len(connection.requests) == 1 and connection.closed


@pytest.mark.parametrize('api_key,limits', [
    ('short', QbittorrentAuthenticatedReadbackLimits()),
    (PRIVATE_BEARER, 'limits'), (True, QbittorrentAuthenticatedReadbackLimits()),
])
def test_closed_inputs_have_no_target_proxy_or_header_surface(api_key, limits):
    connection = Connection([])
    with pytest.raises(QbittorrentAuthenticatedReadbackError,
                       match='^invalid_qbittorrent_authenticated_readback$'):
        QbittorrentAuthenticatedReadback().read(
            connection, api_key=api_key, limits=limits)
    assert connection.requests == []
    parameters = inspect.signature(QbittorrentAuthenticatedReadback.read).parameters
    assert not {'url', 'host', 'resolver', 'proxy', 'headers', 'token'} & set(parameters)


def test_timeout_closes_the_preverified_stream_without_retry():
    class Stalled(Connection):
        def recv(self, _count):
            raise socket.timeout()

    connection = Stalled([])
    with pytest.raises(QbittorrentAuthenticatedReadbackError,
                       match='^qbittorrent_authenticated_readback_timeout$') as raised:
        QbittorrentAuthenticatedReadback().read(
            connection, api_key=PRIVATE_BEARER,
            limits=QbittorrentAuthenticatedReadbackLimits(
                total_seconds=0.01, max_response_bytes=262144))
    assert raised.value.completed_steps == ()
    assert connection.closed and len(connection.requests) == 1


def test_first_response_must_not_close_the_owned_stream():
    connection = Connection([
        version_response(connection=b'close'),
    ])
    with pytest.raises(QbittorrentAuthenticatedReadbackError,
                       match='^qbittorrent_readback_protocol$'):
        QbittorrentAuthenticatedReadback().read(connection, api_key=PRIVATE_BEARER)
    assert len(connection.requests) == 1 and connection.closed


def test_limits_reject_nonfinite_and_unbounded_values():
    for values in [
        {'total_seconds': float('inf')}, {'total_seconds': 0},
        {'max_response_bytes': True}, {'max_response_bytes': 1048577},
    ]:
        with pytest.raises(QbittorrentAuthenticatedReadbackError,
                           match='^invalid_qbittorrent_authenticated_readback$'):
            QbittorrentAuthenticatedReadbackLimits(**values)
