"""Actual Flutter family-board Client -> normal Core TCP across restart."""

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
from conftest import ready, server as core_fixture


class CoreTcp:
    def __init__(self, app, *, port=0):
        self.app = app
        self.requested_port = port

    def __enter__(self):
        self.socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.socket.bind(("127.0.0.1", self.requested_port))
        self.port = self.socket.getsockname()[1]
        self.server = uvicorn.Server(uvicorn.Config(
            self.app,
            log_level="critical",
            access_log=False,
            lifespan="on",
            timeout_keep_alive=1,
        ))
        self.thread = threading.Thread(
            target=self.server.run,
            kwargs={"sockets": [self.socket]},
            daemon=True,
        )
        self.thread.start()
        deadline = time.monotonic() + 10
        while not self.server.started and self.thread.is_alive():
            if time.monotonic() >= deadline:
                break
            time.sleep(0.01)
        if not self.server.started:
            self.__exit__(None, None, None)
            raise RuntimeError("family_board_core_start_failed")
        return self

    def __exit__(self, _kind, _error, _traceback):
        self.server.should_exit = True
        self.thread.join(timeout=10)
        self.socket.close()
        if self.thread.is_alive():
            raise RuntimeError("family_board_core_stop_failed")


class DropTwoCommandAcknowledgements:
    """Commit in Core, then replace two exact command acknowledgements."""

    def __init__(self, app):
        self.app = app
        self.remaining = 2
        self.command_digests = []

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)
        request_body = bytearray()

        async def capture_receive():
            message = await receive()
            if message["type"] == "http.request":
                request_body.extend(message.get("body", b""))
            return message

        response = []

        async def capture_send(message):
            response.append(message)

        await self.app(scope, capture_receive, capture_send)
        status = next(
            (item["status"] for item in response if item["type"] == "http.response.start"),
            None,
        )
        command = (
            scope["method"] == "POST"
            and scope["path"].endswith("/commands")
            and "/family-boards/" in scope["path"]
        )
        if command and status == 200 and self.remaining:
            self.command_digests.append(hashlib.sha256(request_body).hexdigest())
            self.remaining -= 1
            body = json.dumps(
                {"error": {"code": "request_timeout"}},
                sort_keys=True,
                separators=(",", ":"),
            ).encode("utf-8")
            await send({
                "type": "http.response.start",
                "status": 408,
                "headers": [
                    (b"content-type", b"application/json"),
                    (b"content-length", str(len(body)).encode("ascii")),
                ],
            })
            await send({"type": "http.response.body", "body": body})
            return
        for message in response:
            await send(message)


def _events(path):
    with sqlite3.connect(path) as connection:
        return connection.execute(
            "SELECT COUNT(*) FROM family_board_events"
        ).fetchone()[0]


def _flutter(phase, client_root, port):
    return subprocess.run(
        [
            "flutter",
            "test",
            "--no-pub",
            "test/features/family_board/family_board_normal_core_test.dart",
        ],
        cwd=Path(__file__).resolve().parents[3],
        env={
            **os.environ,
            "LARENOR_F39_PHASE": phase,
            "LARENOR_F39_CLIENT_ROOT": str(client_root),
            "LARENOR_F39_CORE_URL": f"http://127.0.0.1:{port}",
        },
        check=False,
    ).returncode


def main():
    with tempfile.TemporaryDirectory(prefix="larenor-f39-client-") as root:
        root = Path(root)
        data_root = root / "core"
        client_root = root / "client"

        first = core_fixture.__wrapped__(data_root)
        fixture = next(first)
        fixture[3].now = time.time()
        ready(fixture)
        lost_ack = DropTwoCommandAcknowledgements(fixture[0])
        try:
            with CoreTcp(lost_ack) as tcp:
                if _flutter("prepare", client_root, tcp.port):
                    raise RuntimeError("family_board_prepare_failed")
                core_port = tcp.port
            if lost_ack.remaining != 0 or len(set(lost_ack.command_digests)) != 1:
                raise RuntimeError("family_board_command_replay_not_exact")
            database = fixture[2].data_dir / "family-board.sqlite3"
            if _events(database) != 1:
                raise RuntimeError("family_board_lost_ack_duplicated_effect")
        finally:
            first.close()

        second = core_fixture.__wrapped__(data_root)
        fixture = next(second)
        fixture[3].now = time.time()
        try:
            with CoreTcp(fixture[0], port=core_port) as tcp:
                if _flutter("restart", client_root, tcp.port):
                    raise RuntimeError("family_board_restart_failed")
            if _events(fixture[2].data_dir / "family-board.sqlite3") != 5:
                raise RuntimeError("family_board_event_count_invalid")
        finally:
            second.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
