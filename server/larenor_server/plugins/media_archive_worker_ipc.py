"""UID-private, bounded Unix IPC for read-only F30 archive collection."""

import json
import os
from pathlib import Path
import re
import socket
import stat
import struct
import threading
import time
import uuid

from pydantic import ValidationError

from .media_archive_core_models import PrivateMediaArchiveCollection
from .media_archive_health_models import MediaArchiveObservation


MAX_FRAME = 8 * 1024 * 1024
_ID = re.compile(r'[0-9a-f]{32}\Z')


class MediaArchiveWorkerError(Exception):
    _CODES = frozenset({
        'worker_unavailable', 'invalid_frame', 'invalid_request',
        'invalid_worker_result', 'replay_rejected', 'deadline_exceeded',
        'cancelled',
    })

    def __init__(self, code='worker_unavailable'):
        self.code = code if code in self._CODES else 'worker_unavailable'
        super().__init__(self.code)

    def __repr__(self):
        return f'MediaArchiveWorkerError({self.code!r})'


def _timeout(connection, deadline):
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise MediaArchiveWorkerError('deadline_exceeded')
    connection.settimeout(remaining)


def _receive(connection, size, deadline):
    result = bytearray()
    while len(result) < size:
        _timeout(connection, deadline)
        try:
            part = connection.recv(size - len(result))
        except socket.timeout:
            raise MediaArchiveWorkerError('deadline_exceeded') from None
        if not part:
            raise MediaArchiveWorkerError('invalid_frame')
        result.extend(part)
    return bytes(result)


def _pairs(values):
    result = {}
    for key, value in values:
        if key in result:
            raise ValueError()
        result[key] = value
    return result


def read_frame(connection, deadline):
    try:
        size = struct.unpack('!I', _receive(connection, 4, deadline))[0]
        if not 1 <= size <= MAX_FRAME:
            raise MediaArchiveWorkerError('invalid_frame')
        value = json.loads(
            _receive(connection, size, deadline).decode('utf-8'),
            object_pairs_hook=_pairs,
            parse_constant=lambda _value: (_ for _ in ()).throw(ValueError()),
        )
        if (type(value) is not dict or type(value.get('protocol')) is not int
                or value['protocol'] != 1
                or type(value.get('requestId')) is not str
                or _ID.fullmatch(value['requestId']) is None):
            raise MediaArchiveWorkerError('invalid_frame')
        return value
    except MediaArchiveWorkerError:
        raise
    except (OSError, UnicodeError, ValueError, TypeError, RecursionError,
            struct.error):
        raise MediaArchiveWorkerError('invalid_frame') from None


def write_frame(connection, value, deadline):
    try:
        raw = json.dumps(
            value, sort_keys=True, separators=(',', ':'),
            ensure_ascii=True, allow_nan=False,
        ).encode('ascii')
        if not 1 <= len(raw) <= MAX_FRAME:
            raise MediaArchiveWorkerError('invalid_frame')
        _timeout(connection, deadline)
        connection.sendall(struct.pack('!I', len(raw)) + raw)
    except MediaArchiveWorkerError:
        raise
    except (OSError, ValueError, TypeError, RecursionError):
        raise MediaArchiveWorkerError('invalid_frame') from None


def _peer_uid(connection):
    if not hasattr(socket, 'SO_PEERCRED'):
        raise MediaArchiveWorkerError()
    try:
        return struct.unpack(
            '3i', connection.getsockopt(
                socket.SOL_SOCKET, socket.SO_PEERCRED, 12))[1]
    except (OSError, struct.error):
        raise MediaArchiveWorkerError() from None


def _socket_identity(path, owner_uid):
    try:
        info = path.lstat()
    except OSError:
        raise MediaArchiveWorkerError() from None
    if (not stat.S_ISSOCK(info.st_mode) or info.st_uid != owner_uid
            or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1):
        raise MediaArchiveWorkerError()
    return info.st_dev, info.st_ino


def _gate(value):
    try:
        if value() is not True:
            raise ValueError()
    except Exception:
        raise MediaArchiveWorkerError('cancelled') from None


class MediaArchiveWorkerClient:
    def __init__(self, path, *, owner_uid=0, peer_uid=None, timeout=5):
        if (type(owner_uid) is not int or owner_uid < 0
                or type(timeout) not in (int, float)
                or type(timeout) is bool or not 0 < timeout <= 5):
            raise MediaArchiveWorkerError()
        self.path = Path(path).absolute()
        self.owner_uid = owner_uid
        self.peer_uid = peer_uid or _peer_uid
        self.timeout = timeout

    def _exchange(self, request, deadline):
        identity = _socket_identity(self.path, self.owner_uid)
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
                _timeout(connection, deadline)
                connection.connect(str(self.path))
                if (_socket_identity(self.path, self.owner_uid) != identity
                        or self.peer_uid(connection) != self.owner_uid):
                    raise MediaArchiveWorkerError()
                write_frame(connection, request, deadline)
                response = read_frame(connection, deadline)
        except MediaArchiveWorkerError as error:
            if error.code == 'invalid_frame':
                raise MediaArchiveWorkerError() from None
            raise
        except (OSError, ValueError, TypeError):
            raise MediaArchiveWorkerError() from None
        if response.get('requestId') != request['requestId']:
            raise MediaArchiveWorkerError('invalid_worker_result')
        if set(response) == {'protocol', 'requestId', 'error'}:
            raise MediaArchiveWorkerError(response['error'])
        if set(response) != {'protocol', 'requestId', 'result'}:
            raise MediaArchiveWorkerError('invalid_worker_result')
        return response['result']

    def status(self):
        deadline = time.monotonic() + self.timeout
        result = self._exchange({
            'protocol': 1, 'requestId': uuid.uuid4().hex,
            'operation': 'status',
        }, deadline)
        expected = {'state', 'readAvailable', 'mutationAvailable'}
        if (type(result) is not dict or set(result) != expected
                or result.get('state') not in {'ready', 'unavailable'}
                or type(result.get('readAvailable')) is not bool
                or result.get('mutationAvailable') is not False
                or (result['state'] == 'ready') != result['readAvailable']):
            raise MediaArchiveWorkerError('invalid_worker_result')
        return result

    def read_media_archive(self, private, *, deadline, gate):
        now = time.monotonic()
        if (type(private) is not PrivateMediaArchiveCollection
                or type(deadline) not in (int, float)
                or type(deadline) is bool or not now < deadline <= now + 5
                or not callable(gate)):
            raise MediaArchiveWorkerError('invalid_request')
        try:
            selected = PrivateMediaArchiveCollection.model_validate(
                private.model_dump(mode='python'))
        except (ValidationError, ValueError, TypeError, AttributeError):
            raise MediaArchiveWorkerError('invalid_request') from None
        _gate(gate)
        result = self._exchange({
            'protocol': 1, 'requestId': selected.requestId,
            'operation': 'read_archive_health',
            'private': selected.model_dump(mode='json'),
        }, min(deadline, time.monotonic() + self.timeout))
        _gate(gate)
        try:
            return MediaArchiveObservation.model_validate(result)
        except (ValidationError, ValueError, TypeError, AttributeError,
                RecursionError, OverflowError):
            raise MediaArchiveWorkerError('invalid_worker_result') from None


class MediaArchiveWorkerServer:
    """A single-flight supervised worker with an unavailable default effect."""

    def __init__(self, path, collector, *, allowed_uid, peer_uid=None,
                 timeout=5):
        if (type(allowed_uid) is not int or allowed_uid < 0
                or type(timeout) not in (int, float) or type(timeout) is bool
                or not 0 < timeout <= 5):
            raise MediaArchiveWorkerError()
        self.path = Path(path).absolute()
        self.collector = collector
        self.allowed_uid = allowed_uid
        self.peer_uid = peer_uid or _peer_uid
        self.timeout = timeout
        self._listener = None
        self._thread = None
        self._identity = None
        self._stopped = threading.Event()
        self._ready = threading.Event()
        self._startup_failed = False
        self._seen = set()
        self._seen_lock = threading.Lock()

    @property
    def read_available(self):
        return callable(getattr(self.collector, 'collect', None))

    def start(self):
        if self._listener is not None or self._thread is not None:
            raise MediaArchiveWorkerError()
        try:
            parent = self.path.parent.lstat()
            if (not stat.S_ISDIR(parent.st_mode) or parent.st_uid != os.getuid()
                    or self.path.exists() or self.path.is_symlink()):
                raise MediaArchiveWorkerError()
            listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            self._listener = listener
            listener.bind(str(self.path))
            os.chmod(self.path, 0o600)
            self._identity = _socket_identity(self.path, os.getuid())
            listener.listen(4)
            listener.settimeout(.1)
            self._stopped.clear()
            self._ready.clear()
            self._startup_failed = False
            self._thread = threading.Thread(
                target=self._serve, name='larenor-media-archive', daemon=True)
            self._thread.start()
            if not self._ready.wait(self.timeout) or self._startup_failed:
                raise MediaArchiveWorkerError()
        except Exception:
            self.close()
            raise MediaArchiveWorkerError() from None

    def _serve(self):
        opened = False
        try:
            if self.read_available:
                opening = getattr(self.collector, 'open', None)
                if callable(opening):
                    opening(time.monotonic() + self.timeout)
                opened = True
            self._ready.set()
            while not self._stopped.is_set():
                try:
                    connection, _ = self._listener.accept()
                except socket.timeout:
                    continue
                except OSError:
                    break
                with connection:
                    deadline = time.monotonic() + self.timeout
                    try:
                        if self.peer_uid(connection) != self.allowed_uid:
                            continue
                        request = read_frame(connection, deadline)
                        write_frame(
                            connection, self.answer(request, deadline=deadline),
                            deadline)
                    except MediaArchiveWorkerError:
                        continue
        except Exception:
            self._startup_failed = True
            self._stopped.set()
        finally:
            if opened:
                closing = getattr(self.collector, 'close', None)
                if callable(closing):
                    try:
                        closing()
                    except Exception:
                        self._startup_failed = True
            self._ready.set()

    def answer(self, request, *, deadline):
        request_id = request.get('requestId') if type(request) is dict else None
        if type(request_id) is not str or _ID.fullmatch(request_id) is None:
            raise MediaArchiveWorkerError('invalid_request')
        try:
            if (request.get('operation') == 'status'
                    and set(request) == {'protocol', 'requestId', 'operation'}):
                available = self.read_available
                result = {
                    'state': 'ready' if available else 'unavailable',
                    'readAvailable': available,
                    'mutationAvailable': False,
                }
            elif (request.get('operation') == 'read_archive_health'
                  and set(request) == {
                      'protocol', 'requestId', 'operation', 'private'}):
                if not self.read_available:
                    raise MediaArchiveWorkerError('worker_unavailable')
                try:
                    private = PrivateMediaArchiveCollection.model_validate(
                        request['private'])
                except (ValidationError, ValueError, TypeError, AttributeError):
                    raise MediaArchiveWorkerError('invalid_request') from None
                if private.requestId != request_id:
                    raise MediaArchiveWorkerError('invalid_request')
                with self._seen_lock:
                    if request_id in self._seen:
                        raise MediaArchiveWorkerError('replay_rejected')
                    if len(self._seen) >= 256:
                        raise MediaArchiveWorkerError('worker_unavailable')
                    self._seen.add(request_id)
                if time.monotonic() >= deadline:
                    raise MediaArchiveWorkerError('deadline_exceeded')
                try:
                    observed = self.collector.collect(
                        private, deadline=deadline,
                        gate=lambda: (not self._stopped.is_set()
                                      and time.monotonic() < deadline))
                    if (time.monotonic() >= deadline
                            or type(observed) is not MediaArchiveObservation):
                        raise ValueError()
                    result = MediaArchiveObservation.model_validate(
                        observed.model_dump(mode='python')).model_dump(
                            mode='json')
                except MediaArchiveWorkerError:
                    raise
                except Exception:
                    raise MediaArchiveWorkerError(
                        'worker_unavailable') from None
            else:
                raise MediaArchiveWorkerError('invalid_request')
            return {'protocol': 1, 'requestId': request_id, 'result': result}
        except MediaArchiveWorkerError as error:
            return {'protocol': 1, 'requestId': request_id,
                    'error': error.code}

    def close(self):
        self._stopped.set()
        listener, self._listener = self._listener, None
        if listener is not None:
            try:
                listener.close()
            except OSError:
                pass
        thread, self._thread = self._thread, None
        if thread is not None and thread is not threading.current_thread():
            thread.join(self.timeout + .2)
        try:
            if self._identity is not None and self.path.exists():
                info = self.path.lstat()
                if (info.st_dev, info.st_ino) == self._identity:
                    self.path.unlink()
        except OSError:
            pass
        self._identity = None
