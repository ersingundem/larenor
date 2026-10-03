"""Actual Flutter profile vault -> two normal Cores -> Jellyfin TCP probe."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import asyncio
import json
import os
import shutil
import socket
import sys
import tempfile
import threading
import time

import uvicorn

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from conftest import server as core_fixture
from support.named_flutter_acceptance import run_named_flutter
from test_media_archive_core_read import configured


TOKENS = {
    "f19-home-a-private-token": "10.11.1",
    "f19-home-b-private-token": "10.11.2",
}


class RequestGate:
    def __init__(self, app, path):
        self.app = app
        self.path = path
        self.entered = threading.Event()
        self.release = threading.Event()
        self._lock = threading.Lock()
        self._armed = False

    def arm(self):
        with self._lock:
            self.entered.clear()
            self.release.clear()
            self._armed = True

    def unblock(self):
        self.release.set()

    async def __call__(self, scope, receive, send):
        selected = False
        if scope.get("type") == "http" and scope.get("path") == self.path:
            with self._lock:
                if self._armed:
                    self._armed = False
                    selected = True
        if selected:
            self.entered.set()
            released = await asyncio.to_thread(self.release.wait, 30)
            if not released:
                raise RuntimeError("bounded_request_gate_timeout")
        await self.app(scope, receive, send)


class GateControl(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    gate = None

    def _empty(self, status):
        self.send_response(status)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        gate = type(self).gate
        if self.path != "/entered" or gate is None:
            self._empty(404)
            return
        self._empty(200 if gate.entered.is_set() else 409)

    def do_POST(self):
        gate = type(self).gate
        if gate is None:
            self._empty(409)
        elif self.path == "/arm":
            gate.arm()
            self._empty(204)
        elif self.path == "/release":
            gate.unblock()
            self._empty(204)
        else:
            self._empty(404)

    def log_message(self, *_args):
        pass


class JellyfinFixture(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    reads = {token: 0 for token in TOKENS}

    def do_GET(self):
        token = self.headers.get("X-Emby-Token")
        if self.path != "/System/Info" or token not in TOKENS:
            self.send_error(401)
            return
        type(self).reads[token] += 1
        body = json.dumps({
            "ProductName": "Jellyfin Server",
            "Version": TOKENS[token],
            "StartupWizardCompleted": True,
        }).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        pass


def _serve(app):
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.bind(("127.0.0.1", 0))
    server = uvicorn.Server(uvicorn.Config(
        app, log_level="critical", access_log=False
    ))
    thread = threading.Thread(
        target=lambda: server.run(sockets=[listener]), daemon=True
    )
    thread.start()
    deadline = time.monotonic() + 5
    while not server.started:
        if not thread.is_alive() or time.monotonic() >= deadline:
            raise RuntimeError("isolated_core_startup_failed")
        time.sleep(0.02)
    return (
        f"http://127.0.0.1:{listener.getsockname()[1]}",
        server,
        thread,
        listener,
    )


def _stop(server, thread, listener):
    server.should_exit = True
    thread.join(timeout=5)
    listener.close()


TEST_FILE = "test/features/server/server_multi_core_normal_test.dart"
TEST_NAME = "actual Client keeps two normal Core homes and services independent"


def _flutter(phase, store, core_a, core_b, jellyfin, logs, control=None):
    run_named_flutter(
        test_file=TEST_FILE,
        test_name=TEST_NAME,
        cwd=Path(__file__).resolve().parents[3],
        log_path=logs / f"f19-{phase}.machine.log",
        env={
            **os.environ,
            "LARENOR_F19_PHASE": phase,
            "LARENOR_F19_STORE": str(store),
            "LARENOR_F19_CORE_A": core_a,
            "LARENOR_F19_CORE_B": core_b,
            "LARENOR_F19_JELLYFIN": jellyfin,
            **({"LARENOR_F19_CONTROL": control} if control else {}),
        },
    )
    return 0


def _catalog(worker, title):
    item = worker.result.jellyfin.items[0].model_copy(update={"title": title})
    worker.result = worker.result.model_copy(update={
        "jellyfin": worker.result.jellyfin.model_copy(update={"items": [item]})
    })


def _private_copy(source, destination):
    shutil.copyfile(source, destination)
    destination.chmod(0o600)


def _duplicate_authority(source, destination):
    _private_copy(source, destination)
    payload = json.loads(destination.read_text())
    if set(payload) != {"version", "activeProfileId", "profiles"}:
        raise RuntimeError("unexpected_registry_shape")
    active = payload["activeProfileId"]
    original = next(
        profile for profile in payload["profiles"]
        if profile["profileId"] != active
    )
    duplicate = json.loads(json.dumps(original))
    duplicate["profileId"] = "f" * 32
    payload["profiles"].append(duplicate)
    destination.write_text(json.dumps(payload, separators=(",", ":")))
    destination.chmod(0o600)


def main():
    with tempfile.TemporaryDirectory(prefix="larenor-f19-client-") as root:
        root = Path(root)
        requested_logs = os.environ.get("LARENOR_F19_LOG_DIR")
        logs = Path(requested_logs) if requested_logs else root / "logs"
        if not logs.is_absolute():
            raise RuntimeError("invalid_private_log_directory")
        logs.mkdir(mode=0o700, exist_ok=requested_logs is not None)
        if logs.is_symlink() or logs.stat().st_mode & 0o077:
            raise RuntimeError("invalid_private_log_directory")
        generator_a = core_fixture.__wrapped__(root / "core-a")
        generator_b = core_fixture.__wrapped__(root / "core-b")
        fixture_a = next(generator_a)
        fixture_b = next(generator_b)
        app_a, _client_a, _settings_a, clock_a = fixture_a
        app_b, _client_b, _settings_b, clock_b = fixture_b
        clock_a.now = clock_b.now = time.time()
        _pair_a, _installation_a, _authority_a, _reader_a, worker_a, _body_a = configured(fixture_a)
        _pair_b, _installation_b, _authority_b, _reader_b, worker_b, _body_b = configured(fixture_b)
        _catalog(worker_a, "Home A Matrix")
        _catalog(worker_b, "Home B Matrix")

        upstream = ThreadingHTTPServer(("127.0.0.1", 0), JellyfinFixture)
        upstream_thread = threading.Thread(
            target=upstream.serve_forever, daemon=True
        )
        upstream_thread.start()
        jellyfin = f"http://127.0.0.1:{upstream.server_port}"
        source_me = RequestGate(app_b, "/api/v1/auth/me")
        source_context = RequestGate(source_me, "/api/v1/context")
        target_me = RequestGate(app_a, "/api/v1/auth/me")
        target_context = RequestGate(target_me, "/api/v1/context")
        gates = {
            "cancel_source_me": source_me,
            "cancel_source_context": source_context,
            "cancel_target_me": target_me,
            "cancel_target_context": target_context,
        }
        # The wrappers stay disarmed during every account initialization and
        # gate only the first matching request after the test explicitly arms
        # one selected Core/route pair.
        core_a = _serve(target_context)
        core_b = _serve(source_context)
        control = ThreadingHTTPServer(("127.0.0.1", 0), GateControl)
        control_thread = threading.Thread(
            target=control.serve_forever, daemon=True
        )
        control_thread.start()
        control_url = f"http://127.0.0.1:{control.server_port}"
        store = root / "client-profile-vault.json"
        duplicate_store = root / "duplicate-profile-vault.json"
        try:
            if _flutter(
                "prepare", store, core_a[0], core_b[0], jellyfin, logs
            ) != 0:
                raise RuntimeError("multi_core_prepare_failed")
            if JellyfinFixture.reads != {
                "f19-home-a-private-token": 1,
                "f19-home-b-private-token": 1,
            }:
                raise RuntimeError("multi_core_provider_probe_failed")
            if len(worker_a.calls) != 1 or len(worker_b.calls) != 1:
                raise RuntimeError("multi_core_catalog_cache_scope_failed")

            original_context_a = app_a.state.core.context
            try:
                app_a.state.core.context = app_b.state.core.context
                if _flutter(
                    "negative_authority", store, core_a[0], core_b[0], jellyfin,
                    logs,
                ) != 0:
                    raise RuntimeError("cross_home_authority_rejection_failed")
            finally:
                app_a.state.core.context = original_context_a
            if len(worker_a.calls) != 1 or len(worker_b.calls) != 1:
                raise RuntimeError("catalog_projected_after_authority_rejection")

            for phase, gate in gates.items():
                GateControl.gate = gate
                try:
                    _flutter(
                        phase, store, core_a[0], core_b[0], jellyfin, logs,
                        control_url,
                    )
                finally:
                    gate.unblock()
                if len(worker_a.calls) != 1 or len(worker_b.calls) != 1:
                    raise RuntimeError("catalog_projected_after_cancellation")

            _duplicate_authority(store, duplicate_store)
            if _flutter(
                "duplicate_restore", duplicate_store,
                core_a[0], core_b[0], jellyfin, logs,
            ) != 0:
                raise RuntimeError("duplicate_authority_restore_failed")
            if len(worker_a.calls) != 1 or len(worker_b.calls) != 1:
                raise RuntimeError("provider_io_after_duplicate_restore")

            _stop(core_a[1], core_a[2], core_a[3])
            core_a = None
            if _flutter(
                "restart", store, "http://127.0.0.1:1", core_b[0], jellyfin,
                logs,
            ) != 0:
                raise RuntimeError("multi_core_restart_failed")
            if JellyfinFixture.reads != {
                "f19-home-a-private-token": 1,
                "f19-home-b-private-token": 1,
            }:
                raise RuntimeError("unexpected_provider_io_after_restart")
            return 0
        finally:
            if core_a is not None:
                _stop(core_a[1], core_a[2], core_a[3])
            if core_b is not None:
                _stop(core_b[1], core_b[2], core_b[3])
            for gate in gates.values():
                gate.unblock()
            control.shutdown()
            control.server_close()
            control_thread.join(timeout=5)
            upstream.shutdown()
            upstream.server_close()
            upstream_thread.join(timeout=5)
            generator_a.close()
            generator_b.close()


if __name__ == "__main__":
    sys.exit(main())
