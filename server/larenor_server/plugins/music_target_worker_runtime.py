"""Supervised private Music Assistant target worker runtime."""

import argparse
import json
import os
from pathlib import Path
import secrets
import signal
import stat
import sys
import threading
import time

from ..files import checked_path, private_directory, private_read, sync_directory
from .music_playback_runtime import MusicPlaybackRuntime
from .music_target_effect_runtime import MusicTargetEffectRuntime
from .music_target_ipc import MusicTargetWorkerServer
from .music_target_lease import MusicTargetCredentialLeaseStore


class MusicTargetWorkerConfigurationError(ValueError):
    pass


class _Parser(argparse.ArgumentParser):
    def error(self, _message):
        raise MusicTargetWorkerConfigurationError('invalid_worker_configuration')


def _uid(value):
    try:
        if not value.isdecimal() or not 0 <= int(value) < 2**31:
            raise ValueError()
        return int(value)
    except Exception:
        raise MusicTargetWorkerConfigurationError(
            'invalid_worker_configuration') from None


def check_configuration(*, socket_path, lease_dir, lease_key_file, api_uid):
    """Validate local ownership only; deliberately performs no network I/O."""
    try:
        socket_path = checked_path(Path(socket_path).absolute())
        lease_dir = checked_path(Path(lease_dir).absolute())
        key_file = checked_path(Path(lease_key_file).absolute())
        if (type(api_uid) is not int or api_uid < 0
                or socket_path.parent not in {lease_dir, lease_dir.parent}
                or socket_path == key_file or lease_dir == key_file):
            raise ValueError()
        private_directory(socket_path.parent)
        private_directory(lease_dir)
        key = private_read(key_file, 32)
        if len(key) != 32:
            raise ValueError()
        MusicTargetCredentialLeaseStore(lease_dir, key)
        return {'effectAvailable': False, 'installAvailable': False}
    except Exception:
        raise MusicTargetWorkerConfigurationError('invalid_worker_configuration') from None


class AtomicMusicTargetWorkerHealth:
    _STATES = {'starting', 'ready', 'restarting', 'stopped', 'failed'}

    def __init__(self, path):
        self.path = checked_path(Path(path).absolute())

    def write(self, state, attempt):
        if state not in self._STATES or type(attempt) is not int or not 1 <= attempt <= 3:
            raise MusicTargetWorkerConfigurationError('invalid_worker_health')
        private_directory(self.path.parent)
        body = json.dumps({
            'schemaVersion': 1,
            'component': 'music_target_effect_worker',
            'state': state, 'attempt': attempt,
            'effectAvailable': False, 'installAvailable': False,
        }, sort_keys=True, separators=(',', ':')).encode('ascii')
        temporary = self.path.parent / (
            '.' + self.path.name + '.' + secrets.token_hex(12))
        descriptor = None
        try:
            descriptor = os.open(
                temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                0o600)
            with os.fdopen(descriptor, 'wb') as stream:
                descriptor = None
                stream.write(body)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, self.path)
            info = self.path.stat(follow_symlinks=False)
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid()
                    or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1):
                raise ValueError()
            sync_directory(self.path.parent)
        except Exception:
            raise MusicTargetWorkerConfigurationError('invalid_worker_health') from None
        finally:
            if descriptor is not None:
                os.close(descriptor)
            try:
                temporary.unlink()
            except FileNotFoundError:
                pass


class MusicTargetWorkerSession:
    def __init__(self, worker):
        self.worker = worker

    def start(self):
        self.worker.start()

    def wait(self, stop):
        while not stop.wait(.1):
            if self.worker._thread is None or not self.worker._thread.is_alive():
                raise RuntimeError('worker_unavailable')

    def close(self):
        self.worker.close()


def build_session(*, socket_path, lease_dir, key, api_uid, peer_uid=None,
                  timeout=5):
    leases = MusicTargetCredentialLeaseStore(lease_dir, key)
    backend = MusicTargetEffectRuntime(MusicPlaybackRuntime(), leases)
    return MusicTargetWorkerSession(MusicTargetWorkerServer(
        socket_path, backend, allowed_uid=api_uid, peer_uid=peer_uid,
        timeout=timeout))


class BoundedMusicTargetWorkerSupervisor:
    def __init__(self, factory, health, *, max_restarts=2,
                 initial_backoff=.25, maximum_backoff=1.0):
        if (not callable(factory) or type(health) is not AtomicMusicTargetWorkerHealth
                or type(max_restarts) is not int or not 0 <= max_restarts <= 2
                or type(initial_backoff) not in (int, float)
                or type(maximum_backoff) not in (int, float)
                or not 0 < initial_backoff <= maximum_backoff <= 1):
            raise MusicTargetWorkerConfigurationError('invalid_worker_configuration')
        self.factory, self.health = factory, health
        self.max_restarts = max_restarts
        self.initial_backoff, self.maximum_backoff = initial_backoff, maximum_backoff

    def run(self, stop):
        attempt = 1
        while True:
            session, failed = None, False
            try:
                self.health.write('starting', attempt)
                session = self.factory()
                session.start()
                self.health.write('ready', attempt)
                session.wait(stop)
                if not stop.is_set():
                    raise RuntimeError('worker_unavailable')
            except Exception:
                failed = True
            finally:
                if session is not None:
                    try:
                        session.close()
                    except Exception:
                        failed = True
            if stop.is_set():
                self.health.write('stopped', attempt)
                return 1 if failed else 0
            if attempt > self.max_restarts:
                self.health.write('failed', attempt)
                return 1
            self.health.write('restarting', attempt)
            if stop.wait(min(
                    self.maximum_backoff,
                    self.initial_backoff * (2 ** (attempt - 1)))):
                self.health.write('stopped', attempt)
                return 0
            attempt += 1


def _serve(args):
    stop = threading.Event()
    previous = {}

    def request_stop(_number, _frame):
        stop.set()

    try:
        for number in (signal.SIGINT, signal.SIGTERM):
            previous[number] = signal.getsignal(number)
            signal.signal(number, request_stop)
        key = private_read(args.lease_key_file, 32)
        health = AtomicMusicTargetWorkerHealth(args.health_receipt)
        supervisor = BoundedMusicTargetWorkerSupervisor(
            lambda: build_session(
                socket_path=args.socket, lease_dir=args.lease_dir,
                key=key, api_uid=args.api_uid), health)
        return supervisor.run(stop)
    finally:
        for number, handler in previous.items():
            signal.signal(number, handler)


def main(argv=None):
    parser = _Parser(prog='larenor-music-target-worker')
    parser.add_argument('--socket', required=True, type=Path)
    parser.add_argument('--lease-dir', required=True, type=Path)
    parser.add_argument('--lease-key-file', required=True, type=Path)
    parser.add_argument('--health-receipt', required=True, type=Path)
    parser.add_argument('--api-uid', required=True, type=_uid)
    parser.add_argument('--check-config', action='store_true')
    try:
        args = parser.parse_args(argv)
        args.socket = args.socket.absolute()
        args.lease_dir = args.lease_dir.absolute()
        args.lease_key_file = args.lease_key_file.absolute()
        args.health_receipt = args.health_receipt.absolute()
        state = check_configuration(
            socket_path=args.socket, lease_dir=args.lease_dir,
            lease_key_file=args.lease_key_file, api_uid=args.api_uid)
        if args.health_receipt.parent != args.socket.parent:
            raise MusicTargetWorkerConfigurationError(
                'invalid_worker_configuration')
        if args.check_config:
            return 0
        return _serve(args)
    except Exception:
        print('worker_unavailable', file=sys.stderr)
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
