"""Closed Jellyfin startup wizard protocol over one preverified stream.

This module cannot resolve, connect, redirect, retry or choose a destination.
Its caller must supply a newly connected stream whose container and private
control-network ownership were independently verified. The configurator takes
ownership of that stream and closes it after one bounded startup sequence.
"""

from dataclasses import dataclass
import json
import math
import re
import socket
import time

from pydantic import ValidationError

from ..services.transport import _Deadline, _Reader, _remaining, _request_bytes
from ..services.transport import ProbeTransportError
from .media_service_bootstrap_models import PrivateMediaServiceBootstrap


_CODES = frozenset({
    'invalid_jellyfin_startup_request', 'invalid_jellyfin_startup_limits',
    'jellyfin_startup_protocol', 'jellyfin_startup_unavailable',
    'jellyfin_startup_timeout', 'jellyfin_already_configured',
})
_TOKEN = re.compile(rb"[!#$%&'*+.^_`|~0-9A-Za-z-]+\Z")
_STEPS = (
    ('GET', '/Startup/User', None, 'observed_unconfigured'),
    ('POST', '/Startup/Configuration', 'configuration', 'configuration_updated'),
    ('POST', '/Startup/User', 'user', 'user_updated'),
    ('POST', '/Startup/RemoteAccess', 'remote', 'remote_access_updated'),
    ('POST', '/Startup/Complete', None, 'wizard_completed'),
)


class JellyfinStartupError(Exception):
    """Secret-free outcome for a sequence that must never be blindly retried."""

    def __init__(self, code='jellyfin_startup_unavailable', *, completed_steps=(),
                 uncertain_effect=False):
        self.code = code if code in _CODES else 'jellyfin_startup_unavailable'
        self.completed_steps = tuple(completed_steps)
        self.uncertain_effect = uncertain_effect is True
        super().__init__(self.code)

    def __repr__(self):
        return (f"JellyfinStartupError({self.code!r}, completed_steps="
                f"{len(self.completed_steps)}, uncertain_effect={self.uncertain_effect!r})")


@dataclass(frozen=True)
class JellyfinStartupLimits:
    total_seconds: float = 30.0
    max_response_bytes: int = 4096

    def __post_init__(self):
        if (type(self.total_seconds) not in (int, float)
                or not math.isfinite(self.total_seconds)
                or not 0 < self.total_seconds <= 120
                or type(self.max_response_bytes) is not int
                or not 1 <= self.max_response_bytes <= 65536):
            raise JellyfinStartupError('invalid_jellyfin_startup_limits')


@dataclass(frozen=True)
class JellyfinStartupResult:
    state: str
    completed_steps: tuple[str, ...]


class _ConnectionLost(Exception):
    pass


class _StartupReader(_Reader):
    def __init__(self, connection, deadline):
        super().__init__(connection, deadline)
        self.response_bytes = 0

    def begin_response(self):
        self.response_bytes = 0

    def receive(self, count):
        value = super().receive(count)
        self.response_bytes += len(value)
        return value


def _unique(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError()
        value[key] = item
    return value


def _json(raw):
    try:
        return json.loads(raw.decode('utf-8'), object_pairs_hook=_unique,
                          parse_constant=lambda _value: (_ for _ in ()).throw(ValueError()))
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError, TypeError):
        raise JellyfinStartupError('jellyfin_startup_protocol') from None


def _headers(reader):
    reader.begin_response()
    try:
        first = reader.line(8192)
    except ProbeTransportError:
        if reader.response_bytes == 0:
            raise _ConnectionLost() from None
        raise
    match = re.fullmatch(rb'HTTP/1\.1 ([2-5][0-9]{2})(?: [\x20-\x7e]*)?\r\n', first)
    if match is None:
        raise ProbeTransportError('invalid_response')
    total, headers = len(first), []
    while True:
        line = reader.line(min(8192, 32768 - total))
        total += len(line)
        if line == b'\r\n':
            break
        if len(headers) >= 100 or b':' not in line:
            raise ProbeTransportError('invalid_response')
        name, value = line[:-2].split(b':', 1)
        if (_TOKEN.fullmatch(name) is None
                or any(byte < 32 and byte != 9 or byte == 127 for byte in value)):
            raise ProbeTransportError('invalid_response')
        headers.append((name.decode('ascii').lower(), value.decode('latin1').strip(' \t')))
    return int(match[1]), tuple(headers)


def _response(reader, maximum, *, content_type='application/json'):
    status, headers = _headers(reader)
    framing = {}
    for key, value in headers:
        if key in {'content-length', 'transfer-encoding', 'content-encoding',
                   'content-type', 'connection'}:
            if key in framing:
                raise ProbeTransportError('invalid_response')
            framing[key] = value.lower()
    if framing.get('content-encoding', 'identity') != 'identity':
        raise ProbeTransportError('unsupported_encoding')
    length, transfer = framing.get('content-length'), framing.get('transfer-encoding')
    if transfer not in (None, 'chunked') or length is not None and transfer is not None:
        raise ProbeTransportError('invalid_response')
    connection_header = framing.get('connection')
    if connection_header not in (None, 'keep-alive', 'close'):
        raise ProbeTransportError('invalid_response')
    if status == 204:
        if transfer is not None or length not in (None, '0'):
            raise ProbeTransportError('invalid_response')
        body = b''
    else:
        if framing.get('content-type', '').split(';')[0].strip() != content_type:
            raise ProbeTransportError('invalid_response')
        if length is not None:
            if re.fullmatch(r'[0-9]{1,20}', length) is None or int(length) > maximum:
                raise ProbeTransportError('response_too_large')
            body = reader.exact(int(length))
        elif transfer == 'chunked':
            body = bytearray()
            for _ in range(256):
                line = reader.line(128)
                if re.fullmatch(rb'[0-9A-Fa-f]{1,16}\r\n', line) is None:
                    raise ProbeTransportError('invalid_response')
                size = int(line[:-2], 16)
                if size > maximum - len(body):
                    raise ProbeTransportError('response_too_large')
                if size == 0:
                    if reader.line(8192) != b'\r\n':
                        raise ProbeTransportError('invalid_response')
                    break
                body.extend(reader.exact(size))
                if reader.exact(2) != b'\r\n':
                    raise ProbeTransportError('invalid_response')
            else:
                raise ProbeTransportError('response_too_large')
            body = bytes(body)
        else:
            raise ProbeTransportError('invalid_response')
    return status, body, connection_header == 'close'


def _payloads(value):
    return {
        'configuration': {
            'UICulture': value.locale,
            'MetadataCountryCode': value.metadataCountryCode,
            'PreferredMetadataLanguage': value.preferredMetadataLanguage,
        },
        'user': {'Name': value.username, 'Password': value.credential},
        # Both required booleans stay false. The managed container separately
        # has no published host ports and only joins Larenor's internal network.
        'remote': {
            'EnableRemoteAccess': value.remote_access,
            'EnableAutomaticPortMapping': value.automatic_port_mapping,
        },
    }


def _wire(method, path, body, final):
    headers = {'Accept': 'application/json'}
    raw = None
    if body is not None:
        raw = json.dumps(body, sort_keys=True, separators=(',', ':')).encode('utf-8')
        headers['Content-Type'] = 'application/json'
    elif method == 'POST':
        headers['Content-Type'] = 'application/json'
    request = _request_bytes(method, path, 'jellyfin', headers, raw)
    if not final:
        request = request.replace(b'Connection: close\r\n', b'Connection: keep-alive\r\n', 1)
    return request


class JellyfinStartupConfigurator:
    """Executes the official fixed startup operations without target authority."""

    def configure(self, connection, bootstrap, *, limits=JellyfinStartupLimits()):
        if type(limits) is not JellyfinStartupLimits:
            raise JellyfinStartupError('invalid_jellyfin_startup_limits')
        try:
            limits = JellyfinStartupLimits(**vars(limits))
        except (TypeError, JellyfinStartupError):
            raise JellyfinStartupError('invalid_jellyfin_startup_limits') from None
        if type(bootstrap) is not PrivateMediaServiceBootstrap:
            raise JellyfinStartupError('invalid_jellyfin_startup_request')
        try:
            bootstrap = PrivateMediaServiceBootstrap.model_validate(
                bootstrap.model_dump(mode='python'))
        except (ValidationError, ValueError, TypeError, AttributeError):
            raise JellyfinStartupError('invalid_jellyfin_startup_request') from None
        methods = ('sendall', 'recv', 'settimeout', 'shutdown', 'close')
        if any(not callable(getattr(connection, name, None)) for name in methods):
            raise JellyfinStartupError('invalid_jellyfin_startup_request')

        deadline = time.monotonic() + limits.total_seconds
        completed = []
        sent_write = False
        scope = None
        try:
            scope = _Deadline(deadline)
            scope.attach(connection)
            reader = _StartupReader(connection, deadline)
            payloads = _payloads(bootstrap)
            for index, (method, path, payload_key, step) in enumerate(_STEPS):
                connection.settimeout(_remaining(deadline))
                body = None if payload_key is None else payloads[payload_key]
                connection.sendall(_wire(method, path, body, index == len(_STEPS) - 1))
                sent_write = method == 'POST'
                status, raw, closes = _response(reader, limits.max_response_bytes)
                if method == 'GET':
                    if status in {401, 403}:
                        raise JellyfinStartupError('jellyfin_already_configured')
                    if status != 200 or closes:
                        raise JellyfinStartupError('jellyfin_startup_protocol')
                    user = _json(raw)
                    if type(user) is not dict or not set(user) <= {'Name', 'Password'}:
                        raise JellyfinStartupError('jellyfin_startup_protocol')
                    if user.get('Password') not in (None, ''):
                        raise JellyfinStartupError('jellyfin_already_configured')
                    name = user.get('Name')
                    if (name not in (None, '')
                            and (type(name) is not str or not 1 <= len(name) <= 128
                                 or name != name.strip()
                                 or any(ord(char) < 32 or ord(char) == 127
                                        for char in name))):
                        raise JellyfinStartupError('jellyfin_startup_protocol')
                elif status != 204 or raw or closes and index != len(_STEPS) - 1:
                    raise JellyfinStartupError('jellyfin_startup_protocol')
                completed.append(step)
                sent_write = False
            return JellyfinStartupResult('succeeded', tuple(completed))
        except JellyfinStartupError as error:
            if error.completed_steps or error.uncertain_effect:
                raise
            raise JellyfinStartupError(error.code, completed_steps=completed,
                                        uncertain_effect=sent_write) from None
        except (socket.timeout, TimeoutError) as error:
            raise JellyfinStartupError('jellyfin_startup_timeout', completed_steps=completed,
                                        uncertain_effect=sent_write) from None
        except _ConnectionLost:
            raise JellyfinStartupError('jellyfin_startup_unavailable', completed_steps=completed,
                                        uncertain_effect=sent_write) from None
        except (OSError, RuntimeError, TypeError, ValueError):
            code = ('jellyfin_startup_timeout' if time.monotonic() >= deadline
                    else 'jellyfin_startup_unavailable')
            raise JellyfinStartupError(code, completed_steps=completed,
                                        uncertain_effect=sent_write) from None
        except ProbeTransportError:
            code = ('jellyfin_startup_timeout' if time.monotonic() >= deadline
                    else 'jellyfin_startup_protocol')
            raise JellyfinStartupError(code, completed_steps=completed,
                                        uncertain_effect=sent_write) from None
        finally:
            if scope is not None:
                scope.finish()
