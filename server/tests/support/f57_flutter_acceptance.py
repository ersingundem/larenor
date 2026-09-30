"""Production Flutter -> normal Core -> authenticated HA MQTT-room I/O."""

from pathlib import Path
from http.server import ThreadingHTTPServer
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
from test_f57_mqtt_room_normal_core import MqttRoomHomeAssistant


class PresenceHomeAssistant(MqttRoomHomeAssistant):
    state_reads = 0
    offline = False
    offline_requests = 0

    def do_GET(self):
        cls = type(self)
        if cls.offline:
            cls.offline_requests += 1
            self.send_error(503)
            return
        if self.path.startswith("/api/states/"):
            cls.state_reads += 1
            cls.observed_ms += 1_000
        super().do_GET()
        if cls.state_reads >= 3:
            cls.offline = True


def main():
    with tempfile.TemporaryDirectory(prefix="larenor-f57-client-") as root:
        generator = core_fixture.__wrapped__(Path(root))
        fixture = next(generator)
        app, client, _settings, clock = fixture
        clock.now = time.time()
        PresenceHomeAssistant.observed_ms = int(clock.now * 1000) - 4_000
        PresenceHomeAssistant.room = "living"
        PresenceHomeAssistant.entity = "sensor.owner_room"
        PresenceHomeAssistant.unique_id = "private-ble-device-id"
        PresenceHomeAssistant.name = "Owner room"
        PresenceHomeAssistant.after_registry = None
        PresenceHomeAssistant.requests = []
        PresenceHomeAssistant.state_reads = 0
        PresenceHomeAssistant.offline = False
        PresenceHomeAssistant.offline_requests = 0
        upstream = ThreadingHTTPServer(
            ("127.0.0.1", 0), PresenceHomeAssistant
        )
        upstream_thread = threading.Thread(
            target=upstream.serve_forever, daemon=True
        )
        upstream_thread.start()
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listener.bind(("127.0.0.1", 0))
        running = uvicorn.Server(uvicorn.Config(
            app, log_level="critical", access_log=False
        ))
        core_thread = threading.Thread(
            target=lambda: running.run(sockets=[listener]), daemon=True
        )
        try:
            pair = ready(fixture)
            headers = auth(pair)
            scope = app.state.core.context
            resources = (
                f"/api/v1/admin/home-resources/{scope.coreId}/{scope.homeId}"
            )
            room = client.post(resources, headers=headers, json={
                "kind": "room", "label": "Living room", "order": 0,
            })
            service = client.post(
                "/api/v1/admin/services", headers=headers, json={
                    "name": "Home Assistant",
                    "kind": "home_assistant",
                    "baseUrl": f"http://127.0.0.1:{upstream.server_port}",
                    "credentials": {"token": "private-ha-token"},
                },
            )
            if room.status_code != 201 or service.status_code != 201:
                raise RuntimeError("presence_fixture_setup_failed")
            actor = app.state.core.auth.authenticate(pair["accessToken"])
            service_id = service.json()["service"]["id"]
            app.state.core.services.record_verification(
                actor, service_id, 1,
                state="authenticated", version="2026.9",
            )

            core_thread.start()
            deadline = time.monotonic() + 5
            while not running.started:
                if not core_thread.is_alive() or time.monotonic() >= deadline:
                    raise RuntimeError("isolated_core_startup_failed")
                time.sleep(0.02)
            result = subprocess.run(
                [
                    "flutter", "test",
                    "test/features/room_presence/room_presence_normal_core_test.dart",
                ],
                cwd=Path(__file__).resolve().parents[3],
                env={
                    **os.environ,
                    "LARENOR_PRESENCE_CORE_URL":
                        f"http://127.0.0.1:{listener.getsockname()[1]}",
                },
                check=False,
            )
            if (
                result.returncode != 0
                or PresenceHomeAssistant.state_reads != 3
                or not PresenceHomeAssistant.offline
                or PresenceHomeAssistant.offline_requests != 0
            ):
                raise RuntimeError("presence_acceptance_contract_failed")
            return 0
        finally:
            running.should_exit = True
            if core_thread.is_alive():
                core_thread.join(timeout=5)
            listener.close()
            upstream.shutdown()
            upstream.server_close()
            upstream_thread.join(timeout=5)
            generator.close()


if __name__ == "__main__":
    sys.exit(main())
