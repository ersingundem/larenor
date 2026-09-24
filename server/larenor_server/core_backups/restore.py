"""Offline, crash-recoverable restore into an empty Larenor Core target."""

import fcntl
import hashlib
import json
import os
import re
import secrets
import shutil
import stat
from contextlib import contextmanager
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
    MAX_DATABASE_BYTES,
    MAX_FAMILY_BOARD_BYTES,
    _open_authenticated_bundle,
    _validate_payload_contract,
)

_JOURNAL = ".restore-state.json"
_INITIALIZED_MARKER = b"larenor-schema-1\n"
_SNAPSHOT = re.compile(r"^[0-9a-f]{32}$")
_EXPECTED_SCHEMA = 3


def _digest(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


@contextmanager
def _open_restore_lock(path: Path):
    """Acquire one verified private lock descriptor without reopening it."""

    def valid(info):
        return (
            stat.S_ISREG(info.st_mode)
            and info.st_uid == os.geteuid()
            and stat.S_IMODE(info.st_mode) == 0o600
            and info.st_nlink == 1
        )

    descriptor = -1
    try:
        descriptor = os.open(
            path,
            os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC,
        )
        info = os.fstat(descriptor)
        if not valid(info):
            raise ValueError("invalid_restore_lock")
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        current = os.stat(path, follow_symlinks=False)
        if not valid(current) or (current.st_dev, current.st_ino) != (
            info.st_dev,
            info.st_ino,
        ):
            raise ValueError("replaced_restore_lock")
    except (OSError, ValueError):
        if descriptor >= 0:
            os.close(descriptor)
        raise StartupError("restore_lock_invalid") from None
    try:
        yield descriptor
    finally:
        os.close(descriptor)


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
    if "componentState" in value:
        expected.add("componentState")
    if (
        set(value) != expected
        or type(value["snapshotId"]) is not str
        or not _SNAPSHOT.fullmatch(value["snapshotId"])
        or any(
            type(value[name]) is not str
            or not re.fullmatch(r"[0-9a-f]{64}", value[name])
            for name in expected - {"version", "snapshotId"} - {"componentState"}
        )
        or "componentState" in value
        and value["componentState"] not in {"pending", "released"}
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


def _verify_initialized_marker(settings: Settings) -> bool:
    marker = settings.data_dir / ".initialized"
    if not os.path.lexists(marker):
        return False
    try:
        if private_read(marker, 64) != _INITIALIZED_MARKER:
            raise ValueError("invalid_marker")
    except (OSError, StartupError, ValueError):
        raise StartupError("restore_recovery_invalid") from None
    return True


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
    if journal.get("componentState") == "pending":
        raise StartupError("restore_components_pending")
    snapshot_id = journal["snapshotId"]
    stage_dir, stage_key, journal_path = _paths(settings, snapshot_id)
    marker_exists = _verify_initialized_marker(settings)
    artifacts = [
        (stage_key, settings.key_file, 32, journal["keySha256"]),
    ]
    if journal["version"] == 2:
        artifacts.append(
            (
                stage_dir / "family-board.sqlite3",
                settings.data_dir / "family-board.sqlite3",
                MAX_FAMILY_BOARD_BYTES,
                journal["familyBoardSha256"],
            )
        )
    artifacts.append(
        (
            stage_dir / "larenor.sqlite3",
            settings.database_file,
            MAX_DATABASE_BYTES,
            journal["databaseSha256"],
        )
    )
    # Verify every late artifact before publishing the first one. Recovery
    # keeps the journal authoritative on failure, but must not create a new
    # partial target when a later staged file is already corrupt or missing.
    for stage, target, maximum, digest in artifacts:
        _verify_file(target if target.exists() else stage, maximum, digest)
    for stage, target, maximum, digest in artifacts:
        _publish_one(stage, target, maximum, digest)
    marker = settings.data_dir / ".initialized"
    if not marker_exists:
        try:
            private_create(marker, _INITIALIZED_MARKER)
        except FileExistsError:
            _verify_initialized_marker(settings)
    else:
        _verify_initialized_marker(settings)
    # Keep the journal authoritative until every staged artifact is gone.
    # If cleanup is interrupted, the next startup verifies both published
    # files and retries cleanup instead of orphaning private stage data.
    _cleanup_stage(stage_dir, stage_key)
    journal_path.unlink()
    sync_directory(settings.data_dir)
    return True


def _worker_topology(settings: Settings) -> dict[str, bool]:
    return {
        "installation": settings.installation_worker_socket is not None,
        "keenetic": settings.keenetic_worker_socket is not None,
        "plugin": settings.plugin_worker_socket is not None,
        "proxmox": settings.proxmox_power_worker_socket is not None,
    }


def _validate_capture(capture, settings: Settings, *, allow_components=False) -> None:
    manifest = capture.manifest
    if (
        manifest.contractVersion not in (1, 2)
        or manifest.coreVersion != server_version()
        or manifest.databaseSchemaVersion != _EXPECTED_SCHEMA
    ):
        raise ApiError("backup_incompatible", 409)
    try:
        _validate_payload_contract(capture)
        configuration = json.loads(capture.payloads["core-configuration"])
        if configuration["workers"] != _worker_topology(settings):
            raise ValueError("worker_topology_mismatch")
    except (KeyError, TypeError, UnicodeError, ValueError):
        raise ApiError("backup_incompatible", 409) from None
    # Component payloads can be authenticated and compatibility-checked, but
    # this slice deliberately has no host-volume publication authority.
    if manifest.components and allow_components is not True:
        raise ApiError("backup_incompatible", 409)


def _replace_journal(settings, snapshot_id, journal):
    stage_dir, _stage_key, journal_path = _paths(settings, snapshot_id)
    staged_journal = stage_dir / "restore-journal.json"
    private_create(
        staged_journal,
        json.dumps(journal, sort_keys=True, separators=(",", ":")).encode(),
    )
    os.replace(staged_journal, journal_path)
    sync_directory(settings.data_dir)


def _component_checkpoint(settings, snapshot_id):
    def checkpoint(state):
        if type(state) is not dict or state.get("phase") != "released":
            return
        journal = _read_journal(settings)
        if (
            journal is None
            or journal.get("snapshotId") != snapshot_id
            or journal.get("componentState") not in {"pending", "released"}
        ):
            raise StartupError("restore_recovery_invalid")
        if journal["componentState"] == "released":
            return
        _replace_journal(
            settings,
            snapshot_id,
            {**journal, "componentState": "released"},
        )

    return checkpoint


def restore_empty(
    settings: Settings,
    bundle: bytes,
    passphrase: str,
    *,
    component_runtime=None,
    deadline=None,
) -> str:
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
        pass
    with _open_restore_lock(lock_path):
        capture = _open_authenticated_bundle(bundle, passphrase)
        has_components = bool(capture.manifest.components)
        if has_components and (
            component_runtime is None
            or not callable(getattr(component_runtime, "restore", None))
            or not callable(getattr(component_runtime, "recover", None))
            or not callable(
                getattr(getattr(component_runtime, "journal", None), "exists", None)
            )
            or type(deadline) not in (int, float)
            or type(deadline) is bool
        ):
            raise StartupError("component_restore_unavailable")
        _validate_capture(
            capture,
            settings,
            allow_components=has_components and component_runtime is not None,
        )
        existing = _read_journal(settings)
        if existing is not None:
            if (
                not has_components
                or existing.get("componentState") not in {"pending", "released"}
                or existing["snapshotId"] != capture.manifest.snapshotId
            ):
                raise StartupError("restore_already_in_progress")
            checkpoint = _component_checkpoint(settings, existing["snapshotId"])
            if existing["componentState"] == "pending":
                if component_runtime.journal.exists():
                    component_runtime.recover(
                        capture, deadline=deadline, checkpoint=checkpoint
                    )
                else:
                    component_runtime.restore(
                        capture, deadline=deadline, checkpoint=checkpoint
                    )
            decided = _read_journal(settings)
            if decided is None or decided.get("componentState") != "released":
                raise StartupError("restore_components_pending")
            recover_empty_restore(settings)
            return existing["snapshotId"]
        marker = settings.data_dir / ".initialized"
        unexpected = [
            entry
            for entry in settings.data_dir.iterdir()
            if entry.name != lock_path.name
        ]
        if (
            unexpected
            or settings.database_file.exists()
            or settings.key_file.exists()
            or marker.exists()
        ):
            raise StartupError("restore_target_not_empty")

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

            database = private_read(stage_dir / "larenor.sqlite3", MAX_DATABASE_BYTES)
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
        if has_components:
            journal["componentState"] = "pending"
        # A failed write must not leave a partial recovery journal alongside
        # private staged bytes. Publish the fully synced journal atomically;
        # once it exists, startup owns recovery even if directory sync fails.
        try:
            _replace_journal(settings, snapshot_id, journal)
        except Exception:
            if not journal_path.exists():
                _cleanup_stage(stage_dir, stage_key)
            raise
        if has_components:
            component_runtime.restore(
                capture,
                deadline=deadline,
                checkpoint=_component_checkpoint(settings, snapshot_id),
            )
            decided = _read_journal(settings)
            if decided is None or decided.get("componentState") != "released":
                raise StartupError("restore_components_pending")
        recover_empty_restore(settings)
        return snapshot_id
