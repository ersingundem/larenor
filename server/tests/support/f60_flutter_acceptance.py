"""Normal TCP Core acceptance for the F60 Flutter v2 orchestration."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from conftest import ready, server as core_fixture
from support.installed_core_tcp import InstalledCoreTcp


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="larenor-f60-client-") as root:
        generator = core_fixture.__wrapped__(Path(root))
        fixture = next(generator)
        try:
            ready(fixture)
            with InstalledCoreTcp(fixture[0]) as tcp:
                result = subprocess.run(
                    [
                        "flutter",
                        "test",
                        "--no-pub",
                        "test/features/game_streaming/"
                        "game_stream_v2_normal_core_test.dart",
                    ],
                    cwd=Path(__file__).resolve().parents[3],
                    env={
                        **os.environ,
                        "LARENOR_F60_CORE_URL": f"http://127.0.0.1:{tcp.port}",
                        "LARENOR_F60_NOW_MS": str(round(fixture[3].now * 1000)),
                    },
                    timeout=120,
                    check=False,
                )
                return result.returncode
        finally:
            generator.close()


if __name__ == "__main__":
    sys.exit(main())
