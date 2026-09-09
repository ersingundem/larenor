"""Closed authenticated Jellyfin identity and library readback.

The caller owns destination selection and supplies one newly proved stream.
This adapter cannot resolve, connect, redirect, retry, or accept ambient auth.
It creates at most one dedicated Larenor API key and never exposes credentials,
session tokens, server paths, or raw Jellyfin payloads through repr/errors.
"""

from dataclasses import dataclass, field
import json
import math
import re
import socket
import time
import unicodedata

from pydantic import ValidationError

from ..services.transport import _Deadline, _remaining, _request_bytes
from ..services.transport import ProbeTransportError
from .jellyfin_startup import _ConnectionLost, _StartupReader, _json, _response
from .media_service_bootstrap_models import PrivateMediaServiceBootstrap


_CODES = frozenset({
    'invalid_jellyfin_authenticated_readback',
    'jellyfin_authentication_failed',
    'jellyfin_authenticated_readback_protocol',
    'jellyfin_authenticated_readback_unavailable',
    'jellyfin_authenticated_readback_timeout',
    'jellyfin_session_cleanup_failed',
})
_ID = re.compile(r'[0-9a-f]{32}\Z')
_TOKEN = re.compile(r'[A-Za-z0-9_-]{32,128}\Z')
_VERSION = re.compile(r'[0-9]{1,4}(?:\.[0-9]{1,4}){2,3}(?:[-+][0-9A-Za-z.-]{1,64})?\Z')
_COLLECTION = re.compile(r'[a-z][a-z0-9_-]{0,31}\Z')
_AUTH_FIELDS = frozenset({'User', 'SessionInfo', 'AccessToken', 'ServerId'})
_KEY_REQUIRED_FIELDS = frozenset({
    'Id', 'AccessToken', 'AppName', 'UserId', 'IsActive', 'DateCreated',
    'DateLastActivity',
})
_KEY_OPTIONAL_FIELDS = frozenset({
    'DeviceId', 'AppVersion', 'DeviceName', 'DateRevoked', 'UserName',
})
_KEY_FIELDS = _KEY_REQUIRED_FIELDS | _KEY_OPTIONAL_FIELDS
_BASE_AUTH = ('MediaBrowser Client="Larenor%20Core", Device="Larenor%20Core", '
              'DeviceId="{device}", Version="0.1.0"')


class JellyfinAuthenticatedReadbackError(Exception):
    """Secret-free result for an authenticated readback sequence."""

    def __init__(self, code='jellyfin_authenticated_readback_unavailable', *,
                 completed_steps=(), uncertain_effect=False):
        self.code = code if code in _CODES else 'jellyfin_authenticated_readback_unavailable'
        self.completed_steps = tuple(completed_steps)
        self.uncertain_effect = uncertain_effect is True
        super().__init__(self.code)

    def __repr__(self):
        return (f'JellyfinAuthenticatedReadbackError({self.code!r}, completed_steps='
                f'{len(self.completed_steps)}, uncertain_effect={self.uncertain_effect!r})')


@dataclass(frozen=True)
class JellyfinAuthenticatedReadbackLimits:
    total_seconds: float = 30.0
    max_response_bytes: int = 262144

    def __post_init__(self):
        if (type(self.total_seconds) not in (int, float)
                or not math.isfinite(self.total_seconds)
                or not 0 < self.total_seconds <= 120
                or type(self.max_response_bytes) is not int
                or not 1 <= self.max_response_bytes <= 1048576):
            raise JellyfinAuthenticatedReadbackError(
                'invalid_jellyfin_authenticated_readback')


@dataclass(frozen=True, repr=False)
class JellyfinAuthenticatedReadbackResult:
    state: str
    server_id: str
    server_name: str
    version: str
    api_key: str = field(repr=False)
    libraries: tuple[tuple[str, str | None, str, tuple[str, ...]], ...] = field(
        repr=False)
    completed_steps: tuple[str, ...]

    def __repr__(self):
        return ('JellyfinAuthenticatedReadbackResult(state={!r}, libraries={}, '
                'completed_steps={})').format(
                    self.state, len(self.libraries), len(self.completed_steps))


def _wire(method, path, body, authorization, *, final=False):
    headers = {'Accept': 'application/json', 'Authorization': authorization}
    raw = None
    if body is not None:
        raw = json.dumps(
            body, sort_keys=True, separators=(',', ':'), allow_nan=False,
        ).encode('utf-8')
        headers['Content-Type'] = 'application/json'
    request = _request_bytes(method, path, 'jellyfin', headers, raw)
    if not final:
        request = request.replace(
            b'Connection: close\r\n', b'Connection: keep-alive\r\n', 1)
    return request


def _name(value, maximum=128):
    return (type(value) is str and 1 <= len(value) <= maximum
            and value == value.strip()
            and all(unicodedata.category(char)[0] != 'C' for char in value))


def _authentication(value, username):
    if type(value) is not dict or set(value) != _AUTH_FIELDS:
        raise ValueError()
    user, session = value['User'], value['SessionInfo']
    if (type(user) is not dict or user.get('Name') != username
            or type(user.get('Id')) is not str or _ID.fullmatch(user['Id']) is None
            or type(session) is not dict or type(session.get('Id')) is not str
            or _ID.fullmatch(session['Id']) is None
            or type(value['AccessToken']) is not str
            or _TOKEN.fullmatch(value['AccessToken']) is None
            or type(value['ServerId']) is not str
            or _ID.fullmatch(value['ServerId']) is None):
        raise ValueError()
    return value['AccessToken'], value['ServerId']


def _keys(value):
    if (type(value) is not dict or set(value) != {
            'Items', 'TotalRecordCount', 'StartIndex'}
            or type(value['Items']) is not list or len(value['Items']) > 256
            or type(value['TotalRecordCount']) is not int
            or value['TotalRecordCount'] != len(value['Items'])
            or value['StartIndex'] != 0):
        raise ValueError()
    matching = []
    for item in value['Items']:
        if (type(item) is not dict
                or not _KEY_REQUIRED_FIELDS <= set(item) <= _KEY_FIELDS):
            raise ValueError()
        if item['AppName'] == 'Larenor Core':
            if (item['IsActive'] is not True or item.get('DateRevoked') is not None
                    or type(item['AccessToken']) is not str
                    or _TOKEN.fullmatch(item['AccessToken']) is None):
                raise ValueError()
            matching.append(item['AccessToken'])
    if len(matching) > 1:
        raise ValueError()
    return matching[0] if matching else None


def _system(value, server_id):
    if (type(value) is not dict or value.get('Id') != server_id
            or value.get('StartupWizardCompleted') is not True
            or value.get('ProductName') != 'Jellyfin Server'
            or not _name(value.get('ServerName'))
            or type(value.get('Version')) is not str
            or _VERSION.fullmatch(value['Version']) is None):
        raise ValueError()
    return value['ServerName'], value['Version']


def _libraries(value):
    if type(value) is not list or len(value) > 256:
        raise ValueError()
    result = []
    for item in value:
        if type(item) is not dict or not {
                'Name', 'Locations', 'CollectionType', 'ItemId'} <= set(item):
            raise ValueError()
        name, locations = item['Name'], item['Locations']
        collection, identifier = item['CollectionType'], item['ItemId']
        if (not _name(name) or type(locations) is not list or len(locations) > 16
                or collection is not None and (
                    type(collection) is not str or _COLLECTION.fullmatch(collection) is None)
                or type(identifier) is not str or _ID.fullmatch(identifier) is None):
            raise ValueError()
        paths = []
        for path in locations:
            if (type(path) is not str or not 7 <= len(path) <= 1024
                    or not path.startswith('/media/') or path.endswith('/')
                    or '//' in path or any(part in {'', '.', '..'} for part in path.split('/')[2:])
                    or any(ord(char) < 32 or ord(char) > 126 for char in path)):
                raise ValueError()
            paths.append(path)
        result.append((name, collection, identifier, tuple(paths)))
    return tuple(result)


class JellyfinAuthenticatedReadback:
    """Authenticate, provision one app key, and read safe managed facts."""

    def read(self, connection, bootstrap, *, device_id,
             limits=JellyfinAuthenticatedReadbackLimits()):
        if (type(limits) is not JellyfinAuthenticatedReadbackLimits
                or type(bootstrap) is not PrivateMediaServiceBootstrap
                or type(device_id) is not str or _ID.fullmatch(device_id) is None):
            raise JellyfinAuthenticatedReadbackError(
                'invalid_jellyfin_authenticated_readback')
        try:
            limits = JellyfinAuthenticatedReadbackLimits(**vars(limits))
            bootstrap = PrivateMediaServiceBootstrap.model_validate(
                bootstrap.model_dump(mode='python'))
        except (ValidationError, ValueError, TypeError, AttributeError,
                JellyfinAuthenticatedReadbackError):
            raise JellyfinAuthenticatedReadbackError(
                'invalid_jellyfin_authenticated_readback') from None
        methods = ('sendall', 'recv', 'settimeout', 'shutdown', 'close')
        if any(not callable(getattr(connection, name, None)) for name in methods):
            raise JellyfinAuthenticatedReadbackError(
                'invalid_jellyfin_authenticated_readback')

        deadline = time.monotonic() + limits.total_seconds
        completed = []
        created = False
        cleanup_sent = False
        scope = None
        try:
            scope = _Deadline(deadline)
            scope.attach(connection)
            reader = _StartupReader(connection, deadline)
            base = _BASE_AUTH.format(device=device_id)

            status, raw = self._request(
                connection, reader, deadline, limits,
                'POST', '/Users/AuthenticateByName',
                {'Username': bootstrap.username, 'Pw': bootstrap.credential}, base,
            )
            if status in {401, 403}:
                raise JellyfinAuthenticatedReadbackError('jellyfin_authentication_failed')
            if status != 200:
                raise JellyfinAuthenticatedReadbackError(
                    'jellyfin_authenticated_readback_protocol')
            session, server_id = _authentication(_json(raw), bootstrap.username)
            completed.append('authenticated')
            session_auth = base + ', Token=' + session

            status, raw = self._request(
                connection, reader, deadline, limits,
                'GET', '/Auth/Keys', None, session_auth,
            )
            if status != 200:
                raise ValueError()
            api_key = _keys(_json(raw))
            completed.append('keys_observed')
            if api_key is None:
                status, raw = self._request(
                    connection, reader, deadline, limits,
                    'POST', '/Auth/Keys?app=Larenor%20Core', None, session_auth,
                )
                created = True
                if status != 204 or raw:
                    raise ValueError()
                completed.append('key_created')
                status, raw = self._request(
                    connection, reader, deadline, limits,
                    'GET', '/Auth/Keys', None, session_auth,
                )
                if status != 200:
                    raise ValueError()
                api_key = _keys(_json(raw))
                if api_key is None:
                    raise ValueError()
            completed.append('key_verified')
            key_auth = base + ', Token=' + api_key

            status, raw = self._request(
                connection, reader, deadline, limits,
                'GET', '/System/Info', None, key_auth,
            )
            if status != 200:
                raise ValueError()
            server_name, version = _system(_json(raw), server_id)
            completed.append('system_verified')

            status, raw = self._request(
                connection, reader, deadline, limits,
                'GET', '/Library/VirtualFolders', None, key_auth,
            )
            if status != 200:
                raise ValueError()
            libraries = _libraries(_json(raw))
            completed.append('libraries_verified')
            cleanup_sent = True
            status, raw = self._request(
                connection, reader, deadline, limits,
                'POST', '/Sessions/Logout', None, session_auth, final=True,
            )
            if status != 204 or raw:
                raise JellyfinAuthenticatedReadbackError(
                    'jellyfin_session_cleanup_failed',
                    completed_steps=completed, uncertain_effect=True,
                )
            completed.append('session_closed')
            return JellyfinAuthenticatedReadbackResult(
                'verified', server_id, server_name, version, api_key, libraries,
                tuple(completed),
            )
        except JellyfinAuthenticatedReadbackError as error:
            if error.completed_steps or error.uncertain_effect:
                raise
            raise JellyfinAuthenticatedReadbackError(
                error.code, completed_steps=completed,
                uncertain_effect=created or cleanup_sent,
            ) from None
        except (socket.timeout, TimeoutError):
            raise JellyfinAuthenticatedReadbackError(
                'jellyfin_authenticated_readback_timeout',
                completed_steps=completed,
                uncertain_effect=created or cleanup_sent,
            ) from None
        except _ConnectionLost:
            raise JellyfinAuthenticatedReadbackError(
                'jellyfin_authenticated_readback_unavailable',
                completed_steps=completed,
                uncertain_effect=created or cleanup_sent,
            ) from None
        except (ProbeTransportError, ValueError, TypeError, AttributeError,
                UnicodeError, json.JSONDecodeError):
            code = ('jellyfin_authenticated_readback_timeout'
                    if time.monotonic() >= deadline
                    else 'jellyfin_authenticated_readback_protocol')
            raise JellyfinAuthenticatedReadbackError(
                code, completed_steps=completed,
                uncertain_effect=created or cleanup_sent,
            ) from None
        except (OSError, RuntimeError):
            code = ('jellyfin_authenticated_readback_timeout'
                    if time.monotonic() >= deadline
                    else 'jellyfin_authenticated_readback_unavailable')
            raise JellyfinAuthenticatedReadbackError(
                code, completed_steps=completed,
                uncertain_effect=created or cleanup_sent,
            ) from None
        finally:
            if scope is not None:
                scope.finish()

    @staticmethod
    def _request(connection, reader, deadline, limits, method, path, body,
                 authorization, *, final=False):
        connection.settimeout(_remaining(deadline))
        connection.sendall(_wire(
            method, path, body, authorization, final=final,
        ))
        status, raw, closes = _response(reader, limits.max_response_bytes)
        if closes and not final:
            raise ProbeTransportError('invalid_response')
        return status, raw
