"""Real Flutter Client -> normal Core -> owned Home Assistant TCP probe.

The owned upstream binds only the runner's RFC 1918 interface. This exercises
the production egress address pin without weakening its deliberate loopback
denial and never contacts a household service.
"""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import ipaddress
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from conftest import ready, server as core_fixture
from support.installed_core_tcp import InstalledCoreTcp


_PRIVATE = tuple(ipaddress.ip_network(value) for value in (
    "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16",
))


def _fixture_address():
    candidates = []
    route = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        route.connect(("192.0.2.1", 9))
        candidates.append(route.getsockname()[0])
    except OSError:
        pass
    finally:
        route.close()
    try:
        candidates.extend(
            answer[4][0] for answer in socket.getaddrinfo(
                socket.gethostname(), None, family=socket.AF_INET,
                type=socket.SOCK_STREAM,
            )
        )
    except OSError:
        pass
    for raw in dict.fromkeys(candidates):
        try:
            address = ipaddress.ip_address(raw)
        except ValueError:
            continue
        if any(address in network for network in _PRIVATE):
            return str(address)
    raise RuntimeError("private_fixture_address_unavailable")


def main():
    calls = []

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_args):
            pass

        def do_GET(self):
            calls.append((self.command, self.path,
                          self.headers.get("Authorization")))
            if (self.path != "/api/config" or
                    self.headers.get("Authorization") != "Bearer f13-owned-token"):
                self.send_error(404)
                return
            raw = json.dumps({
                "version": "2026.9.3",
                "components": ["api", "websocket_api"],
            }, separators=(",", ":")).encode("ascii")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(raw)

    address = _fixture_address()
    upstream = ThreadingHTTPServer((address, 0), Handler)
    worker = threading.Thread(target=upstream.serve_forever, daemon=True)
    worker.start()
    try:
        with tempfile.TemporaryDirectory(prefix="larenor-f13-client-") as root:
            state_file = Path(root) / "client-state.json"
            for phase in ("configure", "restart"):
                generator = core_fixture.__wrapped__(Path(root))
                fixture = next(generator)
                try:
                    if phase == "configure":
                        ready(fixture)
                    with InstalledCoreTcp(fixture[0]) as tcp:
                        result = subprocess.run([
                            "flutter", "test", "--no-pub",
                            "test/features/server/server_component_egress_normal_core_test.dart",
                        ], env={
                            **os.environ,
                            "LARENOR_F13_CORE_URL": f"http://127.0.0.1:{tcp.port}",
                            "LARENOR_F13_PHASE": phase,
                            "LARENOR_F13_STATE_FILE": str(state_file),
                            "LARENOR_F13_HA_URL": (
                                f"http://{address}:{upstream.server_port}"
                            ),
                        }, cwd=Path(__file__).resolve().parents[3],
                            timeout=120, check=False)
                        if result.returncode:
                            return result.returncode
                finally:
                    generator.close()
            expected = [
                ("GET", "/api/config", "Bearer f13-owned-token"),
                ("GET", "/api/config", "Bearer f13-owned-token"),
            ]
            if calls != expected:
                raise RuntimeError(f"unexpected_upstream_calls:{calls!r}")
    finally:
        upstream.shutdown()
        upstream.server_close()
        worker.join(timeout=5)
    return 0


if __name__ == "__main__":
    sys.exit(main())
