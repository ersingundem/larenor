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
