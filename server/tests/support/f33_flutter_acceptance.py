"""Actual Flutter cooking Client against normal Core TCP across restart."""

from pathlib import Path
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from conftest import ready, server as core_fixture
from support.installed_core_tcp import InstalledCoreTcp


def main():
    with tempfile.TemporaryDirectory(prefix="larenor-f33-client-") as root:
        state_file = Path(root) / "client-state.json"
        for phase in ("prepare", "restart"):
            generator = core_fixture.__wrapped__(Path(root))
            fixture = next(generator)
            try:
                if phase == "prepare":
                    ready(fixture)
                with InstalledCoreTcp(fixture[0]) as tcp:
                    result = subprocess.run(
                        [
                            "flutter",
                            "test",
                            "test/features/cooking_assistant/"
                            "cooking_assistant_normal_core_test.dart",
                        ],
                        env={
                            **os.environ,
                            "LARENOR_COOKING_CORE_URL":
                                f"http://127.0.0.1:{tcp.port}",
                            "LARENOR_COOKING_PHASE": phase,
                            "LARENOR_COOKING_STATE_FILE": str(state_file),
                        },
                        cwd=Path(__file__).resolve().parents[3],
                        check=False,
                    )
                    if result.returncode:
                        return result.returncode
            finally:
                generator.close()
        if not state_file.is_file() or state_file.stat().st_size > 4096:
            raise RuntimeError("cooking_client_state_invalid")
    return 0


if __name__ == "__main__":
    sys.exit(main())
