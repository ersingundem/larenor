"""Actual floor-plan Client/editor against normal Core TCP, including restart."""

from pathlib import Path
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from conftest import server as core_fixture
from support.installed_core_tcp import InstalledCoreTcp
from test_home_assistant_adapter import ha as ha_fixture, setup, bind


def main():
    with tempfile.TemporaryDirectory(prefix="larenor-f51-client-") as root:
        ha_generator = ha_fixture.__wrapped__()
        provider = next(ha_generator)
        try:
            for phase in ("save", "restart"):
                generator = core_fixture.__wrapped__(Path(root))
                fixture = next(generator)
                try:
                    if phase == "save":
                        app, client, pair, _resource, _service, base, _url, body = setup(
                            fixture, provider
                        )
                        bind(client, pair, base, body)
                        headers = {"Authorization": "Bearer " + pair["accessToken"]}
                        context = app.state.core.context
                        registry = ("/api/v1/admin/home-resources/"
                                    + context.coreId + "/" + context.homeId)
                        response = client.post(registry, headers=headers, json={
                            "kind": "room", "label": "Living room", "order": 0,
                        })
                        if response.status_code != 201:
                            raise RuntimeError("floor_plan_inventory_setup_failed")
                    with InstalledCoreTcp(fixture[0]) as tcp:
                        result = subprocess.run([
                            "flutter", "test", "--no-pub", "test/features/floor_plan/"
                            "floor_plan_normal_core_test.dart",
                        ], env={**os.environ,
                                "LARENOR_FLOOR_PLAN_CORE_URL":
                                    f"http://127.0.0.1:{tcp.port}",
                                "LARENOR_FLOOR_PLAN_PHASE": phase},
                            cwd=Path(__file__).resolve().parents[3], check=False)
                        if result.returncode:
                            return result.returncode
                finally:
                    generator.close()
            if provider.command_calls != 1 or provider.state != "on":
                raise RuntimeError("floor_plan_exact_ha_effect_failed")
        finally:
            ha_generator.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
