"""Real Flutter Client -> normal Core TCP authority around owned display IO."""

from pathlib import Path
import os
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from conftest import ready, server as core_fixture
from support.installed_core_tcp import InstalledCoreTcp


def _run_phase(root: Path, phase: str) -> int:
    generator = core_fixture.__wrapped__(root)
    fixture = next(generator)
    try:
        app, _client, _settings, clock = fixture
        pair = ready(fixture)
        context = app.state.core.context
        with tempfile.TemporaryDirectory(prefix=f"larenor-f52-{phase}-") as signals:
            signal_root = Path(signals)
            with InstalledCoreTcp(app) as tcp:
                command = [
                    "flutter",
                    "test",
                    "--no-pub",
                    "test/features/multi_display/dual_display_normal_core_test.dart",
                ]
                environment = {
                    **os.environ,
                    "LARENOR_F52_PHASE": phase,
                    "LARENOR_F52_CORE_URL": f"http://127.0.0.1:{tcp.port}",
                    "LARENOR_F52_CORE_ID": context.coreId,
                    "LARENOR_F52_HOME_ID": context.homeId,
                    "LARENOR_F52_ACCOUNT_ID": pair["user"]["id"],
                    "LARENOR_F52_FAMILY_ID": pair["sessionFamilyId"],
                    "LARENOR_F52_ACCESS_TOKEN": pair["accessToken"],
                    "LARENOR_F52_SIGNAL_ROOT": str(signal_root),
                }
                process = subprocess.Popen(
                    command,
                    cwd=Path(__file__).resolve().parents[3],
                    env=environment,
                )
                if phase == "revoked":
                    deadline = time.monotonic() + 30
                    while not (signal_root / "presented").is_file():
                        if process.poll() is not None or time.monotonic() >= deadline:
                            process.terminate()
                            process.wait(timeout=10)
                            raise RuntimeError("f52_native_boundary_not_reached")
                        time.sleep(0.02)
                    with app.state.core.db.transaction() as connection:
                        connection.execute(
                            "UPDATE session_families SET revoked_at=? WHERE id=?",
                            (clock(), pair["sessionFamilyId"]),
                        )
                    (signal_root / "continue").write_text("1")
                try:
                    return process.wait(timeout=120)
                except subprocess.TimeoutExpired:
                    process.terminate()
                    process.wait(timeout=10)
                    raise RuntimeError("f52_flutter_timeout") from None
    finally:
        generator.close()


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="larenor-f52-core-") as temporary:
        root = Path(temporary)
        for index, phase in enumerate(("success", "revoked")):
            code = _run_phase(root / str(index), phase)
            if code:
                return code
    return 0


if __name__ == "__main__":
    sys.exit(main())
