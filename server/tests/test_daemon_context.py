"""Kernel-bound peer identity, with synthetic proc trees and no Docker calls."""

from dataclasses import FrozenInstanceError
from concurrent.futures import ThreadPoolExecutor
import errno
import os
from itertools import cycle
from pathlib import Path
import socket
import struct
import sys
import time
import threading
from types import SimpleNamespace

import pytest

from larenor_server.plugins import daemon_context as module


def process_stat(pid, start=123):
    return f'{pid} (misleading ) dockerd) S ' + '0 ' * 18 + f'{start} 0\n'


@pytest.fixture
def proc_tree(tmp_path, monkeypatch):
    proc = tmp_path / 'proc'
    proc.mkdir()
    executable = tmp_path / 'operator-engine'
    executable.write_bytes(b'synthetic executable')
    executable.chmod(0o755)
    root = tmp_path / 'root'
    root.mkdir()
    mnt = tmp_path / 'mount-namespace'
    net = tmp_path / 'network-namespace'
    mnt.touch()
    net.touch()
    leader, worker, peer = os.getpid(), os.getpid() + 20000, os.getpid() + 10000
    worker_path = proc / str(leader) / 'task' / str(worker)
    for path, pid in ((proc / str(leader), leader), (worker_path, worker), (proc / str(peer), peer)):
        path.mkdir(parents=True)
        (path / 'ns').mkdir()
        (path / 'stat').write_text(process_stat(pid))
        (path / 'status').write_text(f'Name:\tdockerd\nUid:\t{os.getuid()}\t{os.getuid()}\t{os.getuid()}\t{os.getuid()}\n')
        (path / 'exe').symlink_to(executable)
        (path / 'root').symlink_to(root, target_is_directory=True)
        (path / 'ns/mnt').symlink_to(mnt)
        (path / 'ns/net').symlink_to(net)
    read_fd, write_fd = os.pipe()
    received = []
    class Connection:
        def getsockopt(self, level, option, length):
            if option == getattr(socket, 'SO_PEERCRED', 17):
                return struct.pack('3i', peer, os.getuid(), os.getgid())
            assert option == getattr(socket, 'SO_PEERPIDFD', 77)
            duplicate = os.dup(read_fd)
            received.append(duplicate)
            return struct.pack('i', duplicate)
    monkeypatch.setattr(module.sys, 'platform', 'linux')
    monkeypatch.setattr(threading, 'get_native_id', lambda: worker)
    monkeypatch.setattr(module, '_PROC_ROOT', proc)
    # Only the fixture's executable trust anchor is synthetic; proc operations,
    # inode comparisons, bounded reads, pidfd polling and FD cleanup are real.
    monkeypatch.setattr(module, '_trusted_executable', lambda path, deadline: os.stat(path))
    monkeypatch.setattr(module, '_mount_id', lambda fd, deadline: 41, raising=False)
    state = dict(proc=proc, worker=worker, peer=peer, executable=executable,
                 worker_path=worker_path, peer_path=proc / str(peer), leader_path=proc / str(leader),
                 root=root, mnt=mnt, net=net, connection=Connection(), fds=received,
                 read_fd=read_fd, write_fd=write_fd)
    yield state
    os.close(read_fd)
    os.close(write_fd)
    for fd in received:
        with pytest.raises(OSError):
            os.fstat(fd)


def capture(tree):
    return module.capture_daemon_context(tree['connection'], os.getuid(), str(tree['executable']),
                                         time.monotonic() + 2)


def replace_link(path, target):
    path.unlink()
    path.symlink_to(target)


def test_stable_peer_uses_exact_policy_inode_and_returns_only_three_booleans(proc_tree):
    lease = capture(proc_tree)
    assert lease is not None
    try:
        assert lease.context == module.DaemonContext(True, True, True)
        assert lease.revalidate(time.monotonic() + 2) is True
        assert str(proc_tree['peer']) not in repr(lease)
        assert str(proc_tree['executable']) not in repr(lease.context)
        with pytest.raises(FrozenInstanceError):
            lease.context.same_process_root = False
    finally:
        lease.close()
        lease.close()


@pytest.mark.parametrize('field,attribute', [('ns/mnt', 'same_mount_namespace'),
                                         ('ns/net', 'same_network_namespace'),
                                         ('root', 'same_process_root')])
def test_stable_different_context_is_a_false_fact_not_unknown(proc_tree, tmp_path, field, attribute):
    other = tmp_path / 'different'
    other.mkdir() if field == 'root' else other.touch()
    replace_link(proc_tree['proc'] / str(proc_tree['peer']) / field, other)
    lease = capture(proc_tree)
    assert lease is not None
    try:
        assert getattr(lease.context, attribute) is False
        assert lease.revalidate(time.monotonic() + 2)
    finally:
        lease.close()


@pytest.mark.parametrize('field', ['ns/mnt', 'ns/net', 'root', 'exe', 'stat', 'status'])
@pytest.mark.parametrize('actor', ['peer', 'worker'])
def test_changed_identity_during_observation_is_unknown(proc_tree, tmp_path, field, actor):
    lease = capture(proc_tree)
    assert lease is not None
    try:
        pid = proc_tree[actor]
        path = proc_tree[f'{actor}_path'] / field
        if field == 'stat':
            path.write_text(process_stat(pid, start=999))
        elif field == 'status':
            path.write_text('Uid:\t999\t999\t999\t999\n')
        else:
            other = tmp_path / 'replacement'
            other.mkdir() if field == 'root' else other.touch()
            replace_link(path, other)
        assert lease.revalidate(time.monotonic() + 2) is False
    finally:
        lease.close()


@pytest.mark.parametrize('field', ['ns/mnt', 'ns/net', 'root', 'exe', 'stat', 'status'])
def test_inaccessible_proc_field_is_unknown_and_closes_every_fd(proc_tree, field):
    (proc_tree['proc'] / str(proc_tree['peer']) / field).unlink()
    assert capture(proc_tree) is None


def test_comm_or_executable_basename_cannot_prove_direct_daemon(proc_tree, tmp_path):
    other = tmp_path / 'proxy' / 'operator-engine'
    other.parent.mkdir()
    other.write_bytes(b'proxy named like engine')
    other.chmod(0o755)
    replace_link(proc_tree['proc'] / str(proc_tree['peer']) / 'exe', other)
    assert capture(proc_tree) is None


def test_same_socket_dead_original_pidfd_rejects_reused_numeric_pid(proc_tree):
    os.write(proc_tree['write_fd'], b'exited')
    assert capture(proc_tree) is None


def test_same_inode_under_distinct_bind_mount_roots_is_not_same_process_root(proc_tree, monkeypatch):
    mount_ids = cycle([41, 42])
    monkeypatch.setattr(module, '_mount_id', lambda fd, deadline: next(mount_ids))
    lease = capture(proc_tree)
    assert lease is not None
    try:
        assert lease.context.same_mount_namespace is True
        assert lease.context.same_process_root is False
        assert lease.revalidate(time.monotonic() + 2)
    finally:
        lease.close()


@pytest.mark.parametrize('actor,expected', [('leader', True), ('worker', False)])
def test_worker_context_belongs_to_the_callback_thread_not_process_leader(proc_tree, tmp_path, actor, expected):
    other = tmp_path / 'isolated-thread-network'
    other.touch()
    replace_link(proc_tree[f'{actor}_path'] / 'ns/net', other)
    lease = capture(proc_tree)
    assert lease is not None
    try:
        assert lease.context.same_network_namespace is expected
        assert lease.revalidate(time.monotonic() + 2)
    finally:
        lease.close()


def test_original_process_exit_after_capture_invalidates_context(proc_tree):
    lease = capture(proc_tree)
    assert lease is not None
    try:
        os.write(proc_tree['write_fd'], b'exited')
        assert lease.revalidate(time.monotonic() + 2) is False
    finally:
        lease.close()


def test_missing_kernel_peer_pidfd_support_never_uses_pidfd_open(proc_tree, monkeypatch):
    def old_kernel(*args):
        raise OSError('SO_PEERPIDFD unavailable')
    monkeypatch.setattr(proc_tree['connection'], 'getsockopt', old_kernel)
    monkeypatch.setattr(os, 'pidfd_open', lambda *args: pytest.fail('numeric PID is not socket-bound'), raising=False)
    assert capture(proc_tree) is None


@pytest.mark.parametrize('field,contents', [('stat', 'bad'), ('stat', 'x' * 65537),
                                          ('status', 'Uid: 0 0 0\n'),
                                          ('status', 'Uid: 0 0 0 0\nUid: 0 0 0 0\n'),
                                          ('status', 'x' * 65537)])
def test_malformed_or_unbounded_proc_data_fails_closed(proc_tree, field, contents):
    (proc_tree['proc'] / str(proc_tree['peer']) / field).write_text(contents)
    assert capture(proc_tree) is None


def test_deadline_and_non_linux_context_are_unknown(proc_tree, monkeypatch):
    assert module.capture_daemon_context(proc_tree['connection'], os.getuid(),
                                         str(proc_tree['executable']), time.monotonic() - 1) is None
    monkeypatch.setattr(module.sys, 'platform', 'darwin')
    assert capture(proc_tree) is None


def test_operator_executable_trust_rejects_unprivileged_or_writable_anchor(tmp_path):
    path = tmp_path / 'engine'
    path.write_bytes(b'not a privileged executable')
    path.chmod(0o777)
    with pytest.raises((OSError, ValueError)):
        module._trusted_executable(str(path), time.monotonic() + 2)


@pytest.mark.parametrize('changed_index,uid,mode', [
    (None, 0, 0o100755), (0, 17, 0o40755), (1, 0, 0o40777),
    (2, 0, 0o40775), (3, 17, 0o100755), (3, 0, 0o100775),
    (3, 0, 0o100644), (3, 0, 0o120755),
])
def test_explicit_executable_anchor_checks_each_opened_parent_and_binary(monkeypatch, changed_index, uid, mode):
    infos = [SimpleNamespace(st_uid=0, st_mode=0o40755) for _ in range(3)]
    infos.append(SimpleNamespace(st_uid=0, st_mode=0o100755))
    if changed_index is not None:
        infos[changed_index] = SimpleNamespace(st_uid=uid, st_mode=mode)
    opened, closed = [], []
    def open_path(path, flags, **kwargs):
        index = len(opened)
        assert path == ['/', 'usr', 'bin', 'engine'][index]
        if index:
            assert flags & os.O_NOFOLLOW and kwargs['dir_fd'] == index - 1
        opened.append(index)
        return index
    monkeypatch.setattr(module.os, 'open', open_path)
    monkeypatch.setattr(module.os, 'fstat', lambda fd: infos[fd])
    monkeypatch.setattr(module.os, 'close', closed.append)
    if changed_index is None:
        assert module._trusted_executable('/usr/bin/engine', time.monotonic() + 2) is infos[3]
    else:
        with pytest.raises(ValueError, match='^context_unavailable$'):
            module._trusted_executable('/usr/bin/engine', time.monotonic() + 2)
    assert sorted(closed) == opened


@pytest.mark.parametrize('corrupt', [False, True])
def test_all_proc_and_snapshot_descriptors_are_released(proc_tree, monkeypatch, corrupt):
    if corrupt:
        (proc_tree['worker_path'] / 'status').write_text('invalid')
    actual_open, actual_close = os.open, os.close
    outstanding = set()
    def tracked_open(*args, **kwargs):
        fd = actual_open(*args, **kwargs)
        outstanding.add(fd)
        return fd
    def tracked_close(fd):
        outstanding.discard(fd)
        return actual_close(fd)
    with monkeypatch.context() as scope:
        scope.setattr(module.os, 'open', tracked_open)
        scope.setattr(module.os, 'close', tracked_close)
        lease = capture(proc_tree)
        if corrupt:
            assert lease is None
        else:
            assert lease is not None
            lease.revalidate(time.monotonic() + 2)
            lease.close()
        assert outstanding == set()


@pytest.mark.parametrize('credentials', [(0, 0, 0), (-2, 0, 0), (14, -1, 0), (14, 0, -1), b'short'])
def test_invalid_kernel_credentials_never_inspect_numeric_process_paths(proc_tree, monkeypatch, credentials):
    monkeypatch.setattr(proc_tree['connection'], 'getsockopt',
                        lambda *args: credentials if type(credentials) is bytes else struct.pack('3i', *credentials))
    monkeypatch.setattr(module, '_trusted_executable', lambda *args: pytest.fail('peer not authenticated'))
    assert capture(proc_tree) is None


def test_revalidation_access_failure_and_closed_lease_are_unknown(proc_tree):
    lease = capture(proc_tree)
    assert lease is not None
    (proc_tree['proc'] / str(proc_tree['peer']) / 'ns/mnt').unlink()
    assert lease.revalidate(time.monotonic() + 2) is False
    lease.close()
    assert lease.revalidate(time.monotonic() + 2) is False


@pytest.mark.parametrize('contents,expected', [('pos: 0\nmnt_id:\t41\nflags: 0\n', 41),
                                              ('mnt_id: 0\n', None), ('mnt_id: -1\n', None),
                                              ('mnt_id: 1\nmnt_id: 2\n', None),
                                              ('mnt_id: secret\n', None), ('missing\n', None)])
def test_held_root_mount_id_is_bounded_and_unambiguous(tmp_path, monkeypatch, contents, expected):
    directory = tmp_path / str(os.getpid()) / 'task' / str(threading.get_native_id()) / 'fdinfo'
    directory.mkdir(parents=True)
    (directory / '19').write_text(contents)
    monkeypatch.setattr(module, '_PROC_ROOT', tmp_path)
    if expected is None:
        with pytest.raises(ValueError, match='^context_unavailable$'):
            module._mount_id(19, time.monotonic() + 2)
    else:
        assert module._mount_id(19, time.monotonic() + 2) == expected


@pytest.mark.skipif(sys.platform != 'linux', reason='Linux peer-pidfd/procfs integration')
def test_actual_linux_socket_peer_context_without_a_docker_service(monkeypatch):
    # The operator selects this test's running executable explicitly. A socket
    # pair supplies real SO_PEERCRED/SO_PEERPIDFD, without an Engine or listener.
    executable = os.readlink('/proc/self/exe')
    monkeypatch.setattr(module, '_trusted_executable', lambda path, deadline: os.stat(path))
    left, right = socket.socketpair()
    try:
        try:
            raw = left.getsockopt(socket.SOL_SOCKET, getattr(socket, 'SO_PEERPIDFD', 77), 4)
            os.close(struct.unpack('i', raw)[0])
        except OSError as error:
            version = tuple(int(part) for part in os.uname().release.split('-')[0].split('.')[:2])
            unsupported_old_kernel = (version < (6, 8) and error.errno in (errno.ENOPROTOOPT, errno.EOPNOTSUPP))
            assert unsupported_old_kernel or error.errno in (errno.EACCES, errno.EPERM)
            assert module.capture_daemon_context(left, os.getuid(), executable, time.monotonic() + 2) is None
            return
        def in_worker_thread():
            assert threading.get_native_id() != os.getpid()
            lease = module.capture_daemon_context(left, os.getuid(), executable, time.monotonic() + 2)
            assert lease is not None
            try:
                assert lease.context == module.DaemonContext(True, True, True)
                assert lease.revalidate(time.monotonic() + 2)
            finally:
                lease.close()
        with ThreadPoolExecutor(max_workers=1) as executor:
            executor.submit(in_worker_thread).result(timeout=3)
    finally:
        left.close()
        right.close()


def _identity_tree(proc_tree, monkeypatch):
    from larenor_server.plugins import linux_identity_observation
    for name in ('peer_path', 'worker_path', 'leader_path'):
        path = proc_tree[name]
        with (path / 'status').open('a') as file:
            file.write(f'Gid:\t{os.getgid()}\t{os.getgid()}\t{os.getgid()}\t{os.getgid()}\n')
        (path / 'uid_map').write_text('0 0 4294967295\n')
        (path / 'gid_map').write_text('0 0 4294967295\n')
        (path / 'ns/user').symlink_to(proc_tree['mnt'])
    monkeypatch.setattr(linux_identity_observation, '_PROC_ROOT', proc_tree['proc'])
    return linux_identity_observation


def test_optional_identity_capture_binds_held_peer_and_worker_without_changing_public_context(proc_tree, monkeypatch):
    identity = _identity_tree(proc_tree, monkeypatch)
    lease = capture(proc_tree)
    assert lease is not None
    try:
        with lease.capture_identities(time.monotonic() + 2) as pair:
            assert pair.peer.pid == proc_tree['peer'] and pair.worker.pid == proc_tree['worker']
            assert pair.peer.uids == (os.getuid(),) * 4 and pair.peer.gids == (os.getgid(),) * 4
            assert pair.peer.uid_map == identity.parse_id_map(b'0 0 4294967295\n')
            assert pair.check(time.monotonic() + 2) is None
            assert lease.context == module.DaemonContext(True, True, True)
            assert str(proc_tree['peer']) not in repr(pair)
    finally:
        lease.close()


def test_optional_identity_failure_leaves_old_readonly_context_contract_unchanged(proc_tree, monkeypatch):
    identity = _identity_tree(proc_tree, monkeypatch)
    lease = capture(proc_tree)
    assert lease is not None
    try:
        with lease.capture_identities(time.monotonic() + 2) as pair:
            path = proc_tree['peer_path'] / 'gid_map'
            path.write_text('0 100000 65536\n')
            with pytest.raises(identity.IdentityObservationError, match='^identity_observation_unavailable$'):
                pair.check(time.monotonic() + 2)
            assert lease.revalidate(time.monotonic() + 2)
    finally:
        lease.close()
