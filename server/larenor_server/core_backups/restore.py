"""Offline, crash-recoverable restore into an empty Larenor Core target."""

import fcntl
import hashlib
import json
import os
import re
import secrets
import shutil
from dataclasses import replace
from pathlib import Path

from ..config import Settings
from ..errors import ApiError, StartupError
from ..files import (
    checked_path,
    private_create,
    private_directory,
    private_read,
    sync_directory,
)
from ..legal import server_version
from .service import (
    MAX_BUNDLE_BYTES,
    MAX_FAMILY_BOARD_BYTES,
    _open_authenticated_bundle,
    _validate_payload_contract,
)

_JOURNAL = ".restore-state.json"
_SNAPSHOT = re.compile(r"^[0-9a-f]{32}$")
_EXPECTED_SCHEMA = 3


def _digest(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def _paths(settings: Settings, snapshot_id: str):
    stage_dir = settings.data_dir / f".restore-{snapshot_id}"
    stage_key = settings.key_file.parent / f".restore-{snapshot_id}.key"
    return stage_dir, stage_key, settings.data_dir / _JOURNAL


def _read_journal(settings: Settings) -> dict | None:
    path = settings.data_dir / _JOURNAL
    if not path.exists():
        return None
    try:
        value = json.loads(private_read(path, 1024))
    except (OSError, UnicodeError, ValueError, StartupError):
        raise StartupError("restore_recovery_invalid") from None
    if type(value) is not dict or value.get("version") not in (1, 2):
        raise StartupError("restore_recovery_invalid")
    expected = {"version", "snapshotId", "databaseSha256", "keySha256"}
    if value["version"] == 2:
        expected.add("familyBoardSha256")
    if (
        set(value) != expected
        or type(value["snapshotId"]) is not str
        or not _SNAPSHOT.fullmatch(value["snapshotId"])
        or any(
            type(value[name]) is not str
            or not re.fullmatch(r"[0-9a-f]{64}", value[name])
            for name in expected - {"version", "snapshotId"}
        )
    ):
        raise StartupError("restore_recovery_invalid")
    return value


def _verify_file(path: Path, maximum: int, digest: str) -> bytes:
    try:
        value = private_read(path, maximum)
    except (OSError, StartupError):
        raise StartupError("restore_recovery_invalid") from None
    if not secrets.compare_digest(_digest(value), digest):
        raise StartupError("restore_recovery_invalid")
    return value


def _publish_one(stage: Path, target: Path, maximum: int, digest: str) -> None:
    if target.exists():
        _verify_file(target, maximum, digest)
        return
    _verify_file(stage, maximum, digest)
    os.replace(stage, target)
    sync_directory(target.parent)


def _cleanup_stage(stage_dir: Path, stage_key: Path) -> None:
    if stage_key.exists():
        stage_key.unlink()
        sync_directory(stage_key.parent)
    if stage_dir.exists():
        shutil.rmtree(stage_dir)
        sync_directory(stage_dir.parent)


def recover_empty_restore(settings: Settings) -> bool:
    """Finish a journaled publication before normal Core initialization."""
    journal = _read_journal(settings)
    if journal is None:
        return False
    snapshot_id = journal["snapshotId"]
    stage_dir, stage_key, journal_path = _paths(settings, snapshot_id)
    _publish_one(
        stage_key,
        settings.key_file,
        32,
        journal["keySha256"],
    )
    if journal["version"] == 2:
        _publish_one(
            stage_dir / "family-board.sqlite3",
            settings.data_dir / "family-board.sqlite3",
            MAX_FAMILY_BOARD_BYTES,
            journal["familyBoardSha256"],
        )
    _publish_one(
        stage_dir / "larenor.sqlite3",
        settings.database_file,
        MAX_BUNDLE_BYTES,
        journal["databaseSha256"],
    )
    marker = settings.data_dir / ".initialized"
    if not marker.exists():
        private_create(marker, b"larenor-schema-1\n")
    elif private_read(marker, 64) != b"larenor-schema-1\n":
        raise StartupError("restore_recovery_invalid")
    # Keep the journal authoritative until every staged artifact is gone.
    # If cleanup is interrupted, the next startup verifies both published
    # files and retries cleanup instead of orphaning private stage data.
    _cleanup_stage(stage_dir, stage_key)
    journal_path.unlink()
    sync_directory(settings.data_dir)
    return True


def _validate_capture(capture) -> None:
    manifest = capture.manifest
    if (
        manifest.contractVersion not in (1, 2)
        or manifest.coreVersion != server_version()
        or manifest.databaseSchemaVersion != _EXPECTED_SCHEMA
    ):
        raise ApiError("backup_incompatible", 409)
    try:
        _validate_payload_contract(capture)
    except ValueError:
        raise ApiError("backup_incompatible", 409) from None
    # Component payloads can be authenticated and compatibility-checked, but
    # this slice deliberately has no host-volume publication authority.
    if manifest.components:
        raise ApiError("backup_incompatible", 409)


def restore_empty(settings: Settings, bundle: bytes, passphrase: str) -> str:
    """Validate off-target, then journal and publish every captured resource."""
    checked_path(settings.data_dir)
    checked_path(settings.key_file)
    if settings.key_file.is_relative_to(settings.data_dir):
        raise StartupError("vault_key_must_be_outside_data_directory")
    private_directory(settings.data_dir)
    private_directory(settings.key_file.parent)
    lock_path = settings.data_dir / ".initialize.lock"
    try:
        private_create(lock_path, b"")
    except FileExistsError:
        private_read(lock_path, 0)
    with lock_path.open("rb") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if _read_journal(settings) is not None:
            raise StartupError("restore_already_in_progress")
        marker = settings.data_dir / ".initialized"
        unexpected = [
            entry for entry in settings.data_dir.iterdir()
            if entry.name != lock_path.name
        ]
        if (
            unexpected
            or settings.database_file.exists()
            or settings.key_file.exists()
            or marker.exists()
        ):
            raise StartupError("restore_target_not_empty")

        capture = _open_authenticated_bundle(bundle, passphrase)
        _validate_capture(capture)
        snapshot_id = capture.manifest.snapshotId
        stage_dir, stage_key, journal_path = _paths(settings, snapshot_id)
        if stage_dir.exists() or stage_key.exists():
            raise StartupError("restore_stage_exists")
        try:
            private_directory(stage_dir)
            private_create(
                stage_dir / "larenor.sqlite3",
                capture.payloads["core-database"],
            )
            if capture.manifest.contractVersion == 2:
                private_create(
                    stage_dir / "family-board.sqlite3",
                    capture.payloads["family-board"],
                )
            private_create(stage_key, capture.payloads["vault-key"])

            # Construct every Core service against the staged pair. This checks
            # key binding, SQLite integrity, schemas and encrypted records.
            from ..app import create_app

            staged = replace(
                settings,
                data_dir=stage_dir,
                key_file=stage_key,
                bootstrap_file=stage_dir / "bootstrap-admin.txt",
            )
            app = create_app(staged)
            if app.state.core.bootstrap_created:
                raise StartupError("restore_validation_failed")
            with app.state.core.db.connection() as connection:
                if connection.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchone()[0]:
                    raise StartupError("restore_validation_failed")

            database = private_read(
                stage_dir / "larenor.sqlite3", MAX_BUNDLE_BYTES
            )
            key = private_read(stage_key, 32)
            family_board = (
                private_read(stage_dir / "family-board.sqlite3", MAX_FAMILY_BOARD_BYTES)
                if capture.manifest.contractVersion == 2
                else None
            )
        except Exception:
            _cleanup_stage(stage_dir, stage_key)
            raise
        journal = {
            "version": capture.manifest.contractVersion,
            "snapshotId": snapshot_id,
            "databaseSha256": _digest(database),
            "keySha256": _digest(key),
        }
        if family_board is not None:
            journal["familyBoardSha256"] = _digest(family_board)
        # A failed write must not leave a partial recovery journal alongside
        # private staged bytes. Publish the fully synced journal atomically;
        # once it exists, startup owns recovery even if directory sync fails.
        staged_journal = stage_dir / "restore-journal.json"
        try:
            private_create(
                staged_journal,
                json.dumps(journal, sort_keys=True, separators=(",", ":")).encode(),
            )
            os.replace(staged_journal, journal_path)
        except Exception:
            if not journal_path.exists():
                _cleanup_stage(stage_dir, stage_key)
            raise
        sync_directory(settings.data_dir)
        recover_empty_restore(settings)
        return snapshot_id
