"""Run the real Flutter F42 client against normal Core and TCP Frigate/FFmpeg."""

from pathlib import Path
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time

from fastapi.testclient import TestClient
import uvicorn

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from conftest import Clock, ready
from larenor_server.app import create_app
from larenor_server.config import Settings
from support.f41_frigate_fixture import FrigateFixture, provision


def main():
    ffmpeg = shutil.which("ffmpeg")
    ffprobe = shutil.which("ffprobe")
    if ffmpeg is None or ffprobe is None:
        raise RuntimeError("ffmpeg_and_ffprobe_are_required")
    with tempfile.TemporaryDirectory(prefix="larenor-f42-client-") as root:
        path = Path(root).resolve()
        clock = Clock(time.time())
        settings = Settings(
            path / "data",
            path / "secrets/vault.key",
            clock=clock,
            login_ip_limit=100,
            login_account_limit=100,
            login_global_limit=100,
            private_event_ffmpeg=Path(ffmpeg),
            private_event_ffprobe=Path(ffprobe),
        )
        app = create_app(settings)
        provider = FrigateFixture()
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listener.bind(("127.0.0.1", 0))
        running = uvicorn.Server(
            uvicorn.Config(app, log_level="critical", access_log=False)
        )
        thread = threading.Thread(
            target=lambda: running.run(sockets=[listener]), daemon=True
        )
        try:
            with TestClient(app) as client:
                fixture = (app, client, settings, clock)
                actor = ready(fixture)
                provision(client, app.state.core, actor, provider)
                thread.start()
                deadline = time.monotonic() + 5
                while not running.started:
                    if not thread.is_alive() or time.monotonic() >= deadline:
                        raise RuntimeError("isolated_core_startup_failed")
                    time.sleep(0.02)
                result = subprocess.run(
                    [
                        "flutter",
                        "test",
                        "test/features/private_event_sharing/"
                        "private_event_share_normal_core_test.dart",
                    ],
                    env={
                        **os.environ,
                        "LARENOR_F42_CORE_URL": (
                            f"http://127.0.0.1:{listener.getsockname()[1]}"
                        ),
                    },
                    cwd=Path(__file__).resolve().parents[3],
                    check=False,
                )
                if result.returncode:
                    return result.returncode
                if provider.errors or any(
                    method != "GET" for method, path in provider.calls
                    if path != "/api/login"
                ):
                    raise RuntimeError("provider_contract_failed")
                return 0
        finally:
            running.should_exit = True
            if thread.is_alive():
                thread.join(timeout=5)
            listener.close()
            provider.close()


if __name__ == "__main__":
    sys.exit(main())
