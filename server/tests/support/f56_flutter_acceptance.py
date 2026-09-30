"""Production Flutter → normal Core → TCP/WS HA send and learning attempts."""
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
from conftest import server as core_fixture, ready, auth
from support.f56_ha_fixture import BroadlinkFixture


def main():
    with tempfile.TemporaryDirectory(prefix="larenor-f56-client-") as root:
        generator = core_fixture.__wrapped__(Path(root)); fixture = next(generator)
        app, client, _settings, clock = fixture
        clock.now = time.time()
        upstream = BroadlinkFixture()
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM); listener.bind(("127.0.0.1", 0))
        core = uvicorn.Server(uvicorn.Config(app, log_level="critical", access_log=False))
        thread = threading.Thread(target=lambda: core.run(sockets=[listener]), daemon=True)
        try:
            actor = ready(fixture)
            response = client.post("/api/v1/admin/services", headers=auth(actor), json={
                "kind": "home_assistant", "name": "Broadlink HA", "baseUrl": upstream.url,
                "credentials": {"token": upstream.token}})
            if response.status_code != 201: raise RuntimeError("service_fixture_setup_failed")
            service = response.json()["service"]
            # The general discovery probe deliberately excludes loopback; the provider's
            # actual TCP and WS verification still runs for every source operation.
            principal = app.state.core.auth.authenticate(actor["accessToken"])
            app.state.core.services.record_verification(principal, service["id"], service["revision"],
                state="authenticated", version="2026.9.2")
            thread.start()
            deadline = time.monotonic() + 5
            while not core.started:
                if not thread.is_alive() or time.monotonic() >= deadline: raise RuntimeError("core_startup_failed")
                time.sleep(.02)
            result = subprocess.run(["flutter", "test", "test/features/legacy_remote/legacy_remote_normal_core_test.dart"],
                cwd=Path(__file__).resolve().parents[3], env={**os.environ,
                    "LARENOR_REMOTE_CORE_URL": f"http://127.0.0.1:{listener.getsockname()[1]}"}, check=False)
            if result.returncode != 0:
                return result.returncode
            posts = [call for call in upstream.calls if call[0] == "POST"]
            paths = [call[1] for call in posts]
            if upstream.errors or paths != [
                "/api/services/remote/send_command",
                "/api/services/remote/learn_command",
            ]:
                raise RuntimeError("actual_provider_contract_failed")
            return 0
        finally:
            core.should_exit = True
            if thread.is_alive(): thread.join(timeout=5)
            listener.close(); upstream.close(); generator.close()


if __name__ == "__main__": sys.exit(main())
