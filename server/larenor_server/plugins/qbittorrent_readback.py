"""Closed projection for qBittorrent settings and category ownership.

The Web API returns a large evolving preference document.  Larenor retains
only the fixed facts it owns and rejects drift in them without treating
unrelated upstream preferences as part of its configuration surface.
"""

from dataclasses import dataclass


_CODES = frozenset({
    'invalid_qbittorrent_readback',
    'qbittorrent_readback_protocol',
    'qbittorrent_readback_mismatch',
})


class QbittorrentReadbackError(ValueError):
    def __init__(self, code='qbittorrent_readback_protocol'):
        self.code = code if code in _CODES else 'qbittorrent_readback_protocol'
        super().__init__(self.code)


@dataclass(frozen=True)
class QbittorrentReadback:
    state: str
    username: str
    web_port: int
    torrent_port: int
    download_path: str
    incomplete_path: str
    categories: tuple[tuple[str, str], ...]


def _same(actual, expected):
    return type(actual) is type(expected) and actual == expected


def validate_qbittorrent_readback(preferences, categories, *, web_port=8080,
                                  torrent_port=6881):
    """Validate authenticated API payloads against the fixed managed contract."""
    if (type(web_port) is not int or not 1024 <= web_port <= 65535
            or type(torrent_port) is not int
            or not 1024 <= torrent_port <= 65535):
        raise QbittorrentReadbackError('invalid_qbittorrent_readback')
    if type(preferences) is not dict or type(categories) is not dict:
        raise QbittorrentReadbackError('qbittorrent_readback_protocol')
    expected = {
        'save_path': '/data/downloads',
        'temp_path_enabled': True,
        'temp_path': '/data/incomplete',
        'listen_port': torrent_port,
        'upnp': False,
        'web_ui_address': '*',
        'web_ui_port': web_port,
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
    }
    if not expected.keys() <= preferences.keys():
        raise QbittorrentReadbackError('qbittorrent_readback_protocol')
    if any(not _same(preferences[key], value) for key, value in expected.items()):
        raise QbittorrentReadbackError('qbittorrent_readback_mismatch')

    expected_categories = {
        'movies': '/data/downloads/movies',
        'tv': '/data/downloads/tv',
    }
    if set(categories) != set(expected_categories):
        raise QbittorrentReadbackError('qbittorrent_readback_mismatch')
    projected = []
    for name, path in expected_categories.items():
        value = categories[name]
        if type(value) is not dict or not {'name', 'savePath', 'download_path'} <= value.keys():
            raise QbittorrentReadbackError('qbittorrent_readback_protocol')
        if (not _same(value['name'], name) or not _same(value['savePath'], path)
                or value['download_path'] is not None):
            raise QbittorrentReadbackError('qbittorrent_readback_mismatch')
        projected.append((name, path))
    return QbittorrentReadback(
        state='verified', username='larenor-system', web_port=web_port,
        torrent_port=torrent_port, download_path='/data/downloads',
        incomplete_path='/data/incomplete', categories=tuple(projected))
