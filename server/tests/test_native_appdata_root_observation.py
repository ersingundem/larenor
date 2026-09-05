"""Exact root observations: real directory races, synthetic mount context on Mac."""

from dataclasses import replace
import os
from pathlib import Path
import stat
import sys
import tempfile
import threading
import time

import pytest

from larenor_server.plugins import native_appdata_root_observation as module
from larenor_server.plugins.host_preflight import HostPolicy, HostRoot
from larenor_server.plugins.linux_mount_observation import MountObservation, MountRecord


def identity(fd):
    value = os.fstat(fd)
    return value.st_dev, value.st_ino, value.st_uid, value.st_gid, stat.S_IMODE(value.st_mode)


def deadline():
    return time.monotonic() + 2


def unavailable(call):
    with pytest.raises(module.RootObservationError) as caught:
        call()
    assert str(caught.value) == 'root_observation_unavailable'
    assert caught.value.__suppress_context__


@pytest.fixture
def tree(tmp_path, monkeypatch):
    # Only this explicit test fixture redirects '/'. Production always opens
    # actual '/', so /tmp ancestry is never silently granted an exception.
    anchor = tmp_path / 'anchor'
    target = anchor / 'approved' / 'data'
    target.mkdir(parents=True, mode=0o700)
    anchor.chmod(0o700)
    (anchor / 'approved').chmod(0o700)
    original_open = os.open
    def opening(path, flags, *args, **kwargs):
        return original_open(anchor if path == '/' else path, flags, *args, **kwargs)
    monkeypatch.setattr(module.os, 'open', opening)
    monkeypatch.setattr(module.sys, 'platform', 'linux')
    anchor_fd = original_open(anchor, os.O_RDONLY | os.O_DIRECTORY)
    try:
        root_identity = identity(anchor_fd)
    finally:
        os.close(anchor_fd)
    record = MountRecord(41, 41, os.major(root_identity[0]), os.minor(root_identity[0]),
                         '/', '/', ('rw',), (), 'testfs', ('rw',))
    state = dict(anchor=anchor, target=target, parent=target.parent, record=record,
                 root_identity=root_identity, namespace=(7, 100), original_open=original_open)
    def observe(fd, *, deadline):
        return MountObservation(state['record'], identity(fd), state['namespace'],
                                (*state['root_identity'], 41))
    state['observe'] = observe
    monkeypatch.setattr(module, 'observe_fd_mount', observe)
    state['policy'] = HostPolicy({'appdata': HostRoot('/approved/data', 'data')})
    return state


def capture(tree, **kwargs):
    return module.observe_appdata_root(tree['policy'], 'appdata', deadline=deadline(), **kwargs)


def test_exact_approved_root_retains_parents_and_borrows_only_complete_target(tree):
    with capture(tree) as held:
        held.check(deadline())
        with held.borrowed_root(deadline()) as fd:
            assert identity(fd) == held.root_identity
            assert os.fstat(fd).st_ino == tree['target'].stat().st_ino
            assert os.get_inheritable(fd) is False
        assert held.mount.mount_id == 41
        assert '/approved/data' not in repr(held) and str(tree['anchor']) not in repr(held)
    unavailable(lambda: held.check(deadline()))


def test_missing_exact_root_never_returns_nearest_existing_parent(tree):
    tree['target'].rmdir()
    unavailable(lambda: capture(tree))
    assert not tree['target'].exists()


def test_renamed_parent_with_same_held_target_cannot_revalidate(tree):
    with capture(tree) as held:
        tree['parent'].rename(tree['anchor'] / 'moved')
        tree['parent'].mkdir(mode=0o700)
        unavailable(lambda: held.check(deadline()))
        unavailable(lambda: held.check(deadline()))


def test_same_device_different_mount_identity_cannot_revalidate(tree):
    with capture(tree) as held:
        tree['record'] = replace(tree['record'], mount_id=42)
        unavailable(lambda: held.check(deadline()))


def test_cancelled_observation_expires_and_closes(tree):
    event = threading.Event()
    held = capture(tree, cancelled=event)
    event.set()
    unavailable(lambda: held.check(deadline()))
    held.close()


@pytest.mark.parametrize('kind', ['leaf', 'parent', 'root'])
def test_replacing_any_named_directory_expires_held_chain(tree, kind):
    selected = {'leaf': tree['target'], 'parent': tree['parent'], 'root': tree['anchor']}[kind]
    with capture(tree) as held:
        selected.rename(selected.with_name(selected.name + '-old'))
        selected.mkdir(mode=0o700)
        unavailable(lambda: held.check(deadline()))


@pytest.mark.parametrize('kind', ['leaf', 'parent'])
def test_symlinks_are_never_followed_even_if_they_point_to_original_directory(tree, kind):
    selected = tree['target'] if kind == 'leaf' else tree['parent']
    old = selected.with_name(selected.name + '-old')
    selected.rename(old)
    selected.symlink_to(old, target_is_directory=True)
    unavailable(lambda: capture(tree))


@pytest.mark.parametrize('mode', [0o702, 0o720, 0o777, 0o1777])
@pytest.mark.parametrize('kind', ['leaf', 'parent', 'root'])
def test_foreign_writable_ancestry_has_no_sticky_directory_exception(tree, mode, kind):
    selected = {'leaf': tree['target'], 'parent': tree['parent'], 'root': tree['anchor']}[kind]
    selected.chmod(mode)
    unavailable(lambda: capture(tree))


def test_chmod_after_capture_expires_instead_of_returning_stale_safe_fact(tree):
    with capture(tree) as held:
        tree['parent'].chmod(0o777)
        unavailable(lambda: held.check(deadline()))


def test_foreign_owner_is_rejected_without_chown(tree, monkeypatch):
    original = module.os.fstat
    inode = tree['parent'].stat().st_ino
    def foreign(fd):
        value = original(fd)
        if value.st_ino == inode:
            fields = list(value)
            fields[4] = os.geteuid() + 10000
            return os.stat_result(fields)
        return value
    monkeypatch.setattr(module.os, 'fstat', foreign)
    unavailable(lambda: capture(tree))


def test_non_directory_root_never_opens_as_a_file(tree):
    tree['target'].rmdir()
    tree['target'].write_text('private contents')
    unavailable(lambda: capture(tree))


@pytest.mark.parametrize('target_change', ['missing', 'present'])
def test_parent_renamed_between_opening_it_and_child_lookup_never_returns_observation(tree, monkeypatch, target_change):
    original = module.os.open
    changed = False
    def opening(path, flags, *args, **kwargs):
        nonlocal changed
        if path == 'data' and not changed:
            changed = True
            moved = tree['anchor'] / 'moved'
            tree['parent'].rename(moved)
            tree['parent'].mkdir(mode=0o700)
            if target_change == 'missing':
                (moved / 'data').rmdir()
        return original(path, flags, *args, **kwargs)
    monkeypatch.setattr(module.os, 'open', opening)
    unavailable(lambda: capture(tree))
    assert changed


def test_earlier_parent_rename_during_final_child_recheck_is_detected(tree, monkeypatch):
    with capture(tree) as held:
        original = module.os.open
        opened = 0
        def opening(path, flags, *args, **kwargs):
            nonlocal opened
            fd = original(path, flags, *args, **kwargs)
            if path == 'data':
                opened += 1
                if opened == 2:  # Reverse validation after forward complete walk.
                    tree['parent'].rename(tree['anchor'] / 'moved')
                    tree['parent'].mkdir(mode=0o700)
            return fd
        monkeypatch.setattr(module.os, 'open', opening)
        unavailable(lambda: held.check(deadline()))


def mounted_disk(tree, monkeypatch, *, mount_id=42, parent_id=41, point='/approved', readonly_parent=False):
    root = tree['root_identity']
    old = tree['observe']
    disk = replace(tree['record'], mount_id=mount_id, parent_id=parent_id, mount_point=point)
    def observe(fd, *, deadline):
        value = old(fd, deadline=deadline)
        if value.directory_identity != root:
            return replace(value, mount=disk)
        if readonly_parent:
            return replace(value, mount=replace(value.mount, mount_options=('ro',)))
        return value
    monkeypatch.setattr(module, 'observe_fd_mount', observe)
    return disk


def test_stable_explicit_disk_mount_on_approved_path_is_observed(tree, monkeypatch):
    disk = mounted_disk(tree, monkeypatch)
    with capture(tree) as held:
        assert held.mount.mount == disk
        held.check(deadline())


def test_readonly_ancestor_can_lead_to_separate_writable_data_mount(tree, monkeypatch):
    mounted_disk(tree, monkeypatch, readonly_parent=True)
    with capture(tree) as held:
        assert held.mount.read_only is False


@pytest.mark.parametrize('changes', [dict(point='/wrong'), dict(parent_id=99)])
def test_mount_transition_requires_exact_path_and_parent_mount_binding(tree, monkeypatch, changes):
    mounted_disk(tree, monkeypatch, **changes)
    unavailable(lambda: capture(tree))


@pytest.mark.parametrize('change', ['readonly', 'idmapped', 'namespace', 'process_root', 'device', 'same_id_new_record'])
def test_mount_and_context_changes_during_acquisition_are_unavailable(tree, monkeypatch, change):
    old = tree['observe']
    target_inode = tree['target'].stat().st_ino
    def observe(fd, *, deadline):
        value = old(fd, deadline=deadline)
        if value.directory_identity[1] != target_inode:
            return value
        if change == 'readonly':
            return replace(value, mount=replace(value.mount, mount_options=('ro',)))
        if change == 'idmapped':
            return replace(value, mount=replace(value.mount, mount_options=('rw', 'idmapped')))
        if change == 'namespace':
            return replace(value, namespace_identity=(7, 999))
        if change == 'process_root':
            return replace(value, process_root_identity=(*value.process_root_identity[:-1], 999))
        if change == 'device':
            return replace(value, directory_identity=(999, *value.directory_identity[1:]))
        return replace(value, mount=replace(value.mount, filesystem='otherfs'))
    monkeypatch.setattr(module, 'observe_fd_mount', observe)
    unavailable(lambda: capture(tree))


@pytest.mark.parametrize('change', ['namespace', 'process_root', 'mount', 'uid', 'gid'])
def test_final_observation_change_invalidates_existing_hold(tree, monkeypatch, change):
    with capture(tree) as held:
        old = tree['observe']
        def observe(fd, *, deadline):
            value = old(fd, deadline=deadline)
            if change == 'namespace':
                return replace(value, namespace_identity=(7, 999))
            if change == 'process_root':
                return replace(value, process_root_identity=(*value.process_root_identity[:-1], 999))
            if change == 'mount':
                return replace(value, mount=replace(value.mount, mount_id=999))
            index = 2 if change == 'uid' else 3
            data = list(value.directory_identity)
            data[index] += 1
            return replace(value, directory_identity=tuple(data))
        monkeypatch.setattr(module, 'observe_fd_mount', observe)
        unavailable(lambda: held.check(deadline()))


def test_returned_mount_fact_does_not_alias_retained_expectation(tree):
    with capture(tree) as held:
        value = held.mount
        object.__setattr__(value.mount, 'mount_id', 999)
        held.check(deadline())
        assert held.mount.mount_id == 41


@pytest.mark.parametrize('value', [True, None, '2', float('nan'), float('inf'), -1, 0])
def test_invalid_or_expired_deadlines_fail_closed(tree, value):
    unavailable(lambda: module.observe_appdata_root(tree['policy'], 'appdata', deadline=value))


@pytest.mark.parametrize('value', [True, object(), lambda: False])
def test_cancel_argument_is_an_event_not_a_truthy_authority_callback(tree, value):
    unavailable(lambda: capture(tree, cancelled=value))


def test_cancel_during_observation_is_checked_before_return(tree, monkeypatch):
    event = threading.Event()
    old = tree['observe']
    def observe(fd, *, deadline):
        value = old(fd, deadline=deadline)
        event.set()
        return value
    monkeypatch.setattr(module, 'observe_fd_mount', observe)
    unavailable(lambda: capture(tree, cancelled=event))


def test_cancel_after_borrow_cannot_return_as_valid_observation(tree):
    event = threading.Event()
    held = capture(tree, cancelled=event)
    def borrowing():
        with held.borrowed_root(deadline()):
            event.set()
    unavailable(borrowing)
    unavailable(lambda: held.check(deadline()))


def test_deadline_is_rechecked_after_slow_provider_without_reset(tree, monkeypatch):
    now = [100.0]
    monkeypatch.setattr(module.time, 'monotonic', lambda: now[0])
    old = tree['observe']
    def observe(fd, *, deadline):
        result = old(fd, deadline=deadline)
        now[0] = 100.6
        return result
    monkeypatch.setattr(module, 'observe_fd_mount', observe)
    unavailable(lambda: module.observe_appdata_root(tree['policy'], 'appdata', deadline=100.5))


def test_far_future_deadline_is_capped_to_two_seconds(tree, monkeypatch):
    seen = []
    old = tree['observe']
    start = time.monotonic()
    def observe(fd, *, deadline):
        seen.append(deadline)
        return old(fd, deadline=deadline)
    monkeypatch.setattr(module, 'observe_fd_mount', observe)
    with module.observe_appdata_root(tree['policy'], 'appdata', deadline=start + 100):
        pass
    assert seen and max(seen) <= start + 2.05


@pytest.mark.parametrize('kind', ['path', 'purpose', 'owner', 'extra'])
def test_original_policy_mutation_expires_held_root(tree, kind):
    held = capture(tree)
    root = tree['policy'].roots['appdata']
    if kind == 'path':
        object.__setattr__(root, 'path', '/approved/other')
    elif kind == 'purpose':
        object.__setattr__(root, 'purpose', 'library')
    elif kind == 'owner':
        object.__setattr__(tree['policy'], 'owner_uid', True)
    else:
        object.__setattr__(root, 'extra', 'secret')
    unavailable(lambda: held.check(deadline()))


@pytest.mark.parametrize('root_id', ['', '../appdata', 'UNKNOWN', 'x' * 41, True, None, 'absent'])
def test_only_existing_opaque_root_id_is_accepted(tree, root_id):
    unavailable(lambda: module.observe_appdata_root(tree['policy'], root_id, deadline=deadline()))


@pytest.mark.parametrize('path', ['/a/' + 'x' * 256, '/' + '/'.join('a' for _ in range(129)),
                                  '/' + '/'.join('x' * 100 for _ in range(42)), '/\udcff'])
def test_path_byte_component_and_depth_bounds_precede_open(tree, monkeypatch, path):
    policy = HostPolicy({'appdata': HostRoot('/allowed', 'data')})
    object.__setattr__(policy.roots['appdata'], 'path', path)
    def no_open(*args, **kwargs):
        pytest.fail('invalid policy must be rejected before filesystem access')
    monkeypatch.setattr(module.os, 'open', no_open)
    unavailable(lambda: module.observe_appdata_root(policy, 'appdata', deadline=deadline()))


def test_worker_uid_must_match_actual_effective_uid(tree):
    policy = HostPolicy(tree['policy'].roots, owner_uid=os.geteuid() + 1)
    unavailable(lambda: module.observe_appdata_root(policy, 'appdata', deadline=deadline()))


def test_an_observation_cannot_move_to_another_native_thread(tree):
    held = capture(tree)
    failures = []
    def run():
        try:
            held.check(deadline())
        except module.RootObservationError as error:
            failures.append(str(error))
    worker = threading.Thread(target=run)
    worker.start()
    worker.join(2)
    assert not worker.is_alive() and failures == ['root_observation_unavailable']
    unavailable(lambda: held.check(deadline()))


def test_fork_identity_change_invalidates_observation_without_signalling_processes(tree, monkeypatch):
    held = capture(tree)
    current = os.getpid()
    monkeypatch.setattr(module.os, 'getpid', lambda: current + 1)
    unavailable(lambda: held.check(deadline()))


@pytest.mark.parametrize('action', ['check', 'borrow', 'close'])
def test_busy_reentry_never_deadlocks_or_closes_active_borrow(tree, action):
    with capture(tree) as held:
        with held.borrowed_root(deadline()) as fd:
            with pytest.raises(module.RootObservationError, match='^root_observation_busy$'):
                if action == 'check':
                    held.check(deadline())
                elif action == 'close':
                    held.close()
                else:
                    with held.borrowed_root(deadline()):
                        pytest.fail('reentry must not yield')
            assert identity(fd) == held.root_identity
        held.check(deadline())


def test_closing_caller_borrowed_fd_invalidates_held_observation(tree):
    held = capture(tree)
    def borrowing():
        with held.borrowed_root(deadline()) as fd:
            os.close(fd)
    unavailable(borrowing)
    held.close()


def tracked_opens(monkeypatch):
    original = module.os.open
    seen = []
    def opening(*args, **kwargs):
        fd = original(*args, **kwargs)
        seen.append(fd)
        return fd
    monkeypatch.setattr(module.os, 'open', opening)
    return seen


def all_closed(descriptors):
    assert descriptors
    for fd in set(descriptors):
        with pytest.raises(OSError):
            os.fstat(fd)


@pytest.mark.parametrize('when', ['complete', 'capture_error', 'check_error', 'interrupt', 'borrow_interrupt'])
def test_all_owned_descriptors_are_closed_on_each_exit(tree, monkeypatch, when):
    seen = tracked_opens(monkeypatch)
    if when == 'complete':
        with capture(tree):
            pass
    elif when in {'capture_error', 'interrupt'}:
        def broken(fd, *, deadline):
            if when == 'interrupt':
                raise KeyboardInterrupt()
            raise OSError('private /host/path and source details')
        monkeypatch.setattr(module, 'observe_fd_mount', broken)
        if when == 'interrupt':
            with pytest.raises(KeyboardInterrupt):
                capture(tree)
        else:
            unavailable(lambda: capture(tree))
    else:
        held = capture(tree)
        if when == 'check_error':
            tree['target'].rmdir()
            unavailable(lambda: held.check(deadline()))
        else:
            with pytest.raises(KeyboardInterrupt):
                with held.borrowed_root(deadline()):
                    raise KeyboardInterrupt()
    all_closed(seen)


def test_observation_never_mutates_or_enumerates_root_contents(tree, monkeypatch):
    def forbidden(*args, **kwargs):
        pytest.fail('root observation attempted a mutation or content enumeration')
    for name in ('mkdir', 'makedirs', 'chmod', 'chown', 'rename', 'replace', 'unlink', 'rmdir', 'listdir', 'scandir'):
        monkeypatch.setattr(module.os, name, forbidden)
    with capture(tree) as held:
        held.check(deadline())


def test_non_linux_is_explicitly_unavailable_without_filesystem_access(tree, monkeypatch):
    monkeypatch.setattr(module.sys, 'platform', 'darwin')
    def forbidden(*args, **kwargs):
        pytest.fail('unsupported platform must not access filesystem')
    monkeypatch.setattr(module.os, 'open', forbidden)
    unavailable(lambda: capture(tree))


@pytest.mark.skipif(sys.platform != 'linux', reason='real Linux proc/mount evidence, no Mac fallback')
def test_linux_real_exact_root_uses_actual_proc_mount_and_named_descriptors():
    # A dedicated fixture under checkout avoids /tmp's deliberately forbidden
    # sticky ancestry. No mount, namespace, daemon or permission change is used.
    with tempfile.TemporaryDirectory(prefix='.root-observation-', dir=Path.cwd()) as path:
        policy = HostPolicy({'appdata': HostRoot(path, 'data')})
        with module.observe_appdata_root(policy, 'appdata', deadline=deadline()) as held:
            with held.borrowed_root(deadline()) as fd:
                assert identity(fd) == held.root_identity
                actual = module.observe_fd_mount(fd, deadline=deadline())
                assert actual == held.mount
                assert actual.read_only is False and actual.idmapped is False
            held.check(deadline())
