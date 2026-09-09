"""Idempotent configuration of Larenor-owned Jellyfin media libraries.

The caller supplies one freshly proved stream and the private authenticated
readback from the same retained installation authority. Library names, types
and paths are fixed here; no destination, path, token or retry control enters
through an API request or public model.
"""

from dataclasses import dataclass, field
import json
import math
import socket
import time

from ..services.transport import _Deadline, _remaining
from ..services.transport import ProbeTransportError
from .jellyfin_authenticated_readback import (
    JellyfinAuthenticatedReadbackResult, _BASE_AUTH, _ID, _TOKEN, _libraries,
    _wire,
)
from .jellyfin_startup import _ConnectionLost, _StartupReader, _json, _response


_CODES = frozenset({
    'invalid_jellyfin_libraries', 'jellyfin_library_conflict',
    'jellyfin_library_protocol', 'jellyfin_library_unavailable',
    'jellyfin_library_timeout',
})
_DESIRED = (
    ('movies', 'Larenor Movies', 'movies', '/media/movies'),
    ('shows', 'Larenor Shows', 'tvshows', '/media/shows'),
)
_QUERY = {
    'movies': ('/Library/VirtualFolders?name=Larenor%20Movies&collectionType=movies'
               '&paths=%2Fmedia%2Fmovies&refreshLibrary=false'),
    'shows': ('/Library/VirtualFolders?name=Larenor%20Shows&collectionType=tvshows'
              '&paths=%2Fmedia%2Fshows&refreshLibrary=false'),
}


class JellyfinManagedLibrariesError(Exception):
    """Static, secret-free outcome for a bounded library mutation."""

    def __init__(self, code='jellyfin_library_unavailable', *,
                 completed_steps=(), uncertain_effect=False):
        self.code = code if code in _CODES else 'jellyfin_library_unavailable'
        self.completed_steps = tuple(completed_steps)
        self.uncertain_effect = uncertain_effect is True
        super().__init__(self.code)

    def __repr__(self):
        return ('JellyfinManagedLibrariesError({!r}, completed_steps={}, '
                'uncertain_effect={!r})').format(
                    self.code, len(self.completed_steps), self.uncertain_effect)


@dataclass(frozen=True)
class JellyfinManagedLibrariesLimits:
    total_seconds: float = 30.0
    max_response_bytes: int = 262144

    def __post_init__(self):
        if (type(self.total_seconds) not in (int, float)
                or not math.isfinite(self.total_seconds)
                or not 0 < self.total_seconds <= 120
                or type(self.max_response_bytes) is not int
                or not 1 <= self.max_response_bytes <= 1048576):
            raise JellyfinManagedLibrariesError('invalid_jellyfin_libraries')


@dataclass(frozen=True, repr=False)
class JellyfinManagedLibrariesResult:
    state: str
    created: tuple[str, ...]
    libraries: tuple[tuple[str, str | None, str, tuple[str, ...]], ...] = field(
        repr=False)
    completed_steps: tuple[str, ...]

    def __repr__(self):
        return ('JellyfinManagedLibrariesResult(state={!r}, created={}, '
                'libraries={}, completed_steps={})').format(
                    self.state, len(self.created), len(self.libraries),
                    len(self.completed_steps))


def _validated_readback(value):
    if (type(value) is not JellyfinAuthenticatedReadbackResult
            or value.state != 'verified'
            or type(value.api_key) is not str
            or _TOKEN.fullmatch(value.api_key) is None
            or type(value.server_id) is not str
            or _ID.fullmatch(value.server_id) is None
            or type(value.libraries) is not tuple
            or value.completed_steps[-1:] != ('session_closed',)):
        raise ValueError()
    # Reuse the same closed parser by projecting the private tuple to its
    # minimal wire form. This rejects model_construct/object mutation tricks.
    projected = [{
        'Name': name, 'CollectionType': collection, 'ItemId': identifier,
        'Locations': list(paths),
    } for name, collection, identifier, paths in value.libraries]
    if _libraries(projected) != value.libraries:
        raise ValueError()
    return value


def _coherent(current, desired):
    name, collection, _identifier, paths = current
    _slug, wanted_name, wanted_collection, wanted_path = desired
    if name == wanted_name:
        return collection == wanted_collection and paths == (wanted_path,)
    return wanted_path not in paths


class JellyfinManagedLibraries:
    """Create exactly two fixed libraries and verify the resulting state."""

    def ensure(self, connection, readback, *, device_id,
               limits=JellyfinManagedLibrariesLimits()):
        methods = ('sendall', 'recv', 'settimeout', 'shutdown', 'close')
        try:
            trusted = _validated_readback(readback)
            limits = JellyfinManagedLibrariesLimits(**vars(limits))
            if (type(device_id) is not str or _ID.fullmatch(device_id) is None
                    or any(not callable(getattr(connection, name, None))
                           for name in methods)):
                raise ValueError()
        except (ValueError, TypeError, AttributeError, RecursionError,
                JellyfinManagedLibrariesError):
            raise JellyfinManagedLibrariesError(
                'invalid_jellyfin_libraries') from None

        deadline = time.monotonic() + limits.total_seconds
        completed = []
        created = []
        scope = None
        try:
            scope = _Deadline(deadline)
            scope.attach(connection)
            reader = _StartupReader(connection, deadline)
            authorization = (_BASE_AUTH.format(device=device_id)
                             + ', Token=' + trusted.api_key)

            status, raw = self._request(
                connection, reader, deadline, limits,
                'GET', '/Library/VirtualFolders', authorization,
            )
            if status != 200:
                raise ValueError()
            initial = _libraries(_json(raw))
            if (len(initial) != len(trusted.libraries)
                    or set(initial) != set(trusted.libraries)):
                raise JellyfinManagedLibrariesError('jellyfin_library_conflict')
            completed.append('observed')

            for desired in _DESIRED:
                matching = [item for item in initial if item[0] == desired[1]]
                if (len(matching) > 1
                        or any(not _coherent(item, desired) for item in initial)):
                    raise JellyfinManagedLibrariesError(
                        'jellyfin_library_conflict', completed_steps=completed)
                if matching:
                    continue
                status, raw = self._request(
                    connection, reader, deadline, limits,
                    'POST', _QUERY[desired[0]], authorization,
                )
                if status != 204 or raw:
                    raise ValueError()
                created.append(desired[0])
                completed.append(desired[0] + '_created')

            status, raw = self._request(
                connection, reader, deadline, limits,
                'GET', '/Library/VirtualFolders', authorization, final=True,
            )
            if status != 200:
                raise ValueError()
            final = _libraries(_json(raw))
            expected = {
                (desired[1], desired[2], (desired[3],)) for desired in _DESIRED
            }
            actual = {(name, collection, paths)
                      for name, collection, _identifier, paths in final}
            coherent = all(
                len([item for item in final if item[0] == desired[1]]) == 1
                and all(_coherent(item, desired) for item in final)
                for desired in _DESIRED
            )
            if (not coherent or not expected <= actual
                    or not set(initial) <= set(final)):
                raise ValueError()
            completed.append('verified')
            return JellyfinManagedLibrariesResult(
                'verified', tuple(created), final, tuple(completed))
        except JellyfinManagedLibrariesError as error:
            if error.completed_steps or error.uncertain_effect:
                raise
            raise JellyfinManagedLibrariesError(
                error.code, completed_steps=completed,
                uncertain_effect=bool(created),
            ) from None
        except (socket.timeout, TimeoutError):
            raise JellyfinManagedLibrariesError(
                'jellyfin_library_timeout', completed_steps=completed,
                uncertain_effect=bool(created),
            ) from None
        except _ConnectionLost:
            raise JellyfinManagedLibrariesError(
                'jellyfin_library_unavailable', completed_steps=completed,
                uncertain_effect=bool(created),
            ) from None
        except (ProbeTransportError, ValueError, TypeError, AttributeError,
                UnicodeError, json.JSONDecodeError):
            code = ('jellyfin_library_timeout' if time.monotonic() >= deadline
                    else 'jellyfin_library_protocol')
            raise JellyfinManagedLibrariesError(
                code, completed_steps=completed,
                uncertain_effect=bool(created),
            ) from None
        except (OSError, RuntimeError):
            code = ('jellyfin_library_timeout' if time.monotonic() >= deadline
                    else 'jellyfin_library_unavailable')
            raise JellyfinManagedLibrariesError(
                code, completed_steps=completed,
                uncertain_effect=bool(created),
            ) from None
        finally:
            if scope is not None:
                scope.finish()

    @staticmethod
    def _request(connection, reader, deadline, limits, method, path,
                 authorization, *, final=False):
        connection.settimeout(_remaining(deadline))
        connection.sendall(_wire(
            method, path, None, authorization, final=final,
        ))
        status, raw, closes = _response(reader, limits.max_response_bytes)
        if closes and not final:
            raise ProbeTransportError('invalid_response')
        return status, raw
