"""Official MCP Python SDK acceptance against a real normal-Core TCP endpoint."""

import asyncio
from pathlib import Path
import socket
import tempfile
import threading
import time

import httpx2
from mcp.client.session import ClientSession
from mcp.client.streamable_http import streamable_http_client
import uvicorn

from larenor_server.app import create_app
from larenor_server.config import Settings


CLIENT_ID = "fixture.python.sdk"
PASSWORD = "Synthetic MCP SDK password 2026"


def _require(response, status):
    if response.status_code != status:
        raise RuntimeError(f"http_{response.status_code}:{response.text[:200]}")
    return response.json()


async def _accept(base_url, app, settings):
    initial_password = settings.effective_bootstrap_file.read_text().split(
        "password: ", 1
    )[1].strip()
    timeout = httpx2.Timeout(10, read=20)
    async with httpx2.AsyncClient(base_url=base_url, timeout=timeout) as admin_http:
        initial = _require(
            await admin_http.post(
                "/api/v1/auth/login",
                json={
                    "username": "admin",
                    "password": initial_password,
                    "deviceName": "Official MCP Python SDK fixture",
                },
            ),
            200,
        )
        actor = _require(
            await admin_http.post(
                "/api/v1/auth/password",
                headers={"Authorization": "Bearer " + initial["accessToken"]},
                json={"currentPassword": initial_password, "newPassword": PASSWORD},
            ),
            200,
        )
        context = app.state.core.context
        root = f"/api/v1/mcp-gateway/{context.coreId}/{context.homeId}"
        issued = _require(
            await admin_http.post(
                root + "/grants",
                headers={"Authorization": "Bearer " + actor["accessToken"]},
                json={
                    "schemaVersion": 1,
                    "requestKey": "official-python-sdk-acceptance-0001",
                    "clientId": CLIENT_ID,
                    "clientName": "Official MCP Python SDK",
                    "tools": ["home.resource_count.read"],
                    "expiresAt": time.time() + 600,
                },
            ),
            201,
        )

        statuses = []

        async def capture(response):
            statuses.append(response.status_code)

        sdk_http = httpx2.AsyncClient(
            headers={
                "Authorization": "Bearer " + issued["accessToken"],
                "X-Larenor-MCP-Client": CLIENT_ID,
            },
            timeout=timeout,
            event_hooks={"response": [capture]},
        )
        revoked_blocked = False
        async with sdk_http:
            try:
                async with streamable_http_client(
                    base_url + root + "/mcp",
                    http_client=sdk_http,
                    terminate_on_close=False,
                ) as (read_stream, write_stream):
                    async with ClientSession(read_stream, write_stream) as session:
                        initialized = await session.initialize()
                        if initialized.protocol_version != "2025-06-18":
                            raise RuntimeError(
                                "unexpected_protocol:" + initialized.protocol_version
                            )
                        listed = await session.list_tools()
                        names = [tool.name for tool in listed.tools]
                        if names != ["home.resource_count.read"]:
                            raise RuntimeError("unexpected_tools:" + repr(names))
                        _require(
                            await admin_http.post(
                                root
                                + "/grants/"
                                + issued["grant"]["id"]
                                + "/revoke",
                                headers={
                                    "Authorization": "Bearer " + actor["accessToken"]
                                },
                                json={
                                    "schemaVersion": 1,
                                    "expectedRevision": issued["grant"]["revision"],
                                },
                            ),
                            200,
                        )
                        try:
                            await session.list_tools()
                        except BaseException:
                            revoked_blocked = True
            except BaseException:
                if 401 in statuses:
                    revoked_blocked = True
                else:
                    raise
        if not revoked_blocked or 401 not in statuses:
            raise RuntimeError("revoked_sdk_session_not_blocked")
        return {
            "sdk": "mcp==2.2.0",
            "protocol": "2025-06-18",
            "tools": ["home.resource_count.read"],
            "revokedStatus": 401,
        }


def main():
    with tempfile.TemporaryDirectory(prefix="larenor-f12-sdk-") as root:
        root_path = Path(root).resolve()
        settings = Settings(
            root_path / "data",
            root_path / "secrets/vault.key",
            login_ip_limit=100,
            login_account_limit=100,
            login_global_limit=100,
        )
        app = create_app(settings)
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listener.bind(("127.0.0.1", 0))
        server = uvicorn.Server(
            uvicorn.Config(app, log_level="critical", access_log=False)
        )
        thread = threading.Thread(
            target=lambda: server.run(sockets=[listener]), daemon=True
        )
        thread.start()
        try:
            deadline = time.monotonic() + 10
            while not server.started:
                if not thread.is_alive() or time.monotonic() >= deadline:
                    raise RuntimeError("normal_core_startup_failed")
                time.sleep(0.02)
            result = asyncio.run(
                _accept(
                    f"http://127.0.0.1:{listener.getsockname()[1]}", app, settings
                )
            )
            print(result)
        finally:
            server.should_exit = True
            thread.join(timeout=10)
            listener.close()
            if thread.is_alive():
                raise RuntimeError("normal_core_shutdown_failed")


if __name__ == "__main__":
    main()
