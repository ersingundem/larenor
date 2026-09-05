"""One Core context contract is consumed by actual Server routes and Dart."""

import json
from pathlib import Path
from types import SimpleNamespace

from fastapi.testclient import TestClient
from pydantic import ValidationError
import pytest

from conftest import auth, ready
from larenor_server.app import create_app
from larenor_server.config import Settings
from larenor_server.context import ContextResponse
import larenor_server.context as context_module


FIXTURE = json.loads((Path(__file__).resolve().parents[2] /
                      "contracts/core-context.v1.json").read_text())


@pytest.mark.parametrize("case", FIXTURE["validResponses"], ids=lambda case: case["name"])
def test_real_context_route_and_restart_match_the_shared_client_contract(tmp_path, monkeypatch, case):
    expected = case["value"]
    generated = iter([expected["coreId"], expected["homeId"]])

    def identity_bytes(size):
        assert size == 16
        return next(generated)

    # Only identity generation is deterministic; migration/auth/route/DB stay real.
    monkeypatch.setattr(context_module, "secrets", SimpleNamespace(token_hex=identity_bytes))
    settings = Settings(tmp_path / "data", tmp_path / "secrets/key")
    app = create_app(settings)
    with TestClient(app) as client:
        pair = ready((app, client, settings, None))
        response = client.get("/api/v1/context", headers=auth(pair))
        assert response.status_code == 200
        assert response.headers["cache-control"] == "no-store"
        assert response.json() == expected
        assert ContextResponse.model_validate_json(response.content).model_dump() == expected
        schema = client.get("/api/v1/openapi.json", headers=auth(pair)).json()
        model = schema["components"]["schemas"]["ContextResponse"]
        assert set(model["required"]) == set(expected)
        assert set(model["properties"]) == set(expected)
        assert model["additionalProperties"] is False
        assert model["properties"]["schemaVersion"]["const"] == 1
        assert model["properties"]["schemaVersion"]["type"] == "integer"
    # The two deterministic IDs have been consumed: regeneration would also fail.
    with TestClient(create_app(settings)) as restarted:
        response = restarted.get("/api/v1/context", headers=auth(pair))
        assert response.status_code == 200
        assert response.json() == expected


@pytest.mark.parametrize("case", FIXTURE["invalidResponses"], ids=lambda case: case["name"])
def test_server_model_rejects_the_same_invalid_context_payloads_as_client(case):
    with pytest.raises(ValidationError):
        ContextResponse.model_validate(case["value"])
    with pytest.raises(ValidationError):
        ContextResponse.model_validate_json(json.dumps(case["value"]))


def test_context_model_is_immutable_after_validation():
    model = ContextResponse.model_validate(FIXTURE["validResponses"][0]["value"])
    with pytest.raises(ValidationError):
        model.homeId = "f" * 32
