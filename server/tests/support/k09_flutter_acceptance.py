"""Actual Kiosk route -> normal Core authority -> owned TLS MQTT acceptance."""

from pathlib import Path
import os
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from conftest import auth, ready, server as core_fixture
from support.installed_core_tcp import InstalledCoreTcp


DEVICE_ID = "09" * 16


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="larenor-k09-core-") as temporary:
        generator = core_fixture.__wrapped__(Path(temporary))
        fixture = next(generator)
        try:
            app, client, _settings, clock = fixture
            clock.now = time.time()
            administrator = ready(fixture)
            context = app.state.core.context
            device = client.post(
                f"/api/v1/tablet-fleet/{context.coreId}/{context.homeId}/devices",
                headers=auth(administrator),
                json={
                    "schemaVersion": 1,
                    "registrationId": DEVICE_ID,
                    "name": "K09 controlled-view tablet",
                    "platform": "android",
                    "managementMode": "standard",
                    "clientVersion": "1.0.0+1",
                    "appliedProfileRevision": 1,
                },
            )
            if device.status_code != 201:
                raise RuntimeError(f"k09_device_setup_failed:{device.status_code}")
            with InstalledCoreTcp(app) as tcp:
                result = subprocess.run(
                    [
                        "flutter",
                        "test",
                        "--no-pub",
                        "test/features/kiosk/kiosk_controlled_view_normal_core_test.dart",
                    ],
                    cwd=Path(__file__).resolve().parents[3],
                    env={
                        **os.environ,
                        "LARENOR_K09_CORE_URL": f"http://127.0.0.1:{tcp.port}",
                    },
                    check=False,
                    timeout=180,
                )
            if result.returncode:
                return result.returncode
            pairings = client.get(
                f"/api/v1/admin/paired-remote/{context.coreId}/{context.homeId}/pairings",
                headers=auth(administrator),
            )
            if pairings.status_code != 200:
                raise RuntimeError("k09_pairing_readback_failed")
            values = pairings.json()["pairings"]
            if (
                len(values) != 1
                or values[0]["deviceId"] != DEVICE_ID
                or values[0]["state"] != "active"
                or values[0]["scopes"] != ["read"]
            ):
                raise RuntimeError("k09_pairing_authority_not_observed")
            return 0
        finally:
            generator.close()


if __name__ == "__main__":
    raise SystemExit(main())
