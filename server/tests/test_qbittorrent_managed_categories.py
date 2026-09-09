"""Idempotent qBittorrent movie/TV category wiring over a proved stream."""

import json

import pytest

from larenor_server.plugins.qbittorrent_managed_categories import (
    QbittorrentManagedCategories,
    QbittorrentManagedCategoriesError,
)
from test_jellyfin_startup import Connection, response
from test_qbittorrent_owned_config import PRIVATE_BEARER
from test_qbittorrent_readback import categories


def json_response(value, status=200, *, close=False):
    extra = b'Connection: close\r\n' if close else b'Connection: keep-alive\r\n'
    return response(status, json.dumps(value, separators=(',', ':')).encode(),
                    content_type=b'application/json', extra=extra)


def empty_response(status=200):
    return response(status, b'', content_type=b'text/plain',
                    extra=b'Connection: keep-alive\r\n')


def parts(raw):
    head, body = raw.split(b'\r\n\r\n', 1)
    return head.split(b'\r\n'), body


def test_creates_fixed_categories_then_requires_exact_readback():
    connection = Connection([
        json_response({}), empty_response(), empty_response(),
        json_response(categories(), close=True),
    ])
    result = QbittorrentManagedCategories().apply(
        connection, api_key=PRIVATE_BEARER)

    assert result.state == 'verified'
    assert result.categories == (
        ('movies', '/data/downloads/movies'),
        ('tv', '/data/downloads/tv'),
    )
    assert result.completed_steps == (
        'categories_observed', 'movies_created', 'tv_created',
        'categories_verified')
    assert [parts(raw)[0][0] for raw in connection.requests] == [
        b'GET /api/v2/torrents/categories HTTP/1.1',
        b'POST /api/v2/torrents/createCategory HTTP/1.1',
        b'POST /api/v2/torrents/createCategory HTTP/1.1',
        b'GET /api/v2/torrents/categories HTTP/1.1',
    ]
    assert parts(connection.requests[1])[1] == (
        b'category=movies&savePath=%2Fdata%2Fdownloads%2Fmovies')
    assert parts(connection.requests[2])[1] == (
        b'category=tv&savePath=%2Fdata%2Fdownloads%2Ftv')
    assert all(b'Authorization: Bearer ' + PRIVATE_BEARER.encode() in parts(raw)[0]
               for raw in connection.requests)
    assert connection.closed and PRIVATE_BEARER not in repr(result)


def test_exact_existing_categories_are_verified_without_mutation():
    connection = Connection([json_response(categories())])
    result = QbittorrentManagedCategories().apply(
        connection, api_key=PRIVATE_BEARER)
    assert result.completed_steps == ('categories_observed', 'categories_verified')
    assert len(connection.requests) == 1 and connection.closed


def test_partial_exact_state_creates_only_the_missing_category():
    connection = Connection([
        json_response({'movies': categories()['movies']}),
        empty_response(), json_response(categories(), close=True),
    ])
    result = QbittorrentManagedCategories().apply(
        connection, api_key=PRIVATE_BEARER)
    assert result.completed_steps == (
        'categories_observed', 'tv_created', 'categories_verified')
    assert b'category=tv&' in parts(connection.requests[1])[1]


@pytest.mark.parametrize('observed', [
    {'foreign': {'name': 'foreign', 'savePath': '/data/foreign'}},
    {'movies': categories()['movies'] | {'savePath': '/data/wrong'}},
    {'movies': categories()['movies'] | {'download_path': '/tmp'}},
    {'movies': {'name': 'movies'}},
])
def test_conflicting_or_malformed_existing_state_never_mutates(observed):
    connection = Connection([json_response(observed)])
    with pytest.raises(QbittorrentManagedCategoriesError,
                       match='^qbittorrent_category_conflict$') as raised:
        QbittorrentManagedCategories().apply(connection, api_key=PRIVATE_BEARER)
    assert raised.value.completed_steps == ('categories_observed',)
    assert not raised.value.uncertain_effect
    assert len(connection.requests) == 1 and connection.closed


def test_connection_loss_after_create_reports_uncertain_effect_without_secret():
    connection = Connection([json_response({}), empty_response()])
    with pytest.raises(QbittorrentManagedCategoriesError,
                       match='^qbittorrent_categories_unavailable$') as raised:
        QbittorrentManagedCategories().apply(connection, api_key=PRIVATE_BEARER)
    assert raised.value.completed_steps == (
        'categories_observed', 'movies_created')
    assert raised.value.uncertain_effect
    assert PRIVATE_BEARER not in str(raised.value) + repr(raised.value)


@pytest.mark.parametrize('status', [401, 403])
def test_bearer_auth_failure_is_closed_and_never_retried(status):
    connection = Connection([json_response({'private': PRIVATE_BEARER}, status=status)])
    with pytest.raises(QbittorrentManagedCategoriesError,
                       match='^qbittorrent_categories_authentication_failed$'):
        QbittorrentManagedCategories().apply(connection, api_key=PRIVATE_BEARER)
    assert len(connection.requests) == 1 and connection.closed
