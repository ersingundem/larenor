"""One wire fixture is consumed independently by FastAPI and the Dart Client."""

import json
from pathlib import Path
from types import SimpleNamespace
import uuid

from conftest import auth, ready
from larenor_server.services.probe_runner import ServiceProbeRunner


def test_fastapi_service_lifecycle_matches_the_shared_client_contract(server, monkeypatch):
    fixture = json.loads((Path(__file__).resolve().parents[2] / "contracts/service-connections.v1.json").read_text())
    app, client, _, _ = server
    pair = ready(server)
    record_id = fixture["createdResponse"]["service"]["id"]
    monkeypatch.setattr("larenor_server.services.service.uuid.uuid4", lambda: uuid.UUID(hex=record_id))
    app.state.core.service_probe = ServiceProbeRunner(app.state.core.services,
        probe=lambda _: SimpleNamespace(state="authenticated", version="2026.9.1"))
    path = "/api/v1/admin/services"
    for method, suffix, request, response in [
        ("POST", "", "createRequest", "createdResponse"),
        ("PATCH", "/" + record_id, "updateRequest", "updatedResponse"),
        ("POST", "/" + record_id + "/check", "checkRequest", "checkedResponse"),
    ]:
        result = client.request(method, path + suffix, headers=auth(pair), json=fixture[request])
        assert result.status_code == (201 if request == "createRequest" else 200)
        assert result.json() == fixture[response]
        assert "synthetic-contract-only" not in result.text
        assert client.get(path, headers=auth(pair)).json() == {"services": [fixture[response]["service"]]}
    assert client.delete(path + "/" + record_id + "?expectedRevision=2", headers=auth(pair)).status_code == 204
    assert client.get(path, headers=auth(pair)).json() == {"services": []}
