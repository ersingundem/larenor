"""Actual Flutter TCP gate with normal Core and isolated F49 providers."""

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
from support.f49_irrigation_fixture import IrrigationFixture, provision_inventory


def main():
    with tempfile.TemporaryDirectory(prefix="larenor-f49-client-") as root:
        generator = core_fixture.__wrapped__(Path(root))
        fixture = next(generator)
        app, client, _settings, clock = fixture
        upstream = IrrigationFixture(clock.now)
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listener.bind(("127.0.0.1", 0))
        running = uvicorn.Server(
            uvicorn.Config(app, log_level="critical", access_log=False)
        )
        thread = threading.Thread(
            target=lambda: running.run(sockets=[listener]), daemon=True
        )
        try:
            actor = ready(fixture)
            provision_inventory(client, app.state.core, actor, upstream)
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
                    "test/features/irrigation_budget/"
                    "irrigation_budget_normal_core_test.dart",
                ],
                env={
                    **os.environ,
                    "LARENOR_IRRIGATION_CORE_URL": (
                        f"http://127.0.0.1:{listener.getsockname()[1]}"
                    ),
                    "LARENOR_IRRIGATION_CONTROLLER_URL": upstream.url,
                    "LARENOR_IRRIGATION_CONTROLLER_PASSWORD_MD5": (
                        upstream.password_md5
                    ),
                },
                cwd=Path(__file__).resolve().parents[3],
                check=False,
            )
            if result.returncode != 0:
                return result.returncode
            if upstream.errors:
                raise RuntimeError("provider_contract_failed:" + repr(upstream.errors))
            if len(upstream.command_calls) != 1:
                raise RuntimeError(
                    "irrigation_dispatch_count:" + str(len(upstream.command_calls))
                )
            return result.returncode
        finally:
            running.should_exit = True
            if thread.is_alive():
                thread.join(timeout=5)
            listener.close()
            upstream.close()
            generator.close()


if __name__ == "__main__":
    sys.exit(main())
