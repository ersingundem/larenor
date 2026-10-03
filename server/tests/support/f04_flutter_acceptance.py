"""Actual Flutter Client -> normal Core -> owned HA arbitration acceptance."""

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


class _HomeAssistant:
    token = "f04-owned-token"
    entity_id = "switch.f04_owned"

    def __init__(self):
        self.state = "off"
        self.calls = []
        self.overflow = False
        self.calls_lock = threading.Lock()

        fixture = self

        def record(call):
            with fixture.calls_lock:
                if len(fixture.calls) >= 32:
                    fixture.overflow = True
                    return False
                fixture.calls.append(call)
                return True

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
                body = None
                if not record((self.command, self.path,
                               self.headers.get("Authorization"), body)):
                    self._reply(503, {})
                    return
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
                raw = self.rfile.read(length)
                try:
                    body = json.loads(raw)
                except (ValueError, UnicodeError):
                    body = None
                if not record((self.command, self.path,
                               self.headers.get("Authorization"), body)):
                    self._reply(503, {})
                    return
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
        json={"kind": "resource", "label": "F04 owned switch", "order": 0},
    )
    if created.status_code != 201:
        raise RuntimeError("f04_resource_setup_failed")
    resource = created.json()["record"]
    service_response = client.post(
        "/api/v1/admin/services", headers=auth(admin), json={
            "kind": "home_assistant", "name": "F04 owned HA",
            "baseUrl": upstream.url, "credentials": {"token": upstream.token},
        },
    )
    if service_response.status_code != 201:
        raise RuntimeError("f04_service_setup_failed")
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
        raise RuntimeError("f04_binding_preview_failed")
    if preview.json()["preview"]["projection"] != {
            "kind": "switch", "state": "off", "commandAvailable": False}:
        raise RuntimeError("f04_binding_projection_invalid")
    binding = client.post(
        f"/api/v1/admin/home-assistant/{target}/binding-confirm",
        headers=auth(admin), json={"previewId": preview.json()["preview"]["id"]},
    )
    if binding.status_code != 201:
        raise RuntimeError("f04_binding_confirm_failed")
    rule = client.post(
        f"/api/v1/admin/home-assistant/{target}/rules",
        headers=auth(admin), json={
            "schemaVersion": 1, "action": "turn_off",
            "expectedResourceRevision": 1, "expectedAclRevision": 1,
            "expectedBindingRevision": 1, "expectedServiceRevision": 1,
        },
    )
    if rule.status_code != 201:
        raise RuntimeError("f04_rule_setup_failed")
    output.write_text(json.dumps({
        "resource": resource,
        "ruleId": rule.json()["rule"]["id"],
        "manualRequestId": "9" * 32,
        "ruleRequestId": "8" * 32,
    }, separators=(",", ":")))


def _flutter(fixture, phase, fixture_file):
    with InstalledCoreTcp(fixture[0]) as tcp:
        counts = run_named_flutter(
            test_file="test/features/core_ha/core_ha_rule_arbitration_normal_core_test.dart",
            test_name="real Client keeps manual ownership across rule suppression and restart",
            env={
            **os.environ,
            "LARENOR_F04_CORE_URL": f"http://127.0.0.1:{tcp.port}",
            "LARENOR_F04_PHASE": phase,
            "LARENOR_F04_FIXTURE": str(fixture_file),
            }, cwd=Path(__file__).resolve().parents[3],
            log_path=fixture_file.parent / f"f04-{phase}-machine.jsonl",
            timeout_seconds=120,
        )
        print(f"F04 {phase}: named1 passed1 failures0 errors0 skipped0")
        return 0 if counts["passed"] == 1 else 1


def main():
    upstream = _HomeAssistant()
    try:
        with tempfile.TemporaryDirectory(prefix="larenor-f04-client-") as raw:
            root = Path(raw)
            fixture_file = root / "fixture.json"
            for phase in ("manual-suppress", "restart"):
                generator = core_fixture.__wrapped__(root)
                fixture = next(generator)
                try:
                    if phase == "manual-suppress":
                        _configure(fixture, upstream, fixture_file)
                    result = _flutter(fixture, phase, fixture_file)
                    if result:
                        return result
                finally:
                    generator.close()
            methods = [call[:2] for call in upstream.calls]
            if upstream.overflow or methods != [
                    ("GET", f"/api/states/{upstream.entity_id}"),
                    ("GET", f"/api/states/{upstream.entity_id}"),
                    ("POST", "/api/services/switch/turn_on"),
                    ("GET", f"/api/states/{upstream.entity_id}"),
                    ("GET", f"/api/states/{upstream.entity_id}"),
            ]:
                raise RuntimeError("unexpected_upstream_calls")
            if any(call[2] != f"Bearer {upstream.token}" for call in upstream.calls):
                raise RuntimeError("unexpected_upstream_authority")
    finally:
        upstream.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
