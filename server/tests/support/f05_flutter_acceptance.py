"""Actual Flutter Client -> normal Core -> owned HA workflow acceptance."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import sys
import tempfile
import threading

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from conftest import auth, ready, server as core_fixture
from support.installed_core_tcp import InstalledCoreTcp
from support.named_flutter_acceptance import run_named_flutter


TEST_FILE = "test/features/home_workflows/home_workflow_normal_core_test.dart"
TEST_NAME = "real Client completes and reconciles a durable workflow across restart"


class _HomeAssistant:
    token = "f05-owned-token"
    entity_id = "switch.f05_owned"

    def __init__(self):
        self.state = "off"
        self.calls = []
        fixture = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *_args):
                pass

            def _reply(self, status, value):
                raw = json.dumps(value, separators=(",", ":")).encode("ascii")
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(raw)))
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(raw)

            def do_GET(self):
                fixture.calls.append((
                    self.command, self.path, self.headers.get("Authorization"), None,
                ))
                if (self.path != f"/api/states/{fixture.entity_id}" or
                        self.headers.get("Authorization") != f"Bearer {fixture.token}"):
                    self._reply(404, {})
                    return
                self._reply(200, {
                    "entity_id": fixture.entity_id,
                    "state": fixture.state,
                    "attributes": {"private": "never leaves fixture"},
                    "last_updated": "2026-09-30T12:00:00Z",
                })

            def do_POST(self):
                length = int(self.headers.get("Content-Length", "0"))
                try:
                    body = json.loads(self.rfile.read(length))
                except (ValueError, UnicodeError):
                    body = None
                fixture.calls.append((
                    self.command, self.path, self.headers.get("Authorization"), body,
                ))
                if (self.path not in (
                        "/api/services/switch/turn_on",
                        "/api/services/switch/turn_off",
                ) or self.headers.get("Authorization") != f"Bearer {fixture.token}" or
                        body != {"entity_id": fixture.entity_id}):
                    self._reply(404, {})
                    return
                fixture.state = "on" if self.path.endswith("turn_on") else "off"
                self._reply(200, [])

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    @property
    def url(self):
        return f"http://127.0.0.1:{self.server.server_port}"

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)


def _configure(fixture, upstream, output):
    app, client, _, _ = fixture
    admin = ready(fixture)
    scope = app.state.core.context
    root = f"{scope.coreId}/{scope.homeId}"
    created = client.post(
        f"/api/v1/admin/home-resources/{root}", headers=auth(admin),
        json={"kind": "resource", "label": "F05 owned switch", "order": 0},
    )
    if created.status_code != 201:
        raise RuntimeError("f05_resource_setup_failed")
    resource = created.json()["record"]
    service_response = client.post(
        "/api/v1/admin/services", headers=auth(admin), json={
            "kind": "home_assistant", "name": "F05 owned HA",
            "baseUrl": upstream.url, "credentials": {"token": upstream.token},
        },
    )
    if service_response.status_code != 201:
        raise RuntimeError("f05_service_setup_failed")
    service = service_response.json()["service"]
    target = f"{root}/resources/{resource['ref']['id']}"
    preview = client.post(
        f"/api/v1/admin/home-assistant/{target}/binding-preview",
        headers=auth(admin), json={
            "serviceId": service["id"], "expectedServiceRevision": 1,
            "expectedRevision": 1, "expectedAclRevision": 1,
            "entityId": upstream.entity_id, "expectedBindingId": None,
        },
    )
    if preview.status_code != 201:
        raise RuntimeError("f05_binding_preview_failed")
    if preview.json()["preview"]["projection"] != {
            "kind": "switch", "state": "off", "commandAvailable": False}:
        raise RuntimeError("f05_binding_projection_invalid")
    confirm = client.post(
        f"/api/v1/admin/home-assistant/{target}/binding-confirm",
        headers=auth(admin), json={"previewId": preview.json()["preview"]["id"]},
    )
    if confirm.status_code != 201:
        raise RuntimeError("f05_binding_confirm_failed")
    output.write_text(json.dumps({"resource": resource}, separators=(",", ":")))


def _flutter(fixture, phase, fixture_file):
    with InstalledCoreTcp(fixture[0]) as tcp:
        counts = run_named_flutter(
            test_file=TEST_FILE,
            test_name=TEST_NAME,
            env={
                **os.environ,
                "LARENOR_F05_CORE_URL": f"http://127.0.0.1:{tcp.port}",
                "LARENOR_F05_PHASE": phase,
                "LARENOR_F05_FIXTURE": str(fixture_file),
            },
            cwd=Path(__file__).resolve().parents[3],
            log_path=fixture_file.parent / f"f05-{phase}.machine.jsonl",
            timeout_seconds=120,
        )
        print(f"F05 {phase}: named1 passed1 failures0 errors0 skipped0")
        return 0 if counts["passed"] == 1 else 1


def main():
    upstream = _HomeAssistant()
    try:
        with tempfile.TemporaryDirectory(prefix="larenor-f05-client-") as raw:
            root = Path(raw)
            fixture_file = root / "fixture.json"
            for phase in ("create-approve", "restart"):
                generator = core_fixture.__wrapped__(root)
                fixture = next(generator)
                try:
                    if phase == "create-approve":
                        _configure(fixture, upstream, fixture_file)
                    result = _flutter(fixture, phase, fixture_file)
                    if result:
                        return result
                finally:
                    generator.close()
            methods = [call[:2] for call in upstream.calls]
            expected = [
                ("GET", f"/api/states/{upstream.entity_id}"),
                ("GET", f"/api/states/{upstream.entity_id}"),
                ("POST", "/api/services/switch/turn_on"),
                ("GET", f"/api/states/{upstream.entity_id}"),
                ("GET", f"/api/states/{upstream.entity_id}"),
            ]
            if methods != expected:
                raise RuntimeError("unexpected_upstream_calls")
            if any(call[2] != f"Bearer {upstream.token}" for call in upstream.calls):
                raise RuntimeError("unexpected_upstream_authority")
    finally:
        upstream.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
