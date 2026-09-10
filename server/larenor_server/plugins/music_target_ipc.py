"""UID-private bounded Unix socket IPC for Music Assistant playback effects."""

import fcntl
import json
import math
import os
from pathlib import Path
import socket
import stat
import threading
import time

from .music_target_effect_models import (
    MusicTargetEffectEnvelope, MusicTargetEffectResult,
)
from .preflight_ipc import (
    MAX_PACKET, _peer_uid, read_packet, write_packet,
)
from .worker import DockerWorkerError, _safe_path


class MusicTargetIPCError(Exception):
    def __init__(self, code='worker_unavailable'):
        self.code = code if code in {
            'worker_unavailable', 'invalid_request',
            'invalid_worker_result'} else 'worker_unavailable'
        super().__init__(self.code)


def _same_target(expected, actual):
    return (
        actual.id == expected.id
        and actual.provider == expected.provider
        and actual.transport == expected.transport
        and actual.kind == expected.kind
        and actual.homePod == expected.homePod
        and actual.groupMemberIds == expected.groupMemberIds
        and actual.queueId == expected.queueId
        and actual.capabilities == expected.capabilities)


class MusicTargetWorkerClient:
    def __init__(self, path, *, owner_uid=0, peer_uid=None, timeout=5):
        if (type(owner_uid) is not int or owner_uid < 0
                or type(timeout) not in (int, float)
                or not 0 < timeout <= 5):
            raise MusicTargetIPCError()
        self.path = Path(path).absolute()
        self.owner_uid = owner_uid
        self.peer_uid = peer_uid or _peer_uid
        self.timeout = timeout

    def execute_music_target_effect(self, action, *, deadline, gate):
        now = time.monotonic()
        if (type(action) is not MusicTargetEffectEnvelope
                or type(deadline) not in (int, float)
                or not math.isfinite(deadline)
                or not now < deadline <= now + 5
                or not callable(gate)):
            raise MusicTargetIPCError('invalid_request')
        try:
            if gate() is not True:
                raise MusicTargetIPCError('invalid_request')
            _safe_path(
                self.path, uid=self.owner_uid, kind=stat.S_ISSOCK,
                private=True)
            exchange_deadline = min(deadline, now + self.timeout)
            request = {
                'protocol': 1, 'requestId': action.requestId,
                'operation': 'music_target_effect',
                'effect': action.model_dump(mode='json', warnings=False),
            }
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
                connection.settimeout(max(0.001, exchange_deadline - time.monotonic()))
                connection.connect(str(self.path))
                if self.peer_uid(connection) != self.owner_uid:
                    raise MusicTargetIPCError()
                write_packet(connection, request, exchange_deadline)
                response = read_packet(connection, exchange_deadline)
            if response['requestId'] != action.requestId:
                raise MusicTargetIPCError('invalid_worker_result')
            if set(response) == {'protocol', 'requestId', 'error'}:
                raise MusicTargetIPCError()
            if set(response) != {'protocol', 'requestId', 'result'}:
                raise MusicTargetIPCError('invalid_worker_result')
            result = MusicTargetEffectResult.model_validate(response['result'])
            if (gate() is not True or time.monotonic() >= deadline
                    or result.executionId != action.executionId
                    or result.commandId != action.commandId
                    or result.requestId != action.requestId
                    or not _same_target(action.target, result.target)):
                raise MusicTargetIPCError('invalid_worker_result')
            return result
        except MusicTargetIPCError:
            raise
        except Exception:
            raise MusicTargetIPCError() from None


class MusicTargetWorkerServer:
    def __init__(self, path, backend, *, allowed_uid, peer_uid=None, timeout=5):
        if (type(allowed_uid) is not int or allowed_uid < 0
                or type(timeout) not in (int, float)
                or not 0 < timeout <= 5):
            raise MusicTargetIPCError()
        self.path = Path(path).absolute()
        self.backend, self.allowed_uid = backend, allowed_uid
        self.peer_uid, self.timeout = peer_uid or _peer_uid, timeout
        self._listener = self._thread = self._lock = self._identity = None
        self._stopped = threading.Event()
        self._connection_lock = threading.Lock()
        self._active = None
        self._seen_execution_ids = set()
        self._seen_request_ids = set()
        self._seen_lock = threading.Lock()

    def start(self):
        if self._listener is not None or self._lock is not None:
            raise MusicTargetIPCError()
        try:
            _safe_path(self.path.parent, uid=os.getuid(), kind=stat.S_ISDIR)
            lock_path = self.path.parent / (self.path.name + '.lock')
            descriptor = os.open(
                lock_path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
            self._lock = descriptor
            _safe_path(
                lock_path, uid=os.getuid(), kind=stat.S_ISREG, private=True)
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            if self.path.exists() or self.path.is_symlink():
                raise MusicTargetIPCError()
            listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            self._listener = listener
            listener.bind(str(self.path))
            info = self.path.lstat()
            self._identity = (info.st_dev, info.st_ino)
            os.chmod(self.path, 0o600)
            listener.listen(4)
            listener.settimeout(.1)
            self._stopped.clear()
            self._thread = threading.Thread(
                target=self._serve, name='larenor-music-target', daemon=True)
            self._thread.start()
        except Exception:
            self.close()
            raise MusicTargetIPCError() from None

    def _answer(self, request, deadline):
        if (set(request) != {
                'protocol', 'requestId', 'operation', 'effect'}
                or request['operation'] != 'music_target_effect'
                or time.monotonic() >= deadline):
            raise MusicTargetIPCError('invalid_request')
        try:
            raw = json.dumps(
                request['effect'], sort_keys=True, separators=(',', ':'),
                allow_nan=False)
            action = MusicTargetEffectEnvelope.model_validate_json(raw)
            if action.requestId != request['requestId']:
                raise ValueError()
            with self._seen_lock:
                if (len(self._seen_execution_ids) >= 256
                        or action.executionId in self._seen_execution_ids
                        or action.requestId in self._seen_request_ids):
                    raise ValueError()
                self._seen_execution_ids.add(action.executionId)
                self._seen_request_ids.add(action.requestId)
            result = self.backend.execute_music_target_effect(
                action, deadline=deadline,
                gate=lambda: time.monotonic() < deadline)
            if (time.monotonic() >= deadline
                    or type(result) is not MusicTargetEffectResult
                    or result.executionId != action.executionId
                    or result.commandId != action.commandId
                    or result.requestId != action.requestId
                    or not _same_target(action.target, result.target)):
                raise ValueError()
            return result.model_dump(mode='json', warnings=False)
        except MusicTargetIPCError:
            raise
        except Exception:
            raise MusicTargetIPCError('invalid_request') from None

    def _serve(self):
        while not self._stopped.is_set():
            try:
                connection, _ = self._listener.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            with connection:
                with self._connection_lock:
                    if self._stopped.is_set():
                        break
                    self._active = connection
                deadline = time.monotonic() + self.timeout
                try:
                    if self.peer_uid(connection) != self.allowed_uid:
                        continue
                    request = read_packet(connection, deadline)
                    try:
                        result = self._answer(request, deadline)
                        response = {
                            'protocol': 1, 'requestId': request['requestId'],
                            'result': result}
                    except Exception as error:
                        code = ('invalid_request'
                                if isinstance(error, MusicTargetIPCError)
                                and error.code == 'invalid_request'
                                else 'worker_unavailable')
                        response = {
                            'protocol': 1, 'requestId': request['requestId'],
                            'error': code}
                    write_packet(connection, response, deadline)
                except Exception:
                    pass
                finally:
                    with self._connection_lock:
                        self._active = None

    def close(self):
        self._stopped.set()
        if self._listener is not None:
            self._listener.close()
        with self._connection_lock:
            if self._active is not None:
                try:
                    self._active.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
        if self._thread is not None and self._thread.ident is not None:
            self._thread.join(self.timeout + .2)
            if self._thread.is_alive():
                raise MusicTargetIPCError()
        if self._identity is not None:
            try:
                info = self.path.lstat()
                if ((info.st_dev, info.st_ino) == self._identity
                        and stat.S_ISSOCK(info.st_mode)):
                    self.path.unlink()
            except FileNotFoundError:
                pass
        if self._lock is not None:
            os.close(self._lock)
        self._listener = self._thread = self._lock = self._identity = None
