"""Kernel-bound peer identity, with synthetic proc trees and no Docker calls."""

from dataclasses import FrozenInstanceError
import os
from pathlib import Path
import socket
import struct
import sys
import time

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
    worker, peer = os.getpid(), os.getpid() + 10000
    for pid in (worker, peer):
        path = proc / str(pid)
        path.mkdir()
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
    monkeypatch.setattr(module, '_PROC_ROOT', proc)
    # Only the fixture's executable trust anchor is synthetic; proc operations,
    # inode comparisons, bounded reads, pidfd polling and FD cleanup are real.
    monkeypatch.setattr(module, '_trusted_executable', lambda path, deadline: os.stat(path))
    state = dict(proc=proc, worker=worker, peer=peer, executable=executable,
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
        path = proc_tree['proc'] / str(pid) / field
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
        except OSError:
            assert module.capture_daemon_context(left, os.getuid(), executable, time.monotonic() + 2) is None
            return
        lease = module.capture_daemon_context(left, os.getuid(), executable, time.monotonic() + 2)
        assert lease is not None
        try:
            assert lease.context == module.DaemonContext(True, True, True)
            assert lease.revalidate(time.monotonic() + 2)
        finally:
            lease.close()
    finally:
        left.close()
        right.close()
