"""Fail-closed publication preflight for interrupted Core restores."""

import pytest
from larenor_server.core_backups import restore as restore_module
from larenor_server.errors import StartupError
from larenor_server.files import private_create
from test_core_backup_empty_restore import PASSPHRASE, _bundle, _target


def _journaled_restore(server, tmp_path, monkeypatch):
    bundle, _key, _context = _bundle(server)
    target = _target(tmp_path, server[3])

    def stop_after_journal(_settings):
        raise OSError("synthetic stop after journal promotion")

    with monkeypatch.context() as scoped:
        scoped.setattr(restore_module, "recover_empty_restore", stop_after_journal)
        with pytest.raises(OSError, match="after journal promotion"):
            restore_module.restore_empty(target, bundle, PASSPHRASE)
    return target


def test_corrupt_late_stage_file_publishes_no_earlier_restore_artifact(
    server, tmp_path, monkeypatch
):
    bundle, _key, _context = _bundle(server)
    target = _target(tmp_path, server[3])
    recover = restore_module.recover_empty_restore

    def stop_after_journal(_settings):
        raise OSError("synthetic stop after journal promotion")

    with monkeypatch.context() as scoped:
        scoped.setattr(restore_module, "recover_empty_restore", stop_after_journal)
        with pytest.raises(OSError, match="after journal promotion"):
            restore_module.restore_empty(target, bundle, PASSPHRASE)

    stage = next(path for path in target.data_dir.glob(".restore-*") if path.is_dir())
    (stage / "larenor.sqlite3").write_bytes(b"corrupt staged database")

    with pytest.raises(StartupError, match="^restore_recovery_invalid$"):
        recover(target)

    assert not target.key_file.exists()
    assert not (target.data_dir / "family-board.sqlite3").exists()
    assert not target.database_file.exists()
    assert (target.data_dir / ".restore-state.json").exists()


@pytest.mark.parametrize(
    "marker_state",
    ("wrong-content", "symlink", "public-permissions"),
)
def test_invalid_existing_marker_is_rejected_before_any_restore_publication(
    server, tmp_path, monkeypatch, marker_state
):
    target = _journaled_restore(server, tmp_path, monkeypatch)
    marker = target.data_dir / ".initialized"
    if marker_state == "wrong-content":
        private_create(marker, b"unexpected-marker\n")
    elif marker_state == "symlink":
        external = (tmp_path / "external-marker").resolve()
        private_create(external, b"larenor-schema-1\n")
        marker.symlink_to(external)
    else:
        private_create(marker, b"larenor-schema-1\n")
        marker.chmod(0o644)

    with pytest.raises(StartupError, match="^restore_recovery_invalid$"):
        restore_module.recover_empty_restore(target)

    assert not target.key_file.exists()
    assert not (target.data_dir / "family-board.sqlite3").exists()
    assert not target.database_file.exists()
    assert (target.data_dir / ".restore-state.json").exists()
