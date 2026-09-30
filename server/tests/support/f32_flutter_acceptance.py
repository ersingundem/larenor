"""Actual pantry Client against normal Core, including persistent undo replay."""

from pathlib import Path
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from conftest import ready, server as core_fixture
from support.installed_core_tcp import InstalledCoreTcp


def main():
    with tempfile.TemporaryDirectory(prefix="larenor-f32-client-") as root:
        state_file = Path(root) / "client-state.json"
        for phase in ("mutate", "restart"):
            generator = core_fixture.__wrapped__(Path(root))
            fixture = next(generator)
            try:
                if phase == "mutate":
                    ready(fixture)
                with InstalledCoreTcp(fixture[0]) as tcp:
                    result = subprocess.run([
                        "flutter", "test", "--no-pub",
                        "test/features/pantry_stock/pantry_stock_normal_core_test.dart",
                    ], env={**os.environ,
                        "LARENOR_PANTRY_CORE_URL": f"http://127.0.0.1:{tcp.port}",
                        "LARENOR_PANTRY_PHASE": phase,
                        "LARENOR_PANTRY_STATE_FILE": str(state_file)},
                        cwd=Path(__file__).resolve().parents[3],
                        timeout=120, check=False)
                    if result.returncode:
                        return result.returncode
            finally:
                generator.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
