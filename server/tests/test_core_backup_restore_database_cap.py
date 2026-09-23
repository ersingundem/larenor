"""Database-specific size bounds across restore staging and recovery."""

import pytest
from test_core_backup_empty_restore import PASSPHRASE, _bundle, _target

from larenor_server.core_backups import restore as restore_module
from larenor_server.errors import StartupError


def _stop_after_journal(target, bundle, monkeypatch):
    recover = restore_module.recover_empty_restore

    def stop(_settings):
        raise OSError("synthetic stop after journal promotion")

    with monkeypatch.context() as scoped:
        scoped.setattr(restore_module, "recover_empty_restore", stop)
        with pytest.raises(OSError, match="after journal promotion"):
            restore_module.restore_empty(target, bundle, PASSPHRASE)
    return recover


def test_restore_staging_enforces_database_resource_cap(server, tmp_path, monkeypatch):
    bundle, _key, _context = _bundle(server)
    target = _target(tmp_path, server[3])
    monkeypatch.setattr(restore_module, "MAX_DATABASE_BYTES", 0)

    with pytest.raises(StartupError, match="^invalid_storage_file$"):
        restore_module.restore_empty(target, bundle, PASSPHRASE)

    assert not target.key_file.exists()
    assert not target.database_file.exists()
    assert not (target.data_dir / ".restore-state.json").exists()
    assert not list(target.data_dir.glob(".restore-*"))


def test_recovery_preflight_enforces_database_cap_before_publication(
    server, tmp_path, monkeypatch
):
    bundle, _key, _context = _bundle(server)
    target = _target(tmp_path, server[3])
    recover = _stop_after_journal(target, bundle, monkeypatch)
    stage = next(path for path in target.data_dir.glob(".restore-*") if path.is_dir())
    database_size = (stage / "larenor.sqlite3").stat().st_size
    monkeypatch.setattr(restore_module, "MAX_DATABASE_BYTES", database_size - 1)

    with pytest.raises(StartupError, match="^restore_recovery_invalid$"):
        recover(target)

    assert not target.key_file.exists()
    assert not (target.data_dir / "family-board.sqlite3").exists()
    assert not target.database_file.exists()
    assert (target.data_dir / ".restore-state.json").exists()


def test_recovery_revalidates_published_database_against_resource_cap(
    server, tmp_path, monkeypatch
):
    bundle, _key, _context = _bundle(server)
    target = _target(tmp_path, server[3])
    real_sync = restore_module.sync_directory

    def stop_after_database_publication(path):
        if path == target.data_dir and target.database_file.exists():
            raise OSError("synthetic stop after database publication")
        return real_sync(path)

    with monkeypatch.context() as scoped:
        scoped.setattr(restore_module, "sync_directory", stop_after_database_publication)
        with pytest.raises(OSError, match="after database publication"):
            restore_module.restore_empty(target, bundle, PASSPHRASE)

    assert target.database_file.exists()
    assert not (target.data_dir / ".initialized").exists()
    database_size = target.database_file.stat().st_size
    monkeypatch.setattr(restore_module, "MAX_DATABASE_BYTES", database_size - 1)

    with pytest.raises(StartupError, match="^restore_recovery_invalid$"):
        restore_module.recover_empty_restore(target)

    assert (target.data_dir / ".restore-state.json").exists()
    assert not (target.data_dir / ".initialized").exists()


def test_recovery_accepts_database_at_exact_resource_cap(server, tmp_path, monkeypatch):
    bundle, key, _context = _bundle(server)
    target = _target(tmp_path, server[3])
    recover = _stop_after_journal(target, bundle, monkeypatch)
    stage = next(path for path in target.data_dir.glob(".restore-*") if path.is_dir())
    database_size = (stage / "larenor.sqlite3").stat().st_size
    monkeypatch.setattr(restore_module, "MAX_DATABASE_BYTES", database_size)

    assert recover(target)

    assert target.database_file.stat().st_size == database_size
    assert target.key_file.read_bytes() == key
    assert (target.data_dir / ".initialized").read_bytes() == b"larenor-schema-1\n"
    assert not (target.data_dir / ".restore-state.json").exists()
