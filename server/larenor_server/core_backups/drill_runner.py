import json
import os
import stat
import tempfile
import time
import zipfile
from dataclasses import replace
from pathlib import Path, PurePosixPath

from ..files import private_create, private_directory, private_read
from .drill_models import RecoveryDrillExecution
from .models import MAX_COMPONENT_BYTES, MAX_COMPONENT_VOLUME_BYTES, MAX_DATABASE_BYTES
from .service import _validate_payload_contract


_INITIALIZED_MARKER = b"larenor-schema-1\n"
_MAX_ARCHIVE_ENTRIES = 10_000


class _DrillFailure(RuntimeError):
    def __init__(self, code, verified=()):
        self.code, self.verified = code, tuple(verified)
        super().__init__(code)


def _gate(deadline, cancelled):
    if cancelled():
        raise _DrillFailure("cancelled")
    if time.monotonic() >= deadline:
        raise _DrillFailure("deadline_exceeded")


def _isolated_settings(settings, root):
    data = root / "data"
    keys = root / "keys"
    private_directory(data)
    private_directory(keys)
    return replace(
        settings,
        data_dir=data,
        key_file=keys / "vault.key",
        bootstrap_file=data / "bootstrap-admin.txt",
        plugin_worker_socket=None,
        plugin_worker_uid=0,
        installation_worker_socket=None,
        installation_worker_uid=0,
        proxmox_power_worker_socket=None,
        proxmox_power_worker_health=None,
        proxmox_power_worker_uid=0,
        keenetic_worker_socket=None,
        keenetic_worker_health=None,
        keenetic_worker_key_file=None,
        keenetic_worker_uid=0,
        component_backup_worker_socket=None,
        component_backup_worker_uid=0,
    )


def _safe_member(info):
    try:
        path = PurePosixPath(info.filename)
        mode = info.external_attr >> 16
        return bool(
            info.filename
            and not path.is_absolute()
            and ".." not in path.parts
            and all(part not in {"", "."} for part in path.parts)
            and (stat.S_ISREG(mode) or stat.S_ISDIR(mode))
        )
    except (AttributeError, TypeError, ValueError):
        return False


def _restore_component_archive(payload, target, deadline, cancelled):
    if type(payload) is not bytes or not 1 <= len(payload) <= MAX_COMPONENT_VOLUME_BYTES:
        raise _DrillFailure("restore_failed")
    private_directory(target)
    try:
        from io import BytesIO

        with zipfile.ZipFile(BytesIO(payload), "r") as archive:
            entries = archive.infolist()
            if not entries or len(entries) > _MAX_ARCHIVE_ENTRIES:
                raise _DrillFailure("restore_failed")
            total = 0
            seen = set()
            for info in entries:
                _gate(deadline, cancelled)
                if not _safe_member(info) or info.filename in seen:
                    raise _DrillFailure("restore_failed")
                seen.add(info.filename)
                total += info.file_size
                if total > MAX_COMPONENT_VOLUME_BYTES:
                    raise _DrillFailure("restore_failed")
                relative = PurePosixPath(info.filename)
                destination = target.joinpath(*relative.parts)
                if info.is_dir():
                    private_directory(destination)
                    continue
                private_directory(destination.parent)
                private_create(destination, archive.read(info))
    except _DrillFailure:
        raise
    except (OSError, RuntimeError, ValueError, zipfile.BadZipFile):
        raise _DrillFailure("restore_failed") from None


class IsolatedRecoveryDrillRunner:
    """Restore only into an ephemeral tree with every production effect absent."""

    def __init__(self, contract):
        self.contract = contract

    def execute(self, authority, *, deadline, cancelled):
        verified = []
        try:
            _gate(deadline, cancelled)
            try:
                capture = self.contract.capture_for_drill(authority)
                _validate_payload_contract(capture)
            except _DrillFailure:
                raise
            except Exception:
                raise _DrillFailure("backup_failed", verified) from None
            _gate(deadline, cancelled)
            with tempfile.TemporaryDirectory(prefix="larenor-recovery-drill-") as raw:
                root = Path(raw).resolve(strict=True)
                os.chmod(root, 0o700)
                settings = _isolated_settings(self.contract.settings, root)
                try:
                    private_create(
                        settings.database_file,
                        capture.payloads["core-database"],
                    )
                    verified.append("coreDatabase")
                    _gate(deadline, cancelled)
                    private_create(settings.key_file, capture.payloads["vault-key"])
                    verified.append("vaultKey")
                    configuration = json.loads(capture.payloads["core-configuration"])
                    if (
                        type(configuration) is not dict
                        or configuration.get("contractVersion") != 1
                        or set(configuration) != {"contractVersion", "workers"}
                        or type(configuration["workers"]) is not dict
                    ):
                        raise _DrillFailure("restore_failed", verified)
                    verified.append("configuration")
                    _gate(deadline, cancelled)
                    private_create(
                        settings.data_dir / "family-board.sqlite3",
                        capture.payloads["family-board"],
                    )
                    verified.append("familyBoard")
                    private_create(settings.data_dir / ".initialized", _INITIALIZED_MARKER)

                    component_total = 0
                    component_root = root / "components"
                    for component in capture.manifest.components:
                        for resource_id in component.volumeResourceIds:
                            _gate(deadline, cancelled)
                            payload = capture.payloads[resource_id]
                            component_total += len(payload)
                            if component_total > MAX_COMPONENT_BYTES:
                                raise _DrillFailure("restore_failed", verified)
                            _restore_component_archive(
                                payload,
                                component_root / resource_id,
                                deadline,
                                cancelled,
                            )
                    verified.append("componentData")
                    _gate(deadline, cancelled)

                    from ..app import create_app

                    app = create_app(settings)
                    if app.state.core.bootstrap_created:
                        raise _DrillFailure("health_check_failed", verified)
                    with app.state.core.db.connection() as connection:
                        if connection.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
                            raise _DrillFailure("health_check_failed", verified)
                    if len(private_read(settings.database_file, MAX_DATABASE_BYTES)) < 20:
                        raise _DrillFailure("health_check_failed", verified)
                    _gate(deadline, cancelled)
                except _DrillFailure:
                    raise
                except Exception:
                    raise _DrillFailure("restore_failed", verified) from None
                finally:
                    # TemporaryDirectory owns deletion. Explicitly clear any
                    # read-only mode that a restored directory might carry.
                    for directory, names, _files in os.walk(root):
                        for name in names:
                            try:
                                os.chmod(Path(directory) / name, 0o700)
                            except OSError:
                                pass
            return RecoveryDrillExecution(
                succeeded=True,
                verifiedResources=verified,
            )
        except _DrillFailure as error:
            return RecoveryDrillExecution(
                succeeded=False,
                verifiedResources=list(error.verified or verified),
                failureCode=error.code,
            )
        finally:
            # Avoid retaining authenticated resource bytes on the runner.
            if "capture" in locals():
                capture = None
