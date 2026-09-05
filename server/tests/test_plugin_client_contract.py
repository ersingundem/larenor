"""The same versioned catalog/plan fixtures drive Python routes and Dart UI."""

import json
from pathlib import Path

from conftest import auth, ready
from larenor_server.plugins.catalog import load_catalog, verify_plan
from larenor_server.plugins.models import InstallPlan


FIXTURE = Path(__file__).resolve().parents[2] / "test/fixtures/server_plugins.v1.json"
BASE = "/api/v1/admin/plugins"


def test_actual_api_matches_every_shared_client_catalog_and_plan_fixture(server):
    _, client, _, _ = server
    pair = ready(server)
    fixture = json.loads(FIXTURE.read_text())
    response = client.get(BASE + "/catalog", headers=auth(pair))
    assert response.status_code == 200
    assert response.json() == fixture["catalog"]
    catalog = load_catalog()
    for case in fixture["plans"]:
        entry = next(item for item in catalog.entries if item.manifest.serviceId == case["serviceId"])
        expected = InstallPlan.model_validate_json(json.dumps(case["plan"]))
        assert verify_plan(expected, catalog) == expected
        body = {"serviceId": case["serviceId"], "distributionId": entry.manifest.distributionId,
                "manifestDigest": entry.manifestDigest, "platform": case["platform"], "settings": case["settings"]}
        result = client.post(BASE + "/previews", headers=auth(pair), json=body)
        assert result.status_code == 201
        assert result.json()["preview"]["plan"] == case["plan"]
