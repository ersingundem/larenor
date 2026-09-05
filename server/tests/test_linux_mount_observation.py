"""Read-only mount evidence using synthetic proc files and real held directories."""

from dataclasses import FrozenInstanceError
import os
from pathlib import Path
import sys
import time

import pytest

from larenor_server.plugins import linux_mount_observation as module


def row(mount_id=41, *, device='8:1', root='/', point='/private/data',
        options='rw,relatime', extra='shared:7', filesystem='ext4', super_options='rw'):
    optional = f' {extra}' if extra else ''
    return (f'{mount_id} 1 {device} {root} {point} {options}{optional}'
            f' - {filesystem} /dev/example {super_options}\n').encode()


def unavailable(call):
    with pytest.raises(module.MountObservationError) as caught:
        call()
    assert str(caught.value) == 'mount_observation_unavailable'
    assert caught.value.__suppress_context__


def test_mountinfo_preserves_private_exact_identity_without_repr_paths():
    record, = module.parse_mountinfo(row())
    assert (record.mount_id, record.parent_id) == (41, 1)
    assert (record.device_major, record.device_minor) == (8, 1)
    assert record.root == '/' and record.mount_point == '/private/data'
    assert record.filesystem == 'ext4'
    assert record.read_only is False and record.idmapped is False
    assert '/private/data' not in repr(record)
    with pytest.raises(FrozenInstanceError):
        record.mount_id = 2


@pytest.mark.parametrize('options,super_options,readonly,idmapped', [
    ('rw', 'rw', False, False), ('ro', 'rw', True, False),
    ('rw', 'ro', True, False), ('rw,idmapped', 'rw', False, True),
    ('ro,idmapped', 'ro', True, True),
])
def test_readonly_and_idmapping_are_facts_not_write_authority(options, super_options, readonly, idmapped):
    record, = module.parse_mountinfo(row(options=options, super_options=super_options))
    assert record.read_only is readonly and record.idmapped is idmapped


@pytest.mark.parametrize('encoded,decoded', [
    (r'/my\040disk', '/my disk'), (r'/tab\011name', '/tab\tname'),
    (r'/line\012name', '/line\nname'), (r'/back\134slash', '/back\\slash'),
    ('/müzik', '/müzik'), ('/hash#name', '/hash#name'),
])
def test_only_kernel_path_escapes_are_decoded(encoded, decoded):
    record, = module.parse_mountinfo(row(root=encoded, point=encoded))
    assert record.root == decoded and record.mount_point == decoded


@pytest.mark.parametrize('data', [
    b'', b'\n', row()[:-1], row() + b'partial', row() + row(),
    row().replace(b'41 1', b'0 1'), row().replace(b'41 1', b'-1 1'),
    row().replace(b'41 1', b'01 1'), row().replace(b'41 1', b'41 0'),
    row().replace(b'41 1', b'41 41'), row().replace(b'8:1', b'8'),
    row().replace(b'8:1', b'8:1:2'), row().replace(b'8:1', b'-1:2'),
    row().replace(b'41 1', b'2147483648 1'), row().replace(b'8:1', b'4294967296:1'),
    row().replace(b' - ', b' '), row().replace(b' - ', b' - - '),
    row().replace(b'41 1', b'41  1'), row().replace(b'41 1', b'41\t1'),
    row(options='relatime'), row(options='rw,ro'), row(options='rw,rw'),
    row(options='rw,'), row(super_options='rw,ro'), row(extra='shared:0'),
    row(extra='shared:2 shared:3'), row(extra='unknown:1'),
    row(extra='unbindable:1'), row(extra='shared:2 unbindable'),
    row(root='relative'), row(point='/a/../b'), row(point='/a/./b'),
    row(point='/a//b'), row(point='/a/'), row(point=r'/bad\000name'),
    row(point=r'/bad\041name'), row(point='/bad\\'),
    row().replace(b'/private/data', b'/bad\x00path'),
    row().replace(b'ext4', b'ext4\r'), row() + b'\n',
])
def test_malformed_ambiguous_or_truncated_mountinfo_fails_closed(data):
    unavailable(lambda: module.parse_mountinfo(data))


@pytest.mark.parametrize('value', [None, '41 1', bytearray(row()), True])
def test_parser_requires_bounded_bytes(value):
    unavailable(lambda: module.parse_mountinfo(value))


def test_mountinfo_byte_line_row_and_decoded_path_bounds():
    for data in (b'x' * (module.MAX_MOUNTINFO_BYTES + 1),
                 row(super_options='rw,' + 'x' * module.MAX_LINE_BYTES),
                 b''.join(row(i + 2) for i in range(module.MAX_MOUNT_ROWS + 1)),
                 row(point='/' + 'a' * 4096)):
        unavailable(lambda: module.parse_mountinfo(data))


@pytest.mark.parametrize('extra', ['', 'master:2 propagate_from:3', 'unbindable'])
def test_supported_optional_mount_fields(extra):
    assert module.parse_mountinfo(row(extra=extra))[0].mount_id == 41


def test_fdinfo_extracts_one_positive_mount_id():
    assert module.parse_fdinfo_mount_id(b'pos:\t0\nflags:\t02300000\nmnt_id:\t41\nino:\t200\n') == 41


@pytest.mark.parametrize('data', [
    b'', b'mnt_id:\t41', b'pos:\t0\n', b'mnt_id:\t0\n', b'mnt_id:\t-1\n',
    b'mnt_id:\t01\n', b'mnt_id:\t2147483648\n', b'mnt_id:\t41 42\n',
    b'mnt_id:\t41\nmnt_id:\t41\n', b'mnt_id:\t41\ninvalid\n',
    b'mnt_id:\t41\nino:\t2\nino:\t2\n', b'mnt_id:\t41\x00\n',
    b'mnt_id:\t41\r\n', b' mnt_id:\t41\n', 'mnt_id:\t41\n',
    b'x' * 16385,
])
def test_fdinfo_rejects_ambiguity_and_truncation(data):
    unavailable(lambda: module.parse_fdinfo_mount_id(data))


@pytest.fixture
def proc_tree(tmp_path, monkeypatch):
    directory = tmp_path / 'held-directory'
    directory.mkdir()
    fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
    proc = tmp_path / 'proc'
    task = proc / str(os.getpid()) / 'task' / str(module.threading.get_native_id())
    (task / 'fdinfo').mkdir(parents=True)
    (task / 'ns').mkdir()
    namespace = tmp_path / 'namespace'
    namespace.touch()
    process_root = tmp_path / 'process-root'
    process_root.mkdir()
    (task / 'ns/mnt').symlink_to(namespace)
    (task / 'root').symlink_to(process_root, target_is_directory=True)
    device = os.fstat(fd).st_dev
    state = dict(fd=fd, directory=directory, task=task, namespace=namespace,
                 device=f'{os.major(device)}:{os.minor(device)}', target_id=41,
                 original_read=None)
    (task / 'mountinfo').write_bytes(row(device=state['device']))
    monkeypatch.setattr(module, '_PROC_ROOT', proc)
    monkeypatch.setattr(module.sys, 'platform', 'linux')
    # Kernel fdinfo is generated for each duplicated/opened FD. Synthetic proc
    # only supplies that behavior; its content still passes the real bounded read.
    original_read = module._read
    state['original_read'] = original_read
    def read(directory_fd, name, max_bytes, deadline):
        if name.isdecimal():
            info = os.fstat(int(name))
            mount = state['target_id'] if info.st_ino == os.fstat(fd).st_ino else 1
            (task / 'fdinfo' / name).write_bytes(f'pos:\t0\nmnt_id:\t{mount}\n'.encode())
        return original_read(directory_fd, name, max_bytes, deadline)
    monkeypatch.setattr(module, '_read', read)
    yield state
    os.close(fd)


def observe(tree, **kwargs):
    return module.observe_fd_mount(tree['fd'], deadline=time.monotonic() + 2, **kwargs)


def test_held_directory_maps_to_exact_mount_and_retains_no_open_fds(proc_tree, monkeypatch):
    opened = []
    original_open, original_dup = os.open, os.dup
    def opening(*args, **kwargs):
        fd = original_open(*args, **kwargs)
        opened.append(fd)
        return fd
    def duplicating(fd):
        duplicate = original_dup(fd)
        opened.append(duplicate)
        return duplicate
    monkeypatch.setattr(module.os, 'open', opening)
    monkeypatch.setattr(module.os, 'dup', duplicating)
    result = observe(proc_tree)
    assert result.mount_id == 41 and not result.read_only and not result.idmapped
    assert result.directory_identity[:2] == (os.fstat(proc_tree['fd']).st_dev, os.fstat(proc_tree['fd']).st_ino)
    assert result.namespace_identity == (os.stat(proc_tree['namespace']).st_dev, os.stat(proc_tree['namespace']).st_ino)
    assert str(proc_tree['directory']) not in repr(result)
    assert not hasattr(result, 'write_authorized')
    with pytest.raises(FrozenInstanceError):
        result.mount = None
    assert opened
    for fd in set(opened):
        with pytest.raises(OSError):
            os.fstat(fd)
    assert os.fstat(proc_tree['fd'])


def test_same_device_different_mount_is_not_interchangeable(proc_tree):
    (proc_tree['task'] / 'mountinfo').write_bytes(
        row(41, device=proc_tree['device']) + row(42, device=proc_tree['device'], point='/other'))
    first = observe(proc_tree)
    proc_tree['target_id'] = 42
    second = observe(proc_tree)
    assert first.directory_identity == second.directory_identity
    assert first.mount_id != second.mount_id


@pytest.mark.parametrize('options,super_options', [('rw,idmapped', 'rw'), ('ro', 'rw'), ('rw', 'ro')])
def test_live_readonly_or_idmapped_mount_never_looks_plain_writable(proc_tree, options, super_options):
    (proc_tree['task'] / 'mountinfo').write_bytes(row(device=proc_tree['device'], options=options, super_options=super_options))
    result = observe(proc_tree)
    assert result.idmapped or result.read_only


@pytest.mark.parametrize('data', [row(42), row(device='0:0'), row() + row()])
def test_missing_id_wrong_device_or_duplicate_cannot_produce_observation(proc_tree, data):
    (proc_tree['task'] / 'mountinfo').write_bytes(data)
    unavailable(lambda: observe(proc_tree))


@pytest.mark.parametrize('change', ['mount_id', 'mount_options', 'namespace', 'process_root', 'directory_mode', 'thread', 'deadline'])
def test_changed_context_or_mount_during_read_fails_closed(proc_tree, monkeypatch, tmp_path, change):
    original = module._read
    changed = False
    def read(*args):
        nonlocal changed
        result = original(*args)
        if args[1] == 'mountinfo' and not changed:
            changed = True
            if change == 'mount_id':
                proc_tree['target_id'] = 42
            elif change == 'mount_options':
                (proc_tree['task'] / 'mountinfo').write_bytes(row(device=proc_tree['device'], options='ro'))
            elif change in ('namespace', 'process_root'):
                other = tmp_path / 'replacement'
                other.mkdir() if change == 'process_root' else other.touch()
                link = proc_tree['task'] / ('root' if change == 'process_root' else 'ns/mnt')
                link.unlink()
                link.symlink_to(other)
            elif change == 'directory_mode':
                proc_tree['directory'].chmod(0o711)
            elif change == 'thread':
                monkeypatch.setattr(module.threading, 'get_native_id', lambda: 987654321)
            else:
                monkeypatch.setattr(module.time, 'monotonic', lambda: args[3] + 1)
        return result
    monkeypatch.setattr(module, '_read', read)
    unavailable(lambda: observe(proc_tree))


@pytest.mark.parametrize('field', ['mountinfo', 'fdinfo', 'ns/mnt', 'root'])
def test_inaccessible_proc_context_is_static_error(proc_tree, field):
    path = proc_tree['task'] / field
    path.rmdir() if path.is_dir() and not path.is_symlink() else path.unlink()
    unavailable(lambda: observe(proc_tree))


def test_proc_mountinfo_symlink_is_not_followed(proc_tree, tmp_path):
    target = tmp_path / 'sensitive-path-and-secret'
    target.write_bytes(row(device=proc_tree['device']))
    info = proc_tree['task'] / 'mountinfo'
    info.unlink()
    info.symlink_to(target)
    unavailable(lambda: observe(proc_tree))


@pytest.mark.parametrize('fd', [-1, True, 1.0, None])
def test_invalid_descriptor_is_rejected_without_read(fd):
    unavailable(lambda: module.observe_fd_mount(fd, deadline=time.monotonic() + 2))


@pytest.mark.parametrize('deadline', [None, True, float('inf'), float('nan'), -1])
def test_invalid_or_elapsed_deadline_never_reads(proc_tree, monkeypatch, deadline):
    monkeypatch.setattr(module, '_read', lambda *args: pytest.fail('must not read'))
    unavailable(lambda: module.observe_fd_mount(proc_tree['fd'], deadline=deadline))


def test_non_linux_and_regular_files_are_not_directory_observations(proc_tree, monkeypatch, tmp_path):
    monkeypatch.setattr(module.sys, 'platform', 'darwin')
    unavailable(lambda: observe(proc_tree))
    monkeypatch.setattr(module.sys, 'platform', 'linux')
    with (tmp_path / 'regular').open('w+b') as regular:
        unavailable(lambda: module.observe_fd_mount(regular.fileno(), deadline=time.monotonic() + 2))


def test_bounded_reader_reads_at_most_limit_plus_one_and_closes_fd(tmp_path, monkeypatch):
    (tmp_path / 'proc-file').write_bytes(b'a' * 20000)
    directory = os.open(tmp_path, os.O_RDONLY | os.O_DIRECTORY)
    original_read = os.read
    sizes = []
    def read(fd, count):
        sizes.append(count)
        return original_read(fd, count)
    monkeypatch.setattr(module.os, 'read', read)
    try:
        unavailable(lambda: module._read(directory, 'proc-file', 8192, time.monotonic() + 2))
    finally:
        os.close(directory)
    assert sum(sizes) == 8193 and max(sizes) <= 4096


@pytest.mark.skipif(sys.platform != 'linux', reason='real Linux proc mountinfo/fdinfo required')
def test_linux_real_directory_observation_uses_only_readonly_proc_and_fd(tmp_path):
    fd = os.open(tmp_path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        observed = module.observe_fd_mount(fd, deadline=time.monotonic() + 2)
        assert observed.mount_id > 0
        assert (observed.mount.device_major, observed.mount.device_minor) == (os.major(os.fstat(fd).st_dev), os.minor(os.fstat(fd).st_dev))
        assert observed.directory_identity[1] == os.fstat(fd).st_ino
    finally:
        os.close(fd)
