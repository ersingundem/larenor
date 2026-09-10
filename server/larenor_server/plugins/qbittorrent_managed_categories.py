"""Idempotent movie and TV category wiring for an owned qBittorrent instance."""

from dataclasses import dataclass
import json
import math
import re
import socket
import time
from urllib.parse import urlencode

from ..services.transport import _Deadline, _remaining, _request_bytes
from ..services.transport import ProbeTransportError
from .jellyfin_startup import (
    _ConnectionLost,
    _StartupReader,
    _headers,
    _response,
)


_TOKEN = re.compile(r'[A-Za-z0-9_-]{32,128}\Z')
_CODES = frozenset({
    'invalid_qbittorrent_categories',
    'qbittorrent_categories_authentication_failed',
    'qbittorrent_categories_protocol',
    'qbittorrent_categories_observation_protocol',
    'qbittorrent_categories_observation_framing',
    'qbittorrent_categories_observation_http',
    'qbittorrent_categories_observation_closed',
    'qbittorrent_categories_observation_payload',
    'qbittorrent_category_create_protocol',
    'qbittorrent_categories_verification_protocol',
    'qbittorrent_category_conflict',
    'qbittorrent_categories_unavailable',
    'qbittorrent_categories_timeout',
})
_CATEGORIES = (
    ('movies', '/data/downloads/movies'),
    ('tv', '/data/downloads/tv'),
)


class QbittorrentManagedCategoriesError(Exception):
    def __init__(self, code='qbittorrent_categories_unavailable', *,
                 completed_steps=(), uncertain_effect=False):
        self.code = code if code in _CODES else 'qbittorrent_categories_unavailable'
        self.completed_steps = tuple(completed_steps)
        self.uncertain_effect = uncertain_effect is True
        super().__init__(self.code)

    def __repr__(self):
        return (f'QbittorrentManagedCategoriesError({self.code!r}, '
                f'completed_steps={len(self.completed_steps)}, '
                f'uncertain_effect={self.uncertain_effect!r})')


@dataclass(frozen=True)
class QbittorrentManagedCategoriesLimits:
    total_seconds: float = 30.0
    max_response_bytes: int = 262144

    def __post_init__(self):
        if (type(self.total_seconds) not in (int, float)
                or not math.isfinite(self.total_seconds)
                or not 0 < self.total_seconds <= 120
                or type(self.max_response_bytes) is not int
                or not 1 <= self.max_response_bytes <= 1048576):
            raise QbittorrentManagedCategoriesError(
                'invalid_qbittorrent_categories')


@dataclass(frozen=True)
class QbittorrentManagedCategoriesResult:
    state: str
    categories: tuple[tuple[str, str], ...]
    completed_steps: tuple[str, ...]


def _unique(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError()
        value[key] = item
    return value


def _json(raw, protocol_code='qbittorrent_categories_protocol'):
    try:
        value = json.loads(
            raw.decode('utf-8'), object_pairs_hook=_unique,
            parse_constant=lambda _value: (_ for _ in ()).throw(ValueError()))
        if type(value) is not dict:
            raise ValueError()
        return value
    except (UnicodeError, json.JSONDecodeError, ValueError, TypeError):
        raise QbittorrentManagedCategoriesError(
            protocol_code) from None


def _existing(value):
    desired = dict(_CATEGORIES)
    if not set(value) <= set(desired):
        raise QbittorrentManagedCategoriesError('qbittorrent_category_conflict')
    for name, item in value.items():
        if (type(item) is not dict
                or not {'name', 'savePath', 'download_path'} <= item.keys()
                or type(item.get('name')) is not str
                or type(item.get('savePath')) is not str
                or item.get('name') != name or item.get('savePath') != desired[name]
                or item.get('download_path') is not None):
            raise QbittorrentManagedCategoriesError(
                'qbittorrent_category_conflict')
    return frozenset(value)


def _wire(method, api_key, body=None, *, final=False):
    headers = {
        'Accept': 'application/json',
        'Authorization': 'Bearer ' + api_key,
    }
    target = '/api/v2/torrents/categories'
    raw = None
    if method == 'POST':
        target = '/api/v2/torrents/createCategory'
        raw = urlencode(body).encode('ascii')
        headers['Content-Type'] = 'application/x-www-form-urlencoded'
    request = _request_bytes(method, target, 'qbittorrent', headers, raw)
    if not final:
        request = request.replace(
            b'Connection: close\r\n', b'Connection: keep-alive\r\n', 1)
    return request


def _empty_response(reader):
    status, headers = _headers(reader)
    framing = {}
    for key, value in headers:
        if key in {'content-length', 'transfer-encoding', 'content-encoding',
                   'content-type', 'connection'}:
            if key in framing:
                raise ProbeTransportError('invalid_response')
            framing[key] = value.lower()
    if (framing.get('content-encoding', 'identity') != 'identity'
            or framing.get('transfer-encoding') is not None
            or framing.get('content-length') != '0'
            or framing.get('content-type', '').split(';')[0].strip()
            not in {'', 'text/plain'}
            or framing.get('connection') not in {None, 'keep-alive'}):
        raise ProbeTransportError('invalid_response')
    return status


class QbittorrentManagedCategories:
    def apply(self, connection, *, api_key,
              limits=QbittorrentManagedCategoriesLimits()):
        if (type(api_key) is not str or _TOKEN.fullmatch(api_key) is None
                or type(limits) is not QbittorrentManagedCategoriesLimits):
            raise QbittorrentManagedCategoriesError(
                'invalid_qbittorrent_categories')
        try:
            limits = QbittorrentManagedCategoriesLimits(**vars(limits))
        except (ValueError, TypeError, AttributeError,
                QbittorrentManagedCategoriesError):
            raise QbittorrentManagedCategoriesError(
                'invalid_qbittorrent_categories') from None
        methods = ('sendall', 'recv', 'settimeout', 'shutdown', 'close')
        if any(not callable(getattr(connection, name, None)) for name in methods):
            raise QbittorrentManagedCategoriesError(
                'invalid_qbittorrent_categories')

        deadline = time.monotonic() + limits.total_seconds
        completed = []
        mutation_sent = False
        protocol_code = 'qbittorrent_categories_observation_protocol'
        scope = None
        try:
            scope = _Deadline(deadline)
            scope.attach(connection)
            reader = _StartupReader(connection, deadline)
            try:
                status, raw, closes = self._get(
                    connection, reader, deadline, limits, api_key, final=False)
            except ProbeTransportError:
                raise QbittorrentManagedCategoriesError(
                    'qbittorrent_categories_observation_framing') from None
            self._status(
                status, 'qbittorrent_categories_observation_http')
            if closes:
                raise QbittorrentManagedCategoriesError(
                    'qbittorrent_categories_observation_closed')
            completed.append('categories_observed')
            present = _existing(_json(
                raw, 'qbittorrent_categories_observation_payload'))
            if present == frozenset(dict(_CATEGORIES)):
                completed.append('categories_verified')
                return QbittorrentManagedCategoriesResult(
                    'verified', _CATEGORIES, tuple(completed))

            for name, path in _CATEGORIES:
                if name in present:
                    continue
                protocol_code = 'qbittorrent_category_create_protocol'
                mutation_sent = True
                status = self._post(
                    connection, reader, deadline, api_key,
                    {'category': name, 'savePath': path})
                self._status(status, protocol_code)
                completed.append(name + '_created')

            protocol_code = 'qbittorrent_categories_verification_protocol'
            status, raw, _closes = self._get(
                connection, reader, deadline, limits, api_key, final=True)
            self._status(status, protocol_code)
            if _existing(_json(raw, protocol_code)) != frozenset(dict(_CATEGORIES)):
                raise QbittorrentManagedCategoriesError(
                    'qbittorrent_category_conflict')
            completed.append('categories_verified')
            return QbittorrentManagedCategoriesResult(
                'verified', _CATEGORIES, tuple(completed))
        except QbittorrentManagedCategoriesError as error:
            if error.completed_steps or error.uncertain_effect:
                raise
            raise QbittorrentManagedCategoriesError(
                error.code, completed_steps=completed,
                uncertain_effect=mutation_sent) from None
        except (socket.timeout, TimeoutError):
            raise QbittorrentManagedCategoriesError(
                'qbittorrent_categories_timeout', completed_steps=completed,
                uncertain_effect=mutation_sent) from None
        except _ConnectionLost:
            raise QbittorrentManagedCategoriesError(
                'qbittorrent_categories_unavailable', completed_steps=completed,
                uncertain_effect=mutation_sent) from None
        except (ProbeTransportError, ValueError, TypeError, AttributeError,
                UnicodeError, json.JSONDecodeError):
            code = ('qbittorrent_categories_timeout'
                    if time.monotonic() >= deadline
                    else protocol_code)
            raise QbittorrentManagedCategoriesError(
                code, completed_steps=completed,
                uncertain_effect=mutation_sent) from None
        except (OSError, RuntimeError):
            code = ('qbittorrent_categories_timeout'
                    if time.monotonic() >= deadline
                    else 'qbittorrent_categories_unavailable')
            raise QbittorrentManagedCategoriesError(
                code, completed_steps=completed,
                uncertain_effect=mutation_sent) from None
        finally:
            if scope is not None:
                scope.finish()

    @staticmethod
    def _status(status, protocol_code='qbittorrent_categories_protocol'):
        if status in {401, 403}:
            raise QbittorrentManagedCategoriesError(
                'qbittorrent_categories_authentication_failed')
        if status != 200:
            raise QbittorrentManagedCategoriesError(
                protocol_code)

    @staticmethod
    def _get(connection, reader, deadline, limits, api_key, *, final):
        connection.settimeout(_remaining(deadline))
        connection.sendall(_wire('GET', api_key, final=final))
        return _response(reader, limits.max_response_bytes)

    @staticmethod
    def _post(connection, reader, deadline, api_key, body):
        connection.settimeout(_remaining(deadline))
        connection.sendall(_wire('POST', api_key, body))
        return _empty_response(reader)
