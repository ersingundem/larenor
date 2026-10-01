"""Actual F14 Flutter Client against normal Core TCP across restart."""

from contextlib import ExitStack
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from conftest import ready, server as core_fixture
from support.installed_core_tcp import InstalledCoreTcp


def _private_file(path: Path) -> None:
    descriptor = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    os.close(descriptor)


def _flutter(
    primary: InstalledCoreTcp,
    *,
    alternate: InstalledCoreTcp | None,
    phase: str,
    session_file: Path,
    checkpoint_file: Path,
) -> int:
    environment = {
        **os.environ,
        "LARENOR_F14_CORE_URL": f"http://127.0.0.1:{primary.port}",
        "LARENOR_F14_PHASE": phase,
        "LARENOR_F14_SESSION_FILE": str(session_file),
        "LARENOR_F14_CHECKPOINT_FILE": str(checkpoint_file),
    }
    if alternate is not None:
        environment["LARENOR_F14_ALTERNATE_CORE_URL"] = (
            f"http://127.0.0.1:{alternate.port}"
        )
    return subprocess.run(
        [
            "flutter",
            "test",
            "--no-pub",
            "test/features/server/server_support_sessions_normal_core_test.dart",
        ],
        cwd=Path(__file__).resolve().parents[3],
        env=environment,
        check=False,
    ).returncode


def _generator(root: Path):
    generator = core_fixture.__wrapped__(root)
    fixture = next(generator)
    # The production Client computes the requested bounded expiry from its
    # wall clock. Keep the owned Core clock on that same real-time domain.
    fixture[3].now = time.time()
    return generator, fixture


def _validate_private_file(path: Path, *, maximum: int) -> None:
    status = path.stat()
    if not stat.S_ISREG(status.st_mode) or stat.S_IMODE(status.st_mode) != 0o600:
        raise RuntimeError("f14_private_file_invalid")
    if status.st_size < 1 or status.st_size > maximum:
        raise RuntimeError("f14_private_file_invalid")


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="larenor-f14-client-") as raw_root:
        root = Path(raw_root)
        os.chmod(root, 0o700)
        session_file = root / "account-session.json"
        checkpoint_file = root / "support-checkpoint.json"
        _private_file(session_file)
        _private_file(checkpoint_file)

        for phase in ("prepare", "restart"):
            primary_generator, primary_fixture = _generator(root / "primary")
            alternate_generator = None
            try:
                if phase == "prepare":
                    ready(primary_fixture)
                    alternate_generator, alternate_fixture = _generator(
                        root / "alternate"
                    )
                    ready(alternate_fixture)
                with ExitStack() as stack:
                    primary = stack.enter_context(
                        InstalledCoreTcp(primary_fixture[0])
                    )
                    alternate = (
                        stack.enter_context(InstalledCoreTcp(alternate_fixture[0]))
                        if phase == "prepare"
                        else None
                    )
                    result = _flutter(
                        primary,
                        alternate=alternate,
                        phase=phase,
                        session_file=session_file,
                        checkpoint_file=checkpoint_file,
                    )
                    if result:
                        return result
            finally:
                if alternate_generator is not None:
                    alternate_generator.close()
                primary_generator.close()

        _validate_private_file(session_file, maximum=16_384)
        _validate_private_file(checkpoint_file, maximum=4096)
        checkpoint = json.loads(checkpoint_file.read_text(encoding="utf-8"))
        if set(checkpoint) != {"schemaVersion", "primarySessionId"}:
            raise RuntimeError("f14_checkpoint_invalid")
        if checkpoint["schemaVersion"] != 1 or not isinstance(
            checkpoint["primarySessionId"], str
        ):
            raise RuntimeError("f14_checkpoint_invalid")
        if len(checkpoint["primarySessionId"]) != 32:
            raise RuntimeError("f14_checkpoint_invalid")
    return 0


if __name__ == "__main__":
    sys.exit(main())
