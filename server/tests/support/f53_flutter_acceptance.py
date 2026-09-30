"""Actual Flutter tablet runtime -> normal Core TCP acceptance."""

from pathlib import Path
import hashlib
import json
import os
import socket
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time

import uvicorn

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from conftest import auth, ready, server as core_fixture
from larenor_server.app import create_app


DEVICE_ID = "53" * 16


class CoreTcp:
    def __init__(self, app, port=0):
        self.app = app
        self.port = port

    def __enter__(self):
        self.socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.socket.bind(("127.0.0.1", self.port))
        self.port = self.socket.getsockname()[1]
        self.server = uvicorn.Server(uvicorn.Config(
            self.app, log_level="critical", access_log=False,
            lifespan="on", timeout_keep_alive=1,
        ))
        self.thread = threading.Thread(
            target=self.server.run, kwargs={"sockets": [self.socket]},
            daemon=True,
        )
        self.thread.start()
        deadline = time.monotonic() + 10
        while not self.server.started and self.thread.is_alive():
            if time.monotonic() >= deadline:
                break
            time.sleep(0.01)
        if not self.server.started:
            raise RuntimeError("f53_core_start_failed")
        return self

    def __exit__(self, *_args):
        self.server.should_exit = True
        self.thread.join(timeout=10)
        self.socket.close()
        if self.thread.is_alive():
            raise RuntimeError("f53_core_stop_failed")


def flutter(root, url, phase):
    return subprocess.run(
        ["flutter", "test", "--no-pub",
         "test/features/server/tablet_fleet_normal_core_test.dart"],
        cwd=Path(__file__).resolve().parents[3],
        env={**os.environ, "LARENOR_F53_CLIENT_ROOT": str(root),
             "LARENOR_F53_CORE_URL": url, "LARENOR_F53_PHASE": phase},
        check=False,
    ).returncode


def root_path(app):
    scope = app.state.core.context
    return f"/api/v1/tablet-fleet/{scope.coreId}/{scope.homeId}"


def main():
    with tempfile.TemporaryDirectory(prefix="larenor-f53-client-") as temp:
        temp = Path(temp)
        core_root = temp / "core"
        client_root = temp / "client"
        first = core_fixture.__wrapped__(core_root)
        fixture = next(first)
        app, client, settings, clock = fixture
        clock.now = time.time()
        pair = ready(fixture)
        try:
            with CoreTcp(app) as tcp:
                url = f"http://127.0.0.1:{tcp.port}"
                if flutter(client_root, url, "prepare"):
                    raise RuntimeError("f53_prepare_failed")
                path = root_path(app)
                scope = app.state.core.context
                document = {
                    "schemaVersion": 1,
                    "fullscreen": True,
                    "idleTimeoutSeconds": 300,
                }
                digest = hashlib.sha256(json.dumps([
                    1, scope.coreId, scope.homeId, DEVICE_ID, True, 300,
                ], separators=(",", ":")).encode()).hexdigest()
                profile = client.put(
                    f"{path}/devices/{DEVICE_ID}/profile-publication",
                    headers=auth(pair), json={
                        "schemaVersion": 1,
                        "expectedDeviceRevision": 1,
                        "expectedProfileRevision": 0,
                        "documentDigest": digest,
                        "document": document,
                    },
                )
                if profile.status_code != 200:
                    raise RuntimeError("f53_profile_setup_failed")
                issued = client.post(
                    f"{path}/devices/{DEVICE_ID}/commands",
                    headers=auth(pair), json={
                        "schemaVersion": 1, "expectedDeviceRevision": 2,
                        "expectedPolicyRevision": 2,
                        "expiresAt": clock.now + 300,
                        "requestKey": "f53-sync-profile-command-proof-0001",
                        "command": "syncProfile",
                    },
                )
                if issued.status_code != 201:
                    raise RuntimeError("f53_command_setup_failed")
                if flutter(client_root, url, "consume"):
                    raise RuntimeError("f53_consume_failed")
                port = tcp.port
        finally:
            first.close()

        second = core_fixture.__wrapped__(core_root)
        fixture = next(second)
        app, client, settings, clock = fixture
        clock.now = time.time()
        try:
            with CoreTcp(app, port) as tcp:
                url = f"http://127.0.0.1:{tcp.port}"
                if flutter(client_root, url, "restart"):
                    raise RuntimeError("f53_restart_failed")
                if flutter(client_root, url, "revoke"):
                    raise RuntimeError("f53_revoke_failed")
            path = root_path(app)
            listed = client.get(f"{path}/devices", headers=auth(pair))
            if listed.status_code != 200:
                raise RuntimeError("f53_list_failed")
            tablet = listed.json()["tablets"][0]
            if tablet["state"] != "revoked" or tablet["lastSeenAt"] <= 0:
                raise RuntimeError("f53_revoke_readback_failed")
            database = settings.database_file
            with sqlite3.connect(database) as connection:
                row = connection.execute(
                    "SELECT state,result FROM managed_tablet_commands"
                ).fetchone()
            if row != ("completed", "succeeded"):
                raise RuntimeError("f53_command_receipt_failed")
        finally:
            second.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
