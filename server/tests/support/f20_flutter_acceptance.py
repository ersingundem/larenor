"""Actual F20 Flutter Client and normal Core TCP audit acceptance."""

from pathlib import Path
import os
import subprocess
import sys
import tempfile

from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from conftest import ready, server as core_fixture
from larenor_server.app import create_app
from larenor_server.database import Database
from larenor_server.errors import StartupError
from support.installed_core_tcp import InstalledCoreTcp


def _flutter(fixture, checkpoint_file, phase):
    with InstalledCoreTcp(fixture[0]) as tcp:
        return subprocess.run(
            [
                "flutter",
                "test",
                "--no-pub",
                "test/features/core_audit/core_audit_normal_core_test.dart",
            ],
            env={
                **os.environ,
                "LARENOR_CORE_AUDIT_URL": f"http://127.0.0.1:{tcp.port}",
                "LARENOR_CORE_AUDIT_PHASE": phase,
                "LARENOR_CORE_AUDIT_CHECKPOINT": str(checkpoint_file),
            },
            cwd=Path(__file__).resolve().parents[3],
            check=False,
        ).returncode


def _tamper_must_not_reset(settings):
    database = Database(settings.database_file)
    with database.transaction() as connection:
        row = connection.execute(
            "SELECT id,actor_id FROM admin_audit ORDER BY id LIMIT 1"
        ).fetchone()
        if row is None:
            raise RuntimeError("audit_tamper_fixture_missing")
        replacement = "f" * 32 if row["actor_id"] != "f" * 32 else "e" * 32
        connection.execute(
            "UPDATE admin_audit SET actor_id=? WHERE id=?",
            (replacement, row["id"]),
        )
    with database.connection() as connection:
        before = tuple(connection.iterdump())
    try:
        with TestClient(create_app(settings)):
            pass
    except StartupError as error:
        if str(error) != "core_audit_storage_invalid":
            raise
    else:
        raise RuntimeError("tampered_audit_started")
    with database.connection() as connection:
        after = tuple(connection.iterdump())
    if after != before:
        raise RuntimeError("tampered_audit_silently_changed")
    if settings.effective_bootstrap_file.exists():
        raise RuntimeError("tampered_audit_bootstrap_recreated")


def main():
    with tempfile.TemporaryDirectory(prefix="larenor-f20-client-") as root:
        root = Path(root)
        checkpoint_file = root / "device-checkpoint.json"
        settings = None
        for phase in ("pin-rotate", "restart"):
            generator = core_fixture.__wrapped__(root)
            fixture = next(generator)
            try:
                if phase == "pin-rotate":
                    ready(fixture)
                settings = fixture[2]
                result = _flutter(fixture, checkpoint_file, phase)
                if result:
                    return result
            finally:
                generator.close()
        if settings is None or not checkpoint_file.is_file():
            raise RuntimeError("audit_checkpoint_missing")
        if not 1 <= checkpoint_file.stat().st_size <= 8192:
            raise RuntimeError("audit_checkpoint_invalid")
        _tamper_must_not_reset(settings)
    return 0


if __name__ == "__main__":
    sys.exit(main())
