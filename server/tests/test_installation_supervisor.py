"""Retained daemon evidence around every closed installation operation."""

from dataclasses import dataclass
import os
import socket
import struct
import sys
import threading
import time

import pytest

from larenor_server.plugins import installation_supervisor as supervisor
from larenor_server.plugins.daemon_context import DaemonContext
from larenor_server.plugins.docker_probe import DockerEndpoint


IDENTITY_MAP = ((0, 0, 4294967295),)


@dataclass(frozen=True)
class Snapshot:
    uids: tuple = (0, 0, 0, 0)
    gids: tuple = (0, 0, 0, 0)
    uid_map: tuple = IDENTITY_MAP
    gid_map: tuple = IDENTITY_MAP
    target_user_namespace: tuple = (1, 2)
    opener_user_namespace: tuple = (1, 2)


class Pair:
    def __init__(self, peer=None, worker=None):
        self.peer = peer or Snapshot()
        self.worker = worker or Snapshot()
        self.checks = 0
        self.closed = False
        self.fail_after = None

    def check(self, _deadline):
        self.checks += 1
        if self.fail_after is not None and self.checks > self.fail_after:
            raise RuntimeError('private-identity-detail')

    def close(self):
        self.closed = True


class Lease:
    def __init__(self, pair=None, context=None):
        self.context = context or DaemonContext(True, True, True)
        self.pair = pair or Pair()
        self.closed = False

    def capture_identities(self, _deadline):
        return self.pair

    def revalidate(self, _deadline):
        return not self.closed

    def close(self):
        self.closed = True


class Connection:
    def __init__(self):
        self.connected = None
        self.closed = False

    def settimeout(self, _timeout):
        pass

    def connect(self, path):
        self.connected = path

    def close(self):
        self.closed = True


class Backend:
    def __init__(self):
        self.calls = []

    def apply(self, step, plan):
        self.calls.append(('apply', step, plan, threading.get_native_id()))
        return 'applied'

    def reconcile(self, step, plan):
        self.calls.append(('reconcile', step, plan, threading.get_native_id()))
        return 'reconciled'


def build(monkeypatch, *, lease=None, identities=None):
    endpoint = DockerEndpoint('/run/docker.sock', owner_uid=0,
                              daemon_executable='/usr/bin/dockerd')
    connection = Connection()
    lease = lease or Lease(identities)
    endpoint_identity = ((1, 2, 0, 0, 0o140660),)
    monkeypatch.setattr(supervisor, '_identity', lambda _endpoint: endpoint_identity)
    monkeypatch.setattr(supervisor, '_linux_peer_uid', lambda _connection: 0)
    monkeypatch.setattr(supervisor, 'capture_daemon_context',
                        lambda current, uid, executable, deadline: lease)
    guarded = supervisor.SupervisedInstallationBackend(
        endpoint,
        Backend(),
        socket_factory=lambda *_args: connection,
    )
    return guarded, guarded.backend, connection, lease


def test_retains_one_connection_and_checks_evidence_before_and_after_each_call(monkeypatch):
    guarded, backend, connection, lease = build(monkeypatch)
    deadline = time.monotonic() + 2

    guarded.open(deadline)
    assert connection.connected == '/run/docker.sock'
    assert guarded.apply_with_deadline('step', 'plan', deadline) == 'applied'
    assert guarded.reconcile_with_deadline('step', 'plan', deadline) == 'reconciled'
    assert [call[0] for call in backend.calls] == ['apply', 'reconcile']
    assert lease.pair.checks == 5  # open, before/after apply, before/after reconcile
    assert all(call[3] == threading.get_native_id() for call in backend.calls)

    guarded.close()
    assert connection.closed and lease.closed and lease.pair.closed
    guarded.close()


@pytest.mark.parametrize('change', [
    'different_mount', 'different_network', 'different_root', 'peer_map',
    'worker_map', 'peer_reader_namespace', 'worker_reader_namespace',
    'different_user_namespace', 'missing_context',
])
def test_open_fails_closed_for_incomplete_or_different_native_context(monkeypatch, change):
    peer, worker = Snapshot(), Snapshot()
    context = DaemonContext(True, True, True)
    if change == 'different_mount':
        context = DaemonContext(False, True, True)
    elif change == 'different_network':
        context = DaemonContext(True, False, True)
    elif change == 'different_root':
        context = DaemonContext(True, True, False)
    elif change == 'peer_map':
        peer = Snapshot(uid_map=((0, 100000, 65536),))
    elif change == 'worker_map':
        worker = Snapshot(gid_map=((0, 100000, 65536),))
    elif change == 'peer_reader_namespace':
        peer = Snapshot(opener_user_namespace=(9, 9))
    elif change == 'worker_reader_namespace':
        worker = Snapshot(opener_user_namespace=(9, 9))
    elif change == 'different_user_namespace':
        worker = Snapshot(target_user_namespace=(7, 8), opener_user_namespace=(7, 8))
    pair = Pair(peer, worker)
    lease = Lease(pair, context)
    guarded, backend, connection, _lease = build(monkeypatch, lease=lease)
    if change == 'missing_context':
        monkeypatch.setattr(supervisor, 'capture_daemon_context', lambda *_args: None)

    with pytest.raises(supervisor.InstallationSupervisorError,
                       match='^supervisor_unavailable$'):
        guarded.open(time.monotonic() + 2)

    assert backend.calls == [] and connection.closed
    if change != 'missing_context':
        assert lease.closed


def test_endpoint_or_daemon_identity_change_blocks_effect_and_closes_guard(monkeypatch):
    guarded, backend, connection, lease = build(monkeypatch)
    changed = [False]
    monkeypatch.setattr(
        supervisor,
        '_identity',
        lambda _endpoint: (((9, 9) if changed[0] else (1, 2)) + (0, 0, 0o140660),),
    )
    guarded.open(time.monotonic() + 2)
    changed[0] = True

    with pytest.raises(supervisor.InstallationSupervisorError,
                       match='^supervisor_unavailable$'):
        guarded.apply_with_deadline('step', 'plan', time.monotonic() + 2)

    assert backend.calls == [] and connection.closed and lease.closed and lease.pair.closed


def test_post_effect_revalidation_failure_never_returns_success(monkeypatch):
    pair = Pair()
    pair.fail_after = 2  # open and pre-effect checks pass; post-effect fails.
    guarded, backend, connection, lease = build(monkeypatch, identities=pair)
    guarded.open(time.monotonic() + 2)

    with pytest.raises(supervisor.InstallationSupervisorError,
                       match='^supervisor_unavailable$'):
        guarded.apply_with_deadline('step', 'plan', time.monotonic() + 2)

    assert len(backend.calls) == 1 and connection.closed and lease.closed and pair.closed


@pytest.mark.parametrize('deadline', [True, None, float('nan'), float('inf'), -1, 0])
def test_bad_deadline_fails_before_socket_access(monkeypatch, deadline):
    guarded, _backend, connection, _lease = build(monkeypatch)
    with pytest.raises(supervisor.InstallationSupervisorError):
        guarded.open(deadline)
    assert connection.connected is None


def test_guard_cannot_move_to_another_native_thread(monkeypatch):
    guarded, backend, connection, lease = build(monkeypatch)
    guarded.open(time.monotonic() + 2)
    errors = []

    def call():
        try:
            guarded.apply_with_deadline('step', 'plan', time.monotonic() + 2)
        except Exception as error:
            errors.append(error)

    thread = threading.Thread(target=call)
    thread.start()
    thread.join(2)
    assert len(errors) == 1 and type(errors[0]) is supervisor.InstallationSupervisorError
    assert backend.calls == [] and connection.closed and lease.closed


def test_public_repr_and_errors_do_not_expose_policy_or_kernel_details(monkeypatch):
    guarded, _backend, _connection, lease = build(monkeypatch)
    lease.context = DaemonContext(False, True, True)
    assert '/run/docker.sock' not in repr(guarded)
    with pytest.raises(supervisor.InstallationSupervisorError) as caught:
        guarded.open(time.monotonic() + 2)
    assert caught.value.args == ('supervisor_unavailable',)


@pytest.mark.skipif(sys.platform != 'linux', reason='Linux peer-pidfd/procfs integration')
def test_actual_linux_peer_context_is_retained_on_the_effect_thread(monkeypatch):
    from concurrent.futures import ThreadPoolExecutor
    from larenor_server.plugins import daemon_context

    left, right = socket.socketpair()
    try:
        try:
            raw = left.getsockopt(socket.SOL_SOCKET, getattr(socket, 'SO_PEERPIDFD', 77), 4)
            os.close(struct.unpack('i', raw)[0])
        except OSError:
            pytest.skip('kernel does not expose socket-bound peer pidfds')

        executable = os.readlink('/proc/self/exe')
        endpoint = DockerEndpoint('/run/docker.sock', owner_uid=os.getuid(),
                                  daemon_executable=executable)
        identity = ((1, 2, os.getuid(), os.getgid(), 0o140660),)
        monkeypatch.setattr(supervisor, '_identity', lambda _endpoint: identity)
        # The existing daemon-context tests cover the root-owned path walk.
        # This integration isolates the real pidfd/proc/ns and thread lifetime.
        monkeypatch.setattr(daemon_context, '_trusted_executable',
                            lambda path, deadline: os.stat(path))
        guarded = supervisor.SupervisedInstallationBackend(
            endpoint,
            Backend(),
            socket_factory=lambda *_args: left,
        )

        def execute():
            owner = threading.get_native_id()
            guarded.open(time.monotonic() + 2)
            assert guarded.apply_with_deadline('step', 'plan', time.monotonic() + 2) == 'applied'
            guarded.close()
            return owner

        with ThreadPoolExecutor(max_workers=1) as executor:
            owner = executor.submit(execute).result(timeout=5)
        assert guarded.backend.calls[0][3] == owner
    finally:
        left.close()
        right.close()
