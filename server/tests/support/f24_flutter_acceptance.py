"""Run the real Flutter F24 Client against the shared preference store in normal Core."""

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


def main():
    with tempfile.TemporaryDirectory(prefix="larenor-f24-client-") as root:
        generator = core_fixture.__wrapped__(Path(root))
        fixture = next(generator)
        app, client, _settings, clock = fixture
        clock.now = time.time()
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
            thread.start()
            deadline = time.monotonic() + 5
            while not core.started:
                if not thread.is_alive() or time.monotonic() >= deadline:
                    raise RuntimeError("core_startup_failed")
                time.sleep(0.02)
            result = subprocess.run(
                [
                    "flutter", "test",
                    "test/features/media/language_preferences/"
                    "normal_core_preference_unification_test.dart",
                ],
                cwd=Path(__file__).resolve().parents[3],
                env={
                    **os.environ,
                    "LARENOR_F24_CORE_URL": (
                        f"http://127.0.0.1:{listener.getsockname()[1]}"
                    ),
                },
                check=False,
            )
            if result.returncode:
                return result.returncode
            with app.state.core.db.connection() as connection:
                if connection.execute('SELECT COUNT(*) FROM jellyfin_track_preferences').fetchone()[0] != 0:
                    raise RuntimeError('legacy_preference_write_detected')
                if connection.execute('SELECT revision FROM media_language_preferences').fetchone()[0] != 2:
                    raise RuntimeError('shared_preference_revision_missing')
            return 0
        finally:
            core.should_exit = True
            if thread.is_alive():
                thread.join(timeout=5)
            listener.close()
            generator.close()


if __name__ == "__main__":
    sys.exit(main())
