"""Bounded authenticated Sonarr/Radarr status readback on a verified stream."""

import json
import math
import socket
import time
from dataclasses import dataclass

from ..services.transport import (
    ProbeTransportError,
    _Deadline,
    _remaining,
    _request_bytes,
)
from .arr_owned_config import is_arr_api_key
from .jellyfin_startup import _ConnectionLost, _response, _StartupReader

_EXPECTED = {'sonarr': ('Sonarr', '4.0.19.2979'), 'radarr': ('Radarr', '6.3.0.10514')}
_CODES = frozenset(
    {
        'invalid_arr_authenticated_readback',
        'arr_authentication_failed',
        'arr_readback_protocol',
        'arr_readback_mismatch',
        'arr_authenticated_readback_unavailable',
        'arr_authenticated_readback_timeout',
    }
)


class ArrAuthenticatedReadbackError(Exception):
    def __init__(self, code='arr_authenticated_readback_unavailable'):
        self.code = code if code in _CODES else 'arr_authenticated_readback_unavailable'
        super().__init__(self.code)

    def __repr__(self):
        return f'ArrAuthenticatedReadbackError({self.code!r})'


@dataclass(frozen=True)
class ArrAuthenticatedReadbackLimits:
    total_seconds: float = 30.0
    max_response_bytes: int = 131072

    def __post_init__(self):
        if (
            type(self.total_seconds) not in (int, float)
            or not math.isfinite(self.total_seconds)
            or not 0 < self.total_seconds <= 120
            or type(self.max_response_bytes) is not int
            or not 1 <= self.max_response_bytes <= 1048576
        ):
            raise ArrAuthenticatedReadbackError('invalid_arr_authenticated_readback')


@dataclass(frozen=True)
class ArrAuthenticatedReadbackResult:
    state: str
    service_id: str
    app_name: str
    version: str


def _unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError()
        result[key] = value
    return result


class ArrAuthenticatedReadback:
    def read(
        self,
        connection,
        *,
        service_id,
        api_key,
        limits=ArrAuthenticatedReadbackLimits(),
    ):
        if (
            service_id not in _EXPECTED
            or not is_arr_api_key(api_key)
            or type(limits) is not ArrAuthenticatedReadbackLimits
            or any(
                not callable(getattr(connection, name, None))
                for name in ('sendall', 'recv', 'settimeout', 'shutdown', 'close')
            )
        ):
            raise ArrAuthenticatedReadbackError('invalid_arr_authenticated_readback')
        try:
            limits = ArrAuthenticatedReadbackLimits(**vars(limits))
        except (ValueError, TypeError, AttributeError, ArrAuthenticatedReadbackError):
            raise ArrAuthenticatedReadbackError(
                'invalid_arr_authenticated_readback'
            ) from None
        deadline = time.monotonic() + limits.total_seconds
        scope = None
        try:
            scope = _Deadline(deadline)
            scope.attach(connection)
            connection.settimeout(_remaining(deadline))
            connection.sendall(
                _request_bytes(
                    'GET',
                    '/api/v3/system/status',
                    service_id,
                    {'Accept': 'application/json', 'X-Api-Key': api_key},
                    None,
                )
            )
            status, raw, _ = _response(
                _StartupReader(connection, deadline),
                limits.max_response_bytes,
                content_type='application/json',
                error_content_type='text/plain',
            )
            if status in {401, 403}:
                raise ArrAuthenticatedReadbackError('arr_authentication_failed')
            if status != 200:
                raise ArrAuthenticatedReadbackError('arr_readback_protocol')
            try:
                value = json.loads(
                    raw.decode('utf-8'),
                    object_pairs_hook=_unique,
                    parse_constant=lambda _v: (_ for _ in ()).throw(ValueError()),
                )
            except (UnicodeError, json.JSONDecodeError, ValueError, TypeError):
                raise ArrAuthenticatedReadbackError('arr_readback_protocol') from None
            if (
                type(value) is not dict
                or type(value.get('appName')) is not str
                or type(value.get('version')) is not str
            ):
                raise ArrAuthenticatedReadbackError('arr_readback_protocol')
            expected_name, expected_version = _EXPECTED[service_id]
            if (
                value['appName'] != expected_name
                or value['version'] != expected_version
            ):
                raise ArrAuthenticatedReadbackError('arr_readback_mismatch')
            return ArrAuthenticatedReadbackResult(
                'verified', service_id, expected_name, expected_version
            )
        except ArrAuthenticatedReadbackError:
            raise
        except (socket.timeout, TimeoutError):
            raise ArrAuthenticatedReadbackError(
                'arr_authenticated_readback_timeout'
            ) from None
        except _ConnectionLost:
            raise ArrAuthenticatedReadbackError(
                'arr_authenticated_readback_unavailable'
            ) from None
        except (
            ProbeTransportError,
            ValueError,
            TypeError,
            AttributeError,
            UnicodeError,
        ):
            raise ArrAuthenticatedReadbackError('arr_readback_protocol') from None
        except (OSError, RuntimeError):
            raise ArrAuthenticatedReadbackError(
                'arr_authenticated_readback_timeout'
                if time.monotonic() >= deadline
                else 'arr_authenticated_readback_unavailable'
            ) from None
        finally:
            if scope is not None:
                scope.finish()
