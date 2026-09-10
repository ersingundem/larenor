"""One wire fixture is consumed independently by FastAPI and the Dart Client."""

import json
from pathlib import Path
from types import SimpleNamespace
import uuid
from urllib.parse import urlsplit

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
        if request == 'checkRequest':
            # F13 requires an explicit grant before the unchanged probe wire contract.
            current = fixture['updatedResponse']['service']
            destination = urlsplit(current['baseUrl'])
            granted = client.put(path + '/' + record_id + '/outbound-policy', headers=auth(pair), json={
                'expectedRevision': 0, 'expectedServiceRevision': current['revision'],
                'grants': [{'scheme': destination.scheme, 'host': destination.hostname,
                            'port': destination.port or (443 if destination.scheme == 'https' else 80),
                            'addresses': [{'address': '10.20.30.40', 'network': 'lan'}]}]})
            assert granted.status_code == 200, granted.text
        result = client.request(method, path + suffix, headers=auth(pair), json=fixture[request])
        assert result.status_code == (201 if request == "createRequest" else 200)
        assert result.json() == fixture[response]
        assert "synthetic-contract-only" not in result.text
        assert client.get(path, headers=auth(pair)).json() == {"services": [fixture[response]["service"]]}
    assert client.delete(path + "/" + record_id + "?expectedRevision=2", headers=auth(pair)).status_code == 204
    assert client.get(path, headers=auth(pair)).json() == {"services": []}
