"""Run the production F58 Flutter client through normal Core and loopback HA."""

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
from conftest import ready, server as core_fixture
from support.f58_oepl_fixture import OpenEpaperLinkFixture


def main():
    with tempfile.TemporaryDirectory(prefix="larenor-f58-client-") as root:
        generator = core_fixture.__wrapped__(Path(root))
        server = next(generator)
        app, client, _settings, clock = server
        clock.now = time.time()
        provider = OpenEpaperLinkFixture()
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listener.bind(("127.0.0.1", 0))
        running = uvicorn.Server(
            uvicorn.Config(app, log_level="critical", access_log=False)
        )
        thread = threading.Thread(
            target=lambda: running.run(sockets=[listener]), daemon=True
        )
        try:
            actor = ready(server)
            service = client.post("/api/v1/admin/services", headers={
                "Authorization": "Bearer " + actor["accessToken"],
            }, json={
                "kind": "home_assistant", "name": "OpenEPaperLink HA",
                "baseUrl": provider.url,
                "credentials": {"token": "oepl-loopback-only"},
            }).json()["service"]
            principal = app.state.core.auth.authenticate(actor["accessToken"])
            app.state.core.services.record_verification(
                principal, service["id"], service["revision"],
                state="authenticated", version="2026.9",
            )
            thread.start()
            deadline = time.monotonic() + 5
            while not running.started:
                if not thread.is_alive() or time.monotonic() >= deadline:
                    raise RuntimeError("isolated_core_startup_failed")
                time.sleep(0.02)
            result = subprocess.run(
                ["flutter", "test", "test/features/epaper/epaper_normal_core_test.dart"],
                env={**os.environ, "LARENOR_EPAPER_CORE_URL":
                     f"http://127.0.0.1:{listener.getsockname()[1]}"},
                cwd=Path(__file__).resolve().parents[3],
                check=False,
            )
            if provider.dry_runs != 1 or provider.real_sends != 1:
                raise RuntimeError(
                    f"provider_send_count_failed:{provider.dry_runs}:{provider.real_sends}"
                )
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
