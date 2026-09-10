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
        self.startup = object()

    def capture_identities(self, _deadline):
        return self.pair

    def revalidate(self, _deadline):
        return not self.closed

    def matches_connection(self, connection, expected_uid, _deadline):
        return (not self.closed and getattr(connection, 'peer_pid', 1) == 1
                and expected_uid == 0)

    def capture_startup(self, _deadline):
        return self.startup

    def close(self):
        self.closed = True


class Connection:
    def __init__(self):
        self.connected = None
        self.closed = False
        self.peer_pid = 1

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

    def bootstrap(self, job, plan, private, *, deadline, gate):
        self.calls.append(('bootstrap', job, plan, private, threading.get_native_id()))
        assert time.monotonic() < deadline and gate() is True and gate() is True
        return 'bootstrapped'

    def configure_qbittorrent(self, job, stack, credential, *, api_key, salt,
                              cancelled, deadline, gate):
        self.calls.append((
            'configure_qbittorrent', job, stack, credential, api_key, salt,
            cancelled, threading.get_native_id(),
        ))
        assert time.monotonic() < deadline and gate() is True and gate() is True
        return 'configured'

    def configure_arr(self, job, stack, service_id, *, api_key, cancelled,
                      deadline, gate):
        self.calls.append((
            'configure_arr', job, stack, service_id, api_key, cancelled,
            threading.get_native_id(),
        ))
        assert time.monotonic() < deadline and gate() is True and gate() is True
        return 'arr-configured'

    def install_configured_arr(self, job, stack, service_id, *, api_key,
                               cancelled, deadline, gate):
        self.calls.append((
            'install_configured_arr', job, stack, service_id, api_key,
            cancelled, threading.get_native_id(),
        ))
        assert time.monotonic() < deadline and gate() is True and gate() is True
        return 'arr-installed'

    def install_configured_qbittorrent(
            self, job, stack, credential, *, api_key, salt, cancelled,
            deadline, gate):
        self.calls.append((
            'install_configured_qbittorrent', job, stack, credential, api_key,
            salt, cancelled, threading.get_native_id()))
        assert time.monotonic() < deadline and gate() is True and gate() is True
        return 'installed'


class Security:
    def __init__(self):
        self.checks = 0
        self.closed = False
        self.fail = False

    def check(self, _deadline):
        self.checks += 1
        if self.fail:
            raise RuntimeError('private-security-change')

    def close(self):
        self.closed = True


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
    security = Security()
    guarded = supervisor.SupervisedInstallationBackend(
        endpoint,
        Backend(),
        platform='linux/amd64',
        socket_factory=lambda *_args: connection,
        security_attestor=lambda current, startup, peer, worker, **kwargs: security,
    )
    lease.security = security
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
    assert connection.closed and lease.closed and lease.pair.closed and lease.security.closed
    guarded.close()


def test_bootstrap_gates_share_retained_daemon_evidence_and_native_thread(monkeypatch):
    guarded, backend, connection, lease = build(monkeypatch)
    deadline = time.monotonic() + 2
    guarded.open(deadline)

    assert guarded.bootstrap_with_deadline(
        'job', 'plan', 'private', deadline) == 'bootstrapped'
    assert backend.calls[0][:4] == ('bootstrap', 'job', 'plan', 'private')
    assert backend.calls[0][4] == threading.get_native_id()
    assert lease.pair.checks == 5  # open, before, two inner gates, after

    guarded.close()
    assert connection.closed and lease.closed


def test_qbittorrent_config_gates_share_retained_daemon_and_native_thread(monkeypatch):
    guarded, backend, connection, lease = build(monkeypatch)
    deadline = time.monotonic() + 2
    cancelled = threading.Event()
    guarded.open(deadline)

    assert guarded.configure_qbittorrent_with_deadline(
        'a' * 32, 'stack', 'credential', api_key='api-key', salt=b'x' * 16,
        cancelled=cancelled, deadline=deadline,
    ) == 'configured'
    assert backend.calls[0][0:7] == (
        'configure_qbittorrent', 'a' * 32, 'stack', 'credential', 'api-key', b'x' * 16,
        cancelled,
    )
    assert backend.calls[0][7] == threading.get_native_id()
    assert lease.pair.checks == 5

    guarded.close()
    assert connection.closed and lease.closed


def test_qbittorrent_ordered_install_shares_retained_daemon_and_native_thread(
        monkeypatch):
    guarded, backend, connection, lease = build(monkeypatch)
    deadline = time.monotonic() + 2
    cancelled = threading.Event()
    guarded.open(deadline)

    assert guarded.install_configured_qbittorrent_with_deadline(
        'a' * 32, 'stack', 'credential', api_key='api-key', salt=b'x' * 16,
        cancelled=cancelled, deadline=deadline) == 'installed'
    assert backend.calls[0][0:7] == (
        'install_configured_qbittorrent', 'a' * 32, 'stack', 'credential',
        'api-key', b'x' * 16, cancelled)
    assert backend.calls[0][7] == threading.get_native_id()
    assert lease.pair.checks == 5

    guarded.close()
    assert connection.closed and lease.closed


def test_arr_config_gates_share_retained_daemon_and_native_thread(monkeypatch):
    guarded, backend, connection, lease = build(monkeypatch)
    deadline = time.monotonic() + 2
    cancelled = threading.Event()
    guarded.open(deadline)

    assert guarded.configure_arr_with_deadline(
        'a' * 32, 'stack', 'sonarr', api_key='api-key',
        cancelled=cancelled, deadline=deadline,
    ) == 'arr-configured'
    assert backend.calls[0][0:6] == (
        'configure_arr', 'a' * 32, 'stack', 'sonarr', 'api-key', cancelled,
    )
    assert backend.calls[0][6] == threading.get_native_id()
    assert lease.pair.checks == 5

    guarded.close()
    assert connection.closed and lease.closed


def test_arr_ordered_install_shares_retained_daemon_and_native_thread(monkeypatch):
    guarded, backend, connection, lease = build(monkeypatch)
    deadline = time.monotonic() + 2
    cancelled = threading.Event()
    guarded.open(deadline)

    assert guarded.install_configured_arr_with_deadline(
        'a' * 32, 'stack', 'radarr', api_key='api-key',
        cancelled=cancelled, deadline=deadline,
    ) == 'arr-installed'
    assert backend.calls[0][0:6] == (
        'install_configured_arr', 'a' * 32, 'stack', 'radarr', 'api-key',
        cancelled,
    )
    assert backend.calls[0][6] == threading.get_native_id()
    assert lease.pair.checks == 5

    guarded.close()
    assert connection.closed and lease.closed


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


def test_daemon_security_change_blocks_effect_and_closes_all_evidence(monkeypatch):
    guarded, backend, connection, lease = build(monkeypatch)
    guarded.open(time.monotonic() + 2)
    lease.security.fail = True
    with pytest.raises(supervisor.InstallationSupervisorError,
                       match='^supervisor_unavailable$'):
        guarded.apply_with_deadline('step', 'plan', time.monotonic() + 2)
    assert backend.calls == []
    assert connection.closed and lease.closed and lease.pair.closed and lease.security.closed


def test_every_backend_engine_connection_must_match_the_retained_peer(monkeypatch):
    guarded, backend, _connection, _lease = build(monkeypatch)
    engine_connection = Connection()

    def apply(step, plan):
        guarded._peer_verifier(engine_connection)
        return Backend.apply(backend, step, plan)

    backend.apply = apply
    guarded.open(time.monotonic() + 2)
    assert guarded.apply_with_deadline('step', 'plan', time.monotonic() + 2) == 'applied'

    engine_connection.peer_pid = 2
    with pytest.raises(supervisor.InstallationSupervisorError,
                       match='^supervisor_unavailable$'):
        guarded.apply_with_deadline('step', 'plan', time.monotonic() + 2)
    assert len(backend.calls) == 1


def test_peer_verifier_is_inactive_outside_one_supervised_backend_call(monkeypatch):
    guarded, _backend, _connection, _lease = build(monkeypatch)
    guarded.open(time.monotonic() + 2)
    with pytest.raises(supervisor.InstallationSupervisorError):
        guarded._peer_verifier(Connection())


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
    operation_left, operation_right = socket.socketpair()
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
        monkeypatch.setattr(daemon_context._ContextLease, 'capture_startup',
                            lambda self, deadline: object())
        class PreconnectedSocket:
            """Expose real socket credentials while modelling a completed connect."""

            def __init__(self, value):
                self.value = value

            def settimeout(self, timeout):
                self.value.settimeout(timeout)

            def connect(self, path):
                assert path == '/run/docker.sock'

            def getsockopt(self, *args):
                return self.value.getsockopt(*args)

            def close(self):
                self.value.close()

        guarded = supervisor.SupervisedInstallationBackend(
            endpoint,
            Backend(),
            platform='linux/amd64',
            socket_factory=lambda *_args: PreconnectedSocket(left),
            security_attestor=lambda *_args, **_kwargs: Security(),
        )

        def apply(step, plan):
            assert guarded._peer_verifier(operation_left) == os.getuid()
            return Backend.apply(guarded.backend, step, plan)

        guarded.backend.apply = apply

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
        operation_left.close()
        operation_right.close()
