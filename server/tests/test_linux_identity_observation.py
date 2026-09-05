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


@pytest.mark.parametrize('raw', [
    None, '', bytearray(b'0 0 1\n'), b'', b'0 0 1', b'\n', b'0 0 1\n\n',
    b'0 0 1\r\n', b'0 0 1\x00\n', b'0 0 1 2\n', b'0 0\n', b'-1 0 1\n',
    b'0 -1 1\n', b'0 0 -1\n', b'+1 0 1\n', b'01 0 1\n', b'0 01 1\n',
    b'0 0 01\n', b'0 0 0\n', b'4294967295 0 1\n', b'0 4294967295 1\n',
    b'0 0 4294967296\n', b'4294967294 0 2\n', b'0 4294967294 2\n',
    b'0 0 10\n9 100 1\n', b'0 0 10\n100 9 1\n', b'0 0 1\n0 0 1\n',
    b' ' * 16384 + b'0 0 1\n', b'0 0 1\n' * 341,
])
def test_invalid_maps_fail_with_static_errors(raw):
    module = implementation()
    with pytest.raises(module.IdentityObservationError, match='^identity_observation_unavailable$'):
        module.parse_id_map(raw)


def test_maximum_map_row_count_and_last_mappable_id_are_accepted():
    module = implementation()
    rows = b''.join(f'{i} {i + 1000} 1\n'.encode() for i in range(340))
    assert len(module.parse_id_map(rows)) == 340
    assert module.parse_id_map(b'4294967294 4294967294 1\n')[0].length == 1
    assert module.parse_id_map(b'\t0\t 100000 65536 \t\n')[0].outside_first == 100000


@pytest.mark.parametrize('name,contents', [
    ('status', b'Uid: 1 1 1 1\n'), ('status', b'Gid: 1 1 1 1\n'),
    ('status', b'Uid: 1 1 1 1\nUid: 1 1 1 1\nGid: 2 2 2 2\n'),
    ('status', b'Uid: 1 1 1 1\nGid: 2 2 2 2\nGid: 2 2 2 2\n'),
    ('status', b'Uid: 1 1 1\nGid: 2 2 2 2\n'),
    ('status', b'Uid: 1 1 1 1\nGid: 2 2 2 -2\n'),
    ('status', b'Uid: 1 1 1 1\nGid: 2 2 2 4294967295\n'),
    ('status', b'Uid: 01 1 1 1\nGid: 2 2 2 2\n'),
    ('status', b'Uid: 1 1 1 1\nGid: 2 2 2 2'),
    ('stat', process_stat(9002).encode()), ('stat', b'9001 (bad) S 0\n'),
    ('stat', process_stat(9001, start=-1).encode()),
    ('stat', process_stat(9001, start=2**64).encode()),
    ('stat', process_stat(9001).replace(' S ', ' Z ').encode()),
    ('stat', process_stat(9001).replace(' S ', ' X ').encode()),
    ('stat', process_stat(9001).replace(' S ', ' x ').encode()),
    ('uid_map', b''), ('gid_map', b'0 0 1'),
])
def test_malformed_target_records_are_unavailable_and_all_handles_close(synthetic, monkeypatch, name, contents):
    module = synthetic['module']
    (synthetic['target'] / name).write_bytes(contents)
    descriptors = track_descriptors(module, monkeypatch)
    with pytest.raises(module.IdentityObservationError, match='^identity_observation_unavailable$'):
        module.capture_process_identity(synthetic['fd'], pid=synthetic['pid'], deadline=time.monotonic() + 2)
    assert_closed(descriptors)
    os.fstat(synthetic['fd'])


def test_binary_comm_and_cpu_activity_do_not_corrupt_start_time_parsing(synthetic):
    module = synthetic['module']
    path = synthetic['target'] / 'stat'
    path.write_bytes(process_stat(9001).encode().replace(b'misleading ) dockerd', b'private \xff ) command'))
    with module.capture_process_identity(synthetic['fd'], pid=9001, deadline=time.monotonic() + 2) as held:
        path.write_bytes(path.read_bytes().replace(b'S 0 0 ', b'R 999 3 '))
        assert held.check(time.monotonic() + 2) is None
        assert held.snapshot.start_time == 123


@pytest.mark.parametrize('name', ['status', 'stat', 'uid_map', 'gid_map'])
@pytest.mark.parametrize('kind', ['symlink', 'directory', 'fifo'])
def test_only_fixed_nofollow_regular_proc_records_are_read(synthetic, tmp_path, name, kind):
    module = synthetic['module']
    path = synthetic['target'] / name
    source = tmp_path / 'private-record'
    source.write_bytes(path.read_bytes())
    path.unlink()
    if kind == 'symlink':
        path.symlink_to(source)
    elif kind == 'directory':
        path.mkdir()
    else:
        os.mkfifo(path)
    with pytest.raises(module.IdentityObservationError, match='^identity_observation_unavailable$'):
        module.capture_process_identity(synthetic['fd'], pid=9001, deadline=time.monotonic() + 2)


def test_actual_read_is_chunked_and_stops_at_byte_limit(synthetic, monkeypatch):
    module = synthetic['module']
    (synthetic['target'] / 'status').write_bytes(b'x' * 20000 + b'\n')
    original = module.os.read
    sizes = []
    def measured(fd, size):
        sizes.append(size)
        return original(fd, size)
    monkeypatch.setattr(module.os, 'read', measured)
    with pytest.raises(module.IdentityObservationError):
        module.capture_process_identity(synthetic['fd'], pid=9001, deadline=time.monotonic() + 2)
    assert max(sizes) == 4096 and sizes[-1] == 1


@pytest.mark.parametrize('field', ['uid_map', 'gid_map', 'stat', 'status', 'target_namespace'])
def test_changed_target_incarnation_or_identity_invalidates_snapshot(synthetic, tmp_path, field):
    module = synthetic['module']
    with module.capture_process_identity(synthetic['fd'], pid=9001, deadline=time.monotonic() + 2) as held:
        if field == 'target_namespace':
            other = tmp_path / 'target-namespace'
            other.touch()
            path = synthetic['target'] / 'ns/user'
            path.unlink()
            path.symlink_to(other)
        else:
            path = synthetic['target'] / field
            path.write_bytes({'uid_map': b'0 100000 65536\n', 'gid_map': b'0 100000 65536\n',
                              'stat': process_stat(9001, start=124).encode(),
                              'status': b'Uid: 1000 1001 1000 1000\nGid: 2000 2000 2000 2000\n'}[field])
        with pytest.raises(module.IdentityObservationError):
            held.check(time.monotonic() + 2)


@pytest.mark.parametrize('field', ['stat', 'status', 'target_namespace', 'reader_namespace'])
def test_mutation_during_map_read_cannot_mix_identity_snapshots(synthetic, tmp_path, monkeypatch, field):
    module = synthetic['module']
    original = module._read
    def changed(proc, name, deadline, event):
        value = original(proc, name, deadline, event)
        if name == 'gid_map':
            if 'namespace' in field:
                other = tmp_path / field
                other.touch()
                path = synthetic['opener' if field == 'reader_namespace' else 'target'] / 'ns/user'
                path.unlink()
                path.symlink_to(other)
            elif field == 'stat':
                (synthetic['target'] / field).write_text(process_stat(9001, start=200))
            else:
                (synthetic['target'] / field).write_text('Uid: 1000 1000 1000 1000\nGid: 2001 2000 2000 2000\n')
        return value
    monkeypatch.setattr(module, '_read', changed)
    with pytest.raises(module.IdentityObservationError):
        module.capture_process_identity(synthetic['fd'], pid=9001, deadline=time.monotonic() + 2)


def test_capture_duplicates_the_borrowed_fd_and_returns_detached_snapshots(synthetic):
    module = synthetic['module']
    caller = os.dup(synthetic['fd'])
    held = module.capture_process_identity(caller, pid=9001, deadline=time.monotonic() + 2)
    os.close(caller)
    try:
        snapshot = held.snapshot
        object.__setattr__(snapshot, 'uids', (0,) * 4)
        object.__setattr__(snapshot.uid_map[0], 'length', 1)
        assert held.snapshot.uids == (1000,) * 4
        assert held.snapshot.uid_map[0].length == 4294967295
        assert all(not os.get_inheritable(fd) for fd in held._handles)
        assert held.check(time.monotonic() + 2) is None
    finally:
        held.close()


@pytest.mark.parametrize('deadline', [True, False, None, 'secret', float('nan'), float('inf'), -1, 0, 1])
def test_bad_deadlines_fail_before_descriptor_access(synthetic, monkeypatch, deadline):
    module = synthetic['module']
    def forbidden(*args, **kwargs):
        raise AssertionError('descriptor access before validation')
    monkeypatch.setattr(module.os, 'dup', forbidden)
    with pytest.raises(module.IdentityObservationError, match='^identity_observation_unavailable$'):
        module.capture_process_identity(synthetic['fd'], pid=9001, deadline=deadline)


@pytest.mark.parametrize('options', [dict(pid=True), dict(pid=0), dict(pid=2**31), dict(pid='9001'),
                                    dict(proc_fd=True), dict(proc_fd=-1), dict(cancelled=True)])
def test_invalid_private_input_types_fail_before_io(synthetic, monkeypatch, options):
    module = synthetic['module']
    def forbidden(*args, **kwargs):
        raise AssertionError('descriptor access before validation')
    monkeypatch.setattr(module.os, 'dup', forbidden)
    parameters = dict(proc_fd=synthetic['fd'], pid=9001, deadline=time.monotonic() + 2)
    parameters.update(options)
    with pytest.raises(module.IdentityObservationError):
        module.capture_process_identity(**parameters)


def test_nonlinux_capture_is_unsupported_before_descriptor_access(synthetic, monkeypatch):
    module = synthetic['module']
    monkeypatch.setattr(module.sys, 'platform', 'darwin')
    monkeypatch.setattr(module.os, 'dup', lambda *args: pytest.fail('unexpected access'))
    with pytest.raises(module.IdentityObservationError):
        module.capture_process_identity(synthetic['fd'], pid=9001, deadline=time.monotonic() + 2)


@pytest.mark.parametrize('when', ['before', 'during_read', 'after_capture'])
def test_cancellation_closes_owned_descriptors_and_exposes_no_raw_error(synthetic, monkeypatch, when):
    module = synthetic['module']
    event = threading.Event()
    descriptors = track_descriptors(module, monkeypatch)
    if when == 'before':
        event.set()
    elif when == 'during_read':
        original = module.os.read
        def cancel(fd, size):
            value = original(fd, size)
            event.set()
            return value
        monkeypatch.setattr(module.os, 'read', cancel)
    with pytest.raises(module.IdentityObservationError, match='^identity_observation_unavailable$'):
        held = module.capture_process_identity(synthetic['fd'], pid=9001, deadline=time.monotonic() + 2, cancelled=event)
        event.set()
        held.check(time.monotonic() + 2)
    if when == 'before':
        assert not descriptors
    else:
        assert_closed(descriptors)


def test_capture_and_check_have_one_two_second_budget(synthetic, monkeypatch):
    module = synthetic['module']
    original = module._take
    deadlines = []
    def measured(proc, pid, deadline, event):
        deadlines.append(deadline)
        return original(proc, pid, deadline, event)
    monkeypatch.setattr(module, '_take', measured)
    before = time.monotonic()
    with module.capture_process_identity(synthetic['fd'], pid=9001, deadline=before + 100) as held:
        assert deadlines[0] == deadlines[1] and before < deadlines[0] <= time.monotonic() + 2
        assert held.check(before + 100) is None
        assert deadlines[-1] <= time.monotonic() + 2


@pytest.mark.parametrize('operation', ['check', 'close'])
def test_reentry_is_static_busy_and_does_not_invalidate_outer_capture(synthetic, monkeypatch, operation):
    module = synthetic['module']
    with module.capture_process_identity(synthetic['fd'], pid=9001, deadline=time.monotonic() + 2) as held:
        original = module._take
        def reenter(*args):
            with pytest.raises(module.IdentityObservationError, match='^identity_observation_busy$'):
                held.check(time.monotonic() + 2) if operation == 'check' else held.close()
            return original(*args)
        monkeypatch.setattr(module, '_take', reenter)
        assert held.check(time.monotonic() + 2) is None


@pytest.mark.parametrize('field', ['pid', 'tid'])
def test_observation_cannot_move_to_another_process_or_native_thread(synthetic, monkeypatch, field):
    module = synthetic['module']
    with module.capture_process_identity(synthetic['fd'], pid=9001, deadline=time.monotonic() + 2) as held:
        if field == 'pid':
            monkeypatch.setattr(module.os, 'getpid', lambda: 100)
        else:
            monkeypatch.setattr(module.threading, 'get_native_id', lambda: 100)
        with pytest.raises(module.IdentityObservationError):
            held.check(time.monotonic() + 2)


@pytest.mark.parametrize('exception', [OSError('private-path'), ValueError('secret'), RuntimeError('private')])
def test_kernel_read_failures_are_sanitized_and_all_fds_are_closed(synthetic, monkeypatch, exception):
    module = synthetic['module']
    descriptors = track_descriptors(module, monkeypatch)
    def fail(*args):
        raise exception
    monkeypatch.setattr(module.os, 'read', fail)
    with pytest.raises(module.IdentityObservationError, match='^identity_observation_unavailable$') as caught:
        module.capture_process_identity(synthetic['fd'], pid=9001, deadline=time.monotonic() + 2)
    assert caught.value.__suppress_context__
    assert_closed(descriptors)


def test_real_linux_native_thread_reads_only_actual_kernel_identity():
    import sys
    from concurrent.futures import ThreadPoolExecutor
    if sys.platform != 'linux':
        pytest.skip('Linux native-thread procfs/user-namespace read-only integration')
    module = implementation()
    def in_native_thread():
        pid, tid = os.getpid(), threading.get_native_id()
        assert tid != pid
        proc = os.open(f'/proc/{pid}/task/{tid}', os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
        try:
            with module.capture_process_identity(proc, pid=tid, deadline=time.monotonic() + 2) as held:
                assert held.snapshot.pid == tid and held.snapshot.opener == (pid, tid)
                assert held.snapshot.uids[:3] == os.getresuid()
                assert held.snapshot.gids[:3] == os.getresgid()
                assert held.snapshot.target_user_namespace == held.snapshot.opener_user_namespace
                for name, observed in [('uid_map', held.snapshot.uid_map), ('gid_map', held.snapshot.gid_map)]:
                    descriptor = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=proc)
                    try:
                        actual = os.read(descriptor, module.MAX_PROC_BYTES + 1)
                    finally:
                        os.close(descriptor)
                    assert observed == module.parse_id_map(actual)
                assert held.check(time.monotonic() + 2) is None
        finally:
            os.close(proc)
    with ThreadPoolExecutor(max_workers=1) as executor:
        executor.submit(in_native_thread).result(timeout=5)
