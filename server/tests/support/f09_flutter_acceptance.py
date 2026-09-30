"""Run the real Flutter F09 client against an isolated normal TCP Core."""

import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time

import uvicorn

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from conftest import ready, server as core_fixture


def main():
    with tempfile.TemporaryDirectory(prefix="larenor-f09-client-") as root:
        generator = core_fixture.__wrapped__(Path(root))
        fixture = next(generator)
        app, _client, _settings, _clock = fixture
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listener.bind(("127.0.0.1", 0))
        running = uvicorn.Server(
            uvicorn.Config(app, log_level="critical", access_log=False)
        )
        thread = threading.Thread(
            target=lambda: running.run(sockets=[listener]), daemon=True
        )
        try:
            ready(fixture)
            thread.start()
            deadline = time.monotonic() + 5
            while not running.started:
                if not thread.is_alive() or time.monotonic() >= deadline:
                    raise RuntimeError("isolated_core_startup_failed")
                time.sleep(0.02)
            return subprocess.run(
                [
                    "flutter",
                    "test",
                    "test/features/server/server_ai_memory_normal_core_test.dart",
                ],
                env={
                    **os.environ,
                    "LARENOR_MEMORY_CORE_URL": (
                        f"http://127.0.0.1:{listener.getsockname()[1]}"
                    ),
                },
                cwd=Path(__file__).resolve().parents[3],
                check=False,
            ).returncode
        finally:
            running.should_exit = True
            if thread.is_alive():
                thread.join(timeout=5)
            listener.close()
            generator.close()


if __name__ == "__main__":
    sys.exit(main())
