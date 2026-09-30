"""Run the real Flutter F23 client through normal Core to TCP Jellyfin."""

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
from support.f23_jellyfin_fixture import JellyfinLiveTvFixture


def main():
    with tempfile.TemporaryDirectory(prefix="larenor-f23-client-") as root:
        generator = core_fixture.__wrapped__(Path(root))
        fixture = next(generator)
        app, client, _settings, clock = fixture
        clock.now = time.time()
        upstream = JellyfinLiveTvFixture(clock.now)
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listener.bind(("127.0.0.1", 0))
        core = uvicorn.Server(
            uvicorn.Config(app, log_level="critical", access_log=False)
        )
        thread = threading.Thread(
            target=lambda: core.run(sockets=[listener]), daemon=True
        )
        try:
            actor = ready(fixture)
            response = client.post(
                "/api/v1/admin/services", headers=auth(actor), json={
                    "kind": "jellyfin", "name": "Jellyfin Live TV",
                    "baseUrl": upstream.url,
                    "credentials": {"apiKey": upstream.token},
                },
            )
            if response.status_code != 201:
                raise RuntimeError("service_fixture_setup_failed")
            service = response.json()["service"]
            principal = app.state.core.auth.authenticate(actor["accessToken"])
            app.state.core.services.record_verification(
                principal, service["id"], service["revision"],
                state="authenticated", version="10.11.1",
            )
            thread.start()
            deadline = time.monotonic() + 5
            while not core.started:
                if not thread.is_alive() or time.monotonic() >= deadline:
                    raise RuntimeError("core_startup_failed")
                time.sleep(0.02)
            result = subprocess.run(
                [
                    "flutter", "test",
                    "test/features/server/live_tv/"
                    "server_live_tv_normal_core_test.dart",
                ],
                cwd=Path(__file__).resolve().parents[3],
                env={
                    **os.environ,
                    "LARENOR_F23_CORE_URL": (
                        f"http://127.0.0.1:{listener.getsockname()[1]}"
                    ),
                },
                check=False,
            )
            if result.returncode:
                return result.returncode
            mutations = [call[0] for call in upstream.calls
                         if call[0] in {"POST", "DELETE"}]
            if mutations != ["POST", "DELETE"] or upstream.timers:
                raise RuntimeError("jellyfin_timer_contract_failed")
            return 0
        finally:
            core.should_exit = True
            if thread.is_alive():
                thread.join(timeout=5)
            listener.close()
            upstream.close()
            generator.close()


if __name__ == "__main__":
    sys.exit(main())
