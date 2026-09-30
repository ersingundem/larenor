"""Actual Flutter -> normal Core TCP RDP/VNC authority/store gate."""

from pathlib import Path
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from conftest import ready, server as core_fixture
from support.installed_core_tcp import InstalledCoreTcp


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="larenor-f61-f62-core-") as root:
        generator = core_fixture.__wrapped__(Path(root))
        fixture = next(generator)
        try:
            ready(fixture)
            with InstalledCoreTcp(fixture[0]) as tcp:
                result = subprocess.run(
                    [
                        "flutter", "test", "--no-pub",
                        "test/features/remote_access/"
                        "core_managed_desktop_normal_core_test.dart",
                    ],
                    cwd=Path(__file__).resolve().parents[3],
                    env={
                        **os.environ,
                        "LARENOR_F61_F62_CORE_URL":
                            f"http://127.0.0.1:{tcp.port}",
                    },
                    timeout=60,
                    check=False,
                )
                return result.returncode
        finally:
            generator.close()


if __name__ == "__main__":
    sys.exit(main())
