"""Authenticated qBittorrent readback over one preverified private stream.

The adapter accepts no destination, resolver, proxy, ambient headers or retry
policy.  It uses the qBittorrent 5.2.3 Bearer API-key seam and returns only the
small managed projection required for later Sonarr/Radarr wiring.
"""

from dataclasses import dataclass
import hmac
import json
import math
import re
import socket
import time

from ..services.transport import _Deadline, _remaining, _request_bytes
from ..services.transport import ProbeTransportError
from .jellyfin_startup import _ConnectionLost, _StartupReader, _response
from .qbittorrent_readback import (
    QbittorrentReadback,
    QbittorrentReadbackError,
    validate_qbittorrent_readback,
)


_CODES = frozenset({
    'invalid_qbittorrent_authenticated_readback',
    'qbittorrent_authentication_failed',
    'qbittorrent_readback_protocol',
    'qbittorrent_readback_mismatch',
    'qbittorrent_authenticated_readback_unavailable',
    'qbittorrent_authenticated_readback_timeout',
})
_TOKEN = re.compile(r'[A-Za-z0-9_-]{32,128}\Z')


class QbittorrentAuthenticatedReadbackError(Exception):
    """Secret-free failure for one bounded readback attempt."""

    def __init__(self, code='qbittorrent_authenticated_readback_unavailable', *,
                 completed_steps=()):
        self.code = code if code in _CODES else 'qbittorrent_authenticated_readback_unavailable'
        self.completed_steps = tuple(completed_steps)
        super().__init__(self.code)

    def __repr__(self):
        return (f'QbittorrentAuthenticatedReadbackError({self.code!r}, '
                f'completed_steps={len(self.completed_steps)})')


@dataclass(frozen=True)
class QbittorrentAuthenticatedReadbackLimits:
    total_seconds: float = 30.0
    max_response_bytes: int = 262144

    def __post_init__(self):
        if (type(self.total_seconds) not in (int, float)
                or not math.isfinite(self.total_seconds)
                or not 0 < self.total_seconds <= 120
                or type(self.max_response_bytes) is not int
                or not 1 <= self.max_response_bytes <= 1048576):
            raise QbittorrentAuthenticatedReadbackError(
                'invalid_qbittorrent_authenticated_readback')


@dataclass(frozen=True)
class QbittorrentAuthenticatedReadbackResult:
    state: str
    version: str
    settings: QbittorrentReadback
    completed_steps: tuple[str, ...]


def _unique(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError()
        value[key] = item
    return value


def _json(raw):
    try:
        return json.loads(
            raw.decode('utf-8'), object_pairs_hook=_unique,
            parse_constant=lambda _value: (_ for _ in ()).throw(ValueError()))
    except (UnicodeError, json.JSONDecodeError, ValueError, TypeError):
        raise QbittorrentAuthenticatedReadbackError(
            'qbittorrent_readback_protocol') from None


def _wire(path, api_key, *, final):
    request = _request_bytes('GET', path, 'qbittorrent', {
        'Accept': 'application/json',
        'Authorization': 'Bearer ' + api_key,
    }, None)
    if not final:
        request = request.replace(
            b'Connection: close\r\n', b'Connection: keep-alive\r\n', 1)
    return request


class QbittorrentAuthenticatedReadback:
    def read(self, connection, *, api_key, web_port=8080, torrent_port=6881,
             limits=QbittorrentAuthenticatedReadbackLimits()):
        if (type(api_key) is not str or _TOKEN.fullmatch(api_key) is None
                or type(limits) is not QbittorrentAuthenticatedReadbackLimits
                or type(web_port) is not int or not 1024 <= web_port <= 65535
                or type(torrent_port) is not int
                or not 1024 <= torrent_port <= 65535):
            raise QbittorrentAuthenticatedReadbackError(
                'invalid_qbittorrent_authenticated_readback')
        try:
            limits = QbittorrentAuthenticatedReadbackLimits(**vars(limits))
        except (ValueError, TypeError, AttributeError,
                QbittorrentAuthenticatedReadbackError):
            raise QbittorrentAuthenticatedReadbackError(
                'invalid_qbittorrent_authenticated_readback') from None
        methods = ('sendall', 'recv', 'settimeout', 'shutdown', 'close')
        if any(not callable(getattr(connection, name, None)) for name in methods):
            raise QbittorrentAuthenticatedReadbackError(
                'invalid_qbittorrent_authenticated_readback')

        deadline = time.monotonic() + limits.total_seconds
        completed = []
        scope = None
        try:
            scope = _Deadline(deadline)
            scope.attach(connection)
            reader = _StartupReader(connection, deadline)

            status, raw, closes = self._request(
                connection, reader, deadline, limits,
                '/api/v2/app/version', api_key, final=False)
            if status in {401, 403}:
                raise QbittorrentAuthenticatedReadbackError(
                    'qbittorrent_authentication_failed')
            if status != 200 or closes:
                raise QbittorrentAuthenticatedReadbackError(
                    'qbittorrent_readback_protocol')
            if raw != b'v5.2.3':
                raise QbittorrentAuthenticatedReadbackError(
                    'qbittorrent_readback_mismatch')
            version = raw.decode('ascii')
            completed.append('version_verified')

            status, raw, closes = self._request(
                connection, reader, deadline, limits,
                '/api/v2/app/preferences', api_key, final=False)
            if status in {401, 403}:
                raise QbittorrentAuthenticatedReadbackError(
                    'qbittorrent_authentication_failed')
            if status != 200 or closes:
                raise QbittorrentAuthenticatedReadbackError(
                    'qbittorrent_readback_protocol')
            preferences = _json(raw)
            if type(preferences) is not dict:
                raise QbittorrentAuthenticatedReadbackError(
                    'qbittorrent_readback_protocol')
            observed_key = preferences.get('web_ui_api_key')
            if type(observed_key) is not str:
                raise QbittorrentAuthenticatedReadbackError(
                    'qbittorrent_readback_protocol')
            if not hmac.compare_digest(observed_key, api_key):
                raise QbittorrentAuthenticatedReadbackError(
                    'qbittorrent_readback_mismatch')

            status, raw, _closes = self._request(
                connection, reader, deadline, limits,
                '/api/v2/torrents/categories', api_key, final=True)
            if status in {401, 403}:
                raise QbittorrentAuthenticatedReadbackError(
                    'qbittorrent_authentication_failed')
            if status != 200:
                raise QbittorrentAuthenticatedReadbackError(
                    'qbittorrent_readback_protocol')
            categories = _json(raw)
            try:
                projected = validate_qbittorrent_readback(
                    preferences, categories, web_port=web_port,
                    torrent_port=torrent_port)
            except QbittorrentReadbackError as error:
                raise QbittorrentAuthenticatedReadbackError(
                    error.code, completed_steps=completed) from None
            completed.extend(('preferences_verified', 'categories_verified'))
            return QbittorrentAuthenticatedReadbackResult(
                'verified', version, projected, tuple(completed))
        except QbittorrentAuthenticatedReadbackError as error:
            if error.completed_steps:
                raise
            raise QbittorrentAuthenticatedReadbackError(
                error.code, completed_steps=completed) from None
        except (socket.timeout, TimeoutError):
            raise QbittorrentAuthenticatedReadbackError(
                'qbittorrent_authenticated_readback_timeout',
                completed_steps=completed) from None
        except _ConnectionLost:
            raise QbittorrentAuthenticatedReadbackError(
                'qbittorrent_authenticated_readback_unavailable',
                completed_steps=completed) from None
        except (ProbeTransportError, ValueError, TypeError, AttributeError,
                UnicodeError, json.JSONDecodeError):
            code = ('qbittorrent_authenticated_readback_timeout'
                    if time.monotonic() >= deadline
                    else 'qbittorrent_readback_protocol')
            raise QbittorrentAuthenticatedReadbackError(
                code, completed_steps=completed) from None
        except (OSError, RuntimeError):
            code = ('qbittorrent_authenticated_readback_timeout'
                    if time.monotonic() >= deadline
                    else 'qbittorrent_authenticated_readback_unavailable')
            raise QbittorrentAuthenticatedReadbackError(
                code, completed_steps=completed) from None
        finally:
            if scope is not None:
                scope.finish()

    @staticmethod
    def _request(connection, reader, deadline, limits, path, api_key, *, final):
        connection.settimeout(_remaining(deadline))
        connection.sendall(_wire(path, api_key, final=final))
        return _response(
            reader, limits.max_response_bytes,
            content_type=('text/plain' if path == '/api/v2/app/version'
                          else 'application/json'))
