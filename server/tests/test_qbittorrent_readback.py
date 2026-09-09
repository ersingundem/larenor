"""Closed projection of authenticated qBittorrent settings and categories."""

import pytest

from larenor_server.plugins.qbittorrent_readback import (
    QbittorrentReadbackError,
    validate_qbittorrent_readback,
)


def preferences():
    return {
        'save_path': '/data/downloads',
        'temp_path_enabled': True,
        'temp_path': '/data/incomplete',
        'listen_port': 6881,
        'upnp': False,
        'web_ui_address': '*',
        'web_ui_port': 8080,
        'web_ui_upnp': False,
        'use_https': False,
        'web_ui_username': 'larenor-system',
        'bypass_local_auth': False,
        'bypass_auth_subnet_whitelist_enabled': False,
        'web_ui_domain_list': 'qbittorrent',
        'web_ui_clickjacking_protection_enabled': True,
        'web_ui_csrf_protection_enabled': True,
        'web_ui_secure_cookie_enabled': True,
        'web_ui_host_header_validation_enabled': True,
        'unrelated_upstream_setting': 'allowed',
    }


def categories():
    return {
        'movies': {
            'name': 'movies', 'savePath': '/data/downloads/movies',
            'download_path': None, 'ratio_limit': -2,
            'seeding_time_limit': -2, 'inactive_seeding_time_limit': -2,
            'share_limit_action': 'Default',
        },
        'tv': {
            'name': 'tv', 'savePath': '/data/downloads/tv',
            'download_path': None, 'ratio_limit': -2,
            'seeding_time_limit': -2, 'inactive_seeding_time_limit': -2,
            'share_limit_action': 'Default',
        },
    }


def test_projects_only_owned_operational_facts_from_full_upstream_payloads():
    result = validate_qbittorrent_readback(preferences(), categories())
    assert result.state == 'verified'
    assert result.username == 'larenor-system'
    assert result.web_port == 8080 and result.torrent_port == 6881
    assert result.download_path == '/data/downloads'
    assert result.incomplete_path == '/data/incomplete'
    assert result.categories == (
        ('movies', '/data/downloads/movies'),
        ('tv', '/data/downloads/tv'),
    )


@pytest.mark.parametrize('key,value', [
    ('save_path', '/private/downloads'), ('temp_path_enabled', False),
    ('temp_path', '/data/downloads'), ('listen_port', True),
    ('listen_port', 6999), ('upnp', True), ('web_ui_address', '0.0.0.0'),
    ('web_ui_port', 9090), ('web_ui_upnp', True), ('use_https', True),
    ('web_ui_username', 'admin'), ('bypass_local_auth', True),
    ('bypass_auth_subnet_whitelist_enabled', True),
    ('web_ui_domain_list', '*'),
    ('web_ui_clickjacking_protection_enabled', False),
    ('web_ui_csrf_protection_enabled', False),
    ('web_ui_secure_cookie_enabled', False),
    ('web_ui_host_header_validation_enabled', False),
])
def test_rejects_drift_in_every_owned_preference(key, value):
    changed = preferences() | {key: value}
    with pytest.raises(QbittorrentReadbackError,
                       match='^qbittorrent_readback_mismatch$'):
        validate_qbittorrent_readback(changed, categories())


@pytest.mark.parametrize('changed', [
    {},
    {'movies': categories()['movies']},
    categories() | {'music': {'name': 'music', 'savePath': '/data/music'}},
    categories() | {'movies': categories()['movies'] | {'name': 'other'}},
    categories() | {'movies': categories()['movies'] | {'savePath': '/data/movies'}},
    categories() | {'movies': categories()['movies'] | {'download_path': '/tmp'}},
])
def test_requires_exact_movie_and_tv_category_ownership(changed):
    with pytest.raises(QbittorrentReadbackError,
                       match='^qbittorrent_readback_mismatch$'):
        validate_qbittorrent_readback(preferences(), changed)


@pytest.mark.parametrize('preferences_value,categories_value', [
    (None, categories()), ([], categories()), (preferences(), None),
    (preferences(), []), ({}, categories()),
])
def test_invalid_upstream_shapes_are_protocol_failures(preferences_value,
                                                       categories_value):
    with pytest.raises(QbittorrentReadbackError,
                       match='^qbittorrent_readback_protocol$'):
        validate_qbittorrent_readback(preferences_value, categories_value)


def test_custom_manifest_ports_are_checked_without_accepting_bool_or_strings():
    selected = preferences() | {'web_ui_port': 9090, 'listen_port': 6991}
    result = validate_qbittorrent_readback(
        selected, categories(), web_port=9090, torrent_port=6991)
    assert (result.web_port, result.torrent_port) == (9090, 6991)
    for web, torrent in [(True, 6991), (9090, '6991'), (1023, 6991)]:
        with pytest.raises(QbittorrentReadbackError,
                           match='^invalid_qbittorrent_readback$'):
            validate_qbittorrent_readback(
                selected, categories(), web_port=web, torrent_port=torrent)
