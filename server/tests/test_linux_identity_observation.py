"""Kernel identity facts: synthetic proc fixtures are separate from Linux proof."""

import os
import threading
import time

import pytest

from test_daemon_context import process_stat


def implementation():
    from larenor_server.plugins import linux_identity_observation
    return linux_identity_observation


@pytest.fixture
def synthetic(tmp_path, monkeypatch):
    module = implementation()
    proc = tmp_path / 'proc'
    target_pid = 9001
    namespace = tmp_path / 'user-ns'
    namespace.touch()
    target = proc / str(target_pid)
    opener = proc / str(os.getpid()) / 'task' / str(threading.get_native_id())
    for path, pid in ((target, target_pid), (opener, threading.get_native_id())):
        (path / 'ns').mkdir(parents=True)
        (path / 'stat').write_text(process_stat(pid))
        (path / 'status').write_text('Name:\tprivate\nUid:\t1000\t1000\t1000\t1000\nGid:\t2000\t2000\t2000\t2000\n')
        (path / 'uid_map').write_bytes(b'         0          0 4294967295\n')
        (path / 'gid_map').write_bytes(b'         0          0 4294967295\n')
        (path / 'ns/user').symlink_to(namespace)
    monkeypatch.setattr(module, '_PROC_ROOT', proc)
    monkeypatch.setattr(module.sys, 'platform', 'linux')
    fd = os.open(target, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        yield dict(module=module, proc=proc, target=target, opener=opener, namespace=namespace,
                   fd=fd, pid=target_pid)
    finally:
        os.close(fd)


@pytest.mark.parametrize('raw,expected', [
    (b'0 0 4294967295\n', [(0, 0, 4294967295)]),
    (b'0 100000 65536\n', [(0, 100000, 65536)]),
    (b'1000 3000 1\n0 2000 1\n', [(1000, 3000, 1), (0, 2000, 1)]),
])
def test_mapping_parser_records_extents_without_claiming_host_mapping(raw, expected):
    module = implementation()
    values = module.parse_id_map(raw)
    assert [(item.inside_first, item.outside_first, item.length) for item in values] == expected


def test_capture_reads_uid_gid_maps_and_holds_both_namespace_identities(synthetic):
    module = synthetic['module']
    with module.capture_process_identity(synthetic['fd'], pid=synthetic['pid'], deadline=time.monotonic() + 2) as held:
        snapshot = held.snapshot
        assert snapshot.uids == (1000,) * 4 and snapshot.gids == (2000,) * 4
        assert snapshot.target_user_namespace == snapshot.opener_user_namespace
        assert snapshot.uid_map == snapshot.gid_map == module.parse_id_map(b'0 0 4294967295\n')
        assert held.check(time.monotonic() + 2) is None
        assert '1000' not in repr(snapshot) and str(synthetic['target']) not in repr(held)
    os.fstat(synthetic['fd'])  # The borrowed input remains caller-owned.


def test_gid_only_change_invalidates_held_observation(synthetic):
    module = synthetic['module']
    with module.capture_process_identity(synthetic['fd'], pid=synthetic['pid'], deadline=time.monotonic() + 2) as held:
        (synthetic['target'] / 'status').write_text('Uid: 1000 1000 1000 1000\nGid: 2000 2001 2000 2000\n')
        with pytest.raises(module.IdentityObservationError, match='^identity_observation_unavailable$'):
            held.check(time.monotonic() + 2)


def test_changed_reader_namespace_invalidates_map_interpretation(synthetic, tmp_path):
    module = synthetic['module']
    with module.capture_process_identity(synthetic['fd'], pid=synthetic['pid'], deadline=time.monotonic() + 2) as held:
        other = tmp_path / 'other-userns'
        other.touch()
        link = synthetic['opener'] / 'ns/user'
        link.unlink()
        link.symlink_to(other)
        with pytest.raises(module.IdentityObservationError, match='^identity_observation_unavailable$'):
            held.check(time.monotonic() + 2)


def test_closed_observation_cannot_be_reused(synthetic):
    module = synthetic['module']
    held = module.capture_process_identity(synthetic['fd'], pid=synthetic['pid'], deadline=time.monotonic() + 2)
    held.close()
    held.close()
    with pytest.raises(module.IdentityObservationError, match='^identity_observation_unavailable$'):
        held.check(time.monotonic() + 2)


def track_descriptors(module, monkeypatch):
    descriptors = []
    opened, duplicated = module.os.open, module.os.dup
    def open_fd(*args, **kwargs):
        fd = opened(*args, **kwargs)
        descriptors.append(fd)
        return fd
    def dup_fd(*args, **kwargs):
        fd = duplicated(*args, **kwargs)
        descriptors.append(fd)
        return fd
    monkeypatch.setattr(module.os, 'open', open_fd)
    monkeypatch.setattr(module.os, 'dup', dup_fd)
    return descriptors


def assert_closed(descriptors):
    assert descriptors
    for fd in set(descriptors):
        with pytest.raises(OSError):
            os.fstat(fd)


def test_interruption_after_first_capture_closes_owned_descriptors(synthetic, monkeypatch):
    module = synthetic['module']
    descriptors = track_descriptors(module, monkeypatch)
    original = module._take
    calls = 0
    def interrupted(*args):
        nonlocal calls
        calls += 1
        if calls == 2:
            raise KeyboardInterrupt()
        return original(*args)
    monkeypatch.setattr(module, '_take', interrupted)
    with pytest.raises(KeyboardInterrupt):
        module.capture_process_identity(synthetic['fd'], pid=synthetic['pid'], deadline=time.monotonic() + 2)
    assert_closed(descriptors)


def test_replaced_reader_proc_path_during_check_cannot_leave_a_stale_namespace_claim(synthetic, monkeypatch):
    module = synthetic['module']
    with module.capture_process_identity(synthetic['fd'], pid=synthetic['pid'], deadline=time.monotonic() + 2) as held:
        original = module._read
        def replaced(proc, name, deadline, event):
            value = original(proc, name, deadline, event)
            if name == 'gid_map':
                synthetic['opener'].rename(synthetic['opener'].with_name('old-thread'))
                synthetic['opener'].mkdir()
            return value
        monkeypatch.setattr(module, '_read', replaced)
        with pytest.raises(module.IdentityObservationError, match='^identity_observation_unavailable$'):
            held.check(time.monotonic() + 2)
