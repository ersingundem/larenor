"""Run the real Flutter F45 client against normal Core and TCP HA/Frigate."""

from pathlib import Path
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time

import uvicorn

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from conftest import auth, ready, server as core_fixture
from support.f41_frigate_fixture import provision
from support.f45_sound_fixture import SoundFixture


def main():
    with tempfile.TemporaryDirectory(prefix="larenor-f45-client-") as root:
        generator = core_fixture.__wrapped__(Path(root))
        fixture = next(generator)
        app, client, _settings, _clock = fixture
        provider = SoundFixture()
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listener.bind(("127.0.0.1", 0))
        running = uvicorn.Server(uvicorn.Config(app, log_level="critical", access_log=False))
        thread = threading.Thread(target=lambda: running.run(sockets=[listener]), daemon=True)
        try:
            actor = ready(fixture)
            provision(client, app.state.core, actor, provider)
            scope = app.state.core.context
            created = client.post(
                f"/api/v1/admin/home-resources/{scope.coreId}/{scope.homeId}",
                headers=auth(actor),
                json={"kind": "room", "label": "Entry", "order": 0},
            )
            if created.status_code != 201:
                raise RuntimeError("room_setup_failed")
            thread.start()
            deadline = time.monotonic() + 5
            while not running.started:
                if not thread.is_alive() or time.monotonic() >= deadline:
                    raise RuntimeError("isolated_core_startup_failed")
                time.sleep(0.02)
            result = subprocess.run(
                ["flutter", "test", "test/features/sound_events/sound_event_normal_core_test.dart"],
                env={**os.environ, "LARENOR_SOUND_CORE_URL":
                     f"http://127.0.0.1:{listener.getsockname()[1]}"},
                cwd=Path(__file__).resolve().parents[3],
                check=False,
            )
            if provider.errors or any(method != "GET" for method, _path in provider.calls):
                raise RuntimeError("provider_contract_failed")
            return result.returncode
        finally:
            running.should_exit = True
            if thread.is_alive():
                thread.join(timeout=5)
            listener.close()
            provider.close()
            generator.close()


if __name__ == "__main__":
    sys.exit(main())
