"""Private descriptor ownership for the offline restore lock."""

import fcntl
import os
import stat
from pathlib import Path

import pytest
from larenor_server.core_backups import restore as restore_module
from larenor_server.errors import StartupError
from larenor_server.files import private_create
from test_core_backup_empty_restore import PASSPHRASE, _bundle, _target


def test_restore_lock_descriptor_is_private_noninheritable_and_exclusive(tmp_path):
    lock_path = tmp_path.resolve() / ".initialize.lock"
    private_create(lock_path, b"")

    with restore_module._open_restore_lock(lock_path) as descriptor:
        info = os.fstat(descriptor)
        assert stat.S_ISREG(info.st_mode)
        assert stat.S_IMODE(info.st_mode) == 0o600
        assert info.st_uid == os.geteuid()
        assert info.st_nlink == 1
        assert not os.get_inheritable(descriptor)

        contender = os.open(lock_path, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            with pytest.raises(BlockingIOError):
                fcntl.flock(contender, fcntl.LOCK_EX | fcntl.LOCK_NB)
        finally:
            os.close(contender)


def test_restore_lock_rejects_symlink_with_static_error(tmp_path):
    root = tmp_path.resolve()
    target = root / "private-target"
    private_create(target, b"")
    lock_path = root / ".initialize.lock"
    lock_path.symlink_to(target)

    with (
        pytest.raises(StartupError, match="^restore_lock_invalid$"),
        restore_module._open_restore_lock(lock_path),
    ):
        raise AssertionError("unsafe lock must not be acquired")


def test_restore_lock_rejects_path_replacement_after_flock(monkeypatch, tmp_path):
    root = tmp_path.resolve()
    lock_path = root / ".initialize.lock"
    retired_path = root / ".initialize.lock.retired"
    private_create(lock_path, b"")
    real_flock = fcntl.flock

    def replace_after_lock(descriptor, operation):
        real_flock(descriptor, operation)
        lock_path.replace(retired_path)
        private_create(lock_path, b"")

    monkeypatch.setattr(restore_module.fcntl, "flock", replace_after_lock)

    with (
        pytest.raises(StartupError, match="^restore_lock_invalid$"),
        restore_module._open_restore_lock(lock_path),
    ):
        raise AssertionError("replaced lock must not be acquired")


def test_restore_never_reopens_preflighted_lock_through_path_open(
    server, tmp_path, monkeypatch
):
    bundle, _key, _context = _bundle(server)
    target = _target(tmp_path, server[3])
    lock_path = target.data_dir / ".initialize.lock"
    original_open = Path.open

    def guarded_open(path, *args, **kwargs):
        if path == lock_path:
            raise AssertionError("restore lock must stay on its verified descriptor")
        return original_open(path, *args, **kwargs)

    monkeypatch.setattr(Path, "open", guarded_open)

    snapshot_id = restore_module.restore_empty(target, bundle, PASSPHRASE)

    assert len(snapshot_id) == 32
    assert target.database_file.exists()
    assert target.key_file.exists()
