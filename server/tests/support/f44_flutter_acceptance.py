"""Actual Flutter TCP gate with normal Core and an isolated HA/Frigate server."""
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
from conftest import server as core_fixture, ready
from support.f41_frigate_fixture import provision
from support.f44_frigate_fixture import VisualFrigateFixture


def main():
    with tempfile.TemporaryDirectory(prefix='larenor-f44-client-') as root:
        generator = core_fixture.__wrapped__(Path(root))
        fixture = next(generator)
        app, client, _, _ = fixture
        provider = VisualFrigateFixture()
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listener.bind(('127.0.0.1', 0))
        running = uvicorn.Server(uvicorn.Config(app, log_level='critical', access_log=False))
        thread = threading.Thread(target=lambda: running.run(sockets=[listener]), daemon=True)
        try:
            actor = ready(fixture)
            provision(client, app.state.core, actor, provider)
            def new_sample():
                fixture[3].now += 3
                provider.attempt(fixture[3].now)
            provider.on_attempt_list = new_sample
            thread.start()
            deadline = time.monotonic() + 5
            while not running.started:
                if not thread.is_alive() or time.monotonic() >= deadline:
                    raise RuntimeError('isolated_core_startup_failed')
                time.sleep(.02)
            result = subprocess.run(['flutter', 'test', 'test/features/camera_visual_sensors/camera_visual_sensor_normal_core_test.dart'],
                env={**os.environ, 'LARENOR_VISUAL_CORE_URL': f'http://127.0.0.1:{listener.getsockname()[1]}'},
                cwd=Path(__file__).resolve().parents[3], check=False)
            if provider.errors or any(method == 'POST' for method, _ in provider.calls):
                raise RuntimeError('provider_contract_failed')
            return result.returncode
        finally:
            running.should_exit = True
            if thread.is_alive(): thread.join(timeout=5)
            listener.close(); provider.close(); generator.close()


if __name__ == '__main__':
    sys.exit(main())
