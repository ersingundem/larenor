"""Run Flutter F50 against normal Core and bounded HA TCP/WebSocket I/O."""

from pathlib import Path
import json
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
from support.f50_home_assistant_fixture import ComfortHomeAssistantFixture


class DropFirstConfirmAcknowledgement:
    """Complete Core confirmation, then replace its first response with 503."""

    def __init__(self, app):
        self.app = app
        self.dropped = False

    async def __call__(self, scope, receive, send):
        path = scope.get("path", "")
        targeted = (
            scope.get("type") == "http"
            and scope.get("method") == "POST"
            and "/room-comfort/" in path
            and "/previews/" in path
            and path.endswith("/confirm")
            and not self.dropped
        )
        if not targeted:
            await self.app(scope, receive, send)
            return
        messages = []

        async def capture(message):
            messages.append(message)

        await self.app(scope, receive, capture)
        if not messages or messages[0].get("status") != 201:
            for message in messages:
                await send(message)
            return
        self.dropped = True
        body = json.dumps({
            "error": {"code": "comfort_ack_lost"},
        }, separators=(",", ":")).encode()
        await send({
            "type": "http.response.start",
            "status": 503,
            "headers": [
                (b"content-type", b"application/json"),
                (b"content-length", str(len(body)).encode("ascii")),
            ],
        })
        await send({"type": "http.response.body", "body": body})


def main():
    with tempfile.TemporaryDirectory(prefix="larenor-f50-client-") as root:
        generator = core_fixture.__wrapped__(Path(root))
        fixture = next(generator)
        app, client, _settings, clock = fixture
        clock.now = time.time()
        provider = ComfortHomeAssistantFixture(clock.now)
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listener.bind(("127.0.0.1", 0))
        boundary = DropFirstConfirmAcknowledgement(app)
        running = uvicorn.Server(uvicorn.Config(
            boundary, log_level="critical", access_log=False
        ))
        thread = threading.Thread(
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
            area = client.post(resources, headers=headers, json={
                "kind": "resource", "label": "Downstairs", "order": 0,
            })
            service = client.post(
                "/api/v1/admin/services", headers=headers, json={
                    "name": "Home Assistant",
                    "kind": "home_assistant",
                    "baseUrl": provider.base_url,
                    "credentials": {"token": provider.token},
                },
            )
            if any(value.status_code != 201 for value in (room, area, service)):
                raise RuntimeError("comfort_fixture_setup_failed")
            actor = app.state.core.auth.authenticate(pair["accessToken"])
            service_id = service.json()["service"]["id"]
            app.state.core.services.record_verification(
                actor, service_id, 1,
                state="authenticated", version="2026.9",
            )

            thread.start()
            deadline = time.monotonic() + 5
            while not running.started:
                if not thread.is_alive() or time.monotonic() >= deadline:
                    raise RuntimeError("isolated_core_startup_failed")
                time.sleep(0.02)
            result = subprocess.run(
                [
                    "flutter", "test",
                    "test/features/room_comfort/room_comfort_normal_core_test.dart",
                ],
                env={
                    **os.environ,
                    "LARENOR_COMFORT_CORE_URL":
                        f"http://127.0.0.1:{listener.getsockname()[1]}",
                },
                cwd=Path(__file__).resolve().parents[3],
                check=False,
            )
            state_reads = [
                call for call in provider.calls
                if call == ("GET", "/api/states/climate.living_room")
            ]
            if (
                result.returncode != 0
                or provider.errors
                or not boundary.dropped
                or provider.mutation_count != 1
                or provider.climate != "heat"
                or len(state_reads) < 3
            ):
                raise RuntimeError("comfort_acceptance_contract_failed")
            return 0
        finally:
            running.should_exit = True
            if thread.is_alive():
                thread.join(timeout=5)
            listener.close()
            provider.close()
            generator.close()


if __name__ == "__main__":
    sys.exit(main())
