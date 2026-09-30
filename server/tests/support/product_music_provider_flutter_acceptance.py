"""Flutter provider onboarding through normal Core, private IPC, and MA TCP."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import http.client
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time

from fastapi.testclient import TestClient
import uvicorn

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from conftest import Clock
from larenor_server.app import create_app
from larenor_server.config import Settings
from larenor_server.plugins.installation_ipc import InstallationWorkerServer
from larenor_server.plugins.music_provider_setup_runtime import MusicProviderSetupRuntime
from larenor_server.plugins import preflight_ipc
from test_music_provider_setups import ready_core


TOKEN = "synthetic-music-assistant-token-never-public"
SECRET = "SAPISID=product-provider-private-cookie"


class MusicAssistantFixture(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    calls = []

    def log_message(self, *_args):
        pass

    def do_POST(self):
        if (self.path != "/api"
                or self.headers.get("Authorization") != "Bearer " + TOKEN):
            self.send_error(403)
            return
        size = int(self.headers.get("Content-Length", "0"))
        if not 1 <= size <= 65536:
            self.send_error(400)
            return
        request = json.loads(self.rfile.read(size))
        command = request.get("command")
        args = request.get("args")
        type(self).calls.append((command, args))
        if command == "config/providers/setup" and args == {
                "provider_domain": "ytmusic"}:
            value = {
                "flow_id": "ytmusic-owned-flow",
                "step_id": "user",
                "type": "form",
                "entries": [
                    {"key": "username", "type": "string", "required": True},
                    {"key": "cookie", "type": "secure_string", "required": True},
                    {"key": "po_token_server_url", "type": "string", "required": True},
                ],
                "url": None,
                "expires_at": int(time.time()) + 900,
            }
        elif command == "config/flows/submit" and args == {
                "flow_id": "ytmusic-owned-flow",
                "values": {
                    "username": "fixture-family",
                    "cookie": SECRET,
                    "po_token_server_url": "http://127.0.0.1:8096",
                }}:
            value = {
                "flow_id": "ytmusic-owned-flow", "type": "finish",
                "result": {"instance_id": "ytmusic--owned-fixture"},
            }
        elif command == "config/providers/get" and args == {
                "instance_id": "ytmusic--owned-fixture"}:
            value = {
                "instance_id": "ytmusic--owned-fixture",
                "domain": "ytmusic", "status": "loaded",
            }
        elif command == "config/providers/setup" and args == {
                "provider_domain": "spotify"}:
            value = {
                "flow_id": "spotify-owned-flow",
                "step_id": "authenticate",
                "type": "external",
                "entries": [],
                "url": "https://accounts.spotify.com/authorize?state=owned-fixture",
                "expires_at": int(time.time()) + 900,
            }
        elif command == "config/flows/abort" and args == {
                "flow_id": "spotify-owned-flow"}:
            value = None
        else:
            self.send_error(400)
            return
        body = json.dumps(value, separators=(",", ":")).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class ProviderBackend:
    def __init__(self, runtime):
        self.runtime = runtime

    def execute_music_provider_setup(self, action, *, deadline, gate):
        if gate() is not True:
            raise RuntimeError("provider_setup_authority_changed")
        result = self.runtime.execute(action, deadline=deadline)
        if gate() is not True:
            raise RuntimeError("provider_setup_authority_changed")
        return result


class DropFirstCreateAcknowledgement:
    """Commit one exact create, then replace only its public acknowledgement."""

    def __init__(self, app):
        self.app = app
        self.dropped = 0

    async def __call__(self, scope, receive, send):
        if (scope["type"] != "http" or scope["method"] != "POST"
                or scope["path"] !=
                "/api/v1/admin/media/music-assistant/providers"
                or self.dropped):
            return await self.app(scope, receive, send)
        messages = []

        async def capture(message):
            messages.append(message)

        await self.app(scope, receive, capture)
        status = next(
            item["status"] for item in messages
            if item["type"] == "http.response.start"
        )
        if status != 201:
            for message in messages:
                await send(message)
            return
        self.dropped += 1
        body = b'{"error":{"code":"server_error"}}'
        await send({
            "type": "http.response.start", "status": 503,
            "headers": [
                (b"content-type", b"application/json"),
                (b"content-length", str(len(body)).encode("ascii")),
            ],
        })
        await send({"type": "http.response.body", "body": body})


class CoreTcp:
    def __init__(self, app, port=0):
        self.app = app
        self.port = port

    def __enter__(self):
        self.listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.listener.bind(("127.0.0.1", self.port))
        self.port = self.listener.getsockname()[1]
        self.server = uvicorn.Server(uvicorn.Config(
            self.app, log_level="critical", access_log=False,
            lifespan="on", timeout_keep_alive=1,
        ))
        self.thread = threading.Thread(
            target=self.server.run, kwargs={"sockets": [self.listener]},
            daemon=True,
        )
        self.thread.start()
        deadline = time.monotonic() + 10
        while not self.server.started and self.thread.is_alive():
            if time.monotonic() >= deadline:
                break
            time.sleep(.01)
        if not self.server.started:
            self.__exit__(None, None, None)
            raise RuntimeError("product_provider_core_start_failed")
        return self

    def __exit__(self, _kind, _error, _traceback):
        self.server.should_exit = True
        self.thread.join(timeout=10)
        self.listener.close()
        if self.thread.is_alive():
            raise RuntimeError("product_provider_core_stop_failed")


def flutter(phase, url, installation_id, installation_revision, session_file):
    return subprocess.run(
        [
            "flutter", "test", "--no-pub",
            "test/features/server/server_music_provider_setup_normal_core_test.dart",
        ],
        cwd=Path(__file__).resolve().parents[3],
        env={
            **os.environ,
            "LARENOR_PRODUCT_PROVIDER_PHASE": phase,
            "LARENOR_PRODUCT_PROVIDER_CORE_URL": url,
            "LARENOR_PRODUCT_PROVIDER_INSTALLATION_ID": installation_id,
            "LARENOR_PRODUCT_PROVIDER_INSTALLATION_REVISION":
                str(installation_revision),
            "LARENOR_PRODUCT_PROVIDER_SESSION_FILE": str(session_file),
        },
        check=False,
    ).returncode


def main():
    if not hasattr(socket, "SO_PEERCRED"):
        # Darwin has no Linux SO_PEERCRED. The same exact IPC framing and UID
        # checks remain active; Linux host-package gates exercise the kernel
        # credential reader used in production.
        preflight_ipc._peer_uid = lambda _connection: os.getuid()
    MusicAssistantFixture.calls = []
    upstream = ThreadingHTTPServer(("127.0.0.1", 0), MusicAssistantFixture)
    upstream_thread = threading.Thread(target=upstream.serve_forever, daemon=True)
    upstream_thread.start()
    runtime = MusicProviderSetupRuntime(
        lambda timeout: http.client.HTTPConnection(
            "127.0.0.1", upstream.server_port, timeout=timeout))
    try:
        base = "/private/tmp" if Path("/private/tmp").is_dir() else "/tmp"
        with tempfile.TemporaryDirectory(
                prefix="larenor-product-providers-", dir=base) as raw:
            root = Path(raw)
            worker_path = root / "installation.sock"
            worker = InstallationWorkerServer(
                worker_path, ProviderBackend(runtime), allowed_uid=os.getuid(),
                peer_uid=lambda _connection: os.getuid(), timeout=5,
            )
            worker.start()
            try:
                clock = Clock(time.time())
                settings = Settings(
                    root / "data", root / "secrets/vault.key", clock=clock,
                    login_ip_limit=100, login_account_limit=100,
                    login_global_limit=100,
                    installation_worker_socket=worker_path,
                    installation_worker_uid=os.getuid(),
                )
                prepared_app = create_app(settings)
                with TestClient(prepared_app) as client:
                    pair, installation_id, installation_revision = ready_core(
                        (prepared_app, client, settings, clock))
                    if pair["user"]["role"] != "admin":
                        raise RuntimeError("product_provider_admin_missing")

                first_app = create_app(settings)
                lost = DropFirstCreateAcknowledgement(first_app)
                session_file = root / "client" / "session.json"
                with CoreTcp(lost) as first:
                    port = first.port
                    if flutter(
                        "prepare", f"http://127.0.0.1:{port}",
                        installation_id, installation_revision, session_file,
                    ):
                        raise RuntimeError("product_provider_prepare_failed")
                if lost.dropped != 1:
                    raise RuntimeError("product_provider_ack_not_dropped")

                second_app = create_app(settings)
                with CoreTcp(second_app, port=port) as second:
                    if flutter(
                        "restart", f"http://127.0.0.1:{second.port}",
                        installation_id, installation_revision, session_file,
                    ):
                        raise RuntimeError("product_provider_restart_failed")

                commands = [command for command, _args in MusicAssistantFixture.calls]
                if commands != [
                    "config/providers/setup",
                    "config/flows/submit",
                    "config/providers/get",
                    "config/providers/setup",
                    "config/flows/abort",
                ]:
                    raise RuntimeError("product_provider_upstream_sequence_invalid")
                with second_app.state.core.db.connection() as connection:
                    dump = "\n".join(connection.iterdump())
                if SECRET in dump:
                    raise RuntimeError("product_provider_secret_persisted_plaintext")
            finally:
                worker.close()
    finally:
        upstream.shutdown()
        upstream.server_close()
        upstream_thread.join(timeout=5)
    return 0


if __name__ == "__main__":
    sys.exit(main())
