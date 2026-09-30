"""Run the real Flutter API against normal Core and actual loopback HA TCP/WS.

Fixtures replace the external HA installation only. No Core provider, route,
authority, dispatch, or receipt is substituted. Never contacts a household.
"""
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
from conftest import server as core_fixture
from test_f43_camera_ha_normal_core import cameras as ha_fixture, provision


def main():
    with tempfile.TemporaryDirectory(prefix='larenor-f43-client-') as root:
        core_generator = core_fixture.__wrapped__(Path(root))
        ha_generator = ha_fixture.__wrapped__()
        server_tuple = next(core_generator)
        ha = next(ha_generator)
        app, _client, _admin, _root, _settings = provision(server_tuple, ha)
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listener.bind(('127.0.0.1', 0))
        config = uvicorn.Config(app, log_level='critical', access_log=False)
        core = uvicorn.Server(config)
        thread = threading.Thread(target=lambda: core.run(sockets=[listener]), daemon=True)
        thread.start()
        deadline = time.monotonic() + 5
        try:
            while not core.started:
                if not thread.is_alive() or time.monotonic() >= deadline:
                    raise RuntimeError('fixture_core_startup_failed')
                time.sleep(.02)
            environment = {**os.environ, 'LARENOR_CAMERA_CORE_URL': f'http://127.0.0.1:{listener.getsockname()[1]}'}
            result = subprocess.run(['flutter', 'test', 'test/features/camera_profiles/camera_profile_normal_core_test.dart'],
                cwd=Path(__file__).resolve().parents[3], env=environment, check=False)
            if result.returncode:
                return result.returncode
            if [ha.states[name] for name in ('switch.recordings', 'switch.detection')] != ['on', 'on']:
                raise RuntimeError('fixture_readback_restore_failed')
            if sum(method == 'POST' for method, _ in ha.calls) != 4:
                raise RuntimeError('fixture_device_command_count_invalid')
            return result.returncode
        finally:
            core.should_exit = True
            thread.join(timeout=5)
            listener.close()
            core_generator.close()
            ha_generator.close()


if __name__ == '__main__':
    sys.exit(main())
