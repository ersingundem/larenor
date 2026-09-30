"""Actual Flutter -> normal Core TCP -> owned OpenSSH authority gate."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from conftest import ready, server as core_fixture
from support.installed_core_tcp import InstalledCoreTcp


def main():
    required = (
        "LARENOR_SSH_FIXTURE_PORT", "LARENOR_SSH_FIXTURE_USER",
        "LARENOR_SSH_PRIVATE_KEY", "LARENOR_SSH_KEY_PASSPHRASE",
        "LARENOR_SSH_HOST_KEY_TYPE", "LARENOR_SSH_HOST_KEY_FINGERPRINT",
        "LARENOR_F63_COMMAND_LOG", "LARENOR_SFTP_FIXTURE_ROOT",
        "LARENOR_SSH_TUNNEL_PORT", "LARENOR_SSH_TARGET_PORT",
    )
    if any(not os.environ.get(name) for name in required):
        raise RuntimeError("f63_fixture_environment_missing")
    with tempfile.TemporaryDirectory(prefix="larenor-f63-client-") as root:
        generator = core_fixture.__wrapped__(Path(root))
        fixture = next(generator)
        try:
            ready(fixture)
            state = Path(root) / "session.json"
            for phase in ("profile", "session", "cleanup"):
                with InstalledCoreTcp(fixture[0]) as tcp:
                    result = subprocess.run(
                        [
                            "flutter", "test", "--no-pub",
                            "test/features/remote_access/ssh/ssh_normal_core_test.dart",
                        ],
                        cwd=Path(__file__).resolve().parents[3],
                        env={
                            **os.environ,
                            "LARENOR_F63_CORE_URL": f"http://127.0.0.1:{tcp.port}",
                            "LARENOR_F63_PHASE": phase,
                            "LARENOR_F63_STATE_FILE": str(state),
                        },
                        timeout=90,
                        check=False,
                    )
                    if result.returncode:
                        return result.returncode
            command_log = Path(os.environ["LARENOR_F63_COMMAND_LOG"])
            if command_log.read_text(encoding="utf-8").splitlines() != [
                    "profile-drift", "session-revoke"]:
                raise RuntimeError("ssh_command_replayed_or_missing")
        finally:
            generator.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
